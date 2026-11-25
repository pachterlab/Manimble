#!/usr/bin/env python3
"""Render the last frame of each slide of a Manimble deck to PNG, without touching the deck.

    python render_stills.py DECK_DIR --out OUT_DIR [--scenes Name ...] [--hd]

For every slide (the classes in order.txt, or every class with a construct() when there is no order.txt) it writes
OUT_DIR/<Scene>.png, the slide as it looks after its last build, and prints a JSON report:

    {"frame": [w, h], "slides": [{"scene", "png", "ok", "error", "where", "offscreen": [...], "seconds"}]}

`offscreen` lists the top-level objects that reach past the edge of the frame (by more than 0.05 units), with their
type, the text they show (for Text, Tex and their groups) and their bounds [left, right, bottom, top]. `where` is
the deck file and line where a failing slide's error arose. Nothing is written into the deck folder:
manim-slides' clip files are not saved, Python bytecode is not cached and manim's media go to OUT_DIR.
"""
from __future__ import annotations

import argparse
import ast
import importlib
import json
import os
import sys
import time
import traceback
from pathlib import Path

sys.dont_write_bytecode = True
MARGIN = 0.05


def slide_classes(deck: Path) -> list[tuple[str, str]]:
    """(module, class) of every class with a construct() method in the deck's top-level .py files, in file order."""
    found = []
    for py in sorted(deck.glob("*.py")):
        try:
            tree = ast.parse(py.read_text(encoding="utf-8"))
        except (SyntaxError, UnicodeDecodeError) as exc:
            found.append((py.stem, f"!{exc}"))
            continue
        for node in tree.body:
            if isinstance(node, ast.ClassDef) and any(
                    isinstance(b, ast.FunctionDef) and b.name == "construct" for b in node.body):
                found.append((py.stem, node.name))
    return found


def shown_text(mob) -> str:
    for m in [mob, *mob.get_family()]:
        for attr in ("original_text", "tex_string", "text"):
            value = getattr(m, attr, None)
            if isinstance(value, str) and value.strip():
                return value.strip()[:80]
    return ""


def offscreen(scene, half_w: float, half_h: float) -> list[dict]:
    out = []
    for mob in scene.mobjects:
        try:
            if not mob.get_family() or (mob.width == 0 and mob.height == 0):
                continue
            left, right = mob.get_left()[0], mob.get_right()[0]
            bottom, top = mob.get_bottom()[1], mob.get_top()[1]
        except Exception:  # noqa: BLE001
            continue
        sides = [s for s, past in (("left", left < -half_w - MARGIN), ("right", right > half_w + MARGIN),
                                   ("bottom", bottom < -half_h - MARGIN), ("top", top > half_h + MARGIN)) if past]
        if sides:
            out.append({"type": type(mob).__name__, "text": shown_text(mob), "past": sides,
                        "bounds": [round(float(v), 2) for v in (left, right, bottom, top)]})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("deck", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--scenes", nargs="*", help="only these slides (class names)")
    ap.add_argument("--hd", action="store_true", help="render at the deck's own resolution instead of 854x480")
    args = ap.parse_args()

    deck = args.deck.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if out == deck or deck in out.parents:
        sys.exit("--out must be outside the deck folder")

    os.chdir(deck)                    # manim reads manim.cfg from here, and the slides open files relative to it
    sys.path.insert(0, str(deck))

    for engine in (os.environ.get("MANIMBLE_ENGINE"),
                   os.path.expanduser("~/Applications/Manimble.app/Contents/Resources/engine"),
                   "/Applications/Manimble.app/Contents/Resources/engine"):
        if engine and os.path.isdir(os.path.join(engine, "manimble")):
            sys.path.append(engine)
            try:
                from manimble import pilcompat  # pictures under Pillow 13 with manim 0.21, as Manimble renders
                pilcompat.install()
            except Exception:  # noqa: BLE001
                pass
            break

    from manim import config, tempconfig
    try:
        from manim_slides.slide.manim import Slide
        Slide._save_slides = lambda self, *a, **k: None    # no clip files in the deck's slides/ folder
    except Exception:  # noqa: BLE001
        pass

    classes = slide_classes(deck)
    order_file = deck / "order.txt"
    by_name = {name: mod for mod, name in classes if not name.startswith("!")}
    if args.scenes:
        names = args.scenes
    elif order_file.exists():
        names = order_file.read_text(encoding="utf-8").split()
    else:
        names = [name for _, name in classes if not name.startswith("!")]

    report = {"frame": [round(config.frame_width, 3), round(config.frame_height, 3)], "slides": []}
    for mod, name in classes:
        if name.startswith("!"):
            report["slides"].append({"scene": None, "file": f"{mod}.py", "ok": False, "error": name[1:]})

    settings = {"media_dir": str(out / "media"), "save_last_frame": True, "write_to_movie": False,
                "disable_caching": True, "progress_bar": "none", "verbosity": "ERROR", "format": "png"}
    if not args.hd:
        settings.update(pixel_width=854, pixel_height=480)

    for name in names:
        entry = {"scene": name, "png": None, "ok": False, "error": None, "offscreen": []}
        start = time.time()
        mod = by_name.get(name)
        if mod is None:
            entry["error"] = "no class of this name with a construct() in the deck's .py files"
            report["slides"].append(entry)
            continue
        try:
            cls = getattr(importlib.import_module(mod), name)
            with tempconfig({**settings, "output_file": name}):
                scene = cls()
                scene.render()
                half_w, half_h = config.frame_width / 2, config.frame_height / 2
                entry["offscreen"] = offscreen(scene, half_w, half_h)
            pngs = sorted((out / "media").rglob(f"{name}*.png"), key=lambda p: p.stat().st_mtime)
            if pngs:
                target = out / f"{name}.png"
                os.replace(pngs[-1], target)
                entry["png"] = str(target)
            entry["ok"] = True
        except BaseException as exc:  # noqa: BLE001  (a slide may call sys.exit or raise anything)
            if isinstance(exc, KeyboardInterrupt):
                raise
            tb = traceback.format_exception(type(exc), exc, exc.__traceback__)
            entry["error"] = "".join(tb[-6:]).strip()
            in_deck = [f for f in traceback.extract_tb(exc.__traceback__)
                       if Path(f.filename).resolve().parent == deck]
            if in_deck:                                  # the deepest line of the deck's own code
                entry["where"] = f"{Path(in_deck[-1].filename).name}:{in_deck[-1].lineno}"
        entry["seconds"] = round(time.time() - start, 1)
        report["slides"].append(entry)

    print(json.dumps(report, indent=1))
    return 0 if all(s["ok"] for s in report["slides"]) else 1


if __name__ == "__main__":
    sys.exit(main())
