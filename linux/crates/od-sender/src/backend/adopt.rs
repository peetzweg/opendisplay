//! Adopt mode (`--output <name>`): capture and inject on an
//! output that already exists. Nothing is created, sized or removed, so it
//! works on any compositor with `ext-image-copy-capture` and
//! `zwlr_virtual_pointer`. The stream takes the output's size, not the
//! receiver's.

use anyhow::{Context, Result};
use tracing::{info, warn};

use super::capture::CapturePath;
use super::lock::lock_output;
use super::{Backend, BackendId, Caps, DisplayInfo, DisplaySpec, VirtualDisplay};
use crate::wayland::display::{CapturedDisplay, OutputControl};
use crate::wayland::registry;

pub struct AdoptBackend {
    output: String,
    capture: CapturePath,
}

impl AdoptBackend {
    pub fn new(output: String) -> Self {
        Self {
            output,
            capture: CapturePath::Ext,
        }
    }
}

struct AdoptedOutput {
    info: DisplayInfo,
}

fn lookup(name: &str) -> Result<DisplayInfo> {
    let snap = registry::snapshot()?;
    let o = snap.output(name).with_context(|| {
        format!(
            "no output {name}; have {:?}",
            snap.outputs.iter().map(|o| &o.name).collect::<Vec<_>>()
        )
    })?;
    Ok(DisplayInfo {
        name: o.name.clone(),
        width: o.width.max(0) as u32,
        height: o.height.max(0) as u32,
        refresh_hz: o.refresh_mhz as f64 / 1000.0,
        scale: o.fractional_scale(),
        x: o.x,
        y: o.y,
    })
}

impl OutputControl for AdoptedOutput {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    /// The output is not ours to size; re-read it in case its owner did.
    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        self.info = lookup(&self.info.name)?;
        if (spec.width, spec.height) != (self.info.width, self.info.height) {
            info!(
                "adopted output {} stays {}x{} (receiver asked for {}x{})",
                self.info.name, self.info.width, self.info.height, spec.width, spec.height
            );
        }
        Ok(())
    }

    fn remove(&mut self) -> Result<()> {
        Ok(())
    }
}

impl Backend for AdoptBackend {
    fn id(&self) -> BackendId {
        BackendId::Adopt
    }

    fn describe(&self) -> String {
        format!("adopt output {} (no create/remove)", self.output)
    }

    fn caps(&self) -> Caps {
        Caps {
            // ext-image-copy-capture cursor sessions (wayland/cursor.rs).
            cursor_metadata: true,
            dmabuf: false,
            resize_in_place: false,
            creates_outputs: false,
        }
    }

    fn set_capture(&mut self, path: CapturePath) {
        self.capture = path;
    }

    fn open(&mut self, spec: &DisplaySpec) -> Result<Box<dyn VirtualDisplay>> {
        let lock = lock_output(&self.output)?;
        let mut out = AdoptedOutput {
            info: lookup(&self.output)?,
        };
        out.reconfigure(spec)?;
        if out.info.width == 0 || out.info.height == 0 {
            warn!("output {} reports no current mode", self.output);
        }
        info!("adopted display {}", out.info);
        Ok(Box::new(CapturedDisplay::new(out, lock, self.capture)))
    }

    fn clean(&mut self) -> Result<Vec<String>> {
        Ok(Vec::new())
    }

    fn lock_name(&self, _: &DisplaySpec) -> String {
        self.output.clone()
    }
}
