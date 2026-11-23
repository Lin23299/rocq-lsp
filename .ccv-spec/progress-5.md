# item 5 进度（pet_scope_lifecycle.ml + 封新准入接线 + 借用枚举接缝）

## 交付 —— pet_scope_lifecycle.ml（N05，已落盘）
- 状态：scopes : scope_key -> {revision; status Open|Closing|Closed; owner;
  progress(最近 Closing 回执); next_seq; history(历史回执只增)}。无独立锁：只在
  ordinary 线程、Registry 锁内访问。
- run（EndScopeRequest）：幂等——已登记操作的 terminal ⇒ Closed 原样重放；
  无 terminal 且为 Closing 的 owner ⇒ 重估借用。新操作：准入（seq=highest_seen+1、
  未退役、scope=binding.scope、预算已登记、Task 用途、budget.scope/operation_seq/
  source/environment 与 binding 一致、W02 原请求 digest = binding.request_digest）；
  scope 版本：首次以请求 expected_revision 播种（Pet 无独立 scope 登记，U4 供给后
  替换），不符 ⇒ StaleRevision；已 Closed 的 scope 由另一操作再关 ⇒ invalid_input。
- 借用枚举（两阶段快照，锁不嵌套）：Registry 侧（pending 步 + Executing）→
  材料侧（Query_view.unreleased_count / Sync.unreleased_views（新增）/
  Arena.unreleased_downloads（新增））。有借用 ⇒ make_ended_closing（首次 seq=1，
  reclaim=Unknown；续调重放同一回执——Rust 同 seq 须同一回执），op.state=Retiring，
  scope→Closing 封新准入。借用清空 ⇒ make_ended_closed（seq=上一回执+1，
  reclaim=Known reclaim-scope-<scope>-<op>）+ 真实删除：删该 scope 名下操作与 doc
  引用（仍被其它 scope 操作引用的线，其 doc 持有操作保留 = 共享 context 他人引用）、
  丢弃其私有视图材料（含 item 4 失败查询的已捕获前缀 lease：Error 终态不带 view、
  驱动无从 release，按非借用材料在此真实清理）、删除无操作引用的线；保留本
  end-scope 操作的 Closed 终态与历史回执。
- 封新准入接线：pet_native.admit_new / BeginLine 登记 / PullStep 新步（ACK/finish/
  release 仍可沿原 owner）/ Pet_query.admit（query+inspect）在 scope Closing/Closed
  时回 invalid_state not_admitted；status 对 Closing 中的 end-scope 操作报
  make_retiring_status（Rust end_scope_status 只接受 (Retiring,N/A)/(Terminal,Closed)）。
- pet_registry 新增 remove_operation / remove_line。

## 构建与探针
- spec §0 命令退出 0、无警告；git diff --check 干净。
- 运行时探针（临时可执行，未入 git，已删）：真实 Registry 上 EndScope
  Closing→Closed→重放：scope 内带 pending 步的操作 ⇒ run1 回 Closing receipt seq=1
  reclaim=unknown、admits=false、closing_owner=true；续调回执逐字节同一；模拟 owner
  ACK 后 run2 回 Closed terminal seq=2 reclaim=known extent=complete_known，借用者
  操作与无引用线被真实删除（ops 2→1，lines 1→0），end-scope 操作持 terminal；
  再续调 Closed 逐字节同一。
- 待测：四通道端到端（Rust end_scope.rs 对账）、真实 view/blob 未 release 的
  Closing 路径、共享 context 保留分支的真实样本、checkpoint_control scope。

## 已知接缝（诚实记录）
- staged 协议库 T.entry_uses_budget 无 EndScope 分支（Rust validate_head 有）：Pet
  只核可访问关系 + 原请求 digest；initial_request digest 核对留待协议库补齐。
- reclaim 只给 id（roots 观测/外部登记/原退役决定由 U4 供给）。
- 未 N08 的终态操作不计借用（Pet 无 finish 迹象）；已删除操作的迟到
  FinishOperation 回 unknown_operation。
- 借用枚举两阶段：view release 单调 ⇒ 只会偏保守多报一次 Closing，不会漏报。
