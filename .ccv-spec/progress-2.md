# item 2 进度（pet_source_prefix.ml + pet_source_sync.ml，NN03 源码同步）

## 交付 1 —— pet_source_prefix.ml（纯逻辑，已落盘）
- lcp：字节 LCP，结果回退到 UTF-8 字符边界（落不进边界即回退，字节 0 恒为边界）。
- retain：new==old ⇒ 原样返回 old_doc（changed=false）；否则 bump_version(+1) 后
  check 到 LCP 位置的 Position 目标（内部换算 行/UTF-16 列；跨 LCP 句子会被执行
  但其节点不保留；恰在 LCP 起始的句子不执行——Fleche reached 语义），保留前缀 =
  新 doc 中 end≤LCP、无 error diag、ast 非空的连续前驱链；prefix_end=最后保留
  节点 end offset，无保留节点=0。IO 回调静默（不发诊断/进度）。
- horizon_of：read_end=下一未验证节点（end 越过 verified 的首个节点）起点，
  无 ⇒ 最后节点 end（无节点 ⇒ verified）；saw_eof=completed Yes。
- 内部 prefix_chain 记录带 last_node（原行内 record 字面量未声明类型导致
  last_node unbound，已修）。

## 交付 2 —— pet_source_sync.ml（已落盘）
- 状态：contexts : context_id -> {revision; sync_in_progress}（首次见到以主线线
  版本播种）；spools : view_id -> spool（view/operation/digest/bytes/path +
  offset/seq/pending/released 游标）。自持 Mutex，锁序 模块锁→Registry 锁。
- init ~boot：serve() 注入 native_boot_binding（make_native_line_update_document
  与 boot_view_quota 用）。
- prepare_locked 六步：
  1) 核验（Registry 锁内只读）：context 存在（单 context 近似：第一条 Mainline 线 +
     其上最早登记操作=BeginLine 主线 doc/source 持有者，多 context 留后续）、
     binding.context=context、expected_ctx.id=context（Rust state_operation_head 同款）、
     revision=expected_rev、旧 source=登记 id、新 source 已 sealed、
     budget.output_bytes>0（entry_uses_budget 在路由 admit_new 核）；
  2) 幂等：同 binding 已有 aux ⇒ locator_reply 原样重放；
  3) 拒绝与新试区分：前置不符 ⇒ make_protocol_error invalid_input/StaleRevision
     not_admitted；异 binding 在途 sync ⇒ BindingConflict；
  4) 同内容 no-op：不重建 doc，完整未变线表（每线 before=after、Open、frontier
     原值），revision 不变，boundary=FNotApplicable；
  5) 变化：Prefix.retain 求 LCP/新 doc；线表逐线——frontier ∈ 保留前缀 id 集
     （node-<line>-1..kept + root-<line>，与 pet_native 账本 id 同方案）⇒
     before=after；否则 Retiring、frontier 保留原值、版本 +1；context revision+1；
  6) line_updates 封存：make_native_line_change ×N（按 line ID 排序，Registry
     iter_lines 投影）→ make_native_line_update_document（boot 注入）→ encode →
     Filename.temp_file "ccv_line_updates" 写 spool；总量 >0 且 ≤ budget.output_bytes
     且 ≤ boot_view_quota 否则 Capacity 拒绝；view id=view-<op id>-<op seq>，
     digest=sha256 全文。
- 原子发布：三段式——核验(Registry 锁,只读) → 材料构建(仅模块锁,不含 Fleche 执行
  的 Registry 锁) → 发布(Registry 锁内：漂移复验[线版本/前沿/未决/终态] 全过才
  变更——回收线 revision+1、doc 替换为 retain 结果、主线前沿失效时回卷 op
  cursor/parent 到保留前缀[frontier 原值留线表]、ctx revision/sync_in_progress、
  spool 登记同一临界区)。漂移或构建失败 ⇒ unlink 弃材料，context 不动
  （GraphTxn 口径；漂移回 Retiring 续调）。
- RETIRING：context 有 pending/Executing ⇒ sync_in_progress 记 binding、
  op.state=Retiring、make_retiring_status，不发终态（no-op 路径同样遵守）。
- make_source_synced_terminal：revision=新(变化)/原(no-op)；last_valid=FKnown
  主线前沿；reclaim=FKnown "reclaim-sync-<op id>"；boundary=no-op N/A、变化且
  kept>0 ⇒ FKnown(make_entry_boundary, node=node-<line>-kept, 区间=最后保留节点
  字节 offset, target=new_source)否则 FUnknown；view/digest/bytes 用 spool ref；
  extent 由构造器内定（CompleteKnown）。

## 交付 3 —— view 通道服务
- serve_view_pull/ack/release：None ⇒ 未接管（路由回落后续模块→本 item 后仍
  unknown_operation 回错）；operation 不匹配 ⇒ invalid_input。
- pull：credit 4..8192；seq≤last_ack ⇒ make_view_pull_retired；seq=last_ack+1
  （重放 pending 同块）或新块 [offset, offset+credit)∩bytes 的最大完整 UTF-8
  前缀；eof=到达 bytes；capture=complete/总 bytes/FKnown digest/missing=[]/
  N/A（逐项对 line_updates.rs checked_line_update_pull）。
- ack：核 pending seq/end_offset/块文本 SHA-256 ⇒ make_view_acked 推进游标；
  旧 seq ⇒ make_view_ack_retired。
- release：核 last_acked fact（Known=spool.seq / N/A=从未确认）；pending 未清 ⇒
  Closing（spool 保留）；否则真实 unlink 后 Released（条目保留 released 标记，
  重放幂等，此后 pull/ack 回 retired）。

## 交付 4 —— pet_native.ml 接线 + dune
- SyncSourceRequest 解包修正：7 元组 = (header, binding, context,
  (expected_ctx_id, expected_rev), old_source, new_source, publication)——
  mli/types.ml 证实第 4 位是 expected_context 版本对（原按 task 文字误当
  (old_source, expected_rev)，已对齐）。路由：admit_new 准入 + 登记 aux op 后
  （不持 Registry 锁）调 prepare_locked。
- view_loop：view_pull/ack/release 先路由 Pet_source_sync（None 回落
  unknown_operation/not_admitted 现状）；checkpoint_blob_* 分支维持占位。
- serve()：Sync.init ~boot。
- dune：pet_native_support modules 追加 pet_source_prefix、pet_source_sync
  （并从 petanque_shell 的 :standard 排除，解决双 stanza 冲突）。

## 构建结论
- task-2.md 命令（三段 OCAMLPATH，rmcp10-preflight dune，-j1 release）：
  pet_native.exe 退出 0、无输出；追加 @petanque/json_shell/runtest 退出 0；
  git diff --check 干净；pet_native.exe 45.9MB（12:58）。未 commit（按指示）。

## 过程中的编译修复（纪要）
- pet_source_sync 注释内 ASCII "(Retiring,*)" 的 `*)` 序列提前终止 OCaml 注释
  （真正的语法错误根因；全角括号本身无害）；已改写该注释，并按要求把全文件
  全角（）/，清扫为 ASCII。
- Filename.temp_file 需前后缀两参；min/int64 混算改 Int64.sub；
  find_spool 返回 `` `Absent/`Mismatch/`Owned ``（勿与 option 的 None 混用）；
  read_spool_text/capture_of 补 (spool : spool) 注解——materials 与 spool 都有
  view/path 字段，字段消歧取最后声明类型会误选 materials；
  prepare_locked 步骤 4 分支少一层闭括号。

## 已知边界 / 口径
- 单 context 近似：context 载体=第一条 Mainline 线 + BeginLine 操作；context
  revision 首见时以主线线版本播种，此后由本模块持有（多 context 留待后续 item）。
- 变化路径若主线前沿被回收：线表按 Retiring 报原前沿（Rust valid_line_versions
  允许），主线 op 的 cursor/parent 回卷到保留前缀保持 doc/账本一致；后续在该
  context 上的新同步因线版本 +1 会 StaleRevision（封新准入口径）。
- no-op 同样受 RETIRING 前置约束（spec 步骤 7 无豁免；驱动 (Retiring,*) 分支
  排空 pending 后同 binding 续调即发布）。
- 保留前缀判定依赖 Fleche 对相同前缀字节的确定性重析（bump_version 公共前缀
  缓存 + check 真实节点），不猜句界。
