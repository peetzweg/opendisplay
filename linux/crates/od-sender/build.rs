//! `OD_SENDER_VERSION` for `od-sender --version` and `doctor`: the
//! `vX.Y.Z` release tag, see `../build-version.rs`.

include!("../build-version.rs");

fn main() {
    emit_version("OD_SENDER_VERSION");
}
