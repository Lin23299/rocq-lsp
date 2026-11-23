(* 检视（spec §4，真实 Rocq 结构）。
    职责：InspectRequest 公共入口——准入/节点解析/执行捕获/发布复用 Pet_query；
    按 selector 产出 TypedFacts 视图：
    - Toc：doc.toc 真实条目（文档顺序；index=位置；parent 本批不跟踪层级 ⇒ N/A；
      kind 文本取 Info.detail（通常是类型）否则 SymbolKind 十进制；range=节点字节
      区间），complete=true。
    - GoalRoster：节点状态上 Coq.Goals.reify（compact:false，逐假设独立）⇒ 五组
      （Focused=goals、StackLeft/StackRight=stack 各帧 fst/snd、depth=帧层 1..n、
      Shelved、GivenUp；无证明 ⇒ 各组空；stack 无帧 ⇒ depth=0 占位组）；每个
      part（假设类型/体/结论）= 文本子视图（同文本去重共享 view id）；本批单页
      全量、next=N/A、complete=true；带 cursor 的请求本批无后续页 ⇒ 拒绝。
    - GoalPart：按 selector 定位 goal 后物化 part 文本（Conclusion=ty，
      Hypothesis i=第 i 个假设的 ty），range 为 part 文本字节窗口（UTF-8 边界），
      eof iff 窗口到末尾，digest 为整个 part。
    - Assumptions：逐 root 以官方 AST（文本 "Print Assumptions <name>." 解析后核
      恰为一个 VernacSynPure(VernacPrint(PrintAssumptions(_,_,AN _)))、无 control/
      attrs，杜绝文本注入）在节点状态上执行并捕获输出：首行 "Closed under the
      global context" ⇒ AsmClosed；其余 ⇒ AsmAssumptions（行解析从简：非表头行
      各为一项，首个 " :" 之前为 kernel_name，整行为 printed_type 子视图）；Coq
      错误/取消/超限 ⇒ AsmUnavailable（error=Known 文本）；raw 为独立子视图。
    - Environment / Notations：本批拒绝（M5 可信 snapshot / 固定 Rocq 纯接口未接，
      不留假数据）。
    产出：payload 字节 → 内层 complete capture → facts 文档（node/source/
    environment 取请求与 binding；Rust checked_facts_document 逐字节重建）→ 外层
    complete capture → 父 spool + 子 spool 原子登记 → make_inspect_view_terminal。
    父子共享同一输出配额：父文档 + 全部子视图 ≤ min(output_bytes, view_quota)，
    超限 ⇒ StageView 错误终态（TypedFacts 父文档必须完整，不截断）。
    不承诺的事：不伪造 kernel 名解析（resolved=FUnknown）；TOC 层级不跟踪；不分
    页；本批无受管诊断索引 ⇒ diagnostic 恒 FUnknown。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json
module V = Vernacexpr
module C = Constrexpr
module Registry = Pet_registry
module Query = Pet_query
module View = Pet_query_view
module G = Coq.Goals

let get = function Ok value -> value | Error _ -> invalid_arg "pet_inspect"
let uint value = get (T.U.make value)
let id_value value = get (T.Id.make value)

(* Text.make 要求非空且 ≤65536：超界文本按「不可用」占位，不编造内容。 *)
let safe_text text =
  if text = "" || String.length text > 65536 then "<unavailable>" else text

let text_value value = get (T.Text.make (safe_text value))
let digest_value value = get (T.Digest.make value)

type goals = (string, string) G.reified

(* —— 子视图分配（同文本去重：同 view id ⇒ 同内容，Rust exact-alias 去重对账）—— *)

type child = { view : T.Id.t; descriptor : T.native_part_descriptor }

type parts = {
  operation : T.Id.t;
  prefix : string;                                (* "<role>-<operation>-<seq>" *)
  table : (string, child) Hashtbl.t;
  counter : int ref;
  mutable spools : View.spool list;
  mutable total_bytes : int64;                    (* 去重后子视图字节总和 *)
}

let new_parts ~binding ~role =
  let operation = T.op_binding_operation binding in
  { operation;
    prefix = Format.asprintf "%s-%s" role (Query.op_tag binding);
    table = Hashtbl.create 16;
    counter = ref 0;
    spools = [];
    total_bytes = 0L }

let child_of parts text =
  match Hashtbl.find_opt parts.table text with
  | Some child -> child
  | None ->
      incr parts.counter;
      let view = id_value (Format.asprintf "%s-%d" parts.prefix !(parts.counter)) in
      let descriptor =
        T.make_native_part_descriptor
          ~bytes:(uint (Int64.of_int (String.length text)))
          ~digest:(digest_value (S.sha256 text)) ~view
      in
      let child = { view; descriptor } in
      Hashtbl.replace parts.table text child;
      parts.spools <-
        View.create ~view ~operation:parts.operation ~text
          ~capture:(View.complete_capture text)
        :: parts.spools;
      parts.total_bytes <-
        Int64.add parts.total_bytes (Int64.of_int (String.length text));
      child

(* —— facts 文档与发布 —— *)

let facts_document ~node ~binding payload =
  let payload_bytes = get (T.encode_native_facts_payload S.message_limits payload) in
  let source = T.op_binding_source binding in
  let environment = match T.op_binding_line_owner binding with _, _, e -> e in
  let document =
    T.make_native_facts_document ~node ~source ~environment
      ~capture:(View.complete_capture payload_bytes) payload
  in
  get (T.encode_native_facts_document S.message_limits document)

let publish ~header ~binding ~(op : Registry.operation) ~node ~kind ~parts payload =
  let doc_bytes = facts_document ~node ~binding payload in
  let budget =
    Registry.with_tables (fun () ->
        Registry.find_budget (T.op_binding_budget binding))
  in
  let fits =
    match budget with
    | None -> false
    | Some budget ->
        View.output_budget_check ~budget ~used_so_far:parts.total_bytes
          ~new_bytes:(Int64.of_int (String.length doc_bytes))
  in
  if not fits then
    (* 父文档必须完整：超限不截断，报 StageView 错误终态（不登记任何 spool）。 *)
    Query.publish_error ~header ~binding ~op ~node ~stage:T.StageView
      ~extent:T.CompleteKnown ~prefix:""
  else
    let view = Query.view_id binding in
    let parent =
      View.create ~view ~operation:(T.op_binding_operation binding) ~text:doc_bytes
        ~capture:(View.complete_capture doc_bytes)
    in
    Query.publish_view ~header ~binding ~op ~node ~kind:(Some kind)
      ~spools:(parent :: parts.spools) ~view ~capture:(View.complete_capture doc_bytes)

(* —— Toc —— *)

let toc_payload (doc : Fleche.Doc.t) =
  let module Info = Lang.Ast.Info in
  let rec find_info name (info : Info.t) =
    if (match info.Info.name.Lang.With_range.v with
        | Some n -> n = name | None -> false)
    then Some info
    else Stdlib.Option.bind info.Info.children (List.find_map (find_info name))
  in
  let position target =
    let rec go index = function
      | [] -> max_int
      | n :: rest -> if n == target then index else go (index + 1) rest
    in
    go 0 doc.Fleche.Doc.nodes
  in
  let kind_text name node =
    match node.Fleche.Doc.Node.ast with
    | Some { Fleche.Doc.Node.Ast.ast_info = Some infos; _ } ->
        (match List.find_map (find_info name) infos with
         | Some info ->
             (match info.Info.detail with
              | Some detail when detail <> "" -> detail
              | _ -> string_of_int info.Info.kind)
         | None -> "unknown")
    | _ -> "unknown"
  in
  let range node =
    let r = node.Fleche.Doc.Node.range in
    get
      (T.make_byte_range ~start:(uint (Int64.of_int r.start.offset))
         ~stop:(uint (Int64.of_int r.end_.offset)))
  in
  let entries =
    Lang.Compat.String.Map.bindings doc.Fleche.Doc.toc
    |> List.map (fun (name, node) -> (position node, name, node))
    |> List.stable_sort (fun (a, _, _) (b, _, _) -> compare a b)
  in
  let rows =
    List.mapi
      (fun index (_, name, node) ->
         ( uint (Int64.of_int index),
           T.FNotApplicable,
           text_value name,
           text_value (kind_text name node),
           range node ))
      entries
  in
  get (T.make_toc_facts rows ~complete:true)

(* —— goals 物化 —— *)

let goals_of ~token ~(anchor : Query.anchor) : (goals option, bool) result =
  (* 走 Fleche 官方 goals 入口（Coq.State.in_state 内 reify，goal_concl_style 打印），
     与 petanque Agent.goals 同一路径但 State 不经其抽象层。返回 Error 标记：
     true = token 真实到达（取消）。 *)
  let pr = Fleche.Info.Goals.to_pp in
  let { Coq.Protect.E.r; _ } =
    Fleche.Info.Goals.goals ~token ~pr ~compact:false ~st:anchor.Query.state
  in
  match r with
  | Coq.Protect.R.Interrupted -> Error true
  | Coq.Protect.R.Completed (Error _) -> Error false
  | Coq.Protect.R.Completed (Ok None) -> Ok None
  | Coq.Protect.R.Completed (Ok (Some reified)) ->
      let f = Coq.Goals.Reified_goal.map ~f:Coq.Pp_t.to_string in
      Ok (Some (Coq.Goals.map ~f ~g:Coq.Pp_t.to_string reified))

let empty_goals : goals =
  { G.goals = []; stack = []; bullet = None; shelf = []; given_up = [] }

let hypothesis (parts : parts) index (h : string G.Reified_goal.hyp) =
  let names =
    List.filter_map
      (fun name -> match T.Text.make (safe_text name) with Ok t -> Some t | Error _ -> None)
      h.G.Reified_goal.names
  in
  let body =
    match h.G.Reified_goal.def with
    | Some def -> T.FKnown (child_of parts def).descriptor
    | None -> T.FNotApplicable
  in
  get
    (T.make_native_hypothesis ~index:(uint (Int64.of_int index)) ~names ~body
       ~ty:(child_of parts h.G.Reified_goal.ty).descriptor)

let entry (parts : parts) ~group ~depth ~index (g : string G.Reified_goal.t) =
  let hyps = List.mapi (fun i h -> hypothesis parts (i + 1) h) g.G.Reified_goal.hyps in
  get
    (T.make_native_goal_entry ~group ~depth:(uint (Int64.of_int depth))
       ~index:(uint (Int64.of_int index)) ~hypotheses:hyps
       ~conclusion:(child_of parts g.G.Reified_goal.ty).descriptor)

let group (parts : parts) grp depth list =
  get
    (T.make_native_goal_group ~group:grp ~depth:(uint (Int64.of_int depth))
       ~total:(uint (Int64.of_int (List.length list)))
       ~entries:(List.mapi (fun i g -> entry parts ~group:grp ~depth ~index:(i + 1) g) list))

(* stack 帧 i（0 起）⇒ depth=i+1；无帧 ⇒ depth=0 占位（make_goal_roster_facts 要求
   每侧至少一组）。 *)
let frames (parts : parts) side pick stack =
  match stack with
  | [] -> [ group parts side 0 [] ]
  | stack -> List.mapi (fun i frame -> group parts side (i + 1) (pick frame)) stack

let roster_payload parts (goals : goals) =
  let focused = group parts T.Focused 0 goals.G.goals in
  let lefts = frames parts T.StackLeft fst goals.G.stack in
  let rights = frames parts T.StackRight snd goals.G.stack in
  let shelved = group parts T.Shelved 0 goals.G.shelf in
  let given_up = group parts T.GivenUp 0 goals.G.given_up in
  get
    (T.make_goal_roster_facts ([ focused ] @ lefts @ rights @ [ shelved; given_up ])
       ~next:T.FNotApplicable ~complete:true)

let find_goal (goals : goals) (sel : T.goal_selector) : string G.Reified_goal.t option =
  let depth = Int64.to_int (T.U.get sel.T.depth) in
  let index = Int64.to_int (T.U.get sel.T.index) in
  let nth list = if index < 1 || depth < 0 then None else List.nth_opt list (index - 1) in
  match sel.T.selector_group with
  | T.Focused -> nth goals.G.goals
  | T.Shelved -> nth goals.G.shelf
  | T.GivenUp -> nth goals.G.given_up
  | T.StackLeft | T.StackRight ->
      if depth < 1 then None
      else
        match List.nth_opt goals.G.stack (depth - 1) with
        | None -> None
        | Some (left, right) ->
            nth (if sel.T.selector_group = T.StackLeft then left else right)

let part_text (g : string G.Reified_goal.t) = function
  | T.Conclusion -> Some g.G.Reified_goal.ty
  | T.Hypothesis index ->
      let i = Int64.to_int (T.U.get index) in
      if i < 1 then None
      else
        Stdlib.Option.map
          (fun (h : string G.Reified_goal.hyp) -> h.G.Reified_goal.ty)
          (List.nth_opt g.G.Reified_goal.hyps (i - 1))

let utf8_boundary text i =
  i = 0 || i = String.length text || (Char.code text.[i] land 0xc0) <> 0x80

(* range 为 part 文本字节窗口（≤65536：make_goal_part_facts 的 text 上界）；返回
   (窗口文本, eof)。 *)
let window text (range : T.byte_range) =
  let start = Int64.to_int (T.U.get range.T.range_start) in
  let stop = Int64.to_int (T.U.get range.T.range_end) in
  let len = String.length text in
  if start < 0 || stop > len || stop - start > 65536
     || not (utf8_boundary text start && utf8_boundary text stop)
  then None
  else Some (String.sub text start (stop - start), stop = len)

(* —— Assumptions —— *)

(* 组合并核形：恰一个 AST、无 control/attrs、Print Assumptions 作用于显式 qualid。 *)
let assumptions_ast ~token ~st name =
  let text = Format.asprintf "Print Assumptions %s." (T.Text.get name) in
  match Query.parse_commands ~token ~st text with
  | Error _ -> None
  | Ok [ ast ] ->
      let vernac : V.vernac_control = Coq.Ast.to_coq ast in
      (match vernac.CAst.v with
       | { V.control = []; V.attrs = [];
           V.expr = V.VernacSynPure (V.VernacPrint (V.PrintAssumptions (_, _, q))); _ } ->
           (match q.CAst.v with C.AN _ -> Some ast | C.ByNotation _ -> None)
       | _ -> None)
  | Ok _ -> None

let split_lines text =
  String.split_on_char '\n' text |> List.map String.trim |> List.filter (fun l -> l <> "")

(* 表头行：仅字母/空格且以冒号结尾（"Axioms:"、"Variables and Axioms:" 之类）。 *)
let header_line line =
  let n = String.length line in
  n > 0 && line.[n - 1] = ':'
  && String.for_all
       (fun c -> (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = ' ')
       (String.sub line 0 (n - 1))

let closed_line = "Closed under the global context"

(* 首个 " :" 之前为 kernel_name（本批从简：不解析真实 kernel 名）。 *)
let kernel_name_of line =
  let n = String.length line in
  let rec go i =
    if i >= n then Some line
    else if line.[i] = ':' && i > 0 && line.[i - 1] = ' ' then Some (String.sub line 0 (i - 1))
    else go (i + 1)
  in
  go 0

let assumption_root ~parts ~(requested : T.Text.t) ~text ~failure =
  let reason = Stdlib.Option.value failure ~default:"no output" in
  let raw_text = if text <> "" then text else reason in
  let raw = child_of parts raw_text in
  let status, items, error =
    match failure with
    | Some _ -> (T.AsmUnavailable, [], T.FKnown reason)
    | None ->
        (match split_lines text with
         | first :: _ when String.starts_with first ~prefix:closed_line ->
             (T.AsmClosed, [], T.FNotApplicable)
         | [] -> (T.AsmUnavailable, [], T.FKnown reason)
         | lines ->
             let items =
               List.filter_map
                 (fun line ->
                    if header_line line then None
                    else
                      match kernel_name_of line with
                      | None -> None
                      | Some kernel_name ->
                          Some
                            (T.make_assumption_item
                               ~kernel_name:(text_value kernel_name)
                               ~printed_type:(child_of parts line).view))
                 lines
             in
             (T.AsmAssumptions, items, T.FNotApplicable))
  in
  get
    (T.make_assumption_root ~requested ~resolved:T.FUnknown ~status ~assumptions:items
       ~raw:raw.view ~error)

(* —— 公共入口 —— *)

let kind_of = function
  | T.Assumptions _ -> T.IkAssumptions
  | T.Toc -> T.IkToc
  | T.Notations -> T.IkNotations
  | T.Environment -> T.IkEnvironment
  | T.GoalRoster _ -> T.IkGoalRoster
  | T.GoalPartSel _ -> T.IkGoalPart

type built =
  [ `Payload of T.native_facts_payload * parts
  | `Rejected of T.native_code
  | `Failed of T.native_stage * T.extent ]

let build ~token ~(anchor : Query.anchor) ~binding ~cap ~selector =
  match selector with
  | T.Toc ->
      `Payload (toc_payload anchor.Query.doc, new_parts ~binding ~role:"part")
  | T.Environment | T.Notations -> `Rejected T.invalid_input
  | T.GoalRoster (Some _) ->
      (* 本批单页全量且 next=N/A：Pet 从未签发 cursor ⇒ 任何 cursor 请求均无对应页。 *)
      `Rejected T.invalid_input
  | T.GoalRoster None ->
      let parts = new_parts ~binding ~role:"part" in
      (match goals_of ~token ~anchor with
       | Error interrupted ->
           (* 物化期取消：节点状态未被改动（只读打印）；Coq 异常同理。 *)
           ignore interrupted;
           `Failed (T.Execute, T.CompleteKnown)
       | Ok None -> `Payload (roster_payload parts empty_goals, parts)
       | Ok (Some goals) -> `Payload (roster_payload parts goals, parts))
  | T.GoalPartSel (sel, part, range) ->
      let parts = new_parts ~binding ~role:"part" in
      (match goals_of ~token ~anchor with
       | Error _ -> `Failed (T.Execute, T.CompleteKnown)
       | Ok None -> `Rejected T.invalid_input
       | Ok (Some goals) ->
           (match Stdlib.Option.bind (find_goal goals sel) (fun g -> part_text g part) with
            | None -> `Rejected T.invalid_input
            | Some text ->
                (match window text range with
                 | None -> `Rejected T.invalid_input
                 | Some sub_window ->
                     let sub, eof = sub_window in
                     `Payload
                       ( get
                           (T.make_goal_part_facts ~goal:sel ~part ~range
                              ~total_bytes:(uint (Int64.of_int (String.length text)))
                              ~text:sub
                              ~part_digest:(digest_value (S.sha256 text)) ~eof),
                         parts ))))
  | T.Assumptions names ->
      let parts = new_parts ~binding ~role:"asm" in
      let roots =
        List.map
          (fun (requested : T.Text.t) ->
             match assumptions_ast ~token ~st:anchor.Query.state requested with
             | None ->
                 assumption_root ~parts ~requested ~text:""
                   ~failure:(Some "unparseable or non-qualid constant reference")
             | Some ast ->
                 let exec = Query.execute_asts ~token ~anchor ~cap [ ast ] in
                 let failure =
                   match exec.Query.outcome with
                   | `Error ->
                       Some (Stdlib.Option.value exec.Query.error ~default:"query failed")
                   | `Interrupted -> Some "interrupted"
                   | `Ok when exec.Query.truncated -> Some "output budget exhausted"
                   | `Ok when not exec.Query.restored -> Some "state restore failed"
                   | `Ok -> None
                 in
                 assumption_root ~parts ~requested ~text:exec.Query.captured ~failure)
          names
      in
      `Payload (get (T.make_assumptions_facts roots), parts)

let run ~request ~header ~binding ~node ~selector ~output_budget =
  ignore output_budget;
  let kind = kind_of selector in
  let setup =
    Registry.with_tables (fun () ->
        match Registry.find_operation binding with
        | Some { aux = Some aux; _ } -> `Replay aux
        | Some op -> `Existing op
        | None ->
            (match Query.admit header binding request with
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
            match Query.resolve_anchor ~node with
            | Error code -> `Rejected code
            | Ok anchor ->
                (match Registry.find_budget (T.op_binding_budget binding) with
                 | None -> `Rejected T.invalid_input
                 | Some budget -> `Ready (anchor, View.quota budget)))
      in
      (match prepared with
       | `Rejected code -> Query.reject header code
       | `Ready (anchor, cap) ->
           let token = Coq.Limits.Token.create () in
           Registry.with_tables (fun () ->
               op.token <- Some token;
               op.state <- Registry.Executing);
           let reset () =
             Registry.with_tables (fun () ->
                 op.token <- None;
                 op.state <- Registry.Ready)
           in
           (match build ~token ~anchor ~binding ~cap ~selector with
            | `Rejected code ->
                reset ();
                Query.reject header code
            | `Failed (stage, extent) ->
                Query.publish_error ~header ~binding ~op ~node ~stage ~extent ~prefix:""
            | `Payload (payload, parts) ->
                publish ~header ~binding ~op ~node ~kind ~parts payload))
