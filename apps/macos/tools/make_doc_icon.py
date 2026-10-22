"""Regenerate assets/ManimbleDocument.icns, the .manimble file icon (needs Pillow and macOS iconutil).

A white page with a folded corner and the app icon (assets/Manimble.icns) on it.
"""
from PIL import Image, ImageDraw, ImageFilter
import os, subprocess, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets")
S = 1024
L, T, R, B, F = 170, 60, S - 170, S - 60, 210   # page box and fold size
page = [(L, T), (R - F, T), (R, T + F), (R, B), (L, B)]
# soft shadow under the page
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sh).polygon([(x, y + 10) for x, y in page], fill=(0, 0, 0, 90))
im = sh.filter(ImageFilter.GaussianBlur(14))
d = ImageDraw.Draw(im)
d.polygon(page, fill=(252, 252, 254, 255), outline=(200, 202, 212, 255), width=4)
# the folded corner, tinted with the logo's violet
d.polygon([(R - F, T), (R - F, T + F), (R, T + F)], fill=(214, 206, 250, 255), outline=(170, 160, 230, 255), width=4)
# the app icon, centered on the page below the fold
logo = Image.open(os.path.join(ASSETS, "Manimble.icns"))
logo = logo.convert("RGBA").resize((520, 520), Image.LANCZOS)
im.alpha_composite(logo, ((S - 520) // 2, T + F + 120))
ic = os.path.join(HERE, "manimble-doc.iconset"); shutil.rmtree(ic, ignore_errors=True); os.makedirs(ic)
for sz in (16, 32, 64, 128, 256, 512):
    im.resize((sz, sz), Image.LANCZOS).save(f"{ic}/icon_{sz}x{sz}.png"); im.resize((sz * 2, sz * 2), Image.LANCZOS).save(f"{ic}/icon_{sz}x{sz}@2x.png")
subprocess.run(["iconutil", "-c", "icns", ic, "-o", os.path.join(ASSETS, "ManimbleDocument.icns")], check=True)
shutil.rmtree(ic)
