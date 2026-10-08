//! OpenH264, compiled in: the last-resort tier that works on every machine,
//! including ones whose FFmpeg lacks libx264.

use std::time::Instant;

use anyhow::{Context, Result, anyhow};
use opendisplay_proto::video::access_units;
use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, EncoderConfig, FrameRate, FrameType, IntraFramePeriod, RateControlMode,
    SpsPpsStrategy, UsageType,
};
use openh264::formats::{BgraSliceU8, YUVBuffer};

use super::{Encoded, EncoderSettings};

pub struct OpenH264Encoder {
    inner: openh264::encoder::Encoder,
    width: u32,
    height: u32,
    packed: Vec<u8>,
}

impl OpenH264Encoder {
    /// `width`/`height` are already even.
    pub fn new(width: u32, height: u32, s: EncoderSettings) -> Result<Self> {
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
        })
    }

    pub fn encode(
        &mut self,
        bgra: &[u8],
        stride: u32,
        force_idr: bool,
        captured_at: Instant,
    ) -> Result<Vec<Encoded>> {
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
            return Ok(Vec::new());
        }
        let raw = bs.to_vec();
        let mut units = access_units(&raw);
        let unit = units.pop().context("encoder produced no access unit")?;
        Ok(vec![Encoded {
            unit,
            captured_at,
            encode_ms: t0.elapsed().as_secs_f64() * 1000.0,
        }])
    }
}
