//! Continuous capture of one Wayland output through
//! `ext-image-copy-capture-v1` into `wl_shm` buffers. This is the software
//! path (pixels cross the CPU once); the dmabuf path for VA-API zero-copy
//! encode lands with Spike 0 on hardware that has an encoder.

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tracing::{debug, info, warn};
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
}

struct ShmBuffer {
    file: std::fs::File,
    _pool: wl_shm_pool::WlShmPool,
    buffer: wl_buffer::WlBuffer,
    width: u32,
    height: u32,
    stride: u32,
    format: wl_shm::Format,
}

impl ShmBuffer {
    fn new(
        shm: &wl_shm::WlShm,
        qh: &QueueHandle<State>,
        width: u32,
        height: u32,
        format: wl_shm::Format,
    ) -> Result<Self> {
        let stride = width * 4;
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
            file,
            _pool: pool,
            buffer,
            width,
            height,
            stride,
            format,
        })
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
    buffer: Option<ShmBuffer>,
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

/// Capture `output_name` (or the first output) for `duration`, calling
/// `on_frame` with each ready frame's pixels (tightly packed rows of
/// `stride` bytes). Returns the number of frames delivered.
pub fn capture_shm(
    output_name: Option<&str>,
    include_cursor: bool,
    duration: Duration,
    stop: Arc<AtomicBool>,
    mut on_frame: impl FnMut(&FrameInfo, &[u8]),
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
        buffer: None,
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
    while !st.session.done {
        queue.blocking_dispatch(&mut st)?;
        if st.session.stopped {
            bail!("capture session stopped by the compositor");
        }
    }
    info!(
        "session: {}x{} shm formats {:?}",
        st.session.width, st.session.height, st.session.shm_formats
    );

    let start = Instant::now();
    let mut first_frame: Option<Duration> = None;
    let mut last_ready = start;
    let mut intervals_ms: Vec<f64> = Vec::new();
    while start.elapsed() < duration && !st.session.stopped && !stop.load(Ordering::Relaxed) {
        // (Re)allocate the buffer to the session's current size.
        let need_alloc = st
            .buffer
            .as_ref()
            .is_none_or(|b| b.width != st.session.width || b.height != st.session.height);
        if need_alloc {
            let format = pick_format(&st.session.shm_formats)?;
            st.buffer = Some(ShmBuffer::new(
                &shm,
                &qh,
                st.session.width,
                st.session.height,
                format,
            )?);
            debug!(
                "allocated {}x{} {:?}",
                st.session.width, st.session.height, format
            );
        }
        if st.frame.is_none() {
            let frame = session.create_frame(&qh, ());
            let b = st.buffer.as_ref().unwrap();
            frame.attach_buffer(&b.buffer);
            frame.damage_buffer(0, 0, b.width as i32, b.height as i32);
            frame.capture();
            st.frame = Some(frame);
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
            let b = st.buffer.as_ref().unwrap();
            let mut pixels = vec![0u8; (b.stride * b.height) as usize];
            b.file.read_exact_at(&mut pixels, 0)?;
            let info = FrameInfo {
                width: b.width,
                height: b.height,
                stride: b.stride,
                format: b.format,
                presentation_ns: st.frame_presentation,
            };
            on_frame(&info, &pixels);
            if let Some(f) = st.frame.take() {
                f.destroy();
            }
        } else if let Some(reason) = st.failed.take() {
            warn!("frame failed: {reason:?}");
            if let Some(f) = st.frame.take() {
                f.destroy();
            }
            if matches!(
                reason,
                WEnum::Value(ext_image_copy_capture_frame_v1::FailureReason::BufferConstraints)
            ) {
                st.buffer = None;
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

/// `blocking_dispatch` with an upper bound, so a capture of a static output
/// (which never produces a frame) still notices the stop flag.
fn dispatch_with_timeout(
    conn: &Connection,
    queue: &mut wayland_client::EventQueue<State>,
    st: &mut State,
    timeout: Duration,
) -> Result<()> {
    use std::os::fd::AsRawFd;
    queue.dispatch_pending(st)?;
    conn.flush()?;
    let Some(guard) = conn.prepare_read() else {
        queue.dispatch_pending(st)?;
        return Ok(());
    };
    let fd = guard.connection_fd().as_raw_fd();
    let mut pfd = libc_pollfd(fd);
    // SAFETY: pollfd points at one valid struct for the duration of the call.
    let r = unsafe { libc_poll(&mut pfd, 1, timeout.as_millis() as i32) };
    if r > 0 {
        let _ = guard.read();
        queue.dispatch_pending(st)?;
    }
    Ok(())
}

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

fn libc_pollfd(fd: i32) -> PollFd {
    PollFd {
        fd,
        events: 0x001, /* POLLIN */
        revents: 0,
    }
}

unsafe extern "C" {
    #[link_name = "poll"]
    fn libc_poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
}
