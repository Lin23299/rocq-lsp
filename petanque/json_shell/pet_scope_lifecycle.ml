(* scope 生命周期（spec §5 / N05，devlog 六项 #2）。
    职责：EndScopeRequest 公共入口——准入（scope=binding.scope、序号/退役/预算登记、
    Task 用途与 binding↔budget 可核关系、W02 原请求 digest）、scope 版本核验（Pet
    无独立 scope 登记：首次以请求 expected_revision 播种）、幂等（Closing 回执原样
    重放——Rust 同 seq 须同一回执；Closed 终态原样重放；历史回执不可变）、枚举真实
    容器与借用：Registry 内该 scope 名下操作的 pending 步 / 执行中，query/inspect
    视图、line_updates 视图、checkpoint 下载 blob 的未 release spool。有未清借用 ⇒
    make_ended_closing（首次 seq=1，reclaim=Unknown）并封新准入（Closing 后该 scope
    拒新执行）；借用清空 ⇒ make_ended_closed（seq=上一回执 seq+1，reclaim=Known 新
    id），并从 Registry 真实删除该 scope 名下操作（保留本 end-scope 操作的 Closed
    终态与历史回执）、丢弃其私有视图材料、删除无操作引用的线；共享 context 的 doc
    持有操作若仍被其它 scope 的操作引用则保留。
    不承诺的事：staged 协议库 T.entry_uses_budget 不含 EndScope 分支，Pet 只核可访问
    的 binding↔budget 关系与原请求 digest，initial_request digest 核对留待协议库补齐
    后切回 entry_uses_budget；reclaim 观测（roots 数组）与外部登记 / 原退役决定由
    U4 供给，本批 reclaim 只给 id 不展开；未 N08 的终态操作不计借用（Pet 侧无
    finish 迹象可核）；已删除操作的迟到 FinishOperation 回 unknown_operation。
    本模块状态只在 ordinary 线程、Registry 锁内访问，无独立锁；借用枚举时 Registry
    锁与各材料模块锁不嵌套（先快照 Registry 侧，再数材料侧；release 单调，只会
    偏保守多报 Closing）。 *)

module T = Ccv_protocol.Types
module S = Ccv_protocol.Strict_json
module Registry = Pet_registry
module Query_view = Pet_query_view
module Sync = Pet_source_sync
module Arena = Pet_checkpoint_arena

let get = function Ok value -> value | Error _ -> invalid_arg "pet_scope_lifecycle"
let uint value = get (T.U.make value)
let id_value value = get (T.Id.make value)

type status = Open | Closing | Closed

type scope_state = {
  mutable revision : int64;
  mutable status : status;
  mutable owner : T.op_binding option;      (* Closing 中的 end-scope 操作 *)
  mutable progress : T.receipt option;      (* 最近 Closing 回执（同 seq 重放同一回执） *)
  mutable next_seq : int64;                 (* 下一回执序号（首次 Closing 恒 1） *)
  mutable history : (T.receipt_key * T.receipt) list; (* 历史回执，只增不改 *)
}

let scopes : (string, scope_state) Hashtbl.t = Hashtbl.create 7

let init () = Hashtbl.reset scopes

let scope_of (op : Registry.operation) =
  match T.op_binding_line_owner op.binding with _, scope, _ -> scope

let find scope = Hashtbl.find_opt scopes (T.Id.get scope)

(* 新执行准入：scope 处于 Closing/Closed ⇒ 拒新执行（Registry 锁内）。 *)
let admits ~binding =
  match T.op_binding_line_owner binding with
  | _, scope, _ ->
      (match find scope with None -> true | Some s -> s.status = Open)

(* 该操作是否 Closing 中的 end-scope 操作（pet_native status 据此报 Retiring——
   Rust end_scope_status 只接受 (Retiring, N/A) 或 (Terminal, Closed 回执)）。 *)
let is_closing_owner ~binding =
  match T.op_binding_line_owner binding with
  | _, scope, _ ->
      (match find scope with
       | Some { status = Closing; owner = Some owner; _ } ->
           T.op_binding_equal owner binding
       | _ -> false)

(* end-scope 账本操作（aux 操作形状；终态为 Closed 的 terminal_record）。 *)
let make_operation binding line : Registry.operation =
  { binding; state = Registry.Ready; line; source = T.op_binding_source binding;
    expected_revision = uint 0L; cursor = 0L;
    parent = id_value (Format.asprintf "root-%s" (T.Id.get line));
    pending = None; terminal = None; aux = None; last_ack = None;
    acked_through = 0L; line_revision = 0L; doc = None;
    cancel_seq_seen = 0L; cancel_generation = 1L; stop_requested = false;
    token = None; interrupt_snapshot = None; terminal_receipt = None;
    root_state = None }

let reject header code =
  T.make_protocol_error header code T.not_admitted T.fact_unknown

(* 准入（Registry 锁内）：序号/退役 + scope=binding.scope + 预算登记 + 可核的
   binding↔budget 关系（用途 Task、scope、operation_seq、source/environment）+ W02
   原请求 digest。 *)
let admit header (binding : T.op_binding) scope (request : T.native_request) =
  let seq = T.U.get (T.op_seq binding) in
  if seq <= !Registry.retired_through then
    `Rejected (T.make_past_unavailable header (T.op_seq binding) (uint !Registry.highest_seen))
  else if seq <> Int64.succ !Registry.highest_seen then `Rejected (reject header T.SequenceGap)
  else
    let binding_scope, binding_environment =
      match T.op_binding_line_owner binding with _, s, e -> s, e
    in
    if T.Id.get binding_scope <> T.Id.get scope then `Rejected (reject header T.invalid_input)
    else
      match Registry.find_budget (T.op_binding_budget binding) with
      | None -> `Rejected (reject header T.invalid_input)
      | Some budget ->
          let source, environment = T.budget_source_environment budget in
          let task = match T.budget_purpose budget with T.Task -> true | _ -> false in
          if (not task)
             || T.Id.get (T.budget_scope budget) <> T.Id.get scope
             || T.U.get (T.budget_operation_seq budget) <> seq
             || T.Id.get source <> T.Id.get (T.op_binding_source binding)
             || T.Id.get environment <> T.Id.get binding_environment
             || not (T.matches_original_operation S.message_limits binding request)
          then `Rejected (reject header T.invalid_input)
          else `Admitted

(* —— 借用与容器枚举 —— *)

(* Registry 侧快照（锁内）：该 scope 名下全部操作、未 ACK 步数、执行中数。 *)
let registry_snapshot scope =
  let ops = ref [] in
  let pending = ref 0 and executing = ref 0 in
  Registry.iter_operations (fun op ->
      if T.Id.get (scope_of op) = T.Id.get scope then begin
        ops := op :: !ops;
        if op.pending <> None then incr pending;
        if op.state = Registry.Executing then incr executing
      end);
  (List.rev !ops, !pending, !executing)

(* 材料侧（各自模块锁内、Registry 锁外）：query/inspect 视图、line_updates 视图、
   checkpoint 下载 blob 的未 release 数。 *)
let material_borrows operations =
  let views =
    Query_view.with_lock (fun () ->
        List.fold_left
          (fun acc (op : Registry.operation) -> acc + Query_view.unreleased_count ~operation:(T.op_binding_operation op.binding))
          0 operations)
  in
  let sync_views =
    List.fold_left
      (fun acc (op : Registry.operation) -> acc + Sync.unreleased_views ~operation:(T.op_binding_operation op.binding))
      0 operations
  in
  let blobs =
    Arena.with_lock (fun () ->
        List.fold_left
          (fun acc (op : Registry.operation) ->
             acc + Arena.unreleased_downloads ~operation:(T.op_binding_operation op.binding))
          0 operations)
  in
  views + sync_views + blobs

(* Closed 的真实删除，分三步且锁不嵌套（Registry 锁与 view 锁分别持有）：
   步骤 1（Registry 锁内）定出待删操作：仍被其它 scope 操作引用的线，其 doc 持有
   操作保留（共享 context 的他人引用）；删操作与 doc 引用，返回待清视图的操作 id。
   步骤 2（view 锁内）丢弃其私有视图材料（含失败查询的已捕获前缀私有 lease——
   Error 终态不带 view、驱动无从 release，按非借用材料在此真实清理；此处不应再有
   未 release 的借用）。步骤 3（Registry 锁内）删除已无操作引用的线。 *)
let release_registry ~(keep : Registry.operation) ops =
  let others = ref [] in
  Registry.iter_operations (fun op ->
      if T.Id.get (scope_of op) <> T.Id.get (scope_of keep) then others := op :: !others);
  let line_shared line_key =
    List.exists (fun (op : Registry.operation) -> T.Id.get op.line = line_key) !others
  in
  let doomed =
    List.filter
      (fun (op : Registry.operation) ->
         not (op == keep)
         && not (op.doc <> None && line_shared (T.Id.get op.line)))
      ops
  in
  List.iter
    (fun (op : Registry.operation) ->
       op.doc <- None;
       op.state <- Registry.Retiring;
       Registry.remove_operation op.binding)
    doomed;
  List.map (fun (op : Registry.operation) -> T.op_binding_operation op.binding) doomed

let release_views operations =
  Query_view.with_lock (fun () ->
      List.iter (fun operation -> ignore (Query_view.discard_operation ~operation)) operations)
let release_lines () =
  let line_keys =
    let keys = ref [] in
    Registry.iter_lines (fun key _ -> keys := key :: !keys);
    !keys
  in
  List.iter
    (fun key ->
       let referenced = ref false in
       Registry.iter_operations (fun op -> if T.Id.get op.line = key then referenced := true);
       if not !referenced then Registry.remove_line (id_value key))
    line_keys

(* —— 公共入口 —— *)

type phase =
  [ `Rejected of T.native_reply
  | `Closed_replay of T.receipt
  | `Status of Registry.operation
  | `Recheck of Registry.operation * scope_state ]

let run ~request ~header ~binding ~scope ~expected_revision =
  let expected = T.U.get expected_revision in
  let ensure_scope () =
    match find scope with
    | Some s -> s
    | None ->
        let s =
          { revision = expected; status = Open; owner = None; progress = None;
            next_seq = 1L; history = [] }
        in
        Hashtbl.replace scopes (T.Id.get scope) s;
        s
  in
  let phase =
    Registry.with_tables (fun () ->
        match Registry.find_operation binding with
        | Some op ->
            (match op.terminal, op.terminal_receipt with
             | Some _, Some receipt ->
                 (* 已 Closed：原回执原样重放（历史回执不可变）。直答必须是
                    receipt：Rust end_scope.rs:208 直答只认 NativeResult::Receipt
                    （scope_receipt_phase），Terminal 落 bad_end_scope_reply 隔离。 *)
                 `Closed_replay receipt
             | Some _, _ ->
                 (* 只有 record 无回执（不变量破坏）：按 status 路径报 Terminal，不伪造。 *)
                 `Status op
             | None, _ ->
                 let s = ensure_scope () in
                 if s.status = Closing && T.op_binding_equal binding (Stdlib.Option.value s.owner ~default:binding) then
                   `Recheck (op, s)
                 else `Rejected (reject header T.invalid_state))
        | None ->
            (match admit header binding scope request with
             | `Rejected reply -> `Rejected reply
             | `Admitted ->
                 let s = ensure_scope () in
                 if s.revision <> expected then `Rejected (reject header T.StaleRevision)
                 else
                   (match s.status with
                    | Closed ->
                        (* 已关闭的 scope 不可由另一操作再关。 *)
                        `Rejected (reject header T.invalid_input)
                    | Closing -> `Rejected (reject header T.invalid_state)
                    | Open ->
                        Registry.highest_seen := T.U.get (T.op_seq binding);
                        let context, _, _ = T.op_binding_line_owner binding in
                        let op = make_operation binding context in
                        Registry.register_operation binding op;
                        s.status <- Closing;
                        s.owner <- Some binding;
                        `Recheck (op, s))))
  in
  match phase with
  | `Rejected reply -> reply
  | `Closed_replay receipt -> T.receipt_reply header receipt
  | `Status op ->
      (* 与 pet_native.status 的终态分支同形（Terminal → Known(record)）。 *)
      T.make_status header op.binding T.TerminalState (uint op.acked_through)
        ~highest_seen:(uint !Registry.highest_seen)
        ~retired_through:(uint !Registry.retired_through)
        ~pending:op.pending ~terminal:op.terminal ~last_ack:op.last_ack
        ~stop_requested:op.stop_requested
  | `Recheck (op, s) ->
      let ops, pending, executing = Registry.with_tables (fun () -> registry_snapshot scope) in
      let borrowed = pending + executing + material_borrows ops in
      if borrowed > 0 then
        (* 有未清借用：Closing（同 binding 续调重放同一回执）。 *)
        Registry.with_tables (fun () ->
            match s.progress with
            | Some receipt -> T.receipt_reply header receipt
            | None ->
                let receipt = T.make_ended_closing binding (uint s.next_seq) ~scope ~reclaim:T.FUnknown in
                s.history <- (T.receipt_key receipt, receipt) :: s.history;
                s.progress <- Some receipt;
                s.next_seq <- Int64.succ s.next_seq;
                op.state <- Registry.Retiring;
                T.receipt_reply header receipt)
      else begin
        (* 借用清空：按真实结果发布 Closed，真实删除该 scope 的容器。 *)
        let doomed = Registry.with_tables (fun () -> release_registry ~keep:op ops) in
        release_views doomed;
        Registry.with_tables release_lines;
        Registry.with_tables (fun () ->
            let reclaim =
              id_value
                (Format.asprintf "reclaim-scope-%s-%s" (T.Id.get scope)
                   (T.Id.get (T.op_binding_operation binding)))
            in
            let receipt, record =
              T.make_ended_closed binding (uint s.next_seq) ~scope ~reclaim:(T.FKnown reclaim)
            in
            s.history <- (T.receipt_key receipt, receipt) :: s.history;
            s.status <- Closed;
            s.progress <- None;
            s.next_seq <- Int64.succ s.next_seq;
            op.terminal <- Some record;
            op.terminal_receipt <- Some receipt;
            op.state <- Registry.TerminalState;
            (* 直答回 receipt（Rust end_scope.rs:208）；status 仍由 op.terminal 报
               Terminal → Known(record)（end_scope.rs:217）。 *)
            T.receipt_reply header receipt)
      end
