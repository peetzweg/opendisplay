// Shared by the build scripts of od-sender and od-receiver (`include!`d, not
// a crate): the version a binary prints, from the app's `vX.Y.Z` release
// tags. Linux ships in lockstep with the Mac and iOS apps, so the tag
// release-please cuts for the app is the Linux version too.
//
// First of:
//
// 1. `$<env_var>` (OD_SENDER_VERSION / OD_RECEIVER_VERSION), set by the
//    release workflow and the PKGBUILDs (a tag tarball has no `.git`);
// 2. `git describe` against the `v*` tags: `1.26.0` on the tag,
//    `1.26.0-5-gabc1234` past it, `<crate version>-dev.abc1234` with no tag
//    in reach (a shallow clone);
// 3. the crate version (`[workspace.package] version`, which release-please
//    bumps with the tag).

fn git(args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git").args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Emits `cargo:rustc-env=<env_var>=<version>` (see above).
fn emit_version(env_var: &str) {
    println!("cargo:rerun-if-env-changed={env_var}");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../build-version.rs");
    let crate_version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    let from_env = std::env::var(env_var).ok().filter(|v| !v.trim().is_empty());
    let version = from_env
        .or_else(|| {
            // A new commit or checkout changes HEAD (or the branch's log).
            if let Some(dir) = git(&["rev-parse", "--absolute-git-dir"]) {
                println!("cargo:rerun-if-changed={dir}/HEAD");
                println!("cargo:rerun-if-changed={dir}/logs/HEAD");
            }
            // `v[0-9]*`, not `v*`: only release tags, never a branch-like tag.
            let d = git(&["describe", "--tags", "--match", "v[0-9]*", "--always"])?;
            Some(match d.strip_prefix('v') {
                Some(tagged) => tagged.to_string(),
                None => format!("{crate_version}-dev.{d}"),
            })
        })
        .unwrap_or(crate_version);
    println!("cargo:rustc-env={env_var}={version}");
}
