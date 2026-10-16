"""manimble server: HTTP API + render scheduling + source patching."""

from __future__ import annotations

import ast
import difflib
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

from .srcedit import EditError, Planner, Project, Src, _stmt_lines, fmt, py_str, py_tex, remove_kwargs

HERE = Path(__file__).resolve().parent


# ------------------------------------------------------------------ worker

class WorkerProc:
    """A long-lived manim process speaking JSON lines."""

    def __init__(self, python: str, deck: str, worker_name: str, media_root: Path | None = None):
        self.python, self.deck = python, deck
        # Manim caches generated Text/TeX SVGs by content under media_dir.
        # Independent workers rendering different slides concurrently can
        # otherwise delete each other's temporary SVGs while parsing them.
        # The cache lives with the deck's render cache so it outlives the working copy: a fresh
        # directory means every formula goes through LaTeX again before the first edit of each slide.
        root = media_root if media_root is not None else Path(deck).parent / "media" / "manimble"
        self.media_dir = str(root / worker_name)
        self.lock = threading.Lock()
        self.proc = None

    def _start(self):
        env = os.environ.copy()
        env["MANIMBLE_MEDIA_DIR"] = self.media_dir
        self.proc = subprocess.Popen(
            [self.python, str(HERE / "worker.py"), self.deck],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None,
            text=True, bufsize=1, encoding="utf-8", env=env,
        )

    def request(self, req: dict) -> dict:
        with self.lock:
            for attempt in (0, 1):
                if self.proc is None or self.proc.poll() is not None:
                    self._start()
                try:
                    self.proc.stdin.write(json.dumps(req) + "\n")
                    self.proc.stdin.flush()
                    line = self.proc.stdout.readline()
                    if line:
                        return json.loads(line)
                except (BrokenPipeError, OSError):
                    pass
                self.proc = None
            return {"error": "render worker died"}

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()

    def restart(self):
        """Stop the process after its current request; the next request starts a fresh one (re-reading manim.cfg)."""
        with self.lock:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            self.proc = None


# ------------------------------------------------------------------- state

TEXT_OPS = ("text", "font", "color", "style", "table", "delete", "decorate", "highlight", "align", "columns",
            "spacing", "clear_format")


class Manimble:
    def __init__(self, deck: str, python: str, cache: str | None = None):
        self.project = Project(deck)
        self.deck = self.project.dir
        self.python = python
        self.planner = Planner(self.project)
        self.cache_dir = Path(cache) if cache else Path(self.deck) / ".manimble"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        (self.cache_dir / ".gitignore").write_text("*\n")
        media_root = self.cache_dir / "media"
        self.render_worker = WorkerProc(python, self.deck, "background", media_root)
        self.aux_worker = WorkerProc(python, self.deck, "auxiliary", media_root)
        self.on_event = None
        self.lock = threading.RLock()           # guards the tables below
        self.edit_lock = threading.RLock()      # serialises edits
        self.scene_locks: dict = {}             # one render per scene at a time
        self.edit_worker = WorkerProc(python, self.deck, "interactive", media_root)   # edits never wait behind background renders
        self.scenes: list[dict] = []            # ordered scene descriptors (the slides of the talk)
        self.all_scenes: list[dict] = []        # every scene class found, including ones not in order.txt
        self.results: dict[str, dict] = {}      # name -> {"key","dir","data"} or {"error"}
        self.queue: list[str] = []
        self.rendering: set = set()
        self.history: list[dict] = []
        self.redo: list[dict] = []
        self.last_changed: dict = {}
        self.cv = threading.Condition()
        self.refresh_scenes()
        # keys of the untouched deck: slides already built from it count as up to date
        self.baseline_keys = {s["name"]: self.scene_key(s) for s in self.scenes}
        for s in self.scenes:
            self._load_disk(s["name"])
        threading.Thread(target=self._loop, daemon=True).start()
        for w in (self.edit_worker, self.aux_worker):      # import manim now, not at the first click
            threading.Thread(target=w.request, args=({"cmd": "ping"},), daemon=True).start()
        self.enqueue_all()

    def close(self):
        self.render_worker.close()
        self.aux_worker.close()
        self.edit_worker.close()

    # ----------------------------------------------------------- scenes
    def refresh_scenes(self):
        found = self.project.scenes()
        rows = []
        for n, rel, l, e in found:
            try:
                src = self.project.src(rel)
                a = src.line_starts[l - 1]
                b = src.line_starts[l] if l < len(src.line_starts) else len(src.data)
                hidden = self.HIDDEN_MARK in src.data[a:b].decode("utf-8", "replace")
            except Exception:                       # noqa: BLE001
                hidden = False
            rows.append({"name": n, "file": rel, "line": l, "end": e, "module": rel[:-3], "hidden": hidden})
        order_file = os.path.join(self.deck, "order.txt")
        listed = rows
        if os.path.exists(order_file):
            with open(order_file, encoding="utf-8") as fh:
                names = fh.read().split()
            by_name = {r["name"]: r for r in rows}
            listed = [by_name[n] for n in dict.fromkeys(names) if n in by_name]
        with self.lock:
            self.all_scenes = rows
            self.scenes = listed

    def scene(self, name: str) -> dict:
        for s in self.all_scenes:
            if s["name"] == name:
                return s
        raise KeyError(name)

    HIDDEN_MARK = "# manimble hidden"

    def visible_scenes(self) -> list:
        """The slides of the show that are not hidden (what a slideshow, the presenter and exports use)."""
        return [s for s in self.scenes if not s.get("hidden")]

    def _signature(self):
        """Cheap fingerprint (mtimes/sizes) of every file a scene could depend on."""
        now = time.time()
        if now - getattr(self, "_sig_at", 0) < 0.4:
            return self._sig
        parts = []
        for rel in self.project.py_files():
            st = os.stat(os.path.join(self.deck, rel))
            parts.append((rel, st.st_mtime_ns, st.st_size))
        assets = Path(self.deck).parent / "assets"
        if assets.is_dir():
            for p in assets.rglob("*"):
                if p.is_file():
                    st = p.stat()
                    parts.append((str(p), st.st_mtime_ns, st.st_size))
        cfg = os.path.join(self.deck, "manim.cfg")
        parts.append(("manim.cfg", os.path.getmtime(cfg) if os.path.exists(cfg) else 0, 0))
        parts.append(("order", os.path.getmtime(os.path.join(self.deck, "order.txt")) if os.path.exists(os.path.join(self.deck, "order.txt")) else 0, 0))
        self._sig, self._sig_at = tuple(parts), now
        return self._sig

    def scene_key(self, s: dict) -> str:
        sig = self._signature()
        cache = self.__dict__.setdefault("_keys", {})
        hit = cache.get(s["name"])
        if hit and hit[0] == sig:
            return hit[1]
        key = self._scene_key(s)
        cache[s["name"]] = (sig, key)
        return key

    def _scene_key(self, s: dict) -> str:
        """Hash of everything that can change how this scene renders."""
        h = hashlib.sha1(b"manimble-engine-3")
        scene_names = {x["name"] for x in self.all_scenes}
        for rel in self.project.py_files():
            src = self.project.src(rel)
            data = src.data
            if rel == s["file"]:
                # the scene's own class in full; all other scene classes blanked out
                spans = []
                for node in src.tree.body:
                    if isinstance(node, ast.ClassDef) and node.name in scene_names:
                        a = src.off(node.lineno, node.col_offset)
                        b = src.off(node.end_lineno, node.end_col_offset)
                        if node.name == s["name"]:
                            h.update(data[a:b])
                        spans.append((a, b))
                keep = bytearray(data)
                for a, b in sorted(spans, reverse=True):
                    del keep[a:b]
                h.update(bytes(keep))
            else:
                if any(isinstance(n, ast.ClassDef) and n.name in scene_names for n in src.tree.body):
                    # another scene module: only its non-scene code could matter, and scenes don't import it
                    continue
                h.update(data)
        cfg = Path(self.deck) / "manim.cfg"
        if cfg.is_file():
            h.update(cfg.read_bytes())          # background colour, resolution, ...
        assets = Path(self.deck).parent / "assets"
        if assets.is_dir():
            for p in sorted(assets.rglob("*")):
                if p.is_file():
                    st = p.stat()
                    h.update(f"{p.relative_to(assets)}:{st.st_size}:{int(st.st_mtime)}".encode())
        return h.hexdigest()

    # ------------------------------------------------------- disk cache
    def _load_disk(self, name: str):
        f = self.cache_dir / name / "data.json"
        if f.exists():
            try:
                res = json.loads(f.read_text())
                # Render failures can be transient (for example, concurrent
                # Manim workers racing over a generated SVG). Retry them on
                # the next deck open instead of preserving a dead-end error.
                if "error" not in res:
                    self.results[name] = res
            except Exception:
                pass

    def status(self, name: str) -> str:
        with self.lock:
            r = self.results.get(name)
        if name in self.rendering:
            return "rendering"
        if r is None:
            return "queued" if name in self.queue else "pending"
        if "error" in r and r.get("key") == self.scene_key(self.scene(name)):
            return "error"
        if r.get("key") != self.scene_key(self.scene(name)):
            return "queued" if name in self.queue else "stale"
        return "ready"

    # -------------------------------------------------------- rendering
    def enqueue(self, name: str, front: bool = False):
        with self.cv:
            if name in self.queue:
                if front:
                    self.queue.remove(name)
                    self.queue.insert(0, name)
                return
            self.queue.insert(0, name) if front else self.queue.append(name)
            self.cv.notify()

    def enqueue_all(self):
        for s in self.scenes:
            if self.status(s["name"]) in ("pending", "stale"):
                self.enqueue(s["name"])

    def _loop(self):
        while True:
            with self.cv:
                while not self.queue:
                    self.cv.wait()
                name = self.queue.pop(0)
            try:
                self.render_now(name)
                if self.on_event:
                    self.on_event({"event": "rendered", "name": name})
            except Exception:
                traceback.print_exc()

    def render_now(self, name: str, interactive: bool = False, force: bool = False) -> dict:
        """Render a scene (blocking). Returns the stored result record.

        interactive=True uses a dedicated worker so user edits are not queued behind the
        background pre-rendering of other slides."""
        with self.lock:
            lock = self.scene_locks.setdefault(name, threading.RLock())
        with lock:
            s = self.scene(name)
            key = self.scene_key(s)
            cur = self.results.get(name)
            if cur and cur.get("key") == key and "error" not in cur and not cur.get("stale_meta") and not force:
                return cur
            self.rendering.add(name)
            try:
                sub = key[:12]
                out = self.cache_dir / name / sub
                out.mkdir(parents=True, exist_ok=True)
                res = (self.edit_worker if interactive else self.render_worker).request(
                    {"cmd": "render", "scene": name, "module": s["module"], "out": str(out)}
                )
                dependencies = sorted(set(res.get("dependencies", [])))
                if "error" in res:
                    rec = {"key": key, "error": res["error"], "dir": sub,
                           "dependencies": dependencies, "dependencies_scanned": True}
                else:
                    rec = {"key": key, "dir": sub, "data": res}
                    rec["dependencies"] = dependencies
                    rec["dependencies_scanned"] = True
                    for old in (self.cache_dir / name).iterdir():
                        if old.is_dir() and old.name != sub:
                            shutil.rmtree(old, ignore_errors=True)
                with self.lock:
                    self.results[name] = rec
                (self.cache_dir / name).mkdir(exist_ok=True)
                (self.cache_dir / name / "data.json").write_text(json.dumps(rec))
                return rec
            finally:
                self.rendering.discard(name)

    def dependency_report(self) -> dict:
        """Render any unscanned scenes and report files opened by deck code."""
        failures = []
        current_workspace = Path(self.deck).absolute().parent.parent
        work_root = current_workspace.parent
        for s in self.scenes:
            with self.lock:
                rec = self.results.get(s["name"])
            stale_workspace_paths = False
            if rec and rec.get("dependencies_scanned"):
                for raw in rec.get("dependencies", []):
                    dependency = Path(raw).absolute()
                    # Render-cache records survive closing and reopening a deck,
                    # but their absolute paths refer to the previous UUID-named
                    # working copy. Rerender those scenes to collect paths from
                    # this session's workspace before packaging.
                    if dependency.is_relative_to(work_root) and not dependency.is_relative_to(current_workspace):
                        stale_workspace_paths = True
                        break
            if not rec or not rec.get("dependencies_scanned") or stale_workspace_paths:
                rec = self.render_now(s["name"], force=True)
            if "error" in rec:
                failures.append({"scene": s["name"], "error": rec["error"]})
        with self.lock:
            results = [self.results[s["name"]] for s in self.scenes if s["name"] in self.results]
        media_root = Path(self.deck).parent / "media" / "manimble"
        media_roots = (media_root.absolute(), media_root.resolve())

        def generated_media(path: str) -> bool:
            file = Path(path)
            return any(file.absolute().is_relative_to(root) or file.resolve().is_relative_to(root)
                       for root in media_roots)

        paths = sorted({
            path
            for rec in results
            for path in rec.get("dependencies", [])
            if not generated_media(path)
        })
        with self.lock:
            scanned = sum(bool(self.results.get(s["name"], {}).get("dependencies_scanned")) for s in self.scenes)
        return {"dependencies": paths, "scannedScenes": scanned,
                "totalScenes": len(self.scenes), "failures": failures}

    def fresh_record(self, name: str) -> dict:
        """A record whose positional metadata matches the files on disk."""
        rec = self.render_now(name, interactive=True)
        data = rec.get("data")
        if data:
            stale = any(self.project.file_hash(f) != h for f, h in data["files"].items()
                        if os.path.exists(os.path.join(self.deck, f)))
            if stale:
                rec["stale_meta"] = True
                rec = self.render_now(name, interactive=True)
                rec.pop("stale_meta", None)
        return rec

    # ------------------------------------------------------ API: reads
    def api_state(self, current: str | None = None) -> dict:
        self.refresh_scenes()
        # the slide on screen was changed behind our back (e.g. edited by Claude): re-render it right away
        if current and current in {x["name"] for x in self.all_scenes} and self.status(current) in ("pending", "stale") \
                and current not in self.rendering and current not in getattr(self, "_kicked", set()):
            self._kicked = getattr(self, "_kicked", set()) | {current}

            def kick(name=current):
                try:
                    self.render_now(name, interactive=True)
                    if self.on_event:
                        self.on_event({"event": "rendered", "name": name})
                finally:
                    self._kicked.discard(name)
            threading.Thread(target=kick, daemon=True).start()
        def summaries(scenes):
            out = []
            for s in scenes:
                st = self.status(s["name"])
                r = self.results.get(s["name"])
                item = {"name": s["name"], "file": s["file"], "line": s["line"], "status": st, "hidden": bool(s.get("hidden"))}
                if r and "data" in r:
                    item["thumb"] = str(self.cache_dir / s["name"] / r["dir"] / "thumb.jpg")
                    item["stops"] = len(r["data"]["stops"])
                if r and "error" in r and st == "error":
                    item["error"] = r["error"]
                out.append(item)
            return out
        ordered = {s["name"] for s in self.scenes}
        unused = [s for s in self.all_scenes if s["name"] not in ordered]
        out = summaries(self.scenes)
        unused_out = summaries(unused)
        for s in self.scenes:
            if self.status(s["name"]) in ("pending", "stale"):
                self.enqueue(s["name"])
        return {
            "deck": os.path.basename(os.path.dirname(self.deck)) + "/" + os.path.basename(self.deck),
            "path": self.deck,
            "scenes": out,
            "unusedScenes": unused_out,
            "canUndo": bool(self.history), "canRedo": bool(self.redo),
            "undoLabel": self.history[-1]["label"] if self.history else "",
            "hasPresent": os.path.exists(os.path.join(self.deck, "present.sh")),
        }

    def api_scene(self, name: str, wait: bool = True) -> dict:
        self.scene(name)
        if self.status(name) in ("pending", "stale", "queued"):
            # the slide on screen jumps the queue: render it on the interactive worker right now
            with self.cv:
                if name in self.queue:
                    self.queue.remove(name)
            self.render_now(name, interactive=True)
        deadline = time.time() + 120
        while wait and self.status(name) in ("pending", "stale", "queued", "rendering") and time.time() < deadline:
            time.sleep(0.05)
        rec = self.results.get(name)
        if not rec:
            return {"name": name, "status": self.status(name)}
        if "error" in rec:
            return {"name": name, "status": "error", "error": rec["error"], "source": self.api_source(name)}
        data = rec["data"]
        fw, fh = data["frame"]
        pw, ph = data["size"]
        counts: dict = {}
        for o in data["objects"].values():
            k = (o["frames"][-1]["file"], tuple(o["frames"][-1]["pos"]))
            counts[k] = counts.get(k, 0) + 1
        objects = {}
        for oid, o in data["objects"].items():
            k = (o["frames"][-1]["file"], tuple(o["frames"][-1]["pos"]))
            info = {
                "kind": o["kind"], "value": o["value"], "fontSize": o["font_size"], "color": o["color"],
                "siblings": counts[k], "font": o.get("font"), "weight": o.get("weight"), "slant": o.get("slant"),
                "loc": f"{o['frames'][-1]['file']}:{o['frames'][-1]['pos'][0]}",
                "rotation": o.get("rotation"), "dims": o.get("dims"),
            }
            if o["kind"] in ("text", "tex"):
                info["format"] = self.planner.format_info(o)
                t = self.planner.text_target(o)
                info["textOk"] = t.kind == "node"
                if t.kind == "node":
                    info["textLoc"] = f"{t.src.rel}:{t.node.lineno}"
                    if t.via:
                        info["shared"] = {"name": t.via["name"], "uses": t.via["uses"], "rel": t.via["rel"]}
                else:
                    info["textNote"] = t.note
            elif o["kind"] == "image":
                info["image"] = os.path.basename(o["value"])
                if o.get("path"):
                    info["imagePath"] = o["path"]
            else:
                info["shape"] = o["value"]
            objects[oid] = info
        base = str(self.cache_dir / name / rec["dir"]) + "/"
        s = self.scene(name)
        return {
            "name": name, "status": "ready", "size": [pw, ph], "frame": [fw, fh],
            "stops": [{
                "png": base + st["png"], "bg": base + st["bg"], "visible": st["visible"],
                "sprites": [dict(sp, file=base + sp["file"]) for sp in st["sprites"]],
                "lines": st.get("lines", {}),
            } for st in data["stops"]],
            "objects": objects,
            "source": self.api_source(name),
            "notes": self._notes_of(name),
        }

    def api_source(self, name: str) -> dict:
        s = self.scene(name)
        self.refresh_scenes()
        s = self.scene(name)
        src = self.project.src(s["file"])
        cls = next(n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == name)
        a, b = src.span(cls)
        return {
            "file": s["file"], "start": s["line"], "end": s["end"],
            "text": src.data[a:b].decode("utf-8"),
            "changed": self.last_changed if self.last_changed.get("file") == s["file"] else None,
        }

    def edit_source(self, req: dict) -> dict:
        """Replace one scene class, leaving the surrounding module untouched."""
        from .srcedit import Edit
        with self.edit_lock:
            self.refresh_scenes()
            name = req["scene"]
            source = self.api_source(name)
            if req.get("file") != source["file"] or req.get("expected") != source["text"]:
                return {"ok": False, "error": "Source changed since editing began. Copy your draft, then reload the slide."}
            replacement = req["text"]
            if replacement == source["text"]:
                return {"ok": True, "message": "no change"}
            src = self.project.src(source["file"])
            cls = next(n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == name)
            a, b = src.span(cls)
            data = src.data[:a] + replacement.encode("utf-8") + src.data[b:]
            try:
                tree = ast.parse(data, filename=source["file"])
            except SyntaxError as exc:
                return {"ok": False, "error": f"{source['file']}:{exc.lineno}: {exc.msg}"}
            if not any(isinstance(n, ast.ClassDef) and n.name == name and
                       any(isinstance(m, ast.FunctionDef) and m.name == "construct" for m in n.body)
                       for n in tree.body):
                return {"ok": False, "error": f"Keep class {name} and its construct() method in this code box."}
            written = self.project.apply([Edit(source["file"], a, b, replacement)])
            self._sig_at = 0
            self._commit("edit Python source", written)
            self.refresh_scenes()
            rec = self.render_now(name, interactive=True, force=True)
            self.enqueue_all()
            return {"ok": True, "changed": self.last_changed, "error": rec.get("error")}

    # -------------------------------------------------------- API: edit
    def _commit(self, label: str, written: dict):
        entry = {"label": label, "files": {rel: (b, a) for rel, (b, a) in written.items()}}
        self.history.append(entry)
        self.redo.clear()
        self.last_changed = self._diff_lines(written)

    def _diff_lines(self, written: dict) -> dict:
        for rel, (before, after) in written.items():
            if not rel.endswith(".py") or before is None:
                continue
            a = before.decode("utf-8").split("\n")
            b = after.decode("utf-8").split("\n")
            changed = []
            for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
                if tag != "equal":
                    changed.append([j1 + 1, max(j2, j1 + 1)])
            return {"file": rel, "ranges": changed}
        return {}

    def _restore(self, written: dict, which: int):
        for rel, pair in written.items():
            self.project.write(rel, pair[which])
        self._sig_at = 0          # file changed: drop the cached fingerprint
        if "manim.cfg" in written:
            self._restart_workers()

    def _restart_workers(self):
        """manim reads manim.cfg once, when a worker imports it."""
        for w in (self.edit_worker, self.render_worker, self.aux_worker):
            w.restart()

    def edit(self, req: dict) -> dict:
        with self.edit_lock:
            name, op = req["scene"], req["op"]
            rec = self.fresh_record(name)
            if "error" in rec:
                return {"ok": False, "error": rec["error"]}
            data = rec["data"]
            oid = str(req["oid"])
            obj = data["objects"][oid]
            stop = int(req.get("stop", 0))
            vis = {str(v[0]): v for v in data["stops"][min(stop, len(data["stops"]) - 1)]["visible"]}
            before_box = vis.get(oid)
            fw, fh = data["frame"]
            pw, ph = data["size"]
            ux, uy = fw / pw, fh / ph

            attempts: list[tuple[str, list]] = []
            label = op
            try:
                if op == "text":
                    label = "edit text" if obj["kind"] == "text" else "edit formula"
                    attempts = [(label, self.planner.plan_text(obj, req["value"], req.get("shared", True)))]
                elif op == "font":
                    label = "font size"
                    v = float(req["value"])
                    now, base = obj.get("font_size") or v, obj.get("font0") or v
                    attempts = [(label, self.planner.plan_font(obj, base * v / now))]
                elif op == "style":
                    label = "text style"
                    edits = []
                    if req.get("font") is not None:
                        edits += self.planner.plan_font_family(obj, req["font"], req.get("shared", True))
                    if req.get("weight") is not None:
                        edits += self.planner.plan_arg(obj, "weight", py_str(req["weight"]), outermost=True)
                    if req.get("slant") is not None:
                        edits += self.planner.plan_arg(obj, "slant", py_str(req["slant"]), outermost=True)
                    attempts = [(label, edits)]
                elif op == "color":
                    label = "text color"
                    attempts = [(label, self.planner.plan_arg(obj, "color", py_str(req["value"])))]
                elif op == "move":
                    label = "move"
                    dx, dy = float(req["dx"]) * ux, -float(req["dy"]) * uy
                    if abs(dx) < 1e-4 and abs(dy) < 1e-4:
                        return {"ok": True, "message": "no change"}
                    attempts = self.planner.plan_move(obj, dx, dy)
                elif op == "table":
                    label = "edit table"
                    attempts = [(label, self.planner.plan_table(obj, req["rows"]))]
                elif op == "delete":
                    label = "delete element"
                    attempts = [(label, self.planner.plan_delete(obj))]
                elif op == "endpoints":
                    label = "line ends"
                    cx = lambda px: (px - pw / 2) * ux          # noqa: E731
                    cy = lambda py: (ph / 2 - py) * uy          # noqa: E731
                    a = (cx(float(req["sx"])), cy(float(req["sy"])))
                    b = (cx(float(req["ex"])), cy(float(req["ey"])))
                    attempts = self.planner.plan_endpoints(obj, a, b)
                elif op == "resize":
                    label = "resize"
                    ratio = float(req["ratio"])
                    if abs(ratio - 1) < 1e-3:
                        return {"ok": True, "message": "no change"}
                    attempts = self.planner.plan_resize(obj, ratio)
                elif op == "decorate":
                    kind = req.get("kind", "underline")
                    label = ("underline" if kind == "underline" else "strikethrough") + (" on" if req.get("on", True) else " off")
                    attempts = [(label, self.planner.plan_decoration(obj, kind, bool(req.get("on", True))))]
                elif op == "highlight":
                    label = "highlight" if req.get("color") else "remove highlight"
                    attempts = [(label, self.planner.plan_highlight(obj, req.get("color"), float(req.get("opacity", 0.6))))]
                elif op == "align":
                    label = "alignment"
                    attempts = [(label, self.planner.plan_align(obj, str(req["value"])))]
                elif op == "columns":
                    label = "columns"
                    attempts = [(label, self.planner.plan_columns(obj, int(req["value"])))]
                elif op == "spacing":
                    label = "line spacing"
                    if obj["kind"] != "text":
                        return {"ok": False, "error": "line spacing applies to text"}
                    attempts = [(label, self.planner.plan_arg(obj, "line_spacing", fmt(float(req["value"]), 2), outermost=True))]
                elif op == "clear_format":
                    label = "clear formatting"
                    attempts = [(label, self.planner.plan_clear_format(obj))]
                elif op == "size":
                    label = "size"
                    w = float(req["width"]) * ux if req.get("width") is not None else None
                    h = float(req["height"]) * uy if req.get("height") is not None else None
                    if w is None and h is None:
                        return {"ok": True, "message": "no change"}
                    attempts = self.planner.plan_size(obj, w, h)
                elif op == "rotate":
                    label = "rotate"
                    want = float(req["degrees"]) % 360.0
                    delta = math.radians(((want - float(obj.get("rotation") or 0.0)) + 180.0) % 360.0 - 180.0)
                    if abs(delta) < 1e-4:
                        return {"ok": True, "message": "no change"}
                    attempts = self.planner.plan_rotate(obj, delta)
                else:
                    return {"ok": False, "error": f"unknown operation {op}"}
            except EditError as exc:
                return {"ok": False, "error": str(exc)}

            if not attempts:
                return {"ok": False, "error": "nothing to edit"}
            if all(not edits for _, edits in attempts):
                return {"ok": True, "message": "no change"}
            last_error = "edit had no visible effect"
            for how, edits in attempts:
                try:
                    written = self.project.apply(edits)
                    self._sig_at = 0
                except Exception as exc:
                    last_error = f"could not patch source: {exc}"
                    continue
                new = self.render_now(name, interactive=True)
                if "error" in new:
                    self._restore(written, 0)
                    self.results.pop(name, None)
                    self.render_now(name, interactive=True)
                    last_error = new["error"]
                    if op in TEXT_OPS:
                        hint = ""
                        if "NoneType" in last_error or "get_part" in last_error:
                            hint = " The slide's code picks out parts of this text/formula by name, so the new content must keep those parts."
                        return {"ok": False, "error": "The slide no longer renders with this change, so it was undone: "
                                + last_error[-300:] + hint}
                    continue
                ok, why = self._verify(op, req, oid, stop, before_box, new["data"], ux, uy)
                if ok:
                    self._commit(label if op in TEXT_OPS else f"{label} ({how})", written)
                    msg = how
                    sib = None
                    if op in ("move", "resize", "endpoints", "size", "rotate"):
                        cnt = sum(1 for o in data["objects"].values()
                                  if o["frames"][-1]["pos"] == obj["frames"][-1]["pos"]
                                  and o["frames"][-1]["file"] == obj["frames"][-1]["file"])
                        if cnt > 1:
                            sib = cnt
                    return {"ok": True, "message": msg, "siblings": sib, "changed": self.last_changed}
                last_error = why
                self._restore(written, 0)
                self.results.pop(name, None)
                self.render_now(name, interactive=True)
            ctl = [e for e in obj["events"] if e["method"] in
                   ("move_to", "next_to", "to_edge", "to_corner", "align_to", "arrange", "arrange_in_grid")]
            if ctl and op in ("move", "resize", "endpoints", "size"):
                e = ctl[-1]
                fr = e["frames"][-1]
                last_error += f" (position is set by .{e['method']}() at {fr['file']}:{fr['pos'][0]})"
            return {"ok": False, "error": "Could not apply this change: " + last_error}

    def _verify(self, op, req, oid, stop, before_box, data, ux, uy):
        if op == "endpoints":
            ln = data["stops"][min(stop, len(data["stops"]) - 1)].get("lines", {}).get(oid)
            if not ln:
                return False, "line is not visible after the change"
            want = [float(req[k]) for k in ("sx", "sy", "ex", "ey")]
            if max(abs(ln[i] - want[i]) for i in range(4)) > 4:
                return False, "later code in the slide overrides this line"
            return True, ""
        if op == "rotate":
            got = float(data["objects"].get(oid, {}).get("rotation") or 0.0)
            want = float(req["degrees"]) % 360.0
            if abs(((got - want) + 180.0) % 360.0 - 180.0) > 0.5:
                return False, "later code in the slide overrides this rotation"
            return True, ""
        if op not in ("move", "resize", "size"):
            return True, ""
        vis = {str(v[0]): v for v in data["stops"][min(stop, len(data["stops"]) - 1)]["visible"]}
        after = vis.get(oid)
        if not after or not before_box:
            return False, "object is not visible after the change"
        if op == "size":
            dims = data["objects"].get(oid, {}).get("dims") or [after[3] - after[1], after[4] - after[2]]
            for k, i in (("width", 0), ("height", 1)):
                if req.get(k) is None:
                    continue
                got, want = float(dims[i]), float(req[k])
                if abs(got - want) > max(4.0, 0.03 * want):
                    return False, f"later code in the slide overrides this {k}"
            return True, ""
        cx0 = (before_box[1] + before_box[3]) / 2
        cy0 = (before_box[2] + before_box[4]) / 2
        cx1 = (after[1] + after[3]) / 2
        cy1 = (after[2] + after[4]) / 2
        if op == "move":
            ex, ey = cx0 + float(req["dx"]), cy0 + float(req["dy"])
            if abs(cx1 - ex) > 4 or abs(cy1 - ey) > 4:
                return False, "later code in the slide overrides this position"
        else:
            w0 = before_box[3] - before_box[1]
            w1 = after[3] - after[1]
            if abs(w1 / w0 - float(req["ratio"])) > 0.04 * max(1.0, float(req["ratio"])):
                return False, "later code in the slide overrides this size"
        return True, ""

    # ------------------------------------------------------- slide operations
    def _order_names(self) -> list[str]:
        return [x["name"] for x in self.scenes]

    def _order_edit(self, names: list[str]):
        from .srcedit import Edit
        try:
            old = self.project.read("order.txt")
        except FileNotFoundError:
            old = b""
        return Edit("order.txt", 0, len(old), " ".join(names) + "\n")

    def slide_op(self, req: dict) -> dict:
        """Edit a scene class or its membership in the show's order.txt."""
        from .srcedit import Edit
        with self.edit_lock:
            self.refresh_scenes()
            op = req["op"]
            name = req.get("scene")
            names = self._order_names()
            cur = self.scene(name) if name else None
            src = self.project.src(cur["file"]) if cur else None
            cls = next((n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == name), None) if src else None
            used = {x["name"] for x in self.all_scenes}

            def fresh(base):
                i = 1
                while f"{base}{i}" in used:
                    i += 1
                return f"{base}{i}"

            edits, label, select = [], op, name
            numbering = self._page_settings()        # slide numbers written in the deck follow every reordering
            final, nn = None, None                   # the show's order afterwards; a class this operation creates
            try:
                if op == "new":
                    if cls is None:
                        return {"ok": False, "error": "select a slide first"}
                    base = ast.unparse(cls.bases[0]) if cls.bases else "Scene"
                    nn = fresh("NewSlide")
                    i = names.index(name) if name in names else len(names) - 1
                    final = names[:i + 1] + [nn] + names[i + 1:]
                    body = "".join(f"        {ln}\n" for ln in self._layout_body(str(req.get("layout") or "title_content")))
                    text = f"\n\nclass {nn}({base}):\n    def construct(self):\n{body}"
                    if numbering:
                        text = self._page_patch_text(text, numbering["start"] + final.index(nn), numbering["start"] + len(final) - 1, numbering)
                    at = src.line_starts[cls.end_lineno] if cls.end_lineno < len(src.line_starts) else len(src.data)
                    if at == len(src.data) and not src.data.endswith(b"\n"):
                        text = "\n" + text
                    edits.append(Edit(src.rel, at, at, text))
                    edits.append(self._order_edit(final))
                    label, select = "new slide", nn
                elif op == "duplicate":
                    if cls is None:
                        return {"ok": False, "error": "select a slide first"}
                    nn = fresh(name + "Copy")
                    a = src.line_starts[cls.lineno - 1]
                    b = src.line_starts[cls.end_lineno] if cls.end_lineno < len(src.line_starts) else len(src.data)
                    chunk = src.data[a:b].decode("utf-8")
                    chunk = chunk.replace(f"class {name}(", f"class {nn}(", 1)
                    if not chunk.endswith("\n"):
                        chunk += "\n"
                    i = names.index(name) if name in names else len(names) - 1
                    final = names[:i + 1] + [nn] + names[i + 1:]
                    if numbering:
                        chunk = self._page_patch_text(chunk, numbering["start"] + final.index(nn), numbering["start"] + len(final) - 1, numbering)
                    edits.append(Edit(src.rel, b, b, "\n\n" + chunk if b < len(src.data) else "\n\n" + chunk))
                    edits.append(self._order_edit(final))
                    label, select = "duplicate slide", nn
                elif op == "delete":
                    if cls is None:
                        return {"ok": False, "error": "select a slide first"}
                    a = src.line_starts[cls.lineno - 1]
                    b = src.line_starts[cls.end_lineno] if cls.end_lineno < len(src.line_starts) else len(src.data)
                    # swallow the blank lines that separated it from the previous class
                    while a >= 2 and src.data[a - 1:a] == b"\n" and src.data[a - 2:a - 1] == b"\n":
                        a -= 1
                    edits.append(Edit(src.rel, a, b, ""))
                    i = names.index(name) if name in names else -1
                    rest = [n for n in names if n != name]
                    if name in names:
                        edits.append(self._order_edit(rest))
                        final = rest
                    label = "delete slide"
                    select = names[i + 1] if i >= 0 and i + 1 < len(names) else (names[i - 1] if i > 0 else (names[0] if names else None))
                elif op == "skip":
                    if name not in names:
                        return {"ok": False, "error": "slide is already skipped"}
                    i = names.index(name)
                    final = [n for n in names if n != name]
                    edits.append(self._order_edit(final))
                    if numbering and src is not None:
                        e = self._page_edit(src, self._construct(cur)[1], None, True)     # a skipped slide shows no stale number
                        if e:
                            edits.append(e)
                    label = "skip slide"
                    select = names[i + 1] if i + 1 < len(names) else (names[i - 1] if i > 0 else None)
                elif op == "unskip":
                    if name in names:
                        return {"ok": False, "error": "slide is already in the show"}
                    final = names + [name]
                    edits.append(self._order_edit(final))
                    label = "restore slide"
                elif op == "reorder":
                    if name not in names:
                        return {"ok": False, "error": "only slides in the show can be reordered"}
                    destination = req.get("index")
                    if not isinstance(destination, int) or isinstance(destination, bool) or not 0 <= destination <= len(names):
                        return {"ok": False, "error": "invalid slide destination"}
                    source = names.index(name)
                    if destination in (source, source + 1):
                        return {"ok": True, "message": "slide is already there", "select": name}
                    names.pop(source)
                    names.insert(destination - (1 if source < destination else 0), name)
                    edits.append(self._order_edit(names))
                    final = names
                    label = "move slide"
                elif op in ("hide", "unhide"):
                    if cls is None:
                        return {"ok": False, "error": "select a slide first"}
                    a = src.line_starts[cls.lineno - 1]
                    b = src.line_starts[cls.lineno] if cls.lineno < len(src.line_starts) else len(src.data)
                    line = src.data[a:b].decode("utf-8")
                    body = line.rstrip("\n")
                    nl = line[len(body):]
                    if op == "hide":
                        if self.HIDDEN_MARK in body:
                            return {"ok": True, "message": "slide is already hidden", "select": name}
                        new = body + "  " + self.HIDDEN_MARK + nl
                    else:
                        if self.HIDDEN_MARK not in body:
                            return {"ok": True, "message": "slide is not hidden", "select": name}
                        new = re.sub(r"\s*" + re.escape(self.HIDDEN_MARK), "", body) + nl
                    edits.append(Edit(src.rel, a, b, new))
                    label = "hide slide" if op == "hide" else "unhide slide"
                elif op in ("up", "down"):
                    i = names.index(name)
                    j = i - 1 if op == "up" else i + 1
                    if not 0 <= j < len(names):
                        return {"ok": True, "message": "already at the " + ("start" if op == "up" else "end"), "select": name}
                    names[i], names[j] = names[j], names[i]
                    edits.append(self._order_edit(names))
                    final = names
                    label = "move slide"
                else:
                    return {"ok": False, "error": f"unknown slide operation {op}"}
                if numbering and final is not None:
                    edits += self._page_edits(final, numbering, skip={nn} if nn else set())
                written = self.project.apply(edits)
                self._sig_at = 0
            except Exception as exc:
                return {"ok": False, "error": str(exc)}
            self._commit(label, written)
            self.refresh_scenes()
            if op == "delete":
                shutil.rmtree(self.cache_dir / name, ignore_errors=True)
                self.results.pop(name, None)
            self.enqueue_all()
            return {"ok": True, "message": label, "select": select}

    LAYOUTS = ("title", "title_content", "section", "two_content", "title_only", "blank")

    def _layout_body(self, layout: str) -> list[str]:
        """construct() statements (unindented) of a new slide with a PowerPoint-style layout."""
        font = ", font=FONT" if self._font_const() else ""

        def element(var, text, size, x, y, color=None):
            c = f", color={color}" if color else ""
            return [f"{var} = Text({py_str(text)}, font_size={size}{font}{c}).move_to(({fmt(x)}, {fmt(y)}, 0))  # manimble",
                    f"self.add({var})  # manimble"]
        bullets = "\u2022 First point\n\u2022 Second point\n\u2022 Third point"
        if layout == "title":
            return element("title", "Title", 64, 0, 0.7) + element("subtitle", "Subtitle", 32, 0, -0.8, "GREY_B")
        if layout == "section":
            return element("title", "Section title", 56, 0, 0.5) + element("subtitle", "Subtitle", 30, 0, -0.9, "GREY_B")
        if layout == "title_only":
            return element("title", "Title", 48, 0, 3.0)
        if layout == "two_content":
            return (element("title", "Title", 48, 0, 3.0) + element("left", bullets, 30, -3.4, 0.2)
                    + element("right", bullets, 30, 3.4, 0.2))
        if layout == "blank":
            return ["pass"]
        return element("title", "Title", 48, 0, 3.0) + element("body", bullets, 32, 0, 0.2)      # title and content

    # ------------------------------------------------------- slide numbers
    PAGE_MARK = "# manimble page number"
    PAGE_RE = re.compile(r"# manimble page number(?: pos=(\w+))?(?: start=(-?\d+))?(?: skip=([01]))?(?: total=([01]))?(?: size=(\d+))?")
    PAGE_PLACES = {"DR": "to_corner(DR, buff=0.35)", "DOWN": "to_edge(DOWN, buff=0.35)", "DL": "to_corner(DL, buff=0.35)"}
    PAGE_DEFAULTS = {"pos": "DR", "start": 1, "skip": True, "total": True, "size": 24}

    @classmethod
    def _page_parse(cls, text: str) -> dict | None:
        m = cls.PAGE_RE.search(text)
        if not m:
            return None
        pos = m.group(1) or "DR"
        return {"pos": pos if pos in cls.PAGE_PLACES else "DR", "start": int(m.group(2) or 1),
                "skip": m.group(3) == "1", "total": m.group(4) == "1", "size": int(m.group(5) or 24)}

    def _page_settings(self) -> dict | None:
        """The slide-number options recorded in the deck's marker comments; None when the deck has no numbers."""
        for s in self.scenes:
            try:
                src, fn = self._construct(s)
            except Exception:                       # noqa: BLE001
                continue
            hit = self._page_stmt(src, fn)
            if hit:
                return self._page_parse(hit[2]) or dict(self.PAGE_DEFAULTS)
        return None

    def _page_stmt(self, src, fn):
        """(start, end, text) of the slide-number statement Manimble wrote into construct(), if any."""
        for st in fn.body:
            a, b = _stmt_lines(src, st)
            text = src.data[a:b].decode("utf-8")
            if self.PAGE_MARK in text:
                return a, b, text
        return None

    def _background_is_light(self, src=None, fn=None) -> bool:
        """Whether the slide's background (set in construct(), else manim.cfg) is light, so dark text is needed."""
        color = self._default_background()
        if src is not None and fn is not None:
            try:
                info = self._bg_parse([t for _, _, t in self._bg_statements(src, fn)])
                if info["mode"] == "color" and info["color"]:
                    color = info["color"]
            except Exception:                       # noqa: BLE001
                pass
        try:
            r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
        except (ValueError, IndexError):
            return False
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6

    def _page_line(self, n: int, total: int, st: dict, src=None, fn=None) -> str:
        label = f"{n} / {total}" if st["total"] else str(n)
        font = ", font=FONT" if self._font_const() else ""
        color = '"#333333"' if self._background_is_light(src, fn) else '"#FFFFFF"'
        return (f"self.add(Text({py_str(label)}, font_size={st['size']}{font}, color={color}).{self.PAGE_PLACES[st['pos']]})"
                f"  {self.PAGE_MARK} pos={st['pos']} start={st['start']} skip={int(st['skip'])} total={int(st['total'])} size={st['size']}")

    def _is_preamble(self, src, st) -> bool:
        """Statements that stay at the top of construct(): docstring, background, slide number, speaker notes."""
        if isinstance(st, ast.Expr) and isinstance(st.value, ast.Constant) and isinstance(st.value.value, str):
            return True
        a, b = _stmt_lines(src, st)
        text = src.data[a:b].decode("utf-8")
        if self.BG_MARK in text or self.PAGE_MARK in text or self.NOTES_MARK in text:
            return True
        return isinstance(st, ast.Assign) and len(st.targets) == 1 and ast.unparse(st.targets[0]) == "self.camera.background_color"

    def _preamble_end(self, src, fn) -> tuple[int, str]:
        """(offset, indent) for a new statement after construct()'s preamble."""
        for st in fn.body:
            if not self._is_preamble(src, st):
                return src.line_starts[st.lineno - 1], " " * st.col_offset
        last = fn.body[-1]
        at = src.line_starts[last.end_lineno] if last.end_lineno < len(src.line_starts) else len(src.data)
        return at, " " * last.col_offset

    def _page_edit(self, src, fn, want: str | None, rewrite: bool):
        """One edit that brings construct()'s slide-number line to `want` (None: no line). Unless `rewrite`,
        an existing line only gets its number replaced, so a moved or restyled number keeps its tweaks."""
        from .srcedit import Edit
        old = self._page_stmt(src, fn)
        if old:
            a, b, text = old
            if want is None:
                return Edit(src.rel, a, b, "")
            if rewrite:
                indent = text[:len(text) - len(text.lstrip(" "))]
                return Edit(src.rel, a, b, indent + want + "\n")
            label = re.search(r'Text\("[^"]*"', want).group(0)
            new = re.sub(r'Text\("[^"]*"', lambda m: label, text, count=1)
            return Edit(src.rel, a, b, new) if new != text else None
        if want is None or not fn.body:
            return None
        at, indent = self._preamble_end(src, fn)
        lead = "\n" if at == len(src.data) and not src.data.endswith(b"\n") else ""
        return Edit(src.rel, at, at, lead + indent + want + "\n")

    def _page_edits(self, names: list, st: dict, skip=()) -> list:
        """Renumber the slides of the show in this order (scenes in `skip` are handled by the caller)."""
        edits = []
        total = st["start"] + len(names) - 1
        for i, n in enumerate(names):
            if n in skip:
                continue
            try:
                src, fn = self._construct(self.scene(n))
            except Exception:                       # noqa: BLE001
                continue
            want = None if (st["skip"] and i == 0) else self._page_line(st["start"] + i, total, st, src, fn)
            e = self._page_edit(src, fn, want, rewrite=False)
            if e:
                edits.append(e)
        return edits

    def _page_patch_text(self, text: str, n: int, total: int, st: dict) -> str:
        """The slide-number line applied to a class definition given as text (a new or duplicated slide)."""
        try:
            src = Src("chunk", text.encode("utf-8"))
        except SyntaxError:
            return text
        cls = next((n for n in src.tree.body if isinstance(n, ast.ClassDef)), None)
        fn = next((n for n in (cls.body if cls else []) if isinstance(n, ast.FunctionDef) and n.name == "construct"), None)
        if fn is None or not fn.body:
            return text
        want = self._page_line(n, total, st, src, fn)
        e = self._page_edit(src, fn, want, rewrite=False)
        if e is None:
            return text
        data = bytearray(src.data)
        data[e.start:e.end] = e.text.encode("utf-8")
        return bytes(data).decode("utf-8")

    def page_numbers(self, req: dict) -> dict:
        """Slide numbers: op=get reads the options; op=set writes `self.add(Text("3 / 10") ...)` into every slide of the
        show (pos DR|DOWN|DL, start, skip the title slide, show the total, font size); op=remove deletes them."""
        op = req.get("op", "get")
        self.refresh_scenes()
        if op == "get":
            st = self._page_settings()
            return {"on": st is not None, **(st or self.PAGE_DEFAULTS)}
        with self.edit_lock:
            names = self._order_names()
            edits = []
            if op == "remove":
                for s in self.all_scenes:
                    try:
                        src, fn = self._construct(s)
                    except Exception:               # noqa: BLE001
                        continue
                    e = self._page_edit(src, fn, None, True)
                    if e:
                        edits.append(e)
                label = "remove slide numbers"
            elif op == "set":
                pos = str(req.get("pos") or "DR").upper()
                st = {"pos": pos if pos in self.PAGE_PLACES else "DR", "start": int(req.get("start", 1)),
                      "skip": bool(req.get("skip", True)), "total": bool(req.get("total", True)),
                      "size": max(6, min(200, int(req.get("size", 24) or 24)))}
                total = st["start"] + len(names) - 1
                for i, n in enumerate(names):
                    try:
                        src, fn = self._construct(self.scene(n))
                    except Exception:               # noqa: BLE001
                        continue
                    want = None if (st["skip"] and i == 0) else self._page_line(st["start"] + i, total, st, src, fn)
                    e = self._page_edit(src, fn, want, rewrite=True)
                    if e:
                        edits.append(e)
                label = "slide numbers"
            else:
                return {"ok": False, "error": f"unknown slide-number operation {op}"}
            if not edits:
                return {"ok": True, "message": "no change"}
            try:
                written = self.project.apply(edits)
                self._sig_at = 0
            except Exception as exc:                # noqa: BLE001
                return {"ok": False, "error": f"could not patch source: {exc}"}
            current = req.get("scene") if req.get("scene") in names else (names[0] if names else None)
            if current:
                new = self.render_now(current, interactive=True)
                if "error" in new:
                    self._restore(written, 0)
                    self.results.pop(current, None)
                    self.render_now(current, interactive=True)
                    return {"ok": False, "error": "The slide no longer renders with slide numbers, so they were undone: "
                            + new["error"][-300:]}
            self._commit(label, written)
            self.refresh_scenes()
            self.enqueue_all()
            return {"ok": True, "message": label, "changed": self.last_changed}

    # ------------------------------------------------------- one-file Python export
    def export_python(self, req: dict) -> dict:
        """Write the whole deck as one Python file: helper modules inlined, then the slides in show order.
        Deck-local imports are dropped (their code is in the file); everything else is kept as written."""
        path = req.get("path")
        if not path:
            return {"ok": False, "error": "no destination"}
        self.refresh_scenes()
        include_hidden = bool(req.get("hidden", False))
        wanted = [s for s in self.scenes if include_hidden or not s.get("hidden")]
        scene_names = {s["name"] for s in self.all_scenes}
        local = {rel[:-3] for rel in self.project.py_files()}
        srcs = {}
        for rel in self.project.py_files():
            try:
                srcs[rel[:-3]] = self.project.src(rel)
            except SyntaxError as exc:
                return {"ok": False, "error": f"{rel}: {exc}"}

        def local_import(node) -> bool:
            if isinstance(node, ast.ImportFrom):
                return node.level == 0 and (node.module or "").split(".")[0] in local
            if isinstance(node, ast.Import):
                return all(a.name.split(".")[0] in local for a in node.names)
            return False

        def deps(mod) -> set:
            out = set()
            for n in srcs[mod].tree.body:
                if isinstance(n, ast.ImportFrom) and local_import(n):
                    out.add(n.module.split(".")[0])
                elif isinstance(n, ast.Import) and local_import(n):
                    out |= {a.name.split(".")[0] for a in n.names}
            return out & set(srcs) - {mod}

        def chunk(src, node) -> str:
            a = src.line_starts[node.lineno - 1]
            b = src.line_starts[node.end_lineno] if node.end_lineno < len(src.line_starts) else len(src.data)
            # decorators sit above the node's first line
            for d in getattr(node, "decorator_list", []):
                a = min(a, src.line_starts[d.lineno - 1])
            return src.data[a:b].decode("utf-8")

        # helper modules first, each after the ones it imports; then the non-scene code of the scene modules
        ordered, seen = [], set()

        def visit(mod):
            if mod in seen:
                return
            seen.add(mod)
            for d in sorted(deps(mod)):
                visit(d)
            ordered.append(mod)
        helpers = [m for m in sorted(srcs) if not any(isinstance(n, ast.ClassDef) and n.name in scene_names for n in srcs[m].tree.body)]
        scene_mods = [m for m in sorted(srcs) if m not in helpers]
        for m in helpers + scene_mods:
            visit(m)
        parts = [f'"""{os.path.basename(os.path.dirname(self.deck))}/{os.path.basename(self.deck)}: the whole deck in one file, '
                 f'written by Manimble.\n\nKeep it in the deck folder (or next to the deck\'s assets) so relative paths still work.\n"""\n']
        for mod in ordered:
            src = srcs[mod]
            body = []
            for n in src.tree.body:
                if local_import(n) or (isinstance(n, ast.ClassDef) and n.name in scene_names):
                    continue
                if isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str) and n is src.tree.body[0]:
                    continue                                # module docstring
                if isinstance(n, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and body:
                    body.append("\n\n")
                body.append(chunk(src, n))
            text = "".join(body).strip("\n")
            if text:
                parts.append(f"\n# ---- {mod}.py\n\n{text}\n")
        parts.append("\n# ---- slides, in the order of the show\n")
        for s in wanted:
            src = srcs.get(s["module"])
            cls = next((n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == s["name"]), None) if src else None
            if cls is None:
                continue
            parts.append("\n\n" + chunk(src, cls).rstrip("\n") + "\n")
        parts.append("\n\nSLIDES = [" + ", ".join(py_str(s["name"]) for s in wanted) + "]   # the show, in order\n")
        out = "".join(parts)
        try:
            ast.parse(out)
        except SyntaxError as exc:
            return {"ok": False, "error": f"the combined file does not parse: line {exc.lineno}: {exc.msg}"}
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(out)
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "message": f"{len(wanted)} slides written to {os.path.basename(path)}", "path": path}

    # ------------------------------------------------------- speaker notes
    NOTES_MARK = "# manimble notes"

    def _notes_stmt(self, src, fn):
        """(statement, keyword) of the leading `self.next_slide(notes=...)` that holds the slide's speaker notes."""
        for st in fn.body:
            if isinstance(st, ast.Expr) and isinstance(st.value, ast.Call) and ast.unparse(st.value.func) == "self.next_slide":
                kw = next((k for k in st.value.keywords if k.arg == "notes"), None)
                if kw is not None and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
                    return st, kw
                return None
            if not self._is_preamble(src, st):
                return None
        return None

    def _notes_of(self, name: str) -> str:
        try:
            src, fn = self._construct(self.scene(name))
            hit = self._notes_stmt(src, fn)
            return hit[1].value.value if hit else ""
        except Exception:                           # noqa: BLE001
            return ""

    def notes(self, req: dict) -> dict:
        """Speaker notes of a slide: op=get -> {text}; op=set writes `self.next_slide(notes="...")` at the top of
        construct() (what manim-slides' presenter shows for the first build), or removes it for empty text."""
        from .srcedit import Edit
        op = req.get("op", "get")
        name = req["scene"]
        self.refresh_scenes()
        if op == "get":
            return {"text": self._notes_of(name)}
        with self.edit_lock:
            text = str(req.get("text") or "")
            try:
                src, fn = self._construct(self.scene(name))
            except (EditError, KeyError) as exc:
                return {"ok": False, "error": str(exc)}
            hit = self._notes_stmt(src, fn)
            if hit:
                st, kw = hit
                if kw.value.value == text:
                    return {"ok": True, "message": "no change"}
                if text:
                    a, b = src.span(kw.value)
                    edit = Edit(src.rel, a, b, py_str(text))
                elif not st.value.args and len(st.value.keywords) == 1:
                    a, b = _stmt_lines(src, st)
                    edit = Edit(src.rel, a, b, "")
                else:
                    edit = remove_kwargs(src, st.value, {kw})
            else:
                if not text.strip():
                    return {"ok": True, "message": "no change"}
                first = fn.body[0]
                doc = isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str)
                if doc and len(fn.body) > 1:
                    first = fn.body[1]
                indent = " " * first.col_offset
                line = f"self.next_slide(notes={py_str(text)})  {self.NOTES_MARK}"
                if doc and len(fn.body) == 1:
                    at = src.line_starts[first.end_lineno] if first.end_lineno < len(src.line_starts) else len(src.data)
                    lead = "\n" if at == len(src.data) and not src.data.endswith(b"\n") else ""
                    edit = Edit(src.rel, at, at, lead + indent + line + "\n")
                else:
                    at = src.line_starts[first.lineno - 1]
                    edit = Edit(src.rel, at, at, indent + line + "\n")
            try:
                written = self.project.apply([edit])
                self._sig_at = 0
            except Exception as exc:                # noqa: BLE001
                return {"ok": False, "error": f"could not patch source: {exc}"}
            new = self.render_now(name, interactive=True)
            if "error" in new:
                self._restore(written, 0)
                self.results.pop(name, None)
                self.render_now(name, interactive=True)
                return {"ok": False, "error": "The slide no longer renders with these notes (its class needs manim_slides' "
                        "next_slide), so they were undone: " + new["error"][-300:]}
            self._commit("speaker notes", written)
            self.refresh_scenes()
            self.enqueue_all()
            return {"ok": True, "message": "speaker notes", "changed": self.last_changed}

    def deck_pages(self, req: dict) -> dict:
        """Every build of every slide, in order, for the slideshow (hidden slides left out)."""
        slides = []
        for s in self.visible_scenes():
            sc = self.api_scene(s["name"])
            if sc.get("status") != "ready":
                slides.append({"scene": s["name"], "error": sc.get("error", "not rendered"), "pages": []})
            else:
                slides.append({"scene": s["name"], "pages": [st["png"] for st in sc["stops"]], "notes": self._notes_of(s["name"])})
        return {"slides": slides}

    # ------------------------------------------------------------ insert
    def _font_const(self) -> bool:
        return bool(self.project.top_level_assigns("FONT"))

    def _units(self, name: str | None):
        """(ux, uy, pw, ph): manim units per frame pixel and the frame size in pixels."""
        rec = self.results.get(name) if name else None
        data = (rec or {}).get("data")
        if data:
            (fw, fh), (pw, ph) = data["frame"], data["size"]
        else:
            fw, fh, pw, ph = 14.222222, 8.0, 1280, 720
        return fw / pw, fh / ph, pw, ph

    def _insert_code(self, kind: str, req: dict, preview: bool = False) -> str | None:
        font = ""
        if self._font_const():
            if preview:
                hits = self.project.top_level_assigns("FONT")
                if hits and isinstance(hits[0][1], ast.Constant):
                    font = f", font={py_str(hits[0][1].value)}"
            else:
                font = ", font=FONT"
        origin = "(0, 0, 0)"
        # drawn on the canvas: start/end in frame pixels -> manim units
        a, b = (-1.5, 0.0), (1.5, 0.0)
        if req.get("sx") is not None:
            ux, uy, pw, ph = self._units(req.get("scene"))
            a = ((float(req["sx"]) - pw / 2) * ux, (ph / 2 - float(req["sy"])) * uy)
            b = ((float(req["ex"]) - pw / 2) * ux, (ph / 2 - float(req["ey"])) * uy)
            origin = f"({fmt((a[0] + b[0]) / 2)}, {fmt((a[1] + b[1]) / 2)}, 0)"
        w, h = max(abs(b[0] - a[0]), 0.05), max(abs(b[1] - a[1]), 0.05)
        pa, pb = f"({fmt(a[0])}, {fmt(a[1])}, 0)", f"({fmt(b[0])}, {fmt(b[1])}, 0)"
        drawn = req.get("sx") is not None
        codes = {
            "text": f'Text("Text", font_size=36{font}).move_to({origin})',
            "formula": f'MathTex({py_tex(req.get("tex") or "x^2 + y^2 = z^2", True)}, font_size=48).move_to({origin})',
            "rectangle": f'Rectangle(width={fmt(w) if drawn else 3}, height={fmt(h) if drawn else 1.8}, color=WHITE, stroke_width=4).move_to({origin})',
            "rounded": f'RoundedRectangle(width={fmt(w) if drawn else 3}, height={fmt(h) if drawn else 1.8}, corner_radius=0.25, color=WHITE, stroke_width=4).move_to({origin})',
            "circle": f'Circle(radius={fmt(min(w, h) / 2) if drawn else 1}, color=WHITE, stroke_width=4).move_to({origin})',
            "ellipse": f'Ellipse(width={fmt(w) if drawn else 3}, height={fmt(h) if drawn else 1.8}, color=WHITE, stroke_width=4).move_to({origin})',
            "triangle": f'Triangle(color=WHITE, stroke_width=4).scale(1.2).move_to({origin})',
            "line": f'Line({pa}, {pb}, color=WHITE, stroke_width=4)',
            "arrow": f'Arrow({pa}, {pb}, buff=0, color=WHITE)',
            "darrow": f'DoubleArrow({pa}, {pb}, buff=0, color=WHITE)',
        }
        if kind == "table":
            r, c = max(1, int(req.get("rows", 3))), max(1, int(req.get("cols", 3)))
            data = "[" + ", ".join("[" + ", ".join(str(i * c + j + 1) for j in range(c)) + "]" for i in range(r)) + "]"
            codes["table"] = f"MathTable({data}, include_outer_lines=True).scale(0.7).move_to({origin})"
        if kind == "image":
            iw = fmt(w) if drawn else "4"           # drawn / placed: the box's width in manim units
            if preview:
                codes["image"] = f'ImageMobject({py_str(req["path"])}).set(width={iw}).move_to({origin})'
            else:
                codes["image"] = (f'ImageMobject(str(__import__("pathlib").Path(__file__).resolve().parent / {py_str(req["file"])}))'
                                  f'.set(width={iw}).move_to({origin})')
        if kind == "pen":
            pts = [p for p in (req.get("points") or []) if isinstance(p, (list, tuple)) and len(p) == 2]
            if len(pts) < 2:
                return None
            ux, uy, pw, ph = self._units(req.get("scene"))
            coords = ", ".join(f"({fmt((float(x) - pw / 2) * ux, 2)}, {fmt((ph / 2 - float(y)) * uy, 2)}, 0)" for x, y in pts)
            color = str(req.get("color") or "#FF3B30").upper()
            if not re.fullmatch(r"#[0-9A-F]{6}", color):
                color = "#FF3B30"
            width = fmt(min(max(float(req.get("width", 6) or 6), 0.5), 60), 1)
            codes["pen"] = f'VMobject(color={py_str(color)}, stroke_width={width}).set_points_smoothly([{coords}])'
        return codes.get(kind)

    def insert_sprite(self, req: dict) -> dict:
        """Instant raster of what an insert will look like (shown while the real insert renders)."""
        code = self._insert_code(req["kind"], req, preview=True)
        if code is None:
            return {"error": "unknown element"}
        return self.aux_worker.request({"cmd": "sprite", "kind": "code", "code": code, "out": str(self.cache_dir / "sprites")})

    def insert(self, req: dict) -> dict:
        with self.edit_lock:
            name, kind = req["scene"], req["kind"]
            rec = self.fresh_record(name)
            if "error" in rec:
                return {"ok": False, "error": rec["error"]}
            nstops = len(rec["data"]["stops"])
            code = self._insert_code(kind, req)
            if code is None:
                return {"ok": False, "error": f"unknown element {kind}"}
            try:
                stops = rec["data"]["stops"]
                si = min(int(req.get("stop", 0)), nstops - 1)
                edit, line = self.planner.plan_insert(self.scene(name), si, nstops, code,
                                                      stops[si].get("site") if si < nstops - 1 else None,
                                                      tag="pen" if kind == "pen" else "")
                written = self.project.apply([edit])
                self._sig_at = 0
            except Exception as exc:
                return {"ok": False, "error": str(exc)}
            new = self.render_now(name, interactive=True)
            if "error" in new:
                self._restore(written, 0)
                self.results.pop(name, None)
                self.render_now(name, interactive=True)
                return {"ok": False, "error": new["error"]}
            self._commit(f"insert {kind}", written)
            d = new["data"]
            vis = {v[0] for v in d["stops"][min(si, len(d["stops"]) - 1)]["visible"]}
            shown = any(oid in vis for oid in (int(k) for k, o in d["objects"].items()
                                                 if o["frames"][-1]["pos"][0] == line and o["frames"][-1]["file"] == edit.rel))
            return {"ok": True, "message": f"inserted {kind}", "line": line, "file": edit.rel,
                    "changed": self.last_changed, "hidden": not shown}

    def insert_many(self, req: dict) -> dict:
        """Insert several elements (`items`: one dict per element, as for `insert`) at the same build as one undo step."""
        with self.edit_lock:
            name = req["scene"]
            items = [it for it in (req.get("items") or []) if isinstance(it, dict) and it.get("kind")]
            if not items:
                return {"ok": False, "error": "nothing to insert"}
            rec = self.fresh_record(name)
            if "error" in rec:
                return {"ok": False, "error": rec["error"]}
            stops = rec["data"]["stops"]
            nstops = len(stops)
            si = min(int(req.get("stop", 0)), nstops - 1)
            site = stops[si].get("site") if si < nstops - 1 else None
            try:
                edits = []
                for it in items:
                    code = self._insert_code(it["kind"], dict(it, scene=name))
                    if code is None:
                        return {"ok": False, "error": f"unknown element {it['kind']}"}
                    edit, _ = self.planner.plan_insert(self.scene(name), si, nstops, code, site,
                                                       tag="pen" if it["kind"] == "pen" else "")
                    edits.append(edit)
                # edits at one offset land in reverse order of application: keep the items' order on the slide
                written = self.project.apply(list(reversed(edits)))
                self._sig_at = 0
            except Exception as exc:
                return {"ok": False, "error": str(exc)}
            new = self.render_now(name, interactive=True)
            if "error" in new:
                self._restore(written, 0)
                self.results.pop(name, None)
                self.render_now(name, interactive=True)
                return {"ok": False, "error": new["error"]}
            kinds = {it["kind"] for it in items}
            what = f"{len(items)} {next(iter(kinds))}s" if len(kinds) == 1 else f"{len(items)} elements"
            self._commit(f"insert {what}", written)
            return {"ok": True, "message": f"inserted {what}", "file": edits[0].rel, "changed": self.last_changed}

    # -------------------------------------------------------- background
    BG_MARK = "# manimble background"

    def _default_background(self) -> str:
        """The deck-wide background colour from manim.cfg (black when not set)."""
        import configparser
        cp = configparser.ConfigParser()
        try:
            cp.read(os.path.join(self.deck, "manim.cfg"), encoding="utf-8")
            v = cp.get("CLI", "background_color", fallback="#000000").strip().strip('"\'')
        except Exception:
            v = "#000000"
        return v.upper() if re.fullmatch(r"#[0-9A-Fa-f]{6}", v) else "#000000"

    def _construct(self, s: dict):
        src = self.project.src(s["file"])
        cls = next((n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == s["name"]), None)
        fn = next((n for n in (cls.body if cls else []) if isinstance(n, ast.FunctionDef) and n.name == "construct"), None)
        if fn is None:
            raise EditError(f"{s['name']} has no construct()")
        return src, fn

    def _bg_statements(self, src, fn) -> list:
        """[(start, end, text)] of construct()'s top-level statements that set the slide background:
        lines Manimble wrote (marked) and plain `self.camera.background_color = ...` (e.g. from an import)."""
        out = []
        for st in fn.body:
            a = src.line_starts[st.lineno - 1]
            b = src.line_starts[st.end_lineno] if st.end_lineno < len(src.line_starts) else len(src.data)
            text = src.data[a:b].decode("utf-8")
            plain = (isinstance(st, ast.Assign) and len(st.targets) == 1
                     and ast.unparse(st.targets[0]) == "self.camera.background_color")
            if self.BG_MARK in text or plain:
                out.append((a, b, text))
        return out

    def _bg_parse(self, texts: list) -> dict:
        info = {"mode": "none", "color": None, "image": None, "transparency": 0.0}
        for t in texts:
            if "background_color" in t:
                m = re.search(r'["\'](#[0-9A-Fa-f]{6})["\']', t)
                info["color"] = m.group(1).upper() if m else None
                m = re.search(r"interpolate_color\(.*,\s*([0-9.]+)\s*\)", t)
                if info["mode"] == "none":
                    info["mode"] = "color"
                    info["transparency"] = float(m.group(1)) if m else 0.0
            elif "ImageMobject" in t:
                m = re.search(r'/\s*("(?:[^"\\]|\\.)*")\s*\)', t)
                if m:
                    info["image"] = str(Path(self.deck) / json.loads(m.group(1)))
                m = re.search(r"set_opacity\(\s*([0-9.]+)\s*\)", t)
                info["mode"] = "image"
                info["transparency"] = round(1 - float(m.group(1)), 3) if m else 0.0
        return info

    def _bg_code(self, req: dict, base: str) -> list[str]:
        mode = req.get("mode")
        t = min(max(float(req.get("transparency", 0) or 0), 0.0), 1.0)
        if mode == "color":
            c = str(req.get("color", "#000000")).upper()
            if not re.fullmatch(r"#[0-9A-F]{6}", c):
                raise EditError(f"not a colour: {c}")
            if t < 0.005:
                return [f'self.camera.background_color = "{c}"']
            return [f'self.camera.background_color = interpolate_color(ManimColor("{c}"), ManimColor("{base}"), {fmt(t)})']
        if mode == "image":
            f = req.get("file")
            if not f or not (Path(self.deck) / f).is_file():
                raise EditError("choose a picture first")
            opacity = f".set_opacity({fmt(1 - t)})" if t >= 0.005 else ""
            return [f'self.add(ImageMobject(str(__import__("pathlib").Path(__file__).resolve().parent / {py_str(f)}))'
                    f'.stretch_to_fit_width(config.frame_width).stretch_to_fit_height(config.frame_height)'
                    f'{opacity}.set_z_index(-1000))']
        raise EditError(f"unknown background mode {mode}")

    def background(self, req: dict) -> dict:
        """Read (op=get), set (op=set) or remove (op=reset) a slide's background; all=True for every slide."""
        from .srcedit import Edit
        op = req.get("op", "get")
        self.refresh_scenes()
        base = self._default_background()
        if op == "get":
            src, fn = self._construct(self.scene(req["scene"]))
            info = self._bg_parse([t for _, _, t in self._bg_statements(src, fn)])
            info["default"] = base
            return info
        with self.edit_lock:
            name = req["scene"]
            targets = self.scenes if req.get("all") else [self.scene(name)]
            edits = []
            try:
                lines = self._bg_code(req, base) if op == "set" else []
                for s in targets:
                    src, fn = self._construct(s)
                    old = self._bg_statements(src, fn)
                    first = fn.body[0]
                    if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str) \
                            and len(fn.body) > 1:
                        first = fn.body[1]                    # keep the docstring on top
                    indent = " " * first.col_offset
                    new = "".join(f"{indent}{ln}  {self.BG_MARK}\n" for ln in lines)
                    if old:
                        edits.append(Edit(src.rel, old[0][0], old[0][1], new))
                        edits += [Edit(src.rel, a, b, "") for a, b, _ in old[1:]]
                    elif new:
                        at = src.line_starts[first.lineno - 1]
                        edits.append(Edit(src.rel, at, at, new))
                if not edits:
                    return {"ok": True, "message": "no change"}
                written = self.project.apply(edits)
                self._sig_at = 0
            except Exception as exc:
                return {"ok": False, "error": str(exc)}
            new = self.render_now(name, interactive=True)
            if "error" in new:
                self._restore(written, 0)
                self.results.pop(name, None)
                self.render_now(name, interactive=True)
                return {"ok": False, "error": "The slide no longer renders with this background, so it was undone: "
                        + new["error"][-300:]}
            label = "reset background" if op == "reset" else "set background"
            self._commit(label + (" (all slides)" if req.get("all") else ""), written)
            self.refresh_scenes()
            self.enqueue_all()
            n = len(targets)
            return {"ok": True, "message": label + (f" on {n} slides" if n > 1 else ""), "changed": self.last_changed}

    # -------------------------------------------------------- dark mode
    def dark_mode(self, req: dict) -> dict:
        """Write the dark-mode colour flip (mode "dark") or inverted colours (mode "invert") into the deck,
        as one undo step.

        1. every colour the mode changes that is written in the source (and manim.cfg's background) is mapped;
        2. every slide is re-rendered, and objects still showing their old colour (a default,
           e.g. Text without color=) get an explicit color= with the mapped value."""
        from . import darkmode as dm
        from .srcedit import insert_kwarg, locate
        emit = self.on_event or (lambda e: None)
        current = req.get("current")
        mode = req.get("mode", "dark")
        if mode not in ("dark", "invert"):
            return {"ok": False, "error": f"unknown colour mode {mode}"}
        named = {}
        if mode == "invert":
            named = self.aux_worker.request({"cmd": "colors"}).get("colors") or {}
        with self.edit_lock:
            self.refresh_scenes()
            names = [s["name"] for s in self.scenes]
            total = 2 * len(names)

            def prog(i, name):
                emit({"event": "darkmode", "phase": "building", "done": i, "total": total, "scene": name, "mode": mode})

            before = {}
            for i, n in enumerate(names):
                prog(i, n)
                rec = self.fresh_record(n)
                if "data" in rec:
                    before[n] = rec["data"]["objects"]
            edits, _ = dm.plan_literals(self.project, self.deck, mode, named)
            written = {}
            try:
                if edits:
                    written = self.project.apply(edits)
                    self._sig_at = 0
                    if "manim.cfg" in written:
                        self._restart_workers()
            except Exception as exc:                           # noqa: BLE001
                return {"ok": False, "error": f"could not patch source: {exc}"}

            def undo_all(why: str) -> dict:
                self._restore(written, 0)
                self.refresh_scenes()
                self.enqueue_all()
                return {"ok": False, "error": why}

            # objects whose neutral colour did not follow (a default): give them an explicit color=
            inserts: dict = {}
            skipped = 0
            broken = []
            self.refresh_scenes()
            for i, n in enumerate(names):
                prog(len(names) + i, n)
                rec = self.render_now(n, interactive=True)
                if "error" in rec:
                    if n in before:
                        broken.append(n)
                    continue
                old = before.get(n, {})
                for oid, o in rec["data"]["objects"].items():
                    p = old.get(oid)
                    c = (o.get("color") or "").upper()
                    if (not p or p["kind"] != o["kind"] or o["kind"] not in ("text", "tex", "shape", "line", "table")
                            or p["frames"][-1]["file"] != o["frames"][-1]["file"]
                            or p["frames"][-1]["pos"][0] != o["frames"][-1]["pos"][0] or not c or not dm.HEX.fullmatch(c)
                            or not dm.changes(c, mode) or (p.get("color") or "").upper() != c):
                        continue
                    lit = py_str(dm.map_hex(c, mode))
                    if o["kind"] == "table":
                        # a table's lines and cells take their colours from these two configs
                        ts = [locate(self.project, o["frames"], 0, k, None, resolve_globals=False)
                              for k in ("line_config", "element_to_mobject_config")]
                        if any(t.kind != "missing" for t in ts) or ts[0].call is not ts[1].call:
                            skipped += 1
                            continue
                        t = ts[0]
                        e = insert_kwarg(t.src, t.call, "line_config", f'{{"color": {lit}}}')
                        e.text += f', element_to_mobject_config={{"color": {lit}}}'
                    else:
                        t = locate(self.project, o["frames"], 0, "color", None, resolve_globals=False)
                        if t.kind != "missing":
                            skipped += 1                       # computed, or set in a way we cannot flip
                            continue
                        e = insert_kwarg(t.src, t.call, t.param or "color", lit)
                    inserts.setdefault((e.rel, e.start), (e, n))
            if broken:
                return undo_all(("Dark mode" if mode == "dark" else "Inverted colours") + " was not applied: these slides stop rendering with it: " + ", ".join(broken))
            added = 0
            if inserts:
                try:
                    w2 = self.project.apply([e for e, _ in inserts.values()])
                    self._sig_at = 0
                except Exception as exc:                       # noqa: BLE001
                    w2 = None
                    skipped += len(inserts)
                    print(f"dark mode: could not insert colours: {exc}", file=sys.stderr)
                if w2:
                    self.refresh_scenes()
                    failed = [n for n in sorted({n for _, n in inserts.values()})
                              if "error" in self.render_now(n, interactive=True)]
                    if failed:
                        self._restore(w2, 0)
                        self._sig_at = 0
                        skipped += len(inserts)
                    else:
                        added = len(inserts)
                        for rel, (b, a) in w2.items():
                            written[rel] = (written[rel][0], a) if rel in written else (b, a)
            if not written:
                return {"ok": True, "message": "no change"}
            what = "dark mode" if mode == "dark" else "inverted colours"
            self._commit("apply " + what, written)
            self.refresh_scenes()
            if current:
                self.enqueue(current, front=True)
            self.enqueue_all()
            msg = f"{what} written to the deck: {len(edits)} colours changed"
            if added:
                msg += f", {added} default colours set"
            if skipped:
                msg += f"; {skipped} computed colours left as they are"
            return {"ok": True, "message": msg, "changed": self.last_changed}

    def pages(self, req: dict) -> dict:
        """Frame images for exporting: every build or just the last build of each slide (hidden slides left out)."""
        out = []
        for s in self.visible_scenes():
            sc = self.api_scene(s["name"])
            if sc.get("status") != "ready":
                return {"error": f"{s['name']}: {sc.get('error', 'not rendered')}"}
            stops = sc["stops"]
            for st in (stops if req.get("builds") else stops[-1:]):
                out.append(st["png"])
        return {"pages": out}

    # ---------------------------------------------------- undo / redo
    def undo(self) -> dict:
        with self.edit_lock:
            if not self.history:
                return {"ok": False, "error": "nothing to undo"}
            e = self.history.pop()
            self._restore(e["files"], 0)
            self.redo.append(e)
            self.last_changed = {}
            return {"ok": True, "label": e["label"]}

    def redo_(self) -> dict:
        with self.edit_lock:
            if not self.redo:
                return {"ok": False, "error": "nothing to redo"}
            e = self.redo.pop()
            self._restore(e["files"], 1)
            self.history.append(e)
            self.last_changed = self._diff_lines(e["files"])
            return {"ok": True, "label": e["label"]}

    # ------------------------------------------------------------ misc
    def sprite(self, req: dict) -> dict:
        """Rasterise a single text/formula for instant on-canvas preview."""
        req = dict(req, cmd="sprite", out=str(self.cache_dir / "sprites"))
        return self.aux_worker.request(req)

    # ------------------------------------------------------- PowerPoint / Keynote
    def export(self, req: dict) -> dict:
        if getattr(self, "_exporting", False):
            return {"ok": False, "error": "an export is already running"}
        self._exporting = True
        threading.Thread(target=self._export_job, args=(req,), daemon=True).start()
        return {"ok": True}

    def _export_job(self, req: dict):
        from . import export as ex
        emit = self.on_event or (lambda e: None)
        try:
            def prog(i, n, name):
                emit({"event": "export", "phase": "building", "done": i, "total": n, "scene": name})
            builds, editable = bool(req.get("builds", True)), bool(req.get("editable", True))
            if req["kind"] == "pptx":
                r = ex.build_pptx(self, req["path"], builds, editable, prog)
            else:
                import tempfile
                tmp = os.path.join(tempfile.mkdtemp(), "deck.pptx")
                r = ex.build_pptx(self, tmp, builds, editable, prog)
                if r.get("ok"):
                    emit({"event": "export", "phase": "keynote"})
                    r = ex.pptx_to_keynote(tmp, req["path"])
            emit({"event": "export", "phase": "done" if r.get("ok") else "error", "path": req["path"], "error": r.get("error")})
        except Exception as exc:                          # noqa: BLE001
            emit({"event": "export", "phase": "error", "error": str(exc)})
        finally:
            self._exporting = False

    # --------------------------------------------------- Manim Slides presenter
    def present(self, req: dict | None = None) -> dict:
        """Build whatever slides are out of date, then hand their clips to the app's native animated player.

        Runs in the background and reports through events: {"event": "present", "phase": ...}; the last one is
        {"phase": "ready", "slides": [...], "sections": [...], "links": {...}}. Needs manim and manim_slides in the
        Python environment, but not Qt: nothing here imports the Manim Slides presenter."""
        if getattr(self, "_presenting", False):
            return {"ok": False, "error": "already building the presentation"}
        req = req or {}
        if req.get("scene"):
            try:
                self.scene(req["scene"])
            except KeyError:
                return {"ok": False, "error": f"unknown slide: {req['scene']}"}
        self._presenting = True
        threading.Thread(target=self._present_job, args=(req.get("scene"), self._clip_height(req)), daemon=True).start()
        return {"ok": True}

    def animation_preview(self, req: dict) -> dict:
        """Build one scene and send its clips to the native editor player."""
        if getattr(self, "_presenting", False):
            return {"ok": False, "error": "already building the presentation"}
        name = req.get("scene")
        if not name:
            return {"ok": False, "error": "choose a slide to preview"}
        try:
            self.scene(name)
        except KeyError:
            return {"ok": False, "error": f"unknown slide: {name}"}
        self._presenting = True
        threading.Thread(target=self._animation_preview_job, args=(name, self._clip_height(req)), daemon=True).start()
        return {"ok": True}

    # Build resolutions for the animated show, by frame height. 720p is the default (and what builds made before
    # the setting existed are); higher ones look sharper on big screens but take longer to build.
    CLIP_SIZES = {720: "1280,720", 1080: "1920,1080", 1440: "2560,1440", 2160: "3840,2160"}

    def _clip_height(self, req: dict) -> int:
        h = int(req.get("height") or 720)
        return h if h in self.CLIP_SIZES else 720

    def _animation_preview_job(self, name: str, height: int = 720):
        emit = self.on_event or (lambda e: None)
        try:
            selected = [self.scene(name)]
            if not self._build_animation_slides(selected, "animation_preview", height):
                return
            manifest = Path(self.deck) / "slides" / f"{name}.json"
            data = json.loads(manifest.read_text())
            clips = []
            for slide in data.get("slides", []):
                relative = slide.get("file")
                if not isinstance(relative, str):
                    raise ValueError("animation manifest has a clip without a file")
                path = (Path(self.deck) / relative).resolve()
                if not path.is_file() or not path.is_relative_to(Path(self.deck).resolve()):
                    raise ValueError(f"animation clip is missing: {relative}")
                kind = slide.get("type", "video")
                if kind not in ("video", "image"):
                    raise ValueError(f"unsupported animation clip type: {kind}")
                clips.append({"path": str(path), "kind": kind,
                              "playbackRate": slide.get("playback_rate", 1.0)})
            if not clips:
                raise ValueError(f"{name} has no animation clips to play")
            emit({"event": "animation_preview", "phase": "ready", "scene": name, "clips": clips})
        except Exception as exc:                          # noqa: BLE001
            emit({"event": "animation_preview", "phase": "error", "error": str(exc)})
        finally:
            self._presenting = False

    def _build_animation_slides(self, selected: list[dict], event: str, height: int = 720) -> bool:
        """Build the selected scenes with manim where their code (or the resolution asked for) changed since the
        last build. The stamp file keeps each scene's key, with "@<height>p" added for builds above 720p."""
        emit = self.on_event or (lambda e: None)
        deck = Path(self.deck)
        slides_dir = deck / "slides"
        slides_dir.mkdir(exist_ok=True)
        stamp = slides_dir / ".manimble-built.json"
        try:
            built = json.loads(stamp.read_text())
        except Exception:
            built = {}
        def key_of(s):
            return self.scene_key(s) + ("" if height == 720 else f"@{height}p")
        def is_stale(s):
            if not (slides_dir / f"{s['name']}.json").exists():
                return True
            have = built.get(s["name"])
            if have is None:                       # built outside Manimble: trusted at 720p unless edited since opening
                return height != 720 or self.scene_key(s) != self.baseline_keys.get(s["name"])
            return have != key_of(s)

        stale = [s for s in selected if is_stale(s)]
        log = self.cache_dir / "present.log"
        for i, s in enumerate(stale):
            emit({"event": event, "phase": "building", "done": i, "total": len(stale), "scene": s["name"]})
            with open(log, "w") as lf:
                # what `manim-slides render` runs, without going through its CLI
                r = subprocess.run([self.python, "-m", "manim", "render", "--disable_caching", "-r", self.CLIP_SIZES[height],
                                    "--media_dir", "../media", s["file"], s["name"]],
                                   cwd=self.deck, stdout=lf, stderr=subprocess.STDOUT)
            if r.returncode != 0:
                emit({"event": event, "phase": "error", "error": f"Building {s['name']} failed:\n{log.read_text()[-700:]}"})
                return False
            built[s["name"]] = key_of(s)
            stamp.write_text(json.dumps(built))
        for s in selected:
            if (slides_dir / f"{s['name']}.json").exists():
                built.setdefault(s["name"], key_of(s))
        stamp.write_text(json.dumps(built))
        return True

    def _present_job(self, only_scene: str | None = None, height: int = 720):
        emit = self.on_event or (lambda e: None)
        try:
            selected = [self.scene(only_scene)] if only_scene else list(self.visible_scenes())
            if not self._build_animation_slides(selected, "present", height):
                return
            emit({"event": "present", "phase": "ready", "onlyScene": only_scene,
                  "slides": self._present_slides(selected), **self._present_extras()})
        except Exception as exc:                          # noqa: BLE001
            emit({"event": "present", "phase": "error", "error": str(exc)})
        finally:
            self._presenting = False

    def _present_slides(self, selected: list[dict]) -> list[dict]:
        """The built clips of the selected scenes, in show order, for the native player. `sceneIndex` is the
        scene's place in order.txt (what chapters and link regions refer to), `number` its place in this show."""
        deck = Path(self.deck).resolve()
        order = [s["name"] for s in self.scenes]
        out = []
        for number, s in enumerate(selected):
            data = json.loads((deck / "slides" / f"{s['name']}.json").read_text())
            scene_notes = self._notes_of(s["name"])
            for k, slide in enumerate(data.get("slides", [])):
                kind = slide.get("type", "video")
                if kind not in ("video", "image"):
                    raise ValueError(f"unsupported animation clip type: {kind}")
                def resolve(rel):
                    if not isinstance(rel, str):
                        return None
                    path = (deck / rel).resolve()        # Manim Slides writes paths relative to the deck folder
                    if not path.is_file() or not path.is_relative_to(deck):
                        raise ValueError(f"animation clip is missing: {rel}")
                    return str(path)
                out.append({
                    "scene": s["name"], "sceneIndex": order.index(s["name"]) if s["name"] in order else number,
                    "number": number, "index": k, "count": len(data["slides"]), "kind": kind,
                    "file": resolve(slide.get("src") if kind == "image" else slide.get("file")),
                    "revFile": resolve(slide.get("rev_file")) if kind == "video" else None,
                    "loop": bool(slide.get("loop")), "autoNext": bool(slide.get("auto_next")),
                    "rate": float(slide.get("playback_rate") or 1.0),
                    "revRate": float(slide.get("reversed_playback_rate") or 1.0),
                    "notes": slide.get("notes") or scene_notes,
                })
        return out

    def _present_extras(self) -> dict:
        """Chapter jumps and clickable link regions for the animated player.

        Read from the deck's present.json ({"sections": [scene indices], "links": {scene index: [[x0, x1, y0, y1,
        url], ...]}}, coordinates as fractions of the slide, y from the top; scene indices count order.txt). Without
        one, the SECTION_SCENE_INDICES and REFERENCE_LINKS constants of a custom present.py are used, evaluated on
        their own so the Qt presenter it imports is never loaded."""
        deck = Path(self.deck)
        sections, links = [], {}
        try:
            if (deck / "present.json").exists():
                d = json.loads((deck / "present.json").read_text())
                sections, links = d.get("sections", []), d.get("links", {})
            elif (deck / "present.py").exists():
                tree = ast.parse((deck / "present.py").read_text())
                ns: dict = {}
                for node in tree.body:
                    if (isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
                            and node.targets[0].id in ("SECTION_SCENE_INDICES", "REFERENCE_LINKS")):
                        code = compile(ast.Expression(node.value), "present.py", "eval")
                        ns[node.targets[0].id] = eval(code, {"__builtins__": {}, "range": range})   # noqa: S307
                sections = list(ns.get("SECTION_SCENE_INDICES", ()))
                links = ns.get("REFERENCE_LINKS", {})
        except Exception:                                 # noqa: BLE001
            sections, links = [], {}
        n = len(self.scenes)
        return {"sections": [int(i) for i in sections if 0 <= int(i) < n],
                "links": {str(k): [list(r) for r in v] for k, v in links.items()}}

# -------------------------------------------------------------------- HTTP
