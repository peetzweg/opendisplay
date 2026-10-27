//! `od-sender disconnect [receiver]`: stop running senders from another
//! terminal, the same way Ctrl+C in their own terminal would. The per-output
//! lock records each sender's pid ([`lock`]), so no daemon or socket is
//! needed: we send SIGINT and wait for the orderly teardown.

use std::time::{Duration, Instant};

use anyhow::Result;
use tracing::{info, warn};

use crate::backend::lock;

/// A running sender, found through its held output lock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Running {
    /// The virtual display's name, e.g. `od-1f046d`.
    pub output: String,
    pub pid: u32,
    /// Its command line, space-joined (how it was started: `run --to iMac`).
    pub cmdline: String,
}

/// Whether `r` is the sender `wanted` names: part of its display name, or a
/// word of its command line (`iMac` from `--to iMac` / `connect iMac`).
/// Case-insensitive. `None` matches every sender.
pub fn matches(r: &Running, wanted: Option<&str>) -> bool {
    let Some(w) = wanted.map(str::to_lowercase) else {
        return true;
    };
    if w.is_empty() {
        return true;
    }
    r.output.to_lowercase().contains(&w)
        || r.cmdline
            .split_whitespace()
            .skip(1) // the binary path itself
            .filter(|a| !a.starts_with('-'))
            .any(|a| a.to_lowercase().contains(&w))
}

/// Senders currently holding an output lock (a lock nobody holds is a
/// leftover for `clean`, not a connection).
fn running() -> Result<Vec<Running>> {
    let mut out = Vec::new();
    for name in lock::names()? {
        if lock::try_lock(&name)?.is_some() {
            continue; // free: no sender behind it (dropping the guard releases it)
        }
        let Some(pid) = lock::holder_pid(&name) else {
            continue;
        };
        let cmdline = std::fs::read(format!("/proc/{pid}/cmdline"))
            .map(|b| {
                b.split(|&c| c == 0)
                    .filter(|s| !s.is_empty())
                    .map(|s| String::from_utf8_lossy(s).into_owned())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        out.push(Running {
            output: name,
            pid,
            cmdline,
        });
    }
    Ok(out)
}

unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

const SIGINT: i32 = 2;

fn alive(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}

/// Returns the process exit code: 0 when something was disconnected (or
/// nothing was connected and no receiver was named), 3 when the named
/// receiver has no running sender.
pub fn run(wanted: Option<&str>) -> Result<i32> {
    let all = running()?;
    let targets: Vec<_> = all.iter().filter(|r| matches(r, wanted)).collect();
    if targets.is_empty() {
        match wanted {
            Some(w) => {
                eprintln!("no running od-sender is connected to {w:?}");
                for r in &all {
                    eprintln!("  running: {} (pid {}): {}", r.output, r.pid, r.cmdline);
                }
                return Ok(3);
            }
            None => {
                info!("no od-sender is connected");
                return Ok(0);
            }
        }
    }
    for r in &targets {
        // SAFETY: plain syscall; a stale pid at worst yields ESRCH.
        if unsafe { kill(r.pid as i32, SIGINT) } != 0 {
            warn!(
                "could not signal pid {} ({}): {}",
                r.pid,
                r.output,
                std::io::Error::last_os_error()
            );
        }
    }
    // The sender stops capture, removes its display and closes the session;
    // give it the same time a Ctrl+C gets.
    let deadline = Instant::now() + Duration::from_secs(5);
    for r in &targets {
        while alive(r.pid) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
        }
        if alive(r.pid) {
            warn!(
                "pid {} ({}) is still shutting down; check with `od-sender list` or stop it with `kill {}`",
                r.pid, r.output, r.pid
            );
        } else {
            info!("disconnected {} (pid {})", r.output, r.pid);
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(output: &str, cmdline: &str) -> Running {
        Running {
            output: output.into(),
            pid: 1,
            cmdline: cmdline.into(),
        }
    }

    #[test]
    fn matches_receiver_names_display_names_or_everything() {
        let imac = r("od-1f046d", "/home/u/.local/bin/od-sender run --to iMac");
        let pixel = r("od-1e2d1e", "od-sender connect Pixel 10a");
        assert!(matches(&imac, None));
        assert!(matches(&imac, Some("imac")));
        assert!(matches(&imac, Some("od-1f04")));
        assert!(!matches(&imac, Some("pixel")));
        assert!(matches(&pixel, Some("Pixel")));
        // Flags and the binary path never match.
        assert!(!matches(&imac, Some("--to")));
        assert!(!matches(&imac, Some(".local")));
    }
}
