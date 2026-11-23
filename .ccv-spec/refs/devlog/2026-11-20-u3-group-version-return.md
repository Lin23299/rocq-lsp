# U3 组版本返回：协议与 Pet/Driver 编码检查点

## 范围与决策

用户批准修正首次采用的组版本来源，并允许独立核对与实现并行。保留现有探索组语义，撤回替代探索管理提议；修正见 [方案](../fixes/rocq-mcp-fix-group-version-return-path.md)。Forked、ACK、实际结束候选的 Error 返回实际组快照，历史回执不可变；不新增查询 RPC 或 before/after 记录。ACK 仍引用原 PS05 步骤键，完整 ACK 内容独立封存比较。

试用 `deepseek/deepseek-flash` 的两次只读分析约 92 秒、309 秒，未编辑代码；关键接口分析有遗漏/矛盾，用户批准换回 Sol。不是同任务受控性能对照，不据此宣称模型整体性能差异。

## 实现与静态审核

共享 schema/双端 codec 和对应定向样本已修改；worker 报告精确撤销本次字段 delta 能恢复原向量摘要，未用当前输出整份回填。Pet 真实分叉、候选续证、失败恢复与分组采用在隔离工作树实现；Driver 配对消费并登记原生候选 owner。

独立审查后修正：普通入口绕行候选登记、持久 ACK 误用新执行截止、状态查询接受裸结果、失败候选终态结清；Pet 同步错误保护恢复、正式根证明引用核对、同节点采用后的实际线版本；候选 Parse/Execute Error 的 N/A 反向守卫。最终增量静态复核报告上述项目关闭。UnknownTail 不改成已知，不以 Finished 推出外部副作用回滚或内存已释放。

## 编译证据

候选 stage `/tmp/opencode/group-version-return-stage`，contract digest `c6a32a545707af06fd780019596d9a0d50cc562c2b9adaf8060c518a8188893d`。

- 协议 worker：Rust protocol all-targets 通过，6.74s。
- Pet worker：新 stage 的编译期协议、主仓 types 与真实 Pet release 合编通过，26.04s；有一条 OCaml record 类型歧义警告，未错误选型。
- 主代理：首次 workspace all-targets 在 Store 三处旧 ACK 夹具缺参数处失败；这些主线夹具显式补 N/A，断言保持。第二次通过，14.20s。
- 最后一处 Driver 守卫后，主代理 `cargo check --locked --offline -j1 -p ccv-driver -p ccv-manager --all-targets` 通过，1.95s。

未运行本批测试/探针，未部署。候选 Pet 工件不冒正式安装载荷。运行用例仍按用户要求集中后置。

## 剩余边界

Manager/Store 的候选资格账本、逐证据业务效果与逻辑/原生组映射尚未接通，不能称 run 的 fork→adopt 全链完成。N05、scope 全根释放与容量验收尚未完成。仅保存最大版本是观察，不是授权；迟到首次效果仍需逐键处理，相关未知效果阻止采用。

## 度量

- 可复核工作树累计快照（不是本批净增，含此前未提交工作）：9 个选定 tracked 源码/schema/测试文件 `git diff --numstat` 合计约 +3018/-209；另有 untracked Driver 文件及外部 Pet 工作树，未计入。缺本批独立基线，不将累计量冒充本轮产量。
- 本批新增测试断言已由协议 writer 落盘，精确用例数未统计；运行测试数 0，通过率不适用。
- 静态发现/修正：8 个具名检查点；不是运行复现的 bug 数。
- 迭代：接口收敛 1 批（覆盖首次/续证/失败三条链），主体实施 1 批，独立审核修正 2 轮；Rust workspace 编译修复 1 轮。
