//! Protocol versioning (§10).

/// The protocol version this crate implements.
pub const PV: u32 = 3;
/// The oldest peer version this implementation still talks to (`welcome.min`).
pub const MIN_PEER_PV: u32 = 1;
/// A peer that advertises no `pv` anywhere is protocol 1 (§10).
pub const IMPLICIT_PV: u32 = 1;

/// Resolve an optional advertised `pv` to the effective one.
pub fn effective_pv(advertised: Option<u32>) -> u32 {
    advertised.unwrap_or(IMPLICIT_PV)
}

/// Pencil fallback rule (§6.1): stylus messages may only go to senders at
/// `pv >= 3`; below that they degrade to `touch`.
pub fn sender_accepts_pencil(sender_pv: u32) -> bool {
    sender_pv >= 3
}
