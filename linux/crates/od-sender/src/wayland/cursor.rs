//! The pointer cursor of one output, delivered on its own for the cursor
//! side channel (PROTOCOL §6.2 `cursor`/`cursorImg`, §6.3), through an
//! `ext_image_copy_capture_cursor_session_v1`: `enter`/`leave`/`position`
//! events for where the hotspot is, and an image capture session for the
//! sprite. Runs on its own thread with its own Wayland connection.
//!
//! The cursor session is a capture of the output like the frame capture, so
//! the same rule holds: it is stopped and joined before the output is
//! reconfigured or removed ([`super::display::CapturedDisplay`] does both).

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tracing::{debug, warn};
use wayland_client::protocol::{
    wl_buffer, wl_output, wl_pointer, wl_registry, wl_seat, wl_shm, wl_shm_pool,
};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use wayland_protocols::ext::image_capture_source::v1::client::{
    ext_image_capture_source_v1, ext_output_image_capture_source_manager_v1,
};
use wayland_protocols::ext::image_copy_capture::v1::client::{
    ext_image_copy_capture_cursor_session_v1, ext_image_copy_capture_frame_v1,
    ext_image_copy_capture_manager_v1, ext_image_copy_capture_session_v1,
};

use crate::backend::{CursorEvent, CursorSink};

/// The official sender's ceiling for position updates (PROTOCOL §6.2).
const MIN_MOVE_INTERVAL: Duration = Duration::from_micros(8_333);
/// `cursorImg` PNGs stay under this many bytes before base64 (PROTOCOL §6.2).
pub const MAX_PNG_BYTES: usize = 24_000;

// ---------------------------------------------------------------------------
// Sprite encoding: premultiplied BGRA (wl_shm ARGB8888) -> PNG -> base64.

/// Byte order of a 32-bit sprite in memory (wl_shm formats are named
/// little-endian: ARGB8888 is B, G, R, A in memory).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpriteOrder {
    /// ARGB8888.
    Bgra,
    /// ABGR8888.
    Rgba,
}

impl SpriteOrder {
    /// The shm formats a sprite can come in: they need alpha.
    pub fn of(f: wl_shm::Format) -> Option<Self> {
        match f {
            wl_shm::Format::Argb8888 => Some(SpriteOrder::Bgra),
            wl_shm::Format::Abgr8888 => Some(SpriteOrder::Rgba),
            _ => None,
        }
    }
}

/// Straight-alpha RGBA from a premultiplied 32-bit sprite.
pub fn premul_to_rgba(
    px: &[u8],
    order: SpriteOrder,
    width: u32,
    height: u32,
    stride: u32,
) -> Vec<u8> {
    let mut out = Vec::with_capacity((width * height * 4) as usize);
    for y in 0..height as usize {
        let row = &px[y * stride as usize..][..width as usize * 4];
        for px in row.chunks_exact(4) {
            let (r, g, b, a) = match order {
                SpriteOrder::Bgra => (px[2], px[1], px[0], px[3]),
                SpriteOrder::Rgba => (px[0], px[1], px[2], px[3]),
            };
            let un = |c: u8| {
                if a == 0 {
                    0
                } else {
                    ((c as u32 * 255 + a as u32 / 2) / a as u32).min(255) as u8
                }
            };
            out.extend_from_slice(&[un(r), un(g), un(b), a]);
        }
    }
    out
}

/// Halve an RGBA sprite (2x2 box, alpha-weighted so edges do not darken).
pub fn halve_rgba(rgba: &[u8], width: u32, height: u32) -> (Vec<u8>, u32, u32) {
    let (w2, h2) = ((width / 2).max(1), (height / 2).max(1));
    let mut out = Vec::with_capacity((w2 * h2 * 4) as usize);
    for y in 0..h2 {
        for x in 0..w2 {
            let mut acc = [0u32; 4];
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let (sx, sy) = ((2 * x + dx).min(width - 1), (2 * y + dy).min(height - 1));
                let p = &rgba[((sy * width + sx) * 4) as usize..][..4];
                let a = p[3] as u32;
                for c in 0..3 {
                    acc[c] += p[c] as u32 * a;
                }
                acc[3] += a;
            }
            let a = acc[3];
            let px = |c: usize| (acc[c] + a / 2).checked_div(a).unwrap_or(0) as u8;
            out.extend_from_slice(&[px(0), px(1), px(2), ((a + 2) / 4) as u8]);
        }
    }
    (out, w2, h2)
}

fn crc32(chunks: &[&[u8]]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for data in chunks {
        for &b in *data {
            crc ^= b as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >> 1
                };
            }
        }
    }
    !crc
}

/// An 8-bit RGBA PNG.
pub fn encode_png(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
    let mut raw = Vec::with_capacity((width * height * 4 + height) as usize);
    for row in rgba.chunks_exact(width as usize * 4) {
        raw.push(0); // filter: none
        raw.extend_from_slice(row);
    }
    let idat = miniz_oxide::deflate::compress_to_vec_zlib(&raw, 9);
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8 bit, RGBA, deflate, adaptive, no interlace
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    for (kind, data) in [
        (b"IHDR", &ihdr[..]),
        (b"IDAT", &idat[..]),
        (b"IEND", &[][..]),
    ] {
        png.extend_from_slice(&(data.len() as u32).to_be_bytes());
        png.extend_from_slice(kind);
        png.extend_from_slice(data);
        png.extend_from_slice(&crc32(&[kind, data]).to_be_bytes());
    }
    png
}

/// The sprite as a PNG under [`MAX_PNG_BYTES`], halving it while it is not.
pub fn sprite_png(mut rgba: Vec<u8>, mut width: u32, mut height: u32) -> Vec<u8> {
    loop {
        let png = encode_png(&rgba, width, height);
        if png.len() <= MAX_PNG_BYTES || (width <= 8 && height <= 8) {
            return png;
        }
        (rgba, width, height) = halve_rgba(&rgba, width, height);
    }
}

/// Standard base64 with padding (`cursorImg.png`).
pub fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

// ---------------------------------------------------------------------------
// Coordinates.

/// The units a compositor's cursor session reports in, for one output.
///
/// The protocol says `position` is in the output buffer's pixels and
/// `hotspot` in the sprite buffer's. Hyprland 0.56.2 instead sends both in
/// logical (layout) units, and renders the sprite at the highest monitor
/// scale (`CImageCopyCaptureCursorSession::sendCursorEvents`,
/// `CCursorManager`), so a backend says which applies.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorSpace {
    /// The output's size in the units of `position`.
    pub width: f64,
    pub height: f64,
    /// Sprite buffer pixels per `position`/`hotspot` unit, at most: the
    /// highest monitor scale on Hyprland.
    pub sprite_scale: f64,
    /// The cursor theme's size in units (`HYPRCURSOR_SIZE`/`XCURSOR_SIZE`),
    /// when known: a sprite of n times that many pixels is at scale n, which
    /// catches a compositor that did not load the theme at `sprite_scale`.
    pub theme_size: Option<f64>,
}

impl CursorSpace {
    /// As the protocol specifies: everything in buffer pixels.
    pub fn pixels(width: u32, height: u32) -> Self {
        Self {
            width: width.max(1) as f64,
            height: height.max(1) as f64,
            sprite_scale: 1.0,
            theme_size: None,
        }
    }

    /// The scale a `w`x`h` sprite is rendered at.
    pub fn scale_of(&self, w: u32, h: u32) -> f64 {
        let max = self.sprite_scale.max(1.0);
        match self.theme_size {
            Some(t) if t > 0.0 => (w.max(h) as f64 / t).clamp(1.0, max),
            _ => max,
        }
    }

    /// `cursorImg` geometry for a `w`x`h` sprite with this hotspot:
    /// (nw, nh, ax, ay), PROTOCOL §6.2 / §7.
    pub fn sprite_geometry(&self, w: u32, h: u32, hotspot: (i32, i32)) -> (f64, f64, f64, f64) {
        let scale = self.scale_of(w, h);
        let lw = w.max(1) as f64 / scale;
        let lh = h.max(1) as f64 / scale;
        (
            lw / self.width,
            lh / self.height,
            (hotspot.0 as f64 / lw).clamp(0.0, 1.0),
            (hotspot.1 as f64 / lh).clamp(0.0, 1.0),
        )
    }
}

/// The cursor theme size from the environment the compositor shares with
/// its clients (`HYPRCURSOR_SIZE`, then `XCURSOR_SIZE`), default 24.
pub fn theme_size() -> Option<f64> {
    ["HYPRCURSOR_SIZE", "XCURSOR_SIZE"]
        .iter()
        .find_map(|k| std::env::var(k).ok()?.trim().parse::<f64>().ok())
        .filter(|s| *s > 0.0)
        .or(Some(24.0))
}

// ---------------------------------------------------------------------------
// Position: the hotspot in output units -> normalized, rate-limited updates.

/// Turns `enter`/`leave`/`position` into [`CursorEvent`]s: positions are
/// normalized to the output, coalesced to [`MIN_MOVE_INTERVAL`], and
/// repeated positions dropped.
pub struct Positions {
    space: CursorSpace,
    inside: bool,
    hidden_sent: bool,
    latest: Option<(i32, i32)>,
    sent: Option<(i32, i32)>,
    last_emit: Option<Instant>,
}

impl Positions {
    pub fn new(space: CursorSpace) -> Self {
        Self {
            space,
            inside: false,
            hidden_sent: false,
            latest: None,
            sent: None,
            last_emit: None,
        }
    }

    pub fn enter(&mut self) {
        self.inside = true;
    }

    pub fn inside(&self) -> bool {
        self.inside
    }

    pub fn leave(&mut self) {
        self.inside = false;
        self.latest = None;
        self.sent = None;
    }

    pub fn position(&mut self, x: i32, y: i32) {
        self.latest = Some((x, y));
    }

    /// The event to send now, if any, and when to ask again.
    pub fn poll(&mut self, now: Instant) -> (Option<CursorEvent>, Option<Duration>) {
        if !self.inside {
            if self.hidden_sent {
                return (None, None);
            }
            self.hidden_sent = true;
            return (Some(CursorEvent::Hidden), None);
        }
        let Some(p) = self.latest else {
            return (None, None);
        };
        if self.sent == Some(p) {
            return (None, None);
        }
        if let Some(t) = self.last_emit {
            let since = now.saturating_duration_since(t);
            if since < MIN_MOVE_INTERVAL {
                return (None, Some(MIN_MOVE_INTERVAL - since));
            }
        }
        self.sent = Some(p);
        self.hidden_sent = false;
        self.last_emit = Some(now);
        let ev = CursorEvent::Moved {
            x: p.0 as f64 / self.space.width,
            y: p.1 as f64 / self.space.height,
        };
        (Some(ev), None)
    }
}

// ---------------------------------------------------------------------------
// The Wayland side.

struct ShmBuffer {
    file: std::fs::File,
    _pool: wl_shm_pool::WlShmPool,
    buffer: wl_buffer::WlBuffer,
    width: u32,
    height: u32,
    stride: u32,
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
            "/dev/shm/od-cursor-{}-{:?}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
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
        })
    }
}

impl Drop for ShmBuffer {
    fn drop(&mut self) {
        self.buffer.destroy();
    }
}

/// A session's buffer constraints. Events arrive as a batch closed by
/// `done` in any order (Hyprland: shm formats, dmabuf, then size), and a
/// later batch replaces the earlier one.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Constraints {
    pending_size: Option<(u32, u32)>,
    pending_formats: Vec<WEnum<wl_shm::Format>>,
    /// The committed batch.
    pub size: (u32, u32),
    pub formats: Vec<WEnum<wl_shm::Format>>,
    pub known: bool,
}

impl Constraints {
    pub fn size(&mut self, w: u32, h: u32) {
        self.pending_size = Some((w, h));
    }
    pub fn shm_format(&mut self, f: WEnum<wl_shm::Format>) {
        self.pending_formats.push(f);
    }
    pub fn done(&mut self) {
        if let Some(s) = self.pending_size.take() {
            self.size = s;
        }
        self.formats = std::mem::take(&mut self.pending_formats);
        self.known = true;
    }
    /// A format a sprite can be read from.
    pub fn sprite_format(&self) -> Option<(wl_shm::Format, SpriteOrder)> {
        self.formats.iter().find_map(|f| match f {
            WEnum::Value(f) => SpriteOrder::of(*f).map(|o| (*f, o)),
            WEnum::Unknown(_) => None,
        })
    }
}

#[derive(Default)]
struct State {
    shm: Option<wl_shm::WlShm>,
    seat: Option<wl_seat::WlSeat>,
    outputs: HashMap<u32, (Option<wl_output::WlOutput>, String)>,
    source_mgr:
        Option<ext_output_image_capture_source_manager_v1::ExtOutputImageCaptureSourceManagerV1>,
    capture_mgr: Option<ext_image_copy_capture_manager_v1::ExtImageCopyCaptureManagerV1>,
    // Image session constraints: collected until `done`, which commits them.
    constraints: Constraints,
    stopped: bool,
    // Cursor session.
    entered: Option<bool>,
    positions: Vec<(i32, i32)>,
    hotspot_pending: Option<(i32, i32)>,
    // Frame.
    ready: bool,
    failed: Option<WEnum<ext_image_copy_capture_frame_v1::FailureReason>>,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        st: &mut Self,
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
                "wl_shm" => st.shm = Some(registry.bind(name, 1, qh, ())),
                "wl_seat" if st.seat.is_none() => {
                    st.seat = Some(registry.bind(name, version.min(5), qh, ()))
                }
                "wl_output" if version >= 4 => {
                    let o: wl_output::WlOutput = registry.bind(name, 4, qh, name);
                    st.outputs.insert(name, (Some(o), String::new()));
                }
                "ext_output_image_capture_source_manager_v1" => {
                    st.source_mgr = Some(registry.bind(name, 1, qh, ()))
                }
                "ext_image_copy_capture_manager_v1" => {
                    st.capture_mgr = Some(registry.bind(name, 1, qh, ()))
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_output::WlOutput, u32> for State {
    fn event(
        st: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        global: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_output::Event::Name { name } = event {
            if let Some(o) = st.outputs.get_mut(global) {
                o.1 = name;
            }
        }
    }
}

impl Dispatch<ext_image_copy_capture_session_v1::ExtImageCopyCaptureSessionV1, ()> for State {
    fn event(
        st: &mut Self,
        _: &ext_image_copy_capture_session_v1::ExtImageCopyCaptureSessionV1,
        event: ext_image_copy_capture_session_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use ext_image_copy_capture_session_v1::Event;
        match event {
            Event::BufferSize { width, height } => st.constraints.size(width, height),
            Event::ShmFormat { format } => st.constraints.shm_format(format),
            Event::Done => st.constraints.done(),
            Event::Stopped => st.stopped = true,
            _ => {}
        }
    }
}

impl Dispatch<ext_image_copy_capture_cursor_session_v1::ExtImageCopyCaptureCursorSessionV1, ()>
    for State
{
    fn event(
        st: &mut Self,
        _: &ext_image_copy_capture_cursor_session_v1::ExtImageCopyCaptureCursorSessionV1,
        event: ext_image_copy_capture_cursor_session_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use ext_image_copy_capture_cursor_session_v1::Event;
        match event {
            Event::Enter => st.entered = Some(true),
            Event::Leave => st.entered = Some(false),
            Event::Position { x, y } => st.positions.push((x, y)),
            Event::Hotspot { x, y } => st.hotspot_pending = Some((x, y)),
            _ => {}
        }
    }
}

impl Dispatch<ext_image_copy_capture_frame_v1::ExtImageCopyCaptureFrameV1, ()> for State {
    fn event(
        st: &mut Self,
        _: &ext_image_copy_capture_frame_v1::ExtImageCopyCaptureFrameV1,
        event: ext_image_copy_capture_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use ext_image_copy_capture_frame_v1::Event;
        match event {
            Event::Ready => st.ready = true,
            Event::Failed { reason } => st.failed = Some(reason),
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
    wl_seat::WlSeat,
    wl_pointer::WlPointer,
    ext_output_image_capture_source_manager_v1::ExtOutputImageCaptureSourceManagerV1,
    ext_image_capture_source_v1::ExtImageCaptureSourceV1,
    ext_image_copy_capture_manager_v1::ExtImageCopyCaptureManagerV1
);

/// The cursor of one output on its own thread. [`stop`](Self::stop) (or
/// drop) joins it, so once it returns the cursor session is gone.
pub struct CursorThread {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

/// How long [`CursorThread::spawn`] waits for the cursor session.
const READY_WITHIN: Duration = Duration::from_secs(5);

impl CursorThread {
    /// Start delivering the cursor of output `name`, whose cursor session
    /// reports in `space`. Returns once the cursor session exists, or with
    /// the reason it cannot.
    pub fn spawn(name: &str, space: CursorSpace, sink: CursorSink) -> Result<Self> {
        Self::spawn_with_debug(name, space, sink, None)
    }

    /// [`spawn`](Self::spawn) plus low-level session events for diagnostics.
    pub fn spawn_with_debug(
        name: &str,
        space: CursorSpace,
        sink: CursorSink,
        debug_sink: Option<DebugSink>,
    ) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let name = name.to_string();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<()>>();
        let handle = std::thread::Builder::new()
            .name("cursor".into())
            .spawn(move || {
                let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run(&name, space, sink, debug_sink, &thread_stop, &ready_tx)
                }));
                match r {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => {
                        // Before the session existed this goes to `spawn`'s caller.
                        if ready_tx.send(Err(anyhow::anyhow!("{e:#}"))).is_err() {
                            warn!("cursor capture of {name} ended: {e:#}");
                        }
                    }
                    Err(_) => warn!("cursor thread panicked; the cursor stays where it was"),
                }
            })?;
        // Bounded: the setup roundtrips wait on the compositor. A thread
        // still stuck in them is told to stop and left; it exits once the
        // compositor answers (or the connection goes).
        match ready_rx.recv_timeout(READY_WITHIN) {
            Ok(Ok(())) => Ok(Self {
                stop,
                handle: Some(handle),
            }),
            Ok(Err(e)) => {
                let _ = handle.join();
                Err(e)
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                stop.store(true, Ordering::Relaxed);
                bail!("the compositor did not open a cursor session within {READY_WITHIN:?}")
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = handle.join();
                bail!("cursor thread died")
            }
        }
    }

    /// Stop and join. Idempotent.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for CursorThread {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Consecutive failed sprite frames before the sprite is given up.
const MAX_SPRITE_FAILURES: u32 = 5;
/// Empty copies taken with the pointer over the output before giving up.
const MAX_EMPTY_REFRESHES: u32 = 3;
/// Cursor sessions reopened to fetch a current sprite, at most this often.
const REOPEN_INTERVAL: Duration = Duration::from_millis(500);

/// What a captured sprite is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpriteKind {
    /// A cursor image.
    Cursor,
    /// Fully transparent: the cursor is hidden (Hyprland renders "clear"
    /// when the pointer has no image).
    Clear,
    /// Opaque black everywhere: Hyprland's placeholder when the cursor was
    /// not over the output at copy time (or capture is not permitted),
    /// `CCursorshareSession::render`. Never a real cursor.
    Placeholder,
}

/// Classify premultiplied 32-bit pixels (either byte order: black and
/// alpha positions agree for the checks made here).
pub fn sprite_kind(
    px: &[u8],
    order: SpriteOrder,
    width: u32,
    height: u32,
    stride: u32,
) -> SpriteKind {
    let (mut all_clear, mut all_black) = (true, true);
    for y in 0..height as usize {
        let row = &px[y * stride as usize..][..width as usize * 4];
        for p in row.chunks_exact(4) {
            let (c, a) = match order {
                SpriteOrder::Bgra | SpriteOrder::Rgba => ([p[0], p[1], p[2]], p[3]),
            };
            all_clear &= a == 0;
            all_black &= a == 255 && c == [0, 0, 0];
        }
    }
    if all_black {
        SpriteKind::Placeholder
    } else if all_clear {
        SpriteKind::Clear
    } else {
        SpriteKind::Cursor
    }
}

/// Low-level cursor session events for `dev cursor-test --save-raw`.
#[derive(Debug, Clone)]
#[allow(dead_code)] // fields are read through `Debug` when logged
pub enum CursorDebug {
    SessionOpened {
        reason: &'static str,
    },
    Constraints {
        size: (u32, u32),
        formats: Vec<String>,
    },
    Ready {
        hotspot: (i32, i32),
        kind: SpriteKind,
    },
    Failed(String),
    Raw {
        px: Vec<u8>,
        width: u32,
        height: u32,
        stride: u32,
        format: String,
    },
}

pub type DebugSink = Box<dyn FnMut(CursorDebug) + Send>;

type CursorSessions = (
    ext_image_copy_capture_cursor_session_v1::ExtImageCopyCaptureCursorSessionV1,
    ext_image_copy_capture_session_v1::ExtImageCopyCaptureSessionV1,
);

fn run(
    name: &str,
    space: CursorSpace,
    mut sink: CursorSink,
    mut debug_sink: Option<DebugSink>,
    stop: &AtomicBool,
    ready: &std::sync::mpsc::Sender<Result<()>>,
) -> Result<()> {
    let mut dbg = |d: CursorDebug| {
        if let Some(s) = debug_sink.as_mut() {
            s(d);
        }
    };
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State::default();
    queue.roundtrip(&mut st)?;
    queue.roundtrip(&mut st)?;
    let shm = st.shm.clone().context("compositor has no wl_shm")?;
    let seat = st.seat.clone().context("compositor has no wl_seat")?;
    let source_mgr = st
        .source_mgr
        .clone()
        .context("compositor lacks ext_output_image_capture_source_manager_v1")?;
    let capture_mgr = st
        .capture_mgr
        .clone()
        .context("compositor lacks ext_image_copy_capture_manager_v1")?;
    let output = st
        .outputs
        .values()
        .find(|(_, n)| n == name)
        .and_then(|(o, _)| o.clone())
        .with_context(|| format!("no output {name}"))?;

    let pointer = seat.get_pointer(&qh, ());
    let source = source_mgr.create_source(&output, &qh, ());
    let open = |qh: &QueueHandle<State>| -> CursorSessions {
        let c = capture_mgr.create_pointer_cursor_session(&source, &pointer, qh, ());
        let s = c.get_capture_session(qh, ());
        (c, s)
    };
    let mut sessions = open(&qh);
    queue.roundtrip(&mut st)?;
    if st.stopped {
        bail!("the compositor refused the cursor session");
    }
    let _ = ready.send(Ok(()));
    dbg(CursorDebug::SessionOpened { reason: "start" });
    debug!("cursor session for {name} open; the video keeps its cursor until the first sprite");

    let mut positions = Positions::new(space);
    let mut buffer: Option<(ShmBuffer, SpriteOrder)> = None;
    // Set once the sprite is given up; positions keep flowing.
    let mut sprite_failed = false;
    let mut failures = 0u32;
    let give_up = |why: String, sink: &mut CursorSink| {
        debug!("cursor sprite unavailable: {why}");
        sink(CursorEvent::SpriteUnavailable(why));
    };
    let mut frame: Option<ext_image_copy_capture_frame_v1::ExtImageCopyCaptureFrameV1> = None;
    let mut hotspot = (0, 0);
    let mut last_sprite: Option<(Vec<u8>, (i32, i32))> = None;
    // A real cursor image was sent; until then nothing but a real one goes.
    let mut have_sprite = false;
    // The last copy was Hyprland's placeholder: fetch the sprite again once
    // the cursor is over the output (a new session copies at once; an old
    // one only when the cursor image changes).
    let mut stale = false;
    let mut last_open = Instant::now();
    // Fresh sessions that still gave no image while the pointer was over
    // the output: past a few, the compositor cannot deliver one.
    let mut empty_refreshes = 0u32;
    let mut seen_constraints = None;
    let mut wait = Duration::from_millis(100);
    while !stop.load(Ordering::Relaxed) && !st.stopped {
        dispatch_with_timeout(&conn, &mut queue, &mut st, wait)?;
        wait = Duration::from_millis(100);

        let entered = st.entered.take();
        match entered {
            Some(true) => positions.enter(),
            Some(false) => positions.leave(),
            None => {}
        }
        for (x, y) in st.positions.drain(..) {
            positions.position(x, y);
        }
        let (ev, again) = positions.poll(Instant::now());
        if let Some(ev) = ev {
            sink(ev);
        }
        if let Some(again) = again {
            wait = again;
        }

        if stale && !sprite_failed && positions.inside() && last_open.elapsed() >= REOPEN_INTERVAL {
            // Fetch the current sprite with a fresh session (Hyprland copies
            // the first frame of a session at once).
            stale = false;
            last_open = Instant::now();
            if let Some(f) = frame.take() {
                f.destroy();
            }
            buffer = None;
            sessions.1.destroy();
            sessions.0.destroy();
            st.constraints = Constraints::default();
            st.hotspot_pending = None;
            sessions = open(&qh);
            dbg(CursorDebug::SessionOpened {
                reason: "refresh sprite",
            });
            continue;
        }

        let c = &st.constraints;
        if c.known && seen_constraints.as_ref() != Some(c) {
            seen_constraints = Some(c.clone());
            dbg(CursorDebug::Constraints {
                size: c.size,
                formats: c.formats.iter().map(|f| format!("{f:?}")).collect(),
            });
        }
        if !sprite_failed && c.known && c.size.0 > 0 && c.size.1 > 0 {
            let fits = buffer
                .as_ref()
                .is_some_and(|(b, _)| (b.width, b.height) == c.size);
            if !fits {
                if let Some(f) = frame.take() {
                    f.destroy();
                }
                buffer = None;
                match c.sprite_format() {
                    Some((fmt, order)) => {
                        debug!("cursor sprite buffer {}x{} {fmt:?}", c.size.0, c.size.1);
                        buffer = Some((ShmBuffer::new(&shm, &qh, c.size.0, c.size.1, fmt)?, order));
                    }
                    None => {
                        sprite_failed = true;
                        give_up(
                            format!("no 32-bit alpha shm format among {:?}", c.formats),
                            &mut sink,
                        );
                    }
                }
            }
        }
        if st.ready {
            st.ready = false;
            if let Some(f) = frame.take() {
                f.destroy();
            }
            if let Some(h) = st.hotspot_pending.take() {
                hotspot = h;
            }
            failures = 0;
            if let Some((b, order)) = &buffer {
                let mut px = vec![0u8; (b.stride * b.height) as usize];
                b.file.read_exact_at(&mut px, 0)?;
                let kind = sprite_kind(&px, *order, b.width, b.height, b.stride);
                dbg(CursorDebug::Ready { hotspot, kind });
                dbg(CursorDebug::Raw {
                    px: px.clone(),
                    width: b.width,
                    height: b.height,
                    stride: b.stride,
                    format: format!("{order:?}"),
                });
                let send = match kind {
                    SpriteKind::Cursor => true,
                    // A hidden cursor is news only to a receiver drawing one.
                    SpriteKind::Clear if have_sprite => true,
                    SpriteKind::Clear | SpriteKind::Placeholder => {
                        // No image yet. With the pointer over the output a
                        // fresh session should have copied one; a compositor
                        // whose copies stay empty cannot (Hyprland 0.56.2).
                        if positions.inside() && !have_sprite {
                            empty_refreshes += 1;
                        }
                        if empty_refreshes > MAX_EMPTY_REFRESHES && !sprite_failed {
                            sprite_failed = true;
                            give_up(
                                format!(
                                    "{empty_refreshes} cursor copies over the output were empty"
                                ),
                                &mut sink,
                            );
                        } else {
                            stale = true;
                        }
                        false
                    }
                };
                if send && last_sprite.as_ref() != Some(&(px.clone(), hotspot)) {
                    let rgba = premul_to_rgba(&px, *order, b.width, b.height, b.stride);
                    let png = sprite_png(rgba, b.width, b.height);
                    let (nw, nh, ax, ay) = space.sprite_geometry(b.width, b.height, hotspot);
                    debug!(
                        "cursor sprite {}x{} hotspot {hotspot:?}: {} bytes PNG",
                        b.width,
                        b.height,
                        png.len()
                    );
                    sink(CursorEvent::Image {
                        png,
                        nw,
                        nh,
                        ax,
                        ay,
                    });
                    have_sprite = true;
                    last_sprite = Some((px, hotspot));
                }
            }
        } else if let Some(reason) = st.failed.take() {
            if let Some(f) = frame.take() {
                f.destroy();
            }
            dbg(CursorDebug::Failed(format!("{reason:?}")));
            match reason {
                WEnum::Value(ext_image_copy_capture_frame_v1::FailureReason::Stopped) => break,
                WEnum::Value(ext_image_copy_capture_frame_v1::FailureReason::BufferConstraints) => {
                    buffer = None;
                }
                _ => {
                    failures += 1;
                    debug!("cursor frame failed: {reason:?}");
                    if failures >= MAX_SPRITE_FAILURES && !sprite_failed {
                        sprite_failed = true;
                        buffer = None;
                        give_up(
                            format!("{failures} sprite captures failed ({reason:?})"),
                            &mut sink,
                        );
                    }
                }
            }
        }
        if frame.is_none() && !sprite_failed {
            if let Some((b, _)) = &buffer {
                let f = sessions.1.create_frame(&qh, ());
                f.attach_buffer(&b.buffer);
                f.damage_buffer(0, 0, b.width as i32, b.height as i32);
                f.capture();
                frame = Some(f);
            }
        }
    }
    if let Some(f) = frame.take() {
        f.destroy();
    }
    drop(buffer);
    sessions.1.destroy();
    sessions.0.destroy();
    source.destroy();
    if pointer.version() >= 3 {
        pointer.release();
    }
    let _ = queue.roundtrip(&mut st);
    debug!("cursor thread done");
    Ok(())
}

/// `blocking_dispatch` with an upper bound, so the thread notices `stop`.
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
    let mut pfd = PollFd {
        fd: guard.connection_fd().as_raw_fd(),
        events: 0x001, // POLLIN
        revents: 0,
    };
    // SAFETY: one valid pollfd for the duration of the call.
    let r = unsafe { poll(&mut pfd, 1, timeout.as_millis() as i32) };
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

unsafe extern "C" {
    fn poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        for (i, o) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(i.as_bytes()), o);
        }
    }

    #[test]
    fn premultiplied_bgra_becomes_straight_rgba() {
        // Opaque red, half-transparent white (premultiplied 128), transparent.
        let bgra = [0, 0, 255, 255, 128, 128, 128, 128, 0, 0, 0, 0, 9, 9, 9, 9];
        let rgba = premul_to_rgba(&bgra, SpriteOrder::Bgra, 3, 1, 16);
        assert_eq!(rgba, [255, 0, 0, 255, 255, 255, 255, 128, 0, 0, 0, 0]);
        // ABGR8888: R, G, B, A in memory.
        let abgr = [255, 0, 0, 255];
        assert_eq!(
            premul_to_rgba(&abgr, SpriteOrder::Rgba, 1, 1, 4),
            [255, 0, 0, 255]
        );
    }

    #[test]
    fn png_is_well_formed_and_round_trips() {
        let (w, h) = (5u32, 3u32);
        let rgba: Vec<u8> = (0..w * h * 4).map(|i| (i * 7) as u8).collect();
        let png = encode_png(&rgba, w, h);
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        // Walk the chunks, check each CRC, and inflate IDAT.
        let mut at = 8;
        let mut kinds = Vec::new();
        let mut idat = Vec::new();
        while at < png.len() {
            let len = u32::from_be_bytes(png[at..at + 4].try_into().unwrap()) as usize;
            let kind = &png[at + 4..at + 8];
            let data = &png[at + 8..at + 8 + len];
            let crc = u32::from_be_bytes(png[at + 8 + len..at + 12 + len].try_into().unwrap());
            assert_eq!(crc, crc32(&[kind, data]));
            if kind == b"IDAT" {
                idat.extend_from_slice(data);
            }
            kinds.push(String::from_utf8(kind.to_vec()).unwrap());
            at += 12 + len;
        }
        assert_eq!(kinds, ["IHDR", "IDAT", "IEND"]);
        let raw = miniz_oxide::inflate::decompress_to_vec_zlib(&idat).unwrap();
        let rows: Vec<u8> = raw
            .chunks_exact(w as usize * 4 + 1)
            .flat_map(|r| {
                assert_eq!(r[0], 0);
                r[1..].to_vec()
            })
            .collect();
        assert_eq!(rows, rgba);
        // The well-known CRC of "IEND".
        assert_eq!(crc32(&[b"IEND"]), 0xae42_6082);
    }

    /// Hyprland reports logical units: an output of 1280x800 pixels at
    /// scale 2 is 640x400 to the cursor session (the nested-run bug: 0.1
    /// came back as 0.05), at 1.5 853.3x533.3.
    #[test]
    fn positions_normalize_in_the_sessions_units() {
        let t = Instant::now();
        for (scale, at, expect) in [
            (1.0, (128, 80), (0.1, 0.1)),
            (2.0, (64, 40), (0.1, 0.1)),
            (2.0, (192, 160), (0.3, 0.4)),
            (1.5, (512, 373), (0.6, 0.7)),
        ] {
            let space = CursorSpace {
                width: 1280.0 / scale,
                height: 800.0 / scale,
                sprite_scale: scale,
                theme_size: None,
            };
            let mut p = Positions::new(space);
            p.enter();
            p.position(at.0, at.1);
            let Some(CursorEvent::Moved { x, y }) = p.poll(t).0 else {
                panic!("no move")
            };
            assert!(
                (x - expect.0).abs() < 0.002 && (y - expect.1).abs() < 0.002,
                "{scale}: {x},{y}"
            );
        }
    }

    #[test]
    fn sprite_geometry_accounts_for_the_cursor_scale() {
        // Hyprland, highest monitor scale 2: a 24-unit cursor is a 48 px
        // sprite with a logical hotspot (4, 2) on a 640x400 logical output.
        let space = CursorSpace {
            width: 640.0,
            height: 400.0,
            sprite_scale: 2.0,
            theme_size: Some(24.0),
        };
        let (nw, nh, ax, ay) = space.sprite_geometry(48, 48, (4, 2));
        assert_eq!((nw, nh), (24.0 / 640.0, 24.0 / 400.0));
        assert_eq!((ax, ay), (4.0 / 24.0, 2.0 / 24.0));
        // The nested run: a 24 px sprite with a 24 theme is scale 1 even
        // though the highest monitor scale is 2.
        let (nw, _, ax, _) = space.sprite_geometry(24, 24, (4, 2));
        assert_eq!((nw, ax), (24.0 / 640.0, 4.0 / 24.0));
        // Never beyond the highest monitor scale.
        assert_eq!(space.scale_of(96, 96), 2.0);
        // Without a theme size: the highest monitor scale.
        let bare = CursorSpace {
            theme_size: None,
            ..space
        };
        assert_eq!(bare.scale_of(24, 24), 2.0);
        // Per the protocol: everything in pixels.
        let (nw, _, ax, _) = CursorSpace::pixels(1920, 1080).sprite_geometry(32, 32, (8, 8));
        assert_eq!((nw, ax), (32.0 / 1920.0, 0.25));
    }

    /// Hyprland 0.56.2 sends shm_format, dmabuf_*, buffer_size, done; the
    /// first version cleared the formats on buffer_size.
    #[test]
    fn constraints_commit_on_done_in_any_order() {
        let mut c = Constraints::default();
        c.shm_format(WEnum::Value(wl_shm::Format::Argb8888));
        c.size(48, 48);
        assert!(!c.known);
        c.done();
        assert_eq!(c.size, (48, 48));
        assert_eq!(
            c.sprite_format(),
            Some((wl_shm::Format::Argb8888, SpriteOrder::Bgra))
        );
        // A new batch replaces the old one.
        c.size(64, 64);
        c.shm_format(WEnum::Unknown(0x3432_5241));
        c.shm_format(WEnum::Value(wl_shm::Format::Abgr8888));
        c.done();
        assert_eq!(c.size, (64, 64));
        assert_eq!(
            c.sprite_format(),
            Some((wl_shm::Format::Abgr8888, SpriteOrder::Rgba))
        );
        c.shm_format(WEnum::Value(wl_shm::Format::Xrgb8888));
        c.done();
        assert_eq!(c.sprite_format(), None, "no alpha, no sprite");
    }

    #[test]
    fn hyprlands_placeholder_and_clear_sprites_are_recognised() {
        let black = [0, 0, 0, 255].repeat(4);
        let clear = [0u8; 16];
        let mut arrow = black.clone();
        arrow[4..8].copy_from_slice(&[255, 255, 255, 255]);
        arrow[8..12].copy_from_slice(&[0, 0, 0, 0]);
        for order in [SpriteOrder::Bgra, SpriteOrder::Rgba] {
            assert_eq!(sprite_kind(&black, order, 2, 2, 8), SpriteKind::Placeholder);
            assert_eq!(sprite_kind(&clear, order, 2, 2, 8), SpriteKind::Clear);
            assert_eq!(sprite_kind(&arrow, order, 2, 2, 8), SpriteKind::Cursor);
        }
    }

    #[test]
    fn big_noisy_sprites_shrink_under_the_limit() {
        let (w, h) = (256u32, 256u32);
        let mut x = 0x1234_5678u32;
        let rgba: Vec<u8> = (0..w * h * 4)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                x as u8
            })
            .collect();
        assert!(encode_png(&rgba, w, h).len() > MAX_PNG_BYTES);
        assert!(sprite_png(rgba, w, h).len() <= MAX_PNG_BYTES);
    }

    #[test]
    fn halving_weights_by_alpha() {
        // One opaque white pixel next to three transparent black ones.
        let rgba = [255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let (out, w, h) = halve_rgba(&rgba, 2, 2);
        assert_eq!((w, h), (1, 1));
        assert_eq!(out, [255, 255, 255, 64]);
    }

    #[test]
    fn positions_normalize_coalesce_and_hide() {
        let t = Instant::now();
        let mut p = Positions::new(CursorSpace::pixels(2000, 1000));
        // Starts hidden, says so once.
        assert_eq!(p.poll(t).0, Some(CursorEvent::Hidden));
        assert_eq!(p.poll(t).0, None);
        p.enter();
        p.position(500, 250);
        assert_eq!(p.poll(t).0, Some(CursorEvent::Moved { x: 0.25, y: 0.25 }));
        // Within the rate cap: held, with a retry time; the newest wins.
        p.position(600, 250);
        p.position(1000, 500);
        let (ev, again) = p.poll(t + Duration::from_millis(2));
        assert_eq!(ev, None);
        assert!(again.unwrap() <= MIN_MOVE_INTERVAL);
        assert_eq!(
            p.poll(t + Duration::from_millis(10)).0,
            Some(CursorEvent::Moved { x: 0.5, y: 0.5 })
        );
        // No movement, nothing sent.
        assert_eq!(p.poll(t + Duration::from_millis(30)).0, None);
        p.leave();
        assert_eq!(
            p.poll(t + Duration::from_millis(40)).0,
            Some(CursorEvent::Hidden)
        );
        // Re-entering at the same spot sends it again.
        p.enter();
        p.position(1000, 500);
        assert_eq!(
            p.poll(t + Duration::from_millis(50)).0,
            Some(CursorEvent::Moved { x: 0.5, y: 0.5 })
        );
    }
}
