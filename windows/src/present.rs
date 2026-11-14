//! DXGI flip-model presentation of decoded NV12 frames, plus the F2 timing overlay.
//! Part of the small FFI layer: all presentation `unsafe` lives here.
//!
//! The pixel shader samples the decoder's own texture (zero-copy) and converts NV12 to RGB.
//! HLSL is compiled once at startup with `D3DCompile` (d3dcompiler_47.dll ships with Windows 10),
//! which needs no build step.

use crate::cursor::Sprite;
use crate::mf::{Frame, Gpu};
use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::net::IpAddr;
use windows::Win32::Foundation::{
    CloseHandle, E_FAIL, E_INVALIDARG, HANDLE, HWND, RECT, WAIT_OBJECT_0,
};
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Direct3D::Fxc::{D3DCOMPILE_OPTIMIZATION_LEVEL3, D3DCompile};
use windows::Win32::Graphics::Direct3D::{
    D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D11_SRV_DIMENSION_TEXTURE2DARRAY, ID3DBlob,
};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::Security::Cryptography::{CRYPT_STRING_BASE64, CryptStringToBinaryA};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::System::Threading::WaitForSingleObjectEx;
use windows::Win32::UI::WindowsAndMessaging::GetClientRect;
use windows::core::{BOOL, Error, Interface, PCSTR, Result, s, w};

/// BT.709 limited range. The sender's VUI is not checked: the Mac's hardware encoder tags
/// HD streams BT.709, and that is also what decoders assume for untagged HD.
/// shortcut: fixed matrix; read MF_MT_YUV_MATRIX / MF_MT_VIDEO_NOMINAL_RANGE if a sender sends BT.601 or full range.
const SHADERS: &str = r#"
Texture2DArray<float>  Luma   : register(t0);
Texture2DArray<float2> Chroma : register(t1);
SamplerState Linear : register(s0);
cbuffer Crop : register(b0) { float2 visible; float2 pad; }; // visible size / texture size

void vs(uint id : SV_VertexID, out float4 pos : SV_Position, out float2 uv : TEXCOORD) {
    uv = float2((id << 1) & 2, id & 2); // one triangle covering the viewport
    pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 ps(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target {
    float3 t = float3(uv * visible, 0);
    float y = (Luma.SampleLevel(Linear, t, 0) - 16.0 / 255) * (255.0 / 219);
    float2 c = (Chroma.SampleLevel(Linear, t, 0) - 128.0 / 255) * (255.0 / 224);
    float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
    return float4(saturate(rgb), 1);
}

// The cursor sprite, premultiplied BGRA; the viewport is the sprite's rect.
Texture2D<float4> Sprite : register(t2);
float4 ps_cursor(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target {
    return Sprite.SampleLevel(Linear, uv, 0);
}
"#;

/// The logo on the idle screen (own design, see assets/make_logo.py).
const LOGO_PNG: &[u8] = include_bytes!("../assets/logo.png");
/// Idle screen background.
const SPLASH_BG: [f32; 4] = [0.043, 0.071, 0.125, 1.0];

/// Largest accepted cursor sprite side: a 24 kB PNG can still declare huge dimensions.
const MAX_SPRITE: u32 = 1024;

/// More cached views than the decoder pool ever has; past this the cache holds dead textures.
const MAX_VIEWS: usize = 32;

/// Largest rect with the video's aspect ratio, centered in the client area: (x, y, w, h).
pub fn fit(video: (u32, u32), client: (u32, u32)) -> (u32, u32, u32, u32) {
    if video.0 == 0 || video.1 == 0 {
        return (0, 0, client.0, client.1);
    }
    let s = (client.0 as f64 / video.0 as f64).min(client.1 as f64 / video.1 as f64);
    let (w, h) = (
        ((video.0 as f64 * s).round() as u32).min(client.0),
        ((video.1 as f64 * s).round() as u32).min(client.1),
    );
    ((client.0 - w) / 2, (client.1 - h) / 2, w, h)
}

/// Luma and chroma views on one slice of a decoder texture array.
struct View {
    key: (usize, u32),
    luma: ID3D11ShaderResourceView,
    chroma: ID3D11ShaderResourceView,
    visible: [f32; 4],
}

pub struct Presenter {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    swap: IDXGISwapChain2,
    flags: DXGI_SWAP_CHAIN_FLAG,
    tearing: bool,
    /// Signaled when the swap chain can take another frame (maximum frame latency 1).
    waitable: HANDLE,
    /// `wait` consumed the waitable's signal; the next `present` may go ahead.
    ready: bool,
    hwnd: HWND,
    rtv: Option<ID3D11RenderTargetView>,
    vs: ID3D11VertexShader,
    ps: ID3D11PixelShader,
    cursor_ps: ID3D11PixelShader,
    /// Premultiplied alpha, for the cursor.
    blend: ID3D11BlendState,
    wic: IWICImagingFactory,
    /// Current cursor sprite and its (nw, nh, ax, ay) (§6.2).
    sprite: Option<(ID3D11ShaderResourceView, [f32; 4])>,
    sampler: ID3D11SamplerState,
    crop: ID3D11Buffer,
    crop_now: [f32; 4],
    views: Vec<View>,
    client: (u32, u32),
    /// Where the video was last drawn, in client pixels (x, y, w, h). Input is normalized against it.
    pub video_rect: (u32, u32, u32, u32),
    d2d: ID2D1DeviceContext,
    target: Option<ID2D1Bitmap1>,
    font: IDWriteTextFormat,
    text: ID2D1SolidColorBrush,
    shade: ID2D1SolidColorBrush,
    splash: Splash,
}

/// The idle screen, drawn whenever no video frame is on screen: logo, connection status and how
/// to start streaming. Drawn only while idle, so its allocations never touch the video path.
struct Splash {
    dwrite: IDWriteFactory,
    logo: ID2D1Bitmap1,
    title: IDWriteTextFormat,
    status_font: IDWriteTextFormat,
    hints_font: IDWriteTextFormat,
    small: IDWriteTextFormat,
    muted: ID2D1SolidColorBrush,
    card: ID2D1SolidColorBrush,
    dot: ID2D1SolidColorBrush,
    hints: Vec<u16>,
    status: Vec<u16>,
}

fn text_format(
    dwrite: &IDWriteFactory,
    size: f32,
    weight: DWRITE_FONT_WEIGHT,
    align: DWRITE_TEXT_ALIGNMENT,
) -> Result<IDWriteTextFormat> {
    // SAFETY: DirectWrite factory call with static strings.
    unsafe {
        let f = dwrite.CreateTextFormat(
            w!("Segoe UI"),
            None,
            weight,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            size,
            w!("en-us"),
        )?;
        f.SetTextAlignment(align)?;
        Ok(f)
    }
}

/// Decodes an image into premultiplied BGRA.
fn decode(wic: &IWICImagingFactory, bytes: &[u8]) -> Result<IWICBitmapSource> {
    // SAFETY: WIC calls on a stream over `bytes`, which outlives the decode (pixels are copied
    // out by the caller before returning).
    unsafe {
        let stream = wic.CreateStream()?;
        stream.InitializeFromMemory(bytes)?;
        let frame = wic
            .CreateDecoderFromStream(&stream, std::ptr::null(), WICDecodeMetadataCacheOnLoad)?
            .GetFrame(0)?;
        WICConvertBitmapSource(&GUID_WICPixelFormat32bppPBGRA, &frame)
    }
}

impl Presenter {
    /// Creates a flip-model swap chain for `hwnd` on the decoder's device. `name` is the
    /// Bonjour name the idle screen tells the user to pick on the Mac.
    pub fn new(gpu: &Gpu, hwnd: HWND, name: &str) -> Result<Self> {
        // SAFETY: COM/DXGI calls with locally owned descriptors; out-params are local Options.
        unsafe {
            let dxgi: IDXGIDevice = gpu.device.cast()?;
            let factory: IDXGIFactory2 = dxgi.GetAdapter()?.GetParent()?;
            let mut allow = BOOL(0);
            let tearing = factory.cast::<IDXGIFactory5>().is_ok_and(|f| {
                f.CheckFeatureSupport(
                    DXGI_FEATURE_PRESENT_ALLOW_TEARING,
                    &mut allow as *mut _ as *mut c_void,
                    size_of::<BOOL>() as u32,
                )
                .is_ok()
            }) && allow.as_bool();
            let mut flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
            if tearing {
                flags |= DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;
            }
            let desc = DXGI_SWAP_CHAIN_DESC1 {
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC {
                    Count: 1,
                    Quality: 0,
                },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                AlphaMode: DXGI_ALPHA_MODE_IGNORE,
                Flags: flags.0 as u32,
                ..Default::default() // 0x0: the window's client size
            };
            let swap: IDXGISwapChain2 = factory
                .CreateSwapChainForHwnd(&gpu.device, hwnd, &desc, None, None)?
                .cast()?;
            factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER)?;
            swap.SetMaximumFrameLatency(1)?;
            let waitable = swap.GetFrameLatencyWaitableObject();

            let (vs_blob, ps_blob) = (
                compile(s!("vs"), s!("vs_5_0"))?,
                compile(s!("ps"), s!("ps_5_0"))?,
            );
            let cursor_blob = compile(s!("ps_cursor"), s!("ps_5_0"))?;
            let (mut vs, mut ps, mut cursor_ps, mut sampler, mut crop, mut blend) =
                (None, None, None, None, None, None);
            gpu.device
                .CreateVertexShader(bytes(&vs_blob), None, Some(&mut vs))?;
            gpu.device
                .CreatePixelShader(bytes(&ps_blob), None, Some(&mut ps))?;
            gpu.device
                .CreatePixelShader(bytes(&cursor_blob), None, Some(&mut cursor_ps))?;
            let mut bd = D3D11_BLEND_DESC::default();
            bd.RenderTarget[0] = D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: true.into(),
                SrcBlend: D3D11_BLEND_ONE,
                DestBlend: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE,
                DestBlendAlpha: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8,
            };
            gpu.device.CreateBlendState(&bd, Some(&mut blend))?;
            let sd = D3D11_SAMPLER_DESC {
                Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                ComparisonFunc: D3D11_COMPARISON_NEVER,
                MaxLOD: f32::MAX,
                ..Default::default()
            };
            gpu.device.CreateSamplerState(&sd, Some(&mut sampler))?;
            let bd = D3D11_BUFFER_DESC {
                ByteWidth: 16,
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                ..Default::default()
            };
            gpu.device.CreateBuffer(&bd, None, Some(&mut crop))?;

            let factory2d: ID2D1Factory1 =
                D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, None)?;
            let d2d = factory2d
                .CreateDevice(&dxgi)?
                .CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE)?;
            let dwrite: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let font = dwrite.CreateTextFormat(
                w!("Consolas"),
                None,
                DWRITE_FONT_WEIGHT_NORMAL,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                18.0,
                w!("en-us"),
            )?;
            let text = d2d.CreateSolidColorBrush(
                &D2D1_COLOR_F {
                    r: 1.0,
                    g: 1.0,
                    b: 1.0,
                    a: 1.0,
                },
                None,
            )?;
            let shade = d2d.CreateSolidColorBrush(
                &D2D1_COLOR_F {
                    r: 0.0,
                    g: 0.0,
                    b: 0.0,
                    a: 0.7,
                },
                None,
            )?;
            let wic: IWICImagingFactory =
                CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
            let hints_font = text_format(
                &dwrite,
                24.0,
                DWRITE_FONT_WEIGHT_NORMAL,
                DWRITE_TEXT_ALIGNMENT_LEADING,
            )?;
            hints_font.SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, 46.0, 34.0)?;
            let hints = format!(
                "1     Open the OpenDisplay sender.\n2     Choose \u{201c}{name}\u{201d} as the display.\n3     Keep this screen on. Both computers need the same network."
            );
            let splash = Splash {
                logo: d2d.CreateBitmapFromWicBitmap(&decode(&wic, LOGO_PNG)?, None)?,
                title: text_format(
                    &dwrite,
                    46.0,
                    DWRITE_FONT_WEIGHT_SEMI_BOLD,
                    DWRITE_TEXT_ALIGNMENT_CENTER,
                )?,
                status_font: text_format(
                    &dwrite,
                    24.0,
                    DWRITE_FONT_WEIGHT_NORMAL,
                    DWRITE_TEXT_ALIGNMENT_CENTER,
                )?,
                hints_font,
                small: text_format(
                    &dwrite,
                    18.0,
                    DWRITE_FONT_WEIGHT_NORMAL,
                    DWRITE_TEXT_ALIGNMENT_CENTER,
                )?,
                muted: d2d.CreateSolidColorBrush(
                    &D2D1_COLOR_F {
                        r: 0.62,
                        g: 0.68,
                        b: 0.78,
                        a: 1.0,
                    },
                    None,
                )?,
                card: d2d.CreateSolidColorBrush(
                    &D2D1_COLOR_F {
                        r: 1.0,
                        g: 1.0,
                        b: 1.0,
                        a: 0.06,
                    },
                    None,
                )?,
                dot: d2d.CreateSolidColorBrush(&D2D1_COLOR_F::default(), None)?,
                hints: hints.encode_utf16().collect(),
                status: Vec::new(),
                dwrite: dwrite.clone(),
            };

            let mut p = Self {
                device: gpu.device.clone(),
                context: gpu.context.clone(),
                swap,
                flags,
                tearing,
                waitable,
                ready: false,
                hwnd,
                rtv: None,
                vs: vs.unwrap(),
                ps: ps.unwrap(),
                cursor_ps: cursor_ps.unwrap(),
                blend: blend.unwrap(),
                wic,
                sprite: None,
                sampler: sampler.unwrap(),
                crop: crop.unwrap(),
                crop_now: [0.0; 4],
                views: Vec::with_capacity(MAX_VIEWS),
                client: (0, 0),
                video_rect: (0, 0, 0, 0),
                d2d,
                target: None,
                font,
                text,
                shade,
                splash,
            };
            p.set_status(None);
            p.bind()?;
            log::info!(
                "swap chain {}x{}, flip discard, tearing {}",
                p.client.0,
                p.client.1,
                if tearing { "on" } else { "unsupported" }
            );
            Ok(p)
        }
    }

    /// Matches the swap chain to the window's client area.
    pub fn resize(&mut self) -> Result<()> {
        self.rtv = None;
        self.target = None;
        // SAFETY: every reference to the back buffers (RTV, D2D target, context binding) is
        // released before ResizeBuffers, as DXGI requires.
        unsafe {
            self.d2d.SetTarget(None);
            self.context.OMSetRenderTargets(None, None);
            self.context.Flush();
            self.swap
                .ResizeBuffers(0, 0, 0, DXGI_FORMAT_UNKNOWN, self.flags)?;
        }
        self.bind()
    }

    /// Forget cached views, e.g. after the decoder (and its surface pool) was replaced.
    pub fn forget(&mut self) {
        self.views.clear();
    }

    /// Blocks up to `ms` until the swap chain can take another frame.
    pub fn wait(&mut self, ms: u32) {
        // SAFETY: waiting on our own waitable handle.
        self.ready |= unsafe { WaitForSingleObjectEx(self.waitable, ms, false) } == WAIT_OBJECT_0;
    }

    /// The idle screen's status line: waiting, or connected to `peer` with no video yet.
    pub fn set_status(&mut self, peer: Option<IpAddr>) {
        let (text, color) = match peer {
            Some(ip) => (
                format!("Connected to {ip}, starting video\u{2026}"),
                D2D1_COLOR_F {
                    r: 0.13,
                    g: 0.77,
                    b: 0.37,
                    a: 1.0,
                },
            ),
            None => (
                "Waiting for a sender to connect".into(),
                D2D1_COLOR_F {
                    r: 0.98,
                    g: 0.75,
                    b: 0.14,
                    a: 1.0,
                },
            ),
        };
        self.splash.status = text.encode_utf16().collect();
        // SAFETY: setting a color on our own brush.
        unsafe { self.splash.dot.SetColor(&color) };
    }

    /// Decodes a `cursorImg` sprite (base64 PNG) into a texture; once per image. On error no
    /// cursor is drawn until the next valid sprite.
    pub fn set_cursor(&mut self, s: &Sprite) -> Result<()> {
        self.sprite = None;
        let g = [s.nw, s.nh, s.ax, s.ay];
        if g.iter().any(|v| !v.is_finite()) {
            return Err(Error::new(
                E_INVALIDARG,
                "cursor sprite geometry is not finite",
            ));
        }
        // SAFETY: base64/WIC/D3D11 calls on buffers this function owns, sized by the preceding
        // queries; out-params are locals.
        unsafe {
            let b64 = s.png.as_bytes();
            let mut n = 0u32;
            CryptStringToBinaryA(b64, CRYPT_STRING_BASE64, None, &mut n, None, None)?;
            let mut png = vec![0u8; n as usize];
            CryptStringToBinaryA(
                b64,
                CRYPT_STRING_BASE64,
                Some(png.as_mut_ptr()),
                &mut n,
                None,
                None,
            )?;
            let src = decode(&self.wic, &png[..n as usize])?;
            let (mut w, mut h) = (0, 0);
            src.GetSize(&mut w, &mut h)?;
            if w == 0 || h == 0 || w > MAX_SPRITE || h > MAX_SPRITE {
                return Err(Error::new(
                    E_INVALIDARG,
                    format!("cursor sprite is {w}x{h}"),
                ));
            }
            let mut px = vec![0u8; (w * h * 4) as usize];
            src.CopyPixels(std::ptr::null(), w * 4, &mut px)?;
            let desc = D3D11_TEXTURE2D_DESC {
                Width: w,
                Height: h,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC {
                    Count: 1,
                    Quality: 0,
                },
                Usage: D3D11_USAGE_IMMUTABLE,
                BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                ..Default::default()
            };
            let data = D3D11_SUBRESOURCE_DATA {
                pSysMem: px.as_ptr() as *const c_void,
                SysMemPitch: w * 4,
                SysMemSlicePitch: 0,
            };
            let (mut tex, mut srv) = (None, None);
            self.device
                .CreateTexture2D(&desc, Some(&data), Some(&mut tex))?;
            self.device
                .CreateShaderResourceView(&tex.unwrap(), None, Some(&mut srv))?;
            self.sprite = Some((srv.unwrap(), g.map(|v| v.clamp(0.0, 1.0) as f32)));
        }
        Ok(())
    }

    /// Draws `frame` letterboxed (the idle screen when None), the cursor at normalized video position
    /// `cursor`, and `overlay` text on top, then presents without waiting for vsync. Returns
    /// false without drawing when the previous frame is still queued: frame latency 1 means we
    /// never queue a second one; retry with the newest.
    pub fn present(
        &mut self,
        frame: Option<&Frame>,
        cursor: Option<(f32, f32)>,
        overlay: Option<&[u16]>,
    ) -> Result<bool> {
        // SAFETY: waiting with a zero timeout on our own waitable handle.
        if !std::mem::take(&mut self.ready)
            && unsafe { WaitForSingleObjectEx(self.waitable, 0, false) } != WAIT_OBJECT_0
        {
            return Ok(false);
        }
        let view = match frame {
            Some(f) => Some(self.view(f)?),
            None => None,
        };
        let rtv = self
            .rtv
            .clone()
            .ok_or_else(|| Error::new(E_FAIL, "no back buffer"))?;
        let ctx = &self.context;
        // SAFETY: D3D11 state and draw calls with views and buffers this struct owns.
        unsafe {
            ctx.ClearRenderTargetView(
                &rtv,
                if frame.is_some() {
                    &[0.0, 0.0, 0.0, 1.0]
                } else {
                    &SPLASH_BG
                },
            );
            if let (Some(i), Some(f)) = (view, frame) {
                let v = &self.views[i];
                if v.visible != self.crop_now {
                    self.crop_now = v.visible;
                    ctx.UpdateSubresource(
                        &self.crop,
                        0,
                        None,
                        v.visible.as_ptr() as *const c_void,
                        0,
                        0,
                    );
                }
                let r = fit((f.width, f.height), self.client);
                self.video_rect = r;
                ctx.OMSetRenderTargets(Some(&[Some(rtv)]), None);
                ctx.RSSetViewports(Some(&[D3D11_VIEWPORT {
                    TopLeftX: r.0 as f32,
                    TopLeftY: r.1 as f32,
                    Width: r.2 as f32,
                    Height: r.3 as f32,
                    MinDepth: 0.0,
                    MaxDepth: 1.0,
                }]));
                ctx.IASetInputLayout(None);
                ctx.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                ctx.VSSetShader(&self.vs, None);
                ctx.PSSetShader(&self.ps, None);
                ctx.PSSetShaderResources(0, Some(&[Some(v.luma.clone()), Some(v.chroma.clone())]));
                ctx.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
                ctx.PSSetConstantBuffers(0, Some(&[Some(self.crop.clone())]));
                ctx.Draw(3, 0);
                // Don't keep the decoder surface bound while the decoder may write to it.
                ctx.PSSetShaderResources(0, Some(&[None, None]));
                if let (Some((x, y)), Some((srv, g))) = (cursor, &self.sprite) {
                    // Size is normalized to the video, the hotspot to the sprite (§7).
                    let (w, h) = (r.2 as f32 * g[0], r.3 as f32 * g[1]);
                    ctx.RSSetViewports(Some(&[D3D11_VIEWPORT {
                        TopLeftX: r.0 as f32 + x * r.2 as f32 - g[2] * w,
                        TopLeftY: r.1 as f32 + y * r.3 as f32 - g[3] * h,
                        Width: w,
                        Height: h,
                        MinDepth: 0.0,
                        MaxDepth: 1.0,
                    }]));
                    ctx.PSSetShader(&self.cursor_ps, None);
                    ctx.PSSetShaderResources(2, Some(&[Some(srv.clone())]));
                    ctx.OMSetBlendState(&self.blend, None, u32::MAX);
                    ctx.Draw(3, 0);
                    ctx.OMSetBlendState(None, None, u32::MAX);
                }
            }
            if frame.is_none() || overlay.is_some() {
                self.d2d.BeginDraw();
            }
            if frame.is_none() {
                self.draw_splash()?;
            }
            if let Some(t) = overlay {
                let lines = t.iter().filter(|&&c| c == '\n' as u16).count() as f32 + 1.0;
                let r = D2D_RECT_F {
                    left: 8.0,
                    top: 8.0,
                    right: 560.0,
                    bottom: 16.0 + 22.0 * lines,
                };
                self.d2d.FillRectangle(&r, &self.shade);
                let r = D2D_RECT_F {
                    left: 16.0,
                    top: 12.0,
                    ..r
                };
                self.d2d.DrawText(
                    t,
                    &self.font,
                    &r,
                    &self.text,
                    D2D1_DRAW_TEXT_OPTIONS_NONE,
                    DWRITE_MEASURING_MODE_NATURAL,
                );
            }
            if frame.is_none() || overlay.is_some() {
                self.d2d.EndDraw(None, None)?;
            }
            let flags = if self.tearing {
                DXGI_PRESENT_ALLOW_TEARING
            } else {
                DXGI_PRESENT(0)
            };
            self.swap.Present(0, flags).ok()?;
        }
        Ok(true)
    }

    /// Lays the idle screen out in a 1080-unit-high space scaled to the client height.
    fn draw_splash(&self) -> Result<()> {
        let (s, d) = (&self.splash, &self.d2d);
        let k = self.client.1.max(1) as f32 / 1080.0;
        let (w, cx) = (self.client.0 as f32 / k, self.client.0 as f32 / k / 2.0);
        let rect = |left, top, right, bottom| D2D_RECT_F {
            left,
            top,
            right,
            bottom,
        };
        let draw = |t: &[u16], f: &IDWriteTextFormat, r: D2D_RECT_F, b: &ID2D1SolidColorBrush| {
            // SAFETY: drawing our own text with our own format and brush.
            unsafe {
                d.DrawText(
                    t,
                    f,
                    &r,
                    b,
                    D2D1_DRAW_TEXT_OPTIONS_NONE,
                    DWRITE_MEASURING_MODE_NATURAL,
                )
            }
        };
        // SAFETY: D2D drawing between BeginDraw/EndDraw (done by the caller) with resources we own.
        unsafe {
            d.SetTransform(&windows_numerics::Matrix3x2 {
                M11: k,
                M22: k,
                ..Default::default()
            });
            d.DrawBitmap(
                &s.logo,
                Some(&rect(cx - 90.0, 200.0, cx + 90.0, 380.0)),
                1.0,
                D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC,
                None,
                None,
            );
            draw(
                &"Open Display receiver".encode_utf16().collect::<Vec<_>>(),
                &s.title,
                rect(0.0, 400.0, w, 465.0),
                &self.text,
            );
            let layout = s
                .dwrite
                .CreateTextLayout(&s.status, &s.status_font, w, 40.0)?;
            let mut m = DWRITE_TEXT_METRICS::default();
            layout.GetMetrics(&mut m)?;
            let dot = D2D1_ELLIPSE {
                point: windows_numerics::Vector2 {
                    X: m.left - 20.0,
                    Y: 480.0 + m.height / 2.0,
                },
                radiusX: 7.0,
                radiusY: 7.0,
            };
            d.FillEllipse(&dot, &s.dot);
            d.DrawTextLayout(
                windows_numerics::Vector2 { X: 0.0, Y: 480.0 },
                &layout,
                &s.muted,
                D2D1_DRAW_TEXT_OPTIONS_NONE,
            );
            let card = rect(cx - 400.0, 560.0, cx + 400.0, 760.0);
            d.FillRoundedRectangle(
                &D2D1_ROUNDED_RECT {
                    rect: card,
                    radiusX: 20.0,
                    radiusY: 20.0,
                },
                &s.card,
            );
            draw(
                &s.hints,
                &s.hints_font,
                rect(
                    card.left + 44.0,
                    card.top + 30.0,
                    card.right - 30.0,
                    card.bottom,
                ),
                &self.text,
            );
            let footer = "F2  timing overlay          Alt+F4 or the tray icon  quit"
                .encode_utf16()
                .collect::<Vec<_>>();
            draw(&footer, &s.small, rect(0.0, 1000.0, w, 1040.0), &s.muted);
            d.SetTransform(&windows_numerics::Matrix3x2 {
                M11: 1.0,
                M22: 1.0,
                ..Default::default()
            });
        }
        Ok(())
    }

    /// (Re)creates the render target view and the D2D target on the current back buffer. In
    /// D3D11 flip model, buffer 0 always names the current back buffer, so both stay valid
    /// across presents until the next resize.
    fn bind(&mut self) -> Result<()> {
        // SAFETY: views on our swap chain's buffer; out-params are local Options.
        unsafe {
            let buf: ID3D11Texture2D = self.swap.GetBuffer(0)?;
            let mut rtv = None;
            self.device
                .CreateRenderTargetView(&buf, None, Some(&mut rtv))?;
            self.rtv = rtv;
            let props = D2D1_BITMAP_PROPERTIES1 {
                pixelFormat: D2D1_PIXEL_FORMAT {
                    format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    alphaMode: D2D1_ALPHA_MODE_IGNORE,
                },
                dpiX: 96.0,
                dpiY: 96.0,
                bitmapOptions: D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                colorContext: ManuallyDrop::new(None),
            };
            let target = self
                .d2d
                .CreateBitmapFromDxgiSurface(&buf.cast::<IDXGISurface>()?, Some(&props))?;
            self.d2d.SetTarget(&target);
            self.target = Some(target);
            let mut rc = RECT::default();
            GetClientRect(self.hwnd, &mut rc)?;
            self.client = ((rc.right - rc.left) as u32, (rc.bottom - rc.top) as u32);
        }
        Ok(())
    }

    /// Index of the cached views for this frame's surface; created on first sight only.
    fn view(&mut self, f: &Frame) -> Result<usize> {
        let key = (f.texture.as_raw() as usize, f.index);
        if let Some(i) = self.views.iter().position(|v| v.key == key) {
            return Ok(i);
        }
        if self.views.len() >= MAX_VIEWS {
            self.views.clear();
        }
        // SAFETY: views on a live decoder texture; NV12 exposes luma as R8 and chroma as R8G8.
        unsafe {
            let mut td = D3D11_TEXTURE2D_DESC::default();
            f.texture.GetDesc(&mut td);
            let srv = |format| -> Result<ID3D11ShaderResourceView> {
                let desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
                    Format: format,
                    ViewDimension: D3D11_SRV_DIMENSION_TEXTURE2DARRAY,
                    Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 {
                        Texture2DArray: D3D11_TEX2D_ARRAY_SRV {
                            MostDetailedMip: 0,
                            MipLevels: 1,
                            FirstArraySlice: f.index,
                            ArraySize: 1,
                        },
                    },
                };
                let mut v = None;
                self.device
                    .CreateShaderResourceView(&f.texture, Some(&desc), Some(&mut v))?;
                Ok(v.unwrap())
            };
            self.views.push(View {
                key,
                luma: srv(DXGI_FORMAT_R8_UNORM)?,
                chroma: srv(DXGI_FORMAT_R8G8_UNORM)?,
                visible: [
                    f.width as f32 / td.Width as f32,
                    f.height as f32 / td.Height as f32,
                    0.0,
                    0.0,
                ],
            });
        }
        Ok(self.views.len() - 1)
    }
}

impl Drop for Presenter {
    fn drop(&mut self) {
        // SAFETY: the waitable handle is ours and closed once.
        let _ = unsafe { CloseHandle(self.waitable) };
    }
}

fn compile(entry: PCSTR, target: PCSTR) -> Result<ID3DBlob> {
    let (mut blob, mut errors) = (None, None);
    // SAFETY: the source slice outlives the call; out-params are local Options.
    let r = unsafe {
        D3DCompile(
            SHADERS.as_ptr() as *const c_void,
            SHADERS.len(),
            None,
            None,
            None,
            entry,
            target,
            D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &mut blob,
            Some(&mut errors),
        )
    };
    if let Err(e) = r {
        let msg = errors
            .map(|b| String::from_utf8_lossy(bytes(&b)).into_owned())
            .unwrap_or_default();
        return Err(Error::new(e.code(), msg));
    }
    blob.ok_or_else(|| Error::new(E_FAIL, "no shader bytecode"))
}

fn bytes(b: &ID3DBlob) -> &[u8] {
    // SAFETY: a blob's pointer/size describe its own buffer, which lives as long as `b`.
    unsafe { std::slice::from_raw_parts(b.GetBufferPointer() as *const u8, b.GetBufferSize()) }
}

#[cfg(test)]
mod tests {
    use super::fit;

    #[test]
    fn letterbox() {
        assert_eq!(fit((1920, 1080), (1920, 1080)), (0, 0, 1920, 1080));
        assert_eq!(fit((1280, 720), (1920, 1080)), (0, 0, 1920, 1080));
        assert_eq!(
            fit((1920, 1200), (1920, 1080)),
            (96, 0, 1728, 1080),
            "pillarbox"
        );
        assert_eq!(
            fit((2560, 1080), (1920, 1080)),
            (0, 135, 1920, 810),
            "letterbox"
        );
        assert_eq!(fit((0, 0), (800, 600)), (0, 0, 800, 600));
    }
}
