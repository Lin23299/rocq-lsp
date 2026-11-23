继续 item 1。你已读过 spec/types.mli/基线文件，现在直接开写，不要再通读大文件（fleche/doc.ml 不需要读）。按小块推进，本块目标（块 A）：

A1. 新建 petanque/json_shell/pet_registry.ml：把 pet_native.ml 里的 sources/budgets/operations/with_tables/highest_seen 等迁入（spec §1 签名；budgets 改存 T.native_budget，add_budget 用 T.budget_equal 幂等；operation record 扩展 spec §1 的字段；now_us 用 Unix.clock_gettime CLOCK_MONOTONIC 微秒；retired_through ref）。pet_native.ml 改用 Registry。
A2. dune：新库 pet_native_support（modules pet_registry pet_environment_refresh；libraries petanque_shell ccv_protocol threads.posix）；pet_native.exe libraries 追加 pet_native_support。先建空的 pet_environment_refresh.ml（占位注释，下一块填充）。
A3. pet_native.ml 修 API 漂移：T.make_status 加 ~retired_through:!Registry.retired_through；T.error_terminal 加 ~group:None；T.make_ack 加 ~group:None。
A4. native_request_view 补全分派（编译要穷尽）：RefreshEnvironmentRequest/LocateContextRequest/SelectLineRequest/ForkLineRequest/SyncSourceRequest/QueryRequest/InspectRequest/EndScopeRequest/CheckpointRequest 本块一律 `T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown`（后续块替换）；SettleInterruptRequest 同样占位；RetireThroughRequest (header, seq)：Registry.retired_through 取 max 后 `T.make_retired header seq`。
A5. 跑构建（spec §0 命令，或直接用你上块看过的 task-1.md 里的命令原文）到零错误；把结果写进 .ccv-spec/progress-1.md（块 A 完成情况/编译输出结论/剩余块 B-E 清单）。

纪律：不 commit；注释中文；只有本块列出的文件要动。
