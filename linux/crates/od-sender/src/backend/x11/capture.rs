//! Frames of one rectangle of the root window: MIT-SHM `GetImage`, only
//! when XDamage reports a change inside it (plus a slow refresh in case
//! something draws without damage). An X server never includes the pointer
//! in `GetImage`, so a painted cursor is blended in here.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tracing::{debug, warn};
use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::damage::{self, ConnectionExt as _};
use x11rb::protocol::shm::ConnectionExt as _;
use x11rb::protocol::xfixes::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{ConnectionExt as _, ImageFormat, Rectangle, Window};
use x11rb::rust_connection::RustConnection;

use crate::backend::{CaptureEvent, Frame, FrameBuf, FrameSink, PixelFormat};
use crate::bounded::{BoundedThread, DROP_JOIN};

/// A capture with nothing new still sends a frame this often.
const REFRESH: Duration = Duration::from_secs(1);

/// The captured rectangle, root window coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

impl Rect {
    fn overlaps(&self, a: &Rectangle) -> bool {
        let (ax, ay) = (a.x as i32, a.y as i32);
        ax < self.x + self.w as i32
            && ax + a.width as i32 > self.x
            && ay < self.y + self.h as i32
            && ay + a.height as i32 > self.y
    }

    fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w as i32 && y < self.y + self.h as i32
    }
}

/// A MIT-SHM segment the X server writes captured frames into.
struct ShmBuf {
    seg: u32,
    ptr: *mut libc::c_void,
    len: usize,
}

// The mapping is only touched from the capture thread.
unsafe impl Send for ShmBuf {}

impl ShmBuf {
    fn new(conn: &RustConnection, len: usize) -> Result<Self> {
        use std::os::fd::AsRawFd;
        conn.shm_query_version()?
            .reply()
            .context("the X server has no MIT-SHM extension")?;
        let seg = conn.generate_id()?;
        let reply = conn
            .shm_create_segment(seg, len as u32, false)?
            .reply()
            .context("creating a MIT-SHM segment")?;
        // SAFETY: mapping the fresh segment the server just handed over, for
        // exactly the size it was created with.
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ,
                libc::MAP_SHARED,
                reply.shm_fd.as_raw_fd(),
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            bail!("mapping the MIT-SHM segment failed");
        }
        Ok(ShmBuf { seg, ptr, len })
    }

    fn bytes(&self) -> &[u8] {
        // SAFETY: mapped for `len` bytes until drop; the server is done
        // writing once the GetImage reply has arrived.
        unsafe { std::slice::from_raw_parts(self.ptr as *const u8, self.len) }
    }
}

impl Drop for ShmBuf {
    fn drop(&mut self) {
        // SAFETY: unmapping what `new` mapped.
        unsafe { libc::munmap(self.ptr, self.len) };
    }
}

/// The root window must be 24-bit TrueColor stored as 32 bits, little
/// endian red in bits 16..24: BGRX in memory, which the encoders take.
fn check_format(conn: &RustConnection, screen: usize) -> Result<()> {
    let setup = conn.setup();
    let s = &setup.roots[screen];
    let bpp = setup
        .pixmap_formats
        .iter()
        .find(|f| f.depth == s.root_depth)
        .map(|f| f.bits_per_pixel);
    let visual = s
        .allowed_depths
        .iter()
        .flat_map(|d| &d.visuals)
        .find(|v| v.visual_id == s.root_visual);
    let lsb = setup.image_byte_order == x11rb::protocol::xproto::ImageOrder::LSB_FIRST;
    match (bpp, visual) {
        (Some(32), Some(v)) if lsb && v.red_mask == 0xff0000 && v.blue_mask == 0xff => Ok(()),
        _ => bail!(
            "the X screen is depth {} ({:?} bpp); od-sender captures 24-bit BGRX only",
            s.root_depth,
            bpp
        ),
    }
}

/// The pointer sprite, premultiplied ARGB as XFixes hands it out.
struct Sprite {
    w: u32,
    h: u32,
    xhot: i32,
    yhot: i32,
    argb: Vec<u32>,
}

impl Sprite {
    fn fetch(conn: &RustConnection) -> Option<Self> {
        let c = conn.xfixes_get_cursor_image().ok()?.reply().ok()?;
        (c.width > 0 && c.height > 0).then_some(Sprite {
            w: c.width as u32,
            h: c.height as u32,
            xhot: c.xhot as i32,
            yhot: c.yhot as i32,
            argb: c.cursor_image,
        })
    }
}

/// Blend a premultiplied ARGB sprite with its hotspot at `hx`,`hy` into a
/// BGRX frame of `w`x`h`.
fn blend(frame: &mut [u8], w: u32, h: u32, s: &Sprite, hx: i32, hy: i32) {
    let (ox, oy) = (hx - s.xhot, hy - s.yhot);
    for sy in 0..s.h as i32 {
        let fy = oy + sy;
        if fy < 0 || fy >= h as i32 {
            continue;
        }
        for sx in 0..s.w as i32 {
            let fx = ox + sx;
            if fx < 0 || fx >= w as i32 {
                continue;
            }
            let p = s.argb[(sy as u32 * s.w + sx as u32) as usize];
            let a = p >> 24;
            if a == 0 {
                continue;
            }
            let i = ((fy as u32 * w + fx as u32) * 4) as usize;
            let px = &mut frame[i..i + 3];
            for (c, shift) in [(0usize, 0u32), (1, 8), (2, 16)] {
                let src = (p >> shift) & 0xff;
                let dst = px[c] as u32;
                px[c] = (src + (dst * (255 - a) + 127) / 255).min(255) as u8;
            }
        }
    }
}

pub struct Capture {
    stop: Arc<AtomicBool>,
    paint: Arc<AtomicBool>,
    thread: Option<BoundedThread>,
}

impl Capture {
    /// Connect, check the screen format and start the capture thread.
    pub fn spawn(
        display: Option<&str>,
        rect: Rect,
        hz: f64,
        paint_cursor: bool,
        mut sink: FrameSink,
    ) -> Result<Self> {
        let (conn, screen) = x11rb::connect(display).context("connecting to the X server")?;
        check_format(&conn, screen)?;
        let root = conn.setup().roots[screen].root;
        conn.xfixes_query_version(4, 0)?
            .reply()
            .context("the X server has no XFixes extension")?;
        conn.damage_query_version(1, 1)?
            .reply()
            .context("the X server has no DAMAGE extension")?;
        let shm = ShmBuf::new(&conn, (rect.w * rect.h * 4) as usize)?;
        let dmg = conn.generate_id()?;
        conn.damage_create(dmg, root, damage::ReportLevel::BOUNDING_BOX)?
            .check()
            .context("watching the screen for changes")?;
        conn.xfixes_select_cursor_input(root, xfixes::CursorNotifyMask::DISPLAY_CURSOR)?
            .check()?;

        let stop = Arc::new(AtomicBool::new(false));
        let paint = Arc::new(AtomicBool::new(paint_cursor));
        let (stop_t, paint_t) = (stop.clone(), paint.clone());
        let period = Duration::from_secs_f64(1.0 / hz.clamp(1.0, 240.0));
        let thread = BoundedThread::spawn("x11-capture", move || {
            let why = run(
                &conn, root, dmg, &shm, rect, period, &stop_t, &paint_t, &mut sink,
            );
            let _ = conn.damage_destroy(dmg);
            let _ = conn.shm_detach(shm.seg);
            let _ = conn.flush();
            if let Some(why) = why {
                warn!("x11 capture ended: {why}");
                sink(CaptureEvent::Ended(why));
            }
        })?;
        Ok(Self {
            stop,
            paint,
            thread: Some(thread),
        })
    }

    pub fn set_cursor_painted(&self, painted: bool) {
        self.paint.store(painted, Ordering::Relaxed);
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(mut t) = self.thread.take() {
            t.join_within(DROP_JOIN);
        }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The capture loop; `Some(why)` when it ended on its own.
#[allow(clippy::too_many_arguments)]
fn run(
    conn: &RustConnection,
    root: Window,
    dmg: damage::Damage,
    shm: &ShmBuf,
    r: Rect,
    period: Duration,
    stop: &AtomicBool,
    paint: &AtomicBool,
    sink: &mut FrameSink,
) -> Option<String> {
    let mut next = Instant::now();
    let mut last_frame: Option<Instant> = None;
    let mut sprite: Option<Sprite> = None;
    let mut sprite_stale = true;
    let mut last_pointer: Option<(i32, i32)> = None;
    let (mut frames, mut damaged) = (0u64, 0u64);
    while !stop.load(Ordering::Relaxed) {
        let mut dirty = false;
        loop {
            match conn.poll_for_event() {
                Ok(Some(Event::DamageNotify(n))) => dirty |= r.overlaps(&n.area),
                Ok(Some(Event::XfixesCursorNotify(_))) => sprite_stale = true,
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(e) => return Some(format!("X connection: {e}")),
            }
        }
        if dirty {
            damaged += 1;
        }
        // Start every tick from an empty region, so the next change in the
        // rectangle raises a fresh notify.
        if let Err(e) = conn.damage_subtract(dmg, x11rb::NONE, x11rb::NONE) {
            return Some(format!("X connection: {e}"));
        }

        let painting = paint.load(Ordering::Relaxed);
        let mut pointer = None;
        if painting {
            if let Ok(Ok(p)) = conn.query_pointer(root).map(|c| c.reply()) {
                let at = (p.root_x as i32, p.root_y as i32);
                // A move in or out of the rectangle changes the picture.
                let shown = |q: Option<(i32, i32)>| q.filter(|&(x, y)| r.contains(x, y));
                if shown(Some(at)) != shown(last_pointer) {
                    dirty = true;
                }
                last_pointer = Some(at);
                pointer = shown(Some(at));
            }
            if sprite_stale && pointer.is_some() {
                sprite = Sprite::fetch(conn);
                sprite_stale = false;
                dirty = true;
            }
        }

        let stale = last_frame.is_none_or(|t| t.elapsed() >= REFRESH);
        if dirty || stale {
            let captured_at = Instant::now();
            let reply = conn
                .shm_get_image(
                    root,
                    r.x as i16,
                    r.y as i16,
                    r.w as u16,
                    r.h as u16,
                    !0,
                    ImageFormat::Z_PIXMAP.into(),
                    shm.seg,
                    0,
                )
                .map_err(|e| e.to_string())
                .and_then(|c| c.reply().map_err(|e| e.to_string()));
            if let Err(e) = reply {
                // The rectangle left the screen (the output went away under
                // us): the display is gone until it is rebuilt.
                return Some(format!("capturing {}x{} at {},{}: {e}", r.w, r.h, r.x, r.y));
            }
            let mut px = shm.bytes().to_vec();
            if let (Some((x, y)), Some(s)) = (pointer, &sprite) {
                blend(&mut px, r.w, r.h, s, x - r.x, y - r.y);
            }
            sink(CaptureEvent::Frame(Frame {
                captured_at,
                presentation_ns: None,
                buf: FrameBuf::Cpu {
                    pixels: px.into(),
                    width: r.w,
                    height: r.h,
                    stride: r.w * 4,
                    format: PixelFormat::Xrgb8888,
                },
            }));
            last_frame = Some(captured_at);
            frames += 1;
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else {
            next = now;
        }
    }
    debug!("x11 capture stopped after {frames} frames ({damaged} with damage)");
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlap_and_contains() {
        let r = Rect {
            x: 100,
            y: 0,
            w: 50,
            h: 40,
        };
        let a = |x, y, width, height| Rectangle {
            x,
            y,
            width,
            height,
        };
        assert!(r.overlaps(&a(90, 10, 20, 5)));
        assert!(!r.overlaps(&a(0, 0, 100, 100)));
        assert!(!r.overlaps(&a(150, 0, 10, 10)));
        assert!(r.contains(100, 0) && r.contains(149, 39));
        assert!(!r.contains(150, 0) && !r.contains(99, 0));
    }

    #[test]
    fn blending_a_sprite_clips_and_mixes() {
        // 2x1 sprite: opaque red, half-transparent premultiplied white.
        let s = Sprite {
            w: 2,
            h: 1,
            xhot: 0,
            yhot: 0,
            argb: vec![0xffff0000, 0x80808080],
        };
        let mut f = vec![0u8; 3 * 4];
        blend(&mut f, 3, 1, &s, 1, 0);
        assert_eq!(&f[0..4], [0, 0, 0, 0]);
        assert_eq!(&f[4..7], [0, 0, 255]); // B, G, R
        assert_eq!(&f[8..11], [128, 128, 128]);
        // Off the right edge: only the first pixel lands.
        let mut f = vec![255u8; 3 * 4];
        blend(&mut f, 3, 1, &s, 2, 0);
        assert_eq!(&f[8..11], [0, 0, 255]);
        assert_eq!(&f[0..8], [255; 8]);
    }
}
