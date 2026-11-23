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

(* —— 帧级 JSON 投影（spec §1.4/§1.5 method 分派用）——
   只读提取 method 字段与可回显 header；解析不出时返回 None，调用方按
   「不伪造」口径丢弃或拒绝，绝不编造 header。 *)
let frame_method raw =
  match S.decode S.message_limits raw with
  | Error _ -> None
  | Ok value ->
      (match S.view value with
       | S.View_object fields ->
           let open S.StringMap in
           (match find_opt "method" fields with
            | Some field ->
                (match S.view field with
                 | S.View_string name -> Some name
                 | _ -> None)
            | None -> None)
       | _ -> None)

let frame_header raw =
  match S.decode S.message_limits raw with
  | Error _ -> None
  | Ok value ->
      (match S.view value with
       | S.View_object fields ->
           let open S.StringMap in
           let string_field key map =
             match find_opt key map with
             | Some field ->
                 (match S.view field with
                  | S.View_string text -> Some text
                  | _ -> None)
             | None -> None
           in
           let integer_field key map =
             match find_opt key map with
             | Some field ->
                 (match S.view field with
                  | S.View_integer value -> Some value
                  | _ -> None)
             | None -> None
           in
           (match find_opt "header" fields with
            | Some field ->
                (match S.view field with
                 | S.View_object header_fields ->
                     (match
                       string_field "instance" header_fields,
                       integer_field "backend_epoch" header_fields,
                       integer_field "manager_epoch" header_fields,
                       integer_field "rpc_seq" header_fields
                      with
                     | Some instance, Some backend_epoch, Some manager_epoch, Some rpc_seq ->
                         (match
                            T.Id.make instance, T.U.make backend_epoch,
                            T.U.make manager_epoch, T.U.make rpc_seq
                          with
                         | Ok instance, Ok backend_epoch, Ok manager_epoch, Ok rpc_seq ->
                             Some (T.header ~instance ~backend_epoch ~manager_epoch ~rpc_seq)
                         | _ -> None)
                     | _ -> None)
                 | _ -> None)
            | None -> None)
       | _ -> None)

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
  let raw = read_frame fd in
  (* spec §1.4：source 通道按帧内 method 字段分派；未知 method 帧级回错，进程不崩。 *)
  let reply =
    match frame_method raw with
    | Some ("source_begin" | "source_chunk" | "source_finish") ->
        let request = get (T.decode_source_request S.message_limits raw) in
        Some (get (T.encode_source_reply S.message_limits (source_handle request)))
    | Some ("checkpoint_blob_begin" | "checkpoint_blob_chunk" | "checkpoint_blob_finish") ->
        (* 本 item 未接 checkpoint 上传分支：通道内 protocol_error 占位。 *)
        (match T.decode_checkpoint_blob_request S.message_limits raw with
         | Ok request ->
             let header, _ = T.checkpoint_blob_request_view request in
             Some
               (get
                  (T.encode_checkpoint_blob_reply S.message_limits
                     (T.checkpoint_blob_error header T.invalid_input T.not_admitted)))
         | Error _ ->
             (* 解码失败：尽力从帧内投影可回显 header；拿不到则丢弃，不伪造。 *)
             (match frame_header raw with
              | Some header ->
                  Some
                    (get
                       (T.encode_checkpoint_blob_reply S.message_limits
                          (T.checkpoint_blob_error header T.invalid_input T.not_admitted)))
              | None -> None))
    | _ ->
        (* 未知 method：帧级回错（尽力回显 header），进程不崩。 *)
        (match frame_header raw with
         | Some header ->
             Some
               (get
                  (T.encode_source_reply S.message_limits
                     (T.make_source_error header T.invalid_input T.not_admitted T.fact_unknown)))
         | None -> None)
  in
  (match reply with
   | Some encoded -> write_frame fd encoded
   | None -> ());
  source_loop fd

(* —— 控制通道（fd 5，spec §1.3）：ReadControl / RequestCancel —— *)

(* phase 推导：执行中（pull 已标记 Executing）=Active；已有终态（terminal/aux）
   =TerminalPhase；否则 Idle。Settling（中断待落定）在块 E 接线后补充。 *)
let control_phase_of (op : Registry.operation) =
  if op.terminal <> None || op.aux <> None then T.TerminalPhase
  else
    match op.state with
    | Registry.Executing -> T.Active
    | _ -> T.Idle

let control_snapshot_of (op : Registry.operation) =
  T.make_control_snapshot
    ~operation_id:(T.op_binding_operation op.binding)
    ~phase:(control_phase_of op)
    ~token_generation:(uint op.cancel_generation)
    ~highest_cancel_seq:(uint op.cancel_seq_seen)
    ~stop_requested:op.stop_requested

let control_handle request =
  match T.control_request_view request with
  | header, T.ReadControl operation ->
      with_tables (fun () ->
          match Registry.find_operation_by_id operation with
          | Some op -> T.control_snapshot header (control_snapshot_of op)
          | None -> T.control_unknown_operation header operation)
  | header, T.RequestCancel (operation, cancel_seq, _) ->
      with_tables (fun () ->
          match Registry.find_operation_by_id operation with
          | None -> T.control_unknown_operation header operation
          | Some op ->
              let seq = T.U.get cancel_seq in
              if seq = op.cancel_seq_seen && op.last_cancel_ack <> None then
                (* 等值：幂等重放原 ACK。 *)
                Option.get op.last_cancel_ack
              else if seq < op.cancel_seq_seen then
                (* 更小：PastCancel（不存储，避免覆盖原 ACK 的重放）。 *)
                T.control_cancel_ack header T.PastCancel (control_snapshot_of op)
              else begin
                op.cancel_seq_seen <- seq;
                let status =
                  if op.terminal <> None || op.aux <> None then T.AlreadyTerminal
                  else begin
                    (* 对当前执行 token 原子 set；无在途 eval 时只记 stop_requested。 *)
                    (match op.token with Some token -> Coq.Limits.Token.set token | None -> ());
                    op.stop_requested <- true;
                    T.ReceivedAck
                  end
                in
                let ack = T.control_cancel_ack header status (control_snapshot_of op) in
                op.last_cancel_ack <- Some ack;
                ack
              end)

let rec control_loop fd =
  let request = get (T.decode_control_request S.message_limits (read_frame fd)) in
  let reply = control_handle request in
  write_frame fd (get (T.encode_control_reply S.message_limits reply));
  control_loop fd

(* —— view 通道（fd 7，spec §1.5）：view_pull/ack/release + blob 下载骨架 ——
   本 item 无已登记 view/blob：一律 unknown_operation/not_admitted 回错；
   后续 item 接 spool 服务。 *)
let view_channel_error_encoded header (kind : [< `Pull | `Ack | `Release ]) =
  match kind with
  | `Pull ->
      get
        (T.encode_view_reply_pull S.message_limits
           (T.make_view_pull_error header T.unknown_operation T.not_admitted))
  | `Ack ->
      get
        (T.encode_view_reply_ack S.message_limits
           (T.make_view_ack_error header T.unknown_operation T.not_admitted))
  | `Release ->
      get
        (T.encode_view_reply_release S.message_limits
           (T.make_view_release_error header T.unknown_operation T.not_admitted))

let rec view_loop fd =
  let raw = read_frame fd in
  let reply =
    match frame_method raw with
    | Some (("view_pull" | "view_ack" | "view_release") as method_name) ->
        (match T.decode_view_request S.message_limits raw with
         | Ok request ->
             (match T.view_request_view request with
              | T.PullViewRequest (header, _, _, _, _, _) ->
                  Some (view_channel_error_encoded header `Pull)
              | T.AckViewRequest (header, _, _, _, _, _) ->
                  Some (view_channel_error_encoded header `Ack)
              | T.ReleaseViewRequest (header, _, _, _) ->
                  Some (view_channel_error_encoded header `Release))
         | Error _ ->
             (* 解码失败：尽力回显 header 回错；拿不到则丢弃。 *)
             (match frame_header raw with
              | Some header ->
                  let kind : [`Pull | `Ack | `Release ] =
                    match method_name with
                    | "view_pull" -> `Pull
                    | "view_ack" -> `Ack
                    | _ -> `Release
                  in
                  Some (view_channel_error_encoded header kind)
              | None -> None))
    | Some ("checkpoint_blob_pull" | "checkpoint_blob_ack" | "checkpoint_blob_release") ->
        (* 本 item 未接 checkpoint 下载分支：通道内 protocol_error 占位；
           解码失败时尽力回显 header，拿不到则丢弃该帧（不伪造 header）。 *)
        (match T.decode_checkpoint_blob_request S.message_limits raw with
         | Ok request ->
             let header, _ = T.checkpoint_blob_request_view request in
             Some
               (get
                  (T.encode_checkpoint_blob_reply S.message_limits
                     (T.checkpoint_blob_error header T.unknown_operation T.not_admitted)))
         | Error _ ->
             (match frame_header raw with
              | Some header ->
                  Some
                    (get
                       (T.encode_checkpoint_blob_reply S.message_limits
                          (T.checkpoint_blob_error header T.unknown_operation T.not_admitted)))
              | None -> None))
    | _ ->
        (* 未知 method：尽力回错；拿不到 header 则丢弃。 *)
        (match frame_header raw with
         | Some header -> Some (view_channel_error_encoded header `Pull)
         | None -> None)
  in
  (match reply with
   | Some encoded -> write_frame fd encoded
   | None -> ());
  view_loop fd

let node_id (operation : Registry.operation) step_seq =
  id (Format.asprintf "node-%s-%Ld" (T.Id.get operation.line) step_seq)

let status header (op : Registry.operation) =
  (* aux 终态（locate/fork/refresh 等）用 checkpoint_status 形状回报；普通步进操作
     维持 make_status（pending/terminal/last_ack 逐字回放）。 *)
  match op.aux with
  | Some aux ->
      T.checkpoint_status header op.binding
        ~highest_seen:(uint !Registry.highest_seen)
        ~retired_through:(uint !Registry.retired_through)
        T.TerminalState (Some aux) ~stop_requested:op.stop_requested
  | None ->
      let state = match op.pending, op.terminal with
        | Some _, _ -> T.WaitAck | _, Some _ -> T.TerminalState | _ -> T.Ready in
      T.make_status header op.binding state (uint op.acked_through)
        ~highest_seen:(uint !Registry.highest_seen)
        ~retired_through:(uint !Registry.retired_through)
        ~pending:op.pending ~terminal:op.terminal ~last_ack:op.last_ack
        ~stop_requested:op.stop_requested

let pull header (op : Registry.operation) =
  (* 普通可取消 token：本 fork 的 create_atomic 是不可 set 的原子段，
     会完全关闭控制通道取消；跨线程 set 由 bool ref 后端天然支持。
     token 与 Executing 标记先入账本再执行。 *)
  let token = Coq.Limits.Token.create () in
  with_tables (fun () ->
      op.token <- Some token;
      op.state <- Registry.Executing);
  let doc = match op.doc with
    | Some doc -> doc
    | None ->
        incr uri_counter;
        let uri = Lang.LUri.of_string (Format.asprintf "file:///tmp/ccv_native_%d_%d.v"
            (Unix.getpid ()) !uri_counter) |> Lang.LUri.File.of_uri |> get in
        let raw = with_tables (fun () -> Option.get (Registry.source_bytes op.source)) in
        Shell.make_doc ~token ~uri ~raw in
  let doc, outcome = Shell.step_doc ~token ~doc ~cursor:(Int64.to_int op.cursor) in
  with_tables (fun () -> op.state <- Registry.Ready);
  let seq = uint (Int64.succ op.acked_through) in
  let finish record = op.terminal <- Some record; T.terminal_reply header record in
  match outcome with
  | `Eof -> finish (T.make_eof op.binding seq ~acked_through:(uint op.acked_through)
                      ~cursor:(uint op.cursor))
  | `Error stage -> finish (T.error_terminal op.binding seq ~parse:(stage = `Parse)
                              ~last_valid:op.parent ~group:None)
  | `Unknown when Coq.Limits.Token.is_set token ->
      (* 取消真实到达但本块尚未接线中断落定：按 spec 口径不发布新身份、无终态，
         status 报 Ready 且 terminal=FUnknown（块 E 的 SettleInterrupt 接恢复）。 *)
      status header op
  | `Unknown -> fail "nativeface: single-step outcome unknown"
  | `Step stop ->
      let node = node_id op (T.U.get seq) and next_cursor = uint (Int64.of_int stop) in
      let r = T.make_step_receipt op.binding ~parent:op.parent ~node ~source:op.source
          ~command_start:(uint op.cursor) ~command_end:next_cursor ~next_cursor ~line:op.line
          ~base_revision:(uint op.line_revision) ~step_seq:seq in
      op.doc <- Some doc; op.parent <- node; op.cursor <- T.U.get next_cursor;
      op.pending <- Some r;
      (* 线表同步（spec §1.1）：成功步进后 frontier 推进到新节点。 *)
      with_tables (fun () ->
          match Registry.find_line op.line with
          | Some line_state -> line_state.frontier <- node
          | None -> ());
      T.receipt_reply header r

(* —— 内联 locate/fork/select 辅助（spec §1.1）—— *)

(* 账本节点 id：与 pull 的 node_id 同一方案（第 i 个 Fleche 节点 = 步序 i+1）。 *)
let ledger_node line_key index =
  id (Format.asprintf "node-%s-%d" line_key (index + 1))

let line_root line_key = id (Format.asprintf "root-%s" line_key)

(* 新 aux 操作的空账本（locate/fork 等）：终态后填 aux/terminal。 *)
let make_aux_operation binding line_id : Registry.operation =
  { binding; state = Registry.Ready; line = line_id; source = T.op_binding_source binding;
    expected_revision = uint 0L; cursor = 0L; parent = line_root (T.Id.get line_id);
    pending = None; terminal = None; aux = None; last_ack = None;
    acked_through = 0L; line_revision = 0L; doc = None;
    cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
    token = None; interrupt_snapshot = None; last_cancel_ack = None }

(* 新操作准入（spec §1 预算准入）：序号 = highest_seen+1、未退役、
   预算已登记且 entry_uses_budget 与原请求全匹配。 *)
let admit_new header binding request =
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
    | Some budget ->
        if not (T.entry_uses_budget S.message_limits budget request) then
          `Rejected (reject T.invalid_input)
        else `Admitted

(* 单实例单 context：取第一条 Mainline 线及其 operation（须在 with_tables 内）。 *)
let locate_context_line () =
  let chosen = ref None in
  Registry.iter_lines (fun key state ->
      if !chosen = None && state.kind = Registry.Mainline then chosen := Some (key, state));
  match !chosen with
  | None -> None
  | Some (line_key, line_state) ->
      let op_ref = ref None in
      Registry.iter_operations (fun op ->
          if !op_ref = None && T.Id.get op.line = line_key then op_ref := Some op);
      Option.map (fun op -> (line_key, line_state, op)) !op_ref

(* doc 内定位覆盖某 UTF-16 位置且已真实执行的节点。 *)
let range_covers (r : Lang.Range.t) line character =
  let after_start =
    r.start.line < line || (r.start.line = line && r.start.character <= character) in
  let before_end =
    r.end_.line > line || (r.end_.line = line && r.end_.character >= character) in
  after_start && before_end

let covering_node (doc : Fleche.Doc.t) line character =
  let rec go index = function
    | [] -> None
    | node :: rest ->
        if Fleche.Doc.Node.ast node <> None
           && range_covers (Fleche.Doc.Node.range node) line character
        then Some (index, node)
        else go (index + 1) rest
  in
  go 0 doc.Fleche.Doc.nodes

let node_index (doc : Fleche.Doc.t) (target : Fleche.Doc.Node.t) =
  let rec go index = function
    | [] -> None
    | node :: rest -> if node == target then Some index else go (index + 1) rest
  in
  go 0 doc.Fleche.Doc.nodes

let step_reply ~request request_view =
  match request_view with
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
                        doc = None;
                        cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
                        token = None; interrupt_snapshot = None; last_cancel_ack = None }
                    in
                    Registry.register_operation binding operation;
                    (* 线表登记（spec §1.1）：BeginLine 建主线，frontier=root 节点。 *)
                    Registry.register_line line
                      ~revision:(T.U.get expected_revision)
                      ~frontier:operation.parent ~group:None ~kind:Registry.Mainline;
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
                  (* 线表同步（spec §1.1）：ACK 后线版本推进。 *)
                  (match Registry.find_line operation.line with
                   | Some line_state -> line_state.revision <- operation.line_revision
                   | None -> ());
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
  | T.LocateContextRequest (header, args) ->
      (* spec §1.1 内联最小真实：单实例单 context，在当前主线 doc 上定位。 *)
      let binding, _file, _relative_file, target, logical_target, lineage, expected_context =
        T.locate_fields args in
      with_tables (fun () ->
          match Registry.find_operation binding with
          | Some { aux = Some aux; _ } ->
              (* 幂等：同 binding 重入重放原 aux（直答与 status 同源）。 *)
              T.locator_reply header aux
          | Some op -> status header op
          | None ->
              let reject code = T.make_protocol_error header code T.not_admitted T.fact_unknown in
              (match admit_new header binding request with
               | `Rejected reply -> reply
               | `Admitted ->
                   (match locate_context_line () with
                    | None ->
                        (* 无 BeginLine 建立的线：定位输入不齐，诚实拒绝。 *)
                        reject T.invalid_input
                    | Some (line_key, line_state, context_op) ->
                        let context_id =
                          match T.op_binding_line_owner context_op.binding with
                          | context, _, _ -> context in
                        (* expected_context / lineage 版本核对：可核才继续。 *)
                        let stale =
                          (match expected_context with
                           | Some (ctx, rev) ->
                               T.Id.get ctx <> T.Id.get context_id
                               || T.U.get rev <> line_state.revision
                           | None -> false)
                          || (match lineage with
                              | Some (line_id, rev) ->
                                  (match Registry.find_line line_id with
                                   | Some state -> state.revision <> T.U.get rev
                                   | None -> true)
                              | None -> false)
                        in
                        if stale then reject T.StaleRevision
                        else begin
                          (* doc：优先 context op 持有的；无 doc ⇒ 按 sealed source
                             建（只建不执行，定位结果由真实节点决定）。 *)
                          let ensure_doc () =
                            match context_op.doc with
                            | Some doc -> Some doc
                            | None ->
                                (match Registry.source_bytes context_op.source with
                                 | Some raw ->
                                     incr uri_counter;
                                     let uri =
                                       Lang.LUri.of_string
                                         (Format.asprintf "file:///tmp/ccv_native_%d_%d.v"
                                            (Unix.getpid ()) !uri_counter)
                                       |> Lang.LUri.File.of_uri |> get in
                                     let doc =
                                       Shell.make_doc ~token:(Coq.Limits.create_atomic ())
                                         ~uri ~raw in
                                     context_op.doc <- Some doc;
                                     Some doc
                                 | None -> None)
                          in
                          let line_id = id line_key in
                          let revision = uint line_state.revision in
                          let cursor = uint context_op.cursor in
                          let build_aux outcome =
                            T.make_locator_terminal binding ~line:line_id
                              ~node:line_state.frontier ~revision ~cursor outcome in
                          let boundary_of node index =
                            let r = Fleche.Doc.Node.range node in
                            T.make_entry_boundary header binding ~target:logical_target
                              ~node:(ledger_node line_key index)
                              ~command_start:(uint (Int64.of_int r.start.offset))
                              ~command_end:(uint (Int64.of_int r.end_.offset))
                          in
                          let outcome =
                            match target with
                            | T.Root -> `Done (build_aux T.LocatedRoot)
                            | target_rest ->
                                (match ensure_doc () with
                                 | None -> `Rejected
                                 | Some doc ->
                                     (match target_rest with
                                      | T.Theorem name ->
                                          let open Lang.Compat.String.Map in
                                          (match find_opt (T.Text.get name) doc.Fleche.Doc.toc with
                                           | Some toc_node ->
                                               (match node_index doc toc_node with
                                                | Some index ->
                                                    `Done
                                                      (build_aux
                                                         (T.LocatedBoundary
                                                            (boundary_of toc_node index)))
                                                | None ->
                                                    (* toc 节点不在 nodes：按前沿+节点区间构造。 *)
                                                    `Done
                                                      (build_aux
                                                         (T.LocatedBoundary
                                                            (boundary_of toc_node 0))))
                                           | None ->
                                               `Done
                                                 (build_aux (T.PrefixRequired (target_rest, None))))
                                      | T.Position (line, character) ->
                                          let l = Int64.to_int (T.U.get line)
                                          and c = Int64.to_int (T.U.get character) in
                                          (match covering_node doc l c with
                                           | Some (index, node) ->
                                               `Done
                                                 (build_aux (T.LocatedBoundary (boundary_of node index)))
                                           | None ->
                                               `Done
                                                 (build_aux (T.PrefixRequired (target_rest, None))))
                                      | T.EndTarget ->
                                          (match doc.Fleche.Doc.completed with
                                           | Fleche.Doc.Completion.Yes _ ->
                                               (match List.rev doc.Fleche.Doc.nodes with
                                                | last :: _ when Fleche.Doc.Node.ast last <> None ->
                                                    let index =
                                                      List.length doc.Fleche.Doc.nodes - 1 in
                                                    `Done
                                                      (build_aux
                                                         (T.LocatedBoundary (boundary_of last index)))
                                                | _ -> `Done (build_aux T.LocatedRoot))
                                           | _ ->
                                               `Done
                                                 (build_aux (T.PrefixRequired (target_rest, None))))
                                      | T.Root -> assert false))
                          in
                          match outcome with
                          | `Rejected -> reject T.invalid_input
                          | `Done aux ->
                              let operation = make_aux_operation binding line_id in
                              operation.aux <- Some aux;
                              operation.line_revision <- line_state.revision;
                              operation.cursor <- context_op.cursor;
                              operation.parent <- context_op.parent;
                              Registry.highest_seen := T.U.get (T.op_seq binding);
                              Registry.register_operation binding operation;
                              T.locator_reply header aux
                        end)))
  | T.SelectLineRequest (header, args) ->
      (* spec §1.1：本批候选线无独立执行栈；仅「重选当前前沿」账本可核，
         切换到其它节点无法诚实重放 ⇒ 按「不谎称」条款拒绝。 *)
      let binding, destination, expected_revision, candidate, _durable_path, _group_na =
        T.select_fields args in
      with_tables (fun () ->
          match Registry.find_operation binding with
          | Some { terminal = Some record; _ } ->
              (* 幂等：同 binding 重入重放原终态。 *)
              T.terminal_reply header record
          | Some op -> status header op
          | None ->
              let reject code = T.make_protocol_error header code T.not_admitted T.fact_unknown in
              (match admit_new header binding request with
               | `Rejected reply -> reply
               | `Admitted ->
                   (match Registry.find_line destination with
                    | None -> reject T.invalid_input
                    | Some line when line.revision <> T.U.get expected_revision ->
                        reject T.StaleRevision
                    | Some line ->
                        if T.Id.get line.frontier <> T.Id.get candidate then
                          reject T.invalid_input
                        else begin
                          let after_rev = Int64.succ line.revision in
                          line.revision <- after_rev;
                          let record =
                            match T.select_group args with
                            | Some (group_id, group_rev_expected) ->
                                let group_rev = Int64.succ (T.U.get group_rev_expected) in
                                line.group <- Some (group_id, group_rev);
                                let _receipt, record =
                                  T.make_selected_group binding ~line:destination
                                    ~before_revision:expected_revision
                                    ~after_revision:(uint after_rev) ~node:candidate
                                    ~group:group_id ~group_revision:(uint group_rev) in
                                record
                            | None ->
                                let _receipt, record =
                                  T.make_selected_entry binding ~line:destination
                                    ~before_revision:expected_revision
                                    ~after_revision:(uint after_rev) ~node:candidate in
                                record
                          in
                          let operation = make_aux_operation binding destination in
                          operation.terminal <- Some record;
                          operation.line_revision <- after_rev;
                          operation.parent <- candidate;
                          Registry.highest_seen := T.U.get (T.op_seq binding);
                          Registry.register_operation binding operation;
                          T.terminal_reply header record
                        end)))
  | T.ForkLineRequest (header, args) ->
      (* spec §1.1：父线存在且版本/前沿可核 ⇒ 新探索线（frontier=父前沿）。 *)
      let binding, parent_node, (parent_line_id, expected_rev), new_line, exploration =
        T.fork_fields args in
      with_tables (fun () ->
          match Registry.find_operation binding with
          | Some { aux = Some aux; _ } ->
              (* 幂等：同 binding 重入重放原 aux。 *)
              T.locator_reply header aux
          | Some op -> status header op
          | None ->
              let reject code = T.make_protocol_error header code T.not_admitted T.fact_unknown in
              (match admit_new header binding request with
               | `Rejected reply -> reply
               | `Admitted ->
                   (match Registry.find_line parent_line_id with
                    | None -> reject T.invalid_input
                    | Some parent when parent.revision <> T.U.get expected_rev ->
                        reject T.StaleRevision
                    | Some parent when T.Id.get parent.frontier <> T.Id.get parent_node ->
                        (* 请求的父节点与账本前沿不符：不可核 ⇒ 拒绝。 *)
                        reject T.invalid_input
                    | Some parent ->
                        if Registry.find_line new_line <> None then
                          reject T.binding_conflict
                        else begin
                          (* 组版本：父组 rev+1，无父组则 1（Rust 端只核 group id）。 *)
                          let group_rev = match parent.group with
                            | Some (_, rev) -> Int64.succ rev
                            | None -> 1L in
                          Registry.register_line new_line
                            ~revision:(T.U.get expected_rev) ~frontier:parent_node
                            ~group:(Some (exploration, group_rev)) ~kind:Registry.Exploration;
                          let aux = T.make_fork_terminal binding ~line:new_line
                            ~node:parent_node ~revision:expected_rev
                            ~group:(exploration, uint group_rev) in
                          let operation = make_aux_operation binding new_line in
                          operation.aux <- Some aux;
                          operation.line_revision <- T.U.get expected_rev;
                          operation.parent <- parent_node;
                          Registry.highest_seen := T.U.get (T.op_seq binding);
                          Registry.register_operation binding operation;
                          T.locator_reply header aux
                        end)))
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
  let control = fd_of_int 5 in
  let source = fd_of_int 6 in
  let view = fd_of_int 7 in
  Registry.init ();
  Registry.set_input_quota (T.U.get (T.boot_input_quota boot));
  handshake boot ordinary T.Ordinary;
  handshake boot control T.Control;
  handshake boot source T.Source;
  handshake boot view T.View;
  (* spec §1.3/§1.5：控制与 view 通道各自 serve 线程，进程不因单帧错误退出。 *)
  ignore (Thread.create control_loop control);
  ignore (Thread.create source_loop source);
  ignore (Thread.create view_loop view);
  let rec loop () =
    let request = get (T.decode_native_request S.message_limits (read_frame ordinary)) in
    let reply = step_reply ~request (T.native_request_view request) in
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
