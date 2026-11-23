(* 查询 AST 白名单（spec §4 / NB07 首版）。
    职责：对官方 parser 解析出的 Coq.Ast.t 列表做纯判定（不 eval）：外层
    control=[] ∧ attrs=[] 才进入 expr 分类；只放行只读查询构造器，并递归
    核 term / pattern / binder（CNotation、CPatNotation、by-notation、
    CGenarg* 一律拒绝）；set-option 只放行四个已登记的布尔打印选项，并经
    当前 Goptions 表核存在且为布尔类型；PrintUniverses 的文件输出与
    PrintDebugGC 拒绝。
    不承诺的事：不做 OS 沙箱；不解释 notation（devlog 已声明 Notations
    依赖固定 Rocq 纯接口、本批不开放，故含 notation 的项整体保守拒绝）；
    不做 reduction（VernacCheckMayEval 的 Some 分支本批拒绝——设计 §4.3
    的内建 reduction 表留后续批）；匹配不到构造器一律拒绝（兜底 Error），
    升级 Rocq 须重新审表（printable 走全集 match，新构造器会编译告警）。 *)

module V = Vernacexpr
module C = Constrexpr
module G = Goptions

let ( let* ) x f = match x with Error e -> Error e | Ok () -> f ()

let sequence checks =
  List.fold_left (fun acc check -> let* () = acc in check) (Ok ()) checks

(* 本 switch 的 Stdlib.Option 无 to_list。 *)
let opt_list = function Some x -> [ x ] | None -> []

let reject what = Error ("pet_query_check: rejected " ^ what)

(* 本批四项临时打印选项（设计 §4.3 exact-set）。 *)
let option_keys =
  [ [ "Printing"; "All" ]; [ "Printing"; "Universes" ];
    [ "Printing"; "Implicit" ]; [ "Printing"; "Coercions" ] ]

let check_option key setting =
  let known = List.mem key option_keys in
  let setting_ok = match setting with V.OptionSetTrue | V.OptionUnset -> true | _ -> false in
  if not (known && setting_ok) then reject "set-option"
  else
    (* 经当前 Goptions 表核存在且为布尔类型（设计 §4.3）。 *)
    match G.get_option_value key with
    | None -> reject "set-option (undeclared key)"
    | Some read ->
        (match read () with
         | G.BoolValue _ -> Ok ()
         | _ -> reject "set-option (not a boolean option)")

(* qualid-or-by-notation 只收显式 qualid（by-notation 本批拒绝）。 *)
let plain_qualid (q : Libnames.qualid C.or_by_notation) =
  match q.CAst.v with
  | C.AN _ -> Ok ()
  | C.ByNotation _ -> reject "reference by notation"

let check_class = function
  | V.FunClass | V.SortClass -> Ok ()
  | V.RefClass q -> plain_qualid q

let rec check_pattern (p : C.cases_pattern_expr) =
  match p.CAst.v with
  | C.CPatAlias (p, _) -> check_pattern p
  | C.CPatCstr (_, args1, args2) ->
      sequence
        (List.map check_pattern (Stdlib.Option.value args1 ~default:[])
        @ List.map check_pattern args2)
  | C.CPatAtom _ -> Ok ()
  | C.CPatOr ps -> sequence (List.map check_pattern ps)
  | C.CPatNotation _ -> reject "pattern notation"
  | C.CPatPrim _ -> Ok ()
  | C.CPatRecord fields -> sequence (List.map (fun (_, p) -> check_pattern p) fields)
  | C.CPatDelimiters (_, _, p) -> check_pattern p
  | C.CPatCast (p, t) ->
      let* () = check_pattern p in
      check_term t

and check_binder (b : C.local_binder_expr) =
  match b with
  | C.CLocalAssum (_, _, _, t) -> check_term t
  | C.CLocalDef (_, _, t, ty) ->
      let* () = check_term t in
      sequence (List.map check_term (opt_list ty))
  | C.CLocalPattern p -> check_pattern p

and check_case ((c, _, p) : C.case_expr) =
  let* () = check_term c in
  sequence (List.map check_pattern (opt_list p))

and check_branch (br : C.branch_expr) =
  let pss, body = br.CAst.v in
  let* () = sequence (List.map check_pattern (List.concat pss)) in
  check_term body

and check_order (o : C.fixpoint_order_expr) =
  match o.CAst.v with
  | C.CStructRec _ -> Ok ()
  | C.CWfRec (_, t) -> check_term t
  | C.CMeasureRec (_, t, rel) ->
      let* () = check_term t in
      sequence (List.map check_term (opt_list rel))

and check_term (c : C.constr_expr) =
  match c.CAst.v with
  | C.CRef (_, instance) ->
      (* Rocq 9.0 的 constr_expr 里 CRef 只带已解析的 qualid 与 universe 实例
         （quality_expr/univ_level_expr 列表，无引用）：by-notation 引用只出现在
         vernac 层的 qualid-or-by-notation（PrintName / PrintAssumptions / PrintAbout /
         PrintInstances / PrintHint / PrintImplicit / PrintStrategy / LocateAny /
         LocateTerm / RefClass），全部经 plain_qualid 拒绝 ByNotation。term 位置的
         `"+"%nat` 解析为 CDelim(nat, CPrim(String))——字符串字面量而非 notation
         引用（实测 classify 放行、执行报 Coq 用户错误）。 *)
      ignore instance;
      Ok ()
  | C.CFix (_, rows) ->
      sequence
        (List.map
           (fun (_, _, order, binders, ty, body) ->
             let* () = sequence (List.map check_order (opt_list order)) in
             let* () = sequence (List.map check_binder binders) in
             let* () = check_term ty in
             check_term body)
           rows)
  | C.CCoFix (_, rows) ->
      sequence
        (List.map
           (fun (_, _, binders, ty, body) ->
             let* () = sequence (List.map check_binder binders) in
             let* () = check_term ty in
             check_term body)
           rows)
  | C.CProdN (binders, body) | C.CLambdaN (binders, body) ->
      let* () = sequence (List.map check_binder binders) in
      check_term body
  | C.CLetIn (_, a, b, body) ->
      let* () = check_term a in
      let* () = sequence (List.map check_term (opt_list b)) in
      check_term body
  | C.CAppExpl (_, args) -> sequence (List.map check_term args)
  | C.CApp (f, args) ->
      let* () = check_term f in
      sequence (List.map (fun (a, _) -> check_term a) args)
  | C.CProj (_, _, args, c) ->
      let* () = sequence (List.map (fun (a, _) -> check_term a) args) in
      check_term c
  | C.CRecord fields -> sequence (List.map (fun (_, t) -> check_term t) fields)
  | C.CCases (_, ret, cases, branches) ->
      let* () = sequence (List.map check_term (opt_list ret)) in
      let* () = sequence (List.map check_case cases) in
      sequence (List.map check_branch branches)
  | C.CLetTuple (_, init, a, body) ->
      let* () = check_term a in
      let* () = sequence (List.map check_term (opt_list (snd init))) in
      check_term body
  | C.CIf (c, ret, a, b) ->
      let* () = check_term c in
      let* () = sequence (List.map check_term (opt_list (snd ret))) in
      let* () = check_term a in
      check_term b
  | C.CHole _ -> Ok ()
  | C.CGenarg _ | C.CGenargGlob _ -> reject "generic argument"
  | C.CPatVar _ -> Ok ()
  | C.CEvar (_, args) -> sequence (List.map (fun (_, t) -> check_term t) args)
  | C.CSort _ -> Ok ()
  | C.CCast (a, _, b) ->
      let* () = check_term a in
      check_term b
  | C.CNotation _ -> reject "term notation"
  | C.CGeneralization (_, t) -> check_term t
  | C.CPrim _ -> Ok ()
  | C.CDelimiters (_, _, t) -> check_term t
  | C.CArray (_, items, default, ty) ->
      let* () = sequence (List.map check_term (Array.to_list items)) in
      let* () = check_term default in
      check_term ty

let rec check_search (requests : (bool * V.search_request) list) =
  sequence
    (List.map
       (fun (_, request) ->
         match request with
         | V.SearchLiteral item ->
             (match item with
              | V.SearchSubPattern (_, p) -> check_term p
              | V.SearchString _ | V.SearchKind _ -> Ok ())
         | V.SearchDisjConj groups ->
             sequence (List.map check_search groups))
       requests)

let check_printable (p : V.printable) =
  match p with
  | V.PrintTypingFlags | V.PrintTables | V.PrintFullContext | V.PrintInspect _
  | V.PrintGrammar _ | V.PrintCustomGrammar _ | V.PrintKeywords | V.PrintLoadPath _
  | V.PrintLibraries | V.PrintModule _ | V.PrintModuleType _ | V.PrintNamespace _
  | V.PrintMLLoadPath | V.PrintMLModules | V.PrintGraph | V.PrintClasses
  | V.PrintTypeclasses | V.PrintCoercions | V.PrintHintGoal | V.PrintHintDbName _
  | V.PrintHintDb | V.PrintScopes | V.PrintScope _ | V.PrintVisibility _
  | V.PrintRegistered | V.PrintRegisteredSchemes | V.PrintNotation _ ->
      Ok ()
  | V.PrintSectionContext _ -> Ok ()
  | V.PrintName (q, _) | V.PrintInstances q | V.PrintHint q | V.PrintImplicit q
  | V.PrintAssumptions (_, _, q) | V.PrintStrategy (Some q) ->
      plain_qualid q
  | V.PrintStrategy None -> Ok ()
  | V.PrintAbout (q, _, _) -> plain_qualid q
  | V.PrintCanonicalConversions qs -> sequence (List.map plain_qualid qs)
  | V.PrintCoercionPaths (a, b) ->
      let* () = check_class a in
      check_class b
  | V.PrintUniverses { V.file = None; _ } -> Ok ()
  | V.PrintUniverses _ -> reject "PrintUniverses with file output"
  | V.PrintDebugGC -> reject "PrintDebugGC"

let check_locate (l : V.locatable) =
  match l with
  | V.LocateAny q | V.LocateTerm q -> plain_qualid q
  | V.LocateLibrary _ | V.LocateModule _ -> Ok ()
  | V.LocateOther _ | V.LocateFile _ -> reject "locate extension"

let check_one (ast : Coq.Ast.t) =
  let vernac : V.vernac_control = Coq.Ast.to_coq ast in
  let { V.control; attrs; expr; _ } = vernac.CAst.v in
  if control <> [] then reject "control flags"
  else if attrs <> [] then reject "attributes"
  else
    match expr with
    | V.VernacSynPure (V.VernacCheckMayEval (None, _, c)) -> check_term c
    | V.VernacSynPure (V.VernacCheckMayEval (Some _, _, _)) -> reject "reduction"
    | V.VernacSynPure (V.VernacGlobalCheck c) -> check_term c
    | V.VernacSynPure (V.VernacPrint p) -> check_printable p
    | V.VernacSynPure (V.VernacLocate l) -> check_locate l
    | V.VernacSynPure (V.VernacSearch (q, _, _)) ->
        (match q with
         | V.SearchPattern p | V.SearchRewrite p -> check_term p
         | V.Search requests -> check_search requests)
    | V.VernacSynterp (V.VernacSetOption (false, key, setting)) -> check_option key setting
    | V.VernacSynterp (V.VernacSetOption _) -> reject "set-option (export modifier)"
    | _ -> reject "vernac constructor"

(* 空表 ⇒ 空计划（Ok ()）；任一拒绝 ⇒ Error 原因。 *)
let classify (asts : Coq.Ast.t list) = sequence (List.map check_one asts)
