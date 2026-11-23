(* checkpoint 纯校验内核（spec §3 / item 3 交付 1）。
    职责：对「已解码」的 checkpoint 清单做反序列化后的纯结构检查——
    requirements / coverage manifest 的节点表（cnm 稠密序号、parent 引用
    存在且更早、节点 source 属于授权源集合、字节区间满足
    start<end≤cursor≤read_end、saw_eof 则 end 钉到 read_end）、边界行
    node_index 有界且严格单调；manifest 另核 artifacts bytes 为正且不超过
    调用方传入的上界；import map 核 rows 引用一致（boundary / 新节点唯一、
    lineage 与新线一一对应、同 lineage 同 context）与
    validated_node_count=实际行数。
    不承诺的事：无 IO、无自身状态、不重算 digest、不做预算/配对/路由类
    检查（归 arena/dispatch）；所有函数返回 (unit, string) result，
    不抛异常——调用方按 Error 文本决定拒绝口径或错误终态，本模块不猜。 *)

module T = Ccv_protocol.Types

let ( let* ) = Result.bind

(* —— 节点表检查（requirements / manifest 共用）——
   列表序即稠密序号序：第 i 项的 cnm_index 必须恰为 i（同时钉住唯一性
   与 0 起单调排序）；parent 为 Known 时必须引用更早的存在节点
   （0 ≤ parent < i，稠密序号下存在性由此保证）。 *)
let check_nodes (nodes : T.checkpoint_node_meta list) =
  let rec go index = function
    | [] -> Ok ()
    | (meta : T.checkpoint_node_meta) :: rest ->
        let idx = T.U.get meta.cnm_index in
        if idx <> Int64.of_int index then
          Error (Format.asprintf "nodes.%d index=%Ld 不是稠密序号" index idx)
        else
          match meta.cnm_parent with
          | T.KNotApplicable -> go (index + 1) rest
          | T.KKnown parent ->
              if T.U.get parent < 0L || T.U.get parent >= idx then
                Error
                  (Format.asprintf "nodes.%d parent=%Ld 未引用存在且更早的节点"
                     index (T.U.get parent))
              else go (index + 1) rest
  in
  go 0 nodes

(* —— 节点字节区间：start<end≤cursor≤read_end；saw_eof ⇒ end=read_end。 —— *)
let check_ranges (nodes : T.checkpoint_node_meta list) =
  let rec go index = function
    | [] -> Ok ()
    | (meta : T.checkpoint_node_meta) :: rest ->
        let start = T.U.get meta.cnm_start and end_ = T.U.get meta.cnm_end
        and cursor = T.U.get meta.cnm_cursor and read_end = T.U.get meta.cnm_read_end in
        if not (start < end_ && end_ <= cursor && cursor <= read_end) then
          Error
            (Format.asprintf
               "nodes.%d 字节区间不满足 start<end<=cursor<=read_end (%Ld/%Ld/%Ld/%Ld)"
               index start end_ cursor read_end)
        else if meta.cnm_saw_eof && end_ <> read_end then
          Error
            (Format.asprintf "nodes.%d saw_eof 但 end=%Ld 不等于 read_end=%Ld"
               index end_ read_end)
        else go (index + 1) rest
  in
  go 0 nodes

(* —— 节点 source 归属：必须属于授权源 id 集合（字符串 id 集合比对）。 —— *)
let check_sources (nodes : T.checkpoint_node_meta list) ~(allowed : string list) =
  let table = Hashtbl.create 16 in
  List.iter (fun key -> Hashtbl.replace table key ()) allowed;
  let rec go index = function
    | [] -> Ok ()
    | (meta : T.checkpoint_node_meta) :: rest ->
        if Hashtbl.mem table (T.Id.get meta.cnm_source) then go (index + 1) rest
        else
          Error
            (Format.asprintf "nodes.%d source %s 不在授权源集合内"
               index (T.Id.get meta.cnm_source))
  in
  go 0 nodes

let check_nodes_full ~(nodes : T.checkpoint_node_meta list) ~allowed =
  let* () = check_nodes nodes in
  let* () = check_ranges nodes in
  check_sources nodes ~allowed

(* —— 边界行：node_index 落在节点数界内且严格单调（同一条路径的边界序列
   沿节点前进；重复/回退即结构性损坏）。 —— *)
let check_boundaries (nodes : T.checkpoint_node_meta list)
    (rows : T.checkpoint_boundary_row list) =
  let count = Int64.of_int (List.length nodes) in
  let rec go prev = function
    | [] -> Ok ()
    | (row : T.checkpoint_boundary_row) :: rest ->
        let idx = T.U.get row.cbr_node_index in
        if idx < 0L || idx >= count then
          Error
            (Format.asprintf "边界行 node_index=%Ld 越出节点界 [0,%Ld)" idx count)
        else
          match prev with
          | Some p when idx <= p ->
              Error
                (Format.asprintf "边界行 node_index=%Ld 非严格单调（前值=%Ld）"
                   idx p)
          | _ -> go (Some idx) rest
  in
  go None rows

(* —— requirements：节点表 + 授权源（required_sources）+ 边界行。 —— *)
let validate_requirements (requirements : T.checkpoint_requirements) =
  let allowed =
    List.map (fun (source : T.Id.t) -> T.Id.get source) requirements.cr_required_sources
  in
  let* () = check_nodes_full ~nodes:requirements.cr_nodes ~allowed in
  check_boundaries requirements.cr_nodes requirements.cr_boundaries

(* —— manifest：节点表 + 授权源（source_descriptors 投影）+ 边界行
   + artifacts bytes 为正且不超过调用方上界。 —— *)
let validate_manifest ~(max_bytes : int64) (manifest : T.checkpoint_coverage_manifest) =
  let allowed =
    List.map
      (fun (d : T.checkpoint_source_identity) -> T.Id.get d.csi_source)
      manifest.ccm_source_descriptors
  in
  let check_artifact label (ref : T.artifact_ref) =
    let bytes = T.U.get ref.artifact_bytes in
    if bytes <= 0L then Error (Format.asprintf "%s bytes=%Ld 非正" label bytes)
    else if bytes > max_bytes then
      Error (Format.asprintf "%s bytes=%Ld 超过调用方上界 %Ld" label bytes max_bytes)
    else Ok ()
  in
  let* () = check_nodes_full ~nodes:manifest.ccm_nodes ~allowed in
  let* () = check_boundaries manifest.ccm_nodes manifest.ccm_boundaries in
  let* () = check_artifact "plan" manifest.ccm_plan in
  let* () = check_artifact "compatibility" manifest.ccm_compatibility in
  check_artifact "requirements" manifest.ccm_requirements

(* —— import map：rows 引用一致 + validated_node_count=实际行数。
   一致性口径（纯内部可核部分）：
   - boundary 身份唯一（重复 = 同一边界被映射两次）；
   - 新节点 id 唯一（不同边界不得落同一新节点）；
   - 同一 lineage 的所有行必须映射同一（新线, 新 context），不同 lineage
     不得复用同一新线（旧/新线一一对应；context 允许共享——同组多路径
     可在同一 context）。空表合法（本批导入映射行留空）。 —— *)
let validate_import_map (map : T.checkpoint_import_map) =
  let rows = map.cim_rows in
  let count = Int64.of_int (List.length rows) in
  if T.U.get map.cim_validated_node_count <> count then
    Error
      (Format.asprintf "validated_node_count=%Ld 不等于实际行数 %Ld"
         (T.U.get map.cim_validated_node_count) count)
  else begin
    let boundary_key (b : T.checkpoint_boundary) =
      match b with
      | T.CbEntry lineage -> Format.asprintf "entry:%s" (T.Id.get lineage)
      | T.CbStep (lineage, step) ->
          Format.asprintf "step:%s:%s" (T.Id.get lineage) (T.Id.get step)
    in
    let lineage_of (b : T.checkpoint_boundary) =
      match b with T.CbEntry lineage -> lineage | T.CbStep (lineage, _) -> lineage
    in
    let seen_boundary : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    let seen_node : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    let by_lineage : (string, string * string) Hashtbl.t = Hashtbl.create 16 in
    let by_line : (string, string) Hashtbl.t = Hashtbl.create 16 in
    let rec go index = function
      | [] -> Ok ()
      | (row : T.checkpoint_map_row) :: rest ->
          let bkey = boundary_key row.mr_boundary in
          let nkey = T.Id.get row.mr_new_node in
          let lkey = T.Id.get (lineage_of row.mr_boundary) in
          let newline = T.Id.get row.mr_new_line in
          let newctx = T.Id.get row.mr_new_context in
          if Hashtbl.mem seen_boundary bkey then
            Error (Format.asprintf "rows.%d boundary %s 重复" index bkey)
          else if Hashtbl.mem seen_node nkey then
            Error (Format.asprintf "rows.%d 新节点 %s 重复" index nkey)
          else
            match Hashtbl.find_opt by_lineage lkey with
            | Some (known_line, known_ctx)
              when known_line <> newline || known_ctx <> newctx ->
                Error
                  (Format.asprintf
                     "rows.%d 同一 lineage %s 映射不一致（新线/新 context 漂移）"
                     index lkey)
            | Some _ -> go (index + 1) rest
            | None ->
                (match Hashtbl.find_opt by_line newline with
                 | Some other when other <> lkey ->
                     Error
                       (Format.asprintf
                          "rows.%d 新线 %s 被不同 lineage 复用（%s 与 %s）"
                          index newline other lkey)
                 | _ ->
                     Hashtbl.replace seen_boundary bkey ();
                     Hashtbl.replace seen_node nkey ();
                     Hashtbl.replace by_lineage lkey (newline, newctx);
                     Hashtbl.replace by_line newline lkey;
                     go (index + 1) rest)
    in
    go 0 rows
  end
