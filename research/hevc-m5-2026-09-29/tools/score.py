"""Score a received frame of the test page against its ground-truth render.

usage: score.py <capdir> [--panel]
  default : compare at stream resolution against ref-2.0x (1:1 capture case)
  --panel : first bilinear-upscale the frame to the 5120 panel (what the
            receiver's layer does), compare against ref-<panel/stream*2>x
"""
import json, sys, numpy as np
from PIL import Image

d = sys.argv[1]; panel = "--panel" in sys.argv
info = json.load(open(f"{d}/rect.json"))
recv = Image.open(f"{d}/recv.png").convert("RGB")
k = 1.0
if panel:
    k = 5120 / recv.width
    recv = recv.resize((5120, round(recv.height * k)), Image.BILINEAR)
scale = info["backing"] * k
ref = np.asarray(Image.open(f"{d}/ref-{scale:.1f}x.png").convert("RGB"), dtype=np.float64)
R = np.asarray(recv, dtype=np.float64)
x0, y0 = round(info["x"] * k), round(info["y"] * k)
h, w = ref.shape[:2]

def luma(a): return a @ [0.2126, 0.7152, 0.0722]
best = None
ry = luma(ref)[::2, ::2]
for dy in range(-6, 7):
    for dx in range(-6, 7):
        c = R[y0 + dy:y0 + dy + h, x0 + dx:x0 + dx + w]
        if c.shape != ref.shape: continue
        e = np.mean((luma(c)[::2, ::2] - ry) ** 2)
        if best is None or e < best[0]: best = (e, dx, dy)
_, dx, dy = best
C = R[y0 + dy:y0 + dy + h, x0 + dx:x0 + dx + w]

def psnr(a, b): m = np.mean((a - b) ** 2); return 99.0 if m == 0 else 10 * np.log10(255 ** 2 / m)
def ycc(a):
    y = luma(a); return y, (a[..., 2] - y) / 1.8556, (a[..., 0] - y) / 1.5748
def lab(a):
    c = a / 255; c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    xyz = c @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    xyz /= [0.95047, 1.0, 1.08883]
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)

s = scale  # points -> pixels in this comparison
regions = {  # (x, y, w, h) in points on the 1600x900 page
    "text": (0, 8, 1600, 226), "colourText": (0, 234, 1600, 32),
    "patches": (16, 269, 768, 124), "gradients": (800, 269, 780, 124), "fine": (0, 405, 1600, 70),
}
out = {"offset": [dx, dy], "mode": "panel" if panel else "stream", "all_rgb": round(psnr(C, ref), 2)}
for name, (rx, ry_, rw, rh) in regions.items():
    sl = (slice(int(ry_ * s), int((ry_ + rh) * s)), slice(int(rx * s), int((rx + rw) * s)))
    a, b = C[sl], ref[sl]
    (ya, ba, ra), (yb, bb, rb) = ycc(a), ycc(b)
    out[name] = {"Y": round(psnr(ya, yb), 2), "CbCr": round(psnr(np.stack([ba, ra]), np.stack([bb, rb])), 2)}
# patch accuracy away from edges: mean colour of each patch's centre, CIE76 dE
dE = []
for i in range(24):
    px, py = 16 + (i % 12) * 64 + 15, 269 + (i // 12) * 64 + 15
    sl = (slice(int(py * s), int((py + 30) * s)), slice(int(px * s), int((px + 30) * s)))
    dE.append(float(np.linalg.norm(lab(C[sl].mean((0, 1))[None])[0] - lab(ref[sl].mean((0, 1))[None])[0])))
out["patch_dE_mean"] = round(float(np.mean(dE)), 2); out["patch_dE_max"] = round(float(np.max(dE)), 2)
print(json.dumps(out))
Image.fromarray(C.astype(np.uint8)).save(f"{d}/aligned-{out['mode']}.png")
