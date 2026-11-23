//! NN03 的 OperationMetadata view。捕获与 PS06 应用各自有独立确认。

use super::{absolute_deadline, ChannelError, FrameError, NativeDriver, Phase, RegisteredStateOperation, StateOperationSlot};
use crate::native::Channel;
use ccv_protocol::nativeface::{Admission, ArgsSyncSource, AuxTerminal, AuxValue, NativeLineUpdateRef, NativeProtocolError, NativeRequest, NativeVersion, ReceiptKey};
use ccv_protocol::nativeface_b::{ArgsViewAck, ArgsViewPull, ArgsViewRelease, NativeLineState, NativeLineUpdateDocument,
    NativeLineChange, NativeViewChunk, NativeViewReleaseResult, ReleaseStatus, ViewAckResult, ViewPullResult, ViewReleaseResultValue,
    ViewReplyAck, ViewReplyPull, ViewReplyRelease, ViewRequest};
use ccv_protocol::{decode, encode, Digest32, EpochHeader, Fact, Limits, U};
use sha2::{Digest, Sha256};
use std::time::Instant;

pub(super) struct LineUpdates {
    terminal: AuxTerminal,
    reference: NativeLineUpdateRef,
    offset: U,
    seq: U,
    hash: Sha256,
    pending: Option<NativeViewChunk>,
    complete: bool,
    checked: Option<NativeLineUpdateDocument>,
    release: Option<NativeViewReleaseResult>,
    unresolved: Option<NativeProtocolError>,
}

impl LineUpdates {
    pub(super) fn new(terminal: AuxTerminal) -> Result<Self, ChannelError> {
        let AuxValue::SourceSynced { line_updates, .. } = terminal.value() else { return Err(ChannelError::InvalidExpectation); };
        Ok(Self { reference: line_updates.clone(), terminal, offset: U::new(0)?, seq: U::new(0)?, hash: Sha256::new(),
            pending: None, complete: false, checked: None, release: None, unresolved: None })
    }
    pub(super) fn terminal(&self) -> &AuxTerminal { &self.terminal }
    pub(super) fn released(&self) -> bool {
        self.release.as_ref().is_some_and(|r| r.status() == &ReleaseStatus::Released)
    }
    fn ack(&self, chunk: &NativeViewChunk) -> Result<ArgsViewAck, ChannelError> {
        Ok(ArgsViewAck::new(self.reference.view().clone(), self.terminal.binding().operation_id().clone(), *chunk.seq(),
            *chunk.range().end(), Digest32::sha256(chunk.text().as_str().as_bytes()))?)
    }

    fn pull_frame(&self, header: EpochHeader) -> Result<ViewRequest, ChannelError> {
        let seq = U::new(self.seq.get().checked_add(1).ok_or(ChannelError::SequenceOverflow)?)?;
        Ok(ViewRequest::Pull { header, args: ArgsViewPull::new(self.reference.view().clone(),
            self.terminal.binding().operation_id().clone(), seq, self.offset,
            ccv_protocol::nativeface_b::CreditBytesView::new(8192)?)? })
    }
}

impl StateOperationSlot {
    fn updates(&self) -> Result<&LineUpdates, ChannelError> {
        if !matches!(&self.phase, Phase::Established { terminal: Some(_) }) { return Err(ChannelError::InvalidExpectation); }
        let updates = self.line_updates.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        if let Some(error) = &updates.unresolved { return Err(ChannelError::Native(error.clone())); }
        Ok(updates)
    }
}

impl NativeDriver {
    /// BO07 受信调用者须已封受影响 context 的新派发，并持原 view/存储额度。
    /// 每次只读一个块；重入返回已收待提交块，或严格排空原 view RPC。
    pub fn pull_line_updates(&mut self, token: &RegisteredStateOperation, deadline: Instant) -> Result<NativeViewChunk, ChannelError> {
        let slot = self.state_operations.slot(token)?;
        let updates = slot.updates()?;
        if updates.complete || updates.release.is_some() { return Err(ChannelError::InvalidExpectation); }
        if let Some(chunk) = &updates.pending { return Ok(chunk.clone()); }
        let (header, write, recovery) = self.line_update_window(slot, deadline, *slot.budget.output_deadline_us())?;
        let frame = updates.pull_frame(header.clone())?;
        let reply = self.exchange_inspection_view(&frame, &header, pull_reply_header, deadline, write, recovery)?;
        self.checked_line_update_pull(token, reply)
    }

    /// 撤权后只续读已发出的原 pull；返回块仅供原 Partial Commit 对账。
    pub fn drain_pending_line_updates(&mut self, token: &RegisteredStateOperation, deadline: Instant)
        -> Result<Option<NativeViewChunk>, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let slot = self.state_operations.slot(token)?;
        let reply = drain_line_update_pull(&mut self.view, slot.updates()?, *slot.budget.recovery_deadline_us(), deadline);
        if self.view.failed() { self.quarantine(); }
        reply?.map(|reply| self.checked_line_update_pull(token, reply)).transpose()
    }

    fn checked_line_update_pull(&mut self, token: &RegisteredStateOperation, reply: ViewReplyPull)
        -> Result<NativeViewChunk, ChannelError> {
        let value = match reply {
            ViewReplyPull::Result { result: ViewPullResult::Chunk { value }, .. } => value,
            ViewReplyPull::ProtocolError { error, .. } => return self.line_update_error(error),
            _ => return self.bad_state_operation_reply(),
        };
        let updates = self.state_operations.slot(token)?.updates()?;
        let seq = U::new(updates.seq.get().checked_add(1).ok_or(ChannelError::SequenceOverflow)?)?;
        let data = value.text().as_str().as_bytes();
        let end = value.range().end();
        let capture = value.capture();
        if value.view() != updates.reference.view() || value.operation() != updates.terminal.binding().operation_id()
            || value.seq() != &seq || value.range().start() != &updates.offset || data.is_empty() || data.len() > 8192
            || end.get().checked_sub(updates.offset.get()) != Some(data.len() as i64)
            || end > updates.reference.bytes() || *value.end() != (end == updates.reference.bytes())
            || !*capture.complete() || capture.captured_bytes() != updates.reference.bytes()
            || capture.total_bytes() != &Fact::Known(*updates.reference.bytes())
            || capture.digest() != &Fact::Known(*updates.reference.digest())
            || !capture.missing_ranges().as_slice().is_empty() || capture.reason() != &Fact::NotApplicable {
            return self.bad_state_operation_reply();
        }
        if *value.end() {
            let mut hash = updates.hash.clone();
            hash.update(data);
            if &Digest32::from_bytes(hash.finalize().into()) != updates.reference.digest() { return self.bad_state_operation_reply(); }
        }
        self.line_updates_mut().pending = Some(value.clone());
        Ok(value)
    }

    /// confirm_durable 只可取 BO07/PS02 实际已提交的原块凭据。
    pub fn ack_line_updates(&mut self, token: &RegisteredStateOperation, deadline: Instant,
        confirm_durable: impl FnOnce(&ArgsViewAck, Instant) -> Result<bool, ChannelError>,
    ) -> Result<ViewAckResult, ChannelError> {
        let slot = self.state_operations.slot(token)?;
        let updates = slot.updates()?;
        let chunk = updates.pending.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        let ack = updates.ack(chunk)?;
        let (header, write, recovery) = self.line_update_window(slot, deadline, *slot.budget.recovery_deadline_us())?;
        if self.view.pending_header().is_none() && !confirm_durable(&ack, write)? {
            return Err(ChannelError::AwaitingAckEffect);
        }
        let frame = ViewRequest::Ack { header: header.clone(), args: ack.clone() };
        let reply = self.exchange_inspection_view(&frame, &header, |r| match r {
            ViewReplyAck::Result { header, .. } | ViewReplyAck::ProtocolError { header, .. } => header,
        }, deadline, write, recovery)?;
        let result = match reply {
            ViewReplyAck::Result { result, .. } => result,
            ViewReplyAck::ProtocolError { error, .. } => return self.line_update_error(error),
        };
        if !matches!(&result, ViewAckResult::Acked { value } if value.view() == ack.view() && value.operation() == ack.operation()
            && value.seq() == ack.seq() && value.end_offset() == ack.end_offset()) { return self.bad_state_operation_reply(); }
        let updates = self.line_updates_mut();
        let chunk = updates.pending.take().ok_or(ChannelError::InvalidExpectation)?;
        updates.hash.update(chunk.text().as_str().as_bytes());
        updates.offset = *ack.end_offset();
        updates.seq = *ack.seq();
        updates.complete = *chunk.end();
        Ok(result)
    }

    /// MS39 提供 PS02 已封存的原字节及事务前公开线 exact-set（按 ID 排序）。
    /// 线版本快照可检查步长，不含旧路径、源资格或状态；语义变更由原 Pet 事务和 MS39/PS06 对账。
    pub fn verify_line_updates(&mut self, token: &RegisteredStateOperation, bytes: &[u8], before: &[NativeVersion],
        deadline: Instant) -> Result<NativeLineUpdateDocument, ChannelError> {
        let slot = self.state_operations.slot(token)?;
        let updates = slot.updates()?;
        let NativeRequest::SyncSource { header, args } = &slot.request else { return Err(ChannelError::InvalidExpectation); };
        let deadline = deadline.min(absolute_deadline(*slot.budget.recovery_deadline_us())?);
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let doc = checked_document(header, args, updates, bytes, before)?;
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        self.line_updates_mut().checked = Some(doc.clone());
        Ok(doc)
    }

    /// 只有 M2 按该文档确认 PS06 真实拥有材料且当前映射已安装，才可释放 spool。
    pub fn release_line_updates(&mut self, token: &RegisteredStateOperation, deadline: Instant,
        confirm_applied: impl FnOnce(&ReceiptKey, &NativeLineUpdateDocument, Instant) -> Result<bool, ChannelError>,
    ) -> Result<NativeViewReleaseResult, ChannelError> {
        let slot = self.state_operations.slot(token)?;
        let updates = slot.updates()?;
        let doc = updates.checked.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        if updates.released() { return updates.release.clone().ok_or(ChannelError::InvalidExpectation); }
        let (header, write, recovery) = self.line_update_window(slot, deadline, *slot.budget.recovery_deadline_us())?;
        if self.view.pending_header().is_none() && !confirm_applied(updates.terminal.key(), doc, write)? {
            return Err(ChannelError::InvalidExpectation);
        }
        let args = ArgsViewRelease::new(updates.reference.view().clone(), updates.terminal.binding().operation_id().clone(), Fact::Known(updates.seq))?;
        let frame = ViewRequest::Release { header: header.clone(), args: args.clone() };
        let reply = self.exchange_inspection_view(&frame, &header, |r| match r {
            ViewReplyRelease::Result { header, .. } | ViewReplyRelease::ProtocolError { header, .. } => header,
        }, deadline, write, recovery)?;
        let value = match reply {
            ViewReplyRelease::Result { result: ViewReleaseResultValue::Released { value }, .. } => value,
            ViewReplyRelease::ProtocolError { error, .. } => return self.line_update_error(error),
        };
        if value.view() != args.view() || value.operation() != args.operation() { return self.bad_state_operation_reply(); }
        self.line_updates_mut().release = Some(value.clone());
        Ok(value)
    }

    fn line_update_window(&self, slot: &StateOperationSlot, deadline: Instant, write_limit: U)
        -> Result<(EpochHeader, Instant, Instant), ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let recovery = absolute_deadline(*slot.budget.recovery_deadline_us())?;
        let deadline = deadline.min(recovery);
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        if let Some(header) = self.view.pending_header() { return Ok((header.clone(), deadline, recovery)); }
        let write = deadline.min(absolute_deadline(write_limit)?);
        if Instant::now() >= write { return Err(FrameError::Timeout.into()); }
        Ok((self.view.next_header()?, write, recovery))
    }

    fn line_updates_mut(&mut self) -> &mut LineUpdates {
        self.state_operations.slot.as_mut().and_then(|slot| slot.line_updates.as_mut()).expect("已核 NN03 owner")
    }

    fn line_update_error<T>(&mut self, error: NativeProtocolError) -> Result<T, ChannelError> {
        if error.admission() != &Admission::NotAdmitted { self.line_updates_mut().unresolved = Some(error.clone()); }
        Err(ChannelError::Native(error))
    }
}

fn pull_reply_header(reply: &ViewReplyPull) -> &EpochHeader {
    match reply {
        ViewReplyPull::Result { header, .. } | ViewReplyPull::ProtocolError { header, .. } => header,
    }
}

fn drain_line_update_pull(view: &mut Channel, updates: &LineUpdates, recovery: U, deadline: Instant)
    -> Result<Option<ViewReplyPull>, ChannelError> {
    if view.failed() { return Err(ChannelError::Failed); }
    let Some(header) = view.pending_header().cloned() else { return Ok(None); };
    if updates.pending.is_some() || updates.complete || updates.release.is_some() {
        return Err(ChannelError::InvalidExpectation);
    }
    let deadline = deadline.min(absolute_deadline(recovery)?);
    if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
    let frame = updates.pull_frame(header.clone())?;
    // 通道先核原请求字节与回复类型；半写 view 已失败，此处没有发送新帧的路径。
    view.drain_view(&frame, &header, pull_reply_header, deadline)
}

fn checked_document(header: &EpochHeader, args: &ArgsSyncSource, updates: &LineUpdates,
    bytes: &[u8], before: &[NativeVersion]) -> Result<NativeLineUpdateDocument, ChannelError> {
    let mismatch = ChannelError::InvalidExpectation;
    if !updates.complete || updates.pending.is_some() || &updates.offset != updates.reference.bytes()
        || usize::try_from(updates.offset.get()).ok() != Some(bytes.len())
        || &Digest32::sha256(bytes) != updates.reference.digest()
        || &Digest32::from_bytes(updates.hash.clone().finalize().into()) != updates.reference.digest() { return Err(mismatch); }
    let AuxValue::SourceSynced { revision, .. } = updates.terminal.value() else { return Err(mismatch); };
    decode_bound_line_updates(header, args, *revision, bytes, before)
}

fn decode_bound_line_updates(header: &EpochHeader, args: &ArgsSyncSource, revision: U,
    bytes: &[u8], before: &[NativeVersion]) -> Result<NativeLineUpdateDocument, ChannelError> {
    let mismatch = ChannelError::InvalidExpectation;
    let limits = Limits::new(64 * 1024 * 1024, 64)?;
    let doc = decode::<NativeLineUpdateDocument>(bytes, limits)?.into_inner();
    if encode(&doc, limits)? != bytes || doc.operation() != args.binding().operation_id()
        || doc.instance() != header.instance() || *doc.backend_epoch() != header.backend_epoch()
        || *doc.manager_epoch() != header.manager_epoch() || doc.context() != args.context()
        || doc.old_source() != args.old_source() || doc.new_source() != args.new_source()
        || doc.before_context_revision() != args.expected_context().revision() || doc.after_context_revision() != &revision
        || !valid_line_versions(doc.lines().as_slice(), before) { return Err(mismatch); }
    Ok(doc)
}

fn valid_line_versions(lines: &[NativeLineChange], before: &[NativeVersion]) -> bool {
    if lines.len() != before.len() || before.windows(2).any(|pair| pair[0].id() >= pair[1].id()) { return false; }
    for (line, previous) in lines.iter().zip(before) {
        if line.line() != previous.id() || line.before_revision() != previous.revision()
            || (line.after_revision() != line.before_revision()
                && line.before_revision().get().checked_add(1) != Some(line.after_revision().get()))
            || !match line.state() {
                NativeLineState::Open => matches!(line.frontier(), Fact::Known(_)),
                NativeLineState::Retiring => !matches!(line.frontier(), Fact::NotApplicable),
                NativeLineState::Closed => line.frontier() == &Fact::NotApplicable,
            } { return false; }
    }
    true
}

#[cfg(test)]
mod nn03_regression {
    use super::*;
    use ccv_protocol::{actor::Items, storage::SchemaVersion, Id};
    use ccv_protocol::nativeface::{NativeViewRef, OpBinding};

    #[test]
    fn pending_only_drain_without_a_frame_does_not_request_a_header() {
        use ccv_protocol::{reply::ExecutionExtent, NativeChannel};
        use std::{io::Read, os::unix::net::UnixStream, time::Duration};

        let id = |name: &str| Id::new(name.into()).unwrap();
        let one = U::new(1).unwrap();
        let digest = Digest32::sha256(b"test");
        let binding = OpBinding::new(id("sync"), one, digest, id("context"), id("scope"),
            id("source"), id("environment"), id("budget")).unwrap();
        let terminal = AuxTerminal::new(ReceiptKey::new(id("sync"), one, one, digest).unwrap(), binding,
            ExecutionExtent::CompleteKnown, AuxValue::SourceSynced { context: id("context"), revision: one,
                source: id("source"), last_valid: Fact::NotApplicable, reclaim: id("reclaim"),
                boundary: Fact::NotApplicable, line_updates: NativeLineUpdateRef::new(
                    NativeViewRef::new(id("view")), digest, one).unwrap() });
        let updates = LineUpdates::new(terminal).unwrap();
        let (stream, mut peer) = UnixStream::pair().unwrap();
        peer.set_nonblocking(true).unwrap();
        let mut view = Channel::new(stream, NativeChannel::View, id("instance"), one, one);
        let recovery = U::new(NativeDriver::monotonic_time_us().unwrap().get() + 1_000_000).unwrap();
        // 未握手通道会拒绝取新 header，因此 None 也核住不进入首次发送路径。
        assert!(drain_line_update_pull(&mut view, &updates, recovery, Instant::now() + Duration::from_secs(1)).unwrap().is_none());
        assert_eq!(peer.read(&mut [0]).unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
    }

    #[test]
    fn canonical_document_binds_context_and_full_sorted_line_versions() {
        let id = |name: &str| Id::new(name.into()).unwrap();
        let u = |n| U::new(n).unwrap();
        let header = EpochHeader::new(id("instance"), u(3), u(4), u(9));
        let binding = OpBinding::new(id("sync"), u(2), Digest32::sha256(b"sync"), id("context"),
            id("scope"), id("new"), id("environment"), id("budget")).unwrap();
        let version = |line, revision| NativeVersion::new(id(line), u(revision)).unwrap();
        let args = ArgsSyncSource::new(binding, id("context"), version("context", 7), id("old"), id("new"), id("publication")).unwrap();
        let a = version("a", 10);
        let b = version("b", 5);
        let before = [a.clone(), b.clone()];
        let row = |line, from, to, state, frontier| NativeLineChange::new(id(line), u(from), u(to), frontier, state).unwrap();
        let open = row("a", 10, 10, NativeLineState::Open, Fact::Known(id("node")));
        let closed = row("b", 5, 6, NativeLineState::Closed, Fact::NotApplicable);
        let bytes = |context, lines| {
            let doc = NativeLineUpdateDocument::new(SchemaVersion, id("sync"), id("instance"), u(3), u(4),
                id(context), id("old"), id("new"), u(7), u(8), Items::new(lines).unwrap()).unwrap();
            encode(&doc, Limits::MESSAGE).unwrap()
        };
        let good = bytes("context", vec![open.clone(), closed.clone()]);
        let check = |raw: &[u8], expected: &[NativeVersion]| decode_bound_line_updates(&header, &args, u(8), raw, expected);
        assert!(check(&good, &before).is_ok());
        assert!(check(&good, &[b, a]).is_err());
        assert!(check(&bytes("context", vec![open.clone()]), &before).is_err());
        assert!(check(&bytes("context", vec![open.clone(), open.clone()]), &before).is_err());
        assert!(check(&bytes("other", vec![open.clone(), closed.clone()]), &before).is_err());
        assert!(decode_bound_line_updates(&header, &args, u(9), &good, &before).is_err());
        for bad in [row("b", 4, 5, NativeLineState::Closed, Fact::NotApplicable),
            row("b", 5, 7, NativeLineState::Closed, Fact::NotApplicable),
            row("b", 5, 4, NativeLineState::Closed, Fact::NotApplicable),
            row("b", 5, 6, NativeLineState::Closed, Fact::Known(id("node")))] {
            assert!(check(&bytes("context", vec![open.clone(), bad]), &before).is_err());
        }
        let mut noncanonical = good;
        noncanonical.push(b' ');
        assert!(check(&noncanonical, &before).is_err());
    }
}
