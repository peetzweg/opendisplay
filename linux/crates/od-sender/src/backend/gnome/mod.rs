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
/// Keep the latest frame before start_capture (and while stopped) so a
/// static desktop can be delivered without waiting for another redraw.
struct Capture {
    _stream: PwCapture,
    delivery: Arc<Mutex<Delivery>>,
}

#[derive(Default)]
struct Delivery {
    sink: Option<FrameSink>,
    pending: Option<super::Frame>,
    ended: Option<String>,
}

impl Delivery {
    fn event(&mut self, event: CaptureEvent) {
        if self.ended.is_some() {
            return;
        }
        if let CaptureEvent::Ended(why) = &event {
            self.pending = None;
            self.ended = Some(why.clone());
        }
        if let Some(sink) = self.sink.as_mut() {
            sink(event);
        } else if let CaptureEvent::Frame(frame) = event {
            self.pending = Some(frame);
        }
    }

    // Called with the delivery lock held: a new frame cannot overtake the
    // pending one while the sink is attached.
    fn start(&mut self, mut sink: FrameSink) -> Result<()> {
        if let Some(why) = &self.ended {
            bail!("PipeWire capture ended before delivery started: {why}");
        }
        if let Some(frame) = self.pending.take() {
            sink(CaptureEvent::Frame(frame));
        }
        self.sink = Some(sink);
        Ok(())
    }
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
                target.lock().unwrap().event(event);
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
        capture.delivery.lock().unwrap().start(sink)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::{Frame, FrameBuf, PixelFormat};
    use std::sync::mpsc::{self, TryRecvError};
    use std::time::Instant;

    fn frame(width: u32) -> CaptureEvent {
        CaptureEvent::Frame(Frame {
            captured_at: Instant::now(),
            presentation_ns: None,
            buf: FrameBuf::Cpu {
                pixels: vec![0; width as usize * 4].into(),
                width,
                height: 1,
                stride: width * 4,
                format: PixelFormat::Xrgb8888,
            },
        })
    }

    fn receiver() -> (FrameSink, mpsc::Receiver<CaptureEvent>) {
        let (tx, rx) = mpsc::channel();
        (Box::new(move |event| tx.send(event).unwrap()), rx)
    }

    fn width(event: CaptureEvent) -> u32 {
        match event {
            CaptureEvent::Frame(frame) => frame.dimensions().0,
            CaptureEvent::Ended(why) => panic!("unexpected end: {why}"),
        }
    }

    #[test]
    fn static_frame_arriving_before_start_is_delivered_without_another_redraw() {
        let mut delivery = Delivery::default();
        delivery.event(frame(1));
        let (sink, rx) = receiver();
        delivery.start(sink).unwrap();
        assert_eq!(width(rx.try_recv().unwrap()), 1);
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
        assert!(delivery.pending.is_none());
    }

    #[test]
    fn only_latest_pending_frame_is_delivered_before_live_frames() {
        let mut delivery = Delivery::default();
        delivery.event(frame(1));
        delivery.event(frame(2));
        let (sink, rx) = receiver();
        delivery.start(sink).unwrap();
        delivery.event(frame(3));
        assert_eq!(width(rx.try_recv().unwrap()), 2);
        assert_eq!(width(rx.try_recv().unwrap()), 3);
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn frames_while_delivery_is_stopped_are_available_on_restart() {
        let mut delivery = Delivery::default();
        let (sink, rx) = receiver();
        delivery.start(sink).unwrap();
        delivery.event(frame(1));
        assert_eq!(width(rx.try_recv().unwrap()), 1);
        delivery.sink = None;
        delivery.event(frame(2));
        delivery.event(frame(3));
        let (sink, rx) = receiver();
        delivery.start(sink).unwrap();
        assert_eq!(width(rx.try_recv().unwrap()), 3);
    }

    #[test]
    fn end_before_start_discards_pending_frame_and_preserves_error() {
        let mut delivery = Delivery::default();
        delivery.event(frame(1));
        delivery.event(CaptureEvent::Ended("stream lost".into()));
        assert!(delivery.pending.is_none());
        delivery.event(frame(2));
        let (sink, rx) = receiver();
        assert!(
            delivery
                .start(sink)
                .unwrap_err()
                .to_string()
                .contains("stream lost")
        );
        assert!(rx.try_recv().is_err());
        assert!(delivery.pending.is_none());
    }
}
