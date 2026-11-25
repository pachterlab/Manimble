---
name: manimble-new-deck
description: >-
  Create a new Manimble presentation (a Manim Slides deck Manimble opens and
  edits) from an outline, notes, a paper, a README or a plain description:
  makes the project folder with a theme, plans the slides, writes them with
  builds and animations, renders them to check, and tells the user how to
  open it. Triggers: "make a deck about X", "turn my outline/paper/notes into
  slides", "start a new Manimble presentation", "create a talk from this PDF",
  "new deck", "manimble-new-deck".
---

# Create a new Manimble deck

## 1. Settle the brief

From the request and the source material, work out: the title and speaker,
the audience and length (about one slide per minute), the theme, and where
the project goes. Ask only about what you can't infer; default to the folder
the user is in, the **Midnight** theme for a talk and **Paper** for a lecture
or handout, and 8–12 slides.

Read the source fully first (outline, paper, notes, figures, data files). For
a paper: the problem, the key idea, the method in one picture, two or three
results with their figures, and the take-home message.

## 2. Make the project

A project is:

```
Talk Name/
├── assets/          pictures and data the slides use
└── deck/
    ├── common.py    the Deck base class and theme constants
    ├── slides.py    the slides (split into several .py files for a long talk)
    ├── order.txt    slide class names in show order
    └── manim.cfg    background colour and resolution
```

Refuse to write into a folder that already has a `deck/`; pick another name.

**common.py**: copy a Manimble theme if one is installed, from the first that
exists of `$MANIMBLE_ENGINE/manimble/themes/`,
`~/Applications/Manimble.app/Contents/Resources/engine/manimble/themes/`,
`/Applications/Manimble.app/Contents/Resources/engine/manimble/themes/`, or the
Manimble checkout's `engine/manimble/themes/`. The themes are `midnight`,
`paper`, `slate`, `ember`, `parchment`, `chalkboard` and `terminal`. Otherwise
write this (Midnight), adjusting the constants for another look:

```python
"""Shared base class and theme of the deck."""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Midnight"
BACKGROUND = "#000000"
FONT = "Helvetica Neue"
TEXT_COLOR = "#FFFFFF"  # titles and body text
MUTED_COLOR = "#BBBBBB"  # subtitles and captions
ACCENT = "#7C5CFF"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
```

Keep the constants as plain string literals (Manimble reads and rewrites
them). Fonts must exist on the machine: Helvetica Neue, Avenir Next, Palatino
and Menlo do on macOS; elsewhere use a font that `fc-list` shows.

**manim.cfg** (background equal to `BACKGROUND`):

```ini
[CLI]
background_color = #000000
pixel_width = 1280
pixel_height = 720
frame_rate = 30
```

Copy the figures and data the slides need into `assets/` and refer to them as
`ASSETS / "fig2.png"`.

## 3. Plan, then write

Write the plan as a short list (class name, title, what is on it, its builds)
and show it to the user before writing many slides, unless they asked you to
just go ahead.

Then write the slides following the **manimble-slides** skill: one object per
statement with literal `.move_to((x, y, 0))` positions inside the ±7.1 × ±4
frame, the theme constants for fonts and colours, `self.next_slide()` between
builds, `self.wait(0.1)` at the end of a build that only adds objects, and
speaker notes as `self.next_slide(notes="...")` at the top of `construct`.

The title slide, in the layout Manimble's own new decks use:

```python
from common import *


class Title(Deck):
    def construct(self):
        title = Text("Reading the Genome", font_size=64, font=FONT, color=TEXT_COLOR).move_to((0, 0.7, 0))
        self.add(title)
        subtitle = Text("Ada Lovelace · 24 November 2026", font_size=32, font=FONT, color=MUTED_COLOR).move_to((0, -0.8, 0))
        self.add(subtitle)
        self.wait(0.1)
```

Good slides here are short: a title at about `font_size=40` near
`(x, 3.1, 0)`, at most five bullets of a few words at 28–32, one idea per slide,
figures large. Use animation where it explains (build a diagram step by step,
transform an equation, trace a curve), not as decoration.

Write `order.txt` with every slide's class name in order.

## 4. Check and hand over

- `python -m py_compile` every file.
- Render the deck with the **manimble-check** skill, look at every PNG, and fix
  errors, text off the edge, overlaps and crowding.
- Tell the user where the project is and how to open it: in Manimble,
  **File ▸ Open Deck or Project…** and choose the project folder; or present it
  without Manimble with `manim-slides render slides.py <classes in order>`
  then `manim-slides present <classes>` from the `deck` folder.
- Say what you couldn't do (a figure you didn't have, a fact you left as a
  placeholder) instead of inventing it.
