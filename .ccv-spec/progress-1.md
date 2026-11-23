# item 1 进度（接线基础 + pet_environment_refresh）

## 块 A —— 已完成并 commit（5d2ff06）
- pet_registry.ml（spec §1 签名；budgets 存 T.native_budget，budget_equal 幂等/冲突；
  /proc/uptime 单调 µs 时钟，读失败退回墙钟+单调下界）。
- dune：新库 pet_native_support（pet_registry + pet_environment_refresh 占位）；
  pet_native.exe 追加该库；petanque_shell 未加 ccv_protocol。
- pet_native.ml：make_status 补 ~retired_through / error_terminal 补 ~group /
  make_ack 补 ~group；receipt_key_equal/ack_proof_receipt 漂移修复；
  native_request_view 18 构造器穷尽分派；RetireThrough 退役水位；
  RegisterBudget 幂等/BindingConflict；BeginLine 对已退役序号回 past_unavailable。

## 块 B（B0 修正）—— 已完成并随块 A commit
- now_us 改读 /proc/uptime（与 Rust CLOCK_MONOTONIC 同域：boot 起算秒×1e6），
  仅读取失败才退回墙钟+单调下界（注释注明域不一致风险）。

## 块 C —— 本轮完成（未 commit）
- C1 控制通道 serve 线程（fd5）：ReadControl 按 id 查 op ⇒ control_snapshot
  （phase：Executing=Active、terminal/aux=TerminalPhase、否则 Idle；Settling 留块 E）；
  未知 op ⇒ control_unknown_operation。RequestCancel：seq>已见 ⇒ Token.set(原子
  token)+stop_requested ⇒ ReceivedAck；等值 ⇒ 幂等重放原 ACK（存 last_cancel_ack）；
  更小 ⇒ PastCancel（不存储）；已终态 ⇒ AlreadyTerminal。generation 初次 1，
  恢复成功后 +1（块 E）。
- C2 Registry.operation 扩字段：cancel_seq_seen / cancel_generation / stop_requested /
  token / interrupt_snapshot / last_cancel_ack（后两者块 E 消费）。
- C3 source 通道 method 分派：帧先 S.decode 取 "method"；source_* 走原 source_handle；
  checkpoint_blob_begin/chunk/finish ⇒ 通道内 checkpoint_blob_error
  invalid_input/not_admitted（编码用 encode_checkpoint_blob_reply）；未知 method 尽力
  回显 header 回错，拿不到可回显 header 则丢帧（不伪造 header），进程不崩。
- C4 view 通道 serve 线程（fd7）：view_pull/ack/release 与 checkpoint_blob_pull/ack/
  release 分派；本 item 无已登记 view/blob ⇒ unknown_operation/not_admitted 回错
  （make_view_*_error / checkpoint_blob_error）。
- 附带：pull 改用 Coq.Limits.create_atomic 原子 token 并入 op.token 账本；
  op.state 在 eval 期间置 Executing（供控制 phase）；取消真实到达但块 E 未接时
  pull 不再 fail，按「已尝试未知」口径回 status（Ready、无终态）。

## 块 D —— 已完成（未 commit；收尾轮复核构建零错误）
- 状态：D1-D4 全部落盘；spec §0 命令（pet_native.exe + @runtest）退出 0、无输出；
  过程中的两处编译错误已修——make_aux_operation 补 `: Registry.operation`
  标注（Unbound record field binding）；fork 线表 group 存裸 int64、
  make_fork_terminal 终态另用 `(exploration, uint group_rev)`（T.Id.t * T.U.t）。
- D1 Registry 线表：lines : (string, {revision; frontier; group:(Id*int64) option;
  kind: Mainline|Exploration})；register/find/iter；BeginLine 登记主线
  （revision=expected_revision、frontier=root-<line>）；pull 成功步进同步 frontier；
  Ack 后同步线 revision；另加 find_operation_by_id（控制通道用）。
- D2 LocateContextRequest 内联最小真实：locate_fields 解包；admit_new 准入
  （seq=highest_seen+1、未退役、entry_uses_budget 全匹配——step_reply 增传原请求）；
  单实例单 context 取第一条 Mainline 线及其 op；expected_context/lineage 版本可核
  不符 ⇒ StaleRevision；Root ⇒ LocatedRoot；Theorem ⇒ doc.toc 命中 ⇒
  LocatedBoundary(make_entry_boundary，node=账本 node-<line>-<i+1>，区间用节点
  range 字节)，未命中 ⇒ PrefixRequired；Position ⇒ 覆盖该位置且已执行节点 ⇒
  LocatedBoundary，否则 PrefixRequired；End ⇒ completed=Yes ⇒ 末节点 boundary
  （空 doc ⇒ LocatedRoot），否则 PrefixRequired；无 doc 先按 sealed source 建（不执行）；
  线/doc 均无 ⇒ invalid_input。幂等：aux 已存 ⇒ locator_reply 重放。
- D3 ForkLineRequest：父线存在、revision=expected_rev、frontier=parent 节点三项可核；
  新线 frontier=父前沿、group=(exploration, 父组rev+1 或 1)、kind=Exploration；
  make_fork_terminal(node=父前沿, revision=父 rev)；同 binding 幂等重放 aux。
- D4 SelectLineRequest：仅「重选当前前沿」（destination 线存在、revision 匹配、
  candidate=frontier）账本可核 ⇒ revision+1、组版本+1 ⇒ make_selected_group/
  make_selected_entry（回 terminal_reply）；其它情况 invalid_input（spec「不谎称」）。

## 构建结论（块 C+D 时点；最终见文末）
- spec §0 命令（三段 OCAMLPATH：.ccv-findlib + rocq90 + rmcp10-preflight）：
  pet_native.exe + @petanque/json_shell/runtest 退出 0、无输出；git diff --check 干净。

## 块 E —— 已完成（未 commit；构建零错误）
- shell.ml/shell.mli：step_doc 结果加 `` `Interrupted of [`Parse|`Execute] ``
  （判据 = check 后 token is_set 且无新执行节点/错误诊断；parse/execute 用
  「EOF 分支遗留空节点 ⇒ Parse，否则 Execute」区分，无法区分时保守归 Execute）。
  快照经 Shell.snapshot_doc（共享不可变 doc 纯记录），未改 step_doc 参数形状。
- 新增 Shell.snapshot_doc / restore_sentence ~token ~snapshot ~cursor（新 token +
  stop_before 命中 cursor 起始句 ⇒ 停在中断句之前）/ env_snapshot / install_env
  （清 documents）/ readback_env；shell.mli 全部暴露。interp_shell 无 step_doc
  调用，无需适配。
- pet_native SettleInterruptRequest：无在途中断 ⇒ invalid_state；已终态 ⇒
  invalid_state；恢复期限过（无预算可核也按过期）⇒ make_retiring_status 不改
  账本；期限内 ⇒ 新原子 token + Shell.restore_sentence（在 with_tables 内执行，
  锁序单一无死锁）：成功（completed 非 Failed）⇒ generation+1、stop_requested=
  false、snapshot/token 清、state=Ready、make_interrupted_terminal
  （stopped/synchronized/recoverable=FKnown true、last_acked=FKnown parent、
  pending=FNotApplicable、diagnostic=FUnknown、extent=CompleteKnown）⇒
  terminal_reply；恢复抛异常或落 Failed ⇒ 不发终态、state=Retiring 回 Retiring。
- pull：步前 Shell.snapshot_doc 存快照；`Interrupted _` ⇒ interrupt_snapshot=快照、
  state=Retiring、回 make_retiring_status（删除原 `Unknown when is_set` 与 fail
  路径）；中断步不消耗 seq。控制 phase 补 Settling（state=Retiring ⇒ Settling）。

## 块 F —— 已完成（未 commit；构建零错误）
- pet_environment_refresh.ml 实装（自持 Mutex，锁序：模块锁→Registry 锁，
  pet_native 路由不持 Registry 锁调用）：current_env 初始身份从首个任务预算解析
  （Registry.any_budget_environment，无 boot.environment 访问器）；refreshing
  记账；同 binding 幂等重放原 aux；异 binding 在途 ⇒ BindingConflict；
  old_env ≠ current ⇒ invalid_input；同环境 no-op ⇒ changed=false +
  reclaim=FNotApplicable（保热不重建）；变更 ⇒ 旧环境未决 pending 步 ⇒ Retiring；
  否则 env_snapshot ⇒ Coq.Files.make()+Env.make(原 init/workspace) ⇒ install_env ⇒
  readback 物理同一（==）⇒ 同临界区发布（current:=new、refreshing 清、
  changed=true + reclaim=FKnown "reclaim-<old>"）。两条失败路径严格区分：
  install 之前失败 ⇒ 拒绝口径可重试；install 后 readback 失败 ⇒ in_progress
  卡 Retiring 绝不回成功（注释写明）。
- pet_native RefreshEnvironmentRequest 路由：admit_new 准入 + 登记 aux op（锁外
  调 Refresh.refresh）；FinishOperationRequest 扩 aux 终态（key=
  locator_terminal_key）。
- 修复：pet_environment_refresh.ml 内 Shell 绑定（module Shell =
  Petanque_shell.Shell）；SettleInterrupt 分支补 with_tables 收尾括号。

## 构建结论（块 C-F 累计）
- spec §0 命令（三段 OCAMLPATH；pipefail 核退出码）：pet_native.exe +
  @petanque/json_shell/runtest 退出 0、无输出；git diff --check 干净；
  pet_native.exe 产物 45.9MB（12:24）。

## item 1 全部块（A-F）完成；未 commit，待主代理审。

## 已知偏差 / 卡点
- 本 switch OCaml 4.14.2 unix 无 clock_gettime（已实测），now_us 用 /proc/uptime
  同域替代；仅 Linux 可用，读失败退墙钟（域不一致，注释已声明）。
- entry_uses_budget 需要原始 native_request：已把 raw request 传入 step_reply；
  BeginLine 维持基线检查（existence）+ 退役/序号检查，未升级为 entry_uses_budget
  全量核对（基线行为保持，后续 item 视需要统一）。
