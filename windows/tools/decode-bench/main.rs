//! Feeds Annex B files through the receiver's real decode pipeline and reports timing.
//!
//! usage: decode-bench [--throughput] [--start K] [--dump N out.nv12] <file.h264>...
//!   Files are fed back to back, so mixing resolutions exercises the SPS-change rebuild.
//!   --throughput  no per-frame GPU sync; report the sustained decode rate instead of latency.
//!   --fps N       pace input at N frames/s like a live sender (default: back to back).
//!   --start K     begin the first file at access unit K (a non-IDR simulates joining mid-GOP).
//!   --dump N      write decoded frame N (visible NV12) for comparison with a reference decoder.

use od_receiver::h264::access_units;
use od_receiver::mf::Gpu;
use od_receiver::video::{Pipeline, percentile};
use std::error::Error;
use std::time::{Duration, Instant};
use std::{env, fs};

fn main() -> Result<(), Box<dyn Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let (mut throughput, mut start_k, mut dump, mut files) = (false, 0, None, Vec::new());
    let mut pace = None;
    let mut args = env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--throughput" => throughput = true,
            "--fps" => {
                pace = Some(Duration::from_secs_f64(
                    1.0 / args.next().ok_or("--fps N")?.parse::<f64>()?,
                ))
            }
            "--start" => start_k = args.next().ok_or("--start K")?.parse()?,
            "--dump" => {
                dump = Some((
                    args.next().ok_or("--dump N file")?.parse::<u64>()?,
                    args.next().ok_or("--dump N file")?,
                ))
            }
            _ => files.push(a),
        }
    }
    if files.is_empty() {
        return Err(
            "usage: decode-bench [--throughput] [--start K] [--dump N out.nv12] <file.h264>..."
                .into(),
        );
    }

    let mut pl = Pipeline::new(Gpu::new(None)?);
    let (mut cpu_us, mut gpu_us, mut sizes) = (Vec::new(), Vec::new(), Vec::new());
    let (mut kf, mut out_n, mut fed) = (0, 0u64, 0);
    let mut slow = Vec::new(); // (frame, ms, KiB) of frames whose decode call took > 4 ms
    let wall = Instant::now();
    for (fi, path) in files.iter().enumerate() {
        let aus = access_units(&fs::read(path)?);
        for (_, au) in aus.iter().skip(if fi == 0 { start_k } else { 0 }) {
            if let Some(p) = pace {
                std::thread::sleep((wall + p * fed).saturating_duration_since(Instant::now()));
            }
            fed += 1;
            let t0 = Instant::now();
            let (frame, k) = pl.frame(au, 0.0, t0, None);
            kf += k as u32;
            let Some(f) = frame.map(|d| d.frame) else {
                continue;
            };
            cpu_us.push(t0.elapsed().as_micros() as u32);
            if *cpu_us.last().unwrap() > 4000 && slow.len() < 40 {
                slow.push((out_n, cpu_us.last().unwrap() / 1000, au.len() / 1024));
            }
            if !throughput {
                pl.gpu.finish()?;
                gpu_us.push(t0.elapsed().as_micros() as u32);
            }
            if sizes.last() != Some(&(f.width, f.height)) {
                sizes.push((f.width, f.height));
            }
            if let Some((n, out)) = &dump
                && *n == out_n
            {
                fs::write(out, f.read_nv12(&pl.gpu)?)?;
                println!("wrote frame {n} ({}x{} NV12) to {out}", f.width, f.height);
            }
            out_n += 1;
        }
    }
    pl.gpu.finish()?;
    let secs = wall.elapsed().as_secs_f64();
    let s = &pl.stats;
    println!(
        "fed {fed}, decoded {out_n}, skipped {}, kf requests {kf}, rebuilds {}, errors {}, input samples allocated {}",
        s.skipped,
        s.rebuilds,
        s.errors,
        pl.input_pool_size()
    );
    println!("output sizes in order: {sizes:?}");
    if !slow.is_empty() {
        println!("slow decode calls (frame, ms, KiB), first 40: {slow:?}");
    }
    let ms = |v: &mut Vec<u32>, p| percentile(v, p).map_or(f64::NAN, |x| x as f64 / 1000.0);
    println!(
        "decoder CPU time per frame: p50 {:.2} ms, p95 {:.2} ms, max {:.2} ms",
        ms(&mut cpu_us, 0.5),
        ms(&mut cpu_us, 0.95),
        ms(&mut cpu_us, 1.0)
    );
    if throughput {
        println!(
            "sustained: {:.1} fps ({out_n} frames in {secs:.2} s, no per-frame GPU sync)",
            out_n as f64 / secs
        );
    } else {
        println!(
            "submit -> GPU decode complete: p50 {:.2} ms, p95 {:.2} ms, max {:.2} ms",
            ms(&mut gpu_us, 0.5),
            ms(&mut gpu_us, 0.95),
            ms(&mut gpu_us, 1.0)
        );
    }
    Ok(())
}
