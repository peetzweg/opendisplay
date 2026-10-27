//! [`VirtualDisplay`] for every backend that captures through
//! `wayland/capture.rs` and injects through `wayland/input.rs`. The backend
//! supplies only the output side ([`OutputControl`]); this type owns the
//! ordering rule: capture is stopped and joined before the output is
//! reconfigured or removed, on every path including drop.

use anyhow::Result;
use tracing::warn;

use super::capture::CaptureThread;
use super::cursor::{CursorSpace, CursorThread};
use super::input::InputInjector;
use crate::backend::capture::CapturePath;
use crate::backend::lock::OutputLock;
use crate::backend::{
    CaptureOptions, CursorSink, DisplayInfo, DisplaySpec, DriftProbe, FrameSink, InputSink,
    VirtualDisplay,
};
use std::sync::{Arc, Mutex};

/// The compositor-specific half of a display. Neither method is called while
/// a capture of the output is running.
pub trait OutputControl: Send + 'static {
    fn info(&self) -> &DisplayInfo;
    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()>;
    /// Remove the output (a no-op for outputs the sender did not create).
    fn remove(&mut self) -> Result<()>;
    /// A check of whether the compositor changed the output away from what
    /// [`reconfigure`](Self::reconfigure) set (a config reload, a rule), so
    /// the session should apply its spec again; see
    /// [`VirtualDisplay::drift_probe`]. Called often: compositor IPC goes
    /// in the returned probe.
    fn drift_probe(&mut self) -> Option<DriftProbe> {
        None
    }
    /// The units this compositor's cursor session reports in for the
    /// output; the protocol's (pixels) unless the backend knows better.
    fn cursor_space(&self) -> CursorSpace {
        let i = self.info();
        CursorSpace::pixels(i.width, i.height)
    }
}

pub struct CapturedDisplay<O: OutputControl> {
    capture: Option<CaptureThread>,
    /// The cursor side channel's session; a capture of the output too.
    cursor: Option<CursorThread>,
    /// The frame sink and options of the running capture, so it can be
    /// restarted with the cursor painted or not.
    frames: Option<(Arc<Mutex<FrameSink>>, CaptureOptions)>,
    output: O,
    /// Held for the display's lifetime; see [`crate::backend::lock`].
    _lock: OutputLock,
    /// The protocol frames are captured with (backend/capture.rs).
    capture_path: CapturePath,
    /// Set once the output was removed or deliberately kept.
    released: bool,
}

impl<O: OutputControl> CapturedDisplay<O> {
    pub fn new(output: O, lock: OutputLock, capture_path: CapturePath) -> Self {
        Self {
            capture_path,
            capture: None,
            cursor: None,
            frames: None,
            output,
            _lock: lock,
            released: false,
        }
    }

    fn release(&mut self, keep_output: bool) -> Result<()> {
        self.stop_capture();
        if self.released {
            return Ok(());
        }
        self.released = true;
        if keep_output {
            return Ok(());
        }
        self.output.remove()
    }
}

impl<O: OutputControl> VirtualDisplay for CapturedDisplay<O> {
    fn info(&self) -> &DisplayInfo {
        self.output.info()
    }

    fn start_capture(&mut self, opts: CaptureOptions, sink: FrameSink) -> Result<()> {
        // Frames only: a cursor session started just before keeps running.
        if let Some(mut c) = self.capture.take() {
            c.stop();
        }
        let shared = Arc::new(Mutex::new(sink));
        self.capture = Some(spawn_frames(
            &self.output.info().name,
            opts,
            self.capture_path,
            &shared,
        )?);
        self.frames = Some((shared, opts));
        Ok(())
    }

    fn set_cursor_painted(&mut self, painted: bool) -> Result<()> {
        let Some((shared, opts)) = self.frames.clone() else {
            anyhow::bail!("not capturing");
        };
        if opts.cursor == painted {
            return Ok(());
        }
        if let Some(mut c) = self.capture.take() {
            c.stop();
        }
        let opts = CaptureOptions { cursor: painted };
        self.capture = Some(spawn_frames(
            &self.output.info().name,
            opts,
            self.capture_path,
            &shared,
        )?);
        self.frames = Some((shared, opts));
        Ok(())
    }

    fn start_cursor(&mut self, sink: CursorSink) -> Result<()> {
        if let Some(mut c) = self.cursor.take() {
            c.stop();
        }
        self.cursor = Some(CursorThread::spawn(
            &self.output.info().name,
            self.output.cursor_space(),
            sink,
        )?);
        Ok(())
    }

    fn stop_capture(&mut self) {
        if let Some(mut c) = self.capture.take() {
            c.stop();
        }
        if let Some(mut c) = self.cursor.take() {
            c.stop();
        }
    }

    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        self.stop_capture();
        self.output.reconfigure(spec)
    }

    fn drift_probe(&mut self) -> Option<DriftProbe> {
        self.output.drift_probe()
    }

    fn input(&mut self) -> Result<Box<dyn InputSink>> {
        let info = self.output.info();
        Ok(Box::new(InputInjector::start(&info.name, info.scale)?))
    }

    fn close(mut self: Box<Self>, keep_output: bool) -> Result<()> {
        self.release(keep_output)
    }
}

/// A capture thread feeding the shared sink (kept across restarts).
fn spawn_frames(
    name: &str,
    opts: CaptureOptions,
    path: CapturePath,
    shared: &Arc<Mutex<FrameSink>>,
) -> Result<CaptureThread> {
    let shared = shared.clone();
    CaptureThread::spawn(
        name,
        opts,
        path,
        Box::new(move |ev| (shared.lock().unwrap_or_else(|e| e.into_inner()))(ev)),
    )
}

impl<O: OutputControl> Drop for CapturedDisplay<O> {
    /// A display dropped without `close` (error path, panic) still stops
    /// capture first and then removes the output.
    fn drop(&mut self) {
        if !self.released {
            if let Err(e) = self.release(false) {
                warn!("removing {}: {e:#}", self.output.info().name);
            }
        }
        self.stop_capture();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::backend::Position;
    use crate::backend::lock::lock_output;

    struct Fake {
        info: DisplayInfo,
        log: Arc<Mutex<Vec<&'static str>>>,
    }

    impl OutputControl for Fake {
        fn info(&self) -> &DisplayInfo {
            &self.info
        }
        fn reconfigure(&mut self, _: &DisplaySpec) -> Result<()> {
            self.log.lock().unwrap().push("reconfigure");
            Ok(())
        }
        fn remove(&mut self) -> Result<()> {
            self.log.lock().unwrap().push("remove");
            Ok(())
        }
    }

    fn display(tag: &str) -> (Box<dyn VirtualDisplay>, Arc<Mutex<Vec<&'static str>>>) {
        let name = format!("od-display-test-{tag}-{}", std::process::id());
        let log = Arc::new(Mutex::new(Vec::new()));
        let fake = Fake {
            info: DisplayInfo {
                name: name.clone(),
                width: 640,
                height: 480,
                refresh_hz: 60.0,
                scale: 1.0,
                x: 0,
                y: 0,
            },
            log: log.clone(),
        };
        let lock = lock_output(&name).unwrap();
        (
            Box::new(CapturedDisplay::new(fake, lock, CapturePath::Ext)),
            log,
        )
    }

    /// Lock files outlive their locks; tidy the runtime dir.
    fn forget(name: &str) {
        let _ = std::fs::remove_file(crate::backend::lock::dir().join(format!("{name}.lock")));
    }

    #[test]
    fn close_removes_once_and_keep_output_keeps() {
        let (d, log) = display("close");
        let name = d.info().name.clone();
        d.close(false).unwrap();
        forget(&name);
        assert_eq!(*log.lock().unwrap(), ["remove"]);

        let (d, log) = display("keep");
        let name = d.info().name.clone();
        d.close(true).unwrap();
        forget(&name);
        assert!(log.lock().unwrap().is_empty());
    }

    #[test]
    fn drop_without_close_removes_the_output() {
        let (mut d, log) = display("drop");
        let name = d.info().name.clone();
        d.reconfigure(&DisplaySpec {
            name: d.info().name.clone(),
            width: 800,
            height: 600,
            hz: 60,
            scale: 1.0,
            position: Position::AutoRight,
        })
        .unwrap();
        drop(d);
        forget(&name);
        assert_eq!(*log.lock().unwrap(), ["reconfigure", "remove"]);
    }

    #[test]
    fn the_lock_is_held_until_the_display_goes() {
        let (d, _) = display("lock");
        let name = d.info().name.clone();
        assert!(lock_output(&name).is_err());
        drop(d);
        drop(lock_output(&name).unwrap());
        forget(&name);
    }
}
