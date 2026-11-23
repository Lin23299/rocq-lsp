# item 4 进度（pet_query_view / pet_query_check / pet_query / pet_inspect + 接线）

## 交付 A —— pet_query_view.ml（有限内存 spool，已落盘）
- type spool：view/operation/全文 text/digest/bytes/构造期 capture/offset/seq/
  pending/released。create/register（批量原子：任一 view id 撞名或批内重复 ⇒
  `Conflict 一个都不登记）/complete_capture/truncated_capture。
- 与 Pet_source_sync 的文件 spool 差异只在存储（量小内存即材料）；serve_pull/
  ack/release 语义同款（credit 4..8192、UTF-8 前缀、块 SHA-256 ACK、独立游标、
  pending 未清 ⇒ Closing、真实清空全文后才 Released）；capture 回构造期值
  （Rust matches_capture(Parent) 要求逐字段等于 descriptor.capture）；空视图
  唯一一次拉取出空块 eof=true。
- quota = min(budget.output_bytes, boot.view_quota)；output_budget_check 减法比较
  （父子共享总账）。item 5 用入口：unreleased_count / discard_operation。
- 锁序：本模块锁 → Registry 锁；view 通道线程只取本模块锁。

## 交付 B —— pet_query_check.ml（NB07 首版白名单，已落盘）
- classify : Coq.Ast.t list -> (unit, string) result；外层 control=[] ∧ attrs=[]
  才分类；允许 CheckMayEval(None,_,term)/GlobalCheck/Print(全集 match：拒
  PrintDebugGC、PrintUniverses file=Some、by-notation)/Locate(Any/Term/Library/
  Module)/Search(Pattern/Rewrite/Search 递归)/SetOption(false, 四项 exact-set,
  SetTrue|Unset + Goptions 表核存在且布尔)；term/pattern/binder 递归白名单，
  CNotation/CPatNotation/by-notation/CGenarg* 拒；兜底 Error。
- 本批保守面（按 spec §4）：reduction Some 分支拒绝（设计 §4.3 的内建
  reduction 表留后续批）。

## 交付 C —— pet_query.ml（已落盘）
- 节点解析：root-<line> / node-<line>-<n>（n = 第 n 个带 AST 的真实执行节点，
  与 receipt 的 node-<line>-<seq> 同序号方案；探索线/出错节点/越界 ⇒ invalid_input；
  单 context 近似：第一条 Mainline 线上最早登记操作 = doc 持有者）。
- 命令源：sealed、start<stop≤len、UTF-8 边界；官方 parser（Coq.Parsing.parse
  循环，节点状态上下文内）解析为有限 AST 列表，不自写分句；解析失败/解析期取消
  ⇒ Error(Parse)；白名单拒 ⇒ Error(Register)；均 CompleteKnown、无前缀。
- 执行：Coq.State.in_stateM 安装节点状态，逐 AST Coq.Interp.interp（不进 memo），
  反馈消息转文本追加，受 cap 字节上界（超限截断 reason=BudgetExhausted、complete
  =false，但已白名单只读命令继续执行到结束）；遇 Coq 用户错误即停 ⇒ Error
  (Execute, CompleteKnown, 已捕获前缀挂私有 lease)；token set ⇒ Interrupted ⇒
  Error(Execute, 恢复成功 CompleteKnown / 恢复失败 UnknownTail)。finally 用原子
  token 重新安装节点状态（恢复打印选项）。
- 发布：成功 ⇒ spool(view-<op>-<seq>) + make_query_view_terminal CompleteKnown；
  失败前缀同 view id 登记（Error 终态不带 view，由 item 5 清理）；幂等重放 aux。
- args.output_budget 不与 binding.budget 推断同一（Rust 明示），只取 binding 预算。

## 交付 D —— pet_inspect.ml（已落盘）
- 复用 Pet_query 的准入/解析/执行/发布；facts 文档 = payload 字节 → 内层 complete
  capture → make_native_facts_document(node/source/environment 取请求与 binding) →
  外层 complete capture（Rust checked_facts_document 逐字节重建）。
- Toc：doc.toc 文档顺序、index=位置、parent=N/A（本批不跟踪层级）、kind=Info.detail
  （通常为类型）否则 SymbolKind 十进制、range=节点字节区间。
- GoalRoster：Fleche.Info.Goals.goals（compact:false，goal_concl_style）⇒ 五组
  （stack 帧 i ⇒ depth i+1，无帧 depth=0 占位）；part 同文本去重共享 view id；
  单页全量 next=N/A complete=true；带 cursor ⇒ invalid_input。
- GoalPart：selector 定位 goal，Conclusion=ty / Hypothesis i=第 i 假设 ty，range
  字节窗口（UTF-8、≤65536），digest=整 part。
- Assumptions：文本 "Print Assumptions <name>." 解析后核恰一个 PrintAssumptions
  (AN _) 且无 control/attrs（杜绝文本注入）；Closed ⇒ AsmClosed；其余 ⇒
  AsmAssumptions（非表头行：首个 " :" 前为 kernel_name，整行为 printed_type 子
  视图）；Coq 错误/取消/超限 ⇒ AsmUnavailable(error=Known)；raw 独立子视图；
  resolved=FUnknown。
- Environment/Notations：路由在准入前 protocol_error invalid_input 拒绝（不登记
  操作、不推进序号）。
- 父子共享配额：父文档 + 去重子视图 ≤ quota，超限 ⇒ StageView 错误终态（不截断、
  不登记）。

## 交付 E —— pet_native.ml 接线 + dune
- QueryView/Query/Inspect 模块别名；serve() 注入 Query_view.init ~boot。
- view_loop：Sync 返回 None 后查 Pet_query_view（pull/ack/release），仍未接管 ⇒
  unknown_operation。
- step_reply：QueryRequest → Query.run；InspectRequest：Environment/Notations 拒绝，
  其余 → Inspect.run。dune：pet_native_support 追加四模块（petanque_shell 排除表同步）。

## 构建与探针
- spec §0 命令（release -j1 pet_native.exe + @petanque/json_shell/runtest）退出 0、
  无警告；git diff --check 干净；pet_native.exe 46.3MB。
- 运行时探针（临时 dune 可执行，未入 git，已删除）：真实 Rocq 文档
  （Require/Lemma…Qed/Definition/Axiom/Definition）上：25 条 classify 样本全部按
  设计判（Check/Print Assumptions/Set/Unset/About/Locate/Search OK；Eval/Compute
  拒 reduction；Fail/Timeout 拒 control；Print Debug GC 拒；bar%nat 拒 by-notation；
  `Check let (a,b) := …` 拒 term notation）；执行捕获：Check→"bar\n     : nat\n"(15B)、
  Print Assumptions→"Closed under the global context"、不存在引用→Coq 错误文本入
  error、About cap=12 截断 UTF-8 安全；roster 766B/2 parts（去重）、goal_part "nat"
  eof、assumptions 4 roots（closed/assumptions[az]/unavailable/assumptions，4 视图
  去重）、toc 4 条文档序——协议构造器约束（make_goal_roster_facts 等）全部通过。
- 待测（无驱动侧，明确未验）：四通道端到端（Rust inspection.rs 对账）、cancel
  经 RequestCancel 真实到达查询、输出期限、roster 多帧 stack 真实样本。

## 已知接缝（诚实记录）
- 失败前缀私有 lease 的 view id 不进 Error 终态（wire 无字段），驱动无从拉取，
  仅作前缀材料保留；item 5 按「非借用」清理。
- GoalRoster 本批单页；cursor 请求一律拒绝。
- 前任的 locate 用 node 在 doc.nodes 中的位置做节点号，本模块用第 n 个带 AST
  节点（与 receipt 序号一致）；两者在存在 ast=None 非出错节点时不一致——留给
  后续统一。
- TOC 层级不跟踪（parent 全 N/A）；Assumptions 行解析从简。
