"""Draws the od-receiver logo (own design) into assets/logo.png (512 px, splash) and
assets/logo.ico (16-256 px, window and tray). Run: python assets/make_logo.py (needs Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw

S = 1024  # drawn large, downsampled for smooth edges
OUT = Path(__file__).parent


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def logo():
    # Diagonal indigo -> sky gradient on a rounded tile.
    grad = Image.new("RGBA", (S, S))
    top, bottom = (49, 46, 129), (14, 165, 233)
    px = grad.load()
    for y in range(S):
        for x in range(S):
            px[x, y] = lerp(top, bottom, (x + y) / (2 * S - 2)) + (255,)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((24, 24, S - 24, S - 24), radius=220, fill=255)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    # Monitor: screen with a thick bezel, neck and foot.
    glass = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glass).rectangle((200, 250, 824, 650), fill=(255, 255, 255, 56))
    img.alpha_composite(glass)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((170, 220, 854, 680), radius=48, outline=white, width=56)
    d.rectangle((462, 680, 562, 780), fill=white)
    d.rounded_rectangle((330, 770, 694, 826), radius=28, fill=white)
    # Cursor arrow arriving on the screen: the Mac's desktop extending onto this one.
    tip = (430, 330)
    arrow = [tip, (430, 590), (492, 532), (540, 640), (590, 618), (542, 512), (626, 512)]
    d.polygon(arrow, fill=white, outline=(30, 41, 99, 255))
    d.line(arrow + [tip], fill=(30, 41, 99, 255), width=14, joint="curve")
    return img


img = logo()
img.resize((512, 512), Image.LANCZOS).save(OUT / "logo.png")
img.resize((256, 256), Image.LANCZOS).save(OUT / "logo.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)])
print("wrote", OUT / "logo.png", OUT / "logo.ico")
