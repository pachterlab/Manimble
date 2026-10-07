# Manimble for Windows

Not started. A Windows front end would be a second client of the shared Python engine in [`../../engine`](../../engine),
speaking the JSON protocol described in [`../../docs/protocol.md`](../../docs/protocol.md): a slide list, a canvas that
draws the frames and per-object images the engine produces, an inspector, a code pane, and a terminal. Everything that
understands manim, source code and decks lives in the engine, so a new front end is only UI, a working-copy manager
(see `apps/macos/Sources/Manimble/Workspace.swift`), and platform glue (presenter window, sharing, Python discovery).

Notes for whoever picks this up:
- The engine is plain Python 3.11+ (it uses `co_positions`) plus manim, Pillow and optionally python-pptx.
- Keynote import/export (`engine/manimble/export.py`, `importer.py`) uses AppleScript and is macOS-only; PowerPoint
  import/export is portable.
- Starting the presenter and the "open in Finder" behaviour use macOS commands today (`engine/manimble/core.py`).
