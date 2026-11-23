继续块 C+D（上一轮没动笔，这轮直接写代码）。注意：不要去看 test/ 目录——@petanque/json_shell/runtest 对 json_shell 本身是空别名（无测试挂载），构建验收只跑 pet_native.exe 目标即可：
env -i HOME=/home/ubuntu PATH=/home/ubuntu/.opam/rocq90/bin:/usr/local/bin:/usr/bin:/bin OCAMLPATH=/home/ubuntu/tools/rocq-lsp-nativeface-u3/.ccv-findlib:/home/ubuntu/.opam/rocq90/lib:/home/ubuntu/.opam/rmcp10-preflight/lib /home/ubuntu/.opam/rmcp10-preflight/bin/dune build --root /home/ubuntu/tools/rocq-lsp-nativeface-u3 --profile release -j1 petanque/json_shell/pet_native.exe

按 .ccv-spec/task-1c.md 的 C1-C4、D1-D4 原文执行（那份清单仍是准绳）。本轮至少完成 C2+C3+C4（改 pet_registry.ml 加字段、pet_native.ml 加控制通道线程与 source/view method 分派），有余力再 D1-D4。每完成一小块就顺手构建一次。不 commit。完成后把进度写 .ccv-spec/progress-1.md（一行一块）。
