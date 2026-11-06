mod backend;
mod bounded;
mod config;
mod desktop;
mod dev;
mod disconnect;
mod discover;
mod doctor;
mod encoder;
mod latest;
#[cfg(feature = "pipewire")]
mod pipewire;
mod session;
mod tailscale;
pub mod usbmux;
mod wayland;

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::Result;
use clap::{Args as ClapArgs, Parser, Subcommand};
use tracing::{error, info};

use backend::detect::{self, Request};
use backend::{BackendId, Position};

/// OpenDisplay sender for Linux: extends a Wayland desktop onto an
/// OpenDisplay receiver.
#[derive(Parser, Debug)]
#[command(version = env!("OD_SENDER_VERSION"), about)]
struct Args {
    /// Target one of several running Hyprland instances, like `hyprctl -i`
    /// (index from `od-sender doctor`, or the full signature). Sets
    /// HYPRLAND_INSTANCE_SIGNATURE and WAYLAND_DISPLAY for this process.
    #[arg(long, global = true, value_name = "SIG|INDEX")]
    instance: Option<String>,
    /// Config file; default `$XDG_CONFIG_HOME/opendisplay/sender.toml`.
    #[arg(long, global = true, value_name = "PATH")]
    config: Option<std::path::PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

/// Which compositor backend to use.
#[derive(ClapArgs, Debug, Clone, Default)]
pub struct BackendArgs {
    /// Force a backend instead of detecting one.
    #[arg(long, value_enum)]
    pub backend: Option<BackendId>,
    /// Use this existing output instead of creating one (adopt mode).
    #[arg(long, value_name = "NAME")]
    pub output: Option<String>,
    /// Capture protocol: auto (wlr-screencopy on Hyprland < 0.57, else
    /// ext-image-copy-capture), ext or wlr [default: auto, or the config
    /// file's `capture`].
    #[arg(long, value_enum)]
    pub capture: Option<backend::capture::CaptureChoice>,
}

impl BackendArgs {
    /// The request, with the config file's `capture` under the flag.
    pub fn request_with(&self, config: Option<backend::capture::CaptureChoice>) -> Request {
        Request {
            backend: self.backend,
            output: self.output.clone(),
            capture: self.capture.or(config).unwrap_or_default(),
        }
    }

    pub fn request(&self) -> Request {
        self.request_with(None)
    }
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Extend the desktop onto a receiver: dial it (or discover it), create a
    /// virtual display sized from its `hello`, capture, encode and stream.
    /// Ctrl+C disconnects.
    #[command(visible_alias = "connect")]
    Run {
        /// Receiver: `host:port`, or a name/id to discover, or `usb` / `usb:<id>`.
        /// Omitted: the only receiver on the network (several: pick one with --to).
        #[arg(long, value_name = "NAME|ID|ADDR|usb")]
        to: Option<String>,
        /// Same as --to: `od-sender connect iMac`.
        #[arg(value_name = "RECEIVER", conflicts_with = "to")]
        receiver: Option<String>,
        /// Connect over USB cable via usbmuxd (Apple devices) (§2.2).
        #[arg(long, conflicts_with_all = ["connect"])]
        usb: bool,
        /// Keep looking until the receiver appears instead of giving up after
        /// 10 s (for the systemd unit and login autostart).
        #[arg(long)]
        wait: bool,
        /// Receiver address (same as `--to host:port`).
        #[arg(long, hide = true, conflicts_with = "to")]
        connect: Option<SocketAddr>,
        /// Only accept a discovered receiver whose name contains this (same as `--to <name>`).
        #[arg(long, hide = true, conflicts_with_all = ["to", "connect"])]
        name: Option<String>,
        /// Target bitrate [default: 20, or the config file's].
        #[arg(long)]
        bitrate_mbps: Option<f32>,
        /// Frame-rate cap; default: 60, or up to the receiver's panel rate
        /// when its decoder advertises more (never above either).
        #[arg(long)]
        max_fps: Option<f32>,
        /// Output scale: `passthrough` (the receiver's own scale), `mac`
        /// (2 for Retina-class panels, else 1, like the Mac sender) or a
        /// number [default: passthrough, or the config file's].
        #[arg(long)]
        scale: Option<desktop::ScalePolicy>,
        /// H.264 encoder backend (#360) [default: auto, or the config file's].
        #[arg(long, value_enum)]
        encoder: Option<encoder::Backend>,
        /// Encoder threads (0 = all cores).
        #[arg(long, default_value_t = 0)]
        threads: u16,
        /// Cursor delivery: `auto` (side channel when the receiver and
        /// compositor support it, else painted into the video), `video`, or
        /// `off` [default: auto, or the config file's].
        #[arg(long, value_enum)]
        cursor: Option<session::CursorMode>,
        /// Same as `--cursor off`.
        #[arg(long, conflicts_with = "cursor")]
        no_cursor: bool,
        /// Position of the virtual display: auto-right, auto-left, auto-up,
        /// auto-down, or "x,y" [default: auto-right, or the config file's].
        #[arg(long)]
        position: Option<Position>,
        /// Show this workspace (name or number) on the virtual display, without
        /// taking focus from your current monitor. Hyprland and Sway [default:
        /// the next free one, or the config file's].
        #[arg(long, value_name = "NAME|ID")]
        workspace: Option<String>,
        /// Leave the virtual display in place when the sender exits (development).
        #[arg(long)]
        keep_output: bool,
        #[arg(long)]
        no_reconnect: bool,
        /// Stop after this many seconds.
        #[arg(long)]
        duration: Option<f64>,
        #[command(flatten)]
        backend: BackendArgs,
    },
    /// List receivers on the local network.
    List {
        /// How long to browse, in seconds.
        #[arg(long, default_value_t = 3.0)]
        timeout: f64,
        /// Print a JSON array of {name, addr, id, pv} (for scripts and agents).
        #[arg(long)]
        json: bool,
    },
    /// Explain what the sender would use here: backend, protocols, encoders.
    /// Exits non-zero on an unsupported desktop.
    Doctor {
        #[command(flatten)]
        backend: BackendArgs,
    },
    /// Disconnect a running sender from any terminal, like Ctrl+C in its own
    /// (all of them when no receiver is named).
    Disconnect {
        /// Receiver name as given to `connect`/`--to`, or the virtual display (od-…).
        #[arg(value_name = "RECEIVER")]
        receiver: Option<String>,
    },
    /// Remove virtual displays left behind by senders that are no longer running.
    Clean {
        #[command(flatten)]
        backend: BackendArgs,
    },
    /// Developer self-tests.
    #[command(hide = true)]
    Dev {
        #[command(subcommand)]
        cmd: dev::Dev,
    },
}

/// A receiver to dial; `id` and the Bonjour name only when discovered.
struct Receiver {
    endpoint: session::Endpoint,
    id: Option<String>,
    name: String,
}

/// Resolve `--to` (or the legacy `--connect`/`--name`, or `--usb`) to an address or endpoint.
/// `run` found no receiver (exit codes are documented in linux/README.md).
const EXIT_NO_RECEIVER: i32 = 3;
/// `run` without `--to` found several receivers.
const EXIT_SEVERAL_RECEIVERS: i32 = 4;

fn resolve_receiver(
    to: Option<String>,
    connect: Option<SocketAddr>,
    name: Option<String>,
    wait: bool,
    tailscale: bool,
    usb: bool,
) -> Result<Receiver> {
    let to = to.or(name);
    let is_usb = usb
        || to.as_deref() == Some("usb")
        || to.as_deref().is_some_and(|s| s.starts_with("usb:"));
    if is_usb {
        let dev_id = to
            .as_deref()
            .and_then(|t| t.strip_prefix("usb:"))
            .and_then(|s| s.parse::<u32>().ok());
        return Ok(Receiver {
            endpoint: session::Endpoint::Usb(dev_id),
            id: None,
            name: match dev_id {
                Some(id) => format!("USB:{id}"),
                None => "USB".into(),
            },
        });
    }
    let direct = |addr: SocketAddr| Receiver {
        endpoint: session::Endpoint::Network(addr),
        id: None,
        name: addr.to_string(),
    };
    if let Some(a) = connect {
        return Ok(direct(a));
    }
    if let Some(a) = to.as_deref().and_then(|t| t.parse::<SocketAddr>().ok()) {
        return Ok(direct(a));
    }
    if wait {
        match &to {
            Some(t) => info!("waiting for receiver {t:?} to appear (Ctrl+C to stop)"),
            None => info!("waiting for a receiver to appear (Ctrl+C to stop)"),
        }
    }
    let timeout = (!wait).then_some(Duration::from_secs(10));
    let found = discover::find(to.as_deref(), timeout, tailscale)?;
    if to.is_none() {
        info!(
            "using {} ({}), the only receiver found; choose one with --to <name>",
            found.instance, found.addr
        );
    }
    info!(
        "discovered {} at {} (pv {}, id {:?})",
        found.instance, found.addr, found.pv, found.id
    );
    Ok(Receiver {
        endpoint: session::Endpoint::Network(found.addr),
        id: found.id,
        name: found.instance,
    })
}

/// The config file: `--config` (must exist) or the default path (optional).
fn load_config(explicit: Option<&std::path::Path>) -> Result<config::Config> {
    match explicit {
        Some(p) => config::Config::load(p, true),
        None => match config::default_path() {
            Some(p) => config::Config::load(&p, false),
            None => Ok(config::Config::default()),
        },
    }
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();
    let code = match real_main() {
        Ok(code) => code,
        Err(e) => {
            error!("{e:#}");
            if e.downcast_ref::<detect::Unsupported>().is_some() {
                detect::EXIT_UNSUPPORTED
            } else if e.downcast_ref::<discover::NoReceiver>().is_some() {
                EXIT_NO_RECEIVER
            } else if e.downcast_ref::<discover::SeveralReceivers>().is_some() {
                EXIT_SEVERAL_RECEIVERS
            } else {
                1
            }
        }
    };
    std::process::exit(code);
}

fn real_main() -> Result<i32> {
    let args = Args::parse();
    // Before any thread exists: this rewrites the process environment.
    if let Some(i) = &args.instance {
        let inst = detect::select_instance(i)?;
        info!(
            "instance {} (pid {}, {})",
            inst.signature, inst.pid, inst.wl_socket
        );
    }
    match args.cmd {
        Cmd::Run {
            to,
            receiver,
            usb,
            wait,
            connect,
            name,
            bitrate_mbps,
            max_fps,
            scale,
            threads,
            encoder,
            cursor,
            no_cursor,
            position,
            workspace,
            keep_output,
            no_reconnect,
            duration,
            backend,
        } => {
            let to = to.or(receiver);
            let config = load_config(args.config.as_deref())?;
            let cli = config::Layer {
                position,
                scale,
                bitrate_mbps,
                workspace,
            };
            let eff = cli.over(&config.defaults).over(&config::builtin());
            let to = to.or_else(|| {
                (connect.is_none() && name.is_none())
                    .then(|| config.to.clone())
                    .flatten()
            });
            let mut backend = detect::detect(&backend.request_with(config.capture))?;
            let rt = tokio::runtime::Runtime::new()?;
            let ran = rt.block_on(async {
                let receiver = resolve_receiver(
                    to,
                    connect,
                    name,
                    wait,
                    config.tailscale.unwrap_or(true),
                    usb,
                )?;
                session::run(
                    receiver.endpoint,
                    backend.as_mut(),
                    session::RunOptions {
                        bitrate_mbps: eff.bitrate_mbps.unwrap_or(20.0),
                        desktop: desktop::DesktopOptions {
                            scale: eff.scale.unwrap_or_default(),
                            max_fps: max_fps.or(config.max_fps),
                        },
                        threads: dev::threads_or_all(threads),
                        encoder: encoder.or(config.encoder).unwrap_or(encoder::Backend::Auto),
                        cursor: if no_cursor {
                            session::CursorMode::Off
                        } else {
                            cursor.or(config.cursor).unwrap_or_default()
                        },
                        position: eff.position.unwrap_or(Position::AutoRight),
                        workspace: eff.workspace.clone(),
                        keep_output,
                        reconnect: !no_reconnect,
                        duration: duration.map(Duration::from_secs_f64),
                        receiver_id: receiver.id,
                        receiver_name: receiver.name,
                        cli,
                        config,
                    },
                )
                .await
            });
            // A drift probe may still be waiting on compositor IPC; the
            // display is already gone, so do not wait long for it.
            rt.shutdown_timeout(Duration::from_millis(500));
            ran?;
        }
        Cmd::List { timeout, json } => {
            // `list` worked without a config file before; a broken one does
            // not stop it, it only loses the `tailscale` setting.
            let tailscale = load_config(args.config.as_deref())
                .ok()
                .and_then(|c| c.tailscale)
                .unwrap_or(true);
            let found = discover::list(Duration::from_secs_f64(timeout), tailscale)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&found)?);
                return Ok(if found.is_empty() { 1 } else { 0 });
            }
            if found.is_empty() {
                println!("no receivers found.\n{}", discover::NO_RECEIVER_HINT);
                return Ok(1);
            }
            let w = found
                .iter()
                .map(|f| f.instance.len())
                .max()
                .unwrap_or(4)
                .max(4);
            println!("{:w$}  {:21}  pv  id", "name", "address");
            for f in found {
                println!(
                    "{:w$}  {:21}  {:<2}  {}",
                    f.instance,
                    f.addr.to_string(),
                    f.pv,
                    f.id.as_deref().unwrap_or("-")
                );
            }
        }
        Cmd::Doctor { backend } => {
            // A broken config is reported by doctor itself.
            let capture = load_config(args.config.as_deref())
                .ok()
                .and_then(|c| c.capture);
            if !doctor::doctor(&backend.request_with(capture), args.config.as_deref()) {
                return Ok(detect::EXIT_UNSUPPORTED);
            }
        }
        Cmd::Disconnect { receiver } => return disconnect::run(receiver.as_deref()),
        Cmd::Clean { backend } => {
            let mut backend = detect::detect(&backend.request())?;
            let removed = backend.clean()?;
            if removed.is_empty() {
                info!("nothing to clean ({})", backend.describe());
            } else {
                info!("removed {}", removed.join(", "));
            }
        }
        Cmd::Dev { cmd } => dev::run(cmd)?,
    }
    Ok(0)
}
