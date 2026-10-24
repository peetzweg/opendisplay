use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use od_receiver::video::{SinkKind, VideoConfig};
use od_receiver::{Config, Receiver, discovery, id, outputs};
use opendisplay_proto::control::{Hello, Panel, VideoCap};
use tokio::sync::watch;
use tracing::{info, warn};

/// OpenDisplay receiver for Linux.
#[derive(Parser, Debug)]
#[command(version = env!("OD_RECEIVER_VERSION"), about)]
struct Args {
    /// TCP listen address (§1: the receiver listens).
    #[arg(long, default_value = "0.0.0.0:9000")]
    listen: SocketAddr,
    /// Bonjour instance name (display-only). Default: hostname.
    #[arg(long)]
    name: Option<String>,
    /// `hello.device` (free-form).
    #[arg(long, default_value = "Linux")]
    device: String,
    /// Output (connector name) to describe in `hello` and to fullscreen on.
    /// Default: first.
    #[arg(long)]
    output: Option<String>,
    /// Override the announced panel width in physical pixels (else from the output).
    #[arg(long)]
    width: Option<u32>,
    #[arg(long)]
    height: Option<u32>,
    /// Override the panel scale (else the output's).
    #[arg(long)]
    scale: Option<f64>,
    /// Override `hello.displayMaxFrameRate` (else the output's refresh).
    #[arg(long)]
    refresh: Option<u32>,
    /// gtk | gl | wayland | auto | fake | none. `gtk` (the default when
    /// built with it) fullscreens itself, draws the sender's cursor and sends
    /// pointer input back; `wayland` crashes on output hotplug with
    /// GStreamer <= 1.28.7.
    #[arg(long, default_value_t = default_sink())]
    sink: SinkKind,
    /// GStreamer decoder element (decodebin3 autoplugs by rank).
    #[arg(long, default_value = "decodebin3")]
    decoder: String,
    /// Present in a normal window instead of fullscreen.
    #[arg(long)]
    windowed: bool,
    /// Skip the videoconvert before the sink (zero-copy experiments with
    /// dmabuf-capable decoders and sinks).
    #[arg(long)]
    no_videoconvert: bool,
    /// `gtk`: convert on the CPU even when GL is available.
    #[arg(long)]
    no_gl: bool,
    /// Do not advertise via mDNS.
    #[arg(long)]
    no_mdns: bool,
    /// Do not bind UDP port+1 for the cursor side channel (§6.3).
    #[arg(long)]
    no_cursor_udp: bool,
    #[arg(long, default_value_t = 5.0)]
    stats_every: f64,
}

fn default_sink() -> SinkKind {
    if cfg!(feature = "gtk") {
        SinkKind::Gtk
    } else {
        SinkKind::Gl
    }
}

/// The panel as the window system reports it, before command-line overrides.
#[derive(Default)]
struct PanelGuess {
    pixels: Option<(u32, u32)>,
    scale: Option<f64>,
    /// Logical (layout) size, when known.
    points: Option<(u32, u32)>,
    refresh: Option<u32>,
    output: Option<String>,
}

fn hello(a: &Args, guess: PanelGuess, install_id: &str) -> Result<Hello> {
    let (width, height) = match (a.width, a.height, guess.pixels) {
        (Some(w), Some(h), _) => (w, h),
        (w, h, Some((gw, gh))) => (w.unwrap_or(gw), h.unwrap_or(gh)),
        _ => anyhow::bail!("no display information; pass --width and --height"),
    };
    let scale = a.scale.or(guess.scale).unwrap_or(1.0);
    let refresh = a.refresh.or(guess.refresh);
    let points = match (a.width, a.height, a.scale) {
        (None, None, None) => guess.points,
        _ => Some((
            (width as f64 / scale).round() as u32,
            (height as f64 / scale).round() as u32,
        )),
    };
    Ok(Hello {
        pixels_wide: width,
        pixels_high: height,
        // Deprecated field (§7): senders without `panel` read it as a UI
        // factor, so keep it whole.
        scale: scale.ceil().max(1.0),
        device: Some(a.device.clone()),
        id: Some(install_id.to_string()),
        display_max_frame_rate: refresh,
        // §6.7: facts only; the sender decides the desktop size.
        panel: Some(Panel {
            pixels_wide: Some(width),
            pixels_high: Some(height),
            scale: Some(scale),
            points_wide: points.map(|p| p.0),
            points_high: points.map(|p| p.1),
            malformed: false,
        }),
        // §6.5: H.264 always; no measured decode ceiling yet, so only the
        // panel's rate bounds it.
        video_caps: Some(vec![VideoCap {
            codec: "h264".into(),
            max_width: None,
            max_height: None,
            max_frame_rate: refresh,
            max_pixels_per_second: None,
        }]),
        ..Default::default()
    })
}

/// Panel facts from wl_output (the non-GTK sinks).
fn wayland_guess(a: &Args) -> PanelGuess {
    let fallback = || PanelGuess {
        output: a.output.clone(),
        ..Default::default()
    };
    let need = a.width.is_none()
        || a.height.is_none()
        || (a.sink == SinkKind::Wayland && a.output.is_none());
    if !need {
        return fallback();
    }
    let list = match outputs::enumerate() {
        Ok(list) => list,
        Err(e) => {
            warn!("could not enumerate Wayland outputs: {e:#}");
            return fallback();
        }
    };
    for o in &list {
        info!(
            "output {}: {}x{} @{:?} Hz scale {} ({})",
            o.name,
            o.width,
            o.height,
            o.refresh_hz(),
            o.scale,
            o.description
        );
    }
    match outputs::pick(&list, a.output.as_deref()) {
        Ok(o) => PanelGuess {
            pixels: Some((o.width as u32, o.height as u32)),
            scale: Some(o.scale.max(1) as f64),
            points: None,
            refresh: o.refresh_hz(),
            output: Some(o.name.clone()),
        },
        Err(e) => {
            warn!("{e:#}");
            fallback()
        }
    }
}

fn config(a: &Args, hello: Hello) -> Config {
    Config {
        listen: a.listen,
        hello,
        cursor_udp: !a.no_cursor_udp,
        stats_every: Duration::from_secs_f64(a.stats_every),
    }
}

/// Advertise, serve until `shutdown`, withdraw.
async fn serve(
    a: &Args,
    receiver: Receiver,
    install_id: &str,
    shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let port = receiver.local_addr()?.port();
    let host = std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let host = if host.is_empty() {
        "opendisplay".to_string()
    } else {
        host
    };
    let advert = if a.no_mdns {
        None
    } else {
        match discovery::Advertisement::start(
            a.name.as_deref().unwrap_or(&host),
            &host,
            port,
            install_id,
        ) {
            Ok(ad) => Some(ad),
            Err(e) => {
                warn!(
                    "mDNS advertisement failed ({e:#}); senders must dial {} manually",
                    receiver.local_addr()?
                );
                None
            }
        }
    };
    let result = receiver.run(shutdown).await.context("receiver");
    if let Some(ad) = advert {
        ad.stop();
    }
    result.map(|_| ())
}

/// Sleep notifications for the receiver: from logind when built with it.
fn power_events() -> tokio::sync::mpsc::UnboundedReceiver<od_receiver::power::PowerEvent> {
    #[allow(unused_variables)]
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    #[cfg(feature = "logind")]
    od_receiver::power::watch_logind(tx);
    rx
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();
    let a = Args::parse();
    #[cfg(feature = "gtk")]
    if a.sink == SinkKind::Gtk {
        return gtk_main(a);
    }
    if a.sink == SinkKind::Gtk {
        anyhow::bail!("built without the `gtk` feature; pick another --sink");
    }

    let rt = tokio::runtime::Runtime::new()?;
    let install_id = id::load_or_create()?;
    let guess = wayland_guess(&a);
    let output = guess.output.clone();
    let hello = hello(&a, guess, &install_id)?;
    let video = od_receiver::video::open(&VideoConfig {
        sink: a.sink,
        decoder: a.decoder.clone(),
        fullscreen: !a.windowed,
        output,
        videoconvert: !a.no_videoconvert,
        gl: false,
    })?;
    rt.block_on(async {
        let receiver = Receiver::bind(config(&a, hello), video)
            .await?
            .with_power(power_events());
        let (tx, rx) = watch::channel(false);
        tokio::spawn(async move {
            let _ = tokio::signal::ctrl_c().await;
            info!("shutting down");
            let _ = tx.send(true);
        });
        serve(&a, receiver, &install_id, rx).await
    })
}

/// GTK owns the main thread; the receiver loop runs on a worker thread with
/// its own runtime. Ctrl-C and closing the window both end the session with
/// `closing`, then the window goes.
#[cfg(feature = "gtk")]
fn gtk_main(a: Args) -> Result<()> {
    use od_receiver::gtk_ui::{self, GtkVideo, WindowOptions};
    use od_receiver::video::VideoOutput;
    use std::sync::Arc;

    gtk_ui::init()?;
    let monitors = gtk_ui::monitors();
    for m in &monitors {
        info!(
            "monitor {}: {}x{} logical, scale {}, {:?} Hz ({})",
            m.connector,
            m.logical.0,
            m.logical.1,
            m.scale,
            m.refresh_hz(),
            m.description
        );
    }
    let guess = match gtk_ui::pick(&monitors, a.output.as_deref()) {
        Ok(m) => PanelGuess {
            pixels: Some(m.pixels()),
            scale: Some(m.scale),
            points: Some((m.logical.0.max(0) as u32, m.logical.1.max(0) as u32)),
            refresh: m.refresh_hz(),
            output: Some(m.connector.clone()),
        },
        Err(e) => {
            warn!("{e:#}");
            PanelGuess {
                output: a.output.clone(),
                ..Default::default()
            }
        }
    };
    let install_id = id::load_or_create()?;
    let output = guess.output.clone();
    let hello = hello(&a, guess, &install_id)?;

    let gl = !a.no_gl && gtk_ui::gl_available();
    let pipeline = od_receiver::video::gst_out::GstOutput::new(&VideoConfig {
        sink: SinkKind::Gtk,
        decoder: a.decoder.clone(),
        fullscreen: !a.windowed,
        output: output.clone(),
        videoconvert: !a.no_videoconvert,
        gl,
    })?;
    let sink = pipeline
        .paintable_sink()
        .context("gtk4paintablesink missing from the pipeline")?;
    let video: Box<dyn VideoOutput> = Box::new(GtkVideo::new(pipeline));

    let rt = tokio::runtime::Runtime::new()?;
    let (input_tx, input_rx) = tokio::sync::mpsc::unbounded_channel();
    // Bound here so a busy port fails before any window appears.
    let receiver = rt
        .block_on(Receiver::bind(config(&a, hello), video))?
        .with_input(input_rx)
        .with_power(power_events());
    let (tx, rx) = watch::channel(false);
    let tx = Arc::new(tx);
    let options = WindowOptions {
        monitor: output,
        windowed: a.windowed,
    };
    let worker = {
        let tx = tx.clone();
        std::thread::Builder::new()
            .name("receiver".into())
            .spawn(move || {
                let result = rt.block_on(async {
                    tokio::spawn(async move {
                        let _ = tokio::signal::ctrl_c().await;
                        info!("shutting down");
                        let _ = tx.send(true);
                    });
                    serve(&a, receiver, &install_id, rx).await
                });
                gtk_ui::quit();
                result
            })?
    };
    gtk_ui::run(options, sink, input_tx, move || {
        let _ = tx.send(true);
    })?;
    worker
        .join()
        .map_err(|_| anyhow::anyhow!("receiver thread panicked"))?
}
