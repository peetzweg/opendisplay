//! One sender per virtual output. A second sender for the same receiver would
//! adopt and reconfigure an output the first is still capturing, which takes
//! Hyprland down (see [`super::VirtualDisplay`]). The lock is an `flock` on
//! `$XDG_RUNTIME_DIR/opendisplay/<name>.lock`, released when the file closes,
//! including on a crash.

use std::fs::File;
use std::path::PathBuf;

use anyhow::{Context, Result};

#[derive(Debug)]
pub struct OutputLock {
    _file: File,
}

/// Another process holds the lock for `name`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockHeld {
    pub name: String,
    /// The holder's pid, as it wrote it into the lock file.
    pub pid: Option<u32>,
}

impl std::fmt::Display for LockHeld {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.pid {
            Some(pid) => write!(
                f,
                "another od-sender (pid {pid}) is already driving {}",
                self.name
            ),
            None => write!(f, "another od-sender is already driving {}", self.name),
        }
    }
}

impl std::error::Error for LockHeld {}

fn path(name: &str) -> PathBuf {
    dir().join(format!("{name}.lock"))
}

/// The pid recorded in `name`'s lock file, if any.
pub fn holder_pid(name: &str) -> Option<u32> {
    std::fs::read_to_string(path(name))
        .ok()?
        .trim()
        .parse()
        .ok()
}

pub fn dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("opendisplay")
}

/// Every output lock name in [`dir`], held or not (lock files outlive their
/// locks).
pub fn names() -> Result<Vec<String>> {
    let Ok(entries) = std::fs::read_dir(dir()) else {
        return Ok(Vec::new());
    };
    let mut out: Vec<String> = entries
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            (p.extension()? == "lock").then(|| p.file_stem()?.to_str().map(String::from))?
        })
        .collect();
    out.sort();
    Ok(out)
}

/// Take the lock for output `name`, or fail with [`LockHeld`] when a
/// running sender holds it.
pub fn lock_output(name: &str) -> Result<OutputLock> {
    match try_lock(name)? {
        Some(l) => Ok(l),
        None => Err(LockHeld {
            name: name.to_string(),
            pid: holder_pid(name),
        }
        .into()),
    }
}

/// `Ok(None)` when another process holds the lock.
pub fn try_lock(name: &str) -> Result<Option<OutputLock>> {
    let dir = dir();
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let path = path(name);
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    use std::os::fd::AsRawFd;
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;
    // SAFETY: flock on a descriptor we own for the duration of the call.
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
        // Record the holder for the "already driving" message; best effort.
        use std::io::Write;
        let _ = file.set_len(0);
        let _ = (&file).write_all(format!("{}\n", std::process::id()).as_bytes());
        return Ok(Some(OutputLock { _file: file }));
    }
    let e = std::io::Error::last_os_error();
    if e.kind() == std::io::ErrorKind::WouldBlock {
        return Ok(None);
    }
    Err(e).with_context(|| format!("locking {}", path.display()))
}

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

#[cfg(test)]
mod tests {
    use super::{lock_output, try_lock};

    #[test]
    fn second_sender_for_the_same_output_is_refused() {
        let name = format!("od-test-{}", std::process::id());
        let first = lock_output(&name).expect("first lock");
        let err = lock_output(&name).expect_err("second lock must fail");
        let held = err.downcast_ref::<super::LockHeld>().expect("typed error");
        assert_eq!(held.pid, Some(std::process::id()));
        assert!(err.to_string().contains("already driving"), "{err:#}");
        assert!(try_lock(&name).unwrap().is_none());
        drop(first);
        drop(lock_output(&name).expect("lock is free again once the holder closes"));
        assert!(
            super::names().unwrap().contains(&name),
            "lock files are listed"
        );
        let _ = std::fs::remove_file(super::dir().join(format!("{name}.lock")));
    }
}
