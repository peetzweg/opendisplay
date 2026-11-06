//! OpenDisplay receiver for Windows: independent implementation of PROTOCOL.md (pv 3).

pub mod clock;
pub mod config;
pub mod control;
pub mod cursor;
pub mod framing;
pub mod h264;
pub mod mf;
pub mod monitor;
pub mod net;
pub mod present;
pub mod video;
pub mod window;

/// Protocol version this receiver speaks.
pub const PV: u32 = 3;
