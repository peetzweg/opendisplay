//! Continuous capture of one Wayland output through
//! `ext-image-copy-capture-v1` into `wl_shm` buffers. This is the software
//! path: the compositor writes each frame into one of a few mapped buffers,
//! which is lent to the encoder as is (`shm_pool.rs`) and read once by the
//! colour conversion. The dmabuf path for VA-API zero-copy encode lands with
//! Spike 0 on hardware that has an encoder.

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tracing::{debug, info, warn};

use super::dispatch_with_timeout;
use super::shm_pool::{Lease, Mapping, Recycler};
use crate::backend::capture::CapturePath;
use crate::backend::{
    CaptureEvent, CaptureOptions, Frame, FrameBuf, FrameSink, PixelFormat, Pixels,
};
use wayland_client::protocol::{wl_buffer, wl_output, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum};
use wayland_protocols::ext::image_capture_source::v1::client::{
    ext_image_capture_source_v1, ext_output_image_capture_source_manager_v1,
};
use wayland_protocols::ext::image_copy_capture::v1::client::{
    ext_image_copy_capture_frame_v1, ext_image_copy_capture_manager_v1,
    ext_image_copy_capture_session_v1,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameInfo {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: wl_shm::Format,
    /// Compositor presentation time of this frame, if reported.
    pub presentation_ns: Option<u128>,
    /// When the compositor said the frame was ready, before we copy it out.
    pub ready_at: Instant,
}

/// Buffers the compositor may be writing, lent out or free at once: one
/// attached, one waiting in the encoder's latest-wins slot, one being
/// encoded and the last one kept for an IDR replay on a static screen.
pub(super) const MAX_BUFFERS: usize = 4;

/// One mapped `wl_shm` buffer (shared with `screencopy.rs`).
pub(super) struct ShmBuffer {
    pub(super) map: Arc<Mapping>,
    pool: wl_shm_pool::WlShmPool,
    pub(super) buffer: wl_buffer::WlBuffer,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) stride: u32,
    pub(super) format: wl_shm::Format,
}

impl ShmBuffer {
    pub(super) fn new<D>(
        shm: &wl_shm::WlShm,
        qh: &QueueHandle<D>,
        width: u32,
        height: u32,
        stride: u32,
        format: wl_shm::Format,
    ) -> Result<Self>
    where
        D: Dispatch<wl_shm_pool::WlShmPool, ()> + Dispatch<wl_buffer::WlBuffer, ()> + 'static,
    {
        let size = (stride * height) as u64;
        let path = format!(
            "/dev/shm/od-capture-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        );
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)?;
        let _ = std::fs::remove_file(&path);
        file.set_len(size)?;
        let map = Arc::new(Mapping::new(&file, size as usize)?);
        let pool = shm.create_pool(file.as_fd(), size as i32, qh, ());
        let buffer = pool.create_buffer(
            0,
            width as i32,
            height as i32,
            stride as i32,
            format,
            qh,
            (),
        );
        Ok(Self {
            map,
            pool,
            buffer,
            width,
            height,
            stride,
            format,
        })
    }
}

impl Drop for ShmBuffer {
    /// A lease may still read the mapping; it holds its own reference.
    fn drop(&mut self) {
        self.buffer.destroy();
        self.pool.destroy();
    }
}

#[derive(Default)]
struct SessionInfo {
    width: u32,
    height: u32,
    shm_formats: Vec<wl_shm::Format>,
    done: bool,
    stopped: bool,
}

struct State {
    shm: Option<wl_shm::WlShm>,
    outputs: HashMap<u32, (wl_output::WlOutput, String)>,
    source_mgr:
        Option<ext_output_image_capture_source_manager_v1::ExtOutputImageCaptureSourceManagerV1>,
    capture_mgr: Option<ext_image_copy_capture_manager_v1::ExtImageCopyCaptureManagerV1>,
    session: SessionInfo,
    buffers: Vec<ShmBuffer>,
    /// Index of the buffer attached to the frame in flight.
    attached: Option<usize>,
    frame: Option<ext_image_copy_capture_frame_v1::ExtImageCopyCaptureFrameV1>,
    frame_presentation: Option<u128>,
    ready: bool,
    failed: Option<WEnum<ext_image_copy_capture_frame_v1::FailureReason>>,
    frames_ready: u64,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_shm" => state.shm = Some(registry.bind(name, 1, qh, ())),
                "wl_output" if version >= 4 => {
                    let o: wl_output::WlOutput = registry.bind(name, 4, qh, name);
                    state.outputs.insert(name, (o, String::new()));
                }
                "ext_output_image_capture_source_manager_v1" => {
                    state.source_mgr = Some(registry.bind(name, 1, qh, ()))
                }
                "ext_image_copy_capture_manager_v1" => {
                    state.capture_mgr = Some(registry.bind(name, 1, qh, ()))
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_output::WlOutput, u32> for State {
    fn event(
        state: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        global: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_output::Event::Name { name } = event {
            if let Some(o) = state.outputs.get_mut(global) {
                o.1 = name;
            }
        }
    }
}

impl Dispatch<ext_image_copy_capture_session_v1::ExtImageCopyCaptureSessionV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &ext_image_copy_capture_session_v1::ExtImageCopyCaptureSessionV1,
        event: ext_image_copy_capture_session_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use ext_image_copy_capture_session_v1::Event;
        match event {
            Event::BufferSize { width, height } => {
                state.session.width = width;
                state.session.height = height;
            }
            Event::ShmFormat {
                format: WEnum::Value(f),
            } => state.session.shm_formats.push(f),
            Event::DmabufDevice { .. } | Event::DmabufFormat { .. } => {}
            Event::Done => state.session.done = true,
            Event::Stopped => state.session.stopped = true,
            _ => {}
        }
    }
}

impl Dispatch<ext_image_copy_capture_frame_v1::ExtImageCopyCaptureFrameV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &ext_image_copy_capture_frame_v1::ExtImageCopyCaptureFrameV1,
        event: ext_image_copy_capture_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use ext_image_copy_capture_frame_v1::Event;
        match event {
            Event::PresentationTime {
                tv_sec_hi,
                tv_sec_lo,
                tv_nsec,
            } => {
                let secs = ((tv_sec_hi as u128) << 32) | tv_sec_lo as u128;
                state.frame_presentation = Some(secs * 1_000_000_000 + tv_nsec as u128);
            }
            Event::Ready => {
                state.ready = true;
                state.frames_ready += 1;
            }
            Event::Failed { reason } => state.failed = Some(reason),
            _ => {}
        }
    }
}

macro_rules! noop_dispatch {
    ($($t:ty),*) => {$(
        impl Dispatch<$t, ()> for State {
            fn event(_: &mut Self, _: &$t, _: <$t as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
    )*};
}
noop_dispatch!(
    wl_shm::WlShm,
    wl_shm_pool::WlShmPool,
    wl_buffer::WlBuffer,
    ext_output_image_capture_source_manager_v1::ExtOutputImageCaptureSourceManagerV1,
    ext_image_capture_source_v1::ExtImageCaptureSourceV1,
    ext_image_copy_capture_manager_v1::ExtImageCopyCaptureManagerV1
);

/// A capture of one output on its own thread. [`stop`](Self::stop) (or drop)
/// joins the thread, so once it returns no frame is in flight.
pub struct CaptureThread {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl CaptureThread {
    pub fn spawn(
        output: &str,
        opts: CaptureOptions,
        path: CapturePath,
        mut sink: FrameSink,
    ) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let output = output.to_string();
        let handle = std::thread::Builder::new()
            .name("capture".into())
            .spawn(move || {
                // A panic in here (or in the sink) must still tell the session
                // that capture is gone, so it rebuilds instead of idling.
                let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let on_frame = |info: &FrameInfo, lease: Lease| {
                        sink(CaptureEvent::Frame(Frame {
                            captured_at: info.ready_at,
                            presentation_ns: info.presentation_ns,
                            buf: FrameBuf::Cpu {
                                pixels: Pixels::Leased(Box::new(lease)),
                                width: info.width,
                                height: info.height,
                                stride: info.stride,
                                format: pixel_format(info.format),
                            },
                        }));
                    };
                    let forever = Duration::from_secs(u64::MAX / 4);
                    match path {
                        CapturePath::Ext => capture_shm(
                            Some(&output),
                            opts.cursor,
                            forever,
                            thread_stop.clone(),
                            on_frame,
                        ),
                        CapturePath::Wlr => super::screencopy::capture_wlr(
                            &output,
                            opts.cursor,
                            forever,
                            thread_stop.clone(),
                            on_frame,
                        ),
                    }
                }))
                .unwrap_or_else(|_| Err(anyhow::anyhow!("capture thread panicked")));
                if thread_stop.load(Ordering::Relaxed) {
                    if let Err(e) = r {
                        debug!("capture ended after stop: {e:#}");
                    }
                    return;
                }
                let why = match r {
                    Ok(_) => format!("capture of {output} stopped by the compositor"),
                    Err(e) => format!("capture of {output} failed: {e:#}"),
                };
                warn!("{why}");
                sink(CaptureEvent::Ended(why));
            })?;
        Ok(Self {
            stop,
            handle: Some(handle),
        })
    }

    /// Stop and join. Idempotent.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for CaptureThread {
    fn drop(&mut self) {
        self.stop();
    }
}

pub(super) fn pixel_format(f: wl_shm::Format) -> PixelFormat {
    match f {
        wl_shm::Format::Argb8888 => PixelFormat::Argb8888,
        wl_shm::Format::Xbgr8888 => PixelFormat::Xbgr8888,
        wl_shm::Format::Abgr8888 => PixelFormat::Abgr8888,
        _ => PixelFormat::Xrgb8888,
    }
}

/// Capture `output_name` (or the first output) for `duration`, calling
/// `on_frame` with each ready frame's pixels (rows of `stride` bytes) as a
/// lease on the shm buffer they were captured into. The buffer is reused
/// once the lease is dropped; holding [`MAX_BUFFERS`] leases pauses capture.
/// Returns the number of frames delivered.
pub fn capture_shm(
    output_name: Option<&str>,
    include_cursor: bool,
    duration: Duration,
    stop: Arc<AtomicBool>,
    mut on_frame: impl FnMut(&FrameInfo, Lease),
) -> Result<u64> {
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State {
        shm: None,
        outputs: HashMap::new(),
        source_mgr: None,
        capture_mgr: None,
        session: SessionInfo::default(),
        buffers: Vec::new(),
        attached: None,
        frame: None,
        frame_presentation: None,
        ready: false,
        failed: None,
        frames_ready: 0,
    };
    queue.roundtrip(&mut st)?;
    queue.roundtrip(&mut st)?;
    let shm = st.shm.clone().context("compositor has no wl_shm")?;
    let source_mgr = st
        .source_mgr
        .clone()
        .context("compositor lacks ext_output_image_capture_source_manager_v1")?;
    let capture_mgr = st
        .capture_mgr
        .clone()
        .context("compositor lacks ext_image_copy_capture_manager_v1")?;
    let (output, name) = match output_name {
        Some(n) => st
            .outputs
            .values()
            .find(|(_, name)| name == n)
            .cloned()
            .with_context(|| {
                format!(
                    "no output {n}; have {:?}",
                    st.outputs
                        .values()
                        .map(|(_, n)| n.clone())
                        .collect::<Vec<_>>()
                )
            })?,
        None => st.outputs.values().next().cloned().context("no outputs")?,
    };
    info!("capturing output {name}");

    let source = source_mgr.create_source(&output, &qh, ());
    let options = if include_cursor {
        ext_image_copy_capture_manager_v1::Options::PaintCursors
    } else {
        ext_image_copy_capture_manager_v1::Options::empty()
    };
    let session = capture_mgr.create_session(&source, options, &qh, ());
    // Bounded and watching `stop`, so a joiner is never stuck behind a
    // compositor that does not describe the session.
    let setup_deadline = Instant::now() + Duration::from_secs(5);
    while !st.session.done {
        if stop.load(Ordering::Relaxed) {
            return Ok(0);
        }
        if Instant::now() >= setup_deadline {
            bail!("the compositor did not describe the capture session within 5 s");
        }
        dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::from_millis(100))?;
        if st.session.stopped {
            bail!("capture session stopped by the compositor");
        }
    }
    info!(
        "session: {}x{} shm formats {:?}",
        st.session.width, st.session.height, st.session.shm_formats
    );

    let recycler = Recycler::default();
    let start = Instant::now();
    let mut first_frame: Option<Duration> = None;
    let mut last_ready = start;
    let mut intervals_ms: Vec<f64> = Vec::new();
    while start.elapsed() < duration && !st.session.stopped && !stop.load(Ordering::Relaxed) {
        // Reallocate every buffer when the session's size changes.
        if st
            .buffers
            .first()
            .is_some_and(|b| b.width != st.session.width || b.height != st.session.height)
        {
            recycler.reset();
            st.buffers.clear();
        }
        if st.frame.is_none() {
            let index = match recycler.take() {
                Some(i) => i,
                None if st.buffers.len() < MAX_BUFFERS => {
                    let format = pick_format(&st.session.shm_formats)?;
                    st.buffers.push(ShmBuffer::new(
                        &shm,
                        &qh,
                        st.session.width,
                        st.session.height,
                        st.session.width * 4,
                        format,
                    )?);
                    debug!(
                        "allocated capture buffer {} at {}x{} {:?}",
                        st.buffers.len(),
                        st.session.width,
                        st.session.height,
                        format
                    );
                    st.buffers.len() - 1
                }
                None => {
                    // Every buffer is lent out: the encoder is behind.
                    recycler.wait(Duration::from_millis(250));
                    continue;
                }
            };
            // Hyprland 0.56.2 segfaults on a create_frame for an output whose
            // monitor is already gone
            // (research/linux/hyprland-screenshare-transform.md): read what
            // the compositor sent without blocking, and never create a frame
            // on a stopped session.
            dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::ZERO)?;
            if !may_create_frame(&st.session, stop.load(Ordering::Relaxed)) {
                recycler.release(index);
                break;
            }
            if (st.buffers[index].width, st.buffers[index].height)
                != (st.session.width, st.session.height)
            {
                // Resized meanwhile: the top of the loop reallocates.
                recycler.release(index);
                continue;
            }
            let frame = session.create_frame(&qh, ());
            let b = &st.buffers[index];
            frame.attach_buffer(&b.buffer);
            frame.damage_buffer(0, 0, b.width as i32, b.height as i32);
            frame.capture();
            st.frame = Some(frame);
            st.attached = Some(index);
            st.ready = false;
            st.failed = None;
            st.frame_presentation = None;
        }
        dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::from_millis(250))?;
        if st.ready {
            let now = Instant::now();
            first_frame.get_or_insert(now - start);
            intervals_ms.push((now - last_ready).as_secs_f64() * 1000.0);
            last_ready = now;
            let index = st.attached.take().expect("a frame in flight has a buffer");
            let b = &st.buffers[index];
            let lease = recycler.lease(index, b.map.clone(), (b.stride * b.height) as usize);
            let info = FrameInfo {
                width: b.width,
                height: b.height,
                stride: b.stride,
                format: b.format,
                presentation_ns: st.frame_presentation,
                ready_at: now,
            };
            on_frame(&info, lease);
            if let Some(f) = st.frame.take() {
                f.destroy();
            }
        } else if let Some(reason) = st.failed.take() {
            warn!("frame failed: {reason:?}");
            if let Some(f) = st.frame.take() {
                f.destroy();
            }
            match after_failure(reason) {
                AfterFailure::Reallocate => {
                    recycler.reset();
                    st.buffers.clear();
                    st.attached = None;
                }
                AfterFailure::Retry => {
                    if let Some(index) = st.attached.take() {
                        recycler.release(index);
                    }
                }
                AfterFailure::EndSession => {
                    // The session is done even if its own `stopped` event has
                    // not been dispatched yet.
                    st.session.stopped = true;
                }
            }
        }
    }
    if let Some(f) = st.frame.take() {
        f.destroy();
    }
    session.destroy();
    source.destroy();
    let _ = queue.roundtrip(&mut st);
    let n = intervals_ms.len();
    if n > 1 {
        intervals_ms.sort_by(f64::total_cmp);
        info!(
            "{n} frames in {:.1}s: first after {:.0} ms; interval p50 {:.1} ms, p95 {:.1} ms, min {:.1} ms",
            start.elapsed().as_secs_f64(),
            first_frame.map_or(0.0, |d| d.as_secs_f64() * 1000.0),
            intervals_ms[n / 2],
            intervals_ms[(n as f64 * 0.95) as usize],
            intervals_ms[0]
        );
    }
    Ok(st.frames_ready)
}

/// Whether the loop may send another `create_frame`: never on a stopped
/// session or after a stop request. One frame is in flight at a time (the
/// loop only creates one when the previous is done).
fn may_create_frame(session: &SessionInfo, stop_requested: bool) -> bool {
    !session.stopped && !stop_requested
}

#[derive(Debug, PartialEq, Eq)]
enum AfterFailure {
    /// Same buffers, next frame.
    Retry,
    /// The buffers no longer fit the session's constraints.
    Reallocate,
    /// The session is over (output gone): no further frame on it.
    EndSession,
}

fn after_failure(reason: WEnum<ext_image_copy_capture_frame_v1::FailureReason>) -> AfterFailure {
    use ext_image_copy_capture_frame_v1::FailureReason;
    match reason {
        WEnum::Value(FailureReason::BufferConstraints) => AfterFailure::Reallocate,
        WEnum::Value(FailureReason::Stopped) => AfterFailure::EndSession,
        _ => AfterFailure::Retry,
    }
}

fn pick_format(formats: &[wl_shm::Format]) -> Result<wl_shm::Format> {
    for pref in [
        wl_shm::Format::Xrgb8888,
        wl_shm::Format::Argb8888,
        wl_shm::Format::Xbgr8888,
        wl_shm::Format::Abgr8888,
    ] {
        if formats.contains(&pref) {
            return Ok(pref);
        }
    }
    formats
        .first()
        .copied()
        .context("session offered no shm formats")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ext_image_copy_capture_frame_v1::FailureReason;

    #[test]
    fn no_frame_on_a_stopped_session_or_after_stop() {
        let mut s = SessionInfo::default();
        assert!(may_create_frame(&s, false));
        assert!(!may_create_frame(&s, true));
        s.stopped = true;
        assert!(!may_create_frame(&s, false));
    }

    #[test]
    fn a_stopped_frame_ends_the_session() {
        assert_eq!(
            after_failure(WEnum::Value(FailureReason::Stopped)),
            AfterFailure::EndSession
        );
        assert_eq!(
            after_failure(WEnum::Value(FailureReason::BufferConstraints)),
            AfterFailure::Reallocate
        );
        assert_eq!(
            after_failure(WEnum::Value(FailureReason::Unknown)),
            AfterFailure::Retry
        );
        assert_eq!(after_failure(WEnum::Unknown(99)), AfterFailure::Retry);
    }
}
