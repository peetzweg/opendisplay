//! Which Sway output belongs to which display. Sway names headless outputs
//! itself (`HEADLESS-<n>`, never reused), so the lock key stays `od-<id>` and
//! this record, next to the lock file, maps it to the output and the Sway
//! instance that made it. A sender that dies leaves the record behind; the
//! next `open` for the same receiver reuses the output, and `clean` removes
//! it. Only outputs named in a record are ever unplugged.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::backend::lock;

const EXT: &str = "wlroots";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    /// Sway's name for it, e.g. `HEADLESS-3`.
    pub output: String,
    /// `$SWAYSOCK` of the instance that created it; names are only unique
    /// within one Sway run.
    pub swaysock: PathBuf,
}

impl Record {
    /// Made by the Sway behind `sock`.
    pub fn belongs_to(&self, sock: &Path) -> bool {
        self.swaysock == sock
    }

    /// Its Sway is gone (socket removed), so the output is gone too.
    pub fn is_orphan(&self) -> bool {
        !self.swaysock.exists()
    }
}

fn path_in(dir: &Path, lock_name: &str) -> PathBuf {
    dir.join(format!("{lock_name}.{EXT}"))
}

pub fn load(lock_name: &str) -> Option<Record> {
    load_in(&lock::dir(), lock_name)
}

fn load_in(dir: &Path, lock_name: &str) -> Option<Record> {
    let s = std::fs::read_to_string(path_in(dir, lock_name)).ok()?;
    serde_json::from_str(&s).ok()
}

/// Write while holding `lock_name`'s lock.
pub fn save(lock_name: &str, r: &Record) -> Result<()> {
    save_in(&lock::dir(), lock_name, r)
}

fn save_in(dir: &Path, lock_name: &str, r: &Record) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let p = path_in(dir, lock_name);
    std::fs::write(&p, serde_json::to_vec(r)?).with_context(|| format!("writing {}", p.display()))
}

pub fn remove(lock_name: &str) {
    let _ = std::fs::remove_file(path_in(&lock::dir(), lock_name));
}

/// Every record, as `(lock name, record)`.
pub fn all() -> Vec<(String, Record)> {
    all_in(&lock::dir())
}

fn all_in(dir: &Path) -> Vec<(String, Record)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<_> = entries
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.extension()? != EXT {
                return None;
            }
            let name = p.file_stem()?.to_str()?.to_string();
            let r = load_in(dir, &name)?;
            Some((name, r))
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_round_trip_and_list() {
        let dir = std::env::temp_dir().join(format!("od-record-test-{}", std::process::id()));
        let r = Record {
            output: "HEADLESS-3".into(),
            swaysock: "/run/user/1000/sway-ipc.1000.42.sock".into(),
        };
        save_in(&dir, "od-abc123", &r).unwrap();
        std::fs::write(dir.join("od-abc123.lock"), "1\n").unwrap();
        assert_eq!(load_in(&dir, "od-abc123"), Some(r.clone()));
        assert_eq!(all_in(&dir), vec![("od-abc123".to_string(), r.clone())]);
        assert!(r.belongs_to(Path::new("/run/user/1000/sway-ipc.1000.42.sock")));
        assert!(r.is_orphan());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
