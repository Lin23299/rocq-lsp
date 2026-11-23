(* checkpoint 材料与租约状态机（spec §3 / item 3 交付 A）。
    职责：集中保存 checkpoint 二进制材料的三类可变状态——
    - 上传 spool（source 通道）：transfer id（=artifact id）→ {staging bytes；
      next_offset；expected digest/bytes；begin 时的完整 transfer 身份}，
      begin/chunk/finish 的状态迁移在此完成：chunk 按 offset 顺序累加、
      finish 总量 + SHA-256（S.sha256）核对后按 artifact_id 封存进材料表；
    - 下载 spool（view 通道）：transfer id → {sealed bytes；offset/seq 游标；
      pending 块；released}——pull/ack/release 只做簿记迁移，配对矩阵/预算/
      期限/回复口径的判断归 dispatch；
    - import arena：cache id → {材料集 artifact_id→bytes；phase =
      Preparing|Prepared|Activated；group；import_binding}。register_import_material
      收集材料，prepare 做反序列化 + Pet_checkpoint_graph.validate_* 全过 ⇒
      Prepared（并产出本批派生的 import map 与 mapping artifact_ref），
      take_for_activation 供 activate 核对后置 Activated。
    不承诺的事：不解释 wire、不做预算/配对矩阵/期限裁决；不伪造材料——
    digest 不符即弃并释放输入配额；上传材料封存后本批无 release 通道，
    输入配额保持占用（真实材料仍在内存，与 source 封存同口径）；下载材料
    的 release 是真实清理（释放字节、置 released，后续 pull 报 Retired）；
    本批导入映射行留空（真实 map 由后续 owner 输入，见 prepare 注释）。
    锁序约定：本模块锁 → Registry 锁（输入配额记账），禁止反序。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json
module Registry = Pet_registry
module Graph = Pet_checkpoint_graph

let get = function Ok value -> value | Error _ -> invalid_arg "pet_checkpoint_arena"
let uint value = get (T.U.make value)
let id_value value = get (T.Id.make value)

(* —— 上传 spool：transfer id（=artifact id）→ 暂存 —— *)
type upload_state = {
  mutable staging : bytes;
  mutable next_offset : int64;
  expected_digest : string;             (* 64 位小写 hex SHA-256 *)
  expected_bytes : int64;
  transfer : T.checkpoint_transfer;     (* begin 时的完整身份（resume 幂等核对） *)
}

(* —— 下载 spool：transfer id（=artifact id）→ 封存字节 —— *)
type download_state = {
  artifact : T.artifact_ref;
  operation : T.Id.t;                   (* 产出该材料的操作 id（导入终态的 operation） *)
  mutable sealed : string;              (* release 后置空（真实清理） *)
  mutable offset : int64;               (* 已确认偏移 *)
  mutable seq : int64;                  (* 最后确认块 seq；0 = 从未确认 *)
  mutable pending : (int64 * int64 * string) option;  (* (seq, end_offset, 原始块) *)
  mutable released : bool;
}

(* —— import arena —— *)
type import_phase = Preparing | Prepared | Activated

type import_entry = {
  mutable materials : (string, string) Hashtbl.t;  (* cache 的材料集（artifact_id→封存字节） *)
  mutable phase : import_phase;
  mutable group : T.Id.t option;        (* 导入记账组（ci_group），activate 取回 *)
  mutable import_binding : T.op_binding option;   (* 触发 prepare 的导入操作 *)
}

(* 上传封存材料：字节 + 完整 artifact_ref（begin 幂等核对身份用）。 *)
type sealed_material = { bytes : string; artifact : T.artifact_ref }

let lock = Mutex.create ()

let uploads : (string, upload_state) Hashtbl.t = Hashtbl.create 7
let materials : (string, sealed_material) Hashtbl.t = Hashtbl.create 7
let downloads : (string, download_state) Hashtbl.t = Hashtbl.create 7
let imports : (string, import_entry) Hashtbl.t = Hashtbl.create 7

let with_lock f =
  Mutex.lock lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock lock) f

let init () =
  with_lock (fun () ->
      Hashtbl.reset uploads;
      Hashtbl.reset materials;
      Hashtbl.reset downloads;
      Hashtbl.reset imports)

(* 该操作名下未 release 的下载 spool 数（item 5 EndScope 借用枚举用；本模块锁内）。 *)
let unreleased_downloads ~operation =
  let count = ref 0 in
  Hashtbl.iter
    (fun _ (d : download_state) ->
       if not d.released && T.Id.get d.operation = T.Id.get operation then incr count)
    downloads;
  !count

(* artifact 身份比对（kind/digest/bytes；id 由表键钉住，不再比较）。 *)
let artifact_same (a : T.artifact_ref) (b : T.artifact_ref) =
  a.artifact_kind = b.artifact_kind
  && T.Digest.get a.artifact_digest = T.Digest.get b.artifact_digest
  && T.U.get a.artifact_bytes = T.U.get b.artifact_bytes

(* 输入配额记账走 Registry（锁序：本模块锁 → Registry 锁）。 *)
let reserve_input size =
  Registry.with_tables (fun () -> Registry.reserve_input size)

let release_input size =
  Registry.with_tables (fun () -> ignore (Registry.release_input size))

(* —— 上传迁移（判断与回复口径归 dispatch）—— *)

(* begin：已完整同身份封存 ⇒ `Registered（幂等）；同身份在途 ⇒ `Begun 当前
   next_offset（续传）；异身份占用 ⇒ `Rejected；新开须通过 cap 并占输入配额。 *)
let begin_upload (transfer : T.checkpoint_transfer) ~cap :
    [`Begun of int64 | `Registered of T.artifact_ref | `Rejected] =
  with_lock (fun () ->
      let key = T.Id.get transfer.ct_transfer
      and artifact = transfer.ct_artifact in
      let expected_bytes = T.U.get artifact.artifact_bytes in
      match Hashtbl.find_opt materials key with
      | Some sealed when artifact_same artifact sealed.artifact ->
          (* 已完整同身份封存：幂等回 Registered。 *)
          `Registered sealed.artifact
      | Some _ -> `Rejected
      | None -> (
          match Hashtbl.find_opt uploads key with
          | Some up when up.transfer = transfer -> `Begun up.next_offset
          | Some _ -> `Rejected
          | None ->
              if expected_bytes <= 0L
                 || Int64.compare expected_bytes cap > 0
                 || Int64.compare expected_bytes
                      (Int64.of_int Sys.max_string_length) > 0
              then `Rejected
              else if not (reserve_input expected_bytes) then `Rejected
              else begin
                Hashtbl.replace uploads key
                  { staging = Bytes.create (Int64.to_int expected_bytes);
                    next_offset = 0L;
                    expected_digest = T.Digest.get artifact.artifact_digest;
                    expected_bytes; transfer };
                `Begun 0L
              end))

(* chunk：operation 与 begin 一致、offset=next_offset、块 1..8192 且不越界
   ⇒ blit 并推进；返回 (offset, end_offset, 块 SHA-256)。 *)
let chunk_upload transfer_id operation offset chunk :
    [`Acked of int64 * int64 * string | `Rejected] =
  with_lock (fun () ->
      let length = String.length chunk in
      match Hashtbl.find_opt uploads (T.Id.get transfer_id) with
      | None -> `Rejected
      | Some up ->
          if T.Id.get up.transfer.ct_operation <> T.Id.get operation
             || offset <> up.next_offset
             || length < 1 || length > 8192
             || Int64.compare
                  (Int64.add offset (Int64.of_int length))
                  up.expected_bytes > 0
          then `Rejected
          else begin
            Bytes.blit_string chunk 0 up.staging (Int64.to_int offset) length;
            up.next_offset <- Int64.add offset (Int64.of_int length);
            `Acked (offset, up.next_offset, S.sha256 chunk)
          end)

(* finish：总量齐 + 全文 SHA-256 = expected ⇒ 按 artifact_id 封存进材料表；
   digest 不符 ⇒ 弃暂存并释放输入配额（不伪造、可重试）。 *)
let finish_upload transfer_id operation :
    [`Registered of T.artifact_ref | `Rejected] =
  with_lock (fun () ->
      match Hashtbl.find_opt uploads (T.Id.get transfer_id) with
      | None -> `Rejected
      | Some up ->
          if T.Id.get up.transfer.ct_operation <> T.Id.get operation
             || up.next_offset <> up.expected_bytes
          then `Rejected
          else begin
            (* 锁内核对：通过后 staging 不再有到可写缓冲的引用。 *)
            let raw = Bytes.unsafe_to_string up.staging in
            if S.sha256 raw <> up.expected_digest then begin
              Hashtbl.remove uploads (T.Id.get transfer_id);
              release_input up.expected_bytes;
              `Rejected
            end
            else begin
              Hashtbl.replace materials (T.Id.get transfer_id)
                { bytes = raw; artifact = up.transfer.ct_artifact };
              Hashtbl.remove uploads (T.Id.get transfer_id);
              `Registered up.transfer.ct_artifact
            end
          end)

(* —— 下载迁移（pull/ack/release 簿记；配对矩阵/预算归 dispatch）—— *)

(* 产出材料的下载 spool：导入终态发布时由 dispatch 开立。 *)
let open_download (artifact : T.artifact_ref) ~operation bytes =
  with_lock (fun () ->
      Hashtbl.replace downloads (T.Id.get artifact.artifact_id)
        { artifact; operation; sealed = bytes; offset = 0L; seq = 0L;
          pending = None; released = false })

(* pull：credit 1..8192、seq=last_ack+1（或重放 pending）、offset=已确认偏移；
   二进制材料不做 UTF-8 截断；end=到达总量。块 ≤8192。 *)
let pull_download (transfer : T.checkpoint_transfer) ~seq ~offset ~credit :
    [`Chunk of int64 * int64 * string * bool
    | `Retired of int64
    | `Rejected | `Absent] =
  with_lock (fun () ->
      match Hashtbl.find_opt downloads (T.Id.get transfer.ct_transfer) with
      | None -> `Absent
      | Some d ->
          let total = Int64.of_int (String.length d.sealed) in
          if d.released then `Retired d.offset
          else if T.Id.get transfer.ct_operation <> T.Id.get d.operation
                  || not (artifact_same transfer.ct_artifact d.artifact)
          then `Rejected
          else if credit < 1L || credit > 8192L then `Rejected
          else if seq <= d.seq then `Retired d.offset
          else if seq <> Int64.succ d.seq then `Rejected
          else if offset <> d.offset then `Rejected
          else if offset >= total then `Rejected
          else
            match d.pending with
            | Some (pending_seq, pending_end, text) ->
                if pending_seq = seq then
                  `Chunk (offset, pending_end, text, pending_end = total)
                else `Rejected
            | None ->
                let want = Int64.min credit (Int64.sub total offset) in
                let text =
                  String.sub d.sealed (Int64.to_int offset) (Int64.to_int want)
                in
                let end_offset = Int64.add offset want in
                d.pending <- Some (seq, end_offset, text);
                `Chunk (offset, end_offset, text, end_offset = total))

(* ack：核对 pending 块的 seq/end_offset/块 SHA-256 ⇒ 推进游标；旧 seq ⇒ Retired。 *)
let ack_download transfer_id ~operation ~seq ~end_offset ~digest :
    [`Acked of int64 * int64 | `Retired of int64 | `Rejected | `Absent] =
  with_lock (fun () ->
      match Hashtbl.find_opt downloads (T.Id.get transfer_id) with
      | None -> `Absent
      | Some d ->
          if T.Id.get d.operation <> T.Id.get operation then `Rejected
          else
            match d.pending with
            | Some (pending_seq, pending_end, text) when pending_seq = seq ->
                if end_offset = pending_end && S.sha256 text = digest then begin
                  d.pending <- None;
                  d.offset <- pending_end;
                  d.seq <- seq;
                  `Acked (seq, pending_end)
                end
                else `Rejected
            | _ when seq <= d.seq -> `Retired d.offset
            | _ -> `Rejected)

(* release：真实清理（释放封存字节、置 released；表项保留以对后续 pull/ack
   报 Retired）。重复 release 幂等回 `Released。 *)
let release_download transfer_id ~operation :
    [`Released | `Rejected | `Absent] =
  with_lock (fun () ->
      match Hashtbl.find_opt downloads (T.Id.get transfer_id) with
      | None -> `Absent
      | Some d ->
          if T.Id.get d.operation <> T.Id.get operation then `Rejected
          else begin
            d.sealed <- "";
            d.pending <- None;
            d.released <- true;
            `Released
          end)

(* —— import arena —— *)

let import_entry_of cache_key =
  match Hashtbl.find_opt imports cache_key with
  | Some entry -> entry
  | None ->
      let entry =
        { materials = Hashtbl.create 8; phase = Preparing; group = None;
          import_binding = None }
      in
      Hashtbl.add imports cache_key entry;
      entry

(* 材料收集：把上传封存表中的该 artifact 字节登记进 cache 的材料集；
   仅 Preparing 阶段接受（已 Prepared/Activated 的 cache 不再收料）。 *)
let register_import_material ~cache (ref : T.artifact_ref) :
    [`Ok | `Missing | `Conflict] =
  with_lock (fun () ->
      match Hashtbl.find_opt materials (T.Id.get ref.artifact_id) with
      | None -> `Missing
      | Some sealed ->
          let entry = import_entry_of (T.Id.get cache) in
          if entry.phase <> Preparing then `Conflict
          else begin
            Hashtbl.replace entry.materials (T.Id.get ref.artifact_id) sealed.bytes;
            `Ok
          end)

(* prepare 失败形态（`Prepared/`Conflict 见 prepare_import 签名）。 *)
type prepare_failure = [ `Missing of string | `Decode of string | `Validate of string ]

let ( let* ) = Result.bind

(* prepare 内核（须已持模块锁）：manifest/requirements 反序列化 + 三项纯校验
   + 派生本批 import map；不触碰 entry（发布归 prepare_import）。 *)
let prepare_validated ~cache ~binding ~group ~instance ~backend_epoch ~manager_epoch
    ~(manifest : T.artifact_ref) ~manifest_cap manifest_bytes :
    [ `Prepared of string * T.artifact_ref | prepare_failure ] =
  let decode_with decode label bytes =
    match decode S.message_limits bytes with
    | Error _ -> Error (`Decode label)
    | Ok value -> Ok value
  in
  let check_graph result =
    match result with
    | Ok () -> Ok ()
    | Error message -> Error (`Validate message)
  in
  match
    let* ccm =
      decode_with T.decode_checkpoint_coverage_manifest "manifest 反序列化失败"
        manifest_bytes
    in
    let* requirement_bytes =
      match
        Hashtbl.find_opt materials (T.Id.get ccm.ccm_requirements.artifact_id)
      with
      | Some sealed -> Ok sealed.bytes
      | None -> Error (`Missing "requirements 材料未上传")
    in
    let* requirements =
      decode_with T.decode_checkpoint_requirements "requirements 反序列化失败"
        requirement_bytes
    in
    let* () = check_graph (Graph.validate_requirements requirements) in
    let* () = check_graph (Graph.validate_manifest ~max_bytes:manifest_cap ccm) in
    let map : T.checkpoint_import_map =
      {
        cim_cache = cache;
        cim_group = group;
        cim_import_operation = T.op_binding_operation binding;
        cim_instance = instance;
        cim_backend_epoch = backend_epoch;
        cim_manager_epoch = manager_epoch;
        cim_manifest = manifest;
        cim_rows = [];
        cim_validated_node_count = uint 0L;
      }
    in
    let* () = check_graph (Graph.validate_import_map map) in
    match T.encode_checkpoint_import_map S.message_limits map with
    | Error _ -> Error (`Validate "import_map 编码失败")
    | Ok map_bytes ->
        let mapping : T.artifact_ref =
          {
            artifact_id =
              id_value
                (Format.asprintf "map-%s-%s" (T.Id.get cache)
                   (T.Id.get (T.op_binding_operation binding)));
            artifact_digest = manifest.artifact_digest;
            artifact_bytes = manifest.artifact_bytes;
            artifact_kind = T.CkMap;
          }
        in
        Ok (map_bytes, mapping)
  with
  | Ok (map_bytes, mapping) -> `Prepared (map_bytes, mapping)
  | Error failure -> failure

(* prepare：材料齐（plan/manifest/bundle/compatibility 均已入 cache 材料集，
   requirements 由 manifest 引用、从上传封存表解析）⇒ prepare_validated 全过
   ⇒ phase=Prepared、group/import_binding 记账，返回（派生 import map 字节,
   mapping artifact_ref）。
   本批口径：导入映射行留空（validated_node_count=0 合法）；mapping 的
   digest/bytes 取 manifest 同值、id=map-<cache>-<operation>——由 manifest
   派生，真实 map 由后续 owner 输入（devlog「实际 NC01 完整制品事实…」）。 *)
let prepare_import ~cache ~binding ~group ~instance ~backend_epoch ~manager_epoch
    ~plan ~manifest ~bundle ~compatibility ~manifest_cap :
    [ `Prepared of string * T.artifact_ref | `Conflict | prepare_failure ] =
  with_lock (fun () ->
      let cache_key = T.Id.get cache in
      let entry = import_entry_of cache_key in
      if entry.phase <> Preparing then `Conflict
      else
        let bytes_of (ref : T.artifact_ref) =
          Hashtbl.find_opt entry.materials (T.Id.get ref.artifact_id)
        in
        match (bytes_of plan, bytes_of manifest, bytes_of bundle, bytes_of compatibility) with
        | Some _, Some manifest_bytes, Some _, Some _ -> (
            match
              prepare_validated ~cache ~binding ~group ~instance ~backend_epoch
                ~manager_epoch ~manifest ~manifest_cap manifest_bytes
            with
            | `Prepared (map_bytes, mapping) as prepared ->
                entry.phase <- Prepared;
                entry.group <- Some group;
                entry.import_binding <- Some binding;
                prepared
            | failure ->
                (failure
                  :> [ `Prepared of string * T.artifact_ref | `Conflict
                      | prepare_failure ]))
        | _ -> `Missing "材料未齐（plan/manifest/bundle/compatibility）")

(* take_for_activation：仅 Prepared 的 cache 可被激活（核对归 dispatch；
   通过后 dispatch 调 mark_activated 置 Activated）。 *)
let take_for_activation cache : import_entry option =
  with_lock (fun () ->
      match Hashtbl.find_opt imports (T.Id.get cache) with
      | Some ({ phase = Prepared; _ } as entry) -> Some entry
      | _ -> None)

let mark_activated cache =
  with_lock (fun () ->
      match Hashtbl.find_opt imports (T.Id.get cache) with
      | Some entry -> entry.phase <- Activated
      | None -> ())
