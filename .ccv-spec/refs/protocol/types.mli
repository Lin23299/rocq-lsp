(* 显式类型片段：Hello/Ack结构；不把结构可解码当作RC06握手已通过。 *)
module Id : sig
  type t
  val make : string -> (t, Strict_json.fault) result
  val get : t -> string
end
module U : sig
  type t
  val make : int64 -> (t, Strict_json.fault) result
  val get : t -> int64
end
module Text : sig
  type t
  val make : string -> (t, Strict_json.fault) result
  val get : t -> string
end
module Digest : sig
  type t
  val make : string -> (t, Strict_json.fault) result
  val get : t -> string
end
type channel = Ordinary | Control | Source | View
type limits_backend = Control_interrupt | Memprof_limits
type header
type compatibility
type hello
type hello_ack
type peer = Hello of hello | Ack of hello_ack
val header : instance:Id.t -> backend_epoch:U.t -> manager_epoch:U.t -> rpc_seq:U.t -> header
val compatibility : major:U.t -> digest:Digest.t -> capabilities:Text.t list -> (compatibility, Strict_json.fault) result
val compatibility_for_send : major:U.t -> digest:Digest.t -> capabilities:Text.t list -> (compatibility, Strict_json.fault) result
val hello : header:header -> channel:channel -> nonce:Id.t -> compatibility:compatibility -> expected_artifact:Id.t -> hello
val hello_ack : header:header -> channel:channel -> nonce:Id.t -> compatibility:compatibility -> artifact:Id.t -> rocq_version:Text.t -> ocaml_version:Text.t -> limits_backend:limits_backend -> hello_ack
val decode_peer : Strict_json.limits -> string -> (peer, Strict_json.fault) result
val peer_of_json : Strict_json.value -> (peer, Strict_json.fault) result
val peer_to_json : peer -> (Strict_json.value, Strict_json.fault) result
val encode_peer : Strict_json.limits -> peer -> (string, Strict_json.fault) result
val check_unique : compatibility -> (unit, Strict_json.fault) result
type expected_peer
val expected_native : header:header -> channel:channel -> nonce:Id.t -> artifact:Id.t -> (expected_peer, Strict_json.fault) result
val expected_driver : header:header -> channel:channel -> nonce:Id.t -> artifact:Id.t -> rocq_version:Text.t -> ocaml_version:Text.t -> limits_backend:limits_backend -> (expected_peer, Strict_json.fault) result
val check_hello : expected_peer -> peer -> (unit, Strict_json.fault) result

(* U3 nativeface 启动/握手只读投影；不暴露可变状态或 wire 构造旁路。 *)
val hello_header : hello -> header
val hello_channel : hello -> channel
val hello_nonce : hello -> Id.t
val hello_compatibility : hello -> compatibility
val hello_expected_artifact : hello -> Id.t

(* T2a：原生普通+控制消息面（rmcp-7 §3 / rmcp-8 §3）。类型抽象；只暴露typed入口，
   method↔args配对与方法-结果矩阵归消费者，不在此重造。 *)
type native_request
type control_request
type native_reply
type control_reply
type capture_status
val decode_native_request : Strict_json.limits -> string -> (native_request, Strict_json.fault) result
val encode_native_request : Strict_json.limits -> native_request -> (string, Strict_json.fault) result
val decode_control_request : Strict_json.limits -> string -> (control_request, Strict_json.fault) result
val encode_control_request : Strict_json.limits -> control_request -> (string, Strict_json.fault) result
val decode_native_reply : Strict_json.limits -> string -> (native_reply, Strict_json.fault) result
val encode_native_reply : Strict_json.limits -> native_reply -> (string, Strict_json.fault) result
val decode_control_reply : Strict_json.limits -> string -> (control_reply, Strict_json.fault) result
val encode_control_reply : Strict_json.limits -> control_reply -> (string, Strict_json.fault) result
type control_request_view = ReadControl of Id.t | RequestCancel of Id.t * U.t * U.t
val control_request_view : control_request -> header * control_request_view
type control_phase = Idle | Active | Settling | TerminalPhase
type control_snapshot
type cancel_ack_status = ReceivedAck | AlreadyTerminal | PastCancel | Stale
val make_control_snapshot : operation_id:Id.t -> phase:control_phase -> token_generation:U.t ->
  highest_cancel_seq:U.t -> stop_requested:bool -> control_snapshot
val control_snapshot : header -> control_snapshot -> control_reply
val control_unknown_operation : header -> Id.t -> control_reply
val control_cancel_ack : header -> cancel_ack_status -> control_snapshot -> control_reply
val decode_capture_status : Strict_json.limits -> string -> (capture_status, Strict_json.fault) result
val encode_capture_status : Strict_json.limits -> capture_status -> (string, Strict_json.fault) result
(* RC04 ccv-native-operation-v1域：返回64个小写hex字符。 *)
val native_operation_digest : Strict_json.limits -> native_request -> (string, Strict_json.fault) result
val native_request_header : native_request -> header
type 'a fact = FKnown of 'a | FUnknown | FNotApplicable
type extent = NotStarted | PartialKnown | CompleteKnown | UnknownTail
type native_stage =
  | Parse | Execute | Register | Restore | StageView
  | CpCollect | CpEncode | CpDecode | CpValidate | CpActivate
type capture_failure = ProducerFailed | TransportGap | BudgetExhausted | StorageFailed | Expired | InvalidEncoding
val make_capture_status : complete:bool -> captured_bytes:U.t -> total_bytes:U.t fact ->
  digest:Digest.t fact -> missing_ranges:(U.t * U.t) list -> reason:capture_failure fact ->
  (capture_status, Strict_json.fault) result
type native_code =
  | InvalidInput | WrongEpoch | BindingConflict | SequenceGap | Capacity
  | StaleRevision | UnknownOperation | InvalidState
type admission = NotAdmitted | ExistingOperation | AdmissionUnknown
val invalid_input : native_code
val unknown_operation : native_code
val binding_conflict : native_code
val invalid_state : native_code
val not_admitted : admission
val fact_unknown : 'a fact
val make_protocol_error : header -> native_code -> admission -> Id.t fact -> native_reply

(* T2b：source/view/blob通道、checkpoint记录族、facts文档、原生记录、兼容快照。
   类型抽象；只暴露typed入口，通道result子集与跨记录关系归消费者，不在此重造。 *)
type receipt
val decode_receipt : Strict_json.limits -> string -> (receipt, Strict_json.fault) result
val encode_receipt : Strict_json.limits -> receipt -> (string, Strict_json.fault) result
(* RC04 ccv-native-receipt-v1域：完整Receipt仅排顶层key.digest一处；返回64个小写hex字符。 *)
val native_receipt_digest : Strict_json.limits -> receipt -> (string, Strict_json.fault) result
type source_request
type native_source_reply
type view_request
type view_reply_pull
type view_reply_ack
type view_reply_release
type view_request_view =
  | PullViewRequest of header * Id.t * Id.t * U.t * U.t * U.t
  | AckViewRequest of header * Id.t * Id.t * U.t * U.t * Digest.t
  | ReleaseViewRequest of header * Id.t * Id.t * U.t fact
type release_status = ClosingStatus | ReleasedStatus
val view_request_view : view_request -> view_request_view
val make_view_chunk : header -> view:Id.t -> operation:Id.t -> seq:U.t -> offset:U.t ->
  text:string -> eof:bool -> capture:capture_status -> (view_reply_pull, Strict_json.fault) result
val make_view_acked : header -> view:Id.t -> operation:Id.t -> seq:U.t -> end_offset:U.t -> view_reply_ack
val make_view_pull_retired : header -> view:Id.t -> operation:Id.t -> requested_seq:U.t ->
  acked_through:U.t -> end_offset:U.t -> view_reply_pull
val make_view_ack_retired : header -> view:Id.t -> operation:Id.t -> requested_seq:U.t ->
  acked_through:U.t -> end_offset:U.t -> view_reply_ack
val make_view_released : header -> view:Id.t -> operation:Id.t -> status:release_status -> view_reply_release
val make_view_pull_error : header -> native_code -> admission -> view_reply_pull
val make_view_ack_error : header -> native_code -> admission -> view_reply_ack
val make_view_release_error : header -> native_code -> admission -> view_reply_release
type checkpoint_blob_request
type checkpoint_blob_reply
type artifact_kind = CkSelection | CkRequirements | CkPlan | CkManifest | CkMap
                   | CkBundle | CkCompatibility | CkObservation | CkPreloadPlan
type artifact_ref = { artifact_id : Id.t; artifact_digest : Digest.t; artifact_bytes : U.t; artifact_kind : artifact_kind }
type checkpoint_transfer = {
  ct_transfer : Id.t; ct_operation : Id.t; ct_operation_seq : U.t;
  ct_control : Id.t; ct_attempt : Id.t; ct_artifact : artifact_ref }
type blob_release_reason = SealedUp | Discarded
type checkpoint_blob_result =
  | BlobBegun of { transfer : Id.t; next_offset : U.t }
  | BlobRegistered of { reg_artifact : artifact_ref }
  | BlobChunkAck of { transfer : Id.t; offset : U.t; end_offset : U.t; ack_digest : Digest.t }
  | BlobRetired of { transfer : Id.t; next_offset : U.t }
  | BlobChunkOut of { transfer : Id.t; seq : U.t; offset : U.t; end_offset : U.t;
                      out_bytes : string; out_end : bool }
  | BlobAcked of { transfer : Id.t; seq : U.t; end_offset : U.t }
  | BlobReleased of { transfer : Id.t; rel_status : release_status }
type blob_request_view =
  | BlobBeginRequest of checkpoint_transfer
  | BlobChunkRequest of Id.t * Id.t * U.t * string
  | BlobFinishRequest of Id.t * Id.t
  | BlobPullRequest of checkpoint_transfer * U.t * U.t * U.t
  | BlobAckRequest of Id.t * Id.t * U.t * U.t * Digest.t
  | BlobReleaseRequest of Id.t * Id.t * blob_release_reason * Id.t option
val checkpoint_blob_request_view : checkpoint_blob_request -> header * blob_request_view
val checkpoint_blob_result : header -> checkpoint_blob_result -> checkpoint_blob_reply
type checkpoint_alias_fact
type 'a known_or_na = KKnown of 'a | KNotApplicable
type checkpoint_source_identity = { csi_source : Id.t; csi_digest : Digest.t; csi_bytes : U.t }
type checkpoint_node_meta = {
  cnm_index : U.t; cnm_old_node : Id.t; cnm_parent : U.t known_or_na; cnm_source : Id.t;
  cnm_start : U.t; cnm_end : U.t; cnm_cursor : U.t; cnm_read_end : U.t; cnm_saw_eof : bool }
type checkpoint_boundary = CbEntry of Id.t | CbStep of Id.t * Id.t
type checkpoint_boundary_row = { cbr_boundary : checkpoint_boundary; cbr_node_index : U.t }
type checkpoint_requirements = {
  cr_selection : artifact_ref; cr_group : Id.t;
  cr_collect_operation : Id.t; cr_instance : Id.t; cr_backend_epoch : U.t;
  cr_manager_epoch : U.t; cr_environment : Id.t; cr_required_sources : Id.t list;
  cr_source_descriptors : checkpoint_source_identity list; cr_alias_facts : checkpoint_alias_fact list;
  cr_nodes : checkpoint_node_meta list; cr_boundaries : checkpoint_boundary_row list }
type checkpoint_selection
type checkpoint_path_snapshot = {
  cps_lineage : Id.t; cps_path_revision : U.t; cps_proof : Id.t; cps_entry_proof : Id.t;
  cps_source_anchor : Id.t; cps_source : Id.t; cps_environment : Id.t;
  cps_frontier : checkpoint_boundary; cps_boundaries : checkpoint_boundary list }
type checkpoint_line_binding
type checkpoint_group = {
  cg_group_id : Id.t; cg_owner_scope : Id.t; cg_native_scope : Id.t; cg_workspace : Id.t;
  cg_instance : Id.t; cg_backend_epoch : U.t; cg_context : Id.t; cg_environment : Id.t;
  cg_paths : checkpoint_path_snapshot list; cg_line_bindings : checkpoint_line_binding list }
val checkpoint_line_identity : checkpoint_line_binding -> Id.t * Id.t * U.t
type scope_checkpoint_plan
type checkpoint_coverage_manifest = {
  ccm_plan : artifact_ref; ccm_group : Id.t; ccm_export_operation : Id.t;
  ccm_instance : Id.t; ccm_backend_epoch : U.t; ccm_manager_epoch : U.t;
  ccm_environment : Id.t; ccm_compatibility : artifact_ref; ccm_requirements : artifact_ref;
  ccm_source_descriptors : checkpoint_source_identity list;
  ccm_nodes : checkpoint_node_meta list; ccm_boundaries : checkpoint_boundary_row list }
type checkpoint_map_row = {
  mr_boundary : checkpoint_boundary; mr_new_node : Id.t; mr_new_line : Id.t;
  mr_new_line_revision : U.t; mr_new_context : Id.t; mr_new_context_revision : U.t }
type checkpoint_import_map = {
  cim_cache : Id.t; cim_group : Id.t; cim_import_operation : Id.t; cim_instance : Id.t;
  cim_backend_epoch : U.t; cim_manager_epoch : U.t; cim_manifest : artifact_ref;
  cim_rows : checkpoint_map_row list; cim_validated_node_count : U.t }
type byte_range = private { range_start : U.t; range_end : U.t }
val make_byte_range : start:U.t -> stop:U.t -> (byte_range, Strict_json.fault) result
type goal_group = Focused | StackLeft | StackRight | Shelved | GivenUp
type goal_selector = private { selector_group : goal_group; depth : U.t; index : U.t }
type goal_part = Conclusion | Hypothesis of U.t
type inspect_kind = IkAssumptions | IkToc | IkNotations | IkEnvironment | IkGoalRoster | IkGoalPart
type cursor
val cursor_fields : cursor -> Id.t * U.t
val make_cursor : stream:Id.t -> after_seq:U.t -> cursor
type inspect_selector =
  | Assumptions of Text.t list
  | Toc | Notations | Environment
  | GoalRoster of cursor option
  | GoalPartSel of goal_selector * goal_part * byte_range
type native_facts_payload
type native_facts_document
type assumption_status = AsmClosed | AsmAssumptions | AsmUnavailable
type native_assumption_item
type native_assumption_root
type native_notation_entry
type native_import_entry
val make_assumption_item : kernel_name:Text.t -> printed_type:Id.t -> native_assumption_item
val make_assumption_root : requested:Text.t -> resolved:string fact -> status:assumption_status ->
  assumptions:native_assumption_item list -> raw:Id.t -> error:string fact ->
  (native_assumption_root, Strict_json.fault) result
val make_assumptions_facts : native_assumption_root list -> (native_facts_payload, Strict_json.fault) result
val make_notation_entry : notation:Text.t -> scope:string fact -> interpretation:Id.t ->
  location:byte_range fact -> (native_notation_entry, Strict_json.fault) result
val make_notations_facts : native_notation_entry list -> complete:bool -> (native_facts_payload, Strict_json.fault) result
val make_import_entry : logical_name:Text.t -> artifact_digest:Digest.t -> physical_mapping:Id.t -> native_import_entry
val make_environment_facts : toolchain:Id.t -> imports:native_import_entry list -> load_mapping_digest:Digest.t ->
  complete:bool -> (native_facts_payload, Strict_json.fault) result
type native_part_descriptor
type native_hypothesis
type native_goal_entry
type native_goal_group
val make_native_part_descriptor : bytes:U.t -> digest:Digest.t -> view:Id.t -> native_part_descriptor
val make_native_hypothesis : index:U.t -> names:Text.t list -> body:native_part_descriptor fact ->
  ty:native_part_descriptor -> (native_hypothesis, Strict_json.fault) result
val make_native_goal_entry : group:goal_group -> depth:U.t -> index:U.t ->
  hypotheses:native_hypothesis list -> conclusion:native_part_descriptor -> (native_goal_entry, Strict_json.fault) result
(* total 是全量；本页 entries 可为空，否则是 1..total 内的连续子窗口。 *)
val make_native_goal_group : group:goal_group -> depth:U.t -> total:U.t ->
  entries:native_goal_entry list -> (native_goal_group, Strict_json.fault) result
(* 每页都提交完整组/帧元数据；中间页须有条目及 Known cursor，末页 next 为 N/A。
   游标真实性和跨页不重复由 Pet 的快照校验。 *)
val make_goal_roster_facts : native_goal_group list -> next:cursor fact ->
  complete:bool -> (native_facts_payload, Strict_json.fault) result
val make_toc_facts : (U.t * U.t fact * Text.t * Text.t * byte_range) list ->
  complete:bool -> (native_facts_payload, Strict_json.fault) result
val make_goal_part_facts : goal:goal_selector -> part:goal_part -> range:byte_range ->
  total_bytes:U.t -> text:string -> part_digest:Digest.t -> eof:bool ->
  (native_facts_payload, Strict_json.fault) result
val encode_native_facts_payload : Strict_json.limits -> native_facts_payload -> (string, Strict_json.fault) result
(* 此处 capture 对应规范编码的内层 facts；外层 view capture 由整份文档字节另算。 *)
val make_native_facts_document : node:Id.t -> source:Id.t -> environment:Id.t ->
  capture:capture_status -> native_facts_payload -> native_facts_document
type native_line_state = LineOpen | LineRetiring | LineClosed
type native_line_change
type native_line_update_document
type ended_status = Closing | Closed
type root_kind =
  | RkLine | RkDoc | RkIndex | RkMemo | RkImports | RkCurrent | RkPending
  | RkInflight | RkView | RkBootstrap | RkCheckpointExport | RkCheckpointImport
type root_class_fact = { rcf_kind : root_kind; rcf_removed : U.t; rcf_retained : U.t; rcf_unresolved : U.t }
type native_reclaim = private {
  nr_id : Id.t; nr_retirement : Id.t; nr_release_seq : U.t; nr_instance : Id.t;
  nr_backend_epoch : U.t; nr_manager_epoch : U.t; nr_status : ended_status;
  nr_roots : root_class_fact list; nr_blockers : Id.t list; nr_observation : Id.t fact }
(* 调用方提供实际账本快照；未知观测显式传 FUnknown。根类缺失、重复或列表超界返回 Constraint。 *)
val make_native_reclaim : id:Id.t -> retirement:Id.t -> release_seq:U.t -> instance:Id.t ->
  backend_epoch:U.t -> manager_epoch:U.t -> status:ended_status -> roots:root_class_fact list ->
  blockers:Id.t list -> observation:Id.t fact -> (native_reclaim, Strict_json.fault) result
type native_retention
type native_memory_observation
type native_boot_binding
type native_boundary_fact
type artifact_identity = { ai_logical_id : string; ai_sha256 : Digest.t; ai_size : U.t }
type runtime_init_step =
  | FindlibPackages of { ordinal : U.t; packages : string list; artifacts : artifact_identity list }
  | CoqInitModule of { ordinal : U.t; artifact : artifact_identity }
type summary_registration = { sr_tag_decimal : string; sr_name : string }
type word_size = W32 | W64
type endianness = LittleEndian | BigEndian
type link_mode = LinkNative | LinkBytecode
type compat_platform = { cp_system : string; cp_architecture : string }
type loaded_role = LdPet | LdRocq | LdOcamlRuntime | LdPlugin
type loaded_kind = LkEmbedded | LkDynamic
type loaded_artifact = {
  la_ordinal : U.t; la_role : loaded_role; la_logical_name : string;
  la_kind : loaded_kind; la_resolved_path : string; la_artifact : artifact_identity }
type loaded_artifact_observation = {
  lao_instance_id : Id.t; lao_backend_epoch : U.t; lao_load_revision : U.t;
  lao_complete : bool; lao_format_id : string; lao_format_version : U.t;
  lao_ocaml_version : string; lao_word_size : word_size; lao_endian : endianness;
  lao_mode : link_mode; lao_platform : compat_platform; lao_loads : loaded_artifact list;
  lao_init_steps : runtime_init_step list; lao_summary_registrations : summary_registration list;
  lao_capabilities : string list }
type resolved_load_artifact = { rla_artifact : artifact_identity; rla_path : string }
type checkpoint_preload_step =
  | PreloadFindlib of U.t * string list * resolved_load_artifact list
  | PreloadModule of U.t * resolved_load_artifact
type checkpoint_preload_plan = {
  cpp_installation : Digest.t; cpp_compatibility : Digest.t; cpp_steps : checkpoint_preload_step list }
type checkpoint_compatibility
val decode_source_request : Strict_json.limits -> string -> (source_request, Strict_json.fault) result
val encode_source_request : Strict_json.limits -> source_request -> (string, Strict_json.fault) result
val decode_source_reply : Strict_json.limits -> string -> (native_source_reply, Strict_json.fault) result
val encode_source_reply : Strict_json.limits -> native_source_reply -> (string, Strict_json.fault) result
val decode_view_request : Strict_json.limits -> string -> (view_request, Strict_json.fault) result
val encode_view_request : Strict_json.limits -> view_request -> (string, Strict_json.fault) result
val decode_view_reply_pull : Strict_json.limits -> string -> (view_reply_pull, Strict_json.fault) result
val encode_view_reply_pull : Strict_json.limits -> view_reply_pull -> (string, Strict_json.fault) result
val decode_view_reply_ack : Strict_json.limits -> string -> (view_reply_ack, Strict_json.fault) result
val encode_view_reply_ack : Strict_json.limits -> view_reply_ack -> (string, Strict_json.fault) result
val decode_view_reply_release : Strict_json.limits -> string -> (view_reply_release, Strict_json.fault) result
val encode_view_reply_release : Strict_json.limits -> view_reply_release -> (string, Strict_json.fault) result
val decode_checkpoint_blob_request : Strict_json.limits -> string -> (checkpoint_blob_request, Strict_json.fault) result
val encode_checkpoint_blob_request : Strict_json.limits -> checkpoint_blob_request -> (string, Strict_json.fault) result
val decode_checkpoint_blob_reply : Strict_json.limits -> string -> (checkpoint_blob_reply, Strict_json.fault) result
val encode_checkpoint_blob_reply : Strict_json.limits -> checkpoint_blob_reply -> (string, Strict_json.fault) result
val decode_checkpoint_alias_fact : Strict_json.limits -> string -> (checkpoint_alias_fact, Strict_json.fault) result
val encode_checkpoint_alias_fact : Strict_json.limits -> checkpoint_alias_fact -> (string, Strict_json.fault) result
val decode_checkpoint_requirements : Strict_json.limits -> string -> (checkpoint_requirements, Strict_json.fault) result
val encode_checkpoint_requirements : Strict_json.limits -> checkpoint_requirements -> (string, Strict_json.fault) result
val decode_checkpoint_selection : Strict_json.limits -> string -> (checkpoint_selection, Strict_json.fault) result
val encode_checkpoint_selection : Strict_json.limits -> checkpoint_selection -> (string, Strict_json.fault) result
val decode_checkpoint_group : Strict_json.limits -> string -> (checkpoint_group, Strict_json.fault) result
val encode_checkpoint_group : Strict_json.limits -> checkpoint_group -> (string, Strict_json.fault) result
val decode_checkpoint_path_snapshot : Strict_json.limits -> string -> (checkpoint_path_snapshot, Strict_json.fault) result
val encode_checkpoint_path_snapshot : Strict_json.limits -> checkpoint_path_snapshot -> (string, Strict_json.fault) result
val decode_scope_checkpoint_plan : Strict_json.limits -> string -> (scope_checkpoint_plan, Strict_json.fault) result
val encode_scope_checkpoint_plan : Strict_json.limits -> scope_checkpoint_plan -> (string, Strict_json.fault) result
val decode_checkpoint_coverage_manifest : Strict_json.limits -> string -> (checkpoint_coverage_manifest, Strict_json.fault) result
val encode_checkpoint_coverage_manifest : Strict_json.limits -> checkpoint_coverage_manifest -> (string, Strict_json.fault) result
val decode_checkpoint_import_map : Strict_json.limits -> string -> (checkpoint_import_map, Strict_json.fault) result
val encode_checkpoint_import_map : Strict_json.limits -> checkpoint_import_map -> (string, Strict_json.fault) result
val decode_native_facts_document : Strict_json.limits -> string -> (native_facts_document, Strict_json.fault) result
val encode_native_facts_document : Strict_json.limits -> native_facts_document -> (string, Strict_json.fault) result
val decode_native_line_update_document : Strict_json.limits -> string -> (native_line_update_document, Strict_json.fault) result
val encode_native_line_update_document : Strict_json.limits -> native_line_update_document -> (string, Strict_json.fault) result
val decode_native_reclaim : Strict_json.limits -> string -> (native_reclaim, Strict_json.fault) result
val encode_native_reclaim : Strict_json.limits -> native_reclaim -> (string, Strict_json.fault) result
val decode_native_retention : Strict_json.limits -> string -> (native_retention, Strict_json.fault) result
val encode_native_retention : Strict_json.limits -> native_retention -> (string, Strict_json.fault) result
val decode_native_memory_observation : Strict_json.limits -> string -> (native_memory_observation, Strict_json.fault) result
val encode_native_memory_observation : Strict_json.limits -> native_memory_observation -> (string, Strict_json.fault) result
val decode_native_boot_binding : Strict_json.limits -> string -> (native_boot_binding, Strict_json.fault) result
val encode_native_boot_binding : Strict_json.limits -> native_boot_binding -> (string, Strict_json.fault) result
val boot_instance : native_boot_binding -> Id.t
val boot_backend_epoch : native_boot_binding -> U.t
val boot_manager_epoch : native_boot_binding -> U.t
val boot_artifact : native_boot_binding -> Id.t
val boot_input_quota : native_boot_binding -> U.t
val boot_operation_capacity : native_boot_binding -> U.t
val boot_channel_nonce : native_boot_binding -> channel -> Id.t
val expected_boot_peer : native_boot_binding -> channel -> (expected_peer, Strict_json.fault) result
val decode_native_boundary_fact : Strict_json.limits -> string -> (native_boundary_fact, Strict_json.fault) result
val encode_native_boundary_fact : Strict_json.limits -> native_boundary_fact -> (string, Strict_json.fault) result
val decode_loaded_artifact_observation : Strict_json.limits -> string -> (loaded_artifact_observation, Strict_json.fault) result
val encode_loaded_artifact_observation : Strict_json.limits -> loaded_artifact_observation -> (string, Strict_json.fault) result
val decode_checkpoint_preload_plan : Strict_json.limits -> string -> (checkpoint_preload_plan, Strict_json.fault) result
val encode_checkpoint_preload_plan : Strict_json.limits -> checkpoint_preload_plan -> (string, Strict_json.fault) result
val checkpoint_selected_group : checkpoint_selection -> control:Id.t -> group:Id.t -> checkpoint_group option
val checkpoint_plan_group : scope_checkpoint_plan -> group:Id.t ->
  (Id.t * checkpoint_group * artifact_ref * artifact_ref list * Id.t list) option
val decode_checkpoint_compatibility : Strict_json.limits -> string -> (checkpoint_compatibility, Strict_json.fault) result
val encode_checkpoint_compatibility : Strict_json.limits -> checkpoint_compatibility -> (string, Strict_json.fault) result
val checkpoint_installation : checkpoint_compatibility -> Digest.t
val checkpoint_observation_matches : checkpoint_compatibility -> loaded_artifact_observation -> bool

(* OC06：四surface静态表；methods为编入载荷引用（compiled_surfaces.ml经构建期
   逐字节对账编译），无运行schema解释。 *)
module Surface : sig
  type t = Mcp | Pet | Manager_control | Supervisor_control
  type method_definition = Compiled_surfaces.method_def
  type definition = {
    surface : t;
    table_sha256 : string;
    methods : method_definition array;
  }
  val to_name : t -> string
  val all : t list
  val surface : t -> definition
end

(* U3 nativeface typed request view / reply builders. These are constructors for
   the fixed wire roots above; they do not grant authority or execute Rocq. *)
type op_binding
type receipt_key
type ack_proof
type control_operation = Export | Import
type native_purpose = private
  | Task
  | CheckpointControl of { control : Id.t; operation : control_operation; attempt : Id.t }
type native_budget
type native_op_state = Ready | Executing | WaitAck | TerminalState | Retiring
type native_target = Root | EndTarget | Position of U.t * U.t | Theorem of Text.t
type args_locate_context
type args_select_line
type args_fork_line
type aux_terminal
type args_checkpoint_observe = {
  co_binding : op_binding; co_control : Id.t; co_attempt : Id.t; preload : artifact_ref known_or_na }
type args_checkpoint_export_collect = {
  ec_binding : op_binding; ec_control : Id.t; ec_attempt : Id.t;
  selection : artifact_ref; ec_group : Id.t; ec_compatibility : artifact_ref }
type args_checkpoint_export_encode = {
  ee_binding : op_binding; ee_control : Id.t; ee_attempt : Id.t;
  plan : artifact_ref; requirements : artifact_ref; ee_group : Id.t; ee_compatibility : artifact_ref }
type args_checkpoint_import = {
  ci_binding : op_binding; ci_control : Id.t; ci_attempt : Id.t; ci_cache : Id.t;
  ci_plan : artifact_ref; ci_group : Id.t; ci_manifest : artifact_ref;
  ci_bundle : artifact_ref; ci_compatibility : artifact_ref }
type activation_permit = {
  activation_id : Id.t; ap_control_id : Id.t; ap_cache_id : Id.t;
  import_operation : Id.t; import_receipt_key : receipt_key;
  ap_instance : Id.t; ap_backend_epoch : U.t; ap_manager_epoch : U.t; binding_revision : U.t }
type args_checkpoint_activate = {
  ca_binding : op_binding; ca_import_receipt : receipt_key;
  activation : activation_permit; ca_mapping : artifact_ref }
type checkpoint_request_view =
  | ObserveCheckpoint of args_checkpoint_observe
  | CollectCheckpoint of args_checkpoint_export_collect
  | EncodeCheckpoint of args_checkpoint_export_encode
  | ImportCheckpoint of args_checkpoint_import
  | ActivateCheckpoint of args_checkpoint_activate
type native_request_view =
  | BeginLineRequest of header * op_binding * Id.t * U.t * Id.t * bool
  | LocateContextRequest of header * args_locate_context
  | SelectLineRequest of header * args_select_line
  | EndScopeRequest of header * op_binding * Id.t * U.t
  | ForkLineRequest of header * args_fork_line
  | QueryRequest of header * op_binding * Id.t * (Id.t * U.t * U.t) * Id.t
  | InspectRequest of header * op_binding * Id.t * inspect_selector * Id.t
  | SyncSourceRequest of header * op_binding * Id.t * (Id.t * U.t) * Id.t * Id.t * Id.t
  | RefreshEnvironmentRequest of header * op_binding * Id.t * Id.t * Id.t
  | PullStepRequest of header * op_binding * U.t
  | AckStepRequest of header * op_binding * ack_proof
  | OperationStatusRequest of header * op_binding
  | SettleInterruptRequest of header * op_binding
  | FinishOperationRequest of header * op_binding * receipt_key
  | RetireThroughRequest of header * U.t
  | RegisterBudgetRequest of header * native_budget * Id.t
  | CheckpointRequest of header * checkpoint_request_view
  | OtherRequest of header * string
type source_request_view =
  | SourceBeginRequest of header * Id.t * U.t * Digest.t
  | SourceChunkRequest of header * Id.t * U.t * string
  | SourceFinishRequest of header * Id.t
val native_request_view : native_request -> native_request_view
val locate_fields : args_locate_context ->
  op_binding * Id.t * string * native_target * Id.t * (Id.t * U.t) option * (Id.t * U.t) option
val select_fields : args_select_line -> op_binding * Id.t * U.t * Id.t * Id.t * bool
val select_group : args_select_line -> (Id.t * U.t) option
val fork_fields : args_fork_line -> op_binding * Id.t * (Id.t * U.t) * Id.t * Id.t
val make_fork_terminal : op_binding -> line:Id.t -> node:Id.t -> revision:U.t ->
  group:(Id.t * U.t) -> aux_terminal
val native_ready : native_op_state
val op_binding_equal : op_binding -> op_binding -> bool
val op_binding_budget : op_binding -> Id.t
val op_binding_operation : op_binding -> Id.t
val op_binding_source : op_binding -> Id.t
val op_binding_line_owner : op_binding -> Id.t * Id.t * Id.t
val header_matches_boot : native_boot_binding -> header -> bool
val receipt_key_equal : receipt_key -> receipt_key -> bool
val ack_proof_equal : ack_proof -> ack_proof -> bool
val ack_proof_receipt : ack_proof -> receipt_key
val ack_proof_durable_record : ack_proof -> Id.t
val header_rpc_seq : header -> U.t
type terminal_record
type ack_status
val op_seq : op_binding -> U.t
val budget_id : native_budget -> Id.t
val budget_scope : native_budget -> Id.t
val budget_purpose : native_budget -> native_purpose
val budget_grant : native_budget -> Id.t
val budget_operation_seq : native_budget -> U.t
val budget_revision : native_budget -> U.t
val budget_execution_deadline : native_budget -> U.t
val budget_equal : native_budget -> native_budget -> bool
val budget_for_task_entry : native_boot_binding -> native_budget -> bool
val budget_for_checkpoint_entry : native_boot_binding -> native_budget -> bool
val checkpoint_input_budget : native_budget -> checkpoint_transfer -> (U.t * U.t) option
val checkpoint_output_budget : native_budget -> checkpoint_transfer -> (U.t * U.t) option
val checkpoint_pending_import : native_budget -> Id.t option
val checkpoint_request_binding : checkpoint_request_view -> op_binding
val checkpoint_budget_binding : native_budget -> (Id.t * Id.t * U.t * U.t * U.t) option
val budget_source_environment : native_budget -> Id.t * Id.t
val checkpoint_blob_error : header -> native_code -> admission -> checkpoint_blob_reply
val budget_recovery_deadline : native_budget -> U.t
val budget_output_deadline : native_budget -> U.t
val budget_output_bytes : native_budget -> U.t
val boot_view_quota : native_boot_binding -> U.t
val boot_platform_fields : native_boot_binding -> string * string
val entry_uses_budget : Strict_json.limits -> native_budget -> native_request -> bool
val matches_original_operation : Strict_json.limits -> op_binding -> native_request -> bool
type locator_outcome =
  | LocatedRoot
  | LocatedBoundary of native_boundary_fact
  | PrefixRequired of native_target * native_boundary_fact option
  | LocateInitFailed
  | LocateTargetMissing of Id.t
val make_entry_boundary : header -> op_binding -> target:Id.t -> node:Id.t ->
  command_start:U.t -> command_end:U.t -> native_boundary_fact
val make_locator_terminal : op_binding -> line:Id.t -> node:Id.t -> revision:U.t ->
  cursor:U.t -> locator_outcome -> aux_terminal
val locator_terminal_key : aux_terminal -> receipt_key
val locator_reply : header -> aux_terminal -> native_reply
val make_native_line_change : line:Id.t -> before_revision:U.t -> after_revision:U.t ->
  frontier:Id.t fact -> state:native_line_state -> (native_line_change, Strict_json.fault) result
(* 行 ID 必须已严格排序；完整性、源角色和 context 版本由 Pet 的事务核对。 *)
val make_native_line_update_document : boot:native_boot_binding -> binding:op_binding ->
  context:Id.t -> old_source:Id.t -> new_source:Id.t -> before_context_revision:U.t ->
  after_context_revision:U.t -> native_line_change list -> (native_line_update_document, Strict_json.fault) result
val make_source_synced_terminal : op_binding -> context:Id.t -> revision:U.t -> source:Id.t ->
  last_valid:Id.t fact -> reclaim:Id.t -> boundary:native_boundary_fact fact -> view:Id.t ->
  digest:Digest.t -> bytes:U.t -> aux_terminal
val make_environment_refreshed_terminal : op_binding -> environment:Id.t -> changed:bool ->
  reclaim:Id.t fact -> aux_terminal
val make_query_view_terminal : op_binding -> node:Id.t -> view:Id.t -> capture:capture_status ->
  extent:extent -> aux_terminal
val make_inspect_view_terminal : op_binding -> node:Id.t -> view:Id.t -> capture:capture_status ->
  kind:inspect_kind -> extent:extent -> aux_terminal
val make_query_error_terminal : op_binding -> stage:native_stage -> diagnostic:Id.t fact ->
  last_valid:Id.t fact -> extent:extent -> aux_terminal
val locator_status : header -> aux_terminal -> highest_seen:U.t -> retired_through:U.t -> native_reply
type checkpoint_outcome =
  | ObservedArtifact of args_checkpoint_observe * artifact_ref
  | CollectedArtifact of args_checkpoint_export_collect * artifact_ref
  | ExportedArtifacts of args_checkpoint_export_encode * artifact_ref * artifact_ref
  | ImportedArtifact of args_checkpoint_import * artifact_ref
  | ActivatedArtifact of args_checkpoint_activate * Id.t
type checkpoint_stage = CollectStage | EncodeStage | DecodeStage | ValidateStage | ActivateStage
val make_checkpoint_terminal : checkpoint_outcome -> aux_terminal
val make_checkpoint_error : op_binding -> checkpoint_stage -> started:bool -> aux_terminal
val checkpoint_status : header -> op_binding -> highest_seen:U.t -> retired_through:U.t ->
  native_op_state -> aux_terminal option -> stop_requested:bool -> native_reply
val make_retired : header -> U.t -> native_reply
val receipt_key : receipt -> receipt_key
val terminal_key : terminal_record -> receipt_key
val receipt_reply : header -> receipt -> native_reply
val terminal_reply : header -> terminal_record -> native_reply
(* 第二个参数是 receipt_seq。Pet 核原 scope 和 revision，并仅在实际清理完成时构造 closed。 *)
val make_ended_closing : op_binding -> U.t -> scope:Id.t -> reclaim:Id.t fact -> receipt
val make_ended_closed : op_binding -> U.t -> scope:Id.t -> reclaim:Id.t fact -> receipt * terminal_record
val make_selected_entry : op_binding -> line:Id.t -> before_revision:U.t ->
  after_revision:U.t -> node:Id.t -> receipt * terminal_record
val make_selected_group : op_binding -> line:Id.t -> before_revision:U.t ->
  after_revision:U.t -> node:Id.t -> group:Id.t -> group_revision:U.t -> receipt * terminal_record
val terminal_is_eof : terminal_record -> bool
val terminal_is_prefix_reached : terminal_record -> bool
val make_interrupted_terminal : op_binding -> U.t -> stopped:bool fact -> synchronized:bool fact ->
  last_acked:Id.t fact -> pending:Id.t fact -> recoverable:bool fact -> diagnostic:Id.t fact ->
  extent:extent -> terminal_record
val error_terminal : op_binding -> U.t -> parse:bool -> last_valid:Id.t ->
  group:(Id.t * U.t) option -> terminal_record
val make_status :
  ?stop_requested:bool -> header -> op_binding -> native_op_state -> U.t -> highest_seen:U.t -> retired_through:U.t -> pending:receipt option ->
  terminal:terminal_record option -> last_ack:ack_status option -> native_reply
val make_retiring_status : header -> op_binding -> highest_seen:U.t -> retired_through:U.t ->
  stop_requested:bool -> native_reply
val make_step_receipt :
  op_binding -> parent:Id.t -> node:Id.t -> source:Id.t ->
  command_start:U.t -> command_end:U.t -> next_cursor:U.t -> line:Id.t ->
  base_revision:U.t -> step_seq:U.t -> receipt
val make_ack :
  receipt_key -> line:Id.t -> line_revision:U.t -> acked_through:U.t ->
  group:(Id.t * U.t) option -> ack_status
val ack_reply : header -> ack_status -> native_reply
val make_finished : header -> receipt_key -> native_reply
val make_past_unavailable : header -> U.t -> U.t -> native_reply
val make_budget_registered : header -> Id.t -> Id.t -> U.t -> native_reply
val make_eof :
  op_binding -> U.t -> acked_through:U.t -> cursor:U.t -> terminal_record
val make_prefix_reached :
  op_binding -> U.t -> target:Id.t -> acked_through:U.t -> cursor:U.t -> terminal_record
val source_request_view : source_request -> source_request_view
val make_source_begun : header -> Id.t -> U.t -> native_source_reply
val make_source_chunk_ack : header -> Id.t -> U.t -> U.t -> string -> native_source_reply
val make_source_registered : header -> Id.t -> U.t -> string -> native_source_reply
val make_source_retired : header -> Id.t -> U.t -> native_source_reply
val make_source_error :
  header -> native_code -> admission -> Id.t fact -> native_source_reply
