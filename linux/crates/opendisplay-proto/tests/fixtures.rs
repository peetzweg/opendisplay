//! Tests against real x264 output in `linux/testdata/` — mixed 3/4-byte start
//! codes, multiple slices per picture, SPS/PPS only on the first IDR.

use opendisplay_proto::video::{START_CODE, SpsInfo, VideoFrame, access_units, nal_units};
use opendisplay_proto::{Channel, classify};

fn clip(name: &str) -> Vec<u8> {
    std::fs::read(format!(
        "{}/../../testdata/{name}",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn check_clip(name: &str, expected_units: usize, keyint: usize, dims: (u32, u32)) {
    let units = access_units(&clip(name));
    assert_eq!(units.len(), expected_units, "{name}: access units");
    for (i, u) in units.iter().enumerate() {
        assert_eq!(u.is_idr, i % keyint == 0, "{name}: unit {i} idr flag");
        assert!(u.annexb.starts_with(&START_CODE));
        // No 3-byte start codes survive: every `00 00 01` is preceded by `00`.
        for w in 3..u.annexb.len() {
            if u.annexb[w - 2..=w] == [0, 0, 1] {
                assert_eq!(u.annexb[w - 3], 0, "{name}: 3-byte start code in unit {i}");
            }
        }
        assert_eq!(classify(&u.annexb), Channel::Video);
        let f = VideoFrame::parse(&u.annexb).unwrap();
        assert_eq!(f.is_idr, u.is_idr);
        if u.is_idr {
            let sps = f.sps.expect("IDR carries SPS");
            assert!(f.pps.is_some(), "IDR carries PPS");
            let info = SpsInfo::parse(sps).unwrap();
            assert_eq!((info.width, info.height), dims, "{name}: SPS dims");
        } else {
            assert!(
                f.sps.is_none() && f.pps.is_none(),
                "{name}: P-frame {i} carries parameter sets"
            );
        }
        assert!(nal_units(&u.annexb).count() >= 1);
    }
}

#[test]
fn clip_320x180_two_gops() {
    check_clip("clip-320x180-30.h264", 60, 30, (320, 180));
}

#[test]
fn clip_640x360_one_gop() {
    check_clip("clip-640x360-30.h264", 30, 30, (640, 360));
}

#[test]
fn concatenated_clips_are_a_stream_change() {
    let mut raw = clip("clip-320x180-30.h264");
    raw.extend(clip("clip-640x360-30.h264"));
    let units = access_units(&raw);
    assert_eq!(units.len(), 90);
    let mut tracker = opendisplay_proto::video::ParameterSetTracker::default();
    let mut changes = Vec::new();
    for u in &units {
        let f = VideoFrame::parse(&u.annexb).unwrap();
        changes.push(tracker.observe(&f));
    }
    use opendisplay_proto::video::ParameterSetChange::*;
    assert_eq!(changes[0], First);
    assert_eq!(
        changes[30], Unchanged,
        "same SPS/PPS repeated on the second IDR"
    );
    assert_eq!(changes[60], Changed, "new resolution");
    assert!(changes.iter().filter(|c| **c == Changed).count() == 1);
}
