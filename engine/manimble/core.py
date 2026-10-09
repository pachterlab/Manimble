"""manimble server: HTTP API + render scheduling + source patching."""

from __future__ import annotations

import ast
import difflib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

from .srcedit import EditError, Planner, Project, fmt, py_str, py_tex

HERE = Path(__file__).resolve().parent


# ------------------------------------------------------------------ worker

class WorkerProc:
    """A long-lived manim process speaking JSON lines."""

    def __init__(self, python: str, deck: str, worker_name: str):
        self.python, self.deck = python, deck
        # Manim caches generated Text/TeX SVGs by content under media_dir.
        # Independent workers rendering different slides concurrently can
        # otherwise delete each other's temporary SVGs while parsing them.
        self.media_dir = str(Path(deck).parent / "media" / "manimble" / worker_name)
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


# ------------------------------------------------------------------- state

class Manimble:
    def __init__(self, deck: str, python: str, cache: str | None = None):
        self.project = Project(deck)
        self.deck = self.project.dir
        self.python = python
        self.planner = Planner(self.project)
        self.cache_dir = Path(cache) if cache else Path(self.deck) / ".manimble"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        (self.cache_dir / ".gitignore").write_text("*\n")
        self.render_worker = WorkerProc(python, self.deck, "background")
        self.aux_worker = WorkerProc(python, self.deck, "auxiliary")
        self.on_event = None
        self.lock = threading.RLock()           # guards the tables below
        self.edit_lock = threading.RLock()      # serialises edits
        self.scene_locks: dict = {}             # one render per scene at a time
        self.edit_worker = WorkerProc(python, self.deck, "interactive")   # edits never wait behind background renders
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
        rows = [{"name": n, "file": rel, "line": l, "end": e, "module": rel[:-3]} for n, rel, l, e in found]
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
                item = {"name": s["name"], "file": s["file"], "line": s["line"], "status": st}
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
            }
            if o["kind"] in ("text", "tex"):
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
                else:
                    return {"ok": False, "error": f"unknown operation {op}"}
            except EditError as exc:
                return {"ok": False, "error": str(exc)}

            if not attempts:
                return {"ok": False, "error": "nothing to edit"}
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
                    if op in ("text", "font", "color", "style", "table", "delete"):
                        hint = ""
                        if "NoneType" in last_error or "get_part" in last_error:
                            hint = " The slide's code picks out parts of this text/formula by name, so the new content must keep those parts."
                        return {"ok": False, "error": "The slide no longer renders with this change, so it was undone: "
                                + last_error[-300:] + hint}
                    continue
                ok, why = self._verify(op, req, oid, stop, before_box, new["data"], ux, uy)
                if ok:
                    self._commit(label if op in ("text", "font", "color", "style", "table", "delete") else f"{label} ({how})", written)
                    msg = how
                    sib = None
                    if op in ("move", "resize", "endpoints"):
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
            if ctl and op in ("move", "resize", "endpoints"):
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
        if op not in ("move", "resize"):
            return True, ""
        vis = {str(v[0]): v for v in data["stops"][min(stop, len(data["stops"]) - 1)]["visible"]}
        after = vis.get(oid)
        if not after or not before_box:
            return False, "object is not visible after the change"
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
            try:
                if op == "new":
                    if cls is None:
                        return {"ok": False, "error": "select a slide first"}
                    base = ast.unparse(cls.bases[0]) if cls.bases else "Scene"
                    nn = fresh("NewSlide")
                    body = self._insert_code("text", {}).replace('"Text"', '"New slide"', 1)
                    text = (f"\n\nclass {nn}({base}):\n    def construct(self):\n"
                            f"        self.add({body})  # manimble\n")
                    at = src.line_starts[cls.end_lineno] if cls.end_lineno < len(src.line_starts) else len(src.data)
                    if at == len(src.data) and not src.data.endswith(b"\n"):
                        text = "\n" + text
                    edits.append(Edit(src.rel, at, at, text))
                    i = names.index(name)
                    edits.append(self._order_edit(names[:i + 1] + [nn] + names[i + 1:]))
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
                    edits.append(Edit(src.rel, b, b, "\n\n" + chunk if b < len(src.data) else "\n\n" + chunk))
                    i = names.index(name)
                    edits.append(self._order_edit(names[:i + 1] + [nn] + names[i + 1:]))
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
                    label = "delete slide"
                    select = names[i + 1] if i >= 0 and i + 1 < len(names) else (names[i - 1] if i > 0 else (names[0] if names else None))
                elif op == "skip":
                    if name not in names:
                        return {"ok": False, "error": "slide is already skipped"}
                    i = names.index(name)
                    edits.append(self._order_edit([n for n in names if n != name]))
                    label = "skip slide"
                    select = names[i + 1] if i + 1 < len(names) else (names[i - 1] if i > 0 else None)
                elif op == "unskip":
                    if name in names:
                        return {"ok": False, "error": "slide is already in the show"}
                    edits.append(self._order_edit(names + [name]))
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
                    label = "move slide"
                elif op in ("up", "down"):
                    i = names.index(name)
                    j = i - 1 if op == "up" else i + 1
                    if not 0 <= j < len(names):
                        return {"ok": True, "message": "already at the " + ("start" if op == "up" else "end"), "select": name}
                    names[i], names[j] = names[j], names[i]
                    edits.append(self._order_edit(names))
                    label = "move slide"
                else:
                    return {"ok": False, "error": f"unknown slide operation {op}"}
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

    def deck_pages(self, req: dict) -> dict:
        """Every build of every slide, in order, for the slideshow."""
        slides = []
        for s in self.scenes:
            sc = self.api_scene(s["name"])
            if sc.get("status") != "ready":
                slides.append({"scene": s["name"], "error": sc.get("error", "not rendered"), "pages": []})
            else:
                slides.append({"scene": s["name"], "pages": [st["png"] for st in sc["stops"]]})
        return {"slides": slides}

    # ------------------------------------------------------------ insert
    def _font_const(self) -> bool:
        return bool(self.project.top_level_assigns("FONT"))

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
        codes = {
            "text": f'Text("Text", font_size=36{font}).move_to({origin})',
            "formula": f'MathTex({py_tex(req.get("tex") or "x^2 + y^2 = z^2", True)}, font_size=48).move_to({origin})',
            "rectangle": f'Rectangle(width=3, height=1.8, color=WHITE, stroke_width=4).move_to({origin})',
            "rounded": f'RoundedRectangle(width=3, height=1.8, corner_radius=0.25, color=WHITE, stroke_width=4).move_to({origin})',
            "circle": f'Circle(radius=1, color=WHITE, stroke_width=4).move_to({origin})',
            "triangle": f'Triangle(color=WHITE, stroke_width=4).scale(1.2).move_to({origin})',
            "line": 'Line((-1.5, 0, 0), (1.5, 0, 0), color=WHITE, stroke_width=4)',
            "arrow": 'Arrow((-1.5, 0, 0), (1.5, 0, 0), buff=0, color=WHITE)',
        }
        if kind == "table":
            r, c = max(1, int(req.get("rows", 3))), max(1, int(req.get("cols", 3)))
            data = "[" + ", ".join("[" + ", ".join(str(i * c + j + 1) for j in range(c)) + "]" for i in range(r)) + "]"
            codes["table"] = f"MathTable({data}, include_outer_lines=True).scale(0.7).move_to({origin})"
        if kind == "image":
            if preview:
                codes["image"] = f'ImageMobject({py_str(req["path"])}).set(width=4).move_to({origin})'
            else:
                codes["image"] = (f'ImageMobject(str(__import__("pathlib").Path(__file__).resolve().parent / {py_str(req["file"])}))'
                                  f'.set(width=4).move_to({origin})')
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
                                                      stops[si].get("site") if si < nstops - 1 else None)
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

    def pages(self, req: dict) -> dict:
        """Frame images for exporting: every build or just the last build of each slide."""
        out = []
        for s in self.scenes:
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
        """Build whatever slides are out of date, then launch the deck's presenter.

        Runs in the background and reports through events: {"event": "present", "phase": ...}."""
        if getattr(self, "_presenting", False):
            return {"ok": False, "error": "already building the presentation"}
        req = req or {}
        if req.get("scene"):
            try:
                self.scene(req["scene"])
            except KeyError:
                return {"ok": False, "error": f"unknown slide: {req['scene']}"}
        self._presenting = True
        threading.Thread(target=self._present_job, args=(req.get("scene"),), daemon=True).start()
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
        threading.Thread(target=self._animation_preview_job, args=(name,), daemon=True).start()
        return {"ok": True}

    def _animation_preview_job(self, name: str):
        emit = self.on_event or (lambda e: None)
        try:
            selected = [self.scene(name)]
            if not self._build_animation_slides(selected, "animation_preview"):
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

    def _build_animation_slides(self, selected: list[dict], event: str) -> bool:
        emit = self.on_event or (lambda e: None)
        deck = Path(self.deck)
        slides_dir = deck / "slides"
        slides_dir.mkdir(exist_ok=True)
        stamp = slides_dir / ".manimble-built.json"
        try:
            built = json.loads(stamp.read_text())
        except Exception:
            built = {}
        cli = Path(self.python).parent / "manim-slides"
        if not cli.exists():
            emit({"event": event, "phase": "error", "error": f"manim-slides not found next to {self.python}"})
            return False
        def is_stale(s):
            if not (slides_dir / f"{s['name']}.json").exists():
                return True
            key = self.scene_key(s)
            have = built.get(s["name"])
            if have is None:
                return key != self.baseline_keys.get(s["name"])
            return have != key

        stale = [s for s in selected if is_stale(s)]
        log = self.cache_dir / "present.log"
        for i, s in enumerate(stale):
            emit({"event": event, "phase": "building", "done": i, "total": len(stale), "scene": s["name"]})
            with open(log, "w") as lf:
                r = subprocess.run([str(cli), "render", "--disable_caching", "-r", "1280,720", "--media_dir", "../media",
                                    s["file"], s["name"]], cwd=self.deck, stdout=lf, stderr=subprocess.STDOUT)
            if r.returncode != 0:
                emit({"event": event, "phase": "error", "error": f"Building {s['name']} failed:\n{log.read_text()[-700:]}"})
                return False
            built[s["name"]] = self.scene_key(s)
            stamp.write_text(json.dumps(built))
        for s in selected:
            if (slides_dir / f"{s['name']}.json").exists():
                built.setdefault(s["name"], self.scene_key(s))
        stamp.write_text(json.dumps(built))
        return True

    def _present_job(self, only_scene: str | None = None):
        emit = self.on_event or (lambda e: None)
        try:
            deck = Path(self.deck)
            slides_dir = deck / "slides"
            cli = Path(self.python).parent / "manim-slides"
            presenter = deck / "present.py"
            if only_scene is not None or not presenter.exists():
                qt = subprocess.run([self.python, "-c", "from qtpy.QtCore import Qt; from qtpy.QtMultimedia import QMediaPlayer"],
                                    cwd=self.deck, capture_output=True, text=True)
                if qt.returncode != 0:
                    emit({"event": "present", "phase": "error",
                          "error": "Animation playback needs a Qt binding. Re-run install_manimble.sh to install PySide6."})
                    return
            selected = [self.scene(only_scene)] if only_scene else list(self.scenes)
            if not self._build_animation_slides(selected, "present"):
                return
            if presenter.exists() and only_scene is None:
                cmd = [self.python, str(presenter)]
            else:
                cmd = [str(cli), "present", "--folder", str(slides_dir)] + [s["name"] for s in selected]
            plog = open(self.cache_dir / "presenter.log", "w")
            proc = subprocess.Popen(cmd, cwd=self.deck, stdout=plog, stderr=subprocess.STDOUT, start_new_session=True)
            time.sleep(2.5)
            if proc.poll() not in (None, 0):
                emit({"event": "present", "phase": "error",
                      "error": "The presenter exited:\n" + (self.cache_dir / "presenter.log").read_text()[-600:]})
            else:
                emit({"event": "present", "phase": "playing", "onlyScene": only_scene})
        except Exception as exc:                          # noqa: BLE001
            emit({"event": "present", "phase": "error", "error": str(exc)})
        finally:
            self._presenting = False


# -------------------------------------------------------------------- HTTP
