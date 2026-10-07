"""Source-code side of manimble: map on-screen edits back to Python edits.

The worker reports, for every editable object, the stack of call sites that
created it and the layout calls (move_to, shift, next_to, set, ...) that shaped
it.  This module walks the AST of the user's files to turn "move this 0.4 to the
right" or "change this string" into minimal textual patches.
"""

from __future__ import annotations

import ast
import hashlib
import json
import os
import re
from dataclasses import dataclass, field


# ------------------------------------------------------------------ helpers

def fmt(x: float, nd: int = 3) -> str:
    s = f"{x:.{nd}f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def py_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def py_tex(s: str, raw: bool) -> str:
    """Literal for a LaTeX string; raw (r"...") when that is safe."""
    if raw and '"' not in s and "\n" not in s and not s.endswith("\\") and "\r" not in s:
        return 'r"' + s + '"'
    return py_str(s)


def vec_expr(x: float, y: float) -> str:
    parts = []
    if abs(x) > 5e-4:
        parts.append(f"RIGHT * {fmt(x)}" if x > 0 else f"LEFT * {fmt(-x)}")
    if abs(y) > 5e-4:
        parts.append(f"UP * {fmt(y)}" if y > 0 else f"DOWN * {fmt(-y)}")
    return " + ".join(parts) if parts else "ORIGIN"


@dataclass
class Edit:
    rel: str
    start: int
    end: int
    text: str


class Src:
    def __init__(self, rel: str, data: bytes):
        self.rel = rel
        self.data = data
        self.tree = ast.parse(data)
        self.parent: dict = {}
        for n in ast.walk(self.tree):
            for c in ast.iter_child_nodes(n):
                self.parent[c] = n
        self.line_starts = [0]
        for i, b in enumerate(data):
            if b == 10:
                self.line_starts.append(i + 1)
        self._calls = None

    def off(self, line: int, col: int) -> int:
        return self.line_starts[line - 1] + col

    def span(self, node) -> tuple[int, int]:
        return self.off(node.lineno, node.col_offset), self.off(node.end_lineno, node.end_col_offset)

    def text(self, node) -> str:
        a, b = self.span(node)
        return self.data[a:b].decode("utf-8")

    def find_call(self, pos):
        # Python narrows the CALL position of a chained method call to start at the
        # method name, so identify the node by where it ends (unique among calls).
        l, c, el, ec = pos
        if self._calls is None:
            self._calls = {}
            for n in ast.walk(self.tree):
                if isinstance(n, ast.Call):
                    self._calls[(n.end_lineno, n.end_col_offset)] = n
        return self._calls.get((el, ec))

    def enclosing(self, node, types):
        n = self.parent.get(node)
        while n is not None and not isinstance(n, types):
            n = self.parent.get(n)
        return n

    def chain_top(self, call):
        node = call
        while True:
            p = self.parent.get(node)
            if isinstance(p, ast.Attribute) and p.value is node:
                pp = self.parent.get(p)
                if isinstance(pp, ast.Call) and pp.func is p:
                    node = pp
                    continue
            return node

    def in_loop(self, node) -> bool:
        n = self.parent.get(node)
        while n is not None and not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if isinstance(n, (ast.For, ast.While, ast.ListComp, ast.GeneratorExp, ast.SetComp, ast.DictComp)):
                return True
            n = self.parent.get(n)
        return False


class Project:
    def __init__(self, deck_dir: str):
        self.dir = os.path.realpath(deck_dir)
        self._cache: dict = {}

    def py_files(self):
        return sorted(f for f in os.listdir(self.dir) if f.endswith(".py"))

    def read(self, rel: str) -> bytes:
        with open(os.path.join(self.dir, rel), "rb") as fh:
            return fh.read()

    def write(self, rel: str, data: bytes | None):
        path = os.path.join(self.dir, rel)
        if data is None:                           # undo of a file creation
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            return
        tmp = path + ".manimble.tmp"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)

    def src(self, rel: str) -> Src:
        data = self.read(rel)
        key = hashlib.sha1(data).hexdigest()
        hit = self._cache.get(rel)
        if hit and hit[0] == key:
            return hit[1]
        s = Src(rel, data)
        self._cache[rel] = (key, s)
        return s

    def file_hash(self, rel: str) -> str:
        return hashlib.sha1(self.read(rel)).hexdigest()

    # ---------------------------------------------------------- scenes
    def scenes(self):
        """[(name, rel, line)] for every class with a construct() method."""
        found = []
        for rel in self.py_files():
            try:
                tree = self.src(rel).tree
            except SyntaxError:
                continue
            for node in tree.body:
                if isinstance(node, ast.ClassDef) and any(
                    isinstance(b, ast.FunctionDef) and b.name == "construct" for b in node.body
                ):
                    found.append((node.name, rel, node.lineno, node.end_lineno))
        order_file = os.path.join(self.dir, "order.txt")
        if os.path.exists(order_file):
            with open(order_file, encoding="utf-8") as fh:
                order = fh.read().split()
            idx = {n: i for i, n in enumerate(order)}
            found.sort(key=lambda t: (idx.get(t[0], 10**6), t[1], t[2]))
        return found

    # ------------------------------------------------------- applying
    def apply(self, edits: list[Edit]) -> dict:
        """Apply edits; return {rel: (before, after)}."""
        by_file: dict = {}
        for e in edits:
            by_file.setdefault(e.rel, []).append(e)
        out = {}
        for rel, es in by_file.items():
            try:
                before = self.read(rel)
            except FileNotFoundError:
                before = None                      # a file this edit creates
            data = bytearray(before or b"")
            for e in sorted(es, key=lambda e: (e.start, e.end), reverse=True):
                data[e.start:e.end] = e.text.encode("utf-8")
            after = bytes(data)
            if rel.endswith(".py"):
                ast.parse(after)  # refuse to write something that does not parse
            out[rel] = (before, after)
        for rel, (_, after) in out.items():
            self.write(rel, after)
        return out

    # ---------------------------------------------------- name lookups
    def top_level_assigns(self, name: str):
        hits = []
        for rel in self.py_files():
            try:
                s = self.src(rel)
            except SyntaxError:
                continue
            for node in s.tree.body:
                if isinstance(node, ast.Assign) and len(node.targets) == 1:
                    t = node.targets[0]
                    if isinstance(t, ast.Name) and t.id == name:
                        hits.append((s, node.value))
        return hits

    def count_uses(self, name: str) -> int:
        n = 0
        for rel in self.py_files():
            try:
                s = self.src(rel)
            except SyntaxError:
                continue
            for node in ast.walk(s.tree):
                if isinstance(node, ast.Name) and node.id == name and isinstance(node.ctx, ast.Load):
                    n += 1
        return n

    def find_literals(self, value, scope_rel=None):
        """String constants equal to value (docstrings excluded)."""
        hits = []
        for rel in self.py_files():
            try:
                s = self.src(rel)
            except SyntaxError:
                continue
            for node in ast.walk(s.tree):
                if isinstance(node, ast.Constant) and node.value == value and isinstance(node.value, str):
                    p = s.parent.get(node)
                    if isinstance(p, ast.Expr):
                        continue
                    hits.append((s, node))
        return hits


# ------------------------------------------------------- argument tracing

@dataclass
class Target:
    kind: str                 # "node" | "missing" | "computed"
    src: Src | None = None
    node: object = None       # the AST node that supplies the value
    call: object = None       # for "missing": call that should receive a kwarg
    param: str = ""
    frame_index: int = 0
    via: dict | None = None   # shared constant info {name, rel, uses, local_node}
    note: str = ""


def _params(fdef):
    a = fdef.args
    return [x.arg for x in (a.posonlyargs + a.args)], [x.arg for x in a.kwonlyargs]


def _arg_of(call: ast.Call, name, pos):
    for kw in call.keywords:
        if kw.arg is not None and kw.arg == name:
            return kw.value
    if pos is not None:
        npos = 0
        for i, a in enumerate(call.args):
            if isinstance(a, ast.Starred):
                return None
            if i == pos:
                return a
    return None


def locate(project: Project, frames: list, fi: int, name, pos, resolve_globals=True) -> Target:
    """Find the source node supplying an argument of the call in frames[fi].

    Follows the value outward through wrapper functions (e.g. label(text, size)
    forwards its parameters to Text), then resolves module-level constants.
    """
    try:
        fr = frames[fi]
        src = project.src(fr["file"])
        call = src.find_call(fr["pos"])
    except Exception:
        return Target("computed", note="call site not found")
    if call is None:
        return Target("computed", note="call site not found")
    node = _arg_of(call, name, pos)
    while True:
        if node is None and name and fi + 1 < len(frames):
            # a helper forwarding **kwargs to the call: the value belongs in the caller
            fdef = src.enclosing(call, (ast.FunctionDef, ast.AsyncFunctionDef))
            kwname = fdef.args.kwarg.arg if fdef is not None and fdef.args.kwarg else None
            if kwname and any(k.arg is None and isinstance(k.value, ast.Name) and k.value.id == kwname for k in call.keywords):
                outer = frames[fi + 1]
                try:
                    osrc = project.src(outer["file"])
                    ocall = osrc.find_call(outer["pos"])
                except Exception:
                    ocall = None
                fname = None if ocall is None else (ocall.func.id if isinstance(ocall.func, ast.Name) else getattr(ocall.func, "attr", None))
                if ocall is not None and fname == fdef.name:
                    fi += 1
                    src, call = osrc, ocall
                    node = _arg_of(ocall, name, None)
                    continue
        if node is None:
            # argument omitted here: maybe it was a defaulted parameter of the caller
            return Target("missing", src=src, call=call, param=name or "", frame_index=fi)
        if isinstance(node, ast.Name):
            fdef = src.enclosing(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            if fdef is not None:
                pos_params, kw_params = _params(fdef)
                if node.id in pos_params or node.id in kw_params:
                    if fi + 1 >= len(frames):
                        return Target("computed", note="value comes from a parameter")
                    outer = frames[fi + 1]
                    try:
                        osrc = project.src(outer["file"])
                        ocall = osrc.find_call(outer["pos"])
                    except Exception:
                        ocall = None
                    if ocall is None:
                        return Target("computed", note="caller not found")
                    fname = ocall.func.id if isinstance(ocall.func, ast.Name) else getattr(ocall.func, "attr", None)
                    if fname != fdef.name:
                        return Target("computed", note="indirect call")
                    idx = pos_params.index(node.id) if node.id in pos_params else None
                    if idx is not None and isinstance(ocall.func, ast.Attribute) and pos_params and pos_params[0] in ("self", "cls"):
                        idx -= 1
                    nxt = _arg_of(ocall, node.id, idx)
                    fi += 1
                    src, call = osrc, ocall
                    name = node.id
                    node = nxt
                    pos = idx
                    continue
        break
    # node is a real expression in frames[fi]
    via = None
    if isinstance(node, ast.Name):
        resolved = _resolve_name(project, src, node)
        if resolved is not None:
            rsrc, rnode = resolved
            via = {"name": node.id, "rel": rsrc.rel, "uses": project.count_uses(node.id),
                   "local": (src, node)}
            if resolve_globals:
                return Target("node", src=rsrc, node=rnode, frame_index=fi, via=via)
    return Target("node", src=src, node=node, frame_index=fi, via=via)


def _resolve_name(project: Project, src: Src, name_node: ast.Name):
    """Constant assigned to a Name: local assignment, then module level anywhere."""
    fdef = src.enclosing(name_node, (ast.FunctionDef, ast.AsyncFunctionDef))
    if fdef is not None:
        local = []
        for n in ast.walk(fdef):
            if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) \
                    and n.targets[0].id == name_node.id:
                local.append(n.value)
        if len(local) == 1 and isinstance(local[0], ast.Constant):
            return src, local[0]
        if local:
            return None
    hits = project.top_level_assigns(name_node.id)
    if len(hits) == 1 and isinstance(hits[0][1], ast.Constant):
        return hits[0]
    return None


# ------------------------------------------------------------- the planner

class Planner:
    def __init__(self, project: Project):
        self.p = project

    # ------------------------------------------------------------ text
    def text_target(self, obj: dict, siblings: int = 1) -> Target:
        """Where the string content of a text/formula object lives."""
        t = locate(self.p, obj["frames"], 0, "text" if obj["kind"] == "text" else None, 0)
        value = obj["value"]
        if obj["kind"] == "tex":
            call_src = self.p.src(obj["frames"][0]["file"])
            call = call_src.find_call(obj["frames"][0]["pos"])
            if call is not None and sum(1 for a in call.args if not isinstance(a, ast.Starred)) > 1:
                return Target("computed", note="formula built from several strings")
        if t.kind == "node" and isinstance(t.node, ast.Constant) and isinstance(t.node.value, str):
            if t.node.value == value:
                return t
        # value-based fallback: find the one literal holding this text
        hits = self.p.find_literals(value)
        if len(hits) == 1:
            s, n = hits[0]
            return Target("node", src=s, node=n, frame_index=0, via=None, note="matched by value")
        if len(hits) > 1:
            pick = self._disambiguate(obj, hits)
            if pick is not None:
                return pick
            return Target("computed", note=f"{len(hits)} identical literals; ambiguous")
        return Target("computed", note="generated by code (not a plain string)")

    def _disambiguate(self, obj: dict, hits):
        """Several identical literals: keep those the creating code can actually reach."""
        fr = obj["frames"][-1]
        src = self.p.src(fr["file"])
        call = src.find_call(fr["pos"])
        if call is None:
            return None
        fdef = src.enclosing(call, (ast.FunctionDef, ast.AsyncFunctionDef))
        if fdef is None:
            return None
        # (a) literals written inside the creating function itself
        local = [h for h in hits if h[0] is src and h[1] in set(ast.walk(fdef))]
        if len(local) == 1:
            s, n = local[0]
            return Target("node", src=s, node=n, frame_index=0, note="matched by value")
        # (b) literals inside module constants that the creating function refers to
        names = {n.id for n in ast.walk(fdef) if isinstance(n, ast.Name)}
        via_const = []
        for h in hits:
            s, n = h
            top = n
            while s.parent.get(top) is not None and not isinstance(s.parent.get(top), ast.Module):
                top = s.parent[top]
            if isinstance(top, ast.Assign) and len(top.targets) == 1 and isinstance(top.targets[0], ast.Name) \
                    and top.targets[0].id in names:
                via_const.append((h, top.targets[0].id))
        if len(via_const) == 1:
            (s, n), cname = via_const[0]
            via = {"name": cname, "rel": s.rel, "uses": self.p.count_uses(cname), "local": None}
            return Target("node", src=s, node=n, frame_index=0, via=via, note="matched by value")
        return None

    def plan_text(self, obj: dict, new: str, shared: bool = True) -> list[Edit]:
        t = self.text_target(obj)
        if t.kind != "node":
            raise EditError(t.note or "this text is generated by code and cannot be edited directly")
        node, src = t.node, t.src
        if t.via and not shared and t.via.get("local"):
            src, node = t.via["local"]
        old_src = src.text(node)
        raw = bool(re.match(r"^[rR]", old_src.lstrip("(").lstrip()))
        lit = py_tex(new, raw or obj["kind"] == "tex") if obj["kind"] == "tex" else py_str(new)
        a, b = src.span(node)
        return [Edit(src.rel, a, b, lit)]

    # ------------------------------------------------------ simple args
    def plan_arg(self, obj: dict, name: str, literal: str, outermost: bool = False) -> list[Edit]:
        """Set a keyword-style argument (font_size, color, weight ...) of the constructor."""
        t = locate(self.p, obj["frames"], 0, name_map(obj, name), None, resolve_globals=False)
        last = len(obj["frames"]) - 1
        if outermost and t.kind in ("node", "missing") and t.frame_index != last:
            raise EditError(f"{name} is fixed inside a helper function ({obj['frames'][t.frame_index]['func']}); "
                            "it cannot be changed for a single object")
        if t.kind == "node":
            a, b = t.src.span(t.node)
            return [Edit(t.src.rel, a, b, literal)]
        if t.kind == "missing":
            return [insert_kwarg(t.src, t.call, t.param or name, literal)]
        raise EditError("cannot trace this setting back to the source")

    def plan_font(self, obj: dict, ctor_value: float) -> list[Edit]:
        """Set the constructor font size (what the source says, not the on-screen size)."""
        v = max(4.0, ctor_value)
        lit = str(int(round(v))) if abs(v - round(v)) < 0.06 else fmt(v, 1)
        return self.plan_arg(obj, "font_size", lit)

    def plan_font_family(self, obj: dict, family: str, shared: bool) -> list[Edit]:
        """Font family: usually a deck-wide constant (FONT), so edit that when allowed."""
        t = locate(self.p, obj["frames"], 0, "font", None, resolve_globals=True)
        if t.kind == "node":
            if t.via and not shared:
                raise EditError(f"the font is the shared constant {t.via['name']}; tick 'change everywhere' to change it")
            if not t.via and t.frame_index != len(obj["frames"]) - 1:
                raise EditError("the font is fixed inside a helper function and cannot be changed for one object")
            if isinstance(t.node, ast.Constant) and isinstance(t.node.value, str):
                a, b = t.src.span(t.node)
                return [Edit(t.src.rel, a, b, py_str(family))]
            a, b = t.src.span(t.node)
            return [Edit(t.src.rel, a, b, py_str(family))]
        if t.kind == "missing":
            return [insert_kwarg(t.src, t.call, "font", py_str(family))]
        raise EditError("cannot trace the font back to the source")

    def plan_endpoints(self, obj: dict, a, b) -> list[tuple[str, list[Edit]]]:
        """New start/end (manim units) for a Line/Arrow via put_start_and_end_on."""
        def tup(p):
            return f"({fmt(p[0])}, {fmt(p[1])}, 0)"
        attempts: list[tuple[str, list[Edit]]] = []
        own = [e for e in obj["events"] if e["own"] and e["method"] in
               ("shift", "move_to", "next_to", "to_edge", "to_corner", "align_to", "scale", "set",
                "put_start_and_end_on", "set_width", "set_height", "rotate")]
        last = own[-1] if own else None
        if last and last["method"] == "put_start_and_end_on" and len(last["args"]) >= 2:
            edits = []
            for i, p in enumerate((a, b)):
                t = locate(self.p, last["frames"], 0, "start" if i == 0 else "end", i, resolve_globals=False)
                if t.kind != "node" or t.frame_index != len(last["frames"]) - 1 or t.via is not None:
                    edits = []
                    break
                lo, hi = t.src.span(t.node)
                edits.append(Edit(t.src.rel, lo, hi, tup(p)))
            if edits:
                attempts.append(("adjusted the put_start_and_end_on() call", edits))
        text = f".put_start_and_end_on({tup(a)}, {tup(b)})"
        if last:
            attempts.append(("appended .put_start_and_end_on() after the positioning", [self._append_chain(last["frames"], text)]))
        attempts.append(("appended .put_start_and_end_on() where the line is created", [self._append_chain(obj["frames"], text)]))
        return attempts

    # ----------------------------------------------------------- moving
    def plan_move(self, obj: dict, dx: float, dy: float) -> list[tuple[str, list[Edit]]]:
        attempts: list[tuple[str, list[Edit]]] = []
        events = [e for e in obj["events"] if e["method"] in
                  ("shift", "move_to", "next_to", "to_edge", "to_corner", "align_to", "arrange",
                   "arrange_in_grid", "set_x", "set_y", "align_on_border")]
        last = events[-1] if events else None
        if last and last["own"] and last["method"] in ("move_to", "shift"):
            try:
                ed = self._rewrite_vector(last, dx, dy)
                if ed:
                    attempts.append((f"adjusted the {last['method']}() call", ed))
            except EditError:
                pass
        if last and not last["own"]:
            try:
                ed = self._shift_statement(obj, last, dx, dy)
                if ed:
                    attempts.append(("added a shift() after the layout call", ed))
            except EditError:
                pass
        if last and last["own"]:
            attempts.append(("appended .shift() to the positioning chain", [self._append_chain(last["frames"], f".shift({vec_expr(dx, dy)})")]))
        attempts.append(("appended .shift() where the object is created",
                         [self._append_chain(obj["frames"], f".shift({vec_expr(dx, dy)})")]))
        return attempts

    def _rewrite_vector(self, ev: dict, dx: float, dy: float):
        if len(ev["args"]) < 1 or not isinstance(ev["args"][0], list) or len(ev["args"][0]) != 3:
            return None
        if ev["method"] == "shift" and len(ev["args"]) != 1:
            return None
        if ev["method"] == "move_to" and len(ev["args"]) > 1:
            pass
        t = locate(self.p, ev["frames"], 0, "point_or_mobject" if ev["method"] == "move_to" else None, 0,
                   resolve_globals=False)
        if t.kind == "missing" or t.kind == "computed":
            if t.kind == "missing" and t.frame_index == len(ev["frames"]) - 1 and t.param:
                x, y, z = ev["args"][0]
                return [insert_kwarg(t.src, t.call, t.param, f"({fmt(x + dx)}, {fmt(y + dy)}, {fmt(z)})")]
            return None
        if t.frame_index != len(ev["frames"]) - 1:
            return None
        if t.via is not None:
            return None  # a named constant (e.g. center=CENTER); don't rewrite shared constants
        x, y, z = ev["args"][0]
        nx, ny = x + dx, y + dy
        if isinstance(t.node, (ast.Tuple, ast.List)):
            lit = f"({fmt(nx)}, {fmt(ny)}, {fmt(z)})"
        else:
            if abs(z) > 1e-9:
                return None
            lit = vec_expr(nx, ny)
        a, b = t.src.span(t.node)
        return [Edit(t.src.rel, a, b, lit)]

    def _append_chain(self, frames: list, text: str) -> Edit:
        fr = frames[-1]
        src = self.p.src(fr["file"])
        call = src.find_call(fr["pos"])
        if call is None:
            raise EditError("call site not found")
        top = src.chain_top(call)
        _, end = src.span(top)
        return Edit(src.rel, end, end, text)

    def _shift_statement(self, obj: dict, ev: dict, dx: float, dy: float):
        """Insert `var.shift(...)` after the statement holding a group layout call."""
        cf = obj["frames"][-1]
        csrc = self.p.src(cf["file"])
        ccall = csrc.find_call(cf["pos"])
        if ccall is None:
            return None
        top = csrc.chain_top(ccall)
        stmt = csrc.parent.get(top)
        if not (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name)
                and stmt.value is top):
            return None
        var = stmt.targets[0].id
        if len(obj["frames"]) != 1 and not (len(obj["frames"]) == 2 and obj["frames"][0]["func"] == "Tx"):
            pass
        ef = ev["frames"][-1]
        if ef["file"] != cf["file"]:
            return None
        ecall = csrc.find_call(ef["pos"])
        if ecall is None:
            return None
        estmt = ecall
        while not isinstance(csrc.parent.get(estmt), (ast.FunctionDef, ast.For, ast.While, ast.If, ast.With)):
            estmt = csrc.parent.get(estmt)
            if estmt is None:
                return None
        if csrc.enclosing(estmt, (ast.FunctionDef,)) is not csrc.enclosing(stmt, (ast.FunctionDef,)):
            return None
        if not isinstance(estmt, (ast.Expr, ast.Assign, ast.AugAssign)):
            return None
        if estmt.end_lineno + 0 < stmt.end_lineno:
            return None
        indent = " " * estmt.col_offset
        line_end = csrc.off(estmt.end_lineno, estmt.end_col_offset)
        return [Edit(csrc.rel, line_end, line_end, f"\n{indent}{var}.shift({vec_expr(dx, dy)})")]

    # --------------------------------------------------------- resizing
    def plan_resize(self, obj: dict, ratio: float) -> list[tuple[str, list[Edit]]]:
        attempts = []
        size_events = [e for e in obj["events"] if e["own"] and e["method"] in
                       ("set", "set_width", "set_height", "scale_to_fit_width", "scale_to_fit_height", "scale")]
        if size_events:
            try:
                ed = self._rewrite_size(size_events[-1], ratio)
                if ed:
                    attempts.append((f"scaled the {size_events[-1]['method']}() argument", ed))
            except EditError:
                pass
        if obj["kind"] in ("text", "tex") and obj.get("font0"):
            try:
                ed = self.plan_font(obj, obj["font0"] * ratio)
                attempts.append(("changed the font size", ed))
            except EditError:
                pass
        attempts.append(("appended .scale() where the object is created",
                         [self._append_chain(obj["frames"], f".scale({fmt(ratio, 4)})")]))
        return attempts

    def _rewrite_size(self, ev: dict, ratio: float):
        m = ev["method"]
        edits = []
        if m == "scale":
            if not ev["args"] or not isinstance(ev["args"][0], (int, float)):
                return None
            t = locate(self.p, ev["frames"], 0, "scale_factor", 0, resolve_globals=False)
            val = ev["args"][0] * ratio
        elif m == "set":
            kws = [k for k in ("width", "height") if isinstance(ev["kwargs"].get(k), (int, float))]
            if not kws:
                return None
            for k in kws:
                t = locate(self.p, ev["frames"], 0, k, None, resolve_globals=False)
                e = self._size_edit(t, ev, ev["kwargs"][k] * ratio)
                if e is None:
                    return None
                edits.append(e)
            return edits
        else:
            if not ev["args"] or not isinstance(ev["args"][0], (int, float)):
                return None
            t = locate(self.p, ev["frames"], 0, None, 0, resolve_globals=False)
            val = ev["args"][0] * ratio
        e = self._size_edit(t, ev, val)
        return [e] if e else None

    def _size_edit(self, t: Target, ev: dict, val: float):
        if t.kind == "node":
            if t.frame_index != len(ev["frames"]) - 1 or t.via is not None:
                return None
            a, b = t.src.span(t.node)
            return Edit(t.src.rel, a, b, fmt(val, 4))
        if t.kind == "missing" and t.frame_index == len(ev["frames"]) - 1 and t.param:
            return insert_kwarg(t.src, t.call, t.param, fmt(val, 4))
        return None


    # ------------------------------------------------------- insert / delete
    def plan_insert(self, scene: dict, stop: int, nstops: int, code: str, site: dict | None = None) -> tuple[Edit, int]:
        """Insert `self.add(code)  # manimble` so the element exists at the given build.

        `site` is the next_slide() call that ends that build (recorded while the scene ran);
        without it (the last build) the element goes at the end of construct()."""
        src = self.p.src(scene["file"])
        cls = next((n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == scene["name"]), None)
        fn = next((n for n in (cls.body if cls else []) if isinstance(n, ast.FunctionDef) and n.name == "construct"), None)
        if fn is None:
            raise EditError("scene has no construct()")
        line = f"self.add({code})  # manimble"
        if site and site.get("file") == scene["file"]:
            call = src.find_call(site["pos"])
            stmt = call
            while stmt is not None and not isinstance(src.parent.get(stmt), (ast.FunctionDef, ast.For, ast.While, ast.If, ast.With)):
                stmt = src.parent.get(stmt)
            if stmt is not None and isinstance(stmt, ast.Expr):
                at = src.line_starts[stmt.lineno - 1]
                return Edit(src.rel, at, at, " " * stmt.col_offset + line + "\n"), stmt.lineno
        last = fn.body[-1]
        indent = " " * last.col_offset
        at = src.line_starts[last.end_lineno] - 1 if last.end_lineno < len(src.line_starts) else len(src.data)
        return Edit(src.rel, at, at, "\n" + indent + line), last.end_lineno + 1

    def plan_delete(self, obj: dict) -> list[Edit]:
        """Remove an element that manimble inserted (its line carries the # manimble marker)."""
        fr = obj["frames"][-1]
        src = self.p.src(fr["file"])
        call = src.find_call(fr["pos"])
        if call is None:
            raise EditError("call site not found")
        stmt = call
        while stmt is not None and not isinstance(src.parent.get(stmt), (ast.FunctionDef, ast.For, ast.While, ast.If, ast.With)):
            stmt = src.parent.get(stmt)
        if stmt is None:
            raise EditError("statement not found")
        a = src.line_starts[stmt.lineno - 1]
        b = src.line_starts[stmt.end_lineno] if stmt.end_lineno < len(src.line_starts) else len(src.data)
        text = src.data[a:b].decode("utf-8")
        if "# manimble" not in text or text.count("\n") > 1:
            raise EditError("only elements inserted with the toolbar can be deleted; remove its lines in the source instead")
        return [Edit(src.rel, a, b, "")]

    def plan_table(self, obj: dict, rows: list) -> list[Edit]:
        t = locate(self.p, obj["frames"], 0, "table", 0, resolve_globals=False)
        if t.kind != "node":
            raise EditError("the table data is generated by code")

        def cell(c):
            if isinstance(c, (int, float)):
                return fmt(c, 6)
            c = str(c).strip()
            try:
                return str(int(c)) if c.lstrip("-").isdigit() else fmt(float(c), 6) if c.replace(".", "", 1).lstrip("-").isdigit() else py_str(c)
            except ValueError:
                return py_str(c)
        lit = "[" + ", ".join("[" + ", ".join(cell(c) for c in r) + "]" for r in rows) + "]"
        a, b = t.src.span(t.node)
        return [Edit(t.src.rel, a, b, lit)]


class EditError(Exception):
    pass


def name_map(obj: dict, name: str):
    return name


def insert_kwarg(src: Src, call: ast.Call, name: str, literal: str) -> Edit:
    last = None
    for a in list(call.args) + [k.value for k in call.keywords]:
        if last is None or (a.end_lineno, a.end_col_offset) > (last.end_lineno, last.end_col_offset):
            last = a
    if last is None:
        pos = src.off(call.end_lineno, call.end_col_offset) - 1
        return Edit(src.rel, pos, pos, f"{name}={literal}")
    pos = src.off(last.end_lineno, last.end_col_offset)
    return Edit(src.rel, pos, pos, f", {name}={literal}")
