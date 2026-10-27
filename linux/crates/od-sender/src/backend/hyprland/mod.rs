//! Hyprland >= 0.55: headless outputs over the IPC socket, captured and
//! driven through the shared `wayland/*` protocols.

pub mod display;
pub mod events;
pub mod instance;
pub mod ipc;
pub mod workspace;

use std::path::PathBuf;

use anyhow::{Result, bail};
use tracing::{debug, warn};

use self::display::HyprlandOutput;
use self::ipc::HyprlandIpc;
use super::capture::{CapturePath, Preference};
use super::lock::{lock_output, try_lock};
use super::{Backend, BackendId, Caps, DisplaySpec, VirtualDisplay};
use crate::wayland::display::CapturedDisplay;

/// Oldest release with the Lua `eval` path the sender configures outputs with.
pub const MIN_VERSION: (u32, u32) = (0, 55);
/// Newest minor release the sender was run against.
pub const TESTED_UP_TO: (u32, u32) = (0, 56);

/// First release whose ext-image-copy-capture frame constructor no longer
/// dereferences a removed output's monitor (fixed on main after 0.56.2).
pub const EXT_CAPTURE_SAFE_FROM: (u32, u32) = (0, 57);

/// Hyprland before [`EXT_CAPTURE_SAFE_FROM`] (or of unknown version) captures
/// through wlr-screencopy (backend/capture.rs).
pub fn capture_preference(version: Option<(u32, u32, u32)>) -> Preference {
    const WHY: &str = "Hyprland < 0.57 can crash when an output is removed under an \
        ext-image-copy-capture frame request; its wlr-screencopy path is safe";
    match version {
        Some((maj, min, _)) if (maj, min) >= EXT_CAPTURE_SAFE_FROM => None,
        _ => Some((CapturePath::Wlr, WHY)),
    }
}

pub struct HyprlandBackend {
    socket: PathBuf,
    version: String,
    /// Parsed `version`, for the capture choice.
    triple: Option<(u32, u32, u32)>,
    capture: CapturePath,
}

impl HyprlandBackend {
    /// Connect to the instance behind `socket` and refuse versions without
    /// the Lua IPC.
    pub fn connect(socket: PathBuf) -> Result<Self> {
        let ipc = HyprlandIpc::new(socket.clone());
        let v = ipc.version_info()?;
        match v.triple() {
            Some((maj, min, _)) if (maj, min) < MIN_VERSION => bail!(
                "Hyprland {} is too old: od-sender needs {}.{} or newer (Lua IPC)",
                v.version,
                MIN_VERSION.0,
                MIN_VERSION.1
            ),
            Some((maj, min, _)) if (maj, min) > TESTED_UP_TO => warn!(
                "Hyprland {} is newer than the tested {}.{}.x; report problems with `od-sender doctor` output",
                v.version, TESTED_UP_TO.0, TESTED_UP_TO.1
            ),
            Some(_) => {}
            None => warn!("cannot parse Hyprland version {:?}", v.version),
        }
        Ok(Self {
            socket,
            triple: v.triple(),
            version: v.version,
            capture: CapturePath::Ext,
        })
    }

    pub fn ipc(&self) -> HyprlandIpc {
        HyprlandIpc::new(self.socket.clone())
    }
}

impl Backend for HyprlandBackend {
    fn id(&self) -> BackendId {
        BackendId::Hyprland
    }

    fn supports_workspaces(&self) -> bool {
        true
    }

    fn show_workspace(&mut self, output: &str, name: &str) -> Result<()> {
        let ipc = self.ipc();
        let monitors = ipc.monitors()?;
        let workspaces = ipc.workspaces()?;
        let ws = workspaces.iter().find(|w| w.matches(name));
        let before = workspace::Before {
            workspace_on: ws.map(|w| w.monitor.clone()),
            already_shown: monitors.iter().any(|m| {
                m.name == output && m.active_workspace.as_ref().is_some_and(|a| a.matches(name))
            }),
            focused: monitors.iter().find(|m| m.focused).map(|m| m.name.clone()),
            cursor: ipc.cursor_pos().ok(),
        };
        let steps = workspace::plan(name, output, &before);
        for step in &steps {
            debug!("workspace: dispatch {step}");
            ipc.dispatch(step)?;
        }
        // Give focus a moment to settle, then make sure the user has it back:
        // a late event (the workspace's creation, a pointer move) may refocus.
        if let Some(prev) = before
            .focused
            .as_deref()
            .filter(|p| *p != output && !steps.is_empty())
        {
            std::thread::sleep(std::time::Duration::from_millis(100));
            let now = ipc
                .monitors()?
                .into_iter()
                .find(|m| m.focused)
                .map(|m| m.name);
            if now.as_deref() != Some(prev) {
                warn!(
                    "workspace: focus is on {} after placing {name}; focusing {prev} again",
                    now.as_deref().unwrap_or("nothing")
                );
                for step in workspace::restore(prev, before.cursor) {
                    debug!("workspace: dispatch {step}");
                    ipc.dispatch(&step)?;
                }
            }
        }
        Ok(())
    }

    fn describe(&self) -> String {
        format!("Hyprland {} (IPC {})", self.version, self.socket.display())
    }

    fn caps(&self) -> Caps {
        Caps {
            // Off on Hyprland through at least 0.56.2 (and main as of
            // 2026-10-20): CCursorshareSession::render only draws the cursor
            // when the pointer has both a buffer and a surface, which never
            // happens, so every sprite is blank; and a pending cursor frame
            // crashes Hyprland once its output is removed (fixed upstream
            // after 0.56.2 by 8010b4e5c). The cursor stays in the video.
            cursor_metadata: false,
            dmabuf: false,
            resize_in_place: true,
            creates_outputs: true,
        }
    }

    fn capture_preference(&self) -> Preference {
        capture_preference(self.triple)
    }

    fn set_capture(&mut self, path: CapturePath) {
        self.capture = path;
    }

    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
        let lock = lock_output(&spec.name)?;
        let output = HyprlandOutput::open(self.ipc(), spec)?;
        Ok(Box::new(CapturedDisplay::new(output, lock, self.capture)))
    }

    fn clean(&mut self) -> Result<Vec<String>> {
        let ipc = self.ipc();
        let mut removed = Vec::new();
        for m in ipc.monitors()? {
            if !m.name.starts_with("od-") {
                continue;
            }
            // Held while removing, so no sender can start on it meanwhile.
            let Some(_lock) = try_lock(&m.name)? else {
                warn!("{} is in use by a running od-sender; leaving it", m.name);
                continue;
            };
            ipc.remove_output(&m.name)?;
            removed.push(m.name);
        }
        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wlr_capture_before_0_57() {
        assert_eq!(
            capture_preference(Some((0, 56, 2))).map(|p| p.0),
            Some(CapturePath::Wlr)
        );
        assert_eq!(
            capture_preference(Some((0, 55, 0))).map(|p| p.0),
            Some(CapturePath::Wlr)
        );
        // Unknown version: the safe side.
        assert_eq!(
            capture_preference(None).map(|p| p.0),
            Some(CapturePath::Wlr)
        );
        assert_eq!(capture_preference(Some((0, 57, 0))), None);
        assert_eq!(capture_preference(Some((1, 0, 0))), None);
    }
}
