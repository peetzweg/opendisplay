//! Software H.264 encoding with OpenH264 — the fallback tier that works on
//! every machine (Asahi, VMs, boxes without VA-API). Hardware encoders land
//! behind the same [`Encoder`] shape after Spike 0.

use std::time::Instant;

use anyhow::{Context, Result, anyhow};
use opendisplay_proto::video::{AccessUnit, access_units};
use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, EncoderConfig, FrameRate, FrameType, IntraFramePeriod, RateControlMode,
    SpsPpsStrategy, UsageType,
};
use openh264::formats::{BgraSliceU8, YUVBuffer};

#[derive(Debug, Clone, Copy)]
pub struct EncoderSettings {
    pub bitrate_bps: u32,
    pub max_fps: f32,
    pub threads: u16,
}

pub struct Encoder {
    inner: openh264::encoder::Encoder,
    width: u32,
    height: u32,
    packed: Vec<u8>,
    pub frames: u64,
    pub last_encode_ms: f64,
}

/// One encoded picture ready for the wire.
pub struct Encoded {
    pub unit: AccessUnit,
    pub captured_at: Instant,
    pub encode_ms: f64,
}

impl Encoder {
    pub fn new(width: u32, height: u32, s: EncoderSettings) -> Result<Self> {
        // I420 needs even dimensions; drop a row/column if the panel is odd.
        let (width, height) = (width & !1, height & !1);
        let cfg = EncoderConfig::new()
            .usage_type(UsageType::ScreenContentRealTime)
            .rate_control_mode(RateControlMode::Bitrate)
            .bitrate(BitRate::from_bps(s.bitrate_bps))
            .max_frame_rate(FrameRate::from_hz(s.max_fps))
            // §5.1/5.3: no periodic IDRs; keyframes only on demand.
            .intra_frame_period(IntraFramePeriod::from_num_frames(0))
            .sps_pps_strategy(SpsPpsStrategy::ConstantId)
            // OpenH264 insists on scene-change detection for screen content and
            // cannot hold a bitrate without being allowed to skip frames; a
            // skipped frame is fine for a latest-wins display stream.
            .skip_frames(true)
            .scene_change_detect(true)
            .num_threads(s.threads);
        let inner = openh264::encoder::Encoder::with_api_config(OpenH264API::from_source(), cfg)
            .map_err(|e| anyhow!("creating OpenH264 encoder: {e}"))?;
        Ok(Self {
            inner,
            width,
            height,
            packed: Vec::new(),
            frames: 0,
            last_encode_ms: 0.0,
        })
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// Encode one BGRX/BGRA frame (`stride` bytes per row). `None` when the
    /// encoder skipped the frame.
    pub fn encode(
        &mut self,
        bgra: &[u8],
        stride: u32,
        force_idr: bool,
        captured_at: Instant,
    ) -> Result<Option<Encoded>> {
        let t0 = Instant::now();
        let row = (self.width * 4) as usize;
        let src: &[u8] = if stride as usize == row {
            &bgra[..row * self.height as usize]
        } else {
            self.packed.clear();
            for y in 0..self.height as usize {
                let start = y * stride as usize;
                self.packed.extend_from_slice(&bgra[start..start + row]);
            }
            &self.packed
        };
        let yuv = YUVBuffer::from_bgra8_source(BgraSliceU8::new(
            src,
            (self.width as usize, self.height as usize),
        ));
        if force_idr {
            self.inner.force_intra_frame();
        }
        let bs = self
            .inner
            .encode(&yuv)
            .map_err(|e| anyhow!("encode: {e}"))?;
        if matches!(bs.frame_type(), FrameType::Skip | FrameType::Invalid) {
            return Ok(None);
        }
        let raw = bs.to_vec();
        let mut units = access_units(&raw);
        let unit = units.pop().context("encoder produced no access unit")?;
        let encode_ms = t0.elapsed().as_secs_f64() * 1000.0;
        self.frames += 1;
        self.last_encode_ms = encode_ms;
        Ok(Some(Encoded {
            unit,
            captured_at,
            encode_ms,
        }))
    }
}
