"""Score a frame sequence of the test page: per frame Y / CbCr PSNR of the text
and colour-text regions. Scroll frames are aligned by rolling the reference."""
import json, sys, glob, numpy as np
from PIL import Image
d = sys.argv[1]; scroll = "--scroll" in sys.argv
info = json.load(open(f"{d}/rect.json")); s = info["backing"]
ref = np.asarray(Image.open(f"{d}/ref-2.0x.png").convert("RGB"), dtype=np.float64)
h, w = ref.shape[:2]; x0, y0 = int(info["x"]), int(info["y"])
def luma(a): return a @ [0.2126, 0.7152, 0.0722]
def ycc(a): y = luma(a); return y, np.stack([(a[..., 2] - y) / 1.8556, (a[..., 0] - y) / 1.5748])
def psnr(a, b): m = np.mean((a - b) ** 2); return 99.0 if m == 0 else 10 * np.log10(255 ** 2 / m)
refY = luma(ref)
rows = []
for f in sorted(glob.glob(f"{d}/od-seq-*.png")):
    C = np.asarray(Image.open(f).convert("RGB"), dtype=np.float64)[y0:y0 + h, x0:x0 + w]
    shift = 0
    if scroll:
        cy = luma(C)[::4, ::4]
        errs = [np.mean((np.roll(refY, -k * 8, 0)[::4, ::4] - cy) ** 2) for k in range(h // 8)]
        shift = int(np.argmin(errs)) * 8
    R = np.roll(ref, -shift, 0)
    whiteish = np.mean(C) > 250
    out = {"f": f[-6:-4], "shift": shift, "blank": bool(whiteish), "all": round(psnr(C, R), 2)}
    # text rows, with the scroll wrap: rows of the reference that are text, after rolling
    mask = np.zeros(h, bool); mask[int(8 * s):int(234 * s)] = True; mt = np.roll(mask, -shift)
    mask2 = np.zeros(h, bool); mask2[int(234 * s):int(266 * s)] = True; mc = np.roll(mask2, -shift)
    for name, m in (("text", mt), ("colourText", mc)):
        (ya, ca), (yb, cb) = ycc(C[m]), ycc(R[m])
        out[name] = [round(psnr(ya, yb), 2), round(psnr(ca, cb), 2)]
    rows.append(out)
for r in rows: print(json.dumps(r))
