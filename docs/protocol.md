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
| `open` | `deck` (folder with the scene `.py` files), `cache?` (cache folder, default `<deck>/.manimble`) | `{ok: true}` |
| `state` | `current?` (slide on screen; re-rendered first if its source changed) | `{deck, path, scenes: [{name, file, line, status, thumb?, stops?, error?}], unusedScenes: [same summary], canUndo, canRedo, undoLabel, hasPresent}`; `scenes` follows `order.txt` and `unusedScenes` contains scene classes outside it; `status` is `ready`, `rendering`, `queued`, `stale`, `pending` or `error` |
| `scene` | `name` | see below; renders the slide if needed and waits |
| `edit` | `scene`, `stop`, `oid`, `op`, plus op arguments | `{ok, message?, siblings?, changed?: {file, ranges}}` or `{ok: false, error}` |
| `edit_source` | `scene`, `file`, `expected` (source block shown when editing began), `text` (replacement Python class) | `{ok, changed?, error?}`; syntax errors reject the edit, render errors keep it in the working copy and return the error |
| `insert` | `scene`, `stop`, `kind`, plus `tex?`, `rows?`, `cols?`, `file?` | `{ok, message, line, file, changed, hidden}` |
| `insert_sprite` | same as `insert` | a sprite (below) previewing what the insert will look like |
| `sprite` | `kind` (`text`, `tex` or `code`), `value`/`code`, `font_size`, `color?`, `font?`, `weight?`, `slant?` | `{file, path, x, y, w, h, cx, cy}` (a transparent PNG, `cx`/`cy` = offset of its centre from the frame centre) |
| `slide` | `op` (`new`, `duplicate`, `delete`, `up`, `down`, `skip`, `unskip`, `reorder`), `scene`, `index?` | `{ok, message, select}` (`select` = slide to show afterwards); `skip` removes the scene from `order.txt`, `unskip` appends it; `reorder` inserts the scene at the zero-based slot `index` in the original list |
| `undo`, `redo` | | `{ok, label}` or `{ok: false, error}` |
| `present` | `scene?` | `{ok}`; builds out-of-date slides and starts the deck's presenter; with `scene`, builds and presents only that scene |
| `animation_preview` | `scene` | `{ok}`; builds one scene and sends native playback clips in an event |
| `export` | `kind` (`pptx` or `key`), `path`, `builds?`, `editable?` | `{ok}`; progress by events |
| `import` | `src` (`.pptx` or `.key`), `dest` (new folder); needs no open deck | `{ok}`; progress by events |
| `pages` | `builds?` | `{pages: [png, ...]}` (the exact frame of every slide or build, for PDF export) |
| `background` | `op` (`get`, `set`, `reset`), `scene`, `all?` (every slide), and for `set`: `mode` (`color` or `image`), `color?` (`#RRGGBB`), `file?` (picture in the deck folder), `transparency` (0–1) | `get`: `{mode, color, image, transparency, default}`; otherwise `{ok, message, changed}` or `{ok: false, error}` |
| `darkmode` | `mode` (`dark` or `invert`), `current?` (slide to re-render first) | `{ok, message, changed}` or `{ok: false, error}`; writes the dark-mode colour flip or the inverted colours into the deck as one undo step, progress by events |
| `deck_pages` | | `{slides: [{scene, pages: [png, ...], error?}]}` (for a slideshow) |

### `scene` result

```
{name, status: "ready", size: [w, h], frame: [fw, fh],
 stops: [ {png,                      full exact frame for this build
           bg,                       backdrop: everything that is not a tracked object
           visible: [[oid, x0, y0, x1, y1], ...],
           sprites: [{oid, file, x, y, w, h, z}, ...],     one transparent image per object, draw order by z
           lines:   {oid: [sx, sy, ex, ey, strokePx]} } ],
 objects: { oid: {kind, value, fontSize, color, font, weight, slant, siblings, loc,
                  textOk, textLoc?, textNote?, shared?: {name, uses, rel}, image?, shape?} },
 source: {file, start, end, text, changed?: {file, ranges}} }
```
`kind` is `text`, `tex`, `image`, `line`, `shape` or `table`. `loc` is `file:line` of the code that created the object.
Compositing `bg` then the sprites in `z` order reproduces `png`; a client shows `png` when idle and the composite while it
previews an edit.

### `edit` operations

`text {value, shared?}`, `font {value}`, `style {font?, weight?, slant?, shared?}`, `color {value: "#RRGGBB"}`,
`move {dx, dy}` (frame pixels), `resize {ratio}`, `endpoints {sx, sy, ex, ey}` (lines), `table {rows}`, `delete`
(elements inserted by Manimble only). Every edit is verified by re-rendering and rolled back if later code overrides it.

## Events

| event | fields |
|---|---|
| `rendered` | `name`: a slide finished re-rendering in the background |
| `present` | `phase`: `building` (`done`, `total`, `scene`), `playing`, or `error` (`error`); single-scene requests also send `onlyScene` |
| `animation_preview` | `phase`: `building` (`done`, `total`, `scene`), `ready` (`scene`, `clips: [{path, kind, playbackRate}]`), or `error` (`error`) |
| `export` | `phase`: `building` (`done`, `total`, `scene`), `keynote`, `done` (`path`), or `error` (`error`) |
| `darkmode` | `phase`: `building` (`done`, `total`, `scene`, `mode`) |
| `import` | `phase`: `building` (`done`, `total`, `scene`), `done` (`deck`, `slides`, `warnings`), or `error` (`error`) |
