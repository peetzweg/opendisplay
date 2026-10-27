//! `$XDG_CONFIG_HOME/opendisplay/sender.toml`:
//! defaults for `run`'s options, plus per-receiver overrides. Keys are the
//! long option names. Precedence, highest first: command line, the
//! receiver's `[receiver."<id or name>"]` table, the top level, built-in
//! defaults.
//!
//! ```toml
//! to = "iPhone"
//! position = "auto-right"
//! scale = "passthrough"       # or "mac", or a number
//! bitrate-mbps = 20
//! max-fps = 60
//! encoder = "auto"            # auto | v4l2m2m | x264 | openh264
//! cursor = "auto"            # auto | video | off; true = auto, false = off
//! capture = "auto"           # auto | ext | wlr (auto: wlr on Hyprland < 0.57)
//!
//! [receiver."3F2A9C1E-..."]   # id (from `od-sender list`) or Bonjour name
//! position = "auto-left"
//! scale = 2
//! bitrate-mbps = 30
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use clap::ValueEnum;
use serde::Deserialize;

use crate::backend::Position;
use crate::backend::capture::CaptureChoice;
use crate::desktop::ScalePolicy;
use crate::encoder;
use crate::session::CursorMode;

/// `scale` is a word (`passthrough`, `mac`) or a number.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(untagged)]
enum ScaleValue {
    Number(f64),
    Word(String),
}

impl ScaleValue {
    fn policy(&self) -> Result<ScalePolicy> {
        match self {
            ScaleValue::Number(n) => n.to_string().parse(),
            ScaleValue::Word(w) => w.parse(),
        }
        .map_err(|e: String| anyhow!("scale: {e}"))
    }
}

/// `cursor` is a bool (true = auto, false = off) or a mode name.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(untagged)]
enum CursorValue {
    Bool(bool),
    Word(String),
}

impl CursorValue {
    fn mode(&self) -> Result<CursorMode> {
        match self {
            CursorValue::Bool(true) => Ok(CursorMode::Auto),
            CursorValue::Bool(false) => Ok(CursorMode::Off),
            CursorValue::Word(w) => {
                CursorMode::from_str(w, true).map_err(|m| anyhow!("cursor: {m}"))
            }
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct RawOverride {
    position: Option<String>,
    scale: Option<ScaleValue>,
    bitrate_mbps: Option<f32>,
    workspace: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct RawConfig {
    to: Option<String>,
    position: Option<String>,
    scale: Option<ScaleValue>,
    bitrate_mbps: Option<f32>,
    max_fps: Option<f32>,
    encoder: Option<String>,
    cursor: Option<CursorValue>,
    capture: Option<String>,
    workspace: Option<String>,
    #[serde(default)]
    receiver: BTreeMap<String, RawOverride>,
}

/// The settings that can differ per receiver. `None` = not set at this layer.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Layer {
    pub position: Option<Position>,
    pub scale: Option<ScalePolicy>,
    pub bitrate_mbps: Option<f32>,
    /// Workspace to show on the virtual output (Hyprland, Sway).
    pub workspace: Option<String>,
}

impl Layer {
    /// `self` where set, else `below`.
    pub fn over(&self, below: &Layer) -> Layer {
        Layer {
            position: self.position.or(below.position),
            scale: self.scale.or(below.scale),
            bitrate_mbps: self.bitrate_mbps.or(below.bitrate_mbps),
            workspace: self.workspace.clone().or_else(|| below.workspace.clone()),
        }
    }
}

/// A parsed, validated config file.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Config {
    pub to: Option<String>,
    pub max_fps: Option<f32>,
    pub encoder: Option<encoder::Backend>,
    pub capture: Option<CaptureChoice>,
    pub cursor: Option<CursorMode>,
    /// The top-level per-receiver settings.
    pub defaults: Layer,
    /// `[receiver."<key>"]` tables, by id or Bonjour name.
    pub receivers: BTreeMap<String, Layer>,
}

fn layer(
    position: Option<String>,
    scale: Option<ScaleValue>,
    bitrate: Option<f32>,
    workspace: Option<String>,
) -> Result<Layer> {
    if workspace.as_deref().is_some_and(|w| w.trim().is_empty()) {
        anyhow::bail!("workspace: empty");
    }
    if let Some(b) = bitrate {
        if !(b.is_finite() && b > 0.0) {
            anyhow::bail!("bitrate-mbps: {b} is not a positive number");
        }
    }
    Ok(Layer {
        position: position
            .map(|p| p.parse())
            .transpose()
            .context("position")?,
        scale: scale.map(|s| s.policy()).transpose()?,
        bitrate_mbps: bitrate,
        workspace,
    })
}

impl Config {
    pub fn parse(text: &str) -> Result<Config> {
        let raw: RawConfig = toml::from_str(text)?;
        let mut receivers = BTreeMap::new();
        for (key, o) in raw.receiver {
            let l = layer(o.position, o.scale, o.bitrate_mbps, o.workspace)
                .with_context(|| format!("[receiver.\"{key}\"]"))?;
            receivers.insert(key, l);
        }
        Ok(Config {
            to: raw.to,
            max_fps: raw.max_fps,
            encoder: raw
                .encoder
                .map(|e| encoder::Backend::from_str(&e, true).map_err(|m| anyhow!("encoder: {m}")))
                .transpose()?,
            cursor: raw.cursor.map(|c| c.mode()).transpose()?,
            capture: raw
                .capture
                .map(|c| CaptureChoice::from_str(&c, true).map_err(|m| anyhow!("capture: {m}")))
                .transpose()?,
            defaults: layer(raw.position, raw.scale, raw.bitrate_mbps, raw.workspace)?,
            receivers,
        })
    }

    /// Load `path`. A missing file is an empty config unless `required`
    /// (an explicit `--config`).
    pub fn load(path: &Path, required: bool) -> Result<Config> {
        match std::fs::read_to_string(path) {
            Ok(text) => Config::parse(&text).with_context(|| format!("{}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && !required => {
                Ok(Config::default())
            }
            Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
        }
    }

    /// The override for a receiver: the first of `keys` (its id, then its
    /// Bonjour name, then its device name) that has a table. Ids compare
    /// case-insensitively.
    pub fn receiver(&self, keys: &[Option<&str>]) -> Option<(&str, &Layer)> {
        keys.iter().flatten().find_map(|k| {
            self.receivers
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case(k))
                .map(|(name, l)| (name.as_str(), l))
        })
    }
}

/// `$XDG_CONFIG_HOME/opendisplay/sender.toml`, falling back to `~/.config`.
pub fn default_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("opendisplay").join("sender.toml"))
}

/// The built-in defaults, the bottom layer.
pub fn builtin() -> Layer {
    Layer {
        position: Some(Position::AutoRight),
        scale: Some(ScalePolicy::Passthrough),
        bitrate_mbps: Some(20.0),
        workspace: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: &str = r#"
        to = "iPhone"
        position = "auto-left"
        scale = "mac"
        bitrate-mbps = 25
        max-fps = 60
        encoder = "x264"
        cursor = false
        capture = "wlr"

        [receiver."3F2A9C1E-AAAA"]
        position = "-1600,0"
        scale = 2

        [receiver."Mac Studio"]
        bitrate-mbps = 40.5
        scale = "passthrough"
    "#;

    #[test]
    fn a_full_file_parses() {
        let c = Config::parse(FULL).unwrap();
        assert_eq!(c.to.as_deref(), Some("iPhone"));
        assert_eq!(c.max_fps, Some(60.0));
        assert_eq!(c.encoder, Some(encoder::Backend::X264));
        assert_eq!(c.capture, Some(CaptureChoice::Wlr));
        assert!(Config::parse("capture = \"dmabuf\"").is_err());
        assert_eq!(c.cursor, Some(CursorMode::Off));
        let video = Config::parse("cursor = \"video\"").unwrap();
        assert_eq!(video.cursor, Some(CursorMode::Video));
        assert_eq!(
            Config::parse("cursor = true").unwrap().cursor,
            Some(CursorMode::Auto)
        );
        assert_eq!(
            c.defaults,
            Layer {
                position: Some(Position::AutoLeft),
                scale: Some(ScalePolicy::Mac),
                bitrate_mbps: Some(25.0),
                workspace: None,
            }
        );
        let (_, phone) = c.receiver(&[Some("3f2a9c1e-aaaa")]).unwrap();
        assert_eq!(phone.position, Some(Position::At(-1600, 0)));
        assert_eq!(phone.scale, Some(ScalePolicy::Fixed(2.0)));
        assert_eq!(phone.bitrate_mbps, None);
        let (key, mac) = c
            .receiver(&[Some("unknown-id"), Some("Mac Studio")])
            .unwrap();
        assert_eq!(key, "Mac Studio");
        assert_eq!(mac.bitrate_mbps, Some(40.5));
        assert!(c.receiver(&[None, Some("iPad")]).is_none());
    }

    #[test]
    fn the_readme_example_parses() {
        let c = Config::parse(
            "bitrate-mbps = 20\nposition = \"auto-right\"\n\n[receiver.\"3F2A9C1E-...\"]\nposition = \"auto-left\"\nscale = 2\n",
        )
        .unwrap();
        assert_eq!(c.defaults.bitrate_mbps, Some(20.0));
        assert_eq!(c.receivers.len(), 1);
    }

    #[test]
    fn workspace_is_a_default_and_a_receiver_override() {
        let c =
            Config::parse("workspace = \"8\"\n[receiver.phone]\nworkspace = \"web\"\n").unwrap();
        assert_eq!(c.defaults.workspace.as_deref(), Some("8"));
        let (_, phone) = c.receiver(&[Some("phone")]).unwrap();
        assert_eq!(phone.workspace.as_deref(), Some("web"));
        let eff = Layer::default().over(phone).over(&c.defaults);
        assert_eq!(eff.workspace.as_deref(), Some("web"));
        assert!(Config::parse("workspace = \" \"").is_err());
    }

    #[test]
    fn mistakes_are_errors_not_silence() {
        for bad in [
            "bitrate = 20",          // unknown key
            "position = \"middle\"", // bad value
            "scale = \"huge\"",
            "scale = -1",
            "bitrate-mbps = 0",
            "encoder = \"nvenc\"",
            "cursor = \"sometimes\"",
            "[receiver.x]\nmax-fps = 30", // not overridable per receiver
        ] {
            assert!(Config::parse(bad).is_err(), "{bad:?} must not parse");
        }
    }

    #[test]
    fn layers_stack_cli_over_receiver_over_file_over_builtin() {
        let c = Config::parse(FULL).unwrap();
        let cli = Layer {
            bitrate_mbps: Some(8.0),
            ..Layer::default()
        };
        let (_, phone) = c.receiver(&[Some("3F2A9C1E-AAAA")]).unwrap();
        let eff = cli.over(phone).over(&c.defaults).over(&builtin());
        assert_eq!(eff.bitrate_mbps, Some(8.0)); // CLI
        assert_eq!(eff.position, Some(Position::At(-1600, 0))); // receiver
        assert_eq!(eff.scale, Some(ScalePolicy::Fixed(2.0))); // receiver
        let none = Layer::default().over(&Layer::default()).over(&builtin());
        assert_eq!(none, builtin());
    }

    #[test]
    fn a_missing_file_is_fine_unless_asked_for() {
        let p = Path::new("/nonexistent/opendisplay/sender.toml");
        assert_eq!(Config::load(p, false).unwrap(), Config::default());
        assert!(Config::load(p, true).is_err());
    }
}
