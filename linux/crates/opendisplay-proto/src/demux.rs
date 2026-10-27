//! Channel demux for sender-to-receiver frames (§4).
//!
//! This heuristic is design debt scheduled to be replaced by a typed frame
//! header at `pv` 4. It is isolated here so that swap is a one-function change;
//! nothing else in the workspace may look at payload bytes to decide the
//! channel.

/// Control messages are JSON only if strictly shorter than this (§4).
pub const CONTROL_MAX_LEN: usize = 32768;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    /// A JSON control message (§6).
    Control,
    /// An H.264 video frame (§5).
    Video,
}

/// A frame is a control message iff all three hold: `len < 32768`, first byte
/// is `{`, and no NUL byte anywhere. Anything else — including an empty
/// payload, which is a framing error upstream — is video.
pub fn classify(payload: &[u8]) -> Channel {
    if payload.len() < CONTROL_MAX_LEN && payload.first() == Some(&b'{') && !payload.contains(&0) {
        Channel::Control
    } else {
        Channel::Video
    }
}

/// Sender-side guard (§4, normative for senders): a control message MUST be
/// shorter than 32768 bytes, start with `{`, and contain no NUL.
pub fn is_valid_control_payload(payload: &[u8]) -> bool {
    classify(payload) == Channel::Control
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_is_control() {
        assert_eq!(classify(b"{\"type\":\"kf\"}"), Channel::Control);
    }

    #[test]
    fn video_starting_with_brace_is_video_because_of_start_code_nul() {
        // Telemetry prefix followed by an Annex B start code (§5.1).
        let mut f = b"{\"cap\":1,\"snd\":2}".to_vec();
        f.extend_from_slice(&[0, 0, 0, 1, 0x65, 0x88]);
        assert_eq!(classify(&f), Channel::Video);
    }

    #[test]
    fn long_json_is_video() {
        let mut f = b"{\"pad\":\"".to_vec();
        f.resize(CONTROL_MAX_LEN, b'a');
        assert_eq!(classify(&f), Channel::Video);
        f.truncate(CONTROL_MAX_LEN - 1);
        assert_eq!(classify(&f), Channel::Control);
    }

    #[test]
    fn empty_and_non_brace_are_video() {
        assert_eq!(classify(b""), Channel::Video);
        assert_eq!(classify(b"[1]"), Channel::Video);
    }
}
