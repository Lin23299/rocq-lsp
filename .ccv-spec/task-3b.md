# 任务：item 3 续——pet_checkpoint_arena.ml + pet_checkpoint_dispatch.ml + 接线

背景：pet_checkpoint_graph.ml 已完成（196 行：validate_requirements / validate_manifest ~max_bytes / validate_import_map，(unit,string) result）。你完成剩下的。控制读量：只读下面列的，别整读 types.ml。

读：
1. .ccv-spec/spec.md §3
2. .ccv-spec/refs/protocol/types.mli 130-165 行（artifact_kind/transfer/blob_request_view）、398-425 行（args_checkpoint_* / activation_permit / checkpoint_request_view）、478-536 行（预算辅助 + checkpoint_outcome + make_checkpoint_terminal/error）
3. .ccv-spec/refs/native/checkpoint.rs 的 checkpoint_transfer 函数（294-327 行）与 validate_checkpoint_terminal（406-452 行）
4. petanque/json_shell/pet_checkpoint_graph.ml（接口）、pet_registry.ml（operation/lines）、pet_native.ml 的 base64_decode 附近与 source_loop/view_loop 的 blob 分派现状、step_reply 的 CheckpointRequest 分支现状

交付：
A. pet_checkpoint_arena.ml（自持 Mutex）：
   - 上传 spool：transfer id → {mutable staging: bytes；next_offset；expected digest/bytes；artifact_ref}。begin/chunk/finish 迁移（chunk 顺序 offset+digest；finish 总量+SHA-256(S.sha256) ⇒ 封存材料 bytes 按 artifact_id 入 materials 表）。
   - 下载 spool：transfer id → {sealed bytes；mutable offset/seq；released}（pull/ack/release 迁移逻辑薄，判断归 dispatch）。
   - import arena：cache id → {mutable 材料集（artifact_id→bytes）；mutable phase=Preparing|Prepared|Activated；group: Id.t option；import_binding: op_binding option}。register_import_material/prepare（plan+manifest+bundle+compatibility 齐 ⇒ T.decode_checkpoint_requirements 等解回 + Graph.validate_* ⇒ Prepared）/take_for_activation。
B. pet_checkpoint_dispatch.ml：
   - init ~boot（存 boot 给 budget_for_checkpoint_entry）。
   - serve_upload / serve_download / serve_release：按 blob_request_view 分支处理（配对矩阵照 checkpoint.rs checkpoint_transfer：上传=Source 通道 begin/chunk/finish + artifact kind ∈ (method,phase) 允许集；下载=View 通道 pull/ack/release）。块 ≤8192；Base64 编码自写（标准字母表精确 padding，pet_native 有 decode 可对称）。回复 T.checkpoint_blob_result。transfer 的 operation/attempt/control 与预算（T.checkpoint_input_budget/output_budget 给 (bytes 上界,deadline)）核对。已完整同身份 begin ⇒ BlobRegistered 幂等。pull 出块 BlobChunkOut（end=到总量）；ack 核对后 BlobAcked；release 真实清理后 BlobReleased。
   - run_request ~header ~request_view（CheckpointRequest 五分支）：observe/export_collect/export_encode ⇒ make_checkpoint_error（CpValidate/CpCollect, started:false）存 aux；import ⇒ 材料齐 ⇒ arena.prepare ⇒ make_checkpoint_terminal (ImportedArtifact (args, mapping))（mapping：CkMap artifact_ref，id=map-<cache id>-<operation id>，digest/bytes 取 manifest 同值——注释声明本批由 manifest 派生，真实 map 后续 owner 输入；group 记账 arena）；缺/校验败 ⇒ make_checkpoint_error (CpDecode/CpValidate, started:true)。activate ⇒ activation permit 与 arena 核对（cache=Prepared、permit.import_operation=导入终态 operation、import_receipt_key=ca_import_receipt、instance/epochs 与 header 一致、binding_revision>0）⇒ phase=Activated ⇒ make_checkpoint_terminal (ActivatedArtifact (args, group))（group 取 arena 记的导入 group）；不符 ⇒ make_checkpoint_error (CpActivate, started:true)。幂等：同 binding 已有 aux 重放。预算核：T.budget_for_checkpoint_entry boot budget + T.checkpoint_budget_binding 与 args 的 control/attempt。
C. pet_native.ml：CheckpointRequest 分支接 Dispatch.run_request（admit_new + make_aux_operation，注意 checkpoint 操作的 aux 用 make_aux_operation 以 binding.context 建）；source_loop 的 blob_* 分派改 Dispatch.serve_upload；view_loop 的 blob_* 改 serve_download/serve_release（pull/ack 归下载，release 也走 view）。Pet_checkpoint_dispatch.init ~boot 在 serve()。dune modules 追加 pet_checkpoint_arena pet_checkpoint_dispatch（graph 已加）。
D. 构建零错误（命令：env -i HOME=/home/ubuntu PATH=/home/ubuntu/.opam/rocq90/bin:/usr/local/bin:/usr/bin:/bin OCAMLPATH=/home/ubuntu/tools/rocq-lsp-nativeface-u3/.ccv-findlib:/home/ubuntu/.opam/rocq90/lib:/home/ubuntu/.opam/rmcp10-preflight/lib /home/ubuntu/.opam/rmcp10-preflight/bin/dune build --root /home/ubuntu/tools/rocq-lsp-nativeface-u3 --profile release -j1 petanque/json_shell/pet_native.exe）；progress-3.md；不 commit。注释中文，不伪造。
