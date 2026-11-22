#!/usr/bin/env bash
# Test the real Mutter/layout modules without native capture/encoder libraries.
# This is not a PipeWire, D-Bus service, or end-to-end test.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
harness="$(mktemp -d "${TMPDIR:-/tmp}/od-gnome-api.XXXXXX")"
trap 'rm -rf "$harness"' EXIT
mkdir -p "$harness/src"
cat > "$harness/Cargo.toml" <<'TOML'
[package]
name = "od-gnome-api-tests"
version = "0.0.0"
edition = "2024"
[dependencies]
anyhow = "1"
serde = {version="1", features=["derive"]}
tracing = "0.1"
zbus = "=5.13.2"
async-io = "2.6"
futures-lite = "2.6"
TOML
# Reuse the project's dependency versions, including locked yanked releases.
cp "$repo/linux/Cargo.lock" "$harness/Cargo.lock"
cat > "$harness/src/lib.rs" <<RS
#![allow(dead_code)]
pub mod backend {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Position { AutoRight, AutoLeft, AutoUp, AutoDown, At(i32, i32) }
}
#[path = "$repo/linux/crates/od-sender/src/backend/gnome/mutter.rs"] mod mutter;
#[path = "$repo/linux/crates/od-sender/src/backend/gnome/layout.rs"] mod layout;
RS
cargo test --offline --manifest-path "$harness/Cargo.toml" \
  --target-dir "$repo/build/gnome-api-tests"
