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
| `edit` | `scene`, `stop`, `oid`, `op`, plus op arguments | `{ok, message?, siblings?, changed?: {file, ranges}}` or `{ok: false, error}` |
| `edit_source` | `scene`, `file`, `expected` (source block shown when editing began), `text` (replacement Python class) | `{ok, changed?, error?}`; syntax errors reject the edit, render errors keep it in the working copy and return the error |
| `insert` | `scene`, `stop`, `kind` (`text`, `formula`, `rectangle`, `rounded`, `circle`, `ellipse`, `triangle`, `line`, `arrow`, `darrow`, `table`, `image`, `pen`), plus `tex?`, `rows?`, `cols?`, `file?`, and for drawn elements `sx, sy, ex, ey` (frame pixels: the line's ends or the box's corners; an image placed this way takes the box's width); `pen` takes `points` (`[[x, y], ...]` frame pixels), `color?` (`#RRGGBB`) and `width?` (manim stroke width) and writes a `VMobject(...).set_points_smoothly(...)  # manimble pen` | `{ok, message, line, file, changed, hidden}` |
| `insert_many` | `scene`, `stop`, `items` (a list of `insert` arguments without `scene`/`stop`) | `{ok, message, file, changed}`; one undo step and one re-render for all of them |
| `insert_sprite` | same as `insert` | a sprite (below) previewing what the insert will look like |
| `sprite` | `kind` (`text`, `tex` or `code`), `value`/`code`, `font_size`, `color?`, `font?`, `weight?`, `slant?` | `{file, path, x, y, w, h, cx, cy}` (a transparent PNG, `cx`/`cy` = offset of its centre from the frame centre) |
| `slide` | `op` (`new`, `duplicate`, `delete`, `up`, `down`, `skip`, `unskip`, `hide`, `unhide`, `reorder`), `scene`, `index?`, `layout?` | `{ok, message, select}` (`select` = slide to show afterwards); `new` takes `layout` (`title`, `title_content` (default), `section`, `two_content`, `title_only`, `blank`: placeholder `Text` elements, or nothing); `skip` removes the scene from `order.txt`, `unskip` appends it; `hide` / `unhide` toggle a `# manimble hidden` comment on the class line (the slide stays in the show's order and the navigator but is left out of slideshows, the presenter, PDF, PowerPoint and Keynote exports); `reorder` inserts the scene at the zero-based slot `index` in the original list. When the deck has slide numbers they are renumbered in the same undo step |
| `page_numbers` | `op` (`get`, `set`, `remove`), and for `set`: `scene` (re-rendered to verify), `pos` (`DR`, `DOWN`, `DL`), `start`, `skip` (no number on the first slide), `total` (`3 / 10`), `size` | `get`: `{on, pos, start, skip, total, size}`; otherwise `{ok, message, changed}`. Writes `self.add(Text("3 / 10", ...).to_corner(DR, ...))  # manimble page number ...` at the top of every construct() of the show; a moved or restyled number keeps its tweaks when renumbered |
| `notes` | `op` (`get`, `set`), `scene`, `text?` | `get`: `{text}`; `set`: `{ok, message, changed}`. Speaker notes live in `self.next_slide(notes="...")  # manimble notes` as the first statement of construct(), which manim-slides' presenter shows for the first build; empty text removes it |
| `undo`, `redo` | | `{ok, label}` or `{ok: false, error}` |
| `present` | `scene?` | `{ok}`; builds out-of-date slides and starts the deck's presenter; with `scene`, builds and presents only that scene |
| `animation_preview` | `scene` | `{ok}`; builds one scene and sends native playback clips in an event |
| `export` | `kind` (`pptx` or `key`), `path`, `builds?`, `editable?` | `{ok}`; progress by events |
| `export_python` | `path`, `hidden?` (include hidden slides) | `{ok, message, path}`; writes the whole deck as one Python file: helper modules inlined (deck-local imports dropped), then the slides in show order and a `SLIDES` list |
| `import` | `src` (`.pptx` or `.key`), `dest` (new folder); needs no open deck | `{ok}`; progress by events |
| `pages` | `builds?` | `{pages: [png, ...]}` (the exact frame of every slide or build, for PDF export) |
| `background` | `op` (`get`, `set`, `reset`), `scene`, `all?` (every slide), and for `set`: `mode` (`color` or `image`), `color?` (`#RRGGBB`), `file?` (picture in the deck folder), `transparency` (0–1) | `get`: `{mode, color, image, transparency, default}`; otherwise `{ok, message, changed}` or `{ok: false, error}` |
| `darkmode` | `mode` (`dark` or `invert`), `current?` (slide to re-render first) | `{ok, message, changed}` or `{ok: false, error}`; writes the dark-mode colour flip or the inverted colours into the deck as one undo step, progress by events |
| `deck_pages` | | `{slides: [{scene, pages: [png, ...], notes, error?}]}` (for a slideshow and the presenter view) |

### `scene` result

```
{name, status: "ready", size: [w, h], frame: [fw, fh], notes,
 stops: [ {png,                      full exact frame for this build
           bg,                       backdrop: everything that is not a tracked object
           visible: [[oid, x0, y0, x1, y1], ...],
           sprites: [{oid, file, x, y, w, h, z}, ...],     one transparent image per object, draw order by z
           lines:   {oid: [sx, sy, ex, ey, strokePx]} } ],
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
(elements inserted by Manimble only), `decorate {kind: underline|strike, on}`, `highlight {color?: "#RRGGBB", opacity?}`
(no colour removes it), `align {value: left|center|right}`, `columns {value}`, `spacing {value}` (manim `line_spacing`),
`clear_format`, `size {width?, height?}` (frame pixels, each dimension on its own), `rotate {degrees}` (absolute).
Every edit is verified by re-rendering and rolled back if later code overrides it.

## Events

| event | fields |
|---|---|
| `rendered` | `name`: a slide finished re-rendering in the background |
| `present` | `phase`: `building` (`done`, `total`, `scene`), `playing`, or `error` (`error`); single-scene requests also send `onlyScene` |
| `animation_preview` | `phase`: `building` (`done`, `total`, `scene`), `ready` (`scene`, `clips: [{path, kind, playbackRate}]`), or `error` (`error`) |
| `export` | `phase`: `building` (`done`, `total`, `scene`), `keynote`, `done` (`path`), or `error` (`error`) |
| `darkmode` | `phase`: `building` (`done`, `total`, `scene`, `mode`) |
| `import` | `phase`: `building` (`done`, `total`, `scene`), `done` (`deck`, `slides`, `warnings`), or `error` (`error`) |
