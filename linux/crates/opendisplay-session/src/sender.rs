//! The sender's half of a session (§1, §5, §6, §8, Appendix A).

use std::collections::HashSet;
use std::time::Duration;

use opendisplay_proto::control::{
    ControlMessage, Cursor, CursorImg, Hello, Pencil, Ping, Pong, Proximity, Scroll, StreamConfig,
    Touch, UpdateRequired, Welcome,
};
use opendisplay_proto::video::{Telemetry, encode_video_frame};
use opendisplay_proto::{Deframer, encode_frame, version};

use crate::{CloseReason, LIVENESS_TIMEOUT, Now, PING_INTERVAL};

#[derive(Debug, Clone)]
pub struct SenderConfig {
    /// Oldest receiver `pv` we support (`welcome.min`).
    pub min_receiver_pv: u32,
    /// Sent when `hello.pv < min_receiver_pv` (§6.2). Required if the floor is above 1.
    pub update_required: Option<UpdateRequired>,
    pub ping_interval: Duration,
    pub liveness_timeout: Duration,
    /// Offer the UDP cursor channel when the receiver advertises `cursorPort`.
    /// Must be false on the USB binding (§6.3).
    pub use_cursor_udp: bool,
    /// Give up on UDP if no `cursorAck` arrives within this (§6.3: "a few seconds").
    pub cursor_ack_timeout: Duration,
}

impl Default for SenderConfig {
    fn default() -> Self {
        Self {
            min_receiver_pv: version::MIN_PEER_PV,
            update_required: None,
            ping_interval: PING_INTERVAL,
            liveness_timeout: LIVENESS_TIMEOUT,
            use_cursor_udp: true,
            cursor_ack_timeout: Duration::from_secs(3),
        }
    }
}

#[derive(Debug)]
pub enum SenderEvent<'a> {
    /// The TCP dial succeeded.
    Connected,
    Bytes(&'a [u8]),
    Tick,
    Disconnected,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SenderAction {
    /// Write this complete wire frame to the receiver.
    Send(Vec<u8>),
    /// Send this datagram to the receiver's `hello.cursorPort` (§6.3).
    SendCursorDatagram(Vec<u8>),
    /// A `hello` arrived: create (first time) or rebuild (repeat) the virtual
    /// display from it and restart capture. The stream must restart with an IDR.
    Hello(Hello),
    /// The next encoded frame must be an IDR carrying SPS/PPS (§5.3).
    RequestKeyframe,
    Touch(Touch),
    Scroll(Scroll),
    Pencil(Pencil),
    Proximity(Proximity),
    Stats(serde_json::Value),
    /// Receiver locked; it will come back (§6.1).
    ReceiverSleeping,
    /// Receiver quit for good (§6.1).
    ReceiverClosing,
    Close(CloseReason),
    Warn(String),
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SenderCounters {
    pub video_frames: u64,
    pub video_bytes: u64,
    /// Frames dropped while waiting for the encoder to produce the requested IDR.
    pub dropped_awaiting_idr: u64,
    pub kf_requests: u64,
    pub control_ignored: u64,
}

#[derive(Debug)]
pub struct SenderSession {
    cfg: SenderConfig,
    connected: bool,
    deframer: Deframer,
    hello: Option<Hello>,
    receiver_pv: u32,
    need_idr: bool,
    last_rx: Duration,
    next_ping: Duration,
    health: Ping,
    cursor_seq: u64,
    udp_port: Option<u16>,
    udp_started: Option<Duration>,
    udp_acked: bool,
    warned: HashSet<String>,
    pub counters: SenderCounters,
}

impl SenderSession {
    pub fn new(cfg: SenderConfig) -> Self {
        Self {
            cfg,
            connected: false,
            deframer: Deframer::for_sender(),
            hello: None,
            receiver_pv: version::IMPLICIT_PV,
            need_idr: true,
            last_rx: Duration::ZERO,
            next_ping: Duration::ZERO,
            health: Ping::default(),
            cursor_seq: 0,
            udp_port: None,
            udp_started: None,
            udp_acked: false,
            warned: HashSet::new(),
            counters: SenderCounters::default(),
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    /// The receiver's current `hello`, once it arrived.
    pub fn hello(&self) -> Option<&Hello> {
        self.hello.as_ref()
    }

    pub fn receiver_pv(&self) -> u32 {
        self.receiver_pv
    }

    /// Whether video may be sent yet (§6.1: nothing before `hello`).
    pub fn ready_for_video(&self) -> bool {
        self.connected && self.hello.is_some()
    }

    /// Whether the encoder must produce an IDR next (§5.3).
    pub fn needs_idr(&self) -> bool {
        self.need_idr
    }

    /// Health counters to piggyback on our next `ping` (§6.2).
    pub fn set_health(&mut self, health: Ping) {
        self.health = Ping { t: None, ..health };
    }

    /// The UDP cursor port to send datagrams to while the channel is active.
    pub fn cursor_udp_port(&self) -> Option<u16> {
        self.udp_port
    }

    pub fn handle(&mut self, now: Now, event: SenderEvent<'_>) -> Vec<SenderAction> {
        let mut out = Vec::new();
        match event {
            SenderEvent::Connected => {
                self.connected = true;
                self.deframer.reset();
                self.hello = None;
                self.receiver_pv = version::IMPLICIT_PV;
                self.need_idr = true;
                self.last_rx = now.mono;
                self.next_ping = now.mono + self.cfg.ping_interval;
                self.cursor_seq = 0;
                self.udp_port = None;
                self.udp_started = None;
                self.udp_acked = false;
                self.warned.clear();
                self.counters = SenderCounters::default();
            }
            SenderEvent::Bytes(bytes) => self.on_bytes(now, bytes, &mut out),
            SenderEvent::Tick => self.on_tick(now, &mut out),
            SenderEvent::Disconnected => self.connected = false,
        }
        out
    }

    /// An encoded access unit is ready. `annexb` must use 4-byte start codes
    /// and, for IDR frames, carry SPS and PPS (§5.1); `captured_wall_ms` is the
    /// capture timestamp on our clock. Frames are dropped while an IDR is
    /// pending and before `hello`.
    pub fn push_encoded_frame(
        &mut self,
        now: Now,
        annexb: &[u8],
        is_idr: bool,
        captured_wall_ms: Option<f64>,
    ) -> Vec<SenderAction> {
        if !self.ready_for_video() {
            return vec![];
        }
        if self.need_idr && !is_idr {
            self.counters.dropped_awaiting_idr += 1;
            return vec![];
        }
        if is_idr {
            self.need_idr = false;
        }
        let telemetry = Telemetry {
            cap: captured_wall_ms,
            snd: Some(now.wall_ms),
        };
        let payload = encode_video_frame(Some(&telemetry), annexb);
        self.counters.video_frames += 1;
        self.counters.video_bytes += payload.len() as u64;
        vec![SenderAction::Send(encode_frame(&payload))]
    }

    /// Announce the selected operating point before the first frame and after
    /// each reconfiguration (§6.2).
    pub fn stream_config(&self, cfg: StreamConfig) -> SenderAction {
        self.control(&ControlMessage::StreamConfig(cfg))
    }

    pub fn cursor_image(&self, img: CursorImg) -> SenderAction {
        self.control(&ControlMessage::CursorImg(img))
    }

    /// A cursor position update (§6.2/6.3). Goes over UDP when the channel is
    /// active, mirrored onto TCP until the receiver acknowledged the flow.
    pub fn cursor(&mut self, now: Now, x: f64, y: f64, visible: bool) -> Vec<SenderAction> {
        if !self.ready_for_video() {
            return vec![];
        }
        self.cursor_seq += 1;
        let msg = ControlMessage::Cursor(Cursor {
            x: visible.then_some(x),
            y: visible.then_some(y),
            v: visible as u32,
            s: Some(self.cursor_seq),
        });
        let payload = msg.to_payload().expect("cursor serialises");
        let mut out = Vec::new();
        if self.udp_port.is_some() {
            if self.udp_started.is_none() {
                self.udp_started = Some(now.mono);
            }
            out.push(SenderAction::SendCursorDatagram(payload.clone()));
            if self.udp_acked {
                return out;
            }
        }
        out.push(SenderAction::Send(encode_frame(&payload)));
        out
    }

    fn control(&self, msg: &ControlMessage) -> SenderAction {
        SenderAction::Send(encode_frame(
            &msg.to_payload().expect("well-formed control message"),
        ))
    }

    fn on_bytes(&mut self, now: Now, bytes: &[u8], out: &mut Vec<SenderAction>) {
        if !self.connected {
            return;
        }
        self.last_rx = now.mono;
        self.deframer.push(bytes);
        loop {
            match self.deframer.next_frame() {
                Ok(Some(payload)) => self.on_control(now, &payload, out),
                Ok(None) => break,
                Err(e) => {
                    self.connected = false;
                    out.push(SenderAction::Close(CloseReason::Framing(e)));
                    break;
                }
            }
        }
    }

    fn on_control(&mut self, now: Now, payload: &[u8], out: &mut Vec<SenderAction>) {
        // All receiver-to-sender frames are control messages (§4).
        let msg = match ControlMessage::parse(payload) {
            Ok(m) => m,
            Err(e) => {
                self.counters.control_ignored += 1;
                self.warn_once(format!("ignoring control frame: {e}"), out);
                return;
            }
        };
        match msg {
            ControlMessage::Hello(h) => {
                self.receiver_pv = version::effective_pv(h.pv);
                self.udp_port = if self.cfg.use_cursor_udp {
                    h.cursor_port.and_then(|p| u16::try_from(p).ok())
                } else {
                    None
                };
                if self.udp_port.is_none() {
                    self.udp_started = None;
                    self.udp_acked = false;
                }
                self.cursor_seq = 0;
                self.hello = Some(h.clone());
                out.push(SenderAction::Hello(h));
                out.push(self.control(&ControlMessage::Welcome(Welcome {
                    pv: version::PV,
                    min: self.cfg.min_receiver_pv,
                })));
                if self.receiver_pv < self.cfg.min_receiver_pv {
                    let u = self
                        .cfg
                        .update_required
                        .clone()
                        .unwrap_or_else(|| UpdateRequired {
                            target: "receiver".into(),
                            store: String::new(),
                            message: "This receiver is too old for this sender. Please update it."
                                .into(),
                        });
                    out.push(self.control(&ControlMessage::UpdateRequired(u)));
                }
                self.need_idr = true;
                self.counters.kf_requests += 1;
                out.push(SenderAction::RequestKeyframe);
            }
            ControlMessage::Ping(p) => {
                if let Some(t) = p.t {
                    out.push(self.control(&ControlMessage::Pong(Pong { t, mt: now.wall_ms })));
                }
            }
            ControlMessage::Kf => {
                if !self.need_idr {
                    self.need_idr = true;
                    self.counters.kf_requests += 1;
                    out.push(SenderAction::RequestKeyframe);
                }
            }
            ControlMessage::Touch(t) => out.push(SenderAction::Touch(t)),
            ControlMessage::Scroll(s) => out.push(SenderAction::Scroll(s)),
            ControlMessage::Pencil(p) => out.push(SenderAction::Pencil(p)),
            ControlMessage::Proximity(p) => out.push(SenderAction::Proximity(p)),
            ControlMessage::Stats(v) => out.push(SenderAction::Stats(v)),
            ControlMessage::Sleeping => out.push(SenderAction::ReceiverSleeping),
            ControlMessage::Closing => out.push(SenderAction::ReceiverClosing),
            ControlMessage::CursorAck => self.udp_acked = true,
            ControlMessage::Unknown { kind, .. } => {
                self.counters.control_ignored += 1;
                self.warn_once(format!("unknown control type `{kind}`"), out);
            }
            other => {
                self.counters.control_ignored += 1;
                self.warn_once(format!("unexpected `{}` from receiver", other.kind()), out);
            }
        }
    }

    fn on_tick(&mut self, now: Now, out: &mut Vec<SenderAction>) {
        if !self.connected {
            return;
        }
        if now.mono.saturating_sub(self.last_rx) > self.cfg.liveness_timeout {
            self.connected = false;
            out.push(SenderAction::Close(CloseReason::Timeout));
            return;
        }
        if now.mono >= self.next_ping {
            out.push(self.control(&ControlMessage::Ping(self.health.clone())));
            self.next_ping = now.mono + self.cfg.ping_interval;
        }
        if let (Some(started), false, Some(_)) = (self.udp_started, self.udp_acked, self.udp_port) {
            if now.mono.saturating_sub(started) > self.cfg.cursor_ack_timeout {
                self.udp_port = None;
                self.udp_started = None;
                self.warn_once("no cursorAck; cursor stays on TCP".into(), out);
            }
        }
    }

    fn warn_once(&mut self, msg: String, out: &mut Vec<SenderAction>) {
        if self.warned.insert(msg.clone()) {
            out.push(SenderAction::Warn(msg));
        }
    }
}
