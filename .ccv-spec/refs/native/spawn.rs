use super::channel::{Channel, ChannelError};
#[path = "checkpoint.rs"]
mod checkpoint;
#[path = "state_operations.rs"]
mod state_operations;
pub use state_operations::{RegisteredStateOperation, StateOperationRegistration};
#[path = "end_scope.rs"]
mod end_scope;
pub use end_scope::{EndScopeRegistration, RegisteredEndScope};
#[path = "interrupt.rs"]
mod interrupt;
pub use interrupt::CandidateInterrupt;
#[path = "inspection.rs"]
mod inspection;
pub use inspection::{InspectionRegistration, RegisteredInspection};
use super::frame::{write_frame, FrameError};
use crate::domain::{AppliedLimit, Domain, DomainIdentity, LimitError, StopFact};
use ccv_protocol::nativeface::{
    AckProof, AckStatus, Admission, AnyTerminal, ArgsAckStep, ArgsBeginLine, ArgsFinishOperation,
    ArgsLocateContext, ArgsOperationStatus, ArgsPullStep, ArgsRegisterBudget, ArgsSelectLine, ArgsSettleInterrupt,
    AuxTerminal, AuxValue, Completion, InitialNativeMethod, InitialPhase, KnownOrNa, NativeBudget,
    NativeEdit, NativeGroupVersion, NativeOpState, NativePurpose, NativeReply, NativeRequest, NativeResult, NativeStage, NativeTarget,
    OpBinding, PrefixCompletion, Receipt, ReceiptKey,
    ReceiptPayload, TerminalRecord,
};
use ccv_protocol::nativeface_b::{
    ArgsSourceBegin, ArgsSourceChunk, ArgsSourceFinish, Base64Src, NativeBootBinding,
    NativeBootPlatform, NativeChannelNonces, NativeSourceReply, SourceRequest, SourceResult,
};
use ccv_protocol::reply::ExecutionExtent;
use ccv_protocol::{
    compiled_protocol, encode, Digest32, EpochHeader, ExpectedPeer, Fact, Fault, Id, Limits,
    LimitsBackend, NativeChannel, NativeCompatibility, NativeHello, NativeHelloAck, RuntimeIdentity,
    TextNonEmpty, Upos, U,
};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, OsString};
use std::fs::{self, File};
use std::io::{self, Read};
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd, IntoRawFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const BOOT_FD: RawFd = 3;
const ORDINARY_FD: RawFd = 4;
const CONTROL_FD: RawFd = 5;
const SOURCE_FD: RawFd = 6;
const VIEW_FD: RawFd = 7;
const WORKTREE_ROOT_ENV: &str = "CCV_NATIVE_WORKTREE_ROOT";
const REQUIRED_CAPABILITIES: &[&str] = &[
    "checkpoint_observe_v1",
    "checkpoint_export_v1",
    "checkpoint_import_v1",
    "checkpoint_activate_v1",
    "checkpoint_blob_upload_v1",
    "checkpoint_blob_download_v1",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActualExecFile {
    pub canonical_path: String,
    pub sha256: Digest32,
    pub size: U,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExecMode {
    Native,
    Bytecode,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DriverExecIdentity {
    pub instance: Id,
    pub backend_epoch: U,
    pub manager_epoch: U,
    pub domain: DomainIdentity,
    pub exec_receipt: Id,
    pub pet_file: ActualExecFile,
    pub exec_image: ActualExecFile,
    pub mode: ExecMode,
}

#[derive(Debug)]
pub enum IdentityUnavailable {
    NotHealthy,
    Unavailable,
}

impl std::fmt::Display for IdentityUnavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotHealthy => f.write_str("native driver is not healthy"),
            Self::Unavailable => f.write_str("actual exec identity is unavailable"),
        }
    }
}

impl std::error::Error for IdentityUnavailable {}

#[derive(Debug)]
pub enum SpawnError {
    Limit(LimitError),
    Frame(FrameError),
    Channel(ChannelError),
    Protocol(Fault),
    Io(io::Error),
    Invalid(&'static str),
}

impl std::fmt::Display for SpawnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Limit(error) => write!(f, "native domain failed: {error}"),
            Self::Frame(error) => write!(f, "native boot frame failed: {error}"),
            Self::Channel(error) => write!(f, "native handshake failed: {error}"),
            Self::Protocol(error) => write!(f, "native protocol failed: {error:?}"),
            Self::Io(error) => write!(f, "native setup failed: {error}"),
            Self::Invalid(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for SpawnError {}

impl From<LimitError> for SpawnError {
    fn from(value: LimitError) -> Self {
        Self::Limit(value)
    }
}

impl From<FrameError> for SpawnError {
    fn from(value: FrameError) -> Self {
        Self::Frame(value)
    }
}

impl From<ChannelError> for SpawnError {
    fn from(value: ChannelError) -> Self {
        Self::Channel(value)
    }
}

impl From<Fault> for SpawnError {
    fn from(value: Fault) -> Self {
        Self::Protocol(value)
    }
}

impl From<io::Error> for SpawnError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

pub struct SpawnPlan {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub domain: Option<Id>,
    pub instance: Id,
    pub backend_epoch: U,
    pub manager_epoch: U,
    pub artifact: Id,
    pub environment: Id,
    pub rocq_version: TextNonEmpty,
    pub ocaml_version: TextNonEmpty,
    pub limits_backend: LimitsBackend,
    pub ordinary_capacity: Upos,
    pub input_byte_quota: Upos,
    pub view_byte_quota: Upos,
    pub startup_deadline: Duration,
}

/// D04 本地派发预期：只由本端当前派发记录填写，回复不能补齐其中任何一项。
pub struct StepExpectation<'a> {
    pub binding: &'a OpBinding,
    pub line: &'a Id,
    pub parent: &'a Id,
    pub source: &'a str,
    pub cursor: U,
    pub base_revision: U,
    pub step_seq: Upos,
    pub receipt_seq: Upos,
}

impl StepExpectation<'_> {
    fn key_matches_operation(&self, key: &ReceiptKey) -> bool {
        key.operation_id() == self.binding.operation_id()
            && key.operation_seq() == self.binding.operation_seq()
    }

    fn key_matches(&self, key: &ReceiptKey) -> bool {
        self.key_matches_operation(key) && key.receipt_seq().get() == self.receipt_seq.get()
    }

    fn contains_boundary(&self, value: &U) -> bool {
        let Ok(index) = usize::try_from(value.get()) else {
            return false;
        };
        index <= self.source.len() && self.source.is_char_boundary(index)
    }
}

pub struct NativeDriver {
    domain: Domain,
    boot: NativeBootBinding,
    ordinary: OrdinaryChannel,
    control: std::sync::Arc<std::sync::Mutex<Channel>>,
    mainline: Option<interrupt::Mainline>,
    source: Channel,
    view: Channel,
    peer_hello_acks: [NativeHelloAck; 4],
    exec_identity: Option<DriverExecIdentity>,
    quarantined: bool,
    unapplied_ack: Option<(OpBinding, AckStatus)>,
    nw02: Nw02Reservation,
    entry_budget: Option<EntryBudget>,
    state_operations: state_operations::StateOperations,
    end_scopes: end_scope::EndScopeOperations,
    inspection: inspection::InspectionOperationSlot,
    workspace_root: Option<PathBuf>,
}

/// 普通通道共用发帧守卫，包括各模块直接走的 resumable 路径。
struct OrdinaryChannel {
    channel: Channel,
    end_scope_owner: Option<(Id, U)>,
    environment: CurrentEnvironment,
}

struct CurrentEnvironment {
    id: Id,
    generation: std::sync::Arc<()>,
    refreshing: Option<ccv_protocol::nativeface::ArgsRefreshEnvironment>,
}

impl CurrentEnvironment {
    fn new(id: Id) -> Self {
        Self { id, generation: std::sync::Arc::new(()), refreshing: None }
    }

    fn require_new_work(&self, environment: &Id) -> Result<(), ChannelError> {
        if self.refreshing.is_some() || &self.id != environment { return Err(ChannelError::InvalidExpectation); }
        Ok(())
    }

    fn publish(&mut self, args: &ccv_protocol::nativeface::ArgsRefreshEnvironment, observed: &Id, changed: bool)
        -> Result<(), ChannelError> {
        if self.refreshing.as_ref() != Some(args) || &self.id != args.old_environment()
            || observed != args.new_environment() || changed != (args.old_environment() != args.new_environment()) {
            return Err(ChannelError::ReplyMismatch);
        }
        if changed {
            self.id = observed.clone();
            self.generation = std::sync::Arc::new(());
        }
        self.refreshing = None;
        Ok(())
    }
}

impl std::ops::Deref for OrdinaryChannel {
    type Target = Channel;
    fn deref(&self) -> &Channel { &self.channel }
}

impl OrdinaryChannel {
    fn check_non_n05(&self, request: &NativeRequest, sending: bool) -> Result<(), ChannelError> {
        use NativeRequest::*;
        let binding = match request {
            BeginLine { args, .. } => args.binding(),
            PullStep { args, .. } => args.binding(),
            AckStep { args, .. } => args.binding(),
            OperationStatus { args, .. } => args.binding(),
            SelectLine { args, .. } => args.binding(),
            SettleInterrupt { args, .. } => args.binding(),
            FinishOperation { args, .. } => args.binding(),
            LocateContext { args, .. } => args.binding(),
            SyncSource { args, .. } => args.binding(),
            RefreshEnvironment { args, .. } => args.binding(),
            Query { args, .. } => args.binding(),
            Inspect { args, .. } => args.binding(),
            ForkLine { args, .. } => args.binding(),
            CheckpointObserve { args, .. } => args.binding(),
            CheckpointExport { args: ccv_protocol::nativeface::ArgsCheckpointExport::Collect(args), .. } => args.binding(),
            CheckpointExport { args: ccv_protocol::nativeface::ArgsCheckpointExport::Encode(args), .. } => args.binding(),
            CheckpointImport { args, .. } => args.binding(),
            CheckpointActivate { args, .. } => args.binding(),
            RegisterBudget { args, .. } => {
                let budget = args.budget();
                return if budget.initial_request().method() == &InitialNativeMethod::EndScope
                    || self.matches_end_scope(budget.operation(), budget.operation_seq()) {
                    Err(ChannelError::InvalidExpectation)
                } else if !sending {
                    Ok(())
                } else if budget.initial_request().method() == &InitialNativeMethod::RefreshEnvironment {
                    if self.environment.refreshing.as_ref().is_some_and(|original|
                        original.binding().operation_id() == budget.operation()
                        && original.binding().operation_seq() == budget.operation_seq()
                        && original.binding().request_digest() == budget.initial_request().digest()
                        && original.binding().budget() == budget.budget()
                        && budget.environment() == &self.environment.id) { Ok(()) }
                    else { Err(ChannelError::InvalidExpectation) }
                } else { self.environment.require_new_work(budget.environment()) };
            }
            EndScope { .. } => return Err(ChannelError::InvalidExpectation),
            RetireThrough { .. } => return Ok(()),
        };
        if self.matches_end_scope(binding.operation_id(), binding.operation_seq()) {
            return Err(ChannelError::InvalidExpectation);
        }
        if !sending { return Ok(()); }
        match request {
            RefreshEnvironment { args, .. } if self.environment.refreshing.as_ref() == Some(args) => Ok(()),
            RefreshEnvironment { .. } => Err(ChannelError::InvalidExpectation),
            AckStep { .. } | OperationStatus { .. } | FinishOperation { .. } => Ok(()),
            // N07 可能执行原环境的恢复探针；换代后只允许原回执对账，不启动该探针。
            SettleInterrupt { .. } if binding.environment() == &self.environment.id => Ok(()),
            _ => self.environment.require_new_work(binding.environment()),
        }
    }

    fn matches_end_scope(&self, operation: &Id, seq: &U) -> bool {
        self.end_scope_owner.as_ref().is_some_and(|(id, original_seq)| id == operation || original_seq == seq)
    }

    fn request(&mut self, request: &NativeRequest, deadline: Instant) -> Result<NativeReply, ChannelError> {
        self.check_non_n05(request, true)?;
        self.channel.request(request, deadline)
    }

    fn request_resumable(&mut self, request: &NativeRequest, deadline: Instant, write: Instant, recovery: Instant)
        -> Result<NativeReply, ChannelError> {
        self.check_non_n05(request, true)?;
        self.channel.request_resumable(request, deadline, write, recovery)
    }

    fn drain_original(&mut self, request: &NativeRequest, deadline: Instant) -> Result<Option<NativeReply>, ChannelError> {
        // 仅原帧可排空；新派发栅栏不能丢弃已经发出的旧工作或 ACK。
        self.check_non_n05(request, false)?;
        self.channel.drain_original(request, deadline)
    }
}

struct EntryBudget {
    registered: NativeBudget,
    sent: Option<EntrySend>,
}

struct EntrySend {
    header: EpochHeader,
    source_digest: Option<Digest32>,
    recovery_deadline: Instant,
}

// 唯一未消费的 NW02 原预算；与已建立 operation 和 view 的寿命无关。
#[derive(Default)]
struct Nw02Reservation(Option<(NativeBudget, bool)>);

impl Nw02Reservation {
    fn reserve(&mut self, budget: &NativeBudget) -> Result<(), ChannelError> {
        match &self.0 {
            Some((original, _)) if original == budget => Ok(()),
            Some(_) => Err(ChannelError::InvalidExpectation),
            None => {
                self.0 = Some((budget.clone(), false));
                Ok(())
            }
        }
    }

    fn require_registered(&self, budget: &NativeBudget) -> Result<(), ChannelError> {
        if self.0.as_ref().is_some_and(|(original, confirmed)| *confirmed && original == budget) {
            Ok(())
        } else {
            Err(ChannelError::InvalidExpectation)
        }
    }

    fn registration_reply(&mut self, budget: &NativeBudget, reply: &NativeReply) -> Result<(), ChannelError> {
        let Some((original, confirmed)) = self.0.as_mut() else { return Err(ChannelError::InvalidExpectation) };
        if &*original != budget { return Err(ChannelError::InvalidExpectation); }
        match reply {
            NativeReply::Result { result: NativeResult::BudgetRegistered { budget: id, grant, grant_revision }, .. }
                if id == budget.budget() && grant == budget.grant() && grant_revision == budget.grant_revision() =>
            {
                *confirmed = true;
            }
            NativeReply::Result { result: NativeResult::PastUnavailable { operation_seq, highest_seen }, .. }
                if operation_seq == budget.operation_seq() && highest_seen >= operation_seq => self.0 = None,
            NativeReply::ProtocolError { error, .. } if error.admission() == &Admission::NotAdmitted && !*confirmed =>
                self.0 = None,
            NativeReply::ProtocolError { .. } => (),
            _ => return Err(ChannelError::ReplyMismatch),
        }
        Ok(())
    }

    fn consume(&mut self, budget: &NativeBudget) {
        if self.0.as_ref().is_some_and(|(original, _)| original == budget) {
            self.0 = None;
        }
    }

    fn establishment_rejected(reply: &NativeReply) -> bool {
        matches!(reply, NativeReply::ProtocolError { error, .. } if error.admission() == &Admission::NotAdmitted)
    }

    fn check_head(&self, request: &NativeRequest, binding: &OpBinding, method: InitialNativeMethod)
        -> Result<&NativeBudget, ChannelError>
    {
        let Some((budget, true)) = &self.0 else { return Err(ChannelError::InvalidExpectation) };
        Self::validate_head(budget, request, binding, method)?;
        Ok(budget)
    }

    fn validate_head(budget: &NativeBudget, request: &NativeRequest, binding: &OpBinding,
        method: InitialNativeMethod) -> Result<(), ChannelError>
    {
        if budget.initial_request().method() != &method
            || budget.initial_request().phase() != &InitialPhase::NotApplicable
            || !(matches!(budget.purpose(), NativePurpose::Task {})
                || method == InitialNativeMethod::EndScope
                    && matches!(budget.purpose(), NativePurpose::CheckpointControl { .. }))
            || budget.budget() != binding.budget() || budget.operation() != binding.operation_id()
            || budget.operation_seq() != binding.operation_seq() || binding.operation_seq().get() == 0
            || budget.scope() != binding.scope() || budget.source() != binding.source()
            || budget.environment() != binding.environment()
            || budget.initial_request().digest() != binding.request_digest()
            || &request.operation_digest(Limits::MESSAGE)? != binding.request_digest()
        {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(())
    }
}

impl NativeDriver {
    pub fn spawn(plan: SpawnPlan) -> Result<Self, SpawnError> {
        Self::spawn_bound(plan, None)
    }

    /// ND01：caller 持当前 AF 工作区与已核环境绑定。Rocq project 可在其下的
    /// `proof/vst`，但 NN01 的相对路径统一按注册工作区根解释。
    pub fn spawn_in_workspace(
        plan: SpawnPlan,
        workspace: &Path,
        project: &Path,
    ) -> Result<Self, SpawnError> {
        if !workspace.is_absolute()
            || workspace.to_str().is_none()
            || !project.is_absolute()
            || !project.starts_with(workspace)
            || workspace.canonicalize()?.as_path() != workspace
            || project.canonicalize()?.as_path() != project
            || !workspace.is_dir()
            || !project.is_dir()
        {
            return Err(SpawnError::Invalid("unbound Rocq workspace or project directory"));
        }
        if !plan.program.is_absolute() {
            return Err(SpawnError::Invalid("managed Pet executable must be absolute"));
        }
        Self::spawn_bound(plan, Some((workspace, project)))
    }

    fn spawn_bound(plan: SpawnPlan, workspace: Option<(&Path, &Path)>) -> Result<Self, SpawnError> {
        if plan.startup_deadline.is_zero() {
            return Err(SpawnError::Invalid("startup deadline must be positive"));
        }
        let clock_boot = clock_boot()?;
        let platform = platform()?;
        let nonces = [
            random_nonce()?,
            random_nonce()?,
            random_nonce()?,
            random_nonce()?,
        ];
        let boot = NativeBootBinding::new(
            plan.instance.clone(),
            plan.backend_epoch,
            plan.manager_epoch,
            plan.artifact.clone(),
            plan.environment.clone(),
            clock_boot,
            platform,
            NativeChannelNonces::new(
                nonces[0].clone(),
                nonces[1].clone(),
                nonces[2].clone(),
                nonces[3].clone(),
            )?,
            plan.ordinary_capacity,
            plan.input_byte_quota,
            plan.view_byte_quota,
        )?;
        let boot_bytes = encode(&boot, Limits::MESSAGE)?;

        let (mut boot_parent, boot_child) = UnixStream::pair()?;
        let (ordinary_parent, ordinary_child) = UnixStream::pair()?;
        let (control_parent, control_child) = UnixStream::pair()?;
        let (source_parent, source_child) = UnixStream::pair()?;
        let (view_parent, view_child) = UnixStream::pair()?;
        let child_fds = vec![
            boot_child.into_raw_fd(),
            ordinary_child.into_raw_fd(),
            control_child.into_raw_fd(),
            source_child.into_raw_fd(),
            view_child.into_raw_fd(),
        ];
        let parent_fds = vec![
            boot_parent.as_raw_fd(),
            ordinary_parent.as_raw_fd(),
            control_parent.as_raw_fd(),
            source_parent.as_raw_fd(),
            view_parent.as_raw_fd(),
        ];

        let mut command = Command::new(&plan.program);
        command.args(&plan.args);
        for (key, value) in &plan.env {
            command.env(key, value);
        }
        if let Some((worktree, project)) = workspace {
            command.current_dir(project).env(WORKTREE_ROOT_ENV, worktree);
        } else {
            command.env_remove(WORKTREE_ROOT_ENV);
        }
        let child_for_exec = child_fds.clone();
        let parents_for_exec = parent_fds.clone();
        unsafe {
            command.pre_exec(move || setup_child_fds(&child_for_exec, &parents_for_exec));
        }
        let mut domain = match Domain::spawn_command(command, plan.domain.clone()) {
            Ok(domain) => domain,
            Err(error) => {
                close_all(&child_fds);
                return Err(SpawnError::Limit(error));
            }
        };
        close_all(&child_fds);

        let startup_deadline = Instant::now() + plan.startup_deadline;
        let boot_write = write_frame(&mut boot_parent, &boot_bytes, startup_deadline);
        drop(boot_parent);
        if let Err(error) = boot_write {
            let _ = domain.stop(1_000);
            return Err(SpawnError::Frame(error));
        }

        let compatibility = compatibility()?;
        let runtime = RuntimeIdentity::new(
            plan.artifact.clone(),
            plan.rocq_version.clone(),
            plan.ocaml_version.clone(),
            plan.limits_backend,
        );
        let header = EpochHeader::new(
            plan.instance.clone(),
            plan.backend_epoch,
            plan.manager_epoch,
            U::new(0)?,
        );
        let mut ordinary = Channel::new(
            ordinary_parent,
            NativeChannel::Ordinary,
            plan.instance.clone(),
            plan.backend_epoch,
            plan.manager_epoch,
        );
        let mut control = Channel::new(
            control_parent,
            NativeChannel::Control,
            plan.instance.clone(),
            plan.backend_epoch,
            plan.manager_epoch,
        );
        let mut source = Channel::new(
            source_parent,
            NativeChannel::Source,
            plan.instance.clone(),
            plan.backend_epoch,
            plan.manager_epoch,
        );
        let mut view = Channel::new(
            view_parent,
            NativeChannel::View,
            plan.instance.clone(),
            plan.backend_epoch,
            plan.manager_epoch,
        );
        let handshake = |channel: &mut Channel, nonce: &Id| {
            let hello = NativeHello::new(
                header.clone(),
                channel.kind(),
                nonce.clone(),
                compatibility.clone(),
                plan.artifact.clone(),
            );
            let expected = ExpectedPeer::to_driver(
                header.clone(),
                channel.kind(),
                nonce.clone(),
                runtime.clone(),
            )?;
            channel.handshake(&hello, &expected, startup_deadline).map_err(SpawnError::Channel)
        };
        let peer_hello_acks = (|| -> Result<_, SpawnError> {
            Ok([
                handshake(&mut ordinary, &nonces[0])?,
                handshake(&mut control, &nonces[1])?,
                handshake(&mut source, &nonces[2])?,
                handshake(&mut view, &nonces[3])?,
            ])
        })()
        .inspect_err(|_| {
            let _ = domain.stop(1_000);
        })?;

        let exec_identity = observe_exec_identity(
            &domain,
            &plan.instance,
            plan.backend_epoch,
            plan.manager_epoch,
        );
        Ok(Self {
            domain,
            ordinary: OrdinaryChannel { channel: ordinary, end_scope_owner: None,
                environment: CurrentEnvironment::new(boot.environment().clone()) },
            boot,
            control: std::sync::Arc::new(std::sync::Mutex::new(control)),
            mainline: None,
            source,
            view,
            peer_hello_acks,
            exec_identity,
            quarantined: false,
            unapplied_ack: None,
            nw02: Nw02Reservation::default(),
            entry_budget: None,
            state_operations: state_operations::StateOperations::new(),
            end_scopes: end_scope::EndScopeOperations::default(),
            inspection: inspection::InspectionOperationSlot::default(),
            workspace_root: workspace.map(|(root, _)| root.to_owned()),
        })
    }

    pub fn upload_source(
        &mut self,
        source: &Id,
        bytes: &[u8],
        deadline: Instant,
    ) -> Result<U, ChannelError> {
        if self.quarantined {
            return Err(ChannelError::Failed);
        }
        let size = U::new(i64::try_from(bytes.len()).map_err(|_| Fault::Constraint)?)?;
        let digest = Digest32::from_bytes(Sha256::digest(bytes).into());
        let header = self.source.next_header()?;
        let begin = SourceRequest::Begin {
            header,
            args: ArgsSourceBegin::new(source.clone(), size, digest)?,
        };
        let mut offset = match self.exchange_source(&begin, deadline)? {
            NativeSourceReply::Result {
                result: SourceResult::Begun { source: actual, next_offset },
                ..
            } if &actual == source && next_offset <= size => next_offset.get() as usize,
            NativeSourceReply::ProtocolError { error, .. } => {
                return Err(ChannelError::Native(error))
            }
            NativeSourceReply::Result {
                result: SourceResult::Registered { source: actual, size: confirmed, digest: confirmed_digest },
                ..
            } if &actual == source && confirmed == size && confirmed_digest == digest => return Ok(size),
            NativeSourceReply::Result { .. } => return self.bad_source_reply(),
        };
        while offset < bytes.len() {
            let end = offset.saturating_add(8192).min(bytes.len());
            let chunk = &bytes[offset..end];
            let encoded = base64(chunk);
            let header = self.source.next_header()?;
            let expected_offset = U::new(offset as i64)?;
            let expected_end = U::new(end as i64)?;
            let expected_digest = Digest32::sha256(chunk);
            let request = SourceRequest::Chunk {
                header,
                args: ArgsSourceChunk::new(
                    source.clone(),
                    expected_offset,
                    Base64Src::new(encoded)?,
                )?,
            };
            offset = match self.exchange_source(&request, deadline)? {
                NativeSourceReply::Result {
                    result: SourceResult::ChunkAck { source: actual, offset: start, end_offset, digest },
                    ..
                } if &actual == source && start == expected_offset && end_offset == expected_end
                    && digest == expected_digest => end,
                NativeSourceReply::Result {
                    result: SourceResult::RetiredChunk { source: actual, next_offset },
                    ..
                } if &actual == source && expected_end <= next_offset && next_offset <= size => {
                    // 只接受旧块的水位事实；最终仍必须核原完整材料。
                    next_offset.get() as usize
                }
                NativeSourceReply::ProtocolError { error, .. } => {
                    return Err(ChannelError::Native(error))
                }
                NativeSourceReply::Result { .. } => return self.bad_source_reply(),
            };
        }
        let header = self.source.next_header()?;
        let finish = SourceRequest::Finish {
            header,
            args: ArgsSourceFinish::new(source.clone())?,
        };
        match self.exchange_source(&finish, deadline)? {
            NativeSourceReply::Result {
                result: SourceResult::Registered { source: actual, size: confirmed, digest: confirmed_digest },
                ..
            } if &actual == source && confirmed == size && confirmed_digest == digest => Ok(size),
            NativeSourceReply::ProtocolError { error, .. } => Err(ChannelError::Native(error)),
            NativeSourceReply::Result { .. } => self.bad_source_reply(),
        }
    }

    fn exchange_source(&mut self, request: &SourceRequest, deadline: Instant) -> Result<NativeSourceReply, ChannelError> {
        let reply = self.source.source_request(request, deadline);
        if self.source.failed() {
            self.quarantine();
        }
        reply
    }

    fn bad_source_reply<T>(&mut self) -> Result<T, ChannelError> {
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }

    pub fn register_budget(
        &mut self,
        budget: NativeBudget,
        applied_grant: Id,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if matches!(budget.initial_request().method(), InitialNativeMethod::ForkLine
            | InitialNativeMethod::SyncSource | InitialNativeMethod::RefreshEnvironment
            | InitialNativeMethod::Query | InitialNativeMethod::Inspect | InitialNativeMethod::EndScope) {
            return Err(ChannelError::InvalidExpectation);
        }
        let checkpoint = matches!(budget.purpose(), NativePurpose::CheckpointControl { .. });
        let entry = matches!(budget.purpose(), NativePurpose::Task {})
            && matches!(budget.initial_request().method(), InitialNativeMethod::LocateContext | InitialNativeMethod::SelectLine);
        if entry {
            self.require_no_unapplied_ack()?;
        }
        if checkpoint && (budget.grant() != &applied_grant
                || !self.domain.verify_applied_limit().is_ok_and(|actual| &actual.grant == budget.grant()
                    && actual.revision.get().checked_add(1) == Some(budget.grant_revision().get()))) {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        if entry && (budget.grant() != &applied_grant || budget.clock_boot() != self.boot.clock_boot()
            || budget.environment() != self.current_environment()
            || budget.recovery_deadline_us() < budget.execution_deadline_us()
            || budget.initial_request().phase() != &InitialPhase::NotApplicable
            || self.entry_budget.as_ref().is_some_and(|old| {
                old.registered.operation_seq() >= budget.operation_seq() && old.registered != budget
            })) {
            return Err(ChannelError::InvalidExpectation);
        }
        let args = ArgsRegisterBudget::new(budget.clone(), applied_grant)?;
        let reply = self.native_result(&NativeRequest::RegisterBudget { header, args }, deadline)?;
        if entry && matches!(&reply, NativeResult::BudgetRegistered { .. })
            && self.entry_budget.as_ref().is_none_or(|old| old.registered != budget) {
            self.entry_budget = Some(EntryBudget { registered: budget, sent: None });
        }
        Ok(reply)
    }

    pub fn begin_line(
        &mut self,
        binding: ccv_protocol::nativeface::OpBinding,
        line: Id,
        expected_revision: U,
        source: Id,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.state_operations.blocks_mainline(&binding, &line) || self.mainline.is_some() {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        let args = ArgsBeginLine::new(
            binding,
            line,
            expected_revision,
            NativeEdit::Append {},
            source,
        )?;
        let request = NativeRequest::BeginLine { header, args };
        let NativeRequest::BeginLine { args, .. } = &request else { unreachable!() };
        let budget = self.nw02.check_head(&request, args.binding(), InitialNativeMethod::BeginLine)?.clone();
        if budget.clock_boot() != self.boot.clock_boot() || budget.execution_deadline_us() > budget.recovery_deadline_us()
            || args.script_source() != args.binding().source() {
            return Err(ChannelError::InvalidExpectation);
        }
        let deadline = deadline.min(checkpoint::absolute_deadline(*budget.execution_deadline_us())?);
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let result = self.native_result(&request, deadline)?;
        if result_has_step_group(&result) {
            self.quarantine();
            return Err(ChannelError::ReplyMismatch);
        }
        match &result {
            NativeResult::Status { status } => {
                self.mainline = Some(interrupt::Mainline::from_ready(args, budget, status).inspect_err(|_| self.quarantine())?);
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if operation_seq == args.binding().operation_seq() && highest_seen >= operation_seq => self.quarantine(),
            _ => { self.quarantine(); return Err(ChannelError::ReplyMismatch); }
        }
        Ok(result)
    }

    /// W02: bind the complete initial request before NW02; only rpc_seq and
    /// the provisional digest itself are excluded. This does not send a frame.
    pub fn bind_begin_line(
        &self,
        provisional: &OpBinding,
        line: &Id,
        expected_revision: U,
    ) -> Result<OpBinding, ChannelError> {
        if self.state_operations.blocks_mainline(provisional, line) {
            return Err(ChannelError::InvalidExpectation);
        }
        self.bind_begin_line_request(provisional, line, expected_revision)
    }

    fn bind_begin_line_request(
        &self,
        provisional: &OpBinding,
        line: &Id,
        expected_revision: U,
    ) -> Result<OpBinding, ChannelError> {
        let request = NativeRequest::BeginLine {
            header: self.next_header()?,
            args: ArgsBeginLine::new(
                provisional.clone(),
                line.clone(),
                expected_revision,
                NativeEdit::Append {},
                provisional.source().clone(),
            )?,
        };
        Ok(OpBinding::new(
            provisional.operation_id().clone(),
            *provisional.operation_seq(),
            request.operation_digest(Limits::MESSAGE)?,
            provisional.context().clone(),
            provisional.scope().clone(),
            provisional.source().clone(),
            provisional.environment().clone(),
            provisional.budget().clone(),
        )?)
    }

    /// NN01：只返回与原定位操作相符的事实；MS27/PS11 仍是入口的唯一登记者。
    /// `source` 是调用方已持久并上传的原 `binding.source` 字节。
    pub fn locate_context(
        &mut self,
        args: ArgsLocateContext,
        source: &str,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.workspace_root.is_none() {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        let request = NativeRequest::LocateContext { header, args };
        let NativeRequest::LocateContext { header, args } = &request else {
            unreachable!()
        };
        // Step P2: 用 W02 通用前像校验完整 initial request，不信任单独的目标参数。
        if &request.operation_digest(Limits::MESSAGE)? != args.binding().request_digest()
            || matches!(args.expected_context(), KnownOrNa::Known(v) if v.id() != args.binding().context())
        {
            return Err(ChannelError::InvalidExpectation);
        }
        let result = self.send_entry(&request, Some(Digest32::sha256(source.as_bytes())), deadline)?;
        if let Err(error) = validate_locate_reply(header, args, source, &result) {
            self.quarantine();
            return Err(error);
        }
        self.consume_entry_budget(&request);
        Ok(result)
    }

    /// W02：将完整 NN01 请求（含受管相对路径）绑定到预算，不发送请求。
    pub fn bind_locate_context(
        &self,
        args: &ArgsLocateContext,
    ) -> Result<ArgsLocateContext, ChannelError> {
        if self.workspace_root.is_none() {
            return Err(ChannelError::InvalidExpectation);
        }
        let request = NativeRequest::LocateContext { header: self.next_header()?, args: args.clone() };
        let provisional = args.binding();
        let binding = OpBinding::new(
            provisional.operation_id().clone(),
            *provisional.operation_seq(),
            request.operation_digest(Limits::MESSAGE)?,
            provisional.context().clone(),
            provisional.scope().clone(),
            provisional.source().clone(),
            provisional.environment().clone(),
            provisional.budget().clone(),
        )?;
        Ok(ArgsLocateContext::new(
            binding, args.file().clone(), args.relative_file().clone(), args.target().clone(),
            args.logical_target().clone(), args.lineage().clone(), args.expected_context().clone(),
        )?)
    }

    /// W02：采用意图绑定目的线、原生修订、候选节点和 PS11 已登记路径。
    pub fn bind_select_line(&self, args: &ArgsSelectLine) -> Result<ArgsSelectLine, ChannelError> {
        if self.workspace_root.is_none() || args.group() != &KnownOrNa::NotApplicable {
            return Err(ChannelError::InvalidExpectation);
        }
        let old = args.binding();
        let request = NativeRequest::SelectLine { header: self.next_header()?, args: args.clone() };
        let binding = OpBinding::new(
            old.operation_id().clone(), *old.operation_seq(), request.operation_digest(Limits::MESSAGE)?,
            old.context().clone(), old.scope().clone(), old.source().clone(), old.environment().clone(), old.budget().clone(),
        )?;
        Ok(ArgsSelectLine::new(binding, args.destination().clone(), *args.expected_revision(),
            args.candidate().clone(), KnownOrNa::NotApplicable, args.durable_path().clone())?)
    }

    pub fn select_line(&mut self, args: &ArgsSelectLine, deadline: Instant) -> Result<Option<Receipt>, ChannelError> {
        self.require_no_unapplied_ack()?;
        if &self.bind_select_line(args)? != args {
            return Err(ChannelError::InvalidExpectation);
        }
        let request = NativeRequest::SelectLine { header: self.next_header()?, args: args.clone() };
        let result = self.send_entry(&request, None, deadline)?;
        let checked = self.checked_selection_reply(args, result)?;
        self.consume_entry_budget(&request);
        Ok(checked)
    }

    fn checked_selection_reply(&mut self, args: &ArgsSelectLine, result: NativeResult) -> Result<Option<Receipt>, ChannelError> {
        match result {
            NativeResult::Receipt { receipt } if validate_entry_selection(args, &receipt) => Ok(Some(receipt)),
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if &operation_seq == args.binding().operation_seq() && highest_seen >= operation_seq => Ok(None),
            _ => {
                self.quarantine();
                Err(ChannelError::ReplyMismatch)
            }
        }
    }

    /// 对账只读取原 N04；不会再采用或执行。
    pub fn select_line_status(&mut self, args: &ArgsSelectLine, deadline: Instant) -> Result<Option<Receipt>, ChannelError> {
        self.require_no_unapplied_ack()?;
        let (header, deadline) = self.entry_recovery(None, deadline)?;
        let request = NativeRequest::SelectLine { header, args: args.clone() };
        if let Some(result) = self.drain_entry(&request, deadline)? {
            let checked = self.checked_selection_reply(args, result)?;
            self.consume_entry_budget(&request);
            return Ok(checked);
        }
        let binding = args.binding();
        match self.operation_status(binding.clone(), deadline)? {
            NativeResult::Status { status } if status.binding() == binding
                && status.state() == &NativeOpState::Terminal && status.acked_through().get() == 0
                && status.retired_through() < binding.operation_seq() && status.highest_seen() >= binding.operation_seq()
                && status.pending() == &Fact::NotApplicable && status.last_ack() == &Fact::NotApplicable =>
            {
                if let Fact::Known(AnyTerminal::Terminal(TerminalRecord::Receipt { receipt })) = status.terminal() {
                    if validate_entry_selection(args, receipt) {
                        self.consume_entry_budget(&request);
                        return Ok(Some(receipt.clone()));
                    }
                }
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if &operation_seq == binding.operation_seq() && highest_seen >= operation_seq =>
            {
                self.consume_entry_budget(&request);
                return Ok(None);
            }
            _ => {}
        }
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }

    pub fn pull_step(
        &mut self,
        expected: &StepExpectation<'_>,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.pull_paired_step(expected, None, deadline)
    }

    /// 只有已登记正式文件前缀的调用点携带原 NN01 目标；普通 append 拒绝此终态。
    pub fn pull_open_prefix_step(
        &mut self,
        expected: &StepExpectation<'_>,
        target: &Id,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if self.workspace_root.is_none() {
            return Err(ChannelError::InvalidExpectation);
        }
        self.pull_paired_step(expected, Some(target), deadline)
    }

    fn pull_paired_step(
        &mut self,
        expected: &StepExpectation<'_>,
        target: Option<&Id>,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.state_operations.blocks_mainline(expected.binding, expected.line) {
            return Err(ChannelError::InvalidExpectation);
        }
        // Step P1: 请求只由本地代际/序号与已登记预期构造；不经公开裸请求入口。
        if !expected.contains_boundary(&expected.cursor) {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        let args = ArgsPullStep::new(expected.binding.clone(), expected.step_seq)?;
        let request = NativeRequest::PullStep { header, args };
        let reply = self.exchange_mainline_step(expected, &request, deadline)?;
        let result = match reply {
            NativeReply::Result { result, .. } => result,
            NativeReply::ProtocolError { error, .. } => return Err(ChannelError::Native(error)),
        };
        // Step P2: 成功步骤/原终态/对账水位逐项对本地预期；失配不得提供继续执行的事实。
        if let Err(error) = validate_pull_reply(expected, target, &result) {
            self.quarantine();
            return Err(error);
        }
        self.observe_mainline_step(expected, &result)?;
        Ok(result)
    }

    pub fn ack_step(
        &mut self,
        expected: &StepExpectation<'_>,
        proof: AckProof,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.state_operations.blocks_mainline(expected.binding, expected.line) {
            return Err(ChannelError::InvalidExpectation);
        }
        // Step P1: ACK key先核原操作/回执序号；无效预期本地拒绝，不触达通道。
        if !expected.key_matches(proof.receipt())
            || expected
                .base_revision
                .get()
                .checked_add(1)
                .and_then(|n| U::new(n).ok())
                .is_none()
        {
            return Err(ChannelError::InvalidExpectation);
        }
        let header = self.next_header()?;
        let args = ArgsAckStep::new(expected.binding.clone(), proof.clone())?;
        let request = NativeRequest::AckStep { header, args };
        let reply = self.exchange_mainline_step(expected, &request, deadline)?;
        let result = match reply {
            NativeReply::Result { result, .. } => result,
            NativeReply::ProtocolError { error, .. } => return Err(ChannelError::Native(error)),
        };
        // Step P3: ACK只认发出的完整key/line/revision/seq；对账分支不算原ACK已应用。
        if let Err(error) = validate_ack_reply(expected, &proof, &result, None) {
            self.quarantine();
            return Err(error);
        }
        self.observe_mainline_step(expected, &result)?;
        Ok(result)
    }

    fn require_no_unapplied_ack(&self) -> Result<(), ChannelError> {
        if self.unapplied_ack.is_some() {
            Err(ChannelError::AwaitingAckEffect)
        } else {
            Ok(())
        }
    }

    /// 已收到原生 ACK；相关 SQLite 应用事实明确提交前，不允许继续解释。
    pub fn retain_ack_for_commit(
        &mut self,
        binding: &OpBinding,
        ack: &AckStatus,
    ) -> Result<(), ChannelError> {
        if self.state_operations.owns_candidate(binding) || ack.group() != &KnownOrNa::NotApplicable {
            return Err(ChannelError::InvalidExpectation);
        }
        if self.unapplied_ack.as_ref().is_some_and(|(original, saved)| original == binding && saved == ack) {
            return Ok(());
        }
        self.retain_checked_ack(binding, ack)
    }

    fn retain_checked_ack(&mut self, binding: &OpBinding, ack: &AckStatus) -> Result<(), ChannelError> {
        self.require_no_unapplied_ack()?;
        self.unapplied_ack = Some((binding.clone(), ack.clone()));
        Ok(())
    }

    pub fn confirm_ack_commit(
        &mut self,
        binding: &OpBinding,
        ack: &AckStatus,
    ) -> Result<(), ChannelError> {
        match &self.unapplied_ack {
            Some((expected_binding, expected))
                if expected_binding == binding && expected == ack =>
            {
                self.unapplied_ack = None;
                Ok(())
            }
            None => Ok(()),
            _ => Err(ChannelError::AwaitingAckEffect),
        }
    }

    /// D02：只在旧完整 ACK 已读完、同操作仍可读时，对账原事实；不重发 eval 或 ACK。
    pub fn reconcile_retained_ack(
        &mut self,
        binding: &OpBinding,
        proof: &AckProof,
        deadline: Instant,
    ) -> Result<Option<AckStatus>, ChannelError> {
        let Some((owner, ack)) = self.unapplied_ack.clone() else {
            return Ok(None);
        };
        if &owner != binding || ack.receipt() != proof.receipt() {
            return Err(ChannelError::AwaitingAckEffect);
        }
        let deadline = if matches!(ack.group(), KnownOrNa::Known(_)) {
            let deadline = deadline.min(self.state_operations.candidate_recovery_deadline(binding)?);
            if Instant::now() >= deadline {
                return Err(FrameError::Timeout.into());
            }
            deadline
        } else if let Some(run) = &self.mainline {
            if &run.binding != binding { return Err(ChannelError::InvalidExpectation); }
            deadline.min(run.recovery()?)
        } else {
            deadline
        };
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        match self.read_operation_status(binding.clone(), deadline)? {
            NativeResult::Status { status }
                if status.binding() == binding
                    && status.retired_through() < binding.operation_seq()
                    && status.highest_seen() >= binding.operation_seq()
                    && status.acked_through() == ack.acked_through()
                    && status.last_ack() == &Fact::Known(ack.clone()) =>
            {
                Ok(Some(ack))
            }
            NativeResult::PastUnavailable { .. } => Err(ChannelError::AwaitingAckEffect),
            _ => {
                self.quarantine();
                Err(ChannelError::ReplyMismatch)
            }
        }
    }

    pub fn operation_status(
        &mut self,
        binding: ccv_protocol::nativeface::OpBinding,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if self.state_operations.owns_candidate(&binding) || self.state_operations.owns_source_sync(&binding)
            || self.end_scopes.owns_binding(&binding) || self.inspection.owns_binding(&binding)
            || self.mainline.as_ref().is_some_and(|run| run.matches(&binding)) {
            return Err(ChannelError::InvalidExpectation);
        }
        let result = self.read_operation_status(binding, deadline)?;
        if result_has_step_group(&result) {
            self.quarantine();
            return Err(ChannelError::ReplyMismatch);
        }
        Ok(result)
    }

    fn read_operation_status(&mut self, binding: OpBinding, deadline: Instant) -> Result<NativeResult, ChannelError> {
        let header = self.next_header()?;
        let args = ArgsOperationStatus::new(binding)?;
        self.native_result(&NativeRequest::OperationStatus { header, args }, deadline)
    }

    /// D02：已排空普通通道，只读同一前缀的已保存终态和原 ACK 水位。
    pub fn open_prefix_terminal_status(
        &mut self,
        expected: &StepExpectation<'_>,
        target: &Id,
        last_ack: &Fact<AckStatus>,
        deadline: Instant,
    ) -> Result<Option<TerminalRecord>, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.workspace_root.is_none() || !expected.contains_boundary(&expected.cursor) {
            return Err(ChannelError::InvalidExpectation);
        }
        let result = if let Some(run) = &self.mainline {
            if let Some(terminal) = run.prefix_terminal(expected, target) { return Ok(Some(terminal)); }
            if !run.permits_prefix_observation(expected) { return Err(ChannelError::InvalidExpectation); }
            let deadline = deadline.min(run.recovery()?);
            if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
            self.read_operation_status(expected.binding.clone(), deadline)?
        } else { self.operation_status(expected.binding.clone(), deadline)? };
        match result {
            NativeResult::Status { status }
                if status.binding() == expected.binding
                    && status.retired_through() < expected.binding.operation_seq()
                    && status.highest_seen() >= expected.binding.operation_seq() =>
            {
                if status.state() != &NativeOpState::Terminal {
                    if !matches!(status.terminal(), Fact::Known(_)) {
                        return Ok(None);
                    }
                } else if status.pending() == &Fact::NotApplicable
                    && status.acked_through().get() == expected.step_seq.get() - 1
                    && status.last_ack() == last_ack
                {
                    if let Fact::Known(AnyTerminal::Terminal(terminal)) = status.terminal() {
                        if validate_terminal(expected, Some(target), terminal, None).is_ok() {
                            self.observe_mainline_step(expected, &NativeResult::Terminal { terminal: terminal.clone() })?;
                            return Ok(Some(terminal.clone()));
                        }
                    }
                }
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if validate_past_unavailable(expected, &operation_seq, &highest_seen).is_ok() =>
            {
                return Ok(None);
            }
            _ => {}
        }
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }

    /// N07 重读已保存的前缀终态时沿用原配对，不能把 settle 当作到达目标的证据。
    pub fn settle_open_prefix_terminal(
        &mut self,
        expected: &StepExpectation<'_>,
        target: &Id,
        deadline: Instant,
    ) -> Result<Option<TerminalRecord>, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.workspace_root.is_none() || !expected.contains_boundary(&expected.cursor)
            || self.state_operations.blocks_mainline(expected.binding, expected.line)
            || self.inspection.owns_binding(expected.binding) {
            return Err(ChannelError::InvalidExpectation);
        }
        if let Some(run) = &self.mainline {
            if let Some(terminal) = run.prefix_terminal(expected, target) { return Ok(Some(terminal)); }
            if !run.permits_prefix_observation(expected) { return Err(ChannelError::InvalidExpectation); }
        }
        let deadline = if let Some(run) = &self.mainline { deadline.min(run.recovery()?) } else { deadline };
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let request = NativeRequest::SettleInterrupt {
            header: self.next_header()?,
            args: ArgsSettleInterrupt::new(expected.binding.clone())?,
        };
        let result = self.native_result(&request, deadline)?;
        match result {
            NativeResult::Terminal { terminal } if validate_terminal(expected, Some(target), &terminal, None).is_ok() => {
                self.observe_mainline_step(expected, &NativeResult::Terminal { terminal: terminal.clone() })?;
                Ok(Some(terminal))
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if validate_past_unavailable(expected, &operation_seq, &highest_seen).is_ok() => Ok(None),
            _ => {
                self.quarantine();
                Err(ChannelError::ReplyMismatch)
            }
        }
    }

    /// D02：先收原 NN01 帧，已排空时才查原记录；两路均重核终态及字节边界。
    pub fn locate_context_status(
        &mut self,
        args: &ArgsLocateContext,
        source: &str,
        deadline: Instant,
    ) -> Result<Option<AuxTerminal>, ChannelError> {
        self.require_no_unapplied_ack()?;
        let (header, deadline) = self.entry_recovery(Some(Digest32::sha256(source.as_bytes())), deadline)?;
        let request = NativeRequest::LocateContext { header: header.clone(), args: args.clone() };
        if let Some(result) = self.drain_entry(&request, deadline)? {
            if let Err(error) = validate_locate_reply(&header, args, source, &result) {
                self.quarantine();
                return Err(error);
            }
            self.consume_entry_budget(&request);
            return Ok(match result {
                NativeResult::AuxTerminal { terminal } => Some(terminal),
                _ => None, // 原帧中的 PastUnavailable；不猜测执行结果。
            });
        }
        let binding = args.binding();
        let result = self.operation_status(binding.clone(), deadline)?;
        match result {
            NativeResult::Status { status }
                if status.binding() == binding
                    && status.state() == &NativeOpState::Terminal
                    && status.pending() == &Fact::NotApplicable
                    && status.last_ack() == &Fact::NotApplicable
                    && status.acked_through().get() == 0
                    && status.retired_through() < binding.operation_seq()
                    && binding.operation_seq() <= status.highest_seen() =>
            {
                if let Fact::Known(AnyTerminal::Aux(terminal)) = status.terminal() {
                    if validate_locate_terminal(&header, args, source, terminal).is_ok() {
                        self.consume_entry_budget(&request);
                        return Ok(Some(terminal.clone()));
                    }
                }
            }
            NativeResult::PastUnavailable { operation_seq, highest_seen }
                if &operation_seq == binding.operation_seq() && highest_seen >= operation_seq =>
            {
                self.consume_entry_budget(&request);
                return Ok(None);
            }
            _ => {}
        }
        self.quarantine();
        Err(ChannelError::ReplyMismatch)
    }

    pub fn finish_operation(
        &mut self,
        binding: ccv_protocol::nativeface::OpBinding,
        terminal_receipt_key: ccv_protocol::nativeface::ReceiptKey,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        self.require_no_unapplied_ack()?;
        if self.inspection.owns_binding(&binding) || self.state_operations.owns_candidate(&binding)
            || self.state_operations.owns_source_sync(&binding)
            || self.end_scopes.owns_binding(&binding) {
            return Err(ChannelError::InvalidExpectation);
        }
        let tracked = self.mainline.as_ref().filter(|run| run.matches(&binding));
        let deadline = if let Some(run) = tracked {
            if run.binding != binding || run.terminal.as_ref() != Some(&terminal_receipt_key) || run.in_flight.is_some() {
                return Err(ChannelError::InvalidExpectation);
            }
            deadline.min(run.recovery()?)
        } else { deadline };
        if Instant::now() >= deadline { return Err(FrameError::Timeout.into()); }
        let header = self.next_header()?;
        let args = ArgsFinishOperation::new(binding.clone(), terminal_receipt_key.clone())?;
        let result = self.native_result(&NativeRequest::FinishOperation { header, args }, deadline)?;
        if self.mainline.as_ref().is_some_and(|run| run.binding == binding)
            && matches!(&result, NativeResult::Finished { key } if key == &terminal_receipt_key) { self.mainline = None; }
        Ok(result)
    }

    fn native_result(
        &mut self,
        request: &NativeRequest,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        Self::reply_result(self.exchange(request, deadline)?)
    }

    fn registered_entry(&self, request: &NativeRequest) -> Result<&EntryBudget, ChannelError> {
        let (binding, method) = match request {
            NativeRequest::LocateContext { args, .. } => (args.binding(), InitialNativeMethod::LocateContext),
            NativeRequest::SelectLine { args, .. } => (args.binding(), InitialNativeMethod::SelectLine),
            _ => return Err(ChannelError::InvalidExpectation),
        };
        let entry = self.entry_budget.as_ref().ok_or(ChannelError::InvalidExpectation)?;
        let budget = &entry.registered;
        if budget.initial_request().method() != &method
            || budget.budget() != binding.budget()
            || budget.operation() != binding.operation_id()
            || budget.operation_seq() != binding.operation_seq()
            || budget.scope() != binding.scope()
            || budget.source() != binding.source()
            || budget.environment() != binding.environment()
            || budget.initial_request().digest() != binding.request_digest()
            || &request.operation_digest(Limits::MESSAGE)? != binding.request_digest()
        {
            return Err(ChannelError::InvalidExpectation);
        }
        Ok(entry)
    }

    fn send_entry(
        &mut self,
        request: &NativeRequest,
        source_digest: Option<Digest32>,
        deadline: Instant,
    ) -> Result<NativeResult, ChannelError> {
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        let entry = self.registered_entry(request)?;
        self.nw02.require_registered(&entry.registered)?;
        if entry.sent.is_some() {
            return Err(ChannelError::InvalidExpectation);
        }
        let budget = entry.registered.clone();
        let execution = checkpoint::absolute_deadline(*budget.execution_deadline_us())?;
        let recovery = checkpoint::absolute_deadline(*entry.registered.recovery_deadline_us())?;
        // D02 不持新执行票：原调用的可写窗口结束后，只允许读已完整发送的请求。
        let write_deadline = deadline.min(execution);
        let reply = self.ordinary.request_resumable(request, deadline, write_deadline, recovery);
        if reply.is_ok() || self.ordinary.pending_header() == Some(request.header()) {
            self.entry_budget.as_mut().expect("registered entry").sent = Some(EntrySend {
                header: request.header().clone(),
                source_digest,
                recovery_deadline: recovery,
            });
        }
        if self.ordinary.failed() {
            self.quarantine();
        }
        let reply = reply?;
        if Nw02Reservation::establishment_rejected(&reply) { self.nw02.consume(&budget); }
        Self::reply_result(reply)
    }

    fn entry_recovery(
        &self,
        source_digest: Option<Digest32>,
        deadline: Instant,
    ) -> Result<(EpochHeader, Instant), ChannelError> {
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        let sent = self.entry_budget.as_ref().and_then(|entry| entry.sent.as_ref())
            .ok_or(ChannelError::InvalidExpectation)?;
        if source_digest != sent.source_digest {
            return Err(ChannelError::InvalidExpectation);
        }
        let deadline = deadline.min(sent.recovery_deadline);
        if Instant::now() >= deadline {
            return Err(FrameError::Timeout.into());
        }
        Ok((sent.header.clone(), deadline))
    }

    fn drain_entry(&mut self, original: &NativeRequest, deadline: Instant) -> Result<Option<NativeResult>, ChannelError> {
        let budget = self.registered_entry(original)?.registered.clone();
        let reply = self.ordinary.drain_original(original, deadline);
        if self.ordinary.failed() {
            self.quarantine();
        }
        let reply = reply?;
        if reply.as_ref().is_some_and(Nw02Reservation::establishment_rejected) { self.nw02.consume(&budget); }
        reply.map(Self::reply_result).transpose()
    }

    fn consume_entry_budget(&mut self, request: &NativeRequest) {
        if let Ok(entry) = self.registered_entry(request) {
            let budget = entry.registered.clone();
            self.nw02.consume(&budget);
        }
    }

    fn reply_result(reply: NativeReply) -> Result<NativeResult, ChannelError> {
        match reply {
            NativeReply::Result { result, .. } => Ok(result),
            NativeReply::ProtocolError { error, .. } => Err(ChannelError::Native(error)),
        }
    }

    fn exchange(
        &mut self,
        request: &NativeRequest,
        deadline: Instant,
    ) -> Result<NativeReply, ChannelError> {
        if self.is_quarantined() {
            return Err(ChannelError::Failed);
        }
        self.ordinary.check_non_n05(request, true)?;
        let initial = match request {
            NativeRequest::BeginLine { args, .. } => {
                if self.state_operations.blocks_mainline(args.binding(), args.line()) {
                    return Err(ChannelError::InvalidExpectation);
                }
                Some((args.binding(), InitialNativeMethod::BeginLine))
            }
            NativeRequest::SelectLine { args, .. } => Some((args.binding(), InitialNativeMethod::SelectLine)),
            NativeRequest::EndScope { .. } => return Err(ChannelError::InvalidExpectation),
            _ => None,
        };
        let budget = initial.map(|(binding, method)| self.nw02.check_head(request, binding, method).cloned()).transpose()?;
        if let NativeRequest::RegisterBudget { args, .. } = request {
            if request.header() != &self.next_header()? || args.applied_grant() != args.budget().grant() {
                return Err(ChannelError::InvalidExpectation);
            }
            let budget = args.budget();
            if budget.initial_request().method() == &InitialNativeMethod::EndScope
                || self.state_operations.owns_candidate_operation(budget.operation(), budget.operation_seq()) {
                return Err(ChannelError::InvalidExpectation);
            }
            if matches!(budget.purpose(), NativePurpose::CheckpointControl { .. })
                && !self.domain.verify_applied_limit().is_ok_and(|actual| &actual.grant == budget.grant()
                    && actual.revision.get().checked_add(1) == Some(budget.grant_revision().get()))
            {
                return Err(ChannelError::InvalidExpectation);
            }
            self.nw02.reserve(args.budget())?;
        }
        let reply = self.ordinary.request(request, deadline);
        if self.ordinary.failed() {
            self.quarantine();
        }
        let reply = reply?;
        if let NativeRequest::RegisterBudget { args, .. } = request {
            if let Err(error) = self.nw02.registration_reply(args.budget(), &reply) {
                self.quarantine();
                return Err(error);
            }
        }
        if let Some(budget) = &budget {
            let consumed = match (request, &reply) {
                (NativeRequest::BeginLine { args, .. }, NativeReply::Result {
                    result: NativeResult::Status { status }, ..
                }) => status.binding() == args.binding()
                    && status.retired_through() < budget.operation_seq()
                    && status.highest_seen() >= budget.operation_seq(),
                (NativeRequest::SelectLine { args, .. }, NativeReply::Result {
                    result: NativeResult::Receipt { receipt }, ..
                }) => validate_entry_selection(args, receipt),
                _ => definitive_nw02_disposition(&reply, budget),
            };
            if consumed { self.nw02.consume(budget); }
        }
        Ok(reply)
    }

    pub fn boot(&self) -> &NativeBootBinding {
        &self.boot
    }

    /// 已确认安装的环境；刷新未决时保留旧值，不能据此推断可派发。
    pub fn current_environment(&self) -> &Id {
        &self.ordinary.environment.id
    }

    pub fn environment_refresh_pending(&self) -> bool {
        self.ordinary.environment.refreshing.is_some()
    }

    pub fn workspace_root(&self) -> Option<&Path> {
        self.workspace_root.as_deref()
    }

    /// NW02: same-host execution budgets are expressed in CLOCK_MONOTONIC µs.
    pub fn monotonic_time_us() -> io::Result<U> {
        let mut now = MaybeUninit::<libc::timespec>::uninit();
        if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, now.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let now = unsafe { now.assume_init() };
        let micros = now
            .tv_sec
            .checked_mul(1_000_000)
            .and_then(|secs| secs.checked_add(now.tv_nsec / 1_000))
            .and_then(|us| U::new(us).ok());
        micros.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "monotonic clock exceeds wire range",
            )
        })
    }

    pub fn domain(&self) -> &Domain {
        &self.domain
    }

    pub fn actual_exec_identity(&self) -> Result<&DriverExecIdentity, IdentityUnavailable> {
        if self.is_quarantined() {
            return Err(IdentityUnavailable::NotHealthy);
        }
        self.domain
            .verify_live()
            .map_err(|_| IdentityUnavailable::NotHealthy)?;
        self.exec_identity
            .as_ref()
            .ok_or(IdentityUnavailable::Unavailable)
    }

    /// 返回当前活域、同一实例及 epoch 上经 RC06 核验的对端启动回执。
    /// 只保留启动观测，不表示当前运行时格式或载荷加载状态。
    pub fn peer_hello_ack(
        &self,
        channel: NativeChannel,
    ) -> Result<&NativeHelloAck, IdentityUnavailable> {
        if self.is_quarantined() || self.source.failed() || self.view.failed() {
            return Err(IdentityUnavailable::NotHealthy);
        }
        let control = self.control.try_lock().map_err(|_| IdentityUnavailable::NotHealthy)?;
        if control.failed() { return Err(IdentityUnavailable::NotHealthy); }
        self.domain.verify_live().map_err(|_| IdentityUnavailable::NotHealthy)?;
        let current = match channel {
            NativeChannel::Ordinary => &self.ordinary.channel,
            NativeChannel::Control => &*control,
            NativeChannel::Source => &self.source,
            NativeChannel::View => &self.view,
        };
        let header = current.header();
        self.peer_hello_acks
            .iter()
            .find(|ack| ack.channel() == channel && ack.header() == &header)
            .ok_or(IdentityUnavailable::Unavailable)
    }

    pub fn apply_limits(
        &mut self,
        grant: &Id,
        revision: U,
        bytes: U,
    ) -> Result<AppliedLimit, LimitError> {
        self.domain.apply_limit(grant, revision, bytes)
    }

    pub fn quarantine(&mut self) {
        self.quarantined = true;
    }

    pub fn is_quarantined(&self) -> bool {
        self.quarantined || self.ordinary.failed()
    }

    pub fn ordinary(&self) -> &Channel {
        &self.ordinary
    }

    pub fn control_header(&self) -> Result<EpochHeader, ChannelError> {
        self.control.try_lock().map(|channel| channel.header()).map_err(|_| ChannelError::InFlight)
    }

    pub fn source(&self) -> &Channel {
        &self.source
    }

    pub fn view(&self) -> &Channel {
        &self.view
    }

    pub fn next_header(&self) -> Result<EpochHeader, ChannelError> {
        self.ordinary.next_header()
    }

    pub fn request(
        &mut self,
        request: &NativeRequest,
        deadline: Instant,
    ) -> Result<NativeReply, ChannelError> {
        if self.mainline.is_some() && matches!(request, NativeRequest::BeginLine { .. }) {
            return Err(ChannelError::InvalidExpectation);
        }
        if !matches!(request, NativeRequest::OperationStatus { .. }) {
            self.require_no_unapplied_ack()?;
        }
        let candidate_binding = match request {
            NativeRequest::OperationStatus { args, .. } => Some(args.binding()),
            NativeRequest::FinishOperation { args, .. } => Some(args.binding()),
            NativeRequest::SettleInterrupt { args, .. } => Some(args.binding()),
            NativeRequest::BeginLine { args, .. } => Some(args.binding()),
            _ => None,
        };
        if candidate_binding.is_some_and(|binding| self.state_operations.owns_candidate(binding)
            || self.state_operations.owns_source_sync(binding)
            || self.inspection.owns_binding(binding)
            || self.mainline.as_ref().is_some_and(|run| run.matches(binding))
            || self.end_scopes.owns_binding(binding)) {
            return Err(ChannelError::InvalidExpectation);
        }
        if matches!(request, NativeRequest::FinishOperation { args, .. } if self.inspection.owns_binding(args.binding())) {
            return Err(ChannelError::InvalidExpectation);
        }
        // 裸 PullStep/AckStep 不携本地预期，公开调试入口不得代替具名入口。
        if matches!(
            request,
            NativeRequest::PullStep { .. } | NativeRequest::AckStep { .. }
        ) {
            return Err(ChannelError::RawStepRequest);
        }
        if matches!(request, NativeRequest::LocateContext { .. }) {
            return Err(ChannelError::RawLocateRequest);
        }
        if matches!(request, NativeRequest::CheckpointObserve { .. } | NativeRequest::CheckpointExport { .. }
            | NativeRequest::CheckpointImport { .. } | NativeRequest::CheckpointActivate { .. }) {
            return Err(ChannelError::InvalidExpectation);
        }
        // 状态变更必须经过具名入口的原请求、登记槽及回执配对。
        if matches!(request, NativeRequest::ForkLine { .. } | NativeRequest::SyncSource { .. }
            | NativeRequest::RefreshEnvironment { .. } | NativeRequest::Query { .. } | NativeRequest::Inspect { .. })
            || matches!(request, NativeRequest::SelectLine { args, .. } if matches!(args.group(), KnownOrNa::Known(_)))
            || matches!(request, NativeRequest::RegisterBudget { args, .. }
                if matches!(args.budget().initial_request().method(), InitialNativeMethod::ForkLine
                    | InitialNativeMethod::SyncSource | InitialNativeMethod::RefreshEnvironment
                    | InitialNativeMethod::Query | InitialNativeMethod::Inspect)) {
            return Err(ChannelError::InvalidExpectation);
        }
        let reply = self.exchange(request, deadline)?;
        if matches!(&reply, NativeReply::Result { result, .. } if result_has_step_group(result)) {
            self.quarantine();
            return Err(ChannelError::ReplyMismatch);
        }
        Ok(reply)
    }

    pub fn stop(&mut self, deadline_ms: u64) -> StopFact {
        self.domain.stop(deadline_ms)
    }
}

fn valid_nw02_key(key: &ReceiptKey, budget: &NativeBudget) -> bool {
    key.operation_id() == budget.operation() && key.operation_seq() == budget.operation_seq()
        && key.receipt_seq().get() != 0
}

fn definitive_nw02_disposition(reply: &NativeReply, budget: &NativeBudget) -> bool {
    Nw02Reservation::establishment_rejected(reply)
        || matches!(reply, NativeReply::Result { result: NativeResult::PastUnavailable { operation_seq, highest_seen }, .. }
            if operation_seq == budget.operation_seq() && highest_seen >= operation_seq)
}

fn validate_entry_selection(args: &ArgsSelectLine, receipt: &Receipt) -> bool {
    let binding = args.binding();
    receipt.binding() == binding && receipt.key().operation_id() == binding.operation_id()
        && receipt.key().operation_seq() == binding.operation_seq() && receipt.key().receipt_seq().get() == 1
        && receipt.digest(Limits::MESSAGE).is_ok_and(|digest| &digest == receipt.key().digest())
        && receipt.execution_extent() == &ExecutionExtent::CompleteKnown
        && matches!(receipt.payload(), ReceiptPayload::Selected { line, before_revision, after_revision, node, group }
            if line == args.destination() && before_revision == args.expected_revision() && node == args.candidate()
                && &Fact::NotApplicable == group && before_revision.get().checked_add(1) == Some(after_revision.get()))
}

fn validate_locate_reply(
    header: &EpochHeader,
    args: &ArgsLocateContext,
    source: &str,
    result: &NativeResult,
) -> Result<(), ChannelError> {
    let binding = args.binding();
    let mismatch = ChannelError::ReplyMismatch;
    match result {
        NativeResult::AuxTerminal { terminal } => validate_locate_terminal(header, args, source, terminal),
        NativeResult::PastUnavailable {
            operation_seq,
            highest_seen,
        } if operation_seq == binding.operation_seq() && highest_seen >= operation_seq => {
            Ok(())
        }
        _ => Err(mismatch),
    }
}

fn validate_locate_terminal(
    header: &EpochHeader,
    args: &ArgsLocateContext,
    source: &str,
    terminal: &AuxTerminal,
) -> Result<(), ChannelError> {
    let binding = args.binding();
    let mismatch = ChannelError::ReplyMismatch;
    let key = terminal.key();
    if terminal.binding() != binding
        || key.operation_id() != binding.operation_id()
        || key.operation_seq() != binding.operation_seq()
        || key.receipt_seq().get() != 1
        || key.digest()
            != &terminal
                .digest(Limits::MESSAGE)
                .map_err(|_| ChannelError::ReplyMismatch)?
    {
        return Err(mismatch);
    }
    let (context, line, node, revision, cursor, boundary, located) = match terminal.value() {
        AuxValue::Located {
            context,
            line,
            node,
            revision,
            cursor,
            boundary,
        } => (context, line, node, revision, cursor, boundary, true),
        AuxValue::NeedsPrefix {
            context,
            line,
            node,
            revision,
            cursor,
            boundary,
            target,
        } if target == args.target() => (context, line, node, revision, cursor, boundary, false),
        AuxValue::Error { .. } => return Ok(()),
        _ => return Err(mismatch),
    };
    let byte = |value: &U| usize::try_from(value.get()).is_ok_and(|n| source.is_char_boundary(n));
    if terminal.execution_extent() != &ExecutionExtent::CompleteKnown
        || context != binding.context()
        || !byte(cursor)
        || matches!(args.lineage(), KnownOrNa::Known(v) if v.id() != line || v.revision() != revision)
    {
        return Err(mismatch);
    }
    // Step P3: parser 的回执必须把逻辑目标 ID 与已知真实边界一起绑定。
    if matches!(args.target(), NativeTarget::Root {}) {
        return if located && cursor.get() == 0 && matches!(boundary, Fact::NotApplicable) {
            Ok(())
        } else {
            Err(mismatch)
        };
    }
    match boundary {
        Fact::Known(fact) => {
            if fact.instance() != header.instance()
                || fact.backend_epoch() != &header.backend_epoch()
                || fact.manager_epoch() != &header.manager_epoch()
                || fact.context() != context
                || fact.source() != binding.source()
                || fact.environment() != binding.environment()
                || fact.target() != args.logical_target()
                || !byte(fact.entry_offset())
                || (located && (fact.entry_node() != node || fact.entry_offset() != cursor))
                || !byte(fact.entry_command().start())
                || !byte(fact.entry_command().end())
                || matches!(fact.replace_range(), Fact::Known(range) if !byte(range.start()) || !byte(range.end()))
            {
                return Err(mismatch);
            }
        }
        Fact::Unknown if !located => {}
        _ => return Err(mismatch),
    }
    Ok(())
}

fn validate_pull_reply(
    expected: &StepExpectation<'_>,
    target: Option<&Id>,
    result: &NativeResult,
) -> Result<(), ChannelError> {
    match result {
        NativeResult::Receipt { receipt } => validate_step_receipt(expected, receipt),
        NativeResult::Terminal { terminal } => validate_terminal(expected, target, terminal, None),
        NativeResult::PastUnavailable {
            operation_seq,
            highest_seen,
        } => validate_past_unavailable(expected, operation_seq, highest_seen),
        _ => Err(ChannelError::ReplyMismatch),
    }
}

fn validate_step_receipt(
    expected: &StepExpectation<'_>,
    receipt: &Receipt,
) -> Result<(), ChannelError> {
    if receipt.binding() != expected.binding
        || receipt.execution_extent() != &ExecutionExtent::CompleteKnown
        || !expected.key_matches(receipt.key())
    {
        return Err(ChannelError::ReplyMismatch);
    }
    let digest = receipt
        .digest(Limits::MESSAGE)
        .map_err(|_| ChannelError::ReplyMismatch)?;
    if receipt.key().digest() != &digest {
        return Err(ChannelError::ReplyMismatch);
    }
    let ReceiptPayload::Step { fact, .. } = receipt.payload() else {
        return Err(ChannelError::ReplyMismatch);
    };
    if fact.source() != expected.binding.source()
        || fact.line() != expected.line
        || fact.parent() != expected.parent
        || fact.base_revision() != &expected.base_revision
        || fact.step_seq().get() != expected.step_seq.get()
        || fact.node() == fact.parent()
        || fact.command_start().get() != expected.cursor.get()
        || fact.command_end() != fact.next_cursor()
        || fact.next_cursor().get() <= expected.cursor.get()
        || !expected.contains_boundary(fact.command_start())
        || !expected.contains_boundary(fact.command_end())
        || !expected.contains_boundary(fact.next_cursor())
    {
        return Err(ChannelError::ReplyMismatch);
    }
    Ok(())
}

fn validate_terminal(
    expected: &StepExpectation<'_>,
    target: Option<&Id>,
    terminal: &TerminalRecord,
    group: Option<&NativeGroupVersion>,
) -> Result<(), ChannelError> {
    match terminal {
        TerminalRecord::Eof { completion } => validate_completion(expected, completion),
        TerminalRecord::Receipt { receipt } => validate_terminal_receipt(expected, receipt, group),
        TerminalRecord::PrefixReached { completion } => {
            validate_prefix_completion(expected, target, completion)
        }
    }
}

fn validate_prefix_completion(
    expected: &StepExpectation<'_>,
    target: Option<&Id>,
    completion: &PrefixCompletion,
) -> Result<(), ChannelError> {
    // Step P6: 目标来自已登记的私有前缀，cursor 和计数来自持久 ACK 前沿。
    if target != Some(completion.target())
        || !expected.key_matches(completion.key())
        || completion.key().receipt_seq().get() != expected.step_seq.get()
        || completion.acked_through().get() == 0
        || completion.acked_through().get() != expected.step_seq.get() - 1
        || completion.cursor() != &expected.cursor
        || completion.key().digest() != &completion.digest(Limits::MESSAGE).map_err(|_| ChannelError::ReplyMismatch)?
    {
        return Err(ChannelError::ReplyMismatch);
    }
    Ok(())
}

fn validate_completion(
    expected: &StepExpectation<'_>,
    completion: &Completion,
) -> Result<(), ChannelError> {
    if !expected.key_matches(completion.key()) {
        return Err(ChannelError::ReplyMismatch);
    }
    let digest = completion
        .digest(Limits::MESSAGE)
        .map_err(|_| ChannelError::ReplyMismatch)?;
    if completion.key().digest() != &digest {
        return Err(ChannelError::ReplyMismatch);
    }
    let acked_through = expected
        .step_seq
        .get()
        .checked_sub(1)
        .ok_or(ChannelError::ReplyMismatch)?;
    if completion.acked_through().get() != acked_through || completion.cursor() != &expected.cursor
    {
        return Err(ChannelError::ReplyMismatch);
    }
    Ok(())
}

fn validate_terminal_receipt(
    expected: &StepExpectation<'_>,
    receipt: &Receipt,
    group: Option<&NativeGroupVersion>,
) -> Result<(), ChannelError> {
    if receipt.binding() != expected.binding || !expected.key_matches(receipt.key()) {
        return Err(ChannelError::ReplyMismatch);
    }
    let digest = receipt
        .digest(Limits::MESSAGE)
        .map_err(|_| ChannelError::ReplyMismatch)?;
    if receipt.key().digest() != &digest {
        return Err(ChannelError::ReplyMismatch);
    }
    match receipt.payload() {
        ReceiptPayload::Error { last_valid, group: after, stage, .. } => {
            let group_matches = if group.is_some() && matches!(stage, NativeStage::Parse | NativeStage::Execute) {
                advanced_group(group, after)
            } else {
                matches!(after, KnownOrNa::NotApplicable)
            };
            if matches!(last_valid, Fact::Known(node) if node != expected.parent)
                || !group_matches
            {
                return Err(ChannelError::ReplyMismatch);
            }
        }
        ReceiptPayload::Interrupted {
            last_acked,
            pending,
            ..
        } => {
            if matches!(last_acked, Fact::Known(node) if node != expected.parent) {
                return Err(ChannelError::ReplyMismatch);
            }
            if matches!(pending, Fact::Known(node) if node == expected.parent) {
                return Err(ChannelError::ReplyMismatch);
            }
        }
        _ => return Err(ChannelError::ReplyMismatch),
    }
    Ok(())
}

fn validate_past_unavailable(
    expected: &StepExpectation<'_>,
    operation_seq: &U,
    highest_seen: &U,
) -> Result<(), ChannelError> {
    if operation_seq != expected.binding.operation_seq() || highest_seen < operation_seq {
        return Err(ChannelError::ReplyMismatch);
    }
    Ok(())
}

fn validate_ack_reply(
    expected: &StepExpectation<'_>,
    proof: &AckProof,
    result: &NativeResult,
    group: Option<&NativeGroupVersion>,
) -> Result<(), ChannelError> {
    match result {
        NativeResult::Ack { ack } => {
            let line_revision = expected
                .base_revision
                .get()
                .checked_add(1)
                .ok_or(ChannelError::ReplyMismatch)?;
            if ack.receipt() != proof.receipt()
                || ack.line() != expected.line
                || ack.line_revision().get() != line_revision
                || ack.acked_through().get() != expected.step_seq.get()
                || !advanced_group(group, ack.group())
            {
                return Err(ChannelError::ReplyMismatch);
            }
        }
        NativeResult::RetiredStep { acked_through } => {
            if acked_through.get() < expected.step_seq.get() {
                return Err(ChannelError::ReplyMismatch);
            }
        }
        NativeResult::PastUnavailable {
            operation_seq,
            highest_seen,
        } => validate_past_unavailable(expected, operation_seq, highest_seen)?,
        _ => return Err(ChannelError::ReplyMismatch),
    }
    Ok(())
}

// 组只在同一实例代际的受核 operation 槽内比较；不以线修订或固定步长推导。
fn advanced_group(before: Option<&NativeGroupVersion>, after: &KnownOrNa<NativeGroupVersion>) -> bool {
    match (before, after) {
        (None, KnownOrNa::NotApplicable) => true,
        (Some(before), KnownOrNa::Known(after)) => before.group() == after.group()
            && before.expected_revision() < after.expected_revision(),
        _ => false,
    }
}

fn result_has_step_group(result: &NativeResult) -> bool {
    let in_receipt = |receipt: &Receipt| matches!(receipt.payload(), ReceiptPayload::Error { group: KnownOrNa::Known(_), .. });
    match result {
        NativeResult::Ack { ack } => matches!(ack.group(), KnownOrNa::Known(_)),
        NativeResult::Receipt { receipt } | NativeResult::Terminal { terminal: TerminalRecord::Receipt { receipt } } => in_receipt(receipt),
        NativeResult::Status { status } =>
            matches!(status.last_ack(), Fact::Known(ack) if matches!(ack.group(), KnownOrNa::Known(_)))
            || matches!(status.terminal(), Fact::Known(AnyTerminal::Terminal(TerminalRecord::Receipt { receipt })) if in_receipt(receipt)),
        _ => false,
    }
}

fn observe_exec_identity(
    domain: &Domain,
    instance: &Id,
    backend_epoch: U,
    manager_epoch: U,
) -> Option<DriverExecIdentity> {
    let identity = domain.identity().clone();
    let pid = identity.pid;
    let exe = PathBuf::from(format!("/proc/{pid}/exe"));
    let image = File::open(&exe).ok()?;
    let file = hash_loaded_file(image, &fs::canonicalize(&exe).ok()?).ok()?;
    domain.verify_live().ok()?;
    let exec_receipt = Id::new(format!("exec-{pid}-{}", identity.start_time)).ok()?;
    Some(DriverExecIdentity {
        instance: instance.clone(),
        backend_epoch,
        manager_epoch,
        domain: identity,
        exec_receipt,
        pet_file: file.clone(),
        exec_image: file,
        mode: ExecMode::Native,
    })
}

fn hash_loaded_file(mut file: File, path: &Path) -> io::Result<ActualExecFile> {
    let metadata = file.metadata()?;
    if metadata.len() == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "actual executable is empty",
        ));
    }
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65_536];
    let mut total = 0u64;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
        total = total
            .checked_add(count as u64)
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
    }
    let named = fs::metadata(path)?;
    if (named.dev(), named.ino(), metadata.len()) != (metadata.dev(), metadata.ino(), total) {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    Ok(ActualExecFile {
        canonical_path: path.to_str().ok_or(io::ErrorKind::InvalidData)?.into(),
        sha256: Digest32::from_bytes(hasher.finalize().into()),
        size: U::new(total.try_into().map_err(|_| io::ErrorKind::InvalidData)?)
            .map_err(|_| io::ErrorKind::InvalidData)?,
    })
}

#[cfg(test)]
#[test]
fn rejects_path_that_no_longer_names_the_loaded_file() {
    let image = File::open("/proc/self/exe").unwrap();
    assert_eq!(
        hash_loaded_file(image, Path::new("/bin/true"))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidData
    );
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        out.push(TABLE[(a >> 2) as usize] as char);
        out.push(TABLE[(((a & 3) << 4) | (b >> 4)) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[(((b & 15) << 2) | (c >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(c & 63) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn compatibility() -> Result<NativeCompatibility, SpawnError> {
    let (major, digest) = compiled_protocol();
    let major = Upos::new(i64::try_from(major).map_err(|_| Fault::Constraint)?)?;
    let capabilities = REQUIRED_CAPABILITIES
        .iter()
        .map(|value| TextNonEmpty::new((*value).into()))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(NativeCompatibility::for_send(major, digest, capabilities)?)
}

fn clock_boot() -> Result<Id, SpawnError> {
    let value = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    let value = value.trim();
    if value.is_empty() {
        return Err(SpawnError::Invalid("boot id is empty"));
    }
    Ok(Id::new(value.into())?)
}

fn platform() -> Result<NativeBootPlatform, SpawnError> {
    let mut raw = MaybeUninit::<libc::utsname>::zeroed();
    if unsafe { libc::uname(raw.as_mut_ptr()) } != 0 {
        return Err(SpawnError::Io(io::Error::last_os_error()));
    }
    let raw = unsafe { raw.assume_init() };
    let system = c_string(&raw.sysname)?;
    let architecture = c_string(&raw.machine)?;
    Ok(NativeBootPlatform::new(
        TextNonEmpty::new(system)?,
        TextNonEmpty::new(architecture)?,
    )?)
}

fn c_string(value: &[libc::c_char]) -> Result<String, SpawnError> {
    let value = unsafe { CStr::from_ptr(value.as_ptr()) };
    let value = value.to_string_lossy().into_owned();
    if value.is_empty() {
        return Err(SpawnError::Invalid("uname field is empty"));
    }
    Ok(value)
}

fn random_nonce() -> Result<Id, SpawnError> {
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let mut text = String::with_capacity(32);
    for byte in bytes {
        text.push(char::from_digit((byte >> 4) as u32, 16).expect("hex digit"));
        text.push(char::from_digit((byte & 15) as u32, 16).expect("hex digit"));
    }
    Ok(Id::new(text)?)
}

fn setup_child_fds(child: &[RawFd], parent: &[RawFd]) -> io::Result<()> {
    if child.len() != 5 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "native child fd count is not five",
        ));
    }
    let mut moved = [0; 5];
    for (index, fd) in child.iter().enumerate() {
        let duplicate = unsafe { libc::fcntl(*fd, libc::F_DUPFD_CLOEXEC, 20) };
        if duplicate < 0 {
            return Err(io::Error::last_os_error());
        }
        moved[index] = duplicate;
    }
    // 先关闭父端/原始子端，再 dup2 到固定 FD；否则父端 FD 若正好是目标号，
    // 会在 dup2 之后把刚建立的通道关掉。
    close_raw(child);
    close_raw(parent);
    for (target, fd) in [
        (BOOT_FD, moved[0]),
        (ORDINARY_FD, moved[1]),
        (CONTROL_FD, moved[2]),
        (SOURCE_FD, moved[3]),
        (VIEW_FD, moved[4]),
    ] {
        if unsafe { libc::dup2(fd, target) } < 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::fcntl(target, libc::F_SETFD, 0) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    for fd in moved {
        unsafe {
            libc::close(fd);
        }
    }
    Ok(())
}

fn close_all(fds: &[RawFd]) {
    close_raw(fds);
}

fn close_raw(fds: &[RawFd]) {
    for fd in fds {
        unsafe {
            libc::close(*fd);
        }
    }
}

#[cfg(test)]
mod step_expectation_tests {
    use super::*;
    use ccv_protocol::nativeface::{EndedStatus, Receipt, ReceiptKey, ReceiptPayload, StepFact};
    use ccv_protocol::reply::ExecutionExtent;
    use proptest::prelude::*;

    fn id(value: &str) -> Id {
        Id::new(value.into()).unwrap()
    }
    fn u(value: i64) -> U {
        U::new(value).unwrap()
    }
    fn pos(value: i64) -> Upos {
        Upos::new(value).unwrap()
    }

    #[test]
    fn nn04_refresh_fences_pending_and_rotates_only_on_changed_publication() {
        use ccv_protocol::nativeface::ArgsRefreshEnvironment;
        let mut state = CurrentEnvironment::new(id("env"));
        let initial = state.generation.clone();
        let noop = ArgsRefreshEnvironment::new(base_binding(), id("env"), id("env"), id("pub-noop")).unwrap();
        state.refreshing = Some(noop.clone());
        assert!(state.require_new_work(&id("env")).is_err());
        state.publish(&noop, &id("env"), false).unwrap();
        assert!(std::sync::Arc::ptr_eq(&initial, &state.generation));
        let change = ArgsRefreshEnvironment::new(base_binding(), id("env"), id("new-env"), id("pub-change")).unwrap();
        let wrong = ArgsRefreshEnvironment::new(base_binding(), id("env"), id("new-env"), id("other-pub")).unwrap();
        state.refreshing = Some(change.clone());
        assert!(state.publish(&wrong, &id("new-env"), true).is_err());
        assert_eq!(state.id, id("env"));
        assert!(state.require_new_work(&id("env")).is_err());
        assert!(state.require_new_work(&id("new-env")).is_err());
        state.publish(&change, &id("new-env"), true).unwrap();
        assert!(state.require_new_work(&id("env")).is_err());
        assert!(state.require_new_work(&id("new-env")).is_ok());
        assert!(!std::sync::Arc::ptr_eq(&initial, &state.generation));
    }

    fn base_binding() -> OpBinding {
        OpBinding::new(
            id("op-1"),
            u(1),
            Digest32::from_bytes([0; 32]),
            id("ctx"),
            id("scope"),
            id("src"),
            id("env"),
            id("budget"),
        )
        .unwrap()
    }

    #[test]
    fn locate_reply_checks_bound_target_even_with_valid_receipt_digest() {
        use ccv_protocol::{
            actor::ByteRange,
            nativeface::{AuxTerminal, NativeBoundaryFact},
            records::RelPath,
        };

        let header = EpochHeader::new(id("instance"), u(2), u(3), u(1));
        let binding = base_binding();
        let source = "(*é*) Check nat.";
        let end = source.len() as i64;
        let args = ArgsLocateContext::new(
            binding.clone(),
            id("file"),
            RelPath::new("proof/vst/a.v".into()).unwrap(),
            NativeTarget::Position {
                line: u(0),
                character: u(source.encode_utf16().count() as i64),
            },
            id("target"),
            KnownOrNa::NotApplicable,
            KnownOrNa::NotApplicable,
        )
        .unwrap();
        let result_for = |cursor, boundary| {
            let extent = ExecutionExtent::CompleteKnown;
            let value = AuxValue::Located {
                context: id("ctx"),
                line: id("line"),
                node: id("node"),
                revision: u(2),
                cursor: u(cursor),
                boundary,
            };
            let key = |digest| ReceiptKey::new(id("op-1"), u(1), u(1), digest).unwrap();
            let unsigned = AuxTerminal::new(
                key(Digest32::from_bytes([0; 32])),
                binding.clone(),
                extent,
                value.clone(),
            );
            let terminal = AuxTerminal::new(
                key(unsigned.digest(Limits::MESSAGE).unwrap()),
                binding.clone(),
                extent,
                value,
            );
            NativeResult::AuxTerminal { terminal }
        };
        let boundary = |target, cursor, command_end| {
            Fact::Known(NativeBoundaryFact::new(
                id("instance"),
                u(2),
                u(3),
                id("ctx"),
                id("src"),
                id("env"),
                id(target),
                id("node"),
                u(cursor),
                ByteRange::new(u(0), u(command_end)).unwrap(),
                Fact::Unknown,
            ))
        };
        let actual = result_for(end, boundary("target", end, end));
        assert!(validate_locate_reply(&header, &args, source, &actual).is_ok());
        for invalid in [
            result_for(end, boundary("file", end, end)),
            result_for(end, boundary("target", end, 3)),
        ] {
            assert!(matches!(
                validate_locate_reply(&header, &args, source, &invalid),
                Err(ChannelError::ReplyMismatch)
            ));
        }
        let root = ArgsLocateContext::new(
            binding.clone(),
            id("file"),
            RelPath::new("proof/vst/a.v".into()).unwrap(),
            NativeTarget::Root {},
            id("target"),
            KnownOrNa::NotApplicable,
            KnownOrNa::NotApplicable,
        )
        .unwrap();
        assert!(
            validate_locate_reply(&header, &root, source, &result_for(0, Fact::NotApplicable))
                .is_ok()
        );
        assert!(matches!(
            validate_locate_reply(
                &header,
                &root,
                source,
                &result_for(0, boundary("target", 0, end))
            ),
            Err(ChannelError::ReplyMismatch)
        ));
    }

    fn mutated_binding(field: usize) -> OpBinding {
        let base = base_binding();
        let mut operation_id = base.operation_id().clone();
        let mut operation_seq = *base.operation_seq();
        let mut request_digest = *base.request_digest();
        let mut context = base.context().clone();
        let mut scope = base.scope().clone();
        let mut source = base.source().clone();
        let mut environment = base.environment().clone();
        let mut budget = base.budget().clone();
        match field {
            0 => operation_id = id("op-2"),
            1 => operation_seq = u(2),
            2 => request_digest = Digest32::from_bytes([1; 32]),
            3 => context = id("ctx-2"),
            4 => scope = id("scope-2"),
            5 => source = id("src-2"),
            6 => environment = id("env-2"),
            7 => budget = id("budget-2"),
            _ => {}
        }
        OpBinding::new(
            operation_id,
            operation_seq,
            request_digest,
            context,
            scope,
            source,
            environment,
            budget,
        )
        .unwrap()
    }

    fn receipt(field: usize) -> Receipt {
        let mut binding = base_binding();
        let mut line = id("line-1");
        let mut parent = id("node-0");
        let mut node = id("node-1");
        let mut source = id("src");
        let mut start = u(0);
        let mut end = u(4);
        let mut next = u(4);
        let mut base_revision = u(0);
        let mut step_seq = u(1);
        let mut receipt_seq = u(1);
        let mut extent = ExecutionExtent::CompleteKnown;
        let mut corrupted_digest = None;
        let mut wrong_payload = false;
        match field {
            0..=7 => binding = mutated_binding(field),
            8 => receipt_seq = u(2),
            9 => corrupted_digest = Some(Digest32::from_bytes([1; 32])),
            10 => parent = id("node-x"),
            11 => node = parent.clone(),
            12 => source = id("src-other"),
            13 => start = u(1),
            14 => end = u(3),
            15 => next = u(5),
            16 => line = id("line-2"),
            17 => base_revision = u(1),
            18 => step_seq = u(2),
            19 => extent = ExecutionExtent::PartialKnown,
            20 => wrong_payload = true,
            _ => {}
        }
        let payload = if wrong_payload {
            ReceiptPayload::Ended {
                scope: id("scope"),
                status: EndedStatus::Closed,
                reclaim: Fact::NotApplicable,
            }
        } else {
            ReceiptPayload::Step {
                fact: StepFact::new(
                    parent,
                    node,
                    source,
                    start,
                    end,
                    next,
                    line,
                    base_revision,
                    step_seq,
                )
                .unwrap(),
                view: Fact::NotApplicable,
            }
        };
        let key = ReceiptKey::new(
            binding.operation_id().clone(),
            *binding.operation_seq(),
            receipt_seq,
            Digest32::from_bytes([0; 32]),
        )
        .unwrap();
        let draft = Receipt::new(key, binding.clone(), extent, payload.clone()).unwrap();
        let digest = draft.digest(Limits::MESSAGE).unwrap();
        let key = ReceiptKey::new(
            binding.operation_id().clone(),
            *binding.operation_seq(),
            receipt_seq,
            corrupted_digest.unwrap_or(digest),
        )
        .unwrap();
        Receipt::new(key, binding, extent, payload).unwrap()
    }

    fn expectation<'a>(
        binding: &'a OpBinding,
        line: &'a Id,
        parent: &'a Id,
        source: &'a str,
    ) -> StepExpectation<'a> {
        StepExpectation {
            binding,
            line,
            parent,
            source,
            cursor: u(0),
            base_revision: u(0),
            step_seq: pos(1),
            receipt_seq: pos(1),
        }
    }

    #[test]
    fn valid_step_and_completion_pass_local_expectation() {
        let binding = base_binding();
        let line = id("line-1");
        let parent = id("node-0");
        let expected = expectation(&binding, &line, &parent, "abcd");
        assert!(validate_pull_reply(
            &expected,
            None,
            &NativeResult::Receipt {
                receipt: receipt(usize::MAX)
            }
        )
        .is_ok());

        let draft = Completion::new(
            ReceiptKey::new(id("op-1"), u(1), u(1), Digest32::from_bytes([0; 32])).unwrap(),
            u(0),
            u(4),
        );
        let digest = draft.digest(Limits::MESSAGE).unwrap();
        assert_eq!(
            digest,
            Digest32::from_hex("d629ff61a0df60eabb7d03ca859827dfb0e9dac9b41a4a65b6e345d47a4731d4")
                .unwrap()
        );
        let key = ReceiptKey::new(id("op-1"), u(1), u(1), digest).unwrap();
        let completion = Completion::new(key, u(0), u(4));
        let eof_expected = StepExpectation {
            cursor: u(4),
            ..expected
        };
        assert!(validate_pull_reply(
            &eof_expected,
            None,
            &NativeResult::Terminal {
                terminal: TerminalRecord::Eof { completion }
            }
        )
        .is_ok());
    }

    #[test]
    fn prefix_terminal_requires_the_original_target_and_ack_frontier() {
        let binding = base_binding();
        let line = id("line-1");
        let parent = id("node-1");
        let target = id("target-1");
        let expected = StepExpectation {
            cursor: u(4), base_revision: u(1), step_seq: pos(2), receipt_seq: pos(2),
            ..expectation(&binding, &line, &parent, "abcd suffix")
        };
        let make = |target: Id, cursor: U, acked: U| {
            let key = |digest| ReceiptKey::new(id("op-1"), u(1), u(2), digest).unwrap();
            let digest = PrefixCompletion::new(key(Digest32::from_bytes([0; 32])), target.clone(), acked, cursor)
                .digest(Limits::MESSAGE).unwrap();
            NativeResult::Terminal { terminal: TerminalRecord::PrefixReached {
                completion: PrefixCompletion::new(key(digest), target, acked, cursor),
            } }
        };
        let good = make(target.clone(), u(4), u(1));
        assert!(validate_pull_reply(&expected, Some(&target), &good).is_ok());
        assert!(validate_pull_reply(&expected, None, &good).is_err());
        for wrong in [make(id("target-2"), u(4), u(1)), make(target.clone(), u(5), u(1)), make(target.clone(), u(4), u(2))] {
            assert!(validate_pull_reply(&expected, Some(&target), &wrong).is_err());
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig { cases: 64, failure_persistence: None, ..ProptestConfig::default() })]
        #[test]
        fn changing_a_bound_step_field_cannot_pass(field in 0usize..21) {
            let binding = base_binding();
            let line = id("line-1");
            let parent = id("node-0");
            let expected = expectation(&binding, &line, &parent, "abcd");
            let result = NativeResult::Receipt { receipt: receipt(field) };
            prop_assert!(validate_pull_reply(&expected, None, &result).is_err());
        }
    }
}
