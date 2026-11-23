(* CCV nativeface Pet: four inherited channels + boot binding.
   This slice implements the real source registration and the one-step
   begin/pull/ACK/finish surface over Fleche's parser/interpreter. *)
open Petanque_shell
module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json

let fail fmt = Format.kasprintf (fun s -> prerr_endline s; exit 2) fmt
let get = function Ok value -> value | Error _ -> fail "nativeface: protocol invariant failed"
let id value = get (T.Id.make value)
let uint value = get (T.U.make value)
let digest value = get (T.Digest.make value)

let fd_of_int (fd : int) : Unix.file_descr = Obj.magic fd

let read_exact fd bytes =
  let rec loop offset =
    if offset = Bytes.length bytes then ()
    else
      let count = Unix.read fd bytes offset (Bytes.length bytes - offset) in
      if count = 0 then fail "nativeface: unexpected EOF"
      else loop (offset + count)
  in
  loop 0

let write_all fd bytes =
  let rec loop offset =
    if offset = Bytes.length bytes then ()
    else
      let count = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      if count = 0 then fail "nativeface: write returned zero"
      else loop (offset + count)
  in
  loop 0

let read_frame fd =
  let header = Bytes.create 4 in
  read_exact fd header;
  let length =
    (Char.code (Bytes.get header 0) lsl 24)
    lor (Char.code (Bytes.get header 1) lsl 16)
    lor (Char.code (Bytes.get header 2) lsl 8)
    lor Char.code (Bytes.get header 3)
  in
  if length <= 0 || length > 65536 then fail "nativeface: invalid frame length %d" length;
  let payload = Bytes.create length in
  read_exact fd payload;
  Bytes.to_string payload

let write_frame fd raw =
  let length = String.length raw in
  if length <= 0 || length > 65536 then fail "nativeface: invalid reply length %d" length;
  let header = Bytes.create 4 in
  Bytes.set header 0 (Char.chr ((length lsr 24) land 0xff));
  Bytes.set header 1 (Char.chr ((length lsr 16) land 0xff));
  Bytes.set header 2 (Char.chr ((length lsr 8) land 0xff));
  Bytes.set header 3 (Char.chr (length land 0xff));
  write_all fd header;
  write_all fd (Bytes.of_string raw)

let b64_value = function
  | 'A'..'Z' as c -> Char.code c - 65
  | 'a'..'z' as c -> Char.code c - 97 + 26
  | '0'..'9' as c -> Char.code c - 48 + 52
  | '+' -> 62
  | '/' -> 63
  | _ -> invalid_arg "nativeface: invalid base64 alphabet"

let base64_decode text =
  let n = String.length text in
  if n = 0 || n mod 4 <> 0 then invalid_arg "nativeface: invalid base64 length";
  let buffer = Buffer.create (n * 3 / 4) in
  let rec loop index =
    if index >= n then ()
    else
      let c0 = b64_value text.[index] in
      let c1 = b64_value text.[index + 1] in
      let p2 = text.[index + 2] in
      let p3 = text.[index + 3] in
      let c2 = if p2 = '=' then 0 else b64_value p2 in
      let c3 = if p3 = '=' then 0 else b64_value p3 in
      Buffer.add_char buffer (Char.chr ((c0 lsl 2) lor (c1 lsr 4)));
      if p2 <> '=' then Buffer.add_char buffer (Char.chr (((c1 land 15) lsl 4) lor (c2 lsr 2)));
      if p3 <> '=' then Buffer.add_char buffer (Char.chr (((c2 land 3) lsl 6) lor c3));
      loop (index + 4)
  in
  loop 0;
  Buffer.contents buffer

let limits_backend = T.Control_interrupt

let handshake boot fd channel =
  let peer = get (T.decode_peer S.message_limits (read_frame fd)) in
  match peer with
  | T.Hello hello ->
      let expected = get (T.expected_boot_peer boot channel) in
      get (T.check_hello expected peer);
      let ack =
        T.hello_ack
          ~header:(T.hello_header hello)
          ~channel
          ~nonce:(T.hello_nonce hello)
          ~compatibility:(T.hello_compatibility hello)
          ~artifact:(T.boot_artifact boot)
          ~rocq_version:(get (T.Text.make "9.0.0"))
          ~ocaml_version:(get (T.Text.make Sys.ocaml_version))
          ~limits_backend
      in
      write_frame fd (get (T.encode_peer S.message_limits (T.Ack ack)))
  | T.Ack _ -> fail "nativeface: expected hello"

(* 共享运行态已迁入 Pet_registry（spec §1）：sources/budgets/operations/
   highest_seen/retired_through/with_tables 统一走 Registry。 *)
module Registry = Pet_native_support.Pet_registry

let with_tables = Registry.with_tables

let uri_counter = ref 0

let source_handle request =
  let reply =
    match T.source_request_view request with
    | T.SourceBeginRequest (header, source_id, size, expected_digest) ->
        with_tables (fun () ->
            if Registry.find_source (T.Id.get source_id) <> None then
              T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
            else if T.U.get size > Int64.of_int Sys.max_string_length then
              T.make_source_error header T.Capacity T.not_admitted T.fact_unknown
            else if not (Registry.reserve_input (T.U.get size)) then
              T.make_source_error header T.Capacity T.not_admitted T.fact_unknown
            else begin
              Registry.add_source (T.Id.get source_id)
                { data = Registry.Staging (Bytes.create (Int64.to_int (T.U.get size)));
                  expected_digest = T.Digest.get expected_digest; next_offset = 0L };
              T.make_source_begun header source_id (uint 0L)
            end)
    | T.SourceChunkRequest (header, source_id, offset, encoded) ->
        begin
        match (try Ok (base64_decode encoded) with Invalid_argument _ -> Error ()) with
        | Error () ->
            T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
        | Ok chunk ->
        let length = String.length chunk in
        with_tables (fun () ->
            match Registry.find_source (T.Id.get source_id) with
            | Some ({ data = Registry.Staging data; _ } as source) ->
                let offset_value = T.U.get offset in
                if offset_value <> source.next_offset || length < 1 || length > 8192 ||
                   length > Bytes.length data - Int64.to_int source.next_offset then
                  T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
                else begin
                  Bytes.blit_string chunk 0 data (Int64.to_int offset_value) length;
                  let next = Int64.add source.next_offset (Int64.of_int length) in
                  source.next_offset <- next;
                  T.make_source_chunk_ack header source_id
                    (uint offset_value) (uint next) (S.sha256 chunk)
                end
            | Some _ ->
                T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
            | None ->
                T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown)
        end
    | T.SourceFinishRequest (header, source_id) ->
        with_tables (fun () ->
            match Registry.find_source (T.Id.get source_id) with
            | Some ({ data = Registry.Staging data; _ } as source) ->
                let size = Int64.of_int (Bytes.length data) in
                (* 锁内封存：通过后再无到可写缓冲的引用。 *)
                let actual = Bytes.unsafe_to_string data in
                if size <> source.next_offset || S.sha256 actual <> source.expected_digest then begin
                  Registry.remove_source (T.Id.get source_id);
                  ignore (Registry.release_input size);
                  T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
                end else begin
                  source.data <- Registry.Sealed actual;
                  T.make_source_registered header source_id (uint size)
                    source.expected_digest
                end
            | Some _ ->
                T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
            | None ->
                T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown)
  in
  reply

let rec source_loop fd =
  let request = get (T.decode_source_request S.message_limits (read_frame fd)) in
  let reply = source_handle request in
  write_frame fd (get (T.encode_source_reply S.message_limits reply));
  source_loop fd

let node_id (operation : Registry.operation) step_seq =
  id (Format.asprintf "node-%s-%Ld" (T.Id.get operation.line) step_seq)

let status header (op : Registry.operation) =
  let state = match op.pending, op.terminal with
    | Some _, _ -> T.WaitAck | _, Some _ -> T.TerminalState | _ -> T.Ready in
  T.make_status header op.binding state (uint op.acked_through)
    ~highest_seen:(uint !Registry.highest_seen)
    ~retired_through:(uint !Registry.retired_through)
    ~pending:op.pending ~terminal:op.terminal ~last_ack:op.last_ack

let pull header (op : Registry.operation) =
  let token = Coq.Limits.Token.create () in
  let doc = match op.doc with
    | Some doc -> doc
    | None ->
        incr uri_counter;
        let uri = Lang.LUri.of_string (Format.asprintf "file:///tmp/ccv_native_%d_%d.v"
            (Unix.getpid ()) !uri_counter) |> Lang.LUri.File.of_uri |> get in
        let raw = with_tables (fun () -> Option.get (Registry.source_bytes op.source)) in
        Shell.make_doc ~token ~uri ~raw in
  let doc, outcome = Shell.step_doc ~token ~doc ~cursor:(Int64.to_int op.cursor) in
  let seq = uint (Int64.succ op.acked_through) in
  let finish record = op.terminal <- Some record; T.terminal_reply header record in
  match outcome with
  | `Eof -> finish (T.make_eof op.binding seq ~acked_through:(uint op.acked_through)
                      ~cursor:(uint op.cursor))
  | `Error stage -> finish (T.error_terminal op.binding seq ~parse:(stage = `Parse)
                              ~last_valid:op.parent ~group:None)
  | `Unknown -> fail "nativeface: single-step outcome unknown"
  | `Step stop ->
      let node = node_id op (T.U.get seq) and next_cursor = uint (Int64.of_int stop) in
      let r = T.make_step_receipt op.binding ~parent:op.parent ~node ~source:op.source
          ~command_start:(uint op.cursor) ~command_end:next_cursor ~next_cursor ~line:op.line
          ~base_revision:(uint op.line_revision) ~step_seq:seq in
      op.doc <- Some doc; op.parent <- node; op.cursor <- T.U.get next_cursor;
      op.pending <- Some r;
      T.receipt_reply header r

let step_reply request =
  match request with
  | T.BeginLineRequest
      (header, binding, line, expected_revision, script_source, append) ->
      if not append then
        T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
      else
        with_tables (fun () ->
            match Registry.find_operation binding with
            | Some op when op.line = line && op.expected_revision = expected_revision && op.source = script_source -> status header op
            | Some _ -> T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown
            | None when T.U.get (T.op_seq binding) <> Int64.succ !Registry.highest_seen ->
                T.make_protocol_error header T.SequenceGap T.not_admitted T.fact_unknown
            | None when T.U.get (T.op_seq binding) <= !Registry.retired_through ->
                (* 已 retire 的序号：按 spec §1 返回 past_unavailable。 *)
                T.make_past_unavailable header (T.op_seq binding)
                  (uint !Registry.highest_seen)
            | None ->
                Registry.highest_seen := T.U.get (T.op_seq binding);
                begin match Registry.source_bytes script_source with
                | _ when T.U.get expected_revision <> 0L ->
                    T.make_protocol_error header T.StaleRevision T.not_admitted T.fact_unknown
                | None ->
                    T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
                | Some _ when Registry.find_budget (T.op_binding_budget binding) = None ->
                    T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
                | Some _ ->
                    let operation : Registry.operation =
                      { binding; state = Registry.Ready; line; source = script_source; expected_revision;
                        cursor = 0L;
                        parent = id (Format.asprintf "root-%s" (T.Id.get line));
                        pending = None; terminal = None; aux = None; last_ack = None;
                        acked_through = 0L; line_revision = T.U.get expected_revision;
                        doc = None }
                    in
                    Registry.register_operation binding operation;
                    status header operation
                end)
  | T.PullStepRequest (header, binding, expected_step_seq) ->
      let operation = with_tables (fun () -> Registry.find_operation binding) in
      begin match operation with
      | None -> T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown
      | Some op ->
          if T.U.get expected_step_seq <> Int64.succ op.acked_through then
            T.make_protocol_error header T.invalid_state T.ExistingOperation T.fact_unknown
          else match op.pending, op.terminal with
            | Some r, _ -> T.receipt_reply header r
            | _, Some t -> T.terminal_reply header t
            | _ -> pull header op
      end
  | T.AckStepRequest (header, binding, proof) ->
      with_tables (fun () ->
          match Registry.find_operation binding with
          | Some operation ->
              begin match operation.pending with
              | Some pending when T.receipt_key_equal (T.receipt_key pending)
                    (T.ack_proof_receipt proof) ->
                  operation.pending <- None;
                  operation.acked_through <- Int64.succ operation.acked_through;
                  operation.line_revision <- Int64.succ operation.line_revision;
                  let ack = T.make_ack (T.ack_proof_receipt proof) ~line:operation.line
                    ~line_revision:(uint operation.line_revision)
                    ~acked_through:(uint operation.acked_through) ~group:None in
                  operation.last_ack <- Some ack; T.ack_reply header ack
              | _ ->
                  T.make_protocol_error header T.binding_conflict T.not_admitted T.fact_unknown
              end
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.OperationStatusRequest (header, binding) ->
      with_tables (fun () ->
          match Registry.find_operation binding with
          | Some operation ->
              status header operation
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.FinishOperationRequest (header, binding, key) ->
      with_tables (fun () ->
          match Registry.find_operation binding with
          | Some { terminal = Some t; _ } when T.receipt_key_equal (T.terminal_key t) key ->
              T.make_finished header key
          | Some _ -> T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.RegisterBudgetRequest (header, budget, _grant) ->
      (* NW02：存完整 T.native_budget；同内容幂等回原登记，异内容冲突。 *)
      with_tables (fun () ->
          match Registry.add_budget budget with
          | `Ok ->
              T.make_budget_registered header (T.budget_id budget)
                (T.budget_grant budget) (T.budget_revision budget)
          | `Conflict ->
              T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown)
  | T.RetireThroughRequest (header, through) ->
      (* 更新退役水位（单调取 max），水位及以下的操作此后 past_unavailable。 *)
      with_tables (fun () ->
          if Int64.compare (T.U.get through) !Registry.retired_through > 0 then
            Registry.retired_through := T.U.get through;
          T.make_retired header through)
  (* 以下分支本 item 后续块接线；当前按 spec §0 拒绝口径占位，不伪造成功。 *)
  | T.LocateContextRequest (header, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.SelectLineRequest (header, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.ForkLineRequest (header, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.SyncSourceRequest (header, _, _, _, _, _, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.RefreshEnvironmentRequest (header, _, _, _, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.QueryRequest (header, _, _, _, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.InspectRequest (header, _, _, _, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.EndScopeRequest (header, _, _, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.CheckpointRequest (header, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.SettleInterruptRequest (header, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
  | T.OtherRequest (header, _) ->
      T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown

let serve () =
  let boot =
    get
      (T.decode_native_boot_binding S.message_limits
         (read_frame (fd_of_int 3)))
  in
  let ordinary = fd_of_int 4 in
  let source = fd_of_int 6 in
  Registry.init ();
  Registry.set_input_quota (T.U.get (T.boot_input_quota boot));
  handshake boot ordinary T.Ordinary;
  handshake boot (fd_of_int 5) T.Control;
  handshake boot source T.Source;
  handshake boot (fd_of_int 7) T.View;
  ignore (Thread.create source_loop source);
  let rec loop () =
    let request = get (T.decode_native_request S.message_limits (read_frame ordinary)) in
    let reply = step_reply (T.native_request_view request) in
    write_frame ordinary (get (T.encode_native_reply S.message_limits reply));
    loop ()
  in
  loop ()

let () =
  Coq.Limits.start ();
  let token = Coq.Limits.Token.create () in
  (match Shell.init_agent ~token ~debug:false ~record_comments:false
           ~roots:[Sys.getcwd ()] with
   | Ok () -> ()
   | Error error ->
       fail "nativeface: Pet initialization failed: %s"
         (Petanque.Agent.Error.to_string error.payload));
  serve ()
