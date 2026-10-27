//! OpenH264, compiled in: the last-resort tier that works on every machine,
//! including ones whose FFmpeg lacks libx264.

use std::time::Instant;

use anyhow::{Context, Result, anyhow, bail};
use opendisplay_proto::video::access_units;
use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, EncoderConfig, FrameRate, FrameType, IntraFramePeriod, RateControlMode,
    SpsPpsStrategy, UsageType,
};
use openh264::formats::{BgraSliceU8, YUVBuffer};

use super::{Encoded, EncoderSettings};

/// OpenH264 refuses larger frames, at the first `encode` rather than at
/// creation; checking up front lets `auto` skip it cleanly.
const MAX_LONG: u32 = 3840;
const MAX_SHORT: u32 = 2160;

fn supports(width: u32, height: u32) -> bool {
    width.max(height) <= MAX_LONG && width.min(height) <= MAX_SHORT
}

pub struct OpenH264Encoder {
    inner: openh264::encoder::Encoder,
    width: u32,
    height: u32,
    packed: Vec<u8>,
}

impl OpenH264Encoder {
    /// `width`/`height` are already even.
    pub fn new(width: u32, height: u32, s: EncoderSettings) -> Result<Self> {
        if !supports(width, height) {
            bail!(
                "OpenH264 encodes at most {MAX_LONG}x{MAX_SHORT} \
                 ({MAX_SHORT}x{MAX_LONG} portrait), not {width}x{height}"
            );
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoder::Backend;

    fn settings() -> EncoderSettings {
        EncoderSettings {
            backend: Backend::Openh264,
            bitrate_bps: 8_000_000,
            max_fps: 60.0,
            threads: 1,
        }
    }

    #[test]
    fn refuses_frames_above_its_limit_at_creation() {
        assert!(supports(3840, 2160) && supports(2160, 3840) && supports(2556, 1178));
        assert!(!supports(4096, 2304) && !supports(2304, 4096) && !supports(3840, 2162));
        let e = OpenH264Encoder::new(4096, 2304, settings()).err().unwrap();
        assert!(e.to_string().contains("at most 3840x2160"), "{e}");
    }
}
