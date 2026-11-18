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

type source_data = Staging of bytes | Sealed of string
type source = {
  mutable data : source_data;
  expected_digest : string;
  mutable next_offset : int64;
}

type operation = {
  binding : T.op_binding;
  line : T.Id.t;
  source : T.Id.t;
  expected_revision : T.U.t;
  mutable cursor : int64;
  mutable parent : T.Id.t;
  mutable pending : T.receipt option;
  mutable terminal : T.terminal_record option;
  mutable last_ack : T.ack_status option;
  mutable acked_through : int64;
  mutable line_revision : int64;
  mutable doc : Fleche.Doc.t option;
}

let sources : (string, source) Hashtbl.t = Hashtbl.create 17
let budgets : (string, unit) Hashtbl.t = Hashtbl.create 17
let reserved = ref 0L
let highest_seen = ref 0L
let uri_counter = ref 0
let operations : (T.op_binding * operation) list ref = ref []
let tables = Mutex.create ()

let with_tables f = Mutex.lock tables; Fun.protect ~finally:(fun () -> Mutex.unlock tables) f

let find_operation binding =
  List.find_opt (fun (known, _) -> T.op_binding_equal known binding) !operations

let source_bytes source_id = match Hashtbl.find_opt sources (T.Id.get source_id) with
  | Some { data = Sealed raw; _ } -> Some raw
  | _ -> None

let source_handle quota request =
  let reply =
    match T.source_request_view request with
    | T.SourceBeginRequest (header, source_id, size, expected_digest) ->
        with_tables (fun () ->
            if Hashtbl.mem sources (T.Id.get source_id) then
              T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
            else if T.U.get size > Int64.sub quota !reserved ||
                    T.U.get size > Int64.of_int Sys.max_string_length then
              T.make_source_error header T.Capacity T.not_admitted T.fact_unknown
            else begin
              Hashtbl.add sources (T.Id.get source_id)
                { data = Staging (Bytes.create (Int64.to_int (T.U.get size)));
                  expected_digest = T.Digest.get expected_digest; next_offset = 0L };
              reserved := Int64.add !reserved (T.U.get size);
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
            match Hashtbl.find_opt sources (T.Id.get source_id) with
            | Some ({ data = Staging data; _ } as source) ->
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
            match Hashtbl.find_opt sources (T.Id.get source_id) with
            | Some ({ data = Staging data; _ } as source) ->
                let size = Int64.of_int (Bytes.length data) in
                (* 锁内封存：通过后再无到可写缓冲的引用。 *)
                let actual = Bytes.unsafe_to_string data in
                if size <> source.next_offset || S.sha256 actual <> source.expected_digest then begin
                  Hashtbl.remove sources (T.Id.get source_id);
                  reserved := Int64.sub !reserved size;
                  T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
                end else begin
                  source.data <- Sealed actual;
                  T.make_source_registered header source_id (uint size)
                    source.expected_digest
                end
            | Some _ ->
                T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
            | None ->
                T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown)
  in
  reply

let rec source_loop quota fd =
  let request = get (T.decode_source_request S.message_limits (read_frame fd)) in
  let reply = source_handle quota request in
  write_frame fd (get (T.encode_source_reply S.message_limits reply));
  source_loop quota fd

let node_id operation step_seq =
  id (Format.asprintf "node-%s-%Ld" (T.Id.get operation.line) step_seq)

let status header op =
  let state = match op.pending, op.terminal with
    | Some _, _ -> T.WaitAck | _, Some _ -> T.TerminalState | _ -> T.Ready in
  T.make_status header op.binding state (uint op.acked_through) (uint !highest_seen)
    ~pending:op.pending ~terminal:op.terminal ~last_ack:op.last_ack

let pull header op =
  let token = Coq.Limits.Token.create () in
  let doc = match op.doc with
    | Some doc -> doc
    | None ->
        incr uri_counter;
        let uri = Lang.LUri.of_string (Format.asprintf "file:///tmp/ccv_native_%d_%d.v"
            (Unix.getpid ()) !uri_counter) |> Lang.LUri.File.of_uri |> get in
        let raw = with_tables (fun () -> Option.get (source_bytes op.source)) in
        Shell.make_doc ~token ~uri ~raw in
  let doc, outcome = Shell.step_doc ~token ~doc ~cursor:(Int64.to_int op.cursor) in
  let seq = uint (Int64.succ op.acked_through) in
  let finish record = op.terminal <- Some record; T.terminal_reply header record in
  match outcome with
  | `Eof -> finish (T.make_eof op.binding seq ~acked_through:(uint op.acked_through)
                      ~cursor:(uint op.cursor))
  | `Error stage -> finish (T.error_terminal op.binding seq ~parse:(stage = `Parse) ~last_valid:op.parent)
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
            match find_operation binding with
            | Some (_, op) when op.line = line && op.expected_revision = expected_revision && op.source = script_source -> status header op
            | Some _ -> T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown
            | None when T.U.get (T.op_seq binding) <> Int64.succ !highest_seen ->
                T.make_protocol_error header T.SequenceGap T.not_admitted T.fact_unknown
            | None ->
                highest_seen := T.U.get (T.op_seq binding);
                begin match source_bytes script_source with
                | _ when T.U.get expected_revision <> 0L ->
                    T.make_protocol_error header T.StaleRevision T.not_admitted T.fact_unknown
                | None ->
                    T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
                | Some _ when not (Hashtbl.mem budgets (T.Id.get (T.op_binding_budget binding))) ->
                    T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
                | Some _ ->
                    let operation =
                      { binding; line; source = script_source; expected_revision;
                        cursor = 0L;
                        parent = id (Format.asprintf "root-%s" (T.Id.get line));
                        pending = None; terminal = None; last_ack = None;
                        acked_through = 0L; line_revision = T.U.get expected_revision;
                        doc = None }
                    in
                    operations := (binding, operation) :: !operations;
                    status header operation
                end)
  | T.PullStepRequest (header, binding, expected_step_seq) ->
      let operation = with_tables (fun () -> find_operation binding) in
      begin match operation with
      | None -> T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown
      | Some (_, op) ->
          if T.U.get expected_step_seq <> Int64.succ op.acked_through then
            T.make_protocol_error header T.invalid_state T.ExistingOperation T.fact_unknown
          else match op.pending, op.terminal with
            | Some r, _ -> T.receipt_reply header r
            | _, Some t -> T.terminal_reply header t
            | _ -> pull header op
      end
  | T.AckStepRequest (header, binding, proof) ->
      with_tables (fun () ->
          match find_operation binding with
          | Some (_, operation) ->
              begin match operation.pending with
              | Some pending when T.receipt_key_equal (T.receipt_key pending) proof ->
                  operation.pending <- None;
                  operation.acked_through <- Int64.succ operation.acked_through;
                  operation.line_revision <- Int64.succ operation.line_revision;
                  let ack = T.make_ack proof ~line:operation.line
                    ~line_revision:(uint operation.line_revision)
                    ~acked_through:(uint operation.acked_through) in
                  operation.last_ack <- Some ack; T.ack_reply header ack
              | _ ->
                  T.make_protocol_error header T.binding_conflict T.not_admitted T.fact_unknown
              end
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.OperationStatusRequest (header, binding) ->
      with_tables (fun () ->
          match find_operation binding with
          | Some (_, operation) ->
              status header operation
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.FinishOperationRequest (header, binding, key) ->
      with_tables (fun () ->
          match find_operation binding with
          | Some (_, { terminal = Some t; _ }) when T.receipt_key_equal (T.terminal_key t) key ->
              T.make_finished header key
          | Some _ -> T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.RegisterBudgetRequest (header, budget, grant) ->
      with_tables (fun () ->
          Hashtbl.replace budgets (T.Id.get budget) ();
          T.make_budget_registered header budget grant (uint 1L))
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
  handshake boot ordinary T.Ordinary;
  handshake boot (fd_of_int 5) T.Control;
  handshake boot source T.Source;
  handshake boot (fd_of_int 7) T.View;
  ignore (Thread.create (source_loop (T.U.get (T.boot_input_quota boot))) source);
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
