"""Dark mode and inverted colours, written into the deck.

mode "dark": flip near-white and near-black colours, keep every other colour.  The map is the same one the macOS canvas applies on the GPU for its visual-only dark mode
(`fs_tex_dark` in CanvasView.swift): a colour's HSL lightness is mirrored (L -> 1 - L, hue and
saturation kept) in proportion to how neutral it is.  Pure greys become their complement
(#FFFFFF <-> #000000, #BBBBBB <-> #444444); saturated colours are left alone.

mode "invert": every colour becomes its complement (1 - c), like the display's Invert Colors
(`fs_tex_invert` in CanvasView.swift).

`plan_literals` turns that map into source edits: neutral hex strings and manim's grey names
(WHITE, BLACK, GRAY_A ... GRAY_E, LIGHT_GRAY, ...; for "invert" every manim colour name) anywhere in the deck, plus manim.cfg's
background colour.  Objects that take a neutral *default* colour (e.g. Text with no color=)
are found afterwards by re-rendering, see Manimble.dark_mode in core.py.
"""

from __future__ import annotations

import ast
import os
import re

from .srcedit import Edit, Project

# chroma (max - min) below LO is fully flipped, above HI is kept; keep in sync with CanvasView.swift
CHROMA_LO, CHROMA_HI = 0.12, 0.28

HEX = re.compile(r"#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})")

# manim's neutral colour names and the name of their complement (exact: #DDDDDD <-> #222222, ...)
_GREYS = [("WHITE", "BLACK"), ("GRAY_A", "GRAY_E"), ("GRAY_B", "GRAY_D"),
          ("LIGHTER_GRAY", "DARKER_GRAY"), ("LIGHT_GRAY", "DARK_GRAY")]
NAME_SWAP: dict = {}
for _a, _b in _GREYS:
    for a, b in ((_a, _b), (_a.replace("GRAY", "GREY"), _b.replace("GRAY", "GREY"))):
        NAME_SWAP[a], NAME_SWAP[b] = b, a


def _smoothstep(a: float, b: float, x: float) -> float:
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def map_rgb(r: float, g: float, b: float, mode: str = "dark") -> tuple[float, float, float]:
    if mode == "invert":
        return 1 - r, 1 - g, 1 - b
    mx, mn = max(r, g, b), min(r, g, b)
    w = 1.0 - _smoothstep(CHROMA_LO, CHROMA_HI, mx - mn)
    k = w * (1.0 - mx - mn)
    return r + k, g + k, b + k


def map_hex(h: str, mode: str = "dark") -> str:
    """'#RRGGBB' or '#RGB' -> mapped '#RRGGBB' (upper case)."""
    s = h.lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    r, g, b = (int(s[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return "#" + "".join(f"{round(min(max(v, 0.0), 1.0) * 255):02X}" for v in map_rgb(r, g, b, mode))


def changes(h: str, mode: str = "dark") -> bool:
    s = h.lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    return map_hex(h, mode) != "#" + s.upper()


def _cfg_background(deck: str):
    """(path, text, (start, end) of the value or None, value) for manim.cfg's [CLI] background_color."""
    path = os.path.join(deck, "manim.cfg")
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    section = None
    pos = 0                                        # byte offset of the line (Edit offsets are bytes)
    for line in text.splitlines(keepends=True):
        m = re.match(r"\s*\[([^\]]+)\]", line)
        if m:
            section = m.group(1).strip()
        elif section == "CLI":
            m = re.match(r"\s*background_color\s*[=:]\s*[\"']?([#\w]+)", line)
            if m:
                a = pos + len(line[:m.start(1)].encode("utf-8"))
                return path, text, (a, a + len(m.group(1).encode("utf-8"))), m.group(1)
        pos += len(line.encode("utf-8"))
    return path, text, None, None


def plan_literals(project: Project, deck: str, mode: str = "dark", named: dict | None = None) -> tuple[list[Edit], int]:
    """Edits that map every colour written in the deck; (edits, count).

    named: manim's colour names -> #RRGGBB, needed for "invert" (BLUE becomes the hex of its complement)."""
    named = named or {}

    def name_edit(name: str, quote: str = '"') -> str | None:
        if name in NAME_SWAP:
            return NAME_SWAP[name]
        if mode == "invert" and name in named:
            return f"{quote}{map_hex(named[name], mode)}{quote}"
        return None
    edits: list[Edit] = []
    srcs = []
    for rel in project.py_files():
        try:
            srcs.append(project.src(rel))
        except SyntaxError:
            continue
    # the deck's own WHITE/BLACK/... (rare) are not manim's colours
    own = {t.id for src in srcs for n in ast.walk(src.tree) if isinstance(n, (ast.Assign, ast.AnnAssign))
           for t in (n.targets if isinstance(n, ast.Assign) else [n.target]) if isinstance(t, ast.Name)}
    for src in srcs:
        rel = src.rel
        for node in ast.walk(src.tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and HEX.fullmatch(node.value):
                if isinstance(src.parent.get(node), ast.Expr) or not changes(node.value, mode):
                    continue
                a, b = src.span(node)
                quote = src.data[a:a + 1].decode("utf-8", "replace")
                quote = quote if quote in ("'", '"') else '"'
                edits.append(Edit(rel, a, b, f"{quote}{map_hex(node.value, mode)}{quote}"))
            elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id not in own:
                new = name_edit(node.id)
                if new:
                    a, b = src.span(node)
                    edits.append(Edit(rel, a, b, new))
    # the deck-wide background (manim's default is black)
    path, text, span, value = _cfg_background(deck)
    rel = os.path.relpath(path, project.dir)
    if span is not None:
        v = value.upper()
        if v in NAME_SWAP or v in named:
            new = name_edit(v, quote="")
        elif HEX.fullmatch(v):
            new = map_hex(v, mode) if changes(v, mode) else None
        else:
            new = None
        if new:
            edits.append(Edit(rel, span[0], span[1], new))
    else:
        bg = map_hex("#000000", mode)
        if re.search(r"^\s*\[CLI\]\s*$", text, re.M):
            m = re.search(r"^\s*\[CLI\]\s*\n?", text, re.M)
            edits.append(Edit(rel, m.end(), m.end(), f"background_color = {bg}\n"))
        else:
            sep = "" if not text or text.endswith("\n") else "\n"
            edits.append(Edit(rel, len(text.encode("utf-8")), len(text.encode("utf-8")), f"{sep}[CLI]\nbackground_color = {bg}\n"))
    return edits, len(edits)
