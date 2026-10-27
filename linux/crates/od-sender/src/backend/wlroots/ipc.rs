//! Sway IPC (the i3 protocol: `i3-ipc`, u32 length, u32 type, JSON payload)
//! over `$SWAYSOCK`. The wlroots backend needs it only to create and remove
//! headless outputs and to read the layout back; sizing goes through
//! `zwlr_output_manager_v1` ([`super::outman`]).

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde::de::DeserializeOwned;

const MAGIC: &[u8; 6] = b"i3-ipc";
const RUN_COMMAND: u32 = 0;
const GET_WORKSPACES: u32 = 1;
const GET_OUTPUTS: u32 = 3;
const GET_VERSION: u32 = 7;

#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq)]
pub struct Mode {
    pub width: u32,
    pub height: u32,
    /// mHz; 0 for a headless output nobody sized yet.
    pub refresh: u32,
}

/// One entry of `get_outputs`, the fields the backend reads.
#[derive(Debug, Clone, Deserialize)]
pub struct Output {
    pub name: String,
    #[serde(default)]
    pub active: bool,
    /// Layout position and logical size.
    #[serde(default)]
    pub rect: Rect,
    #[serde(default)]
    pub current_mode: Option<Mode>,
    #[serde(default)]
    pub scale: Option<f64>,
}

/// `get_workspaces`, the fields the sender reads.
#[derive(Debug, Clone, Deserialize)]
pub struct Workspace {
    pub name: String,
    #[serde(default)]
    pub focused: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Version {
    pub human_readable: String,
    pub major: u32,
    pub minor: u32,
}

#[derive(Debug, Deserialize)]
struct CommandResult {
    success: bool,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SwayIpc {
    socket: PathBuf,
}

impl SwayIpc {
    pub fn new(socket: PathBuf) -> Self {
        Self { socket }
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    fn request<T: DeserializeOwned>(&self, kind: u32, payload: &str) -> Result<T> {
        let mut s = UnixStream::connect(&self.socket)
            .with_context(|| format!("connecting to Sway IPC {}", self.socket.display()))?;
        s.set_read_timeout(Some(Duration::from_secs(5)))?;
        let mut msg = Vec::with_capacity(14 + payload.len());
        msg.extend_from_slice(MAGIC);
        msg.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
        msg.extend_from_slice(&kind.to_ne_bytes());
        msg.extend_from_slice(payload.as_bytes());
        s.write_all(&msg)?;
        let mut header = [0u8; 14];
        s.read_exact(&mut header)
            .context("reading Sway IPC reply")?;
        if &header[..6] != MAGIC {
            bail!("Sway IPC: bad reply magic");
        }
        let len = u32::from_ne_bytes(header[6..10].try_into().unwrap()) as usize;
        let mut body = vec![0u8; len];
        s.read_exact(&mut body)?;
        serde_json::from_slice(&body).context("parsing Sway IPC reply")
    }

    pub fn version(&self) -> Result<Version> {
        self.request(GET_VERSION, "")
    }

    pub fn outputs(&self) -> Result<Vec<Output>> {
        self.request(GET_OUTPUTS, "")
    }

    pub fn workspaces(&self) -> Result<Vec<Workspace>> {
        self.request(GET_WORKSPACES, "")
    }

    pub fn output(&self, name: &str) -> Result<Option<Output>> {
        Ok(self.outputs()?.into_iter().find(|o| o.name == name))
    }

    /// Run one command; fails with Sway's error message.
    pub fn command(&self, cmd: &str) -> Result<()> {
        let results: Vec<CommandResult> = self.request(RUN_COMMAND, cmd)?;
        for r in results {
            if !r.success {
                bail!(
                    "swaymsg {cmd:?}: {}",
                    r.error.as_deref().unwrap_or("failed")
                );
            }
        }
        Ok(())
    }

    /// `create_output`, returning the new output's name. Sway picks the name
    /// (`HEADLESS-<n>`, never reused), so it is found by diffing the outputs.
    pub fn create_output(&self) -> Result<String> {
        let before: Vec<String> = self.outputs()?.into_iter().map(|o| o.name).collect();
        self.command("create_output")?;
        let new: Vec<String> = self
            .outputs()?
            .into_iter()
            .map(|o| o.name)
            .filter(|n| !before.contains(n))
            .collect();
        match new.as_slice() {
            [one] => Ok(one.clone()),
            [] => bail!("create_output made no new output"),
            many => bail!("create_output raced another client: new outputs {many:?}"),
        }
    }

    /// Remove a headless (or nested) output Sway created.
    pub fn unplug(&self, name: &str) -> Result<()> {
        self.command(&format!("output {name} unplug"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outputs_parse_from_sway_1_12() {
        // Trimmed `swaymsg -t get_outputs -r` from a headless Sway 1.12.
        let json = r#"[
          {"id":3,"type":"output","name":"HEADLESS-1","active":true,"scale":1.0,
           "rect":{"x":0,"y":0,"width":1280,"height":720},
           "current_mode":{"width":1280,"height":720,"refresh":60000}},
          {"id":9,"type":"output","name":"HEADLESS-2","active":true,"scale":2.0,
           "rect":{"x":1280,"y":0,"width":512,"height":384},
           "current_mode":{"width":1024,"height":768,"refresh":75000}}
        ]"#;
        let outs: Vec<Output> = serde_json::from_str(json).unwrap();
        assert_eq!(outs[1].name, "HEADLESS-2");
        assert_eq!(outs[1].rect.x, 1280);
        assert_eq!(outs[1].current_mode.unwrap().refresh, 75000);
        assert_eq!(outs[1].scale, Some(2.0));
    }
}
