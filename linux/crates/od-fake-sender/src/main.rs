use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use clap::Parser;

/// Fake OpenDisplay sender: replays an Annex B H.264 file to a receiver.
#[derive(Parser, Debug)]
#[command(version, about)]
struct Args {
    /// Receiver address (TCP).
    #[arg(long, default_value = "127.0.0.1:9000")]
    connect: SocketAddr,
    /// Annex B .h264 file (x264/ffmpeg raw output is fine).
    #[arg(long)]
    clip: PathBuf,
    #[arg(long, default_value_t = 30.0)]
    fps: f64,
    /// Stop after this many seconds.
    #[arg(long)]
    duration: Option<f64>,
    /// Do not redial after the connection ends.
    #[arg(long)]
    no_reconnect: bool,
    /// Skip every Nth access unit (exercises `kf` recovery).
    #[arg(long)]
    drop_every: Option<u64>,
    /// Stop all writes after this many seconds (exercises liveness + reconnect)...
    #[arg(long)]
    pause_at: Option<f64>,
    /// ...for this many seconds.
    #[arg(long, default_value_t = 8.0)]
    pause_for: f64,
    /// Switch to this clip (exercises the SPS/PPS change path)...
    #[arg(long)]
    switch_clip: Option<PathBuf>,
    /// ...after this many seconds.
    #[arg(long)]
    switch_at: Option<f64>,
    /// Send synthetic cursor motion.
    #[arg(long)]
    cursor: bool,
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
    od_fake_sender::run(od_fake_sender::Options {
        connect: a.connect,
        clip: a.clip,
        fps: a.fps,
        duration: a.duration.map(Duration::from_secs_f64),
        reconnect: !a.no_reconnect,
        drop_every: a.drop_every,
        pause_at: a.pause_at.map(Duration::from_secs_f64),
        pause_for: Duration::from_secs_f64(a.pause_for),
        switch_clip: a.switch_clip,
        switch_at: a.switch_at.map(Duration::from_secs_f64),
        cursor: a.cursor,
        stats_every: Duration::from_secs_f64(a.stats_every),
    })
    .await?;
    Ok(())
}
