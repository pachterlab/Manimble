# Manimble

A native macOS editor for [Manim Slides](https://github.com/jeertmans/manim-slides) decks, in the spirit of Keynote.
Click a text, formula, image, line or shape on a slide and edit it directly. Every edit is written back to your
Python source, and you can watch the lines change in the built-in code pane.

## Run it

```bash
git clone https://github.com/pachterlab/Manimble.git && cd Manimble
./install_manimble.sh   # installs dependencies and builds the app
open "$HOME/Applications/Manimble.app"  # File ▸ Open Deck… (try examples/hello/deck)
```

Prefer not to build from source? Download `Manimble-macOS.zip` from the
[latest release](https://github.com/pachterlab/Manimble/releases/latest), unzip it into
`~/Applications`, then `git clone` the repository above (for the engine and examples) and run
`./setup_python_env.sh` instead of `install_manimble.sh` to install the Python/Manim/TeX
dependencies without needing Xcode. The app is ad-hoc signed, so the first launch needs
right-click ▸ Open (or `xattr -cr ~/Applications/Manimble.app`) to get past Gatekeeper.

Requirements:
- macOS 13+, Xcode or the command line tools, and Homebrew. The installer downloads
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), creates a Python environment in
  `~/Library/Application Support/Manimble/python`, and installs Manim, Manim Slides (no Qt / PySide6: Manimble plays animations itself), Pillow,
  python-pptx and FFmpeg when they are missing. For formulas it installs
  [BasicTeX](https://www.tug.org/mactex/morepackages.html) plus the LaTeX packages manim uses (about 400 MB, against
  several GB for the full MacTeX), and asks for your password once because TeX lives in a system folder. An
  existing TeX installation such as MacTeX is used as it is. A deck that needs another LaTeX package can add it with
  `sudo tlmgr install <package>` (manim's Chinese `ctex` template, for instance, needs `ctex`).
- Keynote is needed only for Keynote import and export.

On launch Manimble checks `$MANIMBLE_PYTHON`, your saved choice, its installed Python environment, a checkout-local
`.venv`, and Python on your login shell's `PATH`. It uses the first one that can import Manim and Pillow, so no
Python chooser is needed after `install_manimble.sh` completes.

A deck is a folder of scene classes (`class MySlide(Slide): def construct(self): ...`). If it has an `order.txt`
(scene names separated by spaces/newlines), only those scenes, in that order, are the slides of the talk;
otherwise every scene class is listed.

`~/Applications/Manimble.app` carries the engine and uses the installed Python environment. Rerun
`install_manimble.sh` after pulling changes.

## Command-line tools

`manimbler` inspects, extracts, and converts portable `.manimble` projects. The installer places it at
`~/.local/bin/manimbler`; it can also be run as `./manimbler` from this repository.

```bash
manimbler --check deck.manimble
manimbler --info deck.manimble
manimbler --extract deck.manimble --output deck-unpacked
manimbler --convert deck.manimble --output talk.mp4
manimbler --convert deck.manimble --slides 1-3,7 --output excerpt.mp4
manimbler --convert deck.manimble --to pdf --output handout.pdf
manimbler --convert deck.manimble --to html --output presentation.html
```

`--check` verifies the archive and its referenced media. `--info` shows slide order, build counts, package sizes, and
estimated MP4 running time. `--extract` creates an editable project directory, defaulting to the package name without
`.manimble`. Conversion follows `order.txt`; `--slides` accepts 1-based numbers, ranges, and scene names, and keeps
their deck order. The output defaults to the package name with the requested format's extension. MP4 conversion plays
each build once at its recorded playback rate and holds its final frame for two seconds; use `--hold 0` for no pauses
or `--fps` to change the frame rate. MP4 output has no audio. PDF and HTML export use the installed Manim Slides
environment. Keep the generated HTML alongside its `_assets` directory when sharing it. Use `--force` to replace
existing conversion output.

The repository is organised so other front ends can share the same engine: the Python engine in [`engine/`](engine) does
everything that involves manim and your source code and talks a small JSON protocol ([`docs/protocol.md`](docs/protocol.md));
the macOS app in [`apps/macos`](apps/macos) is one front end. A Windows front end is not started
([`apps/windows`](apps/windows)).

## How it works

```
Manimble.app  (Swift, AppKit, Metal)                 engine/manimble  (Python)
 ├ slide list, canvas, inspector, code pane     ◄─►   rpc.py      JSON lines over stdio
 ├ Metal canvas: exact frame when idle,                core.py     scheduling, caching, edits, undo
 │   backdrop + per-object sprites while editing        srcedit.py  AST analysis → minimal source patches
 └ working copy of the deck (Workspace.swift)           worker.py   runs scenes in manim, records what it sees
```

* The **worker** runs your real scene code with animations skipped. It records, for every Text / MathTex / image /
  line / shape / table, the call stack that created it and every layout call (`move_to`, `shift`, `next_to`, `set`,
  `arrange`, `.animate…`) that touched it or its groups. It saves a full frame per build, a backdrop, and a
  transparent image per object.
* An **edit** becomes the smallest AST-located patch: rewrite a literal, change a `move_to` / `set` / `scale`
  argument, add a keyword argument, or append `.shift(...)` / `.put_start_and_end_on(...)`. Each patch is
  **verified by re-rendering**; if later code overrides it, it is reverted and the next strategy is tried, ending in a
  message that names the line controlling the position.
* The **canvas** composites the backdrop and sprites on the GPU, so moving, resizing and retyping show instantly
  while the real re-render runs in the background.
* Edits go to a **working copy** of your deck (`~/Library/Application Support/Manimble/work`); nothing touches the
  original until you Save.

## Features

**Editing on the slide**
- Select, move (drag, arrow keys, ⇧ for larger steps) and resize (corner handles, scales about the centre) text,
  formulas, images, shapes, lines/arrows and tables. Numeric X / Y / width / height in the inspector.
- Text: retype in a multi-line box (↵ new line, ⌘↵ or click away to apply, esc to revert; bold/colour ranges follow
  the words they cover), font family, bold, italic, size (field + stepper), colour.
- **Home bar** above the slide, in the spirit of PowerPoint's: font, size (field, stepper, A↑ A↓), bold, italic,
  underline, strikethrough, superscript/subscript, highlight colour, text colour (the A opens the colour panel), clear
  formatting; bullets, numbering, indent/outdent, left/centre/right alignment, line spacing, columns; grid lines,
  snapping and guides. Everything
  is also in the Format, View and Insert menus with shortcuts (⌘B ⌘I ⌘U, ⇧⌘+ ⇧⌘_, ⇧⌘8 ⇧⌘7, ⇧⌘[ ⇧⌘], ⌘L ⌘E ⌘R).
  Each one is a source edit:
  - Underline and strikethrough: Manim text has neither, so Manimble adds a small `manimble_helpers.py` to the deck
    (`strike()` and `underline()` group the glyphs into visual lines and draw one line per line of text) and writes
    `t.add(strike(t, color=...))  # manimble strike`; the lines move, scale and are deleted with the text. The text
    must be held in a variable; an element inserted with the toolbar is given one automatically.
  - Highlight: `.add_background_rectangle(color=..., opacity=0.6)` on the object; "No Highlight" removes it.
  - Superscript and subscript swap the characters selected in the inspector's text box for their Unicode
    super/subscript forms (digits, signs, most letters), since a `Text` has no per-character rise. Formulas take
    `^{}` / `_{}` in the LaTeX sheet.
  - Bullets, numbering and indent rewrite the lines of the string (`• `, `1. `, four spaces); they apply to the lines
    selected in the text box, or all lines.
  - Alignment turns a multi-line `Text("a\nb")` written in the slide into `Paragraph("a", "b", alignment="center")`,
    which Manimble edits like any text. Justify is not possible for text with manual line breaks.
  - Line spacing sets `line_spacing=` (PowerPoint's 1.0 is Manim's default 0.3; 1.5 ≈ 0.8, 2.0 ≈ 1.3).
  - Columns split the lines of a text into `VGroup(Text(...), Text(...)).arrange(RIGHT, buff=0.8, aligned_edge=UP)`;
    one column merges them back.
  - Clear formatting removes bold, italic, colour, per-range styles (`t2c` …), line spacing, highlight, underline and
    strikethrough; font and size stay.
- Arrange (inspector): X, Y, width, height, rotation in degrees (rewrites or appends `.rotate(... * DEGREES)`), and for
  pictures and shapes a *Keep aspect ratio* switch: off, width and height stretch independently
  (`width=`/`height=` arguments, `.set(width=...)`, or `.stretch_to_fit_width/height`).
- Grid lines (View menu, ⌥⌘G) one manim unit apart with the axes marked. Snapping (⌥⌘S): while dragging, an object's
  edges and centre snap to the other objects, your guides, the slide's edges and centre, and the grid when shown;
  orange lines show the match. Hold ⌥ to drag freely.
- Guides: Add Vertical / Horizontal Guide (View menu or the Home bar) puts a cyan guide at the centre; drag it into
  place, drag it off the slide to remove it (Clear Guides removes all). Guides are remembered per deck.
- Drawing (Insert ▸ Draw, or the Shape menu in the toolbar): choose line, arrow, double arrow, rectangle or ellipse,
  then drag on the slide; ⇧ snaps the angle or makes a square/circle. The element is inserted with those endpoints or
  that box.
- **Pen** (Insert ▸ Draw ▸ Pen, ⇧⌘P, or the Shape menu): draw freehand on the slide. Each stroke is simplified and
  written as one line, `self.add(VMobject(color=..., stroke_width=6).set_points_smoothly([...]))  # manimble pen`, so
  it is a real object of the slide: select it to move, resize, recolour or delete it. The pen stays active for the next
  stroke; esc ends it. Insert ▸ Draw ▸ Pen Color picks the colour (remembered).
- Formulas: LaTeX sheet with a live preview compiled by your real TeX; applies to a shared constant
  (e.g. a `FORMULA` defined once and used on several slides) everywhere, or to this slide only.
- Lines and arrows: drag either end (⇧ snaps the angle to 15°).
- Tables: edit the cells as text (one row per line, comma-separated).
- Shared constants (a title, a font name, …) are recognised and edited at their definition.

**Insert** (toolbar and Insert menu)
- Text, formula, shapes (rectangle, rounded rectangle, circle, ellipse, triangle, line, arrow, double arrow), table,
  image; or draw lines, arrows, rectangles, ellipses and pen strokes by dragging on the slide.
  They appear instantly and are written as one marked line (`self.add(...)  # manimble`) at the build you are on.
  The Delete key removes elements inserted this way.
- **Extract Elements from Image…** (Insert menu, with a picture selected): the system's subject-lifting model
  (macOS 14+) finds the separate things in the picture (the five people in a photo, the parts of a figure). Tick the
  ones you want and each becomes its own transparent PNG in the deck folder and its own `ImageMobject`, placed exactly
  where it is in the picture, so it can be moved, resized and animated on its own. The original picture stays; one ⌘Z
  removes all the parts.
- **Slide Numbers…** (Insert menu): a number on every slide of the show, bottom right / centre / left, with a start
  number, "don't show on the title slide" and "show the total" (`3 / 10`). Each is a `Text` written at the top of
  `construct()` with a `# manimble page number` marker, so it is an ordinary object (move it, change its size) and
  the numbers are renumbered in the same undo step whenever slides are added, duplicated, deleted, skipped or
  reordered. Open the dialog again to change the options or remove the numbers.

**Slides and decks**
- Format Background (right-click the slide, or Format ▸ Background…), as in PowerPoint: a solid colour or a picture
  (stretched to fill the slide), a transparency slider with a live preview, and Apply / Apply to All / Reset
  Background. It is written as one marked line at the top of `construct()` (`self.camera.background_color = ...` or
  a full-frame `ImageMobject` at the back); transparency blends with the deck's `manim.cfg` background colour.
- Dark mode (View ▸ Dark Mode, ⌃⇧⌘D, or the moon in the toolbar): near-white and near-black colours are shown
  swapped (lightness mirrored, hue kept, so `WHITE` ↔ `BLACK`, `GRAY_B` ↔ `GRAY_D`); saturated colours are untouched.
  It is view-only and applies to the canvas, thumbnails and the built-in slideshow; each object is mapped on its own
  GPU layer, so edges stay clean. View ▸ Recolor Images Too turns it off for pictures. Format ▸ Apply Dark Mode
  to Deck… writes the same flip into your code as one undoable step: neutral colour literals and grey names are swapped,
  `manim.cfg`'s background too, and objects drawn in a default colour get an explicit `color=` (tables get
  `line_config`/`element_to_mobject_config`). Every slide is re-rendered twice, so it takes about a second per slide.
- Invert Colors (View ▸ Invert Colors, ⌃⇧⌘I): the classic display invert, every colour becomes its complement
  (orange ↔ blue, white ↔ black). Also view-only, with Format ▸ Apply Inverted Colors to Deck… to write it the same way
  (manim's colour names such as `ORANGE` become the hex of their complement).
- Slide list with thumbnails, builds strip for every `next_slide()` stop, ⌘↑/⌘↓ and ⌘[ ⌘] navigation.
- Slide menu: New Slide (with the toolbar's New Slide button): choose a layout as in PowerPoint: Title Slide, Title and
  Content (⇧⌘N), Section Header, Two Content, Title Only or Blank (no text at all). The placeholders are plain `Text`
  objects, bullets included; Duplicate, Delete, Move Up/Down edit the scene class and `order.txt`, fully undoable.
- Bulleted and numbered lists (Home bar, Format menu, ⇧⌘8 / ⇧⌘7) prefix the lines of a text with `• ` or `1. `, and
  Increase / Decrease Indent (⇧⌘] / ⇧⌘[) indent the selected lines; all of it is retyped into the `Text` string.
- **Speaker notes**: the box under the slide (View ▸ Speaker Notes, ⌥⌘K, to hide or show it; drag the divider above
  it to give the notes more or less room, the height is remembered). Notes are saved as
  `self.next_slide(notes="...")  # manimble notes` at the top of `construct()`, which is what manim-slides' own
  presenter shows for the slide; they do not add a build.
- Delete Slide: Slide menu (⇧⌘⌫), the Delete key in the navigator, or right-click a slide; ⌘Z brings it back.
  Right-clicking a slide in the navigator also offers New Slide After This (with layouts), Duplicate, Hide and Skip.
- Hide Slide (Slide menu, ⇧⌘H, or right-click): the slide stays in the deck and the navigator (dimmed, with a
  struck-through number) but is left out of the slideshow, the presenter view and the PDF, PowerPoint and Keynote
  exports, like PowerPoint's hidden slides. It is a `# manimble hidden` comment on the class line; Unhide removes it.
- Slide menu: Skip Slide removes a scene from the show without deleting its code. View ▸ Show Unused Slides reveals
  skipped scenes and other scene classes outside `order.txt`; select one and choose Restore Slide to Show to append it.
- Drag a slide in the navigator to reorder the show; the change is saved to `order.txt` and can be undone.
- Python source pane with syntax colours, highlighted changed/selected lines, and always-visible scroll bars. Click the
  code to edit that scene class, then click outside to update the slide. Syntax errors leave the draft in the editor;
  render errors keep the code in the working copy and appear above the editor while the last good frame remains visible.
- Working copy with **Save to Original**, **Revert**, an "edited" indicator, and a prompt on close/quit; the render
  cache lives outside your deck.
- Undo/redo (⌘Z / ⇧⌘Z) for every edit while the app is open.

**Play and share**
- Built-in full-screen slideshow (Play menu: ⌥⌘P from the current slide, ⌥⌘⇧P from the beginning) with fades,
  progress bar, counter, click/keyboard navigation and blank screen.
- **Presenter View** (Play menu, ⌃⌘P): the current slide, the next slide or build, the speaker notes in large type,
  the slide counter, a clock and an elapsed-time timer (click it, or press R, to reset). With a second display the
  audience sees the full-screen slideshow there while you see the presenter window; with one display it is a
  rehearsal view. Both follow the same keys: → / space / click next, ← back, N next slide, B blank, esc end.
- **Preview Current Slide’s Animations** (Play menu, ⌥⌘R) builds the selected scene if needed, then plays its
  real animations and builds inside the editor. Each build pauses at its end; click the slide or press → to play the
  next build. Use the player controls to pause or scrub, and ← to go back.
- **Play with Animations** (Play menu: ⌥⌘A from the current slide, ⌥⌘⇧A from the beginning): builds any slides
  whose code changed since they were last built (progress in the top-right pill), then plays the real animations
  full-screen in a native player (AVFoundation), so no Qt presenter is needed. Builds go into the working copy's
  `slides/` folder, so the original's builds are untouched. Keys: → / ↓ / return / click next, ← / ↑ / right-click
  previous (shown at its end), space play/pause, R replay, V reverse, N next slide, 1–9 jump to a chapter, B blank,
  P progress, Home/End, esc / Q end. Loops, auto-next and playback rates from `next_slide(...)` are honoured, and
  dark mode / inverted colours apply as in the slideshow. **Presenter View with Animations** (Play menu, ⌃⌘A) is
  the same Presenter View over the animated show: the current slide plays live (mirroring the audience display, with
  a playing / paused / build-done badge), the next panel shows how the next build ends, and notes, counter, clock and
  timer work as above; with one display it is a rehearsal view. Chapters and clickable link regions come from the deck's `present.json`
  (`{"sections": [scene indices], "links": {"<scene index>": [[x0, x1, y0, y1, url], ...]}}`, fractions of the
  slide, y from the top, scene indices counting `order.txt`) or, without one, the `SECTION_SCENE_INDICES` /
  `REFERENCE_LINKS` constants of a custom `present.py`; clicking the bottom 6% of the slide jumps to the chapter
  under the pointer.
- File ▸ Export To ▸ Python (whole deck in one file)… writes the deck as a single `.py`: helper modules inlined, the
  slides in show order, a `SLIDES` list at the end. (The deck's own `.py` files are already the editable source that
  every edit is written to; this is a one-file copy for sharing, best kept in the deck folder so relative paths work.)
- File ▸ Save Project Copy… writes an editable, portable project folder. File ▸ Package for Sharing… creates one
  `.manimble` file that can be transferred and opened in Manimble. Both include existing Manim Slides builds and media,
  scan files opened while scenes render, preserve project-relative paths, and report missing or out-of-project
  dependencies. The Share menu stays focused on PDFs and presentation formats.
- **Export to PowerPoint (.pptx) and Keynote (.key)** (File ▸ Export To, and the Share menu). One slide per build or
  per slide. *Editable* mode keeps text as real text boxes (font, size, colour, bold/italic) over a picture of
  everything else; *Pictures only* gives the exact rendered frames. Keynote export builds the .pptx and has Keynote
  convert it through AppleScript.

**Import** (File ▸ Import ▸ PowerPoint / Keynote)
- Turns a `.pptx` (or a Keynote `.key`, read through Keynote) into a new Manim Slides deck in a folder you choose,
  then opens it. One scene per slide; each text box becomes one `Text(...)` (font, size, colour and bold/italic down to
  the word, alignment, lines wrapped to the box with the real font metrics and PowerPoint's line spacing), pictures are saved to `assets/` and become `ImageMobject(...)`, rectangles, ellipses,
  rounded rectangles, triangles and lines become manim shapes with their fill and outline, tables become `Table(...)`,
  speaker notes are kept as comments, slide background colours are kept. Every element is one line in the scene, so
  it is editable in Manimble like anything else.

**Terminal**
- A docked terminal (View ▸ Show Terminal, ⌥⌘T, or the toolbar button) running your login shell in the project repository (the original deck's git root, or its parent folder; View ▸ Terminal Starts in Working Copy switches it to the *working copy*, the folder the slides are rendered from)
  of the deck, with a "Run claude" shortcut for [Claude Code](https://claude.com/claude-code). Edits made there (by
  Claude or by hand) are noticed within about two seconds; the slide you are looking at is re-rendered first and
  refreshes on screen by itself (about 1–3 s in total), the other slides re-render in the background.
- Several terminals, VS Code style: the + in the terminal header (or View ▸ New Terminal, ⇧⌥⌘T) opens a new tab,
  and once there is more than one terminal they are listed vertically on the right (click to switch, × to kill).
  The split button (View ▸ Split Terminal, ⌘\) opens another shell beside the active one in the same tab; split
  tabs are grouped in the list with ┌ └ lines. The header's Run claude, restart and kill buttons act on the active
  terminal; killing the last one hides the terminal.

**Interface**
- Toolbar (insert, zoom, terminal, share), Keynote-style menus (File, Edit, Insert, Slide, Format, View, Play,
  Window), zoom (menu, pinch, ⌘= / ⌘- / ⌘0, pan by scrolling), draggable remembered dividers, a dark/violet look.

**Performance**
- Dedicated render processes, so edits never queue behind background pre-rendering; the on-screen slide renders first.
- Simple animations (fade, create, write, grow, replace) are fast-forwarded without manim's expensive setup,
  verified frame-identical against the real pipeline on a 46-slide deck.
- Optimistic previews for text, formula, style and insert changes.
- Roughly 170 MB for the app plus about 285 MB for the three Python processes.

## Known issues and limitations

**Import**
- Animations, transitions, gradient/picture backgrounds, charts, SmartArt, bullets and per-run colours or sizes inside
  one paragraph are not imported; unusual autoshapes become rectangles (with a warning). Text is positioned by its box,
  so wrapping and line breaks can differ from PowerPoint. Space between paragraphs is dropped (a manim `Text` has
  even line spacing), and a paragraph with a different size, or a centred or right-aligned paragraph, becomes its own
  `Text` because a `Text` has one size and left-aligns its lines. Slides that are not 16:9 are stretched onto a 16:9 frame.

**Export**
- PowerPoint/Keynote files contain pictures for formulas, shapes, lines, tables, images and plots; only plain text is
  editable. Animations are not exported (builds become separate slides). Text positions are approximate where a font
  is missing on the target machine. A Keynote export can stall if Keynote shows a dialog (for example a missing font).

**Editing**
- An object positioned by a loop plus `arrange()` (for example a list built in a comprehension) can be retyped but
  not moved on its own. A line that is created in a loop moves every copy.
- Bulk objects (more than 12 created from the same line, such as scatter dots) are not individually editable.
- Resizing is uniform about the centre; there is no separate width/height for rectangles and no anchored corner
  resize.
- Text styling applies to the whole object; there is no per-word bold or colour. The font family is usually a
  deck-wide constant, so changing it changes every slide. Bold and italic apply to plain text, not formulas.
- Alignment and columns need a `Text("...")` with a plain string written in the slide itself (not made by a helper
  function such as `label()`); converting to columns drops per-range styles and alignment. Underline, strikethrough and
  highlight work on helper-made text too, but underline/strikethrough need the object in a variable. The lines are
  drawn in the text's colour at the time; recolouring the text later leaves them. `manimble_helpers.py` becomes part
  of the deck (it is plain Manim code and is packaged with the project). Superscript/subscript cover only the
  characters Unicode provides (no q, and few capitals in subscript).
- Rotation is read from the object's own `rotate()` calls, so a rotation applied by a group or computed in code shows
  as 0°. Width/height show Manim's measure (all curve control points), which for circles and curves is a few percent
  larger than the drawn outline.
- Changing a shared constant (or a formula whose parts the code selects by name with `get_part_by_tex`) can break
  other slides. Only the slide on screen is re-rendered, so the breakage shows later as an error badge. A "re-render
  the other slides that use this constant and warn" check is not built.
- Text produced by f-strings or other computation cannot be retyped on the canvas; edit its Python code in the source pane.
- Delete only works for elements inserted with the toolbar. Elements that were already in your code must be removed
  in the source.
- Table editing needs literal table data; cells are rendered as math.
- Images cannot be replaced, cropped or re-linked from the UI.
- Drawing order is approximated when text sits between filled shapes; the canvas is exact when idle.

**Dark mode and inverted colours**
- The view-only modes composite the backdrop and per-object sprites, so drawing order is approximate like while
  editing, and anything not tracked as an object (plots, bulk dots) is mapped as part of the backdrop. Exports, PDFs and
  Play with Manim Slides show the real colours.
- Applying them to the deck does not change pictures, colours computed in code, per-word colours (`t2c`) or gradients,
  so the result can differ from the view-only mode there (images in particular).

**Animations**
- Animations have no direct editing controls. You can edit `self.play(...)` calls in the Python pane; inserted elements
  still appear (`self.add`) rather than animating in.

**Presenting and sharing**
- The full-screen slideshow shows stills of each build scaled up from 1280×720, with no presenter display, notes or
  timer. The selected slide's animations can be previewed inside the editor.
- Play with Animations and the animation preview build with `python -m manim render` (what `manim-slides render`
  runs) in the chosen Python. The first run on a deck with no builds renders every slide (minutes). Slides built outside Manimble are trusted unless you edited
  them. Manimble's own renders keep manim's Text/TeX cache under `~/Library/Application Support/Manimble/cache`; presenting and exporting render through manim-slides' `Slide`, which writes the deck's `../media` folder.
- The animated player shows no pointer cursor over link regions, and V replays forwards when Manim Slides did not
  write a separate reversed clip. In Presenter View, R resets the timer, so replaying a build is done with ← then →.
  Presenter View with Animations is untested on a real second display (checked as a one-display rehearsal).
- New or duplicated slides are added to `order.txt` only: decks that keep their own hand-written lists (build
  scripts, footer progress tables) must be updated by hand.
- Dependency discovery is based on files opened while scenes render. Branches not executed during rendering can still
  refer to files Manimble has not seen; render every slide before packaging for sharing.
- Restored slides are appended to the show; use Move Slide Up/Down to choose their final position.

**App and environment**
- Undo history is kept in memory and lost on quit (the working copy is deleted on close, so use Save).
- If the app crashes, the working copy is left behind and replaced on the next open of that deck, so unsaved edits
  from a crash are not recovered.
- The terminals restart (ending any running `claude` sessions) when you open a different deck, and does not remember
  its scrollback between launches. Claude edits the working copy, so use Save to Original afterwards.
- The app is ad-hoc signed, not notarised (the release workflow supports notarization once a
  Developer ID is configured; see `.github/workflows/release.yml`).
- Re-rendering a slide after an edit takes 0.2–0.8 s (every object is re-created by manim; a slide with 40 formulas
  sits at the top of that range). LaTeX results are cached per deck under the render cache in
  `~/Library/Application Support/Manimble/cache`, so a brand-new formula costs about half a second once.
- macOS only. There are no automated tests; the app has headless self-test hooks (`MANIMBLE_SELFTEST`,
  `MANIMBLE_TEST_FORMULA`, `MANIMBLE_TEST_BG`, `MANIMBLE_TEST_DARK`, `MANIMBLE_TEST_FORMAT`, `MANIMBLE_TEST_PLAY`, `MANIMBLE_TEST_SPLIT`, `MANIMBLE_TEST_TERM`) used for development
  checks.

## Roadmap (missing, roughly in order of value)

1. **Animations panel**: list a build's `self.play(...)` calls, add simple ones to the selected object (fade, write,
   create, grow, move, scale, indicate), reorder, delete, set duration, and preview a build as a short clip.
2. Duplicate / copy / paste elements; Delete for any element; Arrange (bring forward, send back, align, distribute).
3. Per-word text styling; per-element font; justified and wrapped text (`MarkupText`); rotation by dragging.
4. Shared-constant safety: re-render the other slides that use a changed constant and warn before it is saved.
5. PDF/video export at full resolution.
6. Go to Slide; multi-slide selection; find / replace.
7. Persistent undo history; crash recovery of the working copy.
8. Slide transitions, themes / master slides, and a theme picker for new decks.
9. Keep build scripts and progress tables in sync when slides are added, moved or deleted.
10. Image tools: replace, crop, mask; SVG and PDF insertion.
11. Packaging: a Developer ID for notarisation, and an automated test suite.

## License

BSD 2-Clause, see [LICENSE](LICENSE). Manimble links against [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(MIT) and installs Manim, manim-slides and python-pptx into its app environment, each under its own license.

## Layout of this repository

```
engine/                  platform-independent Python engine (rpc, core, srcedit, worker, export, importer)
docs/protocol.md         the engine's JSON-lines protocol
apps/macos/              the macOS app: Package.swift, Sources/Manimble (AppKit, Metal, SwiftTerm),
                         build_app.sh, assets/Manimble.icns, tools/make_icon.py
install_manimble.sh      installs dependencies and builds ~/Applications/Manimble.app
setup_python_env.sh      installs just the Python/Manim/TeX dependencies (used by install_manimble.sh,
                         and standalone for a downloaded prebuilt Manimble.app)
VERSION                  the app's version; the release workflow checks it against the git tag
.github/workflows/       CI build on every push, and the tag-triggered release that publishes
                         Manimble-macOS.zip to GitHub Releases
apps/windows/            placeholder with notes for a future Windows front end
examples/hello/deck/     a tiny deck to try Manimble on
LICENSE                  BSD 2-Clause
```
