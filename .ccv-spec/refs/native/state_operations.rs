//! NN02–04 与 grouped N04：关联普通通道的建立请求与原操作回执。原生图与发布事实归 Pet。

#[path = "line_updates.rs"]
mod line_updates;

use super::{checkpoint::absolute_deadline, interrupt::{CandidateInterrupt, CandidateInterruptState}, validate_ack_reply, validate_step_receipt, validate_terminal,
    ChannelError, FrameError, NativeDriver, Nw02Reservation, StepExpectation};
use ccv_protocol::nativeface::{
    AckProof, AckStatus, AnyTerminal, ArgsAckStep, ArgsBeginLine, ArgsFinishOperation, ArgsOperationStatus, ArgsPullStep,
    ArgsRefreshEnvironment, ArgsRegisterBudget, ArgsSelectLine, ArgsSettleInterrupt, AuxTerminal, AuxValue,
    InitialNativeMethod, InitialPhase, KnownOrNa, NativeBudget, NativeOpState, NativePurpose,
    NativeEdit, NativeGroupVersion, NativeRequest, NativeResult, NativeStage, OpBinding, OpStatus, Receipt, ReceiptKey,
    ReceiptPayload, TerminalRecord,
};
use ccv_protocol::reply::ExecutionExtent;
use ccv_protocol::{Digest32, Fact, Id, Limits, Upos, U};
use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock, Weak};
use std::time::Instant;

pub(super) struct StateOperations {
    owner: Arc<()>,
    slot: Option<StateOperationSlot>,
    // 仅限制本地序号复用，不是 Pet 的 retired_through。
    closed_through: Option<U>,
    // 每条已确认候选线只记身份及本切片的一次 Begin；finish 不撤线 owner。
    candidate_lines: BTreeMap<Id, Option<(Id, U)>>,
}

impl StateOperations {
    pub(super) fn owns_source_sync(&self, binding: &OpBinding) -> bool {
        self.slot.as_ref().is_some_and(|slot| matches!(&slot.request, NativeRequest::SyncSource { args, .. }
            if args.binding().operation_id() == binding.operation_id() || args.binding().operation_seq() == binding.operation_seq()))
    }
    pub(super) fn new() -> Self {
        Self { owner: Arc::new(()), slot: None, closed_through: None, candidate_lines: BTreeMap::new() }
    }

    fn slot(&self, token: &RegisteredStateOperation) -> Result<&StateOperationSlot, ChannelError> {
        if !Weak::ptr_eq(&token.owner, &Arc::downgrade(&self.owner)) {
            return Err(ChannelError::InvalidExpectation);
        }
        self.slot.as_ref().filter(|slot| {
            Arc::ptr_eq(&slot.forked, &token.forked)
                && slot.budget.operation_seq() == &token.operation_seq
                && slot.budget.initial_request().digest() == &token.request_digest
        }).ok_or(ChannelError::InvalidExpectation)
    }

    pub(super) fn owns_candidate(&self, binding: &OpBinding) -> bool {
        self.owns_candidate_operation(binding.operation_id(), binding.operation_seq())
    }

    pub(super) fn owns_candidate_operation(&self, operation: &Id, seq: &U) -> bool {
        self.slot.as_ref().is_some_and(|slot| matches!(&slot.request,
            NativeRequest::BeginLine { args, .. } if args.binding().operation_id() == operation
                || args.binding().operation_seq() == seq))
            || self.candidate_lines.values().flatten().any(|(id, old_seq)| id == operation || old_seq == seq)
    }

    pub(super) fn blocks_mainline(&self, binding: &OpBinding, line: &Id) -> bool {
        self.owns_candidate(binding) || self.owns_source_sync(binding) || self.candidate_lines.contains_key(line)
            || self.slot.as_ref().is_some_and(|slot| matches!(&slot.request,
                NativeRequest::ForkLine { args, .. } if args.new_line() == line))
    }

    pub(super) fn candidate_recovery_deadline(&self, binding: &OpBinding) -> Result<Instant, ChannelError> {
        let slot = self.slot.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        let (_, args) = slot.active_candidate()?;
        if args.binding() != binding {
            return Err(ChannelError::InvalidExpectation);
        }
        absolute_deadline(*slot.budget.recovery_deadline_us())
    }
}

struct StateOperationSlot {
    request: NativeRequest,
    budget: NativeBudget,
    phase: Phase,
    forked: Arc<OnceLock<AuxTerminal>>,
    candidate: Option<CandidateRun>,
    line_updates: Option<line_updates::LineUpdates>,
    refresh_status: Option<NativeRequest>,
}

impl StateOperationSlot {
    fn active_candidate(&self) -> Result<(&CandidateRun, &ArgsBeginLine), ChannelError> {
        match (&self.phase, &self.candidate, &self.request) {
            (Phase::Established { terminal: None }, Some(run), NativeRequest::BeginLine { args, .. })
                if run.begun => Ok((run, args)),
            _ => Err(ChannelError::InvalidExpectation),
        }
    }
}

struct CandidateRun {
    interrupt: Arc<CandidateInterruptState>,
    interrupt_issued: bool,
    begun: bool,
    source: String,
    group: NativeGroupVersion,
    parent: Id,
    line_revision: U,
    cursor: U,
    last_ack: Option<AckStatus>,
    step: Option<Receipt>,
    retry_ack: Option<AckProof>,
    in_flight: Option<NativeRequest>,
    finish_error: Option<Receipt>,
}

impl CandidateRun {
    fn expectation<'a>(&'a self, args: &'a ArgsBeginLine) -> Result<StepExpectation<'a>, ChannelError> {
        let seq = self.last_ack.as_ref().map_or(0, |ack| ack.acked_through().get())
            .checked_add(1).ok_or(ChannelError::InvalidExpectation)?;
        Ok(StepExpectation {
            binding: args.binding(), line: args.line(), parent: &self.parent, source: &self.source,
            cursor: self.cursor, base_revision: self.line_revision,
            step_seq: Upos::new(seq)?, receipt_seq: Upos::new(seq)?,
        })
    }
}

enum Phase {
    Registering { frame: NativeRequest, may_have_sent: bool },
    RegistrationUnresolved(ccv_protocol::nativeface::NativeProtocolError),
    Registered,
    Established { terminal: Option<(ReceiptKey, ExecutionExtent)> },
    Finishing { frame: NativeRequest, extent: ExecutionExtent },
    FinishUnresolved { key: ReceiptKey, error: ccv_protocol::nativeface::NativeProtocolError },
    FinishPast { key: ReceiptKey, result: NativeResult },
}

/// NW02 配对结果。PastUnavailable 不签发 token。
pub enum StateOperationRegistration {
    Registered(RegisteredStateOperation),
    PastUnavailable { operation_seq: U, highest_seen: U },
}

/// 仅由当前 driver 核对 NW02 回复后产生；不代表 Manager 授权或持久应用。
/// 原请求与发送资格只保存在 driver 槽中。
pub struct RegisteredStateOperation {
    owner: Weak<()>,
    operation_seq: U,
    request_digest: Digest32,
    forked: Arc<OnceLock<AuxTerminal>>,
    environment_generation: Weak<()>,
}

impl NativeDriver {
    /// 调用方须持当前 M2 派发决定及 M4 持久意图，并完成该操作的材料登记。
    /// `request` 是已绑定 W02 摘要的完整请求。未知后须从原槽恢复登记。
    pub fn register_state_operation(
        &mut self,
        request: NativeRequest,
        budget: NativeBudget,
        deadline: Instant,
    ) -> Result<StateOperationRegistration, ChannelError> {
        if matches!(&request, NativeRequest::BeginLine { .. })
            || matches!(&request, NativeRequest::ForkLine { args, .. }
                if self.state_operations.candidate_lines.contains_key(args.new_line()))
        {
            return Err(ChannelError::InvalidExpectation);
        }
        self.register_state_operation_inner(request, budget, None, deadline)
    }

    fn candidate_fork<'a>(&self, fork: &'a RegisteredStateOperation, binding: &OpBinding)
        -> Result<&'a AuxTerminal, ChannelError> {
        let terminal = fork.forked.get().ok_or(ChannelError::InvalidExpectation)?;
        let AuxValue::Forked { line, .. } = terminal.value() else {
            return Err(ChannelError::InvalidExpectation);
        };
        let origin = terminal.binding();
        if !Weak::ptr_eq(&fork.owner, &Arc::downgrade(&self.state_operations.owner))
            || !Weak::ptr_eq(&fork.environment_generation, &Arc::downgrade(&self.ordinary.environment.generation))
            || !self.state_operations.closed_through.is_some_and(|floor| floor >= fork.operation_seq)
            || !matches!(self.state_operations.candidate_lines.get(line), Some(None))
            || self.state_operations.owns_candidate(binding)
            || binding.scope() != origin.scope() || binding.context() != origin.context()
            || binding.environment() != origin.environment()
        {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(terminal)
    }

    /// W02：只允许用已完成的原 NN02 token 绑定候选 Begin，不发帧。
    pub fn bind_candidate_line(&self, fork: &RegisteredStateOperation, provisional: &OpBinding)
        -> Result<OpBinding, ChannelError> {
        let AuxValue::Forked { line, revision, .. } = self.candidate_fork(fork, provisional)?.value() else {
            return Err(ChannelError::InvalidExpectation);
        };
        self.bind_begin_line_request(provisional, line, *revision)
    }

    /// 已完成的同 driver NN02 token 携带核过的原 Forked；调用方另持当前 M2/M4 派发与源登记。
    /// 此入口从该真实 fork 前沿开始一次候选操作；NW02 未知沿原槽恢复。
    pub fn register_candidate_line(
        &mut self, fork: &RegisteredStateOperation, binding: OpBinding, source: &str,
        budget: NativeBudget, deadline: Instant,
    ) -> Result<StateOperationRegistration, ChannelError> {
        let AuxValue::Forked { line, node, revision, group } = self.candidate_fork(fork, &binding)?.value() else {
            return Err(ChannelError::InvalidExpectation);
        };
        if source.len() as u64 > self.boot.input_byte_quota().get() as u64 {
            return Err(ChannelError::InvalidExpectation);
        }
        let request = NativeRequest::BeginLine {
            header: self.next_header()?,
            args: ArgsBeginLine::new(binding.clone(), line.clone(), *revision, NativeEdit::Append {}, binding.source().clone())?,
        };
        let candidate = CandidateRun { interrupt: Arc::new(CandidateInterruptState::default()), interrupt_issued: false,
            begun: false, source: source.to_owned(), group: group.clone(), parent: node.clone(),
            line_revision: *revision, cursor: U::new(0)?, last_ack: None, step: None, retry_ack: None,
            in_flight: None, finish_error: None };
        self.register_state_operation_inner(request, budget, Some(candidate), deadline)
    }

    fn register_state_operation_inner(
        &mut self, request: NativeRequest, budget: NativeBudget, candidate: Option<CandidateRun>, deadline: Instant,
    ) -> Result<StateOperationRegistration, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        if self.state_operations.slot.is_some()
            || self.state_operations.closed_through.is_some_and(|floor| *budget.operation_seq() <= floor)
        {
            return Err(ChannelError::InvalidExpectation);
        }
        // Step P2: 先核不可变 W02 请求、实际限额及预算，再登记 NW02。
        self.check_state_operation(&request, &budget)?;
        self.ordinary.environment.require_new_work(budget.environment())?;
        self.check_state_operation_limit(&budget)?;
        let write_deadline = deadline.min(absolute_deadline(*budget.execution_deadline_us())?);
        let drain_deadline = absolute_deadline(*budget.recovery_deadline_us())?;
        if Instant::now() >= write_deadline {
            return Err(FrameError::Timeout.into());
        }
        let frame = NativeRequest::RegisterBudget {
            header: self.next_header()?,
            args: ArgsRegisterBudget::new(budget.clone(), budget.grant().clone())?,
        };
        self.nw02.reserve(&budget)?;
        if let NativeRequest::RefreshEnvironment { args, .. } = &request {
            self.ordinary.environment.refreshing = Some(args.clone());
        }
        self.state_operations.slot = Some(StateOperationSlot {
            request,
            budget,
            phase: Phase::Registering { frame, may_have_sent: false },
            forked: Arc::new(OnceLock::new()),
            candidate,
            line_updates: None,
            refresh_status: None,
        });
        self.continue_state_registration(write_deadline, drain_deadline)
    }

    /// NW02 未知后只排空原登记帧；仅明确未发时可继续发送同一保留帧。
    pub fn resume_state_operation_registration(
        &mut self,
        deadline: Instant,
    ) -> Result<StateOperationRegistration, ChannelError> {
        let slot = self.state_operations.slot.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        if let Phase::RegistrationUnresolved(error) = &slot.phase {
            return Err(ChannelError::Native(error.clone()));
        }
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        let Phase::Registering { may_have_sent, .. } = &slot.phase else {
            return Err(ChannelError::InvalidExpectation);
        };
        let drain_deadline = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let write_deadline = if *may_have_sent {
            deadline
        } else {
            self.require_no_unapplied_ack()?;
            self.nw02.reserve(&slot.budget)?;
            self.check_state_operation_limit(&slot.budget)?;
            deadline.min(absolute_deadline(*slot.budget.execution_deadline_us())?)
        };
        self.continue_state_registration(write_deadline, drain_deadline)
    }

    fn continue_state_registration(
        &mut self,
        deadline: Instant,
        drain_deadline: Instant,
    ) -> Result<StateOperationRegistration, ChannelError> {
        let slot = self.state_operations.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        let Phase::Registering { frame, may_have_sent } = &mut slot.phase else {
            return Err(ChannelError::InvalidExpectation);
        };
        let reply = if *may_have_sent {
            self.ordinary.drain_original(frame, deadline.min(drain_deadline))
                .and_then(|reply| reply.ok_or(ChannelError::InvalidExpectation))
        } else {
            let reply = self.ordinary.request_resumable(frame, deadline, deadline, drain_deadline);
            *may_have_sent = reply.is_ok() || self.ordinary.pending_header() == Some(frame.header());
            reply
        };
        if self.ordinary.failed() {
            self.quarantine();
        }
        let reply = reply?;
        let slot = self.state_operations.slot.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        if self.nw02.registration_reply(&slot.budget, &reply).is_err() {
            return self.bad_state_operation_reply();
        }
        if Nw02Reservation::establishment_rejected(&reply) {
            if matches!(&slot.request, NativeRequest::RefreshEnvironment { .. }) {
                self.ordinary.environment.refreshing = None;
            }
            self.state_operations.slot = None;
        } else if let ccv_protocol::nativeface::NativeReply::ProtocolError { error, .. } = &reply {
            self.state_operations.slot.as_mut().expect("原登记槽").phase = Phase::RegistrationUnresolved(error.clone());
            self.quarantine();
        }
        let result = Self::reply_result(reply)?;
        let slot = self.state_operations.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        let budget = &slot.budget;
        match result {
            NativeResult::BudgetRegistered { budget: id, grant, grant_revision }
                if &id == budget.budget() && &grant == budget.grant()
                    && &grant_revision == budget.grant_revision() =>
            {
                let token = RegisteredStateOperation {
                    owner: Arc::downgrade(&self.state_operations.owner),
                    operation_seq: *budget.operation_seq(),
                    request_digest: *budget.initial_request().digest(),
                    forked: slot.forked.clone(),
                    environment_generation: Arc::downgrade(&self.ordinary.environment.generation),
                };
                slot.phase = Phase::Registered;
                Ok(StateOperationRegistration::Registered(token))
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if &operation_seq == budget.operation_seq() && highest_seen >= operation_seq =>
            {
                self.state_operations.slot = None;
                Ok(StateOperationRegistration::PastUnavailable { operation_seq, highest_seen })
            }
            _ => self.bad_state_operation_reply(),
        }
    }

    /// NN02：探索授权与父线当前性由 M2/Pet 核定。
    pub fn fork_line(
        &mut self,
        operation: &RegisteredStateOperation,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.send_state_operation(operation, InitialNativeMethod::ForkLine, deadline)
    }

    pub fn begin_candidate_line(
        &mut self, operation: &RegisteredStateOperation, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.send_state_operation(operation, InitialNativeMethod::BeginLine, deadline)
    }

    pub fn pull_candidate_step(
        &mut self, operation: &RegisteredStateOperation, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        let (candidate, args) = self.state_operations.slot(operation)?.active_candidate()?;
        if candidate.step.is_some() || candidate.interrupt.fenced() { return Err(ChannelError::InvalidExpectation); }
        let expected = candidate.expectation(args)?;
        let frame = NativeRequest::PullStep { header: self.next_header()?,
            args: ArgsPullStep::new(args.binding().clone(), expected.step_seq)? };
        self.send_candidate_step(operation, frame, deadline)
    }

    /// 调用方先持久提交本槽已验证的 Step；传入原持久/恢复截止，不能借 ACK 开新解释。
    /// ACK 应用提交后沿用 confirm_ack_commit。
    pub fn ack_candidate_step(
        &mut self, operation: &RegisteredStateOperation, proof: AckProof, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        let (candidate, args) = self.state_operations.slot(operation)?.active_candidate()?;
        if !candidate.step.as_ref().is_some_and(|step| step.key() == proof.receipt())
            || candidate.retry_ack.as_ref().is_some_and(|original| original != &proof) {
            return Err(ChannelError::InvalidExpectation);
        }
        let frame = NativeRequest::AckStep { header: self.next_header()?,
            args: ArgsAckStep::new(args.binding().clone(), proof)? };
        self.send_candidate_step(operation, frame, deadline)
    }

    fn send_candidate_step(
        &mut self, operation: &RegisteredStateOperation, frame: NativeRequest, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let slot = self.state_operations.slot(operation)?;
        if slot.active_candidate()?.0.in_flight.is_some() { return Err(ChannelError::InFlight); }
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let write = match &frame {
            NativeRequest::PullStep { .. } => {
                self.check_state_operation_limit(&slot.budget)?;
                if slot.active_candidate()?.0.interrupt.fenced() { return Err(ChannelError::InvalidExpectation); }
                deadline.min(absolute_deadline(*slot.budget.execution_deadline_us())?)
            }
            NativeRequest::AckStep { .. } => deadline.min(recovery),
            _ => return Err(ChannelError::InvalidExpectation),
        };
        let reply = self.ordinary.request_resumable(&frame, write, write, recovery);
        if reply.is_ok() || self.ordinary.pending_header() == Some(frame.header()) {
            self.candidate_run_mut().in_flight = Some(frame);
        }
        if self.ordinary.failed() { self.quarantine(); }
        let result = Self::reply_result(reply?)?;
        self.check_candidate_step_result(operation, result, false)
    }

    /// D02：仅排空原步骤/ACK，或查同一操作；不重发 pull/ACK，不用现在的组值补回执。
    pub fn candidate_step_status(
        &mut self, operation: &RegisteredStateOperation, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let slot = self.state_operations.slot(operation)?;
        let (candidate, args) = slot.active_candidate()?;
        let original = candidate.in_flight.clone().ok_or(ChannelError::InvalidExpectation)?;
        if !matches!(&original, NativeRequest::PullStep { .. } | NativeRequest::AckStep { .. }) {
            return Err(ChannelError::InvalidExpectation);
        }
        let binding = args.binding().clone();
        let deadline = deadline.min(absolute_deadline(*slot.budget.recovery_deadline_us())?);
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let reply = self.ordinary.drain_original(&original, deadline);
        if self.ordinary.failed() { self.quarantine(); }
        if let Some(reply) = reply? {
            return self.check_candidate_step_result(operation, Self::reply_result(reply)?, false);
        }
        let frame = NativeRequest::OperationStatus { header: self.next_header()?, args: ArgsOperationStatus::new(binding)? };
        let result = self.native_result(&frame, deadline)?;
        self.check_candidate_step_result(operation, result, true)
    }

    fn candidate_run_mut(&mut self) -> &mut CandidateRun {
        self.state_operations.slot.as_mut().and_then(|slot| slot.candidate.as_mut()).expect("已核候选槽")
    }

    /// 仅为已确认建立的原候选签发一个控制句柄；在开始可阻塞的 pull 前交给 M2。
    pub fn candidate_interrupt(&mut self, operation: &RegisteredStateOperation) -> Result<CandidateInterrupt, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let slot = self.state_operations.slot(operation)?;
        let (run, args) = slot.active_candidate()?;
        if run.interrupt_issued { return Err(ChannelError::InvalidExpectation); }
        let handle = CandidateInterrupt::new(Arc::downgrade(&self.control), Arc::downgrade(&run.interrupt),
            args.binding().clone(), absolute_deadline(*slot.budget.recovery_deadline_us())?);
        self.candidate_run_mut().interrupt_issued = true;
        Ok(handle)
    }

    /// N07：先由 D02 排空原 pull/ACK。WAIT_ACK 只交原 PS05/ACK 路径，随后再 settle。
    pub fn settle_candidate_interrupt(&mut self, operation: &RegisteredStateOperation, deadline: Instant)
        -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let slot = self.state_operations.slot(operation)?;
        let (run, args) = slot.active_candidate()?;
        if !run.interrupt.can_settle() || run.retry_ack.is_some() { return Err(ChannelError::InvalidExpectation); }
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let reply = if let Some(frame) = &run.in_flight {
            if !matches!(frame, NativeRequest::SettleInterrupt { .. }) { return Err(ChannelError::InFlight); }
            self.ordinary.drain_original(frame, deadline).and_then(|r| r.ok_or(ChannelError::InFlight))
        } else {
            let frame = NativeRequest::SettleInterrupt { header: self.next_header()?, args: ArgsSettleInterrupt::new(args.binding().clone())? };
            let reply = self.ordinary.request_resumable(&frame, deadline, deadline, recovery);
            if reply.is_ok() || self.ordinary.pending_header() == Some(frame.header()) {
                self.candidate_run_mut().in_flight = Some(frame);
            }
            reply
        };
        if self.ordinary.failed() { self.quarantine(); }
        let result = match Self::reply_result(reply?) {
            Ok(result) => result,
            Err(error) => { self.quarantine(); return Err(error); }
        };
        let slot = self.state_operations.slot(operation)?;
        let (run, args) = slot.active_candidate()?;
        let expected = run.expectation(args)?;
        match &result {
            NativeResult::Status { status } if status.binding() == expected.binding
                && status.retired_through() < expected.binding.operation_seq()
                && status.highest_seen() >= expected.binding.operation_seq()
                && status.acked_through().get() == expected.step_seq.get() - 1
                && status.last_ack() == &run.last_ack.clone().map_or(Fact::NotApplicable, Fact::Known)
                && *status.stop_requested() && status.terminal() == &Fact::NotApplicable => {
                if let (NativeOpState::WaitAck, Fact::Known(step)) = (status.state(), status.pending()) {
                    if validate_step_receipt(&expected, step).is_err()
                        || run.step.as_ref().is_some_and(|original| original != step) {
                        return self.bad_state_operation_reply();
                    }
                    let run = self.candidate_run_mut();
                    run.step = Some(step.clone());
                    run.in_flight = None;
                } else {
                    // 非终态不证明停稳；无另一个已审安全恢复入口。
                    self.quarantine();
                }
            }
            NativeResult::Terminal { terminal } if run.step.is_none()
                && validate_terminal(&expected, None, terminal, Some(&run.group)).is_ok() => {
                if let TerminalRecord::Receipt { receipt } = terminal {
                    if let ReceiptPayload::Interrupted { stopped, synchronized, last_acked, pending, .. } = receipt.payload() {
                        if stopped != &Fact::Known(true) || synchronized != &Fact::Known(true)
                            || last_acked != &Fact::Known(run.parent.clone()) || pending != &Fact::NotApplicable
                            || receipt.execution_extent() == &ExecutionExtent::UnknownTail {
                            self.quarantine();
                            return Ok(result);
                        }
                    }
                }
                self.record_candidate_terminal(terminal)?;
                self.candidate_run_mut().in_flight = None;
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if operation_seq == expected.binding.operation_seq() && highest_seen >= operation_seq => self.quarantine(),
            _ => return self.bad_state_operation_reply(),
        }
        Ok(result)
    }

    fn check_candidate_step_result(
        &mut self, operation: &RegisteredStateOperation, result: NativeResult, status_read: bool,
    ) -> Result<NativeResult, ChannelError> {
        let slot = self.state_operations.slot(operation)?;
        let (candidate, args) = slot.active_candidate()?;
        let expected = candidate.expectation(args)?;
        let original = candidate.in_flight.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        let result = match checked_candidate_step(candidate, &expected, original, result, status_read) {
            Ok(result) => result,
            Err(_) => return self.bad_state_operation_reply(),
        };
        match &result {
            NativeResult::Receipt { receipt } => self.candidate_run_mut().step = Some(receipt.clone()),
            NativeResult::Ack { ack } => {
                let binding = args.binding().clone();
                let Some(ReceiptPayload::Step { fact, .. }) = candidate.step.as_ref().map(Receipt::payload) else {
                    return self.bad_state_operation_reply();
                };
                let (node, cursor) = (fact.node().clone(), *fact.next_cursor());
                let KnownOrNa::Known(group) = ack.group() else { return self.bad_state_operation_reply() };
                self.retain_checked_ack(&binding, ack)?;
                let candidate = self.candidate_run_mut();
                candidate.parent = node;
                candidate.cursor = cursor;
                candidate.line_revision = *ack.line_revision();
                candidate.group = group.clone();
                candidate.last_ack = Some(ack.clone());
                candidate.step = None;
                candidate.retry_ack = None;
            }
            NativeResult::Terminal { terminal } => self.record_candidate_terminal(terminal)?,
            NativeResult::Status { status } if status_read && status.state() == &NativeOpState::WaitAck => {
                // checked_candidate_step 已核原 pending、上一个完整 ACK 及操作身份。
                let NativeRequest::AckStep { args, .. } = original else { return self.bad_state_operation_reply(); };
                let proof = args.proof().clone();
                let run = self.candidate_run_mut();
                run.retry_ack = Some(proof);
                run.in_flight = None;
                return Ok(result);
            }
            // 未能确认本次原效果；保留原请求及已确认前沿。
            _ => return Ok(result),
        }
        self.candidate_run_mut().in_flight = None;
        Ok(result)
    }

    fn record_candidate_terminal(&mut self, terminal: &TerminalRecord) -> Result<(), ChannelError> {
                let (key, extent, finish_error) = match terminal {
                    TerminalRecord::Receipt { receipt } => {
                        let extent = receipt.execution_extent();
                        let eligible = extent == &ExecutionExtent::UnknownTail && matches!(receipt.payload(),
                            ReceiptPayload::Error { stage: NativeStage::Parse | NativeStage::Execute,
                                group: KnownOrNa::Known(_), .. });
                        (receipt.key(), extent.clone(), eligible.then(|| receipt.clone()))
                    }
                    TerminalRecord::Eof { completion } => (completion.key(), ExecutionExtent::CompleteKnown, None),
                    TerminalRecord::PrefixReached { .. } => return self.bad_state_operation_reply(),
                };
                let slot = self.state_operations.slot.as_mut().expect("已核候选槽");
                // 原 extent 不变；该错误仅可在 N08 内复核状态，不开放继续解释。
                slot.candidate.as_mut().expect("已核候选槽").finish_error = finish_error;
                slot.phase = Phase::Established { terminal: Some((key.clone(), extent)) };
        Ok(())
    }

    /// W02：绑定完整 grouped N04 请求，供 M4 登记意图及 NW02 构造预算；不发帧。
    /// M2 须先将当前 lease 映射为真实 native group/version，并核定目的线、
    /// 候选热节点及 scope；durable_path 必须引用 M4 明确提交的成功路径。
    pub fn bind_grouped_select_line(&self, args: &ArgsSelectLine) -> Result<NativeRequest, ChannelError> {
        if !matches!(args.group(), KnownOrNa::Known(_)) {
            return Err(ChannelError::InvalidExpectation);
        }
        let mut request = NativeRequest::SelectLine { header: self.next_header()?, args: args.clone() };
        let digest = request.operation_digest(Limits::MESSAGE)?;
        let NativeRequest::SelectLine { args: bound, .. } = &mut request else {
            unreachable!()
        };
        let old = args.binding();
        let binding = OpBinding::new(
            old.operation_id().clone(), *old.operation_seq(), digest, old.context().clone(),
            old.scope().clone(), old.source().clone(), old.environment().clone(), old.budget().clone(),
        )?;
        *bound = ArgsSelectLine::new(
            binding, args.destination().clone(), *args.expected_revision(), args.candidate().clone(),
            args.group().clone(), args.durable_path().clone(),
        )?;
        Ok(request)
    }

    /// N04：仅发送已经由 register_state_operation 核实并保存在原槽中的 grouped 请求。
    /// 已发未知用 state_operation_status；持久确认终态后用 finish_state_operation。
    pub fn select_grouped_line(
        &mut self,
        operation: &RegisteredStateOperation,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.send_state_operation(operation, InitialNativeMethod::SelectLine, deadline)
    }

    /// NN03：返回完整 line_updates 引用；消费与 PS06 应用确认仍由 M2/M6/M4 完成。
    pub fn sync_source(
        &mut self,
        operation: &RegisteredStateOperation,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.send_state_operation(operation, InitialNativeMethod::SyncSource, deadline)
    }

    /// NN04：调用方须持当前 M5 发布事实，且 M2 已封受影响上下文。
    /// W02 只把既有发布 ID 和新旧环境固定进原请求，不为调用方核发 M5 权限。
    pub fn bind_refresh_environment(&self, args: &ArgsRefreshEnvironment) -> Result<NativeRequest, ChannelError> {
        self.ordinary.environment.require_new_work(args.old_environment())?;
        let old = args.binding();
        if old.environment() != args.old_environment() { return Err(ChannelError::InvalidExpectation); }
        let header = self.next_header()?;
        let draft = NativeRequest::RefreshEnvironment { header: header.clone(), args: args.clone() };
        let binding = OpBinding::new(old.operation_id().clone(), *old.operation_seq(), draft.operation_digest(Limits::MESSAGE)?,
            old.context().clone(), old.scope().clone(), old.source().clone(), old.environment().clone(), old.budget().clone())?;
        Ok(NativeRequest::RefreshEnvironment { header, args: ArgsRefreshEnvironment::new(binding,
            args.old_environment().clone(), args.new_environment().clone(), args.publication().clone())? })
    }

    /// 只发送原登记请求；未决结果用 state_operation_status 查同一操作。
    pub fn refresh_environment(
        &mut self,
        operation: &RegisteredStateOperation,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.send_state_operation(operation, InitialNativeMethod::RefreshEnvironment, deadline)
    }

    fn send_state_operation(
        &mut self,
        operation: &RegisteredStateOperation,
        method: InitialNativeMethod,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        let slot = self.state_operations.slot(operation)?;
        if !matches!(&slot.phase, Phase::Registered)
            || slot.budget.initial_request().method() != &method
        {
            return Err(ChannelError::InvalidExpectation);
        }
        self.check_state_operation(&slot.request, &slot.budget)?;
        self.nw02.require_registered(&slot.budget)?;
        self.check_state_operation_limit(&slot.budget)?;
        let write_deadline = deadline.min(absolute_deadline(*slot.budget.execution_deadline_us())?);
        let drain_deadline = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let next_header = self.next_header()?;
        let slot = self.state_operations.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        match &mut slot.request {
            NativeRequest::BeginLine { header, .. }
            | NativeRequest::ForkLine { header, .. }
            | NativeRequest::SelectLine { header, .. }
            | NativeRequest::SyncSource { header, .. }
            | NativeRequest::RefreshEnvironment { header, .. } => *header = next_header,
            _ => return Err(ChannelError::InvalidExpectation),
        }

        // Step P5/P11: 保留原帧供排空；写超期后不借恢复预算继续写。
        slot.phase = Phase::Established { terminal: None };
        let reply = self.ordinary.request_resumable(
            &slot.request, write_deadline, write_deadline, drain_deadline,
        );
        if reply.is_err() && self.ordinary.pending_header() != Some(slot.request.header()) {
            slot.phase = Phase::Registered;
        } else if let NativeRequest::BeginLine { args, .. } = &slot.request {
            let owner = self.state_operations.candidate_lines.get_mut(args.line()).expect("已核候选线");
            *owner = Some((args.binding().operation_id().clone(), *args.binding().operation_seq()));
        }
        if self.ordinary.failed() {
            self.quarantine();
        }
        let reply = reply?;
        self.observe_state_rejection(&reply);
        let result = Self::reply_result(reply)?;
        self.check_state_result(result, false)
    }

    /// D02：只排空原帧或查同一操作；RETIRING、past_unavailable 与原生 admission 原样保留。
    /// 调用方应在原恢复截止时间内对账，未知时继续保持派发隔离。
    pub fn state_operation_status(
        &mut self,
        operation: &RegisteredStateOperation,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        let slot = self.state_operations.slot(operation)?;
        if !matches!(&slot.phase, Phase::Established { .. }) {
            return Err(ChannelError::InvalidExpectation);
        }
        if slot.candidate.as_ref().is_some_and(|run| run.begun) {
            return Err(ChannelError::InvalidExpectation);
        }
        let binding = self.check_state_operation(&slot.request, &slot.budget)?.clone();
        let deadline = deadline.min(absolute_deadline(*slot.budget.recovery_deadline_us())?);
        if Instant::now() >= deadline {
            return Err(FrameError::Timeout.into());
        }
        if matches!(&slot.request, NativeRequest::RefreshEnvironment { .. }) {
            if let Some(frame) = &slot.refresh_status {
                let reply = self.ordinary.drain_original(frame, deadline);
                if self.ordinary.failed() { self.quarantine(); }
                let reply = reply?.ok_or(ChannelError::InFlight)?;
                self.state_operations.slot.as_mut().expect("原 NN04 槽").refresh_status = None;
                return self.check_state_result(Self::reply_result(reply)?, true);
            }
        }
        let refresh_recovery = if matches!(&slot.request, NativeRequest::RefreshEnvironment { .. }) {
            Some(absolute_deadline(*slot.budget.recovery_deadline_us())?)
        } else { None };
        let reply = self.ordinary.drain_original(&slot.request, deadline);
        if self.ordinary.failed() {
            self.quarantine();
        }
        if let Some(reply) = reply? {
            self.observe_state_rejection(&reply);
            return self.check_state_result(Self::reply_result(reply)?, false);
        }
        let request = NativeRequest::OperationStatus { header: self.next_header()?, args: ArgsOperationStatus::new(binding)? };
        if let Some(recovery) = refresh_recovery {
            let reply = self.ordinary.request_resumable(&request, deadline, deadline, recovery);
            if self.ordinary.pending_header() == Some(request.header()) {
                self.state_operations.slot.as_mut().expect("原 NN04 槽").refresh_status = Some(request);
            }
            if self.ordinary.failed() { self.quarantine(); }
            return self.check_state_result(Self::reply_result(reply?)?, true);
        }
        let result = self.native_result(&request, deadline)?;
        self.check_state_result(result, true)
    }

    fn observe_state_rejection(&mut self, reply: &ccv_protocol::nativeface::NativeReply) {
        if Nw02Reservation::establishment_rejected(reply) {
            if let Some(slot) = &self.state_operations.slot {
                self.nw02.consume(&slot.budget);
                // 仅建立帧的明确 NotAdmitted 可清候选 Begin/grouped N04 槽；status 的错误不作此推断。
                if let NativeRequest::BeginLine { args, .. } = &slot.request {
                    if let Some(owner) = self.state_operations.candidate_lines.get_mut(args.line()) {
                        *owner = None;
                    }
                }
                if matches!(&slot.request, NativeRequest::SelectLine { .. } | NativeRequest::BeginLine { .. }) {
                    self.state_operations.slot = None;
                }
            }
        }
    }

    /// N08：调用方须先持久确认此终态。未知时仅排空原 finish 帧，且不释放槽。
    /// Finished 只确认原操作回执，不证明组/分支根已释放。
    pub fn finish_state_operation(
        &mut self,
        operation: &RegisteredStateOperation,
        terminal_key: &ReceiptKey,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        let slot = self.state_operations.slot(operation)?;
        match &slot.phase {
            Phase::FinishUnresolved { key, error } if key == terminal_key => return Err(ChannelError::Native(error.clone())),
            Phase::FinishPast { key, result } if key == terminal_key => return Ok(result.clone()),
            Phase::FinishUnresolved { .. } | Phase::FinishPast { .. } => return Err(ChannelError::InvalidExpectation),
            _ => (),
        }
        self.require_no_unapplied_ack()?;
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        let slot = self.state_operations.slot(operation)?;
        if slot.line_updates.as_ref().is_some_and(|updates| !updates.released()) {
            return Err(ChannelError::InvalidExpectation);
        }
        let recovery_deadline = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery_deadline);
        if Instant::now() >= deadline {
            return Err(FrameError::Timeout.into());
        }
        let candidate_error_confirmed = if matches!(&slot.phase,
            Phase::Established { terminal: Some((key, ExecutionExtent::UnknownTail)) } if key == terminal_key)
        {
            let run = slot.candidate.as_ref().ok_or(ChannelError::InvalidExpectation)?;
            let receipt = run.finish_error.as_ref().filter(|receipt| receipt.key() == terminal_key)
                .ok_or(ChannelError::InvalidExpectation)?;
            if !run.begun || run.step.is_some() || run.in_flight.is_some() {
                return Err(ChannelError::InvalidExpectation);
            }
            let binding = self.check_state_operation(&slot.request, &slot.budget)?.clone();
            let last_ack = run.last_ack.clone().map_or(Fact::NotApplicable, Fact::Known);
            let acked_through = run.last_ack.as_ref().map_or(0, |ack| ack.acked_through().get());
            let terminal = AnyTerminal::Terminal(TerminalRecord::Receipt { receipt: receipt.clone() });
            // 同步 Pet 只有在该错误恢复到原父节点后才公布此 TERMINAL。
            match self.read_operation_status(binding.clone(), deadline)? {
                NativeResult::Status { status } if status.binding() == &binding
                    && status.retired_through() < binding.operation_seq()
                    && status.highest_seen() >= binding.operation_seq()
                    && status.state() == &NativeOpState::Terminal
                    && status.pending() == &Fact::NotApplicable
                    && status.acked_through().get() == acked_through
                    && status.last_ack() == &last_ack
                    && matches!(status.terminal(), Fact::Known(seen) if seen == &terminal) => (),
                result @ NativeResult::PastUnavailable { operation_seq, highest_seen }
                    if &operation_seq == binding.operation_seq() && highest_seen >= operation_seq => return Ok(result),
                _ => return self.bad_state_operation_reply(),
            }
            if Instant::now() >= deadline {
                return Err(FrameError::Timeout.into());
            }
            true
        } else {
            false
        };
        let slot = self.state_operations.slot(operation)?;
        let (reply, extent) = match &slot.phase {
            Phase::Established { terminal: Some((key, extent)) }
                if key == terminal_key && (extent != &ExecutionExtent::UnknownTail || candidate_error_confirmed) =>
            {
                let (binding, _) = state_operation_head(&slot.request, &slot.budget)?;
                let terminal = (key.clone(), extent.clone());
                let frame = NativeRequest::FinishOperation {
                    header: self.next_header()?,
                    args: ArgsFinishOperation::new(binding.clone(), key.clone())?,
                };
                let slot = self.state_operations.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
                slot.phase = Phase::Finishing { frame, extent: terminal.1.clone() };
                let Phase::Finishing { frame, .. } = &slot.phase else {
                    return Err(ChannelError::InvalidExpectation);
                };
                let reply = self.ordinary.request_resumable(frame, deadline, deadline, recovery_deadline);
                if reply.is_err() && self.ordinary.pending_header() != Some(frame.header()) {
                    slot.phase = Phase::Established { terminal: Some(terminal.clone()) };
                }
                (reply, terminal.1)
            }
            Phase::Finishing { frame, extent } => {
                if !matches!(frame, NativeRequest::FinishOperation { args, .. }
                    if args.terminal_receipt_key() == terminal_key)
                {
                    return Err(ChannelError::InvalidExpectation);
                }
                (self.ordinary.drain_original(frame, deadline)
                    .and_then(|reply| reply.ok_or(ChannelError::InvalidExpectation)), extent.clone())
            }
            _ => return Err(ChannelError::InvalidExpectation),
        };
        if self.ordinary.failed() {
            self.quarantine();
        }
        let reply = reply?;
        if let ccv_protocol::nativeface::NativeReply::ProtocolError { error, .. } = reply {
            let rejected = error.admission() == &ccv_protocol::nativeface::Admission::NotAdmitted;
            self.state_operations.slot.as_mut().expect("原 N08 槽").phase = if rejected {
                Phase::Established { terminal: Some((terminal_key.clone(), extent)) }
            } else {
                Phase::FinishUnresolved { key: terminal_key.clone(), error: error.clone() }
            };
            if !rejected { self.quarantine(); }
            return Err(ChannelError::Native(error));
        }
        let result = Self::reply_result(reply)?;
        match &result {
            NativeResult::Finished { key } if key == terminal_key => {
                self.state_operations.closed_through = Some(operation.operation_seq);
                self.state_operations.slot = None;
                Ok(result)
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if *operation_seq == operation.operation_seq && highest_seen >= operation_seq => {
                self.state_operations.slot.as_mut().expect("原 N08 槽").phase =
                    Phase::FinishPast { key: terminal_key.clone(), result: result.clone() };
                Ok(result)
            }
            _ => self.bad_state_operation_reply(),
        }
    }

    fn check_state_operation<'a>(
        &self,
        request: &'a NativeRequest,
        budget: &NativeBudget,
    ) -> Result<&'a OpBinding, ChannelError> {
        let (binding, method) = state_operation_head(request, budget)?;
        let header = request.header();
        if header.instance() != self.boot.instance()
            || header.backend_epoch() != *self.boot.backend_epoch()
            || header.manager_epoch() != *self.boot.manager_epoch()
            || budget.clock_boot() != self.boot.clock_boot()
            || !matches!(budget.purpose(), NativePurpose::Task {})
            || budget.checkpoint_limits() != &KnownOrNa::NotApplicable
            || budget.recovery_deadline_us() < budget.execution_deadline_us()
            || budget.initial_request().method() != &method
            || budget.initial_request().phase() != &InitialPhase::NotApplicable
            || binding.operation_seq().get() == 0
            || binding.operation_seq() != budget.operation_seq()
            || binding.operation_id() != budget.operation()
            || binding.budget() != budget.budget()
            || binding.scope() != budget.scope()
            || binding.source() != budget.source()
            || binding.environment() != budget.environment()
            || binding.request_digest() != budget.initial_request().digest()
            || &request.operation_digest(Limits::MESSAGE)? != binding.request_digest()
        {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(binding)
    }

    fn check_state_operation_limit(&self, budget: &NativeBudget) -> Result<(), ChannelError> {
        // 与现有 ND04/NW02 checkpoint 路径相同：域修订是零基，wire grant 修订是正数。
        if !self.domain.verify_applied_limit().is_ok_and(|actual| {
            &actual.grant == budget.grant()
                && actual.revision.get().checked_add(1) == Some(budget.grant_revision().get())
        }) {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(())
    }

    fn check_state_result(
        &mut self,
        result: NativeResult,
        status_read: bool,
    ) -> Result<NativeResult, ChannelError> {
        let slot = self.state_operations.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        let (binding, method) = state_operation_head(&slot.request, &slot.budget)?;
        if let Some(candidate) = &slot.candidate {
            // D02 建立对账只接受原 BeginLine 的零步状态；之后走候选逐句对账。
            if candidate.step.is_some() || candidate.last_ack.is_some() || candidate.in_flight.is_some()
                || !matches!(&slot.phase, Phase::Established { terminal: None })
            {
                return Err(ChannelError::InvalidExpectation);
            }
            match &result {
                NativeResult::Status { status } if state_status_binding(status, binding)
                    && status.state() == &NativeOpState::Ready
                    && status.terminal() == &Fact::NotApplicable && !*status.stop_requested() =>
                {
                    self.nw02.consume(&slot.budget);
                    slot.candidate.as_mut().expect("candidate slot").begun = true;
                }
                NativeResult::PastUnavailable { operation_seq, highest_seen }
                    if operation_seq == binding.operation_seq() && highest_seen >= operation_seq => (),
                _ => return self.bad_state_operation_reply(),
            }
            return Ok(result);
        }
        let view_quota = *self.boot.view_byte_quota();
        let valid_terminal = |terminal: &AuxTerminal| {
            state_operation_terminal(slot, binding, terminal, view_quota)
        };
        let grouped_args = match &slot.request {
            NativeRequest::SelectLine { args, .. } => Some(args),
            _ => None,
        };
        let mut terminal = None;
        let valid = match &result {
            NativeResult::AuxTerminal { terminal: aux } if !status_read && grouped_args.is_none() => {
                terminal = Some((aux.key(), aux.execution_extent()));
                valid_terminal(aux)
            }
            NativeResult::Receipt { receipt } if !status_read => {
                terminal = Some((receipt.key(), receipt.execution_extent()));
                grouped_args.is_some_and(|args| grouped_selection_receipt(args, receipt))
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen } => {
                operation_seq == binding.operation_seq() && highest_seen >= operation_seq
            }
            NativeResult::Status { status } if state_status_binding(status, binding) => {
                match (status.state(), status.terminal()) {
                    (NativeOpState::Terminal, Fact::Known(AnyTerminal::Aux(aux)))
                        if status_read && grouped_args.is_none() =>
                    {
                        terminal = Some((aux.key(), aux.execution_extent()));
                        valid_terminal(aux)
                    }
                    (NativeOpState::Terminal, Fact::Known(AnyTerminal::Terminal(TerminalRecord::Receipt { receipt })))
                        if status_read =>
                    {
                        terminal = Some((receipt.key(), receipt.execution_extent()));
                        grouped_args.is_some_and(|args| grouped_selection_receipt(args, receipt))
                    }
                    (NativeOpState::Retiring, terminal)
                        if matches!(method, InitialNativeMethod::SyncSource | InitialNativeMethod::RefreshEnvironment)
                            && !matches!(&slot.phase, Phase::Established { terminal: Some(_) }) =>
                    {
                        // 保留已关联的观察；整个结果仍是 RETIRING，不是可 finish 的终态。
                        match terminal {
                            Fact::Unknown | Fact::NotApplicable => true,
                            Fact::Known(AnyTerminal::Aux(terminal)) => valid_terminal(terminal),
                            _ => false,
                        }
                    }
                    (NativeOpState::Ready | NativeOpState::Executing, Fact::Unknown | Fact::NotApplicable)
                        if status_read => matches!(&slot.phase, Phase::Established { terminal: None }),
                    _ => false,
                }
            }
            _ => false,
        };
        if !valid {
            return self.bad_state_operation_reply();
        }
        if let Some((key, extent)) = terminal {
            let grouped = grouped_args.is_some();
            let Phase::Established { terminal } = &mut slot.phase else {
                return Err(ChannelError::InvalidExpectation);
            };
            if terminal.as_ref().is_some_and(|(original_key, original_extent)| {
                original_key != key || original_extent != extent
            }) {
                return self.bad_state_operation_reply();
            }
            if grouped || extent != &ExecutionExtent::UnknownTail {
                *terminal = Some((key.clone(), extent.clone()));
            }
        }
        let aux = match &result {
            NativeResult::AuxTerminal { terminal } => Some(terminal),
            NativeResult::Status { status } => match status.terminal() {
                Fact::Known(AnyTerminal::Aux(terminal)) if status.state() == &NativeOpState::Terminal => Some(terminal),
                _ => None,
            },
            _ => None,
        };
        if let Some(aux) = aux.filter(|t| matches!(t.value(), AuxValue::SourceSynced { .. })) {
            if let Some(updates) = &slot.line_updates {
                if updates.terminal() != aux { return self.bad_state_operation_reply(); }
            } else {
                slot.line_updates = Some(line_updates::LineUpdates::new(aux.clone())?);
            }
        }
        if let (NativeRequest::RefreshEnvironment { args, .. }, Some(aux)) = (&slot.request, aux) {
            if let AuxValue::EnvironmentRefreshed { environment, changed, .. } = aux.value() {
                // 重读已核终态只返回原事实；不再次切换或撤销新一代 owner。
                if self.ordinary.environment.refreshing.is_some() {
                    if self.ordinary.environment.publish(args, environment, *changed).is_err() {
                        return self.bad_state_operation_reply();
                    }
                    if *changed {
                        if let Some(run) = &self.mainline { run.revoke_interrupt(); }
                        self.inspection.revoke_interrupt();
                    }
                } else if &self.ordinary.environment.id != environment {
                    return self.bad_state_operation_reply();
                }
            }
        }
        if let Some(forked) = aux.filter(|t| matches!(t.value(), AuxValue::Forked { .. })) {
            if let Some(original) = slot.forked.get() {
                if original != forked {
                    return self.bad_state_operation_reply();
                }
            } else {
                let _ = slot.forked.set(forked.clone());
            }
            if let AuxValue::Forked { line, .. } = forked.value() {
                self.state_operations.candidate_lines.entry(line.clone()).or_insert(None);
            }
        }
        self.nw02.consume(&slot.budget);
        Ok(result)
    }

    fn bad_state_operation_reply<T>(&mut self) -> Result<T, ChannelError> {
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }
}

fn state_operation_head<'a>(
    request: &'a NativeRequest,
    budget: &NativeBudget,
) -> Result<(&'a OpBinding, InitialNativeMethod), ChannelError> {
    match request {
        NativeRequest::BeginLine { args, .. } => Ok((args.binding(), InitialNativeMethod::BeginLine)),
        NativeRequest::ForkLine { args, .. } if args.expected_line().id() != args.new_line() => {
            Ok((args.binding(), InitialNativeMethod::ForkLine))
        }
        NativeRequest::SelectLine { args, .. } if matches!(args.group(), KnownOrNa::Known(_)) => {
            Ok((args.binding(), InitialNativeMethod::SelectLine))
        }
        NativeRequest::SyncSource { args, .. }
            if args.expected_context().id() == args.context()
                && args.binding().context() == args.context() && budget.output_bytes().get() > 0 =>
        {
            Ok((args.binding(), InitialNativeMethod::SyncSource))
        }
        NativeRequest::RefreshEnvironment { args, .. }
            if args.old_environment() == args.binding().environment() =>
        {
            Ok((args.binding(), InitialNativeMethod::RefreshEnvironment))
        }
        _ => Err(ChannelError::InvalidExpectation),
    }
}

fn checked_candidate_step(
    candidate: &CandidateRun, expected: &StepExpectation<'_>, original: &NativeRequest,
    result: NativeResult, status_read: bool,
) -> Result<NativeResult, ChannelError> {
    let mismatch = ChannelError::ReplyMismatch;
    // W01：先核 RPC 的结果分支，再对 status 内的原事实归一化。
    if (status_read && !matches!(&result, NativeResult::Status { .. } | NativeResult::PastUnavailable { .. }))
        || (!status_read && matches!(&result, NativeResult::Status { .. }))
    {
        return Err(mismatch);
    }
    let proof = match original {
        NativeRequest::PullStep { .. } => None,
        NativeRequest::AckStep { args, .. } => Some(args.proof()),
        _ => return Err(mismatch),
    };
    let result = match result {
        NativeResult::Status { ref status } if status_read => {
            let binding = expected.binding;
            if status.binding() != binding || status.retired_through() >= binding.operation_seq()
                || status.highest_seen() < binding.operation_seq()
            {
                return Err(mismatch);
            }
            let before = candidate.last_ack.as_ref().map_or(0, |ack| ack.acked_through().get());
            let previous_ack = match (candidate.last_ack.as_ref(), status.last_ack()) {
                (None, Fact::NotApplicable) => true,
                (Some(original), Fact::Known(seen)) => original == seen,
                _ => false,
            };
            if proof.is_some() && status.acked_through().get() == expected.step_seq.get()
                && matches!(status.state(), NativeOpState::Ready | NativeOpState::Retiring)
                && status.pending() == &Fact::NotApplicable && status.terminal() == &Fact::NotApplicable
            {
                let Fact::Known(ack) = status.last_ack() else { return Err(mismatch) };
                NativeResult::Ack { ack: ack.clone() }
            } else {
                if status.acked_through().get() != before || !previous_ack { return Err(mismatch); }
                match (status.state(), status.pending(), status.terminal()) {
                    (NativeOpState::WaitAck, Fact::Known(step), Fact::NotApplicable) => {
                        if proof.is_some() {
                            if candidate.step.as_ref() != Some(step) { return Err(mismatch); }
                            return Ok(result);
                        }
                        NativeResult::Receipt { receipt: step.clone() }
                    }
                    (NativeOpState::Terminal, Fact::NotApplicable, Fact::Known(AnyTerminal::Terminal(terminal)))
                        if proof.is_none() => NativeResult::Terminal { terminal: terminal.clone() },
                    (NativeOpState::Ready | NativeOpState::Executing, Fact::NotApplicable, Fact::NotApplicable)
                        if proof.is_none() => return Ok(result),
                    (NativeOpState::Retiring, Fact::NotApplicable | Fact::Unknown,
                        Fact::NotApplicable | Fact::Unknown) => return Ok(result),
                    _ => return Err(mismatch),
                }
            }
        }
        other => other,
    };
    match &result {
        NativeResult::Receipt { receipt } if proof.is_none() => validate_step_receipt(expected, receipt)?,
        NativeResult::Terminal { terminal } if proof.is_none() => validate_terminal(expected, None, terminal, Some(&candidate.group))?,
        NativeResult::Ack { .. } | NativeResult::RetiredStep { .. } if proof.is_some() => {
            validate_ack_reply(expected, proof.expect("ACK 原帧"), &result, Some(&candidate.group))?;
        }
        NativeResult::PastUnavailable { operation_seq, highest_seen }
            if operation_seq == expected.binding.operation_seq() && highest_seen >= operation_seq => (),
        _ => return Err(mismatch),
    }
    Ok(result)
}

fn grouped_selection_receipt(args: &ArgsSelectLine, receipt: &Receipt) -> bool {
    let binding = args.binding();
    let key = receipt.key();
    if receipt.binding() != binding
        || key.operation_id() != binding.operation_id()
        || key.operation_seq() != binding.operation_seq()
        || key.receipt_seq().get() != 1
        || !receipt.digest(Limits::MESSAGE).is_ok_and(|digest| &digest == key.digest())
    {
        return false;
    }
    match receipt.payload() {
        ReceiptPayload::Selected { line, before_revision, after_revision, node, group: Fact::Known(applied) } => {
            let KnownOrNa::Known(expected) = args.group() else { return false; };
            // N04 返回实际采用后的版本；组结束按 rmcp-4 §11.2 增加组版本，不约定步长。
            // 目的线核原版本和实际变更；PS06 的逻辑路径递增规则不用于此 native 版本。
            receipt.execution_extent() == &ExecutionExtent::CompleteKnown
                && line == args.destination() && before_revision == args.expected_revision()
                && after_revision > before_revision && node == args.candidate()
                && applied.group() == expected.group()
                && applied.expected_revision() > expected.expected_revision()
        }
        ReceiptPayload::Error { stage, group: KnownOrNa::NotApplicable, .. } => matches!(stage, NativeStage::Parse | NativeStage::Execute
            | NativeStage::Register | NativeStage::Restore | NativeStage::View),
        _ => false,
    }
}

fn state_status_binding(status: &OpStatus, binding: &OpBinding) -> bool {
    status.binding() == binding
        && status.acked_through().get() == 0
        && status.pending() == &Fact::NotApplicable
        && status.last_ack() == &Fact::NotApplicable
        && status.retired_through() < binding.operation_seq()
        && status.highest_seen() >= binding.operation_seq()
}

fn state_operation_terminal(
    operation: &StateOperationSlot,
    binding: &OpBinding,
    terminal: &AuxTerminal,
    view_quota: Upos,
) -> bool {
    // W03：只核该操作的完整 AuxTerminal；错误事实保留真实 extent。
    let key = terminal.key();
    if terminal.binding() != binding
        || key.operation_id() != binding.operation_id()
        || key.operation_seq() != binding.operation_seq()
        || key.receipt_seq().get() == 0
        || !terminal.digest(Limits::MESSAGE).is_ok_and(|digest| &digest == key.digest())
    {
        return false;
    }
    if let AuxValue::Error { stage, .. } = terminal.value() {
        return matches!(stage, NativeStage::Parse | NativeStage::Execute | NativeStage::Register
            | NativeStage::Restore | NativeStage::View);
    }
    if terminal.execution_extent() != &ExecutionExtent::CompleteKnown {
        return false;
    }
    match (&operation.request, terminal.value()) {
        (NativeRequest::ForkLine { args, .. }, AuxValue::Forked { line, node, group, .. }) => {
            line == args.new_line() && node == args.parent() && group.group() == args.exploration()
        }
        (NativeRequest::SyncSource { header, args },
         AuxValue::SourceSynced { context, revision, source, boundary, line_updates, .. }) => {
            context == args.context() && source == args.new_source()
                && revision >= args.expected_context().revision()
                && line_updates.bytes().get() > 0
                && line_updates.bytes() <= operation.budget.output_bytes()
                && line_updates.bytes().get() <= view_quota.get()
                && match boundary {
                    Fact::Known(fact) => fact.instance() == header.instance()
                        && *fact.backend_epoch() == header.backend_epoch()
                        && *fact.manager_epoch() == header.manager_epoch()
                        && fact.context() == context && fact.source() == source
                        && fact.environment() == binding.environment(),
                    Fact::Unknown | Fact::NotApplicable => true,
                }
        }
        (NativeRequest::RefreshEnvironment { args, .. },
         AuxValue::EnvironmentRefreshed { environment, changed, reclaim }) => {
            environment == args.new_environment()
                && *changed == (args.old_environment() != args.new_environment())
                && (*changed || reclaim == &Fact::NotApplicable)
        }
        _ => false,
    }
}
