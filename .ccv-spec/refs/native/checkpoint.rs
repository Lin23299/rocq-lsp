//! NC04：真实四通道中的 checkpoint 二进制分支。块 ACK 只确认接收方已写入。
use super::{base64, Channel, ChannelError, FrameError, NativeDriver, Nw02Reservation};
use ccv_protocol::misc_rec::CheckpointImportPermit;
use ccv_protocol::nativeface::{AnyTerminal, ArgsCheckpointExport, ArgsSettleInterrupt, ArtifactKind, ArtifactRef, AuxTerminal, AuxValue,
    ControlOperation, ExportPhase, InitialNativeMethod, InitialPhase, KnownOrNa, NativeBudget,
    NativeOpState, NativePurpose, NativeReply, NativeRequest, NativeResult, NativeStage, OpBinding, OpStatus};
use ccv_protocol::nativeface_b::{ArgsCheckpointBlobAck, ArgsCheckpointBlobBegin,
    ArgsCheckpointBlobChunk, ArgsCheckpointBlobFinish, ArgsCheckpointBlobPull,
    ArgsCheckpointBlobRelease, Base64Src, BlobReleaseReason, CheckpointBlobReply,
    CheckpointBlobRequest, CheckpointBlobResult, CheckpointTransfer, CreditBytesBin, ReleaseStatus};
use ccv_protocol::reply::ExecutionExtent;
use ccv_protocol::{Digest32, Fact, Id, Limits, NativeChannel, U};
use sha2::{Digest, Sha256};
use std::{fs::File, io::{Seek, Write}, time::{Duration, Instant}};

const BLOCK: usize = 8192;

impl NativeDriver {
    /// W02/W04 共用。NC06 不走普通发送；必须提供 PS36 的本次准入记录。
    pub fn execute_checkpoint(&mut self, request: &NativeRequest, budget: &NativeBudget, deadline: Instant)
        -> Result<AuxTerminal, ChannelError> {
        if matches!(request, NativeRequest::CheckpointImport { .. } | NativeRequest::CheckpointActivate { .. }) {
            return Err(ChannelError::InvalidExpectation);
        }
        self.execute_checkpoint_registered(request, budget, None, deadline)
    }

    /// NC08 的 group 来自原导入的已核终态，不能从新 activate 响应回填。
    pub fn execute_checkpoint_activation(&mut self, request: &NativeRequest, budget: &NativeBudget,
        imported: &AuxTerminal, deadline: Instant) -> Result<AuxTerminal, ChannelError> {
        let group = activation_group(request, budget, imported)?;
        self.execute_checkpoint_registered(request, budget, Some(group), deadline)
    }

    /// NC06D。`compatibility_record` 是与当前请求材料明确关联的 PS36 记录 ID，
    /// 不把这个 ID 当作 blob 的摘要或当前请求引用。
    pub fn execute_checkpoint_import(&mut self, request: &NativeRequest, budget: &NativeBudget,
        permit: &CheckpointImportPermit, compatibility_record: &Id, deadline: Instant) -> Result<AuxTerminal, ChannelError> {
        let NativeRequest::CheckpointImport { args, .. } = request else { return Err(ChannelError::InvalidExpectation); };
        if permit.control_id() != args.control() || permit.cache_id() != args.cache() || permit.attempt() != args.attempt()
            || permit.instance() != self.boot.instance() || permit.backend_epoch() != self.boot.backend_epoch()
            || permit.manager_epoch() != self.boot.manager_epoch() || permit.budget() != budget.budget()
            || permit.compatibility() != compatibility_record {
            return Err(ChannelError::InvalidExpectation);
        }
        self.execute_checkpoint_registered(request, budget, None, deadline)
    }

    fn execute_checkpoint_registered(&mut self, request: &NativeRequest, budget: &NativeBudget, group: Option<&Id>, deadline: Instant)
        -> Result<AuxTerminal, ChannelError> {
        self.require_no_unapplied_ack()?;
        let deadline = before(deadline, *budget.execution_deadline_us())?;
        let binding = self.checkpoint_original(request, budget)?;
        self.nw02.require_registered(budget)?;
        if request.header() != &self.next_header()?
            || !self.domain.verify_applied_limit().is_ok_and(|limit|
                &limit.grant == budget.grant() && limit.revision.get().checked_add(1) == Some(budget.grant_revision().get())) {
            return Err(ChannelError::InvalidExpectation);
        }
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let drain_deadline = absolute_deadline(*budget.recovery_deadline_us())?;
        let reply = self.ordinary.request_resumable(request, deadline, drain_deadline, drain_deadline);
        if self.ordinary.failed() { self.quarantine(); }
        match self.checkpoint_establishment_result(request, budget, binding, group, reply?)? {
            NativeResult::AuxTerminal { terminal } => Ok(terminal),
            _ => Err(ChannelError::Failed),
        }
    }

    /// ND02：续读超时前登记的原帧。没有待排空帧时，不写请求也不试探 socket。
    pub fn drain_checkpoint_establishment(&mut self, original: &NativeRequest, budget: &NativeBudget,
        imported: Option<&AuxTerminal>, deadline: Instant) -> Result<Option<NativeResult>, ChannelError> {
        if self.is_quarantined() { return Err(ChannelError::Failed); }
        let binding = self.checkpoint_original(original, budget)?;
        let group = recovery_group(original, budget, imported)?;
        self.nw02.require_registered(budget)?;
        let reply = self.ordinary.drain_original(original, deadline);
        if self.ordinary.failed() { self.quarantine(); }
        reply?.map(|reply| self.checkpoint_establishment_result(original, budget, binding, group, reply)).transpose()
    }

    fn checkpoint_establishment_result(&mut self, original: &NativeRequest, budget: &NativeBudget, binding: &OpBinding,
        group: Option<&Id>, reply: NativeReply) -> Result<NativeResult, ChannelError> {
        if Nw02Reservation::establishment_rejected(&reply) {
            self.nw02.consume(budget);
        }
        let result = match reply {
            NativeReply::Result { result, .. } => result,
            NativeReply::ProtocolError { error, .. } => return Err(ChannelError::Native(error)),
        };
        let valid = match &result {
            NativeResult::AuxTerminal { terminal } =>
                validate_checkpoint_terminal(original, budget, binding, terminal)? && matches_activation_group(terminal, group),
            NativeResult::PastUnavailable { operation_seq, highest_seen } =>
                operation_seq == binding.operation_seq() && highest_seen >= operation_seq,
            _ => false,
        };
        if !valid { return self.bad_checkpoint_reply(); }
        self.nw02.consume(budget);
        Ok(result)
    }

    /// W04：从同一已排空连接查原操作。恢复不延长预算、不发送另一建立请求。
    pub fn checkpoint_operation_status(&mut self, original: &NativeRequest, budget: &NativeBudget,
        imported: Option<&AuxTerminal>, deadline: Instant) -> Result<NativeResult, ChannelError> {
        let binding = self.checkpoint_original(original, budget)?;
        let group = recovery_group(original, budget, imported)?;
        let result = self.operation_status(binding.clone(), before(deadline, *budget.recovery_deadline_us())?)?;
        self.checked_checkpoint_recovery(original, budget, binding, group, false, result)
    }

    pub fn settle_checkpoint_operation(&mut self, original: &NativeRequest, budget: &NativeBudget,
        imported: Option<&AuxTerminal>, deadline: Instant) -> Result<NativeResult, ChannelError> {
        let binding = self.checkpoint_original(original, budget)?;
        let group = recovery_group(original, budget, imported)?;
        let request = NativeRequest::SettleInterrupt { header: self.next_header()?,
            args: ArgsSettleInterrupt::new(binding.clone())? };
        let result = self.native_result(&request, before(deadline, *budget.recovery_deadline_us())?)?;
        self.checked_checkpoint_recovery(original, budget, binding, group, true, result)
    }

    /// N08 调用者必须先提交同一终态。`PastUnavailable` 保留为对账事实，不等于 finish。
    pub fn finish_checkpoint_operation(&mut self, original: &NativeRequest, budget: &NativeBudget,
        terminal: &AuxTerminal, imported: Option<&AuxTerminal>, deadline: Instant) -> Result<NativeResult, ChannelError> {
        let binding = self.checkpoint_original(original, budget)?;
        let group = recovery_group(original, budget, imported)?;
        if !validate_checkpoint_terminal(original, budget, binding, terminal)? || !matches_activation_group(terminal, group) {
            return Err(ChannelError::InvalidExpectation);
        }
        let result = self.finish_operation(binding.clone(), terminal.key().clone(), before(deadline, *budget.recovery_deadline_us())?)?;
        match &result {
            NativeResult::Finished { key } if key == terminal.key() => Ok(result),
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if operation_seq == binding.operation_seq() && highest_seen >= operation_seq => Ok(result),
            _ => self.bad_checkpoint_reply(),
        }
    }

    fn checkpoint_original<'a>(&self, original: &'a NativeRequest, budget: &NativeBudget) -> Result<&'a OpBinding, ChannelError> {
        let (binding, method, phase) = checkpoint_head(original, budget).ok_or(ChannelError::InvalidExpectation)?;
        let header = original.header();
        if header.instance() != self.boot.instance() || header.backend_epoch() != *self.boot.backend_epoch()
            || header.manager_epoch() != *self.boot.manager_epoch()
            || budget.clock_boot() != self.boot.clock_boot()
            || budget.recovery_deadline_us() < budget.execution_deadline_us()
            || !matches!(budget.checkpoint_limits(), KnownOrNa::Known(_))
            || budget.initial_request().method() != &method || budget.initial_request().phase() != &phase
            || binding.budget() != budget.budget() || binding.operation_id() != budget.operation()
            || binding.operation_seq() != budget.operation_seq() || binding.operation_seq().get() == 0
            || binding.scope() != budget.scope() || binding.source() != budget.source()
            || binding.environment() != budget.environment() || binding.request_digest() != budget.initial_request().digest()
            || &original.operation_digest(Limits::MESSAGE)? != binding.request_digest() {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(binding)
    }

    fn checked_checkpoint_recovery(&mut self, original: &NativeRequest, budget: &NativeBudget, binding: &OpBinding,
        group: Option<&Id>, settling: bool, result: NativeResult) -> Result<NativeResult, ChannelError> {
        let valid_terminal = |terminal: &AuxTerminal| -> Result<bool, ChannelError> {
            Ok(validate_checkpoint_terminal(original, budget, binding, terminal)? && matches_activation_group(terminal, group))
        };
        let (valid, consumed) = match &result {
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if operation_seq == binding.operation_seq() && highest_seen >= operation_seq => (true, true),
            NativeResult::AuxTerminal { terminal } if settling => (valid_terminal(terminal)?, true),
            NativeResult::Status { status } if checkpoint_status_fields(status, binding) => match (status.state(), status.terminal()) {
                (NativeOpState::Terminal, Fact::Known(AnyTerminal::Aux(terminal))) if !settling => (valid_terminal(terminal)?, true),
                (NativeOpState::Retiring, Fact::Known(AnyTerminal::Aux(terminal))) => (valid_terminal(terminal)?, true),
                (NativeOpState::Retiring, Fact::Unknown | Fact::NotApplicable) => (true, true),
                (NativeOpState::Ready | NativeOpState::Executing, Fact::Unknown | Fact::NotApplicable) => (true, true),
                _ => (false, false),
            },
            _ => (false, false),
        };
        if !valid { return self.bad_checkpoint_reply(); }
        if consumed {
            self.nw02.consume(budget);
        }
        Ok(result)
    }

    /// 输入由本次 PS17 读取授权提供；在已确认 NW02 后按原预算、原 operation 上传。
    pub fn upload_checkpoint_material(&mut self, budget: &NativeBudget, artifact: &ArtifactRef,
        bytes: &[u8], deadline: Instant) -> Result<(), ChannelError> {
        self.nw02.require_registered(budget)?;
        let transfer = self.checkpoint_transfer(budget, artifact, NativeChannel::Source)?;
        let deadline = before(deadline, *budget.execution_deadline_us())?;
        if usize::try_from(artifact.bytes().get()).ok() != Some(bytes.len())
            || artifact.digest() != &Digest32::sha256(bytes) {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.source.next_header()?;
        let reply = blob_exchange(&mut self.source, &CheckpointBlobRequest::Begin {
            header, args: ArgsCheckpointBlobBegin::new(transfer.clone())?,
        }, deadline)?;
        let mut offset = match reply {
            CheckpointBlobResult::Registered { artifact: actual } if &actual == artifact => return Ok(()),
            CheckpointBlobResult::Begun { transfer: actual, next_offset } if &actual == transfer.transfer()
                && next_offset <= *artifact.bytes() => next_offset.get() as usize,
            _ => return self.bad_checkpoint_reply(),
        };
        while offset < bytes.len() {
            let end = offset.saturating_add(BLOCK).min(bytes.len());
            let block = &bytes[offset..end];
            let header = self.source.next_header()?;
            let reply = blob_exchange(&mut self.source, &CheckpointBlobRequest::Chunk { header,
                args: ArgsCheckpointBlobChunk::new(transfer.transfer().clone(), transfer.operation().clone(),
                    U::new(offset as i64)?, Base64Src::new(base64(block))?)?,
            }, deadline)?;
            if !matches!(reply, CheckpointBlobResult::ChunkAck { transfer: id, offset: start, end_offset, digest }
                if &id == transfer.transfer() && start.get() as usize == offset && end_offset.get() as usize == end
                    && digest == Digest32::sha256(block)) {
                return self.bad_checkpoint_reply();
            }
            offset = end;
        }
        let header = self.source.next_header()?;
        match blob_exchange(&mut self.source, &CheckpointBlobRequest::Finish { header,
            args: ArgsCheckpointBlobFinish::new(transfer.transfer().clone(), transfer.operation().clone())?,
        }, deadline)? {
            CheckpointBlobResult::Registered { artifact: actual } if &actual == artifact => Ok(()),
            _ => self.bad_checkpoint_reply(),
        }
    }

    /// `spool` 是接收方独占的空文件（PS02 的实际持久化在完整接收之后）。
    pub fn download_checkpoint_material(&mut self, budget: &NativeBudget, artifact: &ArtifactRef,
        spool: &mut File, deadline: Instant) -> Result<(), ChannelError> {
        let transfer = self.checkpoint_transfer(budget, artifact, NativeChannel::View)?;
        let deadline = before(deadline, *budget.output_deadline_us())?;
        let meta = spool.metadata().map_err(FrameError::Io)?;
        if !meta.is_file() || meta.len() != 0 || spool.stream_position().map_err(FrameError::Io)? != 0 {
            return Err(ChannelError::InvalidExpectation);
        }
        let mut hash = Sha256::new();
        let (mut seq, mut offset) = (U::new(1)?, U::new(0)?);
        loop {
            let header = self.view.next_header()?;
            let reply = blob_exchange(&mut self.view, &CheckpointBlobRequest::Pull { header,
                args: ArgsCheckpointBlobPull::new(transfer.clone(), seq, offset, CreditBytesBin::new(BLOCK as i64)?)?,
            }, deadline)?;
            let CheckpointBlobResult::Chunk { transfer: id, seq: actual, offset: start, end_offset, bytes, end } = reply
                else { return self.bad_checkpoint_reply(); };
            let block = bytes.decoded_bytes();
            if &id != transfer.transfer() || actual != seq || start != offset || end_offset > *artifact.bytes()
                || end_offset.get() - offset.get() != block.len() as i64 || block.len() > BLOCK
                || end != (end_offset == *artifact.bytes()) || (block.is_empty() && !end) {
                return self.bad_checkpoint_reply();
            }
            spool.write_all(&block).map_err(FrameError::Io)?;
            if spool.stream_position().map_err(FrameError::Io)? != end_offset.get() as u64 {
                return Err(ChannelError::InvalidExpectation);
            }
            hash.update(&block);
            if end && &Digest32::from_bytes(hash.clone().finalize().into()) != artifact.digest() {
                return self.bad_checkpoint_reply();
            }
            let header = self.view.next_header()?;
            let reply = blob_exchange(&mut self.view, &CheckpointBlobRequest::Ack { header,
                args: ArgsCheckpointBlobAck::new(transfer.transfer().clone(), transfer.operation().clone(),
                    seq, end_offset, Digest32::sha256(&block))?,
            }, deadline)?;
            if !matches!(reply, CheckpointBlobResult::Acked { transfer: id, seq: actual, end_offset: at }
                if &id == transfer.transfer() && actual == seq && at == end_offset) {
                return self.bad_checkpoint_reply();
            }
            if end { return Ok(()); }
            offset = end_offset;
            seq = U::new(seq.get().checked_add(1).ok_or(ChannelError::SequenceOverflow)?)?;
        }
    }

    /// 只接受对应整份材料的封存/消费或放弃记录；不以块 ACK 推导该记录。
    pub fn release_checkpoint_material(&mut self, budget: &NativeBudget, artifact: &ArtifactRef,
        reason: BlobReleaseReason, durable_record: Id, deadline: Instant) -> Result<ReleaseStatus, ChannelError> {
        let transfer = self.checkpoint_transfer(budget, artifact, NativeChannel::View)?;
        let header = self.view.next_header()?;
        let reply = blob_exchange(&mut self.view, &CheckpointBlobRequest::Release { header,
            args: ArgsCheckpointBlobRelease::new(transfer.transfer().clone(), transfer.operation().clone(),
                reason, Fact::Known(durable_record))?,
        }, before(deadline, *budget.recovery_deadline_us())?)?;
        match reply {
            CheckpointBlobResult::Released { transfer: id, status } if &id == transfer.transfer() => Ok(status),
            _ => self.bad_checkpoint_reply(),
        }
    }

    fn bad_checkpoint_reply<T>(&mut self) -> Result<T, ChannelError> {
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }

    fn checkpoint_transfer(&self, budget: &NativeBudget, artifact: &ArtifactRef, direction: NativeChannel)
        -> Result<CheckpointTransfer, ChannelError> {
        use ArtifactKind::*;
        use InitialNativeMethod::*;
        use InitialPhase::*;
        let (NativePurpose::CheckpointControl { control, operation, attempt }, KnownOrNa::Known(limits)) =
            (budget.purpose(), budget.checkpoint_limits()) else { return Err(ChannelError::InvalidExpectation); };
        let allowed = match (direction, budget.initial_request().method(), budget.initial_request().phase(), operation) {
            (NativeChannel::Source, CheckpointObserve, NotApplicable, ControlOperation::Import) =>
                matches!(artifact.kind(), CheckpointPreloadPlan),
            (NativeChannel::Source, CheckpointExport, Known(ExportPhase::Collect), ControlOperation::Export) =>
                matches!(artifact.kind(), CheckpointSelection | CheckpointCompatibility),
            (NativeChannel::Source, CheckpointExport, Known(ExportPhase::Encode), ControlOperation::Export) =>
                matches!(artifact.kind(), CheckpointPlan | CheckpointRequirements | CheckpointCompatibility),
            (NativeChannel::Source, CheckpointImport, NotApplicable, ControlOperation::Import) =>
                matches!(artifact.kind(), CheckpointPlan | CheckpointRequirements | CheckpointCompatibility | CheckpointManifest | CheckpointBundle),
            (NativeChannel::View, CheckpointObserve, NotApplicable, _) => matches!(artifact.kind(), CheckpointObservation),
            (NativeChannel::View, CheckpointExport, Known(ExportPhase::Collect), ControlOperation::Export) => matches!(artifact.kind(), CheckpointRequirements),
            (NativeChannel::View, CheckpointExport, Known(ExportPhase::Encode), ControlOperation::Export) => matches!(artifact.kind(), CheckpointManifest | CheckpointBundle),
            (NativeChannel::View, CheckpointImport, NotApplicable, ControlOperation::Import) => matches!(artifact.kind(), CheckpointMap),
            _ => false,
        };
        let limit = if artifact.kind() == &CheckpointBundle { limits.bundle_bytes() } else { limits.metadata_bytes() };
        let channel_limit = if direction == NativeChannel::Source { self.boot.input_byte_quota() } else { self.boot.view_byte_quota() };
        if direction == NativeChannel::Source { self.ordinary.environment.require_new_work(budget.environment())?; }
        if self.is_quarantined() || !allowed || artifact.bytes().get() > limit.get()
            || artifact.bytes().get() > channel_limit.get() || budget.clock_boot() != self.boot.clock_boot()
            || budget.operation_seq().get() == 0 {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(CheckpointTransfer::new(artifact.id().clone(), budget.operation().clone(), *budget.operation_seq(),
            control.clone(), attempt.clone(), artifact.clone())?)
    }
}

fn activation_group<'a>(request: &NativeRequest, budget: &NativeBudget, imported: &'a AuxTerminal) -> Result<&'a Id, ChannelError> {
    let NativeRequest::CheckpointActivate { args, .. } = request else { return Err(ChannelError::InvalidExpectation); };
    let AuxValue::CheckpointImported { control, attempt, cache, group, mapping, .. } = imported.value()
        else { return Err(ChannelError::InvalidExpectation); };
    if imported.execution_extent() != &ExecutionExtent::CompleteKnown
        || imported.key() != args.import_receipt() || &imported.digest(Limits::MESSAGE)? != imported.key().digest()
        || imported.key().operation_id() != imported.binding().operation_id()
        || imported.key().operation_seq() != imported.binding().operation_seq() || imported.key().receipt_seq().get() != 1
        || imported.key().operation_seq() >= args.binding().operation_seq()
        || cache != args.activation().cache_id() || mapping != args.mapping()
        || imported.binding().scope() != args.binding().scope()
        || imported.binding().context() != args.binding().context()
        || imported.binding().environment() != args.binding().environment()
        || imported.binding().source() != args.binding().source()
        || !matches!(budget.purpose(), NativePurpose::CheckpointControl { control: id, attempt: run_attempt, .. }
            if id == control && run_attempt == attempt) {
        return Err(ChannelError::InvalidExpectation);
    }
    Ok(group)
}

fn recovery_group<'a>(request: &NativeRequest, budget: &NativeBudget, imported: Option<&'a AuxTerminal>) -> Result<Option<&'a Id>, ChannelError> {
    match (request, imported) {
        (NativeRequest::CheckpointActivate { .. }, Some(term)) => activation_group(request, budget, term).map(Some),
        (NativeRequest::CheckpointActivate { .. }, None) | (_, Some(_)) => Err(ChannelError::InvalidExpectation),
        (_, None) => Ok(None),
    }
}

fn matches_activation_group(terminal: &AuxTerminal, group: Option<&Id>) -> bool {
    match terminal.value() {
        AuxValue::CheckpointActivated { group: actual, .. } => Some(actual) == group,
        _ => true,
    }
}

fn checkpoint_status_fields(status: &OpStatus, binding: &OpBinding) -> bool {
    status.binding() == binding && status.pending() == &Fact::NotApplicable && status.last_ack() == &Fact::NotApplicable
        && status.acked_through().get() == 0 && status.retired_through() < binding.operation_seq()
        && status.highest_seen() >= binding.operation_seq()
}

fn checkpoint_head<'a>(request: &'a NativeRequest, budget: &NativeBudget)
    -> Option<(&'a OpBinding, InitialNativeMethod, InitialPhase)> {
    use ArtifactKind::*;
    use InitialPhase::*;
    let NativePurpose::CheckpointControl { control, operation, attempt } = budget.purpose() else { return None; };
    let kind = |artifact: &ArtifactRef, expect| artifact.kind() == &expect;
    Some(match request {
        NativeRequest::CheckpointObserve { args, .. } if args.control() == control && args.attempt() == attempt
            && matches!((operation, args.preload()), (ControlOperation::Export, KnownOrNa::NotApplicable)
                | (ControlOperation::Import, KnownOrNa::Known(_)))
            && !matches!(args.preload(), KnownOrNa::Known(preload) if !kind(preload, CheckpointPreloadPlan)) =>
                (args.binding(), InitialNativeMethod::CheckpointObserve, NotApplicable),
        NativeRequest::CheckpointExport { args: ArgsCheckpointExport::Collect(args), .. }
            if operation == &ControlOperation::Export && args.control() == control && args.attempt() == attempt
                && kind(args.selection(), CheckpointSelection) && kind(args.compatibility(), CheckpointCompatibility) =>
                    (args.binding(), InitialNativeMethod::CheckpointExport, Known(ExportPhase::Collect)),
        NativeRequest::CheckpointExport { args: ArgsCheckpointExport::Encode(args), .. }
            if operation == &ControlOperation::Export && args.control() == control && args.attempt() == attempt
                && kind(args.plan(), CheckpointPlan) && kind(args.requirements(), CheckpointRequirements)
                && kind(args.compatibility(), CheckpointCompatibility) =>
                    (args.binding(), InitialNativeMethod::CheckpointExport, Known(ExportPhase::Encode)),
        NativeRequest::CheckpointImport { args, .. } if operation == &ControlOperation::Import && args.control() == control
            && args.attempt() == attempt && kind(args.plan(), CheckpointPlan) && kind(args.manifest(), CheckpointManifest)
            && kind(args.bundle(), CheckpointBundle) && kind(args.compatibility(), CheckpointCompatibility) =>
                (args.binding(), InitialNativeMethod::CheckpointImport, NotApplicable),
        NativeRequest::CheckpointActivate { args, header } if operation == &ControlOperation::Import
            && args.activation().control_id() == control && args.activation().import_receipt_key() == args.import_receipt()
            && args.activation().import_operation() == args.import_receipt().operation_id()
            && args.activation().instance() == header.instance() && args.activation().backend_epoch() == &header.backend_epoch()
            && args.activation().manager_epoch() == &header.manager_epoch() && kind(args.mapping(), CheckpointMap) =>
                (args.binding(), InitialNativeMethod::CheckpointActivate, NotApplicable),
        _ => return None,
    })
}

fn validate_checkpoint_terminal(request: &NativeRequest, budget: &NativeBudget, binding: &OpBinding, terminal: &AuxTerminal)
    -> Result<bool, ChannelError> {
    use ArtifactKind::*;
    if terminal.binding() != binding || terminal.key().operation_id() != binding.operation_id()
        || terminal.key().operation_seq() != binding.operation_seq() || terminal.key().receipt_seq().get() != 1
        || &terminal.digest(Limits::MESSAGE)? != terminal.key().digest() {
        return Ok(false);
    }
    let KnownOrNa::Known(limits) = budget.checkpoint_limits() else { return Ok(false); };
    let size = |artifact: &ArtifactRef, kind: ArtifactKind| {
        let cap = if kind == CheckpointBundle { limits.bundle_bytes() } else { limits.metadata_bytes() };
        artifact.kind() == &kind && artifact.bytes().get() > 0 && artifact.bytes().get() <= cap.get()
    };
    if let AuxValue::Error { stage, .. } = terminal.value() {
        if terminal.execution_extent() == &ExecutionExtent::UnknownTail { return Ok(false); }
        return Ok(match request {
            NativeRequest::CheckpointObserve { .. } => matches!(stage, NativeStage::CheckpointValidate),
            NativeRequest::CheckpointExport { args: ArgsCheckpointExport::Collect(_), .. } =>
                matches!(stage, NativeStage::CheckpointCollect | NativeStage::CheckpointValidate),
            NativeRequest::CheckpointExport { args: ArgsCheckpointExport::Encode(_), .. } =>
                matches!(stage, NativeStage::CheckpointCollect | NativeStage::CheckpointEncode | NativeStage::CheckpointValidate),
            NativeRequest::CheckpointImport { .. } => matches!(stage, NativeStage::CheckpointDecode | NativeStage::CheckpointValidate),
            NativeRequest::CheckpointActivate { .. } => matches!(stage, NativeStage::CheckpointActivate | NativeStage::CheckpointValidate),
            _ => false,
        });
    }
    if terminal.execution_extent() != &ExecutionExtent::CompleteKnown { return Ok(false); }
    Ok(match (request, terminal.value()) {
        (NativeRequest::CheckpointObserve { args, .. }, AuxValue::CheckpointObserved { control, attempt, observation }) =>
            control == args.control() && attempt == args.attempt() && size(observation, CheckpointObservation),
        (NativeRequest::CheckpointExport { args: ArgsCheckpointExport::Collect(args), .. },
            AuxValue::CheckpointCollected { control, attempt, selection, group, requirements }) =>
            control == args.control() && attempt == args.attempt() && selection == args.selection() && group == args.group()
                && size(requirements, CheckpointRequirements),
        (NativeRequest::CheckpointExport { args: ArgsCheckpointExport::Encode(args), .. },
            AuxValue::CheckpointExported { control, attempt, plan, group, manifest, bundle, compatibility }) =>
            control == args.control() && attempt == args.attempt() && plan == args.plan() && group == args.group()
                && compatibility == args.compatibility() && size(manifest, CheckpointManifest) && size(bundle, CheckpointBundle),
        (NativeRequest::CheckpointImport { args, .. }, AuxValue::CheckpointImported { control, attempt, cache, group, manifest, mapping, compatibility }) =>
            control == args.control() && attempt == args.attempt() && cache == args.cache() && group == args.group()
                && manifest == args.manifest() && compatibility == args.compatibility() && size(mapping, CheckpointMap),
        (NativeRequest::CheckpointActivate { args, .. }, AuxValue::CheckpointActivated { import_receipt, activation_id, cache, mapping, .. }) =>
            import_receipt == args.import_receipt() && activation_id == args.activation().activation_id()
                && cache == args.activation().cache_id() && mapping == args.mapping(),
        _ => false,
    })
}

fn before(deadline: Instant, absolute_us: U) -> Result<Instant, ChannelError> {
    if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
    Ok(deadline.min(absolute_deadline(absolute_us)?))
}

pub(super) fn absolute_deadline(absolute_us: U) -> Result<Instant, ChannelError> {
    let now = Instant::now();
    let remaining = absolute_us.get() - NativeDriver::monotonic_time_us().map_err(FrameError::Io)?.get();
    if remaining <= 0 { return Err(FrameError::Timeout.into()); }
    now.checked_add(Duration::from_micros(remaining as u64)).ok_or(ChannelError::InvalidExpectation)
}

fn blob_exchange(channel: &mut Channel, request: &CheckpointBlobRequest, deadline: Instant)
    -> Result<CheckpointBlobResult, ChannelError> {
    let (header, kind) = match request {
        CheckpointBlobRequest::Begin { header, .. } | CheckpointBlobRequest::Chunk { header, .. }
        | CheckpointBlobRequest::Finish { header, .. } => (header, NativeChannel::Source),
        CheckpointBlobRequest::Pull { header, .. } | CheckpointBlobRequest::Ack { header, .. }
        | CheckpointBlobRequest::Release { header, .. } => (header, NativeChannel::View),
    };
    if channel.kind() != kind { return Err(ChannelError::WrongChannel); }
    match channel.exchange(request, header, |reply| match reply {
        CheckpointBlobReply::Result { header, .. } | CheckpointBlobReply::ProtocolError { header, .. } => header,
    }, deadline)? {
        CheckpointBlobReply::Result { result, .. } => Ok(result),
        CheckpointBlobReply::ProtocolError { error, .. } => Err(ChannelError::Native(error)),
    }
}
