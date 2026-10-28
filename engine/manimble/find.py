"""Find and replace over the text and formulas of every slide in the show, and with `notes` their speaker notes.

Matches come from the slides' renders, so they are the strings the slide shows (a text box's soft line breaks read
as spaces) and each one is tied to the object that shows it. Replacing goes through the same planning as typing
into the object: one match is an ordinary `text` edit; Replace All rewrites every literal at once as one undo step.
"""
from __future__ import annotations

import ast
import re

from .srcedit import Edit, EditError, py_str, unwrap_soft


def pattern(req: dict) -> re.Pattern:
    """The compiled search: `query`, plus `case` (match case), `word` (whole words) and `regex` flags."""
    q = str(req.get("query") or "")
    if not q:
        raise ValueError("nothing to find")
    body = q if req.get("regex") else re.escape(q)
    if req.get("word"):
        body = rf"(?<!\w)(?:{body})(?!\w)"
    try:
        return re.compile(body, 0 if req.get("case") else re.IGNORECASE)
    except re.error as exc:
        raise ValueError(f"regular expression: {exc}") from None


def _matches(pat: re.Pattern, s: str) -> list:
    return [m for m in pat.finditer(s) if m.end() > m.start()]


def _substitute(pat: re.Pattern, s: str, repl: str, regex: bool, only: int | None = None) -> str:
    """s with its matches (or only match number `only`) replaced; a regular expression's replacement may name
    groups (\\1, \\g<name>, or $1)."""
    if regex:
        repl = re.sub(r"\$(\d+)", r"\\g<\1>", repl)
    out, last = [], 0
    for i, m in enumerate(_matches(pat, s)):
        if only is not None and i != only:
            continue
        out.append(s[last:m.start()])
        out.append(m.expand(repl) if regex else repl)
        last = m.end()
    out.append(s[last:])
    return "".join(out)


def _glyph_span(s: str, h: re.Match) -> list:
    """The match as a range of the text's non-space characters: the indices into a stop's `glyphs` boxes of the
    object (worker.glyph_boxes), which the canvas highlights."""
    def ink(i):
        return sum(not c.isspace() for c in s[:i])
    return [ink(h.start()), ink(h.end())]


def _record(m, name: str, fresh: bool) -> dict | None:
    if fresh:
        rec = m.fresh_record(name)
    else:                                     # an out-of-date render would show the text as it was
        rec = m.results.get(name) if m.status(name) in ("ready", "error") else m.render_now(name)
    if not rec or "data" not in rec:
        return None
    return rec


def _texts(m, data: dict):
    """(oid, obj, first stop showing it, its box there) of every text and formula, in reading order."""
    seen = {}
    for k, st in enumerate(data["stops"]):
        for v in st["visible"]:
            seen.setdefault(str(int(v[0])), (k, v))
    rows = []
    for oid, o in data["objects"].items():
        if o["kind"] in ("text", "tex") and oid in seen:
            k, v = seen[oid]
            rows.append((k, v[2], v[1], oid, o, v))
    rows.sort(key=lambda r: (r[0], round(r[1] / 8), r[2]))
    return [(oid, o, k, v) for k, _, _, oid, o, v in rows]


def _notes(m, name: str, stops: list) -> list:
    """(kind, build, src, string literal) of the slide's notes ("notes") and of each build's own ("buildNotes")."""
    try:
        src, fn = m._construct(m.scene(name))
    except Exception:                               # noqa: BLE001
        return []
    out = []
    hit = m._notes_stmt(src, fn)
    if hit:
        out.append(("notes", 0, src, hit[1].value))
    st = m._first_build_notes_stmt(src, fn)
    if st is not None:
        out.append(("buildNotes", 0, src, st.value))
    for k in range(1, len(stops)):
        try:
            _, kw = m._build_notes_call(src, fn, stops, k)
        except Exception:                           # noqa: BLE001
            continue
        if kw is not None and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
            out.append(("buildNotes", k, src, kw.value))
    return out


def find(m, req: dict) -> dict:
    try:
        pat = pattern(req)
    except ValueError as exc:
        return {"ok": False, "error": str(exc), "matches": []}
    m.refresh_scenes()
    out = []
    for s in m.scenes:
        rec = _record(m, s["name"], fresh=False)
        if rec is None:
            continue
        data = m._rebased(rec["data"])
        for oid, o, stop, _ in _texts(m, data):
            shown = unwrap_soft(o["value"])
            hits = _matches(pat, shown)
            if not hits:
                continue
            editable = m.planner.text_target(o).kind == "node"
            for i, h in enumerate(hits):
                out.append({"scene": s["name"], "oid": int(oid), "stop": stop, "index": i, "kind": o["kind"],
                            "value": shown, "match": h.group(0), "editable": editable,
                            "start": h.start(), "end": h.end(), "glyphs": _glyph_span(shown, h)})
        if req.get("notes"):
            for kind, k, _, node in _notes(m, s["name"], data["stops"]):
                for i, h in enumerate(_matches(pat, node.value)):
                    out.append({"scene": s["name"], "oid": -1, "stop": k, "index": i, "kind": kind,
                                "value": node.value, "match": h.group(0), "editable": True,
                                "start": h.start(), "end": h.end()})
    return {"ok": True, "matches": out}


def replace(m, req: dict) -> dict:
    """One match (`scene`, `oid`, `index`: which match in that object's text; for notes `kind` and `stop` instead
    of `oid`) or, with `all`, every match."""
    try:
        pat = pattern(req)
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}
    repl = str(req.get("replacement") or "")
    regex = bool(req.get("regex"))
    if not req.get("all") and req.get("kind") in ("notes", "buildNotes"):
        name, k = req["scene"], int(req.get("stop", 0))
        rec = _record(m, name, fresh=True)
        hit = next((n for kind, b, _, n in _notes(m, name, rec["data"]["stops"] if rec else [])
                    if kind == req["kind"] and b == k), None)
        if hit is None:
            return {"ok": False, "error": "those notes are gone"}
        try:
            new = _substitute(pat, hit.value, repl, regex, only=int(req.get("index", 0)))
        except (re.error, IndexError) as exc:
            return {"ok": False, "error": f"replacement: {exc}"}
        if new == hit.value:
            return {"ok": False, "error": "the notes no longer match"}
        args = {"op": "set", "scene": name, "text": new}
        if req["kind"] == "buildNotes":
            args["stop"] = k
        return m.notes(args)
    if not req.get("all"):
        name, oid = req["scene"], str(req["oid"])
        rec = _record(m, name, fresh=True)
        obj = rec and rec["data"]["objects"].get(oid)
        if not obj:
            return {"ok": False, "error": "that text is no longer on the slide"}
        shown = unwrap_soft(obj["value"])
        try:
            new = _substitute(pat, shown, repl, regex, only=int(req.get("index", 0)))
        except (re.error, IndexError) as exc:
            return {"ok": False, "error": f"replacement: {exc}"}
        if new == shown:
            return {"ok": False, "error": "the text no longer matches"}
        return m.edit({"scene": name, "op": "text", "oid": oid, "value": new, "stop": int(req.get("stop", 0))})
    return _replace_all(m, pat, repl, regex, bool(req.get("notes")))


def _replace_all(m, pat, repl: str, regex: bool, notes: bool = False) -> dict:
    with m.edit_lock:
        m._settle()
        m.refresh_scenes()
        edits, taken, done = [], {}, set()
        count, skipped, scenes = 0, 0, []
        for s in m.scenes:
            rec = _record(m, s["name"], fresh=True)
            if rec is None:
                continue
            data = rec["data"]
            fw, _ = data["frame"]
            pw, _ = data["size"]
            touched = False
            for oid, obj, _, box in _texts(m, data):
                shown = unwrap_soft(obj["value"])
                n = len(_matches(pat, shown))
                if not n:
                    continue
                t = m.planner.text_target(obj)
                if t.kind != "node":
                    skipped += n
                    continue
                key = (t.src.rel,) + t.src.span(t.node)
                if key in done:                       # one literal shown by several objects (a shared constant)
                    touched = True
                    continue
                try:
                    new = _substitute(pat, shown, repl, regex)
                    width = m.planner.box_width(obj) if obj["kind"] == "text" else None
                    if width:                         # a text box: the new text flows to its width
                        value = m._wrapped(obj, new, width, (box[3] - box[1]) * fw / pw)
                        stored = (m.planner.box_info(obj) or {}).get("w") or width
                        plan = m.planner.plan_wrap(obj, value, stored)
                    else:
                        plan = m.planner.plan_text(obj, new)
                except (EditError, re.error, IndexError):
                    skipped += n
                    continue
                if any(e.start < b and a < e.end for e in plan for a, b in taken.get(e.rel, ())):
                    skipped += n                      # overlaps code already rewritten (a t2c range, ...)
                    continue
                for e in plan:
                    taken.setdefault(e.rel, []).append((e.start, e.end))
                edits += plan
                done.add(key)
                count += n
                touched = True
            for _, _, src, node in (_notes(m, s["name"], data["stops"]) if notes else []):
                n = len(_matches(pat, node.value))
                a, b = src.span(node)
                if not n or any(x < b and a < y for x, y in taken.get(src.rel, ())):
                    continue
                try:
                    lit = py_str(_substitute(pat, node.value, repl, regex))
                except (re.error, IndexError):
                    skipped += n
                    continue
                edits.append(Edit(src.rel, a, b, lit))
                taken.setdefault(src.rel, []).append((a, b))
                count += n
                touched = True
            if touched:
                scenes.append(s["name"])
        if not edits:
            return {"ok": count > 0, "count": count, "skipped": skipped, "scenes": scenes,
                    "error": None if count else ("no editable matches" if skipped else "no matches")}
        try:
            written = m.project.apply(edits)
        except SyntaxError as exc:
            return {"ok": False, "error": f"the replacement would break the code: {exc.msg}"}
        m._sig_at = 0
        m._commit(f"replace {count} match{'es' if count != 1 else ''}", written)
        m.refresh_scenes()
        return {"ok": True, "count": count, "skipped": skipped, "scenes": scenes,
                "message": f"replaced {count} match{'es' if count != 1 else ''}"
                           + (f" on {len(scenes)} slide{'s' if len(scenes) != 1 else ''}" if scenes else "")
                           + (f"; {skipped} made by code left alone" if skipped else ""),
                "changed": m.last_changed}
