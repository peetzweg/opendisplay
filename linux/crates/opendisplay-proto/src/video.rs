//! Video frame layout (§5): telemetry prefix, Annex B NAL units, parameter
//! sets, and the SPS fields a receiver needs (dimensions).
//!
//! Also carries the sender-side helpers a Linux sender or a replay tool needs
//! to turn an arbitrary Annex B byte stream into spec-conformant wire frames:
//! start-code normalisation and access-unit grouping.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// The only start code the spec allows on the wire (§5.1).
pub const START_CODE: [u8; 4] = [0, 0, 0, 1];

#[derive(Debug, Error, PartialEq, Eq)]
pub enum VideoFrameError {
    #[error("video frame contains no 4-byte start code")]
    NoStartCode,
    #[error("SPS could not be parsed: {0}")]
    BadSps(&'static str),
}

/// Sender clock stamps carried before the first start code (§5.1).
/// Milliseconds since the Unix epoch on the sender's clock.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Telemetry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cap: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snd: Option<f64>,
}

impl Telemetry {
    /// Lenient parse: absent or malformed prefixes yield an empty telemetry,
    /// never an error — the spec says receivers MUST tolerate its absence and
    /// it exists only for measurement.
    pub fn parse_lenient(prefix: &[u8]) -> Telemetry {
        if prefix.is_empty() {
            return Telemetry::default();
        }
        serde_json::from_slice(prefix).unwrap_or_default()
    }
}

/// H.264 NAL unit types this protocol cares about (`nal_unit_type`, 5 bits).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NalType {
    NonIdrSlice,
    IdrSlice,
    Sei,
    Sps,
    Pps,
    AccessUnitDelimiter,
    Other(u8),
}

impl NalType {
    pub fn of(nal: &[u8]) -> Option<NalType> {
        let t = *nal.first()? & 0x1f;
        Some(match t {
            1 => NalType::NonIdrSlice,
            5 => NalType::IdrSlice,
            6 => NalType::Sei,
            7 => NalType::Sps,
            8 => NalType::Pps,
            9 => NalType::AccessUnitDelimiter,
            other => NalType::Other(other),
        })
    }

    /// Slice data (VCL) as opposed to parameter sets, SEI, AUD (non-VCL).
    pub fn is_vcl(self) -> bool {
        matches!(self, NalType::NonIdrSlice | NalType::IdrSlice)
            || matches!(self, NalType::Other(2..=4))
    }
}

/// Find the first 4-byte start code at or after `from`.
fn find_start_code(buf: &[u8], from: usize) -> Option<usize> {
    if buf.len() < 4 {
        return None;
    }
    (from..=buf.len() - 4).find(|&i| buf[i..i + 4] == START_CODE)
}

/// Iterate the NAL units of an Annex B buffer, splitting on 4-byte start codes
/// only (§5.1 lets receivers rely on that). Bytes before the first start code
/// are skipped; empty NALs (back-to-back start codes) are dropped.
pub fn nal_units(annexb: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut pos = find_start_code(annexb, 0).map(|p| p + 4);
    std::iter::from_fn(move || {
        let start = pos?;
        let end = find_start_code(annexb, start);
        pos = end.map(|e| e + 4);
        let nal = &annexb[start..end.unwrap_or(annexb.len())];
        Some(nal)
    })
    .filter(|n| !n.is_empty())
}

/// A parsed sender-to-receiver video frame (§5.1).
#[derive(Debug, Clone, PartialEq)]
pub struct VideoFrame<'a> {
    pub telemetry: Telemetry,
    /// The Annex B access unit, starting at its first start code.
    pub annexb: &'a [u8],
    pub sps: Option<&'a [u8]>,
    pub pps: Option<&'a [u8]>,
    pub is_idr: bool,
}

impl<'a> VideoFrame<'a> {
    pub fn parse(payload: &'a [u8]) -> Result<VideoFrame<'a>, VideoFrameError> {
        let first = find_start_code(payload, 0).ok_or(VideoFrameError::NoStartCode)?;
        let telemetry = Telemetry::parse_lenient(&payload[..first]);
        let annexb = &payload[first..];
        let (mut sps, mut pps, mut is_idr) = (None, None, false);
        for nal in nal_units(annexb) {
            match NalType::of(nal) {
                Some(NalType::Sps) => sps = Some(nal),
                Some(NalType::Pps) => pps = Some(nal),
                Some(NalType::IdrSlice) => is_idr = true,
                _ => {}
            }
        }
        Ok(VideoFrame {
            telemetry,
            annexb,
            sps,
            pps,
            is_idr,
        })
    }

    /// Video dimensions from the SPS, if this frame carries one (§5.2:
    /// receivers MUST take dimensions from the SPS, never from `hello`).
    pub fn sps_info(&self) -> Option<Result<SpsInfo, VideoFrameError>> {
        self.sps.map(SpsInfo::parse)
    }
}

/// Build a wire video frame from an Annex B access unit (§5.1). The caller
/// guarantees 4-byte start codes (see [`normalize_start_codes`]) and SPS/PPS on
/// IDR frames (see [`AccessUnit`]).
pub fn encode_video_frame(telemetry: Option<&Telemetry>, annexb: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(annexb.len() + 48);
    if let Some(t) = telemetry {
        // Can never contain a NUL or a start code: it is JSON with numbers.
        serde_json::to_writer(&mut out, t).expect("telemetry serialises");
    }
    out.extend_from_slice(annexb);
    out
}

/// Tracks the active SPS/PPS to detect stream changes (§5.2).
#[derive(Debug, Default, Clone)]
pub struct ParameterSetTracker {
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParameterSetChange {
    /// No parameter sets in this frame, or identical to the active ones.
    Unchanged,
    /// First parameter sets ever seen on this connection.
    First,
    /// Different from the active ones: rebuild the decoder, discard buffered frames.
    Changed,
}

impl ParameterSetTracker {
    pub fn has_parameters(&self) -> bool {
        self.sps.is_some() && self.pps.is_some()
    }

    pub fn active_sps(&self) -> Option<&[u8]> {
        self.sps.as_deref()
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn observe(&mut self, frame: &VideoFrame<'_>) -> ParameterSetChange {
        let (Some(sps), Some(pps)) = (frame.sps, frame.pps) else {
            return ParameterSetChange::Unchanged;
        };
        let had = self.has_parameters();
        let same = self.sps.as_deref() == Some(sps) && self.pps.as_deref() == Some(pps);
        if same {
            return ParameterSetChange::Unchanged;
        }
        self.sps = Some(sps.to_vec());
        self.pps = Some(pps.to_vec());
        if had {
            ParameterSetChange::Changed
        } else {
            ParameterSetChange::First
        }
    }
}

// ---------------------------------------------------------------------------
// SPS parsing
// ---------------------------------------------------------------------------

/// The subset of `seq_parameter_set_data` a receiver needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpsInfo {
    pub profile_idc: u8,
    pub level_idc: u8,
    /// Coded picture size after cropping, in pixels.
    pub width: u32,
    pub height: u32,
}

struct BitReader<'a> {
    data: &'a [u8],
    pos: usize, // in bits
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    fn bit(&mut self) -> Result<u32, VideoFrameError> {
        let byte = *self
            .data
            .get(self.pos / 8)
            .ok_or(VideoFrameError::BadSps("truncated"))?;
        let b = (byte >> (7 - (self.pos % 8))) & 1;
        self.pos += 1;
        Ok(b as u32)
    }
    fn bits(&mut self, n: u32) -> Result<u32, VideoFrameError> {
        let mut v = 0u32;
        for _ in 0..n {
            v = (v << 1) | self.bit()?;
        }
        Ok(v)
    }
    fn ue(&mut self) -> Result<u32, VideoFrameError> {
        let mut zeros = 0;
        while self.bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                return Err(VideoFrameError::BadSps("exp-golomb overflow"));
            }
        }
        if zeros == 0 {
            return Ok(0);
        }
        Ok(((1u64 << zeros) - 1 + self.bits(zeros)? as u64) as u32)
    }
    fn se(&mut self) -> Result<i32, VideoFrameError> {
        let k = self.ue()? as i64;
        Ok(if k % 2 == 1 {
            ((k + 1) / 2) as i32
        } else {
            -(k / 2) as i32
        })
    }
}

/// Strip emulation-prevention bytes (`00 00 03` -> `00 00`) from an RBSP.
fn unescape_rbsp(nal_payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(nal_payload.len());
    let mut zeros = 0;
    for &b in nal_payload {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        out.push(b);
        zeros = if b == 0 { zeros + 1 } else { 0 };
    }
    out
}

impl SpsInfo {
    /// Parse an SPS NAL unit (including its 1-byte NAL header).
    pub fn parse(nal: &[u8]) -> Result<SpsInfo, VideoFrameError> {
        if NalType::of(nal) != Some(NalType::Sps) {
            return Err(VideoFrameError::BadSps("not an SPS NAL"));
        }
        let rbsp = unescape_rbsp(&nal[1..]);
        let mut r = BitReader::new(&rbsp);
        let profile_idc = r.bits(8)? as u8;
        r.bits(8)?; // constraint_set flags + reserved
        let level_idc = r.bits(8)? as u8;
        r.ue()?; // seq_parameter_set_id
        let mut chroma_format_idc = 1;
        if matches!(
            profile_idc,
            100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135
        ) {
            chroma_format_idc = r.ue()?;
            if chroma_format_idc == 3 {
                r.bit()?; // separate_colour_plane_flag
            }
            r.ue()?; // bit_depth_luma_minus8
            r.ue()?; // bit_depth_chroma_minus8
            r.bit()?; // qpprime_y_zero_transform_bypass_flag
            if r.bit()? == 1 {
                // seq_scaling_matrix_present_flag
                let lists = if chroma_format_idc != 3 { 8 } else { 12 };
                for i in 0..lists {
                    if r.bit()? == 1 {
                        let size = if i < 6 { 16 } else { 64 };
                        let mut last = 8i32;
                        let mut next = 8i32;
                        for _ in 0..size {
                            if next != 0 {
                                let delta = r.se()?;
                                next = (last + delta + 256) % 256;
                            }
                            last = if next == 0 { last } else { next };
                        }
                    }
                }
            }
        }
        r.ue()?; // log2_max_frame_num_minus4
        let poc_type = r.ue()?;
        if poc_type == 0 {
            r.ue()?; // log2_max_pic_order_cnt_lsb_minus4
        } else if poc_type == 1 {
            r.bit()?; // delta_pic_order_always_zero_flag
            r.se()?; // offset_for_non_ref_pic
            r.se()?; // offset_for_top_to_bottom_field
            let n = r.ue()?;
            for _ in 0..n {
                r.se()?;
            }
        }
        r.ue()?; // max_num_ref_frames
        r.bit()?; // gaps_in_frame_num_value_allowed_flag
        let width_mbs = r.ue()? + 1;
        let height_map_units = r.ue()? + 1;
        let frame_mbs_only = r.bit()?;
        if frame_mbs_only == 0 {
            r.bit()?; // mb_adaptive_frame_field_flag
        }
        r.bit()?; // direct_8x8_inference_flag
        let (mut cl, mut cr, mut ct, mut cb) = (0, 0, 0, 0);
        if r.bit()? == 1 {
            cl = r.ue()?;
            cr = r.ue()?;
            ct = r.ue()?;
            cb = r.ue()?;
        }
        let (sub_w, sub_h) = match chroma_format_idc {
            0 => (1, 1),
            1 => (2, 2),
            2 => (2, 1),
            _ => (1, 1),
        };
        let crop_unit_x = sub_w;
        let crop_unit_y = sub_h * (2 - frame_mbs_only);
        let width = width_mbs * 16 - (cl + cr) * crop_unit_x;
        let height = (2 - frame_mbs_only) * height_map_units * 16 - (ct + cb) * crop_unit_y;
        Ok(SpsInfo {
            profile_idc,
            level_idc,
            width,
            height,
        })
    }
}

// ---------------------------------------------------------------------------
// Sender-side helpers: normalising arbitrary Annex B into wire frames
// ---------------------------------------------------------------------------

/// Rewrite an Annex B stream so every start code is the 4-byte form (§5.1
/// forbids 3-byte codes on the wire). Encoders such as x264 emit 3-byte codes
/// for all but the first NAL of a picture.
pub fn normalize_start_codes(annexb: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(annexb.len() + 16);
    let mut i = 0;
    let n = annexb.len();
    let mut in_nal = false;
    while i < n {
        if i + 3 <= n && annexb[i] == 0 && annexb[i + 1] == 0 {
            if annexb[i + 2] == 1 {
                out.extend_from_slice(&START_CODE);
                i += 3;
                in_nal = true;
                continue;
            }
            if i + 4 <= n && annexb[i + 2] == 0 && annexb[i + 3] == 1 {
                out.extend_from_slice(&START_CODE);
                i += 4;
                in_nal = true;
                continue;
            }
        }
        if in_nal {
            out.push(annexb[i]);
        }
        i += 1;
    }
    // Trailing zero bytes before a start code belong to the start code in
    // Annex B (trailing_zero_8bits); drop them from the last NAL so a
    // 3-byte code preceded by 00 does not leave a stray zero behind.
    while out.len() > 4 && out.ends_with(&[0]) && !out.ends_with(&START_CODE) {
        out.pop();
    }
    out
}

/// One access unit (one picture), assembled from a raw Annex B stream and
/// ready to become a wire frame. Start codes are 4 bytes; IDR access units
/// carry SPS and PPS (§5.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccessUnit {
    pub annexb: Vec<u8>,
    pub is_idr: bool,
}

/// Split an Annex B stream (3- or 4-byte start codes, x264/ffmpeg style) into
/// access units. A new picture starts at a VCL NAL whose `first_mb_in_slice`
/// is 0 (the first Exp-Golomb bit after the NAL header is 1) — so multi-slice
/// pictures stay together — or at an access unit delimiter. Non-VCL NALs
/// (SPS, PPS, SEI) attach to the picture that follows them. Every IDR unit is
/// guaranteed to start with the most recent SPS and PPS.
pub fn access_units(raw: &[u8]) -> Vec<AccessUnit> {
    let stream = normalize_start_codes(raw);
    let mut units = Vec::new();
    let mut current: Vec<u8> = Vec::new();
    let mut current_has_vcl = false;
    let mut current_is_idr = false;
    let mut current_has_sps = false;
    let mut current_has_pps = false;
    let (mut last_sps, mut last_pps): (Option<Vec<u8>>, Option<Vec<u8>>) = (None, None);

    let flush = |current: &mut Vec<u8>,
                 is_idr: bool,
                 has_sps: bool,
                 has_pps: bool,
                 units: &mut Vec<AccessUnit>,
                 last_sps: &Option<Vec<u8>>,
                 last_pps: &Option<Vec<u8>>| {
        if current.is_empty() {
            return;
        }
        let mut annexb = Vec::with_capacity(current.len() + 64);
        if is_idr {
            if !has_sps {
                if let Some(s) = last_sps {
                    annexb.extend_from_slice(&START_CODE);
                    annexb.extend_from_slice(s);
                }
            }
            if !has_pps {
                if let Some(p) = last_pps {
                    annexb.extend_from_slice(&START_CODE);
                    annexb.extend_from_slice(p);
                }
            }
        }
        annexb.extend_from_slice(current);
        units.push(AccessUnit { annexb, is_idr });
        current.clear();
    };

    for nal in nal_units(&stream) {
        let ty = NalType::of(nal);
        let first_mb_zero = nal.len() > 1 && (nal[1] & 0x80) != 0;
        let starts_new_picture = match ty {
            Some(NalType::AccessUnitDelimiter) => current_has_vcl,
            Some(t) if t.is_vcl() => current_has_vcl && first_mb_zero,
            // A parameter set after slice data belongs to the next picture.
            Some(NalType::Sps | NalType::Pps | NalType::Sei) => current_has_vcl,
            _ => false,
        };
        if starts_new_picture {
            flush(
                &mut current,
                current_is_idr,
                current_has_sps,
                current_has_pps,
                &mut units,
                &last_sps,
                &last_pps,
            );
            current_has_vcl = false;
            current_is_idr = false;
            current_has_sps = false;
            current_has_pps = false;
        }
        match ty {
            Some(NalType::Sps) => {
                last_sps = Some(nal.to_vec());
                current_has_sps = true;
            }
            Some(NalType::Pps) => {
                last_pps = Some(nal.to_vec());
                current_has_pps = true;
            }
            Some(NalType::IdrSlice) => {
                current_has_vcl = true;
                current_is_idr = true;
            }
            Some(t) if t.is_vcl() => current_has_vcl = true,
            _ => {}
        }
        current.extend_from_slice(&START_CODE);
        current.extend_from_slice(nal);
    }
    flush(
        &mut current,
        current_is_idr,
        current_has_sps,
        current_has_pps,
        &mut units,
        &last_sps,
        &last_pps,
    );
    units
}

#[cfg(test)]
mod tests {
    use super::*;

    // SPS from testdata/clip-320x180-30.h264 (x264, High profile, 320x180 -> 192 coded, cropped).
    const SPS_320X180: &[u8] = &[
        0x67, 0x42, 0xc0, 0x0d, 0xda, 0x05, 0x06, 0x7e, 0x7c, 0x04, 0x40, 0x00, 0x00, 0x03, 0x00,
        0x40, 0x00, 0x00, 0x0f, 0x23, 0xc5, 0x0a, 0xa8,
    ];

    #[test]
    fn sps_dimensions_with_cropping_and_emulation_prevention() {
        let info = SpsInfo::parse(SPS_320X180).unwrap();
        assert_eq!((info.width, info.height), (320, 180));
        assert_eq!(info.profile_idc, 66);
    }

    #[test]
    fn parses_telemetry_and_nals() {
        let mut payload = b"{\"cap\":100.5,\"snd\":101}".to_vec();
        payload.extend_from_slice(&START_CODE);
        payload.extend_from_slice(SPS_320X180);
        payload.extend_from_slice(&START_CODE);
        payload.extend_from_slice(&[0x68, 0xce, 0x38, 0x80]);
        payload.extend_from_slice(&START_CODE);
        payload.extend_from_slice(&[0x65, 0x88, 0x84, 0x00]);
        let f = VideoFrame::parse(&payload).unwrap();
        assert_eq!(
            f.telemetry,
            Telemetry {
                cap: Some(100.5),
                snd: Some(101.0)
            }
        );
        assert!(f.is_idr);
        assert_eq!(f.sps, Some(SPS_320X180));
        assert_eq!(f.pps.map(|p| p[0]), Some(0x68));
        assert_eq!(f.sps_info().unwrap().unwrap().width, 320);
    }

    #[test]
    fn missing_or_garbage_telemetry_is_tolerated() {
        let mut payload = START_CODE.to_vec();
        payload.extend_from_slice(&[0x41, 0x9a]);
        assert_eq!(
            VideoFrame::parse(&payload).unwrap().telemetry,
            Telemetry::default()
        );
        let mut payload = b"{not json".to_vec();
        payload.extend_from_slice(&START_CODE);
        payload.extend_from_slice(&[0x41, 0x9a]);
        assert_eq!(
            VideoFrame::parse(&payload).unwrap().telemetry,
            Telemetry::default()
        );
        assert_eq!(
            VideoFrame::parse(b"{\"cap\":1}"),
            Err(VideoFrameError::NoStartCode)
        );
    }

    #[test]
    fn parameter_set_tracker_reports_first_and_changes() {
        let mk = |sps_tail: u8| {
            let mut p = START_CODE.to_vec();
            p.extend_from_slice(SPS_320X180);
            p.push(sps_tail);
            p.extend_from_slice(&START_CODE);
            p.extend_from_slice(&[0x68, 0xce, 0x38, 0x80]);
            p.extend_from_slice(&START_CODE);
            p.extend_from_slice(&[0x65, 0x88]);
            p
        };
        let a = mk(1);
        let b = mk(2);
        let mut t = ParameterSetTracker::default();
        assert_eq!(
            t.observe(&VideoFrame::parse(&a).unwrap()),
            ParameterSetChange::First
        );
        assert_eq!(
            t.observe(&VideoFrame::parse(&a).unwrap()),
            ParameterSetChange::Unchanged
        );
        let mut p_only = START_CODE.to_vec();
        p_only.extend_from_slice(&[0x41, 0x9a]);
        assert_eq!(
            t.observe(&VideoFrame::parse(&p_only).unwrap()),
            ParameterSetChange::Unchanged
        );
        assert_eq!(
            t.observe(&VideoFrame::parse(&b).unwrap()),
            ParameterSetChange::Changed
        );
    }

    #[test]
    fn normalizes_three_byte_start_codes() {
        let raw = [
            0, 0, 0, 1, 0x67, 0xaa, 0, 0, 1, 0x68, 0xbb, 0, 0, 0, 1, 0x65, 0xcc, 0, 0, 1, 0x65,
            0xdd,
        ];
        let n = normalize_start_codes(&raw);
        let nals: Vec<&[u8]> = nal_units(&n).collect();
        assert_eq!(
            nals,
            vec![
                &[0x67, 0xaa][..],
                &[0x68, 0xbb],
                &[0x65, 0xcc],
                &[0x65, 0xdd]
            ]
        );
        assert!(
            !n.windows(3).any(|w| w == [0, 0, 1] && true)
                || n.windows(4).filter(|w| *w == START_CODE).count() == 4
        );
    }

    #[test]
    fn access_units_group_slices_and_carry_parameter_sets_on_idr() {
        // SPS, PPS, IDR (2 slices), P (2 slices), IDR without its own SPS/PPS.
        let sps = [0x67, 0x42];
        let pps = [0x68, 0xce];
        let idr_a = [0x65, 0x88]; // first_mb_in_slice == 0 (bit 1)
        let idr_b = [0x65, 0x08]; // first_mb_in_slice != 0
        let p_a = [0x41, 0x9a];
        let p_b = [0x41, 0x1a];
        let mut raw = Vec::new();
        for nal in [&sps[..], &pps, &idr_a, &idr_b, &p_a, &p_b, &idr_a] {
            raw.extend_from_slice(&[0, 0, 1]);
            raw.extend_from_slice(nal);
        }
        let units = access_units(&raw);
        assert_eq!(units.len(), 3);
        assert!(units[0].is_idr && !units[1].is_idr && units[2].is_idr);
        let nals: Vec<Vec<u8>> = nal_units(&units[0].annexb).map(|n| n.to_vec()).collect();
        assert_eq!(
            nals,
            vec![sps.to_vec(), pps.to_vec(), idr_a.to_vec(), idr_b.to_vec()]
        );
        let nals: Vec<Vec<u8>> = nal_units(&units[1].annexb).map(|n| n.to_vec()).collect();
        assert_eq!(nals, vec![p_a.to_vec(), p_b.to_vec()]);
        // The bare IDR was given the last SPS/PPS.
        let nals: Vec<Vec<u8>> = nal_units(&units[2].annexb).map(|n| n.to_vec()).collect();
        assert_eq!(nals, vec![sps.to_vec(), pps.to_vec(), idr_a.to_vec()]);
        // And every unit round-trips through the receiver-side parser.
        for u in &units {
            let f = VideoFrame::parse(&u.annexb).unwrap();
            assert_eq!(f.is_idr, u.is_idr);
        }
    }
}
