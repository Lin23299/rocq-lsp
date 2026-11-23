# U3：Rust driver 与 OCaml 原生生命周期细化

> rmcp-13增量已在§9形成函数细化：包含checkpoint观测/导出/导入/激活、完整历史root覆盖、新实例映射及二进制接缝；整包§4.4待审。
> rmcp-12只验证固定小例；本轮按[责任矩阵](../subplans/rmcp-13-user-pause-disk-checkpoint.md)补充的设计不代表生产实现/真实验收，也不继承下面历史签字的编码许可。
> 2026-11-18 U3 nativeface上游登记：`Lin23299/rocq-lsp` 分支
> `ccv-nativeface-u3`、提交 `926c20d636fceabdac74174da7cf1d4505891a49`
> （基于 `ccv-demand-2026-09@05fa632`）；登记见
> `scripts/mcp/pins-nativeface.json`，补丁见 `scripts/mcp/petanque-nativeface.patch`。
> 这是候选本地构建，不是 U7 安装/fixed artifact。
> 2026-11-18 U3-c1已落Rust侧ND01固定FD启动/四通道、ND03帧、NW01握手及ND02单在途交换；U3-c2补ND07最小实际exec身份、ND04 RLIMIT/ND05停止/ND06本地隔离标记；U3-c3候选已在维护fork实现真实nativeface source/begin/pull/ACK/EOF并用手动Pet探针验证。仍未独立审计、未固定安装，NW02只做最小budget登记；control取消、view/query、checkpoint、source持久化/恢复及cgroup/watchdog仍缺，不能据本文件把U3记作完成（见[rmcp-20](../subplans/rmcp-20-u3c1-native-transport.md)、[rmcp-21](../subplans/rmcp-21-u3c2-identity-limits-stop.md)、[rmcp-22](../subplans/rmcp-22-u3c3-nativeface-pet.md)）。

2026-10-30；workflow §4.3 设计已获[集成终审§6–7](../../../audits/unified-remediation-2026-10-30/integration-closeout-review.md)通过。只设计，Step 0及真实探针/实现验收独立未完成，未编码、安装或部署。

## 1. 范围与权威

实现[统一架构](../unified-execution-architecture.md) §3、§8、§10 的 M3；支撑 G2–G6、I 所述实例隔离、完整热主线及全根释放。
本文补足原生 Registry、parser 接缝、其余方法及 driver 进程/帧管理，不复制 Manager 的授权/预算策略、M4 持久路径或 M6 输出模型。
步骤协议唯一引用：[rmcp-7](../subplans/rmcp-7-native-step-protocol.md) N01–N08/D01–D04；
消息/摘要唯一引用：[rmcp-8](../subplans/rmcp-8-native-wire-and-token-probes.md) §3、W01–W03。
Token 入口小实验唯一引用 [rmcp-9](../subplans/rmcp-9-token-entry-precode.md)；其通过编码前审不表示原生中断已实现。

新增函数分组：ND01–ND06（Rust）、NR01–NR06（Registry）、NB01–NB08（原生适配）、NN01–NN06（业务入口）。
跨语言协议实现另有 OC01–OC08（固定类型OCaml protocol-only）；不把Rust RC函数存在当成OCaml端已实现。
握手/预算登记另有 NW01–NW02，覆盖启动身份和 B.budget 的实际生产入口。
Rust 实施位置为本 CCV 仓库 `rust/` 中的内部 driver 模块；OCaml 接缝仍在固定维护 fork，不另建 Rust 运行仓库。
OS 接口依赖固定 `libc = "=0.2.191"`、`default-features=false, features=["std"]`（MIT OR Apache-2.0，crate MSRV1.63）；
统一按项目 Rust1.90 验收，不向 protocol-only crate 引入 libc，不另引进程管理 crate。Tokio/Serde/摘要底座引用 U0 总集同一 pin。
所有函数均为待实现；已有九方法只调用这些接缝，不在 Rust 维护第二热图。

## 2. 只读源码与复用合同

固定来源为 `Lin23299/rocq-lsp@f9d408ef44ab42594d6830015863681da2e5284f`；本轮只读导出
`/home/ubuntu/ccv-mcp-lab/issue150-20261026/backend/source`，不是新制品验收。未研究旧 rocq-mcp 实现。

| ID | 源码/依赖 | pre → post 与适配范围 |
|---|---|---|
| C-PARSE | `fleche/doc.ml`、`coq/interp.mli` | 指定父 parsing state 和不可变字节 → 官方 parser 的 AST/EOF/错误；新增单步出口，不能调用现有整段 `Doc.run` 仅取末态 |
| C-DOC | `fleche/doc.mli:35–104,126–168` | Doc.Node 含 prev/state，Doc 含 nodes/toc/root/env；这些全是强根。`create` 可返回 Failed，不把返回对象等同成功 |
| C-MEMO | `fleche/memo.mli:20–79` | Init/Interp/Require/Admit 各有 clear；Intern.clear 是另一入口，不假设它清了所有表。新增统一显式清理接缝 |
| C-SHELL | `petanque/json_shell/shell.ml:56–90` | init/env/documents 是独立根；workspace_update bump files、换 doc、清 Intern/State，但不构成本设计全根证明；新入口取代隐式文档表所有权 |
| C-STATE | `coq/state.ml:11,56–85` | state 为 Vernacstate；hash/物理相等不是来源/有效性证明；mode 读全局，查询前必须恢复明确父状态 |
| C-TOKEN | rmcp-8 §1/§4、rmcp-9 §2/§4 | C 的 check/clear 与 set 必须共享入口排序；实际 C/M/Atomic 支持集合仍待真实验收 |
| C-CODEC | rmcp-5 S-DECODE/S-ENCODE/S-DIGEST/S-HANDSHAKE，rmcp-8 W01–W03 | 固定显式类型、有界严格解码、方法配对、规范摘要；不解释运行catalog，不证明授权、Rocq成功或制品身份 |
| C-M2 | Manager MS08/MS09的TaskAuthorization/DispatchTicket、MemoryGrant与停止决定 | ordinary原WorkGrant/permit校验保持；control_replay仅PS33 AcceptControl与PS15/PS04同事务提交的真实main管理control及固定框架计划，由M2每次派发/续pull重核；当前实例、实际child域/input/deadline与额度须匹配。撤权后仍可确认已有durable pending，不把ACK当新执行 |
| C-M4 | rmcp-7 C4/C5；M4 不可变 SourceRef blob | 意图先 durable；成功步/终态明确 durable 后 ACK/finish；未知不确认；blob 长度/摘要与 SourceRef 一致 |
| C-M6 | M6 typed selector、view descriptor、输出 sink | 有效 node/owner/selector 和有限生成预算 → 原文分块/精确范围/完成事实；捕获失败不抹除执行成功 |
| C-OS | 固定制品启动、受管执行域、wait/限额接口 | exec 前入域/应用限额；完整域停止须核实，PID/Drop/FD EOF 均非核停证据 |

C-PARSE/C-DOC/C-MEMO/C-SHELL 的新增接口在维护 fork 内交付；不改 Rocq 内核，不把固定源码已有 API 误称为完整合同。

## 3. 错误、并发与退出规则

所有入口返回 typed Result，协议错误沿 rmcp-8 NativeProtocolError；Rocq 执行错误走 Receipt.error。
未发送可报 not_started；发送任一字节后至完整可信回执前为 unknown，不把超时、截断、退出归为 COQ_ERROR。
普通通道损坏进入 QUARANTINED；只可独立控制/核停，不能发 status 探测重新同步。完整排空后才允许 rmcp-7 D02。
所有原生图、Rocq、feedback、current、memo 修改在唯一执行线程；控制 reader 只持标量 cell 与 Token。
锁序为 control-cell → Limits-entry；二者都不跨 eval、输出、磁盘、等待 ACK。Rust actor 单所有者控制普通在途槽，控制通道另有 reader。
不可恢复异常/OOM 发生于原生图提交或恢复时，不承诺任意 OCaml 异常可回滚；标 POISONED，拒新执行，交 M2 核停。
成功回执丢失不回滚成功；按 operation 身份对账。进程死亡只使热引用无效，不删除 M4 持久成果。

## 4. 私有类型与新增 wire roots

### 4.1 私有类型（均为易失，只有原生端拥有状态对象）

| 类型 | 字段/不变量 | 建立、修改、删除 |
|---|---|---|
| Driver | instance/epochs、DomainIdentity、实际exec_identity?、普通/控制 FD、各自 rpc_seq、inflight?、Health、AppliedGrant | ND01 创建；ND02 关联；核停后销毁，绝不接管未知 Pet |
| DomainIdentity | service-domain、unit/cgroup 或受核进程组、boot/start identity、pidfd（可用时） | M2/C-OS 登记；PID 复用不相等；unknown 不释放额度 |
| Registry | contexts/nodes/lines/scopes、RootInventory、operations、current、environment、poisoned | 唯一执行线程拥有；不存在第二 legacy documents/State 强表 |
| Node | id、context、parent?、state、SourceSpan、parse_horizon、environment | id 永不复用；parent 严格早于子；ACK 后沿 line 保护全祖先；state hash 不作 key |
| SourceSpan | source、start/end/cursor、parser origin、lexical read horizon、EOF-observed | 绑定实际字节；read horizon 包含 lexer lookahead，EOF 是额外依赖，不能只比较 AST end |
| Line | id、scope、target、revision、frontier、kind(mainline/exploration)、status | 只经 Registry txn 换 frontier；祖先自然共享；不按节点数截断 |
| Scope | id、revision、OPEN/CLOSING/CLOSED、owned line/context refs、borrow set | M2 授予后登记；关闭先停准入，全部借用/输出引用核清后 CLOSED |
| Context | id、logical file/target key、source/env、history:DocBacked或RestoredHistoryIndex、root node、revision | 定位同一实例精确 key 复用；两种history都不暗持已退役后缀；Restored不是外构造private Fleche.Doc.t |
| Borrow | unique id、owner operation/view、node、scope、phase | NR01 取得；单一 finally/明确完成释放；未知 borrower 不视为释放 |
| RootInventory | registered typed handles：line/doc/index/memo/import/current/pending/inflight/view/bootstrap/checkpoint_export/checkpoint_import | 是实际容器的 adapter 目录，不是对象堆镜像；每 adapter 枚举/撤销自身强引用 |
| GraphTxn | old immutable registry root、prepared successor、detach actions、receipt | 先分配/校验，单次发布；外部 current/cache 操作失败可 poison，不伪回滚 |

Registry 是真实所有权图。Node/Line/Scope 映射使用强值时，退役必须从映射删除；辅助 ID 索引用弱值或随主图删除，不能称“仅索引”而保强根。
Doc.Node.prev 仅回指祖先；Doc.nodes/toc、旧 doc 闭包、memo key/value、Coq current 与在途局部变量都纳入 RootInventory。
不建立第二 GC：只管理业务 owner/borrow 和已知强容器，交 OCaml GC 回收对象；不遍历/复制 Vernacstate 内部对象图。

### 4.2 新增 wire（U0 注册，沿 rmcp-8 封闭 codec）

以下 root ID 为设计注册名；共同 header/B/Id/U/Fact/Digest 及操作摘要规则直接复用 rmcp-8，所有字段必填。
表内带点名称仅是逻辑标签；显式类型/标准schema定义名固定映射为 NativeContextRequest/NativeContextResult、NativeForkRequest/NativeForkResult、
NativeSourceSyncRequest/NativeSourceSyncResult、NativeEnvironmentRefreshRequest/NativeEnvironmentRefreshResult、
NativeQueryRequest/NativeQueryResult、NativeInspectRequest/NativeInspectResult。source 三动作对应 NativeSourceBegin/NativeSourceChunk/NativeSourceFinish。
映射逐项登记并查唯一，不用字符替换算法猜 ID。
每个新建立操作也消费 operation_seq，复用 operation_status/finish/retire；不能另开无界幂等表。
新增成功结果为独立 tagged result，非伪造 step；已有 NativeReceipt kind 不扩成 locate/fork。

| root / method | args（全部） | result 的成功 value（全部） |
|---|---|---|
| `native.context.request/result` / locate_context | `{binding:B,file:Id,target:Target,logical_target:Id,lineage:Fact<Version>,expected_context:Fact<Version>}` | `{kind:"located",context:Id,line:Id,node:Id,revision:U,cursor:U,boundary:Fact<NativeBoundaryFact>}` 或 `{kind:"needs_prefix",context:Id,line:Id,node:Id,revision:U,cursor:U,target:Target,boundary:Fact<NativeBoundaryFact>}` |
| `native.fork.request/result` / fork_line | `{binding:B,parent:Id,expected_line:Version,new_line:Id,exploration:Id}` | `{kind:"forked",line:Id,node:Id,revision:U,group:NativeGroupVersion}`；`group.group` 等于原 `exploration`，版本取创建/加入事务之后的实际快照 |
| `native.source_sync.request/result` / sync_source | `{binding:B,context:Id,expected_context:Version,old_source:Id,new_source:Id,publication:Id}` | `{kind:"source_synced",context:Id,revision:U,source:Id,last_valid:Fact<Id>,reclaim:Id,boundary:Fact<NativeBoundaryFact>,line_updates:NativeLineUpdateRef}` |
| `native.environment_refresh.request/result` / refresh_environment | `{binding:B,old_environment:Id,new_environment:Id,publication:Id}` | `{kind:"environment_refreshed",environment:Id,changed:Bool,reclaim:Fact<Id>}` |
| `native.query.request/result` / query | `{binding:B,node:Id,selector:QuerySelector,output_budget:Id}` | `{kind:"view",descriptor:ViewDescriptor}` |
| `native.inspect.request/result` / inspect | `{binding:B,node:Id,selector:InspectSelector,output_budget:Id}` | `{kind:"view",descriptor:ViewDescriptor}` |

`Version={id:Id,revision:U}`；`Target={kind:"root"}|{kind:"end"}|{kind:"position",line:U,character:U}|{kind:"theorem",name:String}`。
position 是零基 UTF-16，经原生 Contents/位置转换校验；end 是实际 EOF，不减一或加一猜句界。
expected_context 只准 known/not_applicable；已有精确上下文须核 revision，新建时 not_applicable，不以 unknown 开放变更。
lineage只准known/not_applicable，其Version专名为NativeLineVersion：id为当前原生Line ID、revision为实际Native Line.revision，
由M2从ProofRef/逻辑lineage映射取得（恢复后来自map.new_line/new_line_revision），**不是M4 path_revision**。新建可not_applicable。
not_applicable在0候选时允许正常新建、1候选时继续；多个合法lineage命中同source/offset必须拒绝歧义，不按第一个或state hash挑节点。
QuerySelector/InspectSelector/ViewDescriptor 及其生成分页 root 唯一归 M6，U3 引用，不再次定义五组 goal schema。
三个具名类型与 NativeFactsDocument/原生 view 消息已由 [build-output.md §3.5](build-output.md) 展开；以该段为唯一来源。
查询 AST 精确白名单见本模块 §4.3/NB07，view ACK/retired 封闭 result 配对见 M6 §3.5；禁止使用任意 JSON 或在编码时自行补猜。
view pull/ACK/release 使用 M6 定义的独立 view channel、EpochHeader 和 tagged ViewReply，不塞普通 NativeResult；
该 channel 有唯一 reader/独立 rpc_seq/一个在途槽，仍核同一 instance/epochs/operation。普通/control/view 的序号不得互配。
view channel 只消费 NB06 已封存 spool，不执行 Rocq、不访问可变 Registry；由执行线程交付的 spool lease 授予消费权，
release 通过串行生命周期事件撤销该 lease，借用未核清时 closing。view IO 失败不堵 control，也不证明原生操作未发生。
上述 result 共用 `{kind:"result",header,result}` 外壳；各建立操作的结果与稳定终态 key 由操作记录保存，未知/拒绝沿 rmcp-8。
新增 `AuxTerminal={kind:"aux",key:K,binding:B,execution_extent:Extent,value:AuxValue}`，AuxValue 为上表六方法及§9四个checkpoint方法的封闭成功 value，
另允许 `{kind:"error",stage:NativeStage,diagnostic:Fact<Id>,last_valid:Fact<Id>}`；完整记录去 key.digest 后按 rmcp-8 receipt 域规范摘要。
U0 将通用操作终态定义为 `AnyTerminal=TerminalRecord|AuxTerminal`（aux 判别与 receipt/eof/prefix_reached 不交叉），
OpStatus.terminal、finish 的 key 和 settle 已终态重读取 AnyTerminal；旧九方法允许结果矩阵保持原约束，只有这些新增建立方法允许 aux。
候选 ACK 和实际结束候选的步骤 Error 也返回各自事务后的组快照（rmcp-7 §3.2）；与 Forked 一样由原事务冻结，重读不查当前组回填。
建立方法返回 `{kind:"aux_terminal",terminal:AuxTerminal}` 或原 past_unavailable/protocol_error；上表 value 不直接裸传。
NN03/NN04 尚有 borrow 时不发可 finish 的成功终态，返回原 OpStatus(state=RETIRING)，同 operation 续调至完成。
这是 U0/U3 联合精确合同增量，须总审核对引用处，不改变旧步骤 ACK 或 Receipt.kind。

`RootKind="line"|"doc"|"index"|"memo"|"imports"|"current"|"pending"|"inflight"|"view"|"bootstrap"|"checkpoint_export"|"checkpoint_import"`。
`RootClassFact={kind:RootKind,removed:U,retained:U,unresolved:U}`（计登记引用，不计独占对象字节）。
`NativeReclaim={id:Id,retirement:Id,release_seq:U,instance:Id,backend_epoch:U,manager_epoch:U,
status:"closing"|"closed",roots:Array<RootClassFact>,blockers:Array<Id>,observation:Fact<Id>}`。
roots 每种 RootKind 恰一项；blockers 有界且超界不截为完整，改返回协议 capacity/保持 closing。
`NativeRetention={node:Id,scope:Id,line:Id,class:"mainline"|"exploration"|"transient",source:Id,environment:Id,
decision:Id,line_revision:U,release_seq:U,progress:"live"|"retiring"|"released"}` 是供 M4 保存的动作事实投影，
不传实际引用计数图；共享 node 可对应多条 owner 事实。root snapshot 只由 NR06 生成，Rust 不据这些历史事件维护第二热图。
InterruptReceipt 原生投影严格沿 rmcp-8 interrupted；task/attempt/reason 与输入核验由 M2 按原 binding 聚合，不再发一份相互可变的原生 record。

源码不放入 64KiB 元数据或 argv：driver 从 C-M4 读不可变 blob，用实例继承的受控 source 流。
`native.source.begin={source:Id,size:U,digest:Digest}`；`chunk={source:Id,offset:U,bytes:Base64}`；`finish={source:Id}`。
每块解码后 ≤8KiB、顺序 offset、总量等 size；begin 先获有限输入额度，finish 核 SHA-256 才发布 source ID。
Base64 使用 RFC4648 标准 alphabet `A–Z a–z 0–9 + /`、必要且精确的 `=` padding，拒空白、URL alphabet、非零 pad bits 与非规范重编码；
chunk 解码长度须 1..8192，空 source 使用 size=0 的 begin 后直接 finish，不发送空 chunk。
最近 chunk 重复只有完全同一 offset/字节才可确认；更旧返回 retired_chunk 且不声称验证其旧内容，gap/异内容拒绝并丢本次未发布 staging；已发布同身份返回原确认。
source stream 单独有界 FD/帧，不与取消 reader 共队列；该传输不授予执行许可。跨方法所用 source 必须先登记完毕。

#### 4.2.1 source 通道完整外壳与结果矩阵

source 有独立 reader/rpc_seq，frame 同 ND03；方法精确为 `source_begin|source_chunk|source_finish`。
四通道普通/control/source/view 的 rpc_seq 各自在实例握手后从1开始，每一个新发送帧严格 previous+1；0保留给本通道首次握手。
合法范围1..2^53−1沿U0 U；下一值会溢出时封该通道新派发，交M2受控结束实例，不wrap/复用0。
完整消费的业务重发使用新 rpc_seq、原 operation/source/view 幂等身份；未知原帧未排空不得以新seq在同通道重发。
receiver 每通道只收 exact-next，旧/跳号拒绝并隔离；response 必须逐字回显本次 header，不从 operation_seq 推 rpc_seq。
`NativeSourceRequest={header:EpochHeader,method:SourceMethod,args:SourceArgs}`，args 对应上文三动作（chunk 的 bytes 为规范 Base64）。
`NativeSourceReply={kind:"result",header:EpochHeader,result:SourceResult}|{kind:"protocol_error",header:EpochHeader,error:NativeProtocolError}`。
`SourceResult={kind:"begun",source:Id,next_offset:U}|{kind:"chunk_ack",source:Id,offset:U,end_offset:U,digest:Digest}
|{kind:"registered",source:Id,size:U,digest:Digest}|{kind:"retired_chunk",source:Id,next_offset:U}`。
begin 允许 begun/registered；chunk 允许 chunk_ack/retired_chunk；finish 只允许 registered；其它配对拒绝。
chunk_ack.digest 是该解码块 SHA-256，offset/end_offset 精确界；重复已完成 source 的 chunk 返回 retired_chunk，不伪造该历史块确认。
每通道一个在途请求、匹配 header 才清槽；坏帧隔离整个实例，不能因只是传源码而在损坏流继续。
begin size=0 合法；finish 未完整或摘要错返回 invalid_input/not_admitted（仅指 source 登记，已有其它 operation 不被撤销）。
容量不足返回 capacity/not_admitted；冲突同 source ID 返回 binding_conflict，不覆盖已发布 source；写失败的登记状态不能核明则 admission=unknown。
SourceResult 无 operation_seq，因为它只登记不可变材料；材料以 source/digest/size 唯一，旧已发布 source 不可变，内存回收后同 ID 重传须核同一 M4 绑定。

#### 4.2.2 状态与内存事实投影

`NativeStateObservation={proof:Id,instance:Id,backend_epoch:U,manager_epoch:U,node:Id,source:Id,prefix_end:U,
branch:Id,branch_step:U,environment:Id}`；proof/branch 为 M2/M4 已登记锚，node 为 NR02 实际分配，不从前者导出。
prefix_end 为该节点已成功精确字节前缀，branch_step 对应 M4 已确认步；pending 不能冒充此已确认观察。
此 root 是可持久历史事实，重启后 node 仍不可执行；公开 StateRef 由 M2 在当前有效绑定下签发。
`NativeMemoryObservation={instance:Id,backend_epoch:U,manager_epoch:U,observed_tick_ns:U,cost_ns:U,
gc_live_words:Fact<U>,word_bytes:U,roots:Array<RootClassFact>,coverage:"complete"|"partial"}`。
word_bytes 由实际 runtime word size/8，非猜8；GC 未实际执行/读不到为 unknown，不以 heap capacity 填 live_words。
根覆盖与 GC 活堆分别测，不能据一方补另一方；时间仅在同 backend epoch 的单调域比较。
OS RSS/核算域、M2 接收时刻/新鲜度、task/attempt/command/grant、总预算归 M2 的 MemoryObservation 组合，不在原生复制策略记录。

`NativeBoundaryFact={instance:Id,backend_epoch:U,manager_epoch:U,context:Id,source:Id,environment:Id,
target:Id,entry_node:Id,entry_offset:U,entry_command:ByteRange,replace_range:Fact<ByteRange>,origin:"native_parser"}`。
target 是 M2/M4 登记逻辑目标 ID（查找请求的 Target 是查询选择器，两者不混）；ByteRange 为 `{start:U,end:U}` UTF-8 字节半开区间。
NN01 只在官方 parser/toc/真实目标入口可确定时产本 fact；replace_range 无法确认则 unknown，不能凭文本 Qed/Defined 推末端。
entry_command 恰为建立目标入口那一条命令的 parser 消费范围，含实际消费空白/注释；后续每条命令边界唯一引用已存在 StepFact，
不在 BoundaryFact 复制整条历史数组；不得拼成其它 source 上的边界。
entry_node 为真实可恢复前驱；entry_offset 为该前驱消费终点；未知 target/范围不伪造零长 replace。
M4 PS19/SourceAnchor/SaveBinding 引用本 fact：identity 不插回，insert 使用已批准零长范围，replace 仅以 known native range 或独立明确 integrate 范围为依据。
位于 NN01 located/needs_prefix 与 NN03 source_synced 的 boundary 字段明确返回该 fact；尚未知道入口则 unknown，root目标不适用则 not_applicable。
完整替换 end 只在该 source 的旧目标结束边界实际已解析且目标对应关系可核时为 known；刚定位入口并不凭空知道后缀终点。
M4 replace 看到 unknown 必须请求当前源旧目标的有预算前缀核验或接受已有明确 integrate 范围，不能用 cursor/last_valid 代替 replace_end。

`NativeLineUpdateRef={view:NativeViewRef,digest:Digest,bytes:U}`，仅source_synced的内部UTF-8 metadata spool引用，不是actor OutputRef。
`NativeLineChange={line:Id,before_revision:U,after_revision:U,frontier:Fact<Id>,state:"open"|"retiring"|"closed"}`。
`NativeLineUpdateDocument={schema_version:1,operation:Id,instance:Id,backend_epoch:U,manager_epoch:U,context:Id,
old_source:Id,new_source:Id,before_context_revision:U,after_context_revision:U,lines:Array<NativeLineChange>}`。
lines恰覆盖该事务前context内全部已登记公开line（含本次关闭者），按line ID排序无重复；不遗漏“没改”的line，也不含隐藏ImportArena。
未改变路径/源使用资格/status的line可before=after；任何改变必须after=before+1且checked防溢出。open有known frontier，closed为not_applicable；retiring只报告实际已知/未知，不能假可执行。
文档由NN03实际GraphTxn生产，ref摘要/长度覆盖完整规范JSON；M2收到后经M6底层流捕获、PS02整材料与RC02固定typed解码，核header/operation/source/context版本/完整line集合后才交PS06更新映射。
view通路仍为原view_pull/ack/release，4..8192 UTF-8规则；不添加InspectKind、不伪装NativeFacts、不借checkpoint二进制用途。
此view的私有owner为`OperationMetadata{operation,kind:line_updates}`而非旧node borrow；与NodeView分支并列，避免NN03等自己排空的node引用而自锁。
finish/source失效不得在M2完整读取/PS06应用确认前丢这个spool；release经现view_release/受控清理，读丢/应用未知时M2封该context新派发，不自增猜native revision。

### 4.2.3 握手与原生预算登记

`NativeChannel="ordinary"|"control"|"source"|"view"`；`NativeCompatibility={major:U,contract_digest:Digest,capabilities:Array<String>}`，
其中major≥1且须落U0支持版本范围，不因U类型允许0而接受协议major=0。
三个字段语义与U0固定握手合同相同；capabilities发送时按UTF-8字节序输出且无重复，接收时只核无重复与该通道required包含，不因合法排列不同拒绝。capabilities来自实际编译且启用的handler集，不直接复制静态manifest全方法；完整required表唯一在rmcp-8 §3.7，基线handler仍须全量exact-set验收。
`NativeHello={kind:"hello",header:EpochHeader,channel:NativeChannel,nonce:Id,compatibility:NativeCompatibility,expected_artifact:Id}`。
`NativeHelloAck={kind:"hello_ack",header:EpochHeader,channel:NativeChannel,nonce:Id,compatibility:NativeCompatibility,
artifact:Id,rocq_version:String,ocaml_version:String,limits_backend:"control_interrupt"|"memprof_limits"}`。
每通道第一次消息只能 Hello 且 rpc_seq=0；Ack逐字段回显header/channel/nonce。握手重复/非0/串通道拒绝并隔离；
四通道全部完成才准入普通执行，之后各自从rpc_seq1按§4.2.1执行。握手错误用同header的protocol_error，不发送部分hello_ack。
driver的expected_artifact来自固定安装载荷验证；原生artifact来自编译制品标识、rocq/ocaml来自实际runtime、limits_backend来自实际启用Limits。
原生自报artifact不建立信任：ND01先核被exec文件/依赖载荷及域，再比较自报值，未知/不符拒绝；manager/backend epochs来自M2一次性启动绑定，不接受Hello换绑。

`NativeBootBinding={instance:Id,backend_epoch:U,manager_epoch:U,artifact:Id,environment:Id,clock_boot:Id,
platform:{system:String,architecture:String},channel_nonces:{ordinary:Id,control:Id,source:Id,view:Id},ordinary_operation_capacity:U,input_byte_quota:U,view_byte_quota:U}`。
platform由ND01当前主机`libc::uname`的sysname/machine生产，原生与Sys.os_type/word_size核运行形态；不取actor参数或安装清单里的期待值。
M2/ND01经自有继承启动FD发送一次、原生在进入请求loop前严格读取；FD只在exec子域继承，不接受actor路径或argv大文本。
clock_boot锚同主机boot；两端deadline统一Linux CLOCK_MONOTONIC微秒（向下取整），可共享数值但必须先核相同clock_boot，不能把另一boot记录当有效期限。
不用安全整数U装绝对纳秒（长uptime可超2^53−1）；微秒转换仍checked，越界拒启动而非截断。
启动配额全为已批准正有限值；此绑定不等于操作预算，缺绑定不启动handler。关闭启动FD后不可重写；接收第二份即协议错误。

`NativeBudget={budget:Id,operation:Id,operation_seq:U,scope:Id,source:Id,environment:Id,grant:Id,grant_revision:U,
clock_boot:Id,execution_deadline_us:U,recovery_deadline_us:U,output_deadline_us:U,output_bytes:U,
purpose:NativeExecutionPurpose,checkpoint_limits:Fact<CheckpointLimits>,initial_request:InitialRequestBinding}`。
`InitialRequestBinding={method:InitialNativeMethod,phase:Fact<"collect"|"encode">,digest:Digest}`；InitialNativeMethod精确复用rmcp-8的13个建立方法。
只有checkpoint_export的phase为known collect/encode，其余必须not_applicable，unknown拒绝；不新增通用描述符/任意方法字符串解释。
构造先分配不可变budget ID/operation ID/seq→对原建立请求按W02前像（排直接B.request_digest）算digest→同时填B.request_digest与budget.initial_request.digest。
请求只引用budget ID不含整个NativeBudget，故无自摘要环。NW02登记后原生所有预输入方法按该head判方法/phase/方向；正式establish必须与head的method/phase及W02摘要全部相等。
`NativeExecutionPurpose={kind:"task"}|{kind:"checkpoint_control",control:Id,operation:"export"|"import",attempt:Id}`；
`CheckpointLimits={bundle_bytes:U,metadata_bytes:U,root_count:U}`，三者正有限且由M2已预留额度派生；task的checkpoint_limits=not_applicable，checkpoint必须known。
用途逐方法核：task不许checkpoint_observe/export/import/activate；export票的业务方法只许checkpoint_observe或checkpoint_export；import票的业务方法只许checkpoint_observe/checkpoint_import/checkpoint_activate，
同purpose不能替代每个新业务operation自己的budget ID/operation_seq。两种checkpoint票都不能begin_line/pull_step/query/inspect或其它普通Rocq执行。
status/ACK/finish/retire及所属blob传输只对账，不获得新的Rocq执行权。
唯一生命周期例外为initial_request.method=end_scope（phase=N/A，新operation）：import只可关闭本control/attempt登记的新import scope/arena；
export只可在M2确认该native scope所有将撤主线都已PS27封存且无其它合法owner后关闭原scope。不得为清理伪造task预算。
未封存export失败/取消只走本地NC11→NC09清临时资源，绝不借end_scope撤原热owner；N05经NR04/NC09处理checkpoint根而不执行新的导出/装载/tactic。
期限由M2已受理attempt总预算派生，不能因每pull重新计算；无输出操作output_bytes=0，不能因此无限输出。
`NativeBudgetRequest={header:EpochHeader,method:"register_budget",args:{budget:NativeBudget,applied_grant:Id}}`；
`NativeBudgetResult={kind:"budget_registered",budget:Id,grant:Id,grant_revision:U}|{kind:"past_unavailable",operation_seq:U,highest_seen:U}`；
回复沿普通 result/protocol_error 外壳，成功kind仅budget_registered，past_unavailable不表示已登记预算。
applied_grant是ND04已核实际生效的回执ID，可信driver登记；Pet不伪装自行证明OS限额，只核启动身份与绑定，并在每步核deadline/预算ID。
此administrative方法不解释Rocq、不消费业务operation_seq；budget ID不可改内容，重复完整相同幂等、异内容binding_conflict。
原生budget表容量绑定 ordinary_operation_capacity 加已保留生命周期槽；满则capacity，不淘汰活预算。预算与operation一一绑定，begin/query等前必须已有登记，
原生比较B.budget以及operation/scope/source/env/purpose，任何不符拒绝。finish/retire后撤执行预算引用；§9的artifact/arena未核释放仍按独立保留引用占账，不随回执退役归还。
过期budget不可重新登记用于新operation，旧ID仅报past_unavailable。
budget tombstone不另建无界表：保其对应operation_seq的既有highest_seen/retired_through；登记时也带本driver已分配但未消费的next operation身份，
下一个建立请求必须用该身份，否则拒绝；只有该next槽或已存在operation可登记，不能预填任意ID积压。deadline到期只封新执行，pending ACK/finish仍可对账。

### 4.3 查询 AST 精确白名单（Rocq 9.0）

只读核对接口：`/home/ubuntu/.opam/rocq90/lib/rocq-runtime/vernac/vernacexpr.mli:32–102,403–407,488–495,524–545`，
`interp/constrexpr.mli:137–208`；固定 fork `serlib_v9.0/ser_vernacexpr.ml` 以 `%import` 引用该 ABI。
编译时模式匹配绑定实际构造器，升级编译须重新审表，不从序列化字符串名猜 AST。

外层 `CAst.v.control=[] ∧ attrs=[]` 才进入 expr 分类。所有 ControlTime/Instructions/Profile/Redirect/Timeout/Fail/Succeed、所有 attributes 一律拒绝；
这排除文件重定向、嵌套控制及其它偷偷执行包装，不用“剥 wrapper 后继续”规则。

| 精确 expr | 附加条件 / 行为 |
|---|---|
| `VernacSynPure (VernacCheckMayEval (red, goal, term))` | term 经 NB07；None=Check，Some reduction 经下列完整内建 reduction 表，保 Eval/Compute；goal 由真实当前证明解释 |
| `VernacSynPure (VernacGlobalCheck term)` | term 经 NB07，无状态发布 |
| `VernacSynPure (VernacPrint p)` | p 仅下列封闭集合 |
| `VernacSynPure (VernacLocate p)` | p 仅 LocateAny/LocateTerm/LocateLibrary/LocateModule；LocateOther 扩展与 LocateFile 拒绝 |
| `VernacSynPure (VernacSearch (q, goal, restriction))` | q 仅 SearchPattern/SearchRewrite/Search；全部 pattern 用 NB07；SearchLiteral/SearchDisjConj 递归有限遍历；search_item 仅 SearchSubPattern/SearchString/SearchKind |
| `VernacSynterp (VernacSetOption (false, key, setting))` | key 恰在下面4项，setting 为 OptionSetTrue/OptionUnset；只通过本地打印选项适配，不泛调任意选项命令 |

printable 允许集合：PrintTypingFlags、PrintTables、PrintFullContext、PrintSectionContext、PrintInspect、PrintGrammar、PrintCustomGrammar、PrintKeywords、
PrintLoadPath、PrintLibraries、PrintModule、PrintModuleType、PrintNamespace、PrintMLLoadPath、PrintMLModules、PrintName、PrintGraph、PrintClasses、PrintTypeclasses、
PrintInstances、PrintCoercions、PrintCoercionPaths、PrintCanonicalConversions、PrintHint、PrintHintGoal、PrintHintDbName、PrintHintDb、PrintScopes、PrintScope、
PrintVisibility、PrintAbout、PrintImplicit、PrintAssumptions、PrintStrategy、PrintRegistered、PrintRegisteredSchemes、PrintNotation；
另允许 `PrintUniverses {sort;subgraph;with_sources;file=None}`，file=Some 拒绝；PrintDebugGC 拒绝，不把 GC 当普通查询副作用。
About 在真实 AST 为 PrintAbout，不发明 VernacAbout 构造器。其它任意未列 printable/vernac 直接拒绝。

本版临时打印选项 key exact-set：`["Printing";"All"]`、`["Printing";"Universes"]`、`["Printing";"Implicit"]`、`["Printing";"Coercions"]`。
先通过当前 Goptions 表核存在且布尔类型，保存各自原值；执行阶段只写这四个已登记选项，查询批次结束/异常恢复原值，失败隔离。
不存在/类型不符拒整个批次；不因以 Printing 开头而开放任意插件注册选项，不接受 Export modifier/OptionSetInt/String。
这是公开 query 的首版支持边界：未知语法、嵌入 tactic/泛型扩展、未列打印选项返回 INVALID_INPUT，不悄悄改命令。
用户已明确接受上述首版query边界；原确认记录见[过程记录归档](../legacy-entry-guidance.archive.md)所指版本的§0.3，该语义delta不再待决。
这不是旧自由 query 语法完全兼容的声明，也不代替实现后的正例/拒绝反例与预算验收。

term whitelist 见 NB07：允许通常显式项结构，拒 CGenarg/CGenargGlob；CNotation 及 qualid-or-by-notation 必须先核所引用的已登记解释模板及实际替换项均不含泛型执行。
不把“含 notation”整体等同拒绝；库中已登记纯记号可查，未知扩展返回 INVALID_INPUT。

内建 reduction 构造器依据 `rocq-runtime/tactics/genredexpr.mli:45–74`：Red/Hnf/Simpl/Cbv/Cbn/Lazy/Unfold/Fold/Pattern/CbvVm/CbvNative；
其中 flags.rConst、Unfold 的引用、red_context 的 term/pattern 均按 NB07/相同 notation 解析核验；Fold/Pattern 的 term 递归核验；
`ExtraRedExpr name` 拒绝，不能将任意注册插件 reduction 当内建。允许 Norm/Head 与 bool flags，occurrence 参数依官方类型检查，不代造语义。
Compute/Eval 不被删除；重计算同样用执行预算、新 Token、临时 state、生成配额和完整根清理，不以“查询”免预算。
“只读”指不改变公开 proof line/源/环境，不承诺计算无内部缓存分配或内建 native evaluation 无临时编译；
CbvNative 的内部子进程/临时目录须属于实例执行域及私有 scratch，越受管边界或无法核完结则 unknown/隔离，而非假恢复成功。
PrintUniverses 的显式文件输出与 ControlRedirect 仍拒绝，二者不是必要的计算临时工件。

## 5. 函数级细化

通用前提 P：严格解码/实例 epochs 已核、M2 ticket 与 M4 durable intent 存在、预算在同实例已生效。
P 不由 Pet 自证 FSM 权限；driver 核 ticket，原生再核投影的 source/env/revision/budget 绑定。
每函数以下失败分支均保可知事实；未列循环的函数仅有限字段检查/有限映射操作，无隐式重试。

### ND01 `spawn_bound(plan: SpawnPlan) -> Result<Driver, SpawnFailure>`

pre：C-M2 固定制品/域身份/环境和已预留额度；callee C-OS、C-CODEC。
Rust侧plan引用M2 BackendInstanceRecord.owner_authority：work沿原真实WorkGrant；checkpoint_control沿§9用途；
control_replay只接受`{task,control}`指向同TaskAuthorization.control_replay的真实管理control，由MS08核PS33/PS15/PS04已提交的唯一Task/attempt及当前管理权。
不把该Id塞进WorkGrant、不由主请求者工作区猜child执行域；新实例取授权固定scope/workspace的实际域。此分支只改变Rust准入，NativeBootBinding/握手不增加策略字段。
顺序：校 plan 与制品 → 建自有普通/control/source/output 管道（其余 FD close-on-exec）→ exec 前入域/限额 → 启动固定 argv → 限时握手核实际能力/版本/epochs。
失败分支：预检失败不 spawn；建管失败关已建 FD；exec/握手/能力失败调用 ND05，域未知保账；成功才交 ready Driver。
post：唯一拥有者及实际兼容实例，或明确未创建/已停止/未知；不自动再启动。有限阶段，各 IO 用剩余绝对期限。
论证：ready 发布晚于隔离与握手，部分初始化不能被 M2 派发；副作用仅本域/管道。
ND01保留下面ND07所述实际启动文件核验及exec/start事实；缺此完整事实不伪填，可正常报告身份不足，但不得由IR20签发checkpoint兼容绑定。

### ND07 `Driver::actual_exec_identity(&self) -> Result<&DriverExecIdentity, IdentityUnavailable>`

Rust-only只读accessor，供IR20调用，不新增wire/服务。`ActualExecFile={canonical_path:String,sha256:Digest,size:U}`；
`DriverExecIdentity={instance:Id,backend_epoch:U,manager_epoch:U,domain:DomainIdentityRef,exec_receipt:Id,
pet_file:ActualExecFile,exec_image:ActualExecFile,mode:"native"|"bytecode"}`。
DomainIdentityRef只引用本Driver已核C-OS进程域/boot/start事实，不暴露FD整数；exec_receipt由ND01实际启动观测生产，不是HelloAck或actor自报。
native模式pet_file与exec_image为同实际可执行文件；bytecode模式pet_file为已核真实bytecode程序，exec_image为实际解释器runtime，IR20分别接载荷记录。
ND01在启动前持有受控文件身份/哈希核验，在启动后将实际进程start/exec映像观察（Linux由自有子进程/proc身份核）与所启动argv/载荷关联；
任何读失败/不一致不生成snapshot；不拿当前同名路径哈希代替已加载事实，不用peer自报artifact补缺。受管安装不可变前提沿IR13，非同用户攻击OS沙箱。
getter先核Driver仍是所请求的当前实例且健康、snapshot与DomainIdentity/epochs相同，完整则借用原不可变snapshot；缺失/退出/隔离/错代返回IdentityUnavailable。
没有IO/重hash/循环/新权限；论证返回事实唯一来自ND01而非期望配置，生命周期由Driver借用约束，IR20仍另核IR13/IR07的安装与smoke，不把getter当授权。

### ND02 `exchange(driver, request, ticket: DispatchTicket?, deadline) -> TransportFact`

pre：driver HEALTHY、普通在途槽空；新执行有 C-M2 ticket，ACK/status/finish 按 rmcp-7 不要求继续执行票；callee C-CODEC、ND03。
新执行ticket的授权只取本Task真实TaskAuthorization；ordinary默认要求不变。control_replay先经§10 ND08核MS08/MS09最新发票与固定计划/实际child域，
不能沿首次spawn的BackendAuthority永久执行或把早先通过的票缓存到下一pull；未知/撤权/输入或代际变化封新发送，已发操作仍走原停止/对账。
核方法及 ticket → 在写第一字节前登记 expected/rpc_seq → 写完整帧 → 唯一 reader 读完整回复 → W01/W03 → typed 返回。
写前拒绝 not_started；部分写/读取超时保原 inflight，由 reader 在原排空期限继续；调用者 Future 取消不清槽。
完整迟到回复关联原调用；坏帧/错关联/EOF 调 ND06，不能发下一请求。完整消费且验证后清槽；不自动重复 eval。
post：可信匹配响应或明确传输范围；副作用仅一次发送及关联事实。读写循环剩余字节递减，期限到进入隔离/停止而非永久等待。
论证：登记先于发送且槽不因上层退出复用，迟到包不可能认成下一操作。

### ND03 `drain_frame(fd, expected, cap, deadline) -> Result<Frame, WireFault>`

pre：唯一该 FD reader；callee 精确 read、C-CODEC。
累计读恰4字节大端长度 → 核 1..65536 → 再分配/读恰 length → UTF-8/严格 JSON/root/关联校验。
前缀 EOF、半帧、超长、未知字段、重复键、错 header 均 fault；不跳花括号重同步，不先取成功子字段。
循环 invariant 为 buffer 等于本帧已消费前缀、读量≤bound；剩余递减或 deadline 退出；完整包才 post Frame。
论证：长度先于分配，唯一 reader 保 frame 边界；stderr 独立排空，绝不参与 parser。

### ND04 `apply_limits(driver, grant: MemoryGrant) -> Applied | Unknown | Rejected`

pre：M2 已原子预留本域新 revision，降配有当前占用/安全余量事实；callee C-OS 实际限额写/读回。
control_replay仍须MemoryGrant.operation=task且task/attempt与MS08票相同；BackendAuthority为control_replay不把额度改成checkpoint_control，
也不授予它所引用Task之外的命令。ordinary work与checkpoint用途既有规则保持，限额应用成功本身不证明受限计划授权仍有效。
核域/旧 revision → 写 cgroup/watchdog 同一目标 → 读回全部约束并核实际模式 → 记录 applied；任何一环未知不派发新负载且不归还额度。
同 revision 相同值重读确认；异内容拒绝；更旧 ACK 不能覆盖新 revision；降配低于占用直接拒绝。
post：全部实际限制一致或未知/拒绝，无隐藏旧16GiB限制；有限约束表逐项检查，失败不猜回滚。
论证：读取实际配置闭合了“获准”和“生效”的差距，策略/额度只归 M2。

### ND05 `stop_domain(identity, authorized_reason, deadline) -> StopFacts`

pre：M2 授权且自有域身份；callee C-OS 身份核验、TERM/KILL/wait/域枚举。
核已经空则 stopped；否则 TERM → 至多2s且不超剩余期限 → 仍活 KILL → 在总10s候选上界内核全部域空。
身份冲突不误杀他域，返回 unknown；读失败、后代存活、超期均 unknown。父 PID 退出不跳过域检查。
post：真实停稳或 unknown，永不自主 spawn；有限阶段/绝对期限，未核停资源仍占账。
论证：进程身份排除 PID 复用，域空排除只杀父进程；关 FD/Drop 不参与 stopped 判据。

### ND06 `quarantine(driver, fault) -> QuarantineFact`

先原子封新发送/标 QUARANTINED、保原 inflight/已消费字节事实，再通知 M2；保持 control reader 供核停。
通知失败仍隔离，记录本地故障，不自主恢复；有限操作。post 不再执行普通方法；论证：隔离先于通知，不依赖 Manager 响应关闭危险窗口。

### NW01 `handshake_channel(boot, channel, hello) -> HelloAck | ProtocolError`

pre：一次性NativeBootBinding已从自有FD读完、该channel尚未握手；callee OC03/OC06/OC07、编入协议常量及实际runtime version/limits读取。
核header instance/epochs/rpc_seq0、channel/nonce与boot对应→核peer compatibility/expected_artifact→从实际handler装配本端兼容性→形成HelloAck→标channel完成。
缺字段/身份/nonce/版本/制品/能力不符均拒绝并隔离，不启动Rocq执行；发送ACK失败完成事实可能已发生，禁止在同channel重新Hello，交ND01核停。
四个有限channel逐一握手并受同启动deadline，任何失败不发布ready；成功后seq起点1。论证：绑定来自exec前受控配置，Hello不能伪造新实例身份。

### NW02 `register_budget(boot, operations, request) -> BudgetResult | ProtocolError`

pre：普通通道握手完成，driver已取得C-M2 ticket并完成ND04；callee OC03、原生有限operation/budget表、单调时钟。
核epochs/clock_boot→核预算字段/期限尚有效→核operation_seq为next未消费槽或已有精确operation→核budget/grant绑定→原子登记immutable预算。
在登记前同时核initial_request.method/phase的封闭配对和purpose允许表；后续NC04的提前材料输入直接使用此已登记head，不靠尚未到达的establish RPC猜操作种类。
同ID同内容返回原确认；异内容拒绝；已退役seq返回past_unavailable；gap/容量/错scope/source/env拒绝，不eval/不扩大额度。
新的next槽登记尚未创建业务operation，下一建立请求消费对应seq并核同identity；建立失败后该seq已消费，按旧operation回执规则清理预算，不得卡死next槽。
Rust只在完整匹配budget_registered后派发begin/query/locate；发送后未知先按同身份对账，不直接假定预算生效；OS applied未知不调用此函数。
post允许执行的budget是可信driver已登记的不可变投影，不能由B.budget裸ID临时造出来；有限字段/表操作无循环等待，失败保原操作/资源账。
论证：预算登记先于Rocq入口，ID、operation_seq与不可变输入一起核，不能用新RPC刷新deadline；ACK对账不需要该预算仍允许执行。

### NR01 `borrow(registry, owner, node, expected) -> Result<Borrow>`

pre：执行线程；callee Registry lookup。校实例/context/env/source/line revision、scope OPEN 与 node 属有效路径，再创建唯一 borrow 并登记。
缺失/过期/关闭拒绝且无引用；分配失败不返回半 lease；成功只借本节点及祖先，不能凭 state hash 命中他源。
post：borrow 存续期间对应根不会释放；论证：验证与登记同串行边界，reclaim 见到真实借用。

### NR02 `prepare_commit(registry, mutation) -> Result<GraphTxn>` / `publish(txn) -> GraphResult`

mutation 封闭为 pending/ACK/select/fork/source-invalid/close/checkpoint_activate；pre 为相应 rmcp-7/NN 方法已校版本。
`GraphResult`为按mutation固定的内部联合：pending→StepFact、ACK→AckStatus、select/close→Receipt、fork/source-invalid→对应AuxValue、
checkpoint_activate→稳定AuxTerminal（包含checkpoint_activated），不得把它强塞旧Receipt.kind；caller只能取其mutation允许分支。
checkpoint_activate携arena ID、CheckpointActivationPermit、原import key与mapping ArtifactRef；额外pre为arena=PREPARED、permit完整匹配当前scope/control/attempt/cache/newinstance，
原import mapping exact且新nodes/lines/context全在该arena、未出现在公开owner表，无异主冲突；当前Manager仍暂停，不能以本事务解除pause。
先枚举本次受影响 line/doc/index/borrow，算新 immutable maps/frontiers/稳定 receipt；检查保护根和预期 revision 后一次替换 registry root。
准备失败不改公开图；发布前不得执行不可回滚 cache/current 切换；发布后故障只报告 applied/unknown，不恢复旧采用路径假装未执行。
ACK 必须已持久；pending 仅受操作根保护；select/首个 replace ACK 才撤旧后缀 owner。
checkpoint_activate的prepared successor同时包含全部新公开node/line/context索引、checkpoint_import owner向当前scope owner转移、arena=ACTIVATED以及稳定activation回执；
唯一registry root替换点同时发布这四者，禁止逐line开放。准备失败保PREPARED无公开节点；发布后异常按applied/unknown对账，不把已应用事实伪回滚。
该变体不eval、不重建Coq.State，也不撤任何旧实例/其它scope的owner；仍由PS31另核当前性后开放派发。
有限受影响集合遍历，invariant 为尚未发布图仍完整、保留 owner 的闭包不缩小；所有节点 parent DAG 先验成立。
post：一个合法新图和稳定回执或原图；论证：唯一发布点使 revision/采用路径/退役动作一致，内存不足不能产生半 line。

### NR03 `release_borrow(registry, borrow_id) -> Released | AlreadyReleased | Unknown`

pre：原 owner 已停止使用；查 exact id，存在则从借用表移除并置本地 option None；已结束幂等返回；无法核 owner 完成返回 unknown。
不顺带释放其它 line；无循环。论证：只有真实完成方撤借用，取消受理不是完成；后续 NR04 才判最终根。

### NR04 `reclaim(registry, retirement) -> ReclaimReceipt`

pre：M2 退役决定已登记，NR02 已撤新使用资格；callee NR03、NB04、各 RootInventory adapter。
1. 核操作/retirement/epochs；重复返回同一已完成事实，未完成继续本轮状态。
2. 存在 pending/inflight/view borrow 则返回 closing 和精确 blocker，不强删、不等待同 loop ACK。
3. 从所有有效 line/frontier 和其它 owner 保留根取祖先闭包；只删除退役 owner 对各容器的引用。
4. 重建 doc.nodes/toc/prev 投影与 ID index，清退役作用域闭包；清 Init/Interp/Require/Admit/Intern 的可重算缓存。
   首版允许在安全边界全清这些辅助缓存（所有有效历史由 line/node 保留，不依赖 memo 才可热恢复）。
5. 若 current 指退役路径则 NB04 恢复一个仍合法根或 bootstrap 中性 state，再丢原 current/local 临时强引用。
6. 各 adapter 都完成才 closed；任何失败 poison/closing，未知仍计费。可选 GC 只在操作后且受预算，回执区分根撤销、GC live heap、RSS。
循环：有限 root adapters 和有限节点 worklist，visited 去重，每次消费未访节点；闭包只沿 parent，禁止环，故终止。
论证：其它 owner 祖先先受保护，删除仅本方根；current/doc/memo/inflight 都是实际容器而非统计表，故不因索引删空误报无根。
不声称能控制任意插件私存全局对象；未知插件持根在内存观察中披露，不能报整个 Rocq heap 不可达。

### NR05 `prefix_anchor(old, new_source, boundary_index) -> PrefixDecision`

pre：同 environment/logical file，new source 已核长度/摘要；callee byte compare、官方 parser 产生的 SourceSpan。
求字节 LCP，遍历已有边界按执行顺序保留最后满足 start/end/read-horizon 全在未变范围且 EOF 依赖仍一致的节点。
零相同前缀返回 root；全文相同可保全部；更短文本拒保越界；UTF-8/UTF-16位置只作定位，不作为相等判据。
若某 parser 接缝不能报告保守 read horizon，则该句不可作为跨版本复用边界，退到最近有证明的前驱；不得猜 AST end 就足够。
post：返回边界实际解释输入和解析依赖不变；有限字节+节点遍历，循环 invariant 为候选已验证完整前缀。
论证：输入字节、祖先环境和 lexer lookahead 均相同，才能沿原解释链复用；新版本建立 anchor alias，旧 source ID 不伪改为新事实。

### NR06 `root_audit(registry) -> RootObservation`

pre：安全串行点、有限诊断预算；遍历 adapter 列 root class/owner/状态及未决引用，交叉核 line/node/borrow 存在性。
预算超期给 partial/unknown，禁止补零；不在控制 reader 跑 GC 或扫描堆。post 是有时间/coverage 的观察，不是 RSS 所有权分摊。
循环为 adapter/登记容器有限项且受 deadline；论证：生产容器自身枚举避免维护一个看似完整但漏真正根的镜像计数。

### NB01 `parse_one(parent, source, cursor, token) -> Parsed | Eof | ParseError`

pre：NR01 借用、父环境已恢复、cursor 位于前次真实边界；callee C-PARSE/官方 Contents。
建立源切片对应的官方 parsable（保绝对 origin，调用 NB08）→恢复父 parsing state→只 parse 一句；返回 AST、消费 cursor、词法读取 high-water/EOF 观察。
EOF 不造节点；parse error 记录诊断/真实范围；成功必须 cursor 前进且范围落在 source 内，否则 poison。
不能在 Rust 以点号/正则分句；不复用 Doc.check 的自动多句循环。lex stream 循环由有限源/Token/期限保护。
论证：句界和语法扩展来自父 parsing state，同一接缝用于文档与交互，精确字节供 M4 持久。

### NB02 `eval_one(parent, parsed, token) -> EvalFact`

pre：借用、NN/RM 步骤已核、无其它 Rocq 调用；callee C-STATE、C-TOKEN、Protect/eval、NR02。
恢复父 → 安装新 token → 解释恰一 AST → 捕获真实 state/最小反馈 → NR02 pending → 返回 WAIT_ACK。
失败/中断恢复合法前驱，保真实错误/副作用 unknown；解释成功后登记失败为 unknown，不能称 not_started。
finally 清 token/局部借用只覆盖正常控制流，不覆盖 KILL；不打印全目标作为成功前置。
无批次循环；tactic 终止只依赖受控中断/进程兜底。论证：成功节点先于回包、ACK 才正式采用，部分批次不丢已确认前沿。

### NB03 `render_chunk(view, selector, credit, token) -> ChunkFact`

pre：C-M6 有效 typed selector、NR01 view borrow、NB06 已封存的有界 spool、有限 credit/输出 deadline；callee 有界 spool read/SHA-256。
核 selector/view/operation/seq/offset → 未 ACK 同请求返回唯一原 pending 块；异内容拒绝；已 ACK 旧 seq 返回 retired、不重打印。
新 seq 先核 credit=4..8192（1..3 在读取前拒绝），从 spool 读至多 credit 字节，取最大完整 UTF-8 标量前缀；非 EOF 不得空；登记 pending 块后回包。
ACK 处理核 seq/end_offset/digest，只有 M6 持久确认后推进 cursor，保最近 ACK 重复确认；错 ACK 不推进，旧 ACK 只报 retired。
release 先封新 pull，有 pending ACK 未核清则 closing；完成后丢 spool/借用才 released，清理失败仍占额度。
原始生成失败的 spool 可有完整捕获前缀，但 end 只表生成端已结束，capture 不能伪为 complete。
循环受有限 spool/byte quota/deadline；论证：无 Rocq 调用、无 printer 重放，丢 ACK 不导致重复查询或字符漂移。

### NB06 `generate_view(node, selector, quota, token) -> ViewDescriptor | ViewFailure`

pre：NR01 borrow、C-M6 精确 selector、已授予正有限生成字节/磁盘/内存/时间预算；callee C-M6 typed query/printer、C-TOKEN、NB04。
在实例私有目录建立新 spool → 核源/node/恢复父 → 仅生成选择 part，以增量 bounded writer 接收有效 UTF-8 并同步计数/摘要 → 封存 spool → 返回 descriptor。
不得先 `Pp.string_of_ppcmds` 构造完整任意长 string 再分块；printer 内部 term/Pp 峰值仍受实际资源治理，不声称磁盘 sink 消除这些成本。
写满/超期/中断/sink失败停止生成，保实际前缀和 capture 原因；恢复原 state/打印选项失败 poison。初始化失败不返回可读 view。
生成期控制通道独立，不等待同普通 loop 的下一 pull/ACK；首块等待本 part 生成结束，这是首版明确延迟，不伪称 Format 有可暂停 continuation。
descriptor 引用已封存 spool，其生命周期归 view borrow，ACK 不等于 release。typed facts 父 document 与子 part 分别用同一总 quota，不通过拆子流扩大额度。
有限 writer 总量/deadline 为终止界，Rocq 内部不可恢复阻塞交 M2 核停；论证：生成端先实施额度，NB03 仅读有界材料，避免同 loop 等 ACK 的死锁。

### NB07 `classify_query(parent, asts, limits) -> QueryPlan | Rejected`

pre：NB01 已把整个请求解析成有限 AST 列表，未 eval，父 source/env 未变；callee §4.3、Notation.interp_notation、Goptions 只读查询。
顺序为检查全部外层 control/attrs→穷尽匹配 §4.3 顶层构造器→遍历各嵌套 reduction/term/notation→核打印选项 exact-set/类型→返回不可变 QueryPlan。
任一失败拒整批、不执行部分命令；allocation/期限失败同样没有查询执行。空 AST 可返回空计划/空输出，不伪造 proof node。
term 允许构造器为 CRef/CFix/CCoFix/CProdN/CLambdaN/CLetIn/CAppExpl/CApp/CProj/CRecord/CCases/CLetTuple/CIf/CHole/CPatVar/CEvar/CSort/CCast/CNotation/CGeneralization/CPrim/CDelimiters/CArray；
CGenarg/CGenargGlob 一律拒绝。所有 term 子字段递归，binders 三分支 CLocalAssum/CLocalDef/CLocalPattern 均递归；
fixpoint order CStructRec/CWfRec/CMeasureRec 的 term 也检查，pattern CPatAlias/CPatCstr/CPatAtom/CPatOr/CPatNotation/CPatPrim/CPatRecord/CPatDelimiters/CPatCast 的子项同样覆盖。
CHole 仅保官方占位语义，泛型执行不通过“hole”替身放行；后续类型类/标准 elaboration 属受预算临时计算，不发布产生的 evar/state。
对 CNotation/CPatNotation/引用 by-notation，以当前父 parsing scope、delimiter 和官方 Notation.interp_notation 找到实际 interpretation，
遍历其 `notation_constr`：NRef/NVar/NApp/NProj/NHole/NList/NLambda/NProd/NBinderList/NLetIn/NCases/NLetTuple/NIf/NRec/NSort/NCast/NInt/NFloat/NString/NArray 允许并检查全部子项；NGenarg 拒绝。
实际 substitution 的四组 term/recursive term/binder pattern/binder lists 都递归核，不只检查模板；scope 不可解析则拒绝，不猜全局同名解释。
该检查使用官方解释模板，不自行执行模板展开/解析器；primitive numeral/string 的既有解释属于固定环境中的受预算 elaboration，不声称可防已加载可信插件的任意 OS 副作用。
loop invariant：已访问节点均属于封闭构造器集合，全部引用模板属于当前环境，尚无 query eval；worklist 有输入节点/深度/模板展开预算，visited 模板身份避免重复，超界拒绝。
QueryPlan 保存精确 AST、resolved-template 身份、打印选项旧值与待设置值；执行前再次核父环境，成功/失败都 NB04 恢复 state/options，不把计划变成永久语法缓存。
论证：从外到内完整分类阻止合法 Check 外壳夹泛型 tactic、合法 Print 夹 file 输出与 wrapper 重定向；所有允许查询临时执行，无 line 发布；
外部受信插件的运行时行为仍沿架构信任边界，不把 AST 白名单宣传成 OS 沙箱。

### NB08 `tracked_parsable(source, cursor, origin) -> {parsable; tracker}`

新增 fork `Coq.Parsing.Tracked` 接口：`make : raw:string -> cursor:int -> loc:Loc.t -> t`；
`parsable : t -> Coq.Parsing.Parsable.t`；`observation : t -> { supplied_end:int; saw_eof:bool }`。
复用实际 `Gramlib.Stream.from : ?offset:int -> ('e -> 'a option) -> ('e,'a) t`（Rocq9 `gramlib/stream.mli:27–34`），
不依赖 Stream.count（它只数已丢弃项，不包含 lexer lookahead）。make 核 cursor/raw/origin 后以 from ~offset:cursor 包装 source 的字符供应闭包。
闭包每次：i<len 返回 raw[i]，先 i←i+1/supplied_end←i；i=len 返回 None 并 saw_eof←true；越界为内部错误，不返回造出的字符。
此 tracker 包住 lexer 唯一字节来源，lexer 的 peek/cache/prefetch 都在实际字符供应时被记录；每次句级 parse 使用新 parsable，
不复用跨句 lexer 缓存以漏掉上次 read-ahead，上一句 observation 在 parser 返回时冻结并与该 node 同存。
source 字符供应上限 len-cursor，EOF 不推进；解析返回后 bounded 读取 observation 无副作用。cursor/AST loc 仍由官方 parser 决定，supplied_end 只保守依赖上界。
post 返回准确覆盖所有已提供字节/EOF观察的 tracker；论证：每个输入字节只能经该闭包进入 lexer，高水位包含预读，即使过保守也不会保留失效状态。
NR05 要求 old[0:supplied_end]=new[0:supplied_end]，saw_eof 时再要求 new 长度=old长度；无 need-to-change Rocq 内核，接缝局限维护 fork 的 coq/parsing.{ml,mli}。

### NB04 `restore_state(registry, target, token) -> Restored | Unknown`

pre：无线程仍在 eval、target 属合法保护根或 bootstrap；callee Vernacstate 恢复/Protect/C-TOKEN。
核来源 → 安装目标 → 丢旧 current 引用 → 进行 rmcp-7 N07 所需有界实际恢复核验；已有终态不得重复核验。
异常/未知副作用保 unknown/poison；成功只证明本次状态可用，不重做原命令，不仅比较 hash。
有限固定恢复步骤，核验受独立预算。论证：恢复晚于执行停稳且旧 token 代际失效，取消不会串到下一操作。

### NB05 `ingest_source(stream, begin_or_chunk_or_finish, reservation) -> SourceTransferFact`

pre：实例认证 source 通道、M2 有限输入额度、M4 PS17 VerifiedByteStream；callee bounded IO、标准 Base64/SHA-256、C-CODEC。
rmcp13 import预登记分支还核当前唯一import-upload预算槽及其SourceAllowlist（§9.4由完整已验manifest.source_descriptors建立）；
source/size/digest必须逐项匹配，全部登记前不开始NC06。普通source注册不能借此预留槽改输入身份或获得checkpoint执行权限。
begin 核 source/size/digest 与 reservation，存在完整同身份只读确认，冲突拒绝；新建私有 staging，分配失败不发布。
chunk 先核帧/解码大小、当前 offset 及总 size；当前 offset 正常写并更新增量 hash/offset；最近同 offset 同字节只确认、不再写；
其它旧 offset 返回 retired_chunk（不验证旧内容），gap/冲突终止 staging，driver 不自动重传整个 source。
finish 只在 offset=size 且摘要相符时原子登记 source；不符删除本次 staging 并报错误；已完整重复 finish 幂等。
读写失败/取消/超期保 source 未发布或已发布的真实事实；清理失败占输入额度、不允许该 staging 被执行引用。
loop invariant 为 staging 恰为已接收前缀且 offset≤size；每正常 chunk offset 严格增加，重发受同绝对 deadline/有限重试额度约束。
post 完整 SourceRef 字节或无可执行 source；论证 hash/长度核在登记之前，路径/半帧/局部内容均无法成为已登记输入。

### NN01 `locate_context(binding, file, relative_file, target, logical_target, lineage, expected) -> LocateResult`

pre P；callee NR01、NB01 位置/目标索引、NR02。
`logical_target` 是 MS27 登记的逻辑目标 ID，和 `target` 选择器、`file` 及 `context` 保持各自的语义；纳入 W02 原操作摘要。
`relative_file:RelPath` 必填，由 Manager 从同一次 AF/PS03/PS25 已确认文件源投影；与 `file` 的不透明 ID 各司其职，也纳入 W02。只与 ND01 受信工作区组合为真实 file URI 供 Rocq 初始化；解析已上传的原 `binding.source` 字节，不重读正式 `.v`。若同文件 ID 已绑定不同路径，或工作区/环境有变，拒绝建立/复用。
精确 key=(实例,物理 workspace/file identity,env,source,target identity) 查上下文；已有核 revision 并查真正句界/theorem toc。
若lineage=known，再核该实际NativeLineVersion在当前context中且目标一致；若not_applicable，候选恰一条才可定位，0条可新建/needs_prefix，多条拒歧义。
命中返回同 node/line，不 eval、不新增永久 doc；未到目标返回 needs_prefix/最近有效前驱，由 driver 用 rmcp-7 D01 恢复逐句并每步 durable ACK，再定位。
中途目标的原前缀 `begin_line` 必须按 [rmcp-24 §8](../subplans/rmcp-24-u2d-append-inputs.md#8-文件中途取锚的正常终态已确认)核对并 finish `PrefixReached` 后，新的 NN01 才可使用其确认边界。
`located` 的 known `boundary.target` 等于请求 `logical_target`，driver 与 MS27 核对后才可绑定入口；root 的 not_applicable 规则不变。
无上下文先受预算创建 doc/bootstrap root，检查 C-DOC Failed，成功登记唯一 context/line；初始化 Require 等实际执行需独立执行事实，不称零成本 getter。
非法位置/不存在且已 EOF 的 theorem 返回明确错误；尚未到 EOF 的缺目标不误报 not_found。
post：真实边界或明确继续入口；有限索引遍历，恢复不隐藏在此循环。论证：定位与执行分开，重复 open 不绕 ACK 也不无界增根。

### NN02 `fork_line(binding, parent, expected_line, new_line, exploration) -> ForkResult`

pre P 且 M2 exploration 已授予，原始 fork origin/聚合深度不由新 line 重置；callee NR01/NR02。
查幂等 → 校父属于该 target/source/env/expected line → 借父 → 准备共享前缀新探索 line → 原子发布 → 释放临时 borrow。
额度/身份/版本失败无新 line；发布后回包未知只查同 operation，不重复创建。post frontier=parent、不 eval、不复制 state。
论证：新引用来自真实父而非 hash；有限操作，只新增受配额 owner。

### NN03 `sync_source(binding, context, expected, old_source, new_source, publication) -> SyncResult`

pre P，M4 已捕获新 source/发布事实，M2 已停冲突新执行；callee NR05/NR02/NR04。
本方法的B.budget必须含正有限metadata输出额度；M2 source-sync派发从受影响line集合及固定上界预留，不能沿“无打印所以output_bytes=0”默认。
核旧 revision/新 blob → 同内容保持边界 → 变化先标失效后缀禁止新借用 → 若 pending/inflight 未解决返回 closing/不可完成事实。
无在途后 NR05 求有效前驱，NR02 发布新 context/source alias 和采用截断/退役决定，NR04 清全部旧后缀容器。
具体发布顺序补齐：NR02 prepare先算实际每line before/after/frontier/status及context版本→OC04编码完整NativeLineUpdateDocument并写受预算spool，
生成NativeLineUpdateRef及OperationMetadata保留根→在唯一GraphTxn发布点同时应用图变化和对应source_synced AuxValue/metadata引用。
metadata编码/写失败或版本溢出发生在图发布前，拒绝本次变更并保持Manager暂停；若图已发布但返回/读取失败，保真实applied/unknown和spool，不伪回滚。
同内容no-op也给完整未变line版本表（before=after），不让caller根据source字节相同自行猜native映射。
失败前保旧有效前缀、失败后保明确新 revision 或 poison；不把文本保存成功冒称 native 已同步。
post 新准入不消费失效后缀，合法前缀不重算；有限节点遍历由 NR05/NR04 证明。论证：先封准入再改图消除与执行竞争，旧持久历史仍属旧 source。
driver读完整line_updates、核操作/身份/源/前后版本及exact-set后，PS06持久应用实际native映射（与logical pathrev自己的变化分开）再解除source-sync派发隔离；
finish只可清operation回执，不代PS06应用，metadata lease留到明确应用/消费。读丢/提交未知时保持context暂停并按原operation对账，不重复执行sync或自增native版本。
M6底层capture只产PS02 BlobRef/CaptureStatus，不注册actor OutputRef；line-update正文blob由PS06 owning_record保留，不按普通view TTL删除尚未应用的回执材料。

### NN04 `refresh_environment(binding, old_environment, new_environment, publication) -> RefreshResult`

pre P，M5 已提交/对账环境事务，M2 已封所有受影响 context；callee NR04/C-SHELL/C-MEMO/NB04。
同完整 EnvironmentRef identity 的 no-op 只返回 changed=false、保热。变化先拒旧 env 所有新使用，pending/inflight/view 未决返回未完成，不丢成功事实。
排空后清各 doc/toc/index/memo/imports/current，构造新 Coq.Files generation/env/root，并核与 M5 update token 匹配，最后发布环境 identity。
失败保持不可用/unknown，不先写 new env 然后继续旧 state；ACK 未知查同 operation，不能再次盲刷新。所有旧 state locator 拒绝。
post 新身份仅在原生应用完成后可见；有限 contexts/缓存表遍历，build/解释不在无限重试内。
论证：真实更新与身份发布同事务边界，no-op 不无故丢热；工具链/load-path 不兼容由 M2 创建新实例，不在本函数偷偷换工具链。

### NN05 `query(binding, node, selector, output_budget) -> ViewResult`

pre P，selector 属 M6 封闭查询族；callee NR01/NB01/NB03/NB04/C-M6。
对 M6 `query_text` 分支，source 已由 NB05 登记，range 必须落在精确不可变 UTF-8 字节内；核身份/selector → 借 node → 恢复父/新 Token →
以官方 parser 完整解析所选文本，取得有限 AST 列表 → 对每一个 AST 及其 wrapper 作静态已登记只读白名单分类 → 全部通过才执行查询并分块 materialize → 恢复原 current → 释放 borrow → 稳定结果。
解析失败、任何未知/插件扩展/定义/加载/证明推进/控制 AST 都在执行任何查询之前拒绝；不按 Print/Check 等文本关键词判定，不执行前半串再拒后半串。
每种查询 handler 必须证明不改变 line。允许的 Rocq 9.0 AST 构造器及 wrapper 精确白名单见 §4.3/NB07，保留内建 Eval/Compute 的受预算临时计算。
分类循环 invariant 为已看 AST 均属登记无状态变更族、尚未 eval；AST 数有限，解析/查询均用原 deadline，不能逐句重置。
错误/中断走 rmcp-7 N07；输出失败不生成成功 proof node。
post line/revision 不变、真实 view 或失败；有界选择器遍历/输出循环见 NB03。论证：查询只输出事实，current 临时切换在安全边界恢复，未知则隔离而非假只读成功。

### NN06 `inspect(binding, node, selector, output_budget) -> ViewResult`

pre P、C-M6 已定义 goal identity/roster selection；callee NR01/NB03/NB04。
核 node 和 selector → 取得 focused/stack_left/stack_right/shelved/given_up 五组 typed roster（stack depth 保留）→ 精确定位 goal/part → 仅物化指定部分。
不存在 selector 返回 not_found view 事实，不切到别的 goal；roster 过期拒绝，given_up 不过滤为空；所有异常合流恢复/释放同 NN05。
post 输出绑定确切 node/goal/part，无证明推进；遍历有限 roster 且受生成预算。论证：身份来自原生 roster 而非显示名，五组完整性不把“focused 为空”冒充完成。

typed facts 摘要域精确引用 M6 §3.2：先对 canonical_encode(facts) 生成文档内 capture，再序列化完整 document，最后计算外部 ViewDescriptor.capture；
内层摘要不包含自身，外层摘要覆盖完整封存 spool。M6替换native refs后须重新计算公开文档内/外capture，不能沿用原生摘要。

### 5.OC OCaml protocol-only 具体实现合同

本节按用户批准的减法裁决第3项，采用固定同版显式类型；对应rmcp-5 S-DECODE/ENCODE/DIGEST/SURFACE/HANDSHAKE/VECTOR，Rust详设RC01–RC08。
删除原OC03 catalog链接、通用shape/default解释、运行指纹重算、通用兼容协商；13个OC函数收敛为下面8个，不以静态descriptor换名保留解释器。
私有模块`Ccv_protocol`为Strict_json/Types/Canonical/Static_surface，无`open Coq`，不依赖Registry/FSM/DB。
同源标准schema/manifest/冻结vectors只在构建检查；OCaml显式record/variant与字段转换接受固定wire，RC08唯一产生双端major/digest常量，Pet不再加载任意catalog。

**固定库与已核 API**：OCaml4.14.2、Yojson3.0.0；只读本机 `yojson/raw.mli:9–18,225,259`，
Raw.t 保留 Intlit/Floatlit/Stringlit，Assoc 是保序 list（可保重复键）；文档明确非 ASCII 字节未做 UTF-8 验证。
`Yojson.Raw.from_string` 不提供本合同的 depth/node/Unicode/数字上界，也不能用其默认接受域替 strict JSON。
新增 hash 依赖固定 digestif1.3.0（源码 API 只读核 `mirage/digestif` tag v1.3.0 的 src/digestif.mli）：
`Digestif.SHA256.init/feed_string/get/to_hex/equal`；expected digest 先核64个小写 hex 再转换，禁止直接使用宽松 `of_hex`（它可截长/补短）。
固定链接 digestif 的 OCaml 后端而非运行时猜后端；运行依赖 eqaf 固定0.10。两个 tag 的 opam 元数据已只读核为 MIT，
digestif需OCaml≥4.08/Dune≥2.6，eqaf需OCaml≥4.07/Dune≥2.0，满足本设计4.14.2；未安装这两包，不把版本约束满足当实际编译通过。
不调用 openssl 子进程，不用 OCaml Digest（MD5）冒充 SHA-256；依赖实验构建须在正式适配前经[rmcp-10](../subplans/rmcp-10-codec-capability-preflight.md) P2验收，正式制品构建/安装验收另在实现后，均未执行。
依赖前置拆为L1-RAW/L2-API：固定Raw公开API的关联序列/记号保真、合法边界处理及key/String实际行为先验收；不要求Yojson默认拒绝其未承诺检查的输入。
顺序为rmcp-10 P0设计审查→P1独立Step 0/测试许可→P2原始API及依赖性能实测→P3正式OC适配（另需本模块准入）。
P2只登记expected_policy，不复制OC01 scanner；L1-STRICT由下面唯一生产OC01/02建立，不把原始库能力与严格策略互相冒充。

**私有类型**：`Value = Null | Bool of bool | Integer of int64 | String of string | Array of Value array | Object of Value StringMap.t`；
string 为合法 UTF-8 标量编码，key 已解码且唯一，整数在 U0 safe range，Map 比较 UTF-8 bytes。
`Token = Structural | AtomSpan(start,end,kind) | StringSpan(start,end,decoded)`；`Scan` 保存有限 token span 与深度/节点计数，不复制任意全文。
`Limits`采用rmcp-5消息/独立文档的有限bytes/depth；无catalog/default结构预算或DAG；
OCaml的node/key计数只是由该 bytes/depth 上界推导的实现保护：node/token数上界取输入bytes（空输入另拒），单key解码字节上界取输入bytes，
不引入更小的独立node/key配置或额外接受性限制，不暗改两端原始拒绝集合。
`Route`是编译期有限variant，caller选择，不能从wire传任意root字符串；`Message`为各具体请求/回复/存储类型的封闭联合。
`Checked`封装具体typed Message，仅OC03可建立；`Fault`为U0码/byte offset/有限路径，不携任意输入整串。
所有纯函数 `('a, Fault.t) result`；Yojson.Json_error/Invalid_argument/Failure 转指定边界故障，Out_of_memory/Stack_overflow 是 Infrastructure，绝不当预期 invalid-input PASS。
OC01–03/OC07的单缺陷错误归类按rmcp-5 §6固定表，与Rust端共用；不由库错误文案或向量当前值决定类别。

#### OC01 `scan_strict : Limits.t -> string -> (Scan.t, Fault.t) result`

pre limits有效；本正式适配单元所用L1-RAW/L2-API已有rmcp-10 CP07证据，不假定输入已严格合法。输入长度先核，不先交 Yojson。
迭代 cursor+container stack 状态机，object 状态为 key-or-end/colon/value/comma-or-end，array 为 value-or-end/comma-or-end。
允许 JSON whitespace 仅 SP/TAB/LF/CR；token 为 `{ } [ ] : , true false null`、字符串、整数；每次 push 前核 depth，每个 value 前核 nodes。
number按U0 `-?(0|[1-9][0-9]*)`收，-0规范为0，不接受点/exponent/前导+、leading zero、NaN/Infinity；以int64累乘前检查safe bound，不让机器溢出后再拒绝。
2026-11-05分类修正（用户批准B）：扫描先识别完整标准JSON数值词法`-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`及token边界，非JSON数值写法（含01/+1/NaN/Infinity、残缺小数/指数）报INVALID_JSON；语法合法但含小数/指数或越safe界才报INVALID_NUMBER。该词法识别不接受浮点值、不经过float；grammar及结束条件仍须满足，字符串中的相同文本不参与数值分类。OC02只消费扫描成功的安全整数，callee前置与接收集合不变。
string 逐字节核 UTF-8 最短编码、无 surrogate scalar、≤U+10FFFF；ASCII控制<0x20拒绝。escape只允许 `\" \\ \/ \b \f \n \r \t \uXXXX`；
高代理必须紧接低代理配对，孤立低代理拒绝；解码成 UTF-8 后核 string/key byte limit。key 在当前 object 的已解码集合查重，`"x"` 与 `"\u0078"` 为重复。
结束条件恰一根且 stack 空，余下只有 JSON whitespace；空输入、trailing comma、comments、tuple/variant/unquoted key、第二根皆拒。
post Scan 精确标记有限合法 JSON 输入、原 token 数值未丢失；失败不产 Scan。循环 cursor 每步前进或出错，stack 受 depth 限，空间受 bytes/nodes 上界。
论证：lexical 与 grammar 状态并核，非法扩展在 Yojson 分配前已拒；容器栈 key 集合防 escape alias 重复，不依赖后来的 Map 覆盖行为。

#### OC02 `materialize_raw : Scan.t -> string -> (Value.t, Fault.t) result`

pre 唯一生产OC01成功且raw identity/长度相同，Raw依赖能力已有rmcp-10证据；probe观察不能构造或替代Scan。调用 `Yojson.Raw.from_string raw`，随后显式栈遍历 Raw.t。
Intlit 必须与 Scan 对应 token 字节一致，再转 int64；Floatlit 一律不可能接受，出现即 codec inconsistency；Stringlit 用 OC01 已验证解码规则/对应 span，
Assoc key 必须与 Scan 的已解码 key/顺序一致并再次查唯一才入 StringMap，Array 保顺序；Null/Bool 逐值对应。
任何差异为实现/codec缺陷，不产生部分 Value；Yojson异常按上段分类。大小/深度已在 parse 前有界，遍历每个 node 恰一次且核累积限制。
post Value 不变量成立；论证 Raw 保 token，安全范围与重复键在数值化/Map前已核，不能 Safe.from_string 先转浮点再解释。

#### OC03 `decode_message : Route.t -> Limits.t -> string -> (Checked.t, Fault.t) result`

pre Route由本地通道/在途method或固定测试表选择。OC01→OC02→该Route的显式record/variant转换；没有schema参数。
每个转换固定检查tag、字段exact-set/required、值域与具名newtype；optional只按该字段分支处理，null不当缺失。
Pet只实现实际Rust↔Pet消息（普通/control/source/view/Hello/Budget/NativeFacts）显式映射，不为测试增ActorRequest/Ingress/Manager/存储record。
这些Rust-only类型的默认及摘要由RC02/RC04与rust_only冻结向量全覆盖；不把不实现写成“OC已通过”。
NativeRequest/Reply逐固定method/kind匹配，配对仍由W01；响应使用原生/M6具体record，Int64转int须核目标API范围。
有限字段/数组遍历，已完成前缀满足具体类型，剩余项严格减少；未知/错类型/缺项立即返回原固定fault，无部分Checked。
post结构与固定局部关系成立；论证OC01/02.post满足显式转换pre，类型穷尽匹配排除未知shape，无DAG/default递归或宽松fallback。
返回后handler另核epoch/源环境/预算/权限；内部typed传值，不再先序列化成JSON重复解析。

#### OC04 `encode_message : Limits.t -> Message.t -> (string, Fault.t) result`

pre消息由合法构造器/owner关系校验产生；具体variant逐字段to_value，调用唯一canonical writer，不用Yojson.to_string冒充规范。
writer按UTF8键序/数组原序/Int64.to_string；控制集合恰为U+0000–U+001F，全部小写\\u00xx而不用短转义，引号/反斜杠按既有转义，其余Unicode含DEL/C1原字节、斜线不转义；depth与每append checked长度先核，Buffer.add_substring后保持有界规范前缀。
字段/字符/数组循环有限，子树严格变小；内部映射缺陷返回INFRA，预算超限拒且丢完整私有buffer。
post与Rust RC03相同bytes，不能把返回string当FD原子发送；无输出截字段或敏感错误回显。

#### OC05 `digest : DigestInput.t -> Limits.t -> (Digest.t, Fault.t) result`

DigestInput为编译封闭variant NativeOperation/NativeReceipt；具体前像沿rmcp-5 §4，contract digest只读构建常量，不在Pet重算schema。
NativeReceipt分支的内部`ReceiptDigestInput = Receipt of Receipt.t | Completion of Completion.t | Aux of AuxTerminal.t`与RC04/W03逐record对应；
这是函数参数variant，不增加wire tag。checkpoint Aux全部字段进入既有`ccv-native-receipt-v1\0`前像，仅去该record直接的key.digest；
AnyTerminal若是receipt/eof包装，caller先取得内部Receipt/Completion再传本函数，不把包装额外hash一层。Aux本来就是带kind=aux的完整record，保该kind。
native只排指定rpc_seq/binding摘要或key.digest，不递归删任意同名键；Actor/Ingress仅Rust实际消费与测试，不给OC造无consumer分支。
调用OC04内部同一writer→Digestif SHA256 feed域ASCII+NUL及bytes→get/to_hex，expected先核64lowerhex才equal。
失败无摘要；有限字段/字节终止。post同源前像同hash，不因此证明权限/执行；不接任意domain字符串。

#### OC06 `surface : Surface.t -> SurfaceDefinition.t`

pre Surface为编译枚举；固定match返回编入methods/schema载荷引用/注解。trivial常量选择，无文件加载或运行解释。
实际handler注册按静态表exact-set核，少/多方法拒启动；能力只来自真正编译启用handler，不由schema声明补造。
manifest字段/可空capability/注解值沿rmcp-5 §2.1，执行方法不含Hello/Ack；同版摘要与required表不能替代实际handler注册核对。

#### OC07 `check_hello : ExpectedPeer.t -> HandshakePeer.t -> (unit, Fault.t) result`

HandshakePeer为显式`Hello of NativeHello.t | Ack of NativeHelloAck.t`，两种record各自封闭；ExpectedPeer包含固定receive_direction。
pre ExpectedPeer由真实启动绑定建立，peer已经OC03核结构；major/digest取RC08同源编入常量。Hello只配to_native、Ack只配to_driver，否则拒绝。
共同逐项核instance/epochs/channel/nonce，再exact major/digest、能力无重复且覆盖该channel静态required；Hello核expected_artifact匹配boot artifact；
Ack完整核artifact/rocq_version/ocaml_version/limits_backend期待，不删字段/补造字段转为Hello。错项拒，不协商到旧版。
完整required表沿rmcp-8 §3.7；合法peer能力排列不同不拒绝，额外能力不启用。数组发送排序与canonical保持原序是不同职责。
有限能力列表循环，已核前缀均合法；四通道完成才NW01 ready，函数本身不改Registry、不启动执行。
论证固定制品格式/身份约束全部合取，仍不以peer自报artifact建立安装信任。删除旧Agreed及任意local/required通用兼容接口。
运行Pet只构造to_native期待；OC08与Rust RC07的固定向量显式带direction，两端均执行两方向完整检查，无另一方向skip。

#### OC08 `check_vector : FrozenVector.t -> (Verdict.t, Fault.t) result`

pre仅接rmcp-5 §2.4 vectors.shared冻结data-only raw/typed/canonical/native-digest/pet-surface/handshake向量，type_case为编译固定表；不接受任意catalog或fingerprint脚本。
RC08先核分组exact-set：native case不得放rust_only，Actor/Ingress等不得放shared；OC08遇未知type_case/action域直接夹具错误，不skip。
核hex与expected分支→调用OC01–07实际入口→比完整值/bytes/hash/码；INFRA不作expected reject，不回写oracle。
有限向量/字节循环；post仅该向量符合/不符，不以双方互认替独立规范。构建RC08负责schema/manifest及固定digest，不在OC再实现另一生成器。

**保留反验**：原始Unicode/duplicate/number/边界样本、每个Pet typed分支完整向量与删字段/错tag、native域前像、错版本/nonce/能力拒绝；try默认=report由Rust-only明确全测。
去掉严格扫描、先Safe数值化、Map吞重复键、宽松hex、忽略字段或默认改变都必须红；旧catalog cycle/default展开测试退役，换标准schema/type漂移检查。
**旧ID同步**：原OC04/13→新OC03，原OC06/08→新OC04，原OC07→新OC05，原OC09→新OC06，原OC11→新OC07，原OC12→新OC08；
原OC03/05/10通用算法删除（唯一业务默认并入新OC03，指纹为构建常量），不能保兼容包装。原生执行/ACK/控制函数不因本节删减改义。
所有函数仍仅设计，尚无代码/编译/实验结果；rmcp10仅公开API观察的前置顺序保留。

## 6. Token 实际接缝、循环及全根验收

控制入口直接复用 rmcp-7 N06/D03、rmcp-8 控制 wire；不能加一个普通 cancel method 排在 eval 后。
生产适配需把每个 eval/query/parse/recovery 的 Token 安装、撤销、C check/clear、nested limit/Atomic 入口纳入同一代际协议。
仅在 token 换代处加锁不足；不能持锁跨整个 eval。M 后端须核实际启用 Memprof_limits，Atomic 区域不能伪称可取消。
P01/P04 只验证入口局部；P02/P03 必须在同实例中实际中断普通 tactic/query、恢复后继续到真实 Qed/查询成功。
P05 READY/WAIT_ACK 取消锁存不清，ACK 后也不得继续 pull；P07 输出背压/不可响应操作走独立控制与域核停。
所有 wait/循环有原绝对 deadline；服务主 loop 本身按输入/关闭事件持续，单次迭代有限，shutdown/域核停为终止机制，不宣称服务必自然终止。

### 待实现测试（本轮均未执行）

| ID | 性质/实例 | 反向验证 |
|---|---|---|
| U3-PBT1 | proptest/QCheck 生成 fork/ACK/select/close/sync 操作序；有效 line 全祖先存在、无环、borrow 不被删 | 去掉一个保护 owner 必须失败，生成两个必需目标与共享前缀 |
| U3-PBT2 | source prefix 变形：同字节同 env 保热；修改边界前/后、EOF 后追加、Unicode/注释/语法扩展 | 删除 parse_horizon/EOF 检查须命中反例，不另写第二 parser 作 oracle |
| U3-PBT3 | 有界帧分片任意组合与一次损坏；正常 decode 相同，坏包不得部分 ACK | 长度先分配、重复键、错epoch/rpc/controlseq、截断、迟到等独立变异 |
| U3-PBT4 | 操作序号/终态/ACK 重发不产生新 node，retire 不删 line 历史 | 用真实 eval/probe 标记计数，不能只比较最终文本/hash |
| U3-R1 | 全根反验逐一独占保留：node map、line、scope、doc.nodes/toc/prev、旧 doc closure、memo key/value、imports、current、pending、inflight、live view | 每类单独注入强根，撤该 owner 后 Weak witness 经 full major 应释放；留另一合法 owner 则不能释放 |
| U3-R2 | 两阶段退休：先撤资格，后根清理；失败/unknown 不返探索/内存额度 | 仅删 Registry 统计而留真实 Doc/memo/current 必须红；不以 RSS 立即下降作判据 |
| U3-E1 | 真实短证明逐句 ACK，任意早期边界热恢复，超过旧256/1000阈值仍免重放 | 插桩 actual interpreter 执行标记；复用只读 node 不增加；重放替代应红 |
| U3-E2 | 首句失败、空白 EOF、k句失败、ACK丢失、select丢失、文档/交互混合 | 实际执行与 durable 记录分别核，不能 mock ACK 取代 M4 落盘测试 |
| U3-E3 | 环境 no-op 保热/更新拒旧 node、源后缀变化保有效前缀 | 禁清全部图冒充精准源同步；新 env identity 先发布的变异应红 |
| U3-E4 | cancel 与换 token/ACK/输出竞争、真实 tactic/query 恢复、不可响应域核停 | Future drop、仅cancel_ack、重启后成功均不算软恢复 |
| U3-E5 | query 五组 roster、精确 UTF-8 chunk、生成侧预算、sink断线 | 整份 Pp/string 生成后裁剪不算通过；只返回 focused 应红 |

U3-E5 固定 Unicode 边界反验：下一标量为4字节时 credit=3 必须在读取前拒绝、credit=4 恰返回该标量；
不得以空非终页、截断字符或超过 credit 来前进。source 二进制 chunk 的1..8192界与文本 view 的4..8192界分别验证。
U3-E5 查询矩阵另核 Check/Print/About/Locate/Search、Eval cbv/vm/native 的真实结果与预算；
拒绝 ControlRedirect、PrintUniverses file=Some、PrintDebugGC、VernacExtend、CGenarg/CGenargGlob、notation 模板 NGenarg、ExtraRedExpr；
正例含普通 CNotation/CPatNotation 与各 builtin red，不能为让负例红而把整个查询族删掉。多句最后一条不合法时第一条执行计数必须为0；
打印选项恢复在成功/失败/中断三路都核原值，native reduction 派生子进程由域核停反验覆盖。
U3-PBT2 直接调用 NB08 producer 并与其输出节点做变形关系：改变 supplier 曾提供的 lookahead 字节必须失效，
EOF 后追加必须失效；去掉 from wrapper 的高水位或仅用 Stream.count 两种单点变异分别必须红。

Weak witness/根 adapter 测试须释放测试自身局部引用，避免观察器造根；对所有容器精确列 root coverage，未覆盖类别不得写“全根通过”。
GC live heap 与 RSS 单列；共享对象不归每个节点独占字节。不以小证明均值估真实大证明容量。

## 7. 联合接线、决策与编码前门

- M2 引用 ND01/ND04/ND05 与 rmcp-7 D01–D04；每下一 pull 重核 DispatchTicket，不能因撤权拒绝已有 durable ACK。
- M4 引用 NN03、rmcp-7 C4/C5；新 source 只有 blob 校验结束才可被原生引用；DB 历史成功不复活 native locator。
- M5 引用 NN04；M6 引用 NN05/NN06/NB03；live view 以 Registry borrow 接入，结束/失效先撤新读取再排空。
- M4 精确 callee：[proof-store.md](proof-store.md) PS04 意图、PS05 step_commit/AckProof、PS06 原生已应用事实、PS07 终态、PS09/10 source 发布/对账、PS17 VerifiedByteStream。
- M2 完整观察 root：[manager-supervisor.md](manager-supervisor.md) §9.1 MemoryObservationRecord/BackendInstanceRecord 与 §9.2 InterruptReceiptRecord；gc_live_words×word_bytes 必须 checked，未知不填0。
- M6 唯一类型：[build-output.md](build-output.md) §3.2–3.5 TypedFactsDocument/GoalGroup/GoalEntry/PartDescriptor/CaptureStatus 与 native view；BO07/BO08 调本模块。
  hypothesis index 对应完整声明（含名字/body/type），不能当只读 type；8KiB 有效 UTF-8 输出块在 M6 明确持久接收后才归还 credit。
- U0 注册 §4.2 roots、source bounded transfer 与非 Receipt 终态/status 投影；这些为完整原生 manifest 的必需差额。

**独立待决项（不是本文擅自改变架构）**：
1. §4.2 AuxTerminal/AnyTerminal精确union及逐方法限制已有联合设计复核，见[集成终审§6–7](../../../audits/unified-remediation-2026-10-30/integration-closeout-review.md)；未扩写旧Receipt.kind，机械schema/向量及真实运行验收仍未做。
2. 若固定 Rocq/OCaml 实验无法满足普通 tactic/query 的可恢复中断，必须回到架构讨论；不得把支持集合设空。
3. parser lookahead 已按 NB08 固定维护 fork 接口与 Gramlib.Stream.from 适配，不需改变内核；实现/性质验收仍待后续阶段，不再列作设计未定。

### 完整性自检

- [x] 范围/复用/错误/私有类型/逐函数 pre/post、分支、退出、callee、循环及论证已列。
- [x] 真 Registry 联合生命周期、源句界复用、process/frame 隔离与中断实际接缝已明确。
- [x] PBT、全根反验、实际执行标记及同实例恢复测试已设计；未声称已执行。
- [x] 本模块 source/state/memory/boundary/aux 终态 root 与 parser/query 接口已具体化并交 U0/M2/M4/M6。
- [x] 非Receipt终态AnyTerminal/finish/settle及逐方法限制的旧文同步已有定向核对，见[原设计审查记录](../../../audits/unified-feature-design-2026-10-30.md)；仅保留该局部证据，不恢复其中已撤回的整体PASS。
- [x] 旧OC通用catalog接口义务superseded，由新OC01–08固定typed边界与静态协议载荷承接；减法3局部设计见[固定typed协议复审](../../../audits/unified-remediation-2026-10-30/typed-protocol-reduction-review.md)，不代后继全caller复核。
- [x] U0/M2/M4/M5/M6 root/callee、新RC/OC、双向握手及shared/rust_only消费矩阵的设计联合复审与整包§4.4完成，见[集成终审§6.2/§7](../../../audits/unified-remediation-2026-10-30/integration-closeout-review.md)；不代机械产物exact-set或实际双端运行验收。
- [ ] 独立Step 0 expectations、固定schema/manifest/规范向量及分支/边界exact-set。
- [ ] OC正式适配前rmcp-10独立准入、双端L1-RAW/L2-API及依赖边界性能实测；随后生产RC01–02/OC01–03严格适配验L1-STRICT，当前均未执行。
- [ ] rmcp9/11实际原生实验、生产全根/中断/恢复及真实Pet验收；测试设计不等运行通过。
- [ ] 用户最终细化确认及按单元实施授权。

## 8. 度量（设计里程碑）

仅新增本设计文件；代码新增/修改/删除 0，涉及设计文件 1；新增测试实现 0，测试计划 11组，执行通过率 N/A。
设计列出新增函数组 41 项（含组合签名）；联合合同决议/验证依赖 3 项，已运行/已修复生产 bug 0；本轮设计4轮、实现0轮、修复0轮。
精确文档行数由最终 `git diff --stat` 记录；本节不是测试报告或部署验收。

## 9. rmcp-13 增量：用户暂停的原生磁盘检查点

2026-10-31，设计基线 `56e472e158853a35178fe66ba92935c10acc9b6d`。本节沿workflow §4.3/§4.4，
承接主架构§5.4.4/§8/§10/§11.5.3及[rmcp-13](../subplans/rmcp-13-user-pause-disk-checkpoint.md)。
旧模块审签不覆盖本节，当前只设计，尚待独立审、增量Step0，未生产编码/新探针/安装/提交。

### 9.1 实际复用点、依赖与证据边界

| callee ID | 已读接口事实 / 本节用法 |
|---|---|
| CK-STATE | 固定fork `coq/state.ml:11,50–53`：t=Vernacstate.t，marshal_out=Marshal.to_channel … []、marshal_in=Marshal.from_channel。既有函数只单state，不能逐root调用后声称保跨root共享 |
| CK-FREEZE | `coq/state.ml:156–165` 的 in_state/in_stateM 经Protect调用 Vernacstate.unfreeze_full_state；`coq/interp.ml:31,42`真实执行前unfreeze、后freeze_full_state再State.of_coq。导出取Registry保存的各历史state，不反复freeze当前末态冒充旧root |
| CK-SUMMARY | Rocq9 `library/summary.mli:25–44,70–76,112`：summary原值应纯且可Marshal；ML summary unfreeze可加载ML及注册新项；Summary.dump给真实(int,string)注册集合，不提供插件可移植性证明 |
| CK-LOAD | 固定fork `petanque/json_shell/shell.ml:3–8` Coq.Init传Dynlink.loadfile及Coq.Loader.plugin_handler；`coq/loader.ml:89–101`经Fl_dynload.load_packages实际加载，可能选择serlib包。已读findlib/fl_dynload.mli:5的`load_packages : ?debug:bool -> ?loadfile:(string -> unit) -> string list -> unit`，可在fork传实际文件hook，无须改Findlib/Rocq内核 |
| CK-PET | `Petanque.Agent.State.t`抽象；Agent.run/goals是实际执行/打印API；rmcp12直接Marshal抽象state小例可行。生产Registry已有Coq.State.t，无Obj.magic、无旧整数handle反推state |
| CK-MARSHAL | OCaml4.14 Marshal.to_buffer/from_bytes/total_size：一次整体对象图默认flags=[]保共享；禁止No_sharing/Closures及失败后改flag重试。to_buffer目标buffer有限，失败不生成有效包 |
| CK-M4 | PS26固定ScopeCheckpointPlan/CheckpointGroup；PS27完整封存→DiskCheckpointRef；PS28记真实退役；PS29 prepare只建立sealed读取租约/attempt，不要求当前ABI；实际observe及IR19之后PS36才admit import；PS30当前性CAS→ActivationPermit（仍暂停）；PS31收到native ACK后再次CAS才解本pause |
| CK-IDENTITY | U7 IR18产CheckpointCompatibility（实际安装/载荷/加载顺序/summary注册），U3 NC01供实际观测；M5 BO22固定源/环境无pending，BO23激活前重核 |

rmcp12仅37行fixture、18root、原进程退出后四路线到Qed/Closed及负例；不证明VST、大root图、任意插件、Manager事务或生产峰值。
生产capability不因该小例自动开启；真实VST/受支持插件集合与默认Marshal失败行为由§9.8验收，不添加Closures fallback。
这里“包不带FD/权限”首先是框架PackedGraph字段排除规则，不把Marshal成功当作任意插件summary内部没有进程局部资源的证明。
Summary声明要求纯可序列化值；生产支持的插件须经IR07/实际新进程续算验收确认其freeze/unfreeze/init满足该要求，已知含FD/进程局部缓存或无法核明者拒checkpoint。
不递归扫描Coq.State并猜整数是否FD，不对插件违约作自动修补；未知支持面返回缓存不支持，普通证明能力不因此被判失败。

### 9.2 输入计划、兼容性与私有所有权

覆盖基准唯一引用M4的CheckpointBoundary/CheckpointPathSnapshot/CheckpointGroup/ScopeCheckpointPlan（proof-store.md §8/PS26），
不从本地猜当前头或只取frontier。Boundary为entry(lineage)或step(lineage,step)，每path保entry至frontier完整已采用durable序列。
CheckpointGroup.line_bindings的`{lineage:Id,native_line:NativeLineVersion}` exact-set覆盖本group全部paths；这是selection时M2真实映射的冻结投影，
逻辑CheckpointBoundary.lineage不冒充native Line ID。NativeLineVersion.id/revision与原生表核；path_revision只与M4固定路径当前性核。
CheckpointGroup另含owner_scope（Manager逻辑域）与native_scope（当前真实原生owner映射），分组键包含owner_scope；
parent/root用户暂停可由M2覆盖授权的有效后代scope，但不把parent Manager scope ID直接放进Pet B.scope。
export/collect/observe的B.scope=该group.native_scope，NC02核每选中line属该native owner；不同owner即便兼容context也分别包，保其它scope共享引用。
import的B.scope取M2当前新预留native scope，旧group.native_scope只为来源审计，禁止要求新scope等于旧scope或由包恢复权限。
NC06新line/context归该新B.scope；PS31从实际import B及map登记(manager_scope,native_scope)桥，NC08逐项核同当前scope/control关联。
**释放域不等于一个group**：现有Scope可持多个context，不新增“一个scope仅一context”假设。
只有同一(instance,backend_epoch,native_scope)释放域的全部必需组都明确PS27封存、覆盖/所有权重核且探索退役条件满足，M2才可调用既有end_scope。
存在本次退役范围外的合法owner/主线就不能关闭整scope；部分封存保持热态/暂停，只报告sealed而不虚报逐组已退役/PAUSED_DISK。
本设计不新增subset-release方法，不为了首个group成功而误删另一个尚未封存context的唯一热态。
一个包覆盖一个兼容group；group内所有path一次序列化。不同workspace/context/environment/实例不能合包，多个group逐项报结果。
每group非空；`B.source`为group.paths里真实SourceRef ID按UTF-8字节排序的最小值，`B.environment=group.environment`。
选中scope没有可封存主线时由M2/M4报告空覆盖的暂停事实，不调用本组方法、不为B.source造占位source。
完整source集合/路径revision由请求内plan ArtifactRef摘要绑定；plan ID不是source ID。import的B.context为M2预留的**新**context ID，group.context仅历史出处。

`ArtifactRef={id:Id,digest:Digest,bytes:U,kind:"checkpoint_selection"|"checkpoint_requirements"|"checkpoint_plan"|"checkpoint_manifest"|"checkpoint_map"|"checkpoint_bundle"|"checkpoint_compatibility"|"checkpoint_observation"|"checkpoint_preload_plan"}`。
id为M4/原生生产者登记的不透明材料引用，bytes为完整原字节长度；JSON类按OC04规范输出，bundle是opaque binary。
材料归属/重绑定沿M4 PS35：M4-origin的id=digest=实际BlobRef且bytes=BlobRecord.size；native-origin id只在其lease生命周期内有效。
seal保存原回执及manifest/PackedGraph原字节，不为新Blob ID回写旧metadata。新import输入用M4-origin当前Ref，不能复活旧native artifact ID。
当前RPC请求/响应echo、transfer、pending块的Ref仍全字段exact（含id）；仅**已封存内容中嵌入的历史引用**按(kind,digest,bytes)在本control已授权完整材料集合解析。
材料集合来自PS29 owning_record读取或当前已登记控制材料，不按裸hash全局查库；缺项/错kind/未授权拒绝，不因digest存在扩大读scope。
大metadata走§9.4有限字节流，完整校digest/长度后按OC01–03固定document类型和metadata_bytes预算解码；64KiB只约束每帧，不截完整计划/映射。

兼容类型唯一归IR18 `CheckpointCompatibility`：format_id/version、installation、实际Pet/Rocq/runtime载荷、OCaml版本/word_size/endian/native-or-bytecode、
实际loaded plugin顺序及summary注册身份、abi_digest。格式固定`ccv-rocq-state-graph`/1，Marshal flags固定default；客户端不能选格式或flags。
兼容文档另含实际成功`initialization_steps`（IR18/IR21唯一类型）：findlib_packages保原packages与实际ordered artifacts，coq_init_module保实际artifact；
这些是加载接缝真实调用记录，不从logical_name猜可执行包名。IR21将已封存步骤按IR20已核当前安装解析为CheckpointPreloadPlan，
其中实际路径是可信driver生产、内部加载使用，不能由actor或包中任意字符串授予路径读取。该plan经kind=checkpoint_preload_plan受控材料传入。
完整compatibility文档由IR18/PS02存为kind=checkpoint_compatibility的ArtifactRef；下面wire只传该ref，不把全部插件/summary数组塞64KiB帧。
每个consumer先取得并严格核该完整受控文档，再比较实际字段；只比较ref ID/digest而未读取实际兼容字段不足以允许import。
摘要只便于索引，导入逐字段exact相等；不包含instance/epochs这些必随新进程变化的身份，不从相同版本串或state hash推兼容。

| 私有类型 | 字段、建立/释放及不变量 |
|---|---|
| ExportLease | operation/control/attempt/group、所有selected root Borrow、兼容观测revision、spool引用；NC02建立，封存/取消对账后NC09释放；不撤原line owner |
| PackedGraph | format、manifest规范字节、nodes数组、line/doc投影；一次Marshal []，绝不包含Registry/NativeOp/control cell/budget/FD/host权限 |
| PackedNode | state:Coq.State.t、AST/原始loc可选、parent_index:option<int>、实际SourceSpan；state与AST保原对象引用，禁止按hash去重 |
| PackedDoc | source身份、source字节引用、只含selected前缀的toc(node_index)与目标入口信息；不含旧Doc.env/documents容器或未选后缀 |
| ImportArena | import operation/control/attempt/cache/group、新context/line/node maps、validation、status=LOADING/PREPARED/ACTIVATED/RETIRING；NC06建立，NC08激活或NC09清理 |
| ImportInputs | pending-import budget槽、plan/requirements/manifest refs、SourceAllowlist、已登记source引用与输入BlobLease；NC04建立，NC06借用或NC09清理；计入checkpoint_import实际根 |
| BlobLease | artifact/transfer身份、direction、control/attempt、原native_scope及budget/epochs绑定、size/quota、pending块、last ACK、消费/释放事实；与operation回执寿命独立 |

OCaml包内私有record精确签名（不进入Rust schema）：
`packed_node={state:Coq.State.t;ast:Coq.Ast.t option;loc:Loc.t option;meta_index:int}`；
`packed_line={lineage:string;target:string;path_revision:int64;boundary_node_indices:int array}`；
`source_alias={source:string;ancestor_source:string;unchanged_prefix_end:int;publication:string}`；
`restored_toc_entry={source:string;name:string;kind:string;parent:int option;node_index:int;start:int;end_:int}`；
`packed_doc={logical_file:string;source_ids:string array;node_indices:int array;toc:restored_toc_entry array;aliases:source_alias array}`；
`packed_graph={format_version:int;manifest_bytes:string;nodes:packed_node array;lines:packed_line array;docs:packed_doc array}`。
所有int转换先核非负/数组或源字节实际界，array/list总大小受root_count/metadata预算；meta_index与manifest.nodes一一对齐。
Doc.env/Coq.Files从当前已核EnvironmentRef重建，不反序列化旧可变文件registry；source_ids必须有M4 retained不可变材料供重建，无网络/任意路径读取。
旧source alias只有NR05已确认的未变前缀事实可入包，import按manifest/原source材料核，不把相同source名字当证明。
Node.source可为历史交互脚本SourceRef，不要求等于当前path.source；它必须等于对应durable StepRecord的实际执行source，并在M4计划保留材料闭包内。
当前path.source/source_anchor负责当前性，历史SourceSpan负责原执行字节，两种身份不可互相覆盖或为简化包改名。

保留根类别增加checkpoint_export/checkpoint_import；NR04/NR06实际遍历ExportLease/ImportArena，不能只加计数行。
两类adapter还分别枚举该purpose的全部BlobLease（含establish尚未受理的预输入）与ImportInputs；不能等成功建arena/ExportLease后才把先前上传材料计入根/额度。
PackedGraph是单包对象图的序列化投影，不是Rust热图；辅助memo/import cache不作为可恢复根打包，恢复后可空缓存，全部必要历史state由nodes数组强保。
导出selected roots的parent闭包必须在同group且覆盖entry前需要的真实前驱；内部support root可额外保存，但不得作为新增公开boundary。
其它scope共享的真实对象可被默认Marshal在包内共享记录，原进程只撤本scope owner；不把包含某对象解释成有权撤其它scope引用。

### 9.3 metadata roots 与普通方法精确矩阵

`CheckpointNodeMeta={index:U,old_node:Id,parent:Fact<U>,source:Id,start:U,end:U,cursor:U,read_end:U,saw_eof:Bool}`。
parent只许known/not_applicable，known<index；范围含于对应实际源；root_count为去重后原生Node身份数，不按state hash。
`CheckpointBoundaryRow={boundary:CheckpointBoundary,node_index:U}`；同一node可被多lineage边界引用。
`CheckpointAliasFact={source:Id,ancestor_source:Id,unchanged_prefix_end:U,publication:Id}`，publication为原source-sync已应用事实的M4生产关联，不从相同文本推alias。
`CheckpointSourceIdentity={source:Id,digest:Digest,bytes:U}`，来自原生已登记完整source字节，不从文件mtime猜；source id集合恰等于required_sources。
`CheckpointRequirements={schema_version:1,selection:ArtifactRef,group:Id,collect_operation:Id,instance:Id,backend_epoch:U,
manager_epoch:U,environment:Id,required_sources:Array<Id>,source_descriptors:Array<CheckpointSourceIdentity>,alias_facts:Array<CheckpointAliasFact>,nodes:Array<CheckpointNodeMeta>,boundaries:Array<CheckpointBoundaryRow>}`。
selection文档唯一引用M4的preliminary CheckpointGroup（停稳且path snapshots已固定、source_materials尚未补齐），不是另造路径schema。
首次NC02 collect在不eval/不撤line owner的条件下给requirements；PS26核required_sources/alias publication均有durable来源后才固定完整plan。
encode的NC02再比同一requirements全部真实node/parent/boundary/source/alias集合；不匹配拒绝旧plan，不能在plan封存后默补源材料。
`CheckpointCoverageManifest={schema_version:1,plan:ArtifactRef,group:Id,export_operation:Id,instance:Id,backend_epoch:U,
manager_epoch:U,environment:Id,compatibility:ArtifactRef,requirements:ArtifactRef,source_descriptors:Array<CheckpointSourceIdentity>,nodes:Array<CheckpointNodeMeta>,boundaries:Array<CheckpointBoundaryRow>}`。
PS26逐descriptor与自身StoredSource/blob核source/digest/bytes exact，encode重核相同descriptor；PS29再次核manifest descriptor与sealed record关联，不接受自报摘要给未知SourceRef。
boundaries顺序/集合恰为PS26 group.paths逐条序列；多path共享node不丢任一Boundary。manifest不带bundle digest，避免自摘要循环：
先构造manifest字节→PackedGraph内包含相同manifest字节→一次Marshal成bundle→分别求manifest/bundle digest→外层ExportValue绑定两者。

`CheckpointMapRow={boundary:CheckpointBoundary,new_node:Id,new_line:Id,new_line_revision:U,new_context:Id,new_context_revision:U}`。
`CheckpointImportMap={schema_version:1,cache:Id,group:Id,import_operation:Id,instance:Id,backend_epoch:U,manager_epoch:U,
manifest:ArtifactRef,rows:Array<CheckpointMapRow>,validated_node_count:U,validation:"all_roots_accessible"}`。
map.rows覆盖全部manifest boundaries，无重复/漏项/额外项；共享旧node映射到同一新node，line/context按新owner分配。
新line/context的实际初始native revision为0，由NC06填上述两个revision字段并在NC08原样发布；不将旧path_revision当新native revision。
逻辑path_revision仍由M4原路径记录提供，用于当前性与Restored索引；M2据map实际revision建立新native绑定，不凭默认值猜。
validated_node_count=manifest.nodes.length；仅抽样frontier不允许此validation。它表示实际可访问性检查，不是新证明成功/全部语义等价定理。

方法共同外壳/绑定/摘要/seq沿§4.2；四者都新建operation并返回稳定AuxTerminal，不改Receipt.kind或原step ACK。

| 普通method / Args全部字段 | AuxValue成功分支（全部字段） |
|---|---|
| checkpoint_observe `{binding:B,control:Id,attempt:Id,preload:Fact<ArtifactRef>}` | `{kind:"checkpoint_observed",control:Id,attempt:Id,observation:ArtifactRef}` |
| checkpoint_export collect `{binding:B,phase:"collect",control:Id,attempt:Id,selection:ArtifactRef,group:Id,compatibility:ArtifactRef}` | `{kind:"checkpoint_collected",control:Id,attempt:Id,selection:ArtifactRef,group:Id,requirements:ArtifactRef}` |
| checkpoint_export encode `{binding:B,phase:"encode",control:Id,attempt:Id,plan:ArtifactRef,requirements:ArtifactRef,group:Id,compatibility:ArtifactRef}` | `{kind:"checkpoint_exported",control:Id,attempt:Id,plan:ArtifactRef,group:Id,manifest:ArtifactRef,bundle:ArtifactRef,compatibility:ArtifactRef}` |
| checkpoint_import `{binding:B,control:Id,attempt:Id,cache:Id,plan:ArtifactRef,group:Id,manifest:ArtifactRef,bundle:ArtifactRef,compatibility:ArtifactRef}` | `{kind:"checkpoint_imported",control:Id,attempt:Id,cache:Id,group:Id,manifest:ArtifactRef,mapping:ArtifactRef,compatibility:ArtifactRef}` |
| checkpoint_activate `{binding:B,import_receipt:K,activation:ActivationPermit,mapping:ArtifactRef}` | `{kind:"checkpoint_activated",import_receipt:K,activation_id:Id,cache:Id,group:Id,mapping:ArtifactRef}` |

ActivationPermit精确字段引用PS30：activation_id/control_id/cache_id/import_operation/import_receipt_key/instance/backend_epoch/manager_epoch/binding_revision。
checkpoint_observe的preload：export必须not_applicable（安全点只观察）；import必须known且kind=checkpoint_preload_plan、来自IR21/PS29当前恢复读取。
unknown拒绝；它不接收任意包内path，也不调用前缀证明。observation必须kind=checkpoint_observation，其完整JSON类型为IR18的共享LoadedArtifactObservation。
observe先返回实际观测，Rust经有界blob取得完整文档后才调用IR18/IR19产当前compatibility；这是跨进程可调用入口，不把NC01写成Rust可直接调的OCaml函数。
全部方法允许aux_terminal/past_unavailable/protocol_error；aux_terminal内部只许自身成功kind或共同error。checkpoint_imported不等于活StateRef；
checkpoint_export的两phase各自新operation/budget/seq，phase在初始request_digest中；collect只许checkpoint_collected、encode只许checkpoint_exported，不能将旧B改phase续用。
checkpoint_activate用**独立新operation_seq、新预算**，purpose为同control/attempt的import；不改写原import终态。
error.stage新增checkpoint_collect/checkpoint_encode/checkpoint_decode/checkpoint_validate/checkpoint_activate；保诊断及extent，不把失败归为成功step。
操作错误只在确定恢复/停稳后形成AuxTerminal error；无法确认的保原OpStatus/unknown并隔离，不finish未知尾。
W01/OC03/OC06与Native method manifest、AnyTerminal status/finish/settle同步纳四方法；终态重读只读原记录，不重新导出/装载/probe。
driver D04在结构/摘要后调用rmcp-8 W04（用途/绑定/类型配对），再交NC/PS生产者事实校验；W04不解析Marshal或自造覆盖表。
所有compatibility字段必须kind=checkpoint_compatibility，selection/requirements/plan/manifest/mapping/bundle分别恰对应同名kind；对方合法ArtifactRef但kind错也拒绝。
包中old instance/epoch只为导出来源，不能要求等于新import实例；当前请求/回复header和B、map中的新身份必须匹配当前实例。

**固定capability与握手增量**：ordinary required增加`checkpoint_observe_v1`、`checkpoint_export_v1`、`checkpoint_import_v1`、`checkpoint_activate_v1`；
source增加`checkpoint_blob_upload_v1`；view增加`checkpoint_blob_download_v1`；control沿原control_status/cancel，不宣称Marshal具备tactic软中断能力。
这些值加入对应channel的固定required集合及静态method映射，不要求每个channel都带全部6项；同版RC08/OC06产共同schema指纹。
NativeHelloAck不加巨大ABI字段；它仍核实际artifact/runtime与上述capabilities，缓存ABI在IR18文档逐字段核。
capabilities只报告真实已编入且用途/传输/根生命周期已接线的handler能力；生产发布/RunOperation必须另有U7验收，rmcp12小例不自动开启生产支持。
可信隔离IR07 CandidateProbe在首次smoke可通过真实握手报告上述已接线能力，以执行验收；这不登记production supported，也不以尚未产生的自身smoke PASS作为前置。
CandidateProbe用途沿IR18/IR21受信封闭调用链，actor不能选模式绕过；不新增wire字段、不按静态manifest补造能力，不改变摘要前像。

finish/retire仅清回执/执行资格，不删已完成export spool或PREPARED arena；BlobLease/ImportArena有独立有界保留账。
export spool只有M4明确seal或明确放弃且不再读时release；封存未知保占用/原热owner。import arena在PS30/NC08/PS31完成或NC09清理前一直受保护。
生命周期槽满阻止新checkpoint，不用丢历史/包/未决arena腾槽；未知操作需按原ID对账，不换operation重复Marshal/import。
checkpoint的OpStatus没有proof-step ACK状态：acked_through=0、last_ack=not_applicable、pending=not_applicable，不能WAIT_ACK。
artifact/arena的pending属于独立资源根，不塞进这个proof-step pending字段，也不使用unknown或known error变相扩该字段。
TERMINAL必须有known匹配原method/phase的AuxTerminal；RETIRING可保既有known Aux事实或unknown/not_applicable，但不能据状态字样推完成。
status/settle只在terminal=known时核对应Aux摘要；未知/N/A不传给W03。finished.key只与已核终态key匹配，不把裸K当可摘要record。

### 9.4 二进制传输：现有source/view通道的显式新分支

不使用UTF-8 source_begin/source_chunk或text view；不传FD整数/actor路径，不新建服务或第五通道。
这些ArtifactRef/二进制方法只在受控driver↔Pet链，不注册普通MCP下载工具；actor只能看DiskCheckpointRef的授权状态投影，不能凭hash/ID请求Marshal字节。
输入在现source channel新增下面三个method，输出在现view channel新增三个method；各通道仍单reader、原有独立rpc_seq/64KiB帧。
`CheckpointTransfer={transfer:Id,operation:Id,operation_seq:U,control:Id,attempt:Id,artifact:ArtifactRef}`，方向由method与登记决定。
transfer固定等于artifact.id（不由actor另选），完整lease键为(instance/epochs,operation,transfer,direction)；不同operation借同一不可变artifact不混消费进度。
NC03/NC06发布输出ArtifactRef前同时建立相应输出lease，因此finish后首次pull是读取既有lease，不是创建新transfer；输入lease由受预算的begin建立。
准备export_plan/import材料可先传输，但必须匹配已register_budget的next operation槽（不提前消费该seq）；失败后清本槽材料或保unknown，不开放任意blob上传。
在establish到达前，NC04按该槽NativeBudget.initial_request.method/phase应用下面方向表；只有purpose=export/import而没有匹配head不足以接收材料。

| channel/method | Args（全部） | Result.kind与全部字段 |
|---|---|---|
| source/checkpoint_blob_begin | `{transfer:CheckpointTransfer}` | `{kind:"checkpoint_blob_begun",transfer:Id,next_offset:U}` 或 `{kind:"checkpoint_blob_registered",artifact:ArtifactRef}` |
| source/checkpoint_blob_chunk | `{transfer:Id,operation:Id,offset:U,bytes:Base64}` | `{kind:"checkpoint_blob_chunk_ack",transfer:Id,offset:U,end_offset:U,digest:Digest}` 或 `{kind:"checkpoint_blob_retired",transfer:Id,next_offset:U}` |
| source/checkpoint_blob_finish | `{transfer:Id,operation:Id}` | `{kind:"checkpoint_blob_registered",artifact:ArtifactRef}` |
| view/checkpoint_blob_pull | `{transfer:CheckpointTransfer,expected_seq:U,offset:U,credit_bytes:U}` | `{kind:"checkpoint_blob_chunk",transfer:Id,seq:U,offset:U,end_offset:U,bytes:Base64,end:Bool}` 或 `{kind:"checkpoint_blob_retired",transfer:Id,next_offset:U}` |
| view/checkpoint_blob_ack | `{transfer:Id,operation:Id,seq:U,end_offset:U,digest:Digest}` | `{kind:"checkpoint_blob_acked",transfer:Id,seq:U,end_offset:U}` 或checkpoint_blob_retired |
| view/checkpoint_blob_release | `{transfer:Id,operation:Id,reason:"sealed"|"discarded",durable_record:Fact<Id>}` | `{kind:"checkpoint_blob_released",transfer:Id,status:"closing"|"released"}` |

请求/回复沿各channel现有 `{header,method,args}`、`{kind:"result",header,result}`/protocol_error外壳；加入封闭variant，不让普通source/text-view方法接受这些kind。
Base64沿§4.2规范但解码块是**任意字节**，1..8192，允许0x00/非法UTF-8；pull credit1..8192，不用text-view最小4规则。
每块digest为原字节SHA256。非终块正长度，唯一空EOF块可在offset=artifact.bytes；end iff end_offset=artifact.bytes。
输入chunk最近同offset/字节重发幂等，更旧retired且不验证旧内容；gap/冲突拒绝。finish必须完整长度+可信ArtifactRef摘要一致才登记。
输出一次pending块；checkpoint_blob_ack仅表示receiver已把本块完整写入自有受预算spool，**只是流控而非durable ACK**；同seq同offset/credit重发返回原块，异内容拒绝，不重新序列化。
ACK推进读cursor，不建立DiskCheckpointRecord或恢复保证。只有整对象接收/hash/PS02完整fsync与PS27封存明确成功，才允许释放export原生完整spool/退役原热owner。
release sealed对bundle/其manifest须known PS27记录；requirements/observation/map等metadata须known整对象PS02及其所属控制/计划/激活记录的消费确认，不能用逐块ACK代替。
discarded须known已登记放弃决定；unknown不释放，not_applicable非法。普通proof step ACK仍严格durable，不能把本条流控语义外推给ack_step。
export bundle与manifest输出transfer只绑定原export operation；import mapping绑定原import operation；plan/import manifest/bundle输入绑定当前导入/导出操作。
方向/kind精确限制：checkpoint_observe export无输入blob、输出只observation；checkpoint_observe import输入只preload_plan，输出只observation；
export collect输入只selection/compatibility，输出只requirements；export encode输入只plan/requirements/compatibility，输出只manifest/bundle；
import输入只plan/requirements/compatibility/manifest/bundle，输出只map；requirements的ref取manifest同名字段并须与plan登记一致；
activate不接新blob，仅引用原import已登记map。每operation同方向同kind至多一个artifact身份（重复同身份复用lease，不另分配），不把该通道开放成通用blob缓存。
**source_materials实际传入**：driver在PS29读取租约下先经PS17按sealed record的owning关系取得每个SourceRef的完整VerifiedByteStream，
将manifest/plan通过checkpoint blob完整登记并核验后，在当前唯一pending import预算槽建立SourceAllowlist=manifest.source_descriptors；
再用既有source_begin/source_chunk/source_finish（NB05）逐source预登记。NB05核id/digest/size与allowlist，原生不能直接调用Rust PS17或读取actor路径。
全部source登记事实确认后才发送checkpoint_import；任一失败保持暂停/清本次输入或unknown，不开始from_bytes。源ID是不可变材料身份，可沿用；它不等于复活旧StateRef。
配额沿现有NativeBootBinding.input_byte_quota：metadata+bundle+全部source_materials实际入站字节checked求和一次并预留，每个source不得重置；
重复同source身份已完整登记不重复分配，冲突拒绝。M2先核总量，原生各begin还核当前聚合占用；无额外通道/普通工具/每source新平台。
metadata_bytes约束该attempt全部同时保留metadata的总字节而非每文件独享；bundle_bytes约束整组唯一bundle，重传不重置总预留/期限。
buffer与spool并存阶段按真实双份物理占用计入各自内存/磁盘预算，已finish但尚有lease仍占资源账；新的operation不继承未核归还的免费额度。
finish_operation后仍可凭已登记transfer/lease对账/补读，不能拿退休operation创建新transfer；artifact引用已释放后报past_unavailable，不再生成。
坏帧/关联损坏仍隔离，输入/输出超时不自动删除未核消费的材料；控制channel独立但只能请求取消，reader仍受OCaml runtime锁/调度限制，不保证Marshal期间响应。
driver外部deadline/M2控制响应不等于原生停止；结束只认执行线程真实串行返回，或M2授权后ND05真实域核停，详见NC03。

### 9.5 具体函数与正确性论证

#### NC01 `observe_loaded_identity(instance) -> LoadedArtifactObservation | Incomplete`

pre：受管实例、安全串行点、固定安装已核；callee CK-LOAD/CK-SUMMARY、IR18。
启动时在Coq.Init传入的load_module与plugin_handler接缝安装单一ledger；plugin handler必须追到Fl_dynload最终resolved文件及其递归依赖，
每次load前核实际路径属于受管安装/环境并记录digest/length，成功后append ordinal/revision，失败保失败事实；静态linked载荷从IR05已验制品清单登记。
ArtifactIdentity.logical_id固定为实际canonical resolved文件路径这个稳定label，identity仍由sha256/size建立；不凭尚未传入的U7 prefix map生成虚构logical ID。
IR21核sealed期待文件仍在IR20安装根/const switch受信范围且当前字节一致；路径改变即缓存不兼容，不声称跨安装路径迁移。
同时在最外层成功初始化调用上记录initialization_steps：findlib_packages记录实际传给Fl_dynload的packages与该调用产生的ordered artifacts；
coq_init_module记录实际checked_load artifact；失败调用只留失败事实，不加入“成功可重放步骤”。递归依赖归所属调用，不伪造同一文件第二次初始化。
沿IR18唯一规则，只有造成新实际加载的成功调用进入initialization_steps；已在core/已经加载而零新增的调用不伪造一步，静态bootstrap不虚构Dynlink事件。
具体调用为`Coq.Loader.plugin_handler (Some (fun pkgs -> Fl_dynload.load_packages ~debug:false ~loadfile:checked_load pkgs))`，
Coq.Init的load_module也传同一`checked_load`；该闭包核文件再调用真实`Dynlink.loadfile`，返回后登记成功及`Dynlink.public_dynamically_loaded_units`新增units。
`Dynlink.main_program_units/all_units`只用于与静态/公开动态ledger交叉核，不声称覆盖loadfile_private（OCaml4.14 dynlink.mli:105–113明确不含private）。
生产支持集合须经U7验收确认不绕过该加载接缝；已知私有/旁路动态加载插件不在checkpoint支持面，不能以all_units为空差异假装完整。
不根据包名/serlib map猜最终文件；找不到真实resolved路径/存在旁路Dynlink/变化期间无法锁定的载荷则complete=false，禁止checkpoint，不伪全覆盖。
在安全点读取ledger与Summary.dump，排序注册(tag_decimal,name)并记录同一load_revision；期间新增load则重取一次有限重核，仍变返回Incomplete。
post为实际加载观测，IR18才与可信载荷相接产CheckpointCompatibility；固定有限ledger扫描受metadata/root预算。论证：每次加载动作是唯一写入者，卸载不存在时revision单调，未知不能变兼容。
运行时Freeze/Unfreeze触发新加载也经该hook；新插件改变compat使先前cache历史可读但不可当当前兼容缓存，不每tactic扫描安装树。
加载观测具体root `LoadedArtifactObservation` 及对应resolved-path事实由IR18文档定义；本函数是运行时生产者，不从安装manifest复制一份“已加载”数组。
完整字段与[install-release.md §9.1](install-release.md)逐项对齐：ocaml_version=Sys.ocaml_version、word_size=Sys.word_size（只32/64）、
endian由Sys.big_endian、mode由Sys.backend_type的Native/Bytecode（Other拒cache）；这四项从原生当前runtime读取，不从配置期待回填。
OCaml4.14 Unix未提供本设计可用的uname接口；platform.system/architecture由Rust driver在已核DomainIdentity/同host启动边界调用`libc::uname`取得sysname/machine，
与原生Sys.os_type/word_size和实际被exec容器一致性校验后作为NC01的已核平台输入合并，失败为Incomplete；不运行任意uname shell，也不把跨机导入当本地支持。
pet/rocq/ocaml_runtime若embedded，resolved_path指IR13已核实际可执行容器/实际runtime文件及其构建链接归属；dynamic只取checked_load实际路径。
静态容器标签直接取IR13/ND01真实launch文件事实并与当前Sys.executable_name/实际runtime容器核对，不从package字符串反推静态库路径。
这些角色由IR05/IR13生产的真实link记录归属，不从Summary名字猜载荷角色；capabilities只读当前真正handler集合，load_revision来自ledger而非版本字串。

#### NC02 `collect_checkpoint_roots(selection: CheckpointGroup, phase: Collect | Encode(plan, requirements), budget) -> Requirements | (ExportLease * PackedGraphSkeleton) | Error`

pre：M4 preliminary selection已有durable控制记录、M2已封选中scope的新派发/写者，pending ACK与在途eval已对账；budget purpose=export且绑定control/attempt/group实际源环境。
callee NR01/NR02、CK-M4、NC01；先核selection字节/digest/全字段、B.primary source/env，逐path经group.line_bindings取真实native Line ID/expected revision，
与Registry核对应native版本及选中路径边界；logical path_revision只核selection/requirements/PS26一致，不拿它和native revision比较→逐Boundary定位实际已ACK Node→取parent闭包。
scope亦经group.owner_scope→group.native_scope实际映射核，选中line必须属后者；support/shared祖先可有其它owner引用，打包不撤其引用也不授其执行权。
任何漏root/非采用候选/旧源/错target/未durable node立即失败，不降级frontier。按真实Node Id去重，parent先于子赋index，路径边界不去重丢别名。
建立checkpoint_export Borrow后再取state/AST/doc投影；无pending/inflight要求也包括本scope live view借用，M6须停新生成并排空；其它scope owner保留。
Collect分支：汇总实际Node执行source、doc.source_ids及alias祖先/publication，从已登记source表给每ID实际digest/bytes描述，写Requirements受控metadata→释放本次临时Borrow，line owner不变，返回完整requirements，不Marshal。
Encode分支：额外要求PS26完整plan已durable、requirements在其记录中；逐项核重新收集集合等于已确认requirements、source全部在plan.source_materials、alias publication已有durable应用记录；
失败不增补plan，保持暂停并要求重新collect/fix计划；成功才返回仍持Borrow的PackedGraphSkeleton供NC03。
失败释放本次Borrow但不撤line owner；释放未知返回unknown/占账。post选中全部边界+support roots强保且原采用路径未改。
循环worklist每次消费未见Node，visited按身份、DAG parent单调，有限root_count上界；超过预算报RESOURCE_LIMIT不截根。
论证：M4完整列表是覆盖基准、Registry实际节点为事实，两者exact-set相交核而非单方自述；一个包同时持所有state引用保共享。

#### NC03 `checkpoint_export(binding, phase, selection_or_plan, requirements?, group, compatibility) -> AuxTerminal`

pre：普通method/NW02用途核通过，CK-M4 intent durable；callee NC02、NC01/IR18、OC04/05、Marshal.to_buffer、受管spool IO。`requirements?`只是函数局部分支记法，wire两phase字段严格按上表不使用null。
固定compat与load_revision→NC02收根；collect分支封存requirements spool/lease并返回checkpoint_collected终态，绝不走Marshal；encode分支才继续：
规范manifest→构造唯一PackedGraph→预留有限buffer `Bytes.create bundle_bytes`→
一次 `Marshal.to_buffer buffer 0 capacity graph []` 返回used长度→只写buffer[0:used]到私有spool→hash/完整封存该原生spool→发布manifest/bundle ArtifactRef与稳定checkpoint_exported终态。
不用Coq.State.marshal_out循环，不先Marshal.to_string无限分配；to_buffer满/functional/custom value不可序列化明确失败，不改Closures/No_sharing。
buffer和Marshal内部共享表的峰值都在M2已授予内存额度内，bundle_bytes不得只占磁盘不占内存；大于能力返回资源不足，不声称无限图保证。
任何阶段错误丢本次未完成spool/buffer、NR03释export borrow（原热owner仍在）；清理或Marshal中断停稳未知保root/spool账并交M2，不能仅因上层取消当导出失败已清完。
成功后ExportLease可释放临时state Borrow，但**原热owner仍保到PS27明确封存后旧退役动作**；BlobLease留到M4消费/release，不由finish删。
有限集合/used字节写循环，write短写推进offset，零进度/期限/IO错误退出；Marshal C路径不能保证Token可中断，按已有软尝试/域核停事实报告，不宣称rmcp12验了中断。
大小实际硬界为预分配buffer capacity与spool写used长度；时间由driver独立单调deadline监测，内存由ND04实际生效域限额/采样保护治理，
不是Marshal API自带timeout，也不在Marshal期间持control锁。deadline到先封该操作继续步骤并记录BLOCKED/unknown，控制token仅记录请求，不报告已停。
Marshal后来返回时执行线程先核已取消/超期，丢未封存候选并清临时Borrow，恢复可核后才报告停止；不得把迟到成功交PS27当准时完成。
无失控增长/安全风险时不为满足导出deadline杀仍持唯一未封存热态的共享实例；保持暂停/占用交M2显式处置。
触及既有硬保护/真实服务故障才按M2已批准隔离/ND05核停，保原持久脚本及unknown尾，承认本次无磁盘恢复保证；不把kernel/外部OOM归咎于“已安全封存”。
论证：一次整体Marshal []保跨root共享；只有完整字节+manifest才给成功；PS27不是本函数内隐式动作，封存前不退役唯一热态。
若后端被硬杀，热态当然失效，诚实报告BACKEND_EXIT/unknown；不为保本scope回收擅杀同实例其它scope，是否核停由M2故障规则决定。

#### NC04 `transfer_checkpoint_blob(channel, message, lease) -> BinaryTransferResult`

pre：现四通道完成握手、匹配预算/next或已登记operation、ArtifactRef来自受信生产者；callee ND02/03、OC03/04、标准Base64/SHA256、PS02/PS17。
begin核kind/方向/预算后建立私有staging；chunk先核raw长度、offset、总size，再增量write/hash；finish全长摘要通过才登记。
metadata类finish还经OC01–03具体route核完整文档；import的plan/requirements/manifest在任意一次finish后若均已登记，
就在NC04的串行metadata提交点核三者cross-ref、source集合/descriptor与当前唯一pending-import预算绑定，构造ImportInputs.SourceAllowlist。
cross-ref先区分当前请求Ref与嵌入历史Ref：前者逐字段exact；后者调用PS35规则以三元组解析到当前已授权材料，不能把旧native ID不存在当包损坏或全局忽略所有id。
缺任一文档仅登记该材料、不等待同loop后续消息且不开放NB05；cross-ref冲突返回binding_conflict、不建立allowlist。这一步早于checkpoint_import/NC06且不Marshal。
NB05完成各source后把实际注册事实写入同ImportInputs；NC06入口exact-set核全部完成。ImportInputs本身及未消费输入也由NC09/NR04清理，不能等arena创建后才计根。
输出pull只读原生已完整生成spool，登记pending byte块，重复返回原块；Rust receiver在自有私有目录创建唯一spool（非actor路径），
循环write_all本块到精确offset并核写量、更新hash后才给流控ACK；此时不要求fsync/不称durable。短写继续，零进度/磁盘满/取消/关联错不ACK。
接收完整对象后核总长度/digest，才把整spool交PS02整体持久化与PS27/相应owner提交；若receiver丢失未封存spool，记录失败/unknown、无DiskRef，
原生仍保完整export spool及原热owner，不因为已ACK若干块清掉唯一副本；不得自动重跑原证明或重复Marshal。
ACK核完整身份/seq/end/digest后推进，release依§9.4整对象封存/消费/放弃事实排空后删自有材料；receiver清理只删自身绑定的spool，删除/在途write未核清仍计占用。
缺/旧/错身份先拒绝再读缓存；存储失败/断线不改原export/import事实。回执未知保lease，不因TTL/operation finish虚还资源。
循环剩余字节严格递减或超期，至少1字节块、受总bytes和原deadline约束，最近ACK/pending有界；post完整可信材料或明确未完成，绝不UTF8解码bundle。
论证：Base64只是帧编码，原字节摘要/长度在登记前闭合；通道/方向/操作隔离防把source或text view混认checkpoint包。

#### NC05 `initialize_checkpoint_import(driver: Driver, launch: VerifiedLoadedInstallation, sealed_compatibility, preload_plan: CheckpointPreloadPlan, current_inputs) -> ObservedCheckpointRuntime | Error`

pre：MS33已经按IR13磁盘LaunchPlan→ND01受预算启动/握手空实例→ND07实际身份→IR20→IR21产preload_plan的顺序执行；
driver/launch/plan属于同一当前checkpoint_control实例，尚无业务line/活动task，BO22输入无pending。本函数不再次spawn、不再次创建launch或preload_plan。
本阶段只要求PS29的CheckpointLoadPreparation/只读lease，不要求CheckpointImportPermit或current compatibility；后者必须由本阶段实际观测之后产生。
callee ND04/NW02、NC04/NC10（其内部NC05a/NC01）、OC03及PS02/PS35完整材料捕获；不把IR20当成可在Driver出生前调用的磁盘检查。
先核launch/current_inputs/plan与driver关联及plan.compatibility_digest对应sealed_compatibility，再为本次observe分配新operation/预算，
ND04确认实际额度→NW02登记匹配initial_request head→NC04上传既有IR21计划→调用checkpoint_observe(preload=known plan)→
NC10原生执行NC05a的必要初始化后缀并由NC01产生真实观测→driver完整捕获并校验observation字节/绑定，返回`ObservedCheckpointRuntime={observation:LoadedArtifactObservation,material:ArtifactRef}`。
material由PS02/PS35完整捕获生产；本返回不包含current compatibility或import许可。MS33随后唯一调用IR18/IR19，再由PS36重核当前输入/权限/预算并持久admit；
不在NC05内部重复该调用链，也不把NC01当Rust可直接调用的函数。完整sealed compatibility留Rust caller作IR19比较，原生只收到受控preload_plan。
preload只从已核安装映射取得库/插件；当前初始化ledger必须是sealed步骤的已核前缀，只执行剩余步骤，差异拒绝，不重复已加载插件初始化。
不调用Agent.start/Doc.check/Agent.run重放待恢复proof前缀；Prelude/runtime初始化单独记成本，不伪称完全零执行。
无法完成加载顺序/真实观测、失败或额外模块未知则拒进入后续比较/装载并清新实例；停不清占账。post为已隔离实例的真实观测，不自行宣称相容或恢复原scope授权。
有限插件清单/初始化阶段受import总deadline，不能无限装包重试；论证新实例隔离旧在途state，初始化仅建立解析/解释所需runtime，身份与旧代码 exact相容才反序列化。

#### NC05a `preload_runtime(plan: CheckpointPreloadPlan, token) -> PreparedRuntime | Error`（OCaml私有callee）

pre：NC10 import分支、新空实例、IR21产且完整受控传入plan；callee checked_load、Fl_dynload.load_packages、NC01 ledger。
核当前operation/boot/budget绑定及plan确为当前driver登记的IR21材料（安装/平台/expected文档前置由Rust IR20/IR21负责，plan本身无伪造的instance字段）→
核当前成功初始化步骤是plan.steps去resolved路径后的expected序列的真实前缀→逐剩余步骤执行；完整Summary/ABI的比对在NC01返回后由IR19执行，不把digest当该比对已完成。
findlib_packages按计划packages调用真实Fl_dynload.load_packages ~loadfile:checked_load；module步骤调用与Coq.Init.load_module相同的checked_load闭包，
不是调用一个不存在的Coq.Init.load_module函数。每个resolved文件先比IR21给定expected sha/size/受管路径，加载完成后核实际ordered artifacts和期望exact。
IR21不在Rust复制Findlib解析：包列表取旧成功调用，当前真实文件次序由此Fl_dynload调用产生，checked_load与已核expected文件序列逐项对账；缺/多/顺序不同即拒。
任何文件/顺序/额外依赖/初始化失败立即停止，不尝试别的包名或路径；部分已加载不能卸载，保持新实例隔离并交M2核停，不假回滚为未加载。
无proof source执行；有限step/artifact清单、原import deadline与域内存界，动态加载不可中断时不假Token成功。post完整准备或明确不完整，不产生可用root/权限。
论证：可执行配方来自实际旧调用与当前可信解析，不从logical_name猜初始化；加载副作用在空新实例内，失败不污染原热态。

#### NC06 `checkpoint_import(binding, cache, plan, group, manifest, bundle, compatibility) -> AuxTerminal`

pre：PS29 prepare取得sealed cache读取租约；NC05实际观测/IR19比较完成后PS36明确提交CheckpointImportPermit，driver只有持此permit才可发送checkpoint_import，
不能凭PS29 lease/ND01 ready/compatibility字符串跳过admit。当前输入/权限/预算由PS36再次核；purpose=import、NC05空实例、无其它scope可受损；
§9.4 driver已将全部retained_sources经NB05完整预登记。
callee NC04/OC01–03、原生source表、Marshal.total_size/from_bytes、NC07、NR02/NR07；不把PS17写成OCaml可直接调用的callee。
先按既有operation幂等表处理重发；同operation返回原状态/终态，不再次from_bytes。新operation若实例已有任何ImportArena或公开业务line，立即拒绝，
不能以“仍暂停/没有普通task”判空再次装载；此拒绝不清前一个operation已有arena。失败清理只针对本次新建资源集合。
先核可信sealed record及ArtifactRef exact（不接actor Marshal）→完整收/验manifest和bundle原字节→核compat逐字段与当前NC01观测→核manifest覆盖PS26/PS29计划，
其中嵌入manifest的plan/requirements/compatibility历史Ref只按上述受控三元组规则与当前材料相接；当前checkpoint_import Args及返回echo仍全Ref精确。
在已预留encoded bytes+decoded graph峰值内读bundle buffer；先核长度≥Marshal.header_size、所有U→int/加法不溢出，再核Marshal.total_size=完整长度/无尾随→
单次 `Marshal.from_bytes bytes 0 : PackedGraph`→核内置format/manifest字节等于外层可信manifest。
Marshal不是不可信输入安全解析器；只有受管M4原产物链+真实摘要验证后才调用，不以“有类型注解”声称任意字节安全。坏包/缺包/不兼容在前置拒绝，无隐式重放。
建立checkpoint_import arena、逐node核metadata/index/parent/source/AST范围，分配**新**node/line/context ID，调用NR07建立自有RestoredHistoryIndex；
不导入旧table/IDs/预算/control cell，不从外部构造private Fleche.Doc.t/Node.t，也不假定Doc.create会装入历史nodes。
NC07对所有unique root完成actual access后，构造完整Boundary→新locator map，封存mapping artifact，再产生稳定checkpoint_imported终态；arena=PREPARED，不在NR01公共查表可借。
部分失败清当前安装state→清临时memo/import/feedback/local references→NC09删除arena；失败/停稳未知隔离新实例，M2可ND05核停，仍暂停/占用，不并入旧实例。
不从成功导入伪造StepRecord或重新运行已成功tactic；成功脚本依旧来自M4原记录。有限nodes/root预算，解码本身受域内存/外层deadline，不能承诺任意Marshal自动可取消。
论证：可信bytes与exact兼容先于解码；新映射完全覆盖已封存路径但在当前性提交前不可执行，旧StateRef永不复活。

#### NC06D `dispatch_checkpoint_import(driver, permit: CheckpointImportPermit, native_budget: NativeBudget, request) -> TransportFact`（Rust）

pre：PS36明确admitted，permit只来自当前control的M4结果；callee PS36记录绑定、ND04/NW02/ND02和W02。
核permit.control/cache/attempt/instance/epochs与request/driver，核permit.budget **等于本次NC06独立operation的NativeBudget.budget**；
它不等于MemoryGrant ID，也不假等于CheckpointLoadAttempt.budget（后者是ExecutionBudgetRecord）。兼容记录ID先按其已核生产关联解析到本request的compatibility材料，不把record ID当blob hash比较。
核native_budget.initial_request恰为checkpoint_import/N/A/本W02摘要、operation/seq/source/env以及grant/revision来自当前已生效M2投影，所有期限不超已批准总预算。
ND04幂等确认实际grant仍生效→NW02确认本次register_budget→确认完整材料/source预登记→ND02发送NC06请求；任何前置失败不发import，不把已占input资源当自动释放。
发送后未知沿ND02/原operation对账，不能换permit/budget重发新import。无新wire load_admission字段，原生仍做自己实际compat/source/root校验；
有限字段检查/有界caller IO，返回是事实不是“已激活”。论证PS29仅读取权、PS36派发准入、native加载三者不互相冒充，预算身份跨域不误等。

#### NC07 `probe_imported_roots(arena, manifest, token) -> ImportValidation | Error`

pre：arena未公开、scope保持暂停，所有root objects来自一次已验包；callee Coq.State.in_state/lemmas/program/parsing、Coq.Goals.reify、NC01。
按index逐root：`Coq.State.in_state ~token ~st ~f` 实际unfreeze；读lemmas/program/parsing，若有proof则`Coq.Goals.reify ~ppx:(fun _ _ _ -> ()) ~compact:false`核五组结构可访问，
不打印整term，不调用tactic/Agent.run、不用hash相等替代访问。记录每root已核，恢复bootstrap/先前合法current后才下一项。
每次unfreeze后核loaded revision和Summary.dump与预期兼容（ML summary可有隐藏加载）；未知/新增不相等即失败并隔离，不把异常丢为None proof。
全部root才validation=all_roots_accessible；任一失败map不发布成功，NC09清理。循环index递增到root_count，整次沿原import deadline/Token，无逐root刷新。
论证：真实Unfreeze及结构访问闭合“读到一个OCaml对象”与“可作为当前Rocq状态”的接缝；不扩大为任意插件语义恢复定理，后继真实续证/T30另验。

#### NC08 `checkpoint_activate(binding, import_receipt, activation, mapping) -> AuxTerminal`

pre：PS30当前性/映射CAS已提交但范围仍暂停；新operation/new import-purpose budget，control/attempt/cache/import/instance/epochs均匹配PREPARED arena。
callee CK-M4 ActivationPermit、NC01/BO23的当前绑定事实、NR02。
核导入K及mapping ArtifactRef digest/长度、全部permit字段和binding_revision→核新owner只为本scope/本arena、无另一个line占同逻辑目标→一次NR02发布新nodes/lines/context并arena=ACTIVATED→稳定checkpoint_activated回执。
发布前错身份/输入/额度拒绝且保持PREPARED；发布后丢回执按同operation查询。同permit只能绑定首次接受的activation operation；
另一operation重用该permit返回binding_conflict并指向原操作诊断，不把旧B的回执冒充新B响应、不再次发布；同operation同摘要返回稳定回执，异permit/内容拒绝。
这一步不执行tactic、不解除Manager pause；driver记录native ACK后由PS31再核输入/权限/gate/path exact-set，只有PS31才开放。
PS30后输入变/撤权时PS31拒绝，M2封派发并NC09清理新owner；未知仍占账。有限map/owner遍历，原子发布前预分配，失败POISONED沿NR02合同。
论证：数据库permit、原生激活、最终Manager准入是三个可对账点，不把任一点当其它两个事实，旧权限不由反序列化恢复。

#### NC09 `discard_checkpoint_arena(scope, retirement, resources: ExportLease | ImportInputs | ImportArena | BlobLease) -> NativeReclaim`

pre：M2登记退役/放弃，暂停新使用；或本函数处理确定失败的本次私有对象；callee NR03/NR04、CK-STATE、NC04释放、必要ND05由M2授权。
核本scope/epochs→关新blob pull/新borrow→在途IO/ACK未决返closing→若current指本arena则恢复bootstrap→撤doc/toc/index/nodes/lines、memo/import缓存和局部strong refs→清自有spool/buffer。
此处恢复bootstrap是`Coq.State.in_state ~token ~st:bootstrap ~f:(fun () -> ()) ()`的真实Unfreeze，不调用NB04/N07通用tactic恢复probe、不执行原证明。
Unfreeze失败或部分preload不可恢复时保持隔离/unknown交M2核停；不据清理成功自动把失败新实例标为可继续证明。
其它scope共享owner保留；ExportLease清理不等于撤原热line，只有PS27封存后的显式retirement才撤原line。
establish业务拒绝时也对其预输入BlobLease执行本地清理（不close原热scope）；若删文件/排空IO未知则保该lease及绑定预算，
not_admitted只说明未开始该业务动作，不冒充输入spool/内存已释放；回执水位推进不能抹掉这些资源事实。
ImportArena ACTIVATED但PS31未开放也按同机制清新owner，不把“已激活”解释为必须继续。所有RootKind实际adapter确认后才released/closed，否则unknown继续计费。
循环只扫有限登记根与lease；不在同loop等M4消息；阻塞返回closing供外层对账，不无限轮询。
论证：回执、磁盘包、热引用分别有寿命，失败清理不误删唯一成功脚本/其它scope；清不清楚永不虚报内存归还。

#### NC10 `checkpoint_observe(binding, control, attempt, preload) -> AuxTerminal`

pre：NW02登记当前checkpoint用途、相同control/attempt，新operation/metadata额度；调用意图已durable，但不要求已有当前CheckpointCompatibility。
import observe的B.context是M2预留新context、B.source是M4选定历史组的真实代表源；这里只核boot/current budget/control与IR21 preload绑定，
**不要求source/node已在Registry，也不要求已存在导入root或完整plan**。NW02此purpose/method分支允许这些已由M2核准的预留引用，不能套普通query的NR01借用前置。
export observe则核已有context/environment的安全串行点与实际ledger；此例外仅为observe/import初始化，不让checkpoint票凭预留ID执行普通tactic。
callee OC03/04/05、NC05a（仅import）、NC01及有界metadata spool。
export要求preload=not_applicable、实例串行安全点，直接NC01观察；import要求known checkpoint_preload_plan且是IR21/PS29登记材料，
先NC05a完成实际初始化，再NC01观察。完整观测按IR18共享LoadedArtifactObservation编码成checkpoint_observation artifact，建立输出lease→稳定checkpoint_observed终态。
未知/不完整观测返回checkpoint_validate error（不生成完整compat）；export不因此释放仍有效主线，import失败清新实例/保暂停；序列化/输出未知不重复加载或换新op猜成功。
正常终态/status重读复用同artifact，不重新运行初始化；预算/nonce/源环境错拒绝。metadata超界给资源错误、不截loaded/summary表。
所有清单/字节处理有限并沿原deadline；post给Rust真实当前观察而非“相容”裁决，IR18/19在完整取得字节后执行，消除观测前要compat的循环。
导出/装载正式执行前NC03/NC06仍重核NC01事实与已传compat；另一scope在两RPC之间加载新插件会使当前性检查失败，不把旧observer结果永久视为当前。

#### NC11 `settle_checkpoint(binding, exited: ExitedCheckpoint) -> OpStatus | AuxTerminal`

由rmcp7 N07按原建立method派发，唯一executor可构造私有`ExitedCheckpoint={method;phase;execution_returned;resources;known_extent;failure_stage}`；
它来自NC03/NC05a/NC06/NC08真实返回及本次资源登记，不可从控制reader cancel_ack/等待Future取消造出。
pre：原操作尚未终态、stop_requested锁存、唯一执行线程确认原生动作已返回；若原操作已有AnyTerminal，N07直接纯读原终态，不进入本函数。
callee NC09及各原方法真实完成事实；先核binding/method/phase与私有exit事实→封本操作新生成/传输→逐资源分类清理：
export collect/encode只清未公开候选spool、buffer与ExportLease临时Borrow，**保原有效line owner**；import或import-observe清ImportInputs/未激活arena及本次runtime临时对象，
动态加载部分成功不能卸载，实例保持隔离；export-observe只清未公布metadata，不改Rocq state；activate若NR02已原子应用则必须读取其稳定Aux成功，不改写为取消失败。
所有资源已确定处理且执行确实退出，才以原method允许的共同Aux error、实际known_extent及对应checkpoint_* stage生成稳定终态key并原子标TERMINAL。
若仍有IO借用/清理未知/执行返回事实不明，返回真实OpStatus(RETIRING、terminal未知/N/A)，保占用/隔离，不造Receipt.interrupted、不调用C2/tactic恢复probe。
stage选取collect→checkpoint_collect、encode→checkpoint_encode、import解码→checkpoint_decode/访问→checkpoint_validate、observe→checkpoint_validate、activate→checkpoint_activate。
known_extent只能由实际阶段记录导出；发生过初始化/编码/装载不能降成not_started。bounded资源遍历与原清理deadline，未完返回，不等同loop下一ACK、不无限重试。
论证：checkpoint取消路径使用真实序列化/装载生命周期，而不是假定它有tactic前驱状态；已完成终态不变，未完成未知不伪停稳，封存前原热owner仍保留。

#### NR07 `restore_history_index(packed_docs, packed_lines, manifest, new_nodes, new_lines, retained_sources, current_env) -> RestoredHistoryIndex | Error`

pre：NC06已核trusted bundle与全部metadata，显式传入其中packed_docs/packed_lines及已核CheckpointCoverageManifest，
new_nodes是本arena新ID→Coq.State/AST对象表；source字节由driver经PS17/NB05完整校验并在原生表中，环境当前。
new_lines由NC06本次分配，精确给每packed_line.lineage对应的新NativeLine ID/初始revision=0；不能从旧lineage字符串推导新ID。
callee是本模块纯索引构造、官方Contents/byte→UTF16位置工具，不调用Doc.check/Agent.start/run或解释前缀。
私有`RestoredHistoryIndex={by_boundary:(CheckpointBoundary,node_id) map;
by_source_boundary:(native_line_id*source_id*byte_offset,node_id list) map;
toc:(native_line_id,restored_toc_entry array) map;
paths:(native_line_id,{logical_lineage:Id;imported_path_revision:U;entry:node_id;frontier:node_id;boundaries:CheckpointBoundary array}) map;
source_materials:immutable source map;aliases:source_alias array}`，只由Registry持有，存续/退役同line owner。
imported_path_revision只保旧路径出处，不能与新Native Line.revision比较；NN01先核真实native版本，再按选定native_line_id查索引。
by_boundary是恢复权威键；source位置只是可多命中的辅助索引，不假设同一脚本SourceRef/range只能消费一次。支持root的定位另由new_nodes/index映射承载，不伪造成durable step。
先逐packed_doc核source_ids在retained集合、每node_index存在且source/range正确→以manifest.boundaries显式核每packed_line的lineage、boundary序列与node index，
建立每path独立entry/frontier与by_boundary；相同CheckpointBoundary只能对应相同node，否则拒矛盾。
再依每packed_line经new_lines映射及其parent闭包按(native_line_id,source,offset)收**全部**合法node，列表只按node ID去重复而不按hash合并；
同一路径两次执行同source/range得到不同node也都保留，不能因此拒整包→
核toc的node_index与range、parent在本数组且拓扑在前/范围包含、别名确为已持久NR05事实→建新index后附到arena的Context.history=Restored。
每条toc entry按node所属的lineage parent闭包及new_lines映射投影到对应native_line_id的toc桶，连同必要的toc父链保留；为各桶按原先后建立old-entry-index→new-index映射并重写parent。
若父entry所需node不在该路径已保存闭包，拒不完整包而非留下悬空parent。只同名/source相等不赋给另一独立重算路径，NN01/NN06在已选lineage桶内查询。
doc创建过程只用于NC05 bootstrap/environment，不作为此函数callee；Fleche.Doc.t/Node.t的private可构造性与本索引无关。
任何缺source/坏index/UTF16转换失败拒整索引，已分配私有结构交NC09清；不以空toc冒充成功。有限node/source/toc数组遍历，checked尺寸和metadata预算，失败不eval。
post重复open/position/theorem定位可以仅取真实新node，且与原保存语句边界一致；不宣称恢复Flèche原始诊断/性能缓存或完整Doc容器。
旧ProofRef/step恢复由M2根据map/本索引的精确CheckpointBoundary取新node，再交fork/advance等方法，不从source位置反猜step；
仅提供source位置的NN01即使已选lineage仍可能多命中，此时拒歧义并保全部root，不静默取最后一个，也不宣称旧点无法精确恢复。
论证：查询索引来自已封存且已核真实节点元数据，恢复只映射身份/坐标、不重新解释；source精确校验排除同名不同文件的定位污染。

**history变体的完整caller接线**：NN01先核相同source/env/revision及请求lineage，按上述known/唯一性规则选定路径，再match history；DocBacked沿现有Doc路径，Restored从NR07索引查边界/实际toc。
命中直接返回新locator，缺少尚未执行的后缀目标返回needs_prefix并从最近已保存合法前驱走rmcp7逐句推进，不能调用Doc.check把已保存前缀重新跑一遍。
NB01后继解析依赖实际父Coq.State.parsing/Tracked parsable，不要求父来自Fleche.Doc.Node；ACK把新node同时接入当前history索引。
后续ACK/select/source-invalid改变采用路径时，NR02同时按新Native Line真实祖先闭包维护该line的source多值索引/toc/entry/frontier；
只保仍有该line owner的旧边界，不把imported_path_revision悄悄递增为M4权威或凭它授权新请求。
NR05/NN03对两种history都按真实SourceSpan/read_horizon截失效后缀，保前缀；NN06 toc selector对Restored投影保存的typed toc，
目标/假设/查询语义仍使用实际loaded state。NR04/NC09清RestoredHistoryIndex强引用，不遗漏其source/toc/node map。

### 9.6 既有consumer必须同批修改

| consumer | 本增量的确定变更 |
|---|---|
| ND01/NW01/NativeBootBinding | 启动来源可为M2 checkpoint_control，仍受固定安装/域核验；runtime实际加载观测供NC01，不以旧WorkGrant建立新owner |
| ND04/MemoryGrant实际应用 | 新MemoryExecutionBinding checkpoint_control投影到本实例/attempt的NativeBudget purpose；只在域额度实际ACK后register，不把同control额外峰值给普通task |
| NW02/NativeBudget | 精确purpose/checkpoint_limits与操作表绑定；checkpoint大额度不能借给普通tactic；deadline不因传块/每root核验重置 |
| ND02/D04/W01/OC03/OC06 | 四普通方法及六binary channel method的exact request/result matrix；新增stage/aux kinds/RootKind进静态typed映射及manifest，不是只加capability文字 |
| N-operation_status/N07 settle/N08 finish/retire | AnyTerminal保原checkpoint事实；未终态checkpoint只路由NC11（不走通用C2恢复probe/Receipt.interrupted）；finish不释放独立artifact/arena，操作表仍有限 |
| NR01/NR02/NR04/NR06 | PREPARED arena不可借；激活后current M2票才能派发；全根清理/audit新增两真实容器；ID索引不保隐藏强根 |
| NR07/NN01/NB01/NN03/NN06 | Context.history显式DocBacked/Restored，重复open/旧位置/toc走新索引不check旧前缀；后继parser从真实父state继续 |
| source/view parser及NB03/NB05 | 新显式binary variants走NC04；旧source UTF8/text view规则不改变，不拿Base64字符串当原字节offset |
| M4 PS26–31/PS36、M2 MS33 | 同源覆盖与封存/导入/激活事实；PS29 prepare→真实observe/IR19→PS36 admit→NC06，PS31最终当前性检查不可省；record/plan/schema唯一由其owner维护 |
| IR18/BO22/BO23 | 实际加载compat与源环境前后核；unfreeze隐含加载变化使cache拒用，不默许旧schema兼容 |

### 9.7 失败窗口与不变量

- export未封存或PS27未知：保原有效热owner，保传输/磁盘预算，查原control；不依据bundle文件存在退役。
- 部分group成功：每group各自AuxTerminal/PS27/retirement；未成功group保持暂停热态，整control不报全部已磁盘化。
- import前失配/坏包：不反序列化、无new state；import中异常/原生失联：隔离新实例，保读取租约与未决额度直至实际核停。
- import完成/PS30提交/NC08 ACK/PS31开放各窗崩溃：原ID对账；Manager重启不接管未知Pet，旧映射不复活，包仍由sealed record保留。
- 坏frame/超预算/取消遵既有unknown原则；Marshal的长C调用不能用async Future取消宣称停止。复用M2 stop机制，不让dump线程与Rocq并发。
- I-CK1：每公开恢复Boundary对应一条既有durable成功路径与真实frozen root；I-CK2：一次Marshal同包完整root集，share不靠外层重建；
  I-CK3：PS27明确封存先于旧热owner撤销；I-CK4：新实例/新locator+PS30/NC08/PS31三点闭合才可执行；I-CK5：unknown根/IO继续占账。

### 9.8 增量测试设计、反验与§4.4状态

本轮全部为测试设计，新增执行0，不重复计rmcp12 PASS。

| ID | 测试与必需观察 | 反验 |
|---|---|---|
| CK-PBT1 | 合法多lineage共享DAG→生产NC02 manifest，全部Boundary exact-set、parent拓扑、shared oldNode同newNode；多上下文逐group | 漏entry/旧step、夹探索尾、按hash合节点、每root单独Marshal均须区分失败 |
| CK-PBT2 | 任意binary字节分块往返，0x00/非法UTF8/长度边界/重复ACK/方向/操作错绑定 | 错用text-view min4/UTF8/source digest或Base64字符offset必红 |
| CK-PBT3 | 全部checkpoint目的×全部method矩阵、控制grant/attempt/source/env置换 | checkpoint票调用begin/query、换control/换scope/旧epoch activate全拒 |
| CK-W1 | export收根/编码/传输/PS02/PS27各前后故障，封存未知查原key | 在明确seal前end_scope撤唯一owner、finish删spool、TTL删受保护cache均红 |
| CK-W2 | import逐root异常、unfreeze新增插件、PS30后源改/撤权/新gate、NC08丢ACK、PS31拒绝 | 只凭imported/PS30/ACK任一项放行须红；partial arena仍有current/memo强根须红 |
| CK-E1 | 真新进程全部旧句界直接回取、每边界真实无前缀eval marker，选早期/末态继续至Qed并核假设 | 冷重放、只留末态、沿旧locator、用hash/耗时冒充免重放须红 |
| CK-E2 | 真实VST及拟支持插件/动态summary，默认Marshal支持面、内存/磁盘/时限与共享成本 | functional/custom值失败不得切Closures；37行成功不替该项；输出缺identity报未验 |
| CK-E3 | 原实例其它scope共享根，暂停一scope导出/退役后其它目标继续；全root adapter清理与Weak witness | 直接kill共享Pet作为正常释放、只删Registry统计留下doc/current/memo须红 |

CK-PBT3另核observe首次import允许已核预留context且无Registry root，不能为了让它通过而放宽普通query；collect/encode不同phase绑定不同operation，
重新收根新增support source必须使旧requirements失败，不能悄悄补plan。CK-E1必须包含恢复后重复NN01 open/旧位置/typed toc与后续NB01推进，
只用StateRef直取而遗漏真实Context.history consumer不算恢复入口验收。
CK-PBT1正例必须包含同source/offset但不同lineage独立重算的两个不同Node，恢复后按各lineage都能定位；把索引缩回二元(source,offset)必须被击中。
CK-PBT3逐一删除/替换source_materials、篡改NB05 size/digest、在全部源登记前发checkpoint_import、每源重置quota，都必须在解码/激活前拒绝；
NR02变异只发布nodes不发布line/arena或先置ACTIVATED再查permit须红，不能只测NC08外层返回tag。

完整性自检：NC01–11、NC05a、NC06D、NR07、ND07逐函数pre/post/callee/分支/失败副作用/循环及论证已列；binary方案、所有权与完整身份字段已指定。
剩余门：跨owner固定record/静态method/schema向量exact-set核对、独立§4.4复核、rmcp13增量Step0；上述通过前不借旧U3/U0签字编码。
本节度量：设计增量4轮、新增函数15、代码变更0、新运行测试0；本设计涉及文件1，生产bug修复0，测试通过率N/A。

## 10. CS5-B：管理Control冷重放的Rust driver接线

本增量承接用户批准的B管理路径：真实main管理Control受理恢复选择并创建唯一内部Task；数学worker按正常冷启动成功后的热态继续。
只改Rust内部准入/调用论证，无Pet方法、Budget purpose、B字段、shared wire或新重放引擎；既有NN01/D01/PS05–06承担真实执行与持久化。
本节独立于§9旧审签，当前为窄设计增量，未编码/执行测试。

### 10.1 唯一授权来源和复用边界

精确语义root引用[manager-supervisor.md §12.1](manager-supervisor.md)：
`TaskAuthorization={kind:ordinary,grant:Id,permit:Id}|{kind:control_replay,control:Id}`；
Rust-only `BackendAuthority.control_replay={task:Id,control:Id}`引用同一真实Control，不新增许可payload。
`control.replay:Option<CheckpointReplayBinding>`的Some含`{recovery,task,attempt,workspace,fsm_epoch,scope_revision,pause_revision}`，
与恢复行accepted_control/accepted_task互为精确引用；仅replay_checkpoint action允许Some。
真实main principal、Ingress key/digest及deadline来自ControlOperationRecord，executor为内部控制Task；不能伪造child worker或把main工作区当实际执行域。
TaskOrigin/StoredTaskOperation/TaskResultRef均取M4的control_replay分支，不伪ActorRequest或走普通B07结果绑定。
M2 MS08/MS09/MS24是当前授权、暂停例外与固定下一步计划的唯一判定者；driver核其票与实际发送动作相接，Pet只见普通task-purpose请求。

| 实际callee | 本增量pre→post |
|---|---|
| M4 PS33 AcceptControl + PS15 + PS04 | 真实main管理选择、当前ControlGrant/action/范围/FSM/版本及固定材料 → 同事务唯一control与内部Task/attempt；Committed才入队，Rejected无半个记录，Indeterminate查原key不派发；重复同key不重放 |
| M2 MS08/MS09 | 已提交control↔唯一Task/attempt、control非终态、当前ControlGrant/action/范围/FSM/manager/authority/scope/pause/input及原deadline → 本Task固定入口或成功材料下一句的DispatchTicket，或拒绝；不延长计划/加attempt |
| M2 MS36 AcceptControl后的执行链 / Finish | AcceptControl明确Committed后，固定entry/material → task-only实际provisional绑定；Finish核完整覆盖终点且当前性成立才PAUSED_HOT；本函数不直接解除用户pause或授worker任意执行 |
| M2 MS38 / M4 PS06 | ordinary保持只消费正式当前绑定；重放专用映射限本accepted Task；logical current revision仅沿该Task连续Committed PS06链推进，不把冻结恢复记录的原始起点当当前值 |
| M3 NN01/N04/D01 + M4 PS11/PS05 | PS11对真实located前驱/入口确认零步StoredProof（seq0/last_step=None、无StoredStep），或PS05已提交真实成功链，才提供N04 durable_path；再由实际selected/逐句ACK推进，不把定位回执冒selected、不把旧ProofRef冒热节点 |

### 10.2 首个冷点与固定输入

缺旧NativeLineBinding时，M2为该Task取得真实新/兼容上下文；NN01可用lineage=N/A，
expected_context=N/A仅在确实新context时使用，复用已有context必须由当前M2索引提供已核实际context revision；无法核则不用它冒新context。
NN01返回的line/node/revision/needs_prefix只登记task-only provisional，不发布到ordinary MS38；缺定位事实不能由lineage名字或历史数字造新locator。
needs_prefix先由PS11确认实际located bootstrap前驱的零步根，再只执行固定已授权成功材料闭包，沿D01/PS05实际ACK取得热前驱后重新定位真实entry；
实际entry由PS11目标/入口确认分支记录task/locate operation/真实node及boundary/source/environment，Committed的entry_proof才给N04 durable_path。
零prefix直接located也走该PS11零步StoredProof分支（durable_step_seq=0、last_step=None，不造StoredStep/StepFact）；无实际定位或COMMIT unknown均不select。
首次N04使用该实际热入口候选及provisional目的line/真实revision，同target/source/env前置照常；只有实际selected回执才PS06，不把PS11确认等同原生已选中。

所有重放字节来自control.replay.recovery指向的冻结恢复记录proof_material及其保留父链/SourceSlice，PS17按MS24核过的定向管理读权读取；执行另核已提交control→Task关联，不从变化后的line_heads重新拼计划。
driver只提交M2已固定的源段/范围，不拼入未验证draft_tail/未知尾、worker补写tactic或“为通过”包装命令；分段由既有材料生产者给出，不在Rust重新按点号猜Coq句界。
实际执行用官方parser；回执与固定source/range/顺序不符时封后续派发并保已发生事实，不把事后范围不符伪称尚未执行。
M2为每个begin_line提供只含该计划授权字节的不可变source材料；到固定frontier不再授权额外eval，不把通用D01的EOF循环当超出计划的许可。

### ND08 `check_task_dispatch(expected: TaskAttempt, requested_action, ticket) -> Result<CheckedDispatch, DispatchDenied>`（Rust私有）

CheckedDispatch是不可Clone、只供ND02本次发送消费的私有已核ticket包装，不复制Control载荷或新发权限；
DispatchDenied沿现有派发错误携固定原因Auth/Stale/Deadline/PlanMismatch及已知发送范围，不归为Rocq证明错误。
pre：ticket来自M2 MS08（续句由MS09重新进入同一检查）；不是actor可反序列化的凭据；requested_action是本次即将发送的实际typed请求。
TaskAttempt唯一引用M2的`{task:Id,attempt:U}`，attempt是普通任务序号；查M4 TaskAttemptRecord按task/attempt_no关联其opaque attempt_id，
不把序号与该Id或checkpoint_control的opaque attempt混等，暂停重放不另造attempt命名空间。
callee为M2当前发票/TaskAuthorization事实、PS33/PS15/PS04已提交关联、MS38实际native版本映射以及现有W02请求摘要；不读取Pet来判断人的选择。
先核ticket.task/attempt/instance/epochs/实际scope-workspace/source-environment/budget与本次发送完全绑定，再按TaskAuthorization分支：
ordinary原样核正常WorkGrant/permit当前事实；control_replay核control引用及control.replay/恢复行与accepted Task/attempt一致，票来自固定entry或计划下一源段，
并核本次method/source/range/操作摘要及计划终点与票一致。main管理范围、继承pause/gate/fence及当前期限的政策判断只调用MS08/MS24结果，不另造driver策略副本。
重放当前logical expected由本Task连续Committed PS06链末端取得：冻结恢复记录expected_path_revision只是不可变起点，不逐句要求仍等于起点；
任何其它Task推进、缺失/unknown提交、材料或输入变更、代际/权限撤销都不得用“最新值”覆盖expected。native expected revision另从真实映射取，不与logical版本混算。
未发送时失败返回具体Auth/Stale/Deadline/PlanMismatch、无Rocq副作用；若先前已有在途执行，返回拒新派发同时保旧inflight，交既有取消/核停/对账，不删除已成功步骤。
成功只允许本次发送，不能缓存成下一句通行证；有限字段/有限摘要校验，无循环重签/新attempt；各Task阶段原绝对deadline不晚于control.deadline，排队/重入不得重置。control取消/终态或当前管理权撤销由MS08/MS09拒新执行，原生不复制main政策。
论证：唯一M2授权与实际即将发送的字节/域相接，真实main管理权不会扩成任意child WorkGrant；ordinary分支不被新例外放松。

### 10.3 D01 / ACK / 接续的完整接线

1. ND01仅在MS08已核本受限Task后创建/复用实际child域；ND04确认同一MemoryGrant.task生效，NW02仍注册purpose=task和原initial_request。
2. D01每个可eval的pull前取得MS08/MS09重新核过的票，经ND08/ND02才发送；首次begin/入口定位/选择也不能跳过该检查。
3. step仍PS05明确durable才ack_step，真实ACK/selected效果才PS06。授权在执行后撤销仍允许同身份ACK完成已发生事实，不允许下一句eval。
4. 未知ACK/断线沿D02原operation对账；失败/超时/输入改变不另开计划/改源/升预算/新增attempt，也不在driver调用MS03/MS16切换路线。
5. 固定终点后由MS36 Finish核完整覆盖、本Task末端实际revision及当前输入，形成PAUSED_HOT；MS24/PS31处理本暂停原因及其余fence，不由driver/native success自行开放。
6. worker之后的普通请求必须有当前真实TaskAuthorization.ordinary及正式热映射；M2以其真实WorkGrant重新绑定/检查BackendAuthority，
   不沿已完成的control_replay越frontier继续。ND07只提供实际进程身份，语义不变，不从身份getter取得授权。
7. MS09按真实执行/持久/输出事实构造ControlReplayTaskResult，PS07核精确内部Task来源并持久TaskResultRef.control_replay；MS36/PS33 Finish再生成管理结果。
   driver回执不直接生成actor ResultView或成功管理结果；历史结果读取沿管理observe/result的当前读权，不从可读结果推出新执行权。

### 10.4 设计反例与准入状态

仅新增测试设计，不执行：
- 已提交main Control及唯一内部Task、当前授权有效且只重放完整固定计划的正例；未提交/事务unknown/错control-task-attempt关联不得派发；task-only provisional不得被ordinary MS38或其它Task消费。
- 新manager/backend epoch、main管理权撤销、其它fence/暂停原因、源码/环境/材料变化，在dispatch及两个pull之间分别拒绝；已执行前缀仍如实持久。
- 计划后多一句、替换一个字节、夹draft_tail/未知尾、换child域、把control ID塞WorkGrant、用checkpoint_control额度、worker/automatic或actor rocq_resume选择恢复ref，全拒。
- 原logical revision为r，首个真实PS06后为r+1，本Task续句应通过；另Task推进、缺回执或unknown commit不能用latest绕过；native revision独立测试不同数值。
- control取消/终态在两次pull之间拒下一句；原Task阶段deadline/control.deadline/预算超期不能通过换票/换会话重置，未到期也不能绕当前撤权。
- 内部结果错判actor分支、伪ActorRequest/B07、错control/task输出或读取历史结果后续执行均拒；成功结果只可在完整计划及当前性核后导出PAUSED_HOT。
- D01传输/ACK丢失不重复执行，最后可用热节点仅在实际固定终点及当前性核后交接；worker须新ordinary授权，不能消费残留replay票。

窄范围：ND01/ND02/ND04、ND08及D01实际caller义务；普通work默认不变，Pet共享协议/方法/预算purpose不变。
后续由原native专审与控制审核真实callee及上述拒绝分支；该审查未完成前不把本节设计当已实施或由旧签字放行。
