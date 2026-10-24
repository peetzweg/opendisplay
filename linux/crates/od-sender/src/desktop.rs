//! Desktop policy: turns a receiver's `hello` into the
//! output to create and the stream to send, the way `Mac/DesktopPolicy.swift`
//! and `Mac/StreamConfiguration.swift` do, so the Linux sender makes the same
//! choices as the Mac sender. Pure: no Wayland, no I/O, no clocks.
//!
//! * Panel facts come from `hello.panel` when it is valid (PROTOCOL.md §6.7),
//!   else from the deprecated `pixelsWide/High/scale`.
//! * The stream is the output raster bounded by the panel's pixels, the
//!   legacy `maxEncodeWide/High` ceiling, the `videoCaps` H.264 entries and
//!   the H.264 High@L5.2 frame-size and macroblock-rate limits (§6.5).
//! * When that stream is smaller than the default output, the output is
//!   shrunk to the stream, so capture is 1:1 and the receiver scales once.
//! * Only H.264: there is no HEVC encoder on this platform (§3.6).

use std::fmt;
use std::str::FromStr;
use std::time::{Duration, Instant};

use opendisplay_proto::control::{Hello, PanelFacts, VideoCap};

pub const H264: &str = "h264";

/// H.264 High@L5.2 MaxFS (macroblocks per frame).
const MAX_MACROBLOCKS_PER_FRAME: u64 = 36_864;
/// H.264 High@L5.2 MaxMBPS (macroblocks per second).
const MAX_MACROBLOCKS_PER_SECOND: u64 = 2_073_600;
/// Largest output axis the Mac policy builds (`DesktopPolicy.maxPixelsPerAxis`).
const MAX_PIXELS_PER_AXIS: u32 = 8_192;
/// The legacy rate when the receiver announces none (§6.1).
const DEFAULT_FPS: u32 = 60;

/// How the output scale is chosen.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum ScalePolicy {
    /// The receiver's announced scale verbatim on an output of its pixels:
    /// `panel.scale` when `panel` is valid, else `hello.scale` (3 on an
    /// iPhone). What the sender has always done.
    #[default]
    Passthrough,
    /// The Mac sender's rule: 2 for a scale of 1.5 and above, else 1, on a
    /// desktop of the receiver's own points when it reports them, else half
    /// its pixels at 2, else its pixels at 1.
    Mac,
    /// A fixed scale on an output of the receiver's pixels (`--scale`).
    Fixed(f64),
}

impl FromStr for ScalePolicy {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "passthrough" => Ok(Self::Passthrough),
            "mac" => Ok(Self::Mac),
            _ => match s.parse::<f64>() {
                Ok(v) if v.is_finite() && v > 0.0 => Ok(Self::Fixed(v)),
                _ => Err(format!(
                    "{s:?}: expected \"passthrough\", \"mac\" or a positive scale"
                )),
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DesktopOptions {
    pub scale: ScalePolicy,
    /// `--max-fps`: lowers the stream rate below the receiver's panel rate.
    pub max_fps: Option<f32>,
}

/// Where the panel facts came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FactsSource {
    /// A valid `hello.panel`.
    Panel,
    /// The deprecated fields; `panel` was absent.
    Legacy,
    /// The deprecated fields; `panel` was sent but failed validation.
    InvalidPanel,
}

/// The output to create (or resize) on the compositor.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OutputMode {
    /// Pixels, i.e. the capture raster.
    pub width: u32,
    pub height: u32,
    /// Refresh rate: the receiver's panel rate.
    pub hz: u32,
    pub scale: f64,
}

impl OutputMode {
    /// The size the compositor lays the output out at.
    pub fn logical(&self) -> (f64, f64) {
        (
            f64::from(self.width) / self.scale,
            f64::from(self.height) / self.scale,
        )
    }
}

/// The stream to encode; announced in `streamConfig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamPlan {
    pub codec: &'static str,
    pub width: u32,
    pub height: u32,
    /// A ceiling: the encoder's throughput decides the delivered rate.
    pub fps: u32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DesktopPlan {
    pub source: FactsSource,
    /// What the plan was built from (legacy fields read as a panel).
    pub facts: PanelFacts,
    pub output: OutputMode,
    pub stream: StreamPlan,
    /// The default output was larger than the best stream and was shrunk to
    /// it (§6.5, Mac sender #322).
    pub capped: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanError {
    /// Neither `panel` nor the deprecated fields give a usable size.
    InvalidSize { width: u32, height: u32 },
    /// `videoCaps` is present and lists no H.264 entry.
    NoH264,
    /// Every H.264 entry (or the legacy ceiling) rules out any stream.
    NoCompatibleConfiguration,
}

impl fmt::Display for PlanError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize { width, height } => {
                write!(f, "receiver announced an unusable size {width}x{height}")
            }
            Self::NoH264 => write!(f, "receiver does not offer H.264"),
            Self::NoCompatibleConfiguration => {
                write!(f, "receiver advertised no usable H.264 configuration")
            }
        }
    }
}

impl std::error::Error for PlanError {}

impl fmt::Display for DesktopPlan {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let p = &self.facts;
        let (lw, lh) = self.output.logical();
        write!(
            f,
            "{} {}x{} @{}",
            match self.source {
                FactsSource::Panel => "panel",
                FactsSource::Legacy => "legacy",
                FactsSource::InvalidPanel => "legacy (invalid panel ignored)",
            },
            p.pixels_wide,
            p.pixels_high,
            p.scale
        )?;
        if let Some((w, h)) = p.points {
            write!(f, " points {w}x{h}")?;
        }
        write!(
            f,
            " -> output {}x{} @{}Hz scale {} ({:.0}x{:.0} logical){} -> {} {}x{} @{}",
            self.output.width,
            self.output.height,
            self.output.hz,
            self.output.scale,
            lw,
            lh,
            if self.capped {
                ", capped to stream"
            } else {
                ""
            },
            self.stream.codec,
            self.stream.width,
            self.stream.height,
            self.stream.fps,
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Size {
    w: u32,
    h: u32,
}

impl Size {
    fn pixels(self) -> u64 {
        u64::from(self.w) * u64::from(self.h)
    }

    fn macroblocks(self) -> u64 {
        u64::from(self.w.div_ceil(16)) * u64::from(self.h.div_ceil(16))
    }
}

fn even(v: u32) -> u32 {
    (v & !1).max(2)
}

fn even_f(v: f64) -> u32 {
    even(v.clamp(0.0, f64::from(u32::MAX)) as u32)
}

/// The receiver's panel rate, as the output's refresh and the stream's
/// ceiling.
fn panel_hz(hello: &Hello) -> u32 {
    hello
        .display_max_frame_rate
        .unwrap_or(DEFAULT_FPS)
        .clamp(30, 240)
}

/// Plan the output and the stream for a receiver.
pub fn plan(hello: &Hello, opts: &DesktopOptions) -> Result<DesktopPlan, PlanError> {
    let (source, facts) = match hello.panel_facts() {
        Some(f) => (FactsSource::Panel, f),
        None => {
            if hello.pixels_wide < 2 || hello.pixels_high < 2 {
                return Err(PlanError::InvalidSize {
                    width: hello.pixels_wide,
                    height: hello.pixels_high,
                });
            }
            let source = if hello.has_invalid_panel() {
                FactsSource::InvalidPanel
            } else {
                FactsSource::Legacy
            };
            // The deprecated fields are pixels of a 2x desktop (§6.1). The
            // Mac sender never reads `hello.scale`; passthrough does, as the
            // Linux sender always has.
            let scale = match opts.scale {
                ScalePolicy::Passthrough if hello.scale.is_finite() && hello.scale >= 1.0 => {
                    hello.scale
                }
                ScalePolicy::Passthrough => 1.0,
                _ => 2.0,
            };
            let facts = PanelFacts {
                pixels_wide: hello.pixels_wide,
                pixels_high: hello.pixels_high,
                scale,
                points: None,
            };
            (source, facts)
        }
    };

    let presentable = Size {
        w: facts.pixels_wide,
        h: facts.pixels_high,
    };
    // The default desktop: pixels, scale, and whether it was asked for in a
    // way that must not be shrunk to the stream (the Mac's `explicit`).
    let (desktop, scale) = match opts.scale {
        ScalePolicy::Passthrough => (presentable, facts.scale),
        ScalePolicy::Fixed(s) => (presentable, s),
        ScalePolicy::Mac => mac_desktop(&facts),
    };
    let explicit = desktop.w > presentable.w || desktop.h > presentable.h;

    let limits = Limits::from_hello(hello, presentable, opts);
    let (best, best_fps) = limits.select(desktop)?;
    let desktop_even = Size {
        w: even(desktop.w),
        h: even(desktop.h),
    };
    let capped = !explicit && (best.w < desktop_even.w || best.h < desktop_even.h);
    let output = if !capped {
        desktop
    } else if let ScalePolicy::Mac = opts.scale {
        // Whole points at the same scale, as the Mac's `canvas(for:)`.
        let s = scale as u32;
        Size {
            w: even(best.w / s) * s,
            h: even(best.h / s) * s,
        }
    } else {
        Size {
            w: best.w,
            h: best.h,
        }
    };
    let (stream, fps) = if output == best {
        (best, best_fps)
    } else {
        limits.select(output)?
    };

    Ok(DesktopPlan {
        source,
        facts,
        output: OutputMode {
            width: output.w,
            height: output.h,
            hz: panel_hz(hello),
            scale,
        },
        stream: StreamPlan {
            codec: H264,
            width: stream.w,
            height: stream.h,
            fps,
        },
        capped,
    })
}

/// `DesktopPolicy.plan` steps A, B and D2 for the default choice. Step D1
/// (526-point minimum for 2x) is a macOS virtual-display limit and is not
/// applied here.
fn mac_desktop(facts: &PanelFacts) -> (Size, f64) {
    let scale: u32 = if facts.scale >= 1.5 { 2 } else { 1 };
    let (mut w, mut h) = match facts.points {
        Some((pw, ph)) => (even(pw), even(ph)),
        None if scale == 2 => (even(facts.pixels_wide / 2), even(facts.pixels_high / 2)),
        None => (even(facts.pixels_wide), even(facts.pixels_high)),
    };
    let longest = w.max(h) * scale;
    if longest > MAX_PIXELS_PER_AXIS {
        let f = f64::from(MAX_PIXELS_PER_AXIS) / f64::from(longest);
        w = even_f((f64::from(w) * f).floor());
        h = even_f((f64::from(h) * f).floor());
    }
    (
        Size {
            w: w * scale,
            h: h * scale,
        },
        f64::from(scale),
    )
}

/// One `videoCaps` H.264 entry, or the legacy contract (`None`).
type Envelope = Option<VideoCap>;

/// Everything that bounds the stream, independent of the source raster.
struct Limits {
    presentable: Size,
    legacy_ceiling: Option<Size>,
    envelopes: Result<Vec<Envelope>, PlanError>,
    target_fps: u32,
}

impl Limits {
    fn from_hello(hello: &Hello, presentable: Size, opts: &DesktopOptions) -> Self {
        let legacy_ceiling = match (hello.max_encode_wide, hello.max_encode_high) {
            (Some(w), Some(h)) if w > 0 && h > 0 => Some(Size { w, h }),
            _ => None,
        };
        // Absent `videoCaps` is the legacy H.264 contract.
        let envelopes = match &hello.video_caps {
            None => Ok(vec![None]),
            Some(caps) => {
                let h264: Vec<Envelope> = caps
                    .iter()
                    .filter(|c| c.codec.eq_ignore_ascii_case(H264))
                    .cloned()
                    .map(Some)
                    .collect();
                if h264.is_empty() {
                    Err(PlanError::NoH264)
                } else {
                    Ok(h264)
                }
            }
        };
        let panel = panel_hz(hello);
        let target_fps = opts
            .max_fps
            .map_or(panel, |cap| (cap.round().max(1.0) as u32).min(panel));
        Limits {
            presentable,
            legacy_ceiling,
            envelopes,
            target_fps,
        }
    }

    /// `VideoStreamConfiguration.make` at Best quality for H.264: the most
    /// detailed raster any envelope allows (then the higher rate).
    fn select(&self, source: Size) -> Result<(Size, u32), PlanError> {
        let envelopes = self.envelopes.as_ref().map_err(Clone::clone)?;
        let shown = fit(source, Some(self.presentable.w), Some(self.presentable.h));
        let scaled = Size {
            w: even(shown.w),
            h: even(shown.h),
        };
        envelopes
            .iter()
            .filter_map(|e| self.candidate(scaled, e.as_ref()))
            .max_by_key(|&(size, fps)| (size.pixels(), fps))
            .ok_or(PlanError::NoCompatibleConfiguration)
    }

    fn candidate(&self, scaled: Size, cap: Option<&VideoCap>) -> Option<(Size, u32)> {
        if let Some(c) = self.legacy_ceiling {
            if c.w < 2 || c.h < 2 {
                return None;
            }
        }
        if let Some(cap) = cap {
            if cap.max_width.is_some_and(|v| v < 2)
                || cap.max_height.is_some_and(|v| v < 2)
                || cap.max_frame_rate.is_some_and(|v| v < 1)
                || cap.max_pixels_per_second.is_some_and(|v| v < 4)
            {
                return None;
            }
        }
        let mut size = match self.legacy_ceiling {
            Some(c) => fit(scaled, Some(c.w), Some(c.h)),
            None => scaled,
        };
        if let Some(cap) = cap {
            size = fit(size, cap.max_width, cap.max_height);
        }
        size = fit_h264_level_frame(size);
        let pps = cap.and_then(|c| c.max_pixels_per_second);
        if let Some(pps) = pps {
            size = fit_pixels(size, pps)?;
        }
        // The panel rate is a display fact, not a decoder promise (§6.1):
        // above the legacy 60 only when this H.264 entry says so.
        let decoder_fps = cap.and_then(|c| c.max_frame_rate).unwrap_or(DEFAULT_FPS);
        let mut fps = self.target_fps.min(decoder_fps);
        if let Some(pps) = pps {
            fps = fps.min(u32::try_from(pps / size.pixels()).unwrap_or(u32::MAX));
        }
        if fps == 0 {
            return None;
        }
        Some((size, safe_h264_frame_rate(size, fps)))
    }
}

/// Fit inside the axes that are present, keeping the aspect.
fn fit(size: Size, max_w: Option<u32>, max_h: Option<u32>) -> Size {
    let ws = max_w
        .filter(|&v| v > 0)
        .map(|v| f64::from(v) / f64::from(size.w));
    let hs = max_h
        .filter(|&v| v > 0)
        .map(|v| f64::from(v) / f64::from(size.h));
    let s = ws.unwrap_or(1.0).min(hs.unwrap_or(1.0)).min(1.0);
    if s >= 1.0 {
        return size;
    }
    Size {
        w: even_f(f64::from(size.w) * s),
        h: even_f(f64::from(size.h) * s),
    }
}

/// Fit inside a pixel budget, or `None` when even the fitted raster misses.
fn fit_pixels(size: Size, max_pixels: u64) -> Option<Size> {
    if max_pixels < 4 {
        return None;
    }
    if size.pixels() <= max_pixels {
        return Some(size);
    }
    let s = (max_pixels as f64 / size.pixels() as f64).sqrt();
    let fitted = Size {
        w: even_f(f64::from(size.w) * s),
        h: even_f(f64::from(size.h) * s),
    };
    (fitted.pixels() <= max_pixels).then_some(fitted)
}

/// High@L5.2 MaxFS, keeping the aspect as closely as 2-pixel steps allow.
fn fit_h264_level_frame(size: Size) -> Size {
    let mbs = size.macroblocks();
    if mbs <= MAX_MACROBLOCKS_PER_FRAME {
        return size;
    }
    let s = (MAX_MACROBLOCKS_PER_FRAME as f64 / mbs as f64).sqrt();
    let mut fitted = Size {
        w: even_f(f64::from(size.w) * s),
        h: even_f(f64::from(size.h) * s),
    };
    // Macroblocks round each axis up to 16, so the area-derived scale can
    // land a few blocks over; trim the axis that is relatively larger.
    while fitted.macroblocks() > MAX_MACROBLOCKS_PER_FRAME {
        if f64::from(fitted.w) / f64::from(size.w) >= f64::from(fitted.h) / f64::from(size.h) {
            fitted.w = (fitted.w - 2).max(2);
        } else {
            fitted.h = (fitted.h - 2).max(2);
        }
    }
    fitted
}

/// High@L5.2 MaxMBPS, one frame per second below the nominal limit.
fn safe_h264_frame_rate(size: Size, requested: u32) -> u32 {
    let level = (MAX_MACROBLOCKS_PER_SECOND / size.macroblocks().max(1)).max(1);
    if level >= u64::from(requested) {
        return requested;
    }
    (level as u32 - 1).max(1)
}

/// Re-sent `hello`s settle for this long before the output is rebuilt
/// (§6.1; the Mac sender's 300 ms).
pub const HELLO_DEBOUNCE: Duration = Duration::from_millis(300);

/// Debounces re-sent `hello`s (rotation, resize, capability updates) into
/// one rebuild, and only when the plan actually changes.
///
/// Feed every plan to [`Debounce::on_hello`]; sleep until
/// [`Debounce::deadline`] and call [`Debounce::poll`]. The first plan is
/// applied at once (nothing runs yet); later ones wait until no newer plan
/// arrived for `delay`. A flurry that ends on the plan already running
/// rebuilds nothing. Replying `welcome` to every `hello` is the caller's job.
#[derive(Debug, Clone)]
pub struct Debounce<P> {
    delay: Duration,
    applied: Option<P>,
    pending: Option<(P, Instant)>,
}

impl<P: Clone + PartialEq> Debounce<P> {
    pub fn new(delay: Duration) -> Self {
        Debounce {
            delay,
            applied: None,
            pending: None,
        }
    }

    /// A new plan from a `hello`. Returns it when it must be applied now.
    pub fn on_hello(&mut self, plan: P, now: Instant) -> Option<P> {
        match &self.applied {
            None => {
                self.pending = None;
                self.applied = Some(plan.clone());
                Some(plan)
            }
            Some(current) if *current == plan => {
                self.pending = None;
                None
            }
            Some(_) => {
                self.pending = Some((plan, now + self.delay));
                None
            }
        }
    }

    /// When to call [`Debounce::poll`] next, if a rebuild is pending.
    pub fn deadline(&self) -> Option<Instant> {
        self.pending.as_ref().map(|(_, at)| *at)
    }

    /// The plan to apply now, if the pending one has settled.
    pub fn poll(&mut self, now: Instant) -> Option<P> {
        match &self.pending {
            Some((_, at)) if *at <= now => {
                let (plan, _) = self.pending.take()?;
                self.applied = Some(plan.clone());
                Some(plan)
            }
            _ => None,
        }
    }

    /// The plan currently running.
    #[allow(dead_code)] // tests; the session keeps its own copy
    pub fn applied(&self) -> Option<&P> {
        self.applied.as_ref()
    }

    /// Forget everything, e.g. when the output is torn down.
    #[allow(dead_code)] // tests; a session ends with its debouncer
    pub fn reset(&mut self) {
        self.applied = None;
        self.pending = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use opendisplay_proto::ControlMessage;

    fn hello(json: &str) -> Hello {
        match ControlMessage::parse(json.as_bytes()) {
            Ok(ControlMessage::Hello(h)) => h,
            other => panic!("{other:?}"),
        }
    }

    fn opts(scale: ScalePolicy) -> DesktopOptions {
        DesktopOptions {
            scale,
            max_fps: None,
        }
    }

    const PASS: DesktopOptions = DesktopOptions {
        scale: ScalePolicy::Passthrough,
        max_fps: None,
    };
    const MAC: DesktopOptions = DesktopOptions {
        scale: ScalePolicy::Mac,
        max_fps: None,
    };

    /// (output w, h, hz, scale, capped), (stream w, h, fps)
    type Expect = ((u32, u32, u32, f64, bool), (u32, u32, u32));

    fn check(name: &str, h: &Hello, o: &DesktopOptions, source: FactsSource, want: Expect) {
        let p = plan(h, o).unwrap_or_else(|e| panic!("{name}: {e}"));
        let got = (
            (
                p.output.width,
                p.output.height,
                p.output.hz,
                p.output.scale,
                p.capped,
            ),
            (p.stream.width, p.stream.height, p.stream.fps),
        );
        assert_eq!(got, want, "{name} {:?}: {p}", o.scale);
        assert_eq!(p.source, source, "{name}");
        assert_eq!(p.stream.codec, H264);
        // Invariants: the stream never exceeds the output or the panel, and
        // stays within High@L5.2.
        assert!(p.stream.width <= p.output.width && p.stream.height <= p.output.height);
        assert!(p.stream.width <= p.facts.pixels_wide && p.stream.height <= p.facts.pixels_high);
        let s = Size {
            w: p.stream.width,
            h: p.stream.height,
        };
        assert!(s.macroblocks() <= MAX_MACROBLOCKS_PER_FRAME);
        assert!(s.macroblocks() * u64::from(p.stream.fps) <= MAX_MACROBLOCKS_PER_SECOND);
        assert_eq!(p.stream.width % 2 + p.stream.height % 2, 0);
    }

    macro_rules! fixture {
        ($name:literal) => {
            hello(include_str!(concat!(
                "../tests/fixtures/hello/",
                $name,
                ".json"
            )))
        };
    }

    // Plan snapshots for realistic receivers (fixtures derived from
    // Shared/StreamReceiver.swift `sendHello`, iOS/OpenSidecarPhoneApp.swift,
    // MacReceiver/MacReceiver.swift and tools/fake-receiver.swift).

    #[test]
    fn iphone_landscape() {
        let h = fixture!("iphone-15-pro-landscape");
        // Today: scale 3 on the panel's pixels; even stream raster; the H.264
        // entry's 60 caps the 120 Hz panel.
        check(
            "iphone",
            &h,
            &PASS,
            FactsSource::Panel,
            ((2556, 1179, 120, 3.0, false), (2556, 1178, 60)),
        );
        // Mac rule: half the pixels at 2x, even points.
        check(
            "iphone",
            &h,
            &MAC,
            FactsSource::Panel,
            ((2556, 1176, 120, 2.0, false), (2556, 1176, 60)),
        );
    }

    #[test]
    fn iphone_portrait() {
        let h = fixture!("iphone-15-pro-portrait");
        check(
            "iphone-p",
            &h,
            &PASS,
            FactsSource::Panel,
            ((1179, 2556, 120, 3.0, false), (1178, 2556, 60)),
        );
        check(
            "iphone-p",
            &h,
            &MAC,
            FactsSource::Panel,
            ((1176, 2556, 120, 2.0, false), (1176, 2556, 60)),
        );
    }

    #[test]
    fn ipad_pro() {
        let h = fixture!("ipad-pro-12.9");
        let want = ((2732, 2048, 120, 2.0, false), (2732, 2048, 60));
        check("ipad", &h, &PASS, FactsSource::Panel, want);
        check("ipad", &h, &MAC, FactsSource::Panel, want);
    }

    #[test]
    fn ipad_air_2_decode_budget_lowers_the_rate_not_the_raster() {
        let h = fixture!("ipad-air-2");
        // 133,693,440 px/s over 2048x1536 = 42.5 fps.
        let want = ((2048, 1536, 60, 2.0, false), (2048, 1536, 42));
        check("air2", &h, &PASS, FactsSource::Panel, want);
        check("air2", &h, &MAC, FactsSource::Panel, want);
    }

    #[test]
    fn mac_5k_is_capped_to_4096x2304_at_55() {
        // PROTOCOL.md §6.5: "For a 16:9 5K source that codec rule selects
        // 4096×2304 at 55 FPS"; the output follows the stream (#322).
        let h = fixture!("mac-5k");
        let want = ((4096, 2304, 60, 2.0, true), (4096, 2304, 55));
        check("5k", &h, &PASS, FactsSource::Panel, want);
        check("5k", &h, &MAC, FactsSource::Panel, want);
        assert_eq!(h.power, Some(vec!["shutdown".into()]));
    }

    #[test]
    fn mac_5k_more_space_is_explicit_and_not_shrunk() {
        // Looks like 3200x1800 on a 5K panel: the Mac policy keeps the 2x
        // desktop of the receiver's points and scales the stream once.
        let mut h = fixture!("mac-5k");
        let panel = h.panel.as_mut().unwrap();
        panel.points_wide = Some(3200);
        panel.points_high = Some(1800);
        check(
            "5k-more",
            &h,
            &MAC,
            FactsSource::Panel,
            ((6400, 3600, 60, 2.0, false), (4096, 2304, 55)),
        );
        // Passthrough ignores points.
        check(
            "5k-more",
            &h,
            &PASS,
            FactsSource::Panel,
            ((4096, 2304, 60, 2.0, true), (4096, 2304, 55)),
        );
    }

    #[test]
    fn mac_non_retina_gets_1x() {
        let h = fixture!("mac-1080p-1x");
        // The legacy fields say 3840x2160 @2; panel facts win in both policies.
        let want = ((1920, 1080, 60, 1.0, false), (1920, 1080, 60));
        check("1x", &h, &PASS, FactsSource::Panel, want);
        check("1x", &h, &MAC, FactsSource::Panel, want);
    }

    #[test]
    fn legacy_receiver_without_panel() {
        let h = fixture!("legacy-ipad");
        let want = ((2732, 2048, 60, 2.0, false), (2732, 2048, 60));
        check("legacy", &h, &PASS, FactsSource::Legacy, want);
        check("legacy", &h, &MAC, FactsSource::Legacy, want);
    }

    #[test]
    fn legacy_iphone_scale_is_passthrough_only() {
        let h = hello(
            r#"{"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3,"device":"iPhone"}"#,
        );
        check(
            "legacy-phone",
            &h,
            &PASS,
            FactsSource::Legacy,
            ((2556, 1179, 60, 3.0, false), (2556, 1178, 60)),
        );
        // The Mac sender reads the legacy fields as a 2x panel.
        check(
            "legacy-phone",
            &h,
            &MAC,
            FactsSource::Legacy,
            ((2556, 1176, 60, 2.0, false), (2556, 1176, 60)),
        );
        // A sub-1 legacy scale is clamped as before.
        let h = hello(r#"{"type":"hello","pixelsWide":1920,"pixelsHigh":1080,"scale":0}"#);
        assert_eq!(plan(&h, &PASS).unwrap().output.scale, 1.0);
    }

    #[test]
    fn invalid_panel_falls_back_to_the_deprecated_fields() {
        let h = hello(
            r#"{"type":"hello","pixelsWide":2732,"pixelsHigh":2048,"scale":2,"panel":{"pixelsWide":2732,"pixelsHigh":2048,"scale":2,"pointsWide":1366}}"#,
        );
        check(
            "invalid",
            &h,
            &MAC,
            FactsSource::InvalidPanel,
            ((2732, 2048, 60, 2.0, false), (2732, 2048, 60)),
        );
        let h = hello(r#"{"type":"hello","pixelsWide":0,"pixelsHigh":0,"scale":2}"#);
        assert_eq!(
            plan(&h, &PASS),
            Err(PlanError::InvalidSize {
                width: 0,
                height: 0
            })
        );
    }

    #[test]
    fn fixed_scale() {
        let h = fixture!("iphone-15-pro-landscape");
        check(
            "fixed",
            &h,
            &opts(ScalePolicy::Fixed(2.0)),
            FactsSource::Panel,
            ((2556, 1179, 120, 2.0, false), (2556, 1178, 60)),
        );
    }

    #[test]
    fn max_fps_and_panel_rate() {
        let mut h = fixture!("ipad-pro-12.9");
        let o = DesktopOptions {
            scale: ScalePolicy::Passthrough,
            max_fps: Some(30.0),
        };
        assert_eq!(plan(&h, &o).unwrap().stream.fps, 30);
        // A 120 Hz panel is a display fact, not a decoder promise: the
        // legacy contract (no videoCaps) streams at most 60, like the Mac.
        h.video_caps = None;
        let p = plan(&h, &PASS).unwrap();
        assert_eq!((p.output.hz, p.stream.fps), (120, 60));
        let mut small = fixture!("iphone-15-pro-landscape");
        small.video_caps = None;
        assert_eq!(plan(&small, &PASS).unwrap().stream.fps, 60);
        // An H.264 entry promising 120 lifts the cap up to the panel rate...
        let h264_at = |fps| {
            Some(vec![VideoCap {
                codec: "h264".into(),
                max_width: None,
                max_height: None,
                max_frame_rate: Some(fps),
                max_pixels_per_second: None,
            }])
        };
        small.video_caps = h264_at(120);
        assert_eq!(plan(&small, &PASS).unwrap().stream.fps, 120);
        small.video_caps = h264_at(240);
        assert_eq!(plan(&small, &PASS).unwrap().stream.fps, 120, "panel rate");
        // ...and High@L5.2 still bounds it: 21,888 macroblocks allow 94 fps,
        // minus one of headroom.
        h.video_caps = h264_at(120);
        assert_eq!(plan(&h, &PASS).unwrap().stream.fps, 93);
        // Absent displayMaxFrameRate is the legacy 60.
        h.display_max_frame_rate = None;
        let p = plan(&h, &PASS).unwrap();
        assert_eq!((p.output.hz, p.stream.fps), (60, 60));
    }

    /// After the next bump a receiver may send only `panel` (§6.1).
    #[test]
    fn a_panel_only_hello_plans_from_the_panel() {
        let mut h = fixture!("iphone-15-pro-portrait");
        let with_legacy = plan(&h, &PASS).unwrap();
        (h.pixels_wide, h.pixels_high, h.scale) = (0, 0, 0.0);
        assert_eq!(plan(&h, &PASS).unwrap(), with_legacy);
        h.panel = None;
        assert!(matches!(
            plan(&h, &PASS),
            Err(PlanError::InvalidSize { .. })
        ));
    }

    #[test]
    fn video_caps_without_h264_is_an_error() {
        let mut h = fixture!("ipad-pro-12.9");
        h.video_caps.as_mut().unwrap().retain(|c| c.codec != "h264");
        assert_eq!(plan(&h, &PASS), Err(PlanError::NoH264));
        // Entries that rule everything out.
        h.video_caps = Some(vec![VideoCap {
            codec: "H264".into(),
            max_width: Some(1),
            max_height: None,
            max_frame_rate: None,
            max_pixels_per_second: None,
        }]);
        assert_eq!(plan(&h, &PASS), Err(PlanError::NoCompatibleConfiguration));
    }

    #[test]
    fn alternative_envelopes_pick_the_most_detail_then_the_rate() {
        let mut h = fixture!("ipad-pro-12.9");
        let cap = |w, fps| VideoCap {
            codec: "h264".into(),
            max_width: Some(w),
            max_height: None,
            max_frame_rate: Some(fps),
            max_pixels_per_second: None,
        };
        h.video_caps = Some(vec![cap(1920, 120), cap(2732, 30), cap(2732, 60)]);
        let p = plan(&h, &PASS).unwrap();
        assert_eq!(
            (p.stream.width, p.stream.height, p.stream.fps),
            (2732, 2048, 60)
        );
    }

    #[test]
    fn single_axis_caps_and_ceilings() {
        let mut h = fixture!("legacy-ipad");
        h.max_encode_wide = Some(1920);
        h.max_encode_high = Some(1080);
        // 2732x2048 into 1920x1080: height-bound.
        let p = plan(&h, &PASS).unwrap();
        assert!(p.capped);
        assert_eq!((p.stream.width, p.stream.height), (1440, 1080));
        assert_eq!((p.output.width, p.output.height), (1440, 1080));
        h.max_encode_wide = None;
        h.video_caps = Some(vec![VideoCap {
            codec: "h264".into(),
            max_width: None,
            max_height: Some(1024),
            max_frame_rate: None,
            max_pixels_per_second: None,
        }]);
        let p = plan(&h, &MAC).unwrap();
        // The best stream is 1366x1024; the output takes whole points at 2x.
        assert_eq!((p.output.width, p.output.height), (1364, 1024));
        assert_eq!((p.stream.width, p.stream.height), (1364, 1024));
    }

    #[test]
    fn level_limits() {
        // 8K: MaxFS first, then MaxMBPS.
        let s = fit_h264_level_frame(Size { w: 7680, h: 4320 });
        assert!(s.macroblocks() <= MAX_MACROBLOCKS_PER_FRAME);
        assert_eq!(s, Size { w: 4096, h: 2304 });
        assert_eq!(safe_h264_frame_rate(s, 60), 55);
        // 1080p: 8160 macroblocks, 254 fps at L5.2.
        assert_eq!(safe_h264_frame_rate(Size { w: 1920, h: 1080 }, 255), 253);
        assert_eq!(safe_h264_frame_rate(Size { w: 1920, h: 1080 }, 240), 240);
        // Under the limit the request stands.
        assert_eq!(safe_h264_frame_rate(Size { w: 1920, h: 1080 }, 60), 60);
    }

    #[test]
    fn scale_policy_parses() {
        assert_eq!("passthrough".parse(), Ok(ScalePolicy::Passthrough));
        assert_eq!("mac".parse(), Ok(ScalePolicy::Mac));
        assert_eq!("1.5".parse(), Ok(ScalePolicy::Fixed(1.5)));
        assert!("0".parse::<ScalePolicy>().is_err());
        assert!("nan".parse::<ScalePolicy>().is_err());
        assert!("big".parse::<ScalePolicy>().is_err());
    }

    #[test]
    fn plan_logs_in_one_line() {
        let p = plan(&fixture!("mac-5k"), &MAC).unwrap();
        assert_eq!(
            p.to_string(),
            "panel 5120x2880 @2 points 2560x1440 -> output 4096x2304 @60Hz scale 2 (2048x1152 logical), capped to stream -> h264 4096x2304 @55"
        );
    }

    #[test]
    fn debounce_applies_the_first_plan_at_once() {
        let t = Instant::now();
        let mut d = Debounce::new(HELLO_DEBOUNCE);
        assert_eq!(d.on_hello(1, t), Some(1));
        assert_eq!(d.deadline(), None);
        assert_eq!(d.applied(), Some(&1));
        // A repeat of the running plan does nothing.
        assert_eq!(d.on_hello(1, t), None);
        assert_eq!(d.deadline(), None);
    }

    #[test]
    fn debounce_settles_a_flurry_into_one_rebuild() {
        let t = Instant::now();
        let ms = Duration::from_millis;
        let mut d = Debounce::new(HELLO_DEBOUNCE);
        d.on_hello("landscape", t);
        assert_eq!(d.on_hello("portrait", t + ms(10)), None);
        assert_eq!(d.on_hello("landscape-left", t + ms(100)), None);
        assert_eq!(d.on_hello("portrait", t + ms(200)), None);
        // Each hello restarts the wait.
        assert_eq!(d.deadline(), Some(t + ms(500)));
        assert_eq!(d.poll(t + ms(310)), None);
        assert_eq!(d.poll(t + ms(500)), Some("portrait"));
        assert_eq!(d.applied(), Some(&"portrait"));
        assert_eq!(d.deadline(), None);
        assert_eq!(d.poll(t + ms(900)), None);
    }

    #[test]
    fn debounce_drops_a_flurry_that_ends_where_it_started() {
        let t = Instant::now();
        let ms = Duration::from_millis;
        let mut d = Debounce::new(HELLO_DEBOUNCE);
        d.on_hello("landscape", t);
        d.on_hello("portrait", t + ms(10));
        assert_eq!(d.on_hello("landscape", t + ms(50)), None);
        assert_eq!(d.deadline(), None);
        assert_eq!(d.poll(t + ms(1000)), None);
        assert_eq!(d.applied(), Some(&"landscape"));
    }

    #[test]
    fn debounce_reset_applies_the_next_plan_at_once() {
        let t = Instant::now();
        let mut d = Debounce::new(HELLO_DEBOUNCE);
        d.on_hello(1, t);
        d.on_hello(2, t);
        d.reset();
        assert_eq!(d.poll(t + HELLO_DEBOUNCE), None);
        assert_eq!(d.on_hello(3, t), Some(3));
    }

    #[test]
    fn debounce_on_real_plans_ignores_hellos_that_do_not_change_the_plan() {
        // A Mac receiver re-sends hello when `addrs` changes (§6.4): same
        // plan, no rebuild.
        let t = Instant::now();
        let mut d = Debounce::new(HELLO_DEBOUNCE);
        let mut h = fixture!("mac-5k");
        d.on_hello(plan(&h, &PASS).unwrap(), t);
        h.addrs = Some(vec!["192.168.1.20".into()]);
        assert_eq!(d.on_hello(plan(&h, &PASS).unwrap(), t), None);
        assert_eq!(d.deadline(), None);
    }
}
