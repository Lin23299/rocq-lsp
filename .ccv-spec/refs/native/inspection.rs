//! NN05/NN06 与 NB03：只关联原操作和封存 view；AST、持久捕获和授权仍归各自 owner。

use super::{checkpoint::absolute_deadline, ChannelError, FrameError, NativeDriver, Nw02Reservation};
use super::interrupt::{CandidateInterrupt, CandidateInterruptState};
use ccv_protocol::actor::{InspectSelector, Items};
use ccv_protocol::nativeface::{
    Admission, AnyTerminal, ArgsFinishOperation, ArgsInspect, ArgsOperationStatus, ArgsQuery,
    ArgsRegisterBudget, ArgsSettleInterrupt, AuxTerminal, AuxValue, InitialNativeMethod, InitialPhase,
    KnownOrNa, NativeBudget, NativeOpState, NativeProtocolError, NativePurpose, NativeReply, NativeRequest, NativeResult,
    NativeStage, NativeViewRef, OpBinding, OpStatus, ReceiptKey, ViewDescriptor, ViewFormat,
};
use ccv_protocol::nativeface_b::{
    ArgsViewAck, ArgsViewPull, ArgsViewRelease, NativeFactsDocument, NativeFactsPayload, NativePartDescriptor, NativeViewReleaseResult, NativeViewRetired,
    ReleaseStatus, ViewAckResult, ViewPullResult, ViewReleaseResultValue, ViewReplyAck,
    ViewReplyPull, ViewReplyRelease, ViewRequest,
};
use ccv_protocol::records::CaptureStatus;
use ccv_protocol::reply::{ExecutionExtent, InspectKind};
use ccv_protocol::{decode, encode, Digest32, EpochHeader, Fact, Id, Limits, WireType, U};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::{Arc, Weak};
use std::time::Instant;

#[derive(Default)]
pub(super) struct InspectionOperationSlot {
    active: Option<Operation>,
    closed_through: Option<U>,
    last_disposition: Option<InspectionDisposition>,
    last_finished: Option<InspectionFinished>,
}

struct InspectionFinished {
    owner: Arc<()>,
    recovery_deadline: U,
    reply: NativeResult,
}

// 只缓存最近已腾槽的原观察；更早身份由 M4 对账。
struct InspectionDisposition {
    owner: Arc<()>,
    key: Option<ReceiptKey>,
    observation: Result<NativeResult, NativeProtocolError>,
}

struct Operation {
    owner: Arc<()>,
    interrupt: Arc<CandidateInterruptState>,
    interrupt_issued: bool,
    request: NativeRequest,
    budget: NativeBudget,
    phase: Phase,
    terminal: Option<AuxTerminal>,
    stream: Option<Stream>,
    roster_children: Option<BTreeMap<Id, (NativePartDescriptor, Stream)>>,
    assumption_children: Option<BTreeMap<Id, Stream>>,
    finished: Option<NativeResult>,
}

enum Phase {
    Registering(NativeRequest),
    RegistrationUnresolved(NativeProtocolError),
    ProtocolUnresolved(NativeProtocolError),
    PastUnavailable(NativeResult),
    Registered,
    Sent,
    ReadingStatus(NativeRequest),
    Settling(NativeRequest),
    Terminal,
    Finishing(NativeRequest),
}

/// 仅在当前 driver 上收到配对 NW02 确认后签发一次。不能克隆，也不代替 M2 派发许可。
pub struct RegisteredInspection {
    owner: Weak<()>,
}

pub enum InspectionRegistration {
    Registered(RegisteredInspection),
    PastUnavailable { operation_seq: U, highest_seen: U },
}

struct Stream {
    offset: U,
    last_ack: Option<ArgsViewAck>,
    pending: Option<PendingChunk>,
    hash: Sha256,
    eof: bool,
    release: Option<ReleaseStatus>,
    unresolved_rpc: Option<NativeProtocolError>,
    observed_capture: Option<CaptureStatus>,
}

impl Stream {
    fn new() -> Result<Self, ChannelError> {
        Ok(Self { offset: U::new(0)?, last_ack: None, pending: None, hash: Sha256::new(),
            eof: false, release: None, unresolved_rpc: None, observed_capture: None })
    }
}

enum ViewEvidence<'a> {
    Parent(&'a ViewDescriptor),
    Child(&'a ViewDescriptor, &'a NativePartDescriptor),
    Assumption(&'a ViewDescriptor, &'a NativeViewRef),
}

impl ViewEvidence<'_> {
    fn view(&self) -> &NativeViewRef {
        match self { Self::Parent(d) => d.view(), Self::Child(_, part) => part.output(), Self::Assumption(_, view) => view }
    }
    fn operation(&self) -> &Id {
        match self { Self::Parent(d) | Self::Child(d, _) | Self::Assumption(d, _) => d.operation() }
    }
    fn bytes<'a>(&'a self, capture: &'a CaptureStatus) -> &'a U {
        match self {
            Self::Parent(d) => d.capture().captured_bytes(), Self::Child(_, part) => part.bytes(),
            Self::Assumption(..) => capture.captured_bytes(),
        }
    }
    fn digest<'a>(&'a self, capture: &'a CaptureStatus) -> Option<&'a Digest32> {
        match self {
            Self::Parent(d) => match d.capture().digest() { Fact::Known(digest) => Some(digest), _ => None },
            Self::Child(_, part) => Some(part.digest()),
            Self::Assumption(..) => match capture.digest() { Fact::Known(digest) => Some(digest), _ => None },
        }
    }
    fn matches_capture(&self, capture: &CaptureStatus, observed: Option<&CaptureStatus>) -> bool {
        match self {
            Self::Parent(d) => capture == d.capture(),
            Self::Child(_, part) => *capture.complete() && capture.captured_bytes() == part.bytes()
                && capture.total_bytes() == &Fact::Known(*part.bytes())
                && capture.digest() == &Fact::Known(*part.digest())
                && capture.missing_ranges().as_slice().is_empty() && capture.reason() == &Fact::NotApplicable,
            Self::Assumption(..) => *capture.complete() && valid_capture(capture, i64::MAX)
                && observed.is_none_or(|old| old == capture),
        }
    }
}

struct PendingChunk {
    pull: ArgsViewPull,
    result: ViewPullResult,
    ack: ArgsViewAck,
    hash: Sha256,
    end: bool,
}

impl InspectionOperationSlot {
    pub(super) fn revoke_interrupt(&self) {
        if let Some(op) = &self.active { op.interrupt.revoke(); }
    }

    fn replay_finished(&self, token: &RegisteredInspection, key: &ReceiptKey, deadline: Instant)
        -> Result<Option<NativeResult>, ChannelError> {
        let (reply, recovery) = if let Some(saved) = self.last_finished.as_ref()
            .filter(|saved| Weak::ptr_eq(&token.owner, &Arc::downgrade(&saved.owner))) {
            (&saved.reply, saved.recovery_deadline)
        } else {
            let op = self.operation(token)?;
            let Some(reply) = &op.finished else { return Ok(None); };
            (reply, *op.budget.recovery_deadline_us())
        };
        if !matches!(reply, NativeResult::Finished { key: actual } if actual == key) {
            return Err(ChannelError::InvalidExpectation);
        }
        deadline_before(deadline, recovery)?;
        Ok(Some(reply.clone()))
    }

    fn record_finished(&mut self, result: &NativeResult, key: &ReceiptKey) -> Result<(), ChannelError> {
        if !matches!(result, NativeResult::Finished { key: actual } if actual == key) {
            return Err(ChannelError::ReplyMismatch);
        }
        let op = self.active_mut()?;
        if op.terminal.as_ref().is_none_or(|terminal| terminal.key() != key) {
            return Err(ChannelError::InvalidExpectation);
        }
        let seq = *op.budget.operation_seq();
        op.finished = Some(result.clone());
        op.phase = Phase::Terminal;
        self.closed_through = Some(seq);
        self.close_finished_if_released();
        Ok(())
    }

    fn close_finished_if_released(&mut self) {
        if self.active.as_ref().is_some_and(|op| op.finished.is_some() && op.views_released()) {
            if let Some(mut op) = self.active.take() {
                if let Some(reply) = op.finished.take() {
                    self.last_finished = Some(InspectionFinished {
                        owner: op.owner, recovery_deadline: *op.budget.recovery_deadline_us(), reply,
                    });
                }
            }
        }
    }

    fn disposition(&self, token: &RegisteredInspection) -> Option<&InspectionDisposition> {
        self.last_disposition.as_ref().filter(|saved| Weak::ptr_eq(&token.owner, &Arc::downgrade(&saved.owner)))
    }

    pub(super) fn owns_binding(&self, binding: &OpBinding) -> bool {
        self.active.as_ref().is_some_and(|op| {
            request_binding(&op.request).is_ok_and(|(original, ..)| original.operation_id() == binding.operation_id()
                || original.operation_seq() == binding.operation_seq())
        })
    }

    fn operation(&self, token: &RegisteredInspection) -> Result<&Operation, ChannelError> {
        self.active.as_ref().filter(|op| Weak::ptr_eq(&token.owner, &Arc::downgrade(&op.owner)))
            .ok_or(ChannelError::InvalidExpectation)
    }

    fn active_mut(&mut self) -> Result<&mut Operation, ChannelError> {
        self.active.as_mut().ok_or(ChannelError::InvalidExpectation)
    }
}

impl InspectionDisposition {
    fn replay(&self) -> Result<NativeResult, ChannelError> {
        self.observation.clone().map_err(ChannelError::Native)
    }
}

impl NativeDriver {
    /// M2 提供已登记的原命令源（ID 和同一份不可变字节）、当前派发许可和 M4 原意图。
    /// 这里只核字节范围，不分类 Coq AST，也不把命令源同父节点源码混为一谈。
    pub fn register_query(
        &mut self, args: ArgsQuery, budget: NativeBudget, command_source: &Id, command: &str,
        deadline: Instant,
    ) -> Result<InspectionRegistration, ChannelError> {
        let range = args.selector().range();
        let start = usize::try_from(range.start().get()).map_err(|_| ChannelError::InvalidExpectation)?;
        let end = usize::try_from(range.end().get()).map_err(|_| ChannelError::InvalidExpectation)?;
        if args.selector().source() != command_source || command.get(start..end).is_none() {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        self.register_inspection(NativeRequest::Query { header, args }, budget, deadline)
    }

    /// M2 提供已绑定原 node/source/environment 的请求及当前派发许可。
    pub fn register_inspect(
        &mut self, args: ArgsInspect, budget: NativeBudget, deadline: Instant,
    ) -> Result<InspectionRegistration, ChannelError> {
        let header = self.next_header()?;
        self.register_inspection(NativeRequest::Inspect { header, args }, budget, deadline)
    }

    fn register_inspection(
        &mut self, request: NativeRequest, budget: NativeBudget, deadline: Instant,
    ) -> Result<InspectionRegistration, ChannelError> {
        self.require_inspection_dispatch(&budget)?;
        if self.inspection.active.is_some()
            || self.inspection.closed_through.is_some_and(|floor| budget.operation_seq() <= &floor)
        {
            return Err(ChannelError::InvalidExpectation);
        }
        let (binding, _, method, _) = request_binding(&request)?;
        // Step P2: 固定 W02 原请求及 NW02 授予，不推断 output_budget 与 budget 为同一 ID。
        if budget.clock_boot() != self.boot.clock_boot()
            || !matches!(budget.purpose(), NativePurpose::Task {})
            || budget.checkpoint_limits() != &KnownOrNa::NotApplicable
            || budget.execution_deadline_us() > budget.recovery_deadline_us()
            || budget.output_bytes().get() == 0
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
        let write = deadline_before(deadline, *budget.execution_deadline_us())?
            .min(absolute_deadline(*budget.output_deadline_us())?);
        let recovery = absolute_deadline(*budget.recovery_deadline_us())?;
        let frame = NativeRequest::RegisterBudget {
            header: request.header().clone(),
            args: ArgsRegisterBudget::new(budget.clone(), budget.grant().clone())?,
        };
        self.nw02.reserve(&budget)?;
        self.inspection.active = Some(Operation {
            owner: Arc::new(()), interrupt: Arc::new(CandidateInterruptState::default()), interrupt_issued: false,
            request, budget, phase: Phase::Registering(frame),
            terminal: None, stream: None, roster_children: None, assumption_children: None, finished: None,
        });
        let op = self.inspection.active_mut()?;
        let Phase::Registering(frame) = &op.phase else { unreachable!() };
        let reply = self.ordinary.request_resumable(frame, write, write, recovery);
        // 只有 transport 明确无原在途且未取得任何回复时，才允许重建登记。
        if reply.is_err() && !self.ordinary.failed() && self.ordinary.pending_header().is_none() {
            self.inspection.active = None;
        }
        self.check_inspection_transport();
        self.inspection_registration_reply(reply?)
    }

    /// 只排空原 NW02 帧；已发 token、未知但无在途帧、或其他阶段均不重新登记。
    pub fn resume_inspection_registration(
        &mut self, deadline: Instant,
    ) -> Result<InspectionRegistration, ChannelError> {
        let op = self.inspection.active.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        let frame = match &op.phase {
            Phase::Registering(frame) => frame,
            Phase::RegistrationUnresolved(error) => return Err(ChannelError::Native(error.clone())),
            _ => return Err(ChannelError::InvalidExpectation),
        };
        self.require_live_inspection_driver()?;
        let deadline = deadline_before(deadline, *op.budget.recovery_deadline_us())?;
        let reply = self.ordinary.drain_original(frame, deadline);
        self.check_inspection_transport();
        let reply = reply?.ok_or(ChannelError::InvalidExpectation)?;
        self.inspection_registration_reply(reply)
    }

    fn inspection_registration_reply(&mut self, reply: ccv_protocol::nativeface::NativeReply)
        -> Result<InspectionRegistration, ChannelError>
    {
        let budget = &self.inspection.active_mut()?.budget;
        if self.nw02.registration_reply(budget, &reply).is_err() {
            return self.bad_inspection_reply();
        }
        if Nw02Reservation::establishment_rejected(&reply) {
            self.inspection.active = None;
        } else if let NativeReply::ProtocolError { error, .. } = &reply {
            self.inspection.active_mut()?.phase = Phase::RegistrationUnresolved(error.clone());
            self.quarantine();
        }
        self.inspection_registration_result(Self::reply_result(reply)?)
    }

    fn inspection_registration_result(
        &mut self, result: NativeResult,
    ) -> Result<InspectionRegistration, ChannelError> {
        let op = self.inspection.active_mut()?;
        match result {
            NativeResult::BudgetRegistered { budget, grant, grant_revision }
                if op.budget.budget() == &budget && op.budget.grant() == &grant
                    && op.budget.grant_revision() == &grant_revision =>
            {
                op.phase = Phase::Registered;
                Ok(InspectionRegistration::Registered(RegisteredInspection {
                    owner: Arc::downgrade(&op.owner),
                }))
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if op.budget.operation_seq() == &operation_seq && highest_seen >= operation_seq =>
            {
                self.inspection.active = None;
                Ok(InspectionRegistration::PastUnavailable { operation_seq, highest_seen })
            }
            _ => self.bad_inspection_reply(),
        }
    }

    /// NN05/NN06：只发送 token 绑定的既有 Args。调用方必须仍持当前 M2 派发许可。
    pub fn inspection_interrupt(&mut self, token: &RegisteredInspection) -> Result<CandidateInterrupt, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        if !matches!(op.phase, Phase::Registered) || op.interrupt_issued { return Err(ChannelError::InvalidExpectation); }
        let handle = CandidateInterrupt::new(Arc::downgrade(&self.control), Arc::downgrade(&op.interrupt),
            request_binding(&op.request)?.0.clone(), absolute_deadline(*op.budget.recovery_deadline_us())?);
        self.inspection.active_mut()?.interrupt_issued = true;
        Ok(handle)
    }

    pub fn execute_inspection(
        &mut self, token: &RegisteredInspection, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if let Some(saved) = self.inspection.disposition(token) { return saved.replay(); }
        let op = self.inspection.operation(token)?;
        if let Phase::ProtocolUnresolved(error) = &op.phase { return Err(ChannelError::Native(error.clone())); }
        if let Phase::PastUnavailable(result) = &op.phase { return Ok(result.clone()); }
        if !matches!(op.phase, Phase::Registered) || op.interrupt.fenced() {
            return Err(ChannelError::InvalidExpectation);
        }
        self.require_inspection_dispatch(&op.budget)?;
        self.nw02.require_registered(&op.budget)?;
        let write = deadline_before(deadline, *op.budget.execution_deadline_us())?
            .min(absolute_deadline(*op.budget.output_deadline_us())?);
        let recovery = absolute_deadline(*op.budget.recovery_deadline_us())?;
        let header = self.next_header()?;
        let op = self.inspection.active_mut()?;
        if op.interrupt.fenced() { return Err(ChannelError::InvalidExpectation); }
        match &mut op.request {
            NativeRequest::Query { header: original, .. } | NativeRequest::Inspect { header: original, .. } =>
                *original = header,
            _ => return Err(ChannelError::InvalidExpectation),
        }
        // Step P5: 一旦可能发送，只允许排空原帧或读取原操作状态。
        op.phase = Phase::Sent;
        let reply = self.ordinary.request_resumable(&op.request, write, write, recovery);
        if reply.is_err() && !self.ordinary.failed() && self.ordinary.pending_header().is_none() {
            op.phase = Phase::Registered;
        }
        self.check_inspection_transport();
        self.inspection_establishment_reply(reply?)
    }

    /// D02：先排空原执行帧，随后只读原操作；不会重新执行查询、检视或打印。
    pub fn inspection_status(
        &mut self, token: &RegisteredInspection, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if let Some(saved) = self.inspection.disposition(token) { return saved.replay(); }
        let op = self.inspection.operation(token)?;
        if let Phase::ProtocolUnresolved(error) = &op.phase { return Err(ChannelError::Native(error.clone())); }
        if let Phase::PastUnavailable(result) = &op.phase { return Ok(result.clone()); }
        self.require_live_inspection_driver()?;
        let recovery = absolute_deadline(*op.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        ensure_before(deadline)?;
        match &op.phase {
            Phase::Sent => {
                if self.ordinary.pending_header() == Some(op.request.header()) {
                    let reply = self.ordinary.drain_original(&op.request, deadline);
                    self.check_inspection_transport();
                    let reply = reply?.ok_or(ChannelError::InvalidExpectation)?;
                    return self.inspection_establishment_reply(reply);
                }
            }
            Phase::ReadingStatus(frame) => {
                let reply = self.ordinary.drain_original(frame, deadline);
                self.check_inspection_transport();
                let reply = reply?.ok_or(ChannelError::InvalidExpectation)?;
                self.inspection.active_mut()?.phase = Phase::Sent;
                return self.inspection_operation_reply(reply, true);
            }
            Phase::Terminal => {
                let terminal = op.terminal.as_ref().ok_or(ChannelError::InvalidExpectation)?;
                return Ok(NativeResult::AuxTerminal { terminal: terminal.clone() });
            }
            _ => return Err(ChannelError::InvalidExpectation),
        }
        let op = self.inspection.operation(token)?;
        let frame = NativeRequest::OperationStatus {
            header: self.next_header()?,
            args: ArgsOperationStatus::new(request_binding(&op.request)?.0.clone())?,
        };
        let op = self.inspection.active_mut()?;
        op.phase = Phase::ReadingStatus(frame);
        let Phase::ReadingStatus(frame) = &op.phase else { unreachable!() };
        let reply = self.ordinary.request_resumable(frame, deadline, deadline, recovery);
        if self.ordinary.pending_header() != Some(frame.header()) {
            op.phase = Phase::Sent;
        }
        self.check_inspection_transport();
        self.inspection_operation_reply(reply?, true)
    }

    /// N07：D02 先收完原建立/status 帧；这里只读原 Query/Inspect 的退出事实。
    pub fn settle_inspection_interrupt(&mut self, token: &RegisteredInspection, deadline: Instant) -> Result<NativeResult, ChannelError> {
        if let Some(saved) = self.inspection.disposition(token) { return saved.replay(); }
        let op = self.inspection.operation(token)?;
        match &op.phase {
            Phase::Terminal => return Ok(NativeResult::AuxTerminal { terminal: op.terminal.clone().ok_or(ChannelError::InvalidExpectation)? }),
            Phase::PastUnavailable(result) => return Ok(result.clone()),
            Phase::ProtocolUnresolved(error) => return Err(ChannelError::Native(error.clone())),
            _ => (),
        }
        self.require_live_inspection_driver()?;
        if !op.interrupt.can_settle() { return Err(ChannelError::InvalidExpectation); }
        let recovery = absolute_deadline(*op.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        ensure_before(deadline)?;
        let reply = match &op.phase {
            Phase::Sent => {
                let frame = NativeRequest::SettleInterrupt { header: self.next_header()?,
                    args: ArgsSettleInterrupt::new(request_binding(&op.request)?.0.clone())? };
                let reply = self.ordinary.request_resumable(&frame, deadline, deadline, recovery);
                if self.ordinary.pending_header() == Some(frame.header()) { self.inspection.active_mut()?.phase = Phase::Settling(frame); }
                reply
            }
            Phase::Settling(frame) => self.ordinary.drain_original(frame, deadline)
                .and_then(|reply| reply.ok_or(ChannelError::InFlight)),
            _ => return Err(ChannelError::InvalidExpectation),
        };
        self.check_inspection_transport();
        let reply = reply?;
        self.inspection.active_mut()?.phase = Phase::Sent;
        if let NativeReply::ProtocolError { error, .. } = reply {
            self.inspection.active_mut()?.phase = Phase::ProtocolUnresolved(error.clone());
            self.quarantine();
            return Err(ChannelError::Native(error));
        }
        let result = Self::reply_result(reply)?;
        match &result {
            NativeResult::AuxTerminal { .. } | NativeResult::PastUnavailable { .. } => self.checked_inspection_result(result, false),
            NativeResult::Status { status } if status.state() == &NativeOpState::Retiring && *status.stop_requested() =>
                self.checked_inspection_result(result, true),
            _ => self.bad_inspection_reply(),
        }
    }

    fn inspection_establishment_reply(&mut self, reply: ccv_protocol::nativeface::NativeReply)
        -> Result<NativeResult, ChannelError>
    {
        self.inspection_operation_reply(reply, false)
    }

    fn inspection_operation_reply(&mut self, reply: NativeReply, status_read: bool) -> Result<NativeResult, ChannelError> {
        if let NativeReply::ProtocolError { error, .. } = reply {
            if error.admission() == &Admission::NotAdmitted {
                if !status_read {
                    let op = self.inspection.active.as_ref().ok_or(ChannelError::InvalidExpectation)?;
                    self.nw02.consume(&op.budget);
                    self.detach_inspection(Err(error.clone()))?;
                }
            } else {
                self.inspection.active_mut()?.phase = Phase::ProtocolUnresolved(error.clone());
                self.quarantine();
            }
            return Err(ChannelError::Native(error));
        }
        self.checked_inspection_result(Self::reply_result(reply)?, status_read)
    }

    fn detach_inspection(&mut self, observation: Result<NativeResult, NativeProtocolError>) -> Result<(), ChannelError> {
        let op = self.inspection.active.take().ok_or(ChannelError::InvalidExpectation)?;
        op.interrupt.revoke();
        self.inspection.closed_through = Some(*op.budget.operation_seq());
        self.inspection.last_disposition = Some(InspectionDisposition {
            owner: op.owner, key: op.terminal.as_ref().map(|terminal| terminal.key().clone()), observation,
        });
        Ok(())
    }

    fn record_inspection_past(&mut self, result: &NativeResult) -> Result<(), ChannelError> {
        let op = self.inspection.active.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        self.nw02.consume(&op.budget);
        if !op.views_released() {
            op.interrupt.revoke();
            self.inspection.active_mut()?.phase = Phase::PastUnavailable(result.clone());
        } else {
            self.detach_inspection(Ok(result.clone()))?;
        }
        Ok(())
    }

    fn checked_inspection_result(
        &mut self, result: NativeResult, status_read: bool,
    ) -> Result<NativeResult, ChannelError> {
        let op = self.inspection.active.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        let (binding, _, _, _) = request_binding(&op.request)?;
        let terminal = match &result {
            NativeResult::AuxTerminal { terminal } if !status_read => Some((terminal, true)),
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if operation_seq == binding.operation_seq() && highest_seen >= operation_seq => {
                self.record_inspection_past(&result)?;
                return Ok(result);
            }
            NativeResult::Status { status } if inspection_status_allowed(status_read, binding, status) =>
            {
                match (status.state(), status.terminal()) {
                    (NativeOpState::Terminal, Fact::Known(AnyTerminal::Aux(aux))) if status_read => Some((aux, true)),
                    (NativeOpState::Retiring, Fact::Known(AnyTerminal::Aux(aux))) => Some((aux, false)),
                    (NativeOpState::Retiring, Fact::Unknown | Fact::NotApplicable) => None,
                    (NativeOpState::Ready | NativeOpState::Executing, Fact::Unknown | Fact::NotApplicable)
                        if status_read => None,
                    _ => return self.bad_inspection_reply(),
                }
            }
            _ => return self.bad_inspection_reply(),
        };
        if let Some((terminal, settled)) = terminal {
            if !valid_inspection_terminal(op, terminal, self.boot.view_byte_quota().get())
                || op.terminal.as_ref().is_some_and(|prior| prior != terminal)
            {
                return self.bad_inspection_reply();
            }
            self.nw02.consume(&op.budget);
            let op = self.inspection.active_mut()?;
            op.terminal = Some(terminal.clone());
            if settled {
                op.interrupt.revoke();
                op.phase = Phase::Terminal;
                if matches!(terminal.value(), AuxValue::View { .. }) {
                    op.stream = Some(Stream::new()?);
                }
                if terminal.execution_extent() == &ExecutionExtent::UnknownTail {
                    self.quarantine();
                }
            }
        } else {
            self.nw02.consume(&op.budget);
        }
        Ok(result)
    }

    /// N08：只用已核原终态的 receipt key；调用方须先确认 M4 终态持久化。
    /// finish 只确认 operation 回执；view 未 released 时仍保留其本地 lease。
    pub fn finish_inspection(
        &mut self, token: &RegisteredInspection, key: &ReceiptKey, deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if let Some(saved) = self.inspection.disposition(token) {
            return if saved.key.as_ref() == Some(key) { saved.replay() }
                else { Err(ChannelError::InvalidExpectation) };
        }
        if let Some(result) = self.inspection.replay_finished(token, key, deadline)? { return Ok(result); }
        let op = self.inspection.operation(token)?;
        if !op.terminal.as_ref().is_some_and(|terminal| terminal.key() == key
            && terminal.execution_extent() != &ExecutionExtent::UnknownTail)
        {
            return Err(ChannelError::InvalidExpectation);
        }
        if let Phase::ProtocolUnresolved(error) = &op.phase { return Err(ChannelError::Native(error.clone())); }
        if let Phase::PastUnavailable(result) = &op.phase { return Ok(result.clone()); }
        self.require_live_inspection_driver()?;
        self.require_no_unapplied_ack()?;
        let recovery = absolute_deadline(*op.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        ensure_before(deadline)?;
        let seq = *op.budget.operation_seq();
        let reply = match &op.phase {
            Phase::Terminal => {
                let frame = NativeRequest::FinishOperation {
                    header: self.next_header()?,
                    args: ArgsFinishOperation::new(request_binding(&op.request)?.0.clone(), key.clone())?,
                };
                let op = self.inspection.active_mut()?;
                op.phase = Phase::Finishing(frame);
                let Phase::Finishing(frame) = &op.phase else { unreachable!() };
                let reply = self.ordinary.request_resumable(frame, deadline, deadline, recovery);
                if reply.is_err() && !self.ordinary.failed() && self.ordinary.pending_header().is_none() {
                    op.phase = Phase::Terminal;
                }
                reply
            }
            Phase::Finishing(frame) => self.ordinary.drain_original(frame, deadline)
                .and_then(|reply| reply.ok_or(ChannelError::InvalidExpectation)),
            _ => return Err(ChannelError::InvalidExpectation),
        };
        self.check_inspection_transport();
        let reply = reply?;
        if let NativeReply::ProtocolError { error, .. } = reply {
            let phase = inspection_finish_error_phase(&error);
            let unresolved = matches!(&phase, Phase::ProtocolUnresolved(_));
            self.inspection.active_mut()?.phase = phase;
            if unresolved {
                self.quarantine();
            }
            return Err(ChannelError::Native(error));
        }
        let result = Self::reply_result(reply)?;
        match &result {
            NativeResult::Finished { key: actual } if actual == key => {
                self.inspection.record_finished(&result, key)?;
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if *operation_seq == seq && highest_seen >= operation_seq => self.record_inspection_past(&result)?,
            _ => return self.bad_inspection_reply(),
        }
        Ok(result)
    }

    /// 登记 M6 已持久接收并 ACK 的原始 roster 文档。返回可按原 token 读取的子描述。
    pub fn register_roster_children(&mut self, token: &RegisteredInspection, parent_bytes: &[u8],
        deadline: Instant) -> Result<Vec<NativePartDescriptor>, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        let end = deadline_before(deadline, *op.budget.recovery_deadline_us())?;
        let quota = op.budget.output_bytes().get().min(self.boot.view_byte_quota().get());
        let children = op.checked_roster_children(parent_bytes, quota)?;
        ensure_before(end)?;
        self.inspection.active_mut()?.install_roster_children(children)
    }

    /// M6 传入 PS02 封存的完整父文档；只登记文档引用的原租约子视图。
    pub fn register_assumption_children(&mut self, token: &RegisteredInspection, parent_bytes: &[u8],
        deadline: Instant) -> Result<Vec<NativeViewRef>, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        let end = deadline_before(deadline, *op.budget.recovery_deadline_us())?;
        let quota = op.budget.output_bytes().get().min(self.boot.view_byte_quota().get());
        let parent = op.checked_parent_bytes(parent_bytes, quota, InspectKind::Assumptions)?;
        let children = checked_assumption_document(parent, parent_bytes, quota)?;
        ensure_before(end)?;
        self.inspection.active_mut()?.install_assumption_children(children)
    }

    /// NB03：每次只接收一个有界块；先验证身份、偏移、credit 和 EOF，再交 M6。
    pub fn pull_inspection_view(
        &mut self, token: &RegisteredInspection, args: ArgsViewPull, deadline: Instant,
    ) -> Result<ViewPullResult, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        let (descriptor, stream) = op.view(args.view())?;
        let last = stream.last_ack.as_ref().map_or(0, |ack| ack.seq().get());
        let seq = args.expected_seq().get();
        let pull_allowed = match stream.release {
            None => true,
            Some(ReleaseStatus::Closing) => stream.pending.as_ref().is_some_and(|chunk| chunk.pull == args),
            Some(ReleaseStatus::Released) => false,
        };
        if args.view() != descriptor.view() || args.operation() != descriptor.operation()
            || !pull_allowed || seq == 0
            || (seq > last && (Some(seq) != last.checked_add(1) || args.offset() != &stream.offset || stream.eof))
            || (seq <= last && args.offset() > &stream.offset)
        {
            return Err(ChannelError::InvalidExpectation);
        }
        if seq > last && stream.pending.as_ref().is_some_and(|chunk| chunk.pull != args) {
            return Err(ChannelError::InvalidExpectation);
        }
        let (header, write, recovery) = self.inspection_view_window(op, stream, deadline, *op.budget.output_deadline_us())?;
        let frame = ViewRequest::Pull { header: header.clone(), args: args.clone() };
        let reply = self.exchange_inspection_view(&frame, &header, pull_reply_header, deadline, write, recovery)?;
        self.checked_inspection_pull(token, args, reply)
    }

    /// 撤权后只收已完整发出的原 pull；读取事实不代表持久提交或获得新输出权限。
    pub fn drain_pending_inspection_pull(
        &mut self, token: &RegisteredInspection, args: ArgsViewPull, deadline: Instant,
    ) -> Result<Option<ViewPullResult>, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        let (descriptor, _) = op.view(args.view())?;
        if args.operation() != descriptor.operation() { return Err(ChannelError::InvalidExpectation); }
        if self.view.failed() {
            self.quarantine();
            return Err(ChannelError::Failed);
        }
        let Some(header) = self.view.pending_header().cloned() else { return Ok(None) };
        let deadline = deadline_before(deadline, *op.budget.recovery_deadline_us())?;
        let frame = ViewRequest::Pull { header: header.clone(), args: args.clone() };
        // 半写 view 已标记失败；此入口没有发送分支。通道在读前核原帧字节及回复类型。
        let reply = self.view.drain_view(&frame, &header, pull_reply_header, deadline);
        if self.view.failed() { self.quarantine(); }
        reply?.map(|reply| self.checked_inspection_pull(token, args, reply)).transpose()
    }

    fn checked_inspection_pull(
        &mut self, token: &RegisteredInspection, args: ArgsViewPull, reply: ViewReplyPull,
    ) -> Result<ViewPullResult, ChannelError> {
        let result = match reply {
            ViewReplyPull::Result { result, .. } => result,
            ViewReplyPull::ProtocolError { error, .. } => return self.inspection_view_error(args.view(), error),
        };
        let op = self.inspection.operation(token)?;
        let (descriptor, stream) = op.view(args.view())?;
        let last = stream.last_ack.as_ref().map_or(0, |ack| ack.seq().get());
        let seq = args.expected_seq().get();
        match &result {
            ViewPullResult::Retired { value } if valid_retired(value, &descriptor, stream, args.expected_seq()) => (),
            ViewPullResult::Chunk { value } if seq > last => {
                if let Some(prior) = &stream.pending {
                    return if prior.result == result { Ok(result) } else { self.bad_inspection_reply() };
                }
                let data = value.text().as_str().as_bytes();
                let end = *value.range().end();
                let capture = value.capture();
                let captured = descriptor.bytes(capture);
                if value.view() != descriptor.view() || value.operation() != descriptor.operation()
                    || value.seq() != args.expected_seq() || value.range().start() != &stream.offset
                    || end.get().checked_sub(stream.offset.get()) != Some(data.len() as i64)
                    || data.len() as i64 > args.credit_bytes().get()
                    || &end > captured || *value.end() != (&end == captured)
                    || (!*value.end() && data.is_empty()) || !descriptor.matches_capture(capture, stream.observed_capture.as_ref())
                {
                    return self.bad_inspection_reply();
                }
                let mut hash = stream.hash.clone();
                hash.update(data);
                if *value.end() && descriptor.digest(capture).is_some_and(|digest|
                    &Digest32::from_bytes(hash.clone().finalize().into()) != digest)
                {
                    return self.bad_inspection_reply();
                }
                let ack = ArgsViewAck::new(value.view().clone(), value.operation().clone(),
                    *value.seq(), end, Digest32::sha256(data))?;
                let observed = if matches!(descriptor, ViewEvidence::Assumption(..)) && stream.observed_capture.is_none() {
                    let quota = op.budget.output_bytes().get().min(self.boot.view_byte_quota().get());
                    if !op.assumption_capture_fits(capture, quota) { return self.bad_inspection_reply(); }
                    Some(capture.clone())
                } else { None };
                let chunk = PendingChunk { pull: args, result: result.clone(), ack, hash, end: *value.end() };
                let view = chunk.pull.view().clone();
                let stream = self.inspection.active_mut()?.view_stream_mut(&view)?;
                if let Some(capture) = observed { stream.observed_capture = Some(capture); }
                stream.pending = Some(chunk);
            }
            _ => return self.bad_inspection_reply(),
        }
        Ok(result)
    }

    /// BO07/PS02：受信 M6 必须通过真实持久接收者核对这一个 ACK 元组。
    /// false/错误/超期均不发送；wire Args 本身不代表持久事实。
    /// 完整写出的原帧续读沿用首次写前的确认，不再次提交或发送；调用方仍须核原 owner 权限。
    pub fn ack_durable_inspection_view(
        &mut self, token: &RegisteredInspection, args: ArgsViewAck, deadline: Instant,
        confirm_durable: impl FnOnce(&ArgsViewAck, Instant) -> Result<bool, ChannelError>,
    ) -> Result<ViewAckResult, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        let (descriptor, stream) = op.view(args.view())?;
        let pending = stream.pending.as_ref().is_some_and(|chunk| chunk.ack == args);
        let recent = stream.last_ack.as_ref() == Some(&args);
        let older = stream.last_ack.as_ref().is_some_and(|ack| args.seq() < ack.seq()
            && args.end_offset() <= ack.end_offset());
        if args.view() != descriptor.view() || args.operation() != descriptor.operation()
            || args.seq().get() == 0 || stream.release == Some(ReleaseStatus::Released)
            || !(pending || recent || older)
        {
            return Err(ChannelError::InvalidExpectation);
        }
        let write_limit = inspection_ack_write_limit(pending, *op.budget.output_deadline_us(), *op.budget.recovery_deadline_us());
        let (header, write, recovery) = self.inspection_view_window(op, stream, deadline, write_limit)?;
        if self.view.pending_header().is_none() && !confirm_durable(&args, write)? {
            return Err(ChannelError::InvalidExpectation);
        }
        let frame = ViewRequest::Ack { header: header.clone(), args: args.clone() };
        let reply: ViewReplyAck = self.exchange_inspection_view(&frame, &header, |reply| match reply {
            ViewReplyAck::Result { header, .. } | ViewReplyAck::ProtocolError { header, .. } => header,
        }, deadline, write, recovery)?;
        let result = match reply {
            ViewReplyAck::Result { result, .. } => result,
            ViewReplyAck::ProtocolError { error, .. } => return self.inspection_view_error(args.view(), error),
        };
        let (descriptor, stream) = self.inspection.operation(token)?.view(args.view())?;
        match &result {
            ViewAckResult::Retired { value } if older && valid_retired(value, &descriptor, stream, args.seq()) => (),
            ViewAckResult::Acked { value } if (pending || recent) && value.view() == descriptor.view()
                && value.operation() == descriptor.operation() && value.seq() == args.seq()
                && value.end_offset() == args.end_offset() =>
            {
                if pending {
                    let stream = self.inspection.active_mut()?.view_stream_mut(args.view())?;
                    let chunk = stream.pending.take().ok_or(ChannelError::InvalidExpectation)?;
                    stream.offset = *args.end_offset();
                    stream.last_ack = Some(args);
                    stream.hash = chunk.hash;
                    stream.eof = chunk.end;
                }
            }
            _ => return self.bad_inspection_reply(),
        }
        Ok(result)
    }

    /// NB03：只接受实际 released；closing 封新 pull，保留原 pending ACK 和 view 所有权。
    pub fn release_inspection_view(
        &mut self, token: &RegisteredInspection, args: ArgsViewRelease, deadline: Instant,
    ) -> Result<NativeViewReleaseResult, ChannelError> {
        self.require_live_inspection_driver()?;
        let op = self.inspection.operation(token)?;
        let (descriptor, stream) = op.view(args.view())?;
        if op.child_registration_pending() && matches!(descriptor, ViewEvidence::Parent(_)) {
            return Err(ChannelError::InvalidExpectation);
        }
        let last = stream.last_ack.as_ref().map_or(Fact::NotApplicable, |ack| Fact::Known(*ack.seq()));
        if args.view() != descriptor.view() || args.operation() != descriptor.operation() || args.last_acked() != &last {
            return Err(ChannelError::InvalidExpectation);
        }
        let (header, write, recovery) = self.inspection_view_window(op, stream, deadline, *op.budget.recovery_deadline_us())?;
        let frame = ViewRequest::Release { header: header.clone(), args: args.clone() };
        let reply: ViewReplyRelease = self.exchange_inspection_view(&frame, &header, |reply| match reply {
            ViewReplyRelease::Result { header, .. } | ViewReplyRelease::ProtocolError { header, .. } => header,
        }, deadline, write, recovery)?;
        let value = match reply {
            ViewReplyRelease::Result { result: ViewReleaseResultValue::Released { value }, .. } => value,
            ViewReplyRelease::ProtocolError { error, .. } => return self.inspection_view_error(args.view(), error),
        };
        let (descriptor, stream) = self.inspection.operation(token)?.view(args.view())?;
        if value.view() != descriptor.view() || value.operation() != descriptor.operation()
            || (value.status() == &ReleaseStatus::Released && stream.pending.is_some())
            || (stream.release == Some(ReleaseStatus::Released) && value.status() != &ReleaseStatus::Released)
        {
            return self.bad_inspection_reply();
        }
        let op = self.inspection.active_mut()?;
        op.view_stream_mut(args.view())?.release = Some(*value.status());
        if value.status() == &ReleaseStatus::Released && op.views_released() {
            if let Phase::PastUnavailable(result) = &op.phase {
                let result = result.clone();
                self.detach_inspection(Ok(result))?;
            } else {
                self.inspection.close_finished_if_released();
            }
        }
        Ok(value)
    }

    fn inspection_view_window(&self, op: &Operation, stream: &Stream, deadline: Instant, write_limit: U)
        -> Result<(EpochHeader, Instant, Instant), ChannelError> {
        if let Some(error) = &stream.unresolved_rpc { return Err(ChannelError::Native(error.clone())); }
        let recovery = absolute_deadline(*op.budget.recovery_deadline_us())?;
        if let Some(header) = self.view.pending_header() {
            return Ok((header.clone(), deadline.min(recovery), recovery));
        }
        let write = deadline_before(deadline.min(recovery), write_limit)?;
        Ok((self.view.next_header()?, write, recovery))
    }

    pub(super) fn exchange_inspection_view<R: WireType + 'static>(
        &mut self, frame: &ViewRequest, header: &EpochHeader, reply_header: fn(&R) -> &EpochHeader,
        deadline: Instant, write: Instant, recovery: Instant,
    ) -> Result<R, ChannelError> {
        let deadline = deadline.min(recovery);
        let reply = if self.view.pending_header().is_some() {
            // Channel 在读任何字节前核完整原帧和回复类型。
            if self.view.failed() { Err(ChannelError::Failed) }
            else {
                ensure_before(deadline)?;
                self.view.drain_view(frame, header, reply_header, deadline)
                    .and_then(|result| result.ok_or(ChannelError::InFlight))
            }
        } else {
            self.view.view_resumable(frame, header, reply_header, deadline, write, recovery)
        };
        // 可排空的短超时仅占 view 流；坏帧/硬期限使传输不可恢复，沿既有实例隔离。
        if self.view.failed() {
            self.quarantine();
        }
        reply
    }

    fn inspection_view_error<T>(&mut self, view: &NativeViewRef, error: NativeProtocolError) -> Result<T, ChannelError> {
        if error.admission() != &Admission::NotAdmitted {
            self.inspection.active_mut()?.view_stream_mut(view)?.unresolved_rpc = Some(error.clone());
        }
        Err(ChannelError::Native(error))
    }

    fn require_live_inspection_driver(&self) -> Result<(), ChannelError> {
        if self.is_quarantined() { Err(ChannelError::Failed) } else { Ok(()) }
    }

    fn require_inspection_dispatch(&self, budget: &NativeBudget) -> Result<(), ChannelError> {
        self.require_live_inspection_driver()?;
        self.ordinary.environment.require_new_work(budget.environment())?;
        self.require_no_unapplied_ack()?;
        if !self.domain.verify_applied_limit().is_ok_and(|actual| {
            &actual.grant == budget.grant()
                && actual.revision.get().checked_add(1) == Some(budget.grant_revision().get())
        }) {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(())
    }

    fn check_inspection_transport(&mut self) {
        if self.ordinary.failed() {
            self.quarantine();
        }
    }

    fn bad_inspection_reply<T>(&mut self) -> Result<T, ChannelError> {
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }
}

impl Operation {
    fn checked_roster_children(&self, bytes: &[u8], quota: i64) -> Result<BTreeMap<Id, NativePartDescriptor>, ChannelError> {
        checked_roster_document(self.checked_parent_bytes(bytes, quota, InspectKind::GoalRoster)?, bytes, quota)
    }

    fn checked_parent_bytes(&self, bytes: &[u8], quota: i64, kind: InspectKind) -> Result<&ViewDescriptor, ChannelError> {
        let parent = self.parent_descriptor().ok_or(ChannelError::InvalidExpectation)?;
        let (_, stream) = self.view(parent.view())?;
        let capture = parent.capture();
        if parent.format() != &ViewFormat::TypedFacts || parent.facts_kind() != &Fact::Known(kind)
            || !*capture.complete() || !stream.eof || stream.pending.is_some() || !valid_capture(capture, quota)
            || stream.offset != *capture.captured_bytes() || !stream.last_ack.as_ref().is_some_and(|ack|
                ack.view() == parent.view() && ack.operation() == parent.operation() && ack.end_offset() == &stream.offset)
            || usize::try_from(stream.offset.get()).ok() != Some(bytes.len())
        {
            return Err(ChannelError::InvalidExpectation);
        }
        let digest = Digest32::sha256(bytes);
        if capture.digest() != &Fact::Known(digest) || Digest32::from_bytes(stream.hash.clone().finalize().into()) != digest {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(parent)
    }

    fn install_roster_children(&mut self, parts: BTreeMap<Id, NativePartDescriptor>) -> Result<Vec<NativePartDescriptor>, ChannelError> {
        if let Some(old) = &self.roster_children {
            if old.len() != parts.len() || parts.iter().any(|(id, part)| old.get(id).is_none_or(|(p, _)| p != part)) {
                return Err(ChannelError::InvalidExpectation);
            }
        } else {
            self.roster_children = Some(parts.iter().map(|(id, part)| Ok((id.clone(), (part.clone(), Stream::new()?))))
                .collect::<Result<_, ChannelError>>()?);
        }
        Ok(parts.into_values().collect())
    }

    fn install_assumption_children(&mut self, refs: std::collections::BTreeSet<Id>) -> Result<Vec<NativeViewRef>, ChannelError> {
        if let Some(old) = &self.assumption_children {
            if !old.keys().eq(refs.iter()) { return Err(ChannelError::InvalidExpectation); }
        } else {
            self.assumption_children = Some(refs.iter().map(|id| Ok((id.clone(), Stream::new()?)))
                .collect::<Result<_, ChannelError>>()?);
        }
        Ok(refs.into_iter().map(NativeViewRef::new).collect())
    }

    fn assumption_capture_fits(&self, capture: &CaptureStatus, quota: i64) -> bool {
        let Some(parent) = self.parent_descriptor() else { return false; };
        let Some(children) = &self.assumption_children else { return false; };
        let initial = parent.capture().captured_bytes().get().checked_add(capture.captured_bytes().get());
        children.values().filter_map(|s| s.observed_capture.as_ref()).fold(initial, |total, observed|
            total.and_then(|total| total.checked_add(observed.captured_bytes().get())))
            .is_some_and(|total| total <= quota)
    }

    fn parent_descriptor(&self) -> Option<&ViewDescriptor> {
        match self.terminal.as_ref()?.value() {
            AuxValue::View { descriptor } => Some(descriptor),
            _ => None,
        }
    }

    fn child_registration_pending(&self) -> bool {
        self.parent_descriptor().is_some_and(|d| match d.facts_kind() {
            Fact::Known(InspectKind::GoalRoster) => self.roster_children.is_none(),
            Fact::Known(InspectKind::Assumptions) => self.assumption_children.is_none(),
            _ => false,
        })
    }

    fn views_released(&self) -> bool {
        if self.parent_descriptor().is_some() && self.stream.is_none() { return false; }
        !self.child_registration_pending()
            && self.stream.as_ref().is_none_or(|s| s.release == Some(ReleaseStatus::Released))
            && self.roster_children.as_ref().is_none_or(|children|
                children.values().all(|(_, s)| s.release == Some(ReleaseStatus::Released)))
            && self.assumption_children.as_ref().is_none_or(|children|
                children.values().all(|s| s.release == Some(ReleaseStatus::Released)))
    }

    fn view<'a>(&'a self, view: &'a NativeViewRef) -> Result<(ViewEvidence<'a>, &'a Stream), ChannelError> {
        if matches!(self.phase, Phase::Terminal | Phase::Finishing(_) | Phase::PastUnavailable(_)) {
            if let (Some(descriptor), Some(stream)) = (self.parent_descriptor(), &self.stream) {
                if view == descriptor.view() { return Ok((ViewEvidence::Parent(descriptor), stream)); }
                if let Some((part, stream)) = self.roster_children.as_ref().and_then(|children| children.get(view.id())) {
                    return Ok((ViewEvidence::Child(descriptor, part), stream));
                }
                if let Some(stream) = self.assumption_children.as_ref().and_then(|children| children.get(view.id())) {
                    return Ok((ViewEvidence::Assumption(descriptor, view), stream));
                }
            }
        }
        Err(ChannelError::InvalidExpectation)
    }

    fn view_stream_mut(&mut self, view: &NativeViewRef) -> Result<&mut Stream, ChannelError> {
        if self.parent_descriptor().is_some_and(|d| d.view() == view) { return self.stream_mut(); }
        if let Some((_, stream)) = self.roster_children.as_mut().and_then(|children| children.get_mut(view.id())) {
            return Ok(stream);
        }
        self.assumption_children.as_mut().and_then(|children| children.get_mut(view.id()))
            .ok_or(ChannelError::InvalidExpectation)
    }

    fn stream_mut(&mut self) -> Result<&mut Stream, ChannelError> {
        self.stream.as_mut().ok_or(ChannelError::InvalidExpectation)
    }
}

fn checked_facts_document(parent: &ViewDescriptor, bytes: &[u8], quota: i64)
    -> Result<NativeFactsDocument, ChannelError> {
    // 与现有 M4 typed document 同一编解码限制；实际解析长度还受原输出额度限制。
    let limits = Limits::new(64 * 1024 * 1024, 64)?;
    if i64::try_from(bytes.len()).ok() != Some(parent.capture().captured_bytes().get())
        || parent.capture().captured_bytes().get() > quota { return Err(ChannelError::InvalidExpectation); }
    let doc = decode::<NativeFactsDocument>(bytes, limits)?.into_inner();
    let payload = doc.facts();
    let payload_bytes = encode(payload, limits)?;
    let size = U::new(payload_bytes.len() as i64)?;
    let inner = CaptureStatus::new(true, size, Fact::Known(size), Fact::Known(Digest32::sha256(&payload_bytes)),
        Items::new(vec![])?, Fact::NotApplicable)?;
    let expected = NativeFactsDocument::new(parent.node().clone(), parent.source().clone(),
        parent.environment().clone(), inner, payload.clone());
    if encode(&expected, limits)? != bytes { return Err(ChannelError::InvalidExpectation); }
    Ok(doc)
}

fn checked_assumption_document(parent: &ViewDescriptor, bytes: &[u8], quota: i64)
    -> Result<std::collections::BTreeSet<Id>, ChannelError> {
    let doc = checked_facts_document(parent, bytes, quota)?;
    let NativeFactsPayload::Assumptions(facts) = doc.facts() else { return Err(ChannelError::InvalidExpectation); };
    let mut refs = std::collections::BTreeSet::new();
    for root in facts.roots().as_slice() {
        for view in std::iter::once(root.raw()).chain(root.assumptions().as_slice().iter().map(|item| item.printed_type())) {
            if view == parent.view() { return Err(ChannelError::InvalidExpectation); }
            refs.insert(view.id().clone());
        }
    }
    Ok(refs)
}

fn checked_roster_document(parent: &ViewDescriptor, bytes: &[u8], quota: i64)
    -> Result<BTreeMap<Id, NativePartDescriptor>, ChannelError> {
    let doc = checked_facts_document(parent, bytes, quota)?;
    let NativeFactsPayload::GoalRoster(roster) = doc.facts() else { return Err(ChannelError::InvalidExpectation); };
    let mut total = parent.capture().captured_bytes().get();
    let mut parts = BTreeMap::new();
    let mut insert = |part: &NativePartDescriptor| -> Result<(), ChannelError> {
        if part.output() == parent.view() { return Err(ChannelError::InvalidExpectation); }
        match parts.entry(part.output().id().clone()) {
            std::collections::btree_map::Entry::Occupied(old) if old.get() == part => (),
            std::collections::btree_map::Entry::Occupied(_) => return Err(ChannelError::InvalidExpectation),
            std::collections::btree_map::Entry::Vacant(entry) => {
                total = total.checked_add(part.bytes().get()).filter(|total| *total <= quota)
                    .ok_or(ChannelError::InvalidExpectation)?;
                entry.insert(part.clone());
            }
        }
        Ok(())
    };
    // roster.complete 是分页语义；只要求整份文档和 payload 完整捕获。
    let mut groups = std::collections::BTreeSet::new();
    for group in roster.groups().as_slice() {
        if !groups.insert((group.group().as_str(), group.depth().get()))
            || i64::try_from(group.entries().as_slice().len()).ok().is_none_or(|n| n > group.total().get()) {
            return Err(ChannelError::InvalidExpectation);
        }
        let mut goals = std::collections::BTreeSet::new();
        for entry in group.entries().as_slice() {
            let selector = entry.selector();
            if selector.group() != group.group() || selector.depth() != group.depth()
                || selector.index() > group.total() || !goals.insert(selector.index().get()) {
                return Err(ChannelError::InvalidExpectation);
            }
            insert(entry.conclusion())?;
            for hyp in entry.hypotheses().as_slice() {
                insert(hyp.r#type())?;
                if let Fact::Known(body) = hyp.body() { insert(body)?; }
            }
        }
    }
    Ok(parts)
}

fn inspection_status_allowed(status_read: bool, binding: &OpBinding, status: &OpStatus) -> bool {
    status_read && status.binding() == binding && status.acked_through().get() == 0
        && status.pending() == &Fact::NotApplicable && status.last_ack() == &Fact::NotApplicable
        && status.retired_through() < binding.operation_seq()
        && status.highest_seen() >= binding.operation_seq()
}

fn inspection_ack_write_limit(pending: bool, output: U, recovery: U) -> U {
    // 只有精确匹配 pending 块的持久 ACK 可借原恢复窗口清算。
    if pending { recovery } else { output }
}

fn inspection_finish_error_phase(error: &NativeProtocolError) -> Phase {
    if error.admission() == &Admission::NotAdmitted {
        // 只拒绝本次 N08，仍可按原终态 key 和原期限重试。
        Phase::Terminal
    } else {
        Phase::ProtocolUnresolved(error.clone())
    }
}

fn request_binding(request: &NativeRequest) -> Result<(&OpBinding, &Id, InitialNativeMethod, Fact<InspectKind>), ChannelError> {
    match request {
        NativeRequest::Query { args, .. } => Ok((args.binding(), args.node(), InitialNativeMethod::Query, Fact::NotApplicable)),
        NativeRequest::Inspect { args, .. } => {
            let kind = match args.selector() {
                InspectSelector::Assumptions { .. } => InspectKind::Assumptions,
                InspectSelector::Toc { .. } => InspectKind::Toc,
                InspectSelector::Notations { .. } => InspectKind::Notations,
                InspectSelector::Environment { .. } => InspectKind::Environment,
                InspectSelector::GoalRoster { .. } => InspectKind::GoalRoster,
                InspectSelector::GoalPart { .. } => InspectKind::GoalPart,
            };
            Ok((args.binding(), args.node(), InitialNativeMethod::Inspect, Fact::Known(kind)))
        }
        _ => Err(ChannelError::InvalidExpectation),
    }
}

fn valid_inspection_terminal(op: &Operation, terminal: &AuxTerminal, view_quota: i64) -> bool {
    let Ok((binding, node, method, facts_kind)) = request_binding(&op.request) else { return false };
    let key = terminal.key();
    // W03：取完整 AuxTerminal 的规范摘要，而非重新定义摘要域。
    if terminal.binding() != binding || key.operation_id() != binding.operation_id()
        || key.operation_seq() != binding.operation_seq() || key.receipt_seq().get() == 0
        || !terminal.digest(Limits::MESSAGE).is_ok_and(|digest| &digest == key.digest())
    {
        return false;
    }
    match terminal.value() {
        AuxValue::View { descriptor } => {
            let format = if method == InitialNativeMethod::Query { ViewFormat::Text } else { ViewFormat::TypedFacts };
            terminal.execution_extent() == &ExecutionExtent::CompleteKnown
                && descriptor.operation() == binding.operation_id() && descriptor.node() == node
                && descriptor.source() == binding.source() && descriptor.environment() == binding.environment()
                && descriptor.format() == &format && descriptor.facts_kind() == &facts_kind
                && valid_capture(descriptor.capture(), op.budget.output_bytes().get().min(view_quota))
        }
        AuxValue::Error { stage, .. } => matches!(stage, NativeStage::Parse | NativeStage::Execute
            | NativeStage::Register | NativeStage::Restore | NativeStage::View),
        _ => false,
    }
}

fn valid_capture(capture: &CaptureStatus, limit: i64) -> bool {
    if capture.captured_bytes().get() > limit
        || matches!(capture.total_bytes(), Fact::Known(total) if total < capture.captured_bytes())
    {
        return false;
    }
    !*capture.complete() || (capture.total_bytes() == &Fact::Known(*capture.captured_bytes())
        && matches!(capture.digest(), Fact::Known(_)) && capture.missing_ranges().as_slice().is_empty()
        && capture.reason() == &Fact::NotApplicable)
}

fn pull_reply_header(reply: &ViewReplyPull) -> &EpochHeader {
    match reply {
        ViewReplyPull::Result { header, .. } | ViewReplyPull::ProtocolError { header, .. } => header,
    }
}

fn valid_retired(value: &NativeViewRetired, descriptor: &ViewEvidence<'_>, stream: &Stream, requested: &U) -> bool {
    stream.last_ack.as_ref().is_some_and(|ack| {
        value.view() == descriptor.view() && value.operation() == descriptor.operation()
            && value.requested_seq() == requested && requested <= ack.seq()
            && value.acked_through() == ack.seq() && value.end_offset() == &stream.offset
    })
}

fn deadline_before(deadline: Instant, absolute: U) -> Result<Instant, ChannelError> {
    let deadline = deadline.min(absolute_deadline(absolute)?);
    ensure_before(deadline)?;
    Ok(deadline)
}

fn ensure_before(deadline: Instant) -> Result<(), ChannelError> {
    if Instant::now() >= deadline { Err(FrameError::Timeout.into()) } else { Ok(()) }
}

#[cfg(test)]
mod inspection_regression {
    use super::*;
    use ccv_protocol::actor::{GoalGroup, GoalSelector};
    use ccv_protocol::nativeface::{InitialRequestBinding, NativeCode};
    use ccv_protocol::nativeface_b::{NativeGoalEntry, NativeGoalGroup, NativeGoalRoster, NativeHypothesis};
    use std::time::Duration;

    #[test]
    fn retiring_status_requires_a_status_request() {
        let id = |value: &str| Id::new(value.into()).unwrap();
        let u = |value| U::new(value).unwrap();
        let binding = OpBinding::new(id("op"), u(1), Digest32::from_bytes([0; 32]),
            id("context"), id("scope"), id("source"), id("environment"), id("budget")).unwrap();
        let status = OpStatus::new(binding.clone(), NativeOpState::Retiring, Fact::NotApplicable,
            Fact::NotApplicable, u(0), u(1), u(0), Fact::NotApplicable, false).unwrap();
        assert!(!inspection_status_allowed(false, &binding, &status), "建立直答不能接受 RETIRING Status");
        assert!(inspection_status_allowed(true, &binding, &status));
    }

    #[test]
    fn pending_ack_can_use_recovery_after_output_expiry() {
        let output = U::new(0).unwrap();
        let recovery = U::new(NativeDriver::monotonic_time_us().unwrap().get() + 10_000_000).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        assert!(deadline_before(deadline, inspection_ack_write_limit(true, output, recovery)).is_ok(),
            "已持久的 pending ACK 不能被已过的输出期限拦截");
        assert!(matches!(deadline_before(deadline, inspection_ack_write_limit(false, output, recovery)),
            Err(ChannelError::Frame(FrameError::Timeout))));
        assert!(matches!(deadline_before(deadline, inspection_ack_write_limit(true, output, output)),
            Err(ChannelError::Frame(FrameError::Timeout))));
    }

    #[test]
    fn decoded_finish_errors_leave_the_inflight_phase() {
        let rejected = NativeProtocolError::new(NativeCode::InvalidInput, Admission::NotAdmitted, Fact::NotApplicable).unwrap();
        assert!(matches!(inspection_finish_error_phase(&rejected), Phase::Terminal));
        for admission in [Admission::Unknown, Admission::ExistingOperation] {
            let error = NativeProtocolError::new(NativeCode::BindingConflict, admission, Fact::NotApplicable).unwrap();
            assert!(matches!(inspection_finish_error_phase(&error), Phase::ProtocolUnresolved(saved) if saved == error));
        }
    }

    fn finish_slot(release: Option<Option<ReleaseStatus>>) -> (InspectionOperationSlot, RegisteredInspection, ReceiptKey) {
        let id = |s: &str| Id::new(s.into()).unwrap();
        let u = |n| U::new(n).unwrap();
        let digest = Digest32::from_bytes([0; 32]);
        let binding = OpBinding::new(id("op"), u(1), digest, id("context"), id("scope"),
            id("source"), id("environment"), id("budget")).unwrap();
        let key = ReceiptKey::new(id("op"), u(1), u(1), digest).unwrap();
        let recovery = u(NativeDriver::monotonic_time_us().unwrap().get() + 10_000_000);
        let budget = NativeBudget::new(id("budget"), id("op"), u(1), id("scope"), id("source"), id("environment"),
            id("grant"), u(1), id("boot"), recovery, recovery, recovery, u(64), NativePurpose::Task {},
            KnownOrNa::NotApplicable, InitialRequestBinding::new(InitialNativeMethod::Inspect, InitialPhase::NotApplicable, digest).unwrap()).unwrap();
        let request = NativeRequest::Inspect { header: EpochHeader::new(id("instance"), u(1), u(1), u(1)),
            args: ArgsInspect::new(binding.clone(), id("node"), InspectSelector::Environment {}, id("output")).unwrap() };
        let owner = Arc::new(());
        let token = RegisteredInspection { owner: Arc::downgrade(&owner) };
        let terminal = AuxTerminal::new(key.clone(), binding, ExecutionExtent::CompleteKnown,
            AuxValue::Error { stage: NativeStage::View, diagnostic: Fact::NotApplicable, last_valid: Fact::NotApplicable });
        let stream = release.map(|release| Stream { release, ..Stream::new().unwrap() });
        (InspectionOperationSlot { active: Some(Operation { owner, interrupt: Arc::new(CandidateInterruptState::default()),
            interrupt_issued: false, request, budget, phase: Phase::Terminal,
            terminal: Some(terminal), stream, roster_children: None, assumption_children: None, finished: None }), ..InspectionOperationSlot::default() }, token, key)
    }

    #[test]
    fn finished_replays_after_slot_closes_in_both_orders() {
        let deadline = Instant::now() + Duration::from_secs(5);
        for release in [None, Some(Some(ReleaseStatus::Released)), Some(None)] {
            let (mut slot, token, key) = finish_slot(release);
            let finished = NativeResult::Finished { key: key.clone() };
            slot.record_finished(&finished, &key).unwrap();
            if release == Some(None) {
                slot.active_mut().unwrap().stream_mut().unwrap().release = Some(ReleaseStatus::Released);
                slot.close_finished_if_released();
            }
            assert!(slot.active.is_none());
            let (next, next_token, _) = finish_slot(None);
            slot.active = next.active;
            assert!(matches!(slot.replay_finished(&token, &key, deadline), Ok(Some(ref seen)) if seen == &finished),
                "腾槽并开启后继操作后，原 token/key 应重取已核 Finished，release={release:?}");
            assert!(matches!(slot.replay_finished(&next_token, &key, deadline), Ok(None)));
            assert!(slot.disposition(&token).is_none() && slot.operation(&token).is_err());
            let wrong = ReceiptKey::new(key.operation_id().clone(), *key.operation_seq(), *key.receipt_seq(),
                Digest32::from_bytes([1; 32])).unwrap();
            assert!(matches!(slot.replay_finished(&token, &wrong, deadline), Err(ChannelError::InvalidExpectation)));
            slot.last_finished.as_mut().unwrap().recovery_deadline = U::new(0).unwrap();
            assert!(matches!(slot.replay_finished(&token, &key, deadline), Err(ChannelError::Frame(FrameError::Timeout))));
        }
    }

    fn roster_slot(child: &str, conflict: bool, wrong_node: bool) -> (InspectionOperationSlot, ReceiptKey, Vec<u8>) {
        let (mut slot, _, key) = finish_slot(Some(None));
        let id = |s: &str| Id::new(s.into()).unwrap();
        let u = |n| U::new(n).unwrap();
        let part = NativePartDescriptor::new(u(3), Digest32::sha256(b"abc"), NativeViewRef::new(id(child))).unwrap();
        let ty = if conflict { NativePartDescriptor::new(u(4), Digest32::sha256(b"abcd"), part.output().clone()).unwrap() }
            else { part.clone() };
        let hyp = NativeHypothesis::new(u(1), Items::new(vec![]).unwrap(), Fact::Known(part.clone()), ty).unwrap();
        let entry = NativeGoalEntry::new(GoalSelector::new(GoalGroup::Focused, u(0), u(1)).unwrap(),
            Items::new(vec![hyp]).unwrap(), part).unwrap();
        let group = NativeGoalGroup::new(GoalGroup::Focused, u(0), u(2), Items::new(vec![entry]).unwrap()).unwrap();
        let facts = NativeFactsPayload::GoalRoster(NativeGoalRoster::new(Items::new(vec![group]).unwrap(), Fact::Unknown, false).unwrap());
        let complete = |bytes: &[u8]| {
            let n = u(bytes.len() as i64);
            CaptureStatus::new(true, n, Fact::Known(n), Fact::Known(Digest32::sha256(bytes)),
                Items::new(vec![]).unwrap(), Fact::NotApplicable).unwrap()
        };
        let facts_bytes = encode(&facts, Limits::MESSAGE).unwrap();
        let doc = NativeFactsDocument::new(id(if wrong_node { "other" } else { "node" }), id("source"),
            id("environment"), complete(&facts_bytes), facts);
        let bytes = encode(&doc, Limits::MESSAGE).unwrap();
        let parent = NativeViewRef::new(id("parent"));
        let descriptor = ViewDescriptor::new(parent.clone(), id("op"), id("node"), id("source"), id("environment"),
            ViewFormat::TypedFacts, Fact::Known(InspectKind::GoalRoster), complete(&bytes));
        let op = slot.active_mut().unwrap();
        let binding = op.terminal.as_ref().unwrap().binding().clone();
        op.terminal = Some(AuxTerminal::new(key.clone(), binding, ExecutionExtent::CompleteKnown, AuxValue::View { descriptor }));
        let stream = op.stream_mut().unwrap();
        stream.offset = u(bytes.len() as i64);
        stream.hash.update(&bytes);
        stream.eof = true;
        stream.last_ack = Some(ArgsViewAck::new(parent, id("op"), u(1), stream.offset, Digest32::sha256(&bytes)).unwrap());
        (slot, key, bytes)
    }

    #[test]
    fn roster_children_require_the_acked_canonical_parent() {
        let (mut slot, _, bytes) = roster_slot("child", false, false);
        let quota = bytes.len() as i64 + 3;
        let op = slot.active_mut().unwrap();
        let parts = op.checked_roster_children(&bytes, quota).unwrap();
        assert_eq!(parts.len(), 1);
        let mut changed = bytes.clone();
        changed[0] ^= 1;
        assert!(op.checked_roster_children(&changed, quota).is_err(), "原 ACK 摘要不匹配应拒绝");
        op.stream_mut().unwrap().last_ack = None;
        assert!(op.checked_roster_children(&bytes, quota).is_err(), "没有持久 ACK 不得登记");
        for (name, conflict, wrong_node) in [("parent", false, false), ("child", true, false), ("child", false, true)] {
            let (fixture, _, bytes) = roster_slot(name, conflict, wrong_node);
            assert!(fixture.active.unwrap().checked_roster_children(&bytes, 4096).is_err(),
                "父别名、冲突子描述或错误文档节点不得登记");
        }
    }

    #[test]
    fn roster_children_share_parent_budget_and_exact_aliases_deduplicate() {
        let (slot, _, bytes) = roster_slot("child", false, false);
        let quota = bytes.len() as i64 + 3;
        let op = slot.active.unwrap();
        assert_eq!(op.checked_roster_children(&bytes, quota).unwrap().len(), 1);
        assert!(op.checked_roster_children(&bytes, quota - 1).is_err(), "父与唯一子合计超界应拒绝");
    }

    #[test]
    fn assumption_refs_freeze_real_capture_and_share_the_parent_quota() {
        use ccv_protocol::nativeface_b::{AssumptionStatus, NativeAssumptionItem, NativeAssumptionRoot, NativeAssumptions};
        let id = |name: &str| Id::new(name.into()).unwrap();
        let text = |name: &str| ccv_protocol::TextNonEmpty::new(name.into()).unwrap();
        let captured = |bytes: &[u8]| {
            let size = U::new(bytes.len() as i64).unwrap();
            CaptureStatus::new(true, size, Fact::Known(size), Fact::Known(Digest32::sha256(bytes)),
                Items::new(vec![]).unwrap(), Fact::NotApplicable).unwrap()
        };
        let parent = NativeViewRef::new(id("parent"));
        let raw = NativeViewRef::new(id("raw"));
        let ty = NativeViewRef::new(id("type"));
        let item = NativeAssumptionItem::new(text("Const"), ty.clone()).unwrap();
        let root = NativeAssumptionRoot::new(text("root"), Fact::NotApplicable, AssumptionStatus::Assumptions,
            Items::new(vec![item.clone(), item]).unwrap(), raw.clone(), Fact::NotApplicable).unwrap();
        let facts = NativeFactsPayload::Assumptions(NativeAssumptions::new(Items::new(vec![root]).unwrap()).unwrap());
        let doc = NativeFactsDocument::new(id("node"), id("source"), id("environment"),
            captured(&encode(&facts, Limits::MESSAGE).unwrap()), facts);
        let bytes = encode(&doc, Limits::MESSAGE).unwrap();
        let quota = bytes.len() as i64 + 3;
        let descriptor = ViewDescriptor::new(parent.clone(), id("op"), id("node"), id("source"), id("environment"),
            ViewFormat::TypedFacts, Fact::Known(InspectKind::Assumptions), captured(&bytes));
        let refs = checked_assumption_document(&descriptor, &bytes, quota).unwrap();
        assert_eq!(refs.len(), 2);
        let (mut slot, _, key) = finish_slot(Some(None));
        let op = slot.active_mut().unwrap();
        let binding = op.terminal.as_ref().unwrap().binding().clone();
        op.terminal = Some(AuxTerminal::new(key, binding, ExecutionExtent::CompleteKnown, AuxValue::View { descriptor }));
        assert!(op.child_registration_pending() && op.view(&raw).is_err());
        op.install_assumption_children(refs.clone()).unwrap();
        let first = captured(b"abc");
        assert!(op.assumption_capture_fits(&first, quota));
        op.view_stream_mut(&raw).unwrap().observed_capture = Some(first.clone());
        op.install_assumption_children(refs).unwrap();
        let (evidence, stream) = op.view(&raw).unwrap();
        assert!(evidence.matches_capture(&first, stream.observed_capture.as_ref()));
        assert!(!evidence.matches_capture(&captured(b"xyz"), stream.observed_capture.as_ref()));
        assert!(!op.assumption_capture_fits(&captured(b"x"), quota));
        assert!(op.assumption_capture_fits(&captured(b""), quota));
        op.view_stream_mut(&parent).unwrap().release = Some(ReleaseStatus::Released);
        op.view_stream_mut(&raw).unwrap().release = Some(ReleaseStatus::Released);
        assert!(!op.views_released());
        op.view_stream_mut(&ty).unwrap().release = Some(ReleaseStatus::Released);
        assert!(op.views_released());
    }

    #[test]
    fn roster_finish_keeps_children_until_real_independent_release() {
        let (mut slot, key, bytes) = roster_slot("child", false, false);
        let child = NativeViewRef::new(Id::new("child".into()).unwrap());
        let op = slot.active_mut().unwrap();
        assert!(op.child_registration_pending() && op.view(&child).is_err());
        let parts = op.checked_roster_children(&bytes, 4096).unwrap();
        op.install_roster_children(parts).unwrap();
        let (evidence, stream) = op.view(&child).unwrap();
        assert!(matches!(evidence, ViewEvidence::Child(..)) && stream.offset.get() == 0);
        op.stream_mut().unwrap().release = Some(ReleaseStatus::Released);
        slot.record_finished(&NativeResult::Finished { key: key.clone() }, &key).unwrap();
        assert!(slot.active.is_some(), "N08/父释放不能清活子");
        slot.active_mut().unwrap().view_stream_mut(&child).unwrap().release = Some(ReleaseStatus::Closing);
        slot.close_finished_if_released();
        assert!(slot.active.is_some());
        slot.active_mut().unwrap().view_stream_mut(&child).unwrap().release = Some(ReleaseStatus::Released);
        slot.close_finished_if_released();
        assert!(slot.active.is_none());
    }
}
