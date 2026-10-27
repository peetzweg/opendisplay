//! A convert stage in front of the encoder: large frames are converted from
//! BGRA to the encoder's 4:2:0 format on their own thread, so frame N+1
//! converts while frame N encodes. The capture lease is returned as soon as
//! the conversion is done.
//!
//! The stage sits between capture and the encoder's latest-wins slot as a
//! [`FrameSink`] adapter and keeps the slot semantics: a busy stage converts
//! only the newest frame. Small frames, and every frame until an encoder has
//! said which format it takes ([`ConvertStage::bind`]), pass through
//! unconverted and the encoder converts them itself, as before.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ff::format::Pixel;
use ff::util::color;
use ffmpeg_next as ff;
use tracing::{debug, warn};

use super::Encoder;
use super::convert::{Converter, band_count};
use crate::backend::{CaptureEvent, Frame, FrameBuf, FrameSink};
use crate::latest;

/// Narrower frames convert in a few ms inside the encode call; a separate
/// stage only pays off where conversion is a real share of the frame time.
pub const MIN_STAGE_WIDTH: u32 = 2560;
/// Converted frames kept for reuse: one in the encoder's slot, one being
/// encoded, the one kept for an IDR replay, and one being converted.
const POOL_FRAMES: usize = 4;

/// A frame already in the encoder's format. Dropping it returns its buffers
/// to the stage's pool.
pub struct YuvFrame {
    video: Option<ff::frame::Video>,
    pool: Arc<Mutex<Vec<ff::frame::Video>>>,
}

impl YuvFrame {
    pub fn dimensions(&self) -> (u32, u32) {
        let v = self.video();
        (v.width(), v.height())
    }

    pub(super) fn video(&self) -> &ff::frame::Video {
        self.video.as_ref().expect("present until drop")
    }
}

impl Drop for YuvFrame {
    fn drop(&mut self) {
        let mut pool = self.pool.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(v) = self.video.take() {
            // A frame of an older size or format is not reused.
            let fits = pool.first().is_none_or(|p| {
                (p.width(), p.height(), p.format()) == (v.width(), v.height(), v.format())
            });
            if fits && pool.len() < POOL_FRAMES {
                pool.push(v);
            }
        }
    }
}

/// Allocate a frame with the colour description the encoders announce.
pub(super) fn new_video(format: Pixel, width: u32, height: u32) -> ff::frame::Video {
    let mut v = ff::frame::Video::new(format, width, height);
    v.set_color_space(color::Space::BT709);
    v.set_color_primaries(color::Primaries::BT709);
    v.set_color_transfer_characteristic(color::TransferCharacteristic::BT709);
    v.set_color_range(color::Range::MPEG);
    v
}

/// Shared between the encode thread (which binds the target format) and
/// the capture sink.
#[derive(Clone, Default)]
pub struct ConvertStage {
    target: Arc<Mutex<Option<Pixel>>>,
}

impl ConvertStage {
    pub fn new() -> Self {
        Self::default()
    }

    /// Tell the stage what the open encoder takes; call after every
    /// `Encoder::new`.
    pub fn bind(&self, encoder: &Encoder) {
        *self.target.lock().unwrap_or_else(|e| e.into_inner()) = encoder.yuv_format();
    }

    fn target_for(&self, frame: &Frame) -> Option<Pixel> {
        let (w, _) = frame.dimensions();
        let is_bgra = matches!(frame.buf, FrameBuf::Cpu { .. });
        let target = *self.target.lock().unwrap_or_else(|e| e.into_inner());
        target.filter(|_| is_bgra && w >= MIN_STAGE_WIDTH)
    }

    /// Wrap the encoder's sink. The returned sink is called on the capture
    /// thread; the stage's thread ends when it is dropped.
    /// If the stage's thread dies, frames pass through unconverted again.
    pub fn sink(&self, next: FrameSink) -> FrameSink {
        let next = Arc::new(Mutex::new(next));
        let (tx, rx) = latest::channel::<(Frame, Pixel)>();
        let forward = next.clone();
        let alive = Arc::new(AtomicBool::new(true));
        let guard = Alive(alive.clone());
        let spawned = std::thread::Builder::new()
            .name("convert".into())
            .spawn(move || {
                let _guard = guard;
                run(rx, forward);
            });
        let stage = self.clone();
        let tx = match spawned {
            Ok(_) => Some(tx),
            Err(e) => {
                warn!("convert stage unavailable, the encoder converts: {e}");
                None
            }
        };
        Box::new(move |ev| match ev {
            CaptureEvent::Frame(f) => match (stage.target_for(&f), &tx) {
                (Some(format), Some(tx)) if alive.load(Ordering::Relaxed) => {
                    tx.send((f, format));
                }
                _ => (next.lock().unwrap_or_else(|e| e.into_inner()))(CaptureEvent::Frame(f)),
            },
            ended => (next.lock().unwrap_or_else(|e| e.into_inner()))(ended),
        })
    }
}

/// Cleared when the stage's thread ends, by panic or otherwise.
struct Alive(Arc<AtomicBool>);

impl Drop for Alive {
    fn drop(&mut self) {
        if std::thread::panicking() {
            warn!("convert stage panicked; the encoder converts from now on");
        }
        self.0.store(false, Ordering::Relaxed);
    }
}

fn run(rx: latest::Receiver<(Frame, Pixel)>, next: Arc<Mutex<FrameSink>>) {
    let pool: Arc<Mutex<Vec<ff::frame::Video>>> = Arc::default();
    let mut converter: Option<(Converter, Pixel)> = None;
    loop {
        let (frame, format) = match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(f) => f,
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let FrameBuf::Cpu {
            pixels,
            width,
            height,
            stride,
            ..
        } = &frame.buf
        else {
            continue;
        };
        let (w, h) = (width & !1, height & !1);
        if converter
            .as_ref()
            .is_none_or(|(c, f)| *f != format || c.dimensions() != (w, h))
        {
            match Converter::new(w, h, format, band_count(h, 0)) {
                Ok(c) => converter = Some((c, format)),
                Err(e) => {
                    warn!("convert stage: {e:#}");
                    continue;
                }
            }
        }
        let video = {
            let mut p = pool.lock().unwrap_or_else(|e| e.into_inner());
            let reuse = p
                .iter()
                .position(|v| (v.width(), v.height(), v.format()) == (w, h, format));
            match reuse {
                Some(i) => p.swap_remove(i),
                None => new_video(format, w, h),
            }
        };
        let mut yuv = YuvFrame {
            video: Some(video),
            pool: pool.clone(),
        };
        let (c, _) = converter.as_mut().expect("built above");
        if let Err(e) = c.convert(pixels, *stride, yuv.video.as_mut().expect("present")) {
            warn!("convert stage: {e:#}");
            continue;
        }
        let converted = Frame {
            captured_at: frame.captured_at,
            presentation_ns: frame.presentation_ns,
            buf: FrameBuf::Yuv(yuv),
        };
        // The capture buffer goes back to its pool here.
        drop(frame);
        (next.lock().unwrap_or_else(|e| e.into_inner()))(CaptureEvent::Frame(converted));
    }
    debug!("convert stage done");
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::Instant;

    use super::*;
    use crate::backend::{PixelFormat, Pixels};
    use crate::encoder::{Backend, EncoderSettings};

    fn bgra(w: u32, h: u32, i: usize) -> Frame {
        let stride = w * 4;
        let mut px = vec![0u8; (stride * h) as usize];
        for y in 0..h as usize {
            for x in 0..w as usize {
                let o = y * stride as usize + x * 4;
                let v = ((x / 8 + y / 12 + i) % 7 * 36) as u8;
                px[o] = v;
                px[o + 1] = (x ^ y) as u8;
                px[o + 2] = 255 - v;
                px[o + 3] = 255;
            }
        }
        Frame {
            captured_at: Instant::now(),
            presentation_ns: None,
            buf: FrameBuf::Cpu {
                pixels: Pixels::Owned(px),
                width: w,
                height: h,
                stride,
                format: PixelFormat::Xrgb8888,
            },
        }
    }

    fn x264(w: u32, h: u32) -> Option<Encoder> {
        Encoder::new(
            w,
            h,
            EncoderSettings {
                backend: Backend::X264,
                bitrate_bps: 20_000_000,
                max_fps: 60.0,
                // Sliced threads make x264's output differ run to run.
                threads: 1,
            },
        )
        .ok()
    }

    /// A stage feeding a channel instead of the encoder's slot.
    fn staged(stage: &ConvertStage) -> (FrameSink, mpsc::Receiver<Frame>) {
        let (tx, rx) = mpsc::channel();
        let sink = stage.sink(Box::new(move |ev| {
            if let CaptureEvent::Frame(f) = ev {
                let _ = tx.send(f);
            }
        }));
        (sink, rx)
    }

    #[test]
    fn staged_frames_encode_to_the_same_bitstream() {
        let (w, h) = (2560, 1440);
        let (Some(mut direct), Some(mut via_stage)) = (x264(w, h), x264(w, h)) else {
            eprintln!("no libx264 in this FFmpeg; skipped");
            return;
        };
        let stage = ConvertStage::new();
        stage.bind(&via_stage);
        let (mut sink, rx) = staged(&stage);
        for i in 0..4 {
            sink(CaptureEvent::Frame(bgra(w, h, i)));
            let converted = rx.recv_timeout(Duration::from_secs(10)).unwrap();
            assert!(matches!(converted.buf, FrameBuf::Yuv(_)));
            let a = direct.encode(&bgra(w, h, i), i == 0).unwrap();
            let b = via_stage.encode(&converted, i == 0).unwrap();
            let bytes = |v: Vec<crate::encoder::Encoded>| {
                v.into_iter()
                    .flat_map(|e| e.unit.annexb)
                    .collect::<Vec<u8>>()
            };
            assert!(bytes(a) == bytes(b), "frame {i} differs");
        }
    }

    #[test]
    fn small_and_unbound_frames_pass_through() {
        let stage = ConvertStage::new();
        let (mut sink, rx) = staged(&stage);
        // Not bound to an encoder yet.
        sink(CaptureEvent::Frame(bgra(2560, 1440, 0)));
        let f = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(f.buf, FrameBuf::Cpu { .. }));
        let Some(enc) = x264(1280, 800) else { return };
        stage.bind(&enc);
        // Below the stage width.
        sink(CaptureEvent::Frame(bgra(1280, 800, 0)));
        let f = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(f.buf, FrameBuf::Cpu { .. }));
    }

    #[test]
    fn converted_frames_are_reused() {
        let Some(enc) = x264(2560, 1440) else { return };
        let stage = ConvertStage::new();
        stage.bind(&enc);
        let (mut sink, rx) = staged(&stage);
        let mut seen = Vec::new();
        for i in 0..6 {
            sink(CaptureEvent::Frame(bgra(2560, 1440, i)));
            let f = rx.recv_timeout(Duration::from_secs(10)).unwrap();
            let FrameBuf::Yuv(y) = &f.buf else { panic!() };
            seen.push(y.video().data(0).as_ptr() as usize);
            // Dropped right away: the next conversion reuses its buffers.
        }
        seen.dedup();
        assert_eq!(seen.len(), 1, "{seen:?}");
    }
}
