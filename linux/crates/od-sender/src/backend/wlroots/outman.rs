//! Size, scale and place one output through `zwlr_output_manager_v1`, the
//! compositor-neutral wlroots protocol (`wlr-randr` speaks it too). Sway
//! applies custom modes to headless outputs, so no IPC is needed for sizing.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use wayland_client::backend::ObjectId;
use wayland_client::protocol::wl_registry;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, event_created_child};

use wayland_protocols_wlr::output_management::v1::client::{
    zwlr_output_configuration_head_v1, zwlr_output_configuration_v1, zwlr_output_head_v1,
    zwlr_output_manager_v1, zwlr_output_mode_v1,
};

use crate::wayland::dispatch_until;

/// What to apply to the output called `name`.
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub name: String,
    /// Physical pixels.
    pub width: i32,
    pub height: i32,
    /// mHz, 0 for the compositor's choice.
    pub refresh_mhz: i32,
    pub scale: f64,
    /// Layout position, logical pixels.
    pub x: i32,
    pub y: i32,
}

#[derive(Default)]
struct Head {
    proxy: Option<zwlr_output_head_v1::ZwlrOutputHeadV1>,
    name: String,
    enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Outcome {
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Default)]
struct State {
    manager: Option<zwlr_output_manager_v1::ZwlrOutputManagerV1>,
    heads: HashMap<ObjectId, Head>,
    /// Serial of the last `done`, i.e. of a consistent head list.
    serial: Option<u32>,
    outcome: Option<Outcome>,
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
            if interface == "zwlr_output_manager_v1" {
                state.manager = Some(registry.bind(name, version.min(4), qh, ()));
            }
        }
    }
}

impl Dispatch<zwlr_output_manager_v1::ZwlrOutputManagerV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &zwlr_output_manager_v1::ZwlrOutputManagerV1,
        event: zwlr_output_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use zwlr_output_manager_v1::Event;
        match event {
            Event::Head { head } => {
                state.heads.insert(
                    head.id(),
                    Head {
                        proxy: Some(head),
                        ..Default::default()
                    },
                );
            }
            Event::Done { serial } => state.serial = Some(serial),
            _ => {}
        }
    }

    event_created_child!(State, zwlr_output_manager_v1::ZwlrOutputManagerV1, [
        zwlr_output_manager_v1::EVT_HEAD_OPCODE => (zwlr_output_head_v1::ZwlrOutputHeadV1, ()),
    ]);
}

impl Dispatch<zwlr_output_head_v1::ZwlrOutputHeadV1, ()> for State {
    fn event(
        state: &mut Self,
        head: &zwlr_output_head_v1::ZwlrOutputHeadV1,
        event: zwlr_output_head_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use zwlr_output_head_v1::Event;
        match event {
            Event::Name { name } => {
                if let Some(h) = state.heads.get_mut(&head.id()) {
                    h.name = name;
                }
            }
            Event::Enabled { enabled } => {
                if let Some(h) = state.heads.get_mut(&head.id()) {
                    h.enabled = enabled != 0;
                }
            }
            Event::Finished => {
                state.heads.remove(&head.id());
            }
            _ => {}
        }
    }

    event_created_child!(State, zwlr_output_head_v1::ZwlrOutputHeadV1, [
        zwlr_output_head_v1::EVT_MODE_OPCODE => (zwlr_output_mode_v1::ZwlrOutputModeV1, ()),
    ]);
}

impl Dispatch<zwlr_output_configuration_v1::ZwlrOutputConfigurationV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &zwlr_output_configuration_v1::ZwlrOutputConfigurationV1,
        event: zwlr_output_configuration_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use zwlr_output_configuration_v1::Event;
        state.outcome = match event {
            Event::Succeeded => Some(Outcome::Succeeded),
            Event::Failed => Some(Outcome::Failed),
            Event::Cancelled => Some(Outcome::Cancelled),
            _ => state.outcome,
        };
    }
}

macro_rules! ignore {
    ($($t:ty),*) => {$(
        impl Dispatch<$t, ()> for State {
            fn event(_: &mut Self, _: &$t, _: <$t as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
    )*};
}
ignore!(
    zwlr_output_mode_v1::ZwlrOutputModeV1,
    zwlr_output_configuration_head_v1::ZwlrOutputConfigurationHeadV1
);

/// How long the compositor gets to answer one output-management request.
const ANSWER_WITHIN: Duration = Duration::from_secs(5);

/// Apply `t` to its output and leave every other head as it is. Retries when
/// the compositor cancels because the layout changed under us.
pub fn apply(t: &Target) -> Result<()> {
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State::default();
    queue.roundtrip(&mut st)?;
    let manager = st
        .manager
        .clone()
        .context("compositor lacks zwlr_output_manager_v1")?;
    for _attempt in 0..3 {
        dispatch_until(
            &conn,
            &mut queue,
            &mut st,
            Instant::now() + ANSWER_WITHIN,
            "the output layout",
            |st| st.serial.is_some(),
        )?;
        let serial = st.serial.take().unwrap();
        if !st.heads.values().any(|h| h.name == t.name) {
            bail!("output manager has no head {}", t.name);
        }
        let config = manager.create_configuration(serial, &qh, ());
        // Every head must appear in a configuration; the others keep their
        // current state (an enabled head's config starts from it).
        for h in st.heads.values() {
            let Some(proxy) = &h.proxy else { continue };
            if h.name == t.name {
                let ch = config.enable_head(proxy, &qh, ());
                ch.set_custom_mode(t.width, t.height, t.refresh_mhz);
                ch.set_scale(t.scale);
                ch.set_position(t.x, t.y);
            } else if h.enabled {
                config.enable_head(proxy, &qh, ());
            } else {
                config.disable_head(proxy);
            }
        }
        config.apply();
        st.outcome = None;
        dispatch_until(
            &conn,
            &mut queue,
            &mut st,
            Instant::now() + ANSWER_WITHIN,
            "a verdict on the output configuration",
            |st| st.outcome.is_some(),
        )?;
        config.destroy();
        match st.outcome {
            Some(Outcome::Succeeded) => return Ok(()),
            Some(Outcome::Failed) => bail!(
                "compositor refused {}x{}@{}mHz scale {} at {},{} for {}",
                t.width,
                t.height,
                t.refresh_mhz,
                t.scale,
                t.x,
                t.y,
                t.name
            ),
            // Layout changed between `done` and `apply`; a new `done` follows.
            _ => continue,
        }
    }
    bail!("output configuration for {} kept being cancelled", t.name)
}
