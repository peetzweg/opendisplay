//! KDE Plasma (KWin): a virtual output requested through
//! `zkde_screencast_unstable_v1`, its frames from the PipeWire node KWin
//! creates for it, input through `org_kde_kwin_fake_input`, scale and place
//! through `kde_output_management_v2` ([`outputs`]). No dialog and no portal. KWin removes the output when the stream closes or the process
//! dies, so nothing is ever left behind and `--keep-output` cannot work.

pub mod input;
pub mod outputs;
pub mod protocols;
pub mod screencast;

use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use tracing::{debug, info, warn};

use self::input::FakeInput;
use self::screencast::{Pointer, Request, VirtualOutputStream};
use super::lock::{self, OutputLock, lock_output};
use super::{
    Backend, BackendId, Caps, CaptureOptions, DisplayInfo, DisplaySpec, FrameSink, InputSink,
    VirtualDisplay,
};
use crate::pipewire::{PwCapture, PwSource};
use crate::wayland::registry::{self, OutputSnapshot};

/// KWin names a virtual output `Virtual-<name>`.
pub fn output_name(lock_name: &str) -> String {
    format!("Virtual-{lock_name}")
}

/// The pointer mode new outputs are made with; KWin fixes it per stream.
pub struct KdeBackend {
    pointer: Pointer,
}

impl Default for KdeBackend {
    fn default() -> Self {
        Self {
            pointer: Pointer::Embedded,
        }
    }
}

impl Backend for KdeBackend {
    /// Frames come over PipeWire, not a Wayland capture protocol.
    fn wayland_capture(&self) -> bool {
        false
    }

    fn set_capture(&mut self, _: super::capture::CapturePath) {}

    fn id(&self) -> BackendId {
        BackendId::Kde
    }

    fn describe(&self) -> String {
        "KWin (zkde_screencast virtual output, PipeWire, fake input)".into()
    }

    fn caps(&self) -> Caps {
        Caps {
            cursor_metadata: false,
            dmabuf: false,
            // zkde has no resize: a new size is a new output.
            resize_in_place: false,
            creates_outputs: true,
        }
    }

    /// Called before the first `open`, so `--cursor off` makes the output
    /// hidden-pointer at once instead of recreating it in `start_capture`.
    fn set_cursor_visible(&mut self, visible: bool) {
        self.pointer = pointer_mode(visible);
    }

    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
        let lock = lock_output(&spec.name)?;
        let mut d = KdeDisplay {
            capture: None,
            stream: None,
            pointer: self.pointer,
            shifted_others: false,
            spec: spec.clone(),
            info: DisplayInfo {
                name: output_name(&spec.name),
                width: spec.width,
                height: spec.height,
                refresh_hz: 60.0,
                scale: spec.scale,
                x: 0,
                y: 0,
            },
            _lock: lock,
        };
        d.create()?;
        Ok(Box::new(d))
    }

    /// KWin drops a virtual output with its client, so no output is left
    /// behind; but a sender killed during a left/up placement leaves the
    /// user's outputs shifted. With no sender running, move them back.
    fn clean(&mut self) -> Result<Vec<String>> {
        // Held while moving outputs, so no sender starts meanwhile.
        let mut held = Vec::new();
        for name in lock::names()? {
            match lock::try_lock(&name)? {
                Some(l) => held.push(l),
                None => {
                    info!("{name} is in use by a running od-sender; leaving the layout alone");
                    return Ok(Vec::new());
                }
            }
        }
        Ok(match outputs::reset_origin()? {
            Some((dx, dy)) => vec![format!("layout offset (moved outputs by {dx},{dy})")],
            None => Vec::new(),
        })
    }
}

pub struct KdeDisplay {
    // Field order is drop order: capture before the output it reads.
    capture: Option<PwCapture>,
    stream: Option<VirtualOutputStream>,
    pointer: Pointer,
    /// A left/up placement moved the other outputs; move them back on close.
    shifted_others: bool,
    spec: DisplaySpec,
    info: DisplayInfo,
    _lock: OutputLock,
}

/// The size to request so the mode comes out `want` pixels, given that a
/// request of `asked` produced `got`. The protocol says logical size, and
/// KWin's virtual backend multiplies by the scale; its DRM backend (real
/// sessions, 6.8) uses the request as the mode as is. One correction from
/// the read-back covers both.
pub fn corrected(want: (u32, u32), asked: (i32, i32), got: (i32, i32)) -> (i32, i32) {
    let fix = |w: u32, a: i32, g: i32| {
        if g <= 0 {
            a
        } else {
            (a as f64 * w as f64 / g as f64).round() as i32
        }
    };
    (fix(want.0, asked.0, got.0), fix(want.1, asked.1, got.1))
}

impl KdeDisplay {
    /// One virtual output of `width`x`height` (as zkde means it); waits for
    /// its wl_output to get a mode and place.
    fn make(&mut self, width: i32, height: i32) -> Result<OutputSnapshot> {
        self.stop_capture();
        self.stream = None;
        let name = output_name(&self.spec.name);
        self.stream = Some(VirtualOutputStream::open(Request {
            name: self.spec.name.clone(),
            description: "OpenDisplay".into(),
            width,
            height,
            scale: self.spec.scale,
            pointer: self.pointer,
        })?);
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let snap = registry::snapshot()?;
            if let Some(o) = snap.output(&name) {
                if o.width > 0 {
                    return Ok(o.clone());
                }
            }
            if Instant::now() > deadline {
                bail!("KWin made no output {name}");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The output as wl_output/xdg-output report it once a configuration
    /// reached them (they follow kde_output_management asynchronously).
    fn settled(&self, name: &str, scale: f64, pos: (i32, i32)) -> Option<OutputSnapshot> {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut last = None;
        while Instant::now() < deadline {
            if let Some(o) = registry::snapshot().ok()?.output(name).cloned() {
                if (o.fractional_scale() - scale).abs() < 0.01 && (o.x, o.y) == pos {
                    return Some(o);
                }
                last = Some(o);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if let Some(o) = &last {
            warn!(
                "{name} reports scale {} at {},{} after asking {scale} at {},{}",
                o.fractional_scale(),
                o.x,
                o.y,
                pos.0,
                pos.1
            );
        }
        last
    }

    /// (Re)create the output for `self.spec` and read its layout back.
    fn create(&mut self) -> Result<()> {
        let want = (self.spec.width, self.spec.height);
        let asked = (
            (want.0 as f64 / self.spec.scale).round() as i32,
            (want.1 as f64 / self.spec.scale).round() as i32,
        );
        let mut o = self.make(asked.0, asked.1)?;
        if (o.width as u32, o.height as u32) != want {
            let again = corrected(want, asked, (o.width, o.height));
            debug!(
                "{}: asked {}x{} got {}x{}; asking {}x{}",
                o.name, asked.0, asked.1, o.width, o.height, again.0, again.1
            );
            o = self.make(again.0, again.1)?;
        }
        if (o.width as u32, o.height as u32) != want {
            warn!(
                "{} is {}x{}, wanted {}x{}",
                o.name, o.width, o.height, want.0, want.1
            );
        }
        // KWin picks a new output's scale from its DPI (or the user's saved
        // choice for this name) and places it itself; set both as asked.
        match outputs::configure(&o.name, self.spec.scale, self.spec.position) {
            Ok(p) => {
                self.shifted_others |= p.shifted_others;
                o = self
                    .settled(&o.name, self.spec.scale, (p.x, p.y))
                    .unwrap_or(o);
            }
            Err(e) => warn!(
                "{}: keeping KWin's scale {} and position: {e:#}",
                o.name,
                o.fractional_scale()
            ),
        }
        let scale = o.fractional_scale();
        self.info = DisplayInfo {
            name: o.name.clone(),
            width: o.width as u32,
            height: o.height as u32,
            refresh_hz: o.refresh_mhz as f64 / 1000.0,
            scale,
            x: o.x,
            y: o.y,
        };
        info!("virtual display {}", self.info);
        Ok(())
    }
}

fn pointer_mode(cursor_in_video: bool) -> Pointer {
    if cursor_in_video {
        Pointer::Embedded
    } else {
        Pointer::Hidden
    }
}

impl VirtualDisplay for KdeDisplay {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    fn start_capture(&mut self, opts: CaptureOptions, sink: FrameSink) -> Result<()> {
        self.stop_capture();
        // KWin fixes the pointer mode when the stream is made.
        let want = pointer_mode(opts.cursor);
        if want != self.pointer {
            info!("recreating {} for pointer mode {want:?}", self.info.name);
            self.pointer = want;
            self.create()?;
        }
        let Some(stream) = &self.stream else {
            bail!("{} is gone", self.info.name);
        };
        let size = (self.info.width, self.info.height);
        let src = PwSource {
            node: stream.node.id,
            serial: stream.node.serial,
            remote_fd: None,
        };
        self.capture = Some(PwCapture::spawn(src, size, sink)?);
        Ok(())
    }

    fn stop_capture(&mut self) {
        if let Some(mut c) = self.capture.take() {
            c.stop();
        }
    }

    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        self.spec = spec.clone();
        self.create()
    }

    fn input(&mut self) -> Result<Box<dyn InputSink>> {
        Ok(Box::new(FakeInput::new(&self.info)?))
    }

    fn close(mut self: Box<Self>, keep_output: bool) -> Result<()> {
        if keep_output {
            warn!(
                "KWin removes {} with its stream; --keep-output has no effect on KDE",
                self.info.name
            );
        }
        self.release();
        info!("removed virtual display {}", self.info.name);
        Ok(())
    }
}

impl KdeDisplay {
    /// Capture first, then the output; then put the user's outputs back.
    fn release(&mut self) {
        self.stop_capture();
        if self.stream.take().is_some() && self.shifted_others {
            self.shifted_others = false;
            if let Err(e) = outputs::restore_origin(&self.info.name) {
                warn!("{e:#}");
            }
        }
    }
}

impl Drop for KdeDisplay {
    fn drop(&mut self) {
        self.release();
    }
}

#[cfg(test)]
mod tests {
    use super::corrected;

    #[test]
    fn size_correction_covers_both_kwin_backends() {
        // Virtual backend: logical request, mode = request * scale.
        assert_eq!(corrected((1024, 768), (512, 384), (1024, 768)), (512, 384));
        // DRM backend: the request is the mode.
        assert_eq!(corrected((1024, 768), (512, 384), (512, 384)), (1024, 768));
        // Scale 1.5 on the virtual backend.
        assert_eq!(
            corrected((1920, 1200), (1280, 800), (1920, 1200)),
            (1280, 800)
        );
    }
}
