//! Length-prefixed framing (§3).
//!
//! `[4-byte payload length, unsigned, big-endian][payload]`, both directions.
//! TCP gives no message boundaries, so [`Deframer`] buffers and reassembles
//! across arbitrary read boundaries.

use thiserror::Error;

/// Receiver-to-sender payloads MUST be `1..=RECEIVER_TO_SENDER_MAX` bytes (§3).
/// The official sender treats anything else as a protocol error.
pub const RECEIVER_TO_SENDER_MAX: usize = (1 << 20) - 1;
/// Sender-to-receiver frames have no hard maximum in the spec; video frames
/// "SHOULD stay in the low megabytes". This is a sane default cap so a corrupt
/// length prefix cannot make a receiver allocate gigabytes.
pub const DEFAULT_SENDER_TO_RECEIVER_MAX: usize = 64 << 20;

#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum FramingError {
    #[error("frame length 0 is a protocol error")]
    ZeroLength,
    #[error("frame length {len} exceeds the maximum of {max}")]
    TooLarge { len: usize, max: usize },
}

/// Prefix `payload` with its 4-byte big-endian length.
pub fn encode_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Incremental frame reassembler. Feed it bytes as they arrive, drain frames
/// with [`Deframer::next_frame`].
///
/// A [`FramingError`] is sticky: once the stream is out of sync the only
/// sensible recovery is closing the connection.
#[derive(Debug)]
pub struct Deframer {
    buf: Vec<u8>,
    max_payload: usize,
    poisoned: Option<FramingError>,
}

impl Deframer {
    pub fn new(max_payload: usize) -> Self {
        Self {
            buf: Vec::new(),
            max_payload,
            poisoned: None,
        }
    }

    /// Deframer for the sender-to-receiver direction.
    pub fn for_receiver() -> Self {
        Self::new(DEFAULT_SENDER_TO_RECEIVER_MAX)
    }

    /// Deframer for the receiver-to-sender direction (§3 hard limits).
    pub fn for_sender() -> Self {
        Self::new(RECEIVER_TO_SENDER_MAX)
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// Bytes buffered but not yet returned as a frame.
    pub fn pending(&self) -> usize {
        self.buf.len()
    }

    /// Drop everything buffered (new connection, new session).
    pub fn reset(&mut self) {
        self.buf.clear();
        self.poisoned = None;
    }

    /// The next complete frame, if one is buffered.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, FramingError> {
        if let Some(e) = &self.poisoned {
            return Err(e.clone());
        }
        if self.buf.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_be_bytes([self.buf[0], self.buf[1], self.buf[2], self.buf[3]]) as usize;
        let err = if len == 0 {
            Some(FramingError::ZeroLength)
        } else if len > self.max_payload {
            Some(FramingError::TooLarge {
                len,
                max: self.max_payload,
            })
        } else {
            None
        };
        if let Some(e) = err {
            self.poisoned = Some(e.clone());
            return Err(e);
        }
        if self.buf.len() < 4 + len {
            return Ok(None);
        }
        let payload = self.buf[4..4 + len].to_vec();
        self.buf.drain(..4 + len);
        Ok(Some(payload))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_split_at_every_boundary() {
        let frames: Vec<Vec<u8>> = vec![
            vec![1],
            vec![2, 3, 4],
            vec![0; 1000],
            b"{\"type\":\"kf\"}".to_vec(),
        ];
        let mut wire = Vec::new();
        for f in &frames {
            wire.extend(encode_frame(f));
        }
        for split in 0..=wire.len() {
            let mut d = Deframer::for_receiver();
            d.push(&wire[..split]);
            let mut got = Vec::new();
            while let Some(f) = d.next_frame().unwrap() {
                got.push(f);
            }
            d.push(&wire[split..]);
            while let Some(f) = d.next_frame().unwrap() {
                got.push(f);
            }
            assert_eq!(got, frames, "split at {split}");
        }
    }

    #[test]
    fn zero_length_is_fatal_and_sticky() {
        let mut d = Deframer::for_sender();
        d.push(&[0, 0, 0, 0, 1, 2, 3]);
        assert_eq!(d.next_frame(), Err(FramingError::ZeroLength));
        assert_eq!(d.next_frame(), Err(FramingError::ZeroLength));
    }

    #[test]
    fn oversize_is_fatal_before_the_payload_arrives() {
        let mut d = Deframer::for_sender();
        d.push(&(1u32 << 20).to_be_bytes());
        assert!(matches!(d.next_frame(), Err(FramingError::TooLarge { .. })));
    }

    #[test]
    fn max_receiver_to_sender_payload_is_accepted() {
        let mut d = Deframer::for_sender();
        d.push(&encode_frame(&vec![7u8; RECEIVER_TO_SENDER_MAX]));
        assert_eq!(
            d.next_frame().unwrap().unwrap().len(),
            RECEIVER_TO_SENDER_MAX
        );
    }
}
