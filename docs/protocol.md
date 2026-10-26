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
| `edit` | `scene`, `stop`, `oid`, `op`, plus op arguments, `optimistic?` (default true) | `{ok, message?, siblings?, changed?: {file, ranges}, pageNumber?, optimistic?, oneBuild?}` or `{ok: false, error}`; `pageNumber` is true when the edit changed a slide-number line. A `move` or `resize` returns at once with `optimistic: true`: the source is patched and committed, and `scene` describes the slide with the object shifted or scaled by hand (its `optimistic` flag set) while the render that verifies the edit runs; a `rendered` event follows when it holds, an `edit_failed` event when it was rolled back (other edits wait for that verdict). `optimistic: false` waits for the render as every other op does |
| `edit_source` | `scene`, `file`, `expected` (source block shown when editing began), `text` (replacement Python class) | `{ok, changed?, error?}`; syntax errors reject the edit, render errors keep it in the working copy and return the error |
| `insert` | `scene`, `stop`, `kind` (`text`, `formula`, `rectangle`, `rounded`, `circle`, `ellipse`, `triangle`, `line`, `arrow`, `darrow`, `table`, `image`, `pen`), plus `tex?`, `rows?`, `cols?`, `file?`, and for drawn elements `sx, sy, ex, ey` (frame pixels: the line's ends or the box's corners; an image placed this way takes the box's width; a line's `startAnchor?`/`endAnchor?` `{oid, at}` attach that end to an object, `at` one of `UL UP UR LEFT ORIGIN RIGHT DL DOWN DR`, written as `var.get_corner(UR)`, `var.get_top()`, ... (`point_at_angle(...)` for a circle's corners), naming the object if needed); `pen` takes `points` (`[[x, y], ...]` frame pixels), `color?` (`#RRGGBB`) and `width?` (manim stroke width) and writes a `VMobject(...).set_points_smoothly(...)  # manimble pen` | `{ok, message, line, file, changed, hidden}` |
| `insert_many` | `scene`, `stop`, `items` (a list of `insert` arguments without `scene`/`stop`), `replace_image?` (`{oid, file}`: point that picture at `file` in the deck folder, e.g. Extract Elements' filled-in background) | `{ok, message, file, changed}`; one undo step and one re-render for all of them. A direct `ImageMobject(...)` gets the new file as its first argument; a helper given the file name gets the new name, with the file copied next to the old picture |
| `delete_build` | `scene`, `stop` | `{ok, message, stop, changed}` or `{ok: false, error}`; removes the `self.next_slide()` that ends that build (for the last build, the one before it), so the build's frame is no longer a stop and its content runs on into the next one; nothing on the slide is deleted. `stop` is the build to show afterwards. Its speaker notes (`notes=...`) go with it. Refused when the call has other options (`loop=...`), sits in a loop or is reached through a helper |
| `insert_sprite` | same as `insert` | a sprite (below) previewing what the insert will look like |
| `sprite` | `kind` (`text`, `tex` or `code`), `value`/`code`, `font_size`, `color?`, `font?`, `weight?`, `slant?` | `{file, path, x, y, w, h, cx, cy}` (a transparent PNG, `cx`/`cy` = offset of its centre from the frame centre) |
| `slide` | `op` (`new`, `duplicate`, `delete`, `up`, `down`, `restore`, `hide`, `unhide`, `reorder`), `scene`, `index?`, `layout?` | `{ok, message, select}` (`select` = slide to show afterwards); `new` takes `layout` (`title`, `title_content` (default), `two_content`, `title_only`, `blank`): PowerPoint's Office Theme boxes written as `# manimble placeholder <role> x0 y0 x1 y1 size` comments (manim units), which render nothing and which the editor draws as "Click to add …" boxes; `restore` appends a scene that is not in `order.txt` to it; `hide` / `unhide` toggle a `# manimble hidden` comment on the class line (the slide stays in the show's order and the navigator but is left out of slideshows, the presenter, PDF, PowerPoint and Keynote exports); `reorder` inserts the scene at the zero-based slot `index` in the original list. When the deck has slide numbers they are renumbered in the same undo step |
| `page_numbers` | `op` (`get`, `set`, `remove`, `spread`), for `spread`: `scene` (its number line, as moved or restyled, is copied to every numbered slide, each keeping its own label); for `set`: `scene` (re-rendered to verify), `pos` (`DR`, `DOWN`, `DL`), `start`, `skip` (no number on the first slide), `total` (`3 / 10`), `size`, `sub` (sub-slide numbers: a slide with several builds shows `3 / 10 · 1/3`, counting on at every `next_slide()` through `sub_slides` in `manimble_helpers.py`; the count follows the slide's renders) | `get`: `{on, pos, start, skip, total, size, sub}`; otherwise `{ok, message, changed}`. Writes `self.add(Text("3 / 10", ...).to_corner(DR, ...))  # manimble page number ...` at the top of every construct() of the show; a moved or restyled number keeps its tweaks when renumbered. An `edit` that changed a number line returns `pageNumber: true` |
| `placeholder` | `scene`, `line`, `text`, `color?`, `op?` (`remove`) | `{ok, message, line, file, changed}`: replaces the placeholder comment on `line` with `self.add(Text(...).move_to(..., aligned_edge=LEFT/UL))  # manimble` at the box's left edge (empty text or `op: remove` deletes it) |
| `notes` | `op` (`get`, `set`), `scene`, `stop?`, `text?` | `get`: `{text}`; `set`: `{ok, message, changed}`. Without `stop`, the slide's notes (every build): `self.next_slide(notes="...")  # manimble notes` as the first statement of construct(), which manim-slides' presenter shows for the first build. With `stop`, that build's own notes: `notes=` on the plain `self.next_slide()` in construct() that starts it (what manim-slides shows for it), or for the first build a `"..."  # manimble build notes` line at the top of construct(); refused when that next_slide() runs in a loop or a helper. Empty text removes them |
| `undo`, `redo` | | `{ok, label}` or `{ok: false, error}` |
| `undo_mark` | | `{mark}`: where the undo history stands, for `undo_merge` |
| `undo_merge` | `mark`, `label?` | `{ok, merged}`; the undo steps recorded since `mark` become one (a move, nudge or delete of several selected objects, sent as one edit each) |
| `present` | `scene?`, `height?` (720, 1080, 1440 or 2160; default 720) | `{ok}`; builds out-of-date slides (`python -m manim render`, no Qt needed) and sends their clips to the app's native player in a `present` `ready` event; with `scene`, only that scene |
| `animation_preview` | `scene`, `height?` (as for `present`) | `{ok}`; builds one scene and sends native playback clips in an event |
| `export` | `kind` (`pptx`, `key` or `beamer`), `path`, `builds?`, `editable?` | `{ok}`; progress by events. `beamer` writes a .tex (one frame per slide, builds as `\only<k>` overlays, pictures in `<name>-figures/`) and typesets it to PDF when a LaTeX is installed |
| `export_python` | `path`, `hidden?` (include hidden slides) | `{ok, message, path}`; writes the whole deck as one Python file: helper modules inlined (deck-local imports dropped), then the slides in show order and a `SLIDES` list |
| `export_movie` | `path` (`.mp4`), `scenes?` (slide names in playing order; default every slide that is not hidden), `height?` (as for `present`), `hold?` (seconds each build's last frame is held; default 2), `fps?` (default 30) | `{ok}` or `{ok: false, error}`; builds slides that are out of date at `height` (as `present` does), then encodes every build's clip with ffmpeg into one movie without audio; progress by `export_movie` events |
| `import` | `src` (`.pptx`, `.key`, or a Beamer `.tex`), `dest` (new folder); needs no open deck | `{ok}`; progress by events. A `.tex` is read as Beamer source (frames laid out in the default theme, overlays as builds, TikZ and tables typeset by LaTeX as pictures) |
| `pages` | `builds?` | `{pages: [png, ...]}` (the exact frame of every slide or build, for PDF export) |
| `background` | `op` (`get`, `set`, `reset`), `scene`, `all?` (every slide), and for `set`: `mode` (`color` or `image`), `color?` (`#RRGGBB`), `file?` (picture in the deck folder), `transparency` (0–1) | `get`: `{mode, color, image, transparency, default}`; otherwise `{ok, message, changed}` or `{ok: false, error}` |
| `darkmode` | `mode` (`dark` or `invert`), `current?` (slide to re-render first) | `{ok, message, changed}` or `{ok: false, error}`; writes the dark-mode colour flip or the inverted colours into the deck as one undo step, progress by events |
| `deck_pages` | `current?`, `ahead?` | `{slides: [{scene, pages: [png, ...], notes, buildNotes: [per page], links: [per page], error?, pending?, builds?}]}` (for a slideshow and the presenter view), read from the render cache. Without `ahead` every out-of-date slide is rendered first. With `ahead`, only `current` and the `ahead - 1` slides after it are waited for; the other out-of-date slides are queued for the background worker in show order and come back as `pending: true` with empty `pages` and `builds` (their last render's build count, else 1); each one's `rendered` event means a call with `ahead: 0` (waits for nothing) now has its pages |
| `find` | `query`, `case?` (match case), `word?` (whole words), `regex?` (`query` is a Python regular expression), `notes?` (search the speaker notes too) | `{ok, matches: [{scene, oid, stop, index, kind, value, match, editable}], error?}`: every match in the text and formulas of the show's slides (hidden ones included), in show order and reading order; `value` is the text as shown (a text box's soft line breaks read as spaces), `index` the match's number within it, `stop` the first build showing the object, `editable` false for text made by code; a match in the notes has `kind` `notes` (the slide's) or `buildNotes` (build `stop`'s own) and `oid` -1. Out-of-date slides are rendered first |
| `replace` | the `find` arguments, `replacement` (with `regex`, `\1`, `\g<name>` or `$1` name groups), and either `scene`, `oid`, `index`, `stop?`, `kind?` (one match: an ordinary `text` edit, or for notes a `notes` set) or `all: true` | one match: as `edit`; `all`: `{ok, count, skipped, scenes, message, changed}`, every editable literal rewritten as one undo step (a literal shown on several slides counts once; text made by code is `skipped`) |

### `scene` result

```
{name, status: "ready", size: [w, h], frame: [fw, fh], notes, buildNotes (per stop), font (the deck's FONT or null),
 optimistic (true while an optimistic edit's render is pending: `png` is stale, composite `bg` and the sprites instead),
 placeholders: [{line, role, prompt, size, box: [x0, y0, x1, y1] frame px}],   empty layout boxes
 stops: [ {png,                      full exact frame for this build
           bg,                       backdrop: everything that is not a tracked object
           visible: [[oid, x0, y0, x1, y1], ...],
           sprites: [{oid, file, x, y, w, h, z, zi, seq}, ...],   one transparent image per object, draw order by z
                                                    (zi: its z_index, seq: the order it was added in)
           lines:   {oid: [sx, sy, ex, ey, strokePx]},
           xforms:  {oid: [a, b, c, d, tx, ty]},   while `optimistic`: a line whose source reads the moved object's
                                                    variable (`Arrow(img.get_right(), ...)`) already has its new ends in
                                                    `lines`/`visible`; draw its sprite mapped by x' = a x + c y + tx,
                                                    y' = b x + d y + ty instead of at its stale place
           cells:   {oid: [[row, col, cell x0, y0, x1, y1, ink x0, y0, x1, y1], ...]} } ],   // tables
 objects: { oid: {kind, value, fontSize, color, font, weight, slant, siblings, loc, rotation, dims,
                  textOk, textLoc?, textNote?, shared?: {name, uses, rel}, image?, imagePath?, shape?,
                  format?: {underline, strike, highlight, align, columns, lineSpacing, valign?},
                  frame?: [x0, y0, x1, y1], group?} },
 source: {file, start, end, text, changed?: {file, ranges}} }
```
`kind` is `text`, `tex`, `image`, `line`, `shape` or `table` (a pen stroke is a `shape` whose `shape` is `Pen`). `loc` is
`file:line` of the code that created the object; `imagePath` is the picture file an image shows.
`rotation` is the total of the object's own `rotate()` calls in degrees, `dims` its manim width and height in frame pixels.
`format` (text and formulas) says what the formatting controls should show: `highlight` is `#RRGGBB`, `"on"` (a named
colour) or null; `align` is `left`, `center` or `right`; `lineSpacing` is the `line_spacing=` literal when there is one.
`frame` (frame px) is a text's *text frame*: text typed into a layout placeholder keeps the placeholder's box, written
as `# manimble box w= h= x= y= v=` on its line. The box keeps its size whatever is typed (the text wraps 0.1 units
inside it) and the text sits in it by `align` and `valign` (`top` or `mid`). A client selects, hits and handles such a
text by its frame; `move` and `resize` carry the frame along, `wrap` sets its width, and after any text edit the engine
puts the text back at its place in the frame.
Compositing `bg` then the sprites in `z` order reproduces `png`; a client shows `png` when idle and the composite while it
previews an edit.

### `edit` operations

`text {value, shared?}`, `font {value}`, `style {font?, weight?, slant?, shared?}`, `color {value: "#RRGGBB"}`,
`move {dx, dy, build?}` (frame pixels; with `build: true` on a slide of several builds it moves the object in build
`stop` only, through `var.shift((x, y, 0))  # manimble build` where the build starts and the opposite
`# manimble build end` shift after the `next_slide()` that ends it, and returns `oneBuild: true`; code not laid out for
that moves it in every build), `spread` (turns that one-build move at `stop` into a move in every build),
`resize {ratio}`, `endpoints {sx, sy, ex, ey, startAnchor?, endAnchor?}` (lines; anchors as for `insert`, an end left in place keeps its source), `table {rows}`, `delete`
(cuts the element out of the code that makes and shows it; a named element that other code depends on keeps its
name and only stops being shown), `decorate {kind: underline|strike, on}`, `highlight {color?: "#RRGGBB", opacity?}`
(no colour removes it), `align {value: left|center|right}`, `columns {value}`, `spacing {value}` (manim `line_spacing`),
`clear_format`, `size {width?, height?}` (frame pixels, each dimension on its own), `rotate {degrees}` (absolute),
`order {value: front|back|forward|backward, oids?}` (stacking order of the objects in `oids` (default `oid`) on build
`stop`: `.set_z_index(n)` on the creation chain of each object whose value has to change, as few as possible;
`forward`/`backward` step past the next object that overlaps it, else the next one), `group {oids}` (writes
`group1 = Group(a, b, ...)  # manimble group` after the last member is made, naming `self.add(X)  # manimble`
inserts first; groups the members were in are merged into it; the line draws nothing) and `ungroup {oids}` (removes
the group lines of those objects, or only their mark when the code uses the group). A grouped object's `group` is
its group's number in the render; a client selects the members of a group together.
Every edit is verified by re-rendering and rolled back if later code overrides it.

## Events

| event | fields |
|---|---|
| `rendered` | `name`: a slide finished re-rendering in the background (also the verdict of an optimistic edit that held) |
| `edit_failed` | `name`, `oid`, `error`: an optimistic edit did not survive its verifying render and was rolled back (the slide is back to its previous render) |
| `present` | `phase`: `building` (`done`, `total`, `scene`), `ready` (`slides`: `[{scene, sceneIndex, number, index, count, kind, file, revFile, loop, autoNext, rate, revRate, notes, buildNotes}]`, `sections`: scene indices, `links`: `{sceneIndex: [[x0, x1, y0, y1, url]]}`), or `error` (`error`); single-scene requests also send `onlyScene` |
| `animation_preview` | `phase`: `building` (`done`, `total`, `scene`), `ready` (`scene`, `clips: [{path, kind, playbackRate}]`), or `error` (`error`) |
| `export` | `phase`: `building` (`done`, `total`, `scene`), `keynote`, `done` (`path`; for `beamer`, `pdfError` when LaTeX failed to typeset the .tex, which is still written), or `error` (`error`) |
| `export_movie` | `phase`: `building` (`done`, `total`, `scene`: manim builds), `encoding` (`done`, `total`, `scene`: ffmpeg, one step per build), `done` (`path`, `slides`, `builds`), or `error` (`error`) |
| `darkmode` | `phase`: `building` (`done`, `total`, `scene`, `mode`) |
| `import` | `phase`: `building` (`done`, `total`, `scene`), `done` (`deck`, `slides`, `warnings`), or `error` (`error`) |
