//! Input injection for `touch` / `scroll` (§6.1) through
//! `zwlr_virtual_pointer_v1`, targeted at the virtual output so normalised
//! coordinates (§7) map onto it directly. Runs on its own thread because a
//! Wayland event queue is not `Send`.

use std::collections::HashMap;
use std::sync::mpsc;
use std::time::Instant;

use anyhow::{Context, Result, bail};
use opendisplay_proto::control::{Scroll, Touch, TouchPhase};
use tracing::{debug, warn};
use wayland_client::protocol::{wl_output, wl_pointer, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1, zwlr_virtual_pointer_v1,
};

const BTN_LEFT: u32 = 0x110;

#[derive(Debug)]
pub enum InputCmd {
    Touch(Touch),
    Scroll(Scroll),
    /// Move without pressing (used by the self-test).
    Move {
        x: f64,
        y: f64,
    },
    Stop,
}

struct State {
    seat: Option<wl_seat::WlSeat>,
    outputs: HashMap<u32, (wl_output::WlOutput, String, (i32, i32))>,
    manager: Option<zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1>,
    manager_version: u32,
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
            match interface.as_str() {
                "wl_seat" if state.seat.is_none() => {
                    state.seat = Some(registry.bind(name, 1, qh, ()))
                }
                "wl_output" if version >= 4 => {
                    let o: wl_output::WlOutput = registry.bind(name, 4, qh, name);
                    state.outputs.insert(name, (o, String::new(), (0, 0)));
                }
                "zwlr_virtual_pointer_manager_v1" => {
                    let v = version.min(2);
                    state.manager_version = v;
                    state.manager = Some(registry.bind(name, v, qh, ()));
                }
                _ => {}
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
        let Some(o) = state.outputs.get_mut(global) else {
            return;
        };
        match event {
            wl_output::Event::Name { name } => o.1 = name,
            wl_output::Event::Mode {
                flags,
                width,
                height,
                ..
            } if flags
                .into_result()
                .is_ok_and(|f| f.contains(wl_output::Mode::Current)) =>
            {
                o.2 = (width, height);
            }
            _ => {}
        }
    }
}

macro_rules! noop_dispatch {
    ($($t:ty),*) => {$(
        impl Dispatch<$t, ()> for State {
            fn event(_: &mut Self, _: &$t, _: <$t as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
    )*};
}
noop_dispatch!(
    wl_seat::WlSeat,
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1
);

pub struct InputInjector {
    tx: mpsc::Sender<InputCmd>,
}

impl InputInjector {
    /// Start the injector thread for the output named `output_name`;
    /// `scale` is `hello.scale`, used to turn video pixels into logical pixels
    /// for scroll deltas.
    pub fn start(output_name: &str, scale: f64) -> Result<InputInjector> {
        let (tx, rx) = mpsc::channel::<InputCmd>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<()>>();
        let name = output_name.to_string();
        std::thread::Builder::new()
            .name("input".into())
            .spawn(move || {
                let r = injector_thread(&name, scale, rx, &ready_tx);
                if let Err(e) = r {
                    let _ = ready_tx.send(Err(e));
                }
            })?;
        ready_rx.recv().context("input thread died")??;
        Ok(InputInjector { tx })
    }

    pub fn send(&self, cmd: InputCmd) {
        let _ = self.tx.send(cmd);
    }
}

impl Drop for InputInjector {
    fn drop(&mut self) {
        let _ = self.tx.send(InputCmd::Stop);
    }
}

fn injector_thread(
    output_name: &str,
    scale: f64,
    rx: mpsc::Receiver<InputCmd>,
    ready: &mpsc::Sender<Result<()>>,
) -> Result<()> {
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State {
        seat: None,
        outputs: HashMap::new(),
        manager: None,
        manager_version: 0,
    };
    queue.roundtrip(&mut st)?;
    queue.roundtrip(&mut st)?;
    let manager = st
        .manager
        .clone()
        .context("compositor lacks zwlr_virtual_pointer_manager_v1")?;
    let (output, _, (w, h)) = st
        .outputs
        .values()
        .find(|(_, n, _)| n == output_name)
        .cloned()
        .with_context(|| format!("no output {output_name}"))?;
    if w <= 0 || h <= 0 {
        bail!("output {output_name} has no mode yet");
    }
    let pointer = if st.manager_version >= 2 {
        manager.create_virtual_pointer_with_output(st.seat.as_ref(), Some(&output), &qh, ())
    } else {
        warn!(
            "virtual pointer manager v1: cannot bind to the output; absolute motion uses the whole layout"
        );
        manager.create_virtual_pointer(st.seat.as_ref(), &qh, ())
    };
    let _ = ready.send(Ok(()));
    let start = Instant::now();
    let time = |start: Instant| start.elapsed().as_millis() as u32;
    // Extents are the output's physical size; x/y are normalised (§7).
    let (xe, ye) = (w as u32, h as u32);
    let to_abs = |x: f64, y: f64| {
        (
            (x.clamp(0.0, 1.0) * xe as f64).round() as u32,
            (y.clamp(0.0, 1.0) * ye as f64).round() as u32,
        )
    };
    let mut pressed = false;
    for cmd in rx {
        match cmd {
            InputCmd::Stop => break,
            InputCmd::Move { x, y } => {
                let (ax, ay) = to_abs(x, y);
                pointer.motion_absolute(time(start), ax, ay, xe, ye);
                pointer.frame();
            }
            InputCmd::Touch(t) => {
                let (ax, ay) = to_abs(t.x, t.y);
                pointer.motion_absolute(time(start), ax, ay, xe, ye);
                pointer.frame();
                match t.phase {
                    TouchPhase::Began => {
                        if !pressed {
                            pointer.button(time(start), BTN_LEFT, wl_pointer::ButtonState::Pressed);
                            pointer.frame();
                            pressed = true;
                        }
                    }
                    TouchPhase::Moved => {}
                    TouchPhase::Ended | TouchPhase::Cancelled => {
                        if pressed {
                            pointer.button(
                                time(start),
                                BTN_LEFT,
                                wl_pointer::ButtonState::Released,
                            );
                            pointer.frame();
                            pressed = false;
                        }
                    }
                }
            }
            InputCmd::Scroll(s) => {
                // §6.1: deltas in video pixels with natural-scrolling sign
                // (content follows the fingers). wl_pointer's positive vertical
                // axis scrolls content up, so the sign flips; units are logical pixels.
                pointer.axis_source(wl_pointer::AxisSource::Finger);
                if s.dy != 0.0 {
                    pointer.axis(time(start), wl_pointer::Axis::VerticalScroll, -s.dy / scale);
                }
                if s.dx != 0.0 {
                    pointer.axis(
                        time(start),
                        wl_pointer::Axis::HorizontalScroll,
                        -s.dx / scale,
                    );
                }
                pointer.frame();
            }
        }
        conn.flush()?;
        queue.dispatch_pending(&mut st)?;
    }
    if pressed {
        pointer.button(time(start), BTN_LEFT, wl_pointer::ButtonState::Released);
        pointer.frame();
    }
    pointer.destroy();
    let _ = queue.roundtrip(&mut st);
    debug!("input thread done");
    Ok(())
}
