"""Manim-side worker for manimble.

Runs inside an environment that has Manim installed.  It speaks JSON lines on
stdin/stdout and answers two kinds of requests:

  {"cmd": "render", "scene": "Intro", "module": "slides", "out": "/dir"}
      Execute the scene with animations skipped, snapshot every slide stop to
      PNG, and report every Text / MathTex / ImageMobject that was created
      together with the source-code call sites needed to edit it.

  {"cmd": "latex", "tex": "..."}
      Compile a LaTeX snippet (for the formula editor preview) and return SVG.

Everything the editor learns about the deck is gathered here by *tracing* the
real execution of the user's code: which source line created each object, and
which positioning calls (move_to / shift / next_to / set ...) shaped it.
"""

from __future__ import annotations

import hashlib
import importlib
import itertools
import linecache
import json
import math
import os
import sys
import traceback
import types
import functools

DECK = os.path.realpath(sys.argv[1])
os.chdir(DECK)
sys.path.insert(0, DECK)
# Always compile the deck from source: Python validates cached bytecode by mtime (seconds) and size, so an edit that
# keeps a file's length (e.g. one digit in a coordinate) within the same second would otherwise run the old code.
sys.dont_write_bytecode = True
sys.pycache_prefix = os.path.join(os.environ.get("TMPDIR", "/tmp"), "manimble-no-pycache")
MEDIA_DIR = os.path.abspath(os.environ.get("MANIMBLE_MEDIA_DIR", os.path.join(DECK, "..", "media")))
MEDIA_DIR_REAL = os.path.realpath(MEDIA_DIR)
DEPENDENCIES: set[str] = set()

# stdout carries the protocol; anything else printing must go to stderr.
_proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
sys.stdout = sys.stderr

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

from manim import config, Scene, Mobject, Text, MathTex, Tex, ImageMobject, Camera, ORIGIN  # noqa: E402
from manim import Paragraph, BackgroundRectangle, VMobject  # noqa: E402
from manim import (FadeIn, FadeOut, Create, Uncreate, Write, Unwrite, DrawBorderThenFill, GrowFromCenter,  # noqa: E402
                   GrowFromPoint, GrowFromEdge, GrowArrow, SpinInFromNothing, ReplacementTransform,
                   TransformFromCopy, AnimationGroup, LaggedStart, Transform, MoveToTarget,
                   Indicate, Flash, Circumscribe, Wiggle, FocusOn)
from manim.animation.transform import _MethodAnimation  # noqa: E402
from manim.animation.transform_matching_parts import TransformMatchingAbstractBase  # noqa: E402
from manim.utils.family import extract_mobject_family_members  # noqa: E402
from manim.utils.iterables import list_update  # noqa: E402
from manim.mobject.mobject import _AnimationBuilder  # noqa: E402


def _track_project_reads(event, args):
    """Record files opened by deck code outside the selected deck directory."""
    if event != "open" or not args or isinstance(args[0], int):
        return
    mode = args[1] if len(args) > 1 else None
    flags = args[2] if len(args) > 2 and isinstance(args[2], int) else 0
    if (mode is not None and any(c in str(mode) for c in "wax+")) or flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
        return
    try:
        path = os.path.abspath(os.fsdecode(os.fspath(args[0])))
    except (TypeError, ValueError):
        return
    if path == DECK or path.startswith(DECK + os.sep):
        return
    if any(path == media_root or path.startswith(media_root + os.sep)
           for media_root in {MEDIA_DIR, MEDIA_DIR_REAL}):
        return
    trusted_roots = (sys.prefix, sys.base_prefix, "/System", "/Library", "/usr", "/opt/homebrew", "/Applications")
    if any(path == root or path.startswith(root.rstrip(os.sep) + os.sep) for root in trusted_roots):
        return

    # Only treat an open as a deck dependency when the active Python call stack
    # came from a source file in the deck. This avoids collecting Manim's own
    # font, package, and renderer reads.
    frame = sys._getframe(1)
    from_deck = False
    while frame is not None:
        filename = os.path.abspath(frame.f_code.co_filename)
        if filename == DECK or filename.startswith(DECK + os.sep):
            from_deck = True
            break
        frame = frame.f_back
    if not from_deck:
        return

    # The working project root contains symlinks to the original project's
    # siblings; preserve those lexical paths so the portable copy can retain
    # the same relative layout.
    DEPENDENCIES.add(path)


sys.addaudithook(_track_project_reads)

config.verbosity = "ERROR"
config.progress_bar = "none"
config.disable_caching = True
config.write_to_movie = False
config.save_last_frame = False
config.preview = False
config.media_dir = os.path.realpath(MEDIA_DIR)

# ----------------------------------------------------------------- tracing

SEQ = itertools.count(1)
TRACKED: list = []          # tracked mobjects of the current run, oid == index
# Side tables keyed by id(); the tuples hold a reference so ids stay unique.
# (Attributes on the mobjects themselves would be deep-copied by manim.)
EVENTS: dict = {}           # id(mob) -> (mob, [event, ...])
PARENTS: dict = {}          # id(mob) -> (mob, [(parent, seq_joined), ...])
_pos_cache: dict = {}
_building = {"on": False}


def in_project(filename: str) -> bool:
    return filename.startswith(DECK + os.sep)


def frame_pos(f):
    code = f.f_code
    table = _pos_cache.get(code)
    if table is None:
        table = _pos_cache[code] = list(code.co_positions())
    i = f.f_lasti // 2
    if i < len(table):
        l, el, c, ec = table[i]
        if l is not None and c is not None:
            return [l, c, el, ec]
    return None


def project_stack(f):
    """Project (deck) frames, innermost first."""
    out = []
    while f is not None:
        fn = f.f_code.co_filename
        if in_project(fn):
            pos = frame_pos(f)
            if pos:
                out.append({"file": os.path.relpath(fn, DECK), "func": f.f_code.co_name, "pos": pos})
        f = f.f_back
    return out


def jsonable(v):
    if isinstance(v, (bool, int, float, str)) or v is None:
        return v
    if isinstance(v, np.generic):
        return v.item()
    if isinstance(v, np.ndarray):
        return [float(x) for x in v.tolist()] if v.ndim == 1 else None
    if isinstance(v, (list, tuple)):
        out = [jsonable(x) for x in v]
        return out
    if isinstance(v, Mobject):
        return {"mobject": True}
    return None


def record_event(mob, method, args, kwargs, frame):
    if not in_project(frame.f_code.co_filename):
        return
    stack = project_stack(frame)
    if not stack:
        return
    ev = {
        "seq": next(SEQ),
        "method": method,
        "args": [jsonable(a) for a in args],
        "kwargs": {k: jsonable(v) for k, v in kwargs.items()},
        "frames": stack,
    }
    EVENTS.setdefault(id(mob), (mob, []))[1].append(ev)


LAYOUT_METHODS = [
    "shift", "move_to", "next_to", "to_edge", "to_corner", "align_to", "arrange",
    "arrange_in_grid", "scale", "set_width", "set_height", "scale_to_fit_width",
    "scale_to_fit_height", "stretch_to_fit_width", "stretch_to_fit_height", "set", "put_start_and_end_on",
    "rotate", "set_x", "set_y", "align_on_border",
]


def _wrap_method(cls, name):
    orig = getattr(cls, name, None)
    if orig is None:
        return

    @functools.wraps(orig)
    def wrapper(self, *a, **k):
        try:
            record_event(self, name, a, k, sys._getframe(1))
        except Exception:
            pass
        return orig(self, *a, **k)

    setattr(cls, name, wrapper)


def _all_subclasses(cls):
    out, stack = [], [cls]
    while stack:
        for sub in stack.pop().__subclasses__():
            if sub not in out:
                out.append(sub)
                stack.append(sub)
    return out


for _m in LAYOUT_METHODS:
    _wrap_method(Mobject, _m)
# Subclasses that override a layout method (VMobject.rotate / .scale, Line.put_start_and_end_on, Table.scale, ...)
# would otherwise call the Mobject wrapper from manim's own code, where the deck frame is no longer visible.
for _cls in _all_subclasses(Mobject):
    for _m in LAYOUT_METHODS:
        if _m in _cls.__dict__:
            _wrap_method(_cls, _m)

_orig_add = Mobject.add


def _add(self, *mobjects):
    for m in mobjects:
        if isinstance(m, Mobject):
            PARENTS.setdefault(id(m), (m, []))[1].append((self, next(SEQ)))
    return _orig_add(self, *mobjects)


Mobject.add = _add

# ``x.animate.shift(...)`` builds the call lazily on a copy; record it on x.
_orig_ab_getattr = _AnimationBuilder.__getattr__


def _ab_getattr(self, method_name):
    fn = _orig_ab_getattr(self, method_name)
    if method_name not in LAYOUT_METHODS:
        return fn
    mob = self.mobject

    def wrapped(*a, **k):
        try:
            record_event(mob, method_name, a, k, sys._getframe(1))
            EVENTS[id(mob)][1][-1]["animated"] = True
        except Exception:
            pass
        return fn(*a, **k)

    return wrapped


_AnimationBuilder.__getattr__ = _ab_getattr


def _track(kind, cls, value_of, only=None):
    """Report every construction of cls by deck code; `only(mobject, source_line)` can restrict that further."""
    orig_init = cls.__init__

    @functools.wraps(orig_init)
    def init(self, *a, **k):
        orig_init(self, *a, **k)
        try:
            caller = sys._getframe(1)
            # Only objects constructed directly by deck code are editable.
            if not in_project(caller.f_code.co_filename):
                return
            if "_sl_id" in self.__dict__:
                return
            stack = project_stack(caller)
            if not stack or any(fr["func"] == "setup" for fr in stack):
                return
            linecache.checkcache(caller.f_code.co_filename)       # the deck changes between renders
            source_line = linecache.getline(caller.f_code.co_filename, caller.f_lineno)
            if "# manimble background" in source_line:
                return            # a slide background is part of the backdrop, not an editable object
            if only is not None and not only(self, source_line):
                return
            self._sl_id = len(TRACKED)
            self._sl_kind = kind
            self._sl_frames = stack
            self._sl_value = value_of(self, a, k)
            self._sl_born = next(SEQ)
            fs = text_attr(self, "font_size") if kind in ("text", "tex") else None
            self._sl_font0 = float(fs) if fs is not None else None
            TRACKED.append(self)
        except Exception:
            traceback.print_exc()

    cls.__init__ = init


_track("text", Text, lambda s, a, k: str(a[0]) if a else str(k.get("text", s.text)))
# Paragraph (one positional string per line, alignment=...) is how Manimble writes aligned multi-line text.
_track("text", Paragraph, lambda s, a, k: "\n".join(str(x) for x in a))
_track("tex", MathTex, lambda s, a, k: "".join(s.tex_strings))
def _track_shapes():
    import inspect
    import manim.mobject.geometry.arc as arc
    import manim.mobject.geometry.line as line
    import manim.mobject.geometry.polygram as poly
    import manim.mobject.geometry.shape_matchers as sm
    from manim import Line as L
    for mod in (arc, line, poly, sm):
        for _, cls in inspect.getmembers(mod, inspect.isclass):
            if cls.__module__ != mod.__name__ or "__init__" not in cls.__dict__:
                continue
            if cls.__name__ in ("TipableVMobject", "LabeledLine", "LabeledArrow", "LabeledPolygram", "Polygram",
                                "ArcPolygon", "ArcPolygonFromArcs", "CurvedArrow", "CurvedDoubleArrow"):
                continue
            _track("line" if issubclass(cls, L) else "shape", cls, lambda s, a, k: type(s).__name__)


def _track_tables():
    import manim.mobject.table as tb
    import json as _json
    for name in ("Table", "MathTable", "MobjectTable", "IntegerTable", "DecimalTable"):
        cls = getattr(tb, name, None)
        if cls is None or "__init__" not in cls.__dict__:
            continue

        def value_of(s, a, k):
            data = a[0] if a else k.get("table")
            try:
                return _json.dumps([[str(c) if not isinstance(c, (int, float)) else c for c in row] for row in data])
            except Exception:
                return "[]"
        _track("table", cls, value_of)


_track_shapes()
_track_tables()
_track("image", ImageMobject, lambda s, a, k: str(a[0]) if a else str(k.get("filename_or_array", "")))
# A freehand pen stroke Manimble wrote (`VMobject(...).set_points_smoothly(...)  # manimble pen`): a plain VMobject,
# tracked only on that marked line so groups and the VMobjects inside Text and shapes stay untouched.
_track("shape", VMobject, lambda s, a, k: "Pen", only=lambda s, line: type(s) is VMobject and "# manimble pen" in line)
# Tex (plain LaTeX text) is a MathTex subclass in manim and is tracked as such.

# ------------------------------------------------------------ fake Slide

_STATE = {"stops": [], "out": None, "scene": None}


class Slide(Scene):
    """Stand-in for manim_slides.Slide: each next_slide() is a recorded stop."""

    _sl_dirty = False

    def next_slide(self, *a, **k):
        if not self._sl_dirty and not _STATE["stops"]:
            return            # options for the first build (e.g. notes=...) before anything is drawn: not a stop
        stack = project_stack(sys._getframe(1))
        self._sl_stop(stack[-1] if stack else None)

    def start_loop(self, *a, **k):
        pass

    def end_loop(self, *a, **k):
        pass

    def play(self, *a, **k):
        self._sl_dirty = True
        if not REAL_PLAY and self._fast_play(a):
            return None
        return super().play(*a, **k)

    def _fast_play(self, anims):
        """Jump straight to the end state of the animations (no begin()/deep copies/interpolation).

        Covered: animations whose end state is "mobject added / removed / replaced", `.animate` and
        MoveToTarget (the mobject takes its prepared target), Transform (the mobject takes the target's
        shape), the TransformMatching family (source out, target in) and indications that leave the
        slide as it was. Anything else (updaters, Homotopy, custom animations ...) goes through the real
        pipeline, which deep-copies every mobject it animates and is the slow part of a re-render."""
        flat = []

        def walk(x):
            if isinstance(x, _AnimationBuilder):
                x = x.build()              # `m.animate.shift(...)` arrives unbuilt; play() would build it the same way
            if type(x) in SIMPLE_ANIMS or type(x) in TARGET_ANIMS or type(x) is Transform \
                    or type(x) in NOOP_ANIMS or isinstance(x, TransformMatchingAbstractBase):
                flat.append(x)
            elif isinstance(x, (AnimationGroup, LaggedStart)):
                for c in x.animations:
                    walk(c)
            else:
                raise _NotSimple

        try:
            for a in anims:
                walk(a)
        except _NotSimple:
            return False
        for m in self.mobjects:
            if m.updaters or any(sub.updaters for sub in m.submobjects):
                return False
        for a in flat:
            if a.mobject.updaters:
                return False
            if type(a) in TARGET_ANIMS and getattr(a.mobject, "target", None) is None:
                return False
        for a in flat:
            if type(a) in SIMPLE_ANIMS and a.is_introducer():
                self.add(a.mobject)
        # what manim's play() adds before animating; the TransformMatching group of pieces is removed again
        self.add_mobjects_from_animations([a for a in flat if not isinstance(a, TransformMatchingAbstractBase)
                                           and type(a) not in NOOP_ANIMS])
        for a in flat:
            if type(a) in TARGET_ANIMS:
                # manim's _MethodAnimation.finish(): the methods for their side effects, then the target's geometry
                for item in getattr(a, "methods", ()):
                    item.method.__func__(a.mobject, *item.args, **item.kwargs)
                a.mobject.become(a.mobject.target)
            elif type(a) is Transform:
                target = a.target_mobject
                # become() aligns both structures; keep the real target untouched like Transform.begin() does
                a.mobject.become(target if _same_shape(a.mobject, target) else target.copy())
                if a.replace_mobject_with_target_in_scene:
                    self.replace(a.mobject, target)
            elif isinstance(a, TransformMatchingAbstractBase):
                self.remove(*a.to_remove)
                self.add(a.to_add)
            elif type(a) in NOOP_ANIMS:
                pass
            else:
                if a.is_remover():
                    self.remove(a.mobject)
                if getattr(a, "replace_mobject_with_target_in_scene", False):
                    self.replace(a.mobject, a.target_mobject)
        return True

    def wait(self, *a, **k):
        self._sl_dirty = True          # a wait() counts as an animation for manim-slides
        return super().wait(*a, **k)

    def add(self, *a, **k):
        self._sl_dirty = True
        return super().add(*a, **k)

    def remove(self, *a, **k):
        self._sl_dirty = True
        return super().remove(*a, **k)

    def tear_down(self):
        super().tear_down()
        if self._sl_dirty or not _STATE["stops"]:
            self._sl_stop()

    def _sl_stop(self, site=None):
        self._sl_dirty = False
        r = self.renderer
        n = len(_STATE["stops"])
        out = _STATE["out"]
        fw, fh = config.frame_width, config.frame_height
        cam = r.camera
        # full, exact frame
        r.update_frame(self, ignore_skipping=True)
        full = np.array(r.get_frame())
        Image.fromarray(full[..., :3].astype("uint8")).save(os.path.join(out, f"stop{n}.png"))
        pw, ph = full.shape[1], full.shape[0]
        members = extract_mobject_family_members(
            list_update(self.mobjects, self.foreground_mobjects), use_z_index=True, only_those_with_points=True)
        order = {id(m): i for i, m in enumerate(members)}
        top = set()
        stack = list(self.mobjects)
        while stack:
            m = stack.pop()
            if id(m) in top:
                continue
            top.add(id(m))
            stack.extend(m.submobjects)
        vis, sprites, taken, lines = [], [], set(), {}
        sites = {}
        for m in TRACKED:
            k = (m._sl_frames[-1]["file"], tuple(m._sl_frames[-1]["pos"]))
            sites[k] = sites.get(k, 0) + 1
        # tracked objects living inside another tracked one (a table's row labels) are drawn by their parent
        inner = {}
        for m in TRACKED:
            if id(m) in top and m.submobjects:
                inner[id(m)] = {id(x) for x in m.get_family() if x is not m}
        nested_ids = set()
        for m in TRACKED:
            if id(m) in top and any(id(m) in d for pid, d in inner.items() if pid != id(m)):
                nested_ids.add(id(m))
        for m in TRACKED:
            if id(m) not in top:
                continue
            if m._sl_kind in ("line", "shape", "table") and sites[(m._sl_frames[-1]["file"], tuple(m._sl_frames[-1]["pos"]))] > 12:
                continue          # data-point style bulk objects are not individually editable
            try:
                if m._sl_kind != "image" and max_opacity(m) < 0.03:
                    continue
                x0, x1 = m.get_left()[0], m.get_right()[0]
                y0, y1 = m.get_top()[1], m.get_bottom()[1]
                if x1 - x0 <= 0 and y0 - y1 <= 0:
                    continue
                vis.append([m._sl_id, (x0 + fw / 2) / fw * pw, (fh / 2 - y0) / fh * ph,
                            (x1 + fw / 2) / fw * pw, (fh / 2 - y1) / fh * ph])
                if m._sl_kind == "line":
                    a, b = m.get_start(), m.get_end()
                    lines[str(m._sl_id)] = [(a[0] + fw / 2) / fw * pw, (fh / 2 - a[1]) / fh * ph,
                                            (b[0] + fw / 2) / fw * pw, (fh / 2 - b[1]) / fh * ph,
                                            float(m.get_stroke_width()) * 0.01 * pw / fw]
                if id(m) in nested_ids:
                    continue                      # selectable, but rendered as part of its parent's sprite
                fam = extract_mobject_family_members([m], use_z_index=True, only_those_with_points=True)
                for f in fam:
                    taken.add(id(f))
                z = min((order.get(id(f), 10 ** 9) for f in fam), default=10 ** 9)
                sp = raster(cam, fam, out)
                if sp:
                    sp.update(oid=m._sl_id, z=z)
                    sprites.append(sp)
            except Exception:
                traceback.print_exc()
        sprites.sort(key=lambda s: s["z"])
        cam.reset()
        cam.capture_mobjects([m for m in members if id(m) not in taken], include_submobjects=False)
        Image.fromarray(np.array(cam.pixel_array)[..., :3].astype("uint8")).save(os.path.join(out, f"bg{n}.png"))
        _STATE["stops"].append({"png": f"stop{n}.png", "bg": f"bg{n}.png", "visible": vis, "sprites": sprites, "lines": lines,
                                "site": site})


def raster(cam, members, out):
    """Render mobjects alone on a transparent canvas; save a cropped straight-alpha PNG."""
    cam.reset()
    cam.pixel_array[:] = 0
    cam.capture_mobjects(members, include_submobjects=False)
    arr = np.array(cam.pixel_array)
    a = arr[..., 3]
    cols, rows = np.flatnonzero(a.any(axis=0)), np.flatnonzero(a.any(axis=1))
    if len(cols) == 0:
        return None
    x0, x1, y0, y1 = cols[0], cols[-1] + 1, rows[0], rows[-1] + 1
    crop = arr[y0:y1, x0:x1].astype("float32")
    al = crop[..., 3:4]
    rgb = np.where(al > 0, crop[..., :3] * 255.0 / np.maximum(al, 1), 0)   # un-premultiply
    img = np.concatenate([np.clip(rgb, 0, 255), al], axis=2).astype("uint8")
    data = img.tobytes()
    name = "sp_" + hashlib.md5(data + bytes([x1 - x0 & 255, y1 - y0 & 255])).hexdigest()[:16] + ".png"
    path = os.path.join(out, name)
    if not os.path.exists(path):
        Image.fromarray(img, "RGBA").save(path, compress_level=1)
    return {"file": name, "x": int(x0), "y": int(y0), "w": int(x1 - x0), "h": int(y1 - y0)}


class _NotSimple(Exception):
    pass


REAL_PLAY = bool(os.environ.get("MANIMBLE_REAL_PLAY"))
SIMPLE_ANIMS = {FadeIn, FadeOut, Create, Uncreate, Write, Unwrite, DrawBorderThenFill, GrowFromCenter,
                GrowFromPoint, GrowFromEdge, GrowArrow, SpinInFromNothing, ReplacementTransform}
TARGET_ANIMS = {_MethodAnimation, MoveToTarget}        # the mobject ends up as its prepared .target
NOOP_ANIMS = {Indicate, Flash, Circumscribe, Wiggle, FocusOn}   # there-and-back / self-removing effects


def _same_shape(a, b) -> bool:
    """True when become() can copy b's points into a without inserting submobjects into either."""
    if a.has_points() != b.has_points() or len(a.submobjects) != len(b.submobjects):
        return False
    return all(_same_shape(x, y) for x, y in zip(a.submobjects, b.submobjects))

fake = types.ModuleType("manim_slides")
fake.Slide = Slide
sys.modules["manim_slides"] = fake


# ------------------------------------------------------------------ runner

_realpaths: dict = {}


def purge_project_modules():
    for name, mod in list(sys.modules.items()):
        fn = getattr(mod, "__file__", None)
        if not fn:
            continue
        real = _realpaths.get(fn)        # resolving ~1200 installed modules each render costs 60 ms
        if real is None:
            real = _realpaths[fn] = os.path.realpath(fn)
        if in_project(real):
            del sys.modules[name]
    importlib.invalidate_caches()


def hexcolor(m):
    try:
        for sub in m.get_family():
            if isinstance(sub, BackgroundRectangle):
                continue              # a text highlight, not the text's colour
            if sub.has_points():
                return sub.get_color().to_hex()
    except Exception:
        pass
    return None


def text_attr(m, name):
    """font_size / font / weight / slant of a Text, or of the Text inside a Paragraph."""
    v = getattr(m, name, None)
    if v is None and getattr(m, "lines_text", None) is not None:
        v = getattr(m.lines_text, name, None)
    return v


def dims_px(m):
    """Manim's width and height of the object (all points, like stretch_to_fit_*), in frame pixels."""
    try:
        fw, fh = config.frame_width, config.frame_height
        return [float(m.width) / fw * config.pixel_width, float(m.height) / fh * config.pixel_height]
    except Exception:
        return None


def rotation_deg(m) -> float:
    """Total angle of the object's own rotate() calls, in degrees (0-360)."""
    total = 0.0
    for e in EVENTS.get(id(m), (None, []))[1]:
        if e["method"] != "rotate":
            continue
        a = e["args"][0] if e["args"] else e["kwargs"].get("angle")
        if isinstance(a, (int, float)) and not isinstance(a, bool):
            total += float(a)
    return round(math.degrees(total) % 360.0, 2)


def shape_color(m):
    try:
        return m.get_stroke_color().to_hex() if m.get_stroke_opacity() > 0 else m.get_fill_color().to_hex()
    except Exception:
        return None


def max_opacity(m):
    best = 0.0
    try:
        for sub in m.get_family():
            if sub.has_points():
                best = max(best, float(sub.get_fill_opacity()), float(sub.get_stroke_opacity()))
    except Exception:
        return 1.0
    return best


def collect_events(m, seen=None):
    """Own events plus events of enclosing groups made after m joined them."""
    out = [dict(e, own=True) for e in EVENTS.get(id(m), (None, []))[1]]
    stack = [(m, 0)]
    visited = {id(m)}
    while stack:
        cur, since = stack.pop()
        for parent, joined in PARENTS.get(id(cur), (None, []))[1]:
            if id(parent) in visited:
                continue
            visited.add(id(parent))
            for e in EVENTS.get(id(parent), (None, []))[1]:
                if e["seq"] > max(joined, since):
                    out.append(dict(e, own=False))
            stack.append((parent, max(joined, since)))
    out.sort(key=lambda e: e["seq"])
    return out


def render(req):
    DEPENDENCIES.clear()
    out = req["out"]
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith(".png") or f.endswith(".jpg"):
            os.remove(os.path.join(out, f))
    TRACKED.clear()
    EVENTS.clear()
    PARENTS.clear()
    _STATE.update(stops=[], out=out, scene=req["scene"])
    purge_project_modules()
    mod = importlib.import_module(req["module"])
    cls = getattr(mod, req["scene"])
    for attempt in (0, 1):
        TRACKED.clear(); EVENTS.clear(); PARENTS.clear(); _STATE.update(stops=[])
        scene = cls(skip_animations=True)
        try:
            scene.render()
            break
        except FileNotFoundError:
            # two worker processes share manim's media cache; a half-written file resolves on retry
            if attempt:
                raise
    objects = {}
    for m in TRACKED:
        objects[m._sl_id] = {
            "kind": m._sl_kind,
            "value": m._sl_value,
            "font_size": text_attr(m, "font_size") if m._sl_kind in ("text", "tex") else None,
            "font0": getattr(m, "_sl_font0", None),
            "font": text_attr(m, "font") if m._sl_kind == "text" else None,
            "weight": text_attr(m, "weight") if m._sl_kind == "text" else None,
            "slant": text_attr(m, "slant") if m._sl_kind == "text" else None,
            "color": (hexcolor(m) if m._sl_kind in ("text", "tex") else shape_color(m)) if m._sl_kind != "image" else None,
            "path": str(getattr(m, "path", "")) if m._sl_kind == "image" and getattr(m, "path", None) else None,
            "rotation": rotation_deg(m),
            "dims": dims_px(m),
            "frames": m._sl_frames,
            "events": collect_events(m),
        }
    files = {}
    for name in os.listdir(DECK):
        if name.endswith(".py"):
            with open(os.path.join(DECK, name), "rb") as fh:
                files[name] = hashlib.sha1(fh.read()).hexdigest()
    last = _STATE["stops"][-1]["png"] if _STATE["stops"] else None
    if last:
        im = Image.open(os.path.join(out, last)).convert("RGB")
        im.thumbnail((360, 203))
        im.save(os.path.join(out, "thumb.jpg"), quality=82)
    return {
        "stops": _STATE["stops"],
        "objects": objects,
        "files": files,
        "dependencies": sorted(DEPENDENCIES),
        "size": [config.pixel_width, config.pixel_height],
        "frame": [config.frame_width, config.frame_height],
    }


def sprite(req):
    """Rasterise one Text/MathTex for instant canvas preview (centered on frame centre)."""
    from manim import Text as T, MathTex as M
    out = req["out"]
    os.makedirs(out, exist_ok=True)
    color = req.get("color") or "#FFFFFF"
    if req["kind"] == "code":
        import manim
        m = eval(req["code"], dict(vars(manim)))
    elif req["kind"] == "text":
        kw = {"font_size": req["font_size"], "color": color}
        if req.get("font"):
            kw["font"] = req["font"]
        if req.get("weight"):
            kw["weight"] = req["weight"]
        if req.get("slant"):
            kw["slant"] = req["slant"]
        m = T(req["value"], **kw)
    else:
        m = M(req["value"], font_size=req["font_size"], color=color)
    if req["kind"] != "code":
        m.move_to(ORIGIN)
    cam = Camera()
    fam = extract_mobject_family_members([m], use_z_index=True, only_those_with_points=True)
    sp = raster(cam, fam, out)
    if sp is None:
        return {"error": "empty"}
    pw, ph = config.pixel_width, config.pixel_height
    # offset of the sprite's centre from the frame centre, in px
    sp["cx"] = sp["x"] + sp["w"] / 2 - pw / 2
    sp["cy"] = sp["y"] + sp["h"] / 2 - ph / 2
    sp["path"] = os.path.join(out, sp["file"])
    return sp


def latex(req):
    from manim.utils.tex_file_writing import tex_to_svg_file
    path = tex_to_svg_file(req["tex"], environment="align*")
    with open(path, encoding="utf-8") as fh:
        return {"svg": fh.read()}


def describe_error(exc) -> str:
    """Error text for the UI; for LaTeX failures, the actual TeX complaint."""
    import re
    msg = str(exc) or exc.__class__.__name__
    m = re.search(r"log file: (\S+\.log)", msg)
    if m and os.path.exists(m.group(1)):
        try:
            with open(m.group(1), encoding="utf-8", errors="replace") as fh:
                lines = fh.read().split("\n")
            for i, ln in enumerate(lines):
                if ln.startswith("!"):
                    detail = "\n".join(l for l in lines[i:i + 4] if l.strip())
                    return "LaTeX error: " + detail
        except OSError:
            pass
    # where in the deck's own code did it fail?
    try:
        import traceback as tb
        frames = [f for f in tb.extract_tb(exc.__traceback__) if in_project(os.path.realpath(f.filename))]
        if frames:
            f = frames[-1]
            msg += f"  (at {os.path.basename(f.filename)}:{f.lineno}: {(f.line or '').strip()})"
    except Exception:
        pass
    return msg


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        try:
            if req["cmd"] == "render":
                res = render(req)
            elif req["cmd"] == "sprite":
                res = sprite(req)
            elif req["cmd"] == "latex":
                res = latex(req)
            elif req["cmd"] == "colors":
                # manim's named colours (WHITE, BLUE_C, ORANGE, ...) as #RRGGBB
                import manim.utils.color as mc
                res = {"colors": {k: v.to_hex().upper()[:7] for k, v in vars(mc).items()
                                  if k.isupper() and isinstance(v, mc.ManimColor)}}
            elif req["cmd"] == "ping":
                res = {"ok": True}
            else:
                res = {"error": "unknown command"}
        except BaseException as exc:  # noqa: BLE001
            if isinstance(exc, KeyboardInterrupt):
                raise
            tb = traceback.format_exc()
            sys.stderr.write(tb)
            msg = describe_error(exc)
            res = {"error": msg[-1800:], "trace": tb[-3000:], "dependencies": sorted(DEPENDENCIES)}
        _proto.write(json.dumps(res) + "\n")


if __name__ == "__main__":
    main()
