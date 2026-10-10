# Manimble

A native macOS editor for [Manim Slides](https://github.com/jeertmans/manim-slides) decks, in the spirit of Keynote.
Click a text, formula, image, line or shape on a slide and edit it directly. Every edit is written back to your
Python source, and you can watch the lines change in the built-in code pane.

## Run it

```bash
git clone <this repository> && cd manimble
./install_manimble.sh   # installs dependencies and builds the app
open "$HOME/Applications/Manimble.app"  # File ▸ Open Deck… (try examples/hello/deck)
```

Requirements:
- macOS 13+, Xcode or the command line tools, and Homebrew. The installer downloads
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), creates a Python environment in
  `~/Library/Application Support/Manimble/python`, and installs Manim, Manim Slides with PySide6, Pillow,
  python-pptx, FFmpeg, and MacTeX when they are missing.
- Keynote is needed only for Keynote import and export.

On launch Manimble checks `$MANIMBLE_PYTHON`, your saved choice, its installed Python environment, a checkout-local
`.venv`, and Python on your login shell's `PATH`. It uses the first one that can import Manim and Pillow, so no
Python chooser is needed after `install_manimble.sh` completes.

A deck is a folder of scene classes (`class MySlide(Slide): def construct(self): ...`). If it has an `order.txt`
(scene names separated by spaces/newlines), only those scenes, in that order, are the slides of the talk;
otherwise every scene class is listed.

`~/Applications/Manimble.app` carries the engine and uses the installed Python environment. Rerun
`install_manimble.sh` after pulling changes.

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
- Text: retype, font family, bold, italic, size (field + stepper), colour.
- Formulas: LaTeX sheet with a live preview compiled by your real TeX; applies to a shared constant
  (e.g. a `FORMULA` defined once and used on several slides) everywhere, or to this slide only.
- Lines and arrows: drag either end (⇧ snaps the angle to 15°).
- Tables: edit the cells as text (one row per line, comma-separated).
- Shared constants (a title, a font name, …) are recognised and edited at their definition.

**Insert** (toolbar and Insert menu)
- Text, formula, shapes (rectangle, rounded rectangle, circle, triangle, line, arrow), table, image.
  They appear instantly and are written as one marked line (`self.add(...)  # manimble`) at the build you are on.
  The Delete key removes elements inserted this way.

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
- Slide menu: New, Duplicate, Delete, Move Up/Down (edits the scene class and `order.txt`, fully undoable).
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
- **Preview Current Slide’s Animations** (Play menu, ⌥⌘R) builds the selected scene if needed, then plays its
  real animations and builds inside the editor. Each build pauses at its end; click the slide or press → to play the
  next build. Use the player controls to pause or scrub, and ← to go back.
- **Play with Manim Slides**: builds any slides whose code changed since they were last built (progress in the
  top-right pill), then launches the deck's `present.py` (or `manim-slides present`) with the real animations. Builds
  go into the working copy's `slides/` folder, so the original's builds are untouched.
- File ▸ Save Project Copy… writes an editable, portable project folder. File ▸ Package for Sharing… creates one
  `.manimble` file that can be transferred and opened in Manimble. Both scan files opened while scenes render,
  preserve project-relative paths, and report missing or out-of-project dependencies. The Share menu stays focused
  on PDFs and presentation formats.
- **Export to PowerPoint (.pptx) and Keynote (.key)** (File ▸ Export To, and the Share menu). One slide per build or
  per slide. *Editable* mode keeps text as real text boxes (font, size, colour, bold/italic) over a picture of
  everything else; *Pictures only* gives the exact rendered frames. Keynote export builds the .pptx and has Keynote
  convert it through AppleScript.

**Import** (File ▸ Import ▸ PowerPoint / Keynote)
- Turns a `.pptx` (or a Keynote `.key`, read through Keynote) into a new Manim Slides deck in a folder you choose,
  then opens it. One scene per slide; text boxes become `Text(...)` (font, size, colour, bold/italic down to the word,
  alignment, lines wrapped to the box with the real font metrics, paragraphs stacked with their own line and
  paragraph spacing), pictures are saved to `assets/` and become `ImageMobject(...)`, rectangles, ellipses,
  rounded rectangles, triangles and lines become manim shapes with their fill and outline, tables become `Table(...)`,
  speaker notes are kept as comments, slide background colours are kept. Every element is one line in the scene, so
  it is editable in Manimble like anything else.

**Terminal**
- A docked terminal (View ▸ Show Terminal, ⌥⌘T, or the toolbar button) running your login shell in the *working copy*
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
  so wrapping and line breaks can differ from PowerPoint. Slides that are not 16:9 are stretched onto a 16:9 frame.

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
- Play with Manim Slides builds with `manim-slides render` from the chosen Python's `bin` folder. The first run on a
  deck with no builds renders every slide (minutes). Slides built outside Manimble are trusted unless you edited
  them. Rendering also writes manim's cache into the deck's `../media` folder.
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
- The app is ad-hoc signed, not notarised.
- Scene renders still take 0.4–1 s; brand-new LaTeX adds roughly half a second for TeX.
- macOS only. There are no automated tests; the app has headless self-test hooks (`MANIMBLE_SELFTEST`,
  `MANIMBLE_TEST_FORMULA`, `MANIMBLE_TEST_BG`, `MANIMBLE_TEST_DARK`, `MANIMBLE_TEST_PLAY`, `MANIMBLE_TEST_SPLIT`, `MANIMBLE_TEST_TERM`) used for development
  checks.

## Roadmap (missing, roughly in order of value)

1. **Animations panel**: list a build's `self.play(...)` calls, add simple ones to the selected object (fade, write,
   create, grow, move, scale, indicate), reorder, delete, set duration, and preview a build as a short clip.
2. Duplicate / copy / paste elements; Delete for any element; Arrange (bring forward, send back, align, distribute).
3. Per-word text styling; per-element font; non-uniform resize; rotate.
4. Shared-constant safety: re-render the other slides that use a changed constant and warn before it is saved.
5. Presenter display (current + next slide, notes, timer); animated playback across the full-screen slideshow; PDF/video
   export at full resolution.
6. Go to Slide; multi-slide selection; find / replace.
7. Persistent undo history; crash recovery of the working copy.
8. Slide transitions, themes / master slides, and a theme picker for new decks.
9. Keep build scripts and progress tables in sync when slides are added, moved or deleted.
10. Image tools: replace, crop, mask; SVG and PDF insertion.
11. Packaging: notarisation and an automated test suite.

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
apps/windows/            placeholder with notes for a future Windows front end
examples/hello/deck/     a tiny deck to try Manimble on
LICENSE                  BSD 2-Clause
```
