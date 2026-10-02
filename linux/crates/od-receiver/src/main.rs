use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use od_receiver::video::{SinkKind, VideoConfig};
use od_receiver::{Config, Receiver, discovery, id, outputs};
use opendisplay_proto::control::Hello;
use tracing::{info, warn};

/// OpenDisplay receiver for Linux.
#[derive(Parser, Debug)]
#[command(version, about)]
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
    /// Wayland output to describe in `hello` and to fullscreen on. Default: first.
    #[arg(long)]
    output: Option<String>,
    /// Override the announced panel width in physical pixels (else from the output).
    #[arg(long)]
    width: Option<u32>,
    #[arg(long)]
    height: Option<u32>,
    /// Override `hello.scale` (else the output's integer scale).
    #[arg(long)]
    scale: Option<f64>,
    /// Override `hello.displayMaxFrameRate` (else the output's refresh).
    #[arg(long)]
    refresh: Option<u32>,
    /// gl | wayland | auto | fake | none. `wayland` supports --output fullscreen
    /// placement but crashes on output hotplug with GStreamer <= 1.28.7.
    #[arg(long, default_value = "gl")]
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
    /// Do not advertise via mDNS.
    #[arg(long)]
    no_mdns: bool,
    /// Bind UDP port+1 for the cursor side channel (§6.3).
    #[arg(long)]
    cursor_udp: bool,
    #[arg(long, default_value_t = 5.0)]
    stats_every: f64,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();
    let a = Args::parse();

    // Panel facts from the compositor unless overridden (§6.1: physical pixels).
    let (mut width, mut height, mut scale, mut refresh, mut output_name) =
        (a.width, a.height, a.scale, a.refresh, a.output.clone());
    if width.is_none() || height.is_none() || (a.sink == SinkKind::Wayland && output_name.is_none())
    {
        match outputs::enumerate() {
            Ok(list) => {
                for o in &list {
                    info!(
                        "output {}: {}x{} @{} scale {} ({})",
                        o.name,
                        o.width,
                        o.height,
                        o.refresh_hz(),
                        o.scale,
                        o.description
                    );
                }
                let o = outputs::pick(&list, a.output.as_deref())?;
                width.get_or_insert(o.width as u32);
                height.get_or_insert(o.height as u32);
                scale.get_or_insert(o.scale.max(1) as f64);
                refresh.get_or_insert(o.refresh_hz());
                output_name.get_or_insert(o.name.clone());
            }
            Err(e) => {
                if width.is_none() || height.is_none() {
                    return Err(e.context("no Wayland outputs; pass --width and --height"));
                }
                warn!("could not enumerate Wayland outputs: {e:#}");
            }
        }
    }
    let install_id = id::load_or_create()?;
    let hello = Hello {
        pixels_wide: width.unwrap(),
        pixels_high: height.unwrap(),
        scale: scale.unwrap_or(1.0),
        device: Some(a.device.clone()),
        id: Some(install_id.clone()),
        display_max_frame_rate: refresh,
        ..Default::default()
    };

    let video = od_receiver::video::open(&VideoConfig {
        sink: a.sink,
        decoder: a.decoder.clone(),
        fullscreen: !a.windowed,
        output: output_name,
        videoconvert: !a.no_videoconvert,
    })?;

    let receiver = Receiver::bind(
        Config {
            listen: a.listen,
            hello,
            cursor_udp: a.cursor_udp,
            stats_every: Duration::from_secs_f64(a.stats_every),
        },
        video,
    )
    .await?;
    let port = receiver.local_addr()?.port();

    let host = std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "opendisplay".into());
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
            &install_id,
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

    let (tx, rx) = tokio::sync::watch::channel(false);
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        info!("shutting down");
        let _ = tx.send(true);
    });
    let result = receiver.run(rx).await.context("receiver");
    if let Some(ad) = advert {
        ad.stop();
    }
    result.map(|_| ())
}
