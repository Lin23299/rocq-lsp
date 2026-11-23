# U3 私有模块重写规格（petanque/json_shell）

本目录是重写工作的内部规格，不进 git（.gitignore 已排除）。权威来源：
- 主仓 devlog：`refs/devlog/2026-11-20-u3-six-item-local-handoff.md`（最权威）
- 设计合同：`refs/design/native-driver.md`
- Rust 消费侧（行为规格，歧义以此为准）：
  `refs/native/` 下同名文件（state_operations.rs 等 8 个`
- 协议（唯一 wire 真相）：`refs/protocol/types.mli`（实现 types.ml 同目录，可读语义）
- 本仓基线：`petanque/json_shell/pet_native.ml`（四通道/source/begin-pull-ack-finish 已有）

## 0. 全局约定

- 构建（唯一验收命令，环境必须干净）：
  ```
  env -i HOME=/home/ubuntu PATH=/home/ubuntu/.opam/rocq90/bin:/usr/local/bin:/usr/bin:/bin \
    OCAMLPATH=/home/ubuntu/tools/rocq-lsp-nativeface-u3/.ccv-findlib:/home/ubuntu/.opam/rocq90/lib:/home/ubuntu/.opam/rmcp10-preflight/lib \
    /home/ubuntu/.opam/rmcp10-preflight/bin/dune build \
    --root /home/ubuntu/tools/rocq-lsp-nativeface-u3 --profile release -j1 \
    petanque/json_shell/pet_native.exe @petanque/json_shell/runtest
  ```
- 协议库经 `.ccv-findlib/ccv_protocol`（symlink 到 stage `/home/ubuntu/ccv-stages/u5-20261123/ocaml-build`）。
- 注释中文；模块头注说明职责与不承诺的事（对齐 devlog「真实/未知」口径）。
- 错误口径：拒绝（protocol_error，not_admitted）与「已尝试、结果未知」（不发布新身份、操作无终态、status 报 Ready/Executing 且 terminal=FUnknown）必须区分；绝不用编造成功掩盖未知。
- 单调时钟：deadline 一律绝对 CLOCK_MONOTONIC 微秒（`Unix.clock_gettime` `CLOCK_MONOTONIC` 换算），与 Rust `NativeDriver::monotonic_time_us` 同域。
- 所有通道 reply 的 header 必须逐字回显请求 header（含 rpc_seq）。
- 新私有模块放 `petanque/json_shell/`，入 dune 新库 `pet_native_support`（见 §6）。

## 1. 架构与共享注册表（item 1 接线基础）

### pet_registry.ml（接线基础的一部分）
共享运行态（基线在 pet_native.ml 的表全部迁来，供各私有模块使用）：

```ocaml
type source = { data : source_data; expected_digest : string; mutable next_offset : int64 } (* 基线原样 *)
type op_state = Ready | Executing | WaitAck | TerminalState | Retiring
type operation = {
  binding : T.op_binding;
  mutable state : op_state;
  mutable pending : T.receipt option;      (* WAIT_ACK 未确认步 *)
  mutable terminal : T.terminal_record option;
  mutable aux : T.aux_terminal option;      (* 六方法 aux 终态；重读返回原事实 *)
  mutable last_ack : T.ack_status option;
  mutable acked_through : int64;
  mutable line : T.Id.t; mutable line_revision : int64;
  mutable cursor : int64; mutable parent : T.Id.t;
  mutable source : T.Id.t;
  mutable doc : Fleche.Doc.t option;        (* 主线/上下文持有 *)
}
val init : unit -> unit
val with_tables : (unit -> 'a) -> 'a        (* Mutex，沿用基线 *)
val find_operation : T.op_binding -> operation option
val register_operation : T.op_binding -> operation -> unit
val iter_operations : (operation -> unit) -> unit
val sources/budgets 表访问（budget 存 T.native_budget，不再存 unit）
val add_budget : T.native_budget -> unit                   (* budget_equal 同内容幂等，否则冲突 *)
val find_budget : T.Id.t -> T.native_budget option
val highest_seen : int64 ref 等价访问；retired_through : int64 ref
val now_us : unit -> int64                                 (* CLOCK_MONOTONIC µs *)
val deadline_expired : T.native_budget -> [`Execution|`Recovery|`Output] -> bool
val reserve_input / release_input : int64 -> bool           (* input quota 记账 *)
```

预算准入（NW02 消费侧）：每个新操作请求先 `T.entry_uses_budget` 核对 budget 与请求匹配；
operation_seq 必须是 `highest_seen+1`（新）或已存在（幂等/查态）；已 retire 的 seq 返回
`T.make_past_unavailable`。

### pet_native.ml 接线（item 1 同批）
1. 修 API 漂移：`T.make_status`（补 `~retired_through:!retired_through`）、`T.error_terminal`（补
   `~group`）、`T.make_ack`（补 `~group`，主线 append 无组 ⇒ `None`）。
2. 全构造器分派（`T.native_request_view` 19 个分支全覆盖）：
   - 基线七项（Begin/Pull/Ack/Status/Finish/RegisterBudget/Other）保留，迁到 Registry。
   - `LocateContextRequest`/`SelectLineRequest`/`ForkLineRequest`：pet_native 内联最小真实实现
     （见 §1.1）。
   - `SyncSourceRequest` → Pet_source_sync；`RefreshEnvironmentRequest` → Pet_environment_refresh；
     `QueryRequest`/`InspectRequest` → Pet_query/Pet_inspect；`CheckpointRequest` →
     Pet_checkpoint_dispatch；`EndScopeRequest` → Pet_scope_lifecycle。
   - `SettleInterruptRequest` → 中断落定（§1.2）；`RetireThroughRequest` → 更新 retired_through 并
     `T.make_retired`。
3. 控制通道 serve 线程（fd 5）：`T.decode_control_request` + `control_request_view`：
   - `ReadControl op` → 按 op 查控制快照（见 §1.2），`T.control_snapshot`；未知 op →
     `T.control_unknown_operation`。
   - `RequestCancel (op, cancel_seq, reason-忽略)` → `T.control_cancel_ack`：核 cancel_seq >
     已见最大取消序号（等值幂等重放原 ACK；更小 PastCancel）；对当前执行 token 执行
     `Coq.Limits.Token.set`（原子 token），stop_requested=true；token 代际只在恢复后递增。
4. source 通道（fd 6）：帧先 `S.decode` 取 `method` 字段分派：`source_*` 走基线 source_handle；
   `checkpoint_blob_begin/chunk/finish` → Pet_checkpoint_dispatch 上传分支。未知 method → 该通道
   protocol_error（帧级回错，进程不崩）。
5. view 通道（fd 7）：`view_pull/ack/release`（`T.decode_view_request`）→ 先查 Pet_source_sync 的
   line_updates spool，再查 Pet_query/Pet_inspect 的 view spool，再查 checkpoint 下载 spool；
   `checkpoint_blob_pull/ack/release` → Pet_checkpoint_dispatch 下载分支。
6. Budget 登记改为存 `T.native_budget`：`T.budget_for_task_entry`/`budget_equal` 校验；重复完整相同
   幂等返回原 `make_budget_registered`，异内容 `BindingConflict`；`checkpoint_input_budget` 等供
   checkpoint 用。

### 1.1 locate / fork / select（内联，最小真实）
- 线注册表（Registry 内）：`line id -> {revision; frontier node; group id * rev option; open}`。
  BeginLine 建立（沿用基线语义 + 线表登记）。locate：在当前 context 的 doc 上按 target（Root/
  End/Position/Thm）用 `Shell.build_doc` 结果定位；已到目标 ⇒ `T.make_locator_terminal`（LocatedRoot/
  LocatedBoundary(make_entry_boundary)/…），未到 ⇒ `PrefixRequired`；`T.locate_fields` 解包参数。
- fork：`T.fork_fields` 解包；校父线存在且 revision 匹配 ⇒ 新线（frontier=父 frontier，revision=父
  rev）⇒ `T.make_fork_terminal`（node=父 frontier，group=(exploration, 事务后组快照 rev+1…用
  `group_revision > expected`，Rust 端 `state_operation_terminal` 只核 group.group()==exploration）。
  幂等：同 binding 重入返回已存 aux。
- select：`T.select_fields`/`select_group`；目的线/候选核版本后：frontier 换到候选节点、
  revision+1、组版本递增 ⇒ `T.make_selected_group`（group=Known）。无组（`select_group=None`）⇒
  `T.make_selected_entry`。Error 分支用 `T.error_terminal ~group:(Some 组快照)`（Rust
  `grouped_selection_receipt` 接受 Error{group=N/A} 或 Selected{group=Known}）。
  注意：候选线本身在本批没有独立执行栈，select 只做账本迁移 + 返回；**不谎称已重放执行**——若
  目的 doc 的真实 state 与账本不一致，本批按 devlog「实际NC01完整制品事实…由后续owner输入」处理：
  不实现的路径返回 `invalid_input/not_admitted`，不留假成功。

### 1.2 中断落定 + Shell.restore_sentence（devlog 六项 #1）
- Shell（shell.ml/mli 新增）：
  ```ocaml
  val step_doc : ... -> Fleche.Doc.t * [< `Step of int | `Eof | `Error of [`Parse|`Execute] | `Unknown | `Interrupted of [`Parse|`Execute] ]
  (* Interrupted：Coq.Protect.R.Interrupted / Sys.Break 真实发生；快照 = 步前 doc（父），stage 区分 parse/execute *)
  val restore_sentence : token:Coq.Limits.Token.t -> doc:Fleche.Doc.t -> cursor:int -> Fleche.Doc.t
  (* 用新 token 从父快照恢复：丢弃中断产生的半成品节点，重放同一句的目标定位（Position），停在中断句之前 *)
  val snapshot_doc : Fleche.Doc.t -> Fleche.Doc.t   (* 共享不可变结构，纯记录 *)
  ```
- pet_native：operation 记 `interrupt : {requested: bool; cancel_seq_seen: int64; generation: int64;
  snapshot: Fleche.Doc.t option}`。RequestCancel ⇒ Token.set + requested=true（代际不变）。
  SettleInterrupt：
  1. 若该 op 无在途中断 ⇒ `invalid_state/not_admitted`。
  2. 等执行真实退出（Pet 单线程：SettleInterrupt 到达时 eval 已返回 Interrupted，`step_doc` 已把
     快照存 op）。
  3. `Shell.restore_sentence` 原恢复期限内恢复父快照；成功 ⇒ generation+1、`T.make_interrupted_terminal`
     （stopped=Known true、synchronized=Known true、last_acked=Known 上个 ACK 父、pending=N/A、
     recoverable=Known true、diagnostic=FUnknown、extent=CompleteKnown）。恢复失败 ⇒ 保留 Unknown，
     不发终态（status 报 Retiring）。
- 控制快照（ReadControl）：phase = 有 pending eval ⇒ Active；terminal ⇒ TerminalPhase；否则 Idle。
  token_generation、highest_cancel_seq、stop_requested 从 op 中断账本读。

## 2. item 2：pet_source_sync.ml + pet_source_prefix.ml（NN03）

### pet_source_prefix.ml（纯逻辑）
```ocaml
type horizon = { read_end : int; saw_eof : bool }
val lcp : old:string -> new_:string -> int        (* 字节 LCP，落在 UTF-8 字符边界 *)
val retain :
  token:Coq.Limits.Token.t -> env:Fleche.Doc.Env.t -> uri:Lang.LUri.File.t ->
  old_raw:string -> old_doc:Fleche.Doc.t -> new_raw:string ->
  { doc : Fleche.Doc.t; prefix_end : int; kept : int (* 保留节点数 *) ; changed : bool }
(* Fleche retain adapter：new==old ⇒ 原样；否则 bump_version 后 check 到 LCP 位置；
   保留前缀 = 新 doc 中 end ≤ LCP、无 error diag、ast 完整的连续前驱链；prefix_end = 最后保留节点 end。 *)
val horizon_of : Fleche.Doc.t -> int -> horizon
(* read_end = 下一未验证节点起点（保守 lexer 高水位；无下一节点 ⇒ 最后节点 end）；saw_eof = completed=Yes *)
```

### pet_source_sync.ml
状态（Mutex 内）：`contexts : (context_id -> {doc; uri; source_id; revision; lines: 线注册表投影;
sync_in_progress : binding option})`；`line_updates_spool : view_id -> spool`。

`Sync.prepare_locked header binding context_id (old_source, expected_rev) new_source publication`：
1. 核：context 存在、revision=expected_rev、旧 source=登记 id、新 source 已 sealed（Registry）、
   binding.context=context、`T.entry_uses_budget`、budget.output_bytes>0（Rust 前置同款）。
2. 幂等：同 binding 已有 aux ⇒ 原样重放（status 与直答都只回原事实）。
3. 拒绝与新试区分：任一前置不符 ⇒ `make_protocol_error invalid_input not_admitted`；材料齐 ⇒ 继续。
4. 同内容（old bytes == new bytes）：不重建 doc；产出完整未变线表（每线 before=after），
   `T.make_native_line_change`/`make_native_line_update_document`（线集 = 该 context 全部公开线，
   按 line ID 排序去重，`make_native_line_update_document` 自带校验）；spool 封存（§下）；
   `T.make_source_synced_terminal`（revision 不变、boundary=FN/A、last_valid=FKnown 当前 frontier、
   reclaim=新 id）。
5. 内容变化：`Pet_source_prefix.retain` 求 LCP/新 doc；线表逐线：frontier 在保留前缀内 ⇒ before=after
   （frontier 不变）；否则该线 closing（state=LineRetiring，frontier 保留原值——Rust 端允许 Retiring
   报 Known/Unknown）；context revision+1。doc 替换为 retain 结果。
6. line_updates 封存（「完整 line_updates 封存及原子映射发布」）：
   - 文档字节 = `T.encode_native_line_update_document`；写有限 FD spool（`Filename.temp_file` 于
     `$TMPDIR`，默认 /tmp——本进程私有易失材料，允许；失控即 unlink）。
   - view id = 新分配 `Id("view-<binding.operation>-<seq>")`；ref =
     {view; digest=sha256(全文); bytes=len}。
   - 「原子映射发布」：图变化（doc/revisions/线表）与 spool 注册在同一 `with_tables` 临界区内提交。
   - GraphTxn 语义：prepare 全部成功才发布；编码/写 spool 失败 ⇒ 拒绝本次（invalid_input 或
     capacity），context 不动。
7. RETIRING 语义：若该 context 有 pending/inflight 未决（存在 pending receipt 或执行中的操作占
   doc）⇒ 返回 status=Retiring（`T.make_retiring_status`），本次不发终态；同一操作续调至完成
   （devlog/Rust：SyncSource/RefreshEnvironment 的 (Retiring, *) 分支）。

view 通道服务（供 pet_native 分派）：
`view_pull (view,operation,seq,offset,credit)`：仅服务本模块 spool；credit 4..8192、seq=last_ack+1、
offset=已确认偏移；块 = spool 的 [offset, offset+credit) 内最大完整 UTF-8 前缀；eof = 到达 bytes；
每块 `T.make_view_chunk`，capture= complete/captured_bytes=总 bytes/total=Known(bytes)/digest=
Known(ref.digest)/missing=[]/reason=N/A（Rust `checked_line_update_pull` 逐项核）。
`view_ack`：核 seq/end_offset/digest(块 SHA-256) ⇒ `T.make_view_acked`，推进游标；旧 seq ⇒
`T.make_view_ack_retired`。`view_release`：核 last_acked ⇒ `T.make_view_released`（真实 unlink spool
后才 Released；有 pending ⇒ Closing）。

## 3. item 3：checkpoint graph → arena → dispatch

### pet_checkpoint_graph.ml（纯内核，无 IO）
输入为已解码的 `T.checkpoint_requirements`/`T.checkpoint_coverage_manifest`/`T.checkpoint_import_map`
（types.mli 具名 record）。职责 = 反序列化后纯清单逐路径检查：
- `validate_requirements : T.checkpoint_requirements -> (unit, string) result`
  逐 node（cnm_*）核：parent 索引存在且更早、source ∈ required_sources、start<end≤cursor≤read_end、
  read_end>saw_eof ⇒ end==read_end；boundaries 行单调、node_index 有界。
- `validate_manifest : T.checkpoint_coverage_manifest -> …`（nodes/boundaries 同上 + artifacts 非空
  正 bytes ≤ 上界）。
- `validate_import_map : T.checkpoint_import_map -> …`：rows 的 boundary/node/line/context 引用一致、
  validated_node_count = 实际行数。
- 「可信源快照 / file-target 输入比对 / alias 消费 / 兼容不明隔离分类」：`classify` 返回
  `[`Ok | `Incompatible of string | `Rejected of string]`，不抛异常。

### pet_checkpoint_arena.ml（材料与租约状态机）
- 状态：`upload spool`（transfer_id → {staging bytes; next_offset; expected digest/bytes; artifact_ref}）；
  `download spool`（transfer_id → {sealed bytes; offset; seq; hash; released}）；
  `import_arena`（cache_id → {staging manifests/requirements/bundle/map; phase = Preparing|Prepared|Activated}）。
- 上传（source 通道侧）：begin（核 transfer 与 budget：`T.checkpoint_input_budget` 给
  (metadata|bundle bytes, deadline)；artifact kind 与 method/phase 配对按 Rust `checkpoint_transfer`
  同表）→ chunk（offset 顺序、块 digest）→ finish（总量+SHA-256 ⇒ `BlobRegistered`，材料交 arena）。
- 下载（view 通道侧）：pull/ack/release 按 §2 同款块协议（credit 1..8192 字节，Base64 出块）；
  release（reason sealed/discarded + durable_record）⇒ 真实清理后 `BlobReleased`。

### pet_checkpoint_dispatch.ml
- `run_observe / run_export_collect / run_export_encode / run_import / run_activate`（本批 devlog 只要求
  import/activate 已接公共操作；observe/export 同骨架，未接真实材料处返回明确错误终态
  `T.make_checkpoint_error stage:CpValidate started:false`，不假成功）。
- `run_import`：blob 材料齐（plan/requirements/compatibility/manifest/bundle 均已 upload spool）⇒
  `Pet_checkpoint_graph.validate_*` 全过 ⇒ arena 阶段 Preparing→Prepared，登记私有恢复图
  （nodes/lines/context 映射按 `T.checkpoint_import_map.cim_rows`）⇒ `T.make_checkpoint_terminal
  (ImportedArtifact (args, mapping_artifact))`（make 于 types.mli `checkpoint_outcome`）。
  材料缺/校验败 ⇒ `T.make_checkpoint_error stage:CpDecode|CpValidate started:true`（错误终态也要
  extent!=UnknownTail——用 `make_checkpoint_error` 构造，Rust 端接受非 UnknownTail 错误）。
- `run_activate`：核 `args.activation`（permit：control/cache/import_receipt/instance/epochs/binding_revision
  匹配 arena 与导入终态）⇒ 图发布：把 arena 行的新 node/line/context 注册进 Registry 线表（幂等：
  已激活同 key ⇒ 原终态重放）⇒ `make_checkpoint_terminal (ActivatedArtifact (args, group_id))`
  （group 取导入终态的 group——Rust `activation_group`）。
- 预算：`checkpoint_request_binding` + `T.budget_for_checkpoint_entry`；`checkpoint_input_budget`/
  `checkpoint_output_budget` 核 transfer 配额；`checkpoint_pending_import` 支持导入预算槽。

## 4. item 4：pet_query.ml / pet_query_view.ml / pet_query_check.ml / pet_inspect.ml

### pet_query_view.ml（有限 FD spool，query/inspect/line_updates 共用骨架）
```ocaml
type spool（文件路径 + 总 bytes + digest + 游标/seq/hash/release 状态，Mutex）
val create : bytes:string -> view:T.Id.t -> operation:T.Id.t -> spool   (* 写 temp 文件后只读 *)
serve_pull / serve_ack / serve_release   (* §2 同款语义；credit 4..8192 UTF-8；parent 与子流各自独立 ACK/release *)
val output_budget_check : budget -> used_so_far -> new_bytes -> bool     (* 父子共享同一 budget.output_bytes 与 boot.view_quota *)
```

### pet_query_check.ml（NB07 首版白名单）
对 Fleche 解析出的 `Coq.Ast.t` 判定（不 eval）：
- 外层 control=[] ∧ attrs=[]（Coq.Ast.v 上的 vernac control/attrs 可达字段）。
- 允许：VernacSynPure(VernacCheckMayEval(_,None,term))、VernacGlobalCheck、VernacPrint(p ∈ 封闭
  printable 集)、VernacLocate(LocateAny/Term/Library/Module)、VernacSearch(q∈{Pattern/Rewrite/Search},
  restriction)、VernacSynterp(VernacSetOption(false, key∈4 项, OptionSetTrue|OptionUnset))。
- term 白名单递归（CRef/CFix/…/CNotation 允许但 notation 走「已登记解释模板纯化」无法本地证明 ⇒
  **CNotation/CPatNotation/by-notation 一律拒绝**，这是本批保守面，报 invalid_input；devlog 已声明
  Notations 依赖固定 Rocq 纯接口、本批不开放）。CGenarg* 拒绝。
- `classify : Coq.Ast.t list -> (plan, rejected) result`；空表 ⇒ 空计划。

### pet_query.ml
`run header binding node (source_id, start, stop) output_budget`：
1. 核 node/doc/源范围（bytes 落在 sealed source 内、字符边界）、budget。
2. 取 node 对应 doc（Registry），恢复父 state（Shell：doc 的该节点 state 即当前，直接
   `Fleche.Doc.run`-style 执行）；解析区间文本为 AST 列表（Shell.parse_span——用
   `Fleche.Doc.check` 到区间终点后取新区块 AST，或 `Coq.Parsing` 直接构建 parsable；以 fork 现有
   API 能力为准，禁止自写分句）。
3. `Pet_query_check.classify` 全过才执行；执行 = 对每个 AST 用原 token+临时 state 解释并捕获输出
   （`run_with_output`：包 `Fleche.Io.CallBack` 捕获 message 到 Buffer，受 output budget 上界；超限
   ⇒ 截断并 CaptureStatus reason=BudgetExhausted，complete=false）。
4. 结束恢复原 state/打印选项；产出 spool（pet_query_view）⇒ `T.make_query_view_terminal`
   （capture=make_capture_status…；extent=CompleteKnown；失败 ⇒ `T.make_query_error_terminal`
   stage=Parse|Execute|Register|Restore|View 之一，last_valid=Known parent，**失败也要挂原操作私有
   lease**——即失败路径同样登记 spool（已捕获前缀），view 可拉取；devlog：「失败查询的已捕获前缀」）。
5. 「不能把 view ID 冒受管 diagnostic 索引」：diagnostic fact 只用 FUnknown/FKnown(真实 id)；本批无
   真实受管诊断 ⇒ diagnostic=FUnknown。

### pet_inspect.ml（真实 Rocq 结构）
`run header binding node selector output_budget`，selector=`T.inspect_selector`：
- `Toc`：`doc.toc`（Shell.get_toc 已有）⇒ `T.make_toc_facts [(序号, 定位 fact, 名, 类型文本, range)]`
  （range 用 `T.make_byte_range`；offset 用 Fleche node range 的字节 offset——`Lang.Range` 提供）。
- `GoalPartSel (sel, part, range)`：node.state 的 `Coq.State.t` 取 proof goal（fork `coq/goals.ml`
  有 goal 提取 API——以实际 mli 为准）；按 sel(group,depth,index) 定位 goal；part=Conclusion|
  Hypothesis i；物化文本=Pp 打印 ⇒ `T.make_goal_part_facts`。
- `GoalRoster cursor`：五组（Focused/StackLeft/StackRight/Shelved/GivenUp）真实分组（goals.ml）；
  分页：每页完整组元数据 + 连续 1..total 子窗 + next cursor（中间页 Known(stream, after_seq)，末页
  N/A）；`T.make_native_goal_group`/`make_goal_roster_facts`（total=全量）。
- `Assumptions names`：`Coq.Printing`/`Assumptions` 官方接口按名逐 root：closed（无假设）⇒
  AsmClosed；有假设 ⇒ AsmAssumptions + items（kernel_name/printed_type 各自子 view）；不可用 ⇒
  AsmUnavailable。`T.make_assumption_root`/`make_assumptions_facts`；「父子共享 budget」= root 的
  raw/printed_type 子流与父文档共用 output budget（pet_query_view.output_budget_check）。
- `Environment`：消费显式可信 snapshot——本批无 M5 输入 ⇒ 明确错误终态（devlog：「Environment公共
  分支消费显式可信snapshot」未接 ⇒ 返回 invalid_input 拒绝，不留假数据）。
- `Notations`：同上，devlog 声明依赖固定 Rocq 纯接口 ⇒ 本批拒绝（invalid_input）。
- 产出 TypedFacts 视图：payload=`make_*_facts`；文档=`make_native_facts_document node source env
  capture payload`；spool=文档字节；终态 `T.make_inspect_view_terminal ~kind`。
- roster/assumptions 子流：父文档字节被完整 ACK 后（Rust 端 register_*_children 消费）允许按
  `NativePartDescriptor`（roster）或文档内 view ref（assumptions）开子 spool；本批 Pet 侧生成
  descriptor/ref 嵌进文档即可，子流拉取走 pet_query_view 通用 serve。

## 5. item 5：pet_scope_lifecycle.ml（N05）

状态：`scopes : scope_id -> {revision; status: Open|Closing|Closed; containers: 借用/引用集合;
history : (receipt_key, T.receipt) list（历史回执不可变）}`。
`Scope.cleanup_locked header binding scope expected_revision`：
1. 核 scope=binding.scope、revision=expected_rev、budget（task purpose）、`T.entry_uses_budget`。
2. 幂等：已有 Closing 回执未清 ⇒ 重放；已 Closed ⇒ `T.make_ended_closed` 原终态（历史回执不可变，
   重读返回原 receipt）。Rust 端：closing receipt seq 必须 1（首次）；重放同 receipt。
3. 枚举真实容器与借用（Registry：该 scope 名下 operations 的 pending/aux/未 release spool、线表、
   doc 引用）：**封新准入**（scope→Closing 后拒新执行：require_new_work 同款检查）；
   - 有未清借用（pending ACK/未 release view/blob）⇒ 先回 `T.make_ended_closing`（receipt seq=1，
     reclaim=FUnknown），后续 EndScope/Settle 重入检查；全部清空后 ⇒ `make_ended_closed`（新
     receipt seq=原 seq+1？——Rust `scope_receipt_phase` 允许 Closed receipt extent=CompleteKnown，
     且 progress 检查允许 seq 递增；closed 是独立 receipt）。
4. Closed 生成条件（「按真实结果发布」）：从 Registry 真实删除该 scope 的线/doc/操作引用（保留共享
   context 的他人引用与历史回执），reclaim fact = Known(新 reclaim id)。
5. 「外部登记和原退役决定由 U4 供给」「NativeReclaim 交付缺合同接缝」⇒ reclaim 观测细节（roots
   数组）本批不伪造：`make_ended_*` 的 reclaim 用 FUnknown/FKnown(id)（types 只收 fact，不展开
   roots——roots 在 NativeReclaim record，不在 receipt）。

## 6. dune / shell.mli / interp_shell 接线

dune（petanque/json_shell/dune）：
```lisp
(library (name pet_native_support)
 (modules pet_registry pet_environment_refresh pet_source_prefix pet_source_sync
          pet_checkpoint_graph pet_checkpoint_arena pet_checkpoint_dispatch
          pet_query_check pet_query_view pet_query pet_inspect pet_scope_lifecycle)
 (libraries petanque_shell ccv_protocol threads.posix))
```
executable pet_native libraries 追加 pet_native_support。petanque_shell 本身不加 ccv_protocol。
shell.mli 追加：restore_sentence/snapshot_doc、step_doc 新结果形状（Interrupted 分支）、
env_snapshot/install_env/readback_env、parse/查询辅助（如 make_doc 已有）。interp_shell.ml 只随
shell.mli 形状变化做最小适配（Target 等已兼容）。

## 7. 每项验收

每 item：dune 全量构建通过（§0 命令）+ `git diff --check` 干净 + 中文 commit（`ccv:` 前缀）+ push。
不确定/未接线的真实行为按 devlog 口径明确「拒绝或未知」，测试红点记录不掩盖。
