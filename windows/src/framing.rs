//! Length-prefixed framing (PROTOCOL.md §3) and the sender-to-receiver demux (§4).

use std::io::{self, Read};

/// Receiver-to-sender payloads must be 1..=2^20-1 bytes (§3).
pub const MAX_OUTBOUND: usize = (1 << 20) - 1;
/// shortcut: the spec has no sender-to-receiver maximum; 32 MiB bounds memory against garbage. Raise if real keyframes approach it.
pub const MAX_INBOUND: usize = 32 << 20;

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    /// Inbound length header exceeds MAX_INBOUND; the connection should be dropped.
    Oversize(usize),
    /// Outbound payload length outside 1..=MAX_OUTBOUND.
    BadOutboundLen(usize),
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameKind {
    Control,
    Video,
}

/// The pv <= 3 demux heuristic (§4). The only place this decision is made: pv 4 replaces it with a typed header.
pub fn classify(payload: &[u8]) -> FrameKind {
    if payload.len() < 32768 && payload.first() == Some(&b'{') && !payload.contains(&0) {
        FrameKind::Control
    } else {
        FrameKind::Video
    }
}

/// Reassembles inbound frames from a TCP byte stream. The buffer grows to the largest
/// frame seen and is then reused, so steady-state reading does not allocate.
pub struct FrameReader {
    buf: Vec<u8>,
    start: usize,
    end: usize,
}

impl Default for FrameReader {
    fn default() -> Self {
        Self {
            buf: vec![0; 256 * 1024],
            start: 0,
            end: 0,
        }
    }
}

impl FrameReader {
    /// One read from `r` into the buffer. Returns the byte count (0 means EOF).
    pub fn read_from<R: Read>(&mut self, r: &mut R) -> io::Result<usize> {
        self.make_room();
        let n = r.read(&mut self.buf[self.end..])?;
        self.end += n;
        Ok(n)
    }

    /// Next complete payload, if one is buffered. Call until `Ok(None)` after each read.
    pub fn next_frame(&mut self) -> Result<Option<&[u8]>, FrameError> {
        let Some(len) = self.header() else {
            return Ok(None);
        };
        if len > MAX_INBOUND {
            return Err(FrameError::Oversize(len));
        }
        let begin = self.start + 4;
        if self.end - begin < len {
            return Ok(None);
        }
        self.start = begin + len;
        Ok(Some(&self.buf[begin..self.start]))
    }

    fn header(&self) -> Option<usize> {
        (self.end - self.start >= 4).then(|| {
            u32::from_be_bytes(self.buf[self.start..self.start + 4].try_into().unwrap()) as usize
        })
    }

    /// Ensures the pending frame fits from `start` and there is space to read into.
    fn make_room(&mut self) {
        let pending = self.end - self.start;
        let frame = self.header().map_or(4, |n| 4 + n.min(MAX_INBOUND));
        let need = frame.max(pending + 1);
        if self.buf.len() - self.start < need || self.end == self.buf.len() {
            self.buf.copy_within(self.start..self.end, 0);
            self.start = 0;
            self.end = pending;
        }
        if self.buf.len() < need {
            self.buf.resize(need, 0);
        }
    }
}

/// Appends one receiver-to-sender frame to `out`.
pub fn write_frame(out: &mut Vec<u8>, payload: &[u8]) -> Result<(), FrameError> {
    if payload.is_empty() || payload.len() > MAX_OUTBOUND {
        return Err(FrameError::BadOutboundLen(payload.len()));
    }
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(payload: &[u8]) -> Vec<u8> {
        let mut v = (payload.len() as u32).to_be_bytes().to_vec();
        v.extend_from_slice(payload);
        v
    }

    /// Feeds `chunks` one read at a time and collects every frame produced.
    fn feed(fr: &mut FrameReader, chunks: &[&[u8]]) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        for chunk in chunks {
            let mut c = *chunk;
            while !c.is_empty() {
                fr.read_from(&mut c).unwrap();
                while let Some(f) = fr.next_frame().unwrap() {
                    out.push(f.to_vec());
                }
            }
        }
        out
    }

    #[test]
    fn split_reads_byte_by_byte() {
        let wire = [
            frame(b"{\"type\":\"ping\"}"),
            frame(&[0, 0, 0, 1, 0x65, 0xaa]),
        ]
        .concat();
        let chunks: Vec<&[u8]> = wire.chunks(1).collect();
        let got = feed(&mut FrameReader::default(), &chunks);
        assert_eq!(
            got,
            vec![
                b"{\"type\":\"ping\"}".to_vec(),
                vec![0, 0, 0, 1, 0x65, 0xaa]
            ]
        );
    }

    #[test]
    fn split_inside_header_and_payload() {
        let wire = frame(b"hello world");
        let got = feed(
            &mut FrameReader::default(),
            &[&wire[..2], &wire[2..7], &wire[7..]],
        );
        assert_eq!(got, vec![b"hello world".to_vec()]);
    }

    #[test]
    fn packed_reads() {
        let wire = [
            frame(b"a"),
            frame(b"bb"),
            frame(b""),
            frame(b"ccc"),
            frame(b"dd")[..3].to_vec(),
        ]
        .concat();
        let mut fr = FrameReader::default();
        let got = feed(&mut fr, &[&wire]);
        assert_eq!(
            got,
            vec![b"a".to_vec(), b"bb".to_vec(), vec![], b"ccc".to_vec()]
        );
        // The trailing partial frame completes on the next read.
        assert_eq!(feed(&mut fr, &[&frame(b"dd")[3..]]), vec![b"dd".to_vec()]);
    }

    #[test]
    fn frame_larger_than_initial_buffer_then_reuse() {
        let big = vec![7u8; 3 * 1024 * 1024];
        let wire = [frame(&big), frame(b"x")].concat();
        let chunks: Vec<&[u8]> = wire.chunks(64 * 1024 + 3).collect();
        let mut fr = FrameReader::default();
        let got = feed(&mut fr, &chunks);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0], big);
        assert_eq!(got[1], b"x");
        let cap = fr.buf.len();
        feed(&mut fr, &chunks);
        assert_eq!(fr.buf.len(), cap, "steady state must not grow the buffer");
    }

    #[test]
    fn oversize_inbound_is_an_error() {
        let mut fr = FrameReader::default();
        let hdr = ((MAX_INBOUND + 1) as u32).to_be_bytes();
        fr.read_from(&mut &hdr[..]).unwrap();
        assert_eq!(fr.next_frame(), Err(FrameError::Oversize(MAX_INBOUND + 1)));
        // Exactly the max is fine (header only, so still incomplete).
        let mut fr = FrameReader::default();
        fr.read_from(&mut &(MAX_INBOUND as u32).to_be_bytes()[..])
            .unwrap();
        assert_eq!(fr.next_frame(), Ok(None));
    }

    #[test]
    fn outbound_length_limits() {
        let mut out = Vec::new();
        assert_eq!(
            write_frame(&mut out, b""),
            Err(FrameError::BadOutboundLen(0))
        );
        let too_big = vec![b'x'; MAX_OUTBOUND + 1];
        assert_eq!(
            write_frame(&mut out, &too_big),
            Err(FrameError::BadOutboundLen(1 << 20))
        );
        assert!(out.is_empty());
        write_frame(&mut out, &too_big[..MAX_OUTBOUND]).unwrap();
        assert_eq!(&out[..4], &[0x00, 0x0f, 0xff, 0xff]);
        assert_eq!(out.len(), 4 + MAX_OUTBOUND);
    }

    #[test]
    fn demux_rule() {
        use FrameKind::*;
        assert_eq!(classify(b"{\"type\":\"pong\",\"t\":1,\"mt\":2}"), Control);
        // Telemetry prefix starts with '{' but the start code has NULs.
        assert_eq!(
            classify(b"{\"cap\":1,\"snd\":2}\x00\x00\x00\x01\x67"),
            Video
        );
        assert_eq!(classify(&[0, 0, 0, 1, 0x65]), Video);
        assert_eq!(classify(b"[1,2]"), Video);
        assert_eq!(classify(b""), Video);
        // Length boundary: 32767 bytes is control, 32768 is video.
        let mut p = vec![b' '; 32767];
        p[0] = b'{';
        assert_eq!(classify(&p), Control);
        p.push(b' ');
        assert_eq!(classify(&p), Video);
    }
}
