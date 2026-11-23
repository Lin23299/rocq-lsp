use super::frame::{read_frame, write_frame, FrameError, FrameRead, FrameWrite};
use ccv_protocol::nativeface::{ControlReply, ControlRequest, NativeProtocolError, NativeReply, NativeRequest};
use ccv_protocol::{
    check_hello, decode, encode, EpochHeader, ExpectedPeer, Fault, HandshakePeer, Id, Limits,
    NativeChannel, NativeHello, NativeHelloAck, WireType, U,
};
use std::os::unix::net::UnixStream;
use std::any::TypeId;
use std::time::Instant;

#[derive(Debug)]
pub enum ChannelError {
    Frame(FrameError),
    Protocol(Fault),
    AlreadyHandshaked,
    NotHandshaked,
    WrongChannel,
    WrongHeader,
    UnexpectedPeer,
    SequenceOverflow,
    NonZeroHandshakeSequence(U),
    Failed,
    Native(NativeProtocolError),
    RawStepRequest,
    RawLocateRequest,
    AwaitingAckEffect,
    InvalidExpectation,
    ReplyMismatch,
    InFlight,
}

impl std::fmt::Display for ChannelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Frame(error) => write!(f, "channel frame failed: {error}"),
            Self::Protocol(error) => write!(f, "channel protocol failed: {error:?}"),
            Self::AlreadyHandshaked => f.write_str("channel is already handshaked"),
            Self::NotHandshaked => f.write_str("channel is not handshaked"),
            Self::WrongChannel => f.write_str("channel kind does not match"),
            Self::WrongHeader => f.write_str("reply header does not echo the request"),
            Self::UnexpectedPeer => f.write_str("handshake peer is not a hello_ack"),
            Self::SequenceOverflow => f.write_str("channel rpc sequence overflowed"),
            Self::NonZeroHandshakeSequence(seq) => {
                write!(f, "handshake rpc_seq must be 0, got {}", seq.get())
            }
            Self::Failed => f.write_str("channel is already failed"),
            Self::Native(error) => write!(f, "native protocol error: {error:?}"),
            Self::RawStepRequest => {
                f.write_str("pull_step/ack_step require the local step expectation")
            }
            Self::RawLocateRequest => f.write_str("locate_context requires its immutable source"),
            Self::AwaitingAckEffect => f.write_str("native ACK effect is not durably confirmed"),
            Self::InvalidExpectation => {
                f.write_str("native request expectation is invalid before send")
            }
            Self::ReplyMismatch => {
                f.write_str("native reply does not match the expected operation")
            }
            Self::InFlight => f.write_str("the original native request is still in flight"),
        }
    }
}

impl std::error::Error for ChannelError {}

impl From<FrameError> for ChannelError {
    fn from(value: FrameError) -> Self {
        Self::Frame(value)
    }
}

impl From<Fault> for ChannelError {
    fn from(value: Fault) -> Self {
        Self::Protocol(value)
    }
}

pub struct Channel {
    stream: UnixStream,
    kind: NativeChannel,
    instance: Id,
    backend_epoch: U,
    manager_epoch: U,
    next_seq: i64,
    handshaked: bool,
    failed: bool,
    pending: Option<PendingExchange>,
}

struct PendingExchange {
    header: EpochHeader,
    reply_type: TypeId,
    request: FrameWrite,
    reply: FrameRead,
    write_deadline: Instant,
    drain_deadline: Instant,
}

impl Channel {
    #[cfg(test)]
    pub(super) fn control_after_handshake_for_test(stream: UnixStream, instance: Id, epoch: U) -> Self {
        let mut channel = Self::new(stream, NativeChannel::Control, instance, epoch, epoch);
        channel.handshaked = true;
        channel
    }

    pub fn new(
        stream: UnixStream,
        kind: NativeChannel,
        instance: Id,
        backend_epoch: U,
        manager_epoch: U,
    ) -> Self {
        Self {
            stream,
            kind,
            instance,
            backend_epoch,
            manager_epoch,
            next_seq: 1,
            handshaked: false,
            failed: false,
            pending: None,
        }
    }

    pub fn kind(&self) -> NativeChannel {
        self.kind
    }

    pub fn header(&self) -> EpochHeader {
        EpochHeader::new(
            self.instance.clone(),
            self.backend_epoch,
            self.manager_epoch,
            U::new(0).expect("handshake header sequence is valid"),
        )
    }

    pub fn next_header(&self) -> Result<EpochHeader, ChannelError> {
        if !self.handshaked {
            return Err(ChannelError::NotHandshaked);
        }
        if self.failed() {
            return Err(ChannelError::Failed);
        }
        if self.pending.is_some() {
            return Err(ChannelError::InFlight);
        }
        let sequence = U::new(self.next_seq).map_err(|_| ChannelError::SequenceOverflow)?;
        Ok(EpochHeader::new(
            self.instance.clone(),
            self.backend_epoch,
            self.manager_epoch,
            sequence,
        ))
    }

    pub fn handshake(
        &mut self,
        hello: &NativeHello,
        expected: &ExpectedPeer,
        deadline: Instant,
    ) -> Result<NativeHelloAck, ChannelError> {
        if self.handshaked {
            return Err(ChannelError::AlreadyHandshaked);
        }
        if self.failed {
            return Err(ChannelError::Failed);
        }
        if hello.channel() != self.kind {
            return Err(ChannelError::WrongChannel);
        }
        if hello.header().rpc_seq().get() != 0 {
            return Err(ChannelError::NonZeroHandshakeSequence(
                hello.header().rpc_seq(),
            ));
        }
        if hello.header().instance() != &self.instance
            || hello.header().backend_epoch() != self.backend_epoch
            || hello.header().manager_epoch() != self.manager_epoch
        {
            return Err(ChannelError::WrongHeader);
        }
        let bytes = encode(hello, Limits::MESSAGE)?;
        if let Err(error) = write_frame(&mut self.stream, &bytes, deadline) {
            self.failed = true;
            return Err(ChannelError::Frame(error));
        }
        let bytes = match read_frame(&mut self.stream, deadline) {
            Ok(bytes) => bytes,
            Err(error) => {
                self.failed = true;
                return Err(ChannelError::Frame(error));
            }
        };
        let peer = match decode::<HandshakePeer>(&bytes, Limits::MESSAGE) {
            Ok(peer) => peer.into_inner(),
            Err(error) => {
                self.failed = true;
                return Err(ChannelError::Protocol(error));
            }
        };
        if let Err(error) = check_hello(expected, &peer) {
            self.failed = true;
            return Err(ChannelError::Protocol(error));
        }
        match peer {
            HandshakePeer::Ack(ack) => {
                self.handshaked = true;
                Ok(ack)
            }
            HandshakePeer::Hello(_) => {
                self.failed = true;
                Err(ChannelError::UnexpectedPeer)
            }
        }
    }

    pub fn request(
        &mut self,
        request: &NativeRequest,
        deadline: Instant,
    ) -> Result<NativeReply, ChannelError> {
        let header = request.header();
        self.exchange(request, header, reply_header, deadline)
    }

    /// ND02：第一字节前固定原 header、帧及排空期限。
    pub(super) fn request_resumable(&mut self, request: &NativeRequest, deadline: Instant,
        write_deadline: Instant, drain_deadline: Instant) -> Result<NativeReply, ChannelError> {
        self.start_resumable(NativeChannel::Ordinary, request, request.header(), reply_header, deadline, write_deadline, drain_deadline)
    }

    pub(super) fn view_resumable<R: WireType + 'static>(&mut self, request: &ccv_protocol::nativeface_b::ViewRequest,
        header: &EpochHeader, reply_header: fn(&R) -> &EpochHeader, deadline: Instant,
        write_deadline: Instant, drain_deadline: Instant,
    ) -> Result<R, ChannelError> {
        self.start_resumable(NativeChannel::View, request, header, reply_header, deadline, write_deadline, drain_deadline)
    }

    pub(super) fn control_resumable(&mut self, request: &ControlRequest, deadline: Instant,
        recovery: Instant, drain_only: bool,
    ) -> Result<Option<ControlReply>, ChannelError> {
        if self.kind != NativeChannel::Control { return Err(ChannelError::WrongChannel); }
        let (ControlRequest::Status { header, .. } | ControlRequest::Cancel { header, .. }) = request;
        if let Some(original) = self.pending_header() {
            if original != header { return Err(ChannelError::InFlight); }
            return self.drain_resumable(request, header, control_reply_header, deadline);
        }
        if drain_only { return Ok(None); }
        self.start_resumable(NativeChannel::Control, request, header, control_reply_header,
            deadline, deadline, recovery).map(Some)
    }

    fn start_resumable<T: WireType, R: WireType + 'static>(&mut self, kind: NativeChannel, request: &T,
        header: &EpochHeader, reply_header: fn(&R) -> &EpochHeader, deadline: Instant,
        write_deadline: Instant, drain_deadline: Instant,
    ) -> Result<R, ChannelError> {
        if self.kind != kind || header != &self.next_header()? {
            return Err(ChannelError::WrongHeader);
        }
        let deadline = deadline.min(write_deadline).min(drain_deadline);
        if Instant::now() >= deadline {
            return Err(FrameError::Timeout.into());
        }
        let frame = FrameWrite::new(encode(request, Limits::MESSAGE)?)?;
        self.next_seq = self.next_seq.checked_add(1).ok_or(ChannelError::SequenceOverflow)?;
        self.pending = Some(PendingExchange { header: header.clone(), reply_type: TypeId::of::<R>(), request: frame,
            reply: FrameRead::default(), write_deadline, drain_deadline });
        self.resume_exchange(header, reply_header, deadline)
    }

    pub(super) fn pending_header(&self) -> Option<&EpochHeader> {
        self.pending.as_ref().map(|pending| &pending.header)
    }

    /// 已完成发送时只读；写期限只约束原帧尚未发出的后缀。
    pub(super) fn drain_original(&mut self, request: &NativeRequest, deadline: Instant) -> Result<Option<NativeReply>, ChannelError> {
        self.drain_resumable(request, request.header(), reply_header, deadline)
    }

    pub(super) fn drain_view<R: WireType + 'static>(&mut self, request: &ccv_protocol::nativeface_b::ViewRequest,
        header: &EpochHeader, reply_header: fn(&R) -> &EpochHeader, deadline: Instant,
    ) -> Result<Option<R>, ChannelError> {
        if self.kind != NativeChannel::View { return Err(ChannelError::WrongChannel); }
        self.drain_resumable(request, header, reply_header, deadline)
    }

    fn drain_resumable<T: WireType, R: WireType + 'static>(&mut self, request: &T, header: &EpochHeader,
        reply_header: fn(&R) -> &EpochHeader, deadline: Instant,
    ) -> Result<Option<R>, ChannelError> {
        if self.failed() { return Err(ChannelError::Failed); }
        let Some(pending) = self.pending.as_ref() else { return Ok(None); };
        if header != &pending.header || pending.reply_type != TypeId::of::<R>()
            || encode(request, Limits::MESSAGE)? != pending.request.payload() {
            return Err(ChannelError::InvalidExpectation);
        }
        self.resume_exchange(header, reply_header, deadline).map(Some)
    }

    fn resume_exchange<R: WireType>(&mut self, header: &EpochHeader, reply_header: fn(&R) -> &EpochHeader,
        deadline: Instant,
    ) -> Result<R, ChannelError> {
        let pending = self.pending.as_mut().ok_or(ChannelError::InvalidExpectation)?;
        if &pending.header != header { return Err(ChannelError::WrongHeader); }
        let deadline = deadline.min(pending.drain_deadline);
        let raw = match pending.request.resume(&mut self.stream, deadline.min(pending.write_deadline))
            .and_then(|()| pending.reply.resume(&mut self.stream, deadline)) {
            Ok(bytes) => bytes,
            Err(FrameError::Timeout) if !pending.request.started() => {
                self.pending = None;
                self.next_seq = header.rpc_seq().get();
                return Err(FrameError::Timeout.into());
            }
            Err(error) => {
                if !matches!(error, FrameError::Timeout) || Instant::now() >= pending.drain_deadline
                    || (!pending.request.complete()
                        && (matches!(self.kind, NativeChannel::View | NativeChannel::Control)
                            || Instant::now() >= pending.write_deadline)) {
                    self.failed = true;
                }
                return Err(error.into());
            }
        };
        let reply = match decode::<R>(&raw, Limits::MESSAGE) {
            Ok(value) if reply_header(value.get()) == header => value.into_inner(),
            Ok(_) => { self.failed = true; return Err(ChannelError::WrongHeader); }
            Err(error) => { self.failed = true; return Err(error.into()); }
        };
        self.pending = None;
        Ok(reply)
    }

    pub(super) fn failed(&self) -> bool {
        self.failed || self.pending.as_ref().is_some_and(|pending| {
            let now = Instant::now();
            now >= pending.drain_deadline || (!pending.request.complete() && now >= pending.write_deadline)
        })
    }

    pub fn source_request(
        &mut self,
        request: &ccv_protocol::nativeface_b::SourceRequest,
        deadline: Instant,
    ) -> Result<ccv_protocol::nativeface_b::NativeSourceReply, ChannelError> {
        let header = source_header(request);
        self.exchange(request, header, source_reply_header, deadline)
    }

    pub fn exchange<T: WireType, R: WireType>(
        &mut self,
        request: &T,
        header: &EpochHeader,
        reply_header: fn(&R) -> &EpochHeader,
        deadline: Instant,
    ) -> Result<R, ChannelError> {
        if !self.handshaked {
            return Err(ChannelError::NotHandshaked);
        }
        if self.failed() {
            return Err(ChannelError::Failed);
        }
        if self.pending.is_some() {
            return Err(ChannelError::InFlight);
        }
        if header.instance() != &self.instance
            || header.backend_epoch() != self.backend_epoch
            || header.manager_epoch() != self.manager_epoch
            || header.rpc_seq().get() != self.next_seq
        {
            return Err(ChannelError::WrongHeader);
        }
        let bytes = encode(request, Limits::MESSAGE)?;
        self.next_seq = self
            .next_seq
            .checked_add(1)
            .ok_or(ChannelError::SequenceOverflow)?;
        if let Err(error) = write_frame(&mut self.stream, &bytes, deadline) {
            self.failed = true;
            return Err(ChannelError::Frame(error));
        }
        let bytes = match read_frame(&mut self.stream, deadline) {
            Ok(bytes) => bytes,
            Err(error) => {
                self.failed = true;
                return Err(ChannelError::Frame(error));
            }
        };
        let reply = match decode::<R>(&bytes, Limits::MESSAGE) {
            Ok(reply) => reply.into_inner(),
            Err(error) => {
                self.failed = true;
                return Err(ChannelError::Protocol(error));
            }
        };
        if reply_header(&reply) != header {
            self.failed = true;
            return Err(ChannelError::WrongHeader);
        }
        Ok(reply)
    }
}

fn control_reply_header(reply: &ControlReply) -> &EpochHeader {
    match reply {
        ControlReply::Result { header, .. } | ControlReply::ProtocolError { header, .. } => header,
    }
}

fn reply_header(reply: &NativeReply) -> &EpochHeader {
    match reply {
        NativeReply::Result { header, .. } | NativeReply::ProtocolError { header, .. } => header,
    }
}

fn source_header(request: &ccv_protocol::nativeface_b::SourceRequest) -> &EpochHeader {
    use ccv_protocol::nativeface_b::SourceRequest;
    match request {
        SourceRequest::Begin { header, .. }
        | SourceRequest::Chunk { header, .. }
        | SourceRequest::Finish { header, .. } => header,
    }
}

fn source_reply_header(reply: &ccv_protocol::nativeface_b::NativeSourceReply) -> &EpochHeader {
    use ccv_protocol::nativeface_b::NativeSourceReply;
    match reply {
        NativeSourceReply::Result { header, .. }
        | NativeSourceReply::ProtocolError { header, .. } => header,
    }
}
