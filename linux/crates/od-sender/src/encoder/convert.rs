//! BGRA → 4:2:0 for the FFmpeg encoders, split into horizontal bands that
//! convert in parallel, each through its own swscale context.
//!
//! swscale's own `threads` option does nothing for the stateful API we use
//! (FFmpeg 9, measured), and a single context costs ~14-24 ms per 4096x2304
//! frame on an M1 Pro, a third of the 4K encode. Bands start on even rows
//! (multiples of 16), and the area filter averages each 2x2 chroma block
//! from its own rows only, so the banded output is byte-identical to one
//! context over the whole frame (with accurate rounding, see
//! `new_context`). Bilinear is not: its chroma taps reach into the
//! neighbouring band.

use std::thread;

use anyhow::{Result, bail};
use ff::format::Pixel;
use ffmpeg_next as ff;

/// Rows per band at least; smaller bands cost more in thread hand-off than
/// they save.
const MIN_BAND_ROWS: u32 = 128;
const MAX_BANDS: usize = 8;

struct Band {
    ctx: *mut ff::ffi::SwsContext,
    y0: u32,
    rows: u32,
}

// SAFETY: a band's context is only ever used by one thread at a time
// (`convert` hands each band to exactly one worker).
unsafe impl Send for Band {}

impl Drop for Band {
    fn drop(&mut self) {
        // SAFETY: allocated by `sws_getContext`, freed once.
        unsafe { ff::ffi::sws_freeContext(self.ctx) };
    }
}

/// Destination planes; each band writes a disjoint range of rows.
#[derive(Clone, Copy)]
struct Planes {
    data: [*mut u8; 4],
    linesize: [i32; 4],
}

// SAFETY: bands write disjoint rows of the planes (see `convert`).
unsafe impl Send for Planes {}
unsafe impl Sync for Planes {}

pub struct Converter {
    bands: Vec<Band>,
    width: u32,
    height: u32,
    format: Pixel,
}

/// How many bands to use for a frame `height` rows high, given the
/// encoder's thread setting (0 = all cores).
pub fn band_count(height: u32, threads: u16) -> usize {
    let cores = if threads == 0 {
        thread::available_parallelism().map_or(4, |n| n.get())
    } else {
        threads as usize
    };
    cores
        .min(MAX_BANDS)
        .min((height / MIN_BAND_ROWS) as usize)
        .max(1)
}

impl Converter {
    /// `format` is a 4:2:0 format (YUV420P or NV12); `width`/`height` even.
    pub fn new(width: u32, height: u32, format: Pixel, bands: usize) -> Result<Self> {
        if !matches!(format, Pixel::YUV420P | Pixel::NV12) {
            bail!("no BGRA conversion to {format:?}");
        }
        let bands = bands.max(1) as u32;
        // Multiples of 16 rows keep every band's chroma rows whole and its
        // plane offsets aligned; the last band takes the remainder.
        let step = ((height / bands) & !15).max(16);
        let mut out = Vec::new();
        let mut y0 = 0;
        while y0 < height {
            let rows = if out.len() as u32 == bands - 1 || y0 + step >= height {
                height - y0
            } else {
                step
            };
            out.push(Band {
                ctx: new_context(width, rows, format)?,
                y0,
                rows,
            });
            y0 += rows;
        }
        Ok(Self {
            bands: out,
            width,
            height,
            format,
        })
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    #[cfg(test)]
    fn bands(&self) -> usize {
        self.bands.len()
    }

    /// Convert one BGRA/BGRX frame into `dst`, which must be `format` at
    /// this converter's size.
    pub fn convert(&mut self, bgra: &[u8], stride: u32, dst: &mut ff::frame::Video) -> Result<()> {
        let (w, h) = (self.width as usize, self.height as usize);
        if (stride as usize) < w * 4 || bgra.len() < stride as usize * (h - 1) + w * 4 {
            bail!("frame buffer smaller than {w}x{h} at stride {stride}");
        }
        if dst.format() != self.format || dst.width() != self.width || dst.height() != self.height {
            bail!("destination frame does not match the converter");
        }
        // SAFETY: plain reads of the frame's plane pointers.
        let planes = unsafe {
            let f = dst.as_mut_ptr();
            if ff::ffi::av_frame_make_writable(f) < 0 {
                bail!("av_frame_make_writable failed");
            }
            let (data, linesize) = (&(*f).data, &(*f).linesize);
            Planes {
                data: [data[0], data[1], data[2], data[3]],
                linesize: [linesize[0], linesize[1], linesize[2], linesize[3]],
            }
        };
        let (first, rest) = self.bands.split_first_mut().expect("at least one band");
        thread::scope(|s| {
            for band in rest {
                s.spawn(move || convert_band(band, bgra, stride, planes));
            }
            convert_band(first, bgra, stride, planes);
        });
        Ok(())
    }
}

fn convert_band(band: &mut Band, bgra: &[u8], stride: u32, planes: Planes) {
    let y0 = band.y0 as usize;
    let src = [
        // In bounds: `convert` checked the buffer covers every row.
        bgra[y0 * stride as usize..].as_ptr(),
        std::ptr::null(),
        std::ptr::null(),
        std::ptr::null(),
    ];
    let src_stride = [stride as i32, 0, 0, 0];
    let mut dst = planes.data;
    for (p, ptr) in dst.iter_mut().enumerate() {
        if ptr.is_null() {
            continue;
        }
        // Planes after luma are 4:2:0 chroma: half the rows.
        let row = if p == 0 { y0 } else { y0 / 2 };
        // SAFETY: the offset stays inside the plane: rows y0..y0+rows of a
        // frame `height` rows high, at the frame's own linesize.
        *ptr = unsafe { ptr.offset(row as isize * planes.linesize[p] as isize) };
    }
    // SAFETY: the context was made for `width` x `band.rows` BGRA → format;
    // source and destination pointers cover exactly that many rows, and no
    // other band touches them.
    unsafe {
        ff::ffi::sws_scale(
            band.ctx,
            src.as_ptr(),
            src_stride.as_ptr(),
            0,
            band.rows as i32,
            dst.as_ptr(),
            planes.linesize.as_ptr(),
        );
    }
}

fn new_context(width: u32, rows: u32, format: Pixel) -> Result<*mut ff::ffi::SwsContext> {
    // SAFETY: plain constructor calls; the result is checked for null and
    // owned by the returned `Band`.
    unsafe {
        let ctx = ff::ffi::sws_getContext(
            width as i32,
            rows as i32,
            Pixel::BGRA.into(),
            width as i32,
            rows as i32,
            format.into(),
            // ACCURATE_RND: x86's approximate SIMD vertical filter rounds a
            // context's interior rows differently from its last row (C), so
            // without it the last chroma row of each band came out up to one
            // level off a single context's (aarch64 is exact either way).
            (ff::software::scaling::Flags::AREA | ff::software::scaling::Flags::ACCURATE_RND).bits()
                as _,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null(),
        );
        if ctx.is_null() {
            bail!("sws_getContext failed for {width}x{rows} BGRA -> {format:?}");
        }
        // BT.709 both ways; source full range (desktop RGB), destination
        // limited (video), as the stream's VUI announces.
        let coeffs = ff::ffi::sws_getCoefficients(ff::ffi::SWS_CS_ITU709);
        ff::ffi::sws_setColorspaceDetails(ctx, coeffs, 1, coeffs, 0, 0, 1 << 16, 1 << 16);
        Ok(ctx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(w: u32, h: u32) -> (Vec<u8>, u32) {
        // Stride with padding, colour edges on odd rows and columns.
        let stride = w * 4 + 64;
        let mut v = vec![0u8; (stride * h) as usize];
        for y in 0..h as usize {
            for x in 0..w as usize {
                let o = y * stride as usize + x * 4;
                let t = (x * 7 + y * 13 + (x ^ y) % 5) as u8;
                v[o] = t;
                v[o + 1] = t.wrapping_mul(3) ^ (y as u8);
                v[o + 2] = 255 - t;
                v[o + 3] = 255;
            }
        }
        (v, stride)
    }

    fn planes(f: &ff::frame::Video) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        for p in 0..f.planes() {
            let (w, h) = (f.plane_width(p) as usize, f.plane_height(p) as usize);
            let bytes = if f.format() == Pixel::NV12 && p == 1 {
                w * 2
            } else {
                w
            };
            let stride = f.stride(p);
            out.push(
                (0..h)
                    .flat_map(|y| f.data(p)[y * stride..y * stride + bytes].to_vec())
                    .collect(),
            );
        }
        out
    }

    #[test]
    fn bands_match_one_context_exactly() {
        ff::init().unwrap();
        for (w, h) in [(4096, 2304), (2556, 1178), (1280, 800), (640, 362)] {
            let (src, stride) = frame(w, h);
            for format in [Pixel::YUV420P, Pixel::NV12] {
                let mut one = Converter::new(w, h, format, 1).unwrap();
                let mut a = ff::frame::Video::new(format, w, h);
                one.convert(&src, stride, &mut a).unwrap();
                for n in [2, 3, 8] {
                    let mut many = Converter::new(w, h, format, n).unwrap();
                    assert!(many.bands() > 1);
                    let mut b = ff::frame::Video::new(format, w, h);
                    many.convert(&src, stride, &mut b).unwrap();
                    assert!(
                        planes(&a) == planes(&b),
                        "{w}x{h} {format:?} {n} bands differ"
                    );
                }
            }
        }
    }

    #[test]
    fn band_layout() {
        ff::init().unwrap();
        let c = Converter::new(4096, 2304, Pixel::YUV420P, 8).unwrap();
        let rows: Vec<u32> = c.bands.iter().map(|b| b.rows).collect();
        assert_eq!(rows, vec![288; 8]);
        let c = Converter::new(2556, 1178, Pixel::YUV420P, 8).unwrap();
        assert_eq!(c.bands.iter().map(|b| b.rows).sum::<u32>(), 1178);
        assert!(c.bands.iter().all(|b| b.y0 % 16 == 0));
        assert_eq!(band_count(800, 8), 6);
        assert_eq!(band_count(2304, 4), 4);
        assert_eq!(band_count(100, 8), 1);
    }

    #[test]
    fn rejects_a_short_buffer() {
        ff::init().unwrap();
        let mut c = Converter::new(64, 64, Pixel::YUV420P, 1).unwrap();
        let mut f = ff::frame::Video::new(Pixel::YUV420P, 64, 64);
        assert!(c.convert(&[0; 100], 256, &mut f).is_err());
    }
}
