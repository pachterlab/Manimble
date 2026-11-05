# Deck file format

A Manimble deck is a standard [Manim Slides](https://manim-slides.eertmans.be) project. Manimble adds nothing that
stops the deck from being rendered or presented with Manim Slides directly; it only adds a few files of its own and
comments that mark the code it wrote. This page lists them.

## Folder layout

```
Project/
├── assets/                  pictures and data shared by the deck
└── deck/
    ├── common.py            the Deck base class and theme constants
    ├── slides.py            slide classes (any number of .py files)
    ├── manim.cfg            Manim settings: background colour, resolution, frame rate
    ├── order.txt            the slides of the show, in order
    ├── manimble_helpers.py  helper functions Manimble adds when needed
    ├── feedback.json        feedback notes
    ├── script.json          the presentation script and voice settings
    ├── present.json         chapters and link regions for the animated show (optional)
    ├── *.plot.json          what each Python plot runs
    ├── *.png, *.jpg …       pictures inserted, pasted or extracted in Manimble
    └── slides/              animation builds made by Manim Slides
```

## Slides

Manimble treats every class with a `construct` method, in any `.py` file of the deck folder, as a slide. The class
name is the slide's name. Slides usually derive from a `Deck` class in `common.py`, which itself derives from Manim
Slides' `Slide`.

## order.txt

The class names of the slides in the show, separated by spaces or new lines:

```
TitleSlide Motivation Method Results Summary
```

Without an `order.txt`, every slide in the deck is in the show. With one, slides that aren't listed are *unused*:
**View ▸ Show Unused Slides** shows them.

## manim.cfg

Manim's configuration file. Manimble reads the background colour from it and writes it when you change the theme or
apply dark mode to the deck. A standard deck renders at 1280 × 720:

```ini
[CLI]
background_color = #000000
pixel_width = 1280
pixel_height = 720
frame_rate = 30
```

## Theme constants

A deck made with a theme has these constants in `common.py`, which Manimble reads and writes:

| Constant | Used for |
|---|---|
| `THEME` | The theme's name |
| `BACKGROUND` | The background colour, also written to `manim.cfg` |
| `FONT` | The font of text that Manimble inserts or types into layouts |
| `TEXT_COLOR` | The colour of that text, and of inserted shapes, lines and formulas |
| `MUTED_COLOR` | The colour of subtitles and captions |
| `ACCENT` | A highlight colour for the deck's own use |

Keep their values as plain string literals so Manimble can read them.

## Marks in the code

Manimble marks some of the code it writes with comments, so it can find that code again later. Leave the marks in
place; deleting one turns the code into ordinary code that Manimble no longer manages.

| Mark | On |
|---|---|
| `# manimble` | A line that inserted an object |
| `# manimble hidden` | The class line of a hidden slide |
| `# manimble notes`, `# manimble build notes` | The `self.next_slide(notes=...)` calls that hold speaker notes |
| `# manimble background` | The line that sets the slide's background |
| `# manimble page number` | A slide number |
| `# manimble group` | A group made with Arrange ▸ Group |
| `# manimble pen` | A pen stroke |
| `# manimble build`, `# manimble build end` | The shifts that move an object in one build only |
| `# manimble box ...` | The size of a text box, on the line of its text |
| `# manimble placeholder` | An empty text placeholder of a slide layout, shown only in the editor |
| `# manimble theme` | A theme applied to one slide only |
| `# manimble new slide`, `# manimble new build` | Slides and builds added in Manimble |

Other attributes Manimble writes:

- `alt_text = "..."` at the top of a slide class: the slide's [alt text](../guide/notes.md#alt-text).
- `.set(manimble_link="https://...")` on a text or formula: its [hyperlink](../guide/text.md#hyperlinks).

## manimble_helpers.py

Some formats need small helper functions, such as the underline, strikethrough and per-character highlight drawn
under text. Manimble adds them to `manimble_helpers.py` in the deck folder the first time they're needed, and imports
them in the slide's file. The file is plain Manim code and is packaged with the deck.

## present.json

An optional file that gives the animated show chapters and clickable regions:

```json
{
  "sections": [0, 4, 9],
  "links": {
    "3": [[0.10, 0.45, 0.80, 0.95, "https://example.com/paper"]]
  }
}
```

- `sections` lists the indices of the slides that start each chapter, counting from 0 in `order.txt`. During the
  show, <kbd>1</kbd>–<kbd>9</kbd> jump to the chapters, and clicking the bottom strip of the slide jumps to the
  chapter under the pointer.
- `links` maps a slide index to regions `[x0, x1, y0, y1, url]`, given as fractions of the slide's width and height,
  with *y* measured from the top. Clicking a region during the show opens its URL.

Hyperlinks set with **Format ▸ Hyperlink…** don't need this file.

## Files outside the code

`feedback.json`, `script.json` and `*.plot.json` hold feedback notes, the presentation script and the code of Python
plots. They are JSON files that Manimble manages; editing them by hand is not necessary. Like the code, they live in
the working copy while the deck is open and are written to the original deck when you save.
