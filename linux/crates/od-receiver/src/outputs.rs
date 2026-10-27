//! Enumerate Wayland outputs (`wl_output` v4) to size `hello` from the real
//! panel: physical pixels, refresh, scale, and the name `waylandsink` needs
//! for `fullscreen-output`.

use std::collections::BTreeMap;

use anyhow::{Context, Result, bail};
use wayland_client::protocol::{wl_output, wl_registry};
use wayland_client::{Connection, Dispatch, QueueHandle};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct OutputInfo {
    pub name: String,
    pub description: String,
    /// Current mode, physical pixels.
    pub width: i32,
    pub height: i32,
    pub refresh_mhz: i32,
    pub scale: i32,
}

impl OutputInfo {
    /// Whole Hz, or `None` when the output does not know (headless and
    /// virtual outputs report 0): announcing that as 1 Hz would cap the
    /// sender at one frame per second.
    pub fn refresh_hz(&self) -> Option<u32> {
        (self.refresh_mhz >= 1000).then(|| ((self.refresh_mhz as f64) / 1000.0).round() as u32)
    }
}

#[derive(Default)]
struct State {
    outputs: BTreeMap<u32, OutputInfo>,
    too_old: bool,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            if interface == "wl_output" {
                if version < 4 {
                    // Pre-v4 outputs have no `name` event; we cannot address them.
                    state.too_old = true;
                    return;
                }
                registry.bind::<wl_output::WlOutput, _, _>(name, 4, qh, name);
                state.outputs.insert(name, OutputInfo::default());
            }
        }
    }
}

impl Dispatch<wl_output::WlOutput, u32> for State {
    fn event(
        state: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        global: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(info) = state.outputs.get_mut(global) else {
            return;
        };
        match event {
            wl_output::Event::Mode {
                flags,
                width,
                height,
                refresh,
            } => {
                if flags
                    .into_result()
                    .is_ok_and(|f| f.contains(wl_output::Mode::Current))
                {
                    info.width = width;
                    info.height = height;
                    info.refresh_mhz = refresh;
                }
            }
            wl_output::Event::Scale { factor } => info.scale = factor,
            wl_output::Event::Name { name } => info.name = name,
            wl_output::Event::Description { description } => info.description = description,
            _ => {}
        }
    }
}

/// All outputs of the compositor named by `WAYLAND_DISPLAY`.
pub fn enumerate() -> Result<Vec<OutputInfo>> {
    let conn = Connection::connect_to_env().context("connecting to the Wayland display")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut state = State::default();
    queue.roundtrip(&mut state).context("registry roundtrip")?;
    queue.roundtrip(&mut state).context("output roundtrip")?;
    if state.too_old && state.outputs.is_empty() {
        bail!("compositor exposes wl_output < v4; pass --width/--height/--output explicitly");
    }
    Ok(state
        .outputs
        .into_values()
        .filter(|o| o.width > 0 && o.height > 0)
        .collect())
}

/// Pick the output named `name`, or the first one.
pub fn pick(outputs: &[OutputInfo], name: Option<&str>) -> Result<OutputInfo> {
    match name {
        Some(n) => outputs
            .iter()
            .find(|o| o.name == n)
            .cloned()
            .with_context(|| {
                format!(
                    "no output named {n}; have: {}",
                    outputs
                        .iter()
                        .map(|o| o.name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            }),
        None => outputs.first().cloned().context("no Wayland outputs found"),
    }
}

#[cfg(test)]
mod tests {
    use super::OutputInfo;

    #[test]
    fn unknown_refresh_is_absent_not_one_hertz() {
        let o = |refresh_mhz| OutputInfo {
            name: "HEADLESS-1".into(),
            description: String::new(),
            width: 1280,
            height: 720,
            refresh_mhz,
            scale: 1,
        };
        assert_eq!(o(0).refresh_hz(), None);
        assert_eq!(o(59_940).refresh_hz(), Some(60));
        assert_eq!(o(119_800).refresh_hz(), Some(120));
    }
}
