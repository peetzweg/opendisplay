//! Touch and scroll (§6.1) as XTest pointer events. The requests go out on
//! their own thread and connection, and queued motion is coalesced, so a
//! burst of touch moves never backs up behind the X server.

use std::sync::mpsc;

use anyhow::{Context, Result};
use opendisplay_proto::control::{Scroll, Touch, TouchPhase};
use tracing::{debug, warn};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, MOTION_NOTIFY_EVENT};
use x11rb::protocol::xtest::ConnectionExt as _;

use super::capture::Rect;
use crate::backend::InputSink;
use crate::bounded::{BoundedThread, DROP_JOIN};

/// Wheel clicks for a two-finger scroll across the display's full height.
/// X11 has no smooth scrolling through XTest, only buttons 4 to 7.
const CLICKS_PER_HEIGHT: f64 = 100.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Call {
    /// Absolute, root window coordinates.
    Motion(i32, i32),
    Button(u8, bool),
}

/// Pure mapping, for tests: normalized touch (§7) to root coordinates on
/// the display; scroll deltas (video pixels, natural-scrolling sign) to
/// wheel clicks.
pub struct Mapper {
    rect: Rect,
    step: f64,
    pressed: bool,
    acc: (f64, f64),
}

impl Mapper {
    pub fn new(rect: Rect) -> Self {
        Self {
            rect,
            step: (rect.h as f64 / CLICKS_PER_HEIGHT).max(1.0),
            pressed: false,
            acc: (0.0, 0.0),
        }
    }

    pub fn touch(&mut self, t: &Touch) -> Vec<Call> {
        let r = self.rect;
        let x = r.x + (t.x.clamp(0.0, 1.0) * (r.w - 1) as f64).round() as i32;
        let y = r.y + (t.y.clamp(0.0, 1.0) * (r.h - 1) as f64).round() as i32;
        let mut out = vec![Call::Motion(x, y)];
        match t.phase {
            TouchPhase::Began if !self.pressed => {
                self.pressed = true;
                out.push(Call::Button(1, true));
            }
            TouchPhase::Ended | TouchPhase::Cancelled if self.pressed => {
                self.pressed = false;
                out.push(Call::Button(1, false));
            }
            _ => {}
        }
        out
    }

    /// Content follows the fingers: dragging down (dy > 0) scrolls up,
    /// button 4; right (dx > 0) scrolls left, button 6.
    pub fn scroll(&mut self, s: &Scroll) -> Vec<Call> {
        let mut out = Vec::new();
        self.acc.0 += s.dx;
        self.acc.1 += s.dy;
        for (acc, pos, neg) in [(&mut self.acc.1, 4u8, 5u8), (&mut self.acc.0, 6, 7)] {
            while acc.abs() >= self.step {
                let b = if *acc > 0.0 { pos } else { neg };
                out.push(Call::Button(b, true));
                out.push(Call::Button(b, false));
                *acc -= self.step.copysign(*acc);
            }
        }
        out
    }

    pub fn release(&mut self) -> Vec<Call> {
        if std::mem::take(&mut self.pressed) {
            vec![Call::Button(1, false)]
        } else {
            vec![]
        }
    }
}

enum Cmd {
    Touch(Touch),
    Scroll(Scroll),
}

pub struct XTestInput {
    tx: Option<mpsc::Sender<Cmd>>,
    thread: BoundedThread,
}

impl XTestInput {
    pub fn start(display: Option<&str>, mut mapper: Mapper) -> Result<Self> {
        let (conn, screen) = x11rb::connect(display).context("connecting to the X server")?;
        let root = conn.setup().roots[screen].root;
        conn.xtest_get_version(2, 2)?
            .reply()
            .context("the X server has no XTEST extension")?;
        let (tx, rx) = mpsc::channel::<Cmd>();
        let thread = BoundedThread::spawn("x11-input", move || {
            let send = |c: Call| {
                let r = match c {
                    Call::Motion(x, y) => conn.xtest_fake_input(
                        MOTION_NOTIFY_EVENT,
                        0,
                        x11rb::CURRENT_TIME,
                        root,
                        x as i16,
                        y as i16,
                        0,
                    ),
                    Call::Button(b, down) => conn.xtest_fake_input(
                        if down {
                            BUTTON_PRESS_EVENT
                        } else {
                            BUTTON_RELEASE_EVENT
                        },
                        b,
                        x11rb::CURRENT_TIME,
                        root,
                        0,
                        0,
                        0,
                    ),
                };
                if let Err(e) = r {
                    warn!("input: {e}");
                }
            };
            while let Ok(first) = rx.recv() {
                let mut calls = Vec::new();
                for cmd in std::iter::once(first).chain(rx.try_iter()) {
                    calls.extend(match cmd {
                        Cmd::Touch(t) => mapper.touch(&t),
                        Cmd::Scroll(s) => mapper.scroll(&s),
                    });
                }
                // Only the last of consecutive moves matters.
                let mut i = 0;
                while i < calls.len() {
                    let skip = matches!(calls[i], Call::Motion(..))
                        && matches!(calls.get(i + 1), Some(Call::Motion(..)));
                    if !skip {
                        send(calls[i]);
                    }
                    i += 1;
                }
                let _ = conn.flush();
            }
            mapper.release().into_iter().for_each(send);
            let _ = conn.flush();
            debug!("x11 input thread done");
        })?;
        Ok(Self {
            tx: Some(tx),
            thread,
        })
    }

    fn send(&self, cmd: Cmd) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(cmd);
        }
    }
}

impl Drop for XTestInput {
    /// Ends the command loop and waits (bounded) for the button release.
    fn drop(&mut self) {
        self.tx = None;
        self.thread.join_within(DROP_JOIN);
    }
}

impl InputSink for XTestInput {
    fn touch(&mut self, t: &Touch) {
        self.send(Cmd::Touch(t.clone()));
    }

    fn scroll(&mut self, s: &Scroll) {
        self.send(Cmd::Scroll(s.clone()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const R: Rect = Rect {
        x: 3840,
        y: 0,
        w: 392,
        h: 844,
    };

    fn touch(phase: TouchPhase, x: f64, y: f64) -> Touch {
        Touch {
            phase,
            x,
            y,
            t: None,
        }
    }

    #[test]
    fn taps_land_on_the_display_and_click_once() {
        let mut m = Mapper::new(R);
        assert_eq!(
            m.touch(&touch(TouchPhase::Began, 0.5, 0.5)),
            [Call::Motion(3840 + 196, 422), Call::Button(1, true)]
        );
        assert_eq!(m.touch(&touch(TouchPhase::Began, 0.5, 0.5)).len(), 1);
        assert_eq!(
            m.touch(&touch(TouchPhase::Moved, 2.0, -1.0)),
            [Call::Motion(3840 + 391, 0)]
        );
        assert_eq!(
            m.touch(&touch(TouchPhase::Ended, 0.0, 1.0)),
            [Call::Motion(3840, 843), Call::Button(1, false)]
        );
        assert!(m.release().is_empty());
        m.touch(&touch(TouchPhase::Began, 0.1, 0.1));
        assert_eq!(m.release(), [Call::Button(1, false)]);
    }

    #[test]
    fn scroll_accumulates_into_wheel_clicks() {
        let mut m = Mapper::new(R); // step 8.44 video pixels
        assert!(m.scroll(&Scroll { dx: 0.0, dy: 5.0 }).is_empty());
        assert_eq!(
            m.scroll(&Scroll { dx: 0.0, dy: 5.0 }),
            [Call::Button(4, true), Call::Button(4, false)]
        );
        let up = m.scroll(&Scroll { dx: 0.0, dy: -20.0 });
        assert_eq!(up.len(), 4, "{up:?}");
        assert!(up.iter().all(|c| matches!(c, Call::Button(5, _))));
        let side = m.scroll(&Scroll { dx: 9.0, dy: 0.0 });
        assert_eq!(side, [Call::Button(6, true), Call::Button(6, false)]);
    }
}
