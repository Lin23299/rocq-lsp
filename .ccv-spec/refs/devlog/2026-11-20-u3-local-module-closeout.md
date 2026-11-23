# U3 及必要消费者：本地模块交付检查点

## 完成口径

模块按原职责判断实现完成，外部调用者/部署未齐只挂相应集成。模块自身未实现分支和未决合同仍据实列缺口；不以重新命名切片制造完成。用户同时要求快速复用既有入口检验代码，禁止测试建设挤占生产实现；两项纪律已写根 AGENTS.md。

## 本批本地成果

- Driver：分叉与候选执行/采用、查询与结构化子流、控制取消原帧恢复、源同步元数据交接、环境刷新本地资格处理。
- Store/Manager：候选持久账本/跨请求采用/采用后续写，原事务未知恢复，源同步内部材料到映射提交的消费。
- M6/Store：Query、roster、Assumptions 的真实父子材料捕获/封存/原子发布/独立释放；未知尺寸子流从真实首块绑定，不伪造 descriptor。源同步使用内部 blob，不注册为 actor 输出。
- Pet：Query 与 TOC/GoalPart/Roster/Assumptions 原生生产，有限输出、原预算/ACK/租约；句间取消及原 token 对账；节点生产加载身份修复。受限项见下文，不报完整 NN05/NN06/N07 已完。
- checkpoint 图导入内核：已实现并编译，集中静态审核通过。反序列化前纯清单逐路径检查、可信源快照、file/target 输入比对、alias 消费、私有恢复与兼容不明隔离分类均收口；不等同公开 import/activate。

## 局部证据（不累加重复回归）

| 入口/范围 | 实际结果 |
|---|---|
| Rust nativeface/nativeface_b | 17项通过；最后向量单项131.45s，其余通过证据未重复执行 |
| Driver inspection_regression | 最新8/8，含子流额度反验；不当作Pet E2E |
| Driver interrupt_regression | 2/2，原控制帧恢复/撤权排空真实UnixStream边界 |
| Driver nn03_regression / nn04_refresh | 分别2/2、1/1，原owner额度/映射前置反验 |
| Manager/Store联合快测 | worker报告65项通过；当时明确跳过的真实Pet和旧prefix用例不计通过；旧prefix适配真实预算受理后单跑1/1通过 |
| 真实OS额度读回 / Manager apply | 单例1/1；后续apply套件11/11，不累加为独立全链证明 |
| M6真实Store Query材料链 | 1/1，0.30s；原红例在PS11生产修复后转绿 |
| roster真实Store材料链 | 1/1，0.33s；父+3子/4真实输出，缺子封存拒绝 |
| Assumptions真实Store材料链 | 1/1，0.35s；closed/assumptions/unavailable，缺子封存拒绝，原子引用及各view释放；Manager同过滤0测试不计通过 |
| Pet既有局部Rocq/FD入口 | Query、Inspect、原token/恢复对应局部通过；构建与缓存复用分别报告，不算正式四通道验收 |
| checkpoint Graph | Dune编译及集中静态审核通过；未运行真实Marshal验收，无新测试平台 |

所有worker停止本批写入后，主代理在 `/tmp/opencode/group-version-return-stage` 上执行 Rust 1.90 `cargo check --locked --offline -j1 --workspace --all-targets`，无警告通过，11.10s。未运行全仓测试，未部署、未提交。

## 真实未完成/待决边界

1. NN05/NB07合法折叠notation与完整Notations结构化遍历缺固定Rocq公开纯接口；未引入安装源码提取方案。
2. P02/P03执行中断后的同实例继续缺受控副作用覆盖依据；保持UnknownTail，不能用探针成功替代。失败查询的已捕获前缀亦缺交付载体。
3. N05原生scope版本/退役决定绑定/NativeReclaim交付缺合同接缝；同类缺口阻Pet NN03成功发布。
4. Environment真实M5加载映射、环境更新输入，以及checkpoint实际安装/装载身份/上层调用者未齐；正式RC06仍未通过，不降级能力要求。
5. checkpoint内核的实际注册、导入/公开激活和运行验收仍由其模块继续；不能把内核完成扩为checkpoint全部完成。

## 度量

- 主仓本次观察的累计 tracked 工作树差异：43文件，+7392/-503（`git diff --shortstat`）。含此前未提交工作，不冒充本轮净量；untracked和外部Pet工作树未计。
- 新增用例总数未从跨会话基线精确分离；上表为可归属的实际通过证据，已跳过/过滤/未执行不计成功率。
- 关键实缺陷包括调用链版本来源、原帧恢复/权限/期限、事务未知恢复、采用别名、memo生产身份和Graph前置检查；跨会话未精确去重，不给虚假bug总数。
- 实施为多个模块批次；Graph集中审核修正2轮加1次分类残余修正。未为每个检查点新建测试平台。
