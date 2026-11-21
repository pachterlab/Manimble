"""Writes the Microsoft Store package's images (msix/Assets/*.png) from the app's icons.

    python3 apps/windows/msix/make_assets.py

The PNGs are committed, so a build needs no Python; run this again after the icons change. The names carry the
scale/targetsize qualifiers that resources.pri (made by build_release.ps1 -Msix with makepri) resolves.
"""
from pathlib import Path
from PIL import Image

here = Path(__file__).resolve().parent
icons = here.parent / "Manimble" / "Assets"
out = here / "Assets"
out.mkdir(exist_ok=True)


def largest(ico: Path) -> Image.Image:
    im = Image.open(ico)
    im.size = max(im.info["sizes"])
    return im.convert("RGBA")


def tile(src: Image.Image, w: int, h: int, fill: float) -> Image.Image:
    """src centred on a transparent w x h canvas, its side fill * the canvas's shorter side."""
    side = round(min(w, h) * fill)
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    canvas.alpha_composite(src.resize((side, side), Image.LANCZOS), ((w - side) // 2, (h - side) // 2))
    return canvas


app, doc = largest(icons / "Manimble.ico"), largest(icons / "ManimbleDocument.ico")
for scale in (100, 200):
    k = scale / 100
    tile(app, round(44 * k), round(44 * k), 1.0).save(out / f"Square44x44Logo.scale-{scale}.png")
    tile(app, round(150 * k), round(150 * k), 0.66).save(out / f"Square150x150Logo.scale-{scale}.png")
    tile(app, round(310 * k), round(150 * k), 0.66).save(out / f"Wide310x150Logo.scale-{scale}.png")
    tile(app, round(50 * k), round(50 * k), 1.0).save(out / f"StoreLogo.scale-{scale}.png")
for size in (16, 24, 32, 48, 256):
    for name, src in (("Square44x44Logo", app), ("Document", doc)):
        img = tile(src, size, size, 1.0)
        img.save(out / f"{name}.targetsize-{size}.png")
        img.save(out / f"{name}.targetsize-{size}_altform-unplated.png")
print(len(list(out.glob("*.png"))), "images in", out)
