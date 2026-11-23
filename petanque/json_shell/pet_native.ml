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
module Refresh = Pet_native_support.Pet_environment_refresh
module Sync = Pet_native_support.Pet_source_sync
module Checkpoint_dispatch = Pet_native_support.Pet_checkpoint_dispatch
module Query_view = Pet_native_support.Pet_query_view
module Query = Pet_native_support.Pet_query
module Inspect = Pet_native_support.Pet_inspect
module Scope = Pet_native_support.Pet_scope_lifecycle

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
        (* checkpoint 上传分支（spec §3）：路由 Pet_checkpoint_dispatch。 *)
        (match T.decode_checkpoint_blob_request S.message_limits raw with
         | Ok request ->
             Some
               (get
                  (T.encode_checkpoint_blob_reply S.message_limits
                     (Checkpoint_dispatch.serve_upload request)))
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

(* phase 推导：执行中（pull 已标记 Executing）=Active；中断已落定待 Settle=Settling；
   已有终态（terminal/aux）=TerminalPhase；否则 Idle。 *)
let control_phase_of (op : Registry.operation) =
  if op.terminal <> None || op.aux <> None then T.TerminalPhase
  else
    match op.state with
    | Registry.Executing -> T.Active
    | Registry.Retiring -> T.Settling
    | _ -> T.Idle

let control_snapshot_of (op : Registry.operation) =
  T.make_control_snapshot
    ~operation_id:(T.op_binding_operation op.binding)
    ~phase:(control_phase_of op)
    ~token_generation:(uint op.cancel_generation)
    ~highest_cancel_seq:(uint op.cancel_seq_seen)
    ~stop_requested:op.stop_requested

(* RequestCancel 的三元组按 types.ml control_request_view 是
   (operation_id, token_generation, cancel_seq)：token_generation 是驱动读到的
   快照代际（Rust interrupt.rs:90-93 用 before.token_generation 发请求），
   cancel_seq 才是取消序号（Rust :142-151 valid_cancel_ack 核
   Received: highest_cancel_seq == cancel_seq ∧ 代际不变 ∧ stop_requested；
   PastCancel: highest_cancel_seq > cancel_seq；Stale: 代际已前进）。
   幂等重放不能用存的旧 ACK 原样回——Rust channel.rs:322 核回复 header 逐字
   等于请求 header（含 rpc_seq），重放按当前账本重算 status、用本次 header。 *)
let control_handle request =
  match T.control_request_view request with
  | header, T.ReadControl operation ->
      with_tables (fun () ->
          match Registry.find_operation_by_id operation with
          | Some op -> T.control_snapshot header (control_snapshot_of op)
          | None -> T.control_unknown_operation header operation)
  | header, T.RequestCancel (operation, token_generation, cancel_seq) ->
      with_tables (fun () ->
          match Registry.find_operation_by_id operation with
          | None -> T.control_unknown_operation header operation
          | Some op ->
              let seq = T.U.get cancel_seq
              and generation = T.U.get token_generation in
              let status =
                if op.terminal <> None || op.aux <> None then
                  (* 已有终态：取消无效果，只报 AlreadyTerminal（phase=terminal）。 *)
                  T.AlreadyTerminal
                else if generation <> op.cancel_generation then
                  (* 请求携带的是旧代际快照（本操作已恢复、代际已 +1）⇒ Stale，
                     不动账本；Rust 要求 after.token_generation > before。 *)
                  T.Stale
                else if seq <= 0L || seq < op.cancel_seq_seen then
                  (* 非正序号或更小序号：PastCancel、不动账本（Rust 对
                     highest_cancel_seq > seq 不成立的 PastCancel 判失配）。 *)
                  T.PastCancel
                else if seq = op.cancel_seq_seen then
                  (* 等值重放：该取消已受理且仍有效（stop_requested 只在恢复
                     成功时清零，而恢复必使代际 +1，已在上一分支报 Stale）。 *)
                  T.ReceivedAck
                else begin
                  (* 新取消：记序号；对当前执行 token 原子 set；无在途 eval 时
                     只记 stop_requested。 *)
                  op.cancel_seq_seen <- seq;
                  (match op.token with
                   | Some token -> Coq.Limits.Token.set token
                   | None -> ());
                  op.stop_requested <- true;
                  T.ReceivedAck
                end
              in
              T.control_cancel_ack header status (control_snapshot_of op))

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
              | T.PullViewRequest (header, view, operation, seq, offset, credit) ->
                  (* spec §1.5：先查 Pet_source_sync 的 line_updates spool；未接管
                     （None）再查 Pet_query_view；都未接管 ⇒ unknown_operation。 *)
                  (match Sync.serve_view_pull header ~view ~operation ~seq
                          ~offset ~credit with
                   | Some reply ->
                       Some (get (T.encode_view_reply_pull S.message_limits reply))
                   | None ->
                       (* spec §1.5：Sync 未接管 ⇒ 查 Pet_query_view（query 文本 /
                          inspect facts 父子流）；仍未接管 ⇒ unknown_operation。 *)
                       (match Query_view.serve_pull header ~view ~operation ~seq
                                ~offset ~credit with
                        | Some reply ->
                            Some (get (T.encode_view_reply_pull S.message_limits reply))
                        | None -> Some (view_channel_error_encoded header `Pull)))
              | T.AckViewRequest (header, view, operation, seq, end_offset, digest) ->
                  (match Sync.serve_view_ack header ~view ~operation ~seq
                          ~end_offset ~digest with
                   | Some reply ->
                       Some (get (T.encode_view_reply_ack S.message_limits reply))
                   | None ->
                       (match Query_view.serve_ack header ~view ~operation ~seq
                                ~end_offset ~digest with
                        | Some reply ->
                            Some (get (T.encode_view_reply_ack S.message_limits reply))
                        | None -> Some (view_channel_error_encoded header `Ack)))
              | T.ReleaseViewRequest (header, view, operation, last_acked) ->
                  (match Sync.serve_view_release header ~view ~operation ~last_acked
                  with
                   | Some reply ->
                       Some
                         (get
                            (T.encode_view_reply_release S.message_limits reply))
                   | None ->
                       (match Query_view.serve_release header ~view ~operation
                                ~last_acked with
                        | Some reply ->
                            Some
                              (get
                                 (T.encode_view_reply_release S.message_limits reply))
                        | None -> Some (view_channel_error_encoded header `Release))))
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
        (* checkpoint 下载/释放分支（spec §3）：pull/ack 归下载，release 也走
           view 通道；解码失败时尽力回显 header，拿不到则丢弃（不伪造）。 *)
        (match T.decode_checkpoint_blob_request S.message_limits raw with
         | Ok request ->
             let reply =
               let _, blob_view = T.checkpoint_blob_request_view request in
               match blob_view with
               | T.BlobReleaseRequest _ -> Checkpoint_dispatch.serve_release request
               | _ -> Checkpoint_dispatch.serve_download request
             in
             Some
               (get
                  (T.encode_checkpoint_blob_reply S.message_limits reply))
         | Error _ ->
             (match frame_header raw with
              | Some header ->
                  Some
                    (get
                       (T.encode_checkpoint_blob_reply S.message_limits
                          (T.checkpoint_blob_error header T.invalid_input T.not_admitted)))
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
  if Scope.is_closing_owner ~binding:op.binding then
    (* item 5：Closing 中的 end-scope 操作报 Retiring（Rust end_scope_status 只接受
       (Retiring, N/A) / (Terminal, Closed 回执)）；Closed 后走 terminal 分支。 *)
    T.make_retiring_status header op.binding
      ~highest_seen:(uint !Registry.highest_seen)
      ~retired_through:(uint !Registry.retired_through)
      ~stop_requested:op.stop_requested
  else
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

(* 中断落定（spec §1.2）：在原恢复期限内用新 token 从父快照恢复；
   恢复成功才发布 Interrupted 终态（stopped/synchronized=true），否则保留
   Unknown（state=Retiring，无终态）。pull 与 SettleInterrupt 共用：
   驱动端 pull 只接受 Receipt/Terminal/PastUnavailable（Status 会隔离实例），
   所以可恢复的中断必须在 pull 内联落定；SettleInterrupt 是幂等/兜底路径。 *)
let settle_interrupted_reply header (op : Registry.operation) snapshot =
  let retiring () =
    op.state <- Registry.Retiring;
    T.make_retiring_status header op.binding
      ~highest_seen:(uint !Registry.highest_seen)
      ~retired_through:(uint !Registry.retired_through)
      ~stop_requested:op.stop_requested
  in
  let expired =
    match Registry.find_budget (T.op_binding_budget op.binding) with
    | Some budget -> Registry.deadline_expired budget `Recovery
    | None -> true (* 无预算可核：按过期处理，不冒险恢复 *)
  in
  if expired then retiring ()
  else begin
    (* 原恢复期限未过：新 token（恢复段不可再被取消，原子段语义正确）。 *)
    let token = Coq.Limits.create_atomic () in
    match
      (try Ok (Shell.restore_sentence ~token ~snapshot ~cursor:(Int64.to_int op.cursor))
       with _ -> Error ())
    with
    | Error () -> retiring ()
    | Ok doc ->
        if match doc.Fleche.Doc.completed with
          | Fleche.Doc.Completion.Failed _ -> true | _ -> false
        then retiring ()
        else begin
          (* 恢复成功：代际+1、清中断账本、发布终态。 *)
          op.doc <- Some doc;
          op.cancel_generation <- Int64.succ op.cancel_generation;
          op.stop_requested <- false;
          op.interrupt_snapshot <- None;
          op.token <- None;
          op.state <- Registry.Ready;
          let seq = uint (Int64.succ op.acked_through) in
          let record =
            T.make_interrupted_terminal op.binding seq
              ~stopped:(T.FKnown true)
              ~synchronized:(T.FKnown true)
              ~last_acked:(T.FKnown op.parent)
              ~pending:T.FNotApplicable
              ~recoverable:(T.FKnown true)
              ~diagnostic:T.FUnknown
              ~extent:T.CompleteKnown
          in
          op.terminal <- Some record;
          T.terminal_reply header record
        end
  end

(* 线组版本推进（须在 Registry 锁内）：ACK 与 Parse/Execute 错误终态各结束一个组
   事务——探索线组版本 +1 并返回推进后的组快照；主线无组 ⇒ None。Rust
   spawn.rs:2066 advanced_group 要求同组 id 且 expected_revision 严格递增，
   state_operations.rs:549 要求候选 ACK 的 group = Known。 *)
let advance_line_group (op : Registry.operation) : (T.Id.t * T.U.t) option =
  match Registry.find_line op.line with
  | Some ({ group = Some (group_id, rev); _ } as line_state) ->
      let next = Int64.succ rev in
      line_state.group <- Some (group_id, next);
      Some (group_id, uint next)
  | _ -> None

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
        let raw, root =
          with_tables (fun () ->
              (Option.get (Registry.source_bytes op.source), op.root_state)) in
        (* 续接 / fork 线：从前沿节点的真实 state 起算（parent = 前沿节点的回执与
           实际执行起点一致）；新线从 workspace init 起算。 *)
        (match root with
         | None -> Shell.make_doc ~token ~uri ~raw
         | Some root -> Shell.make_doc_at ~uri ~raw ~root)
  in
  (* 步前快照（spec §1.2）：中断真实发生时作为恢复父快照。 *)
  let snapshot = Shell.snapshot_doc doc in
  let doc, outcome = Shell.step_doc ~token ~doc ~cursor:(Int64.to_int op.cursor) in
  begin match outcome with
    | `Interrupted _ -> () (* 中断路径下面统一入账，不回 Ready *)
    | _ -> with_tables (fun () -> op.state <- Registry.Ready)
  end;
  let seq = uint (Int64.succ op.acked_through) in
  let finish record = op.terminal <- Some record; T.terminal_reply header record in
  match outcome with
  | `Eof -> finish (T.make_eof op.binding seq ~acked_through:(uint op.acked_through)
                       ~cursor:(uint op.cursor))
  | `Error stage ->
      (* 错误终态结束一个组事务：探索线带推进后的组快照（Rust
         validate_terminal_receipt 对 Parse/Execute 错误核 advanced_group）；主线
         无组 ⇒ None。 *)
      let group = with_tables (fun () -> advance_line_group op) in
      finish (T.error_terminal op.binding seq ~parse:(stage = `Parse)
                ~last_valid:op.parent ~group)
  | `Interrupted _stage ->
      (* 中断真实发生（spec §1.2）：先入父快照账本，再尝试原恢复期限内联落定；
         驱动端 pull 只接受 Receipt/Terminal/PastUnavailable，可恢复的中断必须
         在此回复 Interrupted 终态；恢复失败保留 Unknown（Retiring status，
         极端路径——驱动会隔离实例，诚实不伪造）。 *)
      with_tables (fun () -> op.interrupt_snapshot <- Some snapshot);
      with_tables (fun () -> settle_interrupted_reply header op snapshot)
  | `Unknown -> fail "nativeface: single-step outcome unknown"
  | `Step (stop, state) ->
      let node = node_id op (T.U.get seq) and next_cursor = uint (Int64.of_int stop) in
      let r = T.make_step_receipt op.binding ~parent:op.parent ~node ~source:op.source
          ~command_start:(uint op.cursor) ~command_end:next_cursor ~next_cursor ~line:op.line
          ~base_revision:(uint op.line_revision) ~step_seq:seq in
      (* 线表同步（spec §1.1）：成功步进后 frontier 推进到新节点，前沿 state =
         所执行节点的真实 state（续接 / fork 的执行起点）。 *)
      with_tables (fun () ->
          op.doc <- Some doc; op.parent <- node; op.cursor <- T.U.get next_cursor;
          op.pending <- Some r;
          match Registry.find_line op.line with
          | Some line_state ->
              line_state.frontier <- node;
              line_state.frontier_state <- Some state
          | None -> ());
      T.receipt_reply header r

(* —— 内联 locate/fork/select 辅助（spec §1.1）—— *)

let line_root line_key = id (Format.asprintf "root-%s" line_key)

(* 新 aux 操作的空账本（locate/fork 等）：终态后填 aux/terminal。 *)
let make_aux_operation binding line_id : Registry.operation =
  { binding; state = Registry.Ready; line = line_id; source = T.op_binding_source binding;
    expected_revision = uint 0L; cursor = 0L; parent = line_root (T.Id.get line_id);
    pending = None; terminal = None; aux = None; last_ack = None;
    acked_through = 0L; line_revision = 0L; doc = None;
    cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
    token = None; interrupt_snapshot = None; terminal_receipt = None;
    root_state = None }

(* 新操作准入（spec §1 预算准入）：序号 = highest_seen+1、未退役、
   预算已登记且 entry_uses_budget 与原请求全匹配。 *)
let admit_new header binding request =
  let reject code = T.make_protocol_error header code T.not_admitted T.fact_unknown in
  let seq = T.U.get (T.op_seq binding) in
  if seq <= !Registry.retired_through then
    `Rejected
      (T.make_past_unavailable header (T.op_seq binding) (uint !Registry.highest_seen))
  else if not (Scope.admits ~binding) then
    (* item 5：scope 进入 Closing/Closed 后封新准入（spec §5 步骤 3）。 *)
    `Rejected (reject T.invalid_state)
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

(* doc 内定位覆盖某 UTF-16 位置且已真实执行的节点（只判「已执行到目标位置」，
   不再借用目标节点的区间——定位边界的入口恒为当前前沿）。 *)
let range_covers (r : Lang.Range.t) line character =
  let after_start =
    r.start.line < line || (r.start.line = line && r.start.character <= character) in
  let before_end =
    r.end_.line > line || (r.end_.line = line && r.end_.character >= character) in
  after_start && before_end

let covering_node (doc : Fleche.Doc.t) line character =
  List.exists
    (fun node ->
       Fleche.Doc.Node.ast node <> None
       && range_covers (Fleche.Doc.Node.range node) line character)
    doc.Fleche.Doc.nodes

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
            | None when not (Scope.admits ~binding) ->
                (* item 5：Closing/Closed 的 scope 拒新线（封新准入）。 *)
                T.make_protocol_error header T.invalid_state T.not_admitted T.fact_unknown
            | None ->
                Registry.highest_seen := T.U.get (T.op_seq binding);
                let reject code =
                  T.make_protocol_error header code T.not_admitted T.fact_unknown
                in
                let expected = T.U.get expected_revision in
                match Registry.source_bytes script_source with
                | None -> reject T.invalid_input
                | Some _ when Registry.find_budget (T.op_binding_budget binding) = None ->
                    reject T.invalid_input
                | Some _ ->
                    (* 线准入：新线须 expected_revision = 0；已有线（同线续接、fork 出
                       的探索线）须 expected_revision = 线当前版本，且线上没有未到终态
                       的步进操作。Rust 同线续接以 ACK 后的线版本发 BeginLine
                       （native_pet_probe.rs continue_line），候选 BeginLine 带 fork 的
                       revision（state_operations.rs:212）；旧实现一律要求 0 ⇒ 父线
                       ACK 过一步即 StaleRevision。 *)
                    let admission =
                      match Registry.find_line line with
                      | None when expected <> 0L -> `Stale
                      | None -> `New
                      | Some line_state when line_state.revision <> expected -> `Stale
                      | Some line_state ->
                          let active = ref false in
                          Registry.iter_operations (fun op ->
                              if (not !active) && op.line = line && op.aux = None
                                 && op.terminal = None then active := true);
                          if !active then `Conflict else `Continue line_state
                    in
                    match admission with
                    | `Stale -> reject T.StaleRevision
                    | `Conflict ->
                        T.make_protocol_error header T.BindingConflict
                          T.ExistingOperation T.fact_unknown
                    | `New ->
                        let operation : Registry.operation =
                          { binding; state = Registry.Ready; line; source = script_source; expected_revision;
                            cursor = 0L;
                            parent = id (Format.asprintf "root-%s" (T.Id.get line));
                            pending = None; terminal = None; aux = None; last_ack = None;
                            acked_through = 0L; line_revision = expected;
                            doc = None;
                            cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
                            token = None; interrupt_snapshot = None; terminal_receipt = None;
                            root_state = None }
                        in
                        Registry.register_operation binding operation;
                        (* 线表登记（spec §1.1）：BeginLine 建主线，frontier=root 节点。 *)
                        Registry.register_line line ~revision:expected
                          ~frontier:operation.parent ~frontier_state:None ~group:None
                          ~kind:Registry.Mainline;
                        status header operation
                    | `Continue line_state ->
                        (* 续接：parent = 线前沿节点，执行栈起点 = 前沿节点的真实 state
                           （前沿为 root ⇒ None，从 workspace init 起算）；新脚本 cursor
                           从 0 开始。线表（kind/group/revision/frontier）原样保留——
                           fork 登记的探索组不得被这里覆盖（Rust 候选 ACK 核
                           ack.group = Known）。 *)
                        let operation : Registry.operation =
                          { binding; state = Registry.Ready; line; source = script_source; expected_revision;
                            cursor = 0L;
                            parent = line_state.frontier;
                            pending = None; terminal = None; aux = None; last_ack = None;
                            acked_through = 0L; line_revision = expected;
                            doc = None;
                            cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
                            token = None; interrupt_snapshot = None; terminal_receipt = None;
                            root_state = line_state.frontier_state }
                        in
                        Registry.register_operation binding operation;
                        status header operation)
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
            | _ when not (Scope.admits ~binding:op.binding) ->
                (* item 5：Closing/Closed 的 scope 不再执行新步（ACK/finish/release
                   仍可沿原 owner 处理）。 *)
                T.make_protocol_error header T.invalid_state T.not_admitted
                  T.fact_unknown
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
                  (* ACK 结束一个组事务：探索线带推进后的组快照；主线 None。 *)
                  let group = advance_line_group operation in
                  let ack = T.make_ack (T.ack_proof_receipt proof) ~line:operation.line
                    ~line_revision:(uint operation.line_revision)
                    ~acked_through:(uint operation.acked_through) ~group in
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
          | Some operation ->
              (match operation.terminal, operation.aux with
               | Some t, _ when T.receipt_key_equal (T.terminal_key t) key ->
                   T.make_finished header key
               | _, Some aux
                 when T.receipt_key_equal (T.locator_terminal_key aux) key ->
                   (* aux 终态（locate/fork/refresh 等）同样可结：key 取
                      locator_terminal_key。 *)
                   T.make_finished header key
               | _ ->
                   T.make_protocol_error header T.BindingConflict
                     T.ExistingOperation T.fact_unknown)
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
                          let cursor_int = Int64.to_int context_op.cursor in
                          let build_aux outcome =
                            T.make_locator_terminal binding ~line:line_id
                              ~node:line_state.frontier ~revision ~cursor outcome in
                          (* 定位边界的入口 = 当前已执行前沿（审核 8）：Rust
                             spawn.rs:1848 located 时要求 fact.entry_node = aux.node
                             且 fact.entry_offset = aux.cursor；设计：entry_node 为真实
                             可恢复前驱、entry_offset 为其消费终点。entry_command =
                             前沿节点的 parser 消费区间（句末 = cursor）；前沿为 root
                             或节点对不上 ⇒ 零长 [cursor, cursor)，不借用目标节点的
                             区间冒充入口。 *)
                          let frontier_command doc =
                            let rec last acc = function
                              | [] -> acc
                              | node :: rest ->
                                  let open Fleche.Doc.Node in
                                  if ast node <> None
                                     && not (List.exists Lang.Diagnostic.is_error (diags node))
                                     && (range node).end_.offset <= cursor_int
                                  then last (Some node) rest
                                  else last acc rest
                            in
                            match last None doc.Fleche.Doc.nodes with
                            | Some node when (Fleche.Doc.Node.range node).end_.offset = cursor_int ->
                                let r = Fleche.Doc.Node.range node in
                                Some (r.start.offset, cursor_int)
                            | _ -> None
                          in
                          let located_boundary doc =
                            let start, stop =
                              match frontier_command doc with
                              | Some range -> range
                              | None -> (cursor_int, cursor_int) in
                            T.make_entry_boundary header binding ~target:logical_target
                              ~node:line_state.frontier
                              ~command_start:(uint (Int64.of_int start))
                              ~command_end:(uint (Int64.of_int stop))
                          in
                          let outcome =
                            match target with
                            | T.Root -> `Done (build_aux T.LocatedRoot)
                            | target_rest ->
                                (match ensure_doc () with
                                 | None -> `Rejected
                                 | Some doc ->
                                     let located = build_aux (T.LocatedBoundary (located_boundary doc)) in
                                     let needs_prefix () =
                                       `Done (build_aux (T.PrefixRequired (target_rest, None))) in
                                     (match target_rest with
                                      | T.Theorem name ->
                                          let open Lang.Compat.String.Map in
                                          (match find_opt (T.Text.get name) doc.Fleche.Doc.toc with
                                           | Some _ -> `Done located
                                           | None -> needs_prefix ())
                                      | T.Position (line, character) ->
                                          let l = Int64.to_int (T.U.get line)
                                          and c = Int64.to_int (T.U.get character) in
                                          if covering_node doc l c then `Done located
                                          else needs_prefix ()
                                      | T.EndTarget ->
                                          (match doc.Fleche.Doc.completed with
                                           | Fleche.Doc.Completion.Yes _ ->
                                               (match List.rev doc.Fleche.Doc.nodes with
                                                | last :: _ when Fleche.Doc.Node.ast last <> None ->
                                                    `Done located
                                                | _ -> `Done (build_aux T.LocatedRoot))
                                           | _ -> needs_prefix ())
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
          | Some { terminal = Some record; terminal_receipt = Some receipt; _ } ->
              (* 幂等：同 binding 重入重放原回执。直答必须是 receipt（Rust
                 spawn.rs:962 entry 路径、state_operations.rs:996 grouped 路径
                 只认 NativeResult::Receipt）。 *)
              T.receipt_reply header receipt
          | Some ({ terminal = Some _; _ } as op) ->
              (* 只有 record 无回执（不变量破坏）：按 status 报 Terminal，不伪造。 *)
              T.make_status header op.binding T.TerminalState (uint op.acked_through)
                ~highest_seen:(uint !Registry.highest_seen)
                ~retired_through:(uint !Registry.retired_through)
                ~pending:op.pending ~terminal:op.terminal ~last_ack:op.last_ack
                ~stop_requested:op.stop_requested
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
                           let receipt, record =
                             match T.select_group args with
                             | Some (group_id, group_rev_expected) ->
                                 let group_rev = Int64.succ (T.U.get group_rev_expected) in
                                 line.group <- Some (group_id, group_rev);
                                 T.make_selected_group binding ~line:destination
                                   ~before_revision:expected_revision
                                   ~after_revision:(uint after_rev) ~node:candidate
                                   ~group:group_id ~group_revision:(uint group_rev)
                             | None ->
                                 T.make_selected_entry binding ~line:destination
                                   ~before_revision:expected_revision
                                   ~after_revision:(uint after_rev) ~node:candidate
                           in
                           let operation = make_aux_operation binding destination in
                           operation.terminal <- Some record;
                           (* 直答回 receipt（Rust 直答只认 Receipt）；status 由
                              op.terminal 报 Terminal → Known(record)。 *)
                           operation.terminal_receipt <- Some receipt;
                           operation.line_revision <- after_rev;
                           operation.parent <- candidate;
                           Registry.highest_seen := T.U.get (T.op_seq binding);
                           Registry.register_operation binding operation;
                           T.receipt_reply header receipt
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
                          (* 新线继承父线前沿及其真实 state：候选 BeginLine 以
                             revision = 父线版本准入（不再要求 0），执行从该节点续算。 *)
                          Registry.register_line new_line
                            ~revision:(T.U.get expected_rev) ~frontier:parent_node
                            ~frontier_state:parent.frontier_state
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
  | T.SyncSourceRequest
      (header, binding, context, (expected_ctx, expected_rev), old_source, new_source,
       publication) ->
      (* NN03 源码同步：路由 Pet_source_sync（模块锁→Registry 锁，路由侧不持
         Registry 锁调用）；entry_uses_budget 准入在 admit_new 内完成。 *)
      let admitted =
        with_tables (fun () ->
            match Registry.find_operation binding with
            | Some _ -> `Existing
            | None ->
                (match admit_new header binding request with
                 | `Rejected reply -> `Rejected reply
                 | `Admitted ->
                     Registry.highest_seen := T.U.get (T.op_seq binding);
                     (* aux 操作登记：context 记账与 Registry 联动（本批单 context
                        近似——主线 op/doc 作为 context 载体，在 Sync 内解析）。 *)
                     Registry.register_operation binding
                       (make_aux_operation binding context);
                     `Fresh))
      in
      (match admitted with
       | `Rejected reply -> reply
       | `Existing | `Fresh ->
           Sync.prepare_locked ~header ~binding ~context ~expected_ctx ~expected_rev
             ~old_source ~new_source ~publication)
  | T.RefreshEnvironmentRequest (header, binding, old_env, new_env, publication) ->
      (* NN04：路由 Pet_environment_refresh（模块锁→Registry 锁，路由侧不持
         Registry 锁调用）。 *)
      let admitted =
        with_tables (fun () ->
            match Registry.find_operation binding with
            | Some _ -> `Existing
            | None ->
                (match admit_new header binding request with
                 | `Rejected reply -> `Rejected reply
                 | `Admitted ->
                     Registry.highest_seen := T.U.get (T.op_seq binding);
                     let line_id =
                       match T.op_binding_line_owner binding with
                       | context, _, _ -> context
                     in
                     Registry.register_operation binding
                       (make_aux_operation binding line_id);
                     `Fresh))
      in
      (match admitted with
       | `Rejected reply -> reply
       | `Existing | `Fresh ->
           Refresh.refresh ~header ~binding ~old_env ~new_env ~publication)
  | T.QueryRequest (header, binding, node, (source, start, stop), output_budget) ->
      (* spec §4：路由 Pet_query（准入/节点解析/解析/白名单/执行捕获/发布在模块内，
         模块锁→Registry 锁，路由侧不持 Registry 锁调用）。 *)
      Query.run ~request ~header ~binding ~node ~source ~start ~stop ~output_budget
  | T.InspectRequest (header, binding, node, selector, output_budget) ->
      (* spec §4：Environment 消费显式可信 snapshot（M5 未接）、Notations 依赖固定
         Rocq 纯接口——本批在准入前拒绝（不登记操作、不推进序号），不留假数据。
         其余 selector 路由 Pet_inspect。 *)
      (match selector with
       | T.Environment | T.Notations ->
           T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown
       | _ ->
           Inspect.run ~request ~header ~binding ~node ~selector ~output_budget)
  | T.EndScopeRequest (header, binding, scope, expected_revision) ->
      (* item 5（N05）：路由 Pet_scope_lifecycle（准入/借用枚举/Closing-Closed/真实
         删除在模块内，Registry 锁内串行）。 *)
      Scope.run ~request ~header ~binding ~scope ~expected_revision
  | T.CheckpointRequest (header, view) ->
      (* NC04/NC06/NC08：路由 Pet_checkpoint_dispatch（admit + make_aux_operation
         在 dispatch 内，line 记 binding.context）。 *)
      Checkpoint_dispatch.run_request ~request ~header ~view
    | T.SettleInterruptRequest (header, binding) ->
      (* spec §1.2 中断落定（幂等/兜底）：pull 内联落定已发布终态 ⇒ 原样重放
         （驱动端 settle 期待 Terminal，protocol_error 会隔离实例）；
         aux 终态操作（checkpoint / sync / refresh / query / inspect）同样原样
         重放 aux——Rust settle_checkpoint_operation / settle_inspection_interrupt
         期待 AuxTerminal；旧实现只看 op.terminal ⇒ 取消落在两步之间时回
         invalid_state ⇒ 驱动 ProtocolUnresolved + 隔离（inspection.rs:486-489）；
         未落定且有父快照 ⇒ 原恢复期限内恢复；否则 invalid_state。 *)
      with_tables (fun () ->
          match Registry.find_operation binding with
          | None ->
              T.make_protocol_error header T.unknown_operation T.not_admitted T.fact_unknown
          | Some op ->
              (match op.terminal, op.aux with
               | Some record, _ -> T.terminal_reply header record
               | None, Some aux -> T.locator_reply header aux
               | None, None ->
                   (match op.interrupt_snapshot with
                    | Some snapshot -> settle_interrupted_reply header op snapshot
                    | None when op.stop_requested && op.pending = None
                                  && op.state <> Registry.Executing ->
                        (* 取消落在两步之间：取消已受理、无在途步、无未 ACK 步 ⇒
                           操作停在 ACK 父节点且 doc 与之同步，如实发布 Interrupted
                           终态（stopped/synchronized=Known true、last_acked=父、
                           pending=N/A）。Rust settle 只接受 Terminal 或 pending 回执
                           （interrupt.rs:418-421），旧实现回 invalid_state ⇒ 驱动
                           checked_mainline_transport 隔离。 *)
                        let record =
                          T.make_interrupted_terminal op.binding
                            (uint (Int64.succ op.acked_through))
                            ~stopped:(T.FKnown true)
                            ~synchronized:(T.FKnown true)
                            ~last_acked:(T.FKnown op.parent)
                            ~pending:T.FNotApplicable
                            ~recoverable:(T.FKnown true)
                            ~diagnostic:T.FUnknown
                            ~extent:T.CompleteKnown
                        in
                        op.terminal <- Some record;
                        (* 与恢复路径同款清账本：代际 +1、清 stop_requested、无 token。 *)
                        op.cancel_generation <- Int64.succ op.cancel_generation;
                        op.stop_requested <- false;
                        op.token <- None;
                        T.terminal_reply header record
                    | None ->
                        (* 无在途中断（取消未请求或未真实发生）⇒ invalid_state。 *)
                        T.make_protocol_error header T.invalid_state T.not_admitted
                          T.fact_unknown)))
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
  (* NN03：boot 绑定注入源码同步模块（线表文档构造/视图配额用）。 *)
  Sync.init ~boot;
  (* item 3：boot 绑定注入 checkpoint 分发（预算/配额/epoch 核对用）。 *)
  Checkpoint_dispatch.init ~boot;
  (* item 4：boot 绑定注入 query/inspect 视图 spool（父子共享 view 配额用）。 *)
  Query_view.init ~boot;
  (* item 5：scope 生命周期状态清零。 *)
  Scope.init ();
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
