//! Drives a `SenderSession` and a `ReceiverSession` against each other through
//! an in-memory wire with arbitrary chunking, with the sender's wall clock
//! deliberately skewed. No sockets, no timers, no codecs.

use std::time::Duration;

use opendisplay_proto::control::{ControlMessage, Hello};
use opendisplay_proto::video::START_CODE;
use opendisplay_proto::{Deframer, encode_frame};
use opendisplay_session::receiver::{
    ReceiverAction, ReceiverConfig, ReceiverEvent, ReceiverSession,
};
use opendisplay_session::sender::{SenderAction, SenderConfig, SenderEvent, SenderSession};
use opendisplay_session::{CloseReason, Now};

const SPS_320X180: &[u8] = &[
    0x67, 0x42, 0xc0, 0x0d, 0xda, 0x05, 0x06, 0x7e, 0x7c, 0x04, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40,
    0x00, 0x00, 0x0f, 0x23, 0xc5, 0x0a, 0xa8,
];
const PPS: &[u8] = &[0x68, 0xce, 0x38, 0x80];
/// Sender clock runs this far ahead of the receiver's.
const SKEW_MS: f64 = 1234.5;

fn idr(sps: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    for nal in [sps, PPS, &[0x65, 0x88, 0x84, 0x21][..]] {
        v.extend_from_slice(&START_CODE);
        v.extend_from_slice(nal);
    }
    v
}

fn pframe() -> Vec<u8> {
    let mut v = START_CODE.to_vec();
    v.extend_from_slice(&[0x41, 0x9a, 0x22, 0x0f]);
    v
}

struct Harness {
    rx: ReceiverSession,
    tx: SenderSession,
    mono: Duration,
    rng: u64,
}

impl Harness {
    fn new(hello: Hello) -> Self {
        Self {
            rx: ReceiverSession::new(ReceiverConfig::new(hello)),
            tx: SenderSession::new(SenderConfig::default()),
            mono: Duration::from_secs(10),
            rng: 0x9E37_79B9_7F4A_7C15,
        }
    }
    fn rx_now(&self) -> Now {
        Now::new(self.mono, 1_000_000.0 + self.mono.as_secs_f64() * 1000.0)
    }
    fn tx_now(&self) -> Now {
        let r = self.rx_now();
        Now::new(r.mono, r.wall_ms + SKEW_MS)
    }
    fn advance(&mut self, d: Duration) {
        self.mono += d;
    }
    fn chunk(&mut self) -> usize {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng % 37) as usize + 1
    }
    /// Deliver every `Send` in `actions` to the receiver in random chunks;
    /// returns the receiver's non-Send-related actions.
    fn deliver_to_receiver(&mut self, actions: &[SenderAction]) -> Vec<ReceiverAction> {
        let mut bytes = Vec::new();
        for a in actions {
            if let SenderAction::Send(b) = a {
                bytes.extend_from_slice(b);
            }
        }
        let mut out = Vec::new();
        let mut pos = 0;
        while pos < bytes.len() {
            let end = (pos + self.chunk()).min(bytes.len());
            let now = self.rx_now();
            out.extend(self.rx.handle(now, ReceiverEvent::Bytes(&bytes[pos..end])));
            pos = end;
        }
        out
    }
    fn deliver_to_sender(&mut self, actions: &[ReceiverAction]) -> Vec<SenderAction> {
        let mut bytes = Vec::new();
        for a in actions {
            if let ReceiverAction::Send(b) = a {
                bytes.extend_from_slice(b);
            }
        }
        let mut out = Vec::new();
        let mut pos = 0;
        while pos < bytes.len() {
            let end = (pos + self.chunk()).min(bytes.len());
            let now = self.tx_now();
            out.extend(self.tx.handle(now, SenderEvent::Bytes(&bytes[pos..end])));
            pos = end;
        }
        out
    }
    fn connect(&mut self) -> (Vec<ReceiverAction>, Vec<SenderAction>, Vec<ReceiverAction>) {
        let now = self.tx_now();
        assert!(self.tx.handle(now, SenderEvent::Connected).is_empty());
        let now = self.rx_now();
        let r1 = self.rx.handle(now, ReceiverEvent::Connected);
        let s1 = self.deliver_to_sender(&r1);
        let r2 = self.deliver_to_receiver(&s1);
        (r1, s1, r2)
    }
}

fn control_types(actions: &[ReceiverAction]) -> Vec<String> {
    let mut d = Deframer::for_sender();
    for a in actions {
        if let ReceiverAction::Send(b) = a {
            d.push(b);
        }
    }
    let mut kinds = Vec::new();
    while let Some(p) = d.next_frame().unwrap() {
        kinds.push(ControlMessage::parse(&p).unwrap().kind().to_owned());
    }
    kinds
}

fn hello() -> Hello {
    Hello {
        pixels_wide: 2560,
        pixels_high: 1600,
        scale: 2.0,
        device: Some("Linux".into()),
        id: Some("test".into()),
        ..Default::default()
    }
}

#[test]
fn handshake_hello_welcome_keyframe() {
    let mut h = Harness::new(hello());
    let (r1, s1, r2) = h.connect();
    assert_eq!(r1[0], ReceiverAction::ResetDecoder);
    assert_eq!(control_types(&r1), vec!["hello"]);
    // Sender: display from hello, welcome back, IDR requested.
    let SenderAction::Hello(hh) = &s1[0] else {
        panic!("{s1:?}")
    };
    assert_eq!(
        (hh.pixels_wide, hh.pixels_high, hh.pv),
        (2560, 1600, Some(3))
    );
    assert!(s1.contains(&SenderAction::RequestKeyframe));
    assert!(h.tx.needs_idr() && h.tx.ready_for_video());
    assert_eq!(h.tx.receiver_pv(), 3);
    // Receiver sees welcome pv 3 / min 1.
    assert!(matches!(&r2[..], [ReceiverAction::Welcome(w)] if w.pv == 3 && w.min == 1));
    assert_eq!(h.rx.sender_pv(), 3);
}

#[test]
fn video_waits_for_idr_on_both_ends() {
    let mut h = Harness::new(hello());
    h.connect();
    let now = h.tx_now();
    // Sender drops P-frames while an IDR is pending.
    assert!(
        h.tx.push_encoded_frame(now, &pframe(), false, None)
            .is_empty()
    );
    assert_eq!(h.tx.counters.dropped_awaiting_idr, 1);
    let s =
        h.tx.push_encoded_frame(now, &idr(SPS_320X180), true, Some(now.wall_ms - 5.0));
    assert!(!h.tx.needs_idr());
    let r = h.deliver_to_receiver(&s);
    let [ReceiverAction::Video(v)] = &r[..] else {
        panic!("{r:?}")
    };
    assert!(v.is_idr);
    assert_eq!(v.sps.map(|s| (s.width, s.height)), Some((320, 180)));
    assert_eq!(v.captured_local_ms, None, "no clock offset yet");
    let s = h.tx.push_encoded_frame(now, &pframe(), false, None);
    let r = h.deliver_to_receiver(&s);
    assert!(matches!(&r[..], [ReceiverAction::Video(v)] if !v.is_idr && v.sps.is_none()));
    assert_eq!(h.rx.counters.video_frames, 2);
}

#[test]
fn receiver_drops_pframes_before_idr_and_requests_keyframe_once() {
    let mut h = Harness::new(hello());
    h.connect();
    // Bypass the sender's own IDR gating to simulate a mid-GOP join.
    let raw = encode_frame(&pframe());
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::Bytes(&raw));
    assert_eq!(control_types(&r), vec!["kf"]);
    assert!(!r.iter().any(|a| matches!(a, ReceiverAction::Video(_))));
    let r = h.rx.handle(now, ReceiverEvent::Bytes(&raw));
    assert!(r.is_empty(), "kf is rate limited: {r:?}");
    assert_eq!(h.rx.counters.dropped_awaiting_idr, 2);
    h.advance(Duration::from_millis(400));
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::Bytes(&raw));
    assert_eq!(control_types(&r), vec!["kf"]);
}

#[test]
fn ping_pong_yields_clock_offset_and_maps_telemetry() {
    let mut h = Harness::new(hello());
    h.connect();
    h.advance(Duration::from_secs(1));
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::Tick);
    assert_eq!(control_types(&r), vec!["ping"]);
    let s = h.deliver_to_sender(&r);
    assert_eq!(s.len(), 1, "pong only: {s:?}");
    let r = h.deliver_to_receiver(&s);
    assert!(r.is_empty());
    let off = h.rx.clock().offset_ms().unwrap();
    assert!((off - SKEW_MS).abs() < 1e-6, "offset {off}");
    assert_eq!(h.rx.sender_time(now), Some(now.wall_ms + SKEW_MS));
    // Telemetry now maps onto the receiver's clock.
    let tx_now = h.tx_now();
    let s =
        h.tx.push_encoded_frame(tx_now, &idr(SPS_320X180), true, Some(tx_now.wall_ms - 8.0));
    let r = h.deliver_to_receiver(&s);
    let [ReceiverAction::Video(v)] = &r[..] else {
        panic!("{r:?}")
    };
    assert!((v.captured_local_ms.unwrap() - (now.wall_ms - 8.0)).abs() < 1e-6);
    assert!((v.sent_local_ms.unwrap() - now.wall_ms).abs() < 1e-6);
    // Next receiver ping is 2 s later, not sooner.
    h.advance(Duration::from_millis(1900));
    let now = h.rx_now();
    assert!(h.rx.handle(now, ReceiverEvent::Tick).is_empty());
    h.advance(Duration::from_millis(200));
    let now = h.rx_now();
    assert_eq!(
        control_types(&h.rx.handle(now, ReceiverEvent::Tick)),
        vec!["ping"]
    );
}

#[test]
fn decode_loss_round_trips_to_an_idr() {
    let mut h = Harness::new(hello());
    h.connect();
    let now = h.tx_now();
    let s = h.tx.push_encoded_frame(now, &idr(SPS_320X180), true, None);
    h.deliver_to_receiver(&s);
    h.advance(Duration::from_secs(1));
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::DecodeLost);
    assert_eq!(control_types(&r), vec!["kf"]);
    let s = h.deliver_to_sender(&r);
    assert_eq!(s, vec![SenderAction::RequestKeyframe]);
    assert!(h.tx.needs_idr());
    let now = h.tx_now();
    // Until the encoder delivers, P-frames are dropped on both ends.
    assert!(
        h.tx.push_encoded_frame(now, &pframe(), false, None)
            .is_empty()
    );
    let s = h.tx.push_encoded_frame(now, &idr(SPS_320X180), true, None);
    let r = h.deliver_to_receiver(&s);
    assert!(matches!(&r[..], [ReceiverAction::Video(v)] if v.is_idr));
    // A second kf while one is already pending is not re-requested.
    let now = h.rx_now();
    h.rx.handle(now, ReceiverEvent::DecodeLost);
}

#[test]
fn parameter_set_change_resets_the_decoder_first() {
    let mut h = Harness::new(hello());
    h.connect();
    let now = h.tx_now();
    let s = h.tx.push_encoded_frame(now, &idr(SPS_320X180), true, None);
    h.deliver_to_receiver(&s);
    let mut other_sps = SPS_320X180.to_vec();
    other_sps.push(0x00); // still parses; differs bytewise
    let s = h.tx.push_encoded_frame(now, &idr(&other_sps), true, None);
    let r = h.deliver_to_receiver(&s);
    assert!(
        matches!(&r[..], [ReceiverAction::ResetDecoder, ReceiverAction::Video(v)] if v.is_idr),
        "{r:?}"
    );
}

#[test]
fn cursor_over_tcp_dedupes_by_sequence() {
    let mut h = Harness::new(hello());
    h.connect();
    let now = h.tx_now();
    let s = h.tx.cursor(now, 0.25, 0.75, true);
    assert_eq!(s.len(), 1, "TCP only without cursorPort: {s:?}");
    let r = h.deliver_to_receiver(&s);
    assert_eq!(
        r,
        vec![ReceiverAction::Cursor {
            x: Some(0.25),
            y: Some(0.75),
            visible: true
        }]
    );
    // Replaying the same frame (stale s) does nothing.
    assert!(h.deliver_to_receiver(&s).is_empty());
    let s = h.tx.cursor(now, 0.0, 0.0, false);
    let r = h.deliver_to_receiver(&s);
    assert_eq!(
        r,
        vec![ReceiverAction::Cursor {
            x: None,
            y: None,
            visible: false
        }]
    );
}

#[test]
fn cursor_udp_side_channel_acks_then_leaves_tcp() {
    let mut h = Harness::new(Hello {
        cursor_port: Some(9001),
        ..hello()
    });
    h.connect();
    assert_eq!(h.tx.cursor_udp_port(), Some(9001));
    let now = h.tx_now();
    let s = h.tx.cursor(now, 0.5, 0.5, true);
    let [
        SenderAction::SendCursorDatagram(dgram),
        SenderAction::Send(_),
    ] = &s[..]
    else {
        panic!("{s:?}")
    };
    // Datagram arrives first: applied, acked once.
    let now = h.rx_now();
    let r = h.rx.handle(
        now,
        ReceiverEvent::CursorDatagram {
            flow: 7,
            payload: dgram,
        },
    );
    assert_eq!(control_types(&r), vec!["cursorAck"]);
    assert!(
        r.iter()
            .any(|a| matches!(a, ReceiverAction::Cursor { visible: true, .. }))
    );
    // The TCP mirror of the same s is dropped.
    let tcp_only: Vec<SenderAction> = s
        .iter()
        .filter(|a| matches!(a, SenderAction::Send(_)))
        .cloned()
        .collect();
    assert!(h.deliver_to_receiver(&tcp_only).is_empty());
    // Ack reaches the sender: from now on UDP only.
    let s2 = h.deliver_to_sender(&r);
    assert!(s2.is_empty(), "{s2:?}");
    let now = h.tx_now();
    let s = h.tx.cursor(now, 0.6, 0.6, true);
    assert!(
        matches!(&s[..], [SenderAction::SendCursorDatagram(_)]),
        "{s:?}"
    );
    // A datagram from a different flow restarts sequencing and re-acks.
    let SenderAction::SendCursorDatagram(d2) = &s[0] else {
        unreachable!()
    };
    let now = h.rx_now();
    let r = h.rx.handle(
        now,
        ReceiverEvent::CursorDatagram {
            flow: 8,
            payload: d2,
        },
    );
    assert_eq!(control_types(&r), vec!["cursorAck"]);
}

#[test]
fn udp_without_ack_falls_back_to_tcp() {
    let mut h = Harness::new(Hello {
        cursor_port: Some(9001),
        ..hello()
    });
    h.connect();
    let now = h.tx_now();
    h.tx.cursor(now, 0.5, 0.5, true);
    h.advance(Duration::from_millis(3500));
    let now = h.tx_now();
    let a = h.tx.handle(now, SenderEvent::Tick);
    assert!(
        a.iter().any(|x| matches!(x, SenderAction::Warn(_))),
        "{a:?}"
    );
    assert_eq!(h.tx.cursor_udp_port(), None);
    let s = h.tx.cursor(now, 0.5, 0.5, true);
    assert!(matches!(&s[..], [SenderAction::Send(_)]));
}

#[test]
fn silence_kills_both_ends_and_pings_keep_them_alive() {
    let mut h = Harness::new(hello());
    h.connect();
    // Sender pings at 2 s; receiver reports its health.
    h.advance(Duration::from_millis(2100));
    let now = h.tx_now();
    let s = h.tx.handle(now, SenderEvent::Tick);
    assert_eq!(s.len(), 1);
    let r = h.deliver_to_receiver(&s);
    assert!(matches!(&r[..], [ReceiverAction::SenderHealth(_)]), "{r:?}");
    // Receiver bytes reached the sender at connect only; 5 s later it gives up.
    h.advance(Duration::from_millis(3000));
    let now = h.tx_now();
    assert_eq!(
        h.tx.handle(now, SenderEvent::Tick),
        vec![SenderAction::Close(CloseReason::Timeout)]
    );
    assert!(!h.tx.is_connected());
    // The receiver heard the sender's ping at 2.1 s; it is still alive at 5 s...
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::Tick);
    assert!(
        !r.iter().any(|a| matches!(a, ReceiverAction::Close(_))),
        "{r:?}"
    );
    // ...and dead after 5 s of silence.
    h.advance(Duration::from_millis(5100));
    let now = h.rx_now();
    assert!(
        h.rx.handle(now, ReceiverEvent::Tick)
            .contains(&ReceiverAction::Close(CloseReason::Timeout))
    );
}

#[test]
fn unknown_types_and_garbage_are_ignored_and_warned_once() {
    let mut h = Harness::new(hello());
    h.connect();
    let mut bytes = encode_frame(br#"{"type":"holo","x":1}"#);
    bytes.extend(encode_frame(br#"{"type":"holo","x":2}"#));
    bytes.extend(encode_frame(br#"{"type":"pong"}"#)); // malformed known type
    bytes.extend(encode_frame(
        br#"{"type":"touch","phase":"began","x":0,"y":0}"#,
    )); // wrong direction
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::Bytes(&bytes));
    assert!(
        r.iter().all(|a| matches!(a, ReceiverAction::Warn(_))),
        "{r:?}"
    );
    assert_eq!(r.len(), 3);
    assert_eq!(h.rx.counters.control_ignored, 4);
    assert!(h.rx.is_connected());
    // Same on the sender side.
    let mut bytes = encode_frame(br#"{"type":"holo"}"#);
    bytes.extend(encode_frame(br#"{"type":"welcome","pv":3,"min":1}"#));
    let now = h.tx_now();
    let s = h.tx.handle(now, SenderEvent::Bytes(&bytes));
    assert_eq!(s.len(), 2);
    assert!(s.iter().all(|a| matches!(a, SenderAction::Warn(_))));
    assert!(h.tx.is_connected());
}

#[test]
fn framing_error_closes() {
    let mut h = Harness::new(hello());
    h.connect();
    let now = h.rx_now();
    let r = h.rx.handle(now, ReceiverEvent::Bytes(&[0, 0, 0, 0, 1]));
    assert!(matches!(
        &r[..],
        [ReceiverAction::Close(CloseReason::Framing(_))]
    ));
    let now = h.tx_now();
    let s =
        h.tx.handle(now, SenderEvent::Bytes(&(1u32 << 20).to_be_bytes()));
    assert!(matches!(
        &s[..],
        [SenderAction::Close(CloseReason::Framing(_))]
    ));
}

#[test]
fn rehello_rebuilds_display_and_restarts_with_idr() {
    let mut h = Harness::new(hello());
    h.connect();
    let now = h.tx_now();
    let s = h.tx.push_encoded_frame(now, &idr(SPS_320X180), true, None);
    h.deliver_to_receiver(&s);
    assert!(!h.tx.needs_idr());
    let r = h.rx.update_hello(Hello {
        pixels_wide: 1600,
        pixels_high: 2560,
        ..hello()
    });
    assert_eq!(control_types(&r), vec!["hello"]);
    let s = h.deliver_to_sender(&r);
    assert!(matches!(&s[0], SenderAction::Hello(hh) if hh.pixels_high == 2560));
    assert!(s.contains(&SenderAction::RequestKeyframe));
    let r = h.deliver_to_receiver(&s);
    assert!(
        matches!(&r[..], [ReceiverAction::Welcome(_)]),
        "repeat welcome is idempotent: {r:?}"
    );
}

#[test]
fn old_receiver_gets_update_required_and_old_sender_is_flagged() {
    let mut h = Harness::new(hello());
    h.tx = SenderSession::new(SenderConfig {
        min_receiver_pv: 3,
        ..Default::default()
    });
    let now = h.tx_now();
    h.tx.handle(now, SenderEvent::Connected);
    // A pv-1 receiver: no pv in hello.
    let s = h.tx.handle(
        now,
        SenderEvent::Bytes(&encode_frame(
            br#"{"type":"hello","pixelsWide":1,"pixelsHigh":1,"scale":1}"#,
        )),
    );
    assert_eq!(h.tx.receiver_pv(), 1);
    let kinds: Vec<String> = {
        let mut d = Deframer::for_receiver();
        for a in &s {
            if let SenderAction::Send(b) = a {
                d.push(b);
            }
        }
        let mut k = Vec::new();
        while let Some(p) = d.next_frame().unwrap() {
            k.push(ControlMessage::parse(&p).unwrap().kind().to_owned());
        }
        k
    };
    assert_eq!(kinds, vec!["welcome", "updateRequired"]);
    // And a receiver that demands pv 3 from a pv 2 sender.
    let mut cfg = ReceiverConfig::new(hello());
    cfg.min_sender_pv = 3;
    let mut rx = ReceiverSession::new(cfg);
    let now = h.rx_now();
    rx.handle(now, ReceiverEvent::Connected);
    let r = rx.handle(
        now,
        ReceiverEvent::Bytes(&encode_frame(br#"{"type":"welcome","pv":2,"min":1}"#)),
    );
    assert!(r.contains(&ReceiverAction::SenderOutdated {
        sender_pv: 2,
        required: 3
    }));
}
