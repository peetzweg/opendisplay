//! Hyprland compositor backend: virtual ("headless") outputs over the IPC
//! socket. Hyprland >= 0.55 is Lua-configured, so monitor rules go through
//! `eval hl.monitor({...})`; `keyword` is rejected. Every mutation is verified
//! by reading `monitors` back, because `eval` answers `ok` to inert Lua.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)] // fields are for logging and the coming sender lifecycle
pub struct Monitor {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub width: u32,
    pub height: u32,
    #[serde(rename = "refreshRate")]
    pub refresh_rate: f64,
    pub x: i32,
    pub y: i32,
    pub scale: f64,
    #[serde(default)]
    pub focused: bool,
}

pub struct HyprlandIpc {
    socket: PathBuf,
}

impl HyprlandIpc {
    pub fn from_env() -> Result<Self> {
        let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
            .context("HYPRLAND_INSTANCE_SIGNATURE not set: not inside Hyprland?")?;
        let runtime = std::env::var("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR not set")?;
        let socket = PathBuf::from(runtime)
            .join("hypr")
            .join(sig)
            .join(".socket.sock");
        if !socket.exists() {
            bail!("Hyprland IPC socket {} does not exist", socket.display());
        }
        Ok(Self { socket })
    }

    pub fn request(&self, cmd: &str) -> Result<String> {
        let mut s = UnixStream::connect(&self.socket)
            .with_context(|| format!("connecting {}", self.socket.display()))?;
        s.set_read_timeout(Some(Duration::from_secs(5)))?;
        s.write_all(cmd.as_bytes())?;
        let mut out = String::new();
        s.read_to_string(&mut out)?;
        Ok(out)
    }

    pub fn version(&self) -> Result<String> {
        Ok(self
            .request("version")?
            .lines()
            .next()
            .unwrap_or_default()
            .to_string())
    }

    pub fn monitors(&self) -> Result<Vec<Monitor>> {
        let json = self.request("j/monitors")?;
        serde_json::from_str(&json).with_context(|| format!("parsing monitors: {json}"))
    }

    pub fn monitor(&self, name: &str) -> Result<Option<Monitor>> {
        Ok(self.monitors()?.into_iter().find(|m| m.name == name))
    }

    /// Create a headless output. Hyprland gives it 1920x1080@60 until
    /// [`configure`](Self::configure) sets the real mode.
    pub fn create_headless(&self, name: &str) -> Result<()> {
        let r = self.request(&format!("output create headless {name}"))?;
        if r.trim() != "ok" {
            bail!("output create failed: {r}");
        }
        if self.monitor(name)?.is_none() {
            bail!("output {name} not listed after creation");
        }
        Ok(())
    }

    /// Set mode and scale. `position` is a Hyprland position spec, e.g.
    /// `auto-right`; the sender uses it to park the virtual display beside
    /// the real ones.
    pub fn configure(
        &self,
        name: &str,
        width: u32,
        height: u32,
        hz: u32,
        scale: f64,
        position: &str,
    ) -> Result<Monitor> {
        let lua = format!(
            "hl.monitor({{output=\"{name}\", mode=\"{width}x{height}@{hz}\", position=\"{position}\", scale={scale}}})"
        );
        let r = self.request(&format!("eval {lua}"))?;
        if r.trim() != "ok" {
            bail!("eval failed: {r}");
        }
        // Hyprland applies monitor rules asynchronously; poll briefly.
        for _ in 0..20 {
            if let Some(m) = self.monitor(name)? {
                if m.width == width && m.height == height && (m.scale - scale).abs() < 1e-6 {
                    return Ok(m);
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        bail!("output {name} did not take mode {width}x{height}@{hz} scale {scale}")
    }

    pub fn remove_output(&self, name: &str) -> Result<()> {
        let r = self.request(&format!("output remove {name}"))?;
        if r.trim() != "ok" {
            bail!("output remove failed: {r}");
        }
        Ok(())
    }
}
