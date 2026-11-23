(* checkpoint 公共入口分发（spec §3 / item 3 交付 B）。
    职责：
    - source 通道上传分支 serve_upload：按 blob_request_view 处理 begin/
      chunk/finish——配对矩阵与预算核对走 T.checkpoint_input_budget（返回
      (metadata 上界, bundle 上界)，期限用预算 execution deadline）+ boot
      输入配额；块 ≤8192；Base64 自解自编（标准字母表精确 padding，与
      pet_native 的 decode 对称）；已完整同身份 begin ⇒ BlobRegistered 幂等；
      回复 T.checkpoint_blob_result（header 逐字回显）。
    - view 通道下载分支 serve_download/serve_release：pull/ack/release 按
      checkpoint.rs checkpoint_transfer 的 View 侧矩阵（T.checkpoint_output_
      budget）核对 operation/attempt/control 与输出期限；pull 出块
      BlobChunkOut（end=到总量）；ack 核对后 BlobAcked；release 在 arena
      真实清理后 BlobReleased。release 帧不携带完整 transfer（只有
      transfer/operation id），预算配对以 spool 记账的 operation 为准
      （驱动侧 checkpoint_transfer 已核过预算矩阵）。
    - ordinary 通道 run_request（CheckpointRequest 五分支）：observe/
      export_collect/export_encode 本批未接真实材料 ⇒ make_checkpoint_error
      （CpValidate/CpCollect, started:false）存 aux，不假成功；import ⇒
      材料齐 + arena.prepare 全过 ⇒ make_checkpoint_terminal
      (ImportedArtifact (args, mapping))，缺/反序列化败 ⇒ CpDecode、
      校验败 ⇒ CpValidate（均 started:true）；activate ⇒ permit 与 arena/
      导入终态核对（cache=Prepared、permit.import_operation=导入终态
      operation、import_receipt_key=ca_import_receipt、instance/epochs 与
      header（=boot）一致、binding_revision>0、导入 op 序号早于本操作）
      ⇒ phase=Activated ⇒ ActivatedArtifact (args, group)（group 取 arena
      记的导入组）；不符 ⇒ CpActivate started:true。幂等：同 binding 已有
      aux 重放原事实。准入：admit（序号/退役/预算登记/entry_uses_budget/
      budget_for_checkpoint_entry）+ checkpoint_budget_binding 与 args 的
      control/attempt 核对。
    不承诺的事：本批导入映射行留空（digest/bytes 取实际派生的 map 字节）——
    真实 map 由后续 owner 输入；观察/导出不产出真实制品；环境占用/隔离
    （require_new_work/quarantine）是驱动侧状态，Pet 侧无从核对，不伪造。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json
module Registry = Pet_registry
module Arena = Pet_checkpoint_arena

let get = function Ok value -> value | Error _ -> invalid_arg "pet_checkpoint_dispatch"
let uint value = get (T.U.make value)

(* boot 绑定（budget_for_checkpoint_entry / 输入输出配额 / epoch 核对用），
   serve() 时注入。 *)
let boot_ref : T.native_boot_binding option ref = ref None

let init ~boot =
  boot_ref := Some boot;
  Arena.init ()

(* —— Base64（标准字母表、精确 padding；与 pet_native 的 decode 对称）—— *)

let b64_char = function
  | value when value < 26 -> Char.chr (value + 65)
  | value when value < 52 -> Char.chr (value - 26 + 97)
  | value when value < 62 -> Char.chr (value - 52 + 48)
  | 62 -> '+'
  | _ -> '/'

let base64_encode raw =
  let n = String.length raw in
  let buffer = Buffer.create (4 * ((n + 2) / 3)) in
  let rec loop index =
    if index >= n then ()
    else begin
      let remaining = n - index in
      let b0 = Char.code raw.[index] in
      let b1 = if remaining > 1 then Char.code raw.[index + 1] else 0 in
      let b2 = if remaining > 2 then Char.code raw.[index + 2] else 0 in
      Buffer.add_char buffer (b64_char (b0 lsr 2));
      Buffer.add_char buffer (b64_char (((b0 land 3) lsl 4) lor (b1 lsr 4)));
      Buffer.add_char buffer
        (if remaining > 1 then
           b64_char (((b1 land 15) lsl 2) lor (b2 lsr 6))
         else '=');
      Buffer.add_char buffer
        (if remaining > 2 then b64_char (b2 land 63) else '=');
      loop (index + 3)
    end
  in
  loop 0;
  Buffer.contents buffer

let b64_value = function
  | 'A'..'Z' as c -> Char.code c - 65
  | 'a'..'z' as c -> Char.code c - 97 + 26
  | '0'..'9' as c -> Char.code c - 48 + 52
  | '+' -> 62
  | '/' -> 63
  | _ -> invalid_arg "pet_checkpoint_dispatch: invalid base64 alphabet"

let base64_decode text =
  let n = String.length text in
  if n = 0 || n mod 4 <> 0 then
    invalid_arg "pet_checkpoint_dispatch: invalid base64 length";
  let buffer = Buffer.create (n * 3 / 4) in
  let rec loop index =
    if index >= n then ()
    else begin
      let c0 = b64_value text.[index] in
      let c1 = b64_value text.[index + 1] in
      let p2 = text.[index + 2] in
      let p3 = text.[index + 3] in
      let c2 = if p2 = '=' then 0 else b64_value p2 in
      let c3 = if p3 = '=' then 0 else b64_value p3 in
      Buffer.add_char buffer (Char.chr ((c0 lsl 2) lor (c1 lsr 4)));
      if p2 <> '=' then
        Buffer.add_char buffer (Char.chr (((c1 land 15) lsl 4) lor (c2 lsr 2)));
      if p3 <> '=' then
        Buffer.add_char buffer (Char.chr (((c2 land 3) lsl 6) lor c3));
      loop (index + 4)
    end
  in
  loop 0;
  Buffer.contents buffer

(* —— 预算反查：按配对矩阵找到 transfer 所属预算 ——
   T.checkpoint_input_budget / checkpoint_output_budget 的内部守卫已核对
   operation/operation_seq/control/attempt 与 transfer id=artifact id，且
   方向矩阵（上传=Source 通道允许 kind 集，下载=View 通道允许 kind 集）与
   checkpoint.rs checkpoint_transfer 同表；返回 (metadata 上界, bundle 上界)。
   无匹配 ⇒ None（配对不符）。 *)
let find_transfer_budget ~(input : bool) (transfer : T.checkpoint_transfer) :
    (T.native_budget * (T.U.t * T.U.t)) option =
  Registry.with_tables (fun () ->
      let found = ref None in
      Registry.iter_budgets (fun budget ->
          if !found = None then
            match
              (if input then T.checkpoint_input_budget budget transfer
               else T.checkpoint_output_budget budget transfer)
            with
            | Some caps -> found := Some (budget, caps)
            | None -> ());
      !found)

(* —— source 通道：上传 begin/chunk/finish —— *)

let serve_upload (request : T.checkpoint_blob_request) : T.checkpoint_blob_reply =
  let header, view = T.checkpoint_blob_request_view request in
  let error code = T.checkpoint_blob_error header code T.not_admitted in
  match view with
  | T.BlobBeginRequest transfer -> (
      (* operation_seq=0 是 Rust 侧显式拒绝的非法身份。 *)
      if T.U.get transfer.T.ct_operation_seq <= 0L then error T.invalid_input
      else
        match find_transfer_budget ~input:true transfer with
        | None -> error T.invalid_input
        | Some (budget, (metadata_cap, bundle_cap)) -> (
            let artifact = transfer.T.ct_artifact in
            let cap =
              if artifact.T.artifact_kind = T.CkBundle then bundle_cap
              else metadata_cap
            in
            match !boot_ref with
            | None -> error T.invalid_input
            | Some boot ->
                if
                  Int64.compare (T.U.get artifact.T.artifact_bytes)
                    (T.U.get (T.boot_input_quota boot)) > 0
                then error T.Capacity
                else if Registry.deadline_expired budget `Execution then
                  error T.invalid_input
                else
                  match Arena.begin_upload transfer ~cap:(T.U.get cap) with
                  | `Registered sealed ->
                      T.checkpoint_blob_result header
                        (T.BlobRegistered { reg_artifact = sealed })
                  | `Begun next_offset ->
                      T.checkpoint_blob_result header
                        (T.BlobBegun
                           { transfer = transfer.T.ct_transfer;
                             next_offset = uint next_offset })
                  | `Rejected -> error T.invalid_input))
  | T.BlobChunkRequest (transfer, operation, offset, encoded) -> (
      match (try Ok (base64_decode encoded) with Invalid_argument _ -> Error ()) with
      | Error () -> error T.invalid_input
      | Ok chunk -> (
          match Arena.chunk_upload transfer operation (T.U.get offset) chunk with
          | `Acked (start, stop, sha) ->
              T.checkpoint_blob_result header
                (T.BlobChunkAck
                   { transfer; offset = uint start; end_offset = uint stop;
                     ack_digest = get (T.Digest.make sha) })
          | `Rejected -> error T.invalid_input))
  | T.BlobFinishRequest (transfer, operation) -> (
      match Arena.finish_upload transfer operation with
      | `Registered sealed ->
          T.checkpoint_blob_result header (T.BlobRegistered { reg_artifact = sealed })
      | `Rejected -> error T.invalid_input)
  | _ ->
      (* pull/ack/release 不属于 source 通道：配对矩阵直接拒绝。 *)
      error T.invalid_input

(* —— view 通道：下载 pull/ack —— *)

let serve_download (request : T.checkpoint_blob_request) : T.checkpoint_blob_reply =
  let header, view = T.checkpoint_blob_request_view request in
  let error code = T.checkpoint_blob_error header code T.not_admitted in
  match view with
  | T.BlobPullRequest (transfer, seq, offset, credit) -> (
      if T.U.get transfer.T.ct_operation_seq <= 0L then error T.invalid_input
      else
        match find_transfer_budget ~input:false transfer with
        | None -> error T.invalid_input
        | Some (budget, _) -> (
            match !boot_ref with
            | None -> error T.invalid_input
            | Some boot ->
                if
                  Registry.deadline_expired budget `Output
                  || Int64.compare
                       (T.U.get transfer.T.ct_artifact.T.artifact_bytes)
                       (T.U.get (T.boot_view_quota boot)) > 0
                then error T.invalid_input
                else
                  match
                    Arena.pull_download transfer ~seq:(T.U.get seq)
                      ~offset:(T.U.get offset) ~credit:(T.U.get credit)
                  with
                  | `Chunk (start, stop, text, eof) ->
                      T.checkpoint_blob_result header
                        (T.BlobChunkOut
                           { transfer = transfer.T.ct_transfer; seq;
                             offset = uint start; end_offset = uint stop;
                             out_bytes = base64_encode text; out_end = eof })
                  | `Retired next_offset ->
                      T.checkpoint_blob_result header
                        (T.BlobRetired
                           { transfer = transfer.T.ct_transfer;
                             next_offset = uint next_offset })
                  | `Rejected -> error T.invalid_input
                  | `Absent -> error T.unknown_operation))
  | T.BlobAckRequest (transfer, operation, seq, end_offset, digest) -> (
      match
        Arena.ack_download transfer ~operation ~seq:(T.U.get seq)
          ~end_offset:(T.U.get end_offset) ~digest:(T.Digest.get digest)
      with
      | `Acked (acked_seq, stop) ->
          T.checkpoint_blob_result header
            (T.BlobAcked
               { transfer; seq = uint acked_seq; end_offset = uint stop })
      | `Retired next_offset ->
          T.checkpoint_blob_result header
            (T.BlobRetired { transfer; next_offset = uint next_offset })
      | `Rejected -> error T.invalid_input
      | `Absent -> error T.unknown_operation)
  | _ ->
      (* begin/chunk/finish 不属于 view 通道。 *)
      error T.invalid_input

(* —— view 通道：release（只接受整份材料的封存/消费或放弃记录；
      reason/durable_record 不用于推导块 ACK——Rust 同口径）。 —— *)
let serve_release (request : T.checkpoint_blob_request) : T.checkpoint_blob_reply =
  let header, view = T.checkpoint_blob_request_view request in
  let error code = T.checkpoint_blob_error header code T.not_admitted in
  match view with
  | T.BlobReleaseRequest (transfer, operation, _reason, _durable_record) -> (
      match Arena.release_download transfer ~operation with
      | `Released ->
          T.checkpoint_blob_result header
            (T.BlobReleased { transfer; rel_status = T.ReleasedStatus })
      | `Rejected -> error T.invalid_input
      | `Absent -> error T.unknown_operation)
  | _ -> error T.invalid_input

(* —— ordinary 通道：CheckpointRequest 五分支 —— *)

(* 新 aux 操作的空账本：line 记 binding.context（checkpoint 操作不占执行栈，
   终态后填 aux）。 *)
let make_aux_operation binding =
  let context =
    match T.op_binding_line_owner binding with context, _, _ -> context
  in
  { Registry.binding; state = Registry.Ready; line = context;
    source = T.op_binding_source binding; expected_revision = uint 0L;
    cursor = 0L;
    parent = get (T.Id.make (Format.asprintf "root-%s" (T.Id.get context)));
    pending = None; terminal = None; aux = None; last_ack = None;
    acked_through = 0L; line_revision = 0L; doc = None;
    cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
    token = None; interrupt_snapshot = None; terminal_receipt = None;
    root_state = None }

(* 预算准入（须在 with_tables 内调用；与 pet_native.admit_new 同款 +
   checkpoint 专属预算核对）。 *)
let admit header binding (request : T.native_request) =
  let reject code = T.make_protocol_error header code T.not_admitted T.fact_unknown in
  let seq = T.U.get (T.op_seq binding) in
  if seq <= !Registry.retired_through then
    `Rejected
      (T.make_past_unavailable header (T.op_seq binding) (uint !Registry.highest_seen))
  else if seq <> Int64.succ !Registry.highest_seen then
    `Rejected (reject T.SequenceGap)
  else
    match Registry.find_budget (T.op_binding_budget binding) with
    | None -> `Rejected (reject T.invalid_input)
    | Some budget -> (
        match !boot_ref with
        | None -> `Rejected (reject T.invalid_input)
        | Some boot ->
            if
              not
                (T.entry_uses_budget S.message_limits budget request
                && T.budget_for_checkpoint_entry boot budget)
            then `Rejected (reject T.invalid_input)
            else `Admitted budget)

(* args 的 control/attempt（activate 的 permit 无 attempt 字段：entry_uses_budget
   同口径只核 control）。 *)
let view_control_attempt (view : T.checkpoint_request_view) :
    T.Id.t * T.Id.t option =
  match view with
  | T.ObserveCheckpoint args -> args.T.co_control, Some args.T.co_attempt
  | T.CollectCheckpoint args -> args.T.ec_control, Some args.T.ec_attempt
  | T.EncodeCheckpoint args -> args.T.ee_control, Some args.T.ee_attempt
  | T.ImportCheckpoint args -> args.T.ci_control, Some args.T.ci_attempt
  | T.ActivateCheckpoint args ->
      args.T.activation.T.ap_control_id, None

(* 预算配对：checkpoint_budget_binding 的 (control, attempt, metadata, bundle,
   root_count) 与 args 的 control/attempt 一致（entry_uses_budget 已核
   purpose 配对，此处显式再核一次并取出材料上界）。 *)
let budget_pairing_ok budget view =
  match T.checkpoint_budget_binding budget with
  | None -> false
  | Some (control, attempt, _, _, _) -> (
      let args_control, args_attempt = view_control_attempt view in
      T.Id.get control = T.Id.get args_control
      && (match args_attempt with
          | Some value -> T.Id.get attempt = T.Id.get value
          | None -> true))

let metadata_cap_of budget =
  match T.checkpoint_budget_binding budget with
  | Some (_, _, metadata, _, _) -> T.U.get metadata
  | None -> 0L

(* 错误终态存 aux 并回复（重读/finish 走 aux 原事实）。 *)
let error_publish header binding operation stage started =
  let aux = T.make_checkpoint_error binding stage ~started in
  operation.Registry.aux <- Some aux;
  operation.Registry.state <- Registry.TerminalState;
  T.locator_reply header aux

let terminal_publish header operation aux =
  operation.Registry.aux <- Some aux;
  operation.Registry.state <- Registry.TerminalState;
  T.locator_reply header aux

(* import：材料收集 + arena.prepare + 下载 spool 开立 + 导入终态。 *)
let run_import header binding budget (args : T.args_checkpoint_import) operation =
  let cache = args.T.ci_cache in
  let refs =
    [ args.T.ci_plan; args.T.ci_manifest; args.T.ci_bundle; args.T.ci_compatibility ]
  in
  let outcomes = List.map (fun ref -> Arena.register_import_material ~cache ref) refs in
  if List.exists (fun outcome -> outcome = `Conflict) outcomes then
    T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown
  else if List.exists (fun outcome -> outcome = `Missing) outcomes then
    (* 材料缺（驱动侧先上传后请求，缺即异常）：已准入并尝试 ⇒ 错误终态。 *)
    error_publish header binding operation T.DecodeStage true
  else
    match !boot_ref with
    | None -> error_publish header binding operation T.ValidateStage true
    | Some boot -> (
        (* instance/epochs 取 boot（run_request 已核 header 与 boot 一致）。 *)
        match
          Arena.prepare_import ~cache ~binding ~group:args.T.ci_group
            ~instance:(T.boot_instance boot)
            ~backend_epoch:(T.boot_backend_epoch boot)
            ~manager_epoch:(T.boot_manager_epoch boot)
            ~plan:args.T.ci_plan ~manifest:args.T.ci_manifest
            ~bundle:args.T.ci_bundle ~compatibility:args.T.ci_compatibility
            ~manifest_cap:(metadata_cap_of budget)
        with
        | `Conflict ->
            T.make_protocol_error header T.BindingConflict T.ExistingOperation
              T.fact_unknown
        | `Missing _ | `Decode _ ->
            error_publish header binding operation T.DecodeStage true
        | `Validate _ ->
            error_publish header binding operation T.ValidateStage true
        | `Prepared (map_bytes, mapping) ->
            (* 下载 spool 先开立（后续 pull 才有材料），再发布导入终态；
               私有恢复图登记按 cim_rows（本批行留空，无可登记项）。 *)
            Arena.open_download mapping ~operation:(T.op_binding_operation binding)
              map_bytes;
            let aux =
              T.make_checkpoint_terminal (T.ImportedArtifact (args, mapping))
            in
            terminal_publish header operation aux)

(* activate：permit 与 arena/导入终态核对 ⇒ ActivatedArtifact（group 取
   arena 记的导入组）。 *)
let run_activate header binding (args : T.args_checkpoint_activate) operation =
  let permit = args.T.activation in
  let fail () = error_publish header binding operation T.ActivateStage true in
  let epoch_ok =
    match !boot_ref with
    | Some boot ->
        T.Id.get permit.T.ap_instance = T.Id.get (T.boot_instance boot)
        && T.U.get permit.T.ap_backend_epoch
           = T.U.get (T.boot_backend_epoch boot)
        && T.U.get permit.T.ap_manager_epoch
           = T.U.get (T.boot_manager_epoch boot)
    | None -> false
  in
  if (not epoch_ok) || T.U.get permit.T.binding_revision <= 0L then fail ()
  else
    match Arena.take_for_activation permit.T.ap_cache_id with
    | None ->
        (* cache 不在 Prepared（未导入或已激活）：激活失败错误终态。 *)
        fail ()
    | Some entry -> (
        let entry : Arena.import_entry = entry in
        let import_ok =
          Registry.with_tables (fun () ->
              match Registry.find_operation_by_id permit.T.import_operation with
              | Some ({ Registry.aux = Some aux; _ } as import_op) ->
                  T.receipt_key_equal (T.locator_terminal_key aux)
                    permit.T.import_receipt_key
                  && T.receipt_key_equal (T.locator_terminal_key aux)
                       args.T.ca_import_receipt
                  && Int64.compare (T.U.get (T.op_seq import_op.Registry.binding))
                       (T.U.get (T.op_seq binding)) < 0
                  && (match entry.import_binding with
                      | Some known ->
                          T.op_binding_equal known import_op.Registry.binding
                      | None -> false)
              | _ -> false)
        in
        match (entry.group, import_ok) with
        | Some group, true ->
            Arena.mark_activated permit.T.ap_cache_id;
            let aux =
              T.make_checkpoint_terminal (T.ActivatedArtifact (args, group))
            in
            terminal_publish header operation aux
        | _ -> fail ())

let run_request ~request ~header ~view =
  match !boot_ref with
  | None -> T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | Some boot ->
      if not (T.header_matches_boot boot header) then
        T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
      else
        let binding = T.checkpoint_request_binding view in
        let admitted =
          Registry.with_tables (fun () ->
              match Registry.find_operation binding with
              | Some { aux = Some aux; _ } ->
                  (* 幂等：同 binding 已有 aux ⇒ 原样重放。 *)
                  `Replay aux
              | Some _ -> `Conflict
              | None -> (
                  match admit header binding request with
                  | `Rejected reply -> `Rejected reply
                  | `Admitted budget ->
                      Registry.highest_seen := T.U.get (T.op_seq binding);
                      let operation = make_aux_operation binding in
                      Registry.register_operation binding operation;
                      `Fresh (operation, budget)))
        in
        match admitted with
        | `Replay aux -> T.locator_reply header aux
        | `Rejected reply -> reply
        | `Conflict ->
            T.make_protocol_error header T.BindingConflict T.ExistingOperation
              T.fact_unknown
        | `Fresh (operation, budget) ->
            if not (budget_pairing_ok budget view) then
              T.make_protocol_error header T.invalid_input T.not_admitted
                T.fact_unknown
            else
              match view with
              | T.ObserveCheckpoint _ ->
                  (* observe 本批未接真实观测：明确错误终态，不假成功。 *)
                  error_publish header binding operation T.ValidateStage false
              | T.CollectCheckpoint _ ->
                  error_publish header binding operation T.CollectStage false
              | T.EncodeCheckpoint _ ->
                  error_publish header binding operation T.ValidateStage false
              | T.ImportCheckpoint args ->
                  run_import header binding budget args operation
              | T.ActivateCheckpoint args ->
                  run_activate header binding args operation
