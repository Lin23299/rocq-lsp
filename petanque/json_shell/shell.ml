module SM = Lang.Compat.String.Map

let init_coq ~debug ~record_comments =
  let load_module = Dynlink.loadfile in
  let load_plugin = Coq.Loader.plugin_handler None in
  let vm, warnings = (true, None) in
  Coq.Init.(
    coq_init { debug; record_comments; load_module; load_plugin; vm; warnings })

let cmdline : Coq.Workspace.CmdLine.t =
  { coqlib = Coq.Args.coqlib_dyn
  ; findlib_config = None
  ; ocamlpath = []
  ; vo_load_path = []
  ; args = []
  ; require_libraries = []
  }

let setup_workspace ~token ~init ~debug ~root =
  let dir = Lang.LUri.File.to_string_file root in
  (let open Coq.Compat.Result.O in
   let+ workspace = Coq.Workspace.guess ~token ~debug ~cmdline ~dir () in
   let files = Coq.Files.make () in
   Fleche.Doc.Env.make ~init ~workspace ~files)
  |> Result.map_error (fun msg -> Petanque.Agent.Error.(make_request (coq msg)))

let trace_stderr hdr ?verbose:_ msg =
  Format.eprintf "@[[trace] %s | %s @]@\n%!" hdr msg

let trace_ref = ref trace_stderr

let message_stderr ~lvl:_ ~message =
  Format.eprintf "@[[message] %s @]@\n%!" message

let message_ref = ref message_stderr

let io =
  let trace hdr ?verbose msg = !trace_ref hdr ?verbose msg in
  let message ~lvl ~message = !message_ref ~lvl ~message in
  let diagnostics ~uri:_ ~version:_ _diags = () in
  let fileProgress ~uri:_ ~version:_ _pinfo = () in
  let perfData ~uri:_ ~version:_ _perf = () in
  let serverVersion _ = () in
  let serverStatus _ = () in
  let execInfo ~uri:_ ~version:_ ~range:_ = () in
  { Fleche.Io.CallBack.trace
  ; message
  ; diagnostics
  ; fileProgress
  ; perfData
  ; serverVersion
  ; serverStatus
  ; execInfo
  }

let init_st = ref None
let env = ref None

(* CCV：缓存由 Flèche 自身负责版本失效，绝不按文本猜 Coq 语句边界。 *)
module Target = struct
  type t = End | Root | Position of int * int | Theorem of string
end

let documents : (string, Fleche.Doc.t) Hashtbl.t = Hashtbl.create 17

let set_workspace ~token ~debug ~root =
  let init = Option.get !init_st in
  let open Coq.Compat.Result.O in
  let+ env_ = setup_workspace ~token ~init ~debug ~root in
  Hashtbl.clear documents;
  env := Some env_

(* likely duplicated somewhere else *)
let pp_diag fmt { Lang.Diagnostic.message; _ } =
  Format.fprintf fmt "%a" Pp.pp_with message

let print_diags (doc : Fleche.Doc.t) =
  let d = Fleche.Doc.diags doc in
  Format.(eprintf "@[<v>%a@]" (pp_print_list pp_diag) d)

let read_raw ~uri =
  let file = Lang.LUri.File.to_string_file uri in
  try Ok Coq.Compat.Ocaml_414.In_channel.(with_open_text file input_all)
  with Sys_error err -> Error Petanque.Agent.Error.(make_request (system err))

let languageId = "rocq"

let setup_doc ~token env uri =
  match read_raw ~uri with
  | Ok raw ->
    let doc = Fleche.Doc.create ~token ~env ~uri ~languageId ~version:0 ~raw in
    print_diags doc;
    let target = Fleche.Doc.Target.End in
    Ok (Fleche.Doc.check ~io ~token ~target ~doc ())
  | Error err -> Error err

let last_point (doc : Fleche.Doc.t) =
  match doc.completed with
  | Yes r | Stopped r | Failed r | WorkspaceUpdated r -> r.end_

let prefix_error ?through (doc : Fleche.Doc.t) =
  (* 只按执行顺序扫描到目标 node（含）；诊断可以回指前文，不能当句界。 *)
  let rec scan last = function
    | [] -> None
    | (n : Fleche.Doc.Node.t) :: rest ->
      match List.find_opt Lang.Diagnostic.is_error n.diags with
      | Some d -> Some (n, d, last)
      | None ->
        if (match through with Some stop -> n == stop | None -> false) then None
        else
          let last =
            match Option.bind n.ast (fun ast -> Coq.Ast.loc ast.v) with
            | None -> last
            | Some loc ->
              let r = Coq.Utils.to_range ~lines:doc.contents.lines loc in
              (* 官方 AST 起点在 [start,end) 内；无需猜句界或减 byte。 *)
              if r.start.offset < r.end_.offset then Some r.start else last
          in
          scan last rest
  in
  scan None doc.nodes

let checked_prefix ?through doc =
  match prefix_error ?through doc with
  | None -> Ok doc
  | Some (node, d, last) ->
    let recovery =
      match node.anomaly, last with
      | true, _ -> "Backend anomaly; repair or restart the backend before retrying."
      | false, None -> "No valid predecessor statement; repair the prefix before retrying."
      | false, Some p ->
        Format.asprintf
          "Recovery position inside the last valid statement before the first error (0-based UTF-16): retry start with file=%S, line=%d, character=%d, theorem=''."
          (Lang.LUri.File.to_string_file doc.uri) p.line p.character
    in
    let r = d.range in
    let message =
      Format.asprintf
        "prefix check failed: %s\nDiagnostic range (0-based UTF-16): line=%d, character=%d to line=%d, character=%d\n%a\n%s"
        (Lang.LUri.File.to_string_uri doc.uri)
        r.start.line r.start.character r.end_.line r.end_.character
        Pp.pp_with d.message recovery
    in
    let error = if node.anomaly then Petanque.Agent.Error.Anomaly message
      else Petanque.Agent.Error.coq message in
    Error (Petanque.Agent.Error.make_request error)

let build_doc ~target ~token ~uri =
  let open Coq.Compat.Result.O in
  let* raw = read_raw ~uri in
  let key = Lang.LUri.File.to_string_file uri in
  let doc =
    match Hashtbl.find_opt documents key with
    | Some doc when String.equal raw doc.contents.raw -> doc
    | Some doc -> Fleche.Doc.bump_version ~token ~version:(doc.version + 1) ~raw doc
    | None ->
      Fleche.Doc.create ~token ~env:(Option.get !env) ~uri ~languageId ~version:0 ~raw
  in
  let remember doc = Hashtbl.replace documents key doc; doc in
  let check ?stop_before target doc = Fleche.Doc.check ?stop_before ~io ~token ~target ~doc () |> remember in
  let rec until_theorem thm doc =
    match SM.find_opt thm doc.Fleche.Doc.toc with
    | Some node -> checked_prefix ~through:node doc
    | None ->
      let p = last_point doc in
      let* doc = checked_prefix doc in
      match doc.completed with
      | Stopped _ ->
        (* 只跨过当前已执行句子的末端一个 UTF-16 位置，让官方 parser 执行下一句。 *)
        let next = check (Position (p.line, p.character + 1)) doc in
        if (last_point next).offset <= p.offset && not (Fleche.Doc.Completion.is_completed next.completed) then
          Error Petanque.Agent.Error.(make_request (system "document made no progress"))
        else until_theorem thm next
      | _ ->
        Error Petanque.Agent.Error.(make_request (Theorem_not_found thm))
  in
  let doc = remember doc in
  match target with
  | Target.End -> Ok (check End doc)
  | Root ->
    (* root 只检查初始化；已缓存的任何源码后缀错误都不属于 root。 *)
    checked_prefix (Fleche.Doc.create ~token ~env:(Option.get !env) ~uri
                      ~languageId ~version:doc.version ~raw)
  | Theorem thm -> until_theorem thm doc
  | Position (line, character) ->
    if line < 0 || character < 0 || line >= Array.length doc.contents.lines
       || character > Lang.Utf.length_utf16 doc.contents.lines.(line) then
      Error Petanque.Agent.Error.(make_request (system "invalid document position"))
    else
      let stop_before ast =
        match Coq.Ast.loc ast with
        | None -> false
        | Some loc ->
          let r = Coq.Utils.to_range ~lines:doc.contents.lines loc in
          r.start.line > line || (r.start.line = line && r.start.character > character)
      in
      let doc = check ~stop_before (Position (line, character)) doc in
      (* 已缓存的后缀错误不影响更早位置；刚执行的目标句错误仍需拒绝。 *)
      let node = Fleche.Info.(LC.node ~doc ~point:(line, character) PrevIfEmpty) in
      match node with Some n -> checked_prefix ~through:n doc | None -> Ok doc

(* Flèche LSP backend handles the conversion at the protocol level *)
let to_uri uri : _ Request.R.t =
  Lang.LUri.of_string uri |> Lang.LUri.File.of_uri
  |> Result.map_error (fun msg ->
         Petanque.Agent.Error.(make_request (system msg)))

let uri_of_path path = Format.asprintf "file:///%s" path |> to_uri

let set_roots ~token ~debug ~roots =
  let root =
    match roots with
    | [] -> Sys.getcwd ()
    | root :: _ -> root
  in
  let open Coq.Compat.Result.O in
  let* root = uri_of_path root in
  set_workspace ~token ~debug ~root

let init_agent ~token ~debug ~record_comments ~roots =
  init_st := Some (init_coq ~debug ~record_comments);
  Fleche.Io.CallBack.set io;
  set_roots ~token ~debug ~roots

let toc_to_info (name, node) =
  let open Coq.Compat.Option.O in
  let+ ast = Fleche.Doc.Node.ast node in
  (name, ast.Fleche.Doc.Node.Ast.ast_info)

let get_toc ~token:_ ~(doc : Fleche.Doc.t) :
    (string * Lang.Ast.Info.t list option) list Petanque.Agent.R.t =
  let { Fleche.Doc.toc; _ } = doc in
  let toc = SM.bindings toc |> List.filter_map toc_to_info in
  Ok toc
