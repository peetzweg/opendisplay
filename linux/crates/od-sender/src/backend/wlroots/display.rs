//! The Sway side of a virtual display: a headless output made with
//! `create_output`, sized and placed through `zwlr_output_manager_v1`, and
//! removed with `output <name> unplug`. Capture ordering is enforced by
//! [`crate::wayland::display::CapturedDisplay`], which wraps this.

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tracing::{info, warn};

use super::ipc::SwayIpc;
use super::outman::{self, Target};
use super::record::{self, Record};
use crate::backend::{DisplayInfo, DisplaySpec, DriftProbe, LayoutRect, place};
use crate::wayland::display::OutputControl;

pub struct WlrootsOutput {
    ipc: SwayIpc,
    /// `od-<id>`: the lock and record key.
    lock_name: String,
    info: DisplayInfo,
    last_check: Instant,
}

/// How often the output's mode and scale are compared with ours (a `swaymsg
/// reload` re-applies config output rules, a catch-all included).
const DRIFT_CHECK: Duration = Duration::from_secs(2);

impl WlrootsOutput {
    /// Reuse the output a dead sender left for this display (the caller holds
    /// its lock), or create one; then size it.
    pub fn open(ipc: SwayIpc, spec: &DisplaySpec) -> Result<Self> {
        let sock = ipc.socket().to_path_buf();
        let leftover = record::load(&spec.name)
            .filter(|r| r.belongs_to(&sock))
            .map(|r| r.output)
            .filter(|name| matches!(ipc.output(name), Ok(Some(_))));
        let name = match leftover {
            Some(name) => {
                info!("reusing {name}, left behind for {}", spec.name);
                name
            }
            None => ipc.create_output().context("creating a headless output")?,
        };
        record::save(
            &spec.name,
            &Record {
                output: name.clone(),
                swaysock: sock,
            },
        )?;
        let mut out = Self {
            ipc,
            lock_name: spec.name.clone(),
            info: DisplayInfo {
                name,
                width: 0,
                height: 0,
                refresh_hz: 0.0,
                scale: 1.0,
                x: 0,
                y: 0,
            },
            last_check: Instant::now(),
        };
        if let Err(e) = out.reconfigure(spec) {
            if let Err(r) = out.remove() {
                warn!("removing {} after a failed setup: {r:#}", out.info.name);
            }
            return Err(e);
        }
        Ok(out)
    }
}

impl OutputControl for WlrootsOutput {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        let name = self.info.name.clone();
        let outputs = self.ipc.outputs()?;
        let others: Vec<LayoutRect> = outputs
            .iter()
            .filter(|o| o.active && o.name != name)
            .map(|o| LayoutRect {
                x: o.rect.x,
                y: o.rect.y,
                width: o.rect.width,
                height: o.rect.height,
            })
            .collect();
        let (lw, lh) = (
            (spec.width as f64 / spec.scale).round() as i32,
            (spec.height as f64 / spec.scale).round() as i32,
        );
        let (x, y) = place(spec.position, lw, lh, &others);
        outman::apply(&Target {
            name: name.clone(),
            width: spec.width as i32,
            height: spec.height as i32,
            refresh_mhz: (spec.hz * 1000) as i32,
            scale: spec.scale,
            x,
            y,
        })?;
        let o = self
            .ipc
            .output(&name)?
            .with_context(|| format!("{name} vanished while being configured"))?;
        let mode = o.current_mode.unwrap_or_default();
        if (mode.width, mode.height) != (spec.width, spec.height) {
            bail!(
                "{name} is {}x{} after asking for {}x{}",
                mode.width,
                mode.height,
                spec.width,
                spec.height
            );
        }
        self.info = DisplayInfo {
            name,
            width: mode.width,
            height: mode.height,
            refresh_hz: mode.refresh as f64 / 1000.0,
            scale: o.scale.unwrap_or(spec.scale),
            x: o.rect.x,
            y: o.rect.y,
        };
        self.last_check = Instant::now();
        info!("virtual display {}", self.info);
        Ok(())
    }

    fn drift_probe(&mut self) -> Option<DriftProbe> {
        if self.info.width == 0 || self.last_check.elapsed() < DRIFT_CHECK {
            return None;
        }
        self.last_check = Instant::now();
        let (ipc, info) = (self.ipc.clone(), self.info.clone());
        Some(Box::new(move || {
            let o = ipc.output(&info.name).ok().flatten()?;
            let mode = o.current_mode.unwrap_or_default();
            let scale = o.scale.unwrap_or(info.scale);
            let changed = (mode.width, mode.height) != (info.width, info.height)
                || (scale - info.scale).abs() > 1e-3;
            changed.then(|| {
                format!(
                    "{} is {}x{} scale {scale}, set {}x{} scale {}",
                    info.name, mode.width, mode.height, info.width, info.height, info.scale
                )
            })
        }))
    }

    fn remove(&mut self) -> Result<()> {
        self.ipc.unplug(&self.info.name)?;
        record::remove(&self.lock_name);
        info!("removed virtual display {}", self.info.name);
        Ok(())
    }
}
