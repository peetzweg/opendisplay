//! Pointer input on KWin through `org_kde_kwin_fake_input`. KWin offers it to
//! any unsandboxed client from 6.8 on (earlier only to programs listed in a
//! .desktop file's X-KDE-Wayland-Interfaces), and `authenticate` always
//! succeeds. Absolute motion is in global logical coordinates, so the
//! normalised receiver position is mapped through the output's layout rect.

use anyhow::{Context, Result};
use opendisplay_proto::control::{Scroll, Touch, TouchPhase};
use tracing::warn;
use wayland_client::protocol::wl_registry;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};

use super::protocols::fake_input::org_kde_kwin_fake_input as fake;
use crate::backend::{DisplayInfo, InputSink};

const BTN_LEFT: u32 = 0x110;
const AXIS_VERTICAL: u32 = 0;
const AXIS_HORIZONTAL: u32 = 1;

/// The output's place in the global logical layout.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn of(info: &DisplayInfo) -> Self {
        Self {
            x: info.x as f64,
            y: info.y as f64,
            width: info.width as f64 / info.scale,
            height: info.height as f64 / info.scale,
        }
    }

    /// Normalised (§7) to global logical; clamped to stay on the output.
    pub fn map(&self, x: f64, y: f64) -> (f64, f64) {
        let inside = |v: f64, extent: f64| (v.clamp(0.0, 1.0) * extent).min(extent - 0.5).max(0.0);
        (
            self.x + inside(x, self.width),
            self.y + inside(y, self.height),
        )
    }
}

pub struct FakeInput {
    conn: Connection,
    _queue: wayland_client::EventQueue<State>,
    input: fake::OrgKdeKwinFakeInput,
    rect: Rect,
    scale: f64,
    pressed: bool,
}

struct State {
    fake: Option<(fake::OrgKdeKwinFakeInput, u32)>,
}

impl FakeInput {
    pub fn new(info: &DisplayInfo) -> Result<Self> {
        let conn = Connection::connect_to_env().context("connecting to Wayland")?;
        let mut queue = conn.new_event_queue::<State>();
        let qh = queue.handle();
        conn.display().get_registry(&qh, ());
        let mut st = State { fake: None };
        queue.roundtrip(&mut st)?;
        let (input, version) = st.fake.take().context(
            "KWin does not offer org_kde_kwin_fake_input to od-sender (KWin < 6.8 lists it only for programs named in a .desktop file's X-KDE-Wayland-Interfaces)",
        )?;
        if version < 3 {
            warn!("org_kde_kwin_fake_input v{version} has no absolute motion; input will not work");
        }
        input.authenticate(
            "OpenDisplay".into(),
            "Input from the OpenDisplay receiver".into(),
        );
        conn.flush()?;
        Ok(Self {
            conn,
            _queue: queue,
            input,
            rect: Rect::of(info),
            scale: info.scale,
            pressed: false,
        })
    }

    fn button(&mut self, down: bool) {
        if self.pressed != down {
            self.input.button(BTN_LEFT, down as u32);
            self.pressed = down;
        }
    }

    fn flush(&self) {
        if let Err(e) = self.conn.flush() {
            warn!("fake input: {e}");
        }
    }
}

impl InputSink for FakeInput {
    fn touch(&mut self, t: &Touch) {
        let (gx, gy) = self.rect.map(t.x, t.y);
        self.input.pointer_motion_absolute(gx, gy);
        match t.phase {
            TouchPhase::Began => self.button(true),
            TouchPhase::Moved => {}
            TouchPhase::Ended | TouchPhase::Cancelled => self.button(false),
        }
        self.flush();
    }

    fn scroll(&mut self, s: &Scroll) {
        // §6.1: video pixels, natural sign; the axis wants logical pixels
        // with positive = scroll down, as wl_pointer.
        if s.dy != 0.0 {
            self.input.axis(AXIS_VERTICAL, -s.dy / self.scale);
        }
        if s.dx != 0.0 {
            self.input.axis(AXIS_HORIZONTAL, -s.dx / self.scale);
        }
        self.flush();
    }
}

impl Drop for FakeInput {
    fn drop(&mut self) {
        self.button(false);
        if self.input.version() >= 5 {
            self.input.destroy();
        }
        self.flush();
    }
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
            if interface == "org_kde_kwin_fake_input" {
                let v = version.min(6);
                state.fake = Some((registry.bind(name, v, qh, ()), v));
            }
        }
    }
}

impl Dispatch<fake::OrgKdeKwinFakeInput, ()> for State {
    fn event(
        _: &mut Self,
        _: &fake::OrgKdeKwinFakeInput,
        _: fake::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalised_maps_into_the_outputs_logical_rect() {
        let info = DisplayInfo {
            name: "Virtual-od-abc".into(),
            width: 2048,
            height: 1536,
            refresh_hz: 60.0,
            scale: 2.0,
            x: 1280,
            y: 0,
        };
        let r = Rect::of(&info);
        assert_eq!(r.map(0.0, 0.0), (1280.0, 0.0));
        assert_eq!(r.map(0.5, 0.5), (1280.0 + 512.0, 384.0));
        // The far edge stays on the output, not on its right neighbour.
        assert_eq!(r.map(1.0, 1.0), (1280.0 + 1023.5, 767.5));
        assert_eq!(r.map(-1.0, 2.0), (1280.0, 767.5));
    }
}
