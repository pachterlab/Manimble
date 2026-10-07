"""Import a PowerPoint (.pptx) or Keynote (.key) presentation as a new Manim Slides deck.

Every slide becomes a scene class. Text boxes become `Text(...)`, pictures `ImageMobject(...)`, rectangles /
ellipses / lines the matching manim shapes, tables `Table(...)`. Elements are written one per line, directly in
the scene, so Manimble can edit them like anything else. Animations and transitions are not imported."""

from __future__ import annotations

import re
import subprocess
import tempfile
import textwrap
from pathlib import Path

FW, FH = 14.222222222222221, 8.0          # manim frame in units; 1280 x 720 px
DEFAULT_FONT = "Helvetica Neue"          # used when the presentation does not name a font
PT_PER_FONT_SIZE = 0.945                  # same calibration as the exporter
PX_PER_FONT_SIZE = 1.26                   # em size in px (1280 px frame) per manim font_size


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


def import_presentation(src: str, dest: str, progress=None) -> dict:
    """Create dest/deck (+ dest/assets) from the presentation. Returns {"ok", "deck", "slides", "warnings"}."""
    try:
        from pptx import Presentation
        from pptx.enum.shapes import MSO_SHAPE_TYPE, MSO_SHAPE
        from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
        from pptx.enum.dml import MSO_FILL
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
            paras = [p for p in tf.paragraphs if "".join(r.text for r in p.runs).strip() != ""]
            if not paras:
                return
            anchor = tf.vertical_anchor
            for pi, para in enumerate(paras):
                text = "".join(r.text for r in para.runs).replace("\x0b", "\n").strip()
                run = next((r for r in para.runs if r.text.strip()), para.runs[0])
                f = run.font
                size_pt = f.size.pt if f.size is not None else (44 if getattr(shape, "is_placeholder", False)
                                                                 and "TITLE" in str(shape.placeholder_format.type) else 20)
                fs = max(6.0, size_pt * s_ref / PT_PER_FONT_SIZE)
                color = _rgb_hex(f.color) if f.color is not None and f.color.type is not None else None
                color = color or default_text
                font = f.name or DEFAULT_FONT
                bold = bool(f.bold)
                italic = bool(f.italic)
                # wrap to the box width like PowerPoint would
                em_px = fs * PX_PER_FONT_SIZE
                chars = max(8, int((width * px_per_emu) / (0.5 * em_px)))
                wrapped = "\n".join(textwrap.fill(line, chars) if len(line) > chars else line for line in text.split("\n"))
                kw = [f"font_size={_num(fs, 1)}", f'color="{color}"']
                if font:
                    kw.append(f'font="{font}"')
                if bold:
                    kw.append('weight="BOLD"')
                if italic:
                    kw.append('slant="ITALIC"')
                align = para.alignment
                # place: one paragraph per Text; stack paragraphs top-down inside the box
                n = len(paras)
                n_lines = wrapped.count("\n") + 1
                line_h = em_px * 1.25 / 1280 * FW
                block_h = n_lines * line_h
                if n == 1:
                    ty = cy
                    if anchor == MSO_ANCHOR.TOP:
                        ty = uy(top) - block_h / 2 - 0.05
                    elif anchor == MSO_ANCHOR.BOTTOM:
                        ty = uy(top + height) + block_h / 2 + 0.05
                else:
                    ty = uy(top) - (pi + 0.5) * line_h * 1.2 - 0.05
                pos = f".move_to(({_num(cx)}, {_num(ty)}, 0))"
                if align == PP_ALIGN.LEFT or align is None and n > 1:
                    pos += f".align_to(({_num(ux(left) + 0.08)}, 0, 0), LEFT)"
                elif align == PP_ALIGN.RIGHT:
                    pos += f".align_to(({_num(ux(left + width) - 0.08)}, 0, 0), RIGHT)"
                lines.append(f'self.add(Text({wrapped!r}, {", ".join(kw)}){pos}{rot_code})  # manimble')

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
