"""Import a PowerPoint (.pptx) or Keynote (.key) presentation as a new Manim Slides deck.

Every slide becomes a scene class. Text boxes become `Text(...)`, pictures `ImageMobject(...)`, rectangles /
ellipses / lines the matching manim shapes, tables `Table(...)`. Elements are written one per line, directly in
the scene, so Manimble can edit them like anything else. Animations and transitions are not imported."""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

FW, FH = 14.222222222222221, 8.0          # manim frame in units; 1280 x 720 px
DEFAULT_FONT = "Helvetica Neue"          # used when the presentation does not name a font
PT_PER_FONT_SIZE = 0.945                  # same calibration as the exporter


def keynote_to_pptx(key_path: str, pptx_path: str) -> dict:
    from .export import ensure_keynote_running
    if not Path("/Applications/Keynote.app").exists():
        return {"ok": False, "error": "Keynote is not installed, so a .key file cannot be read. "
                                      "Export it to PowerPoint from Keynote and import the .pptx."}
    ensure_keynote_running()
    script = f'''
    set src to POSIX file "{key_path}"
    set dst to POSIX file "{pptx_path}"
    tell application "Keynote"
        activate
        set d to open src
        delay 2
        export d to dst as Microsoft PowerPoint
        close d saving no
    end tell
    '''
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Keynote did not respond (a dialog may be waiting in Keynote)."}
    if r.returncode != 0 or not Path(pptx_path).exists():
        return {"ok": False, "error": "Keynote could not open the file: " + (r.stderr or r.stdout).strip()[-300:]}
    return {"ok": True}


def _rgb_hex(color) -> str | None:
    try:
        rgb = color.rgb
        return "#%02X%02X%02X" % (rgb[0], rgb[1], rgb[2])
    except Exception:
        return None


def _luma(hexcolor: str) -> float:
    h = hexcolor.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return 0.299 * r + 0.587 * g + 0.114 * b


def _slug(s: str, fallback: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")[:26]
    return s or fallback


def _num(x: float, nd: int = 3) -> str:
    s = f"{x:.{nd}f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


_FONT_DIRS = ("/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
              str(Path.home() / "Library" / "Fonts"))
_font_cache: dict = {}


def _font(family: str, bold: bool, italic: bool):
    """PIL font (at 1000 px per em) for measuring text the way PowerPoint wraps it, or None if not installed."""
    key = (family.lower(), bold, italic)
    if key in _font_cache:
        return _font_cache[key]
    want = ("bold " if bold else "") + ("italic" if italic else "")
    want = want.strip() or "regular"
    stem = family.lower().replace(" ", "")
    found = None
    try:
        from PIL import ImageFont
        faces = []
        for d in _FONT_DIRS:
            p = Path(d)
            if not p.is_dir():
                continue
            for f in p.iterdir():
                if f.suffix.lower() in (".ttf", ".ttc", ".otf") and f.stem.lower().replace(" ", "").startswith(stem):
                    for i in range(64):
                        try:
                            ft = ImageFont.truetype(str(f), 1000, index=i)
                        except Exception:                       # noqa: BLE001
                            break
                        fam, style = ft.getname()
                        if (fam or "").lower() == family.lower():
                            faces.append(((style or "").lower().replace("oblique", "italic"), ft))
        found = next((ft for style, ft in faces if style == want), None)
        if found is None and faces:
            found = next((ft for style, ft in faces if style == "regular"), faces[0][1])
    except Exception:                                           # noqa: BLE001
        found = None
    _font_cache[key] = found
    return found


def _wrap(text: str, styles: list, width_em: float, measure) -> tuple[str, list]:
    """Greedy word wrap to width_em (in ems of the font size), like PowerPoint: break at spaces, and inside a word
    only when the word alone is wider than the box. styles[i] is the style of text[i] and is kept aligned with the
    result. measure(segment, style) -> ems."""
    def width(i, j):
        w, k = 0.0, i
        while k < j:
            m = k
            while m < j and styles[m] == styles[k]:
                m += 1
            w += measure(text[k:m], styles[k])
            k = m
        return w

    out = list(text)
    start, last_space = 0, -1
    for i, ch in enumerate(text + "\n"):
        if ch not in " \n":
            continue
        if last_space > start and width(start, i) > width_em:
            out[last_space] = "\n"
            start = last_space + 1
        if ch == "\n":
            start, last_space = i + 1, -1
        else:
            last_space = i
    # words wider than the box are broken between characters
    res, res_styles = [], []
    start = 0
    for i in range(len(out) + 1):
        if i < len(out) and out[i] != "\n":
            continue
        if width(start, i) > width_em:
            line_w = 0.0
            for k in range(start, i):
                cw = measure(out[k], styles[k])
                if line_w > 0 and line_w + cw > width_em and out[k] != " ":
                    res.append("\n")
                    res_styles.append(styles[k])
                    line_w = 0.0
                line_w += cw
                res.append(out[k])
                res_styles.append(styles[k])
        else:
            res += out[start:i]
            res_styles += styles[start:i]
        if i < len(out):
            res.append("\n")
            res_styles.append(styles[i])
        start = i + 1
    return "".join(res), res_styles


def _runs(para):
    """[(text, font)] for the runs, fields and line breaks of a paragraph (font None for a break)."""
    from pptx.text.text import _Run
    out = []
    for child in para._p:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag in ("r", "fld"):
            r = _Run(child, para)
            out.append((r.text, r.font))
        elif tag == "br":
            out.append(("\n", None))
    return out


def import_presentation(src: str, dest: str, progress=None) -> dict:
    """Create dest/deck (+ dest/assets) from the presentation. Returns {"ok", "deck", "slides", "warnings"}."""
    try:
        from pptx import Presentation
        from pptx.enum.shapes import MSO_SHAPE_TYPE, MSO_SHAPE
        from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
        from pptx.enum.dml import MSO_FILL
        from pptx.oxml.ns import qn
    except ImportError:
        return {"ok": False, "error": "python-pptx is not installed in the Python environment Manimble uses "
                                      "(pip install python-pptx)."}
    src_p = Path(src)
    tmp = None
    if src_p.suffix.lower() == ".key":
        tmp = Path(tempfile.mkdtemp()) / (src_p.stem + ".pptx")
        r = keynote_to_pptx(str(src_p), str(tmp))
        if not r.get("ok"):
            return r
        src_p = tmp
    try:
        prs = Presentation(str(src_p))
    except Exception as exc:                                    # noqa: BLE001
        return {"ok": False, "error": f"Could not read the presentation: {exc}"}

    dest_p = Path(dest)
    deck, assets = dest_p / "deck", dest_p / "assets"
    deck.mkdir(parents=True, exist_ok=True)
    assets.mkdir(parents=True, exist_ok=True)
    W, H = prs.slide_width, prs.slide_height
    warnings: list[str] = []
    if abs(W / H - 16 / 9) > 0.02:
        warnings.append("the presentation is not 16:9; it was stretched onto a 16:9 frame")
    s_ref = 12192000 / W                                        # normalise to a 13.33in wide slide
    px_per_emu = 1280 / W

    def ux(emu_x):            # slide EMU -> manim x
        return (emu_x / W - 0.5) * FW

    def uy(emu_y):            # slide EMU -> manim y (up)
        return (0.5 - emu_y / H) * FH

    def uw(emu):              # EMU length -> manim units
        return emu / W * FW

    # master background
    def slide_bg(slide) -> str:
        for holder in (slide, slide.slide_layout, slide.slide_layout.slide_master):
            try:
                bg = holder._element.cSld.bg
                if bg is not None:
                    fill = holder.background.fill
                    if fill.type == MSO_FILL.SOLID:
                        c = _rgb_hex(fill.fore_color)
                        if c:
                            return c
            except Exception:
                continue
        return "#FFFFFF"

    scene_names: list[str] = []
    classes: list[str] = []
    n_img = 0

    def emit_shape(shape, bg_is_dark: bool, lines: list[str], slide_idx: int):
        nonlocal n_img
        st = None
        try:
            st = shape.shape_type
        except Exception:
            pass
        if st == MSO_SHAPE_TYPE.GROUP:
            for child in shape.shapes:
                emit_shape(child, bg_is_dark, lines, slide_idx)
            return
        try:
            left, top, width, height = shape.left, shape.top, shape.width, shape.height
        except Exception:
            return
        if left is None or width is None:
            return
        cx, cy = ux(left + width / 2), uy(top + height / 2)
        w_u, h_u = uw(width), height / H * FH
        rot = getattr(shape, "rotation", 0) or 0
        rot_code = f".rotate({_num(-rot * 3.14159265 / 180)})" if abs(rot) > 0.5 else ""
        default_text = "#FFFFFF" if bg_is_dark else "#000000"

        # ------------------------------------------------------------ pictures
        if st == MSO_SHAPE_TYPE.PICTURE:
            try:
                blob, ext = shape.image.blob, shape.image.ext
            except Exception:
                warnings.append(f"slide {slide_idx}: a picture could not be read")
                return
            n_img += 1
            name = f"slide{slide_idx:02d}_img{n_img}.{ext}"
            (assets / name).write_bytes(blob)
            lines.append(f'self.add(ImageMobject(ASSETS / "{name}").set(width={_num(w_u)}).move_to(({_num(cx)}, {_num(cy)}, 0)){rot_code})  # manimble')
            return

        # -------------------------------------------------------------- tables
        if getattr(shape, "has_table", False) and shape.has_table:
            rows = []
            for r in shape.table.rows:
                rows.append([c.text.strip().replace("\n", " ") or " " for c in r.cells])
            lines.append(f'self.add(Table({rows!r}, include_outer_lines=True, line_config={{"color": "{default_text}"}}, '
                         f'element_to_mobject_config={{"color": "{default_text}", "font": "{DEFAULT_FONT}"}})'
                         f'.scale_to_fit_width({_num(w_u)}).move_to(({_num(cx)}, {_num(cy)}, 0)))  # manimble')
            return

        # ------------------------------------------------------ lines / arrows
        is_line = st == MSO_SHAPE_TYPE.LINE or shape.__class__.__name__ == "Connector"
        if is_line:
            try:
                x1, y1, x2, y2 = shape.begin_x, shape.begin_y, shape.end_x, shape.end_y
            except Exception:
                x1, y1, x2, y2 = left, top, left + width, top + height
            color = _rgb_hex(shape.line.color) or default_text
            try:
                sw = max(1.0, shape.line.width * px_per_emu / 0.9)
            except Exception:
                sw = 3
            lines.append(f'self.add(Line(({_num(ux(x1))}, {_num(uy(y1))}, 0), ({_num(ux(x2))}, {_num(uy(y2))}, 0), color="{color}", stroke_width={_num(sw, 1)}))  # manimble')
            return

        # ------------------------------------------------------------ autoshapes
        fill = line = None
        try:
            if shape.fill.type == MSO_FILL.SOLID:
                fill = _rgb_hex(shape.fill.fore_color)
        except Exception:
            pass
        try:
            if shape.line.fill.type == MSO_FILL.SOLID:
                line = _rgb_hex(shape.line.color)
        except Exception:
            pass
        has_text = shape.has_text_frame and shape.text_frame.text.strip() != ""
        if st == MSO_SHAPE_TYPE.AUTO_SHAPE and (fill or line):
            try:
                kind = shape.auto_shape_type
            except Exception:
                kind = MSO_SHAPE.RECTANGLE
            try:
                sw = max(0.5, shape.line.width * px_per_emu / 0.9) if line else 0
            except Exception:
                sw = 3
            style = f'color="{line or fill}", stroke_width={_num(sw, 1)}' if line else 'stroke_width=0'
            fill_code = f', fill_color="{fill}", fill_opacity=1' if fill else ""
            if kind == MSO_SHAPE.OVAL:
                code = f"Ellipse(width={_num(w_u)}, height={_num(h_u)}, {style}{fill_code})"
            elif kind == MSO_SHAPE.ROUNDED_RECTANGLE:
                code = f"RoundedRectangle(width={_num(w_u)}, height={_num(h_u)}, corner_radius={_num(min(w_u, h_u) * 0.15)}, {style}{fill_code})"
            elif kind in (MSO_SHAPE.ISOSCELES_TRIANGLE,):
                code = f"Triangle({style}{fill_code}).stretch_to_fit_width({_num(w_u)}).stretch_to_fit_height({_num(h_u)})"
            else:
                if kind != MSO_SHAPE.RECTANGLE:
                    warnings.append(f"slide {slide_idx}: a {kind} shape was imported as a rectangle")
                code = f"Rectangle(width={_num(w_u)}, height={_num(h_u)}, {style}{fill_code})"
            lines.append(f"self.add({code}.move_to(({_num(cx)}, {_num(cy)}, 0)){rot_code})  # manimble")

        # ----------------------------------------------------------------- text
        if has_text:
            tf = shape.text_frame
            paras = [p for p in tf.paragraphs if p.text.strip() != ""]
            if not paras:
                return
            body_pr = tf._txBody.bodyPr

            def inset(attr, default):
                v = body_pr.get(attr)
                return int(v) if v is not None else default

            l_in, r_in = inset("lIns", 91440), inset("rIns", 91440)
            t_in, b_in = inset("tIns", 45720), inset("bIns", 45720)
            font_scale, spacing_scale = 1.0, 1.0
            autofit = body_pr.find(qn("a:normAutofit"))
            if autofit is not None:
                font_scale = int(autofit.get("fontScale", 100000)) / 100000
                spacing_scale = 1 - int(autofit.get("lnSpcReduction", 0)) / 100000
            wrap_text = body_pr.get("wrap") != "none"
            anchor = tf.vertical_anchor
            n = len(paras)

            # Lay the paragraphs out the way PowerPoint does: each wrapped to the box width, stacked top-down with
            # their own line height and spacing. Heights are in manim units.
            laid = []
            for para in paras:
                runs = _runs(para)
                f = next((fnt for t, fnt in runs if fnt is not None and t.strip()), para.font)
                size_pt = f.size.pt if f.size is not None else (44 if getattr(shape, "is_placeholder", False)
                                                                 and "TITLE" in str(shape.placeholder_format.type) else 20)
                size_pt *= font_scale
                fs = max(6.0, size_pt * s_ref / PT_PER_FONT_SIZE)
                color = _rgb_hex(f.color) if f.color is not None and f.color.type is not None else None
                color = color or default_text
                font = f.name or DEFAULT_FONT
                # per-character (bold, italic); the paragraph takes the style of most of its text, the rest is
                # written as t2w / t2s ranges
                raw, styles = "", []
                for t, fnt in runs:
                    t = t.replace("\x0b", "\n").replace("\v", "\n")
                    st = (bool(fnt.bold), bool(fnt.italic)) if fnt is not None else None
                    raw += t
                    styles += [st] * len(t)
                lead = len(raw) - len(raw.lstrip())
                text = raw.strip()
                styles = styles[lead:lead + len(text)]
                counts: dict = {}
                for ch, st in zip(text, styles):
                    if st is not None and not ch.isspace():
                        counts[st] = counts.get(st, 0) + 1
                bold, italic = max(counts, key=counts.get) if counts else (False, False)
                styles = [st or (bold, italic) for st in styles]

                def measure(seg, st, font=font):
                    ft = _font(font, *st)
                    return ft.getlength(seg) / 1000 if ft is not None else len(seg) * (0.55 if st[0] else 0.5)

                pil = _font(font, bold, italic)
                if wrap_text:
                    text, styles = _wrap(text, styles, (width - l_in - r_in) / 12700 / size_pt, measure)
                text_lines = text.split("\n")

                def ranges(pick):
                    out, i = [], 0
                    while i < len(text):
                        j = i
                        while j < len(text) and pick(styles[j]) == pick(styles[i]):
                            j += 1
                        if pick(styles[i]) != pick((bold, italic)) and text[i:j].strip():
                            out.append((i, j))
                        i = j
                    return out

                if pil is not None:
                    ascent, descent = pil.getmetrics()
                    line_em = (ascent + descent) / 1000
                else:
                    line_em = 1.2
                ls = para.line_spacing
                if isinstance(ls, float):
                    pitch = uw(ls * spacing_scale * line_em * size_pt * 12700)
                elif ls is not None:
                    pitch = uw(ls * spacing_scale)
                else:
                    pitch = uw(spacing_scale * line_em * size_pt * 12700)
                laid.append({"text": text, "n_lines": len(text_lines), "fs": fs, "color": color,
                             "font": font, "bold": bold, "italic": italic, "pitch": pitch,
                             "t2w": [(i, j, "NORMAL" if bold else "BOLD") for i, j in ranges(lambda st: st[0])],
                             "t2s": [(i, j, "NORMAL" if italic else "ITALIC") for i, j in ranges(lambda st: st[1])],
                             "before": uw(para.space_before or 0), "after": uw(para.space_after or 0),
                             "align": para.alignment})
            total = sum(p["n_lines"] * p["pitch"] for p in laid)
            total += sum(p["before"] for p in laid[1:]) + sum(p["after"] for p in laid[:-1])
            box_top, box_bottom = uy(top + t_in), uy(top + height - b_in)
            if anchor == MSO_ANCHOR.TOP or (anchor is None and n > 1):
                y = box_top
            elif anchor == MSO_ANCHOR.BOTTOM:
                y = box_bottom + total
            else:
                y = (box_top + box_bottom) / 2 + total / 2
            x_left, x_right = ux(left + l_in), ux(left + width - r_in)
            for pi, p in enumerate(laid):
                if pi:
                    y -= p["before"]
                block_h = p["n_lines"] * p["pitch"]
                ty = y - block_h / 2
                y -= block_h + p["after"]
                kw = [f"font_size={_num(p['fs'], 1)}", f'color="{p["color"]}"']
                if p["font"]:
                    kw.append(f'font="{p["font"]}"')
                if p["bold"]:
                    kw.append('weight="BOLD"')
                if p["italic"]:
                    kw.append('slant="ITALIC"')
                for key in ("t2w", "t2s"):
                    if p[key]:
                        kw.append(f"{key}={{" + ", ".join(f'"[{i}:{j}]": "{v}"' for i, j, v in p[key]) + "}")
                if p["n_lines"] > 1:
                    # manim's line pitch is font_size * (1 + line_spacing) / 96 units
                    kw.append(f"line_spacing={_num(p['pitch'] * 96 / p['fs'] - 1, 2)}")
                align = p["align"]
                pos = f".move_to(({_num((x_left + x_right) / 2)}, {_num(ty)}, 0))"
                if align == PP_ALIGN.LEFT or align is None and n > 1:
                    pos += f".align_to(({_num(x_left)}, 0, 0), LEFT)"
                elif align == PP_ALIGN.RIGHT:
                    pos += f".align_to(({_num(x_right)}, 0, 0), RIGHT)"
                lines.append(f'self.add(Text({p["text"]!r}, {", ".join(kw)}){pos}{rot_code})  # manimble')

    for si, slide in enumerate(prs.slides, start=1):
        if progress:
            progress(si - 1, len(prs.slides), f"slide {si}")
        bg = slide_bg(slide)
        dark = _luma(bg) < 128
        body: list[str] = []
        title = ""
        for shape in slide.shapes:
            if not title and shape.has_text_frame and shape.text_frame.text.strip():
                title = shape.text_frame.text.strip().split("\n")[0]
            try:
                emit_shape(shape, dark, body, si)
            except Exception as exc:                            # noqa: BLE001
                warnings.append(f"slide {si}: skipped a shape ({exc})")
        name = f"S{si:02d}_{_slug(title, 'Slide')}"
        scene_names.append(name)
        notes = ""
        try:
            if slide.has_notes_slide and slide.notes_slide.notes_text_frame.text.strip():
                notes = "\n        # Speaker notes:\n" + "\n".join("        # " + l for l in slide.notes_slide.notes_text_frame.text.strip().split("\n"))
        except Exception:
            pass
        code = [f"class {name}(Deck):", f'    """Imported from slide {si}."""', "", "    def construct(self):",
                f'        self.camera.background_color = "{bg}"{notes}']
        code += ["        " + l for l in body] or ["        pass"]
        classes.append("\n".join(code))

    (deck / "common.py").write_text(
        '"""Shared base class for the imported deck."""\n\nfrom pathlib import Path\n\nfrom manim import *\nfrom manim_slides import Slide\n\n'
        'ASSETS = Path(__file__).resolve().parent.parent / "assets"\n\n\nclass Deck(Slide):\n    skip_reversing = True\n')
    (deck / "slides.py").write_text(
        '"""Slides imported from ' + src_p.name + '."""\n\nfrom common import *\n\n\n' + "\n\n\n".join(classes) + "\n")
    (deck / "order.txt").write_text(" ".join(scene_names) + "\n")
    (deck / "manim.cfg").write_text("[CLI]\nbackground_color = #000000\npixel_width = 1280\npixel_height = "
                                    + str(int(round(1280 * H / W))) + "\nframe_rate = 30\n")
    return {"ok": True, "deck": str(deck), "slides": len(scene_names), "warnings": warnings[:20]}
