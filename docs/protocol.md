# Engine protocol

A front end starts the engine (`python -m manimble.rpc`, with `PYTHONPATH` pointing at `engine/` and
`MANIMBLE_PYTHON` naming the interpreter that has manim; it defaults to the interpreter running the engine) and talks to
it with **one JSON object per line** on stdin/stdout. stderr carries logs.

```
request : {"id": 7, "cmd": "scene", "name": "Welcome"}
response: {"id": 7, "result": { ... }}      or      {"id": 7, "error": "message"}
event   : {"event": "rendered", "name": "Welcome"}        (pushed at any time, no id)
```

Requests are handled concurrently, except `open`, which completes before later requests run. Edits are serialised by
the engine. All file paths in replies are absolute. Image coordinates are **frame pixels, origin top-left** (1280×720
unless the deck says otherwise).

The engine edits the deck folder it was opened on. Front ends should open a *working copy* and copy changes back on
"Save" (the macOS app does, see `apps/macos/Sources/Manimble/Workspace.swift`).

## Commands

| cmd | arguments | result |
|---|---|---|
| `open` | `deck` (folder with the scene `.py` files), `cache?` (cache folder, default `<deck>/.manimble`; renders and the workers' manim Text/TeX cache live there, so it should outlive the working copy) | `{ok: true}` |
| `state` | `current?` (slide on screen; re-rendered first if its source changed) | `{deck, path, scenes: [{name, file, line, status, hidden, thumb?, stops?, error?}], unusedScenes: [same summary], canUndo, canRedo, undoLabel, hasPresent}`; `scenes` follows `order.txt` and `unusedScenes` contains scene classes outside it; `status` is `ready`, `rendering`, `queued`, `stale`, `pending` or `error` |
| `scene` | `name` | see below; renders the slide if needed and waits |
| `edit` | `scene`, `stop`, `oid`, `op`, plus op arguments | `{ok, message?, siblings?, changed?: {file, ranges}, pageNumber?}` or `{ok: false, error}`; `pageNumber` is true when the edit changed a slide-number line |
| `edit_source` | `scene`, `file`, `expected` (source block shown when editing began), `text` (replacement Python class) | `{ok, changed?, error?}`; syntax errors reject the edit, render errors keep it in the working copy and return the error |
| `insert` | `scene`, `stop`, `kind` (`text`, `formula`, `rectangle`, `rounded`, `circle`, `ellipse`, `triangle`, `line`, `arrow`, `darrow`, `table`, `image`, `pen`), plus `tex?`, `rows?`, `cols?`, `file?`, and for drawn elements `sx, sy, ex, ey` (frame pixels: the line's ends or the box's corners; an image placed this way takes the box's width); `pen` takes `points` (`[[x, y], ...]` frame pixels), `color?` (`#RRGGBB`) and `width?` (manim stroke width) and writes a `VMobject(...).set_points_smoothly(...)  # manimble pen` | `{ok, message, line, file, changed, hidden}` |
| `insert_many` | `scene`, `stop`, `items` (a list of `insert` arguments without `scene`/`stop`), `replace_image?` (`{oid, file}`: point that picture at `file` in the deck folder, e.g. Extract Elements' filled-in background) | `{ok, message, file, changed}`; one undo step and one re-render for all of them. A direct `ImageMobject(...)` gets the new file as its first argument; a helper given the file name gets the new name, with the file copied next to the old picture |
| `insert_sprite` | same as `insert` | a sprite (below) previewing what the insert will look like |
| `sprite` | `kind` (`text`, `tex` or `code`), `value`/`code`, `font_size`, `color?`, `font?`, `weight?`, `slant?` | `{file, path, x, y, w, h, cx, cy}` (a transparent PNG, `cx`/`cy` = offset of its centre from the frame centre) |
| `slide` | `op` (`new`, `duplicate`, `delete`, `up`, `down`, `restore`, `hide`, `unhide`, `reorder`), `scene`, `index?`, `layout?` | `{ok, message, select}` (`select` = slide to show afterwards); `new` takes `layout` (`title`, `title_content` (default), `two_content`, `title_only`, `blank`): PowerPoint's Office Theme boxes written as `# manimble placeholder <role> x0 y0 x1 y1 size` comments (manim units), which render nothing and which the editor draws as "Click to add …" boxes; `restore` appends a scene that is not in `order.txt` to it; `hide` / `unhide` toggle a `# manimble hidden` comment on the class line (the slide stays in the show's order and the navigator but is left out of slideshows, the presenter, PDF, PowerPoint and Keynote exports); `reorder` inserts the scene at the zero-based slot `index` in the original list. When the deck has slide numbers they are renumbered in the same undo step |
| `page_numbers` | `op` (`get`, `set`, `remove`, `spread`), for `spread`: `scene` (its number line, as moved or restyled, is copied to every numbered slide, each keeping its own label); for `set`: `scene` (re-rendered to verify), `pos` (`DR`, `DOWN`, `DL`), `start`, `skip` (no number on the first slide), `total` (`3 / 10`), `size`, `sub` (sub-slide numbers: a slide with several builds shows `3 / 10 · 1/3`, counting on at every `next_slide()` through `sub_slides` in `manimble_helpers.py`; the count follows the slide's renders) | `get`: `{on, pos, start, skip, total, size, sub}`; otherwise `{ok, message, changed}`. Writes `self.add(Text("3 / 10", ...).to_corner(DR, ...))  # manimble page number ...` at the top of every construct() of the show; a moved or restyled number keeps its tweaks when renumbered. An `edit` that changed a number line returns `pageNumber: true` |
| `placeholder` | `scene`, `line`, `text`, `color?`, `op?` (`remove`) | `{ok, message, line, file, changed}`: replaces the placeholder comment on `line` with `self.add(Text(...).move_to(..., aligned_edge=LEFT/UL))  # manimble` at the box's left edge (empty text or `op: remove` deletes it) |
| `notes` | `op` (`get`, `set`), `scene`, `text?` | `get`: `{text}`; `set`: `{ok, message, changed}`. Speaker notes live in `self.next_slide(notes="...")  # manimble notes` as the first statement of construct(), which manim-slides' presenter shows for the first build; empty text removes it |
| `undo`, `redo` | | `{ok, label}` or `{ok: false, error}` |
| `present` | `scene?`, `height?` (720, 1080, 1440 or 2160; default 720) | `{ok}`; builds out-of-date slides (`python -m manim render`, no Qt needed) and sends their clips to the app's native player in a `present` `ready` event; with `scene`, only that scene |
| `animation_preview` | `scene`, `height?` (as for `present`) | `{ok}`; builds one scene and sends native playback clips in an event |
| `export` | `kind` (`pptx` or `key`), `path`, `builds?`, `editable?` | `{ok}`; progress by events |
| `export_python` | `path`, `hidden?` (include hidden slides) | `{ok, message, path}`; writes the whole deck as one Python file: helper modules inlined (deck-local imports dropped), then the slides in show order and a `SLIDES` list |
| `import` | `src` (`.pptx` or `.key`), `dest` (new folder); needs no open deck | `{ok}`; progress by events |
| `pages` | `builds?` | `{pages: [png, ...]}` (the exact frame of every slide or build, for PDF export) |
| `background` | `op` (`get`, `set`, `reset`), `scene`, `all?` (every slide), and for `set`: `mode` (`color` or `image`), `color?` (`#RRGGBB`), `file?` (picture in the deck folder), `transparency` (0–1) | `get`: `{mode, color, image, transparency, default}`; otherwise `{ok, message, changed}` or `{ok: false, error}` |
| `darkmode` | `mode` (`dark` or `invert`), `current?` (slide to re-render first) | `{ok, message, changed}` or `{ok: false, error}`; writes the dark-mode colour flip or the inverted colours into the deck as one undo step, progress by events |
| `deck_pages` | | `{slides: [{scene, pages: [png, ...], notes, error?}]}` (for a slideshow and the presenter view) |

### `scene` result

```
{name, status: "ready", size: [w, h], frame: [fw, fh], notes, font (the deck's FONT or null),
 placeholders: [{line, role, prompt, size, box: [x0, y0, x1, y1] frame px}],   empty layout boxes
 stops: [ {png,                      full exact frame for this build
           bg,                       backdrop: everything that is not a tracked object
           visible: [[oid, x0, y0, x1, y1], ...],
           sprites: [{oid, file, x, y, w, h, z}, ...],     one transparent image per object, draw order by z
           lines:   {oid: [sx, sy, ex, ey, strokePx]},
           cells:   {oid: [[row, col, cell x0, y0, x1, y1, ink x0, y0, x1, y1], ...]} } ],   // tables
 objects: { oid: {kind, value, fontSize, color, font, weight, slant, siblings, loc, rotation, dims,
                  textOk, textLoc?, textNote?, shared?: {name, uses, rel}, image?, imagePath?, shape?,
                  format?: {underline, strike, highlight, align, columns, lineSpacing}} },
 source: {file, start, end, text, changed?: {file, ranges}} }
```
`kind` is `text`, `tex`, `image`, `line`, `shape` or `table` (a pen stroke is a `shape` whose `shape` is `Pen`). `loc` is
`file:line` of the code that created the object; `imagePath` is the picture file an image shows.
`rotation` is the total of the object's own `rotate()` calls in degrees, `dims` its manim width and height in frame pixels.
`format` (text and formulas) says what the formatting controls should show: `highlight` is `#RRGGBB`, `"on"` (a named
colour) or null; `align` is `left`, `center` or `right`; `lineSpacing` is the `line_spacing=` literal when there is one.
Compositing `bg` then the sprites in `z` order reproduces `png`; a client shows `png` when idle and the composite while it
previews an edit.

### `edit` operations

`text {value, shared?}`, `font {value}`, `style {font?, weight?, slant?, shared?}`, `color {value: "#RRGGBB"}`,
`move {dx, dy}` (frame pixels), `resize {ratio}`, `endpoints {sx, sy, ex, ey}` (lines), `table {rows}`, `delete`
(cuts the element out of the code that makes and shows it; a named element that other code depends on keeps its
name and only stops being shown), `decorate {kind: underline|strike, on}`, `highlight {color?: "#RRGGBB", opacity?}`
(no colour removes it), `align {value: left|center|right}`, `columns {value}`, `spacing {value}` (manim `line_spacing`),
`clear_format`, `size {width?, height?}` (frame pixels, each dimension on its own), `rotate {degrees}` (absolute).
Every edit is verified by re-rendering and rolled back if later code overrides it.

## Events

| event | fields |
|---|---|
| `rendered` | `name`: a slide finished re-rendering in the background |
| `present` | `phase`: `building` (`done`, `total`, `scene`), `ready` (`slides`: `[{scene, sceneIndex, number, index, count, kind, file, revFile, loop, autoNext, rate, revRate, notes}]`, `sections`: scene indices, `links`: `{sceneIndex: [[x0, x1, y0, y1, url]]}`), or `error` (`error`); single-scene requests also send `onlyScene` |
| `animation_preview` | `phase`: `building` (`done`, `total`, `scene`), `ready` (`scene`, `clips: [{path, kind, playbackRate}]`), or `error` (`error`) |
| `export` | `phase`: `building` (`done`, `total`, `scene`), `keynote`, `done` (`path`), or `error` (`error`) |
| `darkmode` | `phase`: `building` (`done`, `total`, `scene`, `mode`) |
| `import` | `phase`: `building` (`done`, `total`, `scene`), `done` (`deck`, `slides`, `warnings`), or `error` (`error`) |
