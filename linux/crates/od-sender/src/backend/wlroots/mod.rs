//! Sway (wlroots): headless outputs made over Sway IPC, sized through
//! `zwlr_output_manager_v1`, captured and driven through the shared
//! `wayland/*` protocols. Other wlroots
//! compositors lack a way to create outputs; they get adopt mode.

pub mod display;
pub mod ipc;
pub mod outman;
pub mod record;
pub mod workspace;

use std::path::PathBuf;

use anyhow::Result;
use tracing::{info, warn};

use self::display::WlrootsOutput;
use self::ipc::SwayIpc;
use super::capture::CapturePath;
use super::lock::{lock_output, try_lock};
use super::{Backend, BackendId, Caps, DisplaySpec, VirtualDisplay};
use crate::wayland::display::CapturedDisplay;

/// First Sway with `ext-image-copy-capture` (wlroots 0.18).
pub const MIN_VERSION: (u32, u32) = (1, 10);

pub struct WlrootsBackend {
    ipc: SwayIpc,
    version: String,
    capture: CapturePath,
}

impl WlrootsBackend {
    pub fn connect(swaysock: PathBuf) -> Result<Self> {
        let ipc = SwayIpc::new(swaysock);
        let v = ipc.version()?;
        if (v.major, v.minor) < MIN_VERSION {
            warn!(
                "Sway {} predates ext-image-copy-capture ({}.{}); capture will fail",
                v.human_readable, MIN_VERSION.0, MIN_VERSION.1
            );
        }
        Ok(Self {
            ipc,
            version: v.human_readable,
            capture: CapturePath::Ext,
        })
    }
}

impl Backend for WlrootsBackend {
    fn id(&self) -> BackendId {
        BackendId::Wlroots
    }

    fn supports_workspaces(&self) -> bool {
        true
    }

    fn show_workspace(&mut self, output: &str, name: &str) -> Result<()> {
        let focused = self
            .ipc
            .workspaces()?
            .into_iter()
            .find(|w| w.focused)
            .map(|w| w.name);
        for cmd in workspace::plan(name, output, focused.as_deref()) {
            self.ipc.command(&cmd)?;
        }
        Ok(())
    }

    fn describe(&self) -> String {
        format!(
            "Sway {} (IPC {})",
            self.version,
            self.ipc.socket().display()
        )
    }

    fn caps(&self) -> Caps {
        Caps {
            cursor_metadata: false,
            dmabuf: false,
            resize_in_place: true,
            creates_outputs: true,
        }
    }

    fn set_capture(&mut self, path: CapturePath) {
        self.capture = path;
    }

    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
        let lock = lock_output(&spec.name)?;
        let output = WlrootsOutput::open(self.ipc.clone(), spec)?;
        Ok(Box::new(CapturedDisplay::new(output, lock, self.capture)))
    }

    /// Unplug outputs recorded by senders that are no longer running. Outputs
    /// without a record (HEADLESS-1, the user's own) are never touched.
    fn clean(&mut self) -> Result<Vec<String>> {
        let sock = self.ipc.socket().to_path_buf();
        let mut removed = Vec::new();
        for (lock_name, rec) in record::all() {
            // Held while removing, so no sender can start on it meanwhile.
            let Some(_lock) = try_lock(&lock_name)? else {
                warn!(
                    "{} ({lock_name}) is in use by a running od-sender; leaving it",
                    rec.output
                );
                continue;
            };
            if rec.belongs_to(&sock) {
                if self.ipc.output(&rec.output)?.is_some() {
                    self.ipc.unplug(&rec.output)?;
                    removed.push(rec.output.clone());
                }
            } else if !rec.is_orphan() {
                info!(
                    "{} ({lock_name}) belongs to another Sway ({}); leaving it",
                    rec.output,
                    rec.swaysock.display()
                );
                continue;
            }
            record::remove(&lock_name);
        }
        Ok(removed)
    }
}
