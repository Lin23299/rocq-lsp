# 任务：item 1 —— 接线基础 + pet_environment_refresh.ml

先完整读这三份（其它文件按需查，不要通读主仓 Rust）：
1. /home/ubuntu/tools/rocq-lsp-nativeface-u3/.ccv-spec/spec.md 的 §0、§1、§1.1、§1.2、§6 与 §2 中 pet_environment_refresh 相关句
2. .ccv-spec/refs/protocol/types.mli（协议 API 唯一真相；构造器签名以它为准；需要构造器语义时查同目录 types.ml）
3. 本仓 petanque/json_shell/{pet_native.ml,shell.ml,shell.mli,dune}（基线现状）

## 交付（全部落盘后才算完）
A. 新建 petanque/json_shell/pet_registry.ml（spec §1 共享注册表；基线 pet_native.ml 里的 sources/budgets/operations/with_tables 全部迁入，budgets 存 T.native_budget）。
B. shell.ml/shell.mli：step_doc 增加真实 `Interrupted of [`Parse|`Execute]` 结果（Coq.Protect.R.Interrupted / Sys.Break 真实到达时；快照=步前 doc）；新增 snapshot_doc、restore_sentence（新 token、原恢复期限内从父快照重定位，停在中断句之前）、env_snapshot/install_env/readback_env（NN04 用：快照当前 Fleche.Doc.Env.t；构造新 Coq.Files.make()+Fleche.Doc.Env.make 同 init/workspace；读回核物理同一）。注释中文。
C. petanque/json_shell/pet_environment_refresh.ml（spec §2 末尾与六项 devlog #4：同环境 no-op 与变更分开；未知不发布新身份；拒绝(protocol_error not_admitted)与已尝试未知(无终态、status Executing/Ready+terminal FUnknown)区分；幂等重放原 aux）。refresh 用 Shell.env_snapshot/install_env/readback_env 真实重建。
D. pet_native.ml 重接：修 T.make_status(补 retired_through)/T.error_terminal(补 ~group)/T.make_ack(补 ~group) 漂移；T.native_request_view 全部 19 构造器分派——已实现的走原逻辑(迁 Registry)，RefreshEnvironmentRequest→Pet_environment_refresh，本 item 未实现的模块(SyncSource/Query/Inspect/Checkpoint/EndScope)一律先 `T.make_protocol_error header T.invalid_input T.not_admitted T.fact_unknown` 占位路由（后续 item 替换）；LocateContext/SelectLine/ForkLine 按 spec §1.1 内联最小真实实现（线注册表入 Registry；select 若无法诚实完成按 §1.1 的「不谎称」条款返回 invalid_input）；SettleInterruptRequest/RetireThroughRequest 按 §1.2；控制通道 serve 线程（fd5）+ source 通道 method 分派（source_*/checkpoint_blob_*，blob 分支本 item 返回通道内 protocol_error）+ view 通道 serve 骨架（本 item 无已登记 view ⇒ unknown_operation invalid_state 回错）。
E. dune：新库 pet_native_support（spec §6 的 modules 列表先放 pet_registry、pet_environment_refresh 两个，后续 item 追加；libraries petanque_shell ccv_protocol threads.posix），pet_native.exe 追加该库。petanque_shell 不加 ccv_protocol。

## 验收（自己跑到绿才算完）
```
cd /home/ubuntu/tools/rocq-lsp-nativeface-u3 && env -i HOME=/homeubuntu HOME=/home/ubuntu PATH=/home/ubuntu/.opam/rocq90/bin:/usr/local/bin:/usr/bin:/bin OCAMLPATH=/home/ubuntu/tools/rocq-lsp-nativeface-u3/.ccv-findlib:/home/ubuntu/.opam/rocq90/lib /home/ubuntu/.opam/rmcp10-preflight/bin/dune build --root /home/ubuntu/tools/rocq-lsp-nativeface-u3 --profile release -j1 petanque/json_shell/pet_native.exe @petanque/json_shell/runtest
```
（以命令实际文本为准，勿改 OCAMLPATH/HOME。）
警告可留，错误必须清零。编译错误逐个修到过。

## 纪律
- 只改上列文件；不 git commit/push（由主代理审后提交）；不动 upstream；不加新依赖。
- 注释中文；不确定的行为按 spec「拒绝或未知」口径，不伪造成功。
- 完成或 300s 被截断都没关系：把当前进度写进 /home/ubuntu/tools/rocq-lsp-nativeface-u3/.ccv-spec/progress-1.md（改了什么/剩余什么/卡点），主代理会续跑。
