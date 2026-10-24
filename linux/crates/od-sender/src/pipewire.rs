//! Frames from a PipeWire video node as CPU buffers: KWin's virtual outputs
//! (zkde_screencast) today, Mutter / portal ScreenCast streams next. No
//! modifiers are offered, so the producer falls back to memfd/shm buffers;
//! the dmabuf path comes with hardware encode.

// Built for a backend; with the feature alone nothing calls it yet.
#![cfg_attr(not(any(feature = "kde", feature = "gnome")), allow(dead_code))]

use std::os::fd::OwnedFd;
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ::pipewire as pw;
use anyhow::{Context, Result, anyhow};
use pw::spa;
use pw::spa::param::video::VideoFormat;
use pw::spa::pod::Pod;
use tracing::{debug, info, warn};

use crate::backend::{CaptureEvent, Frame, FrameBuf, FrameSink, PixelFormat};

/// Which node to read and over which connection.
#[derive(Debug)]
pub struct PwSource {
    pub node: u32,
    /// `object.serial`, preferred over the id, which PipeWire reuses.
    pub serial: Option<u64>,
    /// A PipeWire remote handed out by a portal (`OpenPipeWireRemote`);
    /// `None` connects to the session's daemon.
    pub remote_fd: Option<OwnedFd>,
}

pub struct PwCapture {
    quit: pw::channel::Sender<()>,
    thread: Option<JoinHandle<()>>,
}

impl PwCapture {
    /// Read `src` and deliver its frames to `sink` until [`stop`](Self::stop).
    /// `size` is the preferred size: the source's own (KWin resamples to
    /// whatever is negotiated).
    pub fn spawn(src: PwSource, size: (u32, u32), sink: FrameSink) -> Result<Self> {
        let (quit_tx, quit_rx) = pw::channel::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<()>>();
        let thread = std::thread::Builder::new()
            .name("kde-pipewire".into())
            .spawn(move || {
                if let Err(e) = run(src, size, sink, quit_rx, &ready_tx) {
                    let _ = ready_tx.send(Err(e));
                }
            })?;
        ready_rx
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| anyhow!("PipeWire capture did not start within 5 s"))??;
        Ok(Self {
            quit: quit_tx,
            thread: Some(thread),
        })
    }

    pub fn stop(&mut self) {
        let _ = self.quit.send(());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for PwCapture {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Data {
    sink: FrameSink,
    format: spa::param::video::VideoInfoRaw,
    pixel: Option<PixelFormat>,
    streaming: bool,
    ended: bool,
    frames: u64,
}

impl Data {
    fn end(&mut self, why: String) {
        if !self.ended {
            self.ended = true;
            (self.sink)(CaptureEvent::Ended(why));
        }
    }
}

fn pixel_format(f: VideoFormat) -> Option<PixelFormat> {
    // SPA names bytes in memory order; wl_shm/DRM names are little-endian words.
    match f {
        VideoFormat::BGRx => Some(PixelFormat::Xrgb8888),
        VideoFormat::BGRA => Some(PixelFormat::Argb8888),
        VideoFormat::RGBx => Some(PixelFormat::Xbgr8888),
        VideoFormat::RGBA => Some(PixelFormat::Abgr8888),
        _ => None,
    }
}

fn format_param((width, height): (u32, u32)) -> Result<Vec<u8>> {
    use spa::param::format::{FormatProperties, MediaSubtype, MediaType};
    let obj = spa::pod::object!(
        spa::utils::SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(FormatProperties::MediaType, Id, MediaType::Video),
        spa::pod::property!(FormatProperties::MediaSubtype, Id, MediaSubtype::Raw),
        spa::pod::property!(
            FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            VideoFormat::BGRx,
            VideoFormat::BGRx,
            VideoFormat::BGRA,
            VideoFormat::RGBx,
            VideoFormat::RGBA
        ),
        spa::pod::property!(
            FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            // Preferred: the output's own size. KWin scales to whatever is
            // negotiated, so a different default means resampled frames.
            spa::utils::Rectangle { width, height },
            spa::utils::Rectangle {
                width: 1,
                height: 1
            },
            spa::utils::Rectangle {
                width: 8192,
                height: 8192
            }
        ),
        spa::pod::property!(
            FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            spa::utils::Fraction { num: 60, denom: 1 },
            spa::utils::Fraction { num: 0, denom: 1 },
            spa::utils::Fraction {
                num: 1000,
                denom: 1
            }
        ),
    );
    Ok(spa::pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &spa::pod::Value::Object(obj),
    )
    .map_err(|e| anyhow!("serializing the format: {e:?}"))?
    .0
    .into_inner())
}

fn run(
    src: PwSource,
    size: (u32, u32),
    sink: FrameSink,
    quit: pw::channel::Receiver<()>,
    ready: &mpsc::Sender<Result<()>>,
) -> Result<()> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None).context("PipeWire main loop")?;
    let context = pw::context::ContextRc::new(&mainloop, None).context("PipeWire context")?;
    let core = match src.remote_fd {
        Some(fd) => context
            .connect_fd_rc(fd, None)
            .context("connecting to the PipeWire remote")?,
        None => context
            .connect_rc(None)
            .context("connecting to PipeWire (is it running in this session?)")?,
    };

    let mut props = pw::properties::properties! {
        *pw::keys::MEDIA_TYPE => "Video",
        *pw::keys::MEDIA_CATEGORY => "Capture",
        *pw::keys::MEDIA_ROLE => "Screen",
    };
    // Target by object serial where the producer gave one, else by node id.
    let target = match src.serial {
        Some(serial) => {
            props.insert("target.object", serial.to_string());
            None
        }
        None => Some(src.node),
    };
    let stream = pw::stream::StreamBox::new(&core, "od-sender", props)?;

    let data = Data {
        sink,
        format: Default::default(),
        pixel: None,
        streaming: false,
        ended: false,
        frames: 0,
    };
    let _listener = stream
        .add_local_listener_with_user_data(data)
        .state_changed(|_, d, old, new| {
            debug!("pipewire stream {old:?} -> {new:?}");
            match new {
                pw::stream::StreamState::Streaming => d.streaming = true,
                pw::stream::StreamState::Error(e) => d.end(format!("PipeWire stream error: {e}")),
                pw::stream::StreamState::Unconnected if d.streaming => {
                    d.end("the virtual output's PipeWire stream went away".into())
                }
                _ => {}
            }
        })
        .param_changed(|_, d, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            if d.format.parse(param).is_err() {
                return;
            }
            d.pixel = pixel_format(d.format.format());
            let size = d.format.size();
            info!(
                "pipewire format {:?} {}x{} @{}/{}",
                d.format.format(),
                size.width,
                size.height,
                d.format.framerate().num,
                d.format.framerate().denom
            );
            if d.pixel.is_none() {
                d.end(format!(
                    "unsupported PipeWire format {:?}",
                    d.format.format()
                ));
            }
        })
        .process(|stream, d| {
            let Some(mut buffer) = stream.dequeue_buffer() else {
                return;
            };
            let Some(format) = d.pixel else { return };
            let size = d.format.size();
            let datas = buffer.datas_mut();
            let Some(data) = datas.first_mut() else {
                return;
            };
            let (offset, len, stride) = {
                let c = data.chunk();
                (c.offset() as usize, c.size() as usize, c.stride())
            };
            if len == 0 {
                return; // no new picture (cursor-only update)
            }
            let stride = if stride > 0 {
                stride as u32
            } else {
                size.width * 4
            };
            let need = stride as usize * size.height as usize;
            let Some(bytes) = data.data() else { return };
            if bytes.len() < offset + need {
                warn!(
                    "short PipeWire buffer: {} bytes, need {}",
                    bytes.len(),
                    offset + need
                );
                return;
            }
            d.frames += 1;
            (d.sink)(CaptureEvent::Frame(Frame {
                captured_at: Instant::now(),
                presentation_ns: None,
                buf: FrameBuf::Cpu {
                    pixels: bytes[offset..offset + need].to_vec().into(),
                    width: size.width,
                    height: size.height,
                    stride,
                    format,
                },
            }));
        })
        .register()?;

    let values = format_param(size)?;
    let mut params = [Pod::from_bytes(&values).context("format pod")?];
    stream.connect(
        spa::utils::Direction::Input,
        target,
        pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
        &mut params,
    )?;
    let ml = mainloop.clone();
    let _quit = quit.attach(mainloop.loop_(), move |_| ml.quit());
    let _ = ready.send(Ok(()));
    mainloop.run();
    let _ = stream.disconnect();
    debug!("pipewire capture done");
    Ok(())
}
