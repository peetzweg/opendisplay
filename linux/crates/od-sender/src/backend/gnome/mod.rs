//! GNOME (Mutter): a virtual monitor from Mutter's ScreenCast API, input
//! through its RemoteDesktop API, frames from the stream's PipeWire node.
//! No portal and no dialog for an unsandboxed process (see `mutter.rs`).
//! Mutter removes the monitor when the session stops or this process's bus
//! connection closes, so nothing is ever left behind and `--keep-output`
//! cannot apply.

pub mod input;
pub mod layout;
pub mod mutter;

use std::sync::{Arc, Mutex};

use anyhow::{Result, bail};
use tracing::{info, warn};

use self::input::{Mapper, RemoteInput};
use self::mutter::{CursorMode, Request, VirtualMonitor};
use super::lock::{OutputLock, lock_output};
use super::{
    Backend, BackendId, Caps, CaptureEvent, CaptureOptions, DisplayInfo, DisplaySpec, FrameSink,
    InputSink, VirtualDisplay,
};
use crate::pipewire::{PwCapture, PwSource};

pub struct GnomeBackend {
    versions: (i32, i32),
    cursor: CursorMode,
}

impl GnomeBackend {
    /// Connect to the session bus and check that Mutter's APIs are there.
    pub fn connect() -> Result<Self> {
        let conn = zbus::blocking::Connection::session()?;
        let versions = mutter::probe(&conn)?;
        Ok(Self {
            versions,
            cursor: CursorMode::Embedded,
        })
    }
}

impl Backend for GnomeBackend {
    /// Frames come over PipeWire, not a Wayland capture protocol.
    fn wayland_capture(&self) -> bool {
        false
    }

    fn set_capture(&mut self, _: super::capture::CapturePath) {}

    fn id(&self) -> BackendId {
        BackendId::Gnome
    }

    fn describe(&self) -> String {
        format!(
            "GNOME Mutter (ScreenCast API v{}, RemoteDesktop API v{})",
            self.versions.0, self.versions.1
        )
    }

    fn caps(&self) -> Caps {
        Caps {
            // Mutter offers cursor metadata on the PipeWire stream; not read yet.
            cursor_metadata: false,
            dmabuf: false,
            // A stream created with `modes` has a fixed size: a new size is a
            // new monitor.
            resize_in_place: false,
            creates_outputs: true,
        }
    }

    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
        let lock = lock_output(&spec.name)?;
        let (vm, capture) = create(spec, self.cursor)?;
        Ok(Box::new(GnomeDisplay::new(
            spec,
            vm,
            capture,
            lock,
            self.cursor,
        )))
    }

    fn set_cursor_visible(&mut self, visible: bool) {
        self.cursor = if visible {
            CursorMode::Embedded
        } else {
            CursorMode::Hidden
        };
    }

    fn clean(&mut self) -> Result<Vec<String>> {
        // Mutter removes a virtual monitor with its session; nothing outlives us.
        Ok(Vec::new())
    }
}

/// The monitor for `spec`, then its scale and position (Mutter places a new
/// monitor at scale 1 on the right).
fn create(spec: &DisplaySpec, cursor: CursorMode) -> Result<(VirtualMonitor, Capture)> {
    let (mut vm, capture) = VirtualMonitor::create(
        &Request {
            width: spec.width,
            height: spec.height,
            hz: spec.hz,
            cursor,
        },
        |node| Capture::connect(node, (spec.width, spec.height)),
    )?;
    match vm.arrange(spec.scale, spec.position) {
        Ok(scale) if (scale - spec.scale).abs() > 1e-6 => info!(
            "scale {} is not available for {}x{}; using {scale}",
            spec.scale, spec.width, spec.height
        ),
        Ok(_) => {}
        Err(e) => warn!("could not set scale/position of the virtual monitor: {e:#}"),
    }
    Ok((vm, capture))
}

fn info_of(name: &str, vm: &VirtualMonitor) -> DisplayInfo {
    let p = &vm.placement;
    DisplayInfo {
        name: name.to_string(),
        width: p.width,
        height: p.height,
        refresh_hz: p.refresh,
        scale: p.scale,
        x: p.x,
        y: p.y,
    }
}

/// Keep the consumer connected from monitor creation through teardown.
/// Frames before start_capture (and while stopped) are discarded.
struct Capture {
    _stream: PwCapture,
    delivery: Arc<Mutex<Delivery>>,
}

#[derive(Default)]
struct Delivery {
    sink: Option<FrameSink>,
    ended: Option<String>,
}

impl Capture {
    fn connect(node: u32, size: (u32, u32)) -> Result<Self> {
        let delivery = Arc::new(Mutex::new(Delivery::default()));
        let target = delivery.clone();
        let stream = PwCapture::spawn(
            PwSource {
                node,
                serial: None,
                remote_fd: None,
            },
            size,
            Box::new(move |event| {
                let mut delivery = target.lock().unwrap();
                if let CaptureEvent::Ended(why) = &event {
                    delivery.ended = Some(why.clone());
                }
                if let Some(sink) = delivery.sink.as_mut() {
                    sink(event);
                }
            }),
        )?;
        Ok(Self {
            _stream: stream,
            delivery,
        })
    }
}

pub struct GnomeDisplay {
    /// Field order is drop order: capture before the monitor.
    capture: Option<Capture>,
    vm: Option<VirtualMonitor>,
    info: DisplayInfo,
    cursor: CursorMode,
    _lock: OutputLock,
}

impl GnomeDisplay {
    fn new(
        spec: &DisplaySpec,
        vm: VirtualMonitor,
        capture: Capture,
        lock: OutputLock,
        cursor: CursorMode,
    ) -> Self {
        let info = info_of(&spec.name, &vm);
        info!(
            "virtual display {} ({}, PipeWire node {})",
            info, vm.placement.connector, vm.node
        );
        Self {
            capture: Some(capture),
            info,
            vm: Some(vm),
            cursor,
            _lock: lock,
        }
    }
}

impl VirtualDisplay for GnomeDisplay {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    /// The cursor is part of the stream (`cursor-mode` embedded), fixed when
    /// the monitor was created; `opts.cursor` does not change it.
    fn start_capture(&mut self, _opts: CaptureOptions, sink: FrameSink) -> Result<()> {
        self.stop_capture();
        let Some(capture) = &self.capture else {
            bail!("no PipeWire capture");
        };
        let mut delivery = capture.delivery.lock().unwrap();
        if let Some(why) = &delivery.ended {
            bail!("PipeWire capture ended before delivery started: {why}");
        }
        delivery.sink = Some(sink);
        Ok(())
    }

    fn stop_capture(&mut self) {
        if let Some(capture) = &self.capture {
            capture.delivery.lock().unwrap().sink = None;
        }
    }

    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        self.stop_capture();
        self.capture.take();
        if let Some(mut old) = self.vm.take() {
            if let Err(e) = old.stop() {
                warn!("stopping the old virtual monitor: {e:#}");
            }
        }
        let (vm, capture) = create(spec, self.cursor)?;
        self.info = info_of(&spec.name, &vm);
        info!("virtual display {} ({})", self.info, vm.placement.connector);
        self.capture = Some(capture);
        self.vm = Some(vm);
        Ok(())
    }

    fn input(&mut self) -> Result<Box<dyn InputSink>> {
        let Some(vm) = &self.vm else {
            bail!("no virtual monitor");
        };
        let p = &vm.placement;
        let (width, height) = p.layout_size();
        Ok(Box::new(RemoteInput::start(
            vm.input(),
            Mapper::new(width, height, p.scale),
        )?))
    }

    fn close(mut self: Box<Self>, keep_output: bool) -> Result<()> {
        if keep_output {
            warn!("--keep-output: Mutter removes a virtual monitor with its session");
        }
        self.stop_capture();
        self.capture.take();
        if let Some(mut vm) = self.vm.take() {
            vm.stop()?;
            info!("removed virtual display {}", self.info.name);
        }
        Ok(())
    }
}

impl Drop for GnomeDisplay {
    fn drop(&mut self) {
        self.stop_capture();
        // VirtualMonitor's own Drop stops the session.
    }
}
