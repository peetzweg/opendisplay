//! Sans-I/O session state machines for both OpenDisplay roles.
//!
//! Neither [`receiver::ReceiverSession`] nor [`sender::SenderSession`] owns a
//! socket, a timer, a decoder or an encoder. The host feeds them events
//! (bytes arrived, time passed, decoder lost sync, an encoded frame is ready)
//! and executes the actions they return (write these bytes, reset the decoder,
//! decode this access unit, make the next frame an IDR, close). That keeps the
//! protocol logic testable on any machine and shared between the Linux
//! binaries and any future receiver or sender.
//!
//! Section references are to `PROTOCOL.md`.

pub mod clock;
pub mod cursor;
pub mod receiver;
pub mod sender;

use std::time::Duration;

/// The host's view of time at the moment an event is handled.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Now {
    /// Monotonic time since an arbitrary origin (e.g. process start).
    pub mono: Duration,
    /// Milliseconds since the Unix epoch on this machine's wall clock, as the
    /// protocol's `t`/`mt`/`cap`/`snd` fields want it (§6, §8.1).
    pub wall_ms: f64,
}

impl Now {
    pub fn new(mono: Duration, wall_ms: f64) -> Self {
        Self { mono, wall_ms }
    }
}

/// Why a session decided the connection is over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloseReason {
    /// No bytes from the peer for longer than the liveness window (§8.2).
    Timeout,
    /// The byte stream is unrecoverable (§3).
    Framing(opendisplay_proto::FramingError),
    /// The peer said goodbye (`closing`, or the sender declared the pairing unsupported).
    Peer(String),
}

/// Both official apps send theirs every 2 s (§8.2).
pub const PING_INTERVAL: Duration = Duration::from_secs(2);
/// Both official apps treat > 5 s of silence as death (§8.2).
pub const LIVENESS_TIMEOUT: Duration = Duration::from_secs(5);
