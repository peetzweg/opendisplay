//! Annex B helpers (PROTOCOL.md §5.1): telemetry prefix and parameter-set scanning. No allocation.

use serde::Deserialize;

const START: [u8; 4] = [0, 0, 0, 1];

fn find_start(d: &[u8], from: usize) -> Option<usize> {
    d.get(from..)?
        .windows(4)
        .position(|w| w == START)
        .map(|i| i + from)
}

/// Splits a video payload into (telemetry prefix, Annex B data from the first 4-byte start code).
pub fn split_prefix(payload: &[u8]) -> (&[u8], &[u8]) {
    match find_start(payload, 0) {
        Some(i) => payload.split_at(i),
        None => (payload, &[]),
    }
}

/// `{"cap","snd"}` stamped by the sender, ms since epoch on the sender clock.
#[derive(Debug, Deserialize, PartialEq)]
pub struct Telemetry {
    pub cap: Option<f64>,
    pub snd: Option<f64>,
}

pub fn telemetry(prefix: &[u8]) -> Option<Telemetry> {
    if prefix.is_empty() {
        None
    } else {
        serde_json::from_slice(prefix).ok()
    }
}

#[derive(Debug, Default, PartialEq)]
pub struct AuInfo<'a> {
    pub idr: bool,
    pub sps: Option<&'a [u8]>,
    pub pps: Option<&'a [u8]>,
}

/// Reads NAL types up to the first slice. Parameter sets precede slices (§5.1), so the slice
/// data itself is never scanned.
pub fn scan(annexb: &[u8]) -> AuInfo<'_> {
    let mut info = AuInfo::default();
    let mut pos = find_start(annexb, 0);
    while let Some(p) = pos {
        let s = p + 4;
        let Some(&h) = annexb.get(s) else { break };
        let t = h & 0x1f;
        if t == 1 || t == 5 {
            info.idr = t == 5;
            break;
        }
        let next = find_start(annexb, s);
        let nal = &annexb[s..next.unwrap_or(annexb.len())];
        match t {
            7 if info.sps.is_none() => info.sps = Some(nal),
            8 if info.pps.is_none() => info.pps = Some(nal),
            _ => {}
        }
        pos = next;
    }
    info
}

/// Splits an Annex B stream (3- or 4-byte start codes) into access units, each re-emitted with
/// 4-byte start codes as the spec requires (§5.1). Returns (is_idr, bytes).
pub fn access_units(data: &[u8]) -> Vec<(bool, Vec<u8>)> {
    let mut starts = Vec::new(); // index of the first NAL byte after each start code
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i..i + 3] == [0, 0, 1] {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut aus = Vec::new();
    let (mut cur, mut has_slice, mut idr) = (Vec::new(), false, false);
    for (k, &s) in starts.iter().enumerate() {
        let end = starts.get(k + 1).map_or(data.len(), |&n| n - 3);
        // Trailing zeros belong to the next 4-byte start code (a NAL never ends in 0x00).
        let nal = &data[s..end];
        let nal = &nal[..nal.iter().rposition(|&b| b != 0).map_or(0, |p| p + 1)];
        let Some(&h) = nal.first() else { continue };
        let t = h & 0x1f;
        // first_mb_in_slice == 0 is ue(v) "1", i.e. the top bit of the first slice-header byte.
        let first_slice = matches!(t, 1 | 5) && nal.get(1).is_some_and(|b| b & 0x80 != 0);
        if has_slice && (first_slice || matches!(t, 6..=9)) {
            aus.push((idr, std::mem::take(&mut cur)));
            (has_slice, idr) = (false, false);
        }
        has_slice |= matches!(t, 1 | 5);
        idr |= t == 5;
        cur.extend_from_slice(&[0, 0, 0, 1]);
        cur.extend_from_slice(nal);
    }
    if !cur.is_empty() {
        aus.push((idr, cur));
    }
    aus
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_and_idr_with_parameter_sets() {
        let p = b"{\"cap\":10,\"snd\":12.5,\"new\":1}\x00\x00\x00\x01\x67\x42\x00\x1f\x00\x00\x00\x01\x68\xce\x00\x00\x00\x01\x06\x05\x00\x00\x00\x01\x65\x88\x00\x00\x00\x01\x65\x99";
        let (prefix, annexb) = split_prefix(p);
        assert_eq!(
            telemetry(prefix),
            Some(Telemetry {
                cap: Some(10.0),
                snd: Some(12.5)
            })
        );
        assert_eq!(&annexb[..4], &START);
        assert_eq!(
            scan(annexb),
            AuInfo {
                idr: true,
                sps: Some(&[0x67, 0x42, 0x00, 0x1f][..]),
                pps: Some(&[0x68, 0xce][..])
            }
        );
    }

    #[test]
    fn no_prefix_p_frame() {
        let p = [0, 0, 0, 1, 0x41, 0x9a, 0x00, 0x01];
        let (prefix, annexb) = split_prefix(&p);
        assert!(prefix.is_empty() && telemetry(prefix).is_none());
        assert_eq!(scan(annexb), AuInfo::default());
    }

    #[test]
    fn garbage_is_harmless() {
        assert_eq!(
            split_prefix(b"{\"cap\":1}"),
            (&b"{\"cap\":1}"[..], &b""[..])
        );
        assert_eq!(scan(&[0, 0, 0, 1]), AuInfo::default());
        assert_eq!(telemetry(b"not json"), None);
    }

    #[test]
    fn groups_nals_into_access_units() {
        let stream = [
            &[0, 0, 0, 1, 0x67, 0x42][..],   // SPS
            &[0, 0, 1, 0x68, 0xce],          // PPS (3-byte start code)
            &[0, 0, 1, 0x65, 0x88, 0x01],    // IDR slice, first_mb 0
            &[0, 0, 1, 0x65, 0x22, 0x02],    // IDR slice, first_mb != 0: same picture
            &[0, 0, 0, 1, 0x41, 0x9a, 0x00], // P slice, first_mb 0, trailing zero
            &[0, 0, 0, 1, 0x41, 0x9b],       // next P picture
        ]
        .concat();
        let aus = access_units(&stream);
        assert_eq!(aus.len(), 3);
        assert!(aus[0].0 && !aus[1].0 && !aus[2].0);
        assert_eq!(
            aus[0].1,
            [
                0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xce, 0, 0, 0, 1, 0x65, 0x88, 0x01, 0, 0,
                0, 1, 0x65, 0x22, 0x02
            ]
        );
        assert_eq!(aus[1].1, [0, 0, 0, 1, 0x41, 0x9a]);
    }
}
