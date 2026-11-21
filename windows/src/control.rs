//! JSON control messages (PROTOCOL.md §6). Numbers are parsed as f64 because the wire
//! does not distinguish int from float.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Sender-to-receiver messages (§6.2). Unknown fields are ignored by serde's default.
#[derive(Debug, Deserialize, PartialEq)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Incoming {
    Pong {
        t: f64,
        mt: f64,
    },
    /// Sender liveness beat; its optional health counters are informational only.
    Ping(SenderHealth),
    Cursor {
        x: Option<f64>,
        y: Option<f64>,
        v: f64,
        s: Option<f64>,
    },
    CursorImg {
        nw: f64,
        nh: f64,
        ax: f64,
        ay: f64,
        png: String,
    },
    Welcome {
        pv: f64,
        #[serde(default = "one")]
        min: f64,
    },
    UpdateRequired {
        target: Option<String>,
        store: Option<String>,
        message: Option<String>,
    },
    StreamConfig {
        codec: String,
        width: Option<f64>,
        height: Option<f64>,
        frames_per_second: Option<f64>,
    },
    /// Never obeyed: we do not list `power` in hello (§6.6).
    Power {},
}

/// Send-side counters the official sender piggybacks on `ping` (§6.2), shown in the overlay.
#[derive(Debug, Deserialize, Default, Clone, Copy, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SenderHealth {
    pub drops: Option<f64>,
    pub enc_drops: Option<f64>,
    pub net_drops: Option<f64>,
    pub pending: Option<f64>,
    pub inp50: Option<f64>,
    pub inp95: Option<f64>,
    pub cap_fps: Option<f64>,
}

fn one() -> f64 {
    1.0
}

/// Parses control payloads, ignoring unknown types and malformed messages (§6),
/// logging each distinct type at most once.
#[derive(Default)]
pub struct ControlParser {
    logged: HashSet<String>,
}

impl ControlParser {
    pub fn parse(&mut self, payload: &[u8]) -> Option<Incoming> {
        let err = match serde_json::from_slice(payload) {
            Ok(m) => return Some(m),
            Err(e) => e,
        };
        #[derive(Deserialize)]
        struct Tag {
            #[serde(rename = "type")]
            t: String,
        }
        let key =
            serde_json::from_slice::<Tag>(payload).map_or_else(|_| "<no type>".into(), |t| t.t);
        if !self.logged.contains(&key) {
            log::info!("ignoring control message type {key:?}: {err}");
            self.logged.insert(key);
        }
        None
    }
}

#[derive(Debug, Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum TouchPhase {
    Began,
    Moved,
    Ended,
    Cancelled,
}

#[derive(Debug, Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum PencilPhase {
    Down,
    Move,
    Up,
    Hover,
}

/// Facts about the panel in its current orientation (§6.7).
#[derive(Debug, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Panel {
    pub pixels_wide: u32,
    pub pixels_high: u32,
    pub scale: f64,
}

#[derive(Debug, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    /// Deprecated in favor of `panel`; still sent for older senders (physical pixels, iOS semantics).
    pub pixels_wide: u32,
    pub pixels_high: u32,
    pub scale: f64,
    pub panel: Panel,
    pub device: String,
    pub id: String,
    pub pv: u32,
    pub display_max_frame_rate: u32,
    pub max_encode_wide: u32,
    pub max_encode_high: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_port: Option<u16>,
}

/// Free-form receiver telemetry (§6.1 `stats`), sent about every 5 s. Times in ms.
#[derive(Debug, Serialize, Default, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub transport: &'static str,
    pub fps: f64,
    pub mbps: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dec50: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ph50: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ph95: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub e2e50: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub e2e95: Option<f64>,
    pub offset_known: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtt: Option<f64>,
    /// Decoded frames never shown because a newer one replaced them first.
    pub stalls: u64,
    pub kf: u64,
    pub drops: u64,
}

/// Receiver-to-sender messages (§6.1).
#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Outgoing {
    Hello(Hello),
    Ping {
        t: u64,
    },
    Touch {
        phase: TouchPhase,
        x: f64,
        y: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        t: Option<f64>,
    },
    Scroll {
        dx: f64,
        dy: f64,
    },
    Pencil {
        phase: PencilPhase,
        x: f64,
        y: f64,
        pressure: f64,
        azimuth: f64,
        altitude: f64,
        rotation: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        t: Option<f64>,
    },
    Proximity {
        entering: bool,
        x: f64,
        y: f64,
    },
    Kf,
    Sleeping,
    Closing,
    CursorAck,
    Stats(Stats),
}

impl Outgoing {
    pub fn to_json(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("control messages always serialize")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn parse(s: &str) -> Option<Incoming> {
        ControlParser::default().parse(s.as_bytes())
    }

    #[test]
    fn parses_known_types_with_int_or_float_numbers() {
        assert_eq!(
            parse(r#"{"type":"pong","t":1730000000000,"mt":1730000000005.5}"#),
            Some(Incoming::Pong {
                t: 1730000000000.0,
                mt: 1730000000005.5
            })
        );
        assert_eq!(
            parse(r#"{"type":"cursor","x":0.4210,"y":0.7735,"v":1,"s":88}"#),
            Some(Incoming::Cursor {
                x: Some(0.421),
                y: Some(0.7735),
                v: 1.0,
                s: Some(88.0)
            })
        );
        assert_eq!(
            parse(r#"{"type":"welcome","pv":3}"#),
            Some(Incoming::Welcome { pv: 3.0, min: 1.0 })
        );
        assert_eq!(
            parse(
                r#"{"type":"streamConfig","codec":"h264","width":1920,"height":1080,"framesPerSecond":60}"#
            ),
            Some(Incoming::StreamConfig {
                codec: "h264".into(),
                width: Some(1920.0),
                height: Some(1080.0),
                frames_per_second: Some(60.0)
            })
        );
    }

    #[test]
    fn optional_and_unknown_fields() {
        // Hidden cursor may omit x/y; unknown fields on known types are ignored.
        assert_eq!(
            parse(r#"{"type":"cursor","v":0,"future":true}"#),
            Some(Incoming::Cursor {
                x: None,
                y: None,
                v: 0.0,
                s: None
            })
        );
        assert_eq!(
            parse(r#"{"type":"ping","encDrops":2,"capFps":59.9}"#),
            Some(Incoming::Ping(SenderHealth {
                enc_drops: Some(2.0),
                cap_fps: Some(59.9),
                ..Default::default()
            }))
        );
        assert_eq!(
            parse(r#"{"type":"ping"}"#),
            Some(Incoming::Ping(SenderHealth::default()))
        );
    }

    #[test]
    fn unknown_and_malformed_are_ignored_and_logged_once() {
        let mut p = ControlParser::default();
        for _ in 0..3 {
            assert_eq!(p.parse(br#"{"type":"teleport","x":1}"#), None);
        }
        assert_eq!(p.parse(b"{not json"), None);
        assert_eq!(p.parse(br#"{"no":"type"}"#), None);
        assert_eq!(p.parse(br#"{"type":"pong","t":"bad"}"#), None);
        assert_eq!(p.logged.len(), 3, "{:?}", p.logged); // teleport, <no type>, pong
    }

    #[test]
    fn outgoing_shapes() {
        let v = |m: Outgoing| serde_json::from_slice::<Value>(&m.to_json()).unwrap();
        assert_eq!(v(Outgoing::Kf), json!({"type":"kf"}));
        assert_eq!(v(Outgoing::CursorAck), json!({"type":"cursorAck"}));
        assert_eq!(v(Outgoing::Ping { t: 5 }), json!({"type":"ping","t":5}));
        assert_eq!(
            v(Outgoing::Stats(Stats {
                transport: "wifi",
                fps: 60.0,
                dec50: Some(0.2),
                stalls: 1,
                ..Default::default()
            })),
            json!({"type":"stats","transport":"wifi","fps":60.0,"mbps":0.0,"dec50":0.2,"offsetKnown":false,"stalls":1,"kf":0,"drops":0})
        );
        assert_eq!(
            v(Outgoing::Touch {
                phase: TouchPhase::Cancelled,
                x: 0.5,
                y: 0.25,
                t: None
            }),
            json!({"type":"touch","phase":"cancelled","x":0.5,"y":0.25})
        );
        let hello = Hello {
            pixels_wide: 2560,
            pixels_high: 1440,
            scale: 1.5,
            panel: Panel {
                pixels_wide: 2560,
                pixels_high: 1440,
                scale: 1.5,
            },
            device: "Windows".into(),
            id: "abc".into(),
            pv: 3,
            display_max_frame_rate: 144,
            max_encode_wide: 4096,
            max_encode_high: 2304,
            cursor_port: Some(9001),
        };
        assert_eq!(
            v(Outgoing::Hello(hello)),
            json!({"type":"hello","pixelsWide":2560,"pixelsHigh":1440,"scale":1.5,
                   "panel":{"pixelsWide":2560,"pixelsHigh":1440,"scale":1.5},
                   "device":"Windows","id":"abc","pv":3,"displayMaxFrameRate":144,
                   "maxEncodeWide":4096,"maxEncodeHigh":2304,"cursorPort":9001})
        );
    }
}
