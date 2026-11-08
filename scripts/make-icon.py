#!/usr/bin/env python3
"""assets/wordmark-source.png -> assets/AppIcon.icns, assets/AppIcon.png (1024) and assets/logo.png (README).
The wordmark is centred on the standard macOS icon shape: a 824 px black rounded square on a 1024 canvas."""
import pathlib, subprocess, tempfile
from PIL import Image, ImageDraw

root = pathlib.Path(__file__).resolve().parent.parent / "assets"
src = Image.open(root / "wordmark-source.png").convert("RGB")

# Bounding box of the cyan letters (anything clearly brighter than the black background).
mask = src.convert("L").point(lambda v: 255 if v > 40 else 0)
word = src.crop(mask.getbbox())

S, INSET, RADIUS = 1024, 100, 185
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shape = Image.new("L", (S, S), 0)
ImageDraw.Draw(shape).rounded_rectangle((INSET, INSET, S - INSET, S - INSET), RADIUS, fill=255)
icon.paste((0, 0, 0, 255), (0, 0), shape)

w = int((S - 2 * INSET) * 0.84)
h = round(word.height * w / word.width)
word = word.resize((w, h), Image.LANCZOS)
icon.paste(word, ((S - w) // 2, (S - h) // 2 - 8))  # a touch up: the "p" descender sits low
icon.save(root / "AppIcon.png")

with tempfile.TemporaryDirectory() as tmp:
    iconset = pathlib.Path(tmp) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "AppIcon.icns")], check=True)

logo = src.resize((1200, round(src.height * 1200 / src.width)), Image.LANCZOS)
logo.save(root / "logo.png", optimize=True)
print("wrote", *(p.name for p in sorted(root.iterdir())))
