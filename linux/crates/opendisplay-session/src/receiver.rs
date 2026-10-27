//! The receiver's half of a session (§1, §5, §6.1/6.2, §8, Appendix A).

use std::collections::HashSet;
use std::time::Duration;

use opendisplay_proto::control::{
    ControlMessage, CursorImg, Hello, Ping, StreamConfig, UpdateRequired, Welcome,
};
use opendisplay_proto::video::{ParameterSetChange, ParameterSetTracker, SpsInfo, VideoFrame};
use opendisplay_proto::{Channel, Deframer, classify, encode_frame, version};

use crate::clock::ClockSync;
use crate::cursor::CursorSeqTracker;
use crate::{CloseReason, LIVENESS_TIMEOUT, Now, PING_INTERVAL};

#[derive(Debug, Clone)]
pub struct ReceiverConfig {
    /// Sent on every connection. `pv` is forced to this crate's version.
    pub hello: Hello,
    /// Oldest sender `pv` this receiver works with; a lower `welcome.pv`
    /// yields [`ReceiverAction::SenderOutdated`].
    pub min_sender_pv: u32,
    pub ping_interval: Duration,
    /// Delay before the first ping after connecting.
    pub first_ping_after: Duration,
    pub liveness_timeout: Duration,
    /// Floor between two `kf` requests, so a stream of undecodable frames does
    /// not become a flood of keyframe requests.
    pub kf_min_interval: Duration,
}

impl ReceiverConfig {
    pub fn new(hello: Hello) -> Self {
        Self {
            hello,
            min_sender_pv: version::MIN_PEER_PV,
            ping_interval: PING_INTERVAL,
            first_ping_after: Duration::from_secs(1),
            liveness_timeout: LIVENESS_TIMEOUT,
            kf_min_interval: Duration::from_millis(300),
        }
    }
}

#[derive(Debug)]
pub enum ReceiverEvent<'a> {
    /// A sender's TCP connection is now the live one. Adopt-and-drop of the
    /// previous connection is the host's job (§1); this resets all state.
    Connected,
    /// Bytes read from the live TCP connection, any chunking.
    Bytes(&'a [u8]),
    /// One UDP datagram on the cursor port (§6.3). `flow` identifies the
    /// source address; a change of flow resets the sequence tracker.
    CursorDatagram { flow: u64, payload: &'a [u8] },
    /// The decoder failed on the last access unit or lost its state.
    DecodeLost,
    /// Time passed; call at least every few hundred ms.
    Tick,
    /// The TCP connection closed underneath us.
    Disconnected,
}

/// Decoded-frame hand-off to the host's decoder.
#[derive(Debug, Clone, PartialEq)]
pub struct VideoOut {
    /// One access unit, telemetry prefix removed, 4-byte start codes.
    pub annexb: Vec<u8>,
    pub is_idr: bool,
    /// Present when this frame carried an SPS (first frame, stream change).
    pub sps: Option<SpsInfo>,
    /// Sender capture / send timestamps mapped onto the local clock, when both
    /// the telemetry prefix and a clock offset are available.
    pub captured_local_ms: Option<f64>,
    pub sent_local_ms: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReceiverAction {
    /// Write this complete wire frame (length prefix included) to the sender.
    Send(Vec<u8>),
    /// Tear down the decoder and drop buffered frames (new connection, §5.2 change).
    ResetDecoder,
    /// Decode and present this access unit, latest-wins.
    Video(VideoOut),
    Cursor {
        x: Option<f64>,
        y: Option<f64>,
        visible: bool,
    },
    CursorImage(CursorImg),
    Welcome(Welcome),
    /// `welcome.pv` is below our floor: tell the user to update the sender (§6.2).
    SenderOutdated {
        sender_pv: u32,
        required: u32,
    },
    UpdateRequired(UpdateRequired),
    StreamConfig(StreamConfig),
    /// The sender's health counters piggybacked on its `ping` (§6.2).
    SenderHealth(Ping),
    Close(CloseReason),
    /// Something worth a log line. Emitted at most once per distinct cause.
    Warn(String),
}

/// Counters for `stats` and the performance overlay.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ReceiverCounters {
    pub video_frames: u64,
    pub video_bytes: u64,
    /// Frames dropped because no decodable IDR had arrived yet.
    pub dropped_awaiting_idr: u64,
    pub kf_requests: u64,
    pub control_ignored: u64,
}

#[derive(Debug)]
pub struct ReceiverSession {
    cfg: ReceiverConfig,
    connected: bool,
    deframer: Deframer,
    params: ParameterSetTracker,
    clock: ClockSync,
    cursor_seq: CursorSeqTracker,
    udp_flow: Option<u64>,
    udp_acked: bool,
    sender_pv: Option<u32>,
    waiting_for_idr: bool,
    last_rx: Duration,
    next_ping: Duration,
    last_kf: Option<Duration>,
    warned: HashSet<String>,
    pub counters: ReceiverCounters,
}

impl ReceiverSession {
    pub fn new(mut cfg: ReceiverConfig) -> Self {
        cfg.hello.pv = Some(version::PV);
        Self {
            cfg,
            connected: false,
            deframer: Deframer::for_receiver(),
            params: ParameterSetTracker::default(),
            clock: ClockSync::default(),
            cursor_seq: CursorSeqTracker::default(),
            udp_flow: None,
            udp_acked: false,
            sender_pv: None,
            waiting_for_idr: true,
            last_rx: Duration::ZERO,
            next_ping: Duration::ZERO,
            last_kf: None,
            warned: HashSet::new(),
            counters: ReceiverCounters::default(),
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    /// Effective sender protocol version (§10): implicit 1 until `welcome`.
    pub fn sender_pv(&self) -> u32 {
        version::effective_pv(self.sender_pv)
    }

    pub fn clock(&self) -> &ClockSync {
        &self.clock
    }

    pub fn hello(&self) -> &Hello {
        &self.cfg.hello
    }

    /// Change the announced panel (rotation, `addrs` change): re-sends `hello`
    /// on the live connection (§6.1). The sender rebuilds the display and the
    /// stream restarts with new SPS/PPS + IDR.
    pub fn update_hello(&mut self, hello: Hello) -> Vec<ReceiverAction> {
        self.cfg.hello = hello;
        self.cfg.hello.pv = Some(version::PV);
        if self.connected {
            vec![self.control(&ControlMessage::Hello(self.cfg.hello.clone()))]
        } else {
            vec![]
        }
    }

    /// Wrap any receiver-to-sender message for the wire. Use for `touch`,
    /// `scroll`, `pencil`, `proximity`, `stats`, `sleeping`, `closing`.
    pub fn control(&self, msg: &ControlMessage) -> ReceiverAction {
        ReceiverAction::Send(encode_frame(
            &msg.to_payload().expect("well-formed control message"),
        ))
    }

    /// `touch.t`/`pencil.t` want the sender's clock (§6.1); `None` until the
    /// offset is known, which the sender must tolerate.
    pub fn sender_time(&self, now: Now) -> Option<f64> {
        self.clock.to_sender(now.wall_ms)
    }

    /// Pencil fallback rule (§6.1).
    pub fn sender_accepts_pencil(&self) -> bool {
        version::sender_accepts_pencil(self.sender_pv())
    }

    pub fn handle(&mut self, now: Now, event: ReceiverEvent<'_>) -> Vec<ReceiverAction> {
        let mut out = Vec::new();
        match event {
            ReceiverEvent::Connected => self.on_connected(now, &mut out),
            ReceiverEvent::Bytes(bytes) => self.on_bytes(now, bytes, &mut out),
            ReceiverEvent::CursorDatagram { flow, payload } => {
                self.on_datagram(flow, payload, &mut out)
            }
            ReceiverEvent::DecodeLost => {
                self.waiting_for_idr = true;
                self.request_kf(now, &mut out);
            }
            ReceiverEvent::Tick => self.on_tick(now, &mut out),
            ReceiverEvent::Disconnected => self.connected = false,
        }
        out
    }

    fn on_connected(&mut self, now: Now, out: &mut Vec<ReceiverAction>) {
        self.connected = true;
        self.deframer.reset();
        self.params.reset();
        self.clock.reset();
        self.cursor_seq.reset();
        self.udp_flow = None;
        self.udp_acked = false;
        self.sender_pv = None;
        self.waiting_for_idr = true;
        self.last_rx = now.mono;
        self.next_ping = now.mono + self.cfg.first_ping_after;
        self.last_kf = None;
        self.warned.clear();
        self.counters = ReceiverCounters::default();
        out.push(ReceiverAction::ResetDecoder);
        out.push(self.control(&ControlMessage::Hello(self.cfg.hello.clone())));
    }

    fn on_bytes(&mut self, now: Now, bytes: &[u8], out: &mut Vec<ReceiverAction>) {
        if !self.connected {
            return;
        }
        self.last_rx = now.mono;
        self.deframer.push(bytes);
        loop {
            match self.deframer.next_frame() {
                Ok(Some(payload)) => self.on_frame(now, &payload, out),
                Ok(None) => break,
                Err(e) => {
                    self.connected = false;
                    out.push(ReceiverAction::Close(CloseReason::Framing(e)));
                    break;
                }
            }
        }
    }

    fn on_frame(&mut self, now: Now, payload: &[u8], out: &mut Vec<ReceiverAction>) {
        match classify(payload) {
            Channel::Control => self.on_control(now, payload, out),
            Channel::Video => self.on_video(now, payload, out),
        }
    }

    fn on_control(&mut self, now: Now, payload: &[u8], out: &mut Vec<ReceiverAction>) {
        let msg = match ControlMessage::parse(payload) {
            Ok(m) => m,
            Err(e) => {
                self.counters.control_ignored += 1;
                self.warn_once(format!("ignoring control frame: {e}"), out);
                return;
            }
        };
        match msg {
            ControlMessage::Pong(p) => {
                self.clock.add_sample(p.t, p.mt, now.wall_ms);
            }
            ControlMessage::Welcome(w) => {
                self.sender_pv = Some(w.pv);
                if w.pv < self.cfg.min_sender_pv {
                    out.push(ReceiverAction::SenderOutdated {
                        sender_pv: w.pv,
                        required: self.cfg.min_sender_pv,
                    });
                }
                out.push(ReceiverAction::Welcome(w));
            }
            ControlMessage::UpdateRequired(u) => out.push(ReceiverAction::UpdateRequired(u)),
            ControlMessage::Cursor(c) => {
                if self.cursor_seq.accept(c.s) {
                    out.push(ReceiverAction::Cursor {
                        x: c.x,
                        y: c.y,
                        visible: c.visible(),
                    });
                }
            }
            ControlMessage::CursorImg(i) => out.push(ReceiverAction::CursorImage(i)),
            ControlMessage::StreamConfig(s) => out.push(ReceiverAction::StreamConfig(s)),
            ControlMessage::Ping(p) => out.push(ReceiverAction::SenderHealth(p)),
            ControlMessage::Unknown { kind, .. } => {
                self.counters.control_ignored += 1;
                self.warn_once(format!("unknown control type `{kind}`"), out);
            }
            other => {
                // A receiver-to-sender type arriving at a receiver: ignore.
                self.counters.control_ignored += 1;
                self.warn_once(format!("unexpected `{}` from sender", other.kind()), out);
            }
        }
    }

    fn on_video(&mut self, now: Now, payload: &[u8], out: &mut Vec<ReceiverAction>) {
        let frame = match VideoFrame::parse(payload) {
            Ok(f) => f,
            Err(e) => {
                self.warn_once(format!("undecodable video frame: {e}"), out);
                self.waiting_for_idr = true;
                self.request_kf(now, out);
                return;
            }
        };
        self.counters.video_frames += 1;
        self.counters.video_bytes += payload.len() as u64;

        let change = self.params.observe(&frame);
        if change == ParameterSetChange::Changed {
            out.push(ReceiverAction::ResetDecoder);
            self.waiting_for_idr = true;
        }
        if self.waiting_for_idr && frame.is_idr && self.params.has_parameters() {
            self.waiting_for_idr = false;
        }
        if self.waiting_for_idr || !self.params.has_parameters() {
            self.counters.dropped_awaiting_idr += 1;
            self.request_kf(now, out);
            return;
        }
        let sps = match frame.sps_info() {
            Some(Ok(info)) => Some(info),
            Some(Err(e)) => {
                self.warn_once(format!("SPS parse failed, dimensions unknown: {e}"), out);
                None
            }
            None => None,
        };
        out.push(ReceiverAction::Video(VideoOut {
            annexb: frame.annexb.to_vec(),
            is_idr: frame.is_idr,
            sps,
            captured_local_ms: frame.telemetry.cap.and_then(|c| self.clock.to_local(c)),
            sent_local_ms: frame.telemetry.snd.and_then(|s| self.clock.to_local(s)),
        }));
    }

    fn on_datagram(&mut self, flow: u64, payload: &[u8], out: &mut Vec<ReceiverAction>) {
        if !self.connected {
            return;
        }
        let Ok(ControlMessage::Cursor(c)) = ControlMessage::parse(payload) else {
            self.warn_once("non-cursor datagram on the cursor port".into(), out);
            return;
        };
        if self.udp_flow != Some(flow) {
            // Accept datagrams only from the most recently seen flow; a new
            // flow restarts the sequence and needs its own `cursorAck`.
            self.udp_flow = Some(flow);
            self.udp_acked = false;
            self.cursor_seq.reset();
        }
        if !self.cursor_seq.accept(c.s) {
            return;
        }
        if !self.udp_acked {
            self.udp_acked = true;
            out.push(self.control(&ControlMessage::CursorAck));
        }
        out.push(ReceiverAction::Cursor {
            x: c.x,
            y: c.y,
            visible: c.visible(),
        });
    }

    fn on_tick(&mut self, now: Now, out: &mut Vec<ReceiverAction>) {
        if !self.connected {
            return;
        }
        if now.mono.saturating_sub(self.last_rx) > self.cfg.liveness_timeout {
            self.connected = false;
            out.push(ReceiverAction::Close(CloseReason::Timeout));
            return;
        }
        if now.mono >= self.next_ping {
            out.push(self.control(&ControlMessage::Ping(Ping {
                t: Some(now.wall_ms),
                ..Default::default()
            })));
            self.next_ping = now.mono + self.cfg.ping_interval;
        }
    }

    fn request_kf(&mut self, now: Now, out: &mut Vec<ReceiverAction>) {
        if !self.connected {
            return;
        }
        if self
            .last_kf
            .is_some_and(|t| now.mono.saturating_sub(t) < self.cfg.kf_min_interval)
        {
            return;
        }
        self.last_kf = Some(now.mono);
        self.counters.kf_requests += 1;
        out.push(self.control(&ControlMessage::Kf));
    }

    fn warn_once(&mut self, msg: String, out: &mut Vec<ReceiverAction>) {
        if self.warned.insert(msg.clone()) {
            out.push(ReceiverAction::Warn(msg));
        }
    }
}
