(* 环境刷新（spec §2 末尾 / NN04，item 1 之 C）。
   本块为占位骨架：职责是「同环境 no-op 与真实变更分开、未知不发布新身份、
   拒绝与已尝试未知区分、幂等重放原 aux」，真实环境重建走
   Shell.env_snapshot / install_env / readback_env。
   不承诺的事：本文件当前不含实现，后续块填充；不伪造刷新成功。 *)
