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
  paste, moves per build. Still to do: rulers and draggable guides, text-box wrap handles, table cell editing, hyperlinks
  and alt text, BioCartoon icons, Python plots, Extract Elements.
- **Phase 3, presenting and sharing:** the animated show and the animation preview are done; New Deck, export
  (PowerPoint, PDF, movie, Beamer, Python) and import (PowerPoint, Beamer) are in. Still to do: Presenter View,
  `.manimble` packages, scripted presentations, the feedback layer.
- **Phase 4, terminal:** not started.
- **Phase 5, setup and release:** `install_manimble.ps1` is written; the first-launch installer and CI are not.
