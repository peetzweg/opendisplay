//! `%APPDATA%\od-receiver\config.json`, created with defaults on first run.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::{env, fs, io};

/// Which monitor to cover: its index in Windows' enumeration order (0-based, logged at startup)
/// or its device name such as `\\.\DISPLAY2`.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(untagged)]
pub enum MonitorSel {
    Index(usize),
    Name(String),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields, default)]
pub struct Config {
    /// TCP port; the UDP cursor channel uses port + 1.
    pub port: u16,
    /// Bonjour service name; null means the computer name.
    pub name: Option<String>,
    pub max_encode_wide: u32,
    pub max_encode_high: u32,
    /// null means the primary monitor.
    pub monitor: Option<MonitorSel>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: 9000,
            name: None,
            max_encode_wide: 4096,
            max_encode_high: 2304,
            monitor: None,
        }
    }
}

impl Config {
    pub fn path() -> PathBuf {
        PathBuf::from(env::var_os("APPDATA").unwrap_or_else(|| ".".into()))
            .join("od-receiver")
            .join("config.json")
    }

    /// Reads `path`, writing the defaults there first if it does not exist. A file that exists
    /// but does not parse is an error, not silently replaced.
    pub fn load(path: &Path) -> io::Result<Self> {
        match fs::read(path) {
            Ok(b) => serde_json::from_slice(&b).map_err(|e| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{}: {e}", path.display()),
                )
            }),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let c = Self::default();
                if let Some(dir) = path.parent() {
                    fs::create_dir_all(dir)?;
                }
                fs::write(
                    path,
                    serde_json::to_string_pretty(&c).expect("config serializes"),
                )?;
                Ok(c)
            }
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_defaults_then_reads_edits() {
        let dir = env::temp_dir().join(format!("od-receiver-test-{}", std::process::id()));
        let path = dir.join("config.json");
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(Config::load(&path).unwrap(), Config::default());
        let written = fs::read_to_string(&path).unwrap();
        assert!(
            written.contains("\"maxEncodeWide\": 4096") && written.contains("\"monitor\": null"),
            "{written}"
        );

        fs::write(&path, r#"{"port":9100,"name":"Desk","maxEncodeWide":3840,"maxEncodeHigh":2160,"monitor":"\\\\.\\DISPLAY2"}"#).unwrap();
        let c = Config::load(&path).unwrap();
        assert_eq!(
            (c.port, c.name.as_deref(), c.monitor),
            (
                9100,
                Some("Desk"),
                Some(MonitorSel::Name(r"\\.\DISPLAY2".into()))
            )
        );
        fs::write(
            &path,
            r#"{"port":9000,"name":null,"maxEncodeWide":4096,"maxEncodeHigh":2304,"monitor":1}"#,
        )
        .unwrap();
        assert_eq!(
            Config::load(&path).unwrap().monitor,
            Some(MonitorSel::Index(1))
        );

        fs::write(&path, r#"{"prot":9000}"#).unwrap();
        assert!(
            Config::load(&path).is_err(),
            "typos are reported, not ignored"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
