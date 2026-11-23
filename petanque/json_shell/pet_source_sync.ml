(* 源码同步(spec §2 / NN03, devlog 六项 #2)。
   职责：SyncSource 的 prepare 六步(核验/幂等/拒绝与未知区分/同内容 no-op 完整
   线表/变化 retain+逐线回收/context revision+1/line_updates 封存与原子映射发布)、
   RETIRING 未决语义(context 有 pending 步 ⇒ 不发终态, 同 binding 续调)、以及
   view 通道的 line_updates spool 服务(pull/ack/release)。
   不承诺的事：本批单 context 近似——context 载体取第一条 Mainline 线及其
   BeginLine 操作(与 pet_native.locate_context_line 同款查找), 多 context 挂钩
   留待后续 item；不伪造保留前缀(句界由 Fleche 官方 check 的真实节点决定)；
   spool 是 $TMPDIR 下本进程私有易失材料, 真实清理(unlink)后才报 Released。
   锁序约定：本模块锁 → Registry 锁, 禁止反序(pet_native 路由不持 Registry 锁
   调用本模块)。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json
module Registry = Pet_registry
module Shell = Petanque_shell.Shell
module Prefix = Pet_source_prefix

let get = function Ok value -> value | Error _ -> invalid_arg "pet_source_sync"
let uint value = get (T.U.make value)
let id_value value = get (T.Id.make value)

(* —— 状态(全部在模块锁内访问)—— *)

type context_state = {
  mutable revision : int64;                       (* context 版本；变更 +1 *)
  mutable sync_in_progress : T.op_binding option; (* 在途同步(Retiring 续调期间保留) *)
}

type spool = {
  view : T.Id.t;
  operation : T.Id.t;                      (* 属主操作 id(binding.operation_id) *)
  digest_hex : string;                     (* 全文 SHA-256(64 小写 hex) *)
  bytes : int;                             (* 全文字节数 *)
  path : string;                           (* temp 文件路径；release 后已 unlink *)
  mutable offset : int64;                  (* 已确认偏移 *)
  mutable seq : int64;                     (* 最后确认块 seq；0 = 从未确认 *)
  mutable pending : (int64 * int64 * string) option; (* (seq, end_offset, text) *)
  mutable released : bool;
}

let lock = Mutex.create ()

(* boot 绑定(make_native_line_update_document / 视图配额用), serve() 时注入。 *)
let boot_ref : T.native_boot_binding option ref = ref None

let contexts : (string, context_state) Hashtbl.t = Hashtbl.create 7
let spools : (string, spool) Hashtbl.t = Hashtbl.create 7

let uri_counter = ref 0

let init ~boot =
  boot_ref := Some boot;
  Hashtbl.reset contexts;
  Hashtbl.reset spools

let fresh_uri () =
  incr uri_counter;
  Lang.LUri.of_string
    (Format.asprintf "file:///tmp/ccv_sync_%d_%d.v" (Unix.getpid ()) !uri_counter)
  |> Lang.LUri.File.of_uri |> get

(* —— Registry 投影辅助(须在 with_tables 内调用)—— *)

(* 单 context 近似：第一条 Mainline 线 + 其上最早登记的操作(= BeginLine 主线
   操作, doc/source 持有者)。迭代顺序为新→旧, 取最后命中即最早登记。 *)
let resolve_context context_id =
  let chosen_line = ref None in
  Registry.iter_lines (fun key state ->
      if !chosen_line = None && state.kind = Registry.Mainline then
        chosen_line := Some key);
  match !chosen_line with
  | None -> None
  | Some line_key ->
      let op_ref = ref None in
      Registry.iter_operations (fun op ->
          if T.Id.get op.line = line_key then op_ref := Some op);
      match !op_ref with
      | None -> None
      | Some context_op ->
          (match T.op_binding_line_owner context_op.binding with
           | ctx, _, _ when T.Id.get ctx = T.Id.get context_id ->
               Some (line_key, context_op)
           | _ -> None)

(* 该 context 是否有未决步(pending receipt 或执行中的操作占 doc)。 *)
let has_unsettled_work context_id =
  let unsettled = ref false in
  Registry.iter_operations (fun op ->
      if not !unsettled then
        let active = op.pending <> None || op.state = Registry.Executing in
        if active then
          match T.op_binding_line_owner op.binding with
          | ctx, _, _ -> if T.Id.get ctx = T.Id.get context_id then unsettled := true);
  !unsettled

(* 该 context 的全部公开线投影(本批单 context 近似：全部已登记线), 
   按 line ID 排序(哈希表键天然去重)。 *)
let public_lines () =
  let rows = ref [] in
  Registry.iter_lines (fun key state ->
      rows := (key, state.revision, state.frontier) :: !rows);
  List.sort (fun (a, _, _) (b, _, _) -> String.compare a b) !rows

let retiring_status header binding stop_requested =
  T.make_retiring_status header binding
    ~highest_seen:(uint !Registry.highest_seen)
    ~retired_through:(uint !Registry.retired_through)
    ~stop_requested

(* —— prepare 材料(模块锁内、Registry 锁外构建；失败即弃, context 不动)—— *)

type snapshot = {
  context : T.Id.t;
  ctx_key : string;
  ctx_rev : int64;                         (* 快照时 context 版本 *)
  line_key : string;                       (* 主线线 key(context 载体) *)
  line_rev : int64;
  line_frontier : T.Id.t;
  lines : (string * int64 * T.Id.t) list;  (* 按 line ID 排序的公开线投影 *)
  sync_op : Registry.operation;            (* 本 binding 的 aux 操作 *)
  context_op : Registry.operation;         (* 主线操作(doc 持有者) *)
  old_raw : string;
  new_raw : string;
  budget : T.native_budget;
}

type materials = {
  changed : bool;
  doc : Fleche.Doc.t;
  prefix_end : int;
  kept : int;
  closing : (string * int64) list;         (* 回收线 (key, before_rev), 发布时 +1 *)
  last_command : (int * int) option;       (* 最后保留节点 (start,end) 字节区间 *)
  doc_bytes : string;
  digest_hex : string;
  digest : T.Digest.t;
  path : string;
  view : T.Id.t;
  after_ctx_rev : int64;
  reclaim : T.Id.t;
}

(* 保留前缀内的账本节点 id 集合(与 pet_native 的 node/root id 方案一致)。 *)
let retained_node_ids line_key kept =
  let table = Hashtbl.create 8 in
  for k = 1 to kept do
    Hashtbl.replace table (Format.asprintf "node-%s-%d" line_key k) ()
  done;
  Hashtbl.replace table (Format.asprintf "root-%s" line_key) ();
  table

(* spool 文件写入：写失败返回 None(调用方按拒绝处理, 不留半成品)。 *)
let write_spool_file bytes =
  let path = try Filename.temp_file "ccv_line_updates" "" with _ -> "" in
  if path = "" then None
  else
    let written =
      try
        let oc = open_out_bin path in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
             output_string oc bytes;
             flush oc;
             true)
      with _ -> false
    in
    if written then Some path
    else begin
      (try Unix.unlink path with _ -> ());
      None
    end

let build_materials header binding (snap : snapshot) ~old_source ~new_source =
  match !boot_ref with
  | None ->
      (* init 未注入 boot：无法构造线表文档, 拒绝口径(可重试)。 *)
      `Rejected T.invalid_input
  | Some boot -> (
      (* retain：原子 token(同步不是可取消的执行步)。 *)
      let token = Coq.Limits.create_atomic () in
      let old_doc =
        match snap.context_op.doc with
        | Some doc -> doc
        | None ->
            (* 主线尚未执行过：从旧源建初始 doc(只建不执行, retain 自 bump 起)。 *)
            Shell.make_doc ~token ~uri:(fresh_uri ()) ~raw:snap.old_raw
      in
      let result =
        Prefix.retain ~token ~env:old_doc.Fleche.Doc.env
          ~uri:old_doc.Fleche.Doc.uri ~old_raw:snap.old_raw ~old_doc
          ~new_raw:snap.new_raw
      in
      (* 线表逐线(spec §2 步骤 5)：frontier 在保留前缀内 ⇒ before=after；
         否则该线 closing(Retiring, frontier 保留原值, 版本 +1)。 *)
      let retained = retained_node_ids snap.line_key result.kept in
      let closing = ref [] in
      let changes =
        List.map
          (fun (key, rev, frontier) ->
             let line_id = id_value key in
             let retained_line =
               (not result.changed) || Hashtbl.mem retained (T.Id.get frontier)
             in
             if retained_line then
               get
                 (T.make_native_line_change ~line:line_id
                    ~before_revision:(uint rev) ~after_revision:(uint rev)
                    ~frontier:(T.FKnown frontier) ~state:T.LineOpen)
             else begin
               closing := (key, rev) :: !closing;
               get
                 (T.make_native_line_change ~line:line_id
                    ~before_revision:(uint rev) ~after_revision:(uint (Int64.succ rev))
                    ~frontier:(T.FKnown frontier) ~state:T.LineRetiring)
             end)
          snap.lines
      in
      let after_ctx_rev =
        if result.changed then Int64.succ snap.ctx_rev else snap.ctx_rev
      in
      let document =
        get
          (T.make_native_line_update_document ~boot ~binding ~context:snap.context
             ~old_source ~new_source ~before_context_revision:(uint snap.ctx_rev)
             ~after_context_revision:(uint after_ctx_rev) changes)
      in
      let doc_bytes =
        get (T.encode_native_line_update_document S.message_limits document)
      in
      let total = Int64.of_int (String.length doc_bytes) in
      let output_cap = T.U.get (T.budget_output_bytes snap.budget) in
      let view_cap = T.U.get (T.boot_view_quota boot) in
      if total <= 0L || total > output_cap || total > view_cap then `Rejected T.Capacity
      else
        match write_spool_file doc_bytes with
        | None -> `Rejected T.Capacity
        | Some path ->
            let digest_hex = S.sha256 doc_bytes in
            let view =
              id_value
                (Format.asprintf "view-%s-%Ld"
                   (T.Id.get (T.op_binding_operation binding))
                   (T.U.get (T.op_seq binding)))
            in
            let reclaim =
              id_value
                (Format.asprintf "reclaim-sync-%s"
                   (T.Id.get (T.op_binding_operation binding)))
            in
            let last_command =
              if result.kept = 0 then None
              else
                let rec nth = function
                  | [], _ -> None
                  | node :: _, 0 -> Some node
                  | _ :: rest, n -> nth (rest, n - 1)
                in
                match nth (result.doc.Fleche.Doc.nodes, result.kept - 1) with
                | Some node ->
                    Some
                      ( (node : Fleche.Doc.Node.t).Fleche.Doc.Node.range.start.offset,
                        (node : Fleche.Doc.Node.t).Fleche.Doc.Node.range.end_.offset )
                | None -> None
            in
            `Built
              { changed = result.changed; doc = result.doc;
                prefix_end = result.prefix_end; kept = result.kept;
                closing = !closing; last_command; doc_bytes; digest_hex;
                digest = get (T.Digest.make digest_hex); path; view;
                after_ctx_rev; reclaim })

(* —— prepare 主入口(spec §2 六步；自取模块锁, 锁序 模块锁→Registry 锁)—— *)

let prepare_locked ~header ~binding ~context ~expected_ctx ~expected_rev ~old_source
    ~new_source ~publication:_ =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
       let reject code =
         `Reply (T.make_protocol_error header code T.not_admitted T.fact_unknown)
       in
       (* 步骤 1/2/3：核验、幂等、拒绝与新试区分(Registry 锁内, 只读)。 *)
       let phase_one =
         Registry.with_tables (fun () ->
             match Registry.find_operation binding with
             | Some { aux = Some aux; _ } ->
                 (* 幂等：同 binding 已有 aux ⇒ 原样重放原事实。 *)
                 `Reply (T.locator_reply header aux)
             | Some sync_op -> (
                 match resolve_context context with
                 | None -> reject T.invalid_input
                 | Some (line_key, context_op) -> (
                     let binding_ctx =
                       match T.op_binding_line_owner binding with
                       | ctx, _, _ -> ctx
                     in
                     if T.Id.get binding_ctx <> T.Id.get context then
                       reject T.invalid_input
                     else if T.Id.get expected_ctx <> T.Id.get context then
                       (* Rust 前置同款：expected_context.id == context。 *)
                       reject T.invalid_input
                     else
                       match
                         Registry.source_bytes old_source,
                         Registry.source_bytes new_source
                       with
                       | Some old_raw, Some new_raw -> (
                           match Registry.find_budget (T.op_binding_budget binding) with
                           | None -> reject T.invalid_input
                           | Some budget
                             when T.U.get (T.budget_output_bytes budget) <= 0L ->
                               (* Rust 前置同款：output_bytes>0。entry_uses_budget
                                  已在路由 admit_new 核对。 *)
                               reject T.invalid_input
                           | Some budget -> (
                               let ctx_key = T.Id.get context in
                               let ctx_state =
                                 match Hashtbl.find_opt contexts ctx_key with
                                 | Some state -> state
                                 | None -> (
                                     (* 首次见到该 context：以主线线版本播种记账。 *)
                                     match Registry.find_line (id_value line_key) with
                                     | Some line ->
                                         let state =
                                           { revision = line.revision;
                                             sync_in_progress = None }
                                         in
                                         Hashtbl.add contexts ctx_key state;
                                         state
                                     | None -> assert false)
                               in
                               if ctx_state.revision <> T.U.get expected_rev then
                                 reject T.StaleRevision
                               else if T.Id.get old_source
                                       <> T.Id.get context_op.source then
                                 (* 旧 source 不是登记在案的 context 源。 *)
                                 reject T.invalid_input
                               else
                                 match ctx_state.sync_in_progress with
                                 | Some other
                                   when not (T.op_binding_equal other binding) ->
                                     `Reply
                                       (T.make_protocol_error header T.BindingConflict
                                          T.ExistingOperation T.fact_unknown)
                                 | _ -> (
                                     let lines = public_lines () in
                                     match
                                       List.find_opt
                                         (fun (key, _, _) -> key = line_key)
                                         lines
                                     with
                                     | None -> reject T.invalid_input
                                     | Some (_, line_rev, line_frontier) ->
                                         let snapshot =
                                           { context; ctx_key;
                                             ctx_rev = ctx_state.revision; line_key;
                                             line_rev; line_frontier; lines; sync_op;
                                             context_op; old_raw; new_raw; budget }
                                         in
                                         (* 步骤 7：RETIRING 未决语义——context 有
                                            pending/执行中 ⇒ 不发终态, 同 binding
                                            续调至完成(devlog/Rust 的 Retiring 分支)。 *)
                                         if has_unsettled_work context then begin
                                           ctx_state.sync_in_progress <- Some binding;
                                           sync_op.state <- Registry.Retiring;
                                           `Reply
                                             (retiring_status header binding
                                                sync_op.stop_requested)
                                         end
                                          else `Prepare (snapshot, ctx_state))))
                       | _ ->
                           (* 旧/新源材料缺失(未 sealed)：拒绝口径(可重试)。 *)
                           reject T.invalid_input))
             | None -> reject T.unknown_operation)
       in
       match phase_one with
       | `Reply reply -> reply
       | `Prepare (snap, ctx_state) -> (
           (* 步骤 4/5/6 的材料构建(Registry 锁外)：retain/线表/编码/spool 文件。
              GraphTxn 语义：全部成功才发布；失败即弃(context 不动)。 *)
           match build_materials header binding snap ~old_source ~new_source with
           | `Rejected code ->
               Registry.with_tables (fun () ->
                   ctx_state.sync_in_progress <- None);
               T.make_protocol_error header code T.not_admitted T.fact_unknown
           | `Built mat -> (
               (* 原子发布：图变化(Registry 线表/context 记账/doc 替换)与 spool
                  登记在同一 with_tables 临界区内提交。 *)
               Registry.with_tables (fun () ->
                   let drift () =
                     (* 复验：构建期间主线线状态/未决/终态不得漂移, 否则弃材料。 *)
                     let mainline_ok =
                       match Registry.find_line (id_value snap.line_key) with
                       | Some line ->
                           line.revision = snap.line_rev
                           && T.Id.get line.frontier = T.Id.get snap.line_frontier
                       | None -> false
                     in
                     let ctx_ok =
                       match Hashtbl.find_opt contexts snap.ctx_key with
                       | Some state -> state.revision = snap.ctx_rev
                       | None -> false
                     in
                     (not mainline_ok) || (not ctx_ok)
                     || has_unsettled_work snap.context
                     || snap.sync_op.aux <> None
                   in
                   if drift () then begin
                     (try Unix.unlink mat.path with _ -> ());
                     snap.sync_op.state <- Registry.Retiring;
                     retiring_status header binding snap.sync_op.stop_requested
                   end
                   else begin
                     (* 图变更：回收线版本 +1；doc 替换为 retain 结果；主线前沿
                        失效时把主线操作账本回卷到保留前缀(frontier 原值保留在
                        线表——Retiring 报原前沿的口径)。 *)
                     if mat.changed then begin
                       List.iter
                         (fun (key, _) ->
                            match Registry.find_line (id_value key) with
                            | Some line -> line.revision <- Int64.succ line.revision
                            | None -> ())
                         mat.closing;
                       snap.context_op.doc <- Some mat.doc;
                       let retained = retained_node_ids snap.line_key mat.kept in
                       if not (Hashtbl.mem retained (T.Id.get snap.line_frontier))
                       then begin
                         snap.context_op.cursor <- Int64.of_int mat.prefix_end;
                         snap.context_op.parent <-
                           (if mat.kept = 0 then
                              id_value (Format.asprintf "root-%s" snap.line_key)
                            else
                              id_value
                                (Format.asprintf "node-%s-%d" snap.line_key mat.kept))
                       end
                     end;
                     ctx_state.revision <- mat.after_ctx_rev;
                     ctx_state.sync_in_progress <- None;
                     Hashtbl.replace spools (T.Id.get mat.view)
                       { view = mat.view;
                         operation = T.op_binding_operation binding;
                         digest_hex = mat.digest_hex;
                         bytes = String.length mat.doc_bytes; path = mat.path;
                         offset = 0L; seq = 0L; pending = None; released = false };
                     (* 终态：revision=新 context revision(变化)或原 revision
                        (no-op)；last_valid=主线前沿；boundary：同内容 N/A, 
                        变化且保留前缀非空 ⇒ 最后保留节点, 否则 Unknown；
                        view/digest/bytes 用 spool ref；extent 由构造器内定。 *)
                      let boundary =
                        if not mat.changed then T.FNotApplicable
                        else
                          match mat.last_command with
                          | None -> T.FUnknown
                          | Some (start, end_) ->
                              (* Rust 端核 fact.source==SourceSynced.source(=new_source)，
                                 而 make_entry_boundary 取 binding.source；两者不一致时
                                 只能报 Unknown，不能发布注定对不上的 Known 边界。 *)
                              if T.Id.get (T.op_binding_source binding)
                                 <> T.Id.get new_source then T.FUnknown
                              else
                                T.FKnown
                                  (T.make_entry_boundary header binding
                                     ~target:new_source
                                     ~node:
                                       (id_value
                                          (Format.asprintf "node-%s-%d" snap.line_key
                                             mat.kept))
                                     ~command_start:(uint (Int64.of_int start))
                                     ~command_end:(uint (Int64.of_int end_)))
                      in
                     let aux =
                       T.make_source_synced_terminal binding ~context
                         ~revision:(uint mat.after_ctx_rev) ~source:new_source
                         ~last_valid:(T.FKnown snap.line_frontier)
                         ~reclaim:mat.reclaim ~boundary ~view:mat.view
                         ~digest:mat.digest
                         ~bytes:(uint (Int64.of_int (String.length mat.doc_bytes)))
                     in
                     snap.sync_op.aux <- Some aux;
                     snap.sync_op.state <- Registry.TerminalState;
                     T.locator_reply header aux
                   end))))

(* —— view 通道服务(pet_native 路由先查本模块 spool；None ⇒ 未接管)—— *)

(* [0, len) 内最大完整 UTF-8 前缀的字节长度(不切多字节字符)。 *)
let utf8_prefix_length text len =
  let rec boundary n =
    if n = 0 then 0
    else if (Char.code text.[n - 1] land 0xc0) = 0x80 then boundary (n - 1)
    else n
  in
  boundary len

let read_spool_text (spool : spool) offset len =
  match
    try
      let ic = open_in_bin spool.path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           seek_in ic (Int64.to_int offset);
           really_input_string ic len)
    with _ -> ""
  with
  | text when String.length text = len -> Some text
  | _ -> None

let find_spool view operation =
  match Hashtbl.find_opt spools (T.Id.get view) with
  | None -> `Absent
  | Some spool ->
      if T.Id.get spool.operation <> T.Id.get operation then `Mismatch
      else `Owned spool

let capture_of (spool : spool) =
  get
    (T.make_capture_status ~complete:true
       ~captured_bytes:(uint (Int64.of_int spool.bytes))
       ~total_bytes:(T.FKnown (uint (Int64.of_int spool.bytes)))
       ~digest:(T.FKnown (get (T.Digest.make spool.digest_hex)))
       ~missing_ranges:[]
       ~reason:T.FNotApplicable)

(* 块语义按 spec §2：credit 4..8192、seq=last_ack+1 或重放 pending、
   offset=已确认偏移、eof=到达 bytes；capture 逐项对 Rust
   checked_line_update_pull(complete/总 bytes/Known digest/missing=[]/N/A)。 *)
let serve_view_pull header ~view ~operation ~seq ~offset ~credit =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
       match find_spool view operation with
       | `Absent -> None
       | `Mismatch ->
           Some (T.make_view_pull_error header T.invalid_input T.not_admitted)
       | `Owned spool ->
           let seq = T.U.get seq and offset = T.U.get offset
           and credit = T.U.get credit in
           let retired () =
             Some
               (T.make_view_pull_retired header ~view ~operation
                  ~requested_seq:(uint seq) ~acked_through:(uint spool.seq)
                  ~end_offset:(uint spool.offset))
           in
           let error () =
             Some (T.make_view_pull_error header T.invalid_input T.not_admitted)
           in
           if spool.released then retired ()
           else if credit < 4L || credit > 8192L then error ()
           else if seq <= spool.seq then retired ()
           else if seq <> Int64.succ spool.seq then error ()
           else if offset <> spool.offset then error ()
           else if offset >= Int64.of_int spool.bytes then error ()
           else
             let make_chunk text end_offset =
               let eof = end_offset = Int64.of_int spool.bytes in
               Some
                 (get
                    (T.make_view_chunk header ~view ~operation ~seq:(uint seq)
                       ~offset:(uint offset) ~text ~eof ~capture:(capture_of spool)))
             in
             match spool.pending with
             | Some (pending_seq, pending_end, text) ->
                 if pending_seq = seq then make_chunk text pending_end else error ()
             | None ->
                 let want =
                   Int64.to_int
                     (Int64.sub
                        (min (Int64.add offset credit) (Int64.of_int spool.bytes))
                        offset)
                 in
                 match read_spool_text spool offset want with
                 | None -> error ()
                 | Some text ->
                     let len = utf8_prefix_length text (String.length text) in
                     let text = String.sub text 0 len in
                     let end_offset = Int64.add offset (Int64.of_int len) in
                     spool.pending <- Some (seq, end_offset, text);
                     make_chunk text end_offset)

(* ack：核 seq/end_offset/块 digest(文本 SHA-256)⇒ 推进游标；
   旧 seq ⇒ make_view_ack_retired。 *)
let serve_view_ack header ~view ~operation ~seq ~end_offset ~digest =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
       match find_spool view operation with
       | `Absent -> None
       | `Mismatch ->
           Some (T.make_view_ack_error header T.invalid_input T.not_admitted)
       | `Owned spool ->
           let seq = T.U.get seq in
           let error () =
             Some (T.make_view_ack_error header T.invalid_input T.not_admitted)
           in
           match spool.pending with
           | Some (pending_seq, pending_end, text) when pending_seq = seq ->
               if T.U.get end_offset = pending_end
                  && S.sha256 text = T.Digest.get digest
               then begin
                 spool.pending <- None;
                 spool.offset <- pending_end;
                 spool.seq <- seq;
                 Some
                   (T.make_view_acked header ~view ~operation ~seq:(uint seq)
                      ~end_offset)
               end
               else error ()
           | _ when seq <= spool.seq ->
               Some
                 (T.make_view_ack_retired header ~view ~operation
                    ~requested_seq:(uint seq) ~acked_through:(uint spool.seq)
                    ~end_offset:(uint spool.offset))
           | _ -> error ())

(* release：核 last_acked fact；真实清理(文件无常开句柄, unlink)后才
   Released；有 pending 未清 ⇒ Closing(spool 保留, 可续读原 pull)。 *)
let serve_view_release header ~view ~operation ~last_acked =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
       match find_spool view operation with
       | `Absent -> None
       | `Mismatch ->
           Some (T.make_view_release_error header T.invalid_input T.not_admitted)
       | `Owned spool ->
           let fact_ok =
             match (last_acked : T.U.t T.fact) with
             | T.FKnown seen -> T.U.get seen = spool.seq
             | T.FNotApplicable -> spool.seq = 0L
             | T.FUnknown -> false
           in
           if not fact_ok then
             Some (T.make_view_release_error header T.invalid_input T.not_admitted)
           else if spool.pending <> None then
             Some (T.make_view_released header ~view ~operation ~status:T.ClosingStatus)
           else begin
             (try Unix.unlink spool.path with _ -> ());
             spool.released <- true;
             Some (T.make_view_released header ~view ~operation ~status:T.ReleasedStatus)
           end)
