use opendisplay_proto::control::{ControlMessage, Cursor, Pong, Welcome};
use opendisplay_proto::video::{START_CODE, nal_units, normalize_start_codes};
use opendisplay_proto::{Channel, Deframer, classify, encode_frame};
use proptest::prelude::*;

proptest! {
    /// §3: frames survive any read boundary pattern.
    #[test]
    fn deframer_is_chunking_invariant(
        frames in prop::collection::vec(prop::collection::vec(any::<u8>(), 1..2000), 0..12),
        cuts in prop::collection::vec(0usize..100, 0..40),
    ) {
        let mut wire = Vec::new();
        for f in &frames { wire.extend(encode_frame(f)); }
        let mut d = Deframer::for_receiver();
        let mut got = Vec::new();
        let mut pos = 0;
        for c in cuts {
            let end = (pos + c).min(wire.len());
            d.push(&wire[pos..end]);
            pos = end;
            while let Some(f) = d.next_frame().unwrap() { got.push(f); }
        }
        d.push(&wire[pos..]);
        while let Some(f) = d.next_frame().unwrap() { got.push(f); }
        prop_assert_eq!(got, frames);
        prop_assert_eq!(d.pending(), 0);
    }

    /// §4: anything with an Annex B start code in it is video, whatever it starts with.
    #[test]
    fn payload_with_start_code_is_video(prefix in "[^\\x00]{0,64}", tail in prop::collection::vec(any::<u8>(), 0..64)) {
        let mut p = prefix.into_bytes();
        p.extend_from_slice(&START_CODE);
        p.extend(tail);
        prop_assert_eq!(classify(&p), Channel::Video);
    }

    /// §4: every message we can emit routes to the control channel.
    #[test]
    fn emitted_control_messages_are_control(t in any::<f64>(), mt in any::<f64>(), x in 0.0f64..1.0, s in any::<u64>()) {
        prop_assume!(t.is_finite() && mt.is_finite());
        for m in [
            ControlMessage::Pong(Pong { t, mt }),
            ControlMessage::Cursor(Cursor { x: Some(x), y: Some(1.0 - x), v: 1, s: Some(s) }),
            ControlMessage::Welcome(Welcome { pv: 3, min: 1 }),
            ControlMessage::Kf,
        ] {
            let p = m.to_payload().unwrap();
            prop_assert_eq!(classify(&p), Channel::Control);
            prop_assert_eq!(ControlMessage::parse(&p).unwrap(), m);
        }
    }

    /// Start-code normalisation keeps NAL payloads and is idempotent.
    #[test]
    fn normalize_preserves_nals(nals in prop::collection::vec(prop::collection::vec(1u8..=255, 1..40), 1..8), four in prop::collection::vec(any::<bool>(), 8)) {
        let mut raw = Vec::new();
        for (i, n) in nals.iter().enumerate() {
            raw.extend_from_slice(if four[i] { &[0, 0, 0, 1][..] } else { &[0, 0, 1][..] });
            raw.extend_from_slice(n);
        }
        let norm = normalize_start_codes(&raw);
        let got: Vec<Vec<u8>> = nal_units(&norm).map(|n| n.to_vec()).collect();
        prop_assert_eq!(&got, &nals);
        prop_assert_eq!(normalize_start_codes(&norm), norm);
    }
}
