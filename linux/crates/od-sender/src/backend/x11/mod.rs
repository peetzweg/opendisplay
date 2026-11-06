//! X11 (Xorg): the virtual display is a RandR output turned on on a spare
//! connector (`randr.rs`), captured with MIT-SHM where XDamage says it
//! changed (`capture.rs`), with input through XTest (`input.rs`) and the
//! cursor from XFixes (`cursor.rs`). Everything is in stock Xorg; no
//! window manager or compositor support is needed.
//!
//! X11 has no per-output scale, so the display is made in logical pixels:
//! an iPhone at 3x gets a 390x844 output and the receiver scales it up.

pub mod capture;
pub mod cursor;
pub mod input;
pub mod randr;

use anyhow::{Context, Result, bail};
use tracing::{info, warn};
use x11rb::connection::RequestConnection;
use x11rb::protocol::{damage, shm, xfixes, xtest};

use self::capture::{Capture, Rect};
use self::cursor::CursorThread;
use self::input::{Mapper, XTestInput};
use self::randr::{Placed, Randr};
use super::lock::{OutputLock, lock_output, try_lock};
use super::{
    Backend, BackendId, Caps, CaptureOptions, CursorSink, DisplayInfo, DisplaySpec, DriftProbe,
    FrameSink, InputSink, VirtualDisplay,
};

pub struct X11Backend {
    display: Option<String>,
    /// `--output`: stream an output that is already on, create nothing.
    adopt: Option<String>,
    describe: String,
}

/// Extensions the backend uses, and the name each one has on the wire.
const EXTENSIONS: [(&str, &str); 4] = [
    ("MIT-SHM", shm::X11_EXTENSION_NAME),
    ("DAMAGE", damage::X11_EXTENSION_NAME),
    ("XFIXES", xfixes::X11_EXTENSION_NAME),
    ("XTEST", xtest::X11_EXTENSION_NAME),
];

impl X11Backend {
    /// Connect and check that the server has what the backend needs and,
    /// unless an output is adopted, a connector to put a display on.
    pub fn connect(display: Option<String>, adopt: Option<String>) -> Result<Self> {
        let r = Randr::connect(display.as_deref())?;
        let mut missing = Vec::new();
        for (label, name) in EXTENSIONS {
            if r.conn.extension_information(name)?.is_none() {
                missing.push(label);
            }
        }
        if !missing.is_empty() {
            bail!("the X server lacks {}", missing.join(", "));
        }
        let display_name = display.clone().unwrap_or_else(|| "$DISPLAY".into());
        let describe = match &adopt {
            Some(o) => {
                let p = r.find_output(o)?;
                format!(
                    "Xorg on {display_name}: streaming existing output {o} ({}x{} at {},{})",
                    p.width, p.height, p.x, p.y
                )
            }
            None => {
                let free = r.free_outputs()?;
                let left: Vec<String> = r
                    .ours()?
                    .into_iter()
                    .filter_map(|(n, p, _)| p.map(|p| format!("{n} on {}", p.output_name)))
                    .collect();
                if free.is_empty() && left.is_empty() {
                    bail!(
                        "no free connector for a virtual display: X11 needs a disconnected output (HDMI, DP, VIRTUAL) with a CRTC no monitor uses, and every one is taken or the driver offers none (the NVIDIA driver usually does not)"
                    );
                }
                let mut s = format!(
                    "Xorg on {display_name} (RandR, MIT-SHM, DAMAGE, XFIXES, XTEST); free connectors: {}",
                    if free.is_empty() {
                        "none".into()
                    } else {
                        free.join(", ")
                    }
                );
                if !left.is_empty() {
                    s.push_str(&format!(
                        "; left on by earlier senders: {}",
                        left.join(", ")
                    ));
                }
                s
            }
        };
        Ok(Self {
            display,
            adopt,
            describe,
        })
    }
}

impl Backend for X11Backend {
    fn id(&self) -> BackendId {
        BackendId::X11
    }

    fn describe(&self) -> String {
        self.describe.clone()
    }

    fn caps(&self) -> Caps {
        Caps {
            cursor_metadata: true,
            dmabuf: false,
            resize_in_place: self.adopt.is_none(),
            creates_outputs: self.adopt.is_none(),
        }
    }

    fn wayland_capture(&self) -> bool {
        false
    }

    fn capture_label(&self) -> &'static str {
        "X11 MIT-SHM"
    }

    fn set_capture(&mut self, _: super::capture::CapturePath) {}

    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
        let lock = lock_output(&spec.name)?;
        let r = Randr::connect(self.display.as_deref())?;
        let (placed, created) = match &self.adopt {
            Some(o) => (r.find_output(o)?, false),
            None => {
                let (w, h) = logical(spec);
                (
                    r.create(&spec.name, w, h, spec.hz as f64, spec.position)?,
                    true,
                )
            }
        };
        let d = X11Display {
            capture: None,
            cursor: None,
            display: self.display.clone(),
            randr: r,
            info: info_of(spec, &placed),
            placed,
            created,
            _lock: lock,
        };
        info!("virtual display {} ({})", d.info, d.placed.output_name);
        if created {
            info!(
                "X11 has no per-output scale: {} is {}x{} logical pixels, scaled up on the receiver",
                d.placed.output_name, d.info.width, d.info.height
            );
        }
        Ok(Box::new(d))
    }

    fn clean(&mut self) -> Result<Vec<String>> {
        let r = Randr::connect(self.display.as_deref())?;
        let mut removed = Vec::new();
        for (name, placed, mode) in r.ours()? {
            // A running sender holds its lock; leave its display alone.
            let Some(_lock) = try_lock(&name)? else {
                continue;
            };
            match placed {
                Some(p) => {
                    r.disable(&p)
                        .with_context(|| format!("turning off {}", p.output_name))?;
                    removed.push(format!("{name} ({})", p.output_name));
                }
                None => {
                    r.destroy_mode(mode)?;
                    removed.push(name);
                }
            }
        }
        Ok(removed)
    }
}

/// The output size for `spec`: its pixels divided by its scale.
fn logical(spec: &DisplaySpec) -> (u32, u32) {
    let s = if spec.scale.is_finite() && spec.scale > 0.0 {
        spec.scale
    } else {
        1.0
    };
    let px = |v: u32| ((v as f64 / s).round() as u32).max(64);
    (px(spec.width), px(spec.height))
}

fn info_of(spec: &DisplaySpec, p: &Placed) -> DisplayInfo {
    DisplayInfo {
        name: spec.name.clone(),
        width: p.width,
        height: p.height,
        refresh_hz: p.refresh_hz,
        scale: 1.0,
        x: p.x,
        y: p.y,
    }
}

fn rect_of(p: &Placed) -> Rect {
    Rect {
        x: p.x,
        y: p.y,
        w: p.width,
        h: p.height,
    }
}

pub struct X11Display {
    /// Field order is drop order: capture and cursor before the output.
    capture: Option<Capture>,
    cursor: Option<CursorThread>,
    display: Option<String>,
    randr: Randr,
    placed: Placed,
    info: DisplayInfo,
    /// Turned on by this sender (not `--output`): turned off on close.
    created: bool,
    _lock: OutputLock,
}

impl VirtualDisplay for X11Display {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    fn start_capture(&mut self, opts: CaptureOptions, sink: FrameSink) -> Result<()> {
        if let Some(mut c) = self.capture.take() {
            c.stop();
        }
        self.capture = Some(Capture::spawn(
            self.display.as_deref(),
            rect_of(&self.placed),
            self.info.refresh_hz.clamp(30.0, 120.0),
            opts.cursor,
            sink,
        )?);
        Ok(())
    }

    fn start_cursor(&mut self, sink: CursorSink) -> Result<()> {
        if let Some(mut c) = self.cursor.take() {
            c.stop();
        }
        self.cursor = Some(CursorThread::spawn(
            self.display.as_deref(),
            rect_of(&self.placed),
            sink,
        )?);
        Ok(())
    }

    fn set_cursor_painted(&mut self, painted: bool) -> Result<()> {
        match &self.capture {
            Some(c) => {
                c.set_cursor_painted(painted);
                Ok(())
            }
            None => bail!("not capturing"),
        }
    }

    fn stop_capture(&mut self) {
        if let Some(mut c) = self.cursor.take() {
            c.stop();
        }
        if let Some(mut c) = self.capture.take() {
            c.stop();
        }
    }

    fn drift_probe(&mut self) -> Option<DriftProbe> {
        let display = self.display.clone();
        let placed = self.placed.clone();
        Some(Box::new(move || {
            let r = Randr::connect(display.as_deref()).ok()?;
            match r.drifted(&placed) {
                Ok(d) => d,
                Err(e) => {
                    warn!("checking {}: {e:#}", placed.output_name);
                    None
                }
            }
        }))
    }

    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        self.stop_capture();
        self.placed = if self.created {
            // Resizes it in place, or turns it on again if something turned
            // it off (a drift rebuild).
            let (w, h) = logical(spec);
            self.randr
                .create(&spec.name, w, h, spec.hz as f64, spec.position)?
        } else {
            self.randr.find_output(&self.placed.output_name)?
        };
        self.info = info_of(spec, &self.placed);
        info!(
            "virtual display {} ({})",
            self.info, self.placed.output_name
        );
        Ok(())
    }

    fn input(&mut self) -> Result<Box<dyn InputSink>> {
        Ok(Box::new(XTestInput::start(
            self.display.as_deref(),
            Mapper::new(rect_of(&self.placed)),
        )?))
    }

    fn close(mut self: Box<Self>, keep_output: bool) -> Result<()> {
        self.stop_capture();
        // Either way the output is settled here, not again on drop.
        if std::mem::take(&mut self.created) && !keep_output {
            self.randr.disable(&self.placed)?;
            info!(
                "removed virtual display {} ({})",
                self.info.name, self.placed.output_name
            );
        }
        Ok(())
    }
}

impl Drop for X11Display {
    /// A display dropped without `close` (an error on the way) still goes.
    fn drop(&mut self) {
        self.stop_capture();
        if self.created {
            if let Err(e) = self.randr.disable(&self.placed) {
                warn!("turning off {}: {e:#}", self.placed.output_name);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::Position;

    #[test]
    fn displays_are_made_in_logical_pixels() {
        let spec = |w, h, scale| DisplaySpec {
            name: "od-abcdef".into(),
            width: w,
            height: h,
            hz: 60,
            scale,
            position: Position::AutoRight,
        };
        assert_eq!(logical(&spec(1170, 2532, 3.0)), (390, 844));
        assert_eq!(logical(&spec(2360, 1640, 2.0)), (1180, 820));
        assert_eq!(logical(&spec(1080, 2424, 2.625)), (411, 923));
        assert_eq!(logical(&spec(1920, 1080, 0.0)), (1920, 1080));
    }
}
