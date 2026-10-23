"""JSON-lines RPC over stdin/stdout, used by the native Manimble app.

Request : {"id": 1, "cmd": "scene", ...args}
Response: {"id": 1, "result": {...}}  or  {"id": 1, "error": "..."}
Event   : {"event": "rendered", "name": "Intro"}        (pushed, no id)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import traceback
from concurrent.futures import ThreadPoolExecutor

from .core import Manimble

_out = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
sys.stdout = sys.stderr
_wlock = threading.Lock()


def send(obj):
    line = json.dumps(obj)
    with _wlock:
        _out.write(line + "\n")


def main():
    python = os.environ.get("MANIMBLE_PYTHON") or sys.executable
    app = {"s": None}

    def need():
        if app["s"] is None:
            raise RuntimeError("no deck open")
        return app["s"]

    def open_deck(a):
        old = app["s"]
        if old:
            old.close()
        s = Manimble(a["deck"], python, a.get("cache"))
        s.on_event = send
        app["s"] = s
        return {"ok": True}

    def present(a):
        return need().present(a)

    handlers = {
        "open": open_deck,
        "state": lambda a: need().api_state(a.get("current")),
        "dependency_report": lambda a: need().dependency_report(),
        "scene": lambda a: need().api_scene(a["name"]),
        "edit": lambda a: need().edit(a),
        "edit_source": lambda a: need().edit_source(a),
        "undo": lambda a: need().undo(),
        "redo": lambda a: need().redo_(),
        "sprite": lambda a: need().sprite(a),
        "present": present,
        "animation_preview": lambda a: need().animation_preview(a),
        "export": lambda a: need().export(a),
        "insert": lambda a: need().insert(a),
        "insert_sprite": lambda a: need().insert_sprite(a),
        "pages": lambda a: need().pages(a),
        "slide": lambda a: need().slide_op(a),
        "deck_pages": lambda a: need().deck_pages(a),
        "background": lambda a: need().background(a),
        "page_numbers": lambda a: need().page_numbers(a),
        "notes": lambda a: need().notes(a),
        "placeholder": lambda a: need().placeholder(a),
        "insert_many": lambda a: need().insert_many(a),
        "delete_build": lambda a: need().delete_build(a),
        "new_build": lambda a: need().new_build(a),
        "export_python": lambda a: need().export_python(a),
        "export_movie": lambda a: need().export_movie(a),
        "darkmode": lambda a: need().dark_mode(a),
    }
    def import_job(a):
        from . import importer

        def go():
            def prog(i, n, what):
                send({"event": "import", "phase": "building", "done": i, "total": n, "scene": what})
            try:
                r = importer.import_presentation(a["src"], a["dest"], prog)
            except Exception as exc:                          # noqa: BLE001
                r = {"ok": False, "error": str(exc)}
            send({"event": "import", "phase": "done" if r.get("ok") else "error", **{k: v for k, v in r.items() if k != "ok"}})
        threading.Thread(target=go, daemon=True).start()
        return {"ok": True}

    handlers["import"] = import_job
    pool = ThreadPoolExecutor(max_workers=8)

    def run(req):
        try:
            res = handlers[req["cmd"]](req)
            send({"id": req["id"], "result": res})
        except BaseException as exc:  # noqa: BLE001
            traceback.print_exc()
            send({"id": req.get("id"), "error": str(exc)})

    for line in sys.stdin:
        line = line.strip()
        if line:
            req = json.loads(line)
            if req.get("cmd") == "open":      # order matters: finish before later requests
                run(req)
            else:
                pool.submit(run, req)
    if app["s"]:
        app["s"].close()


if __name__ == "__main__":
    main()
