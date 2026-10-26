//! FFI/COM layer for decoding: a D3D11 device and the Microsoft H.264 decoder MFT with DXVA
//! output that stays on the GPU (zero-copy). All decode-related `unsafe` lives in this file.

use std::ffi::c_void;
use std::mem::ManuallyDrop;
use windows::Win32::Foundation::{E_FAIL, HMODULE};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0,
    D3D_FEATURE_LEVEL_11_1,
};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter, IDXGIAdapter1, IDXGIFactory1,
};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
};
use windows::core::{BOOL, Error, GUID, IUnknown_Vtbl, Interface, Result};

/// CLSID_CMSH264DecoderMFT (msmpeg2vdec.dll); not exported by the windows crate.
const CLSID_MSH264_DECODER: GUID = GUID::from_u128(0x62ce7e72_4c71_4d20_b15d_452831a87d9d);

pub struct Gpu {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    manager: IMFDXGIDeviceManager,
}

impl Gpu {
    /// Initializes COM (MTA) and Media Foundation on the calling thread, which then owns decode/present.
    /// Uses the adapter driving `monitor` (a GDI device name), so presenting needs no cross-GPU copy;
    /// the default adapter if None or not found.
    pub fn new(monitor: Option<&[u16; 32]>) -> Result<Self> {
        // SAFETY: standard init calls; out-params are local Options filled by the callee.
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
            MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET)?;
            let adapter = monitor.and_then(adapter_for);
            match &adapter {
                Some(a) => {
                    let d = a.GetDesc1()?;
                    let n = d
                        .Description
                        .iter()
                        .position(|&c| c == 0)
                        .unwrap_or(d.Description.len());
                    log::info!("GPU: {}", String::from_utf16_lossy(&d.Description[..n]));
                }
                None => log::info!("GPU: default adapter"),
            }
            let adapter = adapter.map(|a| a.cast::<IDXGIAdapter>()).transpose()?;
            // An explicit adapter requires the UNKNOWN driver type.
            let driver = if adapter.is_some() {
                D3D_DRIVER_TYPE_UNKNOWN
            } else {
                D3D_DRIVER_TYPE_HARDWARE
            };
            let (mut device, mut context) = (None, None);
            D3D11CreateDevice(
                adapter.as_ref(),
                driver,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&[D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
            let (device, context) = (device.unwrap(), context.unwrap());
            // The MFT touches the device from its own threads.
            let _ = context
                .cast::<ID3D11Multithread>()?
                .SetMultithreadProtected(true);
            let (mut token, mut manager) = (0, None);
            MFCreateDXGIDeviceManager(&mut token, &mut manager)?;
            let manager = manager.unwrap();
            manager.ResetDevice(&device, token)?;
            Ok(Self {
                device,
                context,
                manager,
            })
        }
    }

    /// Blocks until the GPU has finished all submitted work. Measurement only; never in the live path.
    pub fn finish(&self) -> Result<()> {
        // SAFETY: event query on our own device; GetData writes a BOOL into `done` once ready.
        unsafe {
            let mut q = None;
            self.device.CreateQuery(
                &D3D11_QUERY_DESC {
                    Query: D3D11_QUERY_EVENT,
                    MiscFlags: 0,
                },
                Some(&mut q),
            )?;
            let q = q.unwrap();
            self.context.End(&q);
            let mut done = BOOL(0);
            while done.0 == 0 {
                self.context.GetData(
                    &q,
                    Some(&mut done as *mut _ as *mut c_void),
                    size_of::<BOOL>() as u32,
                    0,
                )?;
            }
            Ok(())
        }
    }
}

/// The adapter with an output named `monitor`, if any.
fn adapter_for(monitor: &[u16; 32]) -> Option<IDXGIAdapter1> {
    // SAFETY: DXGI enumeration; each call returns an owned COM object or an error that ends the loop.
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        (0..)
            .map_while(|i| factory.EnumAdapters1(i).ok())
            .find(|a| {
                (0..)
                    .map_while(|j| a.EnumOutputs(j).ok())
                    .any(|o| o.GetDesc().is_ok_and(|d| d.DeviceName == *monitor))
            })
    }
}

/// A decoded NV12 picture, still on the GPU (a slice of the decoder's texture array).
/// Holding it keeps the decoder from reusing the surface.
pub struct Frame {
    pub texture: ID3D11Texture2D,
    pub index: u32,
    /// Visible size from the SPS cropping window.
    pub width: u32,
    pub height: u32,
    _sample: IMFSample,
}

impl Frame {
    /// Copies the visible picture to the CPU as NV12 (Y rows, then interleaved UV rows).
    /// Verification only: it stalls the GPU.
    pub fn read_nv12(&self, gpu: &Gpu) -> Result<Vec<u8>> {
        // SAFETY: staging copy of our own texture; the mapped pointer is read within the
        // RowPitch x texture-height bounds D3D guarantees for an NV12 staging resource.
        unsafe {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            self.texture.GetDesc(&mut desc);
            desc.ArraySize = 1;
            desc.MipLevels = 1;
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
            desc.MiscFlags = 0;
            let mut staging = None;
            gpu.device
                .CreateTexture2D(&desc, None, Some(&mut staging))?;
            let staging = staging.unwrap();
            gpu.context.CopySubresourceRegion(
                &staging,
                0,
                0,
                0,
                0,
                &self.texture,
                self.index,
                None,
            );
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            gpu.context
                .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
            let (w, h, pitch) = (
                self.width as usize,
                self.height as usize,
                m.RowPitch as usize,
            );
            let y = m.pData as *const u8;
            let uv = y.add(pitch * desc.Height as usize);
            let mut out = Vec::with_capacity(w * h * 3 / 2);
            for r in 0..h {
                out.extend_from_slice(std::slice::from_raw_parts(y.add(r * pitch), w));
            }
            for r in 0..h / 2 {
                out.extend_from_slice(std::slice::from_raw_parts(uv.add(r * pitch), w));
            }
            gpu.context.Unmap(&staging, 0);
            Ok(out)
        }
    }
}

/// Microsoft H.264 decoder MFT in low-latency mode with a DXGI device manager.
pub struct Decoder {
    mft: IMFTransform,
    /// Reused input samples; a sample is reused only once the MFT has released it.
    inputs: Vec<IMFSample>,
    size: (u32, u32),
    time: i64,
}

impl Decoder {
    pub fn new(gpu: &Gpu) -> Result<Self> {
        // SAFETY: COM calls on a freshly created MFT; the manager pointer outlives the MFT's use
        // because Gpu outlives every Decoder (the decode thread owns both).
        unsafe {
            let mft: IMFTransform =
                CoCreateInstance(&CLSID_MSH264_DECODER, None, CLSCTX_INPROC_SERVER)?;
            let attrs = mft.GetAttributes()?;
            if attrs.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) == 0 {
                return Err(Error::new(E_FAIL, "H.264 decoder MFT is not D3D11-aware"));
            }
            attrs.SetUINT32(&CODECAPI_AVLowLatencyMode, 1)?;
            mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, gpu.manager.as_raw() as usize)?;

            let input = MFCreateMediaType()?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
            mft.SetInputType(0, &input, 0)?;
            // Output surfaces must be sampleable by the presenter's shader.
            let out_attrs = mft.GetOutputStreamAttributes(0)?;
            out_attrs.SetUINT32(
                &MF_SA_D3D11_BINDFLAGS,
                (D3D11_BIND_DECODER.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            )?;

            let mut d = Self {
                mft,
                inputs: Vec::new(),
                size: (0, 0),
                time: 0,
            };
            d.set_output_type()?;
            if d.mft.GetOutputStreamInfo(0)?.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32
                == 0
            {
                return Err(Error::new(
                    E_FAIL,
                    "decoder does not output D3D11 surfaces (no hardware decode?)",
                ));
            }
            d.mft
                .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            d.mft
                .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            Ok(d)
        }
    }

    /// Decodes one access unit (Annex B, 4-byte start codes); returns the newest picture produced.
    pub fn decode(&mut self, au: &[u8]) -> Result<Option<Frame>> {
        let sample = self.input_sample(au)?;
        // SAFETY: COM call with a valid sample.
        match unsafe { self.mft.ProcessInput(0, &sample, 0) } {
            Err(e) if e.code() == MF_E_NOTACCEPTING => {
                let earlier = self.pull()?;
                unsafe { self.mft.ProcessInput(0, &sample, 0)? };
                Ok(self.pull()?.or(earlier))
            }
            r => {
                r?;
                self.pull()
            }
        }
    }

    /// Number of input samples allocated so far (stays small if the MFT releases inputs promptly).
    pub fn input_pool_size(&self) -> usize {
        self.inputs.len()
    }

    fn input_sample(&mut self, au: &[u8]) -> Result<IMFSample> {
        // SAFETY: plain MF calls; the copy writes au.len() bytes into a locked buffer whose
        // max length was checked to be at least that.
        unsafe {
            let sample = match self.inputs.iter().find(|s| is_free(s)) {
                Some(s) => s.clone(),
                None => {
                    let s = MFCreateSample()?;
                    self.inputs.push(s.clone());
                    s
                }
            };
            let buf = match sample.GetBufferByIndex(0) {
                Ok(b) if b.GetMaxLength()? as usize >= au.len() => b,
                _ => {
                    sample.RemoveAllBuffers()?;
                    let b = MFCreateMemoryBuffer(au.len().max(1 << 20).next_power_of_two() as u32)?;
                    sample.AddBuffer(&b)?;
                    b
                }
            };
            let mut p = std::ptr::null_mut();
            buf.Lock(&mut p, None, None)?;
            std::ptr::copy_nonoverlapping(au.as_ptr(), p, au.len());
            buf.Unlock()?;
            buf.SetCurrentLength(au.len() as u32)?;
            self.time += 1;
            sample.SetSampleTime(self.time)?;
            Ok(sample)
        }
    }

    fn pull(&mut self) -> Result<Option<Frame>> {
        let mut newest = None;
        loop {
            let mut out = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: ManuallyDrop::new(None),
                dwStatus: 0,
                pEvents: ManuallyDrop::new(None),
            }];
            let mut status = 0;
            // SAFETY: the MFT provides samples; we take ownership of whatever it wrote into `out`.
            let r = unsafe { self.mft.ProcessOutput(0, &mut out, &mut status) };
            let sample = unsafe { ManuallyDrop::take(&mut out[0].pSample) };
            drop(unsafe { ManuallyDrop::take(&mut out[0].pEvents) });
            match r {
                Ok(()) => {
                    if let Some(s) = sample {
                        newest = Some(self.frame(s)?);
                    }
                }
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(newest),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => self.set_output_type()?,
                Err(e) => return Err(e),
            }
        }
    }

    fn frame(&self, sample: IMFSample) -> Result<Frame> {
        // SAFETY: GetResource writes an AddRef'd ID3D11Texture2D pointer into the Option, whose layout is a nullable pointer.
        unsafe {
            let dxgi: IMFDXGIBuffer = sample.GetBufferByIndex(0)?.cast()?;
            let mut texture: Option<ID3D11Texture2D> = None;
            dxgi.GetResource(
                &ID3D11Texture2D::IID,
                &mut texture as *mut _ as *mut *mut c_void,
            )?;
            Ok(Frame {
                texture: texture
                    .ok_or_else(|| Error::new(E_FAIL, "no texture in decoder output"))?,
                index: dxgi.GetSubresourceIndex()?,
                width: self.size.0,
                height: self.size.1,
                _sample: sample,
            })
        }
    }

    fn set_output_type(&mut self) -> Result<()> {
        // SAFETY: enumerating and setting media types on our MFT.
        unsafe {
            let mut i = 0;
            loop {
                let t = self.mft.GetOutputAvailableType(0, i)?;
                if t.GetGUID(&MF_MT_SUBTYPE)? == MFVideoFormat_NV12 {
                    self.mft.SetOutputType(0, &t, 0)?;
                    self.size = visible_size(&t)?;
                    return Ok(());
                }
                i += 1;
            }
        }
    }
}

/// Visible size: the minimum display aperture (SPS cropping) if set, else the coded frame size.
/// shortcut: crop offsets are assumed 0 (true for every encoder that crops only right/bottom); handle if a sender crops top/left.
fn visible_size(t: &IMFMediaType) -> Result<(u32, u32)> {
    let mut area = MFVideoArea::default();
    // SAFETY: MFVideoArea is plain data and GetBlob writes at most the slice length.
    unsafe {
        let bytes = std::slice::from_raw_parts_mut(
            &mut area as *mut _ as *mut u8,
            size_of::<MFVideoArea>(),
        );
        if t.GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, bytes, None)
            .is_ok()
            && area.Area.cx > 0
            && area.Area.cy > 0
        {
            return Ok((area.Area.cx as u32, area.Area.cy as u32));
        }
        let fs = t.GetUINT64(&MF_MT_FRAME_SIZE)?;
        Ok(((fs >> 32) as u32, fs as u32))
    }
}

/// Reference count of a COM object. Only used as "we hold every reference": once that is true
/// nobody else holds a pointer that could add one, so the answer cannot go stale.
fn refs<T: Interface>(obj: &T) -> u32 {
    // SAFETY: AddRef/Release pair on a live interface pointer; every COM vtable starts with IUnknown.
    unsafe {
        let raw = obj.as_raw();
        let vt = &**(raw as *const *const IUnknown_Vtbl);
        (vt.AddRef)(raw);
        (vt.Release)(raw)
    }
}

/// True when the MFT holds neither the sample nor its buffer (the sample owns one buffer ref, our temporary the other).
fn is_free(s: &IMFSample) -> bool {
    refs(s) == 1 && unsafe { s.GetBufferByIndex(0) }.map_or(true, |b| refs(&b) == 2)
}
