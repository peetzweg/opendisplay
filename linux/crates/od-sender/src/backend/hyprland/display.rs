//! The Hyprland side of a virtual display: a headless output created, sized
//! and removed over IPC. Capture ordering is enforced by
//! [`crate::wayland::display::CapturedDisplay`], which wraps this.

use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tracing::{info, warn};

use super::events::ReloadWatcher;

use super::ipc::{HyprlandIpc, Monitor};
use crate::backend::{DisplayInfo, DisplaySpec, DriftProbe};
use crate::wayland::cursor::CursorSpace;
use crate::wayland::display::OutputControl;

pub struct HyprlandOutput {
    ipc: HyprlandIpc,
    info: DisplayInfo,
    /// The spec last applied: what a config reload or drift is undone to.
    spec: Option<DisplaySpec>,
    reloads: Option<ReloadWatcher>,
    last_check: Instant,
}

/// After `configreloaded`, wait this long for Hyprland to finish
/// re-applying its own monitor rules before restoring ours.
const RELOAD_SETTLE: Duration = Duration::from_millis(200);
/// How often the output's mode and scale are compared with ours.
const DRIFT_CHECK: Duration = Duration::from_secs(2);

/// How `m` differs from what was applied, if it does. Only mode and scale:
/// the stream depends on them. A position the user changed is theirs.
pub fn drift(applied: &DisplayInfo, m: &Monitor) -> Option<String> {
    let mode = (m.width, m.height) != (applied.width, applied.height);
    let scale = (m.scale - applied.scale).abs() > 1e-3;
    (mode || scale).then(|| {
        format!(
            "{} is {}x{} scale {}, set {}x{} scale {}",
            m.name, m.width, m.height, m.scale, applied.width, applied.height, applied.scale
        )
    })
}

fn info_of(m: &Monitor) -> DisplayInfo {
    DisplayInfo {
        name: m.name.clone(),
        width: m.width,
        height: m.height,
        refresh_hz: m.refresh_rate,
        scale: m.scale,
        x: m.x,
        y: m.y,
    }
}

impl HyprlandOutput {
    /// Create the output unless a leftover of the same name exists (the
    /// caller holds its lock, so no sender is using it), then size it. An
    /// output this call created is removed again if sizing fails.
    pub fn open(ipc: HyprlandIpc, spec: &DisplaySpec) -> Result<Self> {
        let existed = ipc.monitor(&spec.name)?.is_some();
        let mut out = Self {
            info: DisplayInfo {
                name: spec.name.clone(),
                width: 0,
                height: 0,
                refresh_hz: 0.0,
                scale: 1.0,
                x: 0,
                y: 0,
            },
            reloads: None,
            spec: None,
            last_check: Instant::now(),
            ipc,
        };
        if let Err(e) = out.reconfigure(spec) {
            if !existed && out.ipc.monitor(&spec.name).ok().flatten().is_some() {
                match out.ipc.remove_output(&spec.name) {
                    Ok(()) => info!("removed {} after a failed setup", spec.name),
                    Err(re) => warn!(
                        "could not remove {} after a failed setup: {re:#}",
                        spec.name
                    ),
                }
            }
            return Err(e);
        }
        match ReloadWatcher::spawn(out.ipc.event_socket()) {
            Ok(w) => out.reloads = Some(w),
            Err(e) => warn!("not watching Hyprland config reloads: {e}"),
        }
        Ok(out)
    }
}

impl OutputControl for HyprlandOutput {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    fn reconfigure(&mut self, spec: &DisplaySpec) -> Result<()> {
        let name = &spec.name;
        if self.ipc.monitor(name)?.is_none() {
            self.ipc
                .create_headless(name)
                .with_context(|| format!("creating headless output {name}"))?;
        }
        let m = self.ipc.configure(
            name,
            spec.width,
            spec.height,
            spec.hz,
            spec.scale,
            spec.position,
        )?;
        self.info = info_of(&m);
        self.spec = Some(spec.clone());
        self.last_check = Instant::now();
        info!("virtual display {}", self.info);
        Ok(())
    }

    fn drift_probe(&mut self) -> Option<DriftProbe> {
        if self
            .reloads
            .as_ref()
            .is_some_and(|w| w.take_settled(RELOAD_SETTLE))
        {
            return Some(Box::new(|| Some("Hyprland config reloaded".into())));
        }
        if self.spec.is_none() || self.last_check.elapsed() < DRIFT_CHECK {
            return None;
        }
        self.last_check = Instant::now();
        let (ipc, info) = (self.ipc.clone(), self.info.clone());
        Some(Box::new(move || {
            // A missing output is the capture-loss path's business.
            let m = ipc.monitor(&info.name).ok().flatten()?;
            drift(&info, &m)
        }))
    }

    /// Hyprland 0.56.2 reports cursor positions and hotspots in logical
    /// units and renders the sprite at the highest monitor scale
    /// (`CImageCopyCaptureCursorSession::sendCursorEvents`,
    /// `CCursorManager::updateTheme`).
    fn cursor_space(&self) -> CursorSpace {
        let scale = self.info.scale.max(0.1);
        let highest = self
            .ipc
            .monitors()
            .map(|ms| ms.iter().map(|m| m.scale).fold(1.0f64, f64::max))
            .unwrap_or(scale)
            .max(1.0);
        CursorSpace {
            width: self.info.width as f64 / scale,
            height: self.info.height as f64 / scale,
            sprite_scale: highest,
            theme_size: crate::wayland::cursor::theme_size(),
        }
    }

    fn remove(&mut self) -> Result<()> {
        self.ipc.remove_output(&self.info.name)?;
        info!("removed virtual display {}", self.info.name);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(w: u32, h: u32, scale: f64, x: i32) -> Monitor {
        Monitor {
            id: 1,
            name: "od-1f046d".into(),
            description: String::new(),
            width: w,
            height: h,
            refresh_rate: 60.0,
            x,
            y: 0,
            scale,
            focused: false,
            active_workspace: None,
        }
    }

    #[test]
    fn mode_and_scale_drift_but_position_is_the_users() {
        let applied = info_of(&monitor(4096, 2304, 2.0, -2048));
        assert_eq!(drift(&applied, &monitor(4096, 2304, 2.0, -2048)), None);
        // The user dragged it elsewhere: theirs.
        assert_eq!(drift(&applied, &monitor(4096, 2304, 2.0, 1917)), None);
        // `hyprctl reload` with a catch-all `preferred`/`auto` rule, as seen live.
        let why = drift(&applied, &monitor(1920, 1080, 1.3333, 1917)).unwrap();
        assert!(
            why.contains("1920x1080") && why.contains("4096x2304"),
            "{why}"
        );
        assert!(drift(&applied, &monitor(4096, 2304, 1.5, -2048)).is_some());
    }
}
