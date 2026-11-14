//! Cursor state shared by the TCP and UDP receive paths and the present thread (PROTOCOL.md §6.2, §6.3).

use serde::Deserialize;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// 24 bits per normalized coordinate: finer than a pixel at any video size.
const MASK: u64 = 0xFF_FFFF;
const VISIBLE: u64 = 1 << 48;

/// A `cursorImg` waiting for the present thread to decode it.
pub struct Sprite {
    pub nw: f64,
    pub nh: f64,
    pub ax: f64,
    pub ay: f64,
    pub png: String,
}

#[derive(Default)]
pub struct Cursor {
    /// Highest `s` accepted; 0 means none yet (`s` starts at 1). Writers hold it while
    /// publishing `pos`, so positions from the TCP and UDP threads land in `s` order.
    seq: Mutex<u64>,
    /// x | y << 24 | visible << 48. The present thread reads it without locking.
    pos: AtomicU64,
    /// Bumped per TCP connection; the UDP thread then treats the next datagram as a new flow.
    pub conn: AtomicU64,
    /// Messages dropped because their `s` was not greater than the highest seen.
    pub stale: AtomicU64,
    pub sprite: Mutex<Option<Sprite>>,
    /// A wake-up for the present thread is already queued.
    pub woken: AtomicBool,
}

impl Cursor {
    /// Applies a `cursor` message. Returns (accepted, position or visibility changed).
    pub fn apply(&self, x: Option<f64>, y: Option<f64>, v: f64, s: Option<f64>) -> (bool, bool) {
        let mut hi = self.seq.lock().unwrap();
        if let Some(s) = s {
            if s <= *hi as f64 || s.is_nan() {
                self.stale.fetch_add(1, Ordering::Relaxed);
                return (false, false);
            }
            *hi = s as u64;
        }
        let old = self.pos.load(Ordering::Relaxed);
        // Absent x/y (allowed when hidden) keep the last position.
        let q = |n: Option<f64>, old: u64| {
            n.map_or(old, |n| (n.clamp(0.0, 1.0) * MASK as f64).round() as u64)
        };
        let new =
            q(x, old & MASK) | q(y, old >> 24 & MASK) << 24 | if v != 0.0 { VISIBLE } else { 0 };
        self.pos.store(new, Ordering::Release);
        (true, new != old)
    }

    /// New UDP flow: the sequence restarts (§6.3).
    pub fn new_flow(&self) {
        *self.seq.lock().unwrap() = 0;
    }

    /// New TCP connection: sequence restarts, cursor hidden until the sender says otherwise.
    pub fn new_connection(&self) {
        let mut hi = self.seq.lock().unwrap();
        *hi = 0;
        self.pos.store(0, Ordering::Release);
        self.conn.fetch_add(1, Ordering::AcqRel);
    }

    /// Packed state; compare to detect changes, [`Cursor::unpack`] to draw.
    pub fn raw(&self) -> u64 {
        self.pos.load(Ordering::Acquire)
    }

    /// Normalized video position, or None while hidden.
    pub fn unpack(raw: u64) -> Option<(f32, f32)> {
        (raw & VISIBLE != 0).then(|| {
            (
                (raw & MASK) as f32 / MASK as f32,
                (raw >> 24 & MASK) as f32 / MASK as f32,
            )
        })
    }
}

/// One UDP datagram (§6.3). Borrowed and flat, so parsing it does not allocate.
#[derive(Deserialize)]
pub struct Datagram<'a> {
    #[serde(rename = "type", borrow)]
    pub t: &'a str,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub v: f64,
    /// Required on UDP; only TCP may omit it.
    pub s: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequence_drops_stale_and_duplicates() {
        let c = Cursor::default();
        assert_eq!(c.apply(Some(0.5), Some(0.25), 1.0, Some(1.0)), (true, true));
        assert_eq!(c.apply(Some(0.6), Some(0.25), 1.0, Some(3.0)), (true, true));
        assert_eq!(
            c.apply(Some(0.1), Some(0.1), 1.0, Some(2.0)),
            (false, false),
            "reordered"
        );
        assert_eq!(
            c.apply(Some(0.1), Some(0.1), 1.0, Some(3.0)),
            (false, false),
            "duplicate (TCP mirror)"
        );
        assert_eq!(c.stale.load(Ordering::Relaxed), 2);
        let (x, y) = Cursor::unpack(c.raw()).unwrap();
        assert!((x - 0.6).abs() < 1e-6 && (y - 0.25).abs() < 1e-6);
        assert_eq!(
            c.apply(Some(0.6), Some(0.25), 1.0, Some(4.0)),
            (true, false),
            "same position"
        );
    }

    #[test]
    fn tcp_without_s_applies_unconditionally() {
        let c = Cursor::default();
        c.apply(Some(0.5), Some(0.5), 1.0, Some(10.0));
        assert_eq!(c.apply(Some(0.2), Some(0.2), 1.0, None), (true, true));
        assert_eq!(
            c.apply(Some(0.3), Some(0.3), 1.0, Some(10.0)),
            (false, false),
            "highest s is still 10"
        );
    }

    #[test]
    fn resets_and_hidden() {
        let c = Cursor::default();
        c.apply(Some(1.0), Some(0.0), 1.0, Some(50.0));
        c.new_flow();
        assert!(
            c.apply(Some(0.0), Some(1.0), 1.0, Some(1.0)).0,
            "new flow restarts at 1"
        );
        assert_eq!(c.apply(None, None, 0.0, Some(2.0)), (true, true));
        assert_eq!(Cursor::unpack(c.raw()), None);
        assert_eq!(c.apply(None, None, 1.0, Some(3.0)), (true, true));
        assert_eq!(
            Cursor::unpack(c.raw()),
            Some((0.0, 1.0)),
            "hidden without x/y keeps the position"
        );
        c.new_connection();
        assert_eq!(Cursor::unpack(c.raw()), None);
        assert!(c.apply(Some(0.5), Some(0.5), 1.0, Some(1.0)).0);
        assert_eq!(
            c.apply(Some(9.0), Some(f64::NAN), 1.0, Some(f64::NAN)),
            (false, false)
        );
    }

    #[test]
    fn datagram_parse() {
        let d: Datagram = serde_json::from_slice(
            br#"{"type":"cursor","x":0.4210,"y":0.7735,"v":1,"s":88,"extra":[1]}"#,
        )
        .unwrap();
        assert_eq!(
            (d.t, d.x, d.y, d.v, d.s),
            ("cursor", Some(0.421), Some(0.7735), 1.0, 88.0)
        );
        assert!(
            serde_json::from_slice::<Datagram>(br#"{"type":"cursor","v":1}"#).is_err(),
            "s is required"
        );
    }
}
