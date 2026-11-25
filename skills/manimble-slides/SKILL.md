---
name: manimble-slides
description: >-
  Write or change slides in a Manimble deck (a Manim Slides project) so that
  they render, animate in clicks, and stay editable on Manimble's canvas: new
  slides, builds and animations, text, formulas, pictures, BioCartoon icons,
  plots from data, speaker notes, slide order and hidden slides, and changes
  across the whole deck (a footer, a title style, a renamed term). Works in
  Manimble's own terminal (where the app re-renders as you save) and in any
  other terminal. Triggers: "add a slide", "make this slide animate",
  "put a figure/plot/equation on the Results slide", "add speaker notes",
  "change every slide's title", "reorder the slides", "edit my Manimble deck",
  "manimble-slides".
---

# Edit slides in a Manimble deck

A Manimble deck is a folder of Python files whose `Slide` classes (from
[manim-slides](https://github.com/jeertmans/manim-slides)) are the slides. The
user edits the same code by hand on Manimble's canvas, so the code you write
must be code Manimble can follow. Everything below applies whether or not the
app is open.

## 1. Find the deck and the situation

- **Inside Manimble's terminal** `$MANIMBLE_DECK` is set. Edit only there (it
  is the working copy); never write to `$MANIMBLE_ORIGINAL_DECK`. The user saves
  with File ▸ Save to Original. Don't run `manim` or `manim-slides`: Manimble
  re-renders each slide within seconds of a save and shows errors on the slide.
  `python -m py_compile FILE` is enough to check syntax. Subfolders of the
  working copy, and `../assets`, are links into the user's real project, so
  writes there skip Save/Revert; prefer the top-level files.
- **Elsewhere** the deck is the folder the user names (or the folder holding
  `order.txt`, `common.py` and the slide `.py` files; in a project it is usually
  `Project/deck/` with pictures in `Project/assets/`). If the deck is in git,
  check `git status` first so your changes can be told apart from theirs. To
  see the result, use the **manimble-check** skill, which renders each slide's
  last frame to PNG without writing into the deck.
- If the folder has its own `CLAUDE.md`/`AGENTS.md`, follow it too.

Read the files before changing them: `common.py` (the `Deck` base class, the
theme constants `THEME`, `BACKGROUND`, `FONT`, `TEXT_COLOR`, `MUTED_COLOR`,
`ACCENT`, and helpers such as `label(...)`), `order.txt`, and two or three
existing slides, then write new slides in the same style with the same helpers.

## 2. How a deck is put together

- Each slide is a class with a `construct(self)` method, usually deriving from
  `Deck` in `common.py`. Its class name is the slide's name.
- `order.txt` lists class names (spaces or new lines) in show order. **A new
  slide appears in the show only once its name is in `order.txt`.** Without an
  `order.txt`, every class is a slide, in file order. Don't delete a slide the
  user didn't ask to delete: take it out of `order.txt` or hide it.
- A class line ending in `# manimble hidden` is a hidden slide (kept, skipped in
  the show).
- `self.next_slide()` separates builds; the presenter clicks once per build.
- Only `self.play(...)` and `self.wait(...)` record frames. Something added with
  `self.add(...)` after a build's last `play`/`wait` shows one click late, so add
  before them. A slide or build that only adds objects should end with
  `self.wait(0.1)`, as Manimble's own builds do.
- Speaker notes: `self.next_slide(notes="...")` as the first statement of
  `construct` holds the slide's notes; `self.next_slide(notes="...")` between
  builds holds that build's notes.
- The frame is about 14.2 × 8 units, centred on the origin (x from −7.1 to 7.1,
  y from −4 to 4). Keep everything at least 0.3 units inside the edge.
- Code runs with the deck folder as working directory. Refer to a picture next
  to the slide files as
  `str(__import__("pathlib").Path(__file__).resolve().parent / "name.png")`,
  and to one in the project's assets folder as `ASSETS / "name.png"` when
  `common.py` defines `ASSETS` (Manimble's themes do), otherwise
  `.parent.parent / "assets" / "name.png"`.

## 3. Write code that stays editable

Manimble moves, resizes, retypes and recolours objects by rewriting the
statement that made each one. So:

- One object per statement, made by one expression with literal arguments:
  `title = Text("Results", font=FONT, font_size=44, color=TEXT_COLOR).move_to((0, 3.2, 0))`
- Position with numbers in `.move_to((x, y, 0))` for anything the user might
  drag. `next_to`, `arrange` and `to_edge` are fine for things that move as a
  unit (a bullet list made as one `VGroup`, a label tied to its arrow).
- Loops, comprehensions and helpers only for things nobody will want to move
  or retype one at a time (axis ticks, a grid of dots).
- A helper that makes `Text` must accept and pass on `**kwargs`: Manimble stores
  bold, italic and colour on part of a text as `t2w`, `t2s` and `t2c`.
- Use the theme constants (`FONT`, `TEXT_COLOR`, `ACCENT`, ...) rather than
  repeating literal colours and font names, so a theme change reaches your text.
- Don't rename slide classes, reorder statements, or reformat code you weren't
  asked to change: Manimble finds objects by the line that made them, and the
  user's hand edits live in those lines.
- Leave alone the `# manimble ...` comment marks, `manimble_helpers.py`, the
  helper functions Manimble appends to a file (such as `underline_chars`),
  `manimble_decoration` attributes, `alt_text = "..."` lines and
  `.set(manimble_link=...)`. Don't edit `feedback.json`, `script.json`,
  `present.json` or `*.plot.json` unless asked.

## 4. Recipes

Text and bullets:

```python
heading = Text("Why it matters", font=FONT, font_size=40, color=TEXT_COLOR).move_to((-6.2, 3.1, 0), aligned_edge=LEFT)
point1 = Text("• Structure predicts function", font=FONT, font_size=30, color=TEXT_COLOR).move_to((-5.8, 1.4, 0), aligned_edge=LEFT)
point2 = Text("• Experiments are slow", font=FONT, font_size=30, color=TEXT_COLOR).move_to((-5.8, 0.6, 0), aligned_edge=LEFT)
```

`.move_to(point)` places the object's centre there; `aligned_edge=LEFT` (or `UL`,
`RIGHT`, ...) places that edge instead, which is how left-aligned text lines up.
Manimble writes positions the same way.

Wide text: keep a line under about 45 characters at `font_size=30` across the
full width, or break it with `\n`. Measure with the manimble-check skill when
unsure.

Builds, one point per click:

```python
self.play(FadeIn(heading), FadeIn(point1))
self.next_slide()
self.play(FadeIn(point2))
```

Formulas: `MathTex(r"e^{i\pi} + 1 = 0", font_size=72, color=TEXT_COLOR).move_to((0, 0.5, 0))`.
For a step-by-step derivation use one `MathTex` per step and
`TransformMatchingTex(step1, step2)` between builds. LaTeX packages beyond
Manim's defaults may be missing; on Manim's error, tell the user which package
(`tlmgr install <name>`).

Pictures: copy the file into the deck folder (or the project's `assets`), then
`ImageMobject(path).set(width=5).move_to((3.5, 0, 0))`. SVG artwork:
`SVGMobject(path).set(height=3).move_to(...)`.

Scientific icons: if the `biocartoon` command is installed (it comes with
Manimble), `biocartoon search "mitochondrion" --icons --limit 8` finds icons,
`biocartoon get ID` gives the license and credit line, and
`biocartoon fetch ID --out DECK_DIR` downloads the SVG (or PNG). Place it as
above and put the credit in a small caption or the speaker notes when its
license asks for attribution.

Plots from data: read the data file in `construct` (relative to the deck
folder) and build `Axes(...)` plus `axes.plot_line_graph(...)` or `BarChart(...)`;
or render a Matplotlib figure to a PNG in the deck folder and insert that. Keep
the axes and title as separate, positioned statements.

Deck-wide changes (a footer on every slide, a title style): put the shared part
in `common.py` (a helper or a method on `Deck`) and call it from each slide,
rather than pasting the code into every slide. A literal on each slide is
better only when the user will want to adjust it per slide.

## 5. Finish

- Make one change at a time and say which slide (class name) it touched, so the
  user can look before the next.
- Run `python -m py_compile` on each file you edited.
- Outside Manimble, render what you changed with **manimble-check** and look
  at the PNGs before saying a slide is done. Inside Manimble, ask the user to
  look, or to paste the error if the slide shows one.
- New slide? Confirm it is in `order.txt`.
