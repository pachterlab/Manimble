# Manimble for Windows: plan

Goal: a Windows front end that matches the macOS app as closely as possible and shares **the same engine**
(`engine/manimble`, JSON lines over stdio, see `docs/developers/protocol.md`). A fix to the engine reaches both apps.
Only UI and platform glue live here. Anything that knows about manim, source code or decks belongs in the engine.

## Technology

| Mac (apps/macos) | Windows (apps/windows) |
|---|---|
| Swift, AppKit | C# / .NET 10, WPF |
| Metal canvas (backdrop + sprites) | WPF `Canvas` with `Image` layers (GPU-composited by WPF) |
| NSTextView source pane | AvalonEdit (Python highlighting) |
| SwiftTerm terminal | WebView2 + xterm.js over ConPTY (later phase) |
| AVPlayer show / presenter | WPF `MediaElement` (Media Foundation, H.264 MP4) |
| `~/Library/Application Support/Manimble` | `%LOCALAPPDATA%\Manimble` (`python`, `work`, `cache`, `manimble.log`) |
| symlinks in the working copy | directory junctions (no admin / developer mode needed); files are copied |
| BasicTeX / TinyTeX | MiKTeX or TinyTeX for Windows |

## Phases

**0. Engine on Windows.** A Python env with `engine/requirements.txt` in `%LOCALAPPDATA%\Manimble\python`. Run
`python -m manimble.rpc` headless on `examples/hello/deck` and fix the portability bugs in the engine (temp
dirs, path separators, macOS-only paths, process handling). These fixes go into the shared engine and keep macOS
behaviour unchanged.

**1. Minimum viable app.**
- `Engine.cs`: starts the engine, request/response with ids, events, log in `%LOCALAPPDATA%\Manimble\manimble.log`.
- Python discovery (`MANIMBLE_PYTHON`, the saved choice, the installed env, the checkout `.venv`, `PATH`).
- `Workspace.cs`: working copy, Save to Original, Revert, change detection (a port of `Workspace.swift`).
- Window: slide navigator with thumbnails, canvas with the exact frame per build, build stepping, status bar.
- Canvas: hover/select by `visible` boxes, drag to move (an optimistic `move` edit, preview made from backdrop and
  sprites), double-click to edit text, Delete, arrow-key nudge.
- Source pane: the slide's class, editable, applied with `edit_source`.
- Undo/Redo, Open Deck, Recent Decks, a slideshow of `deck_pages` (full screen, arrow keys).

**2. Editing parity.** Inspector (font, size, colour, weight/slant, rotation, size), resize handles, insert text,
formula, shapes, lines/arrows, image, table, pen; slide operations (new with layouts, duplicate, delete, reorder by
drag, hide, restore unused); builds; speaker notes; find and replace; format bar; group/ungroup; arrange order;
guides/grid/ruler/snap; zoom; background; themes; dark mode; slide numbers; clipboard.

**3. Presenting and sharing.** Animated show from `present` clips, presenter view on a second monitor, animation
preview, exports (PowerPoint, PDF, Beamer, MP4, Python), imports (PowerPoint, Beamer, Manim Slides project),
`.manimble` packages. Keynote stays macOS-only.

**4. Terminal and agents.** An embedded terminal (ConPTY), agent instruction files in the working copy, live
re-render on outside edits (the engine already watches files).

**5. Setup and release.** First-launch dependency installer (Python runtime, LaTeX), `install_manimble.ps1`, icons,
an MSIX or zip build, and a CI job in `.github/workflows`.

## Status

- **Phase 0, engine on Windows:** done. Platform paths are in `engine/manimble/hostpaths.py`; dark mode and
  themes handle decks with Windows line endings.
- **Phase 1, MVP:** done.
- **Phase 2, editing parity:** done. Resize and line-end handles, marquee selection, drawing tools and the pen,
  inserting text, formulas, shapes, tables and images, layouts and builds, the format inspector, arrange and group,
  right-click menu, find and replace, zoom, grid and snapping, themes, background, dark mode, slide numbers, copy and
  paste, moves per build. Hyperlinks (Ctrl+K, clickable in the show,
  the stills show and Presenter View) and the Alt Text tab are in. Rulers (View > Ruler, Ctrl+Shift+R) and guides
  (dragged off the rulers or added from the View menu, moved by dragging, removed by dragging them off the slide, snap
  targets, remembered per deck) are in. Text boxes have side handles that set their wrap width. Table cells are typed into on the slide (double-click a cell) or in the inspector's grid, which also adds and removes rows and columns. BioCartoon icons are in (Insert > BioCartoon Icons…: search, category and collection filters, click or drag an icon onto the slide; SVG when the icon has one); the Mac's credit tags in the picture files, Your library and favourites are not. Still to do: Python plots, Extract Elements.
- **Phase 3, presenting and sharing:** the animated show, the animation preview and Presenter View are done; New Deck,
  export (PowerPoint, PDF, movie, Beamer, Python) and import (PowerPoint, Beamer) are in. Portable projects are in:
  Save Project Copy, Package for Sharing (`.manimble`, the Mac app's format) and opening packages. Still to do:
  scripted presentations, the feedback layer. Presenter View on a real second monitor is untested.
- **Phase 4, terminal:** done. A Terminal tab (Ctrl+`) runs PowerShell in the working copy over ConPTY; outside edits
  re-render the slide.
- **Phase 5, setup and release:** `install_dependencies.ps1` (tested on a fresh environment), `install_manimble.ps1`
  (tested: builds into `%LOCALAPPDATA%\Programs\Manimble`) and the first-launch setup window (`SetupWindow.cs`, also
  File > Install Dependencies…) are done. `build_release.ps1` makes a self-contained `Manimble-Windows.zip` (tested: it
  runs unzipped on its bundled engine); the build workflow builds it on every push and the release workflow attaches it
  to each GitHub Release. The app and `.manimble` packages have their icons, and an installed or unzipped copy registers itself (per user)
  to open `.manimble` files from Explorer. Still to do: an MSIX or installer, code signing.
