继续 item 1（块 C+D）。块 A 已 commit。参考（已在你 context）：spec §1.1/§1.2、types.mli。

块 C（控制通道 + source/view 帧分派）：
C1. 控制通道 serve 线程（fd 5，serve() 里 Thread.create）：循环 `T.decode_control_request`；`control_request_view`：
  - `ReadControl op`：按 op 在 Registry 找操作；无 ⇒ `T.control_unknown_operation header op`。有 ⇒ `T.control_snapshot ~operation_id:op ~phase ~token_generation ~highest_cancel_seq ~stop_requested`（op 新增可变字段：cancel 账本，见 C2；phase：pending eval 中=Active，有终态=TerminalPhase，否则 Idle；generation 恢复后 +1）。
  - `RequestCancel (op, cancel_seq, _)`：找操作；无 ⇒ unknown。有 ⇒ 若 cancel_seq > 已见最大 ⇒ 记录、`Coq.Limits.Token.set`（该 op 当前 token，pet_native 需把 pull 用的 token 存进 operation 可变字段 token）、stop_requested=true ⇒ `T.control_cancel_ack header T.ReceivedAck snapshot`；等于 ⇒ 幂等重放原 ACK（保存最近 cancel 结果）；小于 ⇒ PastCancel。snapshot 的 token_generation 等按 C1。generation 字段：初次 1，`Shell.restore_sentence` 成功后 +1（块 E 接）。
C2. Registry.operation 扩字段：`mutable cancel_seq_seen : int64; mutable cancel_generation : int64; mutable stop_requested : bool; mutable token : Coq.Limits.Token.t option; mutable interrupt_snapshot : Fleche.Doc.t option`（本块先加字段+默认值，快照在块 E 用）。
C3. source 通道 method 分派：source_loop 读帧后先 `S.decode S.message_limits` 取 value 的 "method"（View_object + StringMap.find），`source_begin/chunk/finish` 走 source_handle；`checkpoint_blob_begin/chunk/finish` 本块回 `T.checkpoint_blob_error header T.invalid_input T.not_admitted`；其它 method 同样回错（不能 fail 整个进程，通道内错误要能继续服务）。注意 checkpoint_blob_error 的 reply 编码用 `T.encode_checkpoint_blob_reply`。
C4. view 通道 serve 线程（fd 7）：`view_pull/view_ack/view_release`（`T.decode_view_request` + `view_request_view`）与 `checkpoint_blob_pull/ack/release` 分派：本块全部无已登记 view/blob ⇒ pull/ack 用 `T.make_view_pull_error/make_view_ack_error header T.unknown_operation T.not_admitted`，release 用 `T.make_view_release_error`；blob 用 `T.checkpoint_blob_error`。

块 D（locate/fork/select 内联最小真实，spec §1.1）：
D1. Registry 加线表 `lines : (string, {mutable revision:int64; mutable frontier:T.Id.t; mutable group:(T.Id.t*int64) option; kind: [`Mainline|`Exploration]}) Hashtbl.t` + register/find/iter。BeginLine 成功时登记线（revision=expected_revision）。
D2. LocateContextRequest：`T.locate_fields` 解包 (binding,file,rel_file,target,logical_target,lineage,expected)。绑定 context：本批每实例单 context——找 Registry 里任一 BeginLine 建的线/doc；没有 ⇒ 拒 invalid_input（不能建 doc 的输入不齐）。有：按 target 定位（用该 op 的 doc 或线 frontier 对应 doc）：Root ⇒ cursor=0、`T.make_locator_terminal binding ~line ~node:frontier ~revision ~cursor (LocatedRoot)`（注意 make_locator_terminal 签名）；Position(l,c)/Theorem/End 用 doc 的 toc/nodes 判定：已到 ⇒ LocatedBoundary(make_entry_boundary …)（entry command 范围用节点 range 字节）；未到 ⇒ PrefixRequired。同 binding 重入幂等（aux 存在即重放）。boundary 构造参数以 types.mli `make_entry_boundary` 签名为准。
D3. ForkLineRequest：`T.fork_fields` 解包；父线存在且 expected_line 版本匹配 ⇒ 新线（frontier=父 frontier、group=(exploration, rev+1)）⇒ `T.make_fork_terminal`（node=父 frontier、revision=父 rev）。同 binding 幂等。
D4. SelectLineRequest：`T.select_fields`/`T.select_group`；本批无候选执行栈：若目的线的 doc/frontier 真实状态与账本可核（frontier 节点在线上）⇒ 迁移 frontier、revision+1、组版本递增 ⇒ make_selected_group/make_selected_entry；不可核 ⇒ invalid_input 拒绝（spec「不谎称」条款）。

完成后：构建到零错误（注意 OCAMLPATH 现在是三个目录：.ccv-findlib + rocq90 + rmcp10-preflight，命令看 spec §0 更新版）；更新 .ccv-spec/progress-1.md。不 commit。
