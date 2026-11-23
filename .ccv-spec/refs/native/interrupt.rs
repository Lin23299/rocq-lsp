//! D03 控制通道：操作凭据来自原操作 owner，取消决定来自 M2。

use super::{checkpoint::absolute_deadline, validate_ack_reply, validate_pull_reply, validate_step_receipt,
    validate_terminal, Channel, ChannelError, FrameError, NativeDriver, StepExpectation};
use ccv_protocol::nativeface::{AckProof, AckStatus, AnyTerminal, ArgsBeginLine, ArgsSettleInterrupt,
    NativeBudget, NativeOpState, NativeReply, NativeRequest, NativeResult, OpStatus, Receipt, ReceiptKey, ReceiptPayload, TerminalRecord};
use ccv_protocol::Fact;
use ccv_protocol::reply::ExecutionExtent;
use ccv_protocol::nativeface::{CancelAckStatus, CancelReason, ControlPhase, ControlReply, ControlRequest, ControlResult, ControlSnapshot, OpBinding};
use ccv_protocol::{Digest32, Id, U, Upos};
use std::sync::{Arc, Mutex, Weak, atomic::{AtomicBool, Ordering}};
use std::time::Instant;

#[derive(Default)]
pub(super) struct CandidateInterruptState {
    fenced: AtomicBool,
    settle: AtomicBool,
    revoked: AtomicBool,
}

impl CandidateInterruptState {
    pub(super) fn fenced(&self) -> bool { self.fenced.load(Ordering::Acquire) }
    pub(super) fn can_settle(&self) -> bool { self.settle.load(Ordering::Acquire) }
    pub(super) fn revoke(&self) { self.revoked.store(true, Ordering::Release); }
}

/// 同一操作的控制端；可交给独立线程，不借用普通通道。
pub struct CandidateInterrupt {
    channel: Weak<Mutex<Channel>>,
    state: Weak<CandidateInterruptState>,
    binding: OpBinding,
    recovery: Instant,
    decision: Option<(U, CancelReason)>,
    phase: CancelPhase,
}

enum CancelPhase {
    Start,
    Status(ControlRequest),
    Snapshot(ControlSnapshot),
    Cancel(ControlRequest, ControlSnapshot),
    Done(ControlResult),
    ProtocolError(ccv_protocol::nativeface::NativeProtocolError),
    Blocked,
}

impl CandidateInterrupt {
    pub(super) fn new(channel: Weak<Mutex<Channel>>, state: Weak<CandidateInterruptState>, binding: OpBinding,
        recovery: Instant) -> Self {
        Self { channel, state, binding, recovery, decision: None, phase: CancelPhase::Start }
    }

    /// 仅可信 M2 调用：原取消决定、序号和原因已持久，且当前身份仍允许止损。
    /// 读取原控制 cell，按读到的 generation 发一次取消；返回原观察，不证明解释停止。
    pub fn cancel(&mut self, seq: U, reason: CancelReason, deadline: Instant) -> Result<ControlResult, ChannelError> {
        if seq.get() == 0 || self.decision.as_ref().is_some_and(|d| d != &(seq, reason.clone())) {
            return Err(ChannelError::InvalidExpectation);
        }
        match &self.phase {
            CancelPhase::Done(result) => return Ok(result.clone()),
            CancelPhase::ProtocolError(error) => return Err(ChannelError::Native(error.clone())),
            CancelPhase::Blocked => return Err(ChannelError::Failed),
            _ => (),
        }
        let deadline = deadline.min(self.recovery);
        if Instant::now() >= self.recovery {
            self.phase = CancelPhase::Blocked;
            return Err(FrameError::Timeout.into());
        }
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let state = self.state.upgrade();
        let channel = self.channel.upgrade().ok_or(ChannelError::Failed)?;
        let mut channel = channel.try_lock().map_err(|_| ChannelError::InFlight)?;
        let revoked = || state.as_ref().is_none_or(|s| s.revoked.load(Ordering::Acquire));
        if let Some(state) = &state { state.fenced.store(true, Ordering::Release); }
        self.decision.get_or_insert((seq, reason.clone()));
        let operation = self.binding.operation_id();
        loop {
            if channel.failed() {
                self.phase = CancelPhase::Blocked;
                return Err(ChannelError::Failed);
            }
            let request = match &self.phase {
                CancelPhase::Start if !revoked() => {
                    self.phase = CancelPhase::Status(ControlRequest::Status {
                        header: channel.next_header()?, operation_id: operation.clone(),
                    });
                    continue;
                }
                CancelPhase::Snapshot(before) if !revoked() => {
                    let request = ControlRequest::Cancel { header: channel.next_header()?, operation_id: operation.clone(),
                        token_generation: *before.token_generation(), cancel_seq: seq, reason: reason.clone() };
                    self.phase = CancelPhase::Cancel(request, before.clone());
                    continue;
                }
                CancelPhase::Status(request) | CancelPhase::Cancel(request, _) => request,
                _ => return Err(ChannelError::InvalidExpectation),
            };
            let reply = match channel.control_resumable(request, deadline, self.recovery, revoked()) {
                Ok(Some(reply)) => reply,
                Ok(None) => return Err(ChannelError::InvalidExpectation),
                Err(error) => {
                    if channel.failed() || !matches!(error, ChannelError::InFlight | ChannelError::Frame(FrameError::Timeout)) {
                        self.phase = CancelPhase::Blocked;
                    }
                    return Err(error);
                }
            };
            let result = match reply {
                ControlReply::Result { result, .. } => result,
                ControlReply::ProtocolError { error, .. } => {
                    self.phase = CancelPhase::ProtocolError(error.clone());
                    return Err(ChannelError::Native(error));
                }
            };
            match (&self.phase, &result) {
                (CancelPhase::Status(_), ControlResult::Snapshot { snapshot }) if snapshot.operation_id() == operation => {
                    self.phase = CancelPhase::Snapshot(snapshot.clone());
                    if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
                    continue;
                }
                (CancelPhase::Cancel(_, before), ControlResult::CancelAck { status, snapshot })
                    if valid_cancel_ack(before, seq, status, snapshot) => {
                    if let Some(state) = state.as_ref().filter(|_| !revoked()) {
                        if matches!(status, CancelAckStatus::Received | CancelAckStatus::AlreadyTerminal) {
                            state.settle.store(true, Ordering::Release);
                        }
                    }
                }
                (_, ControlResult::UnknownOperation { operation_id }) if operation_id == operation => (),
                _ => {
                    self.phase = CancelPhase::Blocked;
                    return Err(ChannelError::ReplyMismatch);
                }
            }
            self.phase = CancelPhase::Done(result.clone());
            return Ok(result);
        }
    }
}

fn valid_cancel_ack(before: &ControlSnapshot, seq: U, status: &CancelAckStatus, after: &ControlSnapshot) -> bool {
    if before.operation_id() != after.operation_id() || after.highest_cancel_seq() < before.highest_cancel_seq()
        || after.token_generation() < before.token_generation() { return false; }
    match status {
        CancelAckStatus::Received => after.token_generation() == before.token_generation()
            && after.highest_cancel_seq() == &seq && *after.stop_requested() && after.phase() != &ControlPhase::TerminalPhase,
        CancelAckStatus::AlreadyTerminal => after.phase() == &ControlPhase::TerminalPhase,
        CancelAckStatus::PastCancel => after.highest_cancel_seq() > &seq,
        CancelAckStatus::Stale => after.token_generation() > before.token_generation(),
    }
}

pub(super) struct Mainline {
    pub(super) binding: OpBinding,
    line: Id,
    budget: NativeBudget,
    base: U,
    front: Option<(Id, U)>,
    pull_expectation: Option<(Upos, Digest32)>,
    last_ack: Option<AckStatus>,
    step: Option<Receipt>,
    retry_ack: Option<AckProof>,
    pub(super) in_flight: Option<NativeRequest>,
    pub(super) terminal: Option<ReceiptKey>,
    terminal_reply: Option<TerminalRecord>,
    control: Arc<CandidateInterruptState>,
    issued: bool,
}

impl Mainline {
    pub(super) fn revoke_interrupt(&self) { self.control.revoke(); }

    pub(super) fn from_ready(args: &ArgsBeginLine, budget: NativeBudget, status: &OpStatus) -> Result<Self, ChannelError> {
        if !status_bound(args.binding(), status) || status.state() != &NativeOpState::Ready
            || status.acked_through().get() != 0 || *status.stop_requested() || status.last_ack() != &Fact::NotApplicable
            || status.pending() != &Fact::NotApplicable || status.terminal() != &Fact::NotApplicable {
            return Err(ChannelError::ReplyMismatch);
        }
        Ok(Self { binding: args.binding().clone(), line: args.line().clone(), budget, base: *args.expected_revision(),
            front: None, pull_expectation: None, last_ack: None, step: None, retry_ack: None, in_flight: None,
            terminal: None, terminal_reply: None,
            control: Arc::new(CandidateInterruptState::default()), issued: false })
    }
    pub(super) fn matches(&self, b: &OpBinding) -> bool {
        self.binding.operation_id() == b.operation_id() || self.binding.operation_seq() == b.operation_seq()
    }
    pub(super) fn recovery(&self) -> Result<Instant, ChannelError> { absolute_deadline(*self.budget.recovery_deadline_us()) }

    fn check_front(&self, expected: &StepExpectation<'_>) -> Result<(), ChannelError> {
        let acked = self.last_ack.as_ref().map_or(0, |ack| ack.acked_through().get());
        if &self.binding != expected.binding || &self.line != expected.line || self.terminal.is_some()
            || self.base != expected.base_revision || Some(expected.step_seq.get()) != acked.checked_add(1)
            || self.front.as_ref().is_some_and(|(node, cursor)| node != expected.parent || cursor != &expected.cursor)
            || self.pull_expectation.as_ref().is_some_and(|(receipt_seq, digest)|
                receipt_seq != &expected.receipt_seq || digest != &Digest32::sha256(expected.source.as_bytes())) {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(())
    }

    pub(super) fn permits_prefix_observation(&self, expected: &StepExpectation<'_>) -> bool {
        !self.control.fenced() && self.in_flight.is_none() && self.check_front(expected).is_ok()
    }

    pub(super) fn prefix_terminal(&self, expected: &StepExpectation<'_>, target: &Id) -> Option<TerminalRecord> {
        if &self.binding != expected.binding || &self.line != expected.line { return None; }
        let terminal = self.terminal_reply.as_ref()?;
        validate_terminal(expected, Some(target), terminal, None).ok()?;
        Some(terminal.clone())
    }
}

fn status_bound(binding: &OpBinding, status: &OpStatus) -> bool {
    status.binding() == binding && status.retired_through() < binding.operation_seq()
        && status.highest_seen() >= binding.operation_seq()
}

impl NativeDriver {
    /// 原普通 append 已获 NW02/READY；在可阻塞 pull 前交给独立的 M2 控制任务。
    pub fn mainline_interrupt(&mut self, binding: &OpBinding) -> Result<CandidateInterrupt, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        self.ordinary.environment.require_new_work(binding.environment())?;
        let run = self.mainline.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        if &run.binding != binding || run.issued || run.terminal.is_some() { return Err(ChannelError::InvalidExpectation); }
        let handle = CandidateInterrupt::new(Arc::downgrade(&self.control), Arc::downgrade(&run.control),
            binding.clone(), run.recovery()?);
        run.issued = true;
        Ok(handle)
    }

    pub(super) fn exchange_mainline_step(&mut self, expected: &StepExpectation<'_>, frame: &NativeRequest, deadline: Instant)
        -> Result<NativeReply, ChannelError> {
        let Some(run) = &self.mainline else { return self.exchange(frame, deadline); };
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        run.check_front(expected)?;
        if run.in_flight.is_some() { return Err(ChannelError::InFlight); }
        let recovery = run.recovery()?;
        let write = match frame {
            NativeRequest::PullStep { .. } if !run.control.fenced() && run.step.is_none() =>
                deadline.min(absolute_deadline(*run.budget.execution_deadline_us())?),
            NativeRequest::AckStep { args, .. } if run.step.as_ref().is_some_and(|step| step.key() == args.proof().receipt())
                && run.retry_ack.as_ref().is_none_or(|proof| proof == args.proof()) => deadline.min(recovery),
            _ => return Err(ChannelError::InvalidExpectation),
        };
        let reply = self.ordinary.request_resumable(frame, write, write, recovery);
        if reply.is_ok() || self.ordinary.pending_header() == Some(frame.header()) {
            let run = self.mainline.as_mut().expect("原主线");
            if matches!(frame, NativeRequest::PullStep { .. }) {
                run.front = Some((expected.parent.clone(), expected.cursor));
                run.pull_expectation = Some((expected.receipt_seq, Digest32::sha256(expected.source.as_bytes())));
            }
            run.in_flight = Some(frame.clone());
        }
        if self.ordinary.failed() { self.quarantine(); }
        reply
    }

    pub(super) fn observe_mainline_step(&mut self, expected: &StepExpectation<'_>, result: &NativeResult) -> Result<(), ChannelError> {
        let Some(run) = &mut self.mainline else { return Ok(()); };
        match result {
            NativeResult::Receipt { receipt } => {
                run.front = Some((expected.parent.clone(), expected.cursor));
                run.step = Some(receipt.clone());
            }
            NativeResult::Ack { ack } => {
                let Some(ReceiptPayload::Step { fact, .. }) = run.step.take().as_ref().map(Receipt::payload).cloned() else {
                    self.quarantine(); return Err(ChannelError::ReplyMismatch);
                };
                run.front = Some((fact.node().clone(), *fact.next_cursor()));
                run.base = *ack.line_revision();
                run.last_ack = Some(ack.clone());
                run.retry_ack = None;
                run.pull_expectation = None;
                self.retain_checked_ack(expected.binding, ack)?;
            }
            NativeResult::Terminal { terminal } => {
                let (key, safe) = match terminal {
                    TerminalRecord::Receipt { receipt } => (receipt.key(), &ExecutionExtent::UnknownTail != receipt.execution_extent()
                        && match receipt.payload() {
                            ReceiptPayload::Interrupted { stopped, synchronized, last_acked, pending, .. } =>
                                stopped == &Fact::Known(true) && synchronized == &Fact::Known(true)
                                    && last_acked == &Fact::Known(expected.parent.clone()) && pending == &Fact::NotApplicable,
                            _ => true,
                        }),
                    TerminalRecord::Eof { completion } => (completion.key(), true),
                    TerminalRecord::PrefixReached { completion } => (completion.key(), true),
                };
                run.control.revoke();
                if safe {
                    run.terminal = Some(key.clone());
                    run.terminal_reply = Some(terminal.clone());
                } else { self.quarantine(); return Ok(()); }
            }
            NativeResult::PastUnavailable { .. } => { run.control.revoke(); self.quarantine(); return Ok(()); }
            _ => return Ok(()),
        }
        self.mainline.as_mut().expect("原主线").in_flight = None;
        Ok(())
    }

    /// D02：确认原帧；若原 ACK 已明确仍为 WAIT_ACK，只允许重交完全相同的 PS05 凭据。
    pub fn reconcile_mainline_interrupt(&mut self, expected: &StepExpectation<'_>, deadline: Instant) -> Result<NativeResult, ChannelError> {
        self.mainline_interrupt_turn(expected, deadline, false)
    }

    /// N07：已收原 pull/ACK、已持久确认原 ACK，才检查同一普通 append 的真实退出状态。
    pub fn settle_mainline_interrupt(&mut self, expected: &StepExpectation<'_>, deadline: Instant) -> Result<NativeResult, ChannelError> {
        self.mainline_interrupt_turn(expected, deadline, true)
    }

    fn mainline_interrupt_turn(&mut self, expected: &StepExpectation<'_>, deadline: Instant, settle: bool)
        -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let run = self.mainline.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        run.check_front(expected)?;
        if !run.control.fenced() || (settle && (!run.control.can_settle() || run.retry_ack.is_some())) {
            return Err(ChannelError::InvalidExpectation);
        }
        let recovery = run.recovery()?;
        let deadline = deadline.min(recovery);
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let original = run.in_flight.clone();
        let mut status_read = false;
        let mut proof = None;
        let result = if settle {
            let reply = if let Some(frame) = original.as_ref() {
                if !matches!(frame, NativeRequest::SettleInterrupt { .. }) { return Err(ChannelError::InFlight); }
                self.ordinary.drain_original(frame, deadline).and_then(|r| r.ok_or(ChannelError::InFlight))
            } else {
                let frame = NativeRequest::SettleInterrupt { header: self.next_header()?, args: ArgsSettleInterrupt::new(expected.binding.clone())? };
                let reply = self.ordinary.request_resumable(&frame, deadline, deadline, recovery);
                if reply.is_ok() || self.ordinary.pending_header() == Some(frame.header()) {
                    self.mainline.as_mut().expect("原主线").in_flight = Some(frame);
                }
                reply
            };
            self.checked_mainline_transport(reply)?
        } else {
            let frame = original.as_ref().ok_or(ChannelError::InvalidExpectation)?;
            match frame {
                NativeRequest::PullStep { args, .. } if args.expected_step_seq() == &expected.step_seq => (),
                NativeRequest::AckStep { args, .. } if expected.key_matches(args.proof().receipt()) => proof = Some(args.proof()),
                _ => return Err(ChannelError::InvalidExpectation),
            }
            let reply = self.ordinary.drain_original(frame, deadline);
            if self.ordinary.failed() { self.quarantine(); }
            match reply? {
                Some(reply) => self.checked_mainline_transport(Ok(reply))?,
                None => { status_read = true; self.read_operation_status(expected.binding.clone(), deadline)? }
            }
        };
        let run = self.mainline.as_ref().expect("原主线");
        let checked = check_mainline_recovery(run, expected, proof, result, status_read, settle);
        let (result, retry) = match checked { Ok(value) => value, Err(error) => { self.quarantine(); return Err(error); } };
        if retry {
            let run = self.mainline.as_mut().expect("原主线");
            run.retry_ack = proof.cloned();
            run.in_flight = None;
        } else if matches!(&result, NativeResult::PastUnavailable { .. }) {
            self.quarantine();
        } else if !matches!(&result, NativeResult::Status { .. }) {
            self.observe_mainline_step(expected, &result)?;
        }
        Ok(result)
    }

    fn checked_mainline_transport(&mut self, reply: Result<NativeReply, ChannelError>) -> Result<NativeResult, ChannelError> {
        if self.ordinary.failed() { self.quarantine(); }
        match Self::reply_result(reply?) {
            Ok(result) => Ok(result),
            Err(error) => { self.quarantine(); Err(error) }
        }
    }
}

fn check_mainline_recovery(run: &Mainline, expected: &StepExpectation<'_>, proof: Option<&AckProof>,
    result: NativeResult, status_read: bool, settle: bool) -> Result<(NativeResult, bool), ChannelError> {
    let mismatch = ChannelError::ReplyMismatch;
    match &result {
        NativeResult::PastUnavailable { operation_seq, highest_seen }
            if operation_seq == expected.binding.operation_seq() && highest_seen >= operation_seq => return Ok((result, false)),
        NativeResult::Status { status } if (status_read || settle) && status_bound(expected.binding, status) => {
            if settle && !*status.stop_requested() { return Err(mismatch); }
            if let Some(proof) = proof {
                if matches!(status.state(), NativeOpState::Ready | NativeOpState::Retiring)
                    && status.acked_through().get() == expected.step_seq.get()
                    && status.pending() == &Fact::NotApplicable && status.terminal() == &Fact::NotApplicable {
                    let Fact::Known(ack) = status.last_ack() else { return Err(mismatch); };
                    let result = NativeResult::Ack { ack: ack.clone() };
                    validate_ack_reply(expected, proof, &result, None)?;
                    return Ok((result, false));
                }
            }
            if status.acked_through().get() != expected.step_seq.get() - 1
                || status.last_ack() != &run.last_ack.clone().map_or(Fact::NotApplicable, Fact::Known) { return Err(mismatch); }
            match (status.state(), status.pending(), status.terminal()) {
                (NativeOpState::WaitAck, Fact::Known(step), Fact::NotApplicable) => {
                    validate_step_receipt(expected, step)?;
                    if run.step.as_ref().is_some_and(|prior| prior != step) { return Err(mismatch); }
                    return if proof.is_some() { Ok((result, true)) }
                        else { Ok((NativeResult::Receipt { receipt: step.clone() }, false)) };
                }
                (NativeOpState::Terminal, Fact::NotApplicable, Fact::Known(AnyTerminal::Terminal(terminal)))
                    if status_read && proof.is_none() && run.step.is_none() => {
                    validate_terminal(expected, None, terminal, None)?;
                    return Ok((NativeResult::Terminal { terminal: terminal.clone() }, false));
                }
                (NativeOpState::Ready | NativeOpState::Executing | NativeOpState::Retiring, Fact::NotApplicable, Fact::NotApplicable)
                    if status_read && proof.is_none() => return Ok((result, false)),
                _ => return Err(mismatch),
            }
        }
        _ => (),
    }
    if status_read { return Err(mismatch); }
    if settle {
        let NativeResult::Terminal { terminal } = &result else { return Err(mismatch); };
        if run.step.is_some() { return Err(mismatch); }
        validate_terminal(expected, None, terminal, None)?;
    } else if let Some(proof) = proof {
        validate_ack_reply(expected, proof, &result, None)?;
    } else {
        validate_pull_reply(expected, None, &result)?;
    }
    Ok((result, false))
}

#[cfg(test)]
mod interrupt_regression {
    use super::*;
    use ccv_protocol::{decode, encode, Limits};
    use std::{os::unix::net::UnixStream, time::Duration};

    #[test]
    fn resumes_original_status_then_cancel_without_retargeting() {
        let id = |s: &str| Id::new(s.into()).unwrap();
        let u = |n| U::new(n).unwrap();
        let (stream, mut peer) = UnixStream::pair().unwrap();
        let channel = Arc::new(Mutex::new(Channel::control_after_handshake_for_test(stream, id("instance"), u(1))));
        let state = Arc::new(CandidateInterruptState::default());
        let binding = |op: &str| OpBinding::new(id(op), u(1), Digest32::sha256(b""), id("ctx"), id("scope"),
            id("src"), id("env"), id("budget")).unwrap();
        let recovery = Instant::now() + Duration::from_secs(5);
        let mut handle = CandidateInterrupt::new(Arc::downgrade(&channel), Arc::downgrade(&state), binding("op"), recovery);
        let short = || Instant::now() + Duration::from_millis(40);
        let read = |peer: &mut UnixStream| {
            let bytes = crate::native::read_frame(peer, recovery).unwrap();
            decode::<ControlRequest>(&bytes, Limits::MESSAGE).unwrap().into_inner()
        };
        let send = |peer: &mut UnixStream, reply: ControlReply| {
            let bytes = encode(&reply, Limits::MESSAGE).unwrap();
            crate::native::write_frame(peer, &bytes, recovery).unwrap();
        };
        let snap = |seq, stopped| ControlSnapshot::new(id("op"), ControlPhase::Active, u(7), u(seq), stopped).unwrap();

        assert!(matches!(handle.cancel(u(2), CancelReason::Pressure, short()), Err(ChannelError::Frame(FrameError::Timeout))));
        let ControlRequest::Status { header, operation_id } = read(&mut peer) else { panic!("首帧须为原 status") };
        assert_eq!(operation_id, id("op"));
        send(&mut peer, ControlReply::Result { header, result: ControlResult::Snapshot { snapshot: snap(1, false) } });

        assert!(matches!(handle.cancel(u(2), CancelReason::Pressure, short()), Err(ChannelError::Frame(FrameError::Timeout))));
        let ControlRequest::Cancel { header, operation_id, token_generation, cancel_seq, reason } = read(&mut peer)
            else { panic!("status 恢复后须发送 cancel") };
        assert_eq!((operation_id, token_generation, cancel_seq, reason), (id("op"), u(7), u(2), CancelReason::Pressure));
        assert!(!state.can_settle());
        let other = Arc::new(CandidateInterruptState::default());
        let mut other_handle = CandidateInterrupt::new(Arc::downgrade(&channel), Arc::downgrade(&other), binding("other"), recovery);
        assert!(matches!(other_handle.cancel(u(2), CancelReason::Pressure, recovery), Err(ChannelError::InFlight)));
        assert!(matches!(handle.cancel(u(2), CancelReason::Cancel, recovery), Err(ChannelError::InvalidExpectation)));

        let ack = ControlResult::CancelAck { status: CancelAckStatus::Received, snapshot: snap(2, true) };
        send(&mut peer, ControlReply::Result { header, result: ack.clone() });
        state.revoke();
        drop(state);
        assert_eq!(handle.cancel(u(2), CancelReason::Pressure, recovery).unwrap(), ack);
        assert_eq!(handle.cancel(u(2), CancelReason::Pressure, recovery).unwrap(), ack);
        assert_eq!(channel.lock().unwrap().next_header().unwrap().rpc_seq(), u(3));
    }

    #[test]
    fn received_cannot_ack_a_new_token_generation() {
        let snap = |generation, highest, stop| ControlSnapshot::new(Id::new("op".into()).unwrap(), ControlPhase::Active,
            U::new(generation).unwrap(), U::new(highest).unwrap(), stop).unwrap();
        let seq = U::new(2).unwrap();
        let before = snap(4, 1, false);
        assert!(valid_cancel_ack(&before, seq, &CancelAckStatus::Received, &snap(4, 2, true)));
        assert!(!valid_cancel_ack(&before, seq, &CancelAckStatus::Received, &snap(5, 2, true)));
        assert!(valid_cancel_ack(&before, seq, &CancelAckStatus::Stale, &snap(5, 1, false)));
    }
}
