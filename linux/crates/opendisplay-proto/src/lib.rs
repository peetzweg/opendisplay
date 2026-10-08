//! The OpenDisplay wire protocol, as specified in `PROTOCOL.md` (`pv` 3).
//!
//! This crate is deliberately sans-I/O and platform-free: it turns bytes into
//! frames, frames into video or control messages, and control messages back
//! into bytes. Everything that touches a socket, a decoder, a display or a
//! clock lives in other crates. Section numbers in doc comments refer to
//! `PROTOCOL.md`.

pub mod control;
pub mod demux;
pub mod framing;
pub mod version;
pub mod video;

pub use control::ControlMessage;
pub use demux::{Channel, classify};
pub use framing::{Deframer, FramingError, encode_frame};
pub use video::{VideoFrame, VideoFrameError};

/// TCP port the receiver listens on (§1).
pub const DEFAULT_PORT: u16 = 9000;
/// UDP port the official receiver uses for the cursor side channel (§6.3).
pub const DEFAULT_CURSOR_PORT: u16 = 9001;
/// Bonjour service type (§2.1). Historical name, never rename.
pub const SERVICE_TYPE: &str = "_opensidecar._tcp";
