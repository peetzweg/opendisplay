//! H.264 encoding behind one [`Encoder`] shape, with the backend picked at
//! run time (#360):
//!
//! 1. `v4l2m2m` — any V4L2 stateful mem2mem encoder through FFmpeg
//!    (`h264_v4l2m2m`): Raspberry Pi, Rockchip, and Asahi's AVE once a
//!    driver ships. Never auto-selected unless a device accepts the session.
//! 2. `x264` — libx264 through FFmpeg, `tune=zerolatency`. The software
//!    default: several times faster than OpenH264 on the same cores.
//! 3. `openh264` — compiled in, so it works even where the system FFmpeg was
//!    built without libx264 (Fedora's `ffmpeg-free`).
//!
//! VA-API (Intel/AMD) slots in as another FFmpeg backend ahead of x264.

mod ffmpeg;
mod openh264;

use std::time::Instant;

use anyhow::{Result, bail};
use clap::ValueEnum;
use opendisplay_proto::video::AccessUnit;
use tracing::{debug, info};

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Backend {
    /// First that opens: v4l2m2m, x264, openh264.
    Auto,
    V4l2m2m,
    X264,
    Openh264,
}

impl Backend {
    fn label(self) -> &'static str {
        match self {
            Backend::Auto => "auto",
            Backend::V4l2m2m => "V4L2 M2M (hardware)",
            Backend::X264 => "x264",
            Backend::Openh264 => "OpenH264",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct EncoderSettings {
    pub backend: Backend,
    pub bitrate_bps: u32,
    pub max_fps: f32,
    /// 0 = let the backend decide.
    pub threads: u16,
}

/// One encoded picture ready for the wire.
pub struct Encoded {
    pub unit: AccessUnit,
    pub captured_at: Instant,
    pub encode_ms: f64,
}

enum Imp {
    Ffmpeg(ffmpeg::FfmpegEncoder),
    OpenH264(Box<openh264::OpenH264Encoder>),
}

pub struct Encoder {
    imp: Imp,
    backend: Backend,
    width: u32,
    height: u32,
}

impl Encoder {
    /// Open the requested backend, or the first working one for
    /// [`Backend::Auto`]. I420 needs even dimensions; an odd panel loses a
    /// row/column.
    pub fn new(width: u32, height: u32, s: EncoderSettings) -> Result<Self> {
        let (width, height) = (width & !1, height & !1);
        let order: &[Backend] = match s.backend {
            Backend::Auto => &[Backend::V4l2m2m, Backend::X264, Backend::Openh264],
            Backend::V4l2m2m => &[Backend::V4l2m2m],
            Backend::X264 => &[Backend::X264],
            Backend::Openh264 => &[Backend::Openh264],
        };
        let mut errors = Vec::new();
        for &b in order {
            let imp = match b {
                Backend::V4l2m2m => {
                    ffmpeg::FfmpegEncoder::new(ffmpeg::Kind::V4l2m2m, width, height, s)
                        .map(Imp::Ffmpeg)
                }
                Backend::X264 => ffmpeg::FfmpegEncoder::new(ffmpeg::Kind::X264, width, height, s)
                    .map(Imp::Ffmpeg),
                Backend::Openh264 => openh264::OpenH264Encoder::new(width, height, s)
                    .map(|e| Imp::OpenH264(Box::new(e))),
                Backend::Auto => unreachable!(),
            };
            match imp {
                Ok(imp) => {
                    if !errors.is_empty() {
                        info!("encoder: using {} ({})", b.label(), errors.join("; "));
                    }
                    return Ok(Self {
                        imp,
                        backend: b,
                        width,
                        height,
                    });
                }
                Err(e) => {
                    debug!("encoder {} unavailable: {e:#}", b.label());
                    errors.push(format!("{} unavailable: {e:#}", b.label()));
                }
            }
        }
        bail!("no H.264 encoder could be opened: {}", errors.join("; "))
    }

    /// The backend that actually opened; pass it back in [`EncoderSettings`]
    /// so a resize does not probe again.
    pub fn backend(&self) -> Backend {
        self.backend
    }

    pub fn label(&self) -> &'static str {
        self.backend.label()
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// Encode one BGRX/BGRA frame (`stride` bytes per row). Returns the
    /// pictures the encoder produced, in order: usually one, none when it
    /// skipped the frame or holds it, two when a lagging encoder catches up.
    pub fn encode(
        &mut self,
        bgra: &[u8],
        stride: u32,
        force_idr: bool,
        captured_at: Instant,
    ) -> Result<Vec<Encoded>> {
        match &mut self.imp {
            Imp::Ffmpeg(e) => e.encode(bgra, stride, force_idr, captured_at),
            Imp::OpenH264(e) => e.encode(bgra, stride, force_idr, captured_at),
        }
    }
}
