"""Deck themes: the common.py files in manimble/themes, and switching an open deck to one of them.

A theme is a set of top-level constants (THEME, BACKGROUND, FONT, TEXT_COLOR, MUTED_COLOR, ACCENT; see
themes/README.md). Applying one rewrites those constants wherever the deck defines them, adds the missing ones to
common.py, and sets manim.cfg's background. Text written with color=TEXT_COLOR / font=FONT (new decks, and what
Manimble inserts into a themed deck) follows at once. When the background goes from dark to light or back, `flip`
first writes dark mode (darkmode.py) so plain WHITE / BLACK text and default-coloured objects stay readable.
"""
from __future__ import annotations

import ast
import os
import re

from . import darkmode as dm
from .srcedit import Edit, py_str

DIR = os.path.join(os.path.dirname(__file__), "themes")
KEYS = ("THEME", "BACKGROUND", "FONT", "TEXT_COLOR", "MUTED_COLOR", "ACCENT")
SLIDE_KEYS = ("FONT", "TEXT_COLOR", "MUTED_COLOR", "ACCENT")
# A theme on one slide only: a line at the top of its construct() that shadows the deck's constants, e.g.
#     FONT, TEXT_COLOR, MUTED_COLOR, ACCENT = "Georgia", "#1D1D1F", "#6E6E73", "#0A66C2"  # manimble theme "Paper"
# next to a Format Background line with the theme's background.
MARK = "# manimble theme"


def load(theme_id: str) -> dict:
    """{constant: value} of themes/<theme_id>.py."""
    if not re.fullmatch(r"[\w-]+", theme_id or ""):
        raise ValueError(f"no theme {theme_id!r}")
    path = os.path.join(DIR, theme_id + ".py")
    if not os.path.exists(path):
        raise ValueError(f"no theme {theme_id!r}")
    tree = ast.parse(open(path, encoding="utf-8").read())
    out = {}
    for st in tree.body:
        if (isinstance(st, ast.Assign) and len(st.targets) == 1 and isinstance(st.targets[0], ast.Name)
                and st.targets[0].id in KEYS and isinstance(st.value, ast.Constant)):
            out[st.targets[0].id] = st.value.value
    out["_id"] = theme_id
    if "THEME" not in out or not dm.HEX.fullmatch(str(out.get("BACKGROUND", ""))):
        raise ValueError(f"theme {theme_id!r} lacks THEME or BACKGROUND")
    return out


def is_light(color: str | None) -> bool:
    """A background colour (manim.cfg value: hex or a manim name; manim's default is black) reads as light."""
    c = (color or "#000000").strip("\"'")
    if not dm.HEX.fullmatch(c):
        return c.upper() in ("WHITE", "GRAY_A", "GREY_A", "LIGHTER_GRAY", "LIGHTER_GREY", "LIGHT_GRAY", "LIGHT_GREY")
    s = c.lstrip("#")
    s = "".join(ch * 2 for ch in s) if len(s) == 3 else s
    r, g, b = (int(s[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5


def _deck_theme(m) -> str | None:
    hits = m.project.top_level_assigns("THEME")
    return hits[0][1].value if hits and isinstance(hits[0][1], ast.Constant) else None


def _slide_lines(src, fn) -> list:
    """[(start, end, text)] of construct()'s top-level statements holding a slide's own theme."""
    out = []
    for st in fn.body:
        a = src.line_starts[st.lineno - 1]
        b = src.line_starts[st.end_lineno] if st.end_lineno < len(src.line_starts) else len(src.data)
        text = src.data[a:b].decode("utf-8")
        if MARK in text:
            out.append((a, b, text))
    return out


def slide_theme(m, name: str) -> str | None:
    """The THEME name a slide has on its own, None when it follows the deck."""
    try:
        src, fn = m._construct(m.scene(name))
    except Exception:                                # noqa: BLE001
        return None
    for _, _, text in _slide_lines(src, fn):
        found = re.search(re.escape(MARK) + r' "([^"]*)"', text)
        if found:
            return found.group(1)
    return None


def plan_slide(m, s: dict, values: dict | None) -> list[Edit]:
    """Edits that give one slide (scene record `s`) the theme `values` on its own, replacing any theme or
    background it had; values=None (or the deck's own theme) leaves only the deck's."""
    src, fn = m._construct(s)
    old = sorted(_slide_lines(src, fn) + m._bg_statements(src, fn))
    lines = []
    if values is not None and values["THEME"] != _deck_theme(m):
        keys = [k for k in SLIDE_KEYS if k in values]
        if keys:
            lines.append(f"{', '.join(keys)} = {', '.join(py_str(values[k]) for k in keys)}  {MARK} {py_str(values['THEME'])}")
        lines.append(f"self.camera.background_color = {py_str(values['BACKGROUND'])}  {m.BG_MARK}")
    body = fn.body
    first = body[0]
    doc = isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str)
    indent = " " * first.col_offset
    new = "".join(f"{indent}{ln}\n" for ln in lines)
    if old:
        edits = [Edit(src.rel, old[0][0], old[0][1], new)]
        return edits + [Edit(src.rel, a, b, "") for a, b, _ in old[1:]]
    if not new:
        return []
    if doc and len(body) == 1:                       # only a docstring: after it
        at = src.line_starts[first.end_lineno] if first.end_lineno < len(src.line_starts) else len(src.data)
    else:
        at = src.line_starts[(body[1] if doc else first).lineno - 1]
    return [Edit(src.rel, at, at, new)]


def preview(m, req: dict) -> dict:
    """Render slide `scene` as it would look with theme `theme` (the whole deck's, or with slide_only the slide's
    own) without touching the deck; {"ok", "png"} with the slide's last build."""
    try:
        values = load(str(req.get("theme") or ""))
        s = m.scene(req["scene"])
    except (ValueError, KeyError) as exc:
        return {"ok": False, "error": str(exc)}
    m.refresh_scenes()
    force = bool(req.get("slide_only")) or slide_theme(m, s["name"]) is not None   # deck-wide drops the slide's own
    # a folder per theme and mode: the app may still be reading one preview while the next renders
    out = m.cache_dir / "theme-preview" / s["name"] / (values["_id"] + ("-slide" if req.get("slide_only") else "")
                                                       + ("-flip" if req.get("flip") else ""))
    res = m.aux_worker.request({"cmd": "render", "scene": s["name"], "module": s["module"], "out": str(out),
                                "constants": {k: values[k] for k in SLIDE_KEYS if k in values},
                                "background": values["BACKGROUND"], "force_background": force,
                                "slide_only": bool(req.get("slide_only")),
                                # with "swap whites and blacks": only when the deck's background goes dark <-> light
                                "flip": bool(req.get("flip")) and not req.get("slide_only")
                                and is_light(dm._cfg_background(m.deck)[3]) != is_light(values["BACKGROUND"])})
    if "error" in res:
        return {"ok": False, "error": res["error"][-300:]}
    if not res.get("stops"):
        return {"ok": False, "error": "the slide shows nothing"}
    return {"ok": True, "png": str(out / res["stops"][-1]["png"])}


def plan(m, values: dict) -> list[Edit]:
    """Edits that give the deck these theme constants and manim.cfg background, and drop slides' own themes."""
    edits, missing = [], []
    for s in m.scenes:
        try:
            src, fn = m._construct(s)
        except Exception:                            # noqa: BLE001
            continue
        if _slide_lines(src, fn):
            edits += plan_slide(m, s, None)
    for key in KEYS:
        if key not in values:
            continue
        hits = m.project.top_level_assigns(key)
        if not hits:
            missing.append(key)
        for src, node in hits:
            if isinstance(node, ast.Constant) and node.value != values[key]:
                edits.append(Edit(src.rel, *src.span(node), py_str(values[key])))
    if missing:
        try:
            src = m.project.src("common.py")
        except (FileNotFoundError, SyntaxError):
            raise ValueError("the deck has no common.py to hold its theme") from None
        imports = [st for st in src.tree.body if isinstance(st, (ast.Import, ast.ImportFrom))]
        at = src.line_starts[imports[-1].end_lineno] if imports and imports[-1].end_lineno < len(src.line_starts) else 0
        block = "".join(f"{k} = {py_str(values[k])}\n" for k in missing)
        edits.append(Edit("common.py", at, at, ("\n" if imports else "") + block + ("" if imports else "\n")))
    try:                                             # the docstring a theme file starts with names the theme
        src = m.project.src("common.py")
        doc = re.search(rb'Manimble theme "[^"\n]*": [^)\n]*', src.data)
        about = re.search(r'Manimble theme "[^"]*": [^)]*', open(os.path.join(DIR, values["_id"] + ".py"), encoding="utf-8").read())
        if doc and about and doc.group().decode("utf-8") != about.group():
            edits.append(Edit("common.py", doc.start(), doc.end(), about.group()))
    except (FileNotFoundError, SyntaxError, KeyError):
        pass
    path, text, span, value = dm._cfg_background(m.deck)
    rel = os.path.relpath(path, m.project.dir)
    bg = values["BACKGROUND"]
    if span is not None:
        if value.upper() != bg.upper():
            edits.append(Edit(rel, span[0], span[1], bg))
    elif re.search(r"^\s*\[CLI\]\s*$", text, re.M):
        e = re.search(r"^\s*\[CLI\]\s*\n?", text, re.M).end()
        edits.append(Edit(rel, e, e, f"background_color = {bg}\n"))
    else:
        n = len(text.encode("utf-8"))
        edits.append(Edit(rel, n, n, ("" if not text or text.endswith("\n") else "\n") + f"[CLI]\nbackground_color = {bg}\n"))
    return edits


def apply(m, req: dict) -> dict:
    """Switch the deck to theme `theme` (a file name in themes/) as one undo step. op=get reports the deck's
    current THEME and whether switching to `theme` crosses between a dark and a light background."""
    try:
        values = load(str(req.get("theme") or "")) if req.get("theme") else None
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}
    current = req.get("current")
    cur_bg = dm._cfg_background(m.deck)[3]
    if req.get("op") == "get":
        return {"ok": True, "theme": _deck_theme(m), "slide_theme": slide_theme(m, current) if current else None,
                "crosses": values is not None and is_light(cur_bg) != is_light(values["BACKGROUND"])}
    if req.get("op") == "preview":
        return preview(m, req)
    if values is None:
        return {"ok": False, "error": "no theme given"}
    if req.get("slide_only"):
        return _apply_slide(m, values, current)
    m.job_start()                                    # the app's X cancels the switch (nothing is kept)
    dark = None                                      # dark mode's undo entry, folded into this one
    if req.get("flip") and is_light(cur_bg) != is_light(values["BACKGROUND"]):
        seq = m._undo_seq
        res = m.dark_mode({"mode": "dark", "current": current, "_nested": True})
        if not res.get("ok"):
            return res
        if m._undo_seq != seq and m.history and m.history[-1]["seq"] == m._undo_seq:
            dark = m.history.pop()
    with m.edit_lock:
        m._settle()
        m.refresh_scenes()
        if m._cancel.is_set():
            if dark:
                m._restore(dark["files"], 0)
                m.refresh_scenes()
                m.enqueue_all()
            return {"ok": False, "error": "cancelled"}
        try:
            edits = plan(m, values)
            written = m.project.apply(edits) if edits else {}
        except Exception as exc:                     # noqa: BLE001
            if dark:
                m._restore(dark["files"], 0)
            return {"ok": False, "error": f"could not apply the theme: {exc}"}
        m._sig_at = 0
        if "manim.cfg" in written:
            m._restart_workers()
        m.refresh_scenes()
        if current:
            rec = m.render_now(current, interactive=True)
            if "error" in rec:
                m._restore(written, 0)
                if dark:
                    m._restore(dark["files"], 0)
                m.refresh_scenes()
                m.enqueue_all()
                if rec.get("cancelled"):
                    return {"ok": False, "error": "cancelled"}
                return {"ok": False, "error": "the slide stops rendering with this theme: " + rec["error"][-300:]}
        if dark:
            for rel, (b, a) in dark["files"].items():
                written[rel] = (b, written[rel][1]) if rel in written else (b, a)
        if not written:
            return {"ok": True, "message": "no change"}
        m._commit(f"theme {values['THEME']}", written)
        m.refresh_scenes()
        if current:
            m.enqueue(current, front=True)
        m.enqueue_all()
        msg = f"theme {values['THEME']}"
        if dark:
            msg += ", whites and blacks swapped"
        return {"ok": True, "message": msg, "changed": m.last_changed}


def _apply_slide(m, values: dict, current: str | None) -> dict:
    """Give slide `current` the theme on its own (one undo step); the deck's own theme takes it back to the deck's."""
    if not current:
        return {"ok": False, "error": "no slide selected"}
    with m.edit_lock:
        m._settle()
        m.refresh_scenes()
        try:
            edits = plan_slide(m, m.scene(current), values)
            written = m.project.apply(edits) if edits else {}
        except Exception as exc:                     # noqa: BLE001
            return {"ok": False, "error": f"could not apply the theme: {exc}"}
        if not written:
            return {"ok": True, "message": "no change"}
        m._sig_at = 0
        m.refresh_scenes()
        rec = m.render_now(current, interactive=True)
        if "error" in rec:
            m._restore(written, 0)
            m.refresh_scenes()
            m.render_now(current, interactive=True)
            return {"ok": False, "error": "the slide stops rendering with this theme: " + rec["error"][-300:]}
        m._commit(f"theme {values['THEME']} on {current}", written)
        m.refresh_scenes()
        m.enqueue_all()
        return {"ok": True, "message": f"theme {values['THEME']} on this slide", "changed": m.last_changed}
