继续 item 1（块 A 收尾）。已完成：pet_registry.ml、pet_environment_refresh.ml 占位、dune。剩余：

B0（修正）：pet_registry.ml 的 now_us 改为读 /proc/uptime（与 Rust 端 CLOCK_MONOTONIC 同域：boot 起算；µs = 秒*1_000_000，保留两位小数精度）。实现：每次调用 In_channel 或 Unix.open_in 读一行解析 float。读失败才退回现有「墙钟+单调下界」并在注释注明域不一致风险。删掉「unix 无 clock_gettime」注释里对 spec §0 的让步表述，改为如实说明选择 /proc/uptime 的原因。

B1：pet_native.ml 修三处 API 漂移（make_status 补 ~retired_through:!Registry.retired_through；error_terminal 补 ~group:None；make_ack 补 ~group:None），表访问迁 Registry（sources/budgets/operations/highest_seen/with_tables）。
B2：native_request_view 补全穷尽分派：LocateContextRequest/SelectLineRequest/ForkLineRequest/SyncSourceRequest/QueryRequest/InspectRequest/EndScopeRequest/CheckpointRequest/SettleInterruptRequest/RefreshEnvironmentRequest 一律占位 `T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown`；RetireThroughRequest (header, seq) ⇒ Registry.retired_through := max 后 `T.make_retired header seq`。
B3：RegisterBudgetRequest 改用 Registry.add_budget 存 T.native_budget：`Ok/`Ok 幂等回原 make_budget_registered；`Conflict ⇒ T.make_protocol_error header T.BindingConflict T.ExistingOperation T.fact_unknown。
B4：跑构建到零错误（命令在你 context 里 task-1.md 原文；注意 OCAMLPATH 与 HOME 原样）。绿后把「块 A 完成/构建输出结论/剩余块 C(控制通道+source/view 分派骨架)、D(locate/fork/select)、E(shell Interrupted+restore_sentence+env 三件套)、F(pet_environment_refresh 实装+refresh 路由)」写进 .ccv-spec/progress-1.md。

纪律：不 commit；注释中文；只动 pet_registry.ml/pet_native.ml/pet_environment_refresh.ml/dune。
