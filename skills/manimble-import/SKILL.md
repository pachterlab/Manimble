---
name: manimble-import
description: >-
  Convert a PowerPoint (.pptx), Keynote (.key, macOS) or Beamer (.tex)
  presentation into a new, editable Manimble deck from the command line, with
  Manimble's own importer, then check the result and, if asked, add what the
  importer can't bring over (animations, charts, builds). Also turns an
  existing Manim Slides project into a Manimble deck. Triggers: "import my
  PowerPoint into Manimble", "convert this .pptx/.key/Beamer talk to Manim",
  "make a Manimble deck from my slides", "animate my old PowerPoint",
  "manimble-import".
---

# Import a presentation into Manimble

Manimble's engine does the conversion (the same code as **File ▸ Import** in
the app). Each element becomes an ordinary line of Manim code, so the result
is edited like any deck.

## 1. Find the engine and its Python

- `ENGINE`: the first folder holding `manimble/importer.py` among
  `$MANIMBLE_ENGINE`, `~/Applications/Manimble.app/Contents/Resources/engine`,
  `/Applications/Manimble.app/Contents/Resources/engine`, and a Manimble
  checkout's `engine/`. Without one, Manimble isn't installed: tell the user to
  install it (https://github.com/pachterlab/Manimble/releases) or import in the
  app; don't hand-convert a whole presentation instead unless they ask.
- `PY`: `$MANIMBLE_PYTHON`, else `~/Library/Application Support/Manimble/python/bin/python`,
  else `python3`; it needs `python-pptx`, `manim` and Pillow.

## 2. Convert

`DEST` is a new project folder (it gets `deck/` and `assets/`); it must not
already hold a `deck/`. Name it after the presentation, beside it, unless the
user says otherwise.

```bash
# PowerPoint, or Keynote / old .ppt (converted through Keynote, so macOS with Keynote only)
PYTHONPATH="$ENGINE" "$PY" -c 'import json, sys
from manimble.importer import import_presentation
print(json.dumps(import_presentation(sys.argv[1], sys.argv[2]), indent=1))' "$SRC" "$DEST"

# Beamer: SRC is the main .tex file; it is typeset with the document's own preamble
PYTHONPATH="$ENGINE" "$PY" -c 'import json, sys
from manimble.beamer_import import import_beamer
print(json.dumps(import_beamer(sys.argv[1], sys.argv[2]), indent=1))' "$SRC" "$DEST"
```

The result is `{"ok": true, "deck": ".../deck", "slides": N, "warnings": [...]}`
or `{"ok": false, "error": "..."}`. Pass every warning on to the user. Beamer
import can take a minute or more (it runs LaTeX); missing LaTeX packages show
as placeholders and are named in the warnings: tell the user to install them
(`tlmgr install ...`, or Manimble offers to) rather than installing them
yourself.

A **Manim Slides project** needs no conversion: it is already a deck. Open its
folder in Manimble; to fix the slide order for Manimble, write an `order.txt`
with the class names in the order of the project's `manim-slides render`
command.

## 3. What comes across, and what doesn't

PowerPoint/Keynote: text boxes (font, size, colour, bold/italic per word,
alignment, wrapping), pictures (to `assets/`), basic shapes, lines and arrows,
tables, groups, background colours, speaker notes (as comments). Not imported:
animations and transitions, charts, SmartArt, gradient or picture backgrounds;
unusual shapes become rectangles. Non-16:9 slides are stretched.

Beamer: frame titles, text with its styling, lists with Beamer's bullets, display
maths as `MathTex`, `\includegraphics`, overlays (`\pause`, `<+->`, `\only`,
`\uncover`, `\onslide`) as builds; TikZ, tables and other drawings as pictures.
The default theme and the Madrid/Boadilla/Warsaw family are recognised.

## 4. Check and improve

- Speaker notes come in as `# Speaker notes:` comments, which Manimble does
  not show. Move each slide's notes into a `self.next_slide(notes="...")` as
  the first statement of its `construct`, as one string.
- A Beamer deck's frame number comes in as plain text at the edge of the slide
  and is not renumbered when slides change. If the user wants slide numbers,
  delete it and add Manimble's own (Format ▸ Slide Numbers in the app, or the
  marked statement described in **manimble-slides**).
- Render the new deck with the **manimble-check** skill and compare the PNGs
  with the original slides (export the original to PDF or PNGs to look at both
  when you can). Report slides that differ noticeably.
- If the user wants more (animations the original lacked, a chart rebuilt as a
  real Manim plot, builds), edit with the **manimble-slides** skill, one slide
  at a time, keeping the imported statements and their literal positions.
- Tell the user where the deck is and to open the project folder with
  **File ▸ Open Deck or Project…** in Manimble.
