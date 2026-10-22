//! Scale and place a KWin output through `kde_output_management_v2`, the
//! protocol KDE's own display settings use. KWin picks a new output's scale
//! from its DPI and ignores the one zkde_screencast asks for, so the KDE
//! backend sets it here, together with `--position`, like the other backends.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use wayland_client::backend::ObjectId;
use wayland_client::protocol::wl_registry;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, event_created_child};

use super::protocols::output_device::{
    kde_output_device_mode_v2 as kmode, kde_output_device_registry_v2 as kregistry,
    kde_output_device_v2 as kdevice,
};
use super::protocols::output_management::{
    kde_output_configuration_v2 as kconfig, kde_output_management_v2 as kmgmt,
};
use crate::backend::{LayoutRect, Position, place};
use crate::wayland::dispatch_with_timeout;

#[derive(Default)]
struct Device {
    proxy: Option<kdevice::KdeOutputDeviceV2>,
    name: String,
    x: i32,
    y: i32,
    scale: f64,
    enabled: bool,
    current_mode: Option<ObjectId>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Outcome {
    Applied,
    Failed,
}

#[derive(Default)]
struct State {
    management: Option<kmgmt::KdeOutputManagementV2>,
    devices: HashMap<ObjectId, Device>,
    modes: HashMap<ObjectId, (i32, i32)>,
    outcome: Option<Outcome>,
    reason: Option<String>,
}

impl State {
    fn logical(&self, d: &Device) -> Option<LayoutRect> {
        let (w, h) = *self.modes.get(d.current_mode.as_ref()?)?;
        let s = if d.scale > 0.0 { d.scale } else { 1.0 };
        Some(LayoutRect {
            x: d.x,
            y: d.y,
            width: (w as f64 / s).round() as i32,
            height: (h as f64 / s).round() as i32,
        })
    }
}

/// Where [`configure`] put the output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    /// Top-left, logical.
    pub x: i32,
    pub y: i32,
    /// The other outputs moved to keep the layout at 0,0 (left/up placement).
    pub shifted_others: bool,
}

type Session = (
    Connection,
    wayland_client::EventQueue<State>,
    State,
    kmgmt::KdeOutputManagementV2,
);

fn session() -> Result<Session> {
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State::default();
    // Registry, then the device announcements, then their properties.
    for _ in 0..3 {
        queue.roundtrip(&mut st)?;
    }
    let management = st
        .management
        .clone()
        .context("KWin does not offer kde_output_management_v2")?;
    Ok((conn, queue, st, management))
}

/// Apply `config` and wait for KWin's verdict.
fn apply(
    conn: &Connection,
    queue: &mut wayland_client::EventQueue<State>,
    st: &mut State,
    config: kconfig::KdeOutputConfigurationV2,
) -> Result<()> {
    st.outcome = None;
    st.reason = None;
    config.apply();
    let deadline = Instant::now() + Duration::from_secs(5);
    while st.outcome.is_none() {
        if Instant::now() > deadline {
            bail!("KWin did not answer the output configuration within 5 s");
        }
        dispatch_with_timeout(conn, queue, st, Duration::from_millis(100))?;
    }
    config.destroy();
    let _ = conn.flush();
    match st.outcome {
        Some(Outcome::Applied) => Ok(()),
        _ => bail!("{}", st.reason.as_deref().unwrap_or("no reason given")),
    }
}

/// Set `name`'s scale and put it at `position` relative to the other
/// enabled outputs.
pub fn configure(name: &str, scale: f64, position: Position) -> Result<Placement> {
    let (conn, mut queue, mut st, management) = session()?;
    let qh = queue.handle();
    let ours = st
        .devices
        .iter()
        .find(|(_, d)| d.name == name)
        .map(|(id, _)| id.clone())
        .with_context(|| {
            format!(
                "no KDE output device {name}; have {:?}",
                st.devices.values().map(|d| &d.name).collect::<Vec<_>>()
            )
        })?;
    let mode = st.devices[&ours]
        .current_mode
        .as_ref()
        .and_then(|m| st.modes.get(m))
        .copied()
        .with_context(|| format!("{name} has no current mode"))?;
    let others: Vec<(ObjectId, LayoutRect)> = st
        .devices
        .iter()
        .filter(|(id, d)| **id != ours && d.enabled)
        .filter_map(|(id, d)| Some((id.clone(), st.logical(d)?)))
        .collect();
    let (w, h) = (
        (mode.0 as f64 / scale).round() as i32,
        (mode.1 as f64 / scale).round() as i32,
    );
    let rects: Vec<LayoutRect> = others.iter().map(|(_, r)| *r).collect();
    let wanted = place(position, w, h, &rects);
    // KWin wants the layout's top-left at 0,0 (it refuses negative
    // positions), so left/up of everything shifts the other outputs instead,
    // as KDE's display settings do.
    let (dx, dy) = normalize(wanted, &rects);
    let (x, y) = (wanted.0 + dx, wanted.1 + dy);

    let device = st.devices[&ours].proxy.clone().context("device proxy")?;
    let config = management.create_configuration(&qh, ());
    config.scale(&device, scale);
    config.position(&device, x, y);
    if (dx, dy) != (0, 0) {
        for (id, r) in &others {
            if let Some(p) = &st.devices[id].proxy {
                config.position(p, r.x + dx, r.y + dy);
            }
        }
    }
    apply(&conn, &mut queue, &mut st, config)
        .with_context(|| format!("KWin refused scale {scale} at {x},{y} for {name}"))?;
    Ok(Placement {
        x,
        y,
        shifted_others: (dx, dy) != (0, 0),
    })
}

/// After `gone` was removed: move the remaining outputs back so the layout
/// starts at 0,0 again, undoing the shift a left/up placement made.
pub fn restore_origin(gone: &str) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(2);
    let s = loop {
        let s = session()?;
        if !s.2.devices.values().any(|d| d.name == gone) || Instant::now() > deadline {
            break s;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    move_to_origin(s, |name| name == gone).map(|_| ())
}

/// `od-sender clean`: undo the shift a sender killed during a left/up
/// placement left behind. Our own outputs vanish with
/// their sender; only the user's outputs can be offset. Returns the shift.
pub fn reset_origin() -> Result<Option<(i32, i32)>> {
    move_to_origin(session()?, |name| name.starts_with("Virtual-od-"))
}

/// Shift every enabled output not `skip`ped so the layout's top-left is 0,0.
fn move_to_origin(
    (conn, mut queue, mut st, management): Session,
    skip: impl Fn(&str) -> bool,
) -> Result<Option<(i32, i32)>> {
    let enabled: Vec<(ObjectId, LayoutRect)> = st
        .devices
        .iter()
        .filter(|(_, d)| d.enabled && !skip(&d.name))
        .filter_map(|(id, d)| Some((id.clone(), st.logical(d)?)))
        .collect();
    let min_x = enabled.iter().map(|(_, r)| r.x).min().unwrap_or(0);
    let min_y = enabled.iter().map(|(_, r)| r.y).min().unwrap_or(0);
    if (min_x, min_y) == (0, 0) || enabled.is_empty() {
        return Ok(None);
    }
    let qh = queue.handle();
    let config = management.create_configuration(&qh, ());
    for (id, r) in &enabled {
        if let Some(p) = &st.devices[id].proxy {
            config.position(p, r.x - min_x, r.y - min_y);
        }
    }
    apply(&conn, &mut queue, &mut st, config).context("restoring the output layout")?;
    Ok(Some((-min_x, -min_y)))
}

/// The shift that puts the layout (ours at `at`, plus `others`) at 0,0:
/// out of negative coordinates, which KWin refuses, and back from a
/// positive offset a killed sender's left/up placement left behind.
pub fn normalize(at: (i32, i32), others: &[LayoutRect]) -> (i32, i32) {
    let min_x = others.iter().map(|r| r.x).chain([at.0]).min().unwrap_or(0);
    let min_y = others.iter().map(|r| r.y).chain([at.1]).min().unwrap_or(0);
    (-min_x, -min_y)
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
        let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        else {
            return;
        };
        match interface.as_str() {
            "kde_output_management_v2" => {
                state.management = Some(registry.bind(name, version.min(22), qh, ()));
            }
            // KWin >= 6.5 announces devices through a registry object.
            "kde_output_device_registry_v2" => {
                let _: kregistry::KdeOutputDeviceRegistryV2 =
                    registry.bind(name, version.min(26), qh, ());
            }
            // Older KWin: one global per device.
            "kde_output_device_v2" => {
                let d: kdevice::KdeOutputDeviceV2 = registry.bind(name, version.min(26), qh, ());
                state.devices.insert(
                    d.id(),
                    Device {
                        proxy: Some(d),
                        ..Default::default()
                    },
                );
            }
            _ => {}
        }
    }
}

impl Dispatch<kregistry::KdeOutputDeviceRegistryV2, ()> for State {
    fn event(
        state: &mut Self,
        _: &kregistry::KdeOutputDeviceRegistryV2,
        event: kregistry::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let kregistry::Event::Output { output } = event {
            state.devices.insert(
                output.id(),
                Device {
                    proxy: Some(output),
                    ..Default::default()
                },
            );
        }
    }

    event_created_child!(State, kregistry::KdeOutputDeviceRegistryV2, [
        kregistry::EVT_OUTPUT_OPCODE => (kdevice::KdeOutputDeviceV2, ()),
    ]);
}

impl Dispatch<kdevice::KdeOutputDeviceV2, ()> for State {
    fn event(
        state: &mut Self,
        device: &kdevice::KdeOutputDeviceV2,
        event: kdevice::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(d) = state.devices.get_mut(&device.id()) else {
            return;
        };
        match event {
            kdevice::Event::Name { name } => d.name = name,
            kdevice::Event::Geometry { x, y, .. } => (d.x, d.y) = (x, y),
            kdevice::Event::Scale { factor } => d.scale = factor,
            kdevice::Event::Enabled { enabled } => d.enabled = enabled != 0,
            kdevice::Event::CurrentMode { mode } => d.current_mode = Some(mode.id()),
            kdevice::Event::Removed => {
                state.devices.remove(&device.id());
            }
            _ => {}
        }
    }

    event_created_child!(State, kdevice::KdeOutputDeviceV2, [
        kdevice::EVT_MODE_OPCODE => (kmode::KdeOutputDeviceModeV2, ()),
    ]);
}

impl Dispatch<kmode::KdeOutputDeviceModeV2, ()> for State {
    fn event(
        state: &mut Self,
        mode: &kmode::KdeOutputDeviceModeV2,
        event: kmode::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let kmode::Event::Size { width, height } = event {
            state.modes.insert(mode.id(), (width, height));
        }
    }
}

impl Dispatch<kconfig::KdeOutputConfigurationV2, ()> for State {
    fn event(
        state: &mut Self,
        _: &kconfig::KdeOutputConfigurationV2,
        event: kconfig::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            kconfig::Event::Applied => state.outcome = Some(Outcome::Applied),
            kconfig::Event::Failed => state.outcome = Some(Outcome::Failed),
            kconfig::Event::FailureReason { reason } => state.reason = Some(reason),
        }
    }
}

impl Dispatch<kmgmt::KdeOutputManagementV2, ()> for State {
    fn event(
        _: &mut Self,
        _: &kmgmt::KdeOutputManagementV2,
        _: kmgmt::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

#[cfg(test)]
mod tests {
    use super::normalize;
    use crate::backend::{LayoutRect, Position, place};

    #[test]
    fn left_of_everything_shifts_the_rest_right() {
        let laptop = LayoutRect {
            x: 0,
            y: 0,
            width: 1280,
            height: 720,
        };
        let at = place(Position::AutoLeft, 512, 384, &[laptop]);
        assert_eq!(at, (-512, 0));
        assert_eq!(normalize(at, &[laptop]), (512, 0));
        let at = place(Position::AutoUp, 512, 384, &[laptop]);
        assert_eq!(normalize(at, &[laptop]), (0, 384));
        // Right of or below: nothing moves.
        let at = place(Position::AutoRight, 512, 384, &[laptop]);
        assert_eq!(normalize(at, &[laptop]), (0, 0));
        // A killed sender left the laptop shifted right: back to 0,0.
        let stale = LayoutRect { x: 512, ..laptop };
        let at = place(Position::AutoRight, 512, 384, &[stale]);
        assert_eq!(at, (1792, 0));
        assert_eq!(normalize(at, &[stale]), (-512, 0));
    }
}
