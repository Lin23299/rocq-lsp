(* 源码同步前缀适配（spec §2，item 2 / NN03 的纯逻辑半块）。
   职责：old→new 文本的三件事——
   1) 字节 LCP（结果必须落在 UTF-8 字符边界上，落不进就回退）；
   2) Fleche retain 适配：new==old 原样返回（changed=false）；否则
      bump_version 后 check 到 LCP 位置的 Position 目标，从新 doc 的真实
      节点求「保留前缀」——end ≤ LCP、无 error 诊断、ast 非空的连续前驱链，
      句界一律由 Fleche 官方 parser 决定，本模块绝不猜句界；
   3) horizon 投影：给定已验证偏移，读出保守 lexer 高水位与是否到 EOF。
   不承诺的事：不做任何协议裁决/记账（拒绝与未知口径归 pet_source_sync），
   不改 Registry，不感知操作身份。 *)

type horizon = { read_end : int; saw_eof : bool }

type retain_result = {
  doc : Fleche.Doc.t;      (* retain 后的 doc（new==old 时为原 doc） *)
  prefix_end : int;        (* 最后保留节点 end offset；无保留节点 = 0 *)
  kept : int;              (* 保留节点数 *)
  changed : bool;          (* new==old ⇒ false *)
}

(* 字节 LCP：先求逐字节公共前缀长度，再回退到 UTF-8 字符边界
   （字节 0 总是边界；落在连续字节 10xxxxxx 上则继续回退）。 *)
let lcp ~old ~new_ =
  let limit = min (String.length old) (String.length new_) in
  let rec common index =
    if index >= limit then limit
    else if old.[index] = new_.[index] then common (index + 1)
    else index
  in
  let rec boundary index =
    if index <= 0 then 0
    else if (Char.code old.[index] land 0xc0) = 0x80 then
      boundary (index - 1)
    else index
  in
  boundary (common 0)

(* 静默 IO 回调：retain 的 check 是内部材料重建，不向前端发诊断/进度/消息。 *)
let silent_io : Fleche.Io.CallBack.t =
  let nop_trace _header ?verbose:_ _message = () in
  let nop_message ~lvl:_ ~message:_ = () in
  let nop_diagnostics ~uri:_ ~version:_ _diags = () in
  let nop_progress ~uri:_ ~version:_ _info = () in
  let nop_perf ~uri:_ ~version:_ _perf = () in
  let nop_server_version _ = () in
  let nop_server_status _ = () in
  let nop_exec_info ~uri:_ ~version:_ ~range:_ = () in
  { Fleche.Io.CallBack.trace = nop_trace; message = nop_message;
    diagnostics = nop_diagnostics; fileProgress = nop_progress;
    perfData = nop_perf; serverVersion = nop_server_version;
    serverStatus = nop_server_status; execInfo = nop_exec_info }

(* 单个节点是否可保留：ast 完整、无 error 诊断、整体落在 LCP 之内。 *)
let node_retained (node : Fleche.Doc.Node.t) lcp =
  Fleche.Doc.Node.ast node <> None
  && node.Fleche.Doc.Node.range.end_.offset <= lcp
  && not (List.exists Lang.Diagnostic.is_error node.Fleche.Doc.Node.diags)

(* 保留前缀链的扫描结果（内部用；last_node 供调用方求边界）。 *)
type prefix_chain = {
  kept : int;                              (* 保留节点数 *)
  prefix_end : int;                        (* 最后保留节点 end offset；无 = 0 *)
  last_node : Fleche.Doc.Node.t option;    (* 最后保留节点 *)
}

(* 保留前缀链：顺序扫描，遇首个不可保留节点即断链（保守）。 *)
let retained_prefix (doc : Fleche.Doc.t) lcp =
  let rec walk count end_ last = function
    | [] -> { kept = count; prefix_end = end_; last_node = last }
    | node :: rest ->
        if node_retained node lcp then
          walk (count + 1) node.Fleche.Doc.Node.range.end_.offset (Some node) rest
        else { kept = count; prefix_end = end_; last_node = last }
  in
  walk 0 0 None doc.Fleche.Doc.nodes

(* 把字节 offset 换算成 (行, UTF-16 列)；offset 允许等于文本长度。
   lines 与 Fleche Contents 一致：按 '\n' 切分、不含换行符本身。 *)
let position_of_offset ~lines offset =
  let rec go index acc =
    if index >= Array.length lines then
      (* 落在文档末尾之后：取末行末列（空文档取 (0,0)）。 *)
      let last = Array.length lines - 1 in
      if last < 0 then (0, 0)
      else
        (last,
         Lang.Utf.utf16_offset_of_utf8_offset ~line:lines.(last)
           ~offset:(String.length lines.(last)))
    else
      let line = lines.(index) in
      let len = String.length line in
      if offset <= acc + len then
        (index, Lang.Utf.utf16_offset_of_utf8_offset ~line ~offset:(offset - acc))
      else go (index + 1) (acc + len + 1)
  in
  go 0 0

(* Fleche retain 适配（spec §2）。
   - new==old：原样返回 old_doc（changed=false），前缀仍按整文计算；
   - 否则：bump_version（版本+1，共用 uri/env/root）后 check 到 LCP 位置的
     Position 目标（跨 LCP 的句子会被执行但其节点不保留；恰在 LCP 起始的
     句子不会执行——Fleche reached 语义），再从新 doc 求保留前缀链。
   env/uri 仅在调用方传入时备用，本实现不重建 doc 身份。 *)
let retain ~token ~env:_ ~uri:_ ~old_raw ~old_doc ~new_raw =
  if String.equal old_raw new_raw then
    let plain = retained_prefix old_doc (String.length old_raw) in
    { doc = old_doc; prefix_end = plain.prefix_end; kept = plain.kept;
      changed = false }
  else
    let lcp = lcp ~old:old_raw ~new_:new_raw in
    let bumped =
      Fleche.Doc.bump_version ~token ~version:(old_doc.Fleche.Doc.version + 1)
        ~raw:new_raw old_doc
    in
    let line, character = position_of_offset ~lines:(Fleche.Doc.lines bumped) lcp in
    let checked =
      Fleche.Doc.check ~io:silent_io ~token
        ~target:(Fleche.Doc.Target.Position (line, character))
        ~doc:bumped ()
    in
    let plain = retained_prefix checked lcp in
    { doc = checked; prefix_end = plain.prefix_end; kept = plain.kept;
      changed = true }

(* 验证高水位：verified 为已验证的字节偏移。
   read_end = 下一未验证节点（end 越过 verified 的首个节点）的起点；
   无下一节点 ⇒ 最后节点 end（完全无节点 ⇒ verified 本身）。
   saw_eof = completed 为 Yes。 *)
let horizon_of (doc : Fleche.Doc.t) verified =
  let rec first_unverified = function
    | [] -> None
    | (node : Fleche.Doc.Node.t) :: rest ->
        if node.Fleche.Doc.Node.range.end_.offset > verified then Some node
        else first_unverified rest
  in
  let read_end =
    match first_unverified doc.Fleche.Doc.nodes with
    | Some node -> node.Fleche.Doc.Node.range.start.offset
    | None ->
        (match List.rev doc.Fleche.Doc.nodes with
         | (last : Fleche.Doc.Node.t) :: _ -> last.Fleche.Doc.Node.range.end_.offset
         | [] -> verified)
  in
  let saw_eof =
    match doc.Fleche.Doc.completed with
    | Fleche.Doc.Completion.Yes _ -> true
    | _ -> false
  in
  { read_end; saw_eof }
