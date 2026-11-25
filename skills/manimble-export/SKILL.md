---
name: manimble-export
description: >-
  Turn a Manimble deck or a .manimble package into something people without
  Manimble can open: an MP4 movie of the animated show, a PDF handout, a
  self-contained HTML presentation, or a PowerPoint with the animations as
  videos; also check, inspect and unpack .manimble packages, and pick slides
  out ("slides 1-3 and Results"). Runs from the command line, with no app
  window. Triggers: "export my deck to PDF/MP4/HTML", "make a movie of my
  talk", "convert this .manimble", "what's in this .manimble file", "unpack
  the .manimble", "make a handout", "manimble-export".
---

# Export a Manimble deck

Inside Manimble the same exports are in **File ▸ Export To** and **Share**
(including PowerPoint/Keynote with editable text, Beamer, and movies with the
narration script). Use this skill for the command line: a `.manimble`
package, a deck folder, a batch, or a machine without the app open.

Find the Python first, the first that can `import manim, manim_slides`:
`$MANIMBLE_PYTHON`, `~/Library/Application Support/Manimble/python/bin/python`
(macOS app), a project `.venv`, `python3`.

```bash
PY="${MANIMBLE_PYTHON:-$HOME/Library/Application Support/Manimble/python/bin/python}"
"$PY" -c "import manim, manim_slides" || PY=python3
```

## A .manimble package: `manimbler`

`manimbler` is installed at `~/.local/bin/manimbler` by Manimble's installer, or
is `./manimbler` in a Manimble checkout. A package carries its rendered builds,
so conversion needs no rendering.

```bash
manimbler --check talk.manimble                       # archive and referenced media intact?
manimbler --info talk.manimble                        # slide order, builds, sizes, MP4 running time
manimbler --extract talk.manimble --output talk       # editable project folder
manimbler --convert talk.manimble --output talk.mp4   # animated show; --hold 0 for no pauses, --fps N
manimbler --convert talk.manimble --slides 1-3,7,Results --output excerpt.mp4
manimbler --convert talk.manimble --to pdf --output handout.pdf
manimbler --convert talk.manimble --to html --output talk.html
```

Conversion follows `order.txt`; `--slides` takes 1-based numbers, ranges and
slide names and keeps deck order. MP4 has no audio. `--force` replaces existing
output. Run `--check` first when a package came from someone else. Keep an HTML
export next to its `_assets` folder when sharing.

## A deck folder: render, then convert with manim-slides

Never render in the user's deck folder (rendering writes `slides/` and `media/`
there) and never in Manimble's working copy. Work in a temporary copy:

```bash
WORK="$(mktemp -d)/deck"
cp -R "$DECK" "$WORK" && cd "$WORK"
cp -R "$DECK/../assets" "$WORK/../assets" 2>/dev/null   # if the slides use the project's assets folder
```

The slides, in show order, without hidden ones:

```bash
SLIDES=$(cat order.txt)    # no order.txt: every Slide class, in file order
# drop any class whose `class` line ends in "# manimble hidden"
```

Render. Prefer Manimble's renderer, which also builds slides that only add
objects and never animate (plain manim-slides refuses those); it is
`ENGINE/manimble/slides_render.py`, with `ENGINE` the first of
`$MANIMBLE_ENGINE`, `~/Applications/Manimble.app/Contents/Resources/engine`,
`/Applications/Manimble.app/Contents/Resources/engine` or a checkout's `engine`:

```bash
"$PY" "$ENGINE/manimble/slides_render.py" render --progress_bar none slides.py $SLIDES
# without Manimble: "$PY" -m manim_slides render slides.py $SLIDES
```

Slides spread over several files: run the render once per file with the
classes from that file. Resolution comes from `manim.cfg` (1280×720); add
`--resolution 1920,1080` for HD.

Convert:

```bash
"$PY" -m manim_slides convert --to html $SLIDES talk.html                        # one-file web show (+ talk_assets/)
"$PY" -m manim_slides convert --to pdf  $SLIDES handout.pdf                      # one page per build
"$PY" -m manim_slides convert --to pptx $SLIDES talk.pptx                        # each build a video slide
```

An MP4 of a deck folder: render as above, then join the build videos listed in
each `slides/<Slide>.json` in order with `ffmpeg -f concat`, or simply make a
`.manimble` package in Manimble (File ▸ Save .manimble…) and use
`manimbler --convert`, which also holds each build's last frame.

Copy the outputs to where the user wants them, then delete the temporary copy.

## Report

Say where each file is, its size, the slide count, and anything left out
(hidden slides, slides that failed to render, with their errors). A slide
that fails to render: fix it with the **manimble-check** skill, or report it.
