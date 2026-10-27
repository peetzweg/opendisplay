//! Which Wayland protocol captures the frames: `ext-image-copy-capture-v1`
//! (the standard, with a separate cursor session) or `wlr-screencopy-v1`.
//!
//! Hyprland before 0.57 dereferences a freed monitor when an
//! ext-image-copy-capture frame request arrives for an output that was just
//! removed (research/linux/hyprland-screenshare-transform.md); a client cannot
//! close that race. Its wlr-screencopy path checks the monitor at every step
//! (nested 0.56.2: 40/40 removals under full-rate capture survived, against a
//! crash at the 7th with ext), so `auto` picks wlr-screencopy there.

use std::fmt;

use anyhow::{Result, bail};
use clap::ValueEnum;

/// What the user asked for (`--capture`, config `capture`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, ValueEnum)]
pub enum CaptureChoice {
    /// The backend's preference, else ext-image-copy-capture.
    #[default]
    Auto,
    /// ext-image-copy-capture-v1.
    Ext,
    /// wlr-screencopy-unstable-v1.
    Wlr,
}

/// The protocol a capture runs on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CapturePath {
    #[default]
    Ext,
    Wlr,
}

impl CapturePath {
    pub fn global(self) -> &'static str {
        match self {
            CapturePath::Ext => "ext_image_copy_capture_manager_v1",
            CapturePath::Wlr => "zwlr_screencopy_manager_v1",
        }
    }
}

impl fmt::Display for CapturePath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            CapturePath::Ext => "ext-image-copy-capture",
            CapturePath::Wlr => "wlr-screencopy",
        })
    }
}

/// A backend's reason to prefer one path over the default.
pub type Preference = Option<(CapturePath, &'static str)>;

/// The chosen path and why, for the log and `doctor`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureSelection {
    pub path: CapturePath,
    pub reason: String,
}

/// Which capture globals the compositor advertises.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Offered {
    pub ext: bool,
    pub wlr: bool,
}

impl Offered {
    fn has(self, p: CapturePath) -> bool {
        match p {
            CapturePath::Ext => self.ext,
            CapturePath::Wlr => self.wlr,
        }
    }
}

/// Pick the capture path. An explicit choice is honoured or refused, never
/// swapped; `auto` takes the backend's preference when the compositor offers
/// it, else ext, else wlr.
pub fn select(
    choice: CaptureChoice,
    preference: Preference,
    offered: Offered,
) -> Result<CaptureSelection> {
    let pick = |path, reason: String| CaptureSelection { path, reason };
    match choice {
        CaptureChoice::Ext | CaptureChoice::Wlr => {
            let path = if choice == CaptureChoice::Ext {
                CapturePath::Ext
            } else {
                CapturePath::Wlr
            };
            if !offered.has(path) {
                bail!(
                    "--capture {path}: the compositor does not offer {}",
                    path.global()
                );
            }
            let mut reason = "asked for with --capture/config".to_string();
            if let Some((p, why)) = preference {
                if p != path {
                    reason.push_str(&format!("; note: {why}, auto would use {p}"));
                }
            }
            Ok(pick(path, reason))
        }
        CaptureChoice::Auto => match preference {
            Some((p, why)) if offered.has(p) => Ok(pick(p, why.to_string())),
            Some((p, why)) => {
                let other = if p == CapturePath::Ext {
                    CapturePath::Wlr
                } else {
                    CapturePath::Ext
                };
                if offered.has(other) {
                    Ok(pick(
                        other,
                        format!("{why}, but the compositor offers no {}", p.global()),
                    ))
                } else {
                    bail!("the compositor offers neither capture protocol")
                }
            }
            None if offered.ext => Ok(pick(
                CapturePath::Ext,
                "the standard capture protocol".into(),
            )),
            None if offered.wlr => Ok(pick(
                CapturePath::Wlr,
                "the compositor offers no ext-image-copy-capture".into(),
            )),
            None => bail!("the compositor offers neither capture protocol"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BOTH: Offered = Offered {
        ext: true,
        wlr: true,
    };
    const HYPR: Preference = Some((CapturePath::Wlr, "Hyprland < 0.57"));

    #[test]
    fn auto_follows_the_backend_preference() {
        assert_eq!(
            select(CaptureChoice::Auto, HYPR, BOTH).unwrap().path,
            CapturePath::Wlr
        );
        assert_eq!(
            select(CaptureChoice::Auto, None, BOTH).unwrap().path,
            CapturePath::Ext
        );
    }

    #[test]
    fn auto_falls_back_to_what_is_offered() {
        let ext_only = Offered {
            ext: true,
            wlr: false,
        };
        let s = select(CaptureChoice::Auto, HYPR, ext_only).unwrap();
        assert_eq!(s.path, CapturePath::Ext);
        assert!(
            s.reason.contains("offers no zwlr_screencopy_manager_v1"),
            "{}",
            s.reason
        );
        let wlr_only = Offered {
            ext: false,
            wlr: true,
        };
        assert_eq!(
            select(CaptureChoice::Auto, None, wlr_only).unwrap().path,
            CapturePath::Wlr
        );
        let none = Offered {
            ext: false,
            wlr: false,
        };
        assert!(select(CaptureChoice::Auto, None, none).is_err());
        assert!(select(CaptureChoice::Auto, HYPR, none).is_err());
    }

    #[test]
    fn an_explicit_choice_is_honoured_or_refused() {
        let s = select(CaptureChoice::Ext, HYPR, BOTH).unwrap();
        assert_eq!(s.path, CapturePath::Ext);
        assert!(
            s.reason.contains("auto would use wlr-screencopy"),
            "{}",
            s.reason
        );
        assert_eq!(
            select(CaptureChoice::Wlr, None, BOTH).unwrap().path,
            CapturePath::Wlr
        );
        let ext_only = Offered {
            ext: true,
            wlr: false,
        };
        assert!(select(CaptureChoice::Wlr, None, ext_only).is_err());
    }
}
