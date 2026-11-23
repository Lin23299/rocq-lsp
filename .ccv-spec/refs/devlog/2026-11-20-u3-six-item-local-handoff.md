# U3 六项本地实现交接

## 本轮边界

按用户确认：写完 U3 本地逻辑；真实外部输入、实际调用和当前无法完成的联调交后续 U4/U5/U7，不扩大为追踪系统、工具链工程或测试设施。本记录描述这次编码交付，不代表服务已安装或正式四通道已验收。

## 实际落盘与公共调用

1. **中断恢复**：Fleche/Shell 保留真实 Interrupted(stage,parent snapshot)，公共入口核原物理 ACK 父；真实退出后用原恢复期限、新 token 安装原快照并恢复。既有真实用例已执行取消→原快照→续句→Qed，1.94s；关闭 token 设置的反验实际失败，恢复后通过。ACK竞争/正式四通道另列。
2. **Scope 清理**：公共入口实际调用 `Scope.cleanup_locked`，枚举真实容器及借用，封新准入，保共享引用和历史回执，按真实结果发布 Closing/Closed；外部登记和原退役决定由 U4 供给。
3. **源码同步**：公共入口调用 `Sync.prepare_locked`，消费原源事实和线全集，构造保留前缀/文档替换及封存metadata，再发布实际新映射；原意图未知不重算。外部publication及回收输入由 U4 补。
4. **环境刷新**：公共入口调用 `Refresh.refresh_locked` 和 Shell 的真实环境 snapshot/install/readback；未知不发布新身份。同环境 no-op 与变更分开；实际 M5 环境输入和授权后续接入。
5. **checkpoint**：`Dispatch.run_import/run_activate` 已接公共操作处理，使用真实封存材料和 Graph/Arena 本地内核，登记私有恢复图及激活映射；独立材料寿命/原回执/retire接线。实际NC01完整制品事实、导入目标映射、PS30/PS31等由后续owner输入。
6. **Query/Inspect**：公共 Query 消费 `run_with_output`，失败前缀挂原操作私有lease，保持失败语义；不能把view ID冒受管diagnostic索引。N08正确清理私有材料，未知保owner。Environment公共分支消费显式可信snapshot。Notations及合法折叠notation仍依赖固定Rocq纯接口；失败材料公开传输字段由U4后续确定，未在本批擅改wire。这两项依赖明确保留，不称功能已公开可用。

## 主代理最终检查

公共 writer 停写后，主代理实读 cleanup/prepare/refresh/import/activate/query调用及私有失败lease清理，运行：

```bash
git diff --check
flock -w 110 /tmp/opencode/rmcp23-v41/cargo.lock opam exec --switch=rocq90 -- env OCAMLPATH=/tmp/opencode/group-version-return-stage/lib:/home/ubuntu/.opam/rmcp10-preflight/lib /home/ubuntu/.opam/rmcp10-preflight/bin/dune build --root /tmp/opencode/rmcp24-pet --profile release -j1 petanque/json_shell/pet_native.exe @petanque/json_shell/runtest
```

均退出0，无诊断；Dune此次无输出，复用已有构建/测试缓存，不计作一次新运行证据。前述1.94s是worker实际执行证据。Dune源码替换用的sed预处理已去掉，Option名称限定在源码处理。未提交、未部署，未重复Rust套件。

## 后继交接

- U4：真实scope/retirement输入、Save→sync调用、checkpoint材料/permit及映射开放，失败诊断材料的对外承载；补齐后联验。
- U5：真实环境发布和load mapping输入。
- U7：实际安装/加载制品身份和部署；正式RC06不降级。
- 固定Rocq只读notation接口是既登记的具体依赖，不追加源码提取构建链。

## 度量

- 外部Pet工作树所选5个tracked文件累计差异：+3545/-243（`git diff --stat`，含此前实现，非本批净量；新增私有文件未计）。
- 本次新增取消直接局部用例1项，实际正例和关闭token反验通过预期结果；其它局部证据复用。
- 本批公共合入修正过记录类型推断、scope variant匹配、失败diagnostic ID误用、arena重放与回调异常；不把跨会话累计bug数伪报为精确统计。
- 一批六项并行实现，公共接线分批合入；最终主代理检查一次，无新增测试平台。
