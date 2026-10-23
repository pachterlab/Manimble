# Manimble engine

The platform-independent core of Manimble (Python 3.11+). A front end starts it as a subprocess and talks to it with
JSON lines over stdin/stdout, see [`../docs/protocol.md`](../docs/protocol.md).

```bash
PYTHONPATH=engine MANIMBLE_PYTHON=$(which python3) python3 -m manimble.rpc
```

| module | role |
|---|---|
| `rpc.py` | the JSON-lines server and request dispatch |
| `core.py` | deck state, render scheduling and caching, edits with verification, undo, slide operations, presenter build |
| `srcedit.py` | AST analysis: turns an on-screen edit into a minimal source patch |
| `worker.py` | runs scenes inside manim with animations skipped; records objects, call sites and layout calls; writes frames and sprites |
| `export.py` / `importer.py` | PowerPoint / Keynote export and import |
| `movie.py` | the animated show as one MP4 through ffmpeg (the `export_movie` request; same recipe as `manimbler --convert`) |

Requirements: `manim`, `manim-slides` (only for the presenter build), `pillow`, and `python-pptx` for PowerPoint.
