//! `OD_RECEIVER_VERSION` for `od-receiver --version`: the `vX.Y.Z` release
//! tag, see `../build-version.rs`.

include!("../build-version.rs");

fn main() {
    emit_version("OD_RECEIVER_VERSION");
}
