//! Touch and scroll (§6.1) as RemoteDesktop pointer events on the virtual
//! monitor's stream. The D-Bus calls run on their own thread so a slow reply
//! never stalls the session loop.

use std::sync::mpsc;

use opendisplay_proto::control::{Scroll, Touch, TouchPhase};
use tracing::{debug, warn};

use super::mutter::{AXIS_SOURCE_FINGER, InputHandle};
use crate::backend::InputSink;
use crate::bounded::{BoundedThread, DROP_JOIN};

const BTN_LEFT: i32 = 0x110;

enum Cmd {
    Touch(Touch),
    Scroll(Scroll),
}

/// What one receiver event becomes, in RemoteDesktop calls.
#[derive(Debug, Clone, PartialEq)]
pub enum Call {
    Motion(f64, f64),
    Button(i32, bool),
    Axis(f64, f64, u32),
}

/// Pure mapping, for tests: normalised touch (§7) to stream pixels; scroll
/// deltas in video pixels with natural-scrolling sign to logical "mouse
/// pixels" with the opposite sign, as for wl_pointer.axis.
pub struct Mapper {
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    pressed: bool,
}

impl Mapper {
    pub fn new(width: u32, height: u32, scale: f64) -> Self {
        Self {
            width: width as f64,
            height: height as f64,
            scale: scale.max(0.1),
            pressed: false,
        }
    }

    pub fn touch(&mut self, t: &Touch) -> Vec<Call> {
        let mut out = vec![Call::Motion(
            t.x.clamp(0.0, 1.0) * self.width,
            t.y.clamp(0.0, 1.0) * self.height,
        )];
        match t.phase {
            TouchPhase::Began if !self.pressed => {
                self.pressed = true;
                out.push(Call::Button(BTN_LEFT, true));
            }
            TouchPhase::Ended | TouchPhase::Cancelled if self.pressed => {
                self.pressed = false;
                out.push(Call::Button(BTN_LEFT, false));
            }
            _ => {}
        }
        out
    }

    pub fn scroll(&self, s: &Scroll) -> Vec<Call> {
        if s.dx == 0.0 && s.dy == 0.0 {
            return vec![];
        }
        vec![Call::Axis(
            -s.dx / self.scale,
            -s.dy / self.scale,
            AXIS_SOURCE_FINGER,
        )]
    }

    /// Calls to leave nothing pressed.
    pub fn release(&mut self) -> Vec<Call> {
        if std::mem::take(&mut self.pressed) {
            vec![Call::Button(BTN_LEFT, false)]
        } else {
            vec![]
        }
    }
}

pub struct RemoteInput {
    tx: Option<mpsc::Sender<Cmd>>,
    thread: BoundedThread,
}

impl RemoteInput {
    pub fn start(handle: InputHandle, mut mapper: Mapper) -> std::io::Result<Self> {
        let (tx, rx) = mpsc::channel::<Cmd>();
        let thread = BoundedThread::spawn("gnome-input", move || {
            let run = |c: Call| {
                let r = match c {
                    Call::Motion(x, y) => handle.motion(x, y),
                    Call::Button(b, p) => handle.button(b, p),
                    Call::Axis(dx, dy, f) => handle.axis(dx, dy, f),
                };
                if let Err(e) = r {
                    warn!("input: {e:#}");
                }
            };
            for cmd in rx {
                let calls = match cmd {
                    Cmd::Touch(t) => mapper.touch(&t),
                    Cmd::Scroll(s) => mapper.scroll(&s),
                };
                calls.into_iter().for_each(run);
            }
            mapper.release().into_iter().for_each(run);
            debug!("gnome input thread done");
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

impl Drop for RemoteInput {
    /// Ends the command loop and waits (bounded) for the button release.
    fn drop(&mut self) {
        self.tx = None;
        self.thread.join_within(DROP_JOIN);
    }
}

impl InputSink for RemoteInput {
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

    fn touch(phase: TouchPhase, x: f64, y: f64) -> Touch {
        Touch {
            phase,
            x,
            y,
            t: None,
        }
    }

    #[test]
    fn taps_become_motion_and_one_click() {
        let mut m = Mapper::new(1170, 2532, 3.0);
        assert_eq!(
            m.touch(&touch(TouchPhase::Began, 0.5, 0.25)),
            [Call::Motion(585.0, 633.0), Call::Button(BTN_LEFT, true)]
        );
        // A second Began while pressed does not press again.
        assert_eq!(m.touch(&touch(TouchPhase::Began, 0.5, 0.25)).len(), 1);
        assert_eq!(
            m.touch(&touch(TouchPhase::Moved, 1.5, -1.0)),
            [Call::Motion(1170.0, 0.0)]
        );
        assert_eq!(
            m.touch(&touch(TouchPhase::Ended, 0.0, 0.0)),
            [Call::Motion(0.0, 0.0), Call::Button(BTN_LEFT, false)]
        );
        assert!(m.release().is_empty());
        m.touch(&touch(TouchPhase::Began, 0.1, 0.1));
        assert_eq!(m.release(), [Call::Button(BTN_LEFT, false)]);
    }

    #[test]
    fn scroll_flips_sign_and_divides_by_scale() {
        let m = Mapper::new(100, 100, 2.0);
        assert_eq!(
            m.scroll(&Scroll { dx: 4.0, dy: -20.0 }),
            [Call::Axis(-2.0, 10.0, AXIS_SOURCE_FINGER)]
        );
        assert!(m.scroll(&Scroll { dx: 0.0, dy: 0.0 }).is_empty());
    }
}
