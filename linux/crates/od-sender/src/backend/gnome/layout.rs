//! Scale and position for our virtual monitor through
//! `org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig`. The call replaces the
//! whole layout, so every other logical monitor is passed through exactly
//! as `GetCurrentState` reports it: mode, scale, transform, primary, and the
//! per-monitor colour mode, RGB range and underscanning. Method 1
//! (temporary): nothing is written to monitors.xml, and Mutter restores the
//! previous layout when the virtual monitor goes away.

use std::collections::HashMap;

use anyhow::{Result, bail};
use zbus::zvariant::{OwnedValue, Type, Value};

use super::mutter::State;
use crate::backend::Position;

/// One logical monitor of `ApplyMonitorsConfig`: `(iiduba(ssa{sv}))`.
#[derive(Debug, PartialEq, serde::Serialize, Type)]
pub struct LogicalConfig {
    pub x: i32,
    pub y: i32,
    pub scale: f64,
    pub transform: u32,
    pub primary: bool,
    pub monitors: Vec<(String, String, HashMap<String, OwnedValue>)>,
}

/// `layout-mode` 1 positions in logical pixels, 2 in physical ones.
fn logical_layout(state: &State) -> bool {
    state
        .3
        .get("layout-mode")
        .and_then(|v| u32::try_from(v).ok())
        .is_none_or(|m| m == 1)
}

/// The scale nearest to `want` among the ones Mutter supports for the mode.
pub fn nearest_scale(supported: &[f64], want: f64) -> f64 {
    supported
        .iter()
        .copied()
        .min_by(|a, b| (a - want).abs().total_cmp(&(b - want).abs()))
        .unwrap_or(1.0)
}

/// The per-monitor properties `ApplyMonitorsConfig` takes, carried over from
/// `GetCurrentState` so the user's settings survive.
fn carried_props(props: &HashMap<String, OwnedValue>) -> HashMap<String, OwnedValue> {
    let mut out = HashMap::new();
    for (from, to) in [
        ("color-mode", "color-mode"),
        ("rgb-range", "rgb-range"),
        ("is-underscanning", "enable_underscanning"),
    ] {
        if let Some(v) = props.get(from).and_then(|v| v.try_clone().ok()) {
            out.insert(to.to_string(), v);
        }
    }
    out
}

/// A complete configuration with `connector` at `scale` (nearest supported)
/// and `position`; everything else unchanged. Returns the configs and the
/// scale applied.
pub fn plan(
    state: &State,
    connector: &str,
    scale: f64,
    position: Position,
) -> Result<(Vec<LogicalConfig>, f64)> {
    let current = |c: &str| {
        state.1.iter().find(|m| m.0.0 == c).and_then(|m| {
            m.1.iter()
                .find(|mode| mode.is_current())
                .map(|mode| (m, mode))
        })
    };
    let Some((_, our_mode)) = current(connector) else {
        bail!("{connector} has no current mode");
    };
    let scale = nearest_scale(&our_mode.5, scale);
    let logical = logical_layout(state);
    // Size in layout units for a mode at a scale.
    let size = |w: i32, h: i32, s: f64| {
        if logical {
            ((w as f64 / s).round() as i32, (h as f64 / s).round() as i32)
        } else {
            (w, h)
        }
    };
    let (ow, oh) = size(our_mode.1, our_mode.2, scale);

    let mut others = Vec::new();
    for l in &state.2 {
        if l.5.iter().any(|(c, ..)| c == connector) {
            continue;
        }
        let mut monitors = Vec::new();
        let mut extent = (0, 0);
        for (c, ..) in &l.5 {
            let Some((m, mode)) = current(c) else {
                bail!("{c} has no current mode");
            };
            // A rotated monitor swaps width and height in the layout.
            let (w, h) = if l.3 % 2 == 1 {
                (mode.2, mode.1)
            } else {
                (mode.1, mode.2)
            };
            let (w, h) = size(w, h, l.2);
            extent = (extent.0.max(w), extent.1.max(h));
            monitors.push((c.clone(), mode.0.clone(), carried_props(&m.2)));
        }
        others.push((
            LogicalConfig {
                x: l.0,
                y: l.1,
                scale: l.2,
                transform: l.3,
                primary: l.4,
                monitors,
            },
            extent,
        ));
    }

    let right = others.iter().map(|(c, e)| c.x + e.0).max().unwrap_or(0);
    let bottom = others.iter().map(|(c, e)| c.y + e.1).max().unwrap_or(0);
    let (mut x, mut y) = match position {
        Position::AutoRight => (right, 0),
        Position::AutoDown => (0, bottom),
        Position::AutoLeft => (-ow, 0),
        Position::AutoUp => (0, -oh),
        Position::At(x, y) => (x, y),
    };
    let mut configs: Vec<LogicalConfig> = others.into_iter().map(|(c, _)| c).collect();
    // Mutter wants the layout's top-left at 0,0: shift everything.
    let min_x = configs.iter().map(|c| c.x).chain([x]).min().unwrap_or(0);
    let min_y = configs.iter().map(|c| c.y).chain([y]).min().unwrap_or(0);
    for c in &mut configs {
        c.x -= min_x;
        c.y -= min_y;
    }
    x -= min_x;
    y -= min_y;
    configs.push(LogicalConfig {
        x,
        y,
        scale,
        transform: 0,
        primary: false,
        monitors: vec![(connector.to_string(), our_mode.0.clone(), HashMap::new())],
    });
    Ok((configs, scale))
}

/// `ApplyMonitorsConfig(serial, 1 = temporary, configs, {})`.
pub fn body(
    state: &State,
    configs: Vec<LogicalConfig>,
) -> (
    u32,
    u32,
    Vec<LogicalConfig>,
    HashMap<String, Value<'static>>,
) {
    (state.0, 1, configs, HashMap::new())
}

#[cfg(test)]
mod tests {
    use super::super::mutter::{Logical, Mode, Monitor};
    use super::*;

    fn mode(id: &str, w: i32, h: i32, scales: &[f64], current: bool) -> Mode {
        let mut p = HashMap::new();
        if current {
            p.insert("is-current".to_string(), OwnedValue::from(true));
        }
        Mode(id.into(), w, h, 60.0, 1.0, scales.to_vec(), p)
    }

    fn connector(c: &str) -> (String, String, String, String) {
        (c.into(), "v".into(), "p".into(), "s".into())
    }

    /// A laptop panel at 2x (rgb-range full), a rotated monitor at 1x, and
    /// our virtual monitor Mutter put on the right at 1x.
    fn state() -> State {
        let mut panel_props = HashMap::new();
        panel_props.insert("rgb-range".to_string(), OwnedValue::from(2u32));
        panel_props.insert("is-underscanning".to_string(), OwnedValue::from(false));
        panel_props.insert("display-name".to_string(), OwnedValue::from(true));
        let mut props = HashMap::new();
        props.insert("layout-mode".to_string(), OwnedValue::from(1u32));
        State(
            9,
            vec![
                Monitor(
                    connector("eDP-1"),
                    vec![mode("3024x1964@120", 3024, 1964, &[1.0, 2.0], true)],
                    panel_props,
                ),
                Monitor(
                    connector("DP-1"),
                    vec![mode("1920x1080@60", 1920, 1080, &[1.0], true)],
                    HashMap::new(),
                ),
                Monitor(
                    connector("Meta-1"),
                    vec![mode("1170x2532@120", 1170, 2532, &[1.0, 1.5, 2.0], true)],
                    HashMap::new(),
                ),
            ],
            vec![
                Logical(0, 0, 2.0, 0, true, vec![connector("eDP-1")], HashMap::new()),
                // Rotated 90 degrees: 1080 wide in the layout.
                Logical(
                    1512,
                    0,
                    1.0,
                    1,
                    false,
                    vec![connector("DP-1")],
                    HashMap::new(),
                ),
                Logical(
                    2592,
                    0,
                    1.0,
                    0,
                    false,
                    vec![connector("Meta-1")],
                    HashMap::new(),
                ),
            ],
            props,
        )
    }

    fn find<'a>(c: &'a [LogicalConfig], name: &str) -> &'a LogicalConfig {
        c.iter().find(|l| l.monitors[0].0 == name).unwrap()
    }

    #[test]
    fn scale_snaps_to_what_mutter_supports() {
        assert_eq!(nearest_scale(&[1.0, 1.5, 2.0], 3.0), 2.0);
        assert_eq!(nearest_scale(&[1.0, 1.5, 2.0], 1.4), 1.5);
        assert_eq!(nearest_scale(&[], 2.0), 1.0);
    }

    #[test]
    fn others_pass_through_unchanged_and_ours_goes_right() {
        let (c, scale) = plan(&state(), "Meta-1", 3.0, Position::AutoRight).unwrap();
        assert_eq!(scale, 2.0);
        let panel = find(&c, "eDP-1");
        assert_eq!(
            (panel.x, panel.y, panel.scale, panel.primary),
            (0, 0, 2.0, true)
        );
        assert_eq!(panel.monitors[0].1, "3024x1964@120");
        // Only the settings ApplyMonitorsConfig takes, renamed where needed.
        let props = &panel.monitors[0].2;
        assert_eq!(props.len(), 2);
        assert_eq!(
            u32::try_from(props["rgb-range"].try_clone().unwrap()).unwrap(),
            2
        );
        assert!(props.contains_key("enable_underscanning"));
        let dp = find(&c, "DP-1");
        assert_eq!((dp.x, dp.transform), (1512, 1));
        // Right of the rotated monitor: 1512 + 1080.
        let ours = find(&c, "Meta-1");
        assert_eq!(
            (ours.x, ours.y, ours.scale, ours.primary),
            (2592, 0, 2.0, false)
        );
    }

    #[test]
    fn left_and_up_shift_the_others() {
        let (c, _) = plan(&state(), "Meta-1", 2.0, Position::AutoLeft).unwrap();
        // 1170 / 2 = 585 logical pixels wide.
        assert_eq!(find(&c, "Meta-1").x, 0);
        assert_eq!(find(&c, "eDP-1").x, 585);
        assert_eq!(find(&c, "DP-1").x, 1512 + 585);
        let (c, _) = plan(&state(), "Meta-1", 1.0, Position::AutoUp).unwrap();
        assert_eq!((find(&c, "Meta-1").x, find(&c, "Meta-1").y), (0, 0));
        assert_eq!(find(&c, "eDP-1").y, 2532);
    }

    #[test]
    fn an_unknown_connector_is_an_error() {
        assert!(plan(&state(), "Meta-9", 1.0, Position::AutoRight).is_err());
    }

    #[test]
    fn the_body_has_mutters_signature() {
        use zbus::zvariant::DynamicType;
        let (c, _) = plan(&state(), "Meta-1", 1.0, Position::AutoRight).unwrap();
        let b = body(&state(), c);
        assert_eq!(b.signature().to_string(), "(uua(iiduba(ssa{sv}))a{sv})");
        assert_eq!((b.0, b.1), (9, 1));
    }
}
