//! The pointer over the virtual display, for the cursor side channel
//! (PROTOCOL §6.2/§6.3): the sprite from XFixes whenever it changes, the
//! position from `QueryPointer` at up to 120 Hz.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tracing::debug;
use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::xfixes::{self, ConnectionExt as _};
use x11rb::protocol::xproto::ConnectionExt as _;

use super::capture::Rect;
use crate::backend::{CursorEvent, CursorSink};
use crate::bounded::{BoundedThread, DROP_JOIN};
use crate::wayland::cursor::{SpriteOrder, premul_to_rgba, sprite_png};

/// The official sender's ceiling for position updates (PROTOCOL §6.2).
const POLL: Duration = Duration::from_micros(8_333);

/// Where a root position lands on the display, normalized; `None` off it.
pub fn normalize(r: Rect, x: i32, y: i32) -> Option<(f64, f64)> {
    let (px, py) = (x - r.x, y - r.y);
    (px >= 0 && py >= 0 && px < r.w as i32 && py < r.h as i32)
        .then(|| (px as f64 / r.w as f64, py as f64 / r.h as f64))
}

pub struct CursorThread {
    stop: Arc<AtomicBool>,
    thread: Option<BoundedThread>,
}

impl CursorThread {
    pub fn spawn(display: Option<&str>, rect: Rect, mut sink: CursorSink) -> Result<Self> {
        let (conn, screen) = x11rb::connect(display).context("connecting to the X server")?;
        let root = conn.setup().roots[screen].root;
        conn.xfixes_query_version(4, 0)?
            .reply()
            .context("the X server has no XFixes extension")?;
        conn.xfixes_select_cursor_input(root, xfixes::CursorNotifyMask::DISPLAY_CURSOR)?
            .check()?;
        let stop = Arc::new(AtomicBool::new(false));
        let stop_t = stop.clone();
        let thread = BoundedThread::spawn("x11-cursor", move || {
            let mut stale = true;
            let mut last_sprite: Option<(Vec<u32>, u16, u16, u16, u16)> = None;
            let mut last: Option<Option<(f64, f64)>> = None;
            let mut next = Instant::now();
            while !stop_t.load(Ordering::Relaxed) {
                loop {
                    match conn.poll_for_event() {
                        Ok(Some(Event::XfixesCursorNotify(_))) => stale = true,
                        Ok(Some(_)) => {}
                        Ok(None) => break,
                        Err(e) => {
                            sink(CursorEvent::SpriteUnavailable(format!("X connection: {e}")));
                            return;
                        }
                    }
                }
                if stale {
                    stale = false;
                    if let Some(c) = conn
                        .xfixes_get_cursor_image()
                        .ok()
                        .and_then(|c| c.reply().ok())
                        .filter(|c| c.width > 0 && c.height > 0)
                    {
                        let key = (c.cursor_image, c.width, c.height, c.xhot, c.yhot);
                        if last_sprite.as_ref() != Some(&key) {
                            let (w, h) = (key.1 as u32, key.2 as u32);
                            let bytes: Vec<u8> =
                                key.0.iter().flat_map(|p| p.to_le_bytes()).collect();
                            let rgba = premul_to_rgba(&bytes, SpriteOrder::Bgra, w, h, w * 4);
                            let png = sprite_png(rgba, w, h);
                            debug!("cursor sprite {w}x{h}: {} bytes PNG", png.len());
                            sink(CursorEvent::Image {
                                png,
                                nw: w as f64 / rect.w as f64,
                                nh: h as f64 / rect.h as f64,
                                ax: key.3 as f64 / w as f64,
                                ay: key.4 as f64 / h as f64,
                            });
                            last_sprite = Some(key);
                        }
                    }
                }
                match conn.query_pointer(root).map(|c| c.reply()) {
                    Ok(Ok(p)) => {
                        let at = if p.same_screen {
                            normalize(rect, p.root_x as i32, p.root_y as i32)
                        } else {
                            None
                        };
                        if last != Some(at) {
                            sink(match at {
                                Some((x, y)) => CursorEvent::Moved { x, y },
                                None => CursorEvent::Hidden,
                            });
                            last = Some(at);
                        }
                    }
                    Ok(Err(e)) => debug!("query pointer: {e}"),
                    Err(e) => {
                        sink(CursorEvent::SpriteUnavailable(format!("X connection: {e}")));
                        return;
                    }
                }
                next += POLL;
                let now = Instant::now();
                if next > now {
                    std::thread::sleep(next - now);
                } else {
                    next = now;
                }
            }
        })?;
        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(mut t) = self.thread.take() {
            t.join_within(DROP_JOIN);
        }
    }
}

impl Drop for CursorThread {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn positions_normalize_to_the_display() {
        let r = Rect {
            x: 3840,
            y: 0,
            w: 392,
            h: 844,
        };
        assert_eq!(normalize(r, 3840, 0), Some((0.0, 0.0)));
        assert_eq!(normalize(r, 3840 + 196, 422), Some((0.5, 0.5)));
        assert_eq!(normalize(r, 3839, 10), None);
        assert_eq!(normalize(r, 3840 + 392, 10), None);
    }
}
