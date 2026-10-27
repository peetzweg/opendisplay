//! What differs per compositor: creating a virtual output, getting its
//! frames, and injecting input. A backend is chosen once at
//! startup by [`detect`]; the session loop only sees the traits below.

pub mod adopt;
pub mod capture;
pub mod detect;
#[cfg(feature = "gnome")]
pub mod gnome;
pub mod hyprland;
#[cfg(feature = "kde")]
pub mod kde;
pub mod lock;
pub mod wlroots;

use std::fmt;
use std::str::FromStr;
use std::time::Instant;

use anyhow::{Result, bail};
use clap::ValueEnum;
use opendisplay_proto::control::{Pencil, Scroll, Touch};

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum BackendId {
    /// Hyprland >= 0.55: headless outputs over the IPC socket.
    Hyprland,
    /// An output that already exists (`--output <name>`): capture and input
    /// only, nothing is created or removed.
    Adopt,
    /// Sway >= 1.10: headless outputs over Sway IPC, sized through
    /// zwlr_output_manager_v1.
    Wlroots,
    /// KDE Plasma (KWin): zkde_screencast virtual outputs over PipeWire,
    /// fake-input pointer.
    Kde,
    /// xdg-desktop-portal ScreenCast/RemoteDesktop, e.g. GNOME (not implemented yet).
    /// GNOME: virtual monitor and input over Mutter's D-Bus APIs.
    Gnome,
    Portal,
}

impl fmt::Display for BackendId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            BackendId::Hyprland => "hyprland",
            BackendId::Adopt => "adopt",
            BackendId::Wlroots => "wlroots",
            BackendId::Kde => "kde",
            BackendId::Gnome => "gnome",
            BackendId::Portal => "portal",
        })
    }
}

/// Where the virtual output goes relative to the existing ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Position {
    AutoRight,
    AutoLeft,
    AutoUp,
    AutoDown,
    At(i32, i32),
}

impl FromStr for Position {
    type Err = anyhow::Error;

    /// `auto-right|auto-left|auto-up|auto-down`, or `x,y` / `XxY`.
    fn from_str(s: &str) -> Result<Self> {
        Ok(match s {
            "auto-right" => Position::AutoRight,
            "auto-left" => Position::AutoLeft,
            "auto-up" => Position::AutoUp,
            "auto-down" => Position::AutoDown,
            _ => {
                let Some((x, y)) = s.split_once(',').or_else(|| s.split_once('x')) else {
                    bail!(
                        "position {s:?}: expected auto-right, auto-left, auto-up, auto-down or x,y"
                    );
                };
                At(x.trim().parse()?, y.trim().parse()?)
            }
        })
    }
}
use Position::At;

/// An output's place in the compositor's global layout, logical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LayoutRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// Top-left of a `w`x`h` (logical) output placed next to `others`.
pub fn place(position: Position, w: i32, h: i32, others: &[LayoutRect]) -> (i32, i32) {
    if others.is_empty() {
        return match position {
            Position::At(x, y) => (x, y),
            _ => (0, 0),
        };
    }
    let right = |r: &LayoutRect| r.x + r.width;
    let bottom = |r: &LayoutRect| r.y + r.height;
    match position {
        Position::At(x, y) => (x, y),
        Position::AutoRight => {
            let edge = others.iter().max_by_key(|r| right(r)).unwrap();
            (right(edge), edge.y)
        }
        Position::AutoLeft => {
            let edge = others.iter().min_by_key(|r| r.x).unwrap();
            (edge.x - w, edge.y)
        }
        Position::AutoDown => {
            let edge = others.iter().max_by_key(|r| bottom(r)).unwrap();
            (edge.x, bottom(edge))
        }
        Position::AutoUp => {
            let edge = others.iter().min_by_key(|r| r.y).unwrap();
            (edge.x, edge.y - h)
        }
    }
}

/// What the session asks for, derived from `hello`.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplaySpec {
    /// `od-<6 chars of hello.id>`; also the lock key.
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub hz: u32,
    pub scale: f64,
    pub position: Position,
}

/// The display as the compositor actually configured it.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayInfo {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub refresh_hz: f64,
    pub scale: f64,
    pub x: i32,
    pub y: i32,
}

impl fmt::Display for DisplayInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} = {}x{} @{:.0} scale {} at {},{} ({}x{} logical)",
            self.name,
            self.width,
            self.height,
            self.refresh_hz,
            self.scale,
            self.x,
            self.y,
            (self.width as f64 / self.scale).round(),
            (self.height as f64 / self.scale).round()
        )
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Caps {
    /// Cursor delivered separately (ext cursor session / portal METADATA).
    pub cursor_metadata: bool,
    /// Capture can hand out GPU buffers.
    pub dmabuf: bool,
    /// Reconfigure without destroy+create.
    pub resize_in_place: bool,
    /// False for Adopt.
    pub creates_outputs: bool,
}

impl fmt::Display for Caps {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let flag = |b: bool| if b { "yes" } else { "no" };
        write!(
            f,
            "creates outputs {}, resize in place {}, cursor metadata {}, dmabuf {}",
            flag(self.creates_outputs),
            flag(self.resize_in_place),
            flag(self.cursor_metadata),
            flag(self.dmabuf)
        )
    }
}

pub trait Backend: Send {
    fn id(&self) -> BackendId;
    /// One line for logs and `doctor`.
    fn describe(&self) -> String;
    fn caps(&self) -> Caps;
    /// Frames come through a Wayland capture protocol (`wayland/capture.rs`,
    /// `wayland/screencopy.rs`); false for PipeWire backends, which ignore
    /// the capture choice.
    fn wayland_capture(&self) -> bool {
        true
    }
    /// A reason to capture with something other than the default protocol
    /// (backend/capture.rs); `None` = no preference.
    fn capture_preference(&self) -> capture::Preference {
        None
    }
    /// The capture protocol the displays this backend opens will use.
    fn set_capture(&mut self, path: capture::CapturePath);
    /// Create (or adopt an unlocked leftover) and size the virtual output.
    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>>;
    /// Remove `od-*` outputs that no running sender holds a lock on.
    fn clean(&mut self) -> Result<Vec<String>>;
    /// Whether the cursor should be visible at all (`--cursor off`: no), for
    /// backends that fix it when the output is created rather than per
    /// capture. Called before the first [`open`](Self::open).
    fn set_cursor_visible(&mut self, _visible: bool) {}
    /// Whether [`show_workspace`](Self::show_workspace) works here.
    fn supports_workspaces(&self) -> bool {
        false
    }
    /// Show workspace `name` (a name or number) on `output`, leaving the
    /// user's focus where it was. Called after every open and recreation.
    fn show_workspace(&mut self, _output: &str, _name: &str) -> Result<()> {
        bail!("workspaces are not supported on this desktop")
    }
    /// The output lock [`open`](Self::open) takes for `spec`.
    fn lock_name(&self, spec: &DisplaySpec) -> String {
        spec.name.clone()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct CaptureOptions {
    /// Paint the cursor into the frames.
    pub cursor: bool,
}

/// One virtual display. Capture always stops before the output is
/// reconfigured or removed, including on drop: Hyprland 0.56.2 aborts in
/// `CScreenshareFrame::transform` when a monitor changes under a frame in
/// flight.
pub trait VirtualDisplay: Send {
    fn info(&self) -> &DisplayInfo;
    /// Start capturing on a thread the display owns; frames go to `sink`.
    /// If capture ends without [`stop_capture`](Self::stop_capture) (the
    /// output was removed, the compositor stopped the session) the sink gets
    /// one [`CaptureEvent::Ended`] as its last event.
    fn start_capture(&mut self, opts: CaptureOptions, sink: FrameSink) -> Result<()>;
    /// Deliver the pointer cursor on its own (position and sprite, for the
    /// cursor side channel, PROTOCOL §6.3) instead of painting it into the
    /// frames. Call before [`start_capture`](Self::start_capture) with
    /// `cursor: false`; [`stop_capture`](Self::stop_capture) stops it too.
    /// Errs when the compositor cannot; then paint the cursor instead.
    fn start_cursor(&mut self, _sink: CursorSink) -> Result<()> {
        bail!("this display cannot deliver the cursor separately")
    }
    /// Switch the frames between with and without a painted cursor, without
    /// touching the output (a new capture session on the same output).
    /// Used to stop painting once the side channel delivers the cursor, and
    /// to paint again if it fails.
    fn set_cursor_painted(&mut self, _painted: bool) -> Result<()> {
        bail!("this display cannot switch cursor painting")
    }
    /// Stop capture (frames and cursor) and join its threads. Idempotent.
    fn stop_capture(&mut self);
    /// A check of whether the compositor changed the display away from its
    /// spec (Hyprland: a config reload); `Some(why)` from the probe makes
    /// the session rebuild it from the same spec. Called on every session
    /// tick and must not block: compositor IPC goes in the probe, which the
    /// session runs on a blocking thread.
    fn drift_probe(&mut self) -> Option<DriftProbe> {
        None
    }
    /// Resize in place; stops capture first.
    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()>;
    /// Input bound to this display. Call again after `reconfigure`.
    fn input(&mut self) -> Result<Box<dyn InputSink>>;
    /// Stop capture, then remove the output unless `keep_output`.
    fn close(self: Box<Self>, keep_output: bool) -> Result<()>;
}

/// In-memory layout of a CPU frame, named as `wl_shm`/DRM fourccs are
/// (little-endian: `Xrgb8888` is B, G, R, X in memory).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelFormat {
    Xrgb8888,
    Argb8888,
    Xbgr8888,
    Abgr8888,
}

pub struct Frame {
    /// When the compositor reported the frame ready, before it is copied out.
    pub captured_at: Instant,
    /// Compositor presentation time, if reported.
    #[allow(dead_code)] // for the cursor side channel and latency stats
    pub presentation_ns: Option<u128>,
    pub buf: FrameBuf,
}

/// The bytes of a CPU frame: owned, or leased from the capture's buffer
/// pool (no copy; the buffer goes back to the pool when this is dropped).
pub enum Pixels {
    Owned(Vec<u8>),
    Leased(Box<dyn PixelLease>),
}

/// A capture buffer lent out for one frame.
pub trait PixelLease: Send {
    fn bytes(&self) -> &[u8];
}

impl std::ops::Deref for Pixels {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        match self {
            Pixels::Owned(v) => v,
            Pixels::Leased(l) => l.bytes(),
        }
    }
}

impl From<Vec<u8>> for Pixels {
    fn from(v: Vec<u8>) -> Self {
        Pixels::Owned(v)
    }
}

pub enum FrameBuf {
    Cpu {
        pixels: Pixels,
        width: u32,
        height: u32,
        stride: u32,
        #[allow(dead_code)] // the encoders assume BGRX/BGRA, which is what capture prefers
        format: PixelFormat,
    },
    /// Already converted to the encoder's 4:2:0 format by the convert stage
    /// ([`crate::encoder::ConvertStage`]).
    Yuv(crate::encoder::YuvFrame),
    /// GPU buffer for zero-copy hardware encode; not produced yet (VA-API).
    #[allow(dead_code)]
    Dmabuf { width: u32, height: u32 },
}

impl Frame {
    pub fn dimensions(&self) -> (u32, u32) {
        match self.buf {
            FrameBuf::Cpu { width, height, .. } | FrameBuf::Dmabuf { width, height } => {
                (width, height)
            }
            FrameBuf::Yuv(ref y) => y.dimensions(),
        }
    }
}

pub enum CaptureEvent {
    Frame(Frame),
    /// Capture stopped on its own; the display is unusable until reopened.
    Ended(String),
}

pub type FrameSink = Box<dyn FnMut(CaptureEvent) + Send>;

/// The pointer cursor over a display, for the cursor side channel.
#[derive(Debug, Clone, PartialEq)]
pub enum CursorEvent {
    /// Hotspot position, normalized to the display (PROTOCOL §7).
    Moved { x: f64, y: f64 },
    /// The cursor left the display (or has no image).
    Hidden,
    /// No sprite can be delivered (unsupported format, captures failing):
    /// the side channel must not be used, paint the cursor instead.
    SpriteUnavailable(String),
    /// A new sprite: PNG bytes, its size normalized to the display, the
    /// hotspot normalized within the sprite.
    Image {
        png: Vec<u8>,
        nw: f64,
        nh: f64,
        ax: f64,
        ay: f64,
    },
}

pub type CursorSink = Box<dyn FnMut(CursorEvent) + Send>;

/// A drift check that may block on the compositor; `Some(why)` if drifted.
pub type DriftProbe = Box<dyn FnOnce() -> Option<String> + Send>;

pub trait InputSink: Send {
    fn touch(&mut self, t: &Touch);
    fn scroll(&mut self, s: &Scroll);
    /// Pencil events are not mapped to the pointer yet; dropped.
    fn pencil(&mut self, _p: &Pencil) {}
}

#[cfg(test)]
mod tests {
    use super::Position;

    #[test]
    fn positions_parse() {
        assert_eq!(
            "auto-right".parse::<Position>().unwrap(),
            Position::AutoRight
        );
        assert_eq!("auto-up".parse::<Position>().unwrap(), Position::AutoUp);
        assert_eq!(
            "-1600,0".parse::<Position>().unwrap(),
            Position::At(-1600, 0)
        );
        assert_eq!("3024x0".parse::<Position>().unwrap(), Position::At(3024, 0));
        assert!("center".parse::<Position>().is_err());
    }
}

#[cfg(test)]
mod placement_tests {
    use super::{LayoutRect, Position, place};

    fn r(x: i32, y: i32, width: i32, height: i32) -> LayoutRect {
        LayoutRect {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn placement_next_to_the_layout() {
        let laptop = r(0, 0, 1512, 982);
        let left = r(-1920, -100, 1920, 1080);
        let both = [laptop, left];
        assert_eq!(place(Position::AutoRight, 800, 600, &both), (1512, 0));
        assert_eq!(place(Position::AutoLeft, 800, 600, &both), (-2720, -100));
        assert_eq!(place(Position::AutoDown, 800, 600, &both), (0, 982));
        assert_eq!(place(Position::AutoUp, 800, 600, &both), (-1920, -700));
        assert_eq!(place(Position::At(5, 6), 800, 600, &both), (5, 6));
        assert_eq!(place(Position::AutoRight, 800, 600, &[]), (0, 0));
    }
}
