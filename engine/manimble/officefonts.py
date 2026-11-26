"""Fonts that come with Microsoft Office: Aptos (Office's default since 2023), Aptos Display, Calibri, Cambria, ...

They are not installed system-wide. Office keeps them in its own folders: the fonts it ships inside each app
(macOS: Microsoft PowerPoint.app/Contents/Resources/DFonts) and the "cloud fonts" it downloads when a document uses
them (Aptos Display, Aptos Serif, ...: one folder per family, files with numbers for names). `install()` makes them
available to manim in this process, so a slide in Aptos is drawn in Aptos rather than a substitute; the render worker
and slides_render.py call it before any text is drawn (Pango reads its fonts once).

On macOS, Core Text files Aptos Display's faces under the family "Aptos" with "Display" for a style, so Pango can't
find a family called "Aptos Display", the heading font of Office's default theme. `install()` therefore also draws a
family Pango can't find with its nearest installed relative (ALIASES): the code keeps `font="Aptos Display"`, which
PowerPoint and Keynote exports pass on, and only the drawing uses Aptos.
"""
from __future__ import annotations

import glob
import os
import re
from pathlib import Path

from .hostpaths import MACOS, WINDOWS

FONT_SUFFIXES = (".ttf", ".otf", ".ttc")
# a family Pango can't find -> the families to draw it with instead, the first available. Aptos's weights (Light,
# SemiBold, ...) are faces of the family "Aptos" too; written as families, as Office lists them, they draw in Aptos.
ALIASES = {"aptos display": ("Aptos",), "aptos light": ("Aptos",), "aptos semibold": ("Aptos",),
           "aptos extrabold": ("Aptos",), "aptos black": ("Aptos",)}

_installed = False


def font_dirs() -> list[str]:
    """Folders of Office's fonts on this machine: those shipped with its apps, then its downloaded cloud fonts."""
    if MACOS:
        shipped = sorted(glob.glob("/Applications/Microsoft *.app/Contents/Resources/DFonts"))
        cloud = Path.home() / "Library/Group Containers/UBF8T346G9.Office/FontCache/4/CloudFonts"
    elif WINDOWS:
        shipped = []                                    # Office installs its own fonts system-wide on Windows
        cloud = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))) / "Microsoft/FontCache/4/CloudFonts"
    else:
        return []
    return shipped + sorted(str(d) for d in cloud.glob("*") if d.is_dir())


def font_files() -> list[str]:
    """Office's font files, each once (every Office app ships the same fonts)."""
    seen, out = set(), []
    for d in font_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.lower().endswith(FONT_SUFFIXES):
                # a cloud font's file names are numbers, unique only within its family's folder
                key = n.lower() if "CloudFonts" not in d else f"{Path(d).name}/{n}".lower()
                if key not in seen:
                    seen.add(key)
                    out.append(os.path.join(d, n))
    return out


def cloud_family(path: str) -> str | None:
    """The family a cloud font file belongs to (its folder's name), or None for another file."""
    p = Path(path)
    return p.parent.name if p.parent.parent.name == "CloudFonts" else None


def resolve(family: str, available) -> str:
    """The family to draw `family` with: itself when Pango has it (or there is no alias), else its alias."""
    if not family or family in available:
        return family
    for alt in ALIASES.get(family.lower(), ()):
        if alt in available:
            return alt
    return family


def install() -> list[str]:
    """Register Office's fonts for manim in this process, and draw the families Pango can't find with their
    aliases. Idempotent; returns the files registered. Call it before any text is drawn."""
    global _installed
    if _installed:
        return []
    _installed = True
    try:
        import manimpango
    except Exception:                                   # noqa: BLE001
        return []
    try:
        before = {f.lower() for f in manimpango.list_fonts()}
    except Exception:                                   # noqa: BLE001
        before = set()
    done = []
    for f in font_files():
        try:
            manimpango.register_font(f)
            done.append(f)
        except Exception:                               # noqa: BLE001
            pass
    try:
        available = set(manimpango.list_fonts())
    except Exception:                                   # noqa: BLE001
        available = set()
    _alias_in_manim(available)
    # families drawn differently from before: Office's (Pango substituted another font) and the aliased ones
    _new_cache_names({f.lower() for f in available} - before | set(ALIASES))
    return done


CACHE_TAG = "officefonts-1"


def _new_cache_names(families: set) -> None:
    """manim keeps each drawn text as an SVG named by a hash of the text and its font's name, and draws it again only
    when no such file exists. A text in one of `families` was drawn with a substitute font before its font was
    registered, under the same name: hash those with CACHE_TAG too, so they are drawn again in their own font."""
    import hashlib

    from manim.mobject.text import text_mobject as tm

    for cls in (tm.Text, tm.MarkupText):
        original = cls._text2hash
        if getattr(original, "_manimble_tagged", False):
            continue

        def tagged(self, color, _original=original):
            h = _original(self, color)
            fonts = {str(self.font or "").lower()} | {str(f).lower() for f in (getattr(self, "t2f", None) or {}).values()}
            if fonts & families:
                return hashlib.sha256((h + CACHE_TAG).encode()).hexdigest()[:16]
            return h
        tagged._manimble_tagged = True
        cls._text2hash = tagged


_MARKUP_FONT = re.compile(r'\b(font_family|face)=(["\'])(.*?)\2')


def _alias_in_manim(available: set) -> None:
    """Pass manim's text to Pango with each family resolved (see resolve): Text through manimpango.text2svg,
    MarkupText (and its <span font_family=...>) through MarkupUtils.text2svg."""
    import manimpango
    from manimpango import MarkupUtils

    def fix(family):
        return resolve(family, available)

    text2svg = manimpango.text2svg
    if not getattr(text2svg, "_manimble_aliases", False):
        def text2svg_aliased(settings, *args, **kwargs):
            for s in settings:
                s.font = fix(s.font)
            return text2svg(settings, *args, **kwargs)
        text2svg_aliased._manimble_aliases = True
        manimpango.text2svg = text2svg_aliased

    markup2svg = MarkupUtils.text2svg
    if not getattr(markup2svg, "_manimble_aliases", False):
        def markup2svg_aliased(text, font, *args, **kwargs):
            text = _MARKUP_FONT.sub(lambda m: f"{m.group(1)}={m.group(2)}{fix(m.group(3))}{m.group(2)}", text)
            return markup2svg(text, fix(font), *args, **kwargs)
        markup2svg_aliased._manimble_aliases = True
        MarkupUtils.text2svg = staticmethod(markup2svg_aliased)
