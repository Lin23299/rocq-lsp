(* 环境刷新（spec §2 末尾 / NN04，devlog 六项 #4）。
   职责：同环境 no-op 与真实变更分开；未知不发布新身份；拒绝（protocol_error
   not_admitted）与已尝试未知（无终态、status 卡 Retiring）区分；同 binding 幂等
   重放原 aux。真实重建走 Shell.env_snapshot / install_env / readback_env。
   不承诺的事：不消费 M5 环境事务输入（后续 item），不偷偷换工具链/load-path
   （workspace/init 原样继承），失败时绝不把安装了一半的状态冒称成功。
   锁序约定：本模块锁 → Registry 锁，禁止反序（pet_native 路由不持 Registry 锁
   调用本模块）。 *)

module T = Ccv_protocol.Types
module Registry = Pet_registry
module Shell = Petanque_shell.Shell

type attempt = {
  binding : T.op_binding;
  old_env : T.Id.t;
  new_env : T.Id.t;
  publication : T.Id.t;
}

let lock = Mutex.create ()

(* 当前环境身份：无 boot.environment 访问器，初始身份从首个任务预算解析
   （budget_for_task_entry 保证任务预算共享 boot 环境）。 *)
let current_env : T.Id.t option ref = ref None

(* 进行中的变更尝试记账（同 binding 重入重试；异 binding 冲突）。 *)
let refreshing : attempt option ref = ref None

(* install 之后 readback 之前失败 ⇒ 状态未知：卡 Retiring，本批无解除路径。 *)
let in_progress = ref false

let init () =
  current_env := None;
  refreshing := None;
  in_progress := false

let get_ok = function Ok value -> value | Error _ -> invalid_arg "pet_environment_refresh"
let uint value = get_ok (T.U.make value)
let id_value value = get_ok (T.Id.make value)

(* 解析当前环境身份（须在 with_tables 内调用）。 *)
let effective_current () =
  match !current_env with
  | Some env -> Some env
  | None ->
      let resolved = Registry.any_budget_environment () in
      (match resolved with Some env -> current_env := Some env | None -> ());
      resolved

(* 旧环境上是否还有未决 pending 步（须在 with_tables 内调用）。 *)
let has_unsettled_work old_env =
  let unsettled = ref false in
  Registry.iter_operations (fun other ->
      if (not !unsettled) && other.pending <> None then
        match T.op_binding_line_owner other.binding with
        | _, _, env ->
            if T.Id.get env = T.Id.get old_env then unsettled := true);
  !unsettled

(* 变更路径的真实重建：快照当前 env ⇒ 新 files/env ⇒ install ⇒ readback
   物理同一 ⇒ 发布。返回 (reply, published)。两条失败路径严格区分：
   - install 之前失败：环境未动，拒绝口径（可重试）；
   - install 之后 readback 失败：状态未知，in_progress 卡 Retiring，绝不回成功。 *)
let rebuild_and_publish header binding (op : Registry.operation) old_env new_env =
  match Shell.env_snapshot () with
  | None -> `Rejected
  | Some current -> (
      let built =
        try
          Ok
            (Fleche.Doc.Env.make
               ~init:current.Fleche.Doc.Env.init
               ~workspace:current.Fleche.Doc.Env.workspace
               ~files:(Coq.Files.make ()))
        with exn -> Error exn
      in
      match built with
      | Error _ -> `Rejected
      | Ok environment -> (
          Shell.install_env environment;
          match Shell.readback_env () with
          | Some readback when readback == environment ->
              (* 发布：身份切换与记账在同一临界区完成。 *)
              current_env := Some new_env;
              refreshing := None;
              let reclaim_id =
                id_value (Format.asprintf "reclaim-%s" (T.Id.get old_env))
              in
              let aux =
                T.make_environment_refreshed_terminal binding
                  ~environment:new_env ~changed:true ~reclaim:(T.FKnown reclaim_id)
              in
              op.aux <- Some aux;
              op.state <- Registry.TerminalState;
              `Published (T.locator_reply header aux)
          | _ ->
              (* 状态未知：不发布新身份，卡 Retiring。 *)
              in_progress := true;
              op.state <- Registry.Retiring;
              `Unknown))

let retiring_status header binding =
  T.make_retiring_status header binding
    ~highest_seen:(uint !Registry.highest_seen)
    ~retired_through:(uint !Registry.retired_through)
    ~stop_requested:false

(* 刷新入口：pet_native 已完成准入（admit_new + 登记 op）。返回直答 reply；
   状态查询走 Registry op（aux/status）。 *)
let refresh ~header ~binding ~old_env ~new_env ~publication =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
      Registry.with_tables (fun () ->
          let reject code =
            T.make_protocol_error header code T.not_admitted T.fact_unknown
          in
          match Registry.find_operation binding with
          | Some { aux = Some aux; _ } ->
              (* 幂等：同 binding 重入重放原 aux（直答与 status 同源）。 *)
              T.locator_reply header aux
          | Some op -> (
              (* 已登记未发布：本 binding 重试/查态继续；异 binding 在途 ⇒ 冲突。 *)
              match !refreshing with
              | Some { binding = other; _ }
                when not (T.op_binding_equal other binding) ->
                  T.make_protocol_error header T.BindingConflict
                    T.ExistingOperation T.fact_unknown
              | _ -> (
                  match effective_current () with
                  | None ->
                      (* 无预算/无环境身份可核：拒绝口径（可重试）。 *)
                      reject T.invalid_input
                  | Some current when T.Id.get old_env <> T.Id.get current ->
                      (* 旧环境不是当前环境 ⇒ 拒绝。 *)
                      reject T.invalid_input
                  | Some _ -> (
                      if T.Id.get old_env = T.Id.get new_env then begin
                        (* 同环境 no-op：changed=false、保热（不重建）。 *)
                        refreshing := None;
                        let aux =
                          T.make_environment_refreshed_terminal binding
                            ~environment:new_env ~changed:false
                            ~reclaim:T.FNotApplicable
                        in
                        op.aux <- Some aux;
                        op.state <- Registry.TerminalState;
                        T.locator_reply header aux
                      end
                      else if !in_progress then begin
                        (* 上次变更 install 后未知：不发布新身份，卡 Retiring。 *)
                        op.state <- Registry.Retiring;
                        retiring_status header binding
                      end
                      else if has_unsettled_work old_env then begin
                        (* 变更前置：旧环境还有未决 pending 步 ⇒ 未完成
                           （RETIRING 语义，同 binding 续调至排空）。 *)
                        refreshing := Some { binding; old_env; new_env; publication };
                        op.state <- Registry.Retiring;
                        retiring_status header binding
                      end
                      else begin
                        refreshing := Some { binding; old_env; new_env; publication };
                        match rebuild_and_publish header binding op old_env new_env with
                        | `Rejected ->
                            (* install 之前失败：不发布、记账保留（可重试）、拒绝。 *)
                            reject T.invalid_input
                        | `Unknown -> retiring_status header binding
                        | `Published reply -> reply
                      end)))
          | None ->
              (* 路由未登记（防御）：拒绝。 *)
              reject T.unknown_operation))
