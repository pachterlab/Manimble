"""BioCartoon icons as vector pictures (`SVGMobject`) when manim can draw them faithfully.

manim reads an SVG's paths and flat colours but not its text, embedded pictures, gradients, clipping or masks; it fills
every path with the nonzero rule (ignoring fill-rule="evenodd", so holes fill in) and takes stroke widths as its own
units (1 = 0.01 scene units) whatever the drawing's scale. `prepare` rewrites the catalog's SVG as plain paths that
manim reads as drawn: transforms and CSS applied, the subpaths of even-odd paths turned so the nonzero rule leaves the
same holes, and the drawing scaled to `HEIGHT` SVG units high, which makes the strokes exact at SVGMobject's default
height of 2 scene units; placed with `.scale(k, scale_stroke=True)` they then stay in proportion at any size (a resize
rewrites that k). It renders the result and compares it with the catalog's PNG of the same icon; the vector copy is
used only when they match, else the caller keeps the PNG.
"""
from __future__ import annotations

import os
import re
from xml.sax.saxutils import quoteattr

import numpy as np

HEIGHT = 200.0           # SVG units high: SVGMobject's default 2 scene units, in stroke units (0.01)
PLACED = 3.0             # scene units on the longer side, the size an icon is placed at
# what manim cannot draw (a gradient or pattern only counts when a shape is painted with it)
UNSUPPORTED = re.compile(r"<(?:\w+:)?(text|image|filter|mask|foreignObject|switch)\b|\b(?:clip-path|mask|filter)\s*[=:]\s*['\"]?url\(")
PAINT_SERVER = re.compile(r"<(?:\w+:)?(?:linearGradient|radialGradient|pattern)\b[^>]*\bid\s*=\s*['\"]([^'\"]+)")


def unsupported(text: str) -> str | None:
    """Why manim would not draw this SVG as it looks, nil when nothing in it is out of reach."""
    m = UNSUPPORTED.search(text)
    if m:
        return f"uses {m.group(1) or 'clipping, masks or filters'}"
    for pid in PAINT_SERVER.findall(text):
        if re.search(r"url\(\s*['\"]?#" + re.escape(pid) + r"['\"]?\s*\)", text):
            return "uses gradients or patterns"
    return None


def _polygon(sub, n: int = 12) -> np.ndarray:
    """Points along a subpath (n per curve), for its orientation and what contains it."""
    import svgelements as se
    pts = []
    for seg in sub:
        if isinstance(seg, (se.Move, se.Close)):
            if seg.end is not None:
                pts.append((seg.end.x, seg.end.y))
            continue
        for t in np.linspace(0, 1, n if not isinstance(seg, se.Line) else 2)[1:]:
            p = seg.point(t)
            pts.append((p.x, p.y))
    return np.array(pts, dtype=float) if pts else np.zeros((0, 2))


def _area(poly: np.ndarray) -> float:
    if len(poly) < 3:
        return 0.0
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def _inside(pt, poly: np.ndarray) -> bool:
    x, y = pt
    xs, ys = poly[:, 0], poly[:, 1]
    xs2, ys2 = np.roll(xs, -1), np.roll(ys, -1)
    cross = (ys > y) != (ys2 > y)
    with np.errstate(divide="ignore", invalid="ignore"):
        xi = xs + (y - ys) * (xs2 - xs) / (ys2 - ys)
    return bool(np.count_nonzero(cross & (x < xi)) % 2)


def _nonzero_d(path) -> str:
    """The path's outline with its subpaths turned so that nonzero filling leaves the holes even-odd filling does."""
    subs = [s for s in path.as_subpaths() if len(s)]
    polys = [_polygon(s) for s in subs]
    out = []
    import svgelements as se
    out = []
    for i, (s, poly) in enumerate(zip(subs, polys)):
        a = _area(poly)
        if a != 0:
            # how many larger subpaths contain it: the outermost and every second level in fill, the others holes
            probe = poly[len(poly) // 2]
            depth = sum(1 for j, q in enumerate(polys) if j != i and len(q) > 2 and abs(_area(q)) > abs(a) and _inside(probe, q))
            if (a > 0) != (depth % 2 == 0):
                out.append(se.Path(s.d()).reverse().d())   # a fresh path: reversing a Subpath changes its parent
                continue
        out.append(s.d())
    return " ".join(out)


def _colour(c) -> tuple[str, float]:
    """An svgelements colour as ("#rrggbb", opacity); ("none", 0) when there is none."""
    if c is None or getattr(c, "value", None) is None:
        return "none", 0.0
    return c.hexrgb, float(c.opacity)


def normalize(src: str, dst: str) -> dict:
    """Write `src` as plain paths manim draws as they look (see the module notes). Returns its width and height."""
    import svgelements as se
    svg = se.SVG.parse(src, reify=True)
    shapes = []
    for e in svg.elements():
        if not isinstance(e, se.Shape) or isinstance(e, se.Text):
            continue
        if e.values.get("visibility") in ("hidden", "collapse") or e.values.get("display") == "none":
            continue
        p = se.Path(e)
        p.reify()
        if not len(p):
            continue
        fill, fo = _colour(e.fill)
        stroke, so = _colour(e.stroke)
        sw = float(e.implicit_stroke_width or 0) if stroke != "none" else 0.0
        if (fill == "none" or fo == 0) and (stroke == "none" or so == 0 or sw == 0):
            continue
        evenodd = str(e.values.get("fill-rule", "")).strip() == "evenodd"
        shapes.append((p, fill, fo, stroke, so, sw, evenodd))
    if not shapes:
        raise ValueError("the SVG draws nothing manim can read")
    boxes = np.array([p.bbox() for p, *_ in shapes if p.bbox() is not None], dtype=float)
    x0, y0 = boxes[:, 0].min(), boxes[:, 1].min()
    x1, y1 = boxes[:, 2].max(), boxes[:, 3].max()
    k = HEIGHT / max(y1 - y0, 1e-9)
    fit = se.Matrix(f"translate({-x0}, {-y0})") * se.Matrix(f"scale({k})")
    w, h = (x1 - x0) * k, (y1 - y0) * k
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.3f} {h:.3f}" width="{w:.3f}" height="{h:.3f}">']
    for p, fill, fo, stroke, so, sw, evenodd in shapes:
        p = p * fit
        p.reify()
        d = _nonzero_d(p) if evenodd else p.d()
        attrs = {"d": d, "fill": fill}
        if fill != "none" and fo < 1:
            attrs["fill-opacity"] = f"{fo:.3f}"
        if stroke != "none" and sw > 0:
            attrs["stroke"] = stroke
            attrs["stroke-width"] = f"{sw * k:.3f}"
            if so < 1:
                attrs["stroke-opacity"] = f"{so:.3f}"
        lines.append("<path " + " ".join(f"{a}={quoteattr(v)}" for a, v in attrs.items()) + "/>")
    lines.append("</svg>")
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return {"width": float(w), "height": float(h)}


def aspect(path: str) -> float:
    """Width over height of an SVG, from its viewBox (or width and height)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        head = fh.read(4096)
    m = re.search(r"viewBox\s*=\s*['\"]\s*[-\d.eE]+[\s,]+[-\d.eE]+[\s,]+([\d.eE]+)[\s,]+([\d.eE]+)", head)
    if m and float(m.group(2)) > 0:
        return float(m.group(1)) / float(m.group(2))
    w, h = (re.search(rf"\b{k}\s*=\s*['\"]([\d.]+)", head) for k in ("width", "height"))
    return float(w.group(1)) / float(h.group(1)) if w and h and float(h.group(1)) > 0 else 1.0


def _trimmed(img):
    """The picture cropped to what is not transparent, nil when it is all transparent."""
    a = np.asarray(img)[:, :, 3]
    ys, xs = np.nonzero(a > 8)
    if not len(xs):
        return None
    return img.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))


def compare(svg: str, png: str, side: int = 200) -> dict:
    """How closely manim's drawing of `svg` (placed PLACED scene units long) matches the PNG of the same icon:
    the overlap of their shapes and the share of their pixels whose colour is clearly off."""
    from PIL import Image
    from manim import SVGMobject
    from manim.camera.camera import Camera
    ref = _trimmed(Image.open(png).convert("RGBA"))
    if ref is None:
        return {"ok": False, "why": "the PNG is empty"}
    m = SVGMobject(svg, use_svg_cache=False)
    if not m.family_members_with_points() or m.width <= 0 or m.height <= 0:
        return {"ok": False, "why": "manim draws nothing"}
    m.scale(PLACED / max(m.width, m.height), scale_stroke=True).move_to([0, 0, 0])
    fw, fh = m.width * 1.3 + 0.2, m.height * 1.3 + 0.2          # room for strokes past the outline
    px = 600 / max(fw, fh)
    cam = Camera(pixel_width=max(8, round(fw * px)), pixel_height=max(8, round(fh * px)), frame_width=fw, frame_height=fh,
                 background_opacity=0)
    cam.capture_mobject(m)
    got = _trimmed(cam.get_image().convert("RGBA"))
    if got is None:
        return {"ok": False, "why": "manim draws nothing"}
    ar_got, ar_ref = got.width / got.height, ref.width / ref.height
    if abs(np.log(ar_got / ar_ref)) > 0.06:
        return {"ok": False, "why": f"its shape differs (aspect {ar_got:.2f} vs {ar_ref:.2f})"}
    s = side / max(ref.width, ref.height)
    size = (max(8, round(ref.width * s)), max(8, round(ref.height * s)))
    a = np.asarray(got.resize(size, Image.LANCZOS), dtype=float) / 255
    b = np.asarray(ref.resize(size, Image.LANCZOS), dtype=float) / 255

    def on_white(p):
        return p[:, :, :3] * p[:, :, 3:] + (1 - p[:, :, 3:])
    sa, sb = a[:, :, 3] > 0.5, b[:, :, 3] > 0.5
    union = sa | sb
    iou = float((sa & sb).sum() / max(1, union.sum()))
    off = float((np.abs(on_white(a) - on_white(b)).max(axis=2) > 0.25)[union].mean()) if union.any() else 1.0
    return {"ok": iou > 0.9 and off < 0.03, "iou": round(iou, 3), "off": round(off, 3),
            "why": None if iou > 0.9 and off < 0.03 else "manim draws it differently"}


def prepare(req: dict) -> dict:
    """{svg, png, out}: write the manim-ready copy of `svg` to `out` when it draws like `png`.
    Returns {ok, width, height} or {ok: False, why}."""
    try:
        with open(req["svg"], encoding="utf-8", errors="replace") as fh:
            why = unsupported(fh.read())
        if why:
            return {"ok": False, "why": why}
        size = normalize(req["svg"], req["out"])
        res = compare(req["out"], req["png"])
    except Exception as exc:  # noqa: BLE001  any SVG manim or svgelements chokes on stays a PNG
        res = {"ok": False, "why": f"{type(exc).__name__}: {exc}"}
    if not res["ok"]:
        try:
            os.remove(req["out"])
        except OSError:
            pass
        return res
    return dict(res, **size)
