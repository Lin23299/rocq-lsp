(* 查询执行（spec §4，devlog 六项 #6）。
    职责：QueryRequest 公共入口——准入（序号/退役/预算登记/entry_uses_budget）、
    账本节点解析（root-<line> / node-<line>-<n>，n = 第 n 个带 AST 的真实执行节点，
    与 receipt 的 node id 同一序号方案；单 context 近似：第一条 Mainline 线上最早
    登记的操作 = doc 持有者）、命令源字节范围核验（sealed、start<stop、UTF-8 边界）、
    官方 parser 解析为有限 AST 列表（不自写分句）、白名单分类全过才执行、在节点
    状态上以临时 token 逐 AST 解释并捕获输出（受 min(output_bytes, view_quota)
    上界，超限截断 reason=BudgetExhausted）、结束恢复原状态（含打印选项）、
    spool 登记（成功 = 可拉取 view；执行失败 = 已捕获前缀挂原操作私有 lease，
    终态仍为 Error）、aux 终态发布与幂等重放。pet_inspect 复用本模块的准入、
    节点解析、执行捕获与发布。
    不承诺的事：args.output_budget 是独立 id，不与 binding.budget 推断同一（Rust
    明示），输出上界只取 binding 预算；本批无受管诊断索引 ⇒ diagnostic 恒 FUnknown，
    view id 绝不冒充；失败前缀的 view id 不进 Error 终态（wire 无此字段），该私有
    lease 由 item 5 的 scope 清理丢弃；不核驱动侧期限（取消经控制通道 token 真实
    到达）；Coq 执行在 ordinary 线程串行，不在执行期间持 Registry 锁 / view 锁。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json
module Registry = Pet_registry
module Shell = Petanque_shell.Shell
module Check = Pet_query_check
module View = Pet_query_view
module Scope = Pet_scope_lifecycle

let get = function Ok value -> value | Error _ -> invalid_arg "pet_query"
let uint value = get (T.U.make value)
let id_value value = get (T.Id.make value)
let opt_list = function Some x -> [ x ] | None -> [] (* Stdlib.Option 无 to_list *)

(* —— 节点解析（须在 Registry 锁内）—— *)

type anchor = {
  doc : Fleche.Doc.t;
  state : Coq.State.t;              (* 目标节点状态：root 或第 n 个执行节点之后 *)
  context_op : Registry.operation;  (* 主线 doc 持有者 *)
  line_key : string;
}

let uri_counter = ref 0

let fresh_uri () =
  incr uri_counter;
  Lang.LUri.of_string
    (Format.asprintf "file:///tmp/ccv_query_%d_%d.v" (Unix.getpid ()) !uri_counter)
  |> Lang.LUri.File.of_uri |> get

(* 账本节点 id：root-<line> ⇒ root；node-<line>-<n> ⇒ 第 n 个节点（n ≥ 1，纯数字、
   无前导零；line id 自身可含 '-'，故取最右侧分隔）。 *)
let parse_node node =
  let s = T.Id.get node in
  let n = String.length s in
  let has_prefix p =
    let l = String.length p in
    n > l && String.sub s 0 l = p
  in
  let index k =
    String.length k > 0 && String.for_all (fun c -> c >= '0' && c <= '9') k
    && (String.length k = 1 || k.[0] <> '0')
    && int_of_string k >= 1
  in
  if has_prefix "root-" then Some (String.sub s 5 (n - 5), 0)
  else if has_prefix "node-" then
    let body = String.sub s 5 (n - 5) in
    (match String.rindex_opt body '-' with
     | Some i when i > 0 ->
         let line = String.sub body 0 i in
         let k = String.sub body (i + 1) (String.length body - i - 1) in
         if index k then Some (line, int_of_string k) else None
     | _ -> None)
  else None

(* 主线 doc 持有者：第一条 Mainline 线上最早登记的操作（迭代新→旧，取最后命中）。
   探索线本批无独立执行栈（spec §1.1）⇒ 其节点不可解析。 *)
let resolve_anchor ~node =
  match parse_node node with
  | None -> Error T.invalid_input
  | Some (line_key, k) ->
      (match Registry.find_line (id_value line_key) with
       | None -> Error T.invalid_input
       | Some line when line.kind <> Registry.Mainline -> Error T.invalid_input
       | Some _ ->
           let holder = ref None in
           Registry.iter_operations (fun op ->
               if T.Id.get op.line = line_key then holder := Some op);
           (match !holder with
            | None -> Error T.invalid_input
            | Some context_op ->
                let doc_result =
                  match context_op.doc with
                  | Some doc -> Ok doc
                  | None ->
                      (match Registry.source_bytes context_op.source with
                       | None -> Error T.invalid_input
                       | Some raw ->
                           let doc =
                             Shell.make_doc ~token:(Coq.Limits.create_atomic ())
                               ~uri:(fresh_uri ()) ~raw
                           in
                           context_op.doc <- Some doc;
                           Ok doc)
                in
                (match doc_result with
                 | Error code -> Error code
                 | Ok doc ->
                     if k = 0 then
                       Ok { doc; state = doc.Fleche.Doc.root; context_op; line_key }
                     else
                       let executed =
                         List.filter
                           (fun (n : Fleche.Doc.Node.t) ->
                              Fleche.Doc.Node.ast n <> None)
                           doc.Fleche.Doc.nodes
                       in
                       (match List.nth_opt executed (k - 1) with
                        | None -> Error T.invalid_input
                        | Some target
                          when List.exists Lang.Diagnostic.is_error
                                 (Fleche.Doc.Node.diags target) ->
                            (* 出错节点的状态不是合法前缀：拒绝。 *)
                            Error T.invalid_input
                        | Some target ->
                            Ok
                              { doc; state = Fleche.Doc.Node.state target;
                                context_op; line_key }))))

(* 命令源字节范围：sealed 源、0 ≤ start < stop ≤ len、两端 UTF-8 字符边界。 *)
let utf8_boundary text i =
  i = 0 || i = String.length text || (Char.code text.[i] land 0xc0) <> 0x80

let command_text ~source ~start ~stop =
  let start = Int64.to_int (T.U.get start) in
  let stop = Int64.to_int (T.U.get stop) in
  match Registry.source_bytes source with
  | None -> Error T.invalid_input
  | Some raw ->
      if start < 0 || start >= stop || stop > String.length raw then
        Error T.invalid_input
      else if not (utf8_boundary raw start && utf8_boundary raw stop) then
        Error T.invalid_input
      else Ok (String.sub raw start (stop - start))

(* —— 准入与账本操作（须在 Registry 锁内）—— *)

let make_aux_operation binding line : Registry.operation =
  { binding; state = Registry.Ready; line; source = T.op_binding_source binding;
    expected_revision = uint 0L; cursor = 0L;
    parent = id_value (Format.asprintf "root-%s" (T.Id.get line));
    pending = None; terminal = None; aux = None; last_ack = None;
    acked_through = 0L; line_revision = 0L; doc = None;
    cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
    token = None; interrupt_snapshot = None; terminal_receipt = None }

(* 新操作准入（spec §1 预算准入）：序号 = highest_seen+1、未退役、预算已登记且
   entry_uses_budget 与原请求全匹配。已存在 ⇒ `Existing（幂等/续跑由调用方判）。 *)
let admit header binding (request : T.native_request) =
  let reject code = T.make_protocol_error header code T.not_admitted T.fact_unknown in
  let seq = T.U.get (T.op_seq binding) in
  match Registry.find_operation binding with
  | Some op -> `Existing op
  | None ->
      if seq <= !Registry.retired_through then
        `Rejected
          (T.make_past_unavailable header (T.op_seq binding) (uint !Registry.highest_seen))
      else if not (Scope.admits ~binding) then `Rejected (reject T.invalid_state)
      else if seq <> Int64.succ !Registry.highest_seen then `Rejected (reject T.SequenceGap)
      else
        match Registry.find_budget (T.op_binding_budget binding) with
        | None -> `Rejected (reject T.invalid_input)
        | Some budget ->
            if not (T.entry_uses_budget S.message_limits budget request) then
              `Rejected (reject T.invalid_input)
            else begin
              Registry.highest_seen := seq;
              let context, _, _ = T.op_binding_line_owner binding in
              let op = make_aux_operation binding context in
              Registry.register_operation binding op;
              `Fresh op
            end

(* —— 解析与执行 —— *)

(* 官方 parser 解析区间文本为有限 AST 列表（在节点状态上下文内解析，不自写分句）。 *)
let parse_commands ~token ~st text =
  let pa = Coq.Parsing.Parsable.make (Coq.Parsing.Stream.of_string text) in
  let rec loop acc =
    let { Coq.Protect.E.r; _ } = Coq.Parsing.parse ~token ~st pa in
    match r with
    | Coq.Protect.R.Completed (Ok None) -> Ok (List.rev acc)
    | Coq.Protect.R.Completed (Ok (Some ast)) -> loop (ast :: acc)
    | Coq.Protect.R.Completed (Error _) -> Error `Parse
    | Coq.Protect.R.Interrupted -> Error `Interrupted
  in
  loop []

type execution = {
  captured : string;                               (* 已捕获输出（≤ cap，UTF-8 完整） *)
  truncated : bool;                                (* 超出输出上界被截断 *)
  outcome : [ `Ok | `Error | `Interrupted ];
  error : string option;                           (* Coq 用户错误/异常文本 *)
  restored : bool;                                 (* 原状态恢复成功 *)
}

let error_text = function
  | Coq.Protect.Error.User payload | Coq.Protect.Error.Anomaly payload ->
      Some (Coq.Pp_t.to_string payload.Coq.Message.Payload.msg)

(* [0, len) 内最大完整 UTF-8 前缀的字节长度。 *)
let utf8_prefix_length text len =
  let rec boundary n =
    if n = 0 then 0
    else if (Char.code text.[n - 1] land 0xc0) = 0x80 then boundary (n - 1)
    else n
  in
  boundary len

(* 逐 AST 解释并捕获输出：反馈消息逐条转文本（Coq.Pp_t.to_string）追加，受 cap
   字节上界——超限截断并停止追加，但已白名单的只读命令继续执行到结束（执行范围
   完全已知，仅输出不完整）。遇 Coq 用户错误即停（outcome=`Error）；token 被
   set ⇒ Interrupted。结束用原子 token 重新安装节点状态（恢复打印选项等）。 *)
let execute_asts ~token ~(anchor : anchor) ~cap asts =
  let buffer = Buffer.create 256 in
  let truncated = ref false in
  let cap = Int64.to_int cap in
  let capture_text text =
    if not !truncated then begin
      Buffer.add_string buffer text;
      let len = Buffer.length buffer in
      if len > cap then begin
        let full = Buffer.contents buffer in
        let keep = utf8_prefix_length full cap in
        Buffer.clear buffer;
        Buffer.add_string buffer (String.sub full 0 keep);
        truncated := true
      end
    end
  in
  let capture_feedback feedback =
    List.iter
      (fun (_, (payload : _ Coq.Message.Payload.t)) ->
         capture_text (Coq.Pp_t.to_string payload.Coq.Message.Payload.msg ^ "\n"))
      feedback
  in
  let outcome = ref `Ok in
  let error = ref None in
  let restored = ref true in
  let rec loop st = function
    | [] -> Coq.Protect.E.ok st
    | ast :: rest ->
        let { Coq.Protect.E.r; feedback } =
          Coq.Interp.interp ~token ~intern:Vernacinterp.fs_intern ~st ast
        in
        capture_feedback feedback;
        (match r with
         | Coq.Protect.R.Completed (Ok st') -> loop st' rest
         | Coq.Protect.R.Completed (Error e) ->
             outcome := `Error;
             error := error_text e;
             Coq.Protect.E.ok st
         | Coq.Protect.R.Interrupted ->
             outcome := `Interrupted;
             Coq.Protect.E.ok st)
  in
  Fun.protect
    ~finally:(fun () ->
        try
          ignore
            (Coq.State.in_state ~token:(Coq.Limits.create_atomic ()) ~st:anchor.state
               ~f:(fun () -> ()) ())
        with _ -> restored := false)
    (fun () ->
       let { Coq.Protect.E.r; feedback } =
         Coq.State.in_stateM ~token ~st:anchor.state
           ~f:(fun () -> loop anchor.state asts) ()
       in
       capture_feedback feedback;
       (match r with
        | Coq.Protect.R.Completed (Ok _) -> ()
        | Coq.Protect.R.Completed (Error e) ->
            outcome := `Error;
            error := error_text e
        | Coq.Protect.R.Interrupted -> outcome := `Interrupted));
  { captured = Buffer.contents buffer; truncated = !truncated;
    outcome = !outcome; error = !error; restored = !restored }

(* —— 发布（view 锁 → Registry 锁）—— *)

let op_tag binding =
  Format.asprintf "%s-%Ld" (T.Id.get (T.op_binding_operation binding))
    (T.U.get (T.op_seq binding))

(* 父视图 id：view-<operation>-<seq>（与 line_updates spool 同一方案，全局唯一）。 *)
let view_id binding = id_value (Format.asprintf "view-%s" (op_tag binding))

let retiring header binding (op : Registry.operation) =
  op.state <- Registry.Retiring;
  op.token <- None;
  T.make_retiring_status header binding
    ~highest_seen:(uint !Registry.highest_seen)
    ~retired_through:(uint !Registry.retired_through)
    ~stop_requested:op.stop_requested

(* 视图终态（成功）：全部 spool 原子登记（父子各自独立 ACK/release）→ aux →
   AuxTerminal；kind=None 为 Query 文本视图，Some 为 Inspect TypedFacts 视图。
   登记撞名（内部不变量破坏）⇒ 不发布新身份，回 Retiring（未知口径）。 *)
let publish_view ~header ~binding ~(op : Registry.operation) ~node ~kind ~spools
    ~view ~capture =
  View.with_lock (fun () ->
      if View.register spools = `Conflict then
        Registry.with_tables (fun () -> retiring header binding op)
      else
        Registry.with_tables (fun () ->
            let aux =
              match kind with
              | None ->
                  T.make_query_view_terminal binding ~node ~view ~capture
                    ~extent:T.CompleteKnown
              | Some k ->
                  T.make_inspect_view_terminal binding ~node ~view ~capture ~kind:k
                    ~extent:T.CompleteKnown
            in
            op.aux <- Some aux;
            op.state <- Registry.TerminalState;
            op.token <- None;
            T.locator_reply header aux))

(* 错误终态：last_valid=Known 锚点节点；有已捕获前缀 ⇒ 挂原操作私有 lease
   （devlog「失败查询的已捕获前缀」；Error 终态不带 view，由 item 5 清理）。 *)
let publish_error ~header ~binding ~(op : Registry.operation) ~node ~stage ~extent
    ~prefix =
  View.with_lock (fun () ->
      if prefix <> "" then
        ignore
          (View.register
             [ View.create ~view:(view_id binding)
                 ~operation:(T.op_binding_operation binding) ~text:prefix
                 ~capture:(View.complete_capture prefix) ]);
      Registry.with_tables (fun () ->
          let aux =
            T.make_query_error_terminal binding ~stage ~diagnostic:T.FUnknown
              ~last_valid:(T.FKnown node) ~extent
          in
          op.aux <- Some aux;
          op.state <- Registry.TerminalState;
          op.token <- None;
          T.locator_reply header aux))

let reject header code =
  T.make_protocol_error header code T.not_admitted T.fact_unknown

(* —— 公共入口 —— *)

let run ~request ~header ~binding ~node ~source ~start ~stop ~output_budget =
  ignore output_budget;
  let setup =
    Registry.with_tables (fun () ->
        match Registry.find_operation binding with
        | Some { aux = Some aux; _ } -> `Replay aux
        | Some op -> `Existing op
        | None ->
            (match admit header binding request with
             | `Rejected reply -> `Rejected reply
             | `Existing op -> `Existing op
             | `Fresh op -> `Fresh op))
  in
  match setup with
  | `Rejected reply -> reply
  | `Replay aux ->
      (* 幂等：同 binding 重入重放原 aux（直答与 status 同源）。 *)
      T.locator_reply header aux
  | `Existing op | `Fresh op ->
      let prepared =
        Registry.with_tables (fun () ->
            match resolve_anchor ~node with
            | Error code -> `Rejected (reject header code)
            | Ok anchor ->
                (match command_text ~source ~start ~stop with
                 | Error code -> `Rejected (reject header code)
                 | Ok text ->
                     (match Registry.find_budget (T.op_binding_budget binding) with
                      | None -> `Rejected (reject header T.invalid_input)
                      | Some budget ->
                          `Ready (anchor, text, View.quota budget))))
      in
      (match prepared with
       | `Rejected reply -> reply
       | `Ready (anchor, text, cap) ->
           let token = Coq.Limits.Token.create () in
           Registry.with_tables (fun () ->
               op.token <- Some token;
               op.state <- Registry.Executing);
           let stage_result =
             match parse_commands ~token ~st:anchor.state text with
             | Error `Parse | Error `Interrupted -> Error T.Parse
             | Ok asts ->
                 (match Check.classify asts with
                  | Error _ -> Error T.Register
                  | Ok () -> Ok asts)
           in
           (match stage_result with
            | Error stage ->
                (* 解析失败 / 解析期取消 / 白名单拒绝：尚未执行任何命令，节点状态
                   未被改动（解析本身在节点状态上下文内进行），范围已知、无前缀。 *)
                publish_error ~header ~binding ~op ~node ~stage
                  ~extent:T.CompleteKnown ~prefix:""
            | Ok asts ->
                let exec = execute_asts ~token ~anchor ~cap asts in
                (match exec.outcome with
                 | `Ok ->
                     let capture =
                       if exec.truncated then View.truncated_capture exec.captured
                       else View.complete_capture exec.captured
                     in
                     let spool =
                       View.create ~view:(view_id binding)
                         ~operation:(T.op_binding_operation binding)
                         ~text:exec.captured ~capture
                     in
                     publish_view ~header ~binding ~op ~node ~kind:None
                       ~spools:[ spool ] ~view:(view_id binding) ~capture
                 | `Error ->
                     (* Coq 用户错误：执行范围已知（遇错即停）。 *)
                     publish_error ~header ~binding ~op ~node ~stage:T.Execute
                       ~extent:T.CompleteKnown ~prefix:exec.captured
                 | `Interrupted ->
                     (* 取消真实到达：原状态恢复成功 ⇒ 范围已知；恢复失败 ⇒ 保留
                        Unknown（UnknownTail，驱动隔离实例），绝不假恢复。 *)
                     publish_error ~header ~binding ~op ~node ~stage:T.Execute
                       ~extent:
                         (if exec.restored then T.CompleteKnown else T.UnknownTail)
                       ~prefix:exec.captured)))
