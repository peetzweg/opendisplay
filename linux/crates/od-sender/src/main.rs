mod capture;
mod discover;
mod encoder;
mod hyprland;
mod input;
mod run;

use std::time::{Duration, Instant};

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing::info;

/// OpenDisplay sender for Linux (work in progress).
#[derive(Parser, Debug)]
#[command(version, about)]
struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Extend the desktop onto a receiver: dial it (or discover it), create a
    /// virtual output sized from its `hello`, capture, encode and stream.
    Run {
        /// Receiver address; omit to discover via Bonjour.
        #[arg(long)]
        connect: Option<std::net::SocketAddr>,
        /// Only accept a discovered receiver whose name contains this.
        #[arg(long)]
        name: Option<String>,
        #[arg(long, default_value_t = 20.0)]
        bitrate_mbps: f32,
        #[arg(long, default_value_t = 60.0)]
        max_fps: f32,
        /// Encoder threads (0 = all cores).
        #[arg(long, default_value_t = 0)]
        threads: u16,
        /// Do not bake the cursor into the video.
        #[arg(long)]
        no_cursor: bool,
        /// Hyprland position for the virtual output (auto-right, auto-left, auto-up, auto-down, or "x,y").
        #[arg(long, default_value = "auto-right")]
        position: String,
        #[arg(long)]
        keep_output: bool,
        #[arg(long)]
        no_reconnect: bool,
        /// Stop after this many seconds.
        #[arg(long)]
        duration: Option<f64>,
    },
    /// List Hyprland monitors over IPC.
    Monitors,
    /// Create, size and remove a headless output through Hyprland IPC.
    HeadlessTest {
        #[arg(long, default_value = "od-test")]
        name: String,
        #[arg(long, default_value_t = 2560)]
        width: u32,
        #[arg(long, default_value_t = 1600)]
        height: u32,
        #[arg(long, default_value_t = 60)]
        hz: u32,
        #[arg(long, default_value_t = 2.0)]
        scale: f64,
        /// Keep the output alive this long before removing it.
        #[arg(long, default_value_t = 2.0)]
        hold: f64,
    },
    /// Encode synthetic frames to measure software encode cost on this machine.
    EncodeBench {
        #[arg(long, default_value_t = 1280)]
        width: u32,
        #[arg(long, default_value_t = 800)]
        height: u32,
        #[arg(long, default_value_t = 60)]
        frames: u32,
        #[arg(long, default_value_t = 0)]
        threads: u16,
        #[arg(long, default_value_t = 20.0)]
        bitrate_mbps: f32,
    },
    /// Create a headless output, move the pointer onto it via the virtual
    /// pointer protocol and verify the position through Hyprland IPC.
    InputTest {
        #[arg(long, default_value_t = 0.25)]
        x: f64,
        #[arg(long, default_value_t = 0.75)]
        y: f64,
    },
    /// Capture an output via ext-image-copy-capture into shm and report frame timing.
    CaptureTest {
        /// wl_output name; default: first output.
        #[arg(long)]
        output: Option<String>,
        #[arg(long, default_value_t = 5.0)]
        seconds: f64,
        #[arg(long)]
        cursor: bool,
        /// Write the last frame as a PPM here.
        #[arg(long)]
        save: Option<std::path::PathBuf>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();
    match Args::parse().cmd {
        Cmd::Run {
            connect,
            name,
            bitrate_mbps,
            max_fps,
            threads,
            no_cursor,
            position,
            keep_output,
            no_reconnect,
            duration,
        } => {
            let addr = match connect {
                Some(a) => a,
                None => {
                    let found = discover::find(name.as_deref(), Duration::from_secs(10))?;
                    info!(
                        "discovered {} at {} (pv {}, id {:?})",
                        found.instance, found.addr, found.pv, found.id
                    );
                    found.addr
                }
            };
            let threads = if threads == 0 {
                std::thread::available_parallelism()
                    .map(|n| n.get() as u16)
                    .unwrap_or(4)
            } else {
                threads
            };
            run::run(
                addr,
                run::RunOptions {
                    bitrate_mbps,
                    max_fps,
                    threads,
                    cursor_in_video: !no_cursor,
                    position,
                    keep_output,
                    reconnect: !no_reconnect,
                    duration: duration.map(Duration::from_secs_f64),
                },
            )
            .await?;
        }
        Cmd::EncodeBench {
            width,
            height,
            frames,
            threads,
            bitrate_mbps,
        } => {
            let threads = if threads == 0 {
                std::thread::available_parallelism()
                    .map(|n| n.get() as u16)
                    .unwrap_or(4)
            } else {
                threads
            };
            let mut enc = encoder::Encoder::new(
                width,
                height,
                encoder::EncoderSettings {
                    bitrate_bps: (bitrate_mbps * 1e6) as u32,
                    max_fps: 60.0,
                    threads,
                },
            )?;
            let stride = width * 4;
            let mut frame = vec![0u8; (stride * height) as usize];
            let mut times = Vec::new();
            let mut bytes = 0usize;
            for i in 0..frames {
                // Desktop-like content: text-ish noise blocks that shift each frame.
                for y in 0..height as usize {
                    for x in 0..width as usize {
                        let v = (((x / 8 + y / 12 + i as usize) % 7) * 36) as u8;
                        let o = y * stride as usize + x * 4;
                        frame[o] = v;
                        frame[o + 1] = v / 2 + 60;
                        frame[o + 2] = 255 - v;
                        frame[o + 3] = 255;
                    }
                }
                let t = Instant::now();
                if let Some(e) = enc.encode(&frame, stride, i == 0, t)? {
                    bytes += e.unit.annexb.len();
                }
                times.push(t.elapsed().as_secs_f64() * 1000.0);
            }
            times.sort_by(f64::total_cmp);
            let n = times.len();
            info!(
                "{width}x{height} {threads} threads: encode p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms -> {:.0} fps sustainable; avg frame {:.0} KB",
                times[n / 2],
                times[(n as f64 * 0.95) as usize],
                times[n - 1],
                1000.0 / times[n / 2],
                bytes as f64 / n as f64 / 1024.0
            );
        }
        Cmd::InputTest { x, y } => {
            let ipc = hyprland::HyprlandIpc::from_env()?;
            let name = "od-input-test";
            let before = ipc.request("cursorpos")?.trim().to_string();
            ipc.create_headless(name)?;
            let m = ipc.configure(name, 1600, 1000, 60, 2.0, "auto-right")?;
            let injector = input::InputInjector::start(name, m.scale)?;
            injector.send(input::InputCmd::Move { x, y });
            std::thread::sleep(Duration::from_millis(150));
            let after = ipc.request("cursorpos")?.trim().to_string();
            // Expected in Hyprland's layout coordinates: monitor origin + normalised * logical size.
            let (lw, lh) = (m.width as f64 / m.scale, m.height as f64 / m.scale);
            let expect = (m.x as f64 + x * lw, m.y as f64 + y * lh);
            info!(
                "cursorpos before: {before}; after move to ({x},{y}) on {name}: {after}; expected ~({:.0}, {:.0})",
                expect.0, expect.1
            );
            drop(injector);
            ipc.remove_output(name)?;
            info!(
                "removed {name}; cursorpos now: {}",
                ipc.request("cursorpos")?.trim()
            );
        }
        Cmd::Monitors => {
            let ipc = hyprland::HyprlandIpc::from_env()?;
            info!("{}", ipc.version()?);
            for m in ipc.monitors()? {
                info!(
                    "{} {}x{} @{:.0} scale {} at {},{} ({})",
                    m.name, m.width, m.height, m.refresh_rate, m.scale, m.x, m.y, m.description
                );
            }
        }
        Cmd::HeadlessTest {
            name,
            width,
            height,
            hz,
            scale,
            hold,
        } => {
            let ipc = hyprland::HyprlandIpc::from_env()?;
            let t = Instant::now();
            ipc.create_headless(&name)?;
            let m = ipc.configure(&name, width, height, hz, scale, "auto-right")?;
            info!(
                "created {} as {}x{} @{:.0} scale {} at {},{} in {:?}",
                m.name,
                m.width,
                m.height,
                m.refresh_rate,
                m.scale,
                m.x,
                m.y,
                t.elapsed()
            );
            std::thread::sleep(Duration::from_secs_f64(hold));
            ipc.remove_output(&name)?;
            info!(
                "removed {name}; monitors now: {:?}",
                ipc.monitors()?
                    .iter()
                    .map(|m| m.name.clone())
                    .collect::<Vec<_>>()
            );
        }
        Cmd::CaptureTest {
            output,
            seconds,
            cursor,
            save,
        } => {
            let mut last: Option<(capture::FrameInfo, Vec<u8>)> = None;
            let n = capture::capture_shm(
                output.as_deref(),
                cursor,
                Duration::from_secs_f64(seconds),
                std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
                |info: &capture::FrameInfo, pixels: &[u8]| {
                    if save.is_some() {
                        last = Some((*info, pixels.to_vec()));
                    }
                },
            )?;
            info!("{n} frames captured");
            if let (Some(path), Some((info, pixels))) = (save, last) {
                let mut ppm = format!("P6\n{} {}\n255\n", info.width, info.height).into_bytes();
                for row in pixels.chunks(info.stride as usize) {
                    for px in row[..(info.width * 4) as usize].chunks(4) {
                        // XRGB8888 / ARGB8888 little-endian: B, G, R, X
                        ppm.extend_from_slice(&[px[2], px[1], px[0]]);
                    }
                }
                std::fs::write(&path, ppm)?;
                info!("wrote {}", path.display());
            }
        }
    }
    Ok(())
}
