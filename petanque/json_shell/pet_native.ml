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
      let expected =
        get
          (T.expected_native
             ~header:(T.hello_header hello)
             ~channel:(T.hello_channel hello)
             ~nonce:(T.hello_nonce hello)
             ~artifact:(T.boot_artifact boot))
      in
      get (T.check_hello expected peer);
      if T.hello_channel hello <> channel then fail "nativeface: channel mismatch";
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

type source = {
  mutable data : Buffer.t;
  expected_size : int64;
  expected_digest : string;
  mutable next_offset : int64;
  mutable finished : bool;
}

type operation = {
  header : T.header;
  binding : T.op_binding;
  line : T.Id.t;
  source : T.Id.t;
  expected_revision : T.U.t;
  mutable state : T.native_op_state;
  mutable step_seq : int64;
  mutable cursor : int64;
  mutable parent : T.Id.t;
  mutable pending : T.receipt_key option;
  mutable acked_through : int64;
  mutable line_revision : int64;
  mutable doc : Fleche.Doc.t option;
}

let sources : (string, source) Hashtbl.t = Hashtbl.create 17
let budgets : (string, unit) Hashtbl.t = Hashtbl.create 17
let uri_counter = ref 0
let operations : (T.op_binding * operation) list ref = ref []
let tables = Mutex.create ()

let with_tables f = Mutex.lock tables; Fun.protect ~finally:(fun () -> Mutex.unlock tables) f

let find_operation binding =
  List.find_opt (fun (known, _) -> T.op_binding_equal known binding) !operations

let source_bytes source_id =
  match Hashtbl.find_opt sources (T.Id.get source_id) with
  | Some source when source.finished -> Ok (Buffer.contents source.data)
  | Some _ -> Error "source is not complete"
  | None -> Error "source is not registered"

let source_handle request =
  let reply =
    match T.source_request_view request with
    | T.SourceBeginRequest (header, source_id, size, expected_digest) ->
        with_tables (fun () ->
            if Hashtbl.mem sources (T.Id.get source_id) then
              T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
            else begin
              Hashtbl.add sources (T.Id.get source_id)
                { data = Buffer.create (Int64.to_int (T.U.get size)); expected_size = T.U.get size;
                  expected_digest = T.Digest.get expected_digest; next_offset = 0L;
                  finished = false };
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
            | Some source when not source.finished ->
                let offset_value = T.U.get offset in
                if offset_value <> source.next_offset || length < 1 || length > 8192 then
                  T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
                else begin
                  Buffer.add_string source.data chunk;
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
            | Some source when not source.finished ->
                let actual = Buffer.contents source.data in
                if Int64.of_int (String.length actual) <> source.expected_size
                   || not (String.equal (S.sha256 actual) source.expected_digest) then
                  T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown
                else begin
                  source.finished <- true;
                  T.make_source_registered header source_id (uint source.expected_size)
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

let node_id operation step_seq =
  id (Format.asprintf "node-%s-%Ld" (T.Id.get operation.line) step_seq)

let step_reply request =
  match request with
  | T.BeginLineRequest
      (header, binding, line, expected_revision, script_source, append) ->
      if not append then
        T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
      else
        with_tables (fun () ->
            match find_operation binding with
            | Some (_, operation) ->
                T.make_status header binding operation.state (uint operation.acked_through)
                  (uint operation.step_seq) (uint 0L)
            | None ->
                begin match source_bytes script_source with
                | Error _ ->
                    T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
                | Ok _ when not (Hashtbl.mem budgets (T.Id.get (T.op_binding_budget binding))) ->
                    T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
                | Ok _ ->
                    let operation =
                      { header; binding; line; source = script_source; expected_revision;
                        state = T.Ready; step_seq = 0L; cursor = 0L;
                        parent = id (Format.asprintf "root-%s" (T.Id.get line));
                        pending = None; acked_through = 0L; line_revision = 0L;
                        doc = None }
                    in
                    operations := (binding, operation) :: !operations;
                    T.make_status header binding T.Ready (uint 0L) (uint 0L) (uint 0L)
                end)
  | T.PullStepRequest (header, binding, expected_step_seq) ->
      let operation = with_tables (fun () -> find_operation binding) in
      begin match operation with
      | None -> T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown
      | Some (_, operation) ->
          if T.U.get expected_step_seq <> Int64.succ operation.step_seq
             || operation.state <> T.Ready then
            T.make_protocol_error header T.invalid_state T.not_admitted T.fact_unknown
          else
            match source_bytes operation.source with
            | Error _ -> T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
            | Ok raw ->
                let uri =
                  incr uri_counter;
                  Lang.LUri.of_string
                    (Format.asprintf "file:///tmp/ccv_native_%d_%d.v"
                       (Unix.getpid ()) !uri_counter)
                in
                let uri = get (Lang.LUri.File.of_uri uri) in
                let token = Coq.Limits.Token.create () in
                let doc =
                  match operation.doc with
                  | Some doc -> doc
                  | None -> Shell.make_doc ~token ~uri ~raw
                in
                let doc, seen = Shell.step_doc ~token ~doc ~cursor:(Int64.to_int operation.cursor) in
                operation.doc <- Some doc;
                if not seen then begin
                  match doc.completed with
                  | Fleche.Doc.Completion.Yes _ ->
                      operation.state <- T.TerminalState;
                      T.make_eof header binding ~acked_through:(uint operation.acked_through)
                        ~cursor:(uint operation.cursor)
                  | _ ->
                      T.make_protocol_error header T.invalid_state T.not_admitted T.fact_unknown
                end else begin
                  match doc.completed with
                  | Fleche.Doc.Completion.Failed _ ->
                      T.make_protocol_error header T.invalid_state T.not_admitted T.fact_unknown
                  | _ ->
                      let node =
                        List.find_opt
                          (fun node ->
                            let range = Fleche.Doc.Node.range node in
                            range.Lang.Range.start.offset >= Int64.to_int operation.cursor)
                          doc.nodes
                      in
                      begin match node with
                      | None ->
                          T.make_protocol_error header T.invalid_state T.not_admitted T.fact_unknown
                      | Some node ->
                          let range = Fleche.Doc.Node.range node in
                          let start = range.Lang.Range.start.offset in
                          let finish = range.Lang.Range.end_.offset in
                          let node = node_id operation (Int64.succ operation.step_seq) in
                          let reply, key =
                            T.make_step_receipt header binding
                              ~parent:operation.parent ~node ~source:operation.source
                              ~command_start:(uint (Int64.of_int start))
                              ~command_end:(uint (Int64.of_int finish))
                              ~next_cursor:(uint (Int64.of_int finish))
                              ~line:operation.line
                              ~base_revision:(uint operation.line_revision)
                              ~step_seq:(uint (Int64.succ operation.step_seq))
                          in
                          operation.parent <- node;
                          operation.cursor <- Int64.of_int finish;
                          operation.step_seq <- Int64.succ operation.step_seq;
                          operation.pending <- Some key;
                          operation.state <- T.WaitAck;
                          reply
                      end
                end
      end
  | T.AckStepRequest (header, binding, proof) ->
      with_tables (fun () ->
          match find_operation binding with
          | Some (_, operation) when operation.state = T.WaitAck ->
              begin match operation.pending with
              | Some pending when T.receipt_key_equal pending proof ->
                  operation.pending <- None;
                  operation.acked_through <- operation.step_seq;
                  operation.line_revision <- Int64.succ operation.line_revision;
                  operation.state <- T.Ready;
                  T.make_ack header binding proof ~line:operation.line
                    ~line_revision:(uint operation.line_revision)
                    ~acked_through:(uint operation.acked_through)
              | _ ->
                  T.make_protocol_error header T.binding_conflict T.not_admitted T.fact_unknown
              end
          | Some _ ->
              T.make_protocol_error header T.invalid_state T.not_admitted T.fact_unknown
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.OperationStatusRequest (header, binding) ->
      with_tables (fun () ->
          match find_operation binding with
          | Some (_, operation) ->
              T.make_status header binding operation.state (uint operation.acked_through)
                (uint operation.step_seq) (uint 0L)
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown)
  | T.FinishOperationRequest (header, binding, key) ->
      with_tables (fun () ->
          match find_operation binding with
          | Some (_, operation) ->
              operation.state <- T.TerminalState;
              T.make_finished header key
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
