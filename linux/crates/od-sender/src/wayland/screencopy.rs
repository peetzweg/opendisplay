//! Continuous capture of one output through `wlr-screencopy-unstable-v1`
//! into the same mapped, leased `wl_shm` buffers as `capture.rs`. Chosen on
//! Hyprland < 0.57, whose ext-image-copy-capture path can crash when an
//! output is removed under a frame request (backend/capture.rs).
//!
//! Per frame: `capture_output` → `buffer` (+ `buffer_done` from v3) →
//! `copy_with_damage` into a free buffer → `ready` or `failed`. One frame is
//! in flight at a time. `copy_with_damage` completes only once the output has
//! new damage, so a static screen yields no frames, as with ext; Hyprland
//! forces the first frame of a session so a capture starts with a picture.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tracing::{debug, info, warn};
use wayland_client::protocol::{wl_buffer, wl_output, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum};
use wayland_protocols_wlr::screencopy::v1::client::{
    zwlr_screencopy_frame_v1, zwlr_screencopy_manager_v1,
};

use super::capture::{FrameInfo, MAX_BUFFERS, ShmBuffer};
use super::dispatch_with_timeout;
use super::shm_pool::{Lease, Recycler};

/// `failed` without a removal in sight, in a row, before giving up: a
/// compositor that fails every copy would otherwise spin here forever.
const MAX_CONSECUTIVE_FAILURES: u32 = 30;

/// What one frame object reported.
#[derive(Debug, Default)]
struct FrameState {
    /// `buffer` (shm): format, width, height, stride.
    shm: Option<(wl_shm::Format, u32, u32, u32)>,
    buffer_done: bool,
    ready: Option<u128>,
    failed: bool,
}

struct State {
    shm: Option<wl_shm::WlShm>,
    manager: Option<(zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1, u32)>,
    /// Registry name → (output, its wl_output name).
    outputs: HashMap<u32, (wl_output::WlOutput, String)>,
    /// Registry name of the captured output, once chosen.
    target: Option<u32>,
    /// The captured output's global went away.
    output_removed: bool,
    frame: FrameState,
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
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } => match interface.as_str() {
                "wl_shm" => state.shm = Some(registry.bind(name, 1, qh, ())),
                "wl_output" if version >= 4 => {
                    let o: wl_output::WlOutput = registry.bind(name, 4, qh, name);
                    state.outputs.insert(name, (o, String::new()));
                }
                "zwlr_screencopy_manager_v1" => {
                    let v = version.min(3);
                    state.manager = Some((registry.bind(name, v, qh, ()), v));
                }
                _ => {}
            },
            wl_registry::Event::GlobalRemove { name } if state.target == Some(name) => {
                state.output_removed = true;
            }
            _ => {}
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
        if let wl_output::Event::Name { name } = event {
            if let Some(o) = state.outputs.get_mut(global) {
                o.1 = name;
            }
        }
    }
}

impl Dispatch<zwlr_screencopy_frame_v1::ZwlrScreencopyFrameV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &zwlr_screencopy_frame_v1::ZwlrScreencopyFrameV1,
        event: zwlr_screencopy_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use zwlr_screencopy_frame_v1::Event;
        let f = &mut state.frame;
        match event {
            Event::Buffer {
                format: WEnum::Value(format),
                width,
                height,
                stride,
            } => f.shm = Some((format, width, height, stride)),
            Event::BufferDone => f.buffer_done = true,
            Event::Ready {
                tv_sec_hi,
                tv_sec_lo,
                tv_nsec,
            } => {
                let secs = ((tv_sec_hi as u128) << 32) | tv_sec_lo as u128;
                f.ready = Some(secs * 1_000_000_000 + tv_nsec as u128);
            }
            Event::Failed => f.failed = true,
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
    wl_shm::WlShm,
    wl_shm_pool::WlShmPool,
    wl_buffer::WlBuffer,
    zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1
);

/// What to do after a frame failed.
#[derive(Debug, PartialEq, Eq)]
enum AfterFailure {
    Retry,
    /// The output is gone, or the compositor keeps failing: end the capture.
    End(&'static str),
}

fn after_failure(output_removed: bool, consecutive: u32) -> AfterFailure {
    if output_removed {
        AfterFailure::End("the output was removed")
    } else if consecutive >= MAX_CONSECUTIVE_FAILURES {
        AfterFailure::End("every copy fails")
    } else {
        AfterFailure::Retry
    }
}

/// Capture `output_name` through wlr-screencopy until `duration`, a stop
/// request, or the output going away; frames go to `on_frame` as leases, as
/// in [`super::capture::capture_shm`].
pub fn capture_wlr(
    output_name: &str,
    include_cursor: bool,
    duration: Duration,
    stop: Arc<AtomicBool>,
    mut on_frame: impl FnMut(&FrameInfo, Lease),
) -> Result<u64> {
    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut st = State {
        shm: None,
        manager: None,
        outputs: HashMap::new(),
        target: None,
        output_removed: false,
        frame: FrameState::default(),
    };
    queue.roundtrip(&mut st)?;
    queue.roundtrip(&mut st)?;
    let shm = st.shm.clone().context("compositor has no wl_shm")?;
    let (manager, version) = st
        .manager
        .clone()
        .context("compositor lacks zwlr_screencopy_manager_v1")?;
    let (global, output) = st
        .outputs
        .iter()
        .find(|(_, (_, name))| name == output_name)
        .map(|(g, (o, _))| (*g, o.clone()))
        .with_context(|| format!("no output {output_name}"))?;
    st.target = Some(global);
    info!("capturing output {output_name} (wlr-screencopy v{version})");

    let recycler = Recycler::default();
    let mut buffers: Vec<ShmBuffer> = Vec::new();
    let mut frames = 0u64;
    let mut failures = 0u32;
    let mut warned_format = false;
    let start = Instant::now();
    while start.elapsed() < duration && !stop.load(Ordering::Relaxed) {
        // The output may have gone while we waited; never ask for a frame then.
        dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::ZERO)?;
        if st.output_removed {
            info!("output {output_name} was removed");
            break;
        }
        st.frame = FrameState::default();
        let frame = manager.capture_output(include_cursor as i32, &output, &qh, ());
        // The buffer description: `buffer` (+ `buffer_done` from v3).
        while !stop.load(Ordering::Relaxed)
            && !st.frame.failed
            && !st.output_removed
            && !(st.frame.shm.is_some() && (st.frame.buffer_done || version < 3))
        {
            dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::from_millis(250))?;
        }
        let Some((format, width, height, stride)) = st.frame.shm.filter(|_| !st.frame.failed)
        else {
            frame.destroy();
            if stop.load(Ordering::Relaxed) {
                break;
            }
            failures += 1;
            match after_failure(st.output_removed, failures) {
                AfterFailure::Retry => continue,
                AfterFailure::End(why) => {
                    info!("capture of {output_name} ends: {why}");
                    break;
                }
            }
        };
        if !warned_format && !matches!(format, wl_shm::Format::Xrgb8888 | wl_shm::Format::Argb8888)
        {
            warn!(
                "compositor offers {format:?}; the encoders expect XRGB/ARGB8888, colours may be off"
            );
            warned_format = true;
        }
        if buffers.first().is_some_and(|b| {
            (b.width, b.height, b.stride, b.format) != (width, height, stride, format)
        }) {
            recycler.reset();
            buffers.clear();
        }
        let index = loop {
            match recycler.take() {
                Some(i) => break Some(i),
                None if buffers.len() < MAX_BUFFERS => {
                    buffers.push(ShmBuffer::new(&shm, &qh, width, height, stride, format)?);
                    debug!(
                        "allocated capture buffer {} at {width}x{height} {format:?}",
                        buffers.len()
                    );
                    break Some(buffers.len() - 1);
                }
                // Every buffer is lent out: the encoder is behind.
                None if stop.load(Ordering::Relaxed) => break None,
                None => {
                    recycler.wait(Duration::from_millis(250));
                }
            }
        };
        let Some(index) = index else {
            frame.destroy();
            break;
        };
        frame.copy_with_damage(&buffers[index].buffer);
        while !stop.load(Ordering::Relaxed)
            && st.frame.ready.is_none()
            && !st.frame.failed
            && !st.output_removed
        {
            dispatch_with_timeout(&conn, &mut queue, &mut st, Duration::from_millis(250))?;
        }
        frame.destroy();
        match st.frame.ready {
            Some(presentation) if !st.frame.failed => {
                failures = 0;
                frames += 1;
                let b = &buffers[index];
                let lease = recycler.lease(index, b.map.clone(), (b.stride * b.height) as usize);
                let info = FrameInfo {
                    width: b.width,
                    height: b.height,
                    stride: b.stride,
                    format: b.format,
                    presentation_ns: Some(presentation),
                    ready_at: Instant::now(),
                };
                on_frame(&info, lease);
            }
            _ => {
                recycler.release(index);
                if stop.load(Ordering::Relaxed) {
                    break;
                }
                failures += 1;
                if let AfterFailure::End(why) = after_failure(st.output_removed, failures) {
                    info!("capture of {output_name} ends: {why}");
                    break;
                }
            }
        }
    }
    manager.destroy();
    let _ = queue.roundtrip(&mut st);
    Ok(frames)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failures_end_the_capture_only_when_the_output_is_gone_or_hopeless() {
        assert_eq!(after_failure(false, 1), AfterFailure::Retry);
        assert_eq!(
            after_failure(true, 1),
            AfterFailure::End("the output was removed")
        );
        assert_eq!(
            after_failure(false, MAX_CONSECUTIVE_FAILURES),
            AfterFailure::End("every copy fails")
        );
    }
}
