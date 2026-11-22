//! The virtual display as a RandR output: a mode named after the receiver
//! (`od-xxxxxx`) on a disconnected connector, driven by a spare CRTC. The
//! window manager and panels see an ordinary monitor. The mode name is the
//! marker `clean` and a restarted sender look for.

use anyhow::{Context, Result, bail};
use tracing::debug;
use x11rb::connection::Connection;
use x11rb::protocol::randr::{
    self, ConnectionExt as _, GetScreenResourcesCurrentReply, ModeFlag, ModeInfo, Rotation,
    SetConfig,
};
use x11rb::protocol::xproto::{ConnectionExt as _, Window};
use x11rb::rust_connection::RustConnection;

use crate::backend::{LayoutRect, Position, place};

/// Mode names this sender creates start with this (the lock names do too).
pub const PREFIX: &str = "od-";

/// CVT timings for `width`x`height` at `hz` (VESA CVT 1.1, normal blanking),
/// as `cvt` and `xrandr --newmode` use them. The width is rounded up to a
/// multiple of 8, as `cvt` does.
pub fn cvt(width: u32, height: u32, hz: f64) -> ModeInfo {
    const GRAN: i64 = 8;
    const MIN_V_PORCH: i64 = 3;
    const MIN_VSYNC_BP: f64 = 550.0;
    const HSYNC_PCT: i64 = 8;
    const CLOCK_STEP: i64 = 250;
    const C_PRIME: f64 = 30.0;
    const M_PRIME: f64 = 300.0;

    let hdisplay = (width as i64 + GRAN - 1) / GRAN * GRAN;
    let vdisplay = height as i64;
    let hz = if hz.is_finite() && hz >= 1.0 {
        hz
    } else {
        60.0
    };
    let vsync = if vdisplay % 3 == 0 && vdisplay * 4 / 3 == hdisplay {
        4
    } else if vdisplay % 9 == 0 && vdisplay * 16 / 9 == hdisplay {
        5
    } else if vdisplay % 10 == 0 && vdisplay * 16 / 10 == hdisplay {
        6
    } else if (vdisplay % 4 == 0 && vdisplay * 5 / 4 == hdisplay)
        || (vdisplay % 9 == 0 && vdisplay * 15 / 9 == hdisplay)
    {
        7
    } else {
        10
    };
    let hperiod = (1_000_000.0 / hz - MIN_VSYNC_BP) / (vdisplay + MIN_V_PORCH) as f64;
    let vsync_bp = ((MIN_VSYNC_BP / hperiod) as i64 + 1).max(vsync + MIN_V_PORCH);
    let vtotal = vdisplay + vsync_bp + MIN_V_PORCH;
    let blank_pct = (C_PRIME - M_PRIME * hperiod / 1000.0).max(20.0);
    let mut hblank = (hdisplay as f64 * blank_pct / (100.0 - blank_pct)) as i64;
    hblank -= hblank % (2 * GRAN);
    let htotal = hdisplay + hblank;
    let hsync_end = hdisplay + hblank / 2;
    let mut hsync_start = hsync_end - htotal * HSYNC_PCT / 100;
    hsync_start += GRAN - hsync_start % GRAN;
    let vsync_start = vdisplay + MIN_V_PORCH;
    let mut clock = (htotal as f64 * 1000.0 / hperiod) as i64;
    clock -= clock % CLOCK_STEP;
    ModeInfo {
        id: 0,
        width: hdisplay as u16,
        height: vdisplay as u16,
        dot_clock: (clock * 1000) as u32,
        hsync_start: hsync_start as u16,
        hsync_end: hsync_end as u16,
        htotal: htotal as u16,
        hskew: 0,
        vsync_start: vsync_start as u16,
        vsync_end: (vsync_start + vsync) as u16,
        vtotal: vtotal as u16,
        name_len: 0,
        mode_flags: ModeFlag::HSYNC_NEGATIVE | ModeFlag::VSYNC_POSITIVE,
    }
}

pub fn refresh_of(m: &ModeInfo) -> f64 {
    let dots = m.htotal as f64 * m.vtotal as f64;
    if dots > 0.0 {
        m.dot_clock as f64 / dots
    } else {
        0.0
    }
}

/// Where a virtual display ended up.
#[derive(Debug, Clone, PartialEq)]
pub struct Placed {
    pub output: randr::Output,
    pub output_name: String,
    pub crtc: randr::Crtc,
    pub mode: randr::Mode,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub refresh_hz: f64,
}

/// One connection to the X server for configuration requests.
pub struct Randr {
    pub conn: RustConnection,
    pub root: Window,
    /// Screen size in mm per pixel at connect time, kept when resizing so
    /// the DPI the desktop reports does not change.
    mm_per_px: (f64, f64),
}

/// The resources and the names of their modes.
struct Snapshot {
    res: GetScreenResourcesCurrentReply,
}

impl Snapshot {
    fn mode_names(&self) -> impl Iterator<Item = (&ModeInfo, &str)> {
        let mut off = 0usize;
        self.res.modes.iter().map(move |m| {
            let n = &self.res.names[off..off + m.name_len as usize];
            off += m.name_len as usize;
            (m, std::str::from_utf8(n).unwrap_or(""))
        })
    }

    fn mode_named(&self, name: &str) -> Option<&ModeInfo> {
        self.mode_names().find(|(_, n)| *n == name).map(|(m, _)| m)
    }

    fn mode_name(&self, id: randr::Mode) -> Option<&str> {
        self.mode_names().find(|(m, _)| m.id == id).map(|(_, n)| n)
    }
}

impl Randr {
    pub fn connect(display: Option<&str>) -> Result<Self> {
        let (conn, screen) = x11rb::connect(display).context("connecting to the X server")?;
        let s = &conn.setup().roots[screen];
        let root = s.root;
        let mm_per_px = (
            per_px(s.width_in_millimeters, s.width_in_pixels),
            per_px(s.height_in_millimeters, s.height_in_pixels),
        );
        let v = conn
            .randr_query_version(1, 3)?
            .reply()
            .context("the X server has no RandR extension")?;
        if (v.major_version, v.minor_version) < (1, 3) {
            bail!(
                "RandR {}.{} is too old; od-sender needs 1.3",
                v.major_version,
                v.minor_version
            );
        }
        Ok(Self {
            conn,
            root,
            mm_per_px,
        })
    }

    fn snapshot(&self) -> Result<Snapshot> {
        let res = self
            .conn
            .randr_get_screen_resources_current(self.root)?
            .reply()?;
        Ok(Snapshot { res })
    }

    fn output_name(&self, o: &randr::GetOutputInfoReply) -> String {
        String::from_utf8_lossy(&o.name).into_owned()
    }

    /// Every active CRTC's rectangle, except `skip`.
    fn layout(&self, snap: &Snapshot, skip: Option<randr::Crtc>) -> Result<Vec<LayoutRect>> {
        let mut out = Vec::new();
        for &c in &snap.res.crtcs {
            if Some(c) == skip {
                continue;
            }
            let i = self
                .conn
                .randr_get_crtc_info(c, snap.res.config_timestamp)?
                .reply()?;
            if i.mode != 0 && i.width > 0 {
                out.push(LayoutRect {
                    x: i.x as i32,
                    y: i.y as i32,
                    width: i.width as i32,
                    height: i.height as i32,
                });
            }
        }
        Ok(out)
    }

    /// Connectors a virtual display could go on: disconnected, off, and
    /// with a CRTC nobody uses. Names only, for `doctor`.
    pub fn free_outputs(&self) -> Result<Vec<String>> {
        let snap = self.snapshot()?;
        Ok(self
            .free(&snap)?
            .into_iter()
            .map(|(_, name, _)| name)
            .collect())
    }

    fn free(&self, snap: &Snapshot) -> Result<Vec<(randr::Output, String, randr::Crtc)>> {
        let ts = snap.res.config_timestamp;
        let mut idle = Vec::new();
        for &c in &snap.res.crtcs {
            let i = self.conn.randr_get_crtc_info(c, ts)?.reply()?;
            if i.mode == 0 && i.outputs.is_empty() {
                idle.push(c);
            }
        }
        let mut out = Vec::new();
        for &o in &snap.res.outputs {
            let info = self.conn.randr_get_output_info(o, ts)?.reply()?;
            if info.connection != randr::Connection::DISCONNECTED || info.crtc != 0 {
                continue;
            }
            if let Some(&c) = info.crtcs.iter().find(|c| idle.contains(c)) {
                out.push((o, self.output_name(&info), c));
            }
        }
        Ok(out)
    }

    /// The display a sender for `name` left on, if it is still on.
    fn existing(&self, snap: &Snapshot, name: &str) -> Result<Option<Placed>> {
        let Some(mode) = snap.mode_named(name).map(|m| m.id) else {
            return Ok(None);
        };
        let ts = snap.res.config_timestamp;
        for &o in &snap.res.outputs {
            let info = self.conn.randr_get_output_info(o, ts)?.reply()?;
            if info.crtc == 0 {
                continue;
            }
            let c = self.conn.randr_get_crtc_info(info.crtc, ts)?.reply()?;
            if c.mode == mode {
                let m = snap.mode_named(name).expect("found above");
                return Ok(Some(Placed {
                    output: o,
                    output_name: self.output_name(&info),
                    crtc: info.crtc,
                    mode,
                    x: c.x as i32,
                    y: c.y as i32,
                    width: c.width as u32,
                    height: c.height as u32,
                    refresh_hz: refresh_of(m),
                }));
            }
        }
        Ok(None)
    }

    /// An enabled output by connector name (`--output`), as it is.
    pub fn find_output(&self, name: &str) -> Result<Placed> {
        let snap = self.snapshot()?;
        let ts = snap.res.config_timestamp;
        let mut names = Vec::new();
        for &o in &snap.res.outputs {
            let info = self.conn.randr_get_output_info(o, ts)?.reply()?;
            let n = self.output_name(&info);
            if n != name {
                if info.crtc != 0 {
                    names.push(n);
                }
                continue;
            }
            if info.crtc == 0 {
                bail!("output {name} is off; turn it on first (xrandr --output {name} --auto)");
            }
            let c = self.conn.randr_get_crtc_info(info.crtc, ts)?.reply()?;
            let refresh = snap
                .res
                .modes
                .iter()
                .find(|m| m.id == c.mode)
                .map_or(60.0, refresh_of);
            return Ok(Placed {
                output: o,
                output_name: n,
                crtc: info.crtc,
                mode: c.mode,
                x: c.x as i32,
                y: c.y as i32,
                width: c.width as u32,
                height: c.height as u32,
                refresh_hz: refresh,
            });
        }
        bail!("no output {name}; enabled outputs: {}", names.join(", "))
    }

    /// Turn on a `width`x`height` display for `name`: reuse one a crashed
    /// sender left on, else take the first free connector.
    pub fn create(
        &self,
        name: &str,
        width: u32,
        height: u32,
        hz: f64,
        position: Position,
    ) -> Result<Placed> {
        let snap = self.snapshot()?;
        if let Some(p) = self.existing(&snap, name)? {
            debug!("{name} is already on {}; using it", p.output_name);
            return self.resize(&p, name, width, height, hz);
        }
        // A leftover mode that is not on any output (turned off from under
        // a running sender, or by hand).
        if let Some(m) = snap.mode_named(name) {
            self.destroy_mode(m.id).ok();
        }
        let free = self.free(&snap)?;
        let Some((output, output_name, crtc)) = free.into_iter().next() else {
            bail!(
                "no free connector for a virtual display: it needs a disconnected output (HDMI, DP, VIRTUAL) and a CRTC no monitor uses. `xrandr` lists them; see the X11 section of the README"
            );
        };
        let others = self.layout(&snap, None)?;
        self.enable(
            name,
            output,
            &output_name,
            crtc,
            width,
            height,
            hz,
            |w, h| place(position, w, h, &others),
        )
    }

    /// Give `p` a new size in place (rotation): off, new mode, on again at
    /// the same top-left.
    fn resize(&self, p: &Placed, name: &str, width: u32, height: u32, hz: f64) -> Result<Placed> {
        let (x, y) = self.position(p)?;
        let want = cvt(width, height, hz);
        if (want.width as u32, want.height as u32) == (p.width, p.height) {
            return Ok(Placed { x, y, ..p.clone() });
        }
        self.disable(p)?;
        self.enable(
            name,
            p.output,
            &p.output_name,
            p.crtc,
            width,
            height,
            hz,
            |_, _| (x, y),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn enable(
        &self,
        name: &str,
        output: randr::Output,
        output_name: &str,
        crtc: randr::Crtc,
        width: u32,
        height: u32,
        hz: f64,
        at: impl FnOnce(i32, i32) -> (i32, i32),
    ) -> Result<Placed> {
        let mode_info = ModeInfo {
            name_len: name.len() as u16,
            ..cvt(width, height, hz)
        };
        let (w, h) = (mode_info.width as u32, mode_info.height as u32);
        let refresh_hz = refresh_of(&mode_info);
        let mode = self
            .conn
            .randr_create_mode(self.root, mode_info, name.as_bytes())?
            .reply()
            .with_context(|| format!("creating mode {name} ({w}x{h})"))?
            .mode;
        let undo = |e: anyhow::Error| {
            let _ = self.conn.randr_delete_output_mode(output, mode);
            let _ = self.conn.randr_destroy_mode(mode);
            let _ = self.conn.flush();
            e
        };
        self.conn
            .randr_add_output_mode(output, mode)?
            .check()
            .with_context(|| format!("adding mode {name} to {output_name}"))
            .map_err(undo)?;
        let (x, y) = at(w as i32, h as i32);
        let snap = self.snapshot().map_err(undo)?;
        let mut rects = self.layout(&snap, Some(crtc)).map_err(undo)?;
        rects.push(LayoutRect {
            x,
            y,
            width: w as i32,
            height: h as i32,
        });
        if x < 0 || y < 0 {
            return Err(undo(anyhow::anyhow!(
                "{w}x{h} at {x},{y}: X11 screens start at 0,0; use --position auto-right or auto-down"
            )));
        }
        self.fit_screen(&rects, true).map_err(undo)?;
        let r = self
            .conn
            .randr_set_crtc_config(
                crtc,
                x11rb::CURRENT_TIME,
                snap.res.config_timestamp,
                x as i16,
                y as i16,
                mode,
                Rotation::ROTATE0,
                &[output],
            )?
            .reply()
            .with_context(|| format!("turning on {output_name}"));
        match r {
            Ok(r) if r.status == SetConfig::SUCCESS => {}
            Ok(r) => {
                let _ = self.fit_screen(&rects[..rects.len() - 1], false);
                return Err(undo(anyhow::anyhow!(
                    "turning on {output_name} with {w}x{h}: {:?}",
                    r.status
                )));
            }
            Err(e) => return Err(undo(e)),
        }
        debug!("{name}: {output_name} on CRTC {crtc} at {x},{y}");
        Ok(Placed {
            output,
            output_name: output_name.to_string(),
            crtc,
            mode,
            x,
            y,
            width: w,
            height: h,
            refresh_hz,
        })
    }

    /// Turn the display off and drop its mode; shrink the screen to what is
    /// left.
    pub fn disable(&self, p: &Placed) -> Result<()> {
        let snap = self.snapshot()?;
        let r = self
            .conn
            .randr_set_crtc_config(
                p.crtc,
                x11rb::CURRENT_TIME,
                snap.res.config_timestamp,
                0,
                0,
                0,
                Rotation::ROTATE0,
                &[],
            )?
            .reply()
            .with_context(|| format!("turning off {}", p.output_name))?;
        if r.status != SetConfig::SUCCESS {
            bail!("turning off {}: {:?}", p.output_name, r.status);
        }
        self.conn
            .randr_delete_output_mode(p.output, p.mode)?
            .check()
            .ok();
        self.conn.randr_destroy_mode(p.mode)?.check().ok();
        let snap = self.snapshot()?;
        let rest = self.layout(&snap, None)?;
        self.fit_screen(&rest, false)?;
        Ok(())
    }

    /// Size the screen to the bounding box of `rects` (only growing when
    /// `grow_only`).
    fn fit_screen(&self, rects: &[LayoutRect], grow_only: bool) -> Result<()> {
        let w = rects
            .iter()
            .map(|r| r.x + r.width)
            .max()
            .unwrap_or(0)
            .max(1);
        let h = rects
            .iter()
            .map(|r| r.y + r.height)
            .max()
            .unwrap_or(0)
            .max(1);
        let geom = self.conn.get_geometry(self.root)?.reply()?;
        let (cw, ch) = (geom.width as i32, geom.height as i32);
        let (w, h) = if grow_only {
            (w.max(cw), h.max(ch))
        } else {
            (w, h)
        };
        if (w, h) == (cw, ch) {
            return Ok(());
        }
        let range = self.conn.randr_get_screen_size_range(self.root)?.reply()?;
        if w > range.max_width as i32 || h > range.max_height as i32 {
            bail!(
                "the X screen would be {w}x{h}, more than its maximum {}x{}",
                range.max_width,
                range.max_height
            );
        }
        let mm = |px: i32, per: f64| ((px as f64 * per).round() as u32).max(1);
        self.conn
            .randr_set_screen_size(
                self.root,
                w as u16,
                h as u16,
                mm(w, self.mm_per_px.0),
                mm(h, self.mm_per_px.1),
            )?
            .check()
            .with_context(|| format!("resizing the X screen to {w}x{h}"))?;
        Ok(())
    }

    /// Whether `p` is still on as created; `Some(why)` when not.
    pub fn drifted(&self, p: &Placed) -> Result<Option<String>> {
        let snap = self.snapshot()?;
        let ts = snap.res.config_timestamp;
        let info = self.conn.randr_get_output_info(p.output, ts)?.reply()?;
        if info.crtc == 0 {
            return Ok(Some(format!("{} was turned off", p.output_name)));
        }
        let c = self.conn.randr_get_crtc_info(info.crtc, ts)?.reply()?;
        if c.mode != p.mode {
            let now = snap.mode_name(c.mode).unwrap_or("another mode");
            return Ok(Some(format!("{} switched to {now}", p.output_name)));
        }
        if (c.x as i32, c.y as i32) != (p.x, p.y) {
            return Ok(Some(format!("{} moved to {},{}", p.output_name, c.x, c.y)));
        }
        Ok(None)
    }

    /// Where `p` is now (it may have been moved in the display settings).
    pub fn position(&self, p: &Placed) -> Result<(i32, i32)> {
        let c = self.conn.randr_get_crtc_info(p.crtc, 0)?.reply()?;
        Ok((c.x as i32, c.y as i32))
    }

    /// Every `od-*` mode, with the display it is on if any.
    pub fn ours(&self) -> Result<Vec<(String, Option<Placed>, randr::Mode)>> {
        let snap = self.snapshot()?;
        let mut out = Vec::new();
        for (m, n) in snap.mode_names() {
            if !n.starts_with(PREFIX) {
                continue;
            }
            let placed = self.existing(&snap, n)?;
            out.push((n.to_string(), placed, m.id));
        }
        Ok(out)
    }

    /// Drop a mode that is on no output.
    pub fn destroy_mode(&self, mode: randr::Mode) -> Result<()> {
        let snap = self.snapshot()?;
        let ts = snap.res.config_timestamp;
        for &o in &snap.res.outputs {
            let info = self.conn.randr_get_output_info(o, ts)?.reply()?;
            if info.modes.contains(&mode) {
                self.conn.randr_delete_output_mode(o, mode)?.check().ok();
            }
        }
        self.conn.randr_destroy_mode(mode)?.check()?;
        Ok(())
    }
}

fn per_px(mm: u16, px: u16) -> f64 {
    if mm == 0 || px == 0 {
        25.4 / 96.0
    } else {
        mm as f64 / px as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (clock MHz, h timings, v timings) as `cvt` prints them.
    fn line(m: &ModeInfo) -> (f64, [u16; 4], [u16; 4]) {
        (
            m.dot_clock as f64 / 1e6,
            [m.width, m.hsync_start, m.hsync_end, m.htotal],
            [m.height, m.vsync_start, m.vsync_end, m.vtotal],
        )
    }

    #[test]
    fn cvt_matches_the_cvt_tool() {
        // `cvt 390 844 60` and friends (libxcvt 0.1.2).
        assert_eq!(
            line(&cvt(390, 844, 60.0)),
            (26.25, [392, 416, 448, 504], [844, 847, 857, 876])
        );
        assert_eq!(
            line(&cvt(1170, 2532, 60.0)),
            (255.25, [1176, 1272, 1400, 1624], [2532, 2535, 2545, 2622])
        );
        assert_eq!(
            line(&cvt(844, 390, 60.0)),
            (25.75, [848, 872, 952, 1056], [390, 393, 403, 407])
        );
        assert_eq!(
            line(&cvt(584, 1266, 120.0)),
            (131.5, [584, 640, 696, 808], [1266, 1269, 1279, 1359])
        );
        // 16:9 gets a 5-line vsync.
        assert_eq!(
            line(&cvt(1920, 1080, 60.0)),
            (173.0, [1920, 2048, 2248, 2576], [1080, 1083, 1088, 1120])
        );
        let m = cvt(390, 844, 60.0);
        assert!((refresh_of(&m) - 59.46).abs() < 0.01, "{}", refresh_of(&m));
    }
}
