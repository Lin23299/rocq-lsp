(* 共享运行态注册表（spec §1，item 1 接线基础）。
   职责：集中保存 Pet 进程内的可变运行态——source 材料、budget 登记、
   操作表（含主线 doc 持有）、操作序号水位（highest_seen）与退役水位
   （retired_through）、输入配额记账，以及单调微秒时钟。
   不承诺的事：本模块不做任何协议裁决（拒绝/未知口径由各公共入口负责），
   也不解释 wire 语义；find/register 类函数须在 with_tables 临界区内调用，
   沿用基线锁纪律。 *)

module T = Ccv_protocol.Types

type source_data = Staging of bytes | Sealed of string

(* 基线原样：data 封存后由 Staging 迁移到 Sealed。 *)
type source = {
  mutable data : source_data;
  expected_digest : string;
  mutable next_offset : int64;
}

type op_state = Ready | Executing | WaitAck | TerminalState | Retiring

type operation = {
  binding : T.op_binding;
  mutable state : op_state;
  mutable pending : T.receipt option;       (* WAIT_ACK 未确认步 *)
  mutable terminal : T.terminal_record option;
  mutable aux : T.aux_terminal option;       (* 六方法 aux 终态；重读返回原事实 *)
  mutable last_ack : T.ack_status option;
  mutable acked_through : int64;
  mutable line : T.Id.t;
  mutable line_revision : int64;
  mutable cursor : int64;
  mutable parent : T.Id.t;
  mutable source : T.Id.t;
  mutable doc : Fleche.Doc.t option;         (* 主线/上下文持有 *)
  expected_revision : T.U.t;                 (* 基线保留：BeginLine 期望线版本 *)
}

let sources : (string, source) Hashtbl.t = Hashtbl.create 17
let budgets : (string, T.native_budget) Hashtbl.t = Hashtbl.create 17

let tables = Mutex.create ()

(* 沿用基线：所有共享表访问都包在 with_tables 内。 *)
let with_tables f = Mutex.lock tables; Fun.protect ~finally:(fun () -> Mutex.unlock tables) f

let highest_seen = ref 0L
let retired_through = ref 0L

let operations : (T.op_binding * operation) list ref = ref []

(* 输入配额：boot 时设置上限，source 上传占用/释放。 *)
let input_quota = ref 0L
let input_reserved = ref 0L

let init () =
  Hashtbl.reset sources;
  Hashtbl.reset budgets;
  operations := [];
  highest_seen := 0L;
  retired_through := 0L;
  input_reserved := 0L

(* 以下三个操作表函数须在 with_tables 临界区内调用。 *)
let find_operation binding =
  List.find_opt (fun (known, _) -> T.op_binding_equal known binding) !operations
  |> Option.map snd

let register_operation binding operation =
  operations := (binding, operation) :: !operations

let iter_operations f = List.iter (fun (_, operation) -> f operation) !operations

(* budget 存完整 T.native_budget：同内容（budget_equal）幂等，异内容冲突。 *)
let add_budget (budget : T.native_budget) =
  match Hashtbl.find_opt budgets (T.Id.get (T.budget_id budget)) with
  | Some known when T.budget_equal known budget -> `Ok
  | Some _ -> `Conflict
  | None ->
      Hashtbl.add budgets (T.Id.get (T.budget_id budget)) budget;
      `Ok

let find_budget budget_id = Hashtbl.find_opt budgets (T.Id.get budget_id)

(* 以下 source 表函数须在 with_tables 临界区内调用。 *)
let find_source key = Hashtbl.find_opt sources key
let add_source key source = Hashtbl.add sources key source
let remove_source key = Hashtbl.remove sources key

let source_bytes source_id =
  match Hashtbl.find_opt sources (T.Id.get source_id) with
  | Some { data = Sealed raw; _ } -> Some raw
  | _ -> None

(* 单调时钟：选择读 /proc/uptime——本 switch 的 OCaml 4.14.2 unix 库没有
   Unix.clock_gettime/CLOCK_MONOTONIC（已实测），而 /proc/uptime 同样以 boot
   起算秒（保留两位小数），与 Rust 端 CLOCK_MONOTONIC 同域，µs = 秒*1_000_000。
   仅当读取失败（非 Linux / proc 不可用）才退回「墙钟+单调下界」：该回退域
   与单调域不一致，只可做进程内相对期限判断，不得与 Rust 端 deadline 比对。 *)
let wall_floor = ref 0L

let fallback_us () =
  let wall = Int64.of_float (Unix.gettimeofday () *. 1_000_000.0) in
  if Int64.compare wall !wall_floor > 0 then begin
    wall_floor := wall;
    wall
  end else !wall_floor

let now_us () =
  let uptime () =
    let ic = open_in "/proc/uptime" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        match input_line ic with
        | line ->
            let seconds =
              match String.index_opt line ' ' with
              | Some space -> String.sub line 0 space
              | None -> line
            in
            Option.map
              (fun s -> Int64.of_float (s *. 1_000_000.0))
              (float_of_string_opt seconds)
        | exception End_of_file -> None)
  in
  match (try uptime () with Sys_error _ | End_of_file -> None) with
  | Some us -> us
  | None -> fallback_us ()

(* 预算期限：deadline 为绝对微秒，过期即真（>=）。 *)
let deadline_expired (budget : T.native_budget) = function
  | `Execution -> now_us () >= T.U.get (T.budget_execution_deadline budget)
  | `Recovery -> now_us () >= T.U.get (T.budget_recovery_deadline budget)
  | `Output -> now_us () >= T.U.get (T.budget_output_deadline budget)

let set_input_quota quota = input_quota := quota

(* 输入配额记账：占用成功返回 true；越界（或非法）不变更并返回 false。 *)
let reserve_input size =
  if size < 0L
     || Int64.compare size (Int64.sub !input_quota !input_reserved) > 0
  then false
  else begin
    input_reserved := Int64.add !input_reserved size;
    true
  end

let release_input size =
  (* 下界保护：多次释放不回退到负数。 *)
  if Int64.compare !input_reserved size < 0 then input_reserved := 0L
  else input_reserved := Int64.sub !input_reserved size;
  true
