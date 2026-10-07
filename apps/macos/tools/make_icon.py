"""Regenerate assets/Manimble.icns (needs Pillow and macOS iconutil)."""
from PIL import Image, ImageDraw, ImageFilter
import os, subprocess, shutil
S = 1024
# squircle with a violet gradient
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    gd.line([(0, y), (S, y)], fill=lerp((124, 92, 255), (46, 30, 140), y / S))
mask = Image.new("L", (S, S), 0); ImageDraw.Draw(mask).rounded_rectangle((60, 60, S - 60, S - 60), 230, fill=255)
im = Image.new("RGBA", (S, S), (0, 0, 0, 0)); im.paste(grad, (0, 0), mask)
# the slide, with a soft shadow
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sh).rounded_rectangle((200, 300, S - 200, S - 280), 46, fill=(0, 0, 0, 120))
im = Image.alpha_composite(im, sh.filter(ImageFilter.GaussianBlur(26)).transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -18)))
d = ImageDraw.Draw(im)
d.rounded_rectangle((200, 290, S - 200, S - 300), 46, fill=(250, 250, 253, 255))
d.rounded_rectangle((270, 360, 560, 410), 20, fill=(255, 108, 12, 255))          # title bar in manim orange
d.rounded_rectangle((270, 450, 700, 480), 14, fill=(205, 207, 218, 255))
d.rounded_rectangle((270, 510, 600, 540), 14, fill=(205, 207, 218, 255))
# selection handles on the slide corners
for (x, y) in [(200, 290), (S - 200, 290), (200, S - 300), (S - 200, S - 300)]:
    d.ellipse((x - 34, y - 34, x + 34, y + 34), fill=(255, 255, 255, 255), outline=(124, 92, 255, 255), width=14)
ic = os.path.join(os.path.dirname(os.path.abspath(__file__)), "manimble.iconset"); shutil.rmtree(ic, ignore_errors=True); os.makedirs(ic)
for sz in (16, 32, 64, 128, 256, 512):
    im.resize((sz, sz)).save(f"{ic}/icon_{sz}x{sz}.png"); im.resize((sz * 2, sz * 2)).save(f"{ic}/icon_{sz}x{sz}@2x.png")
subprocess.run(["iconutil", "-c", "icns", ic, "-o", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "Manimble.icns")], check=True)
shutil.rmtree(ic)
