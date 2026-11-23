# 审核修复轮（协议对齐 1–13）进度

- 提交：b982870（必修 1–4）、1c40fb0（应修 5–8）、ff445cf（应修 9–13），已 push 到 origin/ccv-nativeface-u3。
- 构建：spec §0 命令退出 0；git diff --check 干净。
- 端到端（Rust ccv-driver 公开 API 驱动真实 Pet，临时 crate /tmp/opencode/petprobe，未入 git）8 场景全部 PASS，
  对旧 Pet（4b24e9b 构建）8 场景全部 FAIL 且失败点与审核编号一一对应：
  cancel_between_steps / cancel_during_step（1）、end_scope_closed_receipt（3）、select_then_continue（4+6 续接）、
  fork_candidate（6）、inspection_assumptions（5+10）、locate_after_sync（2 崩溃 + 8 + 9）、settle_on_aux_checkpoint（7）。
- OCaml 探针（临时 dune 可执行，已删）：lcp 8 例（含追加编辑）；Print Assumptions 结构化解析（长公理 / 节变量 / closed）；
  arena prepare_import 映射摘要 = sha256(map_bytes)（11）；discard_operation 回收 5 材料、input_reserved 1091→0（12）。
- 审核 13 核过无缺陷（CRef 无 or_by_notation；`"+"%nat` 是字符串字面量），只补注释。
- 已知接缝（未动）：多操作共线时 Query.resolve_anchor / locate_context_line 仍按单 doc 近似（候选线节点解析 fail closed）；
  make_retiring_status 协议构造器硬编码 acked_through=0；NN04 刷新后线 frontier_state 未失效；sync 回滚前沿时线表 frontier 保留原值（既有口径）。
