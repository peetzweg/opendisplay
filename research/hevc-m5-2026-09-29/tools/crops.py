"""Zoomed crops of the test page only (never the surrounding desktop)."""
import json, numpy as np, sys
from PIL import Image, ImageDraw
S = sys.argv[1]; out = sys.argv[2]
def luma(a): return a @ [0.2126, 0.7152, 0.0722]
def page(capdir, frame=None, panel=False):
    info = json.load(open(f"{capdir}/rect.json"))
    im = Image.open(f"{capdir}/{frame or 'recv.png'}").convert("RGB"); k = 1.0
    if panel: k = 5120 / im.width; im = im.resize((5120, round(im.height * k)), Image.BILINEAR)
    s = info["backing"] * k; x, y = round(info["x"] * k), round(info["y"] * k)
    a = np.asarray(im)[y:y + round(900 * s), x:x + round(1600 * s)]
    ref = np.asarray(Image.open(f"{capdir}/ref-{s:.1f}x.png").convert("RGB"))
    if frame:  # undo scroll by matching against the reference
        ry, cy = luma(ref.astype(float))[::4, ::4], luma(a.astype(float))[::4, ::4]
        k8 = int(np.argmin([np.mean((np.roll(ry, -i * 2, 0) - cy) ** 2) for i in range(ry.shape[0] // 2)])) * 8
        a = np.roll(a, k8, 0)
    return a, ref, s
def crop(a, s, box): x, y, w, h = box; return Image.fromarray(a[int(y*s):int((y+h)*s), int(x*s):int((x+w)*s)])
def panelset(items, box, zoom, name):
    tiles = [(lbl, crop(a, s, box)) for lbl, a, s in items]
    W = max(t.width for _, t in tiles) * zoom; H = sum(t.height * zoom + 26 for _, t in tiles)
    canvas = Image.new("RGB", (W, H), "white"); d = ImageDraw.Draw(canvas); y = 0
    for lbl, t in tiles:
        d.text((6, y + 6), lbl, fill="black"); y += 26
        canvas.paste(t.resize((t.width * zoom, t.height * zoom), Image.NEAREST), (0, y)); y += t.height * zoom
    canvas.save(f"{out}/{name}")
text = (16, 14, 250, 50); colour = (12, 234, 520, 30)
# 1. first frame after a full-page change, 4096 stream, 18 Mbps
h, ref, s = page(f"{S}/cap/h264-4096-change", "od-seq-08.png")
first_hevc = [f for f in sorted(__import__('glob').glob(f"{S}/cap/hevc-4096-change/od-seq-*.png"))
              if np.asarray(Image.open(f).convert('L')).mean() < 250][0].split('/')[-1]
v, _, _ = page(f"{S}/cap/hevc-4096-change", first_hevc)
for box, nm in ((text, "text"), (colour, "colour")):
    panelset([("reference", ref, s), ("H.264 first frame after change, 18 Mbps", h, s),
              ("HEVC first frame after change, 18 Mbps", v, s)], box, 3, f"1-change-first-frame-{nm}-3x.png")
# 2. 5K Default as the panel shows it
h, rh, sh = page(f"{S}/cap/h264-default-static", panel=True)
v, rv, sv = page(f"{S}/cap/hevc-5k-static", panel=True)
for box, nm in ((text, "text"), (colour, "colour")):
    panelset([("H.264 at Default: 4096 stream stretched to 5120 (desktop 2048x1152 pt)", h, sh),
              ("HEVC at Default: 5120 stream 1:1 (desktop 2560x1440 pt)", v, sv)], box, 3, f"2-default-panel-{nm}-3x.png")
# 3. scrolling at 6 Mbps, 4096 stream
h, ref, s = page(f"{S}/cap/h264-4096-6M-scroll", "od-seq-10.png")
v, _, _ = page(f"{S}/cap/hevc-4096-6M-scroll", "od-seq-10.png")
for box, nm in ((text, "text"), (colour, "colour")):
    panelset([("reference", ref, s), ("H.264 scrolling, 6 Mbps", h, s), ("HEVC scrolling, 6 Mbps", v, s)],
             box, 3, f"3-scroll-6mbps-{nm}-3x.png")
print("ok")
