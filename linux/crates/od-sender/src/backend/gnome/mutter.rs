//! Mutter's ScreenCast and RemoteDesktop D-Bus APIs (`org.gnome.Mutter.*`),
//! the ones gnome-remote-desktop uses. An unsandboxed client on the session
//! bus may use them without a dialog: Mutter only checks that later calls on
//! a session come from the connection that created it, and closes the
//! session (removing its virtual monitor) when that connection goes away.
//!
//! `RecordVirtual` takes the monitor's mode in `modes` since Mutter 50; older
//! Mutter ignores the key and sizes the monitor from the PipeWire format the
//! consumer negotiates, so the capture asks for the same size.

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;
use tracing::debug;
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Type, Value};

const SC: &str = "org.gnome.Mutter.ScreenCast";
const SC_PATH: &str = "/org/gnome/Mutter/ScreenCast";
const RD: &str = "org.gnome.Mutter.RemoteDesktop";
const RD_PATH: &str = "/org/gnome/Mutter/RemoteDesktop";
const DC: &str = "org.gnome.Mutter.DisplayConfig";
const DC_PATH: &str = "/org/gnome/Mutter/DisplayConfig";

/// `cursor-mode` of `RecordVirtual`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // metadata: the cursor side channel, later
pub enum CursorMode {
    Hidden = 0,
    Embedded = 1,
    Metadata = 2,
}

/// `org.gnome.Mutter.RemoteDesktop.Session.NotifyPointerAxis` flag.
pub const AXIS_SOURCE_FINGER: u32 = 4;

// org.gnome.Mutter.DisplayConfig.GetCurrentState:
// (u a((ssss)a(siiddada{sv})a{sv}) a(iiduba(ssss)a{sv}) a{sv}).
// Every field is spelled out for the signature; not all are read.
#[derive(Debug, Deserialize, Type)]
#[allow(dead_code)]
pub struct Mode(
    pub String,
    pub i32,
    pub i32,
    pub f64,
    pub f64,
    pub Vec<f64>,
    pub HashMap<String, OwnedValue>,
);

#[derive(Debug, Deserialize, Type)]
#[allow(dead_code)]
pub struct Monitor(
    pub (String, String, String, String),
    pub Vec<Mode>,
    pub HashMap<String, OwnedValue>,
);

#[derive(Debug, Deserialize, Type)]
#[allow(dead_code)]
pub struct Logical(
    pub i32,
    pub i32,
    pub f64,
    pub u32,
    pub bool,
    pub Vec<(String, String, String, String)>,
    pub HashMap<String, OwnedValue>,
);

#[derive(Debug, Deserialize, Type)]
#[allow(dead_code)]
pub struct State(
    pub u32,
    pub Vec<Monitor>,
    pub Vec<Logical>,
    pub HashMap<String, OwnedValue>,
);

impl Mode {
    pub fn is_current(&self) -> bool {
        self.6
            .get("is-current")
            .and_then(|v| bool::try_from(v).ok())
            .unwrap_or(false)
    }
}

/// A connector's current mode and place in the layout.
#[derive(Debug, Clone, PartialEq)]
pub struct Placement {
    pub connector: String,
    pub width: u32,
    pub height: u32,
    pub refresh: f64,
    pub x: i32,
    pub y: i32,
    pub scale: f64,
}

impl State {
    pub fn connectors(&self) -> Vec<String> {
        self.1.iter().map(|m| m.0.0.clone()).collect()
    }

    pub fn placement(&self, connector: &str) -> Option<Placement> {
        let m = self.1.iter().find(|m| m.0.0 == connector)?;
        let mode = m.1.iter().find(|m| m.is_current())?;
        let l = self
            .2
            .iter()
            .find(|l| l.5.iter().any(|(c, ..)| c == connector));
        Some(Placement {
            connector: connector.to_string(),
            width: mode.1.max(0) as u32,
            height: mode.2.max(0) as u32,
            refresh: mode.3,
            x: l.map_or(0, |l| l.0),
            y: l.map_or(0, |l| l.1),
            scale: l.map_or(1.0, |l| l.2),
        })
    }
}

pub fn display_state(conn: &Connection) -> Result<State> {
    let reply = conn
        .call_method(Some(DC), DC_PATH, Some(DC), "GetCurrentState", &())
        .context("DisplayConfig.GetCurrentState")?;
    Ok(reply.body().deserialize()?)
}

fn get_property<T>(conn: &Connection, dest: &str, path: &str, iface: &str, name: &str) -> Result<T>
where
    T: TryFrom<OwnedValue>,
    <T as TryFrom<OwnedValue>>::Error: std::fmt::Display,
{
    let props = zbus::blocking::fdo::PropertiesProxy::builder(conn)
        .destination(dest.to_string())?
        .path(path.to_string())?
        .build()?;
    let v = props
        .get(
            zbus::names::InterfaceName::try_from(iface.to_string())?,
            name,
        )
        .with_context(|| format!("{iface}.{name}"))?;
    T::try_from(v).map_err(|e| anyhow!("{iface}.{name}: {e}"))
}

/// Whether Mutter's APIs are on this session bus, and their version.
pub fn probe(conn: &Connection) -> Result<(i32, i32)> {
    // Both are `i` on the bus.
    let sc: i32 = get_property(conn, SC, SC_PATH, SC, "Version")?;
    let rd: i32 = get_property(conn, RD, RD_PATH, RD, "Version")?;
    Ok((sc, rd))
}

/// How long Mutter gets to announce the PipeWire stream after `Start`.
const NODE_WITHIN: Duration = Duration::from_secs(5);

/// Start the RemoteDesktop session `rd` and wait, at most `within`, for the
/// `PipeWireStreamAdded` signal `rule` matches; its node id. The match is
/// removed again when this returns, whatever the outcome.
async fn start_and_wait_for_node(
    conn: &zbus::Connection,
    rule: zbus::MatchRule<'_>,
    rd: &str,
    within: Duration,
) -> Result<u32> {
    use futures_lite::StreamExt;
    let mut signals = zbus::MessageStream::for_match_rule(rule, conn, Some(4)).await?;
    conn.call_method(
        Some(RD),
        rd,
        Some("org.gnome.Mutter.RemoteDesktop.Session"),
        "Start",
        &(),
    )
    .await
    .context("RemoteDesktop.Session.Start")?;
    let added = async {
        while let Some(msg) = signals.next().await {
            if let Ok(node) = msg.and_then(|m| m.body().deserialize::<u32>()) {
                return Ok(node);
            }
        }
        Err(anyhow!(
            "the session bus closed before Mutter announced the stream"
        ))
    };
    let timeout = async {
        async_io::Timer::after(within).await;
        Err(anyhow!(
            "Mutter announced no PipeWire stream within {}s",
            within.as_secs()
        ))
    };
    futures_lite::future::or(added, timeout).await
}

/// One virtual monitor: a RemoteDesktop session (for input) with a linked
/// ScreenCast session recording a virtual monitor. Stopping the
/// RemoteDesktop session, or dropping the connection, removes the monitor.
pub struct VirtualMonitor {
    conn: Connection,
    rd: OwnedObjectPath,
    /// The stream path, the target of absolute pointer motion.
    pub stream: OwnedObjectPath,
    /// PipeWire node of the stream (Mutter's own PipeWire connection).
    pub node: u32,
    pub placement: Placement,
    stopped: bool,
}

pub struct Request {
    pub width: u32,
    pub height: u32,
    pub hz: u32,
    pub cursor: CursorMode,
}

impl VirtualMonitor {
    pub fn create(req: &Request) -> Result<Self> {
        let conn = Connection::session().context("connecting to the session bus")?;
        let before = display_state(&conn)?.connectors();

        let reply = conn
            .call_method(Some(RD), RD_PATH, Some(RD), "CreateSession", &())
            .context("RemoteDesktop.CreateSession")?;
        let rd: OwnedObjectPath = reply.body().deserialize()?;
        // The session exists from here on: build `Self` now so every early
        // return below stops it (Drop), instead of leaving a virtual monitor
        // on the desktop per failed attempt. `stream`, `node` and
        // `placement` are filled in as they become known.
        let mut vm = Self {
            conn,
            stream: rd.clone(),
            rd,
            node: 0,
            placement: Placement {
                connector: String::new(),
                width: req.width,
                height: req.height,
                refresh: req.hz as f64,
                x: 0,
                y: 0,
                scale: 1.0,
            },
            stopped: false,
        };
        let conn = vm.conn.clone();
        let rd_id: String = get_property(
            &conn,
            RD,
            vm.rd.as_str(),
            "org.gnome.Mutter.RemoteDesktop.Session",
            "SessionId",
        )?;

        let mut opts: HashMap<&str, Value> = HashMap::new();
        opts.insert("remote-desktop-session-id", Value::from(rd_id.as_str()));
        let reply = conn
            .call_method(Some(SC), SC_PATH, Some(SC), "CreateSession", &(opts,))
            .context("ScreenCast.CreateSession")?;
        let sc: OwnedObjectPath = reply.body().deserialize()?;

        let mode: HashMap<&str, Value> = HashMap::from([
            ("size", Value::from((req.width, req.height))),
            ("refresh-rate", Value::from(req.hz as f64)),
            ("is-preferred", Value::from(true)),
        ]);
        let props: HashMap<&str, Value> = HashMap::from([
            ("cursor-mode", Value::from(req.cursor as u32)),
            // A real monitor to the shell, not "the screen is shared".
            ("is-platform", Value::from(true)),
            ("modes", Value::from(vec![mode])),
        ]);
        let reply = conn
            .call_method(
                Some(SC),
                sc.as_str(),
                Some("org.gnome.Mutter.ScreenCast.Session"),
                "RecordVirtual",
                &(props,),
            )
            .context("ScreenCast.Session.RecordVirtual")?;
        vm.stream = reply.body().deserialize()?;

        // PipeWireStreamAdded arrives after Start; listen before starting.
        let rule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender(SC)?
            .interface("org.gnome.Mutter.ScreenCast.Stream")?
            .member("PipeWireStreamAdded")?
            .path(vm.stream.as_str())?
            .build();
        vm.node = async_io::block_on(start_and_wait_for_node(
            conn.inner(),
            rule,
            vm.rd.as_str(),
            NODE_WITHIN,
        ))?;

        // The new connector is ours; Mutter names virtual ones Meta-<n>.
        let mut placement = None;
        for _ in 0..20 {
            let state = display_state(&conn)?;
            placement = state
                .connectors()
                .into_iter()
                .find(|c| !before.contains(c))
                .and_then(|c| state.placement(&c));
            if placement.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        match placement {
            Some(p) => vm.placement = p,
            None => bail!("Mutter added no monitor for the stream"),
        }
        debug!("mutter virtual monitor {:?} node {}", vm.placement, vm.node);
        Ok(vm)
    }

    /// Set the monitor's scale (nearest one Mutter supports) and position
    /// with a temporary DisplayConfig change; a no-op when Mutter already
    /// placed it so. Returns the scale in effect.
    pub fn arrange(&mut self, scale: f64, position: crate::backend::Position) -> Result<f64> {
        use super::layout;
        let state = display_state(&self.conn)?;
        let (configs, scale) = layout::plan(&state, &self.placement.connector, scale, position)?;
        let ours = configs
            .iter()
            .find(|c| c.monitors[0].0 == self.placement.connector)
            .map(|c| (c.x, c.y));
        let already = ours == Some((self.placement.x, self.placement.y))
            && (self.placement.scale - scale).abs() < 1e-6;
        if already {
            return Ok(scale);
        }
        self.conn
            .call_method(
                Some(DC),
                DC_PATH,
                Some(DC),
                "ApplyMonitorsConfig",
                &layout::body(&state, configs),
            )
            .context("DisplayConfig.ApplyMonitorsConfig")?;
        let state = display_state(&self.conn)?;
        if let Some(p) = state.placement(&self.placement.connector) {
            self.placement = p;
        }
        Ok(scale)
    }

    /// A handle for input calls, usable from another thread.
    pub fn input(&self) -> InputHandle {
        InputHandle {
            conn: self.conn.clone(),
            rd: self.rd.clone(),
            stream: self.stream.clone(),
        }
    }

    /// Stop the session; Mutter removes the virtual monitor. Idempotent.
    pub fn stop(&mut self) -> Result<()> {
        if self.stopped {
            return Ok(());
        }
        self.stopped = true;
        self.conn
            .call_method(
                Some(RD),
                self.rd.as_str(),
                Some("org.gnome.Mutter.RemoteDesktop.Session"),
                "Stop",
                &(),
            )
            .context("RemoteDesktop.Session.Stop")?;
        Ok(())
    }
}

impl Drop for VirtualMonitor {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// Pointer input into one virtual monitor's stream.
#[derive(Clone)]
pub struct InputHandle {
    conn: Connection,
    rd: OwnedObjectPath,
    stream: OwnedObjectPath,
}

impl InputHandle {
    fn notify<B>(&self, method: &str, body: &B) -> Result<()>
    where
        B: serde::Serialize + zbus::zvariant::DynamicType,
    {
        self.conn
            .call_method(
                Some(RD),
                self.rd.as_str(),
                Some("org.gnome.Mutter.RemoteDesktop.Session"),
                method,
                body,
            )
            .with_context(|| format!("RemoteDesktop.Session.{method}"))?;
        Ok(())
    }

    /// Absolute motion in stream pixels.
    pub fn motion(&self, x: f64, y: f64) -> Result<()> {
        self.notify("NotifyPointerMotionAbsolute", &(self.stream.as_str(), x, y))
    }

    /// `button` is a Linux evdev code (BTN_LEFT = 0x110).
    pub fn button(&self, button: i32, pressed: bool) -> Result<()> {
        self.notify("NotifyPointerButton", &(button, pressed))
    }

    /// Smooth scroll in "pixels of a standardized mouse" (10 = one detent).
    pub fn axis(&self, dx: f64, dy: f64, flags: u32) -> Result<()> {
        self.notify("NotifyPointerAxis", &(dx, dy, flags))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode(w: i32, h: i32, hz: f64, current: bool) -> Mode {
        let mut p = HashMap::new();
        if current {
            p.insert("is-current".to_string(), OwnedValue::from(true));
        }
        Mode(format!("{w}x{h}@{hz}"), w, h, hz, 1.0, vec![1.0, 2.0], p)
    }

    fn connector(c: &str) -> (String, String, String, String) {
        (
            c.into(),
            "MetaVendor".into(),
            "Virtual remote monitor".into(),
            "0x000001".into(),
        )
    }

    /// The shape of the bench's state: the headless monitor and ours.
    fn state() -> State {
        State(
            7,
            vec![
                Monitor(
                    connector("Meta-0"),
                    vec![mode(1280, 800, 60.0, true)],
                    HashMap::new(),
                ),
                Monitor(
                    connector("Meta-1"),
                    vec![mode(1920, 1080, 60.0, false), mode(1170, 2532, 120.0, true)],
                    HashMap::new(),
                ),
            ],
            vec![
                Logical(
                    0,
                    0,
                    1.0,
                    0,
                    true,
                    vec![connector("Meta-0")],
                    HashMap::new(),
                ),
                Logical(
                    1280,
                    0,
                    2.0,
                    0,
                    false,
                    vec![connector("Meta-1")],
                    HashMap::new(),
                ),
            ],
            HashMap::new(),
        )
    }

    #[test]
    fn placement_is_the_current_mode_and_logical_position() {
        let s = state();
        assert_eq!(s.connectors(), ["Meta-0", "Meta-1"]);
        assert_eq!(
            s.placement("Meta-1"),
            Some(Placement {
                connector: "Meta-1".into(),
                width: 1170,
                height: 2532,
                refresh: 120.0,
                x: 1280,
                y: 0,
                scale: 2.0,
            })
        );
        assert_eq!(s.placement("Meta-9"), None);
    }

    #[test]
    fn the_state_signature_matches_mutters() {
        assert_eq!(
            State::SIGNATURE.to_string(),
            "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"
        );
    }
}
