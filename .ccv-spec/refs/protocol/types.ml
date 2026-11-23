open Strict_json
exception Bad of fault
let bad e = raise (Bad e)
let get = function Ok v -> v | Error e -> bad e
let protect f = try Ok (f ()) with
  | Bad e -> Error e | Out_of_memory | Stack_overflow | Invalid_argument _ | Failure _ -> Error Infrastructure
let text_bound maximum s =
  if String.length s = 0 || String.length s > maximum then Error Constraint
  else match string_value s with Ok _ -> Ok s | Error e -> Error e
(* 空文本允许槽位（schema的Text65536/NativeViewChunk.text为minLength 0）：
   仅上限、可空串；wire编码仍是原字符串，无变换。 *)
let text0_bound maximum s =
  if String.length s > maximum then Error Constraint
  else match string_value s with Ok _ -> Ok s | Error e -> Error e
module Id = struct type t = string let make = text_bound 256 let get v = v end
module Text = struct type t = string let make = text_bound 65536 let get v = v end
module U = struct
  type t = int64
  let make n = if n < 0L || n > 9007199254740991L then Error Constraint else Ok n
  let get v = v
end
module Digest = struct
  type t = string
  let make s =
    if String.length s <> 64 || not (String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) s)
    then Error Constraint else Ok s
  let get v = v
end
type channel = Ordinary | Control | Source | View
type limits_backend = Control_interrupt | Memprof_limits
type header = { instance : Id.t; backend_epoch : U.t; manager_epoch : U.t; rpc_seq : U.t }
type compatibility = { major : U.t; digest : Digest.t; capabilities : Text.t list }
type hello = { header : header; channel : channel; nonce : Id.t; compatibility : compatibility; expected_artifact : Id.t }
type runtime = { artifact : Id.t; rocq_version : Text.t; ocaml_version : Text.t; limits_backend : limits_backend }
type hello_ack = { header : header; channel : channel; nonce : Id.t; compatibility : compatibility; runtime : runtime }
type peer = Hello of hello | Ack of hello_ack
let header ~instance ~backend_epoch ~manager_epoch ~rpc_seq = { instance; backend_epoch; manager_epoch; rpc_seq }
let compatibility ~major ~digest ~capabilities =
  if U.get major < 1L || List.length capabilities > 65536 then Error Constraint
  else Ok { major; digest; capabilities }
let hello_header (h : hello) = h.header
let hello_channel (h : hello) = h.channel
let hello_nonce (h : hello) = h.nonce
let hello_compatibility (h : hello) = h.compatibility
let hello_expected_artifact (h : hello) = h.expected_artifact
let check_unique c = protect (fun () ->
  let seen = Hashtbl.create ~random:true 16 in
  List.iter (fun cap -> let s = Text.get cap in if Hashtbl.mem seen s then bad Constraint; Hashtbl.add seen s ()) c.capabilities)
let compatibility_for_send ~major ~digest ~capabilities =
  let capabilities = List.sort (fun a b -> String.compare (Text.get a) (Text.get b)) capabilities in
  match compatibility ~major ~digest ~capabilities with
  | Error e -> Error e | Ok value -> begin match check_unique value with Ok () -> Ok value | Error e -> Error e end
let hello ~header ~channel ~nonce ~compatibility ~expected_artifact = { header; channel; nonce; compatibility; expected_artifact }
let hello_ack ~header ~channel ~nonce ~compatibility ~artifact ~rocq_version ~ocaml_version ~limits_backend =
  { header; channel; nonce; compatibility; runtime = { artifact; rocq_version; ocaml_version; limits_backend } }

let object_ v = match view v with View_object fields -> fields | _ -> bad Type_mismatch
let string v = match view v with View_string s -> s | _ -> bad Type_mismatch
let int v = match view v with View_integer n -> n | _ -> bad Type_mismatch
let required fields name = match StringMap.find_opt name fields with Some v -> v | None -> bad Missing_field
let fields value names =
  let actual = object_ value in
  List.iter (fun name -> ignore (required actual name)) names;
  StringMap.iter (fun name _ -> if not (List.mem name names) then bad Unknown_field) actual;
  actual
let id v = get (Id.make (string v))
let rel_path v =
  let s = get (text_bound 4096 (string v)) in
  if String.contains s '\000'
     || List.exists (function "" | "." | ".." -> true | _ -> false)
          (String.split_on_char '/' s)
  then bad Constraint;
  s
let text v = get (Text.make (string v))
(* 空文本允许槽位的读取助手（对应schema minLength 0；上限与Rust侧同界）。 *)
let view_text v = get (text0_bound 8192 (string v))
let text65536 v = get (text0_bound 65536 (string v))
let uint v = get (U.make (int v))
let channel v = match string v with
  | "ordinary" -> Ordinary | "control" -> Control | "source" -> Source | "view" -> View | _ -> bad Invalid_tag
let backend v = match string v with
  | "control_interrupt" -> Control_interrupt | "memprof_limits" -> Memprof_limits | _ -> bad Invalid_tag
let read_header v =
  let f = fields v ["version"; "instance"; "backend_epoch"; "manager_epoch"; "rpc_seq"] in
  if int (required f "version") <> 1L then bad Constraint;
  header ~instance:(id (required f "instance")) ~backend_epoch:(uint (required f "backend_epoch"))
    ~manager_epoch:(uint (required f "manager_epoch")) ~rpc_seq:(uint (required f "rpc_seq"))
let read_compatibility v =
  let f = fields v ["major"; "contract_digest"; "capabilities"] in
  let caps = match view (required f "capabilities") with View_array vs -> vs | _ -> bad Type_mismatch in
  if List.length caps > 65536 then bad Constraint;
  get (compatibility ~major:(uint (required f "major")) ~digest:(get (Digest.make (string (required f "contract_digest"))))
    ~capabilities:(List.rev (List.rev_map text caps)))
let peer_of_json v = protect (fun () ->
  let tag = string (required (object_ v) "kind") in
  match tag with
  | "hello" ->
      let f = fields v ["kind"; "header"; "channel"; "nonce"; "compatibility"; "expected_artifact"] in
      Hello (hello ~header:(read_header (required f "header")) ~channel:(channel (required f "channel"))
        ~nonce:(id (required f "nonce")) ~compatibility:(read_compatibility (required f "compatibility"))
        ~expected_artifact:(id (required f "expected_artifact")))
  | "hello_ack" ->
      let f = fields v ["kind"; "header"; "channel"; "nonce"; "compatibility"; "artifact"; "rocq_version"; "ocaml_version"; "limits_backend"] in
      Ack (hello_ack ~header:(read_header (required f "header")) ~channel:(channel (required f "channel"))
        ~nonce:(id (required f "nonce")) ~compatibility:(read_compatibility (required f "compatibility"))
        ~artifact:(id (required f "artifact")) ~rocq_version:(text (required f "rocq_version"))
        ~ocaml_version:(text (required f "ocaml_version")) ~limits_backend:(backend (required f "limits_backend")))
  | _ -> bad Invalid_tag)
let decode_peer limits raw = match decode limits raw with Error e -> Error e | Ok v -> peer_of_json v

let js s = get (string_value s)
let ji n = get (integer_value n)
let record fields = get (object_value fields)
let channel_name = function Ordinary -> "ordinary" | Control -> "control" | Source -> "source" | View -> "view"
let backend_name = function Control_interrupt -> "control_interrupt" | Memprof_limits -> "memprof_limits"
let write_header h = record ["version", ji 1L; "instance", js (Id.get h.instance);
  "backend_epoch", ji (U.get h.backend_epoch); "manager_epoch", ji (U.get h.manager_epoch); "rpc_seq", ji (U.get h.rpc_seq)]
let write_compatibility c = record ["major", ji (U.get c.major); "contract_digest", js (Digest.get c.digest);
  "capabilities", array_value (List.rev (List.rev_map (fun s -> js (Text.get s)) c.capabilities))]
let peer_to_json peer = protect (fun () ->
  let common header channel nonce compatibility = ["header", write_header header; "channel", js (channel_name channel);
    "nonce", js (Id.get nonce); "compatibility", write_compatibility compatibility] in
  match peer with
  | Hello h -> record (("kind", js "hello") :: ("expected_artifact", js (Id.get h.expected_artifact)) :: common h.header h.channel h.nonce h.compatibility)
  | Ack h -> record (["kind", js "hello_ack"; "artifact", js (Id.get h.runtime.artifact);
      "rocq_version", js (Text.get h.runtime.rocq_version); "ocaml_version", js (Text.get h.runtime.ocaml_version);
      "limits_backend", js (backend_name h.runtime.limits_backend)] @ common h.header h.channel h.nonce h.compatibility))
let encode_peer limits peer = match peer_to_json peer with Error e -> Error e | Ok value -> canonical limits value

type receive_identity = To_native of Id.t | To_driver of runtime
type expected_peer = { expected_header : header; expected_channel : channel; expected_nonce : Id.t; receiver : receive_identity }
let expected_native ~header ~channel ~nonce ~artifact =
  if U.get header.rpc_seq <> 0L then Error Constraint
  else Ok { expected_header = header; expected_channel = channel; expected_nonce = nonce; receiver = To_native artifact }
let expected_driver ~header ~channel ~nonce ~artifact ~rocq_version ~ocaml_version ~limits_backend =
  if U.get header.rpc_seq <> 0L then Error Constraint
  else Ok { expected_header = header; expected_channel = channel; expected_nonce = nonce;
    receiver = To_driver { artifact; rocq_version; ocaml_version; limits_backend } }
let required_capabilities = function
  | Ordinary -> ["checkpoint_observe_v1"; "checkpoint_export_v1"; "checkpoint_import_v1"; "checkpoint_activate_v1"]
  | Control -> [] | Source -> ["checkpoint_blob_upload_v1"] | View -> ["checkpoint_blob_download_v1"]

(* OC07：固定接收方向及编入常量，无动态协商策略参数。 *)
let check_hello expected peer = protect (fun () ->
  let header, channel, nonce, compat = match expected.receiver, peer with
    | To_native artifact, Hello h ->
        if artifact <> h.expected_artifact then bad Incompatible;
        h.header, h.channel, h.nonce, h.compatibility
    | To_driver runtime, Ack h ->
        if runtime <> h.runtime then bad Incompatible;
        h.header, h.channel, h.nonce, h.compatibility
    | _ -> bad Invalid_tag in
  if header <> expected.expected_header || channel <> expected.expected_channel || nonce <> expected.expected_nonce then bad Incompatible;
  if U.get compat.major <> Compiled_protocol.major || Digest.get compat.digest <> Compiled_protocol.contract_digest then bad Incompatible;
  get (check_unique compat);
  List.iter (fun required -> if not (List.exists (fun cap -> Text.get cap = required) compat.capabilities) then bad Incompatible)
    (required_capabilities channel))

(* ---- T2a：原生普通+控制消息面（rmcp-7 §3 / rmcp-8 §3 wire投影）----
   method↔args配对、§3.2方法-结果矩阵、WAIT_ACK/TERMINAL状态关系等归消费者（W01-W04），
   此处只做结构封闭与值域。两态Fact分域：group/lineage/checkpoint_limits的unknown是
   已知但被禁用的状态（CONSTRAINT，冻结负例钉住）；initial_request.phase按oneOf判别
   失败归INVALID_TAG（冻结负例钉住）。RC04前像仅删args顶层binding.request_digest一处。 *)

let boolean v = match view v with View_bool b -> b | _ -> bad Type_mismatch
let read_enum table v = match List.assoc_opt (string v) table with
  | Some value -> value | None -> bad Invalid_tag
let write_enum table value = match List.find_opt (fun (_, candidate) -> candidate = value) table with
  | Some (name, _) -> js name | None -> bad Infrastructure
let fields_opt value names optional =
  let actual = object_ value in
  List.iter (fun name -> ignore (required actual name)) names;
  StringMap.iter (fun name _ -> if not (List.mem name names || List.mem name optional) then bad Unknown_field) actual;
  actual
let opt_field read fields_ name = match StringMap.find_opt name fields_ with
  | None -> None | Some value -> Some (read value)

type 'a fact = FKnown of 'a | FUnknown | FNotApplicable
let read_fact read v = match string (required (object_ v) "status") with
  | "known" -> FKnown (read (required (fields v ["status"; "value"]) "value"))
  | "unknown" -> ignore (fields v ["status"]); FUnknown
  | "not_applicable" -> ignore (fields v ["status"]); FNotApplicable
  | _ -> bad Invalid_tag
let write_fact write = function
  | FKnown value -> record ["status", js "known"; "value", write value]
  | FUnknown -> record ["status", js "unknown"]
  | FNotApplicable -> record ["status", js "not_applicable"]
let write_id x = js (Id.get x)
let write_uint x = ji (U.get x)
let write_digest x = js (Digest.get x)

type 'a known_or_na = KKnown of 'a | KNotApplicable
let read_known_or_na read v = match string (required (object_ v) "status") with
  | "known" -> KKnown (read (required (fields v ["status"; "value"]) "value"))
  | "not_applicable" -> ignore (fields v ["status"]); KNotApplicable
  | "unknown" -> bad Constraint
  | _ -> bad Invalid_tag
let write_known_or_na write = function
  | KKnown value -> record ["status", js "known"; "value", write value]
  | KNotApplicable -> record ["status", js "not_applicable"]

type extent = NotStarted | PartialKnown | CompleteKnown | UnknownTail
let extent_table = ["not_started", NotStarted; "partial_known", PartialKnown; "complete_known", CompleteKnown; "unknown_tail", UnknownTail]
let read_extent v = read_enum extent_table v
let write_extent v = write_enum extent_table v

type op_binding = {
  operation_id : Id.t; operation_seq : U.t; request_digest : Digest.t;
  context : Id.t; scope : Id.t; source : Id.t; environment : Id.t; budget : Id.t }
let read_op_binding v =
  let f = fields v ["operation_id"; "operation_seq"; "request_digest"; "context"; "scope"; "source"; "environment"; "budget"] in
  { operation_id = id (required f "operation_id"); operation_seq = uint (required f "operation_seq");
    request_digest = get (Digest.make (string (required f "request_digest")));
    context = id (required f "context"); scope = id (required f "scope"); source = id (required f "source");
    environment = id (required f "environment"); budget = id (required f "budget") }
let write_op_binding b = record ["operation_id", js (Id.get b.operation_id);
  "operation_seq", ji (U.get b.operation_seq); "request_digest", js (Digest.get b.request_digest);
  "context", js (Id.get b.context); "scope", js (Id.get b.scope); "source", js (Id.get b.source);
  "environment", js (Id.get b.environment); "budget", js (Id.get b.budget)]

type receipt_key = { rk_operation_id : Id.t; rk_operation_seq : U.t; rk_receipt_seq : U.t; rk_digest : Digest.t }
let read_receipt_key v =
  let f = fields v ["operation_id"; "operation_seq"; "receipt_seq"; "digest"] in
  { rk_operation_id = id (required f "operation_id"); rk_operation_seq = uint (required f "operation_seq");
    rk_receipt_seq = uint (required f "receipt_seq"); rk_digest = get (Digest.make (string (required f "digest"))) }
let write_receipt_key k = record ["operation_id", js (Id.get k.rk_operation_id);
  "operation_seq", ji (U.get k.rk_operation_seq); "receipt_seq", ji (U.get k.rk_receipt_seq);
  "digest", js (Digest.get k.rk_digest)]

type native_version = { nv_id : Id.t; nv_revision : U.t }
let read_native_version v =
  let f = fields v ["id"; "revision"] in
  { nv_id = id (required f "id"); nv_revision = uint (required f "revision") }
let write_native_version v = record ["id", js (Id.get v.nv_id); "revision", ji (U.get v.nv_revision)]

type native_group_version = { group : Id.t; expected_revision : U.t }
let read_native_group_version v =
  let f = fields v ["group"; "expected_revision"] in
  { group = id (required f "group"); expected_revision = uint (required f "expected_revision") }
let write_native_group_version v = record ["group", js (Id.get v.group); "expected_revision", ji (U.get v.expected_revision)]

type byte_range = { range_start : U.t; range_end : U.t }
let make_byte_range ~start ~stop =
  if U.get start > U.get stop then Error Constraint
  else Ok { range_start = start; range_end = stop }

let read_byte_range v =
  let f = fields v ["start"; "end"] in
  let r = { range_start = uint (required f "start"); range_end = uint (required f "end") } in
  (* 与Rust端既审值域一致（actor批）：start<=end为值本地关系，两端同构。 *)
  if U.get r.range_start > U.get r.range_end then bad Constraint;
  r
let write_byte_range r = record ["start", ji (U.get r.range_start); "end", ji (U.get r.range_end)]

type cursor = { stream : Id.t; after_seq : U.t }
let cursor_fields (cursor : cursor) = cursor.stream, cursor.after_seq
let make_cursor ~stream ~after_seq : cursor = { stream; after_seq }
let read_cursor v =
  let f = fields v ["stream"; "after_seq"] in
  { stream = id (required f "stream"); after_seq = uint (required f "after_seq") }
let write_cursor c = record ["stream", js (Id.get c.stream); "after_seq", ji (U.get c.after_seq)]

type export_phase = Collect | Encode
let export_phase_table = ["collect", Collect; "encode", Encode]
type initial_phase = PhaseKnown of export_phase | PhaseNa
let read_initial_phase v = match string (required (object_ v) "status") with
  | "known" -> PhaseKnown (read_enum export_phase_table (required (fields v ["status"; "value"]) "value"))
  | "not_applicable" -> ignore (fields v ["status"]); PhaseNa
  | _ -> bad Invalid_tag
let write_initial_phase = function
  | PhaseKnown phase -> record ["status", js "known"; "value", write_enum export_phase_table phase]
  | PhaseNa -> record ["status", js "not_applicable"]

type native_edit = Append | ReplaceFrom of Id.t
let read_native_edit v = match string (required (object_ v) "kind") with
  | "append" -> ignore (fields v ["kind"]); Append
  | "replace_from" -> ReplaceFrom (id (required (fields v ["kind"; "node"]) "node"))
  | _ -> bad Invalid_tag
let write_native_edit = function
  | Append -> record ["kind", js "append"]
  | ReplaceFrom node -> record ["kind", js "replace_from"; "node", js (Id.get node)]

type native_target = Root | EndTarget | Position of U.t * U.t | Theorem of Text.t
let read_native_target v = match string (required (object_ v) "kind") with
  | "root" -> ignore (fields v ["kind"]); Root
  | "end" -> ignore (fields v ["kind"]); EndTarget
  | "position" -> let f = fields v ["kind"; "line"; "character"] in
      Position (uint (required f "line"), uint (required f "character"))
  | "theorem" -> Theorem (text (required (fields v ["kind"; "name"]) "name"))
  | _ -> bad Invalid_tag
let write_native_target = function
  | Root -> record ["kind", js "root"]
  | EndTarget -> record ["kind", js "end"]
  | Position (line, character) -> record ["kind", js "position"; "line", ji (U.get line); "character", ji (U.get character)]
  | Theorem name -> record ["kind", js "theorem"; "name", js (Text.get name)]

(* NN01唯一生产；origin是固定标记。 *)
type native_boundary_fact = {
  bf_instance : Id.t; bf_backend_epoch : U.t; bf_manager_epoch : U.t; bf_context : Id.t;
  bf_source : Id.t; bf_environment : Id.t; bf_target : Id.t; bf_entry_node : Id.t;
  bf_entry_offset : U.t; bf_entry_command : byte_range; bf_replace_range : byte_range fact }
let read_native_boundary_fact v =
  let f = fields v ["instance"; "backend_epoch"; "manager_epoch"; "context"; "source"; "environment";
    "target"; "entry_node"; "entry_offset"; "entry_command"; "replace_range"; "origin"] in
  if string (required f "origin") <> "native_parser" then bad Invalid_tag;
  { bf_instance = id (required f "instance"); bf_backend_epoch = uint (required f "backend_epoch");
    bf_manager_epoch = uint (required f "manager_epoch"); bf_context = id (required f "context");
    bf_source = id (required f "source"); bf_environment = id (required f "environment");
    bf_target = id (required f "target"); bf_entry_node = id (required f "entry_node");
    bf_entry_offset = uint (required f "entry_offset"); bf_entry_command = read_byte_range (required f "entry_command");
    bf_replace_range = read_fact read_byte_range (required f "replace_range") }
let write_native_boundary_fact b = record ["instance", js (Id.get b.bf_instance);
  "backend_epoch", ji (U.get b.bf_backend_epoch); "manager_epoch", ji (U.get b.bf_manager_epoch);
  "context", js (Id.get b.bf_context); "source", js (Id.get b.bf_source);
  "environment", js (Id.get b.bf_environment); "target", js (Id.get b.bf_target);
  "entry_node", js (Id.get b.bf_entry_node); "entry_offset", ji (U.get b.bf_entry_offset);
  "entry_command", write_byte_range b.bf_entry_command;
  "replace_range", write_fact write_byte_range b.bf_replace_range; "origin", js "native_parser"]

type native_view_ref = { view_id : Id.t }
let read_native_view_ref v =
  let f = fields v ["kind"; "id"] in
  if string (required f "kind") <> "native_view" then bad Invalid_tag;
  { view_id = id (required f "id") }
let write_native_view_ref r = record ["kind", js "native_view"; "id", js (Id.get r.view_id)]

type native_line_update_ref = { lu_view : native_view_ref; lu_digest : Digest.t; lu_bytes : U.t }
let read_native_line_update_ref v =
  let f = fields v ["view"; "digest"; "bytes"] in
  { lu_view = read_native_view_ref (required f "view");
    lu_digest = get (Digest.make (string (required f "digest"))); lu_bytes = uint (required f "bytes") }
let write_native_line_update_ref r = record ["view", write_native_view_ref r.lu_view;
  "digest", js (Digest.get r.lu_digest); "bytes", ji (U.get r.lu_bytes)]

type ack_proof = { receipt : receipt_key; durable_record : Id.t }
let read_ack_proof v =
  let f = fields v ["receipt"; "durable_record"] in
  { receipt = read_receipt_key (required f "receipt"); durable_record = id (required f "durable_record") }
let write_ack_proof p = record ["receipt", write_receipt_key p.receipt; "durable_record", js (Id.get p.durable_record)]

(* ---- NativeBudget（rmcp-8 §3.5） ---- *)
type checkpoint_limits = { bundle_bytes : U.t; metadata_bytes : U.t; root_count : U.t }
let read_checkpoint_limits v =
  let f = fields v ["bundle_bytes"; "metadata_bytes"; "root_count"] in
  let pos n = if U.get n < 1L then bad Constraint else n in
  { bundle_bytes = pos (uint (required f "bundle_bytes")); metadata_bytes = pos (uint (required f "metadata_bytes"));
    root_count = pos (uint (required f "root_count")) }
let write_checkpoint_limits l = record ["bundle_bytes", ji (U.get l.bundle_bytes);
  "metadata_bytes", ji (U.get l.metadata_bytes); "root_count", ji (U.get l.root_count)]

type control_operation = Export | Import
let control_operation_table = ["export", Export; "import", Import]
type native_purpose = Task | CheckpointControl of { control : Id.t; operation : control_operation; attempt : Id.t }
let read_native_purpose v = match string (required (object_ v) "kind") with
  | "task" -> ignore (fields v ["kind"]); Task
  | "checkpoint_control" ->
      let f = fields v ["kind"; "control"; "operation"; "attempt"] in
      CheckpointControl { control = id (required f "control");
        operation = read_enum control_operation_table (required f "operation"); attempt = id (required f "attempt") }
  | _ -> bad Invalid_tag
let write_native_purpose = function
  | Task -> record ["kind", js "task"]
  | CheckpointControl p -> record ["kind", js "checkpoint_control"; "control", js (Id.get p.control);
      "operation", write_enum control_operation_table p.operation; "attempt", js (Id.get p.attempt)]

type initial_native_method =
  | ImBeginLine | ImSelectLine | ImEndScope | ImLocateContext | ImForkLine | ImSyncSource
  | ImRefreshEnvironment | ImQuery | ImInspect | ImCheckpointObserve | ImCheckpointExport
  | ImCheckpointImport | ImCheckpointActivate
let initial_native_method_table = [
  "begin_line", ImBeginLine; "select_line", ImSelectLine; "end_scope", ImEndScope;
  "locate_context", ImLocateContext; "fork_line", ImForkLine; "sync_source", ImSyncSource;
  "refresh_environment", ImRefreshEnvironment; "query", ImQuery; "inspect", ImInspect;
  "checkpoint_observe", ImCheckpointObserve; "checkpoint_export", ImCheckpointExport;
  "checkpoint_import", ImCheckpointImport; "checkpoint_activate", ImCheckpointActivate]
type initial_request_binding = { irb_method : initial_native_method; phase : initial_phase; digest : Digest.t }
let read_initial_request_binding v =
  let f = fields v ["method"; "phase"; "digest"] in
  { irb_method = read_enum initial_native_method_table (required f "method");
    phase = read_initial_phase (required f "phase");
    digest = get (Digest.make (string (required f "digest"))) }
let write_initial_request_binding b = record ["method", write_enum initial_native_method_table b.irb_method;
  "phase", write_initial_phase b.phase; "digest", js (Digest.get b.digest)]

type native_budget = {
  budget : Id.t; operation : Id.t; operation_seq : U.t; scope : Id.t; source : Id.t;
  environment : Id.t; grant : Id.t; grant_revision : U.t; clock_boot : Id.t;
  execution_deadline_us : U.t; recovery_deadline_us : U.t; output_deadline_us : U.t;
  output_bytes : U.t; purpose : native_purpose;
  checkpoint_limits : checkpoint_limits known_or_na; initial_request : initial_request_binding }
let read_native_budget v =
  let f = fields v ["budget"; "operation"; "operation_seq"; "scope"; "source"; "environment"; "grant";
    "grant_revision"; "clock_boot"; "execution_deadline_us"; "recovery_deadline_us";
    "output_deadline_us"; "output_bytes"; "purpose"; "checkpoint_limits"; "initial_request"] in
  { budget = id (required f "budget"); operation = id (required f "operation");
    operation_seq = uint (required f "operation_seq"); scope = id (required f "scope");
    source = id (required f "source"); environment = id (required f "environment");
    grant = id (required f "grant"); grant_revision = uint (required f "grant_revision");
    clock_boot = id (required f "clock_boot"); execution_deadline_us = uint (required f "execution_deadline_us");
    recovery_deadline_us = uint (required f "recovery_deadline_us"); output_deadline_us = uint (required f "output_deadline_us");
    output_bytes = uint (required f "output_bytes"); purpose = read_native_purpose (required f "purpose");
    checkpoint_limits = read_known_or_na read_checkpoint_limits (required f "checkpoint_limits");
    initial_request = read_initial_request_binding (required f "initial_request") }
let write_native_budget (b : native_budget) = record ["budget", js (Id.get b.budget); "operation", js (Id.get b.operation);
  "operation_seq", ji (U.get b.operation_seq); "scope", js (Id.get b.scope); "source", js (Id.get b.source);
  "environment", js (Id.get b.environment); "grant", js (Id.get b.grant); "grant_revision", ji (U.get b.grant_revision);
  "clock_boot", js (Id.get b.clock_boot); "execution_deadline_us", ji (U.get b.execution_deadline_us);
  "recovery_deadline_us", ji (U.get b.recovery_deadline_us); "output_deadline_us", ji (U.get b.output_deadline_us);
  "output_bytes", ji (U.get b.output_bytes); "purpose", write_native_purpose b.purpose;
  "checkpoint_limits", write_known_or_na write_checkpoint_limits b.checkpoint_limits;
  "initial_request", write_initial_request_binding b.initial_request]

(* ---- 选择器 ---- *)
type query_selector = { selector_source : Id.t; selector_range : byte_range }
let read_query_selector v =
  if string (required (object_ v) "kind") <> "query_text" then bad Invalid_tag;
  let f = fields v ["kind"; "source"; "range"] in
  { selector_source = id (required f "source"); selector_range = read_byte_range (required f "range") }
let write_query_selector s = record ["kind", js "query_text"; "source", js (Id.get s.selector_source);
  "range", write_byte_range s.selector_range]

type goal_group = Focused | StackLeft | StackRight | Shelved | GivenUp
let goal_group_table = ["focused", Focused; "stack_left", StackLeft; "stack_right", StackRight; "shelved", Shelved; "given_up", GivenUp]
type goal_selector = { selector_group : goal_group; depth : U.t; index : U.t }
let read_goal_selector v =
  let f = fields v ["group"; "depth"; "index"] in
  let sel = { selector_group = read_enum goal_group_table (required f "group");
    depth = uint (required f "depth"); index = uint (required f "index") } in
  (* 与Rust端既审值域一致（B05局部）：非stack组depth必须为0。 *)
  (match sel.selector_group with
   | StackLeft | StackRight -> ()
   | _ -> if U.get sel.depth <> 0L then bad Constraint);
  sel
let write_goal_selector s = record ["group", write_enum goal_group_table s.selector_group;
  "depth", ji (U.get s.depth); "index", ji (U.get s.index)]

type goal_part = Conclusion | Hypothesis of U.t
let read_goal_part v = match string (required (object_ v) "kind") with
  | "conclusion" -> ignore (fields v ["kind"]); Conclusion
  | "hypothesis" -> Hypothesis (uint (required (fields v ["kind"; "index"]) "index"))
  | _ -> bad Invalid_tag
let write_goal_part = function
  | Conclusion -> record ["kind", js "conclusion"]
  | Hypothesis index -> record ["kind", js "hypothesis"; "index", ji (U.get index)]

(* InspectSelector唯一复用rmcp-6 §5六分支，native不另造同名；goal_roster的cursor可缺。 *)
type inspect_kind = IkAssumptions | IkToc | IkNotations | IkEnvironment | IkGoalRoster | IkGoalPart
let inspect_kind_table = ["assumptions", IkAssumptions; "toc", IkToc; "notations", IkNotations;
  "environment", IkEnvironment; "goal_roster", IkGoalRoster; "goal_part", IkGoalPart]
type inspect_selector =
  | Assumptions of Text.t list
  | Toc | Notations | Environment
  | GoalRoster of cursor option
  | GoalPartSel of goal_selector * goal_part * byte_range
let read_inspect_selector v = match string (required (object_ v) "kind") with
  | "assumptions" ->
      let f = fields v ["kind"; "constants"] in
      let items = match view (required f "constants") with
        | View_array values -> values | _ -> bad Type_mismatch in
      let length = List.length items in
      if length < 1 || length > 65536 then bad Constraint;
      let constants = List.rev (List.rev_map text items) in
      (* 与Rust端既审值域一致（DistinctConstants）：常量去重检测。 *)
      let rec has_dup = function
        | [] | [_] -> false
        | x :: rest -> List.mem x rest || has_dup rest in
      if has_dup constants then bad Constraint;
      Assumptions constants
  | "toc" -> ignore (fields v ["kind"]); Toc
  | "notations" -> ignore (fields v ["kind"]); Notations
  | "environment" -> ignore (fields v ["kind"]); Environment
  | "goal_roster" ->
      let f = fields_opt v ["kind"] ["cursor"] in
      GoalRoster (opt_field read_cursor f "cursor")
  | "goal_part" ->
      let f = fields v ["kind"; "goal"; "part"; "range"] in
      GoalPartSel (read_goal_selector (required f "goal"), read_goal_part (required f "part"),
        read_byte_range (required f "range"))
  | _ -> bad Invalid_tag
let write_inspect_selector = function
  | Assumptions constants -> record ["kind", js "assumptions";
      "constants", array_value (List.rev (List.rev_map (fun c -> js (Text.get c)) constants))]
  | Toc -> record ["kind", js "toc"]
  | Notations -> record ["kind", js "notations"]
  | Environment -> record ["kind", js "environment"]
  | GoalRoster cursor -> (match cursor with
    | None -> record ["kind", js "goal_roster"]
    | Some c -> record ["kind", js "goal_roster"; "cursor", write_cursor c])
  | GoalPartSel (goal, part, range) -> record ["kind", js "goal_part";
      "goal", write_goal_selector goal; "part", write_goal_part part; "range", write_byte_range range]

(* ---- 普通请求Args与联合 ---- *)
type args_begin_line = {
  binding : op_binding; line : Id.t; expected_revision : U.t;
  edit : native_edit; script_source : Id.t }
let read_args_begin_line v =
  let f = fields v ["binding"; "line"; "expected_revision"; "edit"; "script_source"] in
  { binding = read_op_binding (required f "binding"); line = id (required f "line");
    expected_revision = uint (required f "expected_revision"); edit = read_native_edit (required f "edit");
    script_source = id (required f "script_source") }
let write_args_begin_line a = record ["binding", write_op_binding a.binding; "line", js (Id.get a.line);
  "expected_revision", ji (U.get a.expected_revision); "edit", write_native_edit a.edit;
  "script_source", js (Id.get a.script_source)]

type args_select_line = {
  sl_binding : op_binding; destination : Id.t; sl_expected_revision : U.t; candidate : Id.t;
  group : native_group_version known_or_na; durable_path : Id.t }
let read_args_select_line v =
  let f = fields v ["binding"; "destination"; "expected_revision"; "candidate"; "group"; "durable_path"] in
  { sl_binding = read_op_binding (required f "binding"); destination = id (required f "destination");
    sl_expected_revision = uint (required f "expected_revision"); candidate = id (required f "candidate");
    group = read_known_or_na read_native_group_version (required f "group");
    durable_path = id (required f "durable_path") }
let write_args_select_line a = record ["binding", write_op_binding a.sl_binding;
  "destination", js (Id.get a.destination); "expected_revision", ji (U.get a.sl_expected_revision);
  "candidate", js (Id.get a.candidate); "group", write_known_or_na write_native_group_version a.group;
  "durable_path", js (Id.get a.durable_path)]

(* Step P1: 区分 MS27 逻辑目标身份与 NN01 选择器。 *)
type args_locate_context = {
  lc_binding : op_binding; file : Id.t; relative_file : string;
  target : native_target; logical_target : Id.t;
  lineage : native_version known_or_na; expected_context : native_version known_or_na }
let read_args_locate_context v =
  let f = fields v ["binding"; "file"; "relative_file"; "target"; "logical_target"; "lineage"; "expected_context"] in
  { lc_binding = read_op_binding (required f "binding"); file = id (required f "file");
    relative_file = rel_path (required f "relative_file");
    target = read_native_target (required f "target");
    logical_target = id (required f "logical_target");
    lineage = read_known_or_na read_native_version (required f "lineage");
    expected_context = read_known_or_na read_native_version (required f "expected_context") }
let write_args_locate_context a = record ["binding", write_op_binding a.lc_binding;
  "file", js (Id.get a.file); "relative_file", js a.relative_file; "target", write_native_target a.target;
  "logical_target", js (Id.get a.logical_target);
  "lineage", write_known_or_na write_native_version a.lineage;
  "expected_context", write_known_or_na write_native_version a.expected_context]

type args_query = { q_binding : op_binding; node : Id.t; selector : query_selector; output_budget : Id.t }
let read_args_query v =
  let f = fields v ["binding"; "node"; "selector"; "output_budget"] in
  { q_binding = read_op_binding (required f "binding"); node = id (required f "node");
    selector = read_query_selector (required f "selector"); output_budget = id (required f "output_budget") }
let write_args_query a = record ["binding", write_op_binding a.q_binding; "node", js (Id.get a.node);
  "selector", write_query_selector a.selector; "output_budget", js (Id.get a.output_budget)]

type args_inspect = { i_binding : op_binding; i_node : Id.t; i_selector : inspect_selector; i_output_budget : Id.t }
let read_args_inspect v =
  let f = fields v ["binding"; "node"; "selector"; "output_budget"] in
  { i_binding = read_op_binding (required f "binding"); i_node = id (required f "node");
    i_selector = read_inspect_selector (required f "selector"); i_output_budget = id (required f "output_budget") }
let write_args_inspect a = record ["binding", write_op_binding a.i_binding; "node", js (Id.get a.i_node);
  "selector", write_inspect_selector a.i_selector; "output_budget", js (Id.get a.i_output_budget)]

type args_pull_step = { ps_binding : op_binding; expected_step_seq : U.t }
let read_args_pull_step v =
  let f = fields v ["binding"; "expected_step_seq"] in
  let seq = uint (required f "expected_step_seq") in
  if U.get seq < 1L then bad Constraint;
  { ps_binding = read_op_binding (required f "binding"); expected_step_seq = seq }
let write_args_pull_step a = record ["binding", write_op_binding a.ps_binding;
  "expected_step_seq", ji (U.get a.expected_step_seq)]

type args_ack_step = { as_binding : op_binding; proof : ack_proof }
let read_args_ack_step v =
  let f = fields v ["binding"; "proof"] in
  { as_binding = read_op_binding (required f "binding"); proof = read_ack_proof (required f "proof") }
let write_args_ack_step a = record ["binding", write_op_binding a.as_binding; "proof", write_ack_proof a.proof]

type args_register_budget = { budget : native_budget; applied_grant : Id.t }
let read_args_register_budget v =
  let f = fields v ["budget"; "applied_grant"] in
  { budget = read_native_budget (required f "budget"); applied_grant = id (required f "applied_grant") }
let write_args_register_budget (a : args_register_budget) = record ["budget", write_native_budget a.budget;
  "applied_grant", js (Id.get a.applied_grant)]

type args_refresh_environment = {
  re_binding : op_binding; old_environment : Id.t; new_environment : Id.t; publication : Id.t }
let read_args_refresh_environment v =
  let f = fields v ["binding"; "old_environment"; "new_environment"; "publication"] in
  { re_binding = read_op_binding (required f "binding"); old_environment = id (required f "old_environment");
    new_environment = id (required f "new_environment"); publication = id (required f "publication") }
let write_args_refresh_environment a = record ["binding", write_op_binding a.re_binding;
  "old_environment", js (Id.get a.old_environment); "new_environment", js (Id.get a.new_environment);
  "publication", js (Id.get a.publication)]

type args_binding_only = { binding : op_binding }
let read_args_binding_only v =
  let f = fields v ["binding"] in
  { binding = read_op_binding (required f "binding") }
let write_args_binding_only (a : args_binding_only) = record ["binding", write_op_binding a.binding]

type args_finish_operation = { fo_binding : op_binding; terminal_receipt_key : receipt_key }
let read_args_finish_operation v =
  let f = fields v ["binding"; "terminal_receipt_key"] in
  { fo_binding = read_op_binding (required f "binding");
    terminal_receipt_key = read_receipt_key (required f "terminal_receipt_key") }
let write_args_finish_operation a = record ["binding", write_op_binding a.fo_binding;
  "terminal_receipt_key", write_receipt_key a.terminal_receipt_key]

type args_end_scope = { es_binding : op_binding; es_scope : Id.t; es_expected_revision : U.t }
let read_args_end_scope v =
  let f = fields v ["binding"; "scope"; "expected_revision"] in
  { es_binding = read_op_binding (required f "binding"); es_scope = id (required f "scope");
    es_expected_revision = uint (required f "expected_revision") }
let write_args_end_scope a = record ["binding", write_op_binding a.es_binding;
  "scope", js (Id.get a.es_scope); "expected_revision", ji (U.get a.es_expected_revision)]

type args_retire_through = { through : U.t }
let read_args_retire_through v =
  let f = fields v ["through"] in
  { through = uint (required f "through") }
let write_args_retire_through a = record ["through", ji (U.get a.through)]

type args_sync_source = {
  ss_binding : op_binding; ss_context : Id.t; ss_expected_context : native_version;
  old_source : Id.t; new_source : Id.t; ss_publication : Id.t }
let read_args_sync_source v =
  let f = fields v ["binding"; "context"; "expected_context"; "old_source"; "new_source"; "publication"] in
  { ss_binding = read_op_binding (required f "binding"); ss_context = id (required f "context");
    ss_expected_context = read_native_version (required f "expected_context");
    old_source = id (required f "old_source"); new_source = id (required f "new_source");
    ss_publication = id (required f "publication") }
let write_args_sync_source a = record ["binding", write_op_binding a.ss_binding;
  "context", js (Id.get a.ss_context); "expected_context", write_native_version a.ss_expected_context;
  "old_source", js (Id.get a.old_source); "new_source", js (Id.get a.new_source);
  "publication", js (Id.get a.ss_publication)]

(* ---- T2b并入：checkpoint/fork_line包装（rmcp-8 §3.1表）----
   artifact_kind/artifact_ref自下方AuxValue家族上移到此（checkpoint包装args
   引用它；上移不改定义与语义）。 *)

type artifact_kind =
  | CkSelection | CkRequirements | CkPlan | CkManifest | CkMap | CkBundle
  | CkCompatibility | CkObservation | CkPreloadPlan
let artifact_kind_table = [
  "checkpoint_selection", CkSelection; "checkpoint_requirements", CkRequirements;
  "checkpoint_plan", CkPlan; "checkpoint_manifest", CkManifest; "checkpoint_map", CkMap;
  "checkpoint_bundle", CkBundle; "checkpoint_compatibility", CkCompatibility;
  "checkpoint_observation", CkObservation; "checkpoint_preload_plan", CkPreloadPlan]
type artifact_ref = { artifact_id : Id.t; artifact_digest : Digest.t; artifact_bytes : U.t; artifact_kind : artifact_kind }
let read_artifact_ref v =
  let f = fields v ["id"; "digest"; "bytes"; "kind"] in
  { artifact_id = id (required f "id"); artifact_digest = get (Digest.make (string (required f "digest")));
    artifact_bytes = uint (required f "bytes"); artifact_kind = read_enum artifact_kind_table (required f "kind") }
let write_artifact_ref a = record ["id", js (Id.get a.artifact_id); "digest", js (Digest.get a.artifact_digest);
  "bytes", ji (U.get a.artifact_bytes); "kind", write_enum artifact_kind_table a.artifact_kind]

type args_fork_line = {
  fl_binding : op_binding; fl_parent : Id.t; expected_line : native_version;
  new_line : Id.t; exploration : Id.t }
let read_args_fork_line v =
  let f = fields v ["binding"; "parent"; "expected_line"; "new_line"; "exploration"] in
  { fl_binding = read_op_binding (required f "binding"); fl_parent = id (required f "parent");
    expected_line = read_native_version (required f "expected_line");
    new_line = id (required f "new_line"); exploration = id (required f "exploration") }
let write_args_fork_line a = record ["binding", write_op_binding a.fl_binding;
  "parent", js (Id.get a.fl_parent); "expected_line", write_native_version a.expected_line;
  "new_line", js (Id.get a.new_line); "exploration", js (Id.get a.exploration)]

(* preload恰known/not_applicable两支（oneOf无unknown分支）：unknown=CONSTRAINT、
   未登记=INVALID_TAG，与known_or_na同域；export必须N/A、import必须known且
   kind=checkpoint_preload_plan归消费者。 *)
type args_checkpoint_observe = {
  co_binding : op_binding; co_control : Id.t; co_attempt : Id.t;
  preload : artifact_ref known_or_na }
let read_args_checkpoint_observe v =
  let f = fields v ["binding"; "control"; "attempt"; "preload"] in
  { co_binding = read_op_binding (required f "binding"); co_control = id (required f "control");
    co_attempt = id (required f "attempt");
    preload = read_known_or_na read_artifact_ref (required f "preload") }
let write_args_checkpoint_observe a = record ["binding", write_op_binding a.co_binding;
  "control", js (Id.get a.co_control); "attempt", js (Id.get a.co_attempt);
  "preload", write_known_or_na write_artifact_ref a.preload]

(* M4 PS30唯一生产（rmcp-8 §3.5）；只绑定首次接受的activate operation（消费者）。 *)
type activation_permit = {
  activation_id : Id.t; ap_control_id : Id.t; ap_cache_id : Id.t;
  import_operation : Id.t; import_receipt_key : receipt_key;
  ap_instance : Id.t; ap_backend_epoch : U.t; ap_manager_epoch : U.t; binding_revision : U.t }
let read_activation_permit v =
  let f = fields v ["activation_id"; "control_id"; "cache_id"; "import_operation";
    "import_receipt_key"; "instance"; "backend_epoch"; "manager_epoch"; "binding_revision"] in
  { activation_id = id (required f "activation_id"); ap_control_id = id (required f "control_id");
    ap_cache_id = id (required f "cache_id"); import_operation = id (required f "import_operation");
    import_receipt_key = read_receipt_key (required f "import_receipt_key");
    ap_instance = id (required f "instance"); ap_backend_epoch = uint (required f "backend_epoch");
    ap_manager_epoch = uint (required f "manager_epoch"); binding_revision = uint (required f "binding_revision") }
let write_activation_permit p = record ["activation_id", js (Id.get p.activation_id);
  "control_id", js (Id.get p.ap_control_id); "cache_id", js (Id.get p.ap_cache_id);
  "import_operation", js (Id.get p.import_operation);
  "import_receipt_key", write_receipt_key p.import_receipt_key;
  "instance", js (Id.get p.ap_instance); "backend_epoch", ji (U.get p.ap_backend_epoch);
  "manager_epoch", ji (U.get p.ap_manager_epoch); "binding_revision", ji (U.get p.binding_revision)]

(* checkpoint_export两phase分支是schema两个wrapper；phase是per-branch常量先于
   字段集：错phase=INVALID_TAG、缺phase=MISSING_FIELD。 *)
type args_checkpoint_export_collect = {
  ec_binding : op_binding; ec_control : Id.t; ec_attempt : Id.t;
  selection : artifact_ref; ec_group : Id.t; ec_compatibility : artifact_ref }
let read_args_checkpoint_export_collect v =
  if string (required (object_ v) "phase") <> "collect" then bad Invalid_tag;
  let f = fields v ["binding"; "phase"; "control"; "attempt"; "selection"; "group"; "compatibility"] in
  { ec_binding = read_op_binding (required f "binding"); ec_control = id (required f "control");
    ec_attempt = id (required f "attempt"); selection = read_artifact_ref (required f "selection");
    ec_group = id (required f "group"); ec_compatibility = read_artifact_ref (required f "compatibility") }
let write_args_checkpoint_export_collect a = record ["binding", write_op_binding a.ec_binding;
  "phase", js "collect"; "control", js (Id.get a.ec_control); "attempt", js (Id.get a.ec_attempt);
  "selection", write_artifact_ref a.selection; "group", js (Id.get a.ec_group);
  "compatibility", write_artifact_ref a.ec_compatibility]

type args_checkpoint_export_encode = {
  ee_binding : op_binding; ee_control : Id.t; ee_attempt : Id.t;
  plan : artifact_ref; requirements : artifact_ref;
  ee_group : Id.t; ee_compatibility : artifact_ref }
let read_args_checkpoint_export_encode v =
  if string (required (object_ v) "phase") <> "encode" then bad Invalid_tag;
  let f = fields v ["binding"; "phase"; "control"; "attempt"; "plan"; "requirements"; "group"; "compatibility"] in
  { ee_binding = read_op_binding (required f "binding"); ee_control = id (required f "control");
    ee_attempt = id (required f "attempt"); plan = read_artifact_ref (required f "plan");
    requirements = read_artifact_ref (required f "requirements");
    ee_group = id (required f "group"); ee_compatibility = read_artifact_ref (required f "compatibility") }
let write_args_checkpoint_export_encode a = record ["binding", write_op_binding a.ee_binding;
  "phase", js "encode"; "control", js (Id.get a.ee_control); "attempt", js (Id.get a.ee_attempt);
  "plan", write_artifact_ref a.plan; "requirements", write_artifact_ref a.requirements;
  "group", js (Id.get a.ee_group); "compatibility", write_artifact_ref a.ee_compatibility]

(* export两phase在native_request内共享method判别，args层按phase常量二分发。 *)
type args_checkpoint_export =
  | ExportCollect of args_checkpoint_export_collect
  | ExportEncode of args_checkpoint_export_encode
let read_args_checkpoint_export v = match string (required (object_ v) "phase") with
  | "collect" -> ExportCollect (read_args_checkpoint_export_collect v)
  | "encode" -> ExportEncode (read_args_checkpoint_export_encode v)
  | _ -> bad Invalid_tag
let write_args_checkpoint_export = function
  | ExportCollect a -> write_args_checkpoint_export_collect a
  | ExportEncode a -> write_args_checkpoint_export_encode a

type args_checkpoint_import = {
  ci_binding : op_binding; ci_control : Id.t; ci_attempt : Id.t; ci_cache : Id.t;
  ci_plan : artifact_ref; ci_group : Id.t; ci_manifest : artifact_ref;
  ci_bundle : artifact_ref; ci_compatibility : artifact_ref }
let read_args_checkpoint_import v =
  let f = fields v ["binding"; "control"; "attempt"; "cache"; "plan"; "group"; "manifest"; "bundle"; "compatibility"] in
  { ci_binding = read_op_binding (required f "binding"); ci_control = id (required f "control");
    ci_attempt = id (required f "attempt"); ci_cache = id (required f "cache");
    ci_plan = read_artifact_ref (required f "plan"); ci_group = id (required f "group");
    ci_manifest = read_artifact_ref (required f "manifest"); ci_bundle = read_artifact_ref (required f "bundle");
    ci_compatibility = read_artifact_ref (required f "compatibility") }
let write_args_checkpoint_import a = record ["binding", write_op_binding a.ci_binding;
  "control", js (Id.get a.ci_control); "attempt", js (Id.get a.ci_attempt);
  "cache", js (Id.get a.ci_cache); "plan", write_artifact_ref a.ci_plan;
  "group", js (Id.get a.ci_group); "manifest", write_artifact_ref a.ci_manifest;
  "bundle", write_artifact_ref a.ci_bundle; "compatibility", write_artifact_ref a.ci_compatibility]

type args_checkpoint_activate = {
  ca_binding : op_binding; ca_import_receipt : receipt_key;
  activation : activation_permit; ca_mapping : artifact_ref }
let read_args_checkpoint_activate v =
  let f = fields v ["binding"; "import_receipt"; "activation"; "mapping"] in
  { ca_binding = read_op_binding (required f "binding");
    ca_import_receipt = read_receipt_key (required f "import_receipt");
    activation = read_activation_permit (required f "activation");
    ca_mapping = read_artifact_ref (required f "mapping") }
let write_args_checkpoint_activate a = record ["binding", write_op_binding a.ca_binding;
  "import_receipt", write_receipt_key a.ca_import_receipt;
  "activation", write_activation_permit a.activation; "mapping", write_artifact_ref a.ca_mapping]

(* method判别：20普通方法、schema恰21个wrapper（checkpoint_export两phase分支）。 *)
type native_request =
  | BeginLine of header * args_begin_line
  | PullStep of header * args_pull_step
  | AckStep of header * args_ack_step
  | OperationStatus of header * args_binding_only
  | SelectLine of header * args_select_line
  | EndScope of header * args_end_scope
  | SettleInterrupt of header * args_binding_only
  | FinishOperation of header * args_finish_operation
  | RetireThrough of header * args_retire_through
  | LocateContext of header * args_locate_context
  | SyncSource of header * args_sync_source
  | RefreshEnvironment of header * args_refresh_environment
  | Query of header * args_query
  | Inspect of header * args_inspect
  | RegisterBudget of header * args_register_budget
  | ForkLine of header * args_fork_line
  | CheckpointObserve of header * args_checkpoint_observe
  | CheckpointExport of header * args_checkpoint_export
  | CheckpointImport of header * args_checkpoint_import
  | CheckpointActivate of header * args_checkpoint_activate
let read_native_request v = protect (fun () ->
  match string (required (object_ v) "method") with
  | "begin_line" ->
      let f = fields v ["method"; "header"; "args"] in
      BeginLine (read_header (required f "header"), read_args_begin_line (required f "args"))
  | "pull_step" ->
      let f = fields v ["method"; "header"; "args"] in
      PullStep (read_header (required f "header"), read_args_pull_step (required f "args"))
  | "ack_step" ->
      let f = fields v ["method"; "header"; "args"] in
      AckStep (read_header (required f "header"), read_args_ack_step (required f "args"))
  | "operation_status" ->
      let f = fields v ["method"; "header"; "args"] in
      OperationStatus (read_header (required f "header"), read_args_binding_only (required f "args"))
  | "select_line" ->
      let f = fields v ["method"; "header"; "args"] in
      SelectLine (read_header (required f "header"), read_args_select_line (required f "args"))
  | "end_scope" ->
      let f = fields v ["method"; "header"; "args"] in
      EndScope (read_header (required f "header"), read_args_end_scope (required f "args"))
  | "settle_interrupt" ->
      let f = fields v ["method"; "header"; "args"] in
      SettleInterrupt (read_header (required f "header"), read_args_binding_only (required f "args"))
  | "finish_operation" ->
      let f = fields v ["method"; "header"; "args"] in
      FinishOperation (read_header (required f "header"), read_args_finish_operation (required f "args"))
  | "retire_through" ->
      let f = fields v ["method"; "header"; "args"] in
      RetireThrough (read_header (required f "header"), read_args_retire_through (required f "args"))
  | "locate_context" ->
      let f = fields v ["method"; "header"; "args"] in
      LocateContext (read_header (required f "header"), read_args_locate_context (required f "args"))
  | "sync_source" ->
      let f = fields v ["method"; "header"; "args"] in
      SyncSource (read_header (required f "header"), read_args_sync_source (required f "args"))
  | "refresh_environment" ->
      let f = fields v ["method"; "header"; "args"] in
      RefreshEnvironment (read_header (required f "header"), read_args_refresh_environment (required f "args"))
  | "query" ->
      let f = fields v ["method"; "header"; "args"] in
      Query (read_header (required f "header"), read_args_query (required f "args"))
  | "inspect" ->
      let f = fields v ["method"; "header"; "args"] in
      Inspect (read_header (required f "header"), read_args_inspect (required f "args"))
  | "register_budget" ->
      let f = fields v ["method"; "header"; "args"] in
      RegisterBudget (read_header (required f "header"), read_args_register_budget (required f "args"))
  | "fork_line" ->
      let f = fields v ["method"; "header"; "args"] in
      ForkLine (read_header (required f "header"), read_args_fork_line (required f "args"))
  | "checkpoint_observe" ->
      let f = fields v ["method"; "header"; "args"] in
      CheckpointObserve (read_header (required f "header"), read_args_checkpoint_observe (required f "args"))
  | "checkpoint_export" ->
      let f = fields v ["method"; "header"; "args"] in
      CheckpointExport (read_header (required f "header"), read_args_checkpoint_export (required f "args"))
  | "checkpoint_import" ->
      let f = fields v ["method"; "header"; "args"] in
      CheckpointImport (read_header (required f "header"), read_args_checkpoint_import (required f "args"))
  | "checkpoint_activate" ->
      let f = fields v ["method"; "header"; "args"] in
      CheckpointActivate (read_header (required f "header"), read_args_checkpoint_activate (required f "args"))
  | _ -> bad Invalid_tag)
let request_method_name = function
  | BeginLine _ -> "begin_line" | PullStep _ -> "pull_step" | AckStep _ -> "ack_step"
  | OperationStatus _ -> "operation_status" | SelectLine _ -> "select_line" | EndScope _ -> "end_scope"
  | SettleInterrupt _ -> "settle_interrupt" | FinishOperation _ -> "finish_operation"
  | RetireThrough _ -> "retire_through" | LocateContext _ -> "locate_context"
  | SyncSource _ -> "sync_source" | RefreshEnvironment _ -> "refresh_environment"
  | Query _ -> "query" | Inspect _ -> "inspect" | RegisterBudget _ -> "register_budget"
  | ForkLine _ -> "fork_line" | CheckpointObserve _ -> "checkpoint_observe"
  | CheckpointExport _ -> "checkpoint_export" | CheckpointImport _ -> "checkpoint_import"
  | CheckpointActivate _ -> "checkpoint_activate"
let request_header = function
  | BeginLine (h, _) | PullStep (h, _) | AckStep (h, _) | OperationStatus (h, _)
  | SelectLine (h, _) | EndScope (h, _) | SettleInterrupt (h, _) | FinishOperation (h, _)
  | RetireThrough (h, _) | LocateContext (h, _) | SyncSource (h, _) | RefreshEnvironment (h, _)
  | Query (h, _) | Inspect (h, _) | RegisterBudget (h, _)
  | ForkLine (h, _) | CheckpointObserve (h, _) | CheckpointExport (h, _)
  | CheckpointImport (h, _) | CheckpointActivate (h, _) -> h
let write_request_args = function
  | BeginLine (_, a) -> write_args_begin_line a
  | PullStep (_, a) -> write_args_pull_step a
  | AckStep (_, a) -> write_args_ack_step a
  | OperationStatus (_, a) -> write_args_binding_only a
  | SelectLine (_, a) -> write_args_select_line a
  | EndScope (_, a) -> write_args_end_scope a
  | SettleInterrupt (_, a) -> write_args_binding_only a
  | FinishOperation (_, a) -> write_args_finish_operation a
  | RetireThrough (_, a) -> write_args_retire_through a
  | LocateContext (_, a) -> write_args_locate_context a
  | SyncSource (_, a) -> write_args_sync_source a
  | RefreshEnvironment (_, a) -> write_args_refresh_environment a
  | Query (_, a) -> write_args_query a
  | Inspect (_, a) -> write_args_inspect a
  | RegisterBudget (_, a) -> write_args_register_budget a
  | ForkLine (_, a) -> write_args_fork_line a
  | CheckpointObserve (_, a) -> write_args_checkpoint_observe a
  | CheckpointExport (_, a) -> write_args_checkpoint_export a
  | CheckpointImport (_, a) -> write_args_checkpoint_import a
  | CheckpointActivate (_, a) -> write_args_checkpoint_activate a
let native_request_to_json request = protect (fun () ->
  record ["method", js (request_method_name request); "header", write_header (request_header request);
    "args", write_request_args request])
let decode_native_request limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_native_request v
let native_request_header = request_header
let fact_unknown = FUnknown
let encode_native_request limits request =
  match native_request_to_json request with Error e -> Error e | Ok value -> canonical limits value

(* RC04 NativeOperation域：前像恰{header(version,instance,backend_epoch,manager_epoch),
   method,args}；rpc_seq不进摘要；仅删args顶层binding.request_digest一处、不递归删同名键；
   无binding的args原样保留（该删除步骤为no-op）。 *)
let strip_binding_request_digest args =
  match view args with
  | View_object fields_ ->
      (match StringMap.find_opt "binding" fields_ with
       | None -> args
       | Some binding ->
           (match view binding with
            | View_object binding_fields ->
                let kept = StringMap.filter (fun name _ -> name <> "request_digest") binding_fields in
                let others = StringMap.filter (fun name _ -> name <> "binding") fields_ in
                get (object_value (("binding", get (object_value (StringMap.bindings kept))) :: StringMap.bindings others))
            | _ -> bad Infrastructure))
  | _ -> bad Infrastructure
let native_operation_digest limits request = protect (fun () ->
  let header = request_header request in
  let preimage = record [
    "header", record ["version", ji 1L; "instance", js (Id.get header.instance);
      "backend_epoch", ji (U.get header.backend_epoch); "manager_epoch", ji (U.get header.manager_epoch)];
    "method", js (request_method_name request);
    "args", strip_binding_request_digest (write_request_args request)] in
  match canonical limits preimage with
  | Error e -> bad e
  | Ok bytes -> Strict_json.sha256 ("ccv-native-operation-v1\000" ^ bytes))

(* ---- 控制通道请求（rmcp-8 §3.4） ---- *)
type cancel_reason = ReasonCancel | Pressure | Deadline
let cancel_reason_table = ["cancel", ReasonCancel; "pressure", Pressure; "deadline", Deadline]
type cancel_args = { operation_id : Id.t; token_generation : U.t; cancel_seq : U.t; reason : cancel_reason }
type control_request =
  | ControlStatus of header * Id.t
  | Cancel of header * cancel_args
let read_control_request v = protect (fun () ->
  match string (required (object_ v) "action") with
  | "control_status" ->
      let f = fields v ["action"; "header"; "operation_id"] in
      ControlStatus (read_header (required f "header"), id (required f "operation_id"))
  | "cancel" ->
      let f = fields v ["action"; "header"; "operation_id"; "token_generation"; "cancel_seq"; "reason"] in
      Cancel (read_header (required f "header"),
        { operation_id = id (required f "operation_id"); token_generation = uint (required f "token_generation");
          cancel_seq = uint (required f "cancel_seq"); reason = read_enum cancel_reason_table (required f "reason") })
  | _ -> bad Invalid_tag)
let control_request_to_json = function
  | ControlStatus (h, operation_id) -> record ["action", js "control_status";
      "header", write_header h; "operation_id", js (Id.get operation_id)]
  | Cancel (h, c) -> record ["action", js "cancel"; "header", write_header h;
      "operation_id", js (Id.get c.operation_id); "token_generation", ji (U.get c.token_generation);
      "cancel_seq", ji (U.get c.cancel_seq); "reason", write_enum cancel_reason_table c.reason]
let decode_control_request limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_control_request v
let encode_control_request limits request =
  protect (fun () -> get (canonical limits (control_request_to_json request)))

(* ---- 步骤回执与状态（rmcp-8 §3.3） ---- *)
type native_op_state = Ready | Executing | WaitAck | TerminalState | Retiring
let native_op_state_table = ["READY", Ready; "EXECUTING", Executing; "WAIT_ACK", WaitAck; "TERMINAL", TerminalState; "RETIRING", Retiring]
type native_stage =
  | Parse | Execute | Register | Restore | StageView
  | CpCollect | CpEncode | CpDecode | CpValidate | CpActivate
let native_stage_table = ["parse", Parse; "execute", Execute; "register", Register; "restore", Restore;
  "view", StageView; "checkpoint_collect", CpCollect; "checkpoint_encode", CpEncode;
  "checkpoint_decode", CpDecode; "checkpoint_validate", CpValidate; "checkpoint_activate", CpActivate]

type step_fact = {
  parent : Id.t; node : Id.t; source : Id.t; command_start : U.t; command_end : U.t;
  next_cursor : U.t; line : Id.t; base_revision : U.t; step_seq : U.t }
let read_step_fact v =
  let f = fields v ["parent"; "node"; "source"; "command_start"; "command_end"; "next_cursor"; "line"; "base_revision"; "step_seq"] in
  { parent = id (required f "parent"); node = id (required f "node"); source = id (required f "source");
    command_start = uint (required f "command_start"); command_end = uint (required f "command_end");
    next_cursor = uint (required f "next_cursor"); line = id (required f "line");
    base_revision = uint (required f "base_revision"); step_seq = uint (required f "step_seq") }
let write_step_fact s = record ["parent", js (Id.get s.parent); "node", js (Id.get s.node);
  "source", js (Id.get s.source); "command_start", ji (U.get s.command_start);
  "command_end", ji (U.get s.command_end); "next_cursor", ji (U.get s.next_cursor);
  "line", js (Id.get s.line); "base_revision", ji (U.get s.base_revision); "step_seq", ji (U.get s.step_seq)]

type ack_status = { ack_receipt : receipt_key; ack_line : Id.t; line_revision : U.t; acked_through : U.t;
  ack_group : native_group_version known_or_na }
let read_ack_status v =
  let f = fields v ["receipt"; "line"; "line_revision"; "acked_through"; "group"] in
  { ack_receipt = read_receipt_key (required f "receipt"); ack_line = id (required f "line");
    line_revision = uint (required f "line_revision"); acked_through = uint (required f "acked_through");
    ack_group = read_known_or_na read_native_group_version (required f "group") }
let write_ack_status a = record ["receipt", write_receipt_key a.ack_receipt; "line", js (Id.get a.ack_line);
  "line_revision", ji (U.get a.line_revision); "acked_through", ji (U.get a.acked_through);
  "group", write_known_or_na write_native_group_version a.ack_group]

type ended_status = Closing | Closed
let ended_status_table = ["closing", Closing; "closed", Closed]

type receipt_payload =
  | Step of step_fact * Id.t fact
  | Selected of { line : Id.t; before_revision : U.t; after_revision : U.t; node : Id.t; group : native_group_version fact }
  | Ended of { scope : Id.t; status : ended_status; reclaim : Id.t fact }
  | Interrupted of { stopped : bool fact; synchronized : bool fact; last_acked : Id.t fact;
                     pending : Id.t fact; recoverable : bool fact; diagnostic : Id.t fact }
  | PayloadError of { stage : native_stage; diagnostic : Id.t fact; last_valid : Id.t fact;
                      group : native_group_version known_or_na }
let read_receipt_payload v = match string (required (object_ v) "kind") with
  | "step" ->
      let f = fields v ["kind"; "fact"; "view"] in
      Step (read_step_fact (required f "fact"), read_fact id (required f "view"))
  | "selected" ->
      let f = fields v ["kind"; "line"; "before_revision"; "after_revision"; "node"; "group"] in
      Selected { line = id (required f "line"); before_revision = uint (required f "before_revision");
        after_revision = uint (required f "after_revision"); node = id (required f "node");
        group = read_fact read_native_group_version (required f "group") }
  | "ended" ->
      let f = fields v ["kind"; "scope"; "status"; "reclaim"] in
      Ended { scope = id (required f "scope"); status = read_enum ended_status_table (required f "status");
        reclaim = read_fact id (required f "reclaim") }
  | "interrupted" ->
      let f = fields v ["kind"; "stopped"; "synchronized"; "last_acked"; "pending"; "recoverable"; "diagnostic"] in
      Interrupted { stopped = read_fact boolean (required f "stopped");
        synchronized = read_fact boolean (required f "synchronized");
        last_acked = read_fact id (required f "last_acked"); pending = read_fact id (required f "pending");
        recoverable = read_fact boolean (required f "recoverable"); diagnostic = read_fact id (required f "diagnostic") }
  | "error" ->
      let f = fields v ["kind"; "stage"; "diagnostic"; "last_valid"; "group"] in
      PayloadError { stage = read_enum native_stage_table (required f "stage");
        diagnostic = read_fact id (required f "diagnostic"); last_valid = read_fact id (required f "last_valid");
        group = read_known_or_na read_native_group_version (required f "group") }
  | _ -> bad Invalid_tag
let write_receipt_payload = function
  | Step (fact, view_) -> record ["kind", js "step"; "fact", write_step_fact fact; "view", write_fact write_id view_]
  | Selected s -> record ["kind", js "selected"; "line", js (Id.get s.line);
      "before_revision", ji (U.get s.before_revision); "after_revision", ji (U.get s.after_revision);
      "node", js (Id.get s.node); "group", write_fact write_native_group_version s.group]
  | Ended e -> record ["kind", js "ended"; "scope", js (Id.get e.scope);
      "status", write_enum ended_status_table e.status; "reclaim", write_fact write_id e.reclaim]
  | Interrupted i -> record ["kind", js "interrupted";
      "stopped", write_fact (fun b -> bool_value b) i.stopped;
      "synchronized", write_fact (fun b -> bool_value b) i.synchronized;
      "last_acked", write_fact write_id i.last_acked; "pending", write_fact write_id i.pending;
      "recoverable", write_fact (fun b -> bool_value b) i.recoverable; "diagnostic", write_fact write_id i.diagnostic]
  | PayloadError e -> record ["kind", js "error"; "stage", write_enum native_stage_table e.stage;
      "diagnostic", write_fact write_id e.diagnostic; "last_valid", write_fact write_id e.last_valid;
      "group", write_known_or_na write_native_group_version e.group]

type receipt = { key : receipt_key; binding : op_binding; execution_extent : extent; payload : receipt_payload }
let read_receipt v =
  let f = fields v ["key"; "binding"; "execution_extent"; "payload"] in
  { key = read_receipt_key (required f "key"); binding = read_op_binding (required f "binding");
    execution_extent = read_extent (required f "execution_extent"); payload = read_receipt_payload (required f "payload") }
let write_receipt r = record ["key", write_receipt_key r.key; "binding", write_op_binding r.binding;
  "execution_extent", write_extent r.execution_extent; "payload", write_receipt_payload r.payload]

(* RC04 ccv-native-receipt-v1域（rmcp-8 §3.1）：前像=完整Receipt规范编码仅排
   顶层key.digest一处，不递归删除同名键、不额外包一层外壳；与Rust端同构。 *)
let strip_receipt_key_digest value = protect (fun () ->
  match view value with
  | View_object fields_ ->
      (match StringMap.find_opt "key" fields_ with
       | None -> bad Infrastructure
       | Some key ->
           (match view key with
            | View_object key_fields ->
                let kept = StringMap.filter (fun name _ -> name <> "digest") key_fields in
                let others = StringMap.filter (fun name _ -> name <> "key") fields_ in
                get (object_value (("key", get (object_value (StringMap.bindings kept))) :: StringMap.bindings others))
            | _ -> bad Infrastructure))
  | _ -> bad Infrastructure)
let native_record_digest limits value =
  match strip_receipt_key_digest value with
  | Error e -> Error e
  | Ok preimage ->
      (match canonical limits preimage with
       | Error e -> Error e
        | Ok bytes -> Ok (Strict_json.sha256 ("ccv-native-receipt-v1\000" ^ bytes)))
let native_receipt_digest limits receipt = native_record_digest limits (write_receipt receipt)

(* Completion两常量（reason=eof、extent=complete_known）按schema const拒绝异值。 *)
type completion = { completion_key : receipt_key; completion_acked_through : U.t; completion_cursor : U.t }
let read_completion v =
  let f = fields v ["key"; "reason"; "acked_through"; "cursor"; "execution_extent"] in
  if string (required f "reason") <> "eof" then bad Invalid_tag;
  if string (required f "execution_extent") <> "complete_known" then bad Invalid_tag;
  { completion_key = read_receipt_key (required f "key");
    completion_acked_through = uint (required f "acked_through"); completion_cursor = uint (required f "cursor") }
let write_completion c = record ["key", write_receipt_key c.completion_key; "reason", js "eof";
  "acked_through", ji (U.get c.completion_acked_through); "cursor", ji (U.get c.completion_cursor);
  "execution_extent", js "complete_known"]

type prefix_completion = {
  prefix_key : receipt_key; prefix_target : Id.t;
  prefix_acked_through : U.t; prefix_cursor : U.t
}
let read_prefix_completion v =
  let f = fields v ["key"; "reason"; "target"; "acked_through"; "cursor"; "execution_extent"] in
  if string (required f "reason") <> "prefix_reached" then bad Invalid_tag;
  if string (required f "execution_extent") <> "complete_known" then bad Invalid_tag;
  { prefix_key = read_receipt_key (required f "key"); prefix_target = id (required f "target");
    prefix_acked_through = uint (required f "acked_through"); prefix_cursor = uint (required f "cursor") }
let write_prefix_completion c = record ["key", write_receipt_key c.prefix_key; "reason", js "prefix_reached";
  "target", js (Id.get c.prefix_target); "acked_through", ji (U.get c.prefix_acked_through);
  "cursor", ji (U.get c.prefix_cursor); "execution_extent", js "complete_known"]

type terminal_record = TrReceipt of receipt | TrEof of completion | TrPrefixReached of prefix_completion
let read_terminal_record v = match string (required (object_ v) "kind") with
  | "receipt" -> TrReceipt (read_receipt (required (fields v ["kind"; "receipt"]) "receipt"))
  | "eof" -> TrEof (read_completion (required (fields v ["kind"; "completion"]) "completion"))
  | "prefix_reached" -> TrPrefixReached (read_prefix_completion (required (fields v ["kind"; "completion"]) "completion"))
  | _ -> bad Invalid_tag
let write_terminal_record = function
  | TrReceipt r -> record ["kind", js "receipt"; "receipt", write_receipt r]
  | TrEof c -> record ["kind", js "eof"; "completion", write_completion c]
  | TrPrefixReached c -> record ["kind", js "prefix_reached"; "completion", write_prefix_completion c]
(* ---- AuxTerminal与AuxValue家族 ----
   artifact_kind/artifact_ref已上移至T2b并入段（checkpoint包装args引用）。 *)

type view_format = FormatText | TypedFacts
let view_format_table = ["text", FormatText; "typed_facts", TypedFacts]
type capture_failure = ProducerFailed | TransportGap | BudgetExhausted | StorageFailed | Expired | InvalidEncoding
let capture_failure_table = ["producer_failed", ProducerFailed; "transport_gap", TransportGap;
  "budget_exhausted", BudgetExhausted; "storage_failed", StorageFailed; "expired", Expired;
  "invalid_encoding", InvalidEncoding]
type capture_status = {
  complete : bool; captured_bytes : U.t; total_bytes : U.t fact; capture_digest : Digest.t fact;
  missing_ranges : byte_range list; reason : capture_failure fact }

let make_capture_status ~complete ~captured_bytes ~total_bytes ~digest ~missing_ranges ~reason =
  protect (fun () ->
    if List.length missing_ranges > 65536 then bad Constraint;
    let missing_ranges = List.rev (List.rev_map (fun (range_start, range_end) ->
      if U.get range_start > U.get range_end then bad Constraint;
      { range_start; range_end }) missing_ranges) in
    { complete; captured_bytes; total_bytes; capture_digest = digest; missing_ranges; reason })

let read_capture_status v =
  let f = fields v ["complete"; "captured_bytes"; "total_bytes"; "digest"; "missing_ranges"; "reason"] in
  let ranges = match view (required f "missing_ranges") with
    | View_array values -> values | _ -> bad Type_mismatch in
  if List.length ranges > 65536 then bad Constraint;
  { complete = boolean (required f "complete"); captured_bytes = uint (required f "captured_bytes");
    total_bytes = read_fact uint (required f "total_bytes");
    capture_digest = read_fact (fun d -> get (Digest.make (string d))) (required f "digest");
    missing_ranges = List.rev (List.rev_map read_byte_range ranges);
    reason = read_fact (read_enum capture_failure_table) (required f "reason") }
let write_capture_status c = record ["complete", bool_value c.complete;
  "captured_bytes", ji (U.get c.captured_bytes); "total_bytes", write_fact write_uint c.total_bytes;
  "digest", write_fact write_digest c.capture_digest;
  "missing_ranges", array_value (List.rev (List.rev_map write_byte_range c.missing_ranges));
  "reason", write_fact (write_enum capture_failure_table) c.reason]
let decode_capture_status limits raw =
  match decode limits raw with Error e -> Error e | Ok v ->
    protect (fun () -> read_capture_status v)
let encode_capture_status limits value =
  protect (fun () -> get (canonical limits (write_capture_status value)))

type view_descriptor = {
  vd_view : native_view_ref; vd_operation : Id.t; vd_node : Id.t; vd_source : Id.t;
  vd_environment : Id.t; format : view_format; facts_kind : inspect_kind fact; capture : capture_status }
let read_view_descriptor v =
  let f = fields v ["schema_version"; "view"; "operation"; "node"; "source"; "environment"; "format"; "facts_kind"; "capture"] in
  (match view (required f "schema_version") with
   | View_integer 1L -> () | View_integer _ -> bad Constraint | _ -> bad Type_mismatch);
  { vd_view = read_native_view_ref (required f "view"); vd_operation = id (required f "operation");
    vd_node = id (required f "node"); vd_source = id (required f "source");
    vd_environment = id (required f "environment"); format = read_enum view_format_table (required f "format");
    facts_kind = read_fact (read_enum inspect_kind_table) (required f "facts_kind");
    capture = read_capture_status (required f "capture") }
let write_view_descriptor d = record ["schema_version", ji 1L; "view", write_native_view_ref d.vd_view;
  "operation", js (Id.get d.vd_operation); "node", js (Id.get d.vd_node); "source", js (Id.get d.vd_source);
  "environment", js (Id.get d.vd_environment); "format", write_enum view_format_table d.format;
  "facts_kind", write_fact (write_enum inspect_kind_table) d.facts_kind; "capture", write_capture_status d.capture]

(* 恰十二分支（六辅助+五checkpoint+error）；各checkpoint方法允许的value子集归消费者。 *)
type aux_value =
  | Located of { context : Id.t; line : Id.t; node : Id.t; revision : U.t; cursor : U.t;
                 boundary : native_boundary_fact fact }
  | NeedsPrefix of { context : Id.t; line : Id.t; node : Id.t; revision : U.t; cursor : U.t;
                     target : native_target; boundary : native_boundary_fact fact }
  | Forked of { line : Id.t; node : Id.t; revision : U.t; group : native_group_version }
  | SourceSynced of { context : Id.t; revision : U.t; source : Id.t; last_valid : Id.t fact;
                      reclaim : Id.t; boundary : native_boundary_fact fact; line_updates : native_line_update_ref }
  | EnvironmentRefreshed of { environment : Id.t; changed : bool; reclaim : Id.t fact }
  | ViewValue of { descriptor : view_descriptor }
  | CheckpointObserved of { control : Id.t; attempt : Id.t; observation : artifact_ref }
  | CheckpointCollected of { control : Id.t; attempt : Id.t; selection : artifact_ref;
                             group : Id.t; requirements : artifact_ref }
  | CheckpointExported of { control : Id.t; attempt : Id.t; plan : artifact_ref; group : Id.t;
                            manifest : artifact_ref; bundle : artifact_ref; compatibility : artifact_ref }
  | CheckpointImported of { control : Id.t; attempt : Id.t; cache : Id.t; group : Id.t;
                            manifest : artifact_ref; mapping : artifact_ref; compatibility : artifact_ref }
  | CheckpointActivated of { import_receipt : receipt_key; activation_id : Id.t;
                             cache : Id.t; group : Id.t; mapping : artifact_ref }
  | AuxError of { stage : native_stage; diagnostic : Id.t fact; last_valid : Id.t fact }
let read_aux_value v = match string (required (object_ v) "kind") with
  | "located" ->
      let f = fields v ["kind"; "context"; "line"; "node"; "revision"; "cursor"; "boundary"] in
      Located { context = id (required f "context"); line = id (required f "line"); node = id (required f "node");
        revision = uint (required f "revision"); cursor = uint (required f "cursor");
        boundary = read_fact read_native_boundary_fact (required f "boundary") }
  | "needs_prefix" ->
      let f = fields v ["kind"; "context"; "line"; "node"; "revision"; "cursor"; "target"; "boundary"] in
      NeedsPrefix { context = id (required f "context"); line = id (required f "line"); node = id (required f "node");
        revision = uint (required f "revision"); cursor = uint (required f "cursor");
        target = read_native_target (required f "target");
        boundary = read_fact read_native_boundary_fact (required f "boundary") }
  | "forked" ->
      let f = fields v ["kind"; "line"; "node"; "revision"; "group"] in
      Forked { line = id (required f "line"); node = id (required f "node"); revision = uint (required f "revision");
        group = read_native_group_version (required f "group") }
  | "source_synced" ->
      let f = fields v ["kind"; "context"; "revision"; "source"; "last_valid"; "reclaim"; "boundary"; "line_updates"] in
      SourceSynced { context = id (required f "context"); revision = uint (required f "revision");
        source = id (required f "source"); last_valid = read_fact id (required f "last_valid");
        reclaim = id (required f "reclaim"); boundary = read_fact read_native_boundary_fact (required f "boundary");
        line_updates = read_native_line_update_ref (required f "line_updates") }
  | "environment_refreshed" ->
      let f = fields v ["kind"; "environment"; "changed"; "reclaim"] in
      EnvironmentRefreshed { environment = id (required f "environment"); changed = boolean (required f "changed");
        reclaim = read_fact id (required f "reclaim") }
  | "view" ->
      ViewValue { descriptor = read_view_descriptor (required (fields v ["kind"; "descriptor"]) "descriptor") }
  | "checkpoint_observed" ->
      let f = fields v ["kind"; "control"; "attempt"; "observation"] in
      CheckpointObserved { control = id (required f "control"); attempt = id (required f "attempt");
        observation = read_artifact_ref (required f "observation") }
  | "checkpoint_collected" ->
      let f = fields v ["kind"; "control"; "attempt"; "selection"; "group"; "requirements"] in
      CheckpointCollected { control = id (required f "control"); attempt = id (required f "attempt");
        selection = read_artifact_ref (required f "selection"); group = id (required f "group");
        requirements = read_artifact_ref (required f "requirements") }
  | "checkpoint_exported" ->
      let f = fields v ["kind"; "control"; "attempt"; "plan"; "group"; "manifest"; "bundle"; "compatibility"] in
      CheckpointExported { control = id (required f "control"); attempt = id (required f "attempt");
        plan = read_artifact_ref (required f "plan"); group = id (required f "group");
        manifest = read_artifact_ref (required f "manifest"); bundle = read_artifact_ref (required f "bundle");
        compatibility = read_artifact_ref (required f "compatibility") }
  | "checkpoint_imported" ->
      let f = fields v ["kind"; "control"; "attempt"; "cache"; "group"; "manifest"; "mapping"; "compatibility"] in
      CheckpointImported { control = id (required f "control"); attempt = id (required f "attempt");
        cache = id (required f "cache"); group = id (required f "group");
        manifest = read_artifact_ref (required f "manifest"); mapping = read_artifact_ref (required f "mapping");
        compatibility = read_artifact_ref (required f "compatibility") }
  | "checkpoint_activated" ->
      let f = fields v ["kind"; "import_receipt"; "activation_id"; "cache"; "group"; "mapping"] in
      CheckpointActivated { import_receipt = read_receipt_key (required f "import_receipt");
        activation_id = id (required f "activation_id"); cache = id (required f "cache");
        group = id (required f "group"); mapping = read_artifact_ref (required f "mapping") }
  | "error" ->
      let f = fields v ["kind"; "stage"; "diagnostic"; "last_valid"] in
      AuxError { stage = read_enum native_stage_table (required f "stage");
        diagnostic = read_fact id (required f "diagnostic"); last_valid = read_fact id (required f "last_valid") }
  | _ -> bad Invalid_tag
let write_aux_value = function
  | Located a -> record ["kind", js "located"; "context", js (Id.get a.context); "line", js (Id.get a.line);
      "node", js (Id.get a.node); "revision", ji (U.get a.revision); "cursor", ji (U.get a.cursor);
      "boundary", write_fact write_native_boundary_fact a.boundary]
  | NeedsPrefix a -> record ["kind", js "needs_prefix"; "context", js (Id.get a.context); "line", js (Id.get a.line);
      "node", js (Id.get a.node); "revision", ji (U.get a.revision); "cursor", ji (U.get a.cursor);
      "target", write_native_target a.target; "boundary", write_fact write_native_boundary_fact a.boundary]
  | Forked a -> record ["kind", js "forked"; "line", js (Id.get a.line); "node", js (Id.get a.node);
      "revision", ji (U.get a.revision); "group", write_native_group_version a.group]
  | SourceSynced a -> record ["kind", js "source_synced"; "context", js (Id.get a.context);
      "revision", ji (U.get a.revision); "source", js (Id.get a.source); "last_valid", write_fact write_id a.last_valid;
      "reclaim", js (Id.get a.reclaim); "boundary", write_fact write_native_boundary_fact a.boundary;
      "line_updates", write_native_line_update_ref a.line_updates]
  | EnvironmentRefreshed a -> record ["kind", js "environment_refreshed"; "environment", js (Id.get a.environment);
      "changed", bool_value a.changed; "reclaim", write_fact write_id a.reclaim]
  | ViewValue a -> record ["kind", js "view"; "descriptor", write_view_descriptor a.descriptor]
  | CheckpointObserved a -> record ["kind", js "checkpoint_observed"; "control", js (Id.get a.control);
      "attempt", js (Id.get a.attempt); "observation", write_artifact_ref a.observation]
  | CheckpointCollected a -> record ["kind", js "checkpoint_collected"; "control", js (Id.get a.control);
      "attempt", js (Id.get a.attempt); "selection", write_artifact_ref a.selection;
      "group", js (Id.get a.group); "requirements", write_artifact_ref a.requirements]
  | CheckpointExported a -> record ["kind", js "checkpoint_exported"; "control", js (Id.get a.control);
      "attempt", js (Id.get a.attempt); "plan", write_artifact_ref a.plan; "group", js (Id.get a.group);
      "manifest", write_artifact_ref a.manifest; "bundle", write_artifact_ref a.bundle;
      "compatibility", write_artifact_ref a.compatibility]
  | CheckpointImported a -> record ["kind", js "checkpoint_imported"; "control", js (Id.get a.control);
      "attempt", js (Id.get a.attempt); "cache", js (Id.get a.cache); "group", js (Id.get a.group);
      "manifest", write_artifact_ref a.manifest; "mapping", write_artifact_ref a.mapping;
      "compatibility", write_artifact_ref a.compatibility]
  | CheckpointActivated a -> record ["kind", js "checkpoint_activated";
      "import_receipt", write_receipt_key a.import_receipt; "activation_id", js (Id.get a.activation_id);
      "cache", js (Id.get a.cache); "group", js (Id.get a.group); "mapping", write_artifact_ref a.mapping]
  | AuxError a -> record ["kind", js "error"; "stage", write_enum native_stage_table a.stage;
      "diagnostic", write_fact write_id a.diagnostic; "last_valid", write_fact write_id a.last_valid]

(* AuxTerminal的kind是固定常量。 *)
type aux_terminal = { aux_key : receipt_key; aux_binding : op_binding; aux_extent : extent; value : aux_value }
let read_aux_terminal v =
  ignore (object_ v);
  if string (required (object_ v) "kind") <> "aux" then bad Invalid_tag;
  let f = fields v ["kind"; "key"; "binding"; "execution_extent"; "value"] in
  { aux_key = read_receipt_key (required f "key"); aux_binding = read_op_binding (required f "binding");
    aux_extent = read_extent (required f "execution_extent"); value = read_aux_value (required f "value") }
let write_aux_terminal t = record ["kind", js "aux"; "key", write_receipt_key t.aux_key;
  "binding", write_op_binding t.aux_binding; "execution_extent", write_extent t.aux_extent;
  "value", write_aux_value t.value]

(* 步骤终态与 aux 的 tag 互不重叠。 *)
type any_terminal = TerminalValue of terminal_record | AuxValueCase of aux_terminal
let read_any_terminal v = match string (required (object_ v) "kind") with
  | "receipt" | "eof" | "prefix_reached" -> TerminalValue (read_terminal_record v)
  | "aux" -> AuxValueCase (read_aux_terminal v)
  | _ -> bad Invalid_tag
let write_any_terminal = function
  | TerminalValue t -> write_terminal_record t
  | AuxValueCase t -> write_aux_terminal t

type op_status = {
  status_binding : op_binding; state : native_op_state; pending : receipt fact;
  terminal : any_terminal fact; status_acked_through : U.t; highest_seen : U.t;
  retired_through : U.t; last_ack : ack_status fact; stop_requested : bool }
let read_op_status v =
  let f = fields v ["binding"; "state"; "pending"; "terminal"; "acked_through"; "highest_seen"; "retired_through"; "last_ack"; "stop_requested"] in
  { status_binding = read_op_binding (required f "binding"); state = read_enum native_op_state_table (required f "state");
    pending = read_fact read_receipt (required f "pending"); terminal = read_fact read_any_terminal (required f "terminal");
    status_acked_through = uint (required f "acked_through"); highest_seen = uint (required f "highest_seen");
    retired_through = uint (required f "retired_through"); last_ack = read_fact read_ack_status (required f "last_ack");
    stop_requested = boolean (required f "stop_requested") }
let write_op_status s = record ["binding", write_op_binding s.status_binding;
  "state", write_enum native_op_state_table s.state; "pending", write_fact write_receipt s.pending;
  "terminal", write_fact write_any_terminal s.terminal; "acked_through", ji (U.get s.status_acked_through);
  "highest_seen", ji (U.get s.highest_seen); "retired_through", ji (U.get s.retired_through);
  "last_ack", write_fact write_ack_status s.last_ack; "stop_requested", bool_value s.stop_requested]

(* ---- 结果联合（外层恰十kind） ---- *)
type native_code =
  | InvalidInput | WrongEpoch | BindingConflict | SequenceGap | Capacity
  | StaleRevision | UnknownOperation | InvalidState
let native_code_table = ["invalid_input", InvalidInput; "wrong_epoch", WrongEpoch;
  "binding_conflict", BindingConflict; "sequence_gap", SequenceGap; "capacity", Capacity;
  "stale_revision", StaleRevision; "unknown_operation", UnknownOperation; "invalid_state", InvalidState]
type admission = NotAdmitted | ExistingOperation | AdmissionUnknown
let admission_table = ["not_admitted", NotAdmitted; "existing_operation", ExistingOperation; "unknown", AdmissionUnknown]
let invalid_input = InvalidInput
let unknown_operation = UnknownOperation
let binding_conflict = BindingConflict
let invalid_state = InvalidState
let not_admitted = NotAdmitted
type native_protocol_error = { code : native_code; admission : admission; diagnostic : Id.t fact }
let read_native_protocol_error v =
  let f = fields v ["code"; "admission"; "diagnostic"] in
  { code = read_enum native_code_table (required f "code"); admission = read_enum admission_table (required f "admission");
    diagnostic = read_fact id (required f "diagnostic") }
let write_native_protocol_error e = record ["code", write_enum native_code_table e.code;
  "admission", write_enum admission_table e.admission; "diagnostic", write_fact write_id e.diagnostic]

type native_result =
  | StatusResult of op_status
  | ReceiptResult of receipt
  | TerminalResult of terminal_record
  | AuxTerminalResult of aux_terminal
  | AckResult of ack_status
  | Finished of receipt_key
  | Retired of U.t
  | PastUnavailable of { operation_seq : U.t; highest_seen : U.t }
  | RetiredStep of U.t
  | BudgetRegistered of { budget : Id.t; grant : Id.t; grant_revision : U.t }
let read_native_result v = match string (required (object_ v) "kind") with
  | "status" -> StatusResult (read_op_status (required (fields v ["kind"; "status"]) "status"))
  | "receipt" -> ReceiptResult (read_receipt (required (fields v ["kind"; "receipt"]) "receipt"))
  | "terminal" -> TerminalResult (read_terminal_record (required (fields v ["kind"; "terminal"]) "terminal"))
  | "aux_terminal" -> AuxTerminalResult (read_aux_terminal (required (fields v ["kind"; "terminal"]) "terminal"))
  | "ack" -> AckResult (read_ack_status (required (fields v ["kind"; "ack"]) "ack"))
  | "finished" -> Finished (read_receipt_key (required (fields v ["kind"; "key"]) "key"))
  | "retired" -> Retired (uint (required (fields v ["kind"; "through"]) "through"))
  | "past_unavailable" ->
      let f = fields v ["kind"; "operation_seq"; "highest_seen"] in
      PastUnavailable { operation_seq = uint (required f "operation_seq"); highest_seen = uint (required f "highest_seen") }
  | "retired_step" -> RetiredStep (uint (required (fields v ["kind"; "acked_through"]) "acked_through"))
  | "budget_registered" ->
      let f = fields v ["kind"; "budget"; "grant"; "grant_revision"] in
      BudgetRegistered { budget = id (required f "budget"); grant = id (required f "grant");
        grant_revision = uint (required f "grant_revision") }
  | _ -> bad Invalid_tag
let write_native_result = function
  | StatusResult s -> record ["kind", js "status"; "status", write_op_status s]
  | ReceiptResult r -> record ["kind", js "receipt"; "receipt", write_receipt r]
  | TerminalResult t -> record ["kind", js "terminal"; "terminal", write_terminal_record t]
  | AuxTerminalResult t -> record ["kind", js "aux_terminal"; "terminal", write_aux_terminal t]
  | AckResult a -> record ["kind", js "ack"; "ack", write_ack_status a]
  | Finished k -> record ["kind", js "finished"; "key", write_receipt_key k]
  | Retired through -> record ["kind", js "retired"; "through", ji (U.get through)]
  | PastUnavailable p -> record ["kind", js "past_unavailable"; "operation_seq", ji (U.get p.operation_seq);
      "highest_seen", ji (U.get p.highest_seen)]
  | RetiredStep acked -> record ["kind", js "retired_step"; "acked_through", ji (U.get acked)]
  | BudgetRegistered b -> record ["kind", js "budget_registered"; "budget", js (Id.get b.budget);
      "grant", js (Id.get b.grant); "grant_revision", ji (U.get b.grant_revision)]

type native_reply = NativeResult of header * native_result | NativeProtocolError of header * native_protocol_error
let make_protocol_error header code admission diagnostic =
  NativeProtocolError (header, { code; admission; diagnostic })
let read_native_reply v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      NativeResult (read_header (required f "header"), read_native_result (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      NativeProtocolError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let native_reply_to_json = function
  | NativeResult (h, r) -> record ["kind", js "result"; "header", write_header h; "result", write_native_result r]
  | NativeProtocolError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_native_reply limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_native_reply v
let encode_native_reply limits reply =
  protect (fun () -> get (canonical limits (native_reply_to_json reply)))

(* ---- 控制通道回复 ---- *)
type control_phase = Idle | Active | Settling | TerminalPhase
let control_phase_table = ["idle", Idle; "active", Active; "settling", Settling; "terminal", TerminalPhase]
type control_snapshot = {
  operation_id : Id.t; phase : control_phase; token_generation : U.t;
  highest_cancel_seq : U.t; stop_requested : bool }
let read_control_snapshot v =
  let f = fields v ["operation_id"; "phase"; "token_generation"; "highest_cancel_seq"; "stop_requested"] in
  { operation_id = id (required f "operation_id"); phase = read_enum control_phase_table (required f "phase");
    token_generation = uint (required f "token_generation"); highest_cancel_seq = uint (required f "highest_cancel_seq");
    stop_requested = boolean (required f "stop_requested") }
let write_control_snapshot (s : control_snapshot) = record ["operation_id", js (Id.get s.operation_id);
  "phase", write_enum control_phase_table s.phase; "token_generation", ji (U.get s.token_generation);
  "highest_cancel_seq", ji (U.get s.highest_cancel_seq); "stop_requested", bool_value s.stop_requested]

type cancel_ack_status = ReceivedAck | AlreadyTerminal | PastCancel | Stale
let cancel_ack_status_table = ["received", ReceivedAck; "already_terminal", AlreadyTerminal;
  "past_cancel", PastCancel; "stale", Stale]
type control_result =
  | SnapshotResult of control_snapshot
  | CancelAck of { status : cancel_ack_status; snapshot : control_snapshot }
  | UnknownOperation of Id.t
let read_control_result v = match string (required (object_ v) "kind") with
  | "snapshot" -> SnapshotResult (read_control_snapshot (required (fields v ["kind"; "snapshot"]) "snapshot"))
  | "cancel_ack" ->
      let f = fields v ["kind"; "status"; "snapshot"] in
      CancelAck { status = read_enum cancel_ack_status_table (required f "status");
        snapshot = read_control_snapshot (required f "snapshot") }
  | "unknown_operation" -> UnknownOperation (id (required (fields v ["kind"; "operation_id"]) "operation_id"))
  | _ -> bad Invalid_tag
let write_control_result = function
  | SnapshotResult s -> record ["kind", js "snapshot"; "snapshot", write_control_snapshot s]
  | CancelAck c -> record ["kind", js "cancel_ack"; "status", write_enum cancel_ack_status_table c.status;
      "snapshot", write_control_snapshot c.snapshot]
  | UnknownOperation operation_id -> record ["kind", js "unknown_operation"; "operation_id", js (Id.get operation_id)]

type control_reply = ControlResultValue of header * control_result | ControlProtocolError of header * native_protocol_error
let read_control_reply v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      ControlResultValue (read_header (required f "header"), read_control_result (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      ControlProtocolError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let control_reply_to_json = function
  | ControlResultValue (h, r) -> record ["kind", js "result"; "header", write_header h; "result", write_control_result r]
  | ControlProtocolError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_control_reply limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_control_reply v
let encode_control_reply limits reply =
  protect (fun () -> get (canonical limits (control_reply_to_json reply)))

type control_request_view = ReadControl of Id.t | RequestCancel of Id.t * U.t * U.t
let control_request_view = function
  | ControlStatus (h, operation) -> h, ReadControl operation
  | Cancel (h, c) -> h, RequestCancel (c.operation_id, c.token_generation, c.cancel_seq)

let make_control_snapshot ~operation_id ~phase ~token_generation ~highest_cancel_seq ~stop_requested =
  { operation_id; phase; token_generation; highest_cancel_seq; stop_requested }
let control_snapshot header snapshot = ControlResultValue (header, SnapshotResult snapshot)
let control_unknown_operation header operation = ControlResultValue (header, UnknownOperation operation)
let control_cancel_ack header status snapshot = ControlResultValue (header, CancelAck { status; snapshot })

(* ---- T2b：source/view/blob通道、checkpoint记录族、facts文档、原生记录、兼容快照 ----
    通道method↔result子集、字节精确界、跨记录引用一致归消费者（W01–W04/NB03/
    NC02/NC06）；此处只封字段集/枚举exact-set/常量/数组上下界/Base64与credit值域，
    与Rust端nativeface_b.rs逐检查同构（双端一致纪律）。 *)

(* 通用助手 *)
let schema1 v = match view v with
  | View_integer 1L -> () | View_integer _ -> bad Constraint | _ -> bad Type_mismatch
let read_list read v = match view v with
  | View_array values -> List.rev (List.rev_map read values)
  | _ -> bad Type_mismatch
let bound_list maximum lst = if List.length lst > maximum then bad Constraint; lst
let min1_list lst = match lst with [] -> bad Constraint | _ -> lst
(* 纯数据值（无浮点/闭包）上Marshal串相等⇔结构相等：65536级数组的线性去重。 *)
let unique_list lst =
  let seen = Hashtbl.create 1024 in
  List.iter (fun item ->
    let key = Marshal.to_string item [] in
    if Hashtbl.mem seen key then bad Constraint;
    Hashtbl.replace seen key ()) lst;
  lst
let b64_digit = function
  | 'A'..'Z' as c -> Some (Char.code c - 65)
  | 'a'..'z' as c -> Some (Char.code c - 97 + 26)
  | '0'..'9' as c -> Some (Char.code c - 48 + 52)
  | '+' -> Some 62 | '/' -> Some 63 | _ -> None
(* RFC4648标准alphabet、长度mod4、尾部至多2个'='、非零pad bits拒绝；空串只许
   Base64Bin（EOF空块）、Base64Src最低4字符（解码≥1字节的必要条件）。 *)
let check_b64 text minimum maximum =
  let n = String.length text in
  if n < minimum || n > maximum || n mod 4 <> 0 then bad Constraint;
  let rec count_pad index acc =
    if index >= 0 && text.[index] = '=' then count_pad (index - 1) (acc + 1) else acc in
  let pads = count_pad (n - 1) 0 in
  if pads > 2 then bad Constraint;
  let body_end = n - pads in
  String.iteri (fun index c ->
    if index < body_end then begin match b64_digit c with Some _ -> () | None -> bad Constraint end
    else if c <> '=' then bad Constraint) text;
  if pads >= 1 then begin
    match b64_digit text.[body_end - 1] with
    | None -> bad Constraint
    | Some value ->
        let mask = if pads = 1 then 3 else 15 in
        if value land mask <> 0 then bad Constraint
  end
let read_b64_src v = let text = string v in check_b64 text 4 10924; text
let read_b64_bin v = let text = string v in check_b64 text 0 10924; text
(* view credit=4..8192、blob credit=1..8192：两族界不同构（冻结负例钉住）。 *)
let read_credit lo hi v = let value = uint v in
  if U.get value < lo || U.get value > hi then bad Constraint; value
(* M4 Option<Id>编码（PS §3.2:150）：可缺≠null。 *)
let read_opt_id v = match string (required (object_ v) "kind") with
  | "none" -> ignore (fields v ["kind"]); None
  | "some" -> Some (id (required (fields v ["kind"; "value"]) "value"))
  | _ -> bad Invalid_tag
let write_opt_id = function
  | None -> record ["kind", js "none"]
  | Some value -> record ["kind", js "some"; "value", js (Id.get value)]
let decode_with read limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> protect (fun () -> read v)
let encode_with write limits value =
  protect (fun () -> get (canonical limits (write value)))

(* ---- source通道（native-driver §4.2.1） ---- *)

type args_source_begin = { sb_source : Id.t; sb_size : U.t; sb_digest : Digest.t }
let read_args_source_begin v =
  let f = fields v ["source"; "size"; "digest"] in
  { sb_source = id (required f "source"); sb_size = uint (required f "size");
    sb_digest = get (Digest.make (string (required f "digest"))) }
let write_args_source_begin a = record ["source", js (Id.get a.sb_source);
  "size", ji (U.get a.sb_size); "digest", js (Digest.get a.sb_digest)]

type args_source_chunk = { sk_source : Id.t; sk_offset : U.t; sk_bytes : string }
let read_args_source_chunk v =
  let f = fields v ["source"; "offset"; "bytes"] in
  { sk_source = id (required f "source"); sk_offset = uint (required f "offset");
    sk_bytes = read_b64_src (required f "bytes") }
let write_args_source_chunk a = record ["source", js (Id.get a.sk_source);
  "offset", ji (U.get a.sk_offset); "bytes", js a.sk_bytes]

type args_source_finish = { sf_source : Id.t }
let read_args_source_finish v =
  let f = fields v ["source"] in
  { sf_source = id (required f "source") }
let write_args_source_finish a = record ["source", js (Id.get a.sf_source)]

type source_request =
  | SourceBegin of header * args_source_begin
  | SourceChunk of header * args_source_chunk
  | SourceFinish of header * args_source_finish
let read_source_request v = protect (fun () ->
  match string (required (object_ v) "method") with
  | "source_begin" ->
      let f = fields v ["method"; "header"; "args"] in
      SourceBegin (read_header (required f "header"), read_args_source_begin (required f "args"))
  | "source_chunk" ->
      let f = fields v ["method"; "header"; "args"] in
      SourceChunk (read_header (required f "header"), read_args_source_chunk (required f "args"))
  | "source_finish" ->
      let f = fields v ["method"; "header"; "args"] in
      SourceFinish (read_header (required f "header"), read_args_source_finish (required f "args"))
  | _ -> bad Invalid_tag)
let source_request_method = function
  | SourceBegin _ -> "source_begin" | SourceChunk _ -> "source_chunk" | SourceFinish _ -> "source_finish"
let source_request_header = function
  | SourceBegin (h, _) | SourceChunk (h, _) | SourceFinish (h, _) -> h
let write_source_request_args = function
  | SourceBegin (_, a) -> write_args_source_begin a
  | SourceChunk (_, a) -> write_args_source_chunk a
  | SourceFinish (_, a) -> write_args_source_finish a
let source_request_to_json request = protect (fun () ->
  record ["method", js (source_request_method request);
    "header", write_header (source_request_header request);
    "args", write_source_request_args request])
let decode_source_request limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_source_request v
let encode_source_request limits request =
  match source_request_to_json request with Error e -> Error e | Ok value -> canonical limits value

(* 每方法允许的result子集（begin→begun|registered等）归通道消费者。 *)
type source_result =
  | SrcBegun of { src : Id.t; next_offset : U.t }
  | SrcChunkAck of { src : Id.t; offset : U.t; end_offset : U.t; ack_digest : Digest.t }
  | SrcRegistered of { src : Id.t; size : U.t; reg_digest : Digest.t }
  | SrcRetiredChunk of { src : Id.t; next_offset : U.t }
let read_source_result v = match string (required (object_ v) "kind") with
  | "begun" -> let f = fields v ["kind"; "source"; "next_offset"] in
      SrcBegun { src = id (required f "source"); next_offset = uint (required f "next_offset") }
  | "chunk_ack" -> let f = fields v ["kind"; "source"; "offset"; "end_offset"; "digest"] in
      SrcChunkAck { src = id (required f "source"); offset = uint (required f "offset");
        end_offset = uint (required f "end_offset");
        ack_digest = get (Digest.make (string (required f "digest"))) }
  | "registered" -> let f = fields v ["kind"; "source"; "size"; "digest"] in
      SrcRegistered { src = id (required f "source"); size = uint (required f "size");
        reg_digest = get (Digest.make (string (required f "digest"))) }
  | "retired_chunk" -> let f = fields v ["kind"; "source"; "next_offset"] in
      SrcRetiredChunk { src = id (required f "source"); next_offset = uint (required f "next_offset") }
  | _ -> bad Invalid_tag
let write_source_result = function
  | SrcBegun r -> record ["kind", js "begun"; "source", js (Id.get r.src);
      "next_offset", ji (U.get r.next_offset)]
  | SrcChunkAck r -> record ["kind", js "chunk_ack"; "source", js (Id.get r.src);
      "offset", ji (U.get r.offset); "end_offset", ji (U.get r.end_offset);
      "digest", js (Digest.get r.ack_digest)]
  | SrcRegistered r -> record ["kind", js "registered"; "source", js (Id.get r.src);
      "size", ji (U.get r.size); "digest", js (Digest.get r.reg_digest)]
  | SrcRetiredChunk r -> record ["kind", js "retired_chunk"; "source", js (Id.get r.src);
      "next_offset", ji (U.get r.next_offset)]

type native_source_reply =
  | SourceReplyResult of header * source_result
  | SourceReplyError of header * native_protocol_error
let read_native_source_reply v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      SourceReplyResult (read_header (required f "header"), read_source_result (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      SourceReplyError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let native_source_reply_to_json = function
  | SourceReplyResult (h, r) -> record ["kind", js "result"; "header", write_header h;
      "result", write_source_result r]
  | SourceReplyError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_source_reply limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_native_source_reply v
let encode_source_reply limits value = encode_with native_source_reply_to_json limits value

(* ---- view通道（build-output §3.5） ---- *)

type args_view_pull = {
  vp_view : native_view_ref; vp_operation : Id.t; expected_seq : U.t;
  vp_offset : U.t; credit_bytes : U.t }
let read_args_view_pull v =
  let f = fields v ["view"; "operation"; "expected_seq"; "offset"; "credit_bytes"] in
  { vp_view = read_native_view_ref (required f "view"); vp_operation = id (required f "operation");
    expected_seq = uint (required f "expected_seq"); vp_offset = uint (required f "offset");
    credit_bytes = read_credit 4L 8192L (required f "credit_bytes") }
let write_args_view_pull a = record ["view", write_native_view_ref a.vp_view;
  "operation", js (Id.get a.vp_operation); "expected_seq", ji (U.get a.expected_seq);
  "offset", ji (U.get a.vp_offset); "credit_bytes", ji (U.get a.credit_bytes)]

type args_view_ack = {
  va_view : native_view_ref; va_operation : Id.t; va_seq : U.t;
  va_end_offset : U.t; va_digest : Digest.t }
let read_args_view_ack v =
  let f = fields v ["view"; "operation"; "seq"; "end_offset"; "digest"] in
  { va_view = read_native_view_ref (required f "view"); va_operation = id (required f "operation");
    va_seq = uint (required f "seq"); va_end_offset = uint (required f "end_offset");
    va_digest = get (Digest.make (string (required f "digest"))) }
let write_args_view_ack a = record ["view", write_native_view_ref a.va_view;
  "operation", js (Id.get a.va_operation); "seq", ji (U.get a.va_seq);
  "end_offset", ji (U.get a.va_end_offset); "digest", js (Digest.get a.va_digest)]

type args_view_release = {
  vr_view : native_view_ref; vr_operation : Id.t; vr_last_acked : U.t fact }
let read_args_view_release v =
  let f = fields v ["view"; "operation"; "last_acked"] in
  { vr_view = read_native_view_ref (required f "view"); vr_operation = id (required f "operation");
    vr_last_acked = read_fact uint (required f "last_acked") }
let write_args_view_release a = record ["view", write_native_view_ref a.vr_view;
  "operation", js (Id.get a.vr_operation); "last_acked", write_fact write_uint a.vr_last_acked]

type view_request =
  | ViewPull of header * args_view_pull
  | ViewAck of header * args_view_ack
  | ViewRelease of header * args_view_release

type view_request_view =
  | PullViewRequest of header * Id.t * Id.t * U.t * U.t * U.t
  | AckViewRequest of header * Id.t * Id.t * U.t * U.t * Digest.t
  | ReleaseViewRequest of header * Id.t * Id.t * U.t fact

let view_request_view = function
  | ViewPull (h, a) ->
      PullViewRequest (h, a.vp_view.view_id, a.vp_operation, a.expected_seq, a.vp_offset, a.credit_bytes)
  | ViewAck (h, a) ->
      AckViewRequest (h, a.va_view.view_id, a.va_operation, a.va_seq, a.va_end_offset, a.va_digest)
  | ViewRelease (h, a) ->
      ReleaseViewRequest (h, a.vr_view.view_id, a.vr_operation, a.vr_last_acked)

let read_view_request v = protect (fun () ->
  match string (required (object_ v) "method") with
  | "view_pull" ->
      let f = fields v ["method"; "header"; "args"] in
      ViewPull (read_header (required f "header"), read_args_view_pull (required f "args"))
  | "view_ack" ->
      let f = fields v ["method"; "header"; "args"] in
      ViewAck (read_header (required f "header"), read_args_view_ack (required f "args"))
  | "view_release" ->
      let f = fields v ["method"; "header"; "args"] in
      ViewRelease (read_header (required f "header"), read_args_view_release (required f "args"))
  | _ -> bad Invalid_tag)
let view_request_method = function
  | ViewPull _ -> "view_pull" | ViewAck _ -> "view_ack" | ViewRelease _ -> "view_release"
let view_request_header = function
  | ViewPull (h, _) | ViewAck (h, _) | ViewRelease (h, _) -> h
let write_view_request_args = function
  | ViewPull (_, a) -> write_args_view_pull a
  | ViewAck (_, a) -> write_args_view_ack a
  | ViewRelease (_, a) -> write_args_view_release a
let view_request_to_json request = protect (fun () ->
  record ["method", js (view_request_method request);
    "header", write_header (view_request_header request);
    "args", write_view_request_args request])
let decode_view_request limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_view_request v
let encode_view_request limits request =
  match view_request_to_json request with Error e -> Error e | Ok value -> canonical limits value

type release_status = ClosingStatus | ReleasedStatus
let release_status_table = ["closing", ClosingStatus; "released", ReleasedStatus]
type native_view_chunk = {
  vc_view : native_view_ref; vc_operation : Id.t; vc_seq : U.t;
  vc_range : byte_range; vc_text : string; vc_end : bool; vc_capture : capture_status }
let read_native_view_chunk v =
  let f = fields v ["view"; "operation"; "seq"; "range"; "text"; "end"; "capture"] in
  (* 0..8192 UTF-8字节、可空终块；字节精确界=end-start归NB03消费者。 *)
  { vc_view = read_native_view_ref (required f "view"); vc_operation = id (required f "operation");
    vc_seq = uint (required f "seq"); vc_range = read_byte_range (required f "range");
    vc_text = view_text (required f "text"); vc_end = boolean (required f "end");
    vc_capture = read_capture_status (required f "capture") }
let write_native_view_chunk c = record ["view", write_native_view_ref c.vc_view;
  "operation", js (Id.get c.vc_operation); "seq", ji (U.get c.vc_seq);
  "range", write_byte_range c.vc_range; "text", js c.vc_text;
  "end", bool_value c.vc_end; "capture", write_capture_status c.vc_capture]

type native_view_retired = {
  vt_view : native_view_ref; vt_operation : Id.t; vt_requested_seq : U.t;
  vt_acked_through : U.t; vt_end_offset : U.t }
let read_native_view_retired v =
  let f = fields v ["view"; "operation"; "requested_seq"; "acked_through"; "end_offset"] in
  { vt_view = read_native_view_ref (required f "view"); vt_operation = id (required f "operation");
    vt_requested_seq = uint (required f "requested_seq"); vt_acked_through = uint (required f "acked_through");
    vt_end_offset = uint (required f "end_offset") }
let write_native_view_retired r = record ["view", write_native_view_ref r.vt_view;
  "operation", js (Id.get r.vt_operation); "requested_seq", ji (U.get r.vt_requested_seq);
  "acked_through", ji (U.get r.vt_acked_through); "end_offset", ji (U.get r.vt_end_offset)]

type native_view_ack_result = {
  vack_view : native_view_ref; vack_operation : Id.t; vack_seq : U.t; vack_end_offset : U.t }
let read_native_view_ack_result v =
  let f = fields v ["view"; "operation"; "seq"; "end_offset"] in
  { vack_view = read_native_view_ref (required f "view"); vack_operation = id (required f "operation");
    vack_seq = uint (required f "seq"); vack_end_offset = uint (required f "end_offset") }
let write_native_view_ack_result a = record ["view", write_native_view_ref a.vack_view;
  "operation", js (Id.get a.vack_operation); "seq", ji (U.get a.vack_seq);
  "end_offset", ji (U.get a.vack_end_offset)]

type native_view_release_result = {
  vrel_view : native_view_ref; vrel_operation : Id.t; vrel_status : release_status }
let read_native_view_release_result v =
  let f = fields v ["view"; "operation"; "status"] in
  { vrel_view = read_native_view_ref (required f "view"); vrel_operation = id (required f "operation");
    vrel_status = read_enum release_status_table (required f "status") }
let write_native_view_release_result r = record ["view", write_native_view_ref r.vrel_view;
  "operation", js (Id.get r.vrel_operation); "status", write_enum release_status_table r.vrel_status]

type view_pull_result =
  | PullChunk of native_view_chunk
  | PullRetired of native_view_retired
let read_view_pull_result v = match string (required (object_ v) "kind") with
  | "view_chunk" -> PullChunk (read_native_view_chunk (required (fields v ["kind"; "value"]) "value"))
  | "view_retired" -> PullRetired (read_native_view_retired (required (fields v ["kind"; "value"]) "value"))
  | _ -> bad Invalid_tag
let write_view_pull_result = function
  | PullChunk c -> record ["kind", js "view_chunk"; "value", write_native_view_chunk c]
  | PullRetired r -> record ["kind", js "view_retired"; "value", write_native_view_retired r]

type view_ack_result =
  | AckAcked of native_view_ack_result
  | AckRetired of native_view_retired
let read_view_ack_result v = match string (required (object_ v) "kind") with
  | "view_acked" -> AckAcked (read_native_view_ack_result (required (fields v ["kind"; "value"]) "value"))
  | "view_retired" -> AckRetired (read_native_view_retired (required (fields v ["kind"; "value"]) "value"))
  | _ -> bad Invalid_tag
let write_view_ack_result = function
  | AckAcked a -> record ["kind", js "view_acked"; "value", write_native_view_ack_result a]
  | AckRetired r -> record ["kind", js "view_retired"; "value", write_native_view_retired r]

type view_release_result_value = VrelReleased of native_view_release_result
let read_view_release_result_value v = match string (required (object_ v) "kind") with
  | "view_released" -> VrelReleased (read_native_view_release_result (required (fields v ["kind"; "value"]) "value"))
  | _ -> bad Invalid_tag
let write_view_release_result_value = function
  | VrelReleased r -> record ["kind", js "view_released"; "value", write_native_view_release_result r]

type view_reply_pull =
  | ViewPullResult of header * view_pull_result
  | ViewPullError of header * native_protocol_error
let read_view_reply_pull v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      ViewPullResult (read_header (required f "header"), read_view_pull_result (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      ViewPullError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let view_reply_pull_to_json = function
  | ViewPullResult (h, r) -> record ["kind", js "result"; "header", write_header h;
      "result", write_view_pull_result r]
  | ViewPullError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_view_reply_pull limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_view_reply_pull v
let encode_view_reply_pull limits value = encode_with view_reply_pull_to_json limits value

type view_reply_ack =
  | ViewAckResultReply of header * view_ack_result
  | ViewAckError of header * native_protocol_error
let read_view_reply_ack v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      ViewAckResultReply (read_header (required f "header"), read_view_ack_result (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      ViewAckError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let view_reply_ack_to_json = function
  | ViewAckResultReply (h, r) -> record ["kind", js "result"; "header", write_header h;
      "result", write_view_ack_result r]
  | ViewAckError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_view_reply_ack limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_view_reply_ack v
let encode_view_reply_ack limits value = encode_with view_reply_ack_to_json limits value

type view_reply_release =
  | ViewReleaseResultReply of header * view_release_result_value
  | ViewReleaseError of header * native_protocol_error
let read_view_reply_release v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      ViewReleaseResultReply (read_header (required f "header"),
        read_view_release_result_value (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      ViewReleaseError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let view_reply_release_to_json = function
  | ViewReleaseResultReply (h, r) -> record ["kind", js "result"; "header", write_header h;
      "result", write_view_release_result_value r]
  | ViewReleaseError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_view_reply_release limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_view_reply_release v
let encode_view_reply_release limits value = encode_with view_reply_release_to_json limits value

let make_view_chunk h ~view ~operation ~seq ~offset ~text ~eof ~capture = protect (fun () ->
  let text = get (text0_bound 8192 text) in
  let bytes = String.length text in
  if bytes = 0 && not eof then bad Constraint;
  (* U 最大为 2^53-1，加至多 8192 不会使 int64 溢出；U.make 核 wire 上界。 *)
  let range_end = get (U.make (Int64.add (U.get offset) (Int64.of_int bytes))) in
  ViewPullResult (h, PullChunk {
    vc_view = { view_id = view }; vc_operation = operation; vc_seq = seq;
    vc_range = { range_start = offset; range_end }; vc_text = text; vc_end = eof; vc_capture = capture }))

let make_view_acked h ~view ~operation ~seq ~end_offset =
  ViewAckResultReply (h, AckAcked {
    vack_view = { view_id = view }; vack_operation = operation; vack_seq = seq; vack_end_offset = end_offset })

let view_retired ~view ~operation ~requested_seq ~acked_through ~end_offset = {
  vt_view = { view_id = view }; vt_operation = operation; vt_requested_seq = requested_seq;
  vt_acked_through = acked_through; vt_end_offset = end_offset }

let make_view_pull_retired h ~view ~operation ~requested_seq ~acked_through ~end_offset =
  ViewPullResult (h, PullRetired (view_retired ~view ~operation ~requested_seq ~acked_through ~end_offset))

let make_view_ack_retired h ~view ~operation ~requested_seq ~acked_through ~end_offset =
  ViewAckResultReply (h, AckRetired (view_retired ~view ~operation ~requested_seq ~acked_through ~end_offset))

let make_view_released h ~view ~operation ~status =
  ViewReleaseResultReply (h, VrelReleased {
    vrel_view = { view_id = view }; vrel_operation = operation; vrel_status = status })

let make_view_pull_error h code admission = ViewPullError (h, { code; admission; diagnostic = FUnknown })
let make_view_ack_error h code admission = ViewAckError (h, { code; admission; diagnostic = FUnknown })
let make_view_release_error h code admission = ViewReleaseError (h, { code; admission; diagnostic = FUnknown })

(* ---- checkpoint blob通道（rmcp-8 §3.6） ---- *)

(* transfer固定等于artifact.id归消费者；同artifact ID不等于跨operation/方向可读资格。 *)
type checkpoint_transfer = {
  ct_transfer : Id.t; ct_operation : Id.t; ct_operation_seq : U.t;
  ct_control : Id.t; ct_attempt : Id.t; ct_artifact : artifact_ref }
let read_checkpoint_transfer v =
  let f = fields v ["transfer"; "operation"; "operation_seq"; "control"; "attempt"; "artifact"] in
  { ct_transfer = id (required f "transfer"); ct_operation = id (required f "operation");
    ct_operation_seq = uint (required f "operation_seq"); ct_control = id (required f "control");
    ct_attempt = id (required f "attempt"); ct_artifact = read_artifact_ref (required f "artifact") }
let write_checkpoint_transfer t = record ["transfer", js (Id.get t.ct_transfer);
  "operation", js (Id.get t.ct_operation); "operation_seq", ji (U.get t.ct_operation_seq);
  "control", js (Id.get t.ct_control); "attempt", js (Id.get t.ct_attempt);
  "artifact", write_artifact_ref t.ct_artifact]

type args_blob_begin = { bb_transfer : checkpoint_transfer }
let read_args_blob_begin v =
  let f = fields v ["transfer"] in
  { bb_transfer = read_checkpoint_transfer (required f "transfer") }
let write_args_blob_begin a = record ["transfer", write_checkpoint_transfer a.bb_transfer]

type args_blob_chunk = { bc_transfer : Id.t; bc_operation : Id.t; bc_offset : U.t; bc_bytes : string }
let read_args_blob_chunk v =
  let f = fields v ["transfer"; "operation"; "offset"; "bytes"] in
  { bc_transfer = id (required f "transfer"); bc_operation = id (required f "operation");
    bc_offset = uint (required f "offset"); bc_bytes = read_b64_src (required f "bytes") }
let write_args_blob_chunk a = record ["transfer", js (Id.get a.bc_transfer);
  "operation", js (Id.get a.bc_operation); "offset", ji (U.get a.bc_offset); "bytes", js a.bc_bytes]

type args_blob_finish = { bf_transfer : Id.t; bf_operation : Id.t }
let read_args_blob_finish v =
  let f = fields v ["transfer"; "operation"] in
  { bf_transfer = id (required f "transfer"); bf_operation = id (required f "operation") }
let write_args_blob_finish a = record ["transfer", js (Id.get a.bf_transfer);
  "operation", js (Id.get a.bf_operation)]

type args_blob_pull = {
  bp_transfer : checkpoint_transfer; bp_expected_seq : U.t; bp_offset : U.t; bp_credit : U.t }
let read_args_blob_pull v =
  let f = fields v ["transfer"; "expected_seq"; "offset"; "credit_bytes"] in
  { bp_transfer = read_checkpoint_transfer (required f "transfer");
    bp_expected_seq = uint (required f "expected_seq"); bp_offset = uint (required f "offset");
    bp_credit = read_credit 1L 8192L (required f "credit_bytes") }
let write_args_blob_pull a = record ["transfer", write_checkpoint_transfer a.bp_transfer;
  "expected_seq", ji (U.get a.bp_expected_seq); "offset", ji (U.get a.bp_offset);
  "credit_bytes", ji (U.get a.bp_credit)]

type args_blob_ack = {
  ba_transfer : Id.t; ba_operation : Id.t; ba_seq : U.t; ba_end_offset : U.t; ba_digest : Digest.t }
let read_args_blob_ack v =
  let f = fields v ["transfer"; "operation"; "seq"; "end_offset"; "digest"] in
  { ba_transfer = id (required f "transfer"); ba_operation = id (required f "operation");
    ba_seq = uint (required f "seq"); ba_end_offset = uint (required f "end_offset");
    ba_digest = get (Digest.make (string (required f "digest"))) }
let write_args_blob_ack a = record ["transfer", js (Id.get a.ba_transfer);
  "operation", js (Id.get a.ba_operation); "seq", ji (U.get a.ba_seq);
  "end_offset", ji (U.get a.ba_end_offset); "digest", js (Digest.get a.ba_digest)]

type blob_release_reason = SealedUp | Discarded
let blob_release_reason_table = ["sealed", SealedUp; "discarded", Discarded]
type args_blob_release = {
  br_transfer : Id.t; br_operation : Id.t; br_reason : blob_release_reason;
  br_durable_record : Id.t fact }
let read_args_blob_release v =
  let f = fields v ["transfer"; "operation"; "reason"; "durable_record"] in
  { br_transfer = id (required f "transfer"); br_operation = id (required f "operation");
    br_reason = read_enum blob_release_reason_table (required f "reason");
    br_durable_record = read_fact id (required f "durable_record") }
let write_args_blob_release a = record ["transfer", js (Id.get a.br_transfer);
  "operation", js (Id.get a.br_operation); "reason", write_enum blob_release_reason_table a.br_reason;
  "durable_record", write_fact write_id a.br_durable_record]

type checkpoint_blob_request =
  | BlobBegin of header * args_blob_begin
  | BlobChunk of header * args_blob_chunk
  | BlobFinish of header * args_blob_finish
  | BlobPull of header * args_blob_pull
  | BlobAck of header * args_blob_ack
  | BlobRelease of header * args_blob_release
let read_checkpoint_blob_request v = protect (fun () ->
  match string (required (object_ v) "method") with
  | "checkpoint_blob_begin" ->
      let f = fields v ["method"; "header"; "args"] in
      BlobBegin (read_header (required f "header"), read_args_blob_begin (required f "args"))
  | "checkpoint_blob_chunk" ->
      let f = fields v ["method"; "header"; "args"] in
      BlobChunk (read_header (required f "header"), read_args_blob_chunk (required f "args"))
  | "checkpoint_blob_finish" ->
      let f = fields v ["method"; "header"; "args"] in
      BlobFinish (read_header (required f "header"), read_args_blob_finish (required f "args"))
  | "checkpoint_blob_pull" ->
      let f = fields v ["method"; "header"; "args"] in
      BlobPull (read_header (required f "header"), read_args_blob_pull (required f "args"))
  | "checkpoint_blob_ack" ->
      let f = fields v ["method"; "header"; "args"] in
      BlobAck (read_header (required f "header"), read_args_blob_ack (required f "args"))
  | "checkpoint_blob_release" ->
      let f = fields v ["method"; "header"; "args"] in
      BlobRelease (read_header (required f "header"), read_args_blob_release (required f "args"))
  | _ -> bad Invalid_tag)
let blob_request_method = function
  | BlobBegin _ -> "checkpoint_blob_begin" | BlobChunk _ -> "checkpoint_blob_chunk"
  | BlobFinish _ -> "checkpoint_blob_finish" | BlobPull _ -> "checkpoint_blob_pull"
  | BlobAck _ -> "checkpoint_blob_ack" | BlobRelease _ -> "checkpoint_blob_release"
let blob_request_header = function
  | BlobBegin (h, _) | BlobChunk (h, _) | BlobFinish (h, _)
  | BlobPull (h, _) | BlobAck (h, _) | BlobRelease (h, _) -> h
let write_blob_request_args = function
  | BlobBegin (_, a) -> write_args_blob_begin a
  | BlobChunk (_, a) -> write_args_blob_chunk a
  | BlobFinish (_, a) -> write_args_blob_finish a
  | BlobPull (_, a) -> write_args_blob_pull a
  | BlobAck (_, a) -> write_args_blob_ack a
  | BlobRelease (_, a) -> write_args_blob_release a
let blob_request_to_json request = protect (fun () ->
  record ["method", js (blob_request_method request);
    "header", write_header (blob_request_header request);
    "args", write_blob_request_args request])
let decode_checkpoint_blob_request limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_checkpoint_blob_request v
let encode_checkpoint_blob_request limits request =
  match blob_request_to_json request with Error e -> Error e | Ok value -> canonical limits value

(* 七种Result对象（均显式kind）；每方法允许子集由通道/method消费者核：
   begin→begun|registered、chunk→chunk_ack|retired、finish→registered、
   pull→chunk|retired、ack→acked|retired、release→released。 *)
type checkpoint_blob_result =
  | BlobBegun of { transfer : Id.t; next_offset : U.t }
  | BlobRegistered of { reg_artifact : artifact_ref }
  | BlobChunkAck of { transfer : Id.t; offset : U.t; end_offset : U.t; ack_digest : Digest.t }
  | BlobRetired of { transfer : Id.t; next_offset : U.t }
  | BlobChunkOut of { transfer : Id.t; seq : U.t; offset : U.t; end_offset : U.t;
                      out_bytes : string; out_end : bool }
  | BlobAcked of { transfer : Id.t; seq : U.t; end_offset : U.t }
  | BlobReleased of { transfer : Id.t; rel_status : release_status }
let read_checkpoint_blob_result v = match string (required (object_ v) "kind") with
  | "checkpoint_blob_begun" -> let f = fields v ["kind"; "transfer"; "next_offset"] in
      BlobBegun { transfer = id (required f "transfer"); next_offset = uint (required f "next_offset") }
  | "checkpoint_blob_registered" ->
      ignore (object_ v);
      BlobRegistered { reg_artifact = read_artifact_ref (required (fields v ["kind"; "artifact"]) "artifact") }
  | "checkpoint_blob_chunk_ack" ->
      let f = fields v ["kind"; "transfer"; "offset"; "end_offset"; "digest"] in
      BlobChunkAck { transfer = id (required f "transfer"); offset = uint (required f "offset");
        end_offset = uint (required f "end_offset");
        ack_digest = get (Digest.make (string (required f "digest"))) }
  | "checkpoint_blob_retired" -> let f = fields v ["kind"; "transfer"; "next_offset"] in
      BlobRetired { transfer = id (required f "transfer"); next_offset = uint (required f "next_offset") }
  | "checkpoint_blob_chunk" ->
      let f = fields v ["kind"; "transfer"; "seq"; "offset"; "end_offset"; "bytes"; "end"] in
      BlobChunkOut { transfer = id (required f "transfer"); seq = uint (required f "seq");
        offset = uint (required f "offset"); end_offset = uint (required f "end_offset");
        out_bytes = read_b64_bin (required f "bytes"); out_end = boolean (required f "end") }
  | "checkpoint_blob_acked" -> let f = fields v ["kind"; "transfer"; "seq"; "end_offset"] in
      BlobAcked { transfer = id (required f "transfer"); seq = uint (required f "seq");
        end_offset = uint (required f "end_offset") }
  | "checkpoint_blob_released" -> let f = fields v ["kind"; "transfer"; "status"] in
      BlobReleased { transfer = id (required f "transfer");
        rel_status = read_enum release_status_table (required f "status") }
  | _ -> bad Invalid_tag
let write_checkpoint_blob_result = function
  | BlobBegun r -> record ["kind", js "checkpoint_blob_begun"; "transfer", js (Id.get r.transfer);
      "next_offset", ji (U.get r.next_offset)]
  | BlobRegistered r -> record ["kind", js "checkpoint_blob_registered"; "artifact", write_artifact_ref r.reg_artifact]
  | BlobChunkAck r -> record ["kind", js "checkpoint_blob_chunk_ack"; "transfer", js (Id.get r.transfer);
      "offset", ji (U.get r.offset); "end_offset", ji (U.get r.end_offset);
      "digest", js (Digest.get r.ack_digest)]
  | BlobRetired r -> record ["kind", js "checkpoint_blob_retired"; "transfer", js (Id.get r.transfer);
      "next_offset", ji (U.get r.next_offset)]
  | BlobChunkOut r -> record ["kind", js "checkpoint_blob_chunk"; "transfer", js (Id.get r.transfer);
      "seq", ji (U.get r.seq); "offset", ji (U.get r.offset); "end_offset", ji (U.get r.end_offset);
      "bytes", js r.out_bytes; "end", bool_value r.out_end]
  | BlobAcked r -> record ["kind", js "checkpoint_blob_acked"; "transfer", js (Id.get r.transfer);
      "seq", ji (U.get r.seq); "end_offset", ji (U.get r.end_offset)]
  | BlobReleased r -> record ["kind", js "checkpoint_blob_released"; "transfer", js (Id.get r.transfer);
      "status", write_enum release_status_table r.rel_status]

type checkpoint_blob_reply =
  | BlobReplyResult of header * checkpoint_blob_result
  | BlobReplyError of header * native_protocol_error
let read_checkpoint_blob_reply v = protect (fun () ->
  match string (required (object_ v) "kind") with
  | "result" ->
      let f = fields v ["kind"; "header"; "result"] in
      BlobReplyResult (read_header (required f "header"), read_checkpoint_blob_result (required f "result"))
  | "protocol_error" ->
      let f = fields v ["kind"; "header"; "error"] in
      BlobReplyError (read_header (required f "header"), read_native_protocol_error (required f "error"))
  | _ -> bad Invalid_tag)
let checkpoint_blob_reply_to_json = function
  | BlobReplyResult (h, r) -> record ["kind", js "result"; "header", write_header h;
      "result", write_checkpoint_blob_result r]
  | BlobReplyError (h, e) -> record ["kind", js "protocol_error"; "header", write_header h;
      "error", write_native_protocol_error e]
let decode_checkpoint_blob_reply limits raw =
  match decode limits raw with Error e -> Error e | Ok v -> read_checkpoint_blob_reply v
let encode_checkpoint_blob_reply limits value = encode_with checkpoint_blob_reply_to_json limits value

type blob_request_view =
  | BlobBeginRequest of checkpoint_transfer
  | BlobChunkRequest of Id.t * Id.t * U.t * string
  | BlobFinishRequest of Id.t * Id.t
  | BlobPullRequest of checkpoint_transfer * U.t * U.t * U.t
  | BlobAckRequest of Id.t * Id.t * U.t * U.t * Digest.t
  | BlobReleaseRequest of Id.t * Id.t * blob_release_reason * Id.t option

let checkpoint_blob_request_view request =
  blob_request_header request,
  match request with
  | BlobBegin (_, a) -> BlobBeginRequest a.bb_transfer
  | BlobChunk (_, a) -> BlobChunkRequest (a.bc_transfer, a.bc_operation, a.bc_offset, a.bc_bytes)
  | BlobFinish (_, a) -> BlobFinishRequest (a.bf_transfer, a.bf_operation)
  | BlobPull (_, a) -> BlobPullRequest (a.bp_transfer, a.bp_expected_seq, a.bp_offset, a.bp_credit)
  | BlobAck (_, a) -> BlobAckRequest (a.ba_transfer, a.ba_operation, a.ba_seq, a.ba_end_offset, a.ba_digest)
  | BlobRelease (_, a) -> BlobReleaseRequest (a.br_transfer, a.br_operation, a.br_reason,
      match a.br_durable_record with FKnown id -> Some id | FUnknown | FNotApplicable -> None)

let checkpoint_blob_result header result = BlobReplyResult (header, result)

(* ---- checkpoint记录族（rmcp-13/U3 §9.3/PS §8.1/PS26/PS34） ---- *)

type checkpoint_alias_fact = {
  alias_source : Id.t; ancestor_source : Id.t; unchanged_prefix_end : U.t; alias_publication : Id.t }
let read_checkpoint_alias_fact v =
  let f = fields v ["source"; "ancestor_source"; "unchanged_prefix_end"; "publication"] in
  { alias_source = id (required f "source"); ancestor_source = id (required f "ancestor_source");
    unchanged_prefix_end = uint (required f "unchanged_prefix_end");
    alias_publication = id (required f "publication") }
let write_checkpoint_alias_fact a = record ["source", js (Id.get a.alias_source);
  "ancestor_source", js (Id.get a.ancestor_source);
  "unchanged_prefix_end", ji (U.get a.unchanged_prefix_end);
  "publication", js (Id.get a.alias_publication)]

type checkpoint_source_identity = { csi_source : Id.t; csi_digest : Digest.t; csi_bytes : U.t }
let read_checkpoint_source_identity v =
  let f = fields v ["source"; "digest"; "bytes"] in
  { csi_source = id (required f "source");
    csi_digest = get (Digest.make (string (required f "digest"))); csi_bytes = uint (required f "bytes") }
let write_checkpoint_source_identity d = record ["source", js (Id.get d.csi_source);
  "digest", js (Digest.get d.csi_digest); "bytes", ji (U.get d.csi_bytes)]

(* parent恰known/not_applicable两支（oneOf无unknown分支）；known<index归消费者。 *)
type checkpoint_node_meta = {
  cnm_index : U.t; cnm_old_node : Id.t; cnm_parent : U.t known_or_na; cnm_source : Id.t;
  cnm_start : U.t; cnm_end : U.t; cnm_cursor : U.t; cnm_read_end : U.t; cnm_saw_eof : bool }
let read_checkpoint_node_meta v =
  let f = fields v ["index"; "old_node"; "parent"; "source"; "start"; "end"; "cursor"; "read_end"; "saw_eof"] in
  { cnm_index = uint (required f "index"); cnm_old_node = id (required f "old_node");
    cnm_parent = read_known_or_na uint (required f "parent"); cnm_source = id (required f "source");
    cnm_start = uint (required f "start"); cnm_end = uint (required f "end");
    cnm_cursor = uint (required f "cursor"); cnm_read_end = uint (required f "read_end");
    cnm_saw_eof = boolean (required f "saw_eof") }
let write_checkpoint_node_meta m = record ["index", ji (U.get m.cnm_index);
  "old_node", js (Id.get m.cnm_old_node); "parent", write_known_or_na write_uint m.cnm_parent;
  "source", js (Id.get m.cnm_source); "start", ji (U.get m.cnm_start); "end", ji (U.get m.cnm_end);
  "cursor", ji (U.get m.cnm_cursor); "read_end", ji (U.get m.cnm_read_end);
  "saw_eof", bool_value m.cnm_saw_eof]

(* boundary身份为权威，源码位置仅辅助定位（rmcp-8 §3.5）。 *)
type checkpoint_boundary = CbEntry of Id.t | CbStep of Id.t * Id.t
let read_checkpoint_boundary v = match string (required (object_ v) "kind") with
  | "entry" -> CbEntry (id (required (fields v ["kind"; "lineage"]) "lineage"))
  | "step" ->
      let f = fields v ["kind"; "lineage"; "step"] in
      CbStep (id (required f "lineage"), id (required f "step"))
  | _ -> bad Invalid_tag
let write_checkpoint_boundary = function
  | CbEntry lineage -> record ["kind", js "entry"; "lineage", js (Id.get lineage)]
  | CbStep (lineage, step) -> record ["kind", js "step"; "lineage", js (Id.get lineage);
      "step", js (Id.get step)]

type checkpoint_boundary_row = { cbr_boundary : checkpoint_boundary; cbr_node_index : U.t }
let read_checkpoint_boundary_row v =
  let f = fields v ["boundary"; "node_index"] in
  { cbr_boundary = read_checkpoint_boundary (required f "boundary");
    cbr_node_index = uint (required f "node_index") }
let write_checkpoint_boundary_row r = record ["boundary", write_checkpoint_boundary r.cbr_boundary;
  "node_index", ji (U.get r.cbr_node_index)]

type checkpoint_map_row = {
  mr_boundary : checkpoint_boundary; mr_new_node : Id.t; mr_new_line : Id.t;
  mr_new_line_revision : U.t; mr_new_context : Id.t; mr_new_context_revision : U.t }
let read_checkpoint_map_row v =
  let f = fields v ["boundary"; "new_node"; "new_line"; "new_line_revision"; "new_context"; "new_context_revision"] in
  { mr_boundary = read_checkpoint_boundary (required f "boundary"); mr_new_node = id (required f "new_node");
    mr_new_line = id (required f "new_line"); mr_new_line_revision = uint (required f "new_line_revision");
    mr_new_context = id (required f "new_context");
    mr_new_context_revision = uint (required f "new_context_revision") }
let write_checkpoint_map_row r = record ["boundary", write_checkpoint_boundary r.mr_boundary;
  "new_node", js (Id.get r.mr_new_node); "new_line", js (Id.get r.mr_new_line);
  "new_line_revision", ji (U.get r.mr_new_line_revision); "new_context", js (Id.get r.mr_new_context);
  "new_context_revision", ji (U.get r.mr_new_context_revision)]

(* 数组上下界助手：bound65536/bound256/bound12/min1（与schema maxItems逐项对应）。 *)
let bound65536 lst = bound_list 65536 lst
let bound256 lst = bound_list 256 lst
let bound12 lst = bound_list 12 lst
let bound64 lst = bound_list 64 lst

(* NC02 collect唯一生产；encode必须重核同一集合不能封plan后默补（消费者）。 *)
type checkpoint_requirements = {
  cr_selection : artifact_ref; cr_group : Id.t;
  cr_collect_operation : Id.t; cr_instance : Id.t; cr_backend_epoch : U.t;
  cr_manager_epoch : U.t; cr_environment : Id.t; cr_required_sources : Id.t list;
  cr_source_descriptors : checkpoint_source_identity list; cr_alias_facts : checkpoint_alias_fact list;
  cr_nodes : checkpoint_node_meta list; cr_boundaries : checkpoint_boundary_row list }
let read_checkpoint_requirements v =
  let f = fields v ["schema_version"; "selection"; "group"; "collect_operation"; "instance";
    "backend_epoch"; "manager_epoch"; "environment"; "required_sources"; "source_descriptors";
    "alias_facts"; "nodes"; "boundaries"] in
  schema1 (required f "schema_version");
  { cr_selection = read_artifact_ref (required f "selection"); cr_group = id (required f "group");
    cr_collect_operation = id (required f "collect_operation"); cr_instance = id (required f "instance");
    cr_backend_epoch = uint (required f "backend_epoch"); cr_manager_epoch = uint (required f "manager_epoch");
    cr_environment = id (required f "environment");
    cr_required_sources = read_list id (required f "required_sources") |> bound256;
    cr_source_descriptors = read_list read_checkpoint_source_identity (required f "source_descriptors") |> bound256;
    cr_alias_facts = read_list read_checkpoint_alias_fact (required f "alias_facts") |> bound256;
    cr_nodes = read_list read_checkpoint_node_meta (required f "nodes") |> bound65536;
    cr_boundaries = read_list read_checkpoint_boundary_row (required f "boundaries") |> bound65536 }
let write_checkpoint_requirements r = record ["schema_version", ji 1L;
  "selection", write_artifact_ref r.cr_selection; "group", js (Id.get r.cr_group);
  "collect_operation", js (Id.get r.cr_collect_operation); "instance", js (Id.get r.cr_instance);
  "backend_epoch", ji (U.get r.cr_backend_epoch); "manager_epoch", ji (U.get r.cr_manager_epoch);
  "environment", js (Id.get r.cr_environment);
  "required_sources", array_value (List.rev (List.rev_map write_id r.cr_required_sources));
  "source_descriptors", array_value (List.rev (List.rev_map write_checkpoint_source_identity r.cr_source_descriptors));
  "alias_facts", array_value (List.rev (List.rev_map write_checkpoint_alias_fact r.cr_alias_facts));
  "nodes", array_value (List.rev (List.rev_map write_checkpoint_node_meta r.cr_nodes));
  "boundaries", array_value (List.rev (List.rev_map write_checkpoint_boundary_row r.cr_boundaries))]
let decode_checkpoint_requirements limits raw = decode_with read_checkpoint_requirements limits raw
let encode_checkpoint_requirements limits value = encode_with write_checkpoint_requirements limits value

(* U3 §9.3：boundaries顺序/集合恰为PS26 group.paths逐条序列；manifest不带bundle
   digest避免自摘要循环（消费者）。 *)
type checkpoint_coverage_manifest = {
  ccm_plan : artifact_ref; ccm_group : Id.t; ccm_export_operation : Id.t;
  ccm_instance : Id.t; ccm_backend_epoch : U.t; ccm_manager_epoch : U.t;
  ccm_environment : Id.t; ccm_compatibility : artifact_ref; ccm_requirements : artifact_ref;
  ccm_source_descriptors : checkpoint_source_identity list;
  ccm_nodes : checkpoint_node_meta list; ccm_boundaries : checkpoint_boundary_row list }
let read_checkpoint_coverage_manifest v =
  let f = fields v ["schema_version"; "plan"; "group"; "export_operation"; "instance";
    "backend_epoch"; "manager_epoch"; "environment"; "compatibility"; "requirements";
    "source_descriptors"; "nodes"; "boundaries"] in
  schema1 (required f "schema_version");
  { ccm_plan = read_artifact_ref (required f "plan"); ccm_group = id (required f "group");
    ccm_export_operation = id (required f "export_operation"); ccm_instance = id (required f "instance");
    ccm_backend_epoch = uint (required f "backend_epoch"); ccm_manager_epoch = uint (required f "manager_epoch");
    ccm_environment = id (required f "environment");
    ccm_compatibility = read_artifact_ref (required f "compatibility");
    ccm_requirements = read_artifact_ref (required f "requirements");
    ccm_source_descriptors = read_list read_checkpoint_source_identity (required f "source_descriptors") |> bound256;
    ccm_nodes = read_list read_checkpoint_node_meta (required f "nodes") |> bound65536;
    ccm_boundaries = read_list read_checkpoint_boundary_row (required f "boundaries") |> bound65536 }
let write_checkpoint_coverage_manifest m = record ["schema_version", ji 1L;
  "plan", write_artifact_ref m.ccm_plan; "group", js (Id.get m.ccm_group);
  "export_operation", js (Id.get m.ccm_export_operation); "instance", js (Id.get m.ccm_instance);
  "backend_epoch", ji (U.get m.ccm_backend_epoch); "manager_epoch", ji (U.get m.ccm_manager_epoch);
  "environment", js (Id.get m.ccm_environment); "compatibility", write_artifact_ref m.ccm_compatibility;
  "requirements", write_artifact_ref m.ccm_requirements;
  "source_descriptors", array_value (List.rev (List.rev_map write_checkpoint_source_identity m.ccm_source_descriptors));
  "nodes", array_value (List.rev (List.rev_map write_checkpoint_node_meta m.ccm_nodes));
  "boundaries", array_value (List.rev (List.rev_map write_checkpoint_boundary_row m.ccm_boundaries))]
let decode_checkpoint_coverage_manifest limits raw = decode_with read_checkpoint_coverage_manifest limits raw
let encode_checkpoint_coverage_manifest limits value = encode_with write_checkpoint_coverage_manifest limits value

(* NC06–07：rows覆盖全部manifest boundaries无重复/漏项/额外、validated_node_count=
   manifest.nodes.length归消费者；validation是读取期常量，异值INVALID_TAG、
   常量先于字段集。 *)
type checkpoint_import_map = {
  cim_cache : Id.t; cim_group : Id.t; cim_import_operation : Id.t; cim_instance : Id.t;
  cim_backend_epoch : U.t; cim_manager_epoch : U.t; cim_manifest : artifact_ref;
  cim_rows : checkpoint_map_row list; cim_validated_node_count : U.t }
let read_checkpoint_import_map v =
  if string (required (object_ v) "validation") <> "all_roots_accessible" then bad Invalid_tag;
  let f = fields v ["schema_version"; "cache"; "group"; "import_operation"; "instance";
    "backend_epoch"; "manager_epoch"; "manifest"; "rows"; "validated_node_count"; "validation"] in
  schema1 (required f "schema_version");
  { cim_cache = id (required f "cache"); cim_group = id (required f "group");
    cim_import_operation = id (required f "import_operation"); cim_instance = id (required f "instance");
    cim_backend_epoch = uint (required f "backend_epoch"); cim_manager_epoch = uint (required f "manager_epoch");
    cim_manifest = read_artifact_ref (required f "manifest");
    cim_rows = read_list read_checkpoint_map_row (required f "rows") |> bound65536;
    cim_validated_node_count = uint (required f "validated_node_count") }
let write_checkpoint_import_map m = record ["schema_version", ji 1L;
  "cache", js (Id.get m.cim_cache); "group", js (Id.get m.cim_group);
  "import_operation", js (Id.get m.cim_import_operation); "instance", js (Id.get m.cim_instance);
  "backend_epoch", ji (U.get m.cim_backend_epoch); "manager_epoch", ji (U.get m.cim_manager_epoch);
  "manifest", write_artifact_ref m.cim_manifest;
  "rows", array_value (List.rev (List.rev_map write_checkpoint_map_row m.cim_rows));
  "validated_node_count", ji (U.get m.cim_validated_node_count);
  "validation", js "all_roots_accessible"]
let decode_checkpoint_import_map limits raw = decode_with read_checkpoint_import_map limits raw
let encode_checkpoint_import_map limits value = encode_with write_checkpoint_import_map limits value

(* PS §8.1：boundaries以entry开头、零步主线frontier=entry（消费者核）；minItems=1。 *)
type checkpoint_path_snapshot = {
  cps_lineage : Id.t; cps_path_revision : U.t; cps_proof : Id.t; cps_entry_proof : Id.t;
  cps_source_anchor : Id.t; cps_source : Id.t; cps_environment : Id.t;
  cps_frontier : checkpoint_boundary; cps_boundaries : checkpoint_boundary list }
let read_checkpoint_path_snapshot v =
  let f = fields v ["lineage"; "path_revision"; "proof"; "entry_proof"; "source_anchor";
    "source"; "environment"; "frontier"; "boundaries"] in
  { cps_lineage = id (required f "lineage"); cps_path_revision = uint (required f "path_revision");
    cps_proof = id (required f "proof"); cps_entry_proof = id (required f "entry_proof");
    cps_source_anchor = id (required f "source_anchor"); cps_source = id (required f "source");
    cps_environment = id (required f "environment");
    cps_frontier = read_checkpoint_boundary (required f "frontier");
    cps_boundaries = read_list read_checkpoint_boundary (required f "boundaries") |> bound65536 |> min1_list }
let write_checkpoint_path_snapshot p = record ["lineage", js (Id.get p.cps_lineage);
  "path_revision", ji (U.get p.cps_path_revision); "proof", js (Id.get p.cps_proof);
  "entry_proof", js (Id.get p.cps_entry_proof); "source_anchor", js (Id.get p.cps_source_anchor);
  "source", js (Id.get p.cps_source); "environment", js (Id.get p.cps_environment);
  "frontier", write_checkpoint_boundary p.cps_frontier;
  "boundaries", array_value (List.rev (List.rev_map write_checkpoint_boundary p.cps_boundaries))]

(* line_bindings恰覆盖paths.lineage且来自M2当前NativeLineBinding（消费者核）。 *)
type checkpoint_line_binding = { clb_lineage : Id.t; clb_native_line : native_version }
let read_checkpoint_line_binding v =
  let f = fields v ["lineage"; "native_line"] in
  { clb_lineage = id (required f "lineage");
    clb_native_line = read_native_version (required f "native_line") }
let write_checkpoint_line_binding b = record ["lineage", js (Id.get b.clb_lineage);
  "native_line", write_native_version b.clb_native_line]

(* 同group必须同workspace/context/EnvironmentRef/owner_scope（消费者核）。 *)
type checkpoint_group = {
  cg_group_id : Id.t; cg_owner_scope : Id.t; cg_native_scope : Id.t; cg_workspace : Id.t;
  cg_instance : Id.t; cg_backend_epoch : U.t; cg_context : Id.t; cg_environment : Id.t;
  cg_paths : checkpoint_path_snapshot list; cg_line_bindings : checkpoint_line_binding list }
let read_checkpoint_group v =
  let f = fields v ["group_id"; "owner_scope"; "native_scope"; "workspace"; "instance";
    "backend_epoch"; "context"; "environment"; "paths"; "line_bindings"] in
  { cg_group_id = id (required f "group_id"); cg_owner_scope = id (required f "owner_scope");
    cg_native_scope = id (required f "native_scope"); cg_workspace = id (required f "workspace");
    cg_instance = id (required f "instance"); cg_backend_epoch = uint (required f "backend_epoch");
    cg_context = id (required f "context"); cg_environment = id (required f "environment");
    cg_paths = read_list read_checkpoint_path_snapshot (required f "paths") |> bound256;
    cg_line_bindings = read_list read_checkpoint_line_binding (required f "line_bindings") |> bound256 }
let write_checkpoint_group g = record ["group_id", js (Id.get g.cg_group_id);
  "owner_scope", js (Id.get g.cg_owner_scope); "native_scope", js (Id.get g.cg_native_scope);
  "workspace", js (Id.get g.cg_workspace); "instance", js (Id.get g.cg_instance);
  "backend_epoch", ji (U.get g.cg_backend_epoch); "context", js (Id.get g.cg_context);
  "environment", js (Id.get g.cg_environment);
  "paths", array_value (List.rev (List.rev_map write_checkpoint_path_snapshot g.cg_paths));
  "line_bindings", array_value (List.rev (List.rev_map write_checkpoint_line_binding g.cg_line_bindings))]

type covered_scope_row = { csr_scope : Id.t; csr_revision : U.t; csr_parent : Id.t option }
let read_covered_scope_row v =
  let f = fields v ["scope"; "revision"; "parent"] in
  { csr_scope = id (required f "scope"); csr_revision = uint (required f "revision");
    csr_parent = read_opt_id (required f "parent") }
let write_covered_scope_row r = record ["scope", js (Id.get r.csr_scope);
  "revision", ji (U.get r.csr_revision); "parent", write_opt_id r.csr_parent]

(* PS34唯一生产；groups∪reused_bindings=selected_lineages且互斥（消费者核）。 *)
type checkpoint_selection = {
  cs_selection_id : Id.t; cs_control_id : Id.t; cs_run_id : Id.t; cs_scope : Id.t;
  cs_pause_revision : U.t; cs_covered_scopes : covered_scope_row list;
  cs_groups : checkpoint_group list; cs_reused_bindings : Id.t list;
  cs_selected_lineages : Id.t list; cs_input_facts : Id.t list; cs_stop_facts : Id.t list }
let read_checkpoint_selection v =
  let f = fields v ["schema_version"; "selection_id"; "control_id"; "run_id"; "scope";
    "pause_revision"; "covered_scopes"; "groups"; "reused_bindings"; "selected_lineages";
    "input_facts"; "stop_facts"] in
  schema1 (required f "schema_version");
  { cs_selection_id = id (required f "selection_id"); cs_control_id = id (required f "control_id");
    cs_run_id = id (required f "run_id"); cs_scope = id (required f "scope");
    cs_pause_revision = uint (required f "pause_revision");
    cs_covered_scopes = read_list read_covered_scope_row (required f "covered_scopes") |> bound256;
    cs_groups = read_list read_checkpoint_group (required f "groups") |> bound256;
    cs_reused_bindings = read_list id (required f "reused_bindings") |> bound256;
    cs_selected_lineages = read_list id (required f "selected_lineages") |> bound256;
    cs_input_facts = read_list id (required f "input_facts") |> bound256;
    cs_stop_facts = read_list id (required f "stop_facts") |> bound256 }
let write_checkpoint_selection s = record ["schema_version", ji 1L;
  "selection_id", js (Id.get s.cs_selection_id); "control_id", js (Id.get s.cs_control_id);
  "run_id", js (Id.get s.cs_run_id); "scope", js (Id.get s.cs_scope);
  "pause_revision", ji (U.get s.cs_pause_revision);
  "covered_scopes", array_value (List.rev (List.rev_map write_covered_scope_row s.cs_covered_scopes));
  "groups", array_value (List.rev (List.rev_map write_checkpoint_group s.cs_groups));
  "reused_bindings", array_value (List.rev (List.rev_map write_id s.cs_reused_bindings));
  "selected_lineages", array_value (List.rev (List.rev_map write_id s.cs_selected_lineages));
  "input_facts", array_value (List.rev (List.rev_map write_id s.cs_input_facts));
  "stop_facts", array_value (List.rev (List.rev_map write_id s.cs_stop_facts))]
let decode_checkpoint_selection limits raw = decode_with read_checkpoint_selection limits raw
let encode_checkpoint_selection limits value = encode_with write_checkpoint_selection limits value

(* PS26唯一生产；正式文件依赖只从SourceAnchor.formal_input构造（消费者核）。 *)
type scope_checkpoint_plan = {
  scp_plan_id : Id.t; scp_control_id : Id.t; scp_run_id : Id.t; scp_scope : Id.t;
  scp_scope_revision : U.t; scp_pause_revision : U.t; scp_manager_epoch : U.t;
  scp_authority_ref : Id.t; scp_input_facts : Id.t list; scp_stop_facts : Id.t list;
  scp_covered_scopes : covered_scope_row list; scp_groups : checkpoint_group list;
  scp_reused_bindings : Id.t list; scp_selected_lineages : Id.t list;
  scp_selection : artifact_ref; scp_requirements : artifact_ref list;
  scp_source_materials : Id.t list; scp_budget : Id.t }
let read_scope_checkpoint_plan v =
  let f = fields v ["schema_version"; "plan_id"; "control_id"; "run_id"; "scope";
    "scope_revision"; "pause_revision"; "manager_epoch"; "authority_ref"; "input_facts";
    "stop_facts"; "covered_scopes"; "groups"; "reused_bindings"; "selected_lineages";
    "selection"; "requirements"; "source_materials"; "budget"] in
  schema1 (required f "schema_version");
  { scp_plan_id = id (required f "plan_id"); scp_control_id = id (required f "control_id");
    scp_run_id = id (required f "run_id"); scp_scope = id (required f "scope");
    scp_scope_revision = uint (required f "scope_revision");
    scp_pause_revision = uint (required f "pause_revision");
    scp_manager_epoch = uint (required f "manager_epoch");
    scp_authority_ref = id (required f "authority_ref");
    scp_input_facts = read_list id (required f "input_facts") |> bound256;
    scp_stop_facts = read_list id (required f "stop_facts") |> bound256;
    scp_covered_scopes = read_list read_covered_scope_row (required f "covered_scopes") |> bound256;
    scp_groups = read_list read_checkpoint_group (required f "groups") |> bound256;
    scp_reused_bindings = read_list id (required f "reused_bindings") |> bound256;
    scp_selected_lineages = read_list id (required f "selected_lineages") |> bound256;
    scp_selection = read_artifact_ref (required f "selection");
    scp_requirements = read_list read_artifact_ref (required f "requirements") |> bound256;
    scp_source_materials = read_list id (required f "source_materials") |> bound65536;
    scp_budget = id (required f "budget") }
let write_scope_checkpoint_plan p = record ["schema_version", ji 1L;
  "plan_id", js (Id.get p.scp_plan_id); "control_id", js (Id.get p.scp_control_id);
  "run_id", js (Id.get p.scp_run_id); "scope", js (Id.get p.scp_scope);
  "scope_revision", ji (U.get p.scp_scope_revision); "pause_revision", ji (U.get p.scp_pause_revision);
  "manager_epoch", ji (U.get p.scp_manager_epoch); "authority_ref", js (Id.get p.scp_authority_ref);
  "input_facts", array_value (List.rev (List.rev_map write_id p.scp_input_facts));
  "stop_facts", array_value (List.rev (List.rev_map write_id p.scp_stop_facts));
  "covered_scopes", array_value (List.rev (List.rev_map write_covered_scope_row p.scp_covered_scopes));
  "groups", array_value (List.rev (List.rev_map write_checkpoint_group p.scp_groups));
  "reused_bindings", array_value (List.rev (List.rev_map write_id p.scp_reused_bindings));
  "selected_lineages", array_value (List.rev (List.rev_map write_id p.scp_selected_lineages));
  "selection", write_artifact_ref p.scp_selection;
  "requirements", array_value (List.rev (List.rev_map write_artifact_ref p.scp_requirements));
  "source_materials", array_value (List.rev (List.rev_map write_id p.scp_source_materials));
  "budget", js (Id.get p.scp_budget)]
let decode_scope_checkpoint_plan limits raw = decode_with read_scope_checkpoint_plan limits raw
let encode_scope_checkpoint_plan limits value = encode_with write_scope_checkpoint_plan limits value

(* 独立decode/encode入口（checkpoint_group/path_snapshot本体无外壳）。 *)
let decode_checkpoint_group limits raw = decode_with read_checkpoint_group limits raw
let encode_checkpoint_group limits value = encode_with write_checkpoint_group limits value
let decode_checkpoint_path_snapshot limits raw = decode_with read_checkpoint_path_snapshot limits raw
let encode_checkpoint_path_snapshot limits value = encode_with write_checkpoint_path_snapshot limits value
let decode_checkpoint_alias_fact limits raw = decode_with read_checkpoint_alias_fact limits raw
let encode_checkpoint_alias_fact limits value = encode_with write_checkpoint_alias_fact limits value

(* ---- 原生记录（native-driver §4.2.2） ---- *)

(* 恰十二项（rmcp-8 §3.7）；roots每种RootKind恰一项（exact-set归消费者）。 *)
type root_kind =
  | RkLine | RkDoc | RkIndex | RkMemo | RkImports | RkCurrent | RkPending
  | RkInflight | RkView | RkBootstrap | RkCheckpointExport | RkCheckpointImport
let root_kind_table = [
  "line", RkLine; "doc", RkDoc; "index", RkIndex; "memo", RkMemo;
  "imports", RkImports; "current", RkCurrent; "pending", RkPending;
  "inflight", RkInflight; "view", RkView; "bootstrap", RkBootstrap;
  "checkpoint_export", RkCheckpointExport; "checkpoint_import", RkCheckpointImport]
type root_class_fact = { rcf_kind : root_kind; rcf_removed : U.t; rcf_retained : U.t; rcf_unresolved : U.t }
let read_root_class_fact v =
  let f = fields v ["kind"; "removed"; "retained"; "unresolved"] in
  { rcf_kind = read_enum root_kind_table (required f "kind"); rcf_removed = uint (required f "removed");
    rcf_retained = uint (required f "retained"); rcf_unresolved = uint (required f "unresolved") }
let write_root_class_fact r = record ["kind", write_enum root_kind_table r.rcf_kind;
  "removed", ji (U.get r.rcf_removed); "retained", ji (U.get r.rcf_retained);
  "unresolved", ji (U.get r.rcf_unresolved)]

(* blockers有界超界不截为完整（消费者）。 *)
type native_reclaim = {
  nr_id : Id.t; nr_retirement : Id.t; nr_release_seq : U.t; nr_instance : Id.t;
  nr_backend_epoch : U.t; nr_manager_epoch : U.t; nr_status : ended_status;
  nr_roots : root_class_fact list; nr_blockers : Id.t list; nr_observation : Id.t fact }

let make_native_reclaim ~id ~retirement ~release_seq ~instance ~backend_epoch ~manager_epoch
    ~status ~roots ~blockers ~observation = protect (fun () ->
  let roots = bound12 roots in
  let blockers = bound65536 blockers in
  (* 生产者必须提供完整根类集合；保留原顺序，不补零或截断。 *)
  if List.sort compare (List.map (fun r -> r.rcf_kind) roots)
     <> List.sort compare (List.map snd root_kind_table) then bad Constraint;
  { nr_id = id; nr_retirement = retirement; nr_release_seq = release_seq; nr_instance = instance;
    nr_backend_epoch = backend_epoch; nr_manager_epoch = manager_epoch; nr_status = status;
    nr_roots = roots; nr_blockers = blockers; nr_observation = observation })

let read_native_reclaim v =
  let f = fields v ["id"; "retirement"; "release_seq"; "instance"; "backend_epoch";
    "manager_epoch"; "status"; "roots"; "blockers"; "observation"] in
  { nr_id = id (required f "id"); nr_retirement = id (required f "retirement");
    nr_release_seq = uint (required f "release_seq"); nr_instance = id (required f "instance");
    nr_backend_epoch = uint (required f "backend_epoch"); nr_manager_epoch = uint (required f "manager_epoch");
    nr_status = read_enum ended_status_table (required f "status");
    nr_roots = read_list read_root_class_fact (required f "roots") |> bound12;
    nr_blockers = read_list id (required f "blockers") |> bound65536;
    nr_observation = read_fact id (required f "observation") }
let write_native_reclaim r = record ["id", js (Id.get r.nr_id);
  "retirement", js (Id.get r.nr_retirement); "release_seq", ji (U.get r.nr_release_seq);
  "instance", js (Id.get r.nr_instance); "backend_epoch", ji (U.get r.nr_backend_epoch);
  "manager_epoch", ji (U.get r.nr_manager_epoch); "status", write_enum ended_status_table r.nr_status;
  "roots", array_value (List.rev (List.rev_map write_root_class_fact r.nr_roots));
  "blockers", array_value (List.rev (List.rev_map write_id r.nr_blockers));
  "observation", write_fact write_id r.nr_observation]
let decode_native_reclaim limits raw = decode_with read_native_reclaim limits raw
let encode_native_reclaim limits value = encode_with write_native_reclaim limits value

type retention_class = RcMainline | RcExploration | RcTransient
let retention_class_table = ["mainline", RcMainline; "exploration", RcExploration; "transient", RcTransient]
type retention_progress = RpLive | RpRetiring | RpReleased
let retention_progress_table = ["live", RpLive; "retiring", RpRetiring; "released", RpReleased]
type native_retention = {
  nt_node : Id.t; nt_scope : Id.t; nt_line : Id.t; nt_class : retention_class;
  nt_source : Id.t; nt_environment : Id.t; nt_decision : Id.t;
  nt_line_revision : U.t; nt_release_seq : U.t; nt_progress : retention_progress }
let read_native_retention v =
  let f = fields v ["node"; "scope"; "line"; "class"; "source"; "environment";
    "decision"; "line_revision"; "release_seq"; "progress"] in
  { nt_node = id (required f "node"); nt_scope = id (required f "scope"); nt_line = id (required f "line");
    nt_class = read_enum retention_class_table (required f "class");
    nt_source = id (required f "source"); nt_environment = id (required f "environment");
    nt_decision = id (required f "decision"); nt_line_revision = uint (required f "line_revision");
    nt_release_seq = uint (required f "release_seq");
    nt_progress = read_enum retention_progress_table (required f "progress") }
let write_native_retention r = record ["node", js (Id.get r.nt_node);
  "scope", js (Id.get r.nt_scope); "line", js (Id.get r.nt_line);
  "class", write_enum retention_class_table r.nt_class; "source", js (Id.get r.nt_source);
  "environment", js (Id.get r.nt_environment); "decision", js (Id.get r.nt_decision);
  "line_revision", ji (U.get r.nt_line_revision); "release_seq", ji (U.get r.nt_release_seq);
  "progress", write_enum retention_progress_table r.nt_progress]
let decode_native_retention limits raw = decode_with read_native_retention limits raw
let encode_native_retention limits value = encode_with write_native_retention limits value

(* gc_live_words：GC未实际执行为unknown，不以capacity填值；word_bytes由实际
   runtime word size/8（消费者）。 *)
type observation_coverage = CoverageComplete | CoveragePartial
let observation_coverage_table = ["complete", CoverageComplete; "partial", CoveragePartial]
type native_memory_observation = {
  nmo_instance : Id.t; nmo_backend_epoch : U.t; nmo_manager_epoch : U.t;
  nmo_observed_tick_ns : U.t; nmo_cost_ns : U.t; nmo_gc_live_words : U.t fact;
  nmo_word_bytes : U.t; nmo_roots : root_class_fact list; nmo_coverage : observation_coverage }
let read_native_memory_observation v =
  let f = fields v ["instance"; "backend_epoch"; "manager_epoch"; "observed_tick_ns";
    "cost_ns"; "gc_live_words"; "word_bytes"; "roots"; "coverage"] in
  let word_bytes = uint (required f "word_bytes") in
  if U.get word_bytes < 1L then bad Constraint;
  { nmo_instance = id (required f "instance"); nmo_backend_epoch = uint (required f "backend_epoch");
    nmo_manager_epoch = uint (required f "manager_epoch");
    nmo_observed_tick_ns = uint (required f "observed_tick_ns"); nmo_cost_ns = uint (required f "cost_ns");
    nmo_gc_live_words = read_fact uint (required f "gc_live_words");
    nmo_word_bytes = word_bytes;
    nmo_roots = read_list read_root_class_fact (required f "roots") |> bound12;
    nmo_coverage = read_enum observation_coverage_table (required f "coverage") }
let write_native_memory_observation m = record ["instance", js (Id.get m.nmo_instance);
  "backend_epoch", ji (U.get m.nmo_backend_epoch); "manager_epoch", ji (U.get m.nmo_manager_epoch);
  "observed_tick_ns", ji (U.get m.nmo_observed_tick_ns); "cost_ns", ji (U.get m.nmo_cost_ns);
  "gc_live_words", write_fact write_uint m.nmo_gc_live_words; "word_bytes", ji (U.get m.nmo_word_bytes);
  "roots", array_value (List.rev (List.rev_map write_root_class_fact m.nmo_roots));
  "coverage", write_enum observation_coverage_table m.nmo_coverage]
let decode_native_memory_observation limits raw = decode_with read_native_memory_observation limits raw
let encode_native_memory_observation limits value = encode_with write_native_memory_observation limits value

(* 一次性启动绑定（自有FD一次读取）；配额为已批准正有限值（消费者）。
   platform用Text非空（schema精确区分：compat/loaded用Str4096）。 *)
type native_boot_platform = { nbp_system : Text.t; nbp_architecture : Text.t }
let read_native_boot_platform v =
  let f = fields v ["system"; "architecture"] in
  { nbp_system = text (required f "system"); nbp_architecture = text (required f "architecture") }
let write_native_boot_platform p = record ["system", js (Text.get p.nbp_system);
  "architecture", js (Text.get p.nbp_architecture)]
type native_channel_nonces = {
  ncn_ordinary : Id.t; ncn_control : Id.t; ncn_source : Id.t; ncn_view : Id.t }
let read_native_channel_nonces v =
  let f = fields v ["ordinary"; "control"; "source"; "view"] in
  { ncn_ordinary = id (required f "ordinary"); ncn_control = id (required f "control");
    ncn_source = id (required f "source"); ncn_view = id (required f "view") }
let write_native_channel_nonces n = record ["ordinary", js (Id.get n.ncn_ordinary);
  "control", js (Id.get n.ncn_control); "source", js (Id.get n.ncn_source);
  "view", js (Id.get n.ncn_view)]
type native_boot_binding = {
  nbb_instance : Id.t; nbb_backend_epoch : U.t; nbb_manager_epoch : U.t;
  nbb_artifact : Id.t; nbb_environment : Id.t; nbb_clock_boot : Id.t;
  nbb_platform : native_boot_platform; nbb_channel_nonces : native_channel_nonces;
  nbb_ordinary_operation_capacity : U.t; nbb_input_byte_quota : U.t; nbb_view_byte_quota : U.t }
let boot_instance b = b.nbb_instance
let boot_backend_epoch b = b.nbb_backend_epoch
let boot_manager_epoch b = b.nbb_manager_epoch
let boot_artifact b = b.nbb_artifact
let boot_input_quota b = b.nbb_input_byte_quota
let boot_operation_capacity b = b.nbb_ordinary_operation_capacity
let boot_channel_nonce b = function
  | Ordinary -> b.nbb_channel_nonces.ncn_ordinary
  | Control -> b.nbb_channel_nonces.ncn_control
  | Source -> b.nbb_channel_nonces.ncn_source
  | View -> b.nbb_channel_nonces.ncn_view
let expected_boot_peer b channel = expected_native ~header:(header ~instance:b.nbb_instance
    ~backend_epoch:b.nbb_backend_epoch ~manager_epoch:b.nbb_manager_epoch ~rpc_seq:(get (U.make 0L)))
    ~channel ~nonce:(boot_channel_nonce b channel) ~artifact:b.nbb_artifact
let read_native_boot_binding v =
  let f = fields v ["instance"; "backend_epoch"; "manager_epoch"; "artifact"; "environment";
    "clock_boot"; "platform"; "channel_nonces"; "ordinary_operation_capacity";
    "input_byte_quota"; "view_byte_quota"] in
  let pos value = if U.get value < 1L then bad Constraint else value in
  { nbb_instance = id (required f "instance"); nbb_backend_epoch = uint (required f "backend_epoch");
    nbb_manager_epoch = uint (required f "manager_epoch"); nbb_artifact = id (required f "artifact");
    nbb_environment = id (required f "environment"); nbb_clock_boot = id (required f "clock_boot");
    nbb_platform = read_native_boot_platform (required f "platform");
    nbb_channel_nonces = read_native_channel_nonces (required f "channel_nonces");
    nbb_ordinary_operation_capacity = pos (uint (required f "ordinary_operation_capacity"));
    nbb_input_byte_quota = pos (uint (required f "input_byte_quota"));
    nbb_view_byte_quota = pos (uint (required f "view_byte_quota")) }
let write_native_boot_binding b = record ["instance", js (Id.get b.nbb_instance);
  "backend_epoch", ji (U.get b.nbb_backend_epoch); "manager_epoch", ji (U.get b.nbb_manager_epoch);
  "artifact", js (Id.get b.nbb_artifact); "environment", js (Id.get b.nbb_environment);
  "clock_boot", js (Id.get b.nbb_clock_boot); "platform", write_native_boot_platform b.nbb_platform;
  "channel_nonces", write_native_channel_nonces b.nbb_channel_nonces;
  "ordinary_operation_capacity", ji (U.get b.nbb_ordinary_operation_capacity);
  "input_byte_quota", ji (U.get b.nbb_input_byte_quota);
  "view_byte_quota", ji (U.get b.nbb_view_byte_quota)]
let decode_native_boot_binding limits raw = decode_with read_native_boot_binding limits raw
let encode_native_boot_binding limits value = encode_with write_native_boot_binding limits value

(* NativeBoundaryFact（NN01）T2a已有typed定义，此处补独立通道入口。 *)
let decode_native_boundary_fact limits raw = decode_with read_native_boundary_fact limits raw
let encode_native_boundary_fact limits value = encode_with write_native_boundary_fact limits value

(* 改变者after=before+1、未改变者可相等、open有known frontier、closed为
   not_applicable（消费者核）。 *)
type native_line_state = LineOpen | LineRetiring | LineClosed
let native_line_state_table = ["open", LineOpen; "retiring", LineRetiring; "closed", LineClosed]
type native_line_change = {
  nlc_line : Id.t; nlc_before_revision : U.t; nlc_after_revision : U.t;
  nlc_frontier : Id.t fact; nlc_state : native_line_state }
let make_native_line_change ~line ~before_revision ~after_revision ~frontier ~state =
  (* 两个 U 的差在 int64 范围内，不对最大版本做递增。 *)
  let delta = Int64.sub (U.get after_revision) (U.get before_revision) in
  if delta <> 0L && delta <> 1L then Error Constraint
  else match state, frontier with
    | LineOpen, FKnown _ | LineClosed, FNotApplicable
    | LineRetiring, (FKnown _ | FUnknown) ->
        Ok { nlc_line = line; nlc_before_revision = before_revision; nlc_after_revision = after_revision;
          nlc_frontier = frontier; nlc_state = state }
    | _ -> Error Constraint

let read_native_line_change v =
  let f = fields v ["line"; "before_revision"; "after_revision"; "frontier"; "state"] in
  { nlc_line = id (required f "line"); nlc_before_revision = uint (required f "before_revision");
    nlc_after_revision = uint (required f "after_revision");
    nlc_frontier = read_fact id (required f "frontier");
    nlc_state = read_enum native_line_state_table (required f "state") }
let write_native_line_change c = record ["line", js (Id.get c.nlc_line);
  "before_revision", ji (U.get c.nlc_before_revision);
  "after_revision", ji (U.get c.nlc_after_revision);
  "frontier", write_fact write_id c.nlc_frontier;
  "state", write_enum native_line_state_table c.nlc_state]

(* lines精确覆盖事务前该context全部公开line、按line ID排序无重复、不含
   ImportArena（消费者核）；minItems=1。 *)
type native_line_update_document = {
  nlud_operation : Id.t; nlud_instance : Id.t; nlud_backend_epoch : U.t;
  nlud_manager_epoch : U.t; nlud_context : Id.t; nlud_old_source : Id.t;
  nlud_new_source : Id.t; nlud_before_context_revision : U.t;
  nlud_after_context_revision : U.t; nlud_lines : native_line_change list }
let make_native_line_update_document ~boot ~(binding : op_binding) ~context ~old_source ~new_source
    ~before_context_revision ~after_context_revision lines = protect (fun () ->
  if context <> binding.context then bad Constraint;
  let lines = lines |> bound65536 |> min1_list in
  let rec check_order = function
    | first :: (next :: _ as rest) ->
        if String.compare (Id.get first.nlc_line) (Id.get next.nlc_line) >= 0 then bad Constraint;
        check_order rest
    | _ -> () in
  check_order lines;
  { nlud_operation = binding.operation_id; nlud_instance = boot.nbb_instance;
    nlud_backend_epoch = boot.nbb_backend_epoch; nlud_manager_epoch = boot.nbb_manager_epoch;
    nlud_context = binding.context; nlud_old_source = old_source; nlud_new_source = new_source;
    nlud_before_context_revision = before_context_revision; nlud_after_context_revision = after_context_revision;
    nlud_lines = lines })

let read_native_line_update_document v =
  let f = fields v ["schema_version"; "operation"; "instance"; "backend_epoch";
    "manager_epoch"; "context"; "old_source"; "new_source"; "before_context_revision";
    "after_context_revision"; "lines"] in
  schema1 (required f "schema_version");
  { nlud_operation = id (required f "operation"); nlud_instance = id (required f "instance");
    nlud_backend_epoch = uint (required f "backend_epoch");
    nlud_manager_epoch = uint (required f "manager_epoch"); nlud_context = id (required f "context");
    nlud_old_source = id (required f "old_source"); nlud_new_source = id (required f "new_source");
    nlud_before_context_revision = uint (required f "before_context_revision");
    nlud_after_context_revision = uint (required f "after_context_revision");
    nlud_lines = read_list read_native_line_change (required f "lines") |> bound65536 |> min1_list }
let write_native_line_update_document d = record ["schema_version", ji 1L;
  "operation", js (Id.get d.nlud_operation); "instance", js (Id.get d.nlud_instance);
  "backend_epoch", ji (U.get d.nlud_backend_epoch); "manager_epoch", ji (U.get d.nlud_manager_epoch);
  "context", js (Id.get d.nlud_context); "old_source", js (Id.get d.nlud_old_source);
  "new_source", js (Id.get d.nlud_new_source);
  "before_context_revision", ji (U.get d.nlud_before_context_revision);
  "after_context_revision", ji (U.get d.nlud_after_context_revision);
  "lines", array_value (List.rev (List.rev_map write_native_line_change d.nlud_lines))]
let decode_native_line_update_document limits raw = decode_with read_native_line_update_document limits raw
let encode_native_line_update_document limits value = encode_with write_native_line_update_document limits value

(* ---- facts文档（build-output §3.5 native投影） ----
   投影差异恰四处：PartDescriptor.output/AssumptionRoot.raw/printed_type/
   NotationEntry.interpretation→NativeViewRef；environment.toolchain→Id。 *)

type native_part_descriptor = {
  npd_bytes : U.t; npd_digest : Digest.t; npd_output : native_view_ref }
let make_native_part_descriptor ~bytes ~digest ~view =
  { npd_bytes = bytes; npd_digest = digest; npd_output = { view_id = view } }

let read_native_part_descriptor v =
  let f = fields v ["bytes"; "digest"; "output"] in
  { npd_bytes = uint (required f "bytes");
    npd_digest = get (Digest.make (string (required f "digest")));
    npd_output = read_native_view_ref (required f "output") }
let write_native_part_descriptor d = record ["bytes", ji (U.get d.npd_bytes);
  "digest", js (Digest.get d.npd_digest); "output", write_native_view_ref d.npd_output]

type native_hypothesis = {
  nh_index : U.t; nh_names : Text.t list;
  nh_body : native_part_descriptor fact; nh_type : native_part_descriptor }
let make_native_hypothesis ~index ~names ~body ~ty = protect (fun () ->
  if U.get index = 0L then bad Constraint;
  { nh_index = index; nh_names = bound65536 names; nh_body = body; nh_type = ty })

let read_native_hypothesis v =
  let f = fields v ["index"; "names"; "body"; "type"] in
  { nh_index = uint (required f "index");
    nh_names = read_list text (required f "names") |> bound65536;
    nh_body = read_fact read_native_part_descriptor (required f "body");
    nh_type = read_native_part_descriptor (required f "type") }
let write_native_hypothesis h = record ["index", ji (U.get h.nh_index);
  "names", array_value (List.rev (List.rev_map (fun t -> js (Text.get t)) h.nh_names));
  "body", write_fact write_native_part_descriptor h.nh_body;
  "type", write_native_part_descriptor h.nh_type]

type native_goal_entry = {
  nge_selector : goal_selector; nge_hypotheses : native_hypothesis list;
  nge_conclusion : native_part_descriptor }
let goal_group_is_stack = function StackLeft | StackRight -> true | _ -> false

let check_one_based check entries =
  let rec loop index = function
    | [] -> ()
    | entry :: rest -> check index entry; loop (Int64.succ index) rest in
  loop 1L entries

let make_native_goal_entry ~group ~depth ~index ~hypotheses ~conclusion = protect (fun () ->
  if U.get index = 0L || goal_group_is_stack group <> (U.get depth > 0L) then bad Constraint;
  let hypotheses = bound65536 hypotheses in
  check_one_based (fun expected h -> if U.get h.nh_index <> expected then bad Constraint) hypotheses;
  { nge_selector = { selector_group = group; depth; index };
    nge_hypotheses = hypotheses; nge_conclusion = conclusion })

let read_native_goal_entry v =
  let f = fields v ["selector"; "hypotheses"; "conclusion"] in
  { nge_selector = read_goal_selector (required f "selector");
    nge_hypotheses = read_list read_native_hypothesis (required f "hypotheses") |> bound65536;
    nge_conclusion = read_native_part_descriptor (required f "conclusion") }
let write_native_goal_entry e = record ["selector", write_goal_selector e.nge_selector;
  "hypotheses", array_value (List.rev (List.rev_map write_native_hypothesis e.nge_hypotheses));
  "conclusion", write_native_part_descriptor e.nge_conclusion]

type native_goal_group = {
  ngg_group : goal_group; ngg_depth : U.t; ngg_total : U.t; ngg_entries : native_goal_entry list }
let make_native_goal_group ~group ~depth ~total ~entries = protect (fun () ->
  let entries = bound65536 entries in
  let depth_is_zero = U.get depth = 0L in
  let count = U.get total in
  if (if goal_group_is_stack group then depth_is_zero && count <> 0L else not depth_is_zero)
  then bad Constraint;
  let rec check_window expected = function
    | [] -> ()
    | entry :: rest ->
        let selector = entry.nge_selector in
        if expected = 0L || expected > count || selector.selector_group <> group
           || selector.depth <> depth || U.get selector.index <> expected then bad Constraint;
        check_window (Int64.succ expected) rest in
  (match entries with
   | [] -> ()
   | first :: _ -> check_window (U.get first.nge_selector.index) entries);
  { ngg_group = group; ngg_depth = depth; ngg_total = total; ngg_entries = entries })

let read_native_goal_group v =
  let f = fields v ["group"; "depth"; "total"; "entries"] in
  { ngg_group = read_enum goal_group_table (required f "group"); ngg_depth = uint (required f "depth");
    ngg_total = uint (required f "total");
    ngg_entries = read_list read_native_goal_entry (required f "entries") |> bound65536 }
let write_native_goal_group g = record ["group", write_enum goal_group_table g.ngg_group;
  "depth", ji (U.get g.ngg_depth); "total", ji (U.get g.ngg_total);
  "entries", array_value (List.rev (List.rev_map write_native_goal_entry g.ngg_entries))]

type native_goal_roster = {
  ngr_groups : native_goal_group list; ngr_next : cursor fact; ngr_complete : bool }
let read_native_goal_roster v =
  let f = fields v ["groups"; "next"; "complete"] in
  { ngr_groups = read_list read_native_goal_group (required f "groups") |> bound65536;
    ngr_next = read_fact read_cursor (required f "next");
    ngr_complete = boolean (required f "complete") }
let write_native_goal_roster r = record ["groups", array_value (List.rev (List.rev_map write_native_goal_group r.ngr_groups));
  "next", write_fact write_cursor r.ngr_next; "complete", bool_value r.ngr_complete]

(* range字节长=text UTF-8长度、eof iff end=total_bytes、digest是整个part非本页
   （消费者核）。 *)
type native_goal_part = {
  ngp_goal : goal_selector; ngp_part : goal_part; ngp_range : byte_range;
  ngp_total_bytes : U.t; ngp_text : string; ngp_part_digest : Digest.t; ngp_eof : bool }
let read_native_goal_part v =
  let f = fields v ["goal"; "part"; "range"; "total_bytes"; "text"; "part_digest"; "eof"] in
  { ngp_goal = read_goal_selector (required f "goal"); ngp_part = read_goal_part (required f "part");
    ngp_range = read_byte_range (required f "range"); ngp_total_bytes = uint (required f "total_bytes");
    ngp_text = text65536 (required f "text");
    ngp_part_digest = get (Digest.make (string (required f "part_digest")));
    ngp_eof = boolean (required f "eof") }
let write_native_goal_part p = record ["goal", write_goal_selector p.ngp_goal;
  "part", write_goal_part p.ngp_part; "range", write_byte_range p.ngp_range;
  "total_bytes", ji (U.get p.ngp_total_bytes); "text", js p.ngp_text;
  "part_digest", js (Digest.get p.ngp_part_digest); "eof", bool_value p.ngp_eof]

type assumption_status = AsmClosed | AsmAssumptions | AsmUnavailable
let assumption_status_table = ["closed", AsmClosed; "assumptions", AsmAssumptions; "unavailable", AsmUnavailable]
type native_assumption_item = { nai_kernel_name : Text.t; nai_printed_type : native_view_ref }
let make_assumption_item ~kernel_name ~printed_type =
  { nai_kernel_name = kernel_name; nai_printed_type = { view_id = printed_type } }

let read_native_assumption_item v =
  let f = fields v ["kernel_name"; "printed_type"] in
  { nai_kernel_name = text (required f "kernel_name");
    nai_printed_type = read_native_view_ref (required f "printed_type") }
let write_native_assumption_item i = record ["kernel_name", js (Text.get i.nai_kernel_name);
  "printed_type", write_native_view_ref i.nai_printed_type]
type native_assumption_root = {
  nar_requested : Text.t; nar_resolved : string fact; nar_status : assumption_status;
  nar_assumptions : native_assumption_item list; nar_raw : native_view_ref;
  nar_error : string fact }
let check_facts_text = function
  | FKnown s -> ignore (get (text0_bound 65536 s))
  | FUnknown | FNotApplicable -> ()

let make_assumption_root ~requested ~resolved ~status ~assumptions ~raw ~error = protect (fun () ->
  let assumptions = bound65536 assumptions in
  if status = AsmClosed && assumptions <> [] then bad Constraint;
  check_facts_text resolved;
  check_facts_text error;
  { nar_requested = requested; nar_resolved = resolved; nar_status = status;
    nar_assumptions = assumptions; nar_raw = { view_id = raw }; nar_error = error })

let read_native_assumption_root v =
  let f = fields v ["requested"; "resolved"; "status"; "assumptions"; "raw"; "error"] in
  { nar_requested = text (required f "requested");
    nar_resolved = read_fact text65536 (required f "resolved");
    nar_status = read_enum assumption_status_table (required f "status");
    nar_assumptions = read_list read_native_assumption_item (required f "assumptions") |> bound65536;
    nar_raw = read_native_view_ref (required f "raw");
    nar_error = read_fact text65536 (required f "error") }
let write_native_assumption_root r = record ["requested", js (Text.get r.nar_requested);
  "resolved", write_fact js r.nar_resolved;
  "status", write_enum assumption_status_table r.nar_status;
  "assumptions", array_value (List.rev (List.rev_map write_native_assumption_item r.nar_assumptions));
  "raw", write_native_view_ref r.nar_raw;
  "error", write_fact js r.nar_error]
type native_assumptions = { na_roots : native_assumption_root list }
let read_native_assumptions v =
  let f = fields v ["roots"] in
  { na_roots = read_list read_native_assumption_root (required f "roots") |> bound65536 }
let write_native_assumptions a = record ["roots", array_value (List.rev (List.rev_map write_native_assumption_root a.na_roots))]

(* 根parent=not_applicable、非根known且小于自身index（消费者核）。 *)
type native_toc_entry = {
  nte_index : U.t; nte_parent : U.t fact; nte_name : Text.t;
  nte_kind : Text.t; nte_range : byte_range }
let read_native_toc_entry v =
  let f = fields v ["index"; "parent"; "name"; "kind"; "range"] in
  { nte_index = uint (required f "index"); nte_parent = read_fact uint (required f "parent");
    nte_name = text (required f "name"); nte_kind = text (required f "kind");
    nte_range = read_byte_range (required f "range") }
let write_native_toc_entry e = record ["index", ji (U.get e.nte_index);
  "parent", write_fact write_uint e.nte_parent; "name", js (Text.get e.nte_name);
  "kind", js (Text.get e.nte_kind); "range", write_byte_range e.nte_range]
type native_toc = { nt_entries : native_toc_entry list; nt_complete : bool }
let read_native_toc v =
  let f = fields v ["entries"; "complete"] in
  { nt_entries = read_list read_native_toc_entry (required f "entries") |> bound65536;
    nt_complete = boolean (required f "complete") }
let write_native_toc t = record ["entries", array_value (List.rev (List.rev_map write_native_toc_entry t.nt_entries));
  "complete", bool_value t.nt_complete]

type native_notation_entry = {
  nne_notation : Text.t; nne_scope : string fact;
  nne_interpretation : native_view_ref; nne_location : byte_range fact }
let make_notation_entry ~notation ~scope ~interpretation ~location = protect (fun () ->
  check_facts_text scope;
  { nne_notation = notation; nne_scope = scope; nne_interpretation = { view_id = interpretation };
    nne_location = location })

let read_native_notation_entry v =
  let f = fields v ["notation"; "scope"; "interpretation"; "location"] in
  { nne_notation = text (required f "notation");
    nne_scope = read_fact text65536 (required f "scope");
    nne_interpretation = read_native_view_ref (required f "interpretation");
    nne_location = read_fact read_byte_range (required f "location") }
let write_native_notation_entry e = record ["notation", js (Text.get e.nne_notation);
  "scope", write_fact js e.nne_scope;
  "interpretation", write_native_view_ref e.nne_interpretation;
  "location", write_fact write_byte_range e.nne_location]
type native_notations = { nn_entries : native_notation_entry list; nn_complete : bool }
let read_native_notations v =
  let f = fields v ["entries"; "complete"] in
  { nn_entries = read_list read_native_notation_entry (required f "entries") |> bound65536;
    nn_complete = boolean (required f "complete") }
let write_native_notations n = record ["entries", array_value (List.rev (List.rev_map write_native_notation_entry n.nn_entries));
  "complete", bool_value n.nn_complete]

(* physical_mapping为受控映射ID，不公开任意缓存路径。 *)
type native_import_entry = {
  nie_logical_name : Text.t; nie_artifact_digest : Digest.t; nie_physical_mapping : Id.t }
let make_import_entry ~logical_name ~artifact_digest ~physical_mapping =
  { nie_logical_name = logical_name; nie_artifact_digest = artifact_digest;
    nie_physical_mapping = physical_mapping }

let read_native_import_entry v =
  let f = fields v ["logical_name"; "artifact_digest"; "physical_mapping"] in
  { nie_logical_name = text (required f "logical_name");
    nie_artifact_digest = get (Digest.make (string (required f "artifact_digest")));
    nie_physical_mapping = id (required f "physical_mapping") }
let write_native_import_entry e = record ["logical_name", js (Text.get e.nie_logical_name);
  "artifact_digest", js (Digest.get e.nie_artifact_digest);
  "physical_mapping", js (Id.get e.nie_physical_mapping)]
(* toolchain由Ref<environment>替成Id（build-output §3.5:300）。 *)
type native_environment_facts = {
  nef_toolchain : Id.t; nef_imports : native_import_entry list;
  nef_load_mapping_digest : Digest.t; nef_complete : bool }
let read_native_environment_facts v =
  let f = fields v ["toolchain"; "imports"; "load_mapping_digest"; "complete"] in
  { nef_toolchain = id (required f "toolchain");
    nef_imports = read_list read_native_import_entry (required f "imports") |> bound65536;
    nef_load_mapping_digest = get (Digest.make (string (required f "load_mapping_digest")));
    nef_complete = boolean (required f "complete") }
let write_native_environment_facts e = record ["toolchain", js (Id.get e.nef_toolchain);
  "imports", array_value (List.rev (List.rev_map write_native_import_entry e.nef_imports));
  "load_mapping_digest", js (Digest.get e.nef_load_mapping_digest);
  "complete", bool_value e.nef_complete]

(* payload无自身判别：分支由文档kind决定（schema allOf if/then同构）。 *)
type native_facts_payload =
  | FactsGoalRoster of native_goal_roster
  | FactsGoalPart of native_goal_part
  | FactsAssumptions of native_assumptions
  | FactsToc of native_toc
  | FactsNotations of native_notations
  | FactsEnvironment of native_environment_facts

let make_assumptions_facts roots = protect (fun () ->
  FactsAssumptions { na_roots = bound65536 roots })

let make_notations_facts entries ~complete = protect (fun () ->
  FactsNotations { nn_entries = bound65536 entries; nn_complete = complete })

let make_environment_facts ~toolchain ~imports ~load_mapping_digest ~complete = protect (fun () ->
  FactsEnvironment { nef_toolchain = toolchain; nef_imports = bound65536 imports;
    nef_load_mapping_digest = load_mapping_digest; nef_complete = complete })

let make_goal_roster_facts groups ~next ~complete = protect (fun () ->
  let groups = bound65536 groups in
  (match complete, next with
   | true, FNotApplicable -> ()
   | false, FKnown _ when List.exists (fun group -> group.ngg_entries <> []) groups -> ()
   | _ -> bad Constraint);
  (* 每侧必须明确给出无帧占位，或按正深度递增给出实际帧；两者互斥。 *)
  let consume_stack side = function
    | first :: rest when first.ngg_group = side ->
        let depth = U.get first.ngg_depth in
        if depth = 0L then rest
        else
          let rec frames previous = function
            | frame :: rest when frame.ngg_group = side ->
                let depth = U.get frame.ngg_depth in
                if depth <= previous then bad Constraint;
                frames depth rest
            | rest -> rest in
          frames depth rest
    | _ -> bad Constraint in
  (match groups with
   | focused :: rest when focused.ngg_group = Focused ->
       let rest = consume_stack StackLeft rest in
       (match consume_stack StackRight rest with
        | [shelved; given_up] when shelved.ngg_group = Shelved && given_up.ngg_group = GivenUp -> ()
        | _ -> bad Constraint)
   | _ -> bad Constraint);
  FactsGoalRoster { ngr_groups = groups; ngr_next = next; ngr_complete = complete })

let make_toc_facts entries ~complete = protect (fun () ->
  let entries = bound65536 entries in
  let rec collect position acc = function
    | [] -> List.rev acc
    | (nte_index, nte_parent, nte_name, nte_kind, nte_range) :: rest ->
        if U.get nte_index <> position then bad Constraint;
        (match nte_parent with
         | FNotApplicable -> ()
         | FKnown parent when U.get parent < position -> ()
         | _ -> bad Constraint);
        let entry = { nte_index; nte_parent; nte_name; nte_kind; nte_range } in
        collect (Int64.succ position) (entry :: acc) rest in
  FactsToc { nt_entries = collect 0L [] entries; nt_complete = complete })

let make_goal_part_facts ~goal ~part ~range ~total_bytes ~text ~part_digest ~eof = protect (fun () ->
  let text = get (text0_bound 65536 text) in
  let start = U.get range.range_start and stop = U.get range.range_end in
  let total = U.get total_bytes in
  if stop > total || Int64.sub stop start <> Int64.of_int (String.length text)
     || eof <> (stop = total) then bad Constraint;
  FactsGoalPart { ngp_goal = goal; ngp_part = part; ngp_range = range;
    ngp_total_bytes = total_bytes; ngp_text = text; ngp_part_digest = part_digest; ngp_eof = eof })

let native_facts_payload_kind = function
  | FactsGoalRoster _ -> "goal_roster" | FactsGoalPart _ -> "goal_part"
  | FactsAssumptions _ -> "assumptions" | FactsToc _ -> "toc"
  | FactsNotations _ -> "notations" | FactsEnvironment _ -> "environment"
let write_native_facts_payload = function
  | FactsGoalRoster r -> write_native_goal_roster r
  | FactsGoalPart p -> write_native_goal_part p
  | FactsAssumptions a -> write_native_assumptions a
  | FactsToc t -> write_native_toc t
  | FactsNotations n -> write_native_notations n
  | FactsEnvironment e -> write_native_environment_facts e

let encode_native_facts_payload limits value = encode_with write_native_facts_payload limits value

(* kind↔facts分支配对是读取期封闭；schema_version常量1。 *)
type native_facts_document = {
  nfd_node : Id.t; nfd_source : Id.t; nfd_environment : Id.t;
  nfd_capture : capture_status; nfd_facts : native_facts_payload }

let make_native_facts_document ~node ~source ~environment ~capture payload =
  { nfd_node = node; nfd_source = source; nfd_environment = environment;
    nfd_capture = capture; nfd_facts = payload }

let read_native_facts_document v =
  let f = fields v ["schema_version"; "node"; "source"; "environment"; "kind"; "capture"; "facts"] in
  schema1 (required f "schema_version");
  let facts = match string (required f "kind") with
    | "assumptions" -> FactsAssumptions (read_native_assumptions (required f "facts"))
    | "toc" -> FactsToc (read_native_toc (required f "facts"))
    | "notations" -> FactsNotations (read_native_notations (required f "facts"))
    | "environment" -> FactsEnvironment (read_native_environment_facts (required f "facts"))
    | "goal_roster" -> FactsGoalRoster (read_native_goal_roster (required f "facts"))
    | "goal_part" -> FactsGoalPart (read_native_goal_part (required f "facts"))
    | _ -> bad Invalid_tag in
  { nfd_node = id (required f "node"); nfd_source = id (required f "source");
    nfd_environment = id (required f "environment");
    nfd_capture = read_capture_status (required f "capture"); nfd_facts = facts }
let write_native_facts_document d = record ["schema_version", ji 1L;
  "node", js (Id.get d.nfd_node); "source", js (Id.get d.nfd_source);
  "environment", js (Id.get d.nfd_environment);
  "kind", js (native_facts_payload_kind d.nfd_facts);
  "capture", write_capture_status d.nfd_capture;
  "facts", write_native_facts_payload d.nfd_facts]
let decode_native_facts_document limits raw = decode_with read_native_facts_document limits raw
let encode_native_facts_document limits value = encode_with write_native_facts_document limits value

(* ---- 兼容快照与加载观测（install-release IR18/NC01） ---- *)

(* Str4096：0..4096 UTF-8字节的保守结构界（TI §4.8:291）。 *)
let str4096 v = let s = string v in
  if String.length s > 4096 then bad Constraint; s

(* 载荷身份三元组；同版本文本不代替实际身份（IR18区）。 *)
type artifact_identity = { ai_logical_id : string; ai_sha256 : Digest.t; ai_size : U.t }
let read_artifact_identity v =
  let f = fields v ["logical_id"; "sha256"; "size"] in
  { ai_logical_id = str4096 (required f "logical_id");
    ai_sha256 = get (Digest.make (string (required f "sha256")));
    ai_size = uint (required f "size") }
let write_artifact_identity a = record ["logical_id", js a.ai_logical_id;
  "sha256", js (Digest.get a.ai_sha256); "size", ji (U.get a.ai_size)]

type runtime_init_step =
  | FindlibPackages of { ordinal : U.t; packages : string list; artifacts : artifact_identity list }
  | CoqInitModule of { ordinal : U.t; artifact : artifact_identity }
let read_runtime_init_step v = match string (required (object_ v) "kind") with
  | "findlib_packages" ->
      let f = fields v ["ordinal"; "kind"; "packages"; "artifacts"] in
      (* schema只表达maxItems=64、无uniqueItems（合同不要求去重，T2b审核处置）。 *)
      FindlibPackages { ordinal = uint (required f "ordinal");
        packages = read_list str4096 (required f "packages") |> bound64;
        artifacts = read_list read_artifact_identity (required f "artifacts") |> bound64 }
  | "coq_init_module" ->
      let f = fields v ["ordinal"; "kind"; "artifact"] in
      CoqInitModule { ordinal = uint (required f "ordinal");
        artifact = read_artifact_identity (required f "artifact") }
  | _ -> bad Invalid_tag
let write_runtime_init_step = function
  | FindlibPackages s -> record ["ordinal", ji (U.get s.ordinal); "kind", js "findlib_packages";
      "packages", array_value (List.rev (List.rev_map js s.packages));
      "artifacts", array_value (List.rev (List.rev_map write_artifact_identity s.artifacts))]
  | CoqInitModule s -> record ["ordinal", ji (U.get s.ordinal); "kind", js "coq_init_module";
      "artifact", write_artifact_identity s.artifact]

type summary_registration = { sr_tag_decimal : string; sr_name : string }
let read_summary_registration v =
  let f = fields v ["tag_decimal"; "name"] in
  { sr_tag_decimal = str4096 (required f "tag_decimal"); sr_name = str4096 (required f "name") }
let write_summary_registration s = record ["tag_decimal", js s.sr_tag_decimal; "name", js s.sr_name]

(* word_size恰32/64两支：int域内异值=CONSTRAINT、非int=TYPE_MISMATCH。 *)
type word_size = W32 | W64
let read_word_size v = match view v with
  | View_integer 32L -> W32 | View_integer 64L -> W64
  | View_integer _ -> bad Constraint | _ -> bad Type_mismatch
let write_word_size = function W32 -> ji 32L | W64 -> ji 64L
type endianness = LittleEndian | BigEndian
let endian_table = ["little", LittleEndian; "big", BigEndian]
type link_mode = LinkNative | LinkBytecode
let link_mode_table = ["native", LinkNative; "bytecode", LinkBytecode]

type compat_platform = { cp_system : string; cp_architecture : string }
let read_compat_platform v =
  let f = fields v ["system"; "architecture"] in
  { cp_system = str4096 (required f "system"); cp_architecture = str4096 (required f "architecture") }
let write_compat_platform p = record ["system", js p.cp_system; "architecture", js p.cp_architecture]
type compat_ocaml = {
  co_version : string; co_runtime_artifacts : artifact_identity list;
  co_word_size : word_size; co_endian : endianness; co_mode : link_mode }
let read_compat_ocaml v =
  let f = fields v ["version"; "runtime_artifacts"; "word_size"; "endian"; "mode"] in
  { co_version = str4096 (required f "version");
    co_runtime_artifacts = read_list read_artifact_identity (required f "runtime_artifacts") |> bound65536 |> unique_list;
    co_word_size = read_word_size (required f "word_size");
    co_endian = read_enum endian_table (required f "endian");
    co_mode = read_enum link_mode_table (required f "mode") }
let write_compat_ocaml o = record ["version", js o.co_version;
  "runtime_artifacts", array_value (List.rev (List.rev_map write_artifact_identity o.co_runtime_artifacts));
  "word_size", write_word_size o.co_word_size; "endian", write_enum endian_table o.co_endian;
  "mode", write_enum link_mode_table o.co_mode]
type loaded_plugin = {
  lp_ordinal : U.t; lp_logical_name : string; lp_artifact : artifact_identity }
let read_loaded_plugin v =
  let f = fields v ["ordinal"; "logical_name"; "artifact"] in
  { lp_ordinal = uint (required f "ordinal"); lp_logical_name = str4096 (required f "logical_name");
    lp_artifact = read_artifact_identity (required f "artifact") }
let write_loaded_plugin p = record ["ordinal", ji (U.get p.lp_ordinal);
  "logical_name", js p.lp_logical_name; "artifact", write_artifact_identity p.lp_artifact]

(* IR18唯一生产：format_id/format_version是读取期常量（ccv-rocq-state-graph/1），
   常量先于字段集：错format_id属InvalidTag不是MissingField。 *)
type checkpoint_compatibility = {
  cc_installation_id : Digest.t; cc_pet : artifact_identity;
  cc_rocq : artifact_identity list; cc_ocaml : compat_ocaml; cc_platform : compat_platform;
  cc_loaded_plugins : loaded_plugin list; cc_init_steps : runtime_init_step list;
  cc_summary_registrations : summary_registration list; cc_abi_digest : Digest.t }
let read_checkpoint_compatibility v =
  if string (required (object_ v) "format_id") <> "ccv-rocq-state-graph" then bad Invalid_tag;
  let f = fields v ["schema_version"; "format_id"; "format_version"; "installation_id";
    "pet"; "rocq"; "ocaml"; "platform"; "loaded_plugins"; "initialization_steps";
    "summary_registrations"; "abi_digest"] in
  schema1 (required f "schema_version");
  (match view (required f "format_version") with
   | View_integer 1L -> () | View_integer _ -> bad Constraint | _ -> bad Type_mismatch);
  { cc_installation_id = get (Digest.make (string (required f "installation_id")));
    cc_pet = read_artifact_identity (required f "pet");
    cc_rocq = read_list read_artifact_identity (required f "rocq") |> bound65536 |> unique_list;
    cc_ocaml = read_compat_ocaml (required f "ocaml");
    cc_platform = read_compat_platform (required f "platform");
    cc_loaded_plugins = read_list read_loaded_plugin (required f "loaded_plugins") |> bound65536 |> unique_list;
    cc_init_steps = read_list read_runtime_init_step (required f "initialization_steps") |> bound65536 |> unique_list;
    cc_summary_registrations = read_list read_summary_registration (required f "summary_registrations") |> bound65536 |> unique_list;
    cc_abi_digest = get (Digest.make (string (required f "abi_digest"))) }
let write_checkpoint_compatibility c = record ["schema_version", ji 1L;
  "format_id", js "ccv-rocq-state-graph"; "format_version", ji 1L;
  "installation_id", js (Digest.get c.cc_installation_id); "pet", write_artifact_identity c.cc_pet;
  "rocq", array_value (List.rev (List.rev_map write_artifact_identity c.cc_rocq));
  "ocaml", write_compat_ocaml c.cc_ocaml; "platform", write_compat_platform c.cc_platform;
  "loaded_plugins", array_value (List.rev (List.rev_map write_loaded_plugin c.cc_loaded_plugins));
  "initialization_steps", array_value (List.rev (List.rev_map write_runtime_init_step c.cc_init_steps));
  "summary_registrations", array_value (List.rev (List.rev_map write_summary_registration c.cc_summary_registrations));
  "abi_digest", js (Digest.get c.cc_abi_digest)]
let decode_checkpoint_compatibility limits raw = decode_with read_checkpoint_compatibility limits raw
let encode_checkpoint_compatibility limits value = encode_with write_checkpoint_compatibility limits value

(* NC01实际加载观测；complete=false不判兼容（消费者）。 *)
type loaded_role = LdPet | LdRocq | LdOcamlRuntime | LdPlugin
let loaded_role_table = ["pet", LdPet; "rocq", LdRocq; "ocaml_runtime", LdOcamlRuntime; "plugin", LdPlugin]
type loaded_kind = LkEmbedded | LkDynamic
let loaded_kind_table = ["embedded", LkEmbedded; "dynamic", LkDynamic]
type loaded_artifact = {
  la_ordinal : U.t; la_role : loaded_role; la_logical_name : string;
  la_kind : loaded_kind; la_resolved_path : string; la_artifact : artifact_identity }
let read_loaded_artifact v =
  let f = fields v ["ordinal"; "role"; "logical_name"; "kind"; "resolved_path"; "artifact"] in
  { la_ordinal = uint (required f "ordinal"); la_role = read_enum loaded_role_table (required f "role");
    la_logical_name = str4096 (required f "logical_name");
    la_kind = read_enum loaded_kind_table (required f "kind");
    la_resolved_path = str4096 (required f "resolved_path");
    la_artifact = read_artifact_identity (required f "artifact") }
let write_loaded_artifact a = record ["ordinal", ji (U.get a.la_ordinal);
  "role", write_enum loaded_role_table a.la_role; "logical_name", js a.la_logical_name;
  "kind", write_enum loaded_kind_table a.la_kind; "resolved_path", js a.la_resolved_path;
  "artifact", write_artifact_identity a.la_artifact]
type loaded_artifact_observation = {
  lao_instance_id : Id.t; lao_backend_epoch : U.t; lao_load_revision : U.t;
  lao_complete : bool; lao_format_id : string; lao_format_version : U.t;
  lao_ocaml_version : string; lao_word_size : word_size; lao_endian : endianness;
  lao_mode : link_mode; lao_platform : compat_platform; lao_loads : loaded_artifact list;
  lao_init_steps : runtime_init_step list; lao_summary_registrations : summary_registration list;
  lao_capabilities : string list }
let read_loaded_artifact_observation v =
  let f = fields v ["schema_version"; "instance_id"; "backend_epoch"; "load_revision";
    "complete"; "format_id"; "format_version"; "ocaml_version"; "word_size"; "endian";
    "mode"; "platform"; "loads"; "initialization_steps"; "summary_registrations"; "capabilities"] in
  schema1 (required f "schema_version");
  { lao_instance_id = id (required f "instance_id"); lao_backend_epoch = uint (required f "backend_epoch");
    lao_load_revision = uint (required f "load_revision"); lao_complete = boolean (required f "complete");
    lao_format_id = str4096 (required f "format_id"); lao_format_version = uint (required f "format_version");
    lao_ocaml_version = str4096 (required f "ocaml_version");
    lao_word_size = read_word_size (required f "word_size");
    lao_endian = read_enum endian_table (required f "endian");
    lao_mode = read_enum link_mode_table (required f "mode");
    lao_platform = read_compat_platform (required f "platform");
    lao_loads = read_list read_loaded_artifact (required f "loads") |> bound65536 |> unique_list;
    lao_init_steps = read_list read_runtime_init_step (required f "initialization_steps") |> bound65536 |> unique_list;
    lao_summary_registrations = read_list read_summary_registration (required f "summary_registrations") |> bound65536 |> unique_list;
    lao_capabilities = read_list str4096 (required f "capabilities") |> bound65536 |> unique_list }
let write_loaded_artifact_observation o = record ["schema_version", ji 1L;
  "instance_id", js (Id.get o.lao_instance_id); "backend_epoch", ji (U.get o.lao_backend_epoch);
  "load_revision", ji (U.get o.lao_load_revision); "complete", bool_value o.lao_complete;
  "format_id", js o.lao_format_id; "format_version", ji (U.get o.lao_format_version);
  "ocaml_version", js o.lao_ocaml_version; "word_size", write_word_size o.lao_word_size;
  "endian", write_enum endian_table o.lao_endian; "mode", write_enum link_mode_table o.lao_mode;
  "platform", write_compat_platform o.lao_platform;
  "loads", array_value (List.rev (List.rev_map write_loaded_artifact o.lao_loads));
  "initialization_steps", array_value (List.rev (List.rev_map write_runtime_init_step o.lao_init_steps));
  "summary_registrations", array_value (List.rev (List.rev_map write_summary_registration o.lao_summary_registrations));
  "capabilities", array_value (List.rev (List.rev_map js o.lao_capabilities))]
let decode_loaded_artifact_observation limits raw = decode_with read_loaded_artifact_observation limits raw
let encode_loaded_artifact_observation limits value = encode_with write_loaded_artifact_observation limits value

let checkpoint_installation c = c.cc_installation_id

(* IR19 的原生消费者对实际 NC01 字段做全量对照。安装和加载路径的授权由
   IR20/IR21 生产，不从 compatibility 文档派生。 *)
let checkpoint_observation_matches c o =
  let artifacts role = List.filter_map (fun a ->
    if a.la_role = role then Some a.la_artifact else None) o.lao_loads in
  let sorted role = List.sort (fun a b -> String.compare a.ai_logical_id b.ai_logical_id) (artifacts role) in
  let plugins = List.filter_map (fun a ->
    if a.la_role = LdPlugin then Some a else None) o.lao_loads
    |> List.mapi (fun i a -> { lp_ordinal = get (U.make (Int64.of_int i));
      lp_logical_name = a.la_logical_name; lp_artifact = a.la_artifact }) in
  let digest_matches = match view (write_checkpoint_compatibility c) with
    | View_object fields ->
        let preimage = object_value (StringMap.bindings (StringMap.remove "abi_digest" fields)) in
        let limits = Option.get (Strict_json.limits ~max_bytes:8388608 ~max_depth:64) in
        (match Result.bind preimage (canonical limits) with
         | Ok raw -> Strict_json.sha256 raw = Digest.get c.cc_abi_digest
         | Error _ -> false)
    | _ -> false in
  o.lao_complete && o.lao_format_id = "ccv-rocq-state-graph" && U.get o.lao_format_version = 1L
  && o.lao_platform = c.cc_platform && artifacts LdPet = [c.cc_pet]
  && c.cc_rocq <> [] && sorted LdRocq = c.cc_rocq
  && c.cc_ocaml.co_runtime_artifacts <> [] && sorted LdOcamlRuntime = c.cc_ocaml.co_runtime_artifacts
  && o.lao_ocaml_version = c.cc_ocaml.co_version && o.lao_word_size = c.cc_ocaml.co_word_size
  && o.lao_endian = c.cc_ocaml.co_endian && o.lao_mode = c.cc_ocaml.co_mode
  && plugins = c.cc_loaded_plugins && o.lao_init_steps = c.cc_init_steps
  && o.lao_summary_registrations = c.cc_summary_registrations && digest_matches

(* IR21 走已冻结 CheckpointPreloadPlan 文档，不把 RuntimeInitStep 中的历史
   ArtifactIdentity 当作可在当前实例直接加载的路径。 *)
type resolved_load_artifact = { rla_artifact : artifact_identity; rla_path : string }
let read_resolved_load_artifact v =
  let f = fields v ["artifact"; "resolved_path"] in
  { rla_artifact = read_artifact_identity (required f "artifact"); rla_path = str4096 (required f "resolved_path") }
let write_resolved_load_artifact a = record ["artifact", write_artifact_identity a.rla_artifact; "resolved_path", js a.rla_path]

type checkpoint_preload_step =
  | PreloadFindlib of U.t * string list * resolved_load_artifact list
  | PreloadModule of U.t * resolved_load_artifact
let read_checkpoint_preload_step v = match string (required (object_ v) "kind") with
  | "findlib_packages" ->
      let f = fields v ["kind"; "ordinal"; "packages"; "artifacts"] in
      PreloadFindlib (uint (required f "ordinal"), read_list str4096 (required f "packages") |> bound64,
        read_list read_resolved_load_artifact (required f "artifacts") |> bound64)
  | "coq_init_module" ->
      let f = fields v ["kind"; "ordinal"; "artifact"] in
      PreloadModule (uint (required f "ordinal"), read_resolved_load_artifact (required f "artifact"))
  | _ -> bad Invalid_tag
let write_checkpoint_preload_step = function
  | PreloadFindlib (ordinal, packages, artifacts) -> record ["kind", js "findlib_packages";
      "ordinal", ji (U.get ordinal); "packages", array_value (List.map js packages);
      "artifacts", array_value (List.map write_resolved_load_artifact artifacts)]
  | PreloadModule (ordinal, artifact) -> record ["kind", js "coq_init_module";
      "ordinal", ji (U.get ordinal); "artifact", write_resolved_load_artifact artifact]

type checkpoint_preload_plan = {
  cpp_installation : Digest.t; cpp_compatibility : Digest.t; cpp_steps : checkpoint_preload_step list }
let read_checkpoint_preload_plan v =
  let f = fields v ["installation_id"; "compatibility_digest"; "steps"] in
  { cpp_installation = get (Digest.make (string (required f "installation_id")));
    cpp_compatibility = get (Digest.make (string (required f "compatibility_digest")));
    cpp_steps = read_list read_checkpoint_preload_step (required f "steps") |> bound65536 |> unique_list }
let write_checkpoint_preload_plan p = record ["installation_id", js (Digest.get p.cpp_installation);
  "compatibility_digest", js (Digest.get p.cpp_compatibility);
  "steps", array_value (List.rev (List.rev_map write_checkpoint_preload_step p.cpp_steps))]
let decode_checkpoint_preload_plan limits raw = decode_with read_checkpoint_preload_plan limits raw
let encode_checkpoint_preload_plan limits value = encode_with write_checkpoint_preload_plan limits value

let checkpoint_line_identity x = x.clb_lineage, x.clb_native_line.nv_id, x.clb_native_line.nv_revision

let checkpoint_selected_group selection ~control ~group =
  if selection.cs_control_id <> control then None
  else match List.filter (fun g -> g.cg_group_id = group) selection.cs_groups with
    | [x] -> Some x
    | _ -> None

let checkpoint_plan_group plan ~group =
  match List.filter (fun g -> g.cg_group_id = group) plan.scp_groups with
  | [found] -> Some (plan.scp_control_id, found, plan.scp_selection, plan.scp_requirements, plan.scp_source_materials)
  | _ -> None

(* Receipt的独立通道入口（native_receipt向量/dispatch用）与RC04摘要域。 *)
let read_receipt_typed v =
  let f = fields v ["key"; "binding"; "execution_extent"; "payload"] in
  { key = read_receipt_key (required f "key"); binding = read_op_binding (required f "binding");
    execution_extent = read_extent (required f "execution_extent");
    payload = read_receipt_payload (required f "payload") }
let decode_receipt limits raw = decode_with read_receipt_typed limits raw
let encode_receipt limits value = encode_with write_receipt limits value

(* ---- OC06 surface：构建期编入的四surface静态表（compiled_surfaces.ml，由
   build.py对stage副本逐字节对账后编译）；此处只做固定match常量选择，
   无文件加载或运行schema解释。实际handler注册按静态表exact-set核（B08侧），
   不由本表自证。 ---- *)
module Surface = struct
  type t = Mcp | Pet | Manager_control | Supervisor_control
  (* 表载荷即编入method_def数组引用；逐表SHA256前像与发射器同一格式定义。 *)
  type method_definition = Compiled_surfaces.method_def
  type definition = {
    surface : t;
    table_sha256 : string;
    methods : method_definition array;
  }
  let to_name = function
    | Mcp -> "mcp"
    | Pet -> "pet"
    | Manager_control -> "manager_control"
    | Supervisor_control -> "supervisor_control"
  let all = [Mcp; Pet; Manager_control; Supervisor_control]
  (* 全限定字段投影避免与definition同名字段歧义；仍是固定match常量选择。 *)
  let parts (table : Compiled_surfaces.surface_table) =
    (table.Compiled_surfaces.table_sha256, table.Compiled_surfaces.methods)
  let surface : t -> definition = fun value ->
    match value with
    | Mcp ->
        let table_sha256, methods = parts Compiled_surfaces.mcp_table in
        { surface = Mcp; table_sha256; methods }
    | Pet ->
        let table_sha256, methods = parts Compiled_surfaces.pet_table in
        { surface = Pet; table_sha256; methods }
    | Manager_control ->
        let table_sha256, methods = parts Compiled_surfaces.manager_control_table in
        { surface = Manager_control; table_sha256; methods }
    | Supervisor_control ->
        let table_sha256, methods = parts Compiled_surfaces.supervisor_control_table in
        { surface = Supervisor_control; table_sha256; methods }
end

(* ---- U3 nativeface request view / reply builders ---- *)

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

let native_request_view = function
  | BeginLine (header, args) ->
      BeginLineRequest
        ( header, args.binding, args.line, args.expected_revision,
           args.script_source,
           match args.edit with Append -> true | ReplaceFrom _ -> false )
  | LocateContext (header, args) -> LocateContextRequest (header, args)
  | SelectLine (header, args) -> SelectLineRequest (header, args)
  | EndScope (header, args) ->
      EndScopeRequest (header, args.es_binding, args.es_scope, args.es_expected_revision)
  | ForkLine (header, args) -> ForkLineRequest (header, args)
  | Query (header, args) ->
      let selector = args.selector in
      let range = selector.selector_range in
      QueryRequest (header, args.q_binding, args.node,
        (selector.selector_source, range.range_start, range.range_end), args.output_budget)
  | Inspect (header, args) ->
      InspectRequest (header, args.i_binding, args.i_node, args.i_selector, args.i_output_budget)
  | SyncSource (header, args) ->
      let expected = args.ss_expected_context in
      SyncSourceRequest (header, args.ss_binding, args.ss_context,
        (expected.nv_id, expected.nv_revision), args.old_source, args.new_source, args.ss_publication)
  | RefreshEnvironment (header, args) ->
      RefreshEnvironmentRequest (header, args.re_binding, args.old_environment, args.new_environment,
        args.publication)
  | PullStep (header, args) ->
      PullStepRequest (header, args.ps_binding, args.expected_step_seq)
  | AckStep (header, args) ->
      AckStepRequest (header, args.as_binding, args.proof)
  | OperationStatus (header, args) ->
      OperationStatusRequest (header, args.binding)
  | SettleInterrupt (header, args) ->
      SettleInterruptRequest (header, args.binding)
  | FinishOperation (header, args) ->
      FinishOperationRequest (header, args.fo_binding, args.terminal_receipt_key)
   | RetireThrough (header, args) -> RetireThroughRequest (header, args.through)
  | RegisterBudget (header, args) ->
      RegisterBudgetRequest (header, args.budget, args.applied_grant)
  | CheckpointObserve (header, a) -> CheckpointRequest (header, ObserveCheckpoint a)
  | CheckpointExport (header, ExportCollect a) -> CheckpointRequest (header, CollectCheckpoint a)
  | CheckpointExport (header, ExportEncode a) -> CheckpointRequest (header, EncodeCheckpoint a)
  | CheckpointImport (header, a) -> CheckpointRequest (header, ImportCheckpoint a)
  | CheckpointActivate (header, a) -> CheckpointRequest (header, ActivateCheckpoint a)
  | request -> OtherRequest (request_header request, request_method_name request)

let native_ready = Ready
let op_binding_equal a b = a = b
let op_binding_budget (b : op_binding) = b.budget
let op_binding_operation (b : op_binding) = b.operation_id
let op_binding_source (b : op_binding) = b.source
let op_binding_line_owner (b : op_binding) = (b.context, b.scope, b.environment)
let header_matches_boot boot header =
  header.instance = boot.nbb_instance && header.backend_epoch = boot.nbb_backend_epoch
  && header.manager_epoch = boot.nbb_manager_epoch
let receipt_key_equal a b = a = b
let ack_proof_equal (a : ack_proof) b = a = b
let ack_proof_receipt (proof : ack_proof) = proof.receipt
let ack_proof_durable_record (proof : ack_proof) = proof.durable_record
let header_rpc_seq (h : header) = h.rpc_seq

let op_seq (b : op_binding) = b.operation_seq
let budget_id (b : native_budget) = b.budget
let budget_scope (b : native_budget) = b.scope
let budget_purpose (b : native_budget) = b.purpose
let budget_grant (b : native_budget) = b.grant
let budget_operation_seq (b : native_budget) = b.operation_seq
let budget_revision (b : native_budget) = b.grant_revision
let budget_execution_deadline (b : native_budget) = b.execution_deadline_us
let budget_recovery_deadline (b : native_budget) = b.recovery_deadline_us
let budget_output_deadline (b : native_budget) = b.output_deadline_us
let budget_output_bytes (b : native_budget) = b.output_bytes
let boot_view_quota b = b.nbb_view_byte_quota
let boot_platform_fields b = b.nbb_platform.nbp_system, b.nbb_platform.nbp_architecture
let budget_equal (a : native_budget) b = a = b
let locate_fields a =
  let version = function KKnown v -> Some (v.nv_id, v.nv_revision) | KNotApplicable -> None in
  a.lc_binding, a.file, a.relative_file, a.target, a.logical_target,
  version a.lineage, version a.expected_context

let select_fields a =
  a.sl_binding, a.destination, a.sl_expected_revision, a.candidate, a.durable_path,
  a.group = KNotApplicable

let select_group (a : args_select_line) = match a.group with
  | KKnown g -> Some (g.group, g.expected_revision)
  | KNotApplicable -> None

let fork_fields a =
  a.fl_binding, a.fl_parent, (a.expected_line.nv_id, a.expected_line.nv_revision),
  a.new_line, a.exploration

let budget_for_task_entry boot (b : native_budget) =
  b.clock_boot = boot.nbb_clock_boot
  && b.environment = boot.nbb_environment && b.purpose = Task
  && b.checkpoint_limits = KNotApplicable
  && (match b.initial_request.irb_method with
      | ImBeginLine | ImLocateContext | ImSelectLine | ImForkLine | ImQuery | ImInspect
      | ImSyncSource | ImRefreshEnvironment -> true
      | _ -> false)
  && b.initial_request.phase = PhaseNa

let budget_for_checkpoint_entry boot (b : native_budget) =
  b.clock_boot = boot.nbb_clock_boot && b.environment = boot.nbb_environment
  && b.recovery_deadline_us >= b.execution_deadline_us
  && match b.purpose, b.checkpoint_limits, b.initial_request.irb_method, b.initial_request.phase with
  | CheckpointControl _, KKnown _, ImCheckpointObserve, PhaseNa -> true
  | CheckpointControl { operation = Export; _ }, KKnown _, ImCheckpointExport, PhaseKnown _ -> true
  | CheckpointControl { operation = Import; _ }, KKnown _, (ImCheckpointImport | ImCheckpointActivate), PhaseNa -> true
  | _ -> false

let checkpoint_artifact_budget input (b : native_budget) transfer =
  let artifact = transfer.ct_artifact in
  match b.purpose, b.checkpoint_limits with
  | CheckpointControl p, KKnown limits when
      b.operation = transfer.ct_operation && b.operation_seq = transfer.ct_operation_seq
      && p.control = transfer.ct_control && p.attempt = transfer.ct_attempt
      && transfer.ct_transfer = artifact.artifact_id ->
    let allowed = match input, p.operation, b.initial_request.irb_method, b.initial_request.phase, artifact.artifact_kind with
      | true, Import, ImCheckpointObserve, PhaseNa, CkPreloadPlan
      | true, Export, ImCheckpointExport, PhaseKnown Collect, (CkSelection | CkCompatibility)
      | true, Export, ImCheckpointExport, PhaseKnown Encode, (CkPlan | CkRequirements | CkCompatibility)
      | true, Import, ImCheckpointImport, PhaseNa, (CkPlan | CkRequirements | CkCompatibility | CkManifest | CkBundle)
      | false, _, ImCheckpointObserve, PhaseNa, CkObservation
      | false, Export, ImCheckpointExport, PhaseKnown Collect, CkRequirements
      | false, Export, ImCheckpointExport, PhaseKnown Encode, (CkManifest | CkBundle)
      | false, Import, ImCheckpointImport, PhaseNa, CkMap -> true
      | _ -> false in
    if allowed then Some (limits.metadata_bytes, limits.bundle_bytes) else None
  | _ -> None

let checkpoint_input_budget = checkpoint_artifact_budget true
let checkpoint_output_budget = checkpoint_artifact_budget false

let checkpoint_pending_import (b : native_budget) =
  match b.purpose, b.initial_request.irb_method with
  | CheckpointControl { operation = Import; _ }, ImCheckpointImport -> Some b.operation
  | _ -> None

let checkpoint_request_binding = function
  | ObserveCheckpoint a -> a.co_binding | CollectCheckpoint a -> a.ec_binding
  | EncodeCheckpoint a -> a.ee_binding | ImportCheckpoint a -> a.ci_binding
  | ActivateCheckpoint a -> a.ca_binding

let checkpoint_budget_binding (b : native_budget) = match b.purpose, b.checkpoint_limits with
  | CheckpointControl p, KKnown lim -> Some (p.control, p.attempt, lim.metadata_bytes, lim.bundle_bytes, lim.root_count)
  | _ -> None

let budget_source_environment (b : native_budget) = b.source, b.environment

let checkpoint_blob_error header code admission =
  BlobReplyError (header, { code; admission; diagnostic = FUnknown })

let matches_original_operation limits (b : op_binding) request =
  native_operation_digest limits request = Ok (Digest.get b.request_digest)

let entry_uses_budget limits (b : native_budget) request =
  let matches (op : op_binding) method_ =
    method_ = b.initial_request.irb_method
    && op.budget = b.budget && op.operation_seq = b.operation_seq && op.operation_id = b.operation
    && op.scope = b.scope && op.source = b.source && op.environment = b.environment
    && op.request_digest = b.initial_request.digest
    && matches_original_operation limits op request
  in
  match request with
  | BeginLine (_, args) -> matches args.binding ImBeginLine
  | LocateContext (_, args) -> matches args.lc_binding ImLocateContext
  | SelectLine (_, args) -> matches args.sl_binding ImSelectLine
  | ForkLine (_, args) -> matches args.fl_binding ImForkLine
  | Query (_, args) ->
      b.purpose = Task && b.checkpoint_limits = KNotApplicable && b.initial_request.phase = PhaseNa
      && matches args.q_binding ImQuery
  | Inspect (_, args) ->
      b.purpose = Task && b.checkpoint_limits = KNotApplicable && b.initial_request.phase = PhaseNa
      && matches args.i_binding ImInspect
  | SyncSource (_, args) ->
      b.purpose = Task && b.checkpoint_limits = KNotApplicable && b.initial_request.phase = PhaseNa
      && matches args.ss_binding ImSyncSource
  | RefreshEnvironment (_, args) ->
      b.purpose = Task && b.checkpoint_limits = KNotApplicable && b.initial_request.phase = PhaseNa
      && matches args.re_binding ImRefreshEnvironment
  | CheckpointObserve (_, a) ->
      matches a.co_binding ImCheckpointObserve && b.initial_request.phase = PhaseNa &&
      (match b.purpose, a.preload with
       | CheckpointControl p, KNotApplicable -> p.operation = Export && (p.control, p.attempt) = (a.co_control, a.co_attempt)
       | CheckpointControl p, KKnown ref -> p.operation = Import && (p.control, p.attempt) = (a.co_control, a.co_attempt)
           && ref.artifact_kind = CkPreloadPlan
       | _ -> false)
  | CheckpointExport (_, ExportCollect a) ->
      matches a.ec_binding ImCheckpointExport && b.initial_request.phase = PhaseKnown Collect
      && a.selection.artifact_kind = CkSelection && a.ec_compatibility.artifact_kind = CkCompatibility &&
      (match b.purpose with CheckpointControl p -> p.operation = Export && (p.control, p.attempt) = (a.ec_control, a.ec_attempt) | _ -> false)
  | CheckpointExport (_, ExportEncode a) ->
      matches a.ee_binding ImCheckpointExport && b.initial_request.phase = PhaseKnown Encode
      && a.plan.artifact_kind = CkPlan && a.requirements.artifact_kind = CkRequirements && a.ee_compatibility.artifact_kind = CkCompatibility &&
      (match b.purpose with CheckpointControl p -> p.operation = Export && (p.control, p.attempt) = (a.ee_control, a.ee_attempt) | _ -> false)
  | CheckpointImport (_, a) ->
      matches a.ci_binding ImCheckpointImport && b.initial_request.phase = PhaseNa
      && a.ci_plan.artifact_kind = CkPlan && a.ci_manifest.artifact_kind = CkManifest
      && a.ci_bundle.artifact_kind = CkBundle && a.ci_compatibility.artifact_kind = CkCompatibility &&
      (match b.purpose with CheckpointControl p -> p.operation = Import && (p.control, p.attempt) = (a.ci_control, a.ci_attempt) | _ -> false)
  | CheckpointActivate (_, a) ->
      matches a.ca_binding ImCheckpointActivate && b.initial_request.phase = PhaseNa
      && a.ca_mapping.artifact_kind = CkMap && a.ca_import_receipt = a.activation.import_receipt_key
      && a.ca_import_receipt.rk_operation_id = a.activation.import_operation &&
      (match b.purpose with CheckpointControl p -> p.operation = Import && p.control = a.activation.ap_control_id | _ -> false)
  | _ -> false
let fact_of_option = function Some x -> FKnown x | None -> FNotApplicable
let make_status ?(stop_requested = false) header (binding : op_binding) state acked_through ~highest_seen ~retired_through ~pending ~terminal ~last_ack =
  NativeResult
    ( header,
      StatusResult
        { status_binding = binding; state; pending = fact_of_option pending;
          terminal = fact_of_option (Option.map (fun t -> TerminalValue t) terminal); status_acked_through = acked_through;
           highest_seen; retired_through; last_ack = fact_of_option last_ack;
           stop_requested } )

let make_retiring_status header (binding : op_binding) ~highest_seen ~retired_through ~stop_requested =
  NativeResult (header, StatusResult {
    status_binding = binding; state = Retiring; pending = FNotApplicable; terminal = FNotApplicable;
    status_acked_through = get (U.make 0L); highest_seen; retired_through;
    last_ack = FNotApplicable; stop_requested })

let zero_digest () =
  get (Digest.make (String.make 64 '0'))

let key_for (binding : op_binding) receipt_seq =
  { rk_operation_id = binding.operation_id; rk_operation_seq = binding.operation_seq;
    rk_receipt_seq = receipt_seq; rk_digest = zero_digest () }

let digest_receipt receipt =
  match native_receipt_digest Strict_json.message_limits receipt with
  | Error _ -> bad Infrastructure
  | Ok digest -> get (Digest.make digest)

let seal_receipt receipt =
  let digest = digest_receipt receipt in
  { receipt with key = { receipt.key with rk_digest = digest } }

type locator_outcome =
  | LocatedRoot
  | LocatedBoundary of native_boundary_fact
  | PrefixRequired of native_target * native_boundary_fact option
  | LocateInitFailed
  | LocateTargetMissing of Id.t

let make_entry_boundary (header : header) (binding : op_binding) ~target ~node
    ~command_start ~command_end =
  { bf_instance = header.instance; bf_backend_epoch = header.backend_epoch;
    bf_manager_epoch = header.manager_epoch; bf_context = binding.context;
    bf_source = binding.source; bf_environment = binding.environment; bf_target = target;
    bf_entry_node = node; bf_entry_offset = command_end;
    bf_entry_command = { range_start = command_start; range_end = command_end };
    bf_replace_range = FUnknown }

let seal_aux binding aux_extent value =
  let aux_key = key_for binding (get (U.make 1L)) in
  let terminal = { aux_key; aux_binding = binding; aux_extent; value } in
  let digest = get (native_record_digest Strict_json.message_limits (write_aux_terminal terminal)) in
  { terminal with aux_key = { aux_key with rk_digest = get (Digest.make digest) } }

let make_source_synced_terminal binding ~context ~revision ~source ~last_valid ~reclaim ~boundary
    ~view ~digest ~bytes =
  let line_updates = { lu_view = { view_id = view }; lu_digest = digest; lu_bytes = bytes } in
  seal_aux binding CompleteKnown (SourceSynced {
    context; revision; source; last_valid; reclaim; boundary; line_updates })

let make_environment_refreshed_terminal binding ~environment ~changed ~reclaim =
  seal_aux binding CompleteKnown (EnvironmentRefreshed { environment; changed; reclaim })

let make_query_view_terminal (binding : op_binding) ~node ~view ~capture ~extent =
  let descriptor = { vd_view = { view_id = view }; vd_operation = binding.operation_id;
    vd_node = node; vd_source = binding.source; vd_environment = binding.environment;
    format = FormatText; facts_kind = FNotApplicable; capture } in
  seal_aux binding extent (ViewValue { descriptor })

let make_inspect_view_terminal (binding : op_binding) ~node ~view ~capture ~kind ~extent =
  let descriptor = { vd_view = { view_id = view }; vd_operation = binding.operation_id;
    vd_node = node; vd_source = binding.source; vd_environment = binding.environment;
    format = TypedFacts; facts_kind = FKnown kind; capture } in
  seal_aux binding extent (ViewValue { descriptor })

let make_query_error_terminal binding ~stage ~diagnostic ~last_valid ~extent =
  seal_aux binding extent (AuxError { stage; diagnostic; last_valid })

let group_version (group, expected_revision) = { group; expected_revision }

let group_version_or_na = function
  | Some pair -> KKnown (group_version pair)
  | None -> KNotApplicable

let make_fork_terminal binding ~line ~node ~revision ~group =
  seal_aux binding CompleteKnown (Forked { line; node; revision; group = group_version group })

let make_locator_terminal (binding : op_binding) ~line ~node ~revision ~cursor outcome =
  let context = binding.context in
  let value, aux_extent = match outcome with
    | LocateInitFailed -> AuxError { stage = Register; diagnostic = FUnknown; last_valid = FNotApplicable }, UnknownTail
    | LocateTargetMissing last_valid -> AuxError { stage = Parse; diagnostic = FUnknown; last_valid = FKnown last_valid }, CompleteKnown
    | LocatedRoot -> Located { context; line; node; revision; cursor; boundary = FNotApplicable }, CompleteKnown
    | LocatedBoundary boundary ->
        Located { context; line; node; revision; cursor; boundary = FKnown boundary }, CompleteKnown
    | PrefixRequired (target, boundary) ->
        let boundary = match boundary with Some b -> FKnown b | None -> FUnknown in
        NeedsPrefix { context; line; node; revision; cursor; target; boundary }, CompleteKnown
  in
  seal_aux binding aux_extent value

let locator_terminal_key t = t.aux_key
let locator_reply header t = NativeResult (header, AuxTerminalResult t)
let locator_status header t ~highest_seen ~retired_through =
  let zero = get (U.make 0L) in
  NativeResult (header, StatusResult {
    status_binding = t.aux_binding; state = TerminalState; pending = FNotApplicable;
    terminal = FKnown (AuxValueCase t); status_acked_through = zero;
    highest_seen; retired_through; last_ack = FNotApplicable; stop_requested = false })

type checkpoint_outcome =
  | ObservedArtifact of args_checkpoint_observe * artifact_ref
  | CollectedArtifact of args_checkpoint_export_collect * artifact_ref
  | ExportedArtifacts of args_checkpoint_export_encode * artifact_ref * artifact_ref
  | ImportedArtifact of args_checkpoint_import * artifact_ref
  | ActivatedArtifact of args_checkpoint_activate * Id.t

let make_checkpoint_terminal = function
  | ObservedArtifact (a, observation) -> seal_aux a.co_binding CompleteKnown (CheckpointObserved {
      control = a.co_control; attempt = a.co_attempt; observation })
  | CollectedArtifact (a, requirements) -> seal_aux a.ec_binding CompleteKnown (CheckpointCollected {
      control = a.ec_control; attempt = a.ec_attempt; selection = a.selection; group = a.ec_group; requirements })
  | ExportedArtifacts (a, manifest, bundle) -> seal_aux a.ee_binding CompleteKnown (CheckpointExported {
      control = a.ee_control; attempt = a.ee_attempt; plan = a.plan; group = a.ee_group;
      manifest; bundle; compatibility = a.ee_compatibility })
  | ImportedArtifact (a, mapping) -> seal_aux a.ci_binding CompleteKnown (CheckpointImported {
      control = a.ci_control; attempt = a.ci_attempt; cache = a.ci_cache; group = a.ci_group;
      manifest = a.ci_manifest; mapping; compatibility = a.ci_compatibility })
  | ActivatedArtifact (a, group) -> seal_aux a.ca_binding CompleteKnown (CheckpointActivated {
      import_receipt = a.ca_import_receipt; activation_id = a.activation.activation_id;
      cache = a.activation.ap_cache_id; group; mapping = a.ca_mapping })

type checkpoint_stage = CollectStage | EncodeStage | DecodeStage | ValidateStage | ActivateStage

let make_checkpoint_error binding stage ~started =
  let stage = match stage with
    | CollectStage -> CpCollect | EncodeStage -> CpEncode | DecodeStage -> CpDecode
    | ValidateStage -> CpValidate | ActivateStage -> CpActivate in
  seal_aux binding (if started then PartialKnown else NotStarted)
    (AuxError { stage; diagnostic = FUnknown; last_valid = FNotApplicable })

let checkpoint_status header binding ~highest_seen ~retired_through state terminal ~stop_requested =
  NativeResult (header, StatusResult { status_binding = binding; state; pending = FNotApplicable;
    terminal = (match terminal with Some term -> FKnown (AuxValueCase term) | None -> FNotApplicable);
    status_acked_through = get (U.make 0L); highest_seen; retired_through;
    last_ack = FNotApplicable; stop_requested })

let make_retired header through = NativeResult (header, Retired through)

let make_step_receipt (binding : op_binding) ~parent ~node ~source ~command_start
    ~command_end ~next_cursor ~line ~base_revision ~step_seq =
  let fact =
    { parent; node; source; command_start; command_end; next_cursor; line;
      base_revision; step_seq }
  in
  seal_receipt
      { key = key_for binding step_seq;
         binding; execution_extent = CompleteKnown;
         payload = Step (fact, FNotApplicable) }

let receipt_key r = r.key
let receipt_reply header r = NativeResult (header, ReceiptResult r)
let terminal_reply header r = NativeResult (header, TerminalResult r)

let make_ended_closing binding receipt_seq ~scope ~reclaim =
  (* 完整记录本轮进展；scope 仍为 Closing，不产生终态。 *)
  seal_receipt { key = key_for binding receipt_seq; binding; execution_extent = CompleteKnown;
    payload = Ended { scope; status = Closing; reclaim } }

let make_ended_closed binding receipt_seq ~scope ~reclaim =
  let receipt = seal_receipt { key = key_for binding receipt_seq; binding; execution_extent = CompleteKnown;
    payload = Ended { scope; status = Closed; reclaim } } in
  receipt, TrReceipt receipt

let make_selected_entry binding ~line ~before_revision ~after_revision ~node =
  let receipt = seal_receipt {
    key = key_for binding (get (U.make 1L)); binding; execution_extent = CompleteKnown;
    payload = Selected { line; before_revision; after_revision; node; group = FNotApplicable } }
  in
  receipt, TrReceipt receipt

let make_selected_group binding ~line ~before_revision ~after_revision ~node ~group ~group_revision =
  let receipt = seal_receipt {
    key = key_for binding (get (U.make 1L)); binding; execution_extent = CompleteKnown;
    payload = Selected { line; before_revision; after_revision; node;
      group = FKnown { group; expected_revision = group_revision } } }
  in
  receipt, TrReceipt receipt

let terminal_key = function
  | TrReceipt r -> r.key
  | TrEof c -> c.completion_key
  | TrPrefixReached c -> c.prefix_key
let terminal_is_eof = function TrEof _ -> true | _ -> false
let terminal_is_prefix_reached = function TrPrefixReached _ -> true | _ -> false
let make_interrupted_terminal binding receipt_seq ~stopped ~synchronized ~last_acked ~pending
    ~recoverable ~diagnostic ~extent =
  TrReceipt (seal_receipt {
    key = key_for binding receipt_seq; binding; execution_extent = extent;
    payload = Interrupted { stopped; synchronized; last_acked; pending; recoverable; diagnostic } })

let error_terminal binding seq ~parse ~last_valid ~group = TrReceipt (seal_receipt
  { key = key_for binding seq; binding; execution_extent = UnknownTail;
    payload = PayloadError { stage = (if parse then Parse else Execute);
      diagnostic = FUnknown; last_valid = FKnown last_valid; group = group_version_or_na group } })

let make_ack ack_receipt ~line ~line_revision ~acked_through ~group =
  { ack_receipt; ack_line = line; line_revision; acked_through; ack_group = group_version_or_na group }
let ack_reply header a = NativeResult (header, AckResult a)

let make_finished header key = NativeResult (header, Finished key)
let make_past_unavailable header operation_seq highest_seen =
  NativeResult (header, PastUnavailable { operation_seq; highest_seen })
let make_budget_registered header budget grant grant_revision =
  NativeResult (header, BudgetRegistered { budget; grant; grant_revision })

let make_eof binding seq ~acked_through ~cursor =
  let key = key_for binding seq in
  let c = { completion_key = key; completion_acked_through = acked_through; completion_cursor = cursor } in
  let digest = get (native_record_digest Strict_json.message_limits (write_completion c)) in
  TrEof { c with completion_key = { key with rk_digest = get (Digest.make digest) } }

let make_prefix_reached binding seq ~target ~acked_through ~cursor =
  let key = key_for binding seq in
  let c = { prefix_key = key; prefix_target = target; prefix_acked_through = acked_through; prefix_cursor = cursor } in
  let digest = get (native_record_digest Strict_json.message_limits (write_prefix_completion c)) in
  TrPrefixReached { c with prefix_key = { key with rk_digest = get (Digest.make digest) } }

let source_request_view = function
  | SourceBegin (header, args) ->
      SourceBeginRequest (header, args.sb_source, args.sb_size, args.sb_digest)
  | SourceChunk (header, args) ->
      SourceChunkRequest (header, args.sk_source, args.sk_offset, args.sk_bytes)
  | SourceFinish (header, args) ->
      SourceFinishRequest (header, args.sf_source)

let make_source_begun header source next_offset =
  SourceReplyResult (header, SrcBegun { src = source; next_offset })

let make_source_chunk_ack header source offset end_offset digest =
  SourceReplyResult (header, SrcChunkAck { src = source; offset; end_offset;
    ack_digest = get (Digest.make digest) })

let make_source_registered header source size digest =
  SourceReplyResult (header, SrcRegistered { src = source; size;
    reg_digest = get (Digest.make digest) })

let make_source_retired header source next_offset =
  SourceReplyResult (header, SrcRetiredChunk { src = source; next_offset })

let make_source_error header code admission diagnostic =
  SourceReplyError (header, { code; admission; diagnostic })
