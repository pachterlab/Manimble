---
name: manimble-check
description: >-
  Render every slide (or chosen slides) of a Manimble deck to PNG without
  touching the deck, report the slides that fail to render (with the file and
  line) and the objects that run off the edge of the slide, look at the
  pictures, and fix what is wrong. Use it to see what a slide looks like when
  Manimble is not showing it, before saying a slide is finished, or when asked
  to check a deck. Triggers: "check my deck", "which slides are broken",
  "find text that runs off the slide", "render the slides so you can see them",
  "fix the slide that shows an error", "manimble-check".
---

# Check a Manimble deck

`scripts/render_stills.py` (next to this file) renders the last frame of each
slide, that is the slide after its final build, to `OUT/<Slide>.png` at
854×480 and prints a JSON report. It writes nothing into the deck folder: no
manim-slides clips, no `__pycache__`, and manim's media go to `OUT`.

## 1. Find the Python and the deck

Use the Python Manimble renders with, the first of these that can
`import manim, manim_slides`:

1. `$MANIMBLE_PYTHON`
2. `~/Library/Application Support/Manimble/python/bin/python` (macOS app)
3. a `.venv` in the project, then `python3` on `PATH`

```bash
PY="${MANIMBLE_PYTHON:-$HOME/Library/Application Support/Manimble/python/bin/python}"
"$PY" -c "import manim, manim_slides" || PY=python3
```

The deck is `$MANIMBLE_DECK` inside Manimble's terminal, otherwise the folder
the user names (the one holding `order.txt` and the slide `.py` files).

**Inside Manimble** the app already renders every slide and shows errors on
them; run this only when the user asked for a check or you need to see a slide
yourself. It is safe to run there: it reads the working copy and writes only to
`OUT`.

## 2. Render

```bash
OUT="$(mktemp -d)/manimble-check"
"$PY" "SKILL_DIR/scripts/render_stills.py" "$DECK" --out "$OUT"              # every slide in order.txt
"$PY" "SKILL_DIR/scripts/render_stills.py" "$DECK" --out "$OUT" --scenes Results Summary
```

(`SKILL_DIR` is the directory of this SKILL.md.) `--hd` renders at the deck's
own resolution. A slide with formulas takes a few seconds the first time
(LaTeX); others take well under a second. The exit status is 1 if any slide
failed.

The report:

```json
{"frame": [14.222, 8.0],
 "slides": [{"scene": "Results", "ok": true, "png": ".../Results.png",
             "offscreen": [{"type": "Text", "text": "A very long ...", "past": ["right"],
                            "bounds": [-6.8, 10.8, -0.3, 0.3]}]},
            {"scene": "Method", "ok": false, "where": "slides.py:49", "error": "TypeError: ..."}]}
```

- `ok: false` with `where`/`error`: the slide raised. An entry with
  `scene: null` is a file that doesn't parse. "no class of this name" means a
  name in `order.txt` has no class.
- `offscreen`: top-level objects reaching past the frame edge;
  `bounds` is `[left, right, bottom, top]` against a frame of ±7.11 × ±4.

## 3. Look

Open the PNGs of the slides you changed or that were flagged (read them as
images). The report can't see overlapping objects, text that is too small to
read (under about `font_size=20`), low contrast against the background, or
crowded layouts; the picture can. Only the final frame is rendered: for a
problem in an earlier build, read that build's code or ask the user what they see.

## 4. Fix

Follow the **manimble-slides** skill's rules when editing: change only the
statements at fault, keep literal positions in `.move_to((x, y, 0))`, don't
rename classes or reformat code. Typical fixes:

- Text past an edge: break the line with `\n`, lower `font_size` a little, or
  move it; for a group, re-centre the group.
- An error: fix the line `where` points at. A LaTeX error names the missing
  package or the bad expression; a missing package is for the user to install
  (`tlmgr install <package>`), so say so instead of rewriting the formula.
- A missing picture: check the path is relative to the slide file, as in
  `Path(__file__).resolve().parent / "name.png"`.

Re-render the slides you fixed (`--scenes ...`), look again, and report what was
wrong and what you changed, slide by slide, plus anything you left for the user.
Delete `OUT` when done.
