//! N05 独立生命周期槽：原操作有待排空的借用时，仍可沿原 owner 处理其 ACK/finish/release。

use super::{checkpoint::absolute_deadline, valid_nw02_key, ChannelError, FrameError, NativeDriver, Nw02Reservation};
use ccv_protocol::nativeface::{AnyTerminal, ArgsEndScope, ArgsFinishOperation, ArgsOperationStatus,
    ArgsRegisterBudget, EndedStatus, InitialNativeMethod, KnownOrNa, NativeBudget, NativeOpState, NativePurpose,
    NativeProtocolError, NativeReply, NativeRequest, NativeResult, NativeStage, OpBinding, Receipt, ReceiptKey,
    ReceiptPayload, TerminalRecord};
use ccv_protocol::reply::ExecutionExtent;
use ccv_protocol::{Fact, Limits, U};
use std::{sync::Arc, time::Instant};

#[derive(Default)]
pub(super) struct EndScopeOperations {
    slot: Option<EndScopeSlot>,
    used_through: Option<U>,
}

struct EndScopeSlot {
    token: RegisteredEndScope,
    args: ArgsEndScope,
    budget: NativeBudget,
    phase: Phase,
    pending: Option<NativeRequest>,
    pending_first: bool,
    progress: Option<Receipt>,
    terminal: Option<Receipt>,
}

#[derive(PartialEq, Eq)]
enum Phase { Registering, RegistrationUnresolved(NativeProtocolError), Registered, Uncertain, Closing, Terminal, Finishing }

/// 仅由 Driver 核 NW02 回包后签发，不能作为 M2/M4 授权凭据。
#[derive(Clone)]
pub struct RegisteredEndScope(Arc<()>);

pub enum EndScopeRegistration {
    Registered(RegisteredEndScope),
    PastUnavailable { operation_seq: U, highest_seen: U },
}

impl EndScopeOperations {
    pub(super) fn owns_binding(&self, binding: &OpBinding) -> bool {
        self.slot.as_ref().is_some_and(|slot| slot.args.binding().operation_id() == binding.operation_id()
            || slot.args.binding().operation_seq() == binding.operation_seq())
    }

    fn slot(&self, token: &RegisteredEndScope) -> Result<&EndScopeSlot, ChannelError> {
        self.slot.as_ref().filter(|slot| Arc::ptr_eq(&slot.token.0, &token.0))
            .ok_or(ChannelError::InvalidExpectation)
    }
}

impl NativeDriver {
    /// W02：保留调用方给出的 native scope 和 expected_revision；上游 revision 来源尚未接线。
    pub fn bind_end_scope(&self, args: &ArgsEndScope) -> Result<ArgsEndScope, ChannelError> {
        if args.scope() != args.binding().scope() { return Err(ChannelError::InvalidExpectation); }
        let draft = NativeRequest::EndScope { header: self.next_header()?, args: args.clone() };
        let b = args.binding();
        let binding = OpBinding::new(b.operation_id().clone(), *b.operation_seq(), draft.operation_digest(Limits::MESSAGE)?,
            b.context().clone(), b.scope().clone(), b.source().clone(), b.environment().clone(), b.budget().clone())?;
        Ok(ArgsEndScope::new(binding, args.scope().clone(), *args.expected_revision())?)
    }

    /// 调用方先核 M2 撤准入和 M4 原关闭意图。applied grant 从实际域读回，不由回包补齐。
    pub fn register_end_scope(&mut self, args: ArgsEndScope, budget: NativeBudget, deadline: Instant)
        -> Result<EndScopeRegistration, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.end_scopes.slot.is_some() || self.is_quarantined()
            || self.end_scopes.used_through.is_some_and(|seq| seq >= *budget.operation_seq()) {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        let request = NativeRequest::EndScope { header: header.clone(), args: args.clone() };
        // 借用已有 NW02 完整请求核验；不在正式槽伪造 BudgetRegistered。
        Nw02Reservation::validate_head(&budget, &request, args.binding(), InitialNativeMethod::EndScope)?;
        if args.scope() != args.binding().scope()
            || budget.clock_boot() != self.boot.clock_boot()
            || budget.recovery_deadline_us() < budget.execution_deadline_us()
            || !matches!((budget.purpose(), budget.checkpoint_limits()),
                (NativePurpose::Task {}, KnownOrNa::NotApplicable)) {
            // checkpoint_control 清理是独立授权：当前域读回只有 grant/修订，
            // 没有原 control/attempt 的 arena 或整 scope PS27 封存证据。
            return Err(ChannelError::InvalidExpectation);
        }
        self.check_end_scope_grant(&budget)?;
        let frame = NativeRequest::RegisterBudget { header, args: ArgsRegisterBudget::new(budget.clone(), budget.grant().clone())? };
        let write = deadline.min(absolute_deadline(*budget.execution_deadline_us())?);
        let recovery = absolute_deadline(*budget.recovery_deadline_us())?;
        if Instant::now() >= write { return Err(FrameError::Timeout.into()); }
        self.nw02.reserve(&budget)?;
        self.ordinary.end_scope_owner = Some((args.binding().operation_id().clone(), *args.binding().operation_seq()));
        self.end_scopes.slot = Some(EndScopeSlot { token: RegisteredEndScope(Arc::new(())), args, budget,
            phase: Phase::Registering, pending: None, pending_first: false, progress: None, terminal: None });
        let reply = self.send_end_scope_frame(frame, write, recovery);
        if reply.is_err() && self.end_scopes.slot.as_ref().is_some_and(|slot| slot.pending.is_none()) {
            let slot = self.end_scopes.slot.take().expect("原登记未发");
            self.nw02.consume(&slot.budget);
            self.ordinary.end_scope_owner = None;
        }
        self.checked_end_scope_registration(reply?)
    }

    pub fn resume_end_scope_registration(&mut self, deadline: Instant) -> Result<EndScopeRegistration, ChannelError> {
        let slot = self.end_scopes.slot.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        match &slot.phase {
            Phase::Registering => (),
            Phase::RegistrationUnresolved(error) => return Err(ChannelError::Native(error.clone())),
            _ => return Err(ChannelError::InvalidExpectation),
        }
        let frame = slot.pending.clone().ok_or(ChannelError::InvalidExpectation)?;
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let reply = self.drain_end_scope_frame(&frame, deadline.min(recovery))?;
        self.checked_end_scope_registration(reply)
    }

    fn checked_end_scope_registration(&mut self, reply: NativeReply) -> Result<EndScopeRegistration, ChannelError> {
        let slot = self.end_scopes.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        if self.nw02.registration_reply(&slot.budget, &reply).is_err() { return self.bad_end_scope_reply(); }
        if Nw02Reservation::establishment_rejected(&reply) {
            self.clear_end_scope_slot();
        } else if let NativeReply::ProtocolError { error, .. } = &reply {
            // 原回复已完整读出，无帧可排空；保留预算与占槽，交 M2 对账或隔离核停。
            slot.phase = Phase::RegistrationUnresolved(error.clone());
            self.quarantine();
        }
        match Self::reply_result(reply)? {
            NativeResult::BudgetRegistered { .. } => {
                let slot = self.end_scopes.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
                slot.phase = Phase::Registered;
                Ok(EndScopeRegistration::Registered(slot.token.clone()))
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen } => {
                self.end_scopes.used_through = Some(operation_seq);
                self.clear_end_scope_slot();
                Ok(EndScopeRegistration::PastUnavailable { operation_seq, highest_seen })
            }
            _ => self.bad_end_scope_reply(),
        }
    }

    fn check_end_scope_grant(&self, budget: &NativeBudget) -> Result<(), ChannelError> {
        if !self.domain.verify_applied_limit().is_ok_and(|actual| &actual.grant == budget.grant()
            && actual.revision.get().checked_add(1) == Some(budget.grant_revision().get())) {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(())
    }

    /// 首次发原 N05，或在已核 closing 后继续原操作。调用者负责先让原 owner 排空借用。
    pub fn end_scope(&mut self, token: &RegisteredEndScope, deadline: Instant) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        let slot = self.end_scopes.slot(token)?;
        if slot.pending.is_some() { return Err(ChannelError::InFlight); }
        let first = slot.phase == Phase::Registered;
        if !first && slot.phase != Phase::Closing { return Err(ChannelError::InvalidExpectation); }
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let frame = NativeRequest::EndScope { header: self.next_header()?, args: slot.args.clone() };
        let write = if first {
            self.nw02.check_head(&frame, slot.args.binding(), InitialNativeMethod::EndScope)?;
            self.check_end_scope_grant(&slot.budget)?;
            deadline.min(absolute_deadline(*slot.budget.execution_deadline_us())?)
        } else { deadline.min(recovery) };
        let reply = self.send_end_scope_frame(frame, write, recovery);
        let slot = self.end_scopes.slot.as_mut().expect("原 N05 槽");
        if slot.pending.is_some() { slot.pending_first = first; }
        if reply.is_ok() || slot.pending.is_some() { slot.phase = Phase::Uncertain; }
        let reply = reply?;
        self.checked_end_scope_reply(reply, false, first)
    }

    /// D02：先排空原帧；只读原 operation，不以查询代替 N05 继续检查。
    pub fn end_scope_status(&mut self, token: &RegisteredEndScope, deadline: Instant) -> Result<NativeResult, ChannelError> {
        let slot = self.end_scopes.slot(token)?;
        if !matches!(slot.phase, Phase::Uncertain | Phase::Closing | Phase::Terminal) {
            return Err(ChannelError::InvalidExpectation);
        }
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        if let Some(frame) = slot.pending.clone() {
            let status = matches!(&frame, NativeRequest::OperationStatus { .. });
            let first = !status && slot.pending_first;
            let reply = self.drain_end_scope_frame(&frame, deadline)?;
            return self.checked_end_scope_reply(reply, status, first);
        }
        let frame = NativeRequest::OperationStatus { header: self.next_header()?, args: ArgsOperationStatus::new(slot.args.binding().clone())? };
        let reply = self.send_end_scope_frame(frame, deadline, recovery)?;
        self.checked_end_scope_reply(reply, true, false)
    }

    fn checked_end_scope_reply(&mut self, reply: NativeReply, status_read: bool, first: bool)
        -> Result<NativeResult, ChannelError> {
        let slot = self.end_scopes.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        if first && Nw02Reservation::establishment_rejected(&reply) {
            self.nw02.consume(&slot.budget);
            self.end_scopes.used_through = Some(*slot.budget.operation_seq());
            self.clear_end_scope_slot();
        }
        let result = Self::reply_result(reply)?;
        let slot = self.end_scopes.slot.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        let binding = slot.args.binding();
        let (phase, receipt) = match &result {
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if operation_seq == binding.operation_seq() && highest_seen >= operation_seq => {
                self.nw02.consume(&slot.budget);
                slot.phase = Phase::Uncertain;
                return Ok(result);
            }
            NativeResult::Receipt { receipt } if !status_read && (!first || receipt.key().receipt_seq().get() == 1) => match scope_receipt_phase(slot, receipt) {
                Some(phase) => (phase, Some(receipt)),
                None => return self.bad_end_scope_reply(),
            },
            NativeResult::Status { status } if status_read && status.binding() == binding
                && status.retired_through() < binding.operation_seq() && status.highest_seen() >= binding.operation_seq()
                && status.acked_through().get() == 0 && status.pending() == &Fact::NotApplicable
                && status.last_ack() == &Fact::NotApplicable => match (status.state(), status.terminal()) {
                (NativeOpState::Retiring, Fact::NotApplicable) => (Phase::Closing, None),
                (NativeOpState::Terminal, Fact::Known(AnyTerminal::Terminal(TerminalRecord::Receipt { receipt })))
                    if scope_receipt_phase(slot, receipt) == Some(Phase::Terminal) => (Phase::Terminal, Some(receipt)),
                _ => return self.bad_end_scope_reply(),
            },
            _ => return self.bad_end_scope_reply(),
        };
        if let Some(old) = &slot.terminal {
            if phase != Phase::Terminal || receipt != Some(old) { return self.bad_end_scope_reply(); }
        } else if let Some(receipt) = receipt {
            if let Some(old) = &slot.progress {
                if receipt.key().receipt_seq() <= old.key().receipt_seq() && receipt != old {
                    return self.bad_end_scope_reply();
                }
            }
            if phase == Phase::Terminal { slot.terminal = Some(receipt.clone()); }
            else { slot.progress = Some(receipt.clone()); }
        }
        slot.phase = phase;
        self.nw02.consume(&slot.budget);
        Ok(result)
    }

    /// N08：调用者已持久保存原终态。closing 不是 finish 的输入。
    pub fn finish_end_scope(&mut self, token: &RegisteredEndScope, key: &ReceiptKey, deadline: Instant)
        -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        let slot = self.end_scopes.slot(token)?;
        if !slot.terminal.as_ref().is_some_and(|r| r.key() == key && r.execution_extent() != &ExecutionExtent::UnknownTail) {
            return Err(ChannelError::InvalidExpectation);
        }
        let seq = *slot.budget.operation_seq();
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        let reply = match slot.phase {
            Phase::Terminal => {
                if slot.pending.is_some() { return Err(ChannelError::InFlight); }
                let frame = NativeRequest::FinishOperation { header: self.next_header()?,
                    args: ArgsFinishOperation::new(slot.args.binding().clone(), key.clone())? };
                self.send_end_scope_frame(frame, deadline, recovery)
            }
            Phase::Finishing => {
                let frame = slot.pending.clone().ok_or(ChannelError::InvalidExpectation)?;
                if !matches!(&frame, NativeRequest::FinishOperation { args, .. } if args.terminal_receipt_key() == key) {
                    return Err(ChannelError::InvalidExpectation);
                }
                self.drain_end_scope_frame(&frame, deadline)
            }
            _ => return Err(ChannelError::InvalidExpectation),
        };
        let slot = self.end_scopes.slot.as_mut().expect("原 N08 槽");
        slot.phase = if slot.pending.is_some() { Phase::Finishing } else { Phase::Terminal };
        let result = Self::reply_result(reply?)?;
        match &result {
            NativeResult::Finished { key: seen } if seen == key => {
                self.end_scopes.used_through = Some(seq);
                self.clear_end_scope_slot();
                Ok(result)
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if *operation_seq == seq && highest_seen >= operation_seq => {
                self.end_scopes.slot.as_mut().expect("原 N08 槽").phase = Phase::Uncertain;
                Ok(result)
            }
            _ => self.bad_end_scope_reply(),
        }
    }

    fn send_end_scope_frame(&mut self, frame: NativeRequest, write: Instant, recovery: Instant) -> Result<NativeReply, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        if self.end_scopes.slot.as_ref().is_some_and(|s| s.pending.is_some()) { return Err(ChannelError::InFlight); }
        let reply = self.ordinary.channel.request_resumable(&frame, write, write, recovery);
        if self.ordinary.pending_header() == Some(frame.header()) {
            self.end_scopes.slot.as_mut().expect("原 N05 槽").pending = Some(frame);
        }
        if self.ordinary.failed() { self.quarantine(); }
        reply
    }

    fn drain_end_scope_frame(&mut self, frame: &NativeRequest, deadline: Instant) -> Result<NativeReply, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let reply = self.ordinary.channel.drain_original(frame, deadline);
        if self.ordinary.failed() { self.quarantine(); }
        let reply = reply?.ok_or(ChannelError::InvalidExpectation)?;
        let slot = self.end_scopes.slot.as_mut().expect("原 N05 槽");
        slot.pending = None;
        slot.pending_first = false;
        Ok(reply)
    }

    fn clear_end_scope_slot(&mut self) {
        self.end_scopes.slot = None;
        self.ordinary.end_scope_owner = None;
    }

    fn bad_end_scope_reply<T>(&mut self) -> Result<T, ChannelError> {
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }
}

fn scope_receipt_phase(slot: &EndScopeSlot, receipt: &Receipt) -> Option<Phase> {
    if receipt.binding() != slot.args.binding() || !valid_nw02_key(receipt.key(), &slot.budget)
        || !receipt.digest(Limits::MESSAGE).is_ok_and(|digest| &digest == receipt.key().digest()) {
        return None;
    }
    match receipt.payload() {
        ReceiptPayload::Ended { scope, status: EndedStatus::Closing, .. } if scope == slot.args.scope() => Some(Phase::Closing),
        // reclaim 只是原引用事实，保持其 Fact 域，不把关闭转成清根或额度结算证明。
        ReceiptPayload::Ended { scope, status: EndedStatus::Closed, .. }
            if scope == slot.args.scope() && receipt.execution_extent() == &ExecutionExtent::CompleteKnown => Some(Phase::Terminal),
        ReceiptPayload::Error { stage: NativeStage::Parse | NativeStage::Execute | NativeStage::Register | NativeStage::Restore
            | NativeStage::View, group: KnownOrNa::NotApplicable, .. } => Some(Phase::Terminal),
        _ => None,
    }
}
