//! H.264 through the system FFmpeg: libx264 in software, or a V4L2 mem2mem
//! hardware encoder. Capture hands us BGRA; swscale converts it to the
//! encoder's 4:2:0 format with BT.709 limited-range coefficients, which the
//! stream's VUI announces so the receiver converts back the same way.

use std::collections::VecDeque;
use std::sync::Once;
use std::time::Instant;

use anyhow::{Context as _, Result, anyhow, bail};
use ff::format::Pixel;
use ff::util::color;
use ffmpeg_next as ff;
use opendisplay_proto::video::{AccessUnit, NalType, access_units, nal_units};

use super::{Encoded, EncoderSettings};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    X264,
    V4l2m2m,
}

pub struct FfmpegEncoder {
    enc: ff::encoder::Video,
    sws: ff::software::scaling::Context,
    yuv: ff::frame::Video,
    width: u32,
    height: u32,
    pts: i64,
    /// Capture instants of frames handed to the encoder, by pts. A hardware
    /// encoder may return a packet one call late.
    in_flight: VecDeque<(i64, Instant, Instant)>,
    /// Parameter sets from the last IDR, prepended to any IDR that arrives
    /// without them (§5.1). x264 repeats them itself; V4L2 drivers vary.
    param_sets: Vec<u8>,
}

static INIT: Once = Once::new();

fn init() {
    INIT.call_once(|| {
        let _ = ff::init();
        // FFmpeg's own log is noise next to ours (v4l2m2m probing in
        // particular logs every device it rejects).
        ff::util::log::set_level(ff::util::log::Level::Fatal);
    });
}

impl FfmpegEncoder {
    /// `width`/`height` are already even.
    pub fn new(kind: Kind, width: u32, height: u32, s: EncoderSettings) -> Result<Self> {
        init();
        let name = match kind {
            Kind::X264 => "libx264",
            Kind::V4l2m2m => "h264_v4l2m2m",
        };
        let codec = ff::encoder::find_by_name(name)
            .ok_or_else(|| anyhow!("this FFmpeg build has no {name}"))?;
        let format = pick_format(&codec, kind);

        let mut v = ff::codec::context::Context::new_with_codec(codec)
            .encoder()
            .video()?;
        v.set_width(width);
        v.set_height(height);
        v.set_format(format);
        v.set_time_base((1, 1_000_000));
        let fps = s.max_fps.round().max(1.0) as i32;
        v.set_frame_rate(Some((fps, 1)));
        v.set_max_b_frames(0);
        v.set_colorspace(color::Space::BT709);
        v.set_color_primaries(color::Primaries::BT709);
        v.set_color_transfer_characteristic(color::TransferCharacteristic::BT709);
        v.set_color_range(color::Range::MPEG);

        let mut opts = ff::Dictionary::new();
        match kind {
            Kind::X264 => {
                // Quality-targeted with a VBV cap: a static desktop costs
                // almost nothing, motion is held to the bitrate, and a
                // quarter-second buffer keeps one frame from stalling the link.
                let kbps = (s.bitrate_bps / 1000).max(500);
                v.set_max_bit_rate(s.bitrate_bps as usize);
                // SAFETY: plain field write on a context we own and have not opened.
                unsafe { (*v.as_mut_ptr()).rc_buffer_size = (s.bitrate_bps / 4) as i32 };
                opts.set("preset", "superfast");
                opts.set("tune", "zerolatency");
                opts.set("crf", "21");
                // A pict_type of I becomes an IDR, not a recovery-point I frame.
                opts.set("forced-idr", "1");
                // §5.3: keyframes only on demand.
                opts.set(
                    "x264-params",
                    &format!(
                        "keyint=infinite:scenecut=0:vbv-maxrate={kbps}:vbv-bufsize={}",
                        kbps / 4
                    ),
                );
                if s.threads > 0 {
                    opts.set("threads", &s.threads.to_string());
                }
            }
            Kind::V4l2m2m => {
                v.set_bit_rate(s.bitrate_bps as usize);
                // The longest GOP drivers accept without complaint; IDRs are
                // forced on demand anyway.
                v.set_gop(32_767);
            }
        }
        let enc = v
            .open_with(opts)
            .with_context(|| format!("opening {name} at {width}x{height}"))?;

        let sws = ff::software::scaling::Context::get(
            Pixel::BGRA,
            width,
            height,
            format,
            width,
            height,
            ff::software::scaling::Flags::BILINEAR,
        )?;
        // SAFETY: coefficient tables are static; the context is valid.
        unsafe {
            let coeffs = ff::ffi::sws_getCoefficients(ff::ffi::SWS_CS_ITU709);
            // Source full range (desktop RGB), destination limited (video).
            ff::ffi::sws_setColorspaceDetails(
                sws.as_ptr() as *mut _,
                coeffs,
                1,
                coeffs,
                0,
                0,
                1 << 16,
                1 << 16,
            );
        }

        let mut yuv = ff::frame::Video::new(format, width, height);
        yuv.set_color_space(color::Space::BT709);
        yuv.set_color_primaries(color::Primaries::BT709);
        yuv.set_color_transfer_characteristic(color::TransferCharacteristic::BT709);
        yuv.set_color_range(color::Range::MPEG);

        Ok(Self {
            enc,
            sws,
            yuv,
            width,
            height,
            pts: 0,
            in_flight: VecDeque::new(),
            param_sets: Vec::new(),
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
        if bgra.len() < stride as usize * (self.height as usize - 1) + self.width as usize * 4 {
            bail!(
                "frame buffer smaller than {}x{} at stride {stride}",
                self.width,
                self.height
            );
        }
        // SAFETY: the source pointer/stride describe `height` rows inside
        // `bgra` (checked above); the destination is our own frame, made
        // writable first because the encoder may still reference its buffers.
        unsafe {
            let dst = self.yuv.as_mut_ptr();
            if ff::ffi::av_frame_make_writable(dst) < 0 {
                bail!("av_frame_make_writable failed");
            }
            let src = [
                bgra.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
            ];
            let src_stride = [stride as i32, 0, 0, 0];
            ff::ffi::sws_scale(
                self.sws.as_mut_ptr(),
                src.as_ptr(),
                src_stride.as_ptr(),
                0,
                self.height as i32,
                (*dst).data.as_ptr(),
                (*dst).linesize.as_ptr(),
            );
        }
        self.yuv.set_pts(Some(self.pts));
        self.yuv.set_kind(if force_idr {
            ff::picture::Type::I
        } else {
            ff::picture::Type::None
        });
        self.enc.send_frame(&self.yuv).context("send_frame")?;
        self.in_flight.push_back((self.pts, captured_at, t0));
        // 1/60 s apart in the time base; the encoder only needs monotonic pts.
        self.pts += 16_667;

        // Usually one packet per call; a hardware encoder can lag by one and
        // then return two. Every picture goes out: dropping a P frame would
        // corrupt the ones that reference it.
        let mut out = Vec::new();
        let mut pkt = ff::Packet::empty();
        loop {
            match self.enc.receive_packet(&mut pkt) {
                Ok(()) => {}
                Err(ff::Error::Other { errno }) if errno == ff::util::error::EAGAIN => break,
                Err(e) => return Err(e).context("receive_packet"),
            }
            let Some(data) = pkt.data() else { continue };
            let (captured_at, started) = self.take_in_flight(pkt.pts());
            if let Some(unit) = self.access_unit(data) {
                out.push(Encoded {
                    unit,
                    captured_at,
                    encode_ms: started.elapsed().as_secs_f64() * 1000.0,
                });
            }
        }
        Ok(out)
    }

    fn take_in_flight(&mut self, pts: Option<i64>) -> (Instant, Instant) {
        while let Some(&(p, cap, started)) = self.in_flight.front() {
            self.in_flight.pop_front();
            if pts.is_none_or(|t| t <= p) {
                return (cap, started);
            }
        }
        let now = Instant::now();
        (now, now)
    }

    /// One packet is one picture; normalize it to an access unit and make
    /// sure an IDR carries SPS and PPS.
    fn access_unit(&mut self, data: &[u8]) -> Option<AccessUnit> {
        let mut unit = access_units(data).pop()?;
        if unit.is_idr {
            let mut sets = Vec::new();
            for nal in nal_units(&unit.annexb) {
                if matches!(NalType::of(nal), Some(NalType::Sps | NalType::Pps)) {
                    sets.extend_from_slice(&[0, 0, 0, 1]);
                    sets.extend_from_slice(nal);
                }
            }
            if sets.is_empty() {
                if self.param_sets.is_empty() {
                    return None;
                }
                let mut with = self.param_sets.clone();
                with.extend_from_slice(&unit.annexb);
                unit.annexb = with;
            } else {
                self.param_sets = sets;
            }
        }
        Some(unit)
    }
}

/// x264 wants planar I420; V4L2 encoders usually take NV12 and sometimes
/// only that.
fn pick_format(codec: &ff::Codec, kind: Kind) -> Pixel {
    let listed: Vec<Pixel> = codec
        .video()
        .ok()
        .and_then(|v| v.formats())
        .map(|f| f.collect())
        .unwrap_or_default();
    let prefs: &[Pixel] = match kind {
        Kind::X264 => &[Pixel::YUV420P, Pixel::NV12],
        Kind::V4l2m2m => &[Pixel::NV12, Pixel::YUV420P],
    };
    prefs
        .iter()
        .copied()
        .find(|p| listed.is_empty() || listed.contains(p))
        .unwrap_or(prefs[0])
}
