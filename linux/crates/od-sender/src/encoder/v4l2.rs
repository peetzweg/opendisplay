//! Is there a V4L2 mem2mem H.264 encoder at all? Only some ARM SoCs have
//! one, so on most machines `h264_v4l2m2m` cannot work, and its open error
//! (`Invalid argument`) reads like a broken device (#409). This asks the
//! `/dev/video*` nodes the same questions FFmpeg's probe does, without
//! FFmpeg: a mem2mem node whose coded (CAPTURE) queue offers H.264.

use std::ffi::c_ulong;
use std::fs::File;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

const CAP_VIDEO_CAPTURE: u32 = 0x0000_0001;
const CAP_VIDEO_OUTPUT: u32 = 0x0000_0002;
const CAP_VIDEO_CAPTURE_MPLANE: u32 = 0x0000_1000;
const CAP_VIDEO_OUTPUT_MPLANE: u32 = 0x0000_2000;
const CAP_VIDEO_M2M_MPLANE: u32 = 0x0000_4000;
const CAP_VIDEO_M2M: u32 = 0x0000_8000;
const CAP_STREAMING: u32 = 0x0400_0000;
const CAP_DEVICE_CAPS: u32 = 0x8000_0000;

const BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const BUF_TYPE_VIDEO_CAPTURE_MPLANE: u32 = 9;

const PIX_FMT_H264: u32 = u32::from_le_bytes(*b"H264");

/// `_IOR('V', 0, struct v4l2_capability)` and `_IOWR('V', 2, struct
/// v4l2_fmtdesc)` in the generic ioctl encoding (x86, arm, riscv).
const VIDIOC_QUERYCAP: c_ulong = 0x8068_5600;
const VIDIOC_ENUM_FMT: c_ulong = 0xc040_5602;

#[repr(C)]
#[derive(Default)]
struct Capability {
    driver: [u8; 16],
    card: [u8; 32],
    bus_info: [u8; 32],
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [u32; 3],
}

#[repr(C)]
#[derive(Default)]
struct FmtDesc {
    index: u32,
    kind: u32,
    flags: u32,
    description: [u8; 32],
    pixelformat: u32,
    mbus_code: u32,
    reserved: [u32; 3],
}

unsafe extern "C" {
    fn ioctl(fd: i32, request: c_ulong, ...) -> i32;
}

#[derive(Debug, PartialEq, Eq)]
pub enum Presence {
    /// This node has an H.264 encoder.
    Found(PathBuf),
    /// None found, but some node could not be asked (permissions); let
    /// FFmpeg try and report what it finds.
    Unknown,
    /// No node is an H.264 encoder.
    Absent,
}

/// Scan `/dev/video*`.
pub fn h264_encoder() -> Presence {
    let Ok(dir) = std::fs::read_dir("/dev") else {
        return Presence::Unknown;
    };
    let mut nodes: Vec<PathBuf> = dir
        .flatten()
        .map(|e| e.path())
        .filter(|p| is_video_node(p))
        .collect();
    nodes.sort();
    let mut unknown = false;
    for node in nodes {
        match probe(&node) {
            Some(true) => return Presence::Found(node),
            Some(false) => {}
            None => unknown = true,
        }
    }
    if unknown {
        Presence::Unknown
    } else {
        Presence::Absent
    }
}

fn is_video_node(p: &Path) -> bool {
    p.file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.strip_prefix("video"))
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// `Some(is an H.264 encoder)`, or `None` when the node cannot be opened.
fn probe(node: &Path) -> Option<bool> {
    let f = File::open(node).ok()?;
    let fd = f.as_raw_fd();
    let mut cap = Capability::default();
    // SAFETY: QUERYCAP fills one v4l2_capability, which `cap` is.
    if unsafe { ioctl(fd, VIDIOC_QUERYCAP, &mut cap as *mut Capability) } != 0 {
        return Some(false);
    }
    let Some(kind) = coded_queue(cap.capabilities, cap.device_caps) else {
        return Some(false);
    };
    let formats = (0..64).map_while(|index| {
        let mut d = FmtDesc {
            index,
            kind,
            ..Default::default()
        };
        // SAFETY: ENUM_FMT reads index/type from and fills one v4l2_fmtdesc.
        let r = unsafe { ioctl(fd, VIDIOC_ENUM_FMT, &mut d as *mut FmtDesc) };
        (r == 0).then_some(d.pixelformat)
    });
    Some(offers_h264(formats))
}

/// The buffer type an encoder's coded output would use on a node with
/// these capabilities, or `None` when it is not a mem2mem node. Mirrors
/// FFmpeg's `v4l2_m2m` probe, multi-planar first.
fn coded_queue(capabilities: u32, device_caps: u32) -> Option<u32> {
    let caps = if capabilities & CAP_DEVICE_CAPS != 0 {
        device_caps
    } else {
        capabilities
    };
    let both = |a: u32, b: u32| caps & a != 0 && caps & b != 0 && caps & CAP_STREAMING != 0;
    if caps & CAP_VIDEO_M2M_MPLANE != 0 || both(CAP_VIDEO_CAPTURE_MPLANE, CAP_VIDEO_OUTPUT_MPLANE) {
        Some(BUF_TYPE_VIDEO_CAPTURE_MPLANE)
    } else if caps & CAP_VIDEO_M2M != 0 || both(CAP_VIDEO_CAPTURE, CAP_VIDEO_OUTPUT) {
        Some(BUF_TYPE_VIDEO_CAPTURE)
    } else {
        None
    }
}

fn offers_h264(capture_formats: impl IntoIterator<Item = u32>) -> bool {
    capture_formats.into_iter().any(|f| f == PIX_FMT_H264)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NV12: u32 = u32::from_le_bytes(*b"NV12");

    #[test]
    fn struct_sizes_match_the_ioctls() {
        assert_eq!(std::mem::size_of::<Capability>(), 104);
        assert_eq!(std::mem::size_of::<FmtDesc>(), 64);
        assert_eq!(PIX_FMT_H264, 0x3436_3248);
    }

    #[test]
    fn webcams_are_not_mem2mem() {
        // uvcvideo: capture + streaming, with the device_caps flag.
        let caps = CAP_DEVICE_CAPS | CAP_VIDEO_CAPTURE | CAP_STREAMING;
        assert_eq!(coded_queue(caps, CAP_VIDEO_CAPTURE | CAP_STREAMING), None);
        // Metadata node of the same camera: no video caps on this node.
        assert_eq!(coded_queue(caps, 0x0080_0000 | CAP_STREAMING), None);
    }

    #[test]
    fn mem2mem_nodes_pick_their_plane_layout() {
        let m = CAP_VIDEO_M2M_MPLANE | CAP_STREAMING;
        assert_eq!(
            coded_queue(CAP_DEVICE_CAPS | m, m),
            Some(BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        );
        let s = CAP_VIDEO_M2M | CAP_STREAMING;
        assert_eq!(coded_queue(s, 0), Some(BUF_TYPE_VIDEO_CAPTURE));
        let split = CAP_VIDEO_CAPTURE | CAP_VIDEO_OUTPUT | CAP_STREAMING;
        assert_eq!(coded_queue(split, 0), Some(BUF_TYPE_VIDEO_CAPTURE));
        // Without streaming a capture+output pair is not usable.
        assert_eq!(coded_queue(CAP_VIDEO_CAPTURE | CAP_VIDEO_OUTPUT, 0), None);
    }

    #[test]
    fn only_h264_on_the_coded_queue_counts() {
        assert!(offers_h264([NV12, PIX_FMT_H264]));
        // A decoder's CAPTURE queue carries raw pictures.
        assert!(!offers_h264([NV12]));
        assert!(!offers_h264([]));
    }

    #[test]
    fn video_nodes_by_name() {
        assert!(is_video_node(Path::new("/dev/video0")));
        assert!(is_video_node(Path::new("/dev/video12")));
        assert!(!is_video_node(Path::new("/dev/video")));
        assert!(!is_video_node(Path::new("/dev/video-dec0")));
        assert!(!is_video_node(Path::new("/dev/vbi0")));
    }
}
