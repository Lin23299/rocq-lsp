open Petanque

(** I/O handling, by default, print to stderr *)

(** [trace header extra message] *)
val trace_ref : (string -> ?verbose:string -> string -> unit) ref

(** [message level message] *)
val message_ref : (lvl:Fleche.Io.Level.t -> message:string -> unit) ref

(** Start the shell, must be called only once. *)
val init_agent :
     token:Coq.Limits.Token.t
  -> debug:bool
  -> record_comments:bool
  -> roots:string list
  -> unit Agent.R.t

(** [set_workspace ~root] Sets project and workspace settings from [root].
    [root] needs to be in URI format. If called repeteadly, overrides the
    previous call. *)
val set_workspace :
     token:Coq.Limits.Token.t
  -> debug:bool
  -> root:Lang.LUri.File.t
  -> unit Agent.R.t

module Target : sig
  type t = End | Root | Position of int * int | Theorem of string
end

val make_doc :
  token:Coq.Limits.Token.t -> uri:Lang.LUri.File.t -> raw:string ->
  Fleche.Doc.t

(** [make_doc_at ~uri ~raw ~root] 以真实已执行节点 state 为执行起点的文档（同线
    续接 / fork 探索线）；root 必须来自真实节点谱系。 *)
val make_doc_at :
  uri:Lang.LUri.File.t -> raw:string -> root:Coq.State.t -> Fleche.Doc.t

(** [step_doc] 的 [`Step] 带 (句末字节偏移, 所执行节点的真实 state)。 *)
val step_doc :
     token:Coq.Limits.Token.t -> doc:Fleche.Doc.t -> cursor:int ->
     Fleche.Doc.t *
     [ `Step of int * Coq.State.t | `Eof | `Error of [ `Parse | `Execute ] | `Unknown
     | `Interrupted of [ `Parse | `Execute ] ]

(** [snapshot_doc doc] 步前快照：共享不可变结构，纯记录（传回同一 doc）。 *)
val snapshot_doc : Fleche.Doc.t -> Fleche.Doc.t

(** [restore_sentence ~token ~snapshot ~cursor] 用新 token 从父快照恢复：重放
    同一句的目标定位（Position），停在中断句之前。 *)
val restore_sentence :
  token:Coq.Limits.Token.t -> snapshot:Fleche.Doc.t -> cursor:int -> Fleche.Doc.t

(** NN04 环境三件套：快照当前 env / 安装新 env（旧 documents 全失效）/
    读回 !env 供物理同一性核验。 *)
val env_snapshot : unit -> Fleche.Doc.Env.t option
val install_env : Fleche.Doc.Env.t -> unit
val readback_env : unit -> Fleche.Doc.Env.t option

val build_doc :
  target:Target.t -> token:Coq.Limits.Token.t -> uri:Lang.LUri.File.t -> Fleche.Doc.t Agent.R.t

val get_toc :
     token:Coq.Limits.Token.t
  -> doc:Fleche.Doc.t
  -> (string * Lang.Ast.Info.t list option) list Agent.R.t
