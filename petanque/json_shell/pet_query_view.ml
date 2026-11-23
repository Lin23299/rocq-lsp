(* 有限 view spool（spec §4）：query 文本 / inspect facts 文档 / roster 子部件 /
    assumptions 子流共用的内存 spool 与 view 通道服务。
    职责：create/register（内存 spool：全文 bytes、SHA-256、构造期 capture——
    complete 或截断 BudgetExhausted）、serve_pull/serve_ack/serve_release
    （credit 4..8192、最大完整 UTF-8 前缀、块 SHA-256 ACK、每个 spool 独立游标
    = 父子各自独立 ACK/release、真实释放后才 Released）、output_budget_check
    （父子共享同一 budget.output_bytes 与 boot.view_quota 的总账）、以及 item 5
    要的借用枚举 / 真实丢弃入口。
    不承诺的事：不写文件（量小，内存即材料；与 Pet_source_sync 的 $TMPDIR 文件
    spool 的差异仅此）；spool 不跨进程、不持久；不裁决协议语义之外的事。
    锁序：本模块锁 → Registry 锁（发布时）；view 通道线程只取本模块锁。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json

let get = function
  | Ok value -> value
  | Error _ -> invalid_arg "pet_query_view"

let uint value = get (T.U.make value)
let id_value value = get (T.Id.make value)

type spool = {
  view : T.Id.t;
  operation : T.Id.t;                      (* 属主操作 id（= binding.operation_id） *)
  mutable text : string;                   (* release 后清空（真实清理） *)
  digest_hex : string;                     (* 全文 SHA-256（64 小写 hex） *)
  bytes : int;                             (* 全文字节数（release 后保留供 retired 回报） *)
  capture : T.capture_status;              (* 构造期给定：complete 或截断 *)
  mutable offset : int64;                  (* 已确认偏移 *)
  mutable seq : int64;                     (* 最后确认块 seq；0 = 从未确认 *)
  mutable pending : (int64 * int64 * string) option; (* (seq, end_offset, text) *)
  mutable released : bool;
}

let lock = Mutex.create ()

(* boot 绑定（view 配额），serve() 时注入。 *)
let boot_ref : T.native_boot_binding option ref = ref None
let spools : (string, spool) Hashtbl.t = Hashtbl.create 17

let init ~boot =
  boot_ref := Some boot;
  Hashtbl.reset spools

let with_lock f =
  Mutex.lock lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock lock) f

(* —— capture 与配额 —— *)

(* 完整捕获：complete、captured=total=Known(bytes)、digest=Known(sha256)、
   missing=[]、reason=N/A（Rust valid_capture / matches_capture(Parent) 逐项对账）。 *)
let complete_capture text =
  let n = uint (Int64.of_int (String.length text)) in
  get
    (T.make_capture_status ~complete:true ~captured_bytes:n
       ~total_bytes:(T.FKnown n)
       ~digest:(T.FKnown (get (T.Digest.make (S.sha256 text))))
       ~missing_ranges:[] ~reason:T.FNotApplicable)

(* 截断捕获：complete=false、captured=保留前缀 bytes、total 未知、digest 对已
   捕获前缀可核、reason=Known BudgetExhausted。 *)
let truncated_capture text =
  let n = uint (Int64.of_int (String.length text)) in
  get
    (T.make_capture_status ~complete:false ~captured_bytes:n
       ~total_bytes:T.FUnknown
       ~digest:(T.FKnown (get (T.Digest.make (S.sha256 text))))
       ~missing_ranges:[] ~reason:(T.FKnown T.BudgetExhausted))

(* 父子共享配额 = min(budget.output_bytes, boot.view_quota)；boot 未注入 ⇒ 0
   （fail closed，任何产出都放不下）。 *)
let quota (budget : T.native_budget) =
  match !boot_ref with
  | None -> 0L
  | Some boot ->
      min (T.U.get (T.budget_output_bytes budget)) (T.U.get (T.boot_view_quota boot))

(* 父子共享总账：used_so_far + new_bytes ≤ quota（减法比较，避免溢出）。 *)
let output_budget_check ~(budget : T.native_budget) ~used_so_far ~new_bytes =
  let cap = quota budget in
  used_so_far >= 0L && new_bytes >= 0L && used_so_far <= cap
  && new_bytes <= Int64.sub cap used_so_far

(* —— spool 构造与登记（须持本模块锁）—— *)

let create ~view ~operation ~text ~capture =
  { view; operation; text; digest_hex = S.sha256 text;
    bytes = String.length text; capture; offset = 0L; seq = 0L;
    pending = None; released = false }

(* 批量原子登记：任一视图 id 已存在（或批内重复）⇒ `Conflict 且一个都不登记
   （绝不覆盖已发布视图、不留半套父子流）；成功 `Ok。 *)
let register (batch : spool list) =
  let seen = Hashtbl.create (List.length batch) in
  let conflict =
    List.exists
      (fun (s : spool) ->
         Hashtbl.mem spools (T.Id.get s.view) || Hashtbl.mem seen (T.Id.get s.view)
         || (Hashtbl.replace seen (T.Id.get s.view) (); false))
      batch
  in
  if conflict then `Conflict
  else begin
    List.iter (fun (s : spool) -> Hashtbl.replace spools (T.Id.get s.view) s) batch;
    `Ok
  end

(* —— 借用枚举 / 真实丢弃（item 5 用；须持本模块锁）—— *)

(* 该操作名下未 release 的 spool 数（未清借用）。 *)
let unreleased_count ~operation =
  let count = ref 0 in
  Hashtbl.iter
    (fun _ (s : spool) ->
       if not s.released && T.Id.get s.operation = T.Id.get operation then incr count)
    spools;
  !count

(* 真实丢弃该操作名下全部 spool（含已 release 的空壳记录），返回丢弃的
   未 release 数；已 release 的只删记录。 *)
let discard_operation ~operation =
  let dropped = ref 0 in
  let keys =
    Hashtbl.fold
      (fun key (s : spool) acc ->
         if T.Id.get s.operation = T.Id.get operation then key :: acc else acc)
      spools []
  in
  List.iter
    (fun key ->
       match Hashtbl.find_opt spools key with
       | None -> ()
       | Some s ->
           if not s.released then incr dropped;
           s.text <- "";
           s.released <- true;
           Hashtbl.remove spools key)
    keys;
  !dropped

(* —— view 通道服务（pet_native 路由在 Sync 之后查本模块；None ⇒ 未接管）—— *)

(* [0, len) 内最大完整 UTF-8 前缀的字节长度（不切多字节字符）。 *)
let utf8_prefix_length text len =
  let rec boundary n =
    if n = 0 then 0
    else if (Char.code text.[n - 1] land 0xc0) = 0x80 then boundary (n - 1)
    else n
  in
  boundary len

let find_spool view operation =
  match Hashtbl.find_opt spools (T.Id.get view) with
  | None -> `Absent
  | Some spool ->
      if T.Id.get spool.operation <> T.Id.get operation then `Mismatch
      else `Owned spool

(* 块语义（spec §4 与 §2 同款）：credit 4..8192、seq=last_ack+1 或重放 pending、
   offset=已确认偏移、eof=到达 bytes；capture 回 spool 构造期 capture（Rust
   matches_capture(Parent) 要求逐字段等于 descriptor.capture）。 *)
let serve_pull header ~view ~operation ~seq ~offset ~credit =
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
           else if offset >= Int64.of_int spool.bytes && spool.bytes > 0 then error ()
           else
             (* 空视图（bytes=0、offset=0）唯一一次拉取出空块且 eof=true——
                Rust checked_inspection_pull 允许 eof 空块、拒绝非 eof 空块。 *)
             let make_chunk text end_offset =
               let eof = end_offset = Int64.of_int spool.bytes in
               Some
                 (get
                    (T.make_view_chunk header ~view ~operation ~seq:(uint seq)
                       ~offset:(uint offset) ~text ~eof ~capture:spool.capture))
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
                 let raw = String.sub spool.text (Int64.to_int offset) want in
                 let len = utf8_prefix_length raw (String.length raw) in
                 let text = String.sub raw 0 len in
                 let end_offset = Int64.add offset (Int64.of_int len) in
                 spool.pending <- Some (seq, end_offset, text);
                 make_chunk text end_offset)

(* ack：核 pending seq/end_offset/块文本 SHA-256 ⇒ 推进游标；旧 seq ⇒ retired。 *)
let serve_ack header ~view ~operation ~seq ~end_offset ~digest =
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

(* release：核 last_acked fact（Known=spool.seq / N/A=从未确认）；pending 未清
   ⇒ Closing（spool 保留，可续读原 pull）；否则真实清理（丢弃全文）后 Released，
   幂等重放。 *)
let serve_release header ~view ~operation ~last_acked =
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
             spool.text <- "";
             spool.released <- true;
             Some (T.make_view_released header ~view ~operation ~status:T.ReleasedStatus)
           end)
