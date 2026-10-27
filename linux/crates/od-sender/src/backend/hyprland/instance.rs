//! `--instance <sig|index>`: pick one of several running Hyprland instances
//! the way `hyprctl -i` does, from the directories under
//! `$XDG_RUNTIME_DIR/hypr/` (each has `hyprland.lock`: pid, then the
//! Wayland socket name). Indices count from the oldest instance.

use std::path::Path;

use anyhow::{Context, Result, bail};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instance {
    pub signature: String,
    pub pid: u32,
    pub wl_socket: String,
    /// Start time from the signature (`<hash>_<time>_<rand>`), for ordering.
    pub time: u64,
}

/// Every instance with a readable lock file, oldest first.
pub fn list(runtime_dir: &Path) -> Result<Vec<Instance>> {
    let dir = runtime_dir.join("hypr");
    let mut out = Vec::new();
    let entries = std::fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))?;
    for entry in entries.flatten() {
        let signature = entry.file_name().to_string_lossy().into_owned();
        let Ok(lock) = std::fs::read_to_string(entry.path().join("hyprland.lock")) else {
            continue;
        };
        let mut lines = lock.lines();
        let (Some(pid), Some(wl_socket)) = (
            lines.next().and_then(|p| p.trim().parse().ok()),
            lines.next(),
        ) else {
            continue;
        };
        let time = signature
            .split('_')
            .nth(1)
            .and_then(|t| t.parse().ok())
            .unwrap_or(0);
        out.push(Instance {
            signature,
            pid,
            wl_socket: wl_socket.trim().to_string(),
            time,
        });
    }
    out.sort_by(|a, b| (a.time, &a.signature).cmp(&(b.time, &b.signature)));
    Ok(out)
}

/// Resolve `sig_or_index` against the instances under `runtime_dir`. A
/// signature must match exactly, so a typo fails instead of landing on
/// another session.
pub fn resolve(runtime_dir: &Path, sig_or_index: &str) -> Result<Instance> {
    let all = list(runtime_dir)?;
    let describe = || {
        all.iter()
            .enumerate()
            .map(|(i, x)| format!("{i}: {} ({})", x.signature, x.wl_socket))
            .collect::<Vec<_>>()
            .join(", ")
    };
    if let Ok(i) = sig_or_index.parse::<usize>() {
        return match all.get(i) {
            Some(x) => Ok(x.clone()),
            None => bail!("no Hyprland instance {i}; running: [{}]", describe()),
        };
    }
    match all.iter().find(|x| x.signature == sig_or_index) {
        Some(x) => Ok(x.clone()),
        None => bail!(
            "no Hyprland instance {sig_or_index:?}; running: [{}]",
            describe()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_runtime(tag: &str, instances: &[(&str, &str)]) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("od-inst-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for (sig, lock) in instances {
            let d = root.join("hypr").join(sig);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("hyprland.lock"), lock).unwrap();
        }
        root
    }

    #[test]
    fn index_counts_from_the_oldest_and_signatures_match_exactly() {
        let rt = fake_runtime(
            "resolve",
            &[
                ("efb5_1792492358_1013631050", "45373\nwayland-2\n"),
                ("efb5_1791974227_723898458", "1217\nwayland-1\n"),
                ("stale_without_lock", ""),
            ],
        );
        std::fs::remove_file(rt.join("hypr/stale_without_lock/hyprland.lock")).unwrap();
        let first = resolve(&rt, "0").unwrap();
        assert_eq!((first.pid, first.wl_socket.as_str()), (1217, "wayland-1"));
        let nested = resolve(&rt, "efb5_1792492358_1013631050").unwrap();
        assert_eq!(nested.wl_socket, "wayland-2");
        assert_eq!(resolve(&rt, "1").unwrap(), nested);
        let err = resolve(&rt, "efb5_1792492358").unwrap_err().to_string();
        assert!(err.contains("running: [0: efb5_1791974227"), "{err}");
        assert!(resolve(&rt, "2").is_err());
        let _ = std::fs::remove_dir_all(rt);
    }
}
