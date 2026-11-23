# item 3 进度（pet_checkpoint_graph.ml（既有）+ pet_checkpoint_arena.ml + pet_checkpoint_dispatch.ml + 接线）

## 交付 0 —— pet_checkpoint_graph.ml（此前已落盘，196 行，本 item 未改）
- validate_requirements / validate_manifest ~max_bytes / validate_import_map，
  (unit, string) result，不抛异常。

## 交付 A —— pet_checkpoint_arena.ml（材料与租约状态机，已落盘）
- 状态（自持 Mutex，锁序：本模块锁 → Registry 锁）：
  - 上传 spool：transfer id（=artifact id）→ {staging bytes; next_offset;
    expected digest/bytes; begin 时完整 transfer 身份}；
  - 材料表：artifact_id → {bytes; artifact_ref}（ref 供 begin 幂等核对身份）；
  - 下载 spool：transfer id → {artifact; operation; sealed; offset/seq 游标;
    pending 块; released}（sealed="" + released=true = 真实清理，后续 pull 报 Retired）；
  - import arena：cache id → {材料集 artifact_id→封存字节; phase=
    Preparing|Prepared|Activated; group; import_binding}。
- 上传迁移：begin（已完整同身份封存 ⇒ `Registered 幂等；同身份在途 ⇒ `Begun
  当前 next_offset 续传；异身份 ⇒ `Rejected；新开须过 cap + Registry.reserve_input）；
  chunk（operation 与 begin 一致、offset=next_offset、块 1..8192 不越界 ⇒ blit 推进，
  返回 (offset, end, 块 sha256)）；finish（总量齐 + 全文 SHA-256 ⇒ 按 artifact_id
  封存；digest 不符 ⇒ 弃暂存并 release_input，可重试）。
- 下载迁移：open_download（导入终态发布时开立）；pull（credit 1..8192、
  seq=last_ack+1 或重放 pending、offset=已确认偏移；二进制材料不做 UTF-8 截断；
  end=到总量）；ack（核 pending seq/end/块 digest ⇒ 推进；旧 seq ⇒ Retired）；
  release（真实清理，幂等 `Released）。
- import：register_import_material（全局封存表 → cache 材料集，仅 Preparing 收料）；
  prepare_validated + prepare_import（Result 单子扁平链：manifest/requirements
  反序列化 + Graph 三项校验 + 派生 import map（cim_rows=[]、
  validated_node_count=0）+ encode ⇒ phase=Prepared、group/import_binding 记账，
  返回 (map 字节, mapping ref)）；take_for_activation（仅 Prepared）；
  mark_activated。
- 本批口径（不伪造）：mapping 的 digest/bytes 取 manifest 同值、id=
  map-<cache>-<operation>——由 manifest 派生，真实 map 由后续 owner 输入；
  上传材料封存后无 release 通道，输入配额保持占用（材料仍在内存，与 source
  封存同口径）。

## 交付 B —— pet_checkpoint_dispatch.ml（公共入口分发，已落盘）
- init ~boot（serve() 注入；boot_ref 供 budget_for_checkpoint_entry/
  boot_input_quota/boot_view_quota/epoch 核对）。
- Base64 自解自编（标准字母表精确 padding，与 pet_native 的 decode 对称）。
- serve_upload（source 通道 begin/chunk/finish）：配对矩阵与预算核对 =
  Registry.iter_budgets（本 item 新增，须在 with_tables 内）逐预算过
  T.checkpoint_input_budget——其内部守卫即 checkpoint.rs checkpoint_transfer 的
  Source 侧同表（operation/seq/control/attempt + transfer id=artifact id + kind
  允许集），返回 (metadata 上界, bundle 上界)（注意：types.ml 实现返回两个
  bytes 上界，不是 (bytes, deadline)；期限另走 Registry.deadline_expired
  `Execution）；artifact bytes ≤ boot_input_quota 否则 Capacity；
  operation_seq=0 拒绝。回复 BlobBegun/BlobRegistered（幂等）/BlobChunkAck/
  BlobRegistered；块 ≤8192。
- serve_download（view 通道 pull/ack）：T.checkpoint_output_budget 同款反查 +
  `Output 期限 + view 配额；pull 出块 BlobChunkOut（end=到总量）；ack 核对后
  BlobAcked；Absent ⇒ unknown_operation。
- serve_release（view 通道）：BlobReleased（ReleasedStatus）；release 帧不带
  完整 transfer，配对以 spool 记账 operation 为准（驱动侧已核预算矩阵）；
  reason/durable_record 不用于推导块 ACK（Rust 同口径）。
- run_request ~request ~header ~view（CheckpointRequest 五分支）：
  - 公共：header_matches_boot 核对；幂等（同 binding 已有 aux ⇒ locator_reply
    原样重放；无 aux 的在途 ⇒ BindingConflict ExistingOperation）；admit（past_
    unavailable/SequenceGap/预算登记/entry_uses_budget/budget_for_checkpoint_
    entry）+ highest_seen 推进 + make_aux_operation（line=binding.context）；
    checkpoint_budget_binding 的 (control, attempt, …) 与 args 的 control/attempt
    显式核对（activate 的 permit 无 attempt，同 entry_uses_budget 只核 control）。
  - observe/export_encode ⇒ make_checkpoint_error (CpValidate, started:false)
    存 aux；export_collect ⇒ CpCollect started:false（observe/export 本批未接
    真实材料，明确错误终态，不假成功）。
  - import：register ×4（plan/manifest/bundle/compatibility）——Conflict ⇒
    BindingConflict；Missing ⇒ CpDecode started:true；prepare ⇒ Missing/Decode ⇒
    CpDecode、Validate ⇒ CpValidate（均 started:true）；Prepared ⇒ 先
    Arena.open_download（mapping, 导入 op, map 字节）再 make_checkpoint_terminal
    (ImportedArtifact (args, mapping))；私有恢复图登记按 cim_rows（本批行留空，
    无可登记项）。
  - activate：核对（cache=Prepared（take_for_activation）、permit.import_
    operation=导入终态 operation、locator_terminal_key(导入 aux)=permit.import_
    receipt_key=args.ca_import_receipt、导入 op 序号 < activate 序号、arena 的
    import_binding=导入 op binding、permit instance/epochs=boot（header 已核
    =boot）、binding_revision>0）⇒ mark_activated ⇒ ActivatedArtifact
    (args, arena 记的导入 group)；任一不符 ⇒ CpActivate started:true。
- 环境占用/隔离（require_new_work/quarantine）是驱动侧状态，Pet 侧无从核对，
  不伪造（模块头注声明）。

## 交付 C —— pet_native.ml 接线 + dune
- module Checkpoint_dispatch 别名；serve() 在 Sync.init 后 Checkpoint_dispatch.
  init ~boot。
- source_loop：checkpoint_blob_begin/chunk/finish → serve_upload（解码失败
  尽力回显 header 回错，拿不到则丢帧，不伪造）。
- view_loop：checkpoint_blob_pull/ack → serve_download；checkpoint_blob_release
  → serve_release（同分支按 view 构造分派）。
- step_reply CheckpointRequest → Dispatch.run_request ~request ~header ~view。
- dune：pet_native_support modules 追加 pet_checkpoint_arena
  pet_checkpoint_dispatch；petanque_shell 排除列表同步追加。
- pet_registry.ml：新增 iter_budgets（须在 with_tables 内；transfer 不带
  budget id，只能按配对矩阵逐预算反查）。

## 交付 D —— 构建
- task-3b.md 原文命令（--profile release -j1 pet_native.exe）零错误零警告；
  spec §0 全量命令（含 @petanque/json_shell/runtest）零错误。
- git diff --check 干净；未 commit。

## 已知接缝（诚实记录，不掩盖）
- mapping artifact 的 digest/bytes 声明取 manifest 同值（task 指定），而下载
  spool 服务的是派生 import map 字节——两者哈希不对齐；真实 map 由后续 owner
  输入后才会对齐（导入映射行本批留空）。
- observe/export 三个分支为明确错误终态骨架，无真实制品产出。
- 上传材料无 release/退役通道（spec §3 上传侧本批未定义 release），内存与
  输入配额占用随材料存活；EndScope 侧清理由 item 5 处理。
