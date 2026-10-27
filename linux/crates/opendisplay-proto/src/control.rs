//! Control messages (§6). JSON objects with a `type` discriminator, each in
//! its own frame. Unknown types and unknown fields MUST be ignored; optional
//! fields MUST be tolerated when absent. Numbers are just JSON numbers, so
//! integer fields accept `2` and `2.0` alike.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::demux::is_valid_control_payload;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ControlError {
    /// Not JSON, not an object, or no string `type`: the spec says ignore it.
    #[error("unparseable control payload: {0}")]
    Unparseable(String),
    /// Known `type`, but the required fields for it are missing or mistyped.
    #[error("malformed {kind} message: {reason}")]
    Malformed { kind: String, reason: String },
    #[error("control payload violates §4 (too long, no leading '{{', or contains NUL)")]
    InvalidForWire,
}

/// JSON numbers are just numbers (§6): accept `2` and `2.0` for integer
/// fields, but keep exact integers exact (a `u64` sequence number must not
/// round-trip through `f64`).
fn number_to_u64(n: &serde_json::Number, what: &str) -> Result<u64, String> {
    if let Some(u) = n.as_u64() {
        return Ok(u);
    }
    if let Some(f) = n.as_f64() {
        if f.is_finite() && f >= 0.0 && f <= u64::MAX as f64 && f.fract() == 0.0 {
            return Ok(f as u64);
        }
    }
    Err(format!("{n} is not a {what}"))
}

fn lenient_u32<'de, D: Deserializer<'de>>(d: D) -> Result<u32, D::Error> {
    let n = serde_json::Number::deserialize(d)?;
    let v = number_to_u64(&n, "u32").map_err(serde::de::Error::custom)?;
    u32::try_from(v).map_err(|_| serde::de::Error::custom(format!("{n} is not a u32")))
}

fn lenient_opt_u32<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
    Option::<serde_json::Number>::deserialize(d)?
        .map(|n| {
            let v = number_to_u64(&n, "u32").map_err(serde::de::Error::custom)?;
            u32::try_from(v).map_err(|_| serde::de::Error::custom(format!("{n} is not a u32")))
        })
        .transpose()
}

fn lenient_opt_u64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
    Option::<serde_json::Number>::deserialize(d)?
        .map(|n| number_to_u64(&n, "u64").map_err(serde::de::Error::custom))
        .transpose()
}

/// `hello` (§6.1): first message on every connection, re-sent on rotation
/// and when `addrs` changes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    // Deprecated by `panel` and removed at the next bump (§6.1): absent
    // parses as 0, which the sender's plan only accepts with a valid panel.
    #[serde(default, deserialize_with = "lenient_u32")]
    pub pixels_wide: u32,
    #[serde(default, deserialize_with = "lenient_u32")]
    pub pixels_high: u32,
    #[serde(default)]
    pub scale: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub pv: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub cursor_port: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub addrs: Option<Vec<String>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub max_encode_wide: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub max_encode_high: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub display_max_frame_rate: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_caps: Option<Vec<VideoCap>>,
    /// Panel facts (§6.7). Never fails the `hello`: a malformed object comes
    /// back as a [`Panel`] whose [`Panel::facts`] is `None`.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_panel"
    )]
    pub panel: Option<Panel>,
    /// Power actions the receiver obeys on this session (§6.6). Parsed so a
    /// malformed list never fails the `hello`; non-string entries are dropped.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_power"
    )]
    pub power: Option<Vec<String>>,
}

impl Hello {
    /// The validated panel facts, or `None` when `panel` is absent or fails
    /// §6.7 validation (then the sender falls back to the deprecated fields).
    pub fn panel_facts(&self) -> Option<PanelFacts> {
        self.panel.as_ref().and_then(Panel::facts)
    }

    /// `panel` was sent but is ignored as a whole (§6.7), worth logging once.
    pub fn has_invalid_panel(&self) -> bool {
        self.panel.is_some() && self.panel_facts().is_none()
    }
}

/// `hello.panel` as sent (§6.7). Fields that are absent or not of the
/// expected kind are `None`, which invalidates the whole object.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Panel {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixels_wide: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixels_high: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub points_wide: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub points_high: Option<u32>,
    /// Set when a field was present but not a usable number (a string, a
    /// fraction for an integer field, out of range): the object is invalid
    /// even though that field reads as absent.
    #[serde(skip)]
    pub malformed: bool,
}

/// Validated §6.7 facts, in the receiver's current orientation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PanelFacts {
    /// Physical pixels lit 1:1: no stream needs to be larger.
    pub pixels_wide: u32,
    pub pixels_high: u32,
    /// The real backing scale; may be fractional.
    pub scale: f64,
    /// The desktop size the receiver itself runs (a Mac's "looks like").
    pub points: Option<(u32, u32)>,
}

impl Panel {
    /// §6.7: pixels integers of at least 2, `scale` finite above 0, points
    /// both absent or both integers of at least 2. Otherwise the whole object
    /// is ignored, never part of it.
    pub fn facts(&self) -> Option<PanelFacts> {
        if self.malformed {
            return None;
        }
        let (w, h, scale) = (self.pixels_wide?, self.pixels_high?, self.scale?);
        if w < 2 || h < 2 || !scale.is_finite() || scale <= 0.0 {
            return None;
        }
        let points = match (self.points_wide, self.points_high) {
            (None, None) => None,
            (Some(pw), Some(ph)) if pw >= 2 && ph >= 2 => Some((pw, ph)),
            _ => return None,
        };
        Some(PanelFacts {
            pixels_wide: w,
            pixels_high: h,
            scale,
            points,
        })
    }
}

fn lenient_panel<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Panel>, D::Error> {
    let value = Value::deserialize(d)?;
    if value.is_null() {
        return Ok(None);
    }
    let mut panel = Panel::default();
    let Some(obj) = value.as_object() else {
        panel.malformed = true;
        return Ok(Some(panel));
    };
    let mut int = |key: &str| -> Option<u32> {
        let v = obj.get(key)?;
        let n = v
            .as_number()
            .and_then(|n| number_to_u64(n, "u32").ok())
            .and_then(|n| u32::try_from(n).ok());
        if n.is_none() {
            panel.malformed = true;
        }
        n
    };
    let (pw, ph) = (int("pixelsWide"), int("pixelsHigh"));
    let (qw, qh) = (int("pointsWide"), int("pointsHigh"));
    panel.pixels_wide = pw;
    panel.pixels_high = ph;
    panel.points_wide = qw;
    panel.points_high = qh;
    panel.scale = match obj.get("scale") {
        None => None,
        Some(v) => {
            let s = v.as_f64();
            if s.is_none() {
                panel.malformed = true;
            }
            s
        }
    };
    Ok(Some(panel))
}

fn lenient_power<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<String>>, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Array(items) => Some(
            items
                .into_iter()
                .filter_map(|v| match v {
                    Value::String(s) => Some(s),
                    _ => None,
                })
                .collect(),
        ),
        _ => None,
    })
}

/// One `hello.videoCaps` entry (§6.5). All limits present apply together.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoCap {
    pub codec: String,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub max_width: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub max_height: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u32"
    )]
    pub max_frame_rate: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u64"
    )]
    pub max_pixels_per_second: Option<u64>,
}

/// `ping` in either direction (§6.1, §6.2). The receiver's carries `t` and
/// solicits a `pong`; the sender's carries health counters and solicits
/// nothing. All fields optional, informational.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Ping {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drops: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enc_drops: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub net_drops: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inp50: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inp95: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cap_fps: Option<f64>,
}

/// `pong` (§6.2, §8.1): echoes `t`, adds the sender's clock `mt`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pong {
    pub t: f64,
    pub mt: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TouchPhase {
    Began,
    Moved,
    Ended,
    Cancelled,
}

/// `touch` (§6.1): normalised position (§7), `t` in the sender's clock.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Touch {
    pub phase: TouchPhase,
    pub x: f64,
    pub y: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t: Option<f64>,
}

/// `scroll` (§6.1): deltas in video pixels, natural-scrolling sign.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Scroll {
    pub dx: f64,
    pub dy: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PencilPhase {
    Down,
    Move,
    Up,
    Hover,
}

/// `pencil` (§6.1, pv 3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pencil {
    pub phase: PencilPhase,
    pub x: f64,
    pub y: f64,
    pub pressure: f64,
    pub azimuth: f64,
    pub altitude: f64,
    #[serde(default)]
    pub rotation: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t: Option<f64>,
}

/// `proximity` (§6.1, pv 3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Proximity {
    pub entering: bool,
    pub x: f64,
    pub y: f64,
}

/// `cursor` (§6.2, §6.3): `v` 1 visible / 0 hidden; `s` is the side-channel
/// sequence number, absent from older senders.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cursor {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    #[serde(deserialize_with = "lenient_u32")]
    pub v: u32,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_opt_u64"
    )]
    pub s: Option<u64>,
}

impl Cursor {
    pub fn visible(&self) -> bool {
        self.v != 0
    }
}

/// `cursorImg` (§6.2): base64 PNG sprite, size normalised to the display,
/// hotspot normalised within the sprite.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CursorImg {
    pub nw: f64,
    pub nh: f64,
    pub ax: f64,
    pub ay: f64,
    pub png: String,
}

/// `welcome` (§6.2): sender's `pv` and the oldest receiver `pv` it supports.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    #[serde(deserialize_with = "lenient_u32")]
    pub pv: u32,
    #[serde(deserialize_with = "lenient_u32")]
    pub min: u32,
}

/// `updateRequired` (§6.2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct UpdateRequired {
    #[serde(default)]
    pub target: String,
    #[serde(default)]
    pub store: String,
    #[serde(default)]
    pub message: String,
}

/// `streamConfig` (§6.2): the sender's selected operating point.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamConfig {
    pub codec: String,
    #[serde(deserialize_with = "lenient_u32")]
    pub width: u32,
    #[serde(deserialize_with = "lenient_u32")]
    pub height: u32,
    #[serde(deserialize_with = "lenient_u32")]
    pub frames_per_second: u32,
}

/// Every control message of `pv` 3, plus [`ControlMessage::Unknown`] for
/// types this implementation predates (§6: ignore, log at most once per type).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ControlMessage {
    // Receiver -> sender (§6.1)
    #[serde(rename = "hello")]
    Hello(Hello),
    #[serde(rename = "ping")]
    Ping(Ping),
    #[serde(rename = "touch")]
    Touch(Touch),
    #[serde(rename = "scroll")]
    Scroll(Scroll),
    #[serde(rename = "pencil")]
    Pencil(Pencil),
    #[serde(rename = "proximity")]
    Proximity(Proximity),
    #[serde(rename = "kf")]
    Kf,
    #[serde(rename = "stats")]
    Stats(Value),
    #[serde(rename = "sleeping")]
    Sleeping,
    #[serde(rename = "closing")]
    Closing,
    #[serde(rename = "cursorAck")]
    CursorAck,
    // Sender -> receiver (§6.2)
    #[serde(rename = "pong")]
    Pong(Pong),
    #[serde(rename = "cursor")]
    Cursor(Cursor),
    #[serde(rename = "cursorImg")]
    CursorImg(CursorImg),
    #[serde(rename = "welcome")]
    Welcome(Welcome),
    #[serde(rename = "updateRequired")]
    UpdateRequired(UpdateRequired),
    #[serde(rename = "streamConfig")]
    StreamConfig(StreamConfig),
    /// A `type` this implementation does not know. Never serialised.
    #[serde(skip)]
    Unknown { kind: String, raw: Value },
}

impl ControlMessage {
    /// Parse a control payload. Unknown types come back as
    /// [`ControlMessage::Unknown`]; only non-JSON / no-`type` payloads and
    /// malformed known types are errors, and callers MUST treat both as
    /// "ignore this frame", never as fatal (§6).
    pub fn parse(payload: &[u8]) -> Result<ControlMessage, ControlError> {
        let value: Value = serde_json::from_slice(payload)
            .map_err(|e| ControlError::Unparseable(e.to_string()))?;
        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| ControlError::Unparseable("no string `type` field".into()))?
            .to_owned();
        match serde_json::from_value::<ControlMessage>(value.clone()) {
            Ok(m) => Ok(m),
            Err(e) if is_known_type(&kind) => Err(ControlError::Malformed {
                kind,
                reason: e.to_string(),
            }),
            Err(_) => Ok(ControlMessage::Unknown { kind, raw: value }),
        }
    }

    /// The `type` discriminator.
    pub fn kind(&self) -> &str {
        match self {
            ControlMessage::Hello(_) => "hello",
            ControlMessage::Ping(_) => "ping",
            ControlMessage::Touch(_) => "touch",
            ControlMessage::Scroll(_) => "scroll",
            ControlMessage::Pencil(_) => "pencil",
            ControlMessage::Proximity(_) => "proximity",
            ControlMessage::Kf => "kf",
            ControlMessage::Stats(_) => "stats",
            ControlMessage::Sleeping => "sleeping",
            ControlMessage::Closing => "closing",
            ControlMessage::CursorAck => "cursorAck",
            ControlMessage::Pong(_) => "pong",
            ControlMessage::Cursor(_) => "cursor",
            ControlMessage::CursorImg(_) => "cursorImg",
            ControlMessage::Welcome(_) => "welcome",
            ControlMessage::UpdateRequired(_) => "updateRequired",
            ControlMessage::StreamConfig(_) => "streamConfig",
            ControlMessage::Unknown { kind, .. } => kind,
        }
    }

    /// Serialise to the JSON payload (without the length prefix), checking
    /// the §4 sender-side constraints.
    pub fn to_payload(&self) -> Result<Vec<u8>, ControlError> {
        if matches!(self, ControlMessage::Unknown { .. }) {
            return Err(ControlError::Malformed {
                kind: self.kind().into(),
                reason: "unknown messages are never sent".into(),
            });
        }
        let bytes = serde_json::to_vec(self).map_err(|e| ControlError::Malformed {
            kind: self.kind().into(),
            reason: e.to_string(),
        })?;
        if !is_valid_control_payload(&bytes) {
            return Err(ControlError::InvalidForWire);
        }
        Ok(bytes)
    }
}

fn is_known_type(kind: &str) -> bool {
    matches!(
        kind,
        "hello"
            | "ping"
            | "touch"
            | "scroll"
            | "pencil"
            | "proximity"
            | "kf"
            | "stats"
            | "sleeping"
            | "closing"
            | "cursorAck"
            | "pong"
            | "cursor"
            | "cursorImg"
            | "welcome"
            | "updateRequired"
            | "streamConfig"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_official_hello_shapes() {
        // From tools/fake-receiver.swift.
        let m = ControlMessage::parse(
            br#"{"type":"hello","pixelsWide":2732,"pixelsHigh":2048,"scale":2,"device":"iPad","id":"FAKE-3"}"#,
        )
        .unwrap();
        let ControlMessage::Hello(h) = m else {
            panic!()
        };
        assert_eq!((h.pixels_wide, h.pixels_high, h.scale), (2732, 2048, 2.0));
        assert_eq!(h.pv, None);
        assert_eq!(h.device.as_deref(), Some("iPad"));
        // pv 3 receiver with floats where ints are expected and unknown fields.
        let m = ControlMessage::parse(
            br#"{"type":"hello","pixelsWide":1920.0,"pixelsHigh":1080,"scale":1,"pv":3,"cursorPort":9001,"addrs":["fe80::1"],"maxEncodeWide":3840,"maxEncodeHigh":2160,"displayMaxFrameRate":120,"videoCaps":[{"codec":"h264","maxWidth":4096,"maxHeight":2304,"maxPixelsPerSecond":530841600,"future":1}],"future":true}"#,
        )
        .unwrap();
        let ControlMessage::Hello(h) = m else {
            panic!()
        };
        assert_eq!(h.pv, Some(3));
        assert_eq!(h.cursor_port, Some(9001));
        assert_eq!(
            h.video_caps.unwrap()[0].max_pixels_per_second,
            Some(530_841_600)
        );
    }

    fn hello(json: &str) -> Hello {
        match ControlMessage::parse(json.as_bytes()) {
            Ok(ControlMessage::Hello(h)) => h,
            other => panic!("{json}: {other:?}"),
        }
    }

    fn with_panel(panel: &str) -> Hello {
        hello(&format!(
            r#"{{"type":"hello","pixelsWide":5120,"pixelsHigh":2880,"scale":2,"panel":{panel}}}"#
        ))
    }

    #[test]
    fn parses_panel_facts() {
        // The Mac receiver's shape (MacReceiver.swift `announcePanel`).
        let h = with_panel(
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":2,"pointsWide":2560,"pointsHigh":1440,"future":1}"#,
        );
        assert_eq!(
            h.panel_facts(),
            Some(PanelFacts {
                pixels_wide: 5120,
                pixels_high: 2880,
                scale: 2.0,
                points: Some((2560, 1440)),
            })
        );
        assert!(!h.has_invalid_panel());
        // iOS: no points; a fractional scale and float-typed integers are fine.
        let h = with_panel(r#"{"pixelsWide":2556.0,"pixelsHigh":1179,"scale":2.608}"#);
        let f = h.panel_facts().unwrap();
        assert_eq!(
            (f.pixels_wide, f.pixels_high, f.scale, f.points),
            (2556, 1179, 2.608, None)
        );
        // Absent panel: nothing to ignore.
        let h = hello(r#"{"type":"hello","pixelsWide":2732,"pixelsHigh":2048,"scale":2}"#);
        assert_eq!(h.panel, None);
        assert!(!h.has_invalid_panel());
        let h = with_panel("null");
        assert_eq!(h.panel, None);
    }

    #[test]
    fn invalid_panel_is_ignored_whole_and_never_fails_the_hello() {
        for panel in [
            r#"{"pixelsHigh":2880,"scale":2}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880}"#,
            r#"{"pixelsWide":1,"pixelsHigh":2880,"scale":2}"#,
            r#"{"pixelsWide":-5120,"pixelsHigh":2880,"scale":2}"#,
            r#"{"pixelsWide":5120.5,"pixelsHigh":2880,"scale":2}"#,
            r#"{"pixelsWide":"5120","pixelsHigh":2880,"scale":2}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":0}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":-1}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":"2"}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":2,"pointsWide":2560}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":2,"pointsWide":2560,"pointsHigh":1}"#,
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":2,"pointsWide":2560,"pointsHigh":null}"#,
            r#"{"pixelsWide":99999999999,"pixelsHigh":2880,"scale":2}"#,
            r#""5120x2880""#,
            r#"[5120,2880,2]"#,
        ] {
            let h = with_panel(panel);
            assert!(h.has_invalid_panel(), "{panel}");
            assert_eq!(h.panel_facts(), None, "{panel}");
            // The deprecated fields still carry the hello.
            assert_eq!((h.pixels_wide, h.pixels_high), (5120, 2880), "{panel}");
        }
    }

    #[test]
    fn power_is_parsed_leniently() {
        let h = hello(
            r#"{"type":"hello","pixelsWide":5120,"pixelsHigh":2880,"scale":2,"power":["shutdown","reboot"]}"#,
        );
        assert_eq!(h.power, Some(vec!["shutdown".into(), "reboot".into()]));
        let h = hello(
            r#"{"type":"hello","pixelsWide":5120,"pixelsHigh":2880,"scale":2,"power":["shutdown",7]}"#,
        );
        assert_eq!(h.power, Some(vec!["shutdown".into()]));
        let h = hello(
            r#"{"type":"hello","pixelsWide":5120,"pixelsHigh":2880,"scale":2,"power":"shutdown"}"#,
        );
        assert_eq!(h.power, None);
        let h = hello(r#"{"type":"hello","pixelsWide":5120,"pixelsHigh":2880,"scale":2}"#);
        assert_eq!(h.power, None);
    }

    /// The next bump drops the deprecated fields (§6.1); such a `hello`
    /// must still parse, with the panel carrying the facts.
    #[test]
    fn a_panel_only_hello_parses() {
        let h = hello(
            r#"{"type":"hello","pv":4,"panel":{"pixelsWide":2556,"pixelsHigh":1179,"scale":3}}"#,
        );
        assert_eq!((h.pixels_wide, h.pixels_high, h.scale), (0, 0, 0.0));
        let f = h.panel_facts().expect("panel facts");
        assert_eq!((f.pixels_wide, f.pixels_high, f.scale), (2556, 1179, 3.0));
    }

    #[test]
    fn hello_with_panel_round_trips() {
        let h = with_panel(
            r#"{"pixelsWide":5120,"pixelsHigh":2880,"scale":2,"pointsWide":2560,"pointsHigh":1440}"#,
        );
        let p = ControlMessage::Hello(h.clone()).to_payload().unwrap();
        assert_eq!(
            p,
            br#"{"type":"hello","pixelsWide":5120,"pixelsHigh":2880,"scale":2.0,"panel":{"pixelsWide":5120,"pixelsHigh":2880,"scale":2.0,"pointsWide":2560,"pointsHigh":1440}}"#
        );
        assert_eq!(ControlMessage::parse(&p).unwrap(), ControlMessage::Hello(h));
    }

    #[test]
    fn unknown_type_is_not_an_error_and_unknown_fields_are_ignored() {
        let m = ControlMessage::parse(br#"{"type":"holo","x":1}"#).unwrap();
        assert!(matches!(m, ControlMessage::Unknown { ref kind, .. } if kind == "holo"));
        let m = ControlMessage::parse(br#"{"type":"kf","extra":[1,2,3]}"#).unwrap();
        assert_eq!(m, ControlMessage::Kf);
        let m =
            ControlMessage::parse(br#"{"type":"pong","t":1.5,"mt":2,"whatever":null}"#).unwrap();
        assert_eq!(m, ControlMessage::Pong(Pong { t: 1.5, mt: 2.0 }));
    }

    #[test]
    fn garbage_and_malformed_are_errors_to_ignore() {
        assert!(matches!(
            ControlMessage::parse(b"nope"),
            Err(ControlError::Unparseable(_))
        ));
        assert!(matches!(
            ControlMessage::parse(b"{\"x\":1}"),
            Err(ControlError::Unparseable(_))
        ));
        assert!(matches!(
            ControlMessage::parse(b"{\"type\":\"pong\"}"),
            Err(ControlError::Malformed { .. })
        ));
    }

    #[test]
    fn serialises_with_type_tag_and_camel_case() {
        let p = ControlMessage::Welcome(Welcome { pv: 3, min: 1 })
            .to_payload()
            .unwrap();
        assert_eq!(p, br#"{"type":"welcome","pv":3,"min":1}"#);
        let p = ControlMessage::Kf.to_payload().unwrap();
        assert_eq!(p, br#"{"type":"kf"}"#);
        let p = ControlMessage::StreamConfig(StreamConfig {
            codec: "h264".into(),
            width: 1920,
            height: 1080,
            frames_per_second: 60,
        })
        .to_payload()
        .unwrap();
        assert_eq!(p, br#"{"type":"streamConfig","codec":"h264","width":1920,"height":1080,"framesPerSecond":60}"#);
        let p = ControlMessage::Cursor(Cursor {
            x: Some(0.5),
            y: Some(0.25),
            v: 1,
            s: Some(88),
        })
        .to_payload()
        .unwrap();
        assert_eq!(p, br#"{"type":"cursor","x":0.5,"y":0.25,"v":1,"s":88}"#);
        let p = ControlMessage::Hello(Hello {
            pixels_wide: 2560,
            pixels_high: 1600,
            scale: 2.0,
            pv: Some(3),
            ..Default::default()
        })
        .to_payload()
        .unwrap();
        assert_eq!(
            p,
            br#"{"type":"hello","pixelsWide":2560,"pixelsHigh":1600,"scale":2.0,"pv":3}"#
        );
    }

    #[test]
    fn oversize_control_message_is_rejected_for_the_wire() {
        let png = "A".repeat(40_000);
        let r = ControlMessage::CursorImg(CursorImg {
            nw: 0.01,
            nh: 0.01,
            ax: 0.0,
            ay: 0.0,
            png,
        })
        .to_payload();
        assert_eq!(r, Err(ControlError::InvalidForWire));
    }

    #[test]
    fn round_trips_every_variant() {
        let msgs = vec![
            ControlMessage::Ping(Ping {
                t: Some(1.0),
                ..Default::default()
            }),
            ControlMessage::Touch(Touch {
                phase: TouchPhase::Began,
                x: 0.1,
                y: 0.2,
                t: None,
            }),
            ControlMessage::Scroll(Scroll { dx: -3.0, dy: 12.5 }),
            ControlMessage::Pencil(Pencil {
                phase: PencilPhase::Hover,
                x: 0.0,
                y: 1.0,
                pressure: 0.0,
                azimuth: 0.1,
                altitude: 1.5,
                rotation: 0.0,
                t: Some(3.0),
            }),
            ControlMessage::Proximity(Proximity {
                entering: true,
                x: 0.5,
                y: 0.5,
            }),
            ControlMessage::Stats(serde_json::json!({"fps": 60, "transport": "wifi"})),
            ControlMessage::Sleeping,
            ControlMessage::Closing,
            ControlMessage::CursorAck,
            ControlMessage::UpdateRequired(UpdateRequired {
                target: "ios".into(),
                store: "https://x".into(),
                message: "m".into(),
            }),
        ];
        for m in msgs {
            let p = m.to_payload().unwrap();
            assert_eq!(
                ControlMessage::parse(&p).unwrap(),
                m,
                "{}",
                String::from_utf8_lossy(&p)
            );
        }
    }
}
