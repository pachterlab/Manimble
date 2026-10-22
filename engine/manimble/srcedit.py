"""Source-code side of manimble: map on-screen edits back to Python edits.

The worker reports, for every editable object, the stack of call sites that
created it and the layout calls (move_to, shift, next_to, set, ...) that shaped
it.  This module walks the AST of the user's files to turn "move this 0.4 to the
right" or "change this string" into minimal textual patches.
"""

from __future__ import annotations

import ast
import hashlib
import io
import json
import math
import os
import re
import shutil
import tokenize
from dataclasses import dataclass, field


# ------------------------------------------------------------------ helpers

def fmt(x: float, nd: int = 3) -> str:
    s = f"{x:.{nd}f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def py_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


# A text box's wrap width (manim units), on the line of its string literal. The text is wrapped there by
# soft line breaks, written " \n" (the space is invisible at the end of a line) so they can be undone.
BOX_RE = re.compile(r"# manimble box w=(\d+(?:\.\d+)?)")


def unwrap_soft(s: str) -> str:
    return s.replace(" \n", " ")


def wrap_soft(s: str, width: float, measure) -> str:
    """Greedy word wrap of each paragraph of s to `width`, measure(line) giving the same unit; words wider
    than the box keep a line of their own."""
    out = []
    for para in unwrap_soft(s).split("\n"):
        words = para.split(" ")
        lines = [words[0]]
        for w in words[1:]:
            if lines[-1].strip() and w and measure(lines[-1] + " " + w) > width:
                lines.append(w)
            else:
                lines[-1] += " " + w
        out.append(" \n".join(lines))
    return "\n".join(out)


def _line_tokens(src: "Src", ln: int) -> list:
    try:
        toks = list(tokenize.tokenize(io.BytesIO(src.data).readline))
    except (tokenize.TokenError, SyntaxError):
        return []
    return [t for t in toks if t.start[0] == ln]


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
        if obj["kind"] == "text":
            call_src = self.p.src(obj["frames"][0]["file"])
            call = call_src.find_call(obj["frames"][0]["pos"])
            if call is not None and _func_name(call) == "Paragraph" and call.args and \
                    all(isinstance(a, ast.Constant) and isinstance(a.value, str) for a in call.args):
                if "\n".join(a.value for a in call.args) == value:
                    return Target("node", src=call_src, node=call, frame_index=0, note="paragraph")
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
        if t.note == "paragraph":            # Paragraph("line", "line", ...): one literal per line
            a = src.span(node.args[0])[0]
            b = src.span(node.args[-1])[1]
            return [Edit(src.rel, a, b, ", ".join(py_str(line) for line in new.split("\n")))]
        if t.via and not shared and t.via.get("local"):
            src, node = t.via["local"]
        old_src = src.text(node)
        raw = bool(re.match(r"^[rR]", old_src.lstrip("(").lstrip()))
        lit = py_tex(new, raw or obj["kind"] == "tex") if obj["kind"] == "tex" else py_str(new)
        a, b = src.span(node)
        edits = [Edit(src.rel, a, b, lit)]
        call = src.parent.get(node)
        if obj["kind"] == "text" and isinstance(call, ast.Call) and call.args and call.args[0] is node:
            edits += _shift_text_ranges(src, call, node.value, new)
        return edits

    # ------------------------------------------------------ text box width
    def _box_line(self, obj: dict):
        """(src, line number) of the text's string literal, where its `# manimble box w=` comment lives."""
        t = self.text_target(obj)
        if t.kind != "node":
            raise EditError(t.note or "this text is generated by code and cannot be wrapped")
        if t.via:
            raise EditError(f"the text is the shared constant {t.via['name']}; it cannot be wrapped for one object")
        return t.src, t.node.end_lineno

    def box_width(self, obj: dict) -> float | None:
        """The wrap width (manim units) a text box was given by dragging its side handles, if any."""
        try:
            src, ln = self._box_line(obj)
        except EditError:
            return None
        end = src.line_starts[ln] if ln < len(src.line_starts) else len(src.data)
        m = BOX_RE.search(src.data[src.line_starts[ln - 1]:end].decode("utf-8"))
        return float(m.group(1)) if m else None

    def plan_wrap(self, obj: dict, new: str, width: float) -> list[Edit]:
        """The text re-wrapped (`new`) plus the `# manimble box w=<width>` comment that remembers its box."""
        src, ln = self._box_line(obj)
        edits = self.plan_text(obj, new, shared=False) if new != obj["value"] else []
        a = src.line_starts[ln - 1]
        b = src.line_starts[ln] - 1 if ln < len(src.line_starts) else len(src.data)
        line = src.data[a:b].decode("utf-8")
        tag = f"box w={fmt(width, 3)}"
        m = BOX_RE.search(line)
        if m:
            s, e = (len(line[:i].encode("utf-8")) for i in m.span())
            return edits + [Edit(src.rel, a + s, a + e, "# manimble " + tag)]
        comment = next((tok for tok in _line_tokens(src, ln) if tok.type == tokenize.COMMENT), None)
        add = (" " + tag) if comment is not None and comment.string.startswith("# manimble") else "  # manimble " + tag
        return edits + [Edit(src.rel, b, b, add)]

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
    def plan_insert(self, scene: dict, stop: int, nstops: int, code: str, site: dict | None = None,
                    tag: str = "") -> tuple[Edit, int]:
        """Insert `self.add(code)  # manimble` so the element exists at the given build.

        `site` is the next_slide() call that ends that build (recorded while the scene ran);
        without it (the last build) the element goes at the end of construct(). `tag` extends the marker
        (`# manimble pen`) for elements the worker recognises by it."""
        src = self.p.src(scene["file"])
        cls = next((n for n in src.tree.body if isinstance(n, ast.ClassDef) and n.name == scene["name"]), None)
        fn = next((n for n in (cls.body if cls else []) if isinstance(n, ast.FunctionDef) and n.name == "construct"), None)
        if fn is None:
            raise EditError("scene has no construct()")
        line = f"self.add({code})  # manimble" + (f" {tag}" if tag else "")
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

    # animations that take the mobjects to show as their positional arguments, and the scene / group calls that do
    DISPLAY_CALLS = {
        "add", "remove", "play", "bring_to_front", "bring_to_back", "add_foreground_mobject", "add_foreground_mobjects",
        "remove_foreground_mobject", "remove_foreground_mobjects", "Group", "VGroup", "AnimationGroup", "LaggedStart",
        "Succession", "FadeIn", "FadeOut", "Write", "Unwrite", "Create", "Uncreate", "DrawBorderThenFill", "GrowArrow",
        "GrowFromCenter", "GrowFromEdge", "GrowFromPoint", "SpinInFromNothing", "ShrinkToCenter", "Indicate",
        "Circumscribe", "Wiggle", "Flash", "ShowPassingFlash", "ApplyWave", "AddTextLetterByLetter",
        "RemoveTextLetterByLetter", "ShowIncreasingSubsets", "ShowSubmobjectsOneByOne",
    }

    def plan_delete(self, obj: dict) -> list[Edit]:
        """Remove an element from the slide.

        An element that is a bare expression (`self.add(Circle())`, `self.play(FadeIn(Text("x")))`,
        `Group(Circle(), ...)`) is cut out of the call that shows it. A named element (`t = Text(...)`) loses its
        assignment, its own statements (`t.shift(...)`) and every place it is shown (`self.add(t)`, `FadeIn(t)`,
        `VGroup(a, t)`), as long as nothing else depends on it. When other code uses it (`SurroundingRectangle(t)`,
        `t.get_right()`, `Transform(t, ...)`) the name and its statements stay, so that code keeps working, and only
        the places that show it are removed; the re-render then checks that it is really gone."""
        src, call, top, stmt = self._creation(obj)
        body = _body_of(src, stmt)
        var = _assigned_name(stmt, top)
        if var is None:
            if isinstance(stmt, ast.Expr) and (stmt.value is top or _chain_root(stmt.value) is top):
                edits = [self._cut_stmt(src, stmt)]
            else:
                edits = self._cut_node(src, top)
                if edits is None:
                    raise EditError("this element is part of a larger expression; remove it in the source instead")
            return self._keep_block(src, body, edits)

        fdef = src.enclosing(stmt, (ast.FunctionDef, ast.AsyncFunctionDef))
        scope = fdef if fdef is not None else src.tree
        uses = [n for n in ast.walk(scope) if isinstance(n, ast.Name) and n.id == var and n is not stmt.targets[0]]
        own, shown, other = [], [], []
        for n in uses:
            s = src.enclosing(n, ast.stmt)
            if isinstance(n.ctx, ast.Store) or s is None or s is stmt or src.enclosing(n, (ast.Lambda, ast.FunctionDef,
                                                                                         ast.AsyncFunctionDef)) is not fdef:
                other.append(n)
            elif isinstance(s, ast.Expr) and isinstance(_chain_root(s.value), ast.Name) and _chain_root(s.value).id == var:
                own.append(s)                        # `var.shift(...)`, `var.add(Underline(var))`
            elif self._cut_node(src, n) is not None:
                shown.append(n)
            else:
                other.append(n)
        edits = []
        if not other:
            edits.append(self._cut_stmt(src, stmt))
            for s in own:
                edits.append(self._cut_stmt(src, s))
        gone = {id(stmt)} | {id(s) for s in own} if not other else set()
        for n in shown:
            if any(id(p) in gone for p in _ancestors(src, n)):
                continue                             # inside a statement that goes anyway
            cut = self._cut_node(src, n)
            if cut:
                edits += cut
                gone.update(id(p) for p in _ancestors(src, n) if isinstance(p, ast.stmt)
                            and any(e.start <= src.span(p)[0] and e.end >= src.span(p)[1] for e in cut))
        if not edits:
            raise EditError("could not find where this element is shown; remove it in the source instead")
        return self._keep_block(src, body, _disjoint(edits))

    def _cut_stmt(self, src: Src, stmt) -> Edit:
        a, b = _stmt_lines(src, stmt)
        return Edit(src.rel, a, b, "")

    def _keep_block(self, src: Src, body: list, edits: list[Edit]) -> list[Edit]:
        """An emptied construct() (or loop body) would not parse, so `pass` keeps the block."""
        spans = [(src.span(s)[0], _stmt_lines(src, s)[1]) for s in body]
        left = [s for s, (a, b) in zip(body, spans) if not any(e.start <= a and e.end >= b and not e.text for e in edits)]
        if body and not left:
            first = min(edits, key=lambda e: e.start)
            edits[edits.index(first)] = Edit(first.rel, first.start, first.end, " " * body[0].col_offset + "pass\n")
        return edits

    def _cut_node(self, src: Src, node) -> list[Edit] | None:
        """Edits that drop `node` from the call or literal that shows it, cascading outwards when the container
        becomes empty (`self.play(FadeIn(x))` goes as a whole). None when the node is not in such a place."""
        p = src.parent.get(node)
        if isinstance(p, ast.Expr):
            return [self._cut_stmt(src, p)]
        if isinstance(p, ast.Starred):
            return None
        if isinstance(p, (ast.List, ast.Tuple)) and isinstance(getattr(p, "ctx", None), ast.Load) and node in p.elts:
            pp = src.parent.get(p)
            shown = isinstance(pp, ast.Starred) and isinstance(src.parent.get(pp), ast.Call) \
                and _func_name(src.parent.get(pp)) in self.DISPLAY_CALLS
            kept = isinstance(pp, ast.Assign) and len(pp.targets) == 1 and isinstance(pp.targets[0], ast.Name)
            if not (shown or kept):
                return None                          # a table's labels, a list of points, ...
            return [self._drop_item(src, p.elts, [], node)]
        if isinstance(p, ast.Call) and node in p.args and _func_name(p) in self.DISPLAY_CALLS:
            if len(p.args) == 1 and _func_name(p) not in ("Group", "VGroup"):
                up = self._cut_node(src, p)
                if up is not None:
                    return up
            return [self._drop_item(src, p.args, p.keywords, node)]
        return None

    @staticmethod
    def _drop_item(src: Src, items: list, keywords: list, node) -> Edit:
        """Remove one positional item from a call or literal, taking a separating comma with it."""
        order = sorted(list(items) + [k.value for k in keywords], key=lambda n: src.span(n)[0])
        i = order.index(node)
        a, b = src.span(node)
        if i > 0:
            return Edit(src.rel, src.span(order[i - 1])[1], b, "")
        if i + 1 < len(order):
            nxt = order[i + 1]
            kw = next((k for k in keywords if k.value is nxt), None)
            start = src.off(kw.lineno, kw.col_offset) if kw is not None and getattr(kw, "lineno", None) else src.span(nxt)[0]
            return Edit(src.rel, a, start, "")
        # The only item: a trailing comma goes with it (`Group(\n    x,\n)` must not become `Group(\n    ,\n)`),
        # and so does the whole line when nothing else is on it.
        data, e = src.data, b
        while e < len(data) and data[e:e + 1] in (b" ", b"\t"):
            e += 1
        if data[e:e + 1] == b",":
            e += 1
            while e < len(data) and data[e:e + 1] in (b" ", b"\t"):
                e += 1
        s = a
        while s > 0 and data[s - 1:s] in (b" ", b"\t"):
            s -= 1
        if (s == 0 or data[s - 1:s] == b"\n") and data[e:e + 1] == b"\n":
            return Edit(src.rel, s, e + 1, "")
        return Edit(src.rel, a, e, "")

    def plan_image_file(self, obj: dict, file: str, deck_dir: str) -> list[Edit]:
        """Point a picture at another file (Extract Elements' filled-in background). `file` is in the deck folder.
        A direct ImageMobject(...) gets that file in place of its first argument; a helper call that is given the
        picture's file name (paper_figure("x.png") ...) gets the new name, with the file copied next to the old one."""
        src, call, _, _ = self._creation(obj)
        if _func_name(call) == "ImageMobject" and call.args and not isinstance(call.args[0], ast.Starred):
            a, b = src.span(call.args[0])
            return [Edit(src.rel, a, b, f'str(__import__("pathlib").Path(__file__).resolve().parent / {py_str(file)})')]
        old = os.path.basename(str(obj.get("value") or ""))
        hits = [n for n in ast.walk(call) if isinstance(n, ast.Constant) and isinstance(n.value, str)
                and old and (n.value == old or n.value.endswith("/" + old))]
        if len(hits) != 1:
            raise EditError("the picture's file is chosen by code, so it cannot be swapped for the filled-in copy")
        n = hits[0]
        here = os.path.dirname(str(obj.get("path") or obj.get("value") or ""))
        if not here or not os.path.isdir(here):
            raise EditError("could not find the folder of the picture")
        name = os.path.basename(file)
        if os.path.realpath(os.path.join(here, name)) != os.path.realpath(os.path.join(deck_dir, file)):
            shutil.copyfile(os.path.join(deck_dir, file), os.path.join(here, name))
        a, b = src.span(n)
        return [Edit(src.rel, a, b, py_str(n.value[: len(n.value) - len(old)] + name))]

    # ------------------------------------------------------- formatting
    def _creation(self, obj: dict):
        """(src, call, top, stmt): the outermost deck call that made the object, the end of its method chain
        and the statement holding it."""
        fr = obj["frames"][-1]
        src = self.p.src(fr["file"])
        call = src.find_call(fr["pos"])
        if call is None:
            raise EditError("call site not found")
        top = src.chain_top(call)
        stmt = top
        while stmt is not None and not isinstance(stmt, ast.stmt):
            stmt = src.parent.get(stmt)
        if stmt is None:
            raise EditError("statement not found")
        return src, call, top, stmt

    def _ensure_var(self, obj: dict, src: Src, top, stmt) -> tuple[str, list[Edit]]:
        """A variable holding the object. A Manimble insert (`self.add(X)  # manimble`) is split into
        `name = X  # manimble` + `self.add(name)  # manimble`; other code must name the object itself."""
        var = _assigned_name(stmt, top)
        if var:
            return var, []
        a, b = _stmt_lines(src, stmt)
        text = src.data[a:b].decode("utf-8")
        if (isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call) and ast.unparse(stmt.value.func) == "self.add"
                and len(stmt.value.args) == 1 and stmt.value.args[0] is top and "# manimble" in text and text.count("\n") <= 1):
            fdef = src.enclosing(stmt, (ast.FunctionDef, ast.AsyncFunctionDef))
            used = {n.id for n in ast.walk(fdef) if isinstance(n, ast.Name)} if fdef is not None else set()
            base = {"text": "text", "tex": "formula", "image": "image", "line": "line", "table": "table"}.get(obj["kind"], "shape")
            i = 1
            while f"{base}{i}" in used:
                i += 1
            name = f"{base}{i}"
            indent = " " * stmt.col_offset
            sa, sb = src.span(stmt)
            return name, [Edit(src.rel, sa, sb, f"{name} = {src.text(top)}  # manimble\n{indent}self.add({name})")]
        raise EditError("give this element a name in the source first (for example `t = Text(...)`), "
                        "then it can be underlined or struck through")

    def _decoration_stmt(self, src: Src, stmt, var: str, kind: str):
        """The `var.add(...)  # manimble <kind>` statement that follows the creation of var, if any."""
        body = _body_of(src, stmt)
        marker = f"# manimble {kind}"
        for s in body[body.index(stmt) + 1:]:
            a, b = _stmt_lines(src, s)
            text = src.data[a:b].decode("utf-8")
            if marker in text and isinstance(s, ast.Expr) and isinstance(s.value, ast.Call) \
                    and ast.unparse(s.value.func) == f"{var}.add":
                return s
        return None

    def plan_decoration(self, obj: dict, kind: str, on: bool) -> list[Edit]:
        """Underline / strikethrough: Manim text has neither, so a line is attached to the text object
        (`t.add(Underline(t, ...))`), which then moves, scales and recolours with it."""
        if kind not in ("underline", "strike"):
            raise EditError(f"unknown decoration {kind}")
        if obj["kind"] not in ("text", "tex"):
            raise EditError("only text and formulas can be underlined or struck through")
        src, call, top, stmt = self._creation(obj)
        var = _assigned_name(stmt, top)
        existing = self._decoration_stmt(src, stmt, var, kind) if var else None
        if not on:
            if existing is None:
                return []
            a, b = _stmt_lines(src, existing)
            return [Edit(src.rel, a, b, "")]
        if existing is not None:
            return []
        edits: list[Edit] = []
        if not var:
            var, edits = self._ensure_var(obj, src, top, stmt)
        edits += self._ensure_helpers(src)
        # the text's rendered colour as a literal: a Text with a default colour reports get_color() as black
        col = py_str((obj.get("color") or "#FFFFFF").upper())
        edits.append(_after_stmt(src, stmt, f"{var}.add({kind}({var}, color={col}))  # manimble {kind}"))
        return edits

    def _ensure_helpers(self, src: Src) -> list[Edit]:
        """Make sure the deck has manimble_helpers.py and this file imports strike/underline from it."""
        return ensure_helpers(self.p, src, ["strike", "underline"])

    def _chain(self, src: Src, call):
        """The method calls chained onto `call`, innermost first (call itself included)."""
        out = [call]
        node = call
        while True:
            p = src.parent.get(node)
            if isinstance(p, ast.Attribute) and p.value is node:
                pp = src.parent.get(p)
                if isinstance(pp, ast.Call) and pp.func is p:
                    out.append(pp)
                    node = pp
                    continue
            return out

    def _chain_call(self, src: Src, call, name: str):
        return next((c for c in self._chain(src, call) if isinstance(c.func, ast.Attribute) and c.func.attr == name), None)

    def _remove_chain_call(self, src: Src, c) -> Edit:
        """Drop `.name(...)` from a method chain."""
        a = src.span(c.func.value)[1]
        b = src.span(c)[1]
        return Edit(src.rel, a, b, "")

    def plan_highlight(self, obj: dict, color: str | None, opacity: float = 0.6) -> list[Edit]:
        """Text highlight: a background rectangle behind the text (`.add_background_rectangle(...)`)."""
        if obj["kind"] not in ("text", "tex"):
            raise EditError("only text and formulas can be highlighted")
        src, call, top, stmt = self._creation(obj)
        existing = self._chain_call(src, call, "add_background_rectangle")
        if color is None:
            return [self._remove_chain_call(src, existing)] if existing is not None else []
        args = f"color={py_str(color.upper())}, opacity={fmt(opacity, 2)}"
        if existing is not None:
            a = src.span(existing.func)[1]
            b = src.span(existing)[1]
            return [Edit(src.rel, a, b, f"({args})")]
        return [self._append_chain(obj["frames"], f".add_background_rectangle({args})")]

    def _text_call(self, obj: dict, what: str):
        """The Text(...) / Paragraph(...) call itself; it must be written in the slide, not in a helper."""
        if obj["kind"] != "text":
            raise EditError(f"{what} applies to text")
        if len(obj["frames"]) > 1:
            raise EditError(f"this text is made by {obj['frames'][0]['func']}(); {what} can only be set on a "
                            "Text(...) written in the slide itself")
        fr = obj["frames"][0]
        src = self.p.src(fr["file"])
        call = src.find_call(fr["pos"])
        if call is None or _func_name(call) not in ("Text", "Paragraph"):
            raise EditError(f"{what} can only be set on a Text(...) written in the slide itself")
        return src, call

    def plan_align(self, obj: dict, value: str) -> list[Edit]:
        """Paragraph alignment: a multi-line Text becomes a Paragraph(line, line, ..., alignment=...)."""
        if value == "justify":
            raise EditError("Manim cannot justify text with manual line breaks; use left, centre or right")
        if value not in ("left", "center", "right"):
            raise EditError(f"unknown alignment {value}")
        src, call = self._text_call(obj, "alignment")
        if _func_name(call) == "Paragraph":
            kw = next((k for k in call.keywords if k.arg == "alignment"), None)
            if kw is not None:
                if isinstance(kw.value, ast.Constant) and kw.value.value == value:
                    return []
                a, b = src.span(kw.value)
                return [Edit(src.rel, a, b, py_str(value))]
            return [insert_kwarg(src, call, "alignment", py_str(value))]
        if value == "left":
            return []                      # a Text already aligns its lines to the left
        if not call.args:
            raise EditError("the text is passed by keyword; alignment needs Text(\"...\")")
        first = call.args[0]
        if isinstance(first, ast.Constant) and isinstance(first.value, str):
            lines = first.value.split("\n")
            if len(lines) < 2:
                raise EditError("alignment shows on text with several lines (press ↵ in the text box to add one)")
            new_first = ", ".join(py_str(line) for line in lines)
        elif isinstance(first, ast.Name):
            new_first = f'*{first.id}.split("\\n")'
        else:
            raise EditError("the text is computed; alignment can only be set on a plain string")
        fa, fb = src.span(call.func)
        a, b = src.span(first)
        return [Edit(src.rel, fa, fb, "Paragraph"), Edit(src.rel, a, b, new_first),
                insert_kwarg(src, call, "alignment", py_str(value))]

    def _columns_group(self, src: Src, call):
        """(VGroup call, arrange call) when `call` is one column of VGroup(Text, Text, ...).arrange(RIGHT, ...)."""
        p = src.parent.get(call)
        if not (isinstance(p, ast.Call) and _func_name(p) == "VGroup" and call in p.args and len(p.args) >= 2
                and all(isinstance(a, ast.Call) and _func_name(a) in ("Text", "Paragraph") for a in p.args)):
            return None
        arrange = None
        pp = src.parent.get(p)
        if isinstance(pp, ast.Attribute) and pp.attr == "arrange":
            ppp = src.parent.get(pp)
            if isinstance(ppp, ast.Call) and ppp.func is pp:
                arrange = ppp
        return p, arrange

    def plan_columns(self, obj: dict, n: int) -> list[Edit]:
        """Lay the lines of a text out in n columns: VGroup(Text(...), Text(...)).arrange(RIGHT, ...)."""
        if obj["kind"] != "text":
            raise EditError("columns apply to text")
        src, call, top, stmt = self._creation(obj)

        def lines_of(c):
            if _func_name(c) == "Text" and c.args and isinstance(c.args[0], ast.Constant) and isinstance(c.args[0].value, str):
                return c.args[0].value.split("\n")
            if _func_name(c) == "Paragraph" and c.args and all(isinstance(a, ast.Constant) and isinstance(a.value, str) for a in c.args):
                return [a.value for a in c.args]
            raise EditError("columns need a Text(\"...\") with a plain string written in the slide")

        skip = {"t2c", "t2w", "t2s", "t2f", "t2g", "alignment"}
        grp = self._columns_group(src, call)
        if grp is not None:
            vgroup, arrange = grp
            lines = [line for c in vgroup.args for line in lines_of(c)]
            kws = [src.text(k) for k in vgroup.args[0].keywords if k.arg not in skip]
            a = src.span(vgroup)[0]
            b = src.span(arrange if arrange is not None else vgroup)[1]
        else:
            if len(obj["frames"]) > 1:
                raise EditError(f"this text is made by {obj['frames'][0]['func']}(); columns can only be set on a "
                                "Text(...) written in the slide itself")
            lines = lines_of(call)
            kws = [src.text(k) for k in call.keywords if k.arg not in skip]
            a, b = src.span(call)
        n = max(1, min(int(n), len(lines)))
        kw = (", " + ", ".join(kws)) if kws else ""
        if n == 1:
            new = f"Text({py_str(chr(10).join(lines))}{kw})"
        else:
            per = math.ceil(len(lines) / n)
            chunks = [lines[i * per:(i + 1) * per] for i in range(n)]
            chunks = [c for c in chunks if c]
            new = ("VGroup(" + ", ".join(f"Text({py_str(chr(10).join(c))}{kw})" for c in chunks)
                   + ").arrange(RIGHT, buff=0.8, aligned_edge=UP)")
        return [Edit(src.rel, a, b, new)]

    def format_info(self, obj: dict) -> dict:
        """What the formatting controls should show for a text object."""
        info = {"underline": False, "strike": False, "highlight": None, "align": None, "columns": 1, "lineSpacing": None}
        try:
            src, call, top, stmt = self._creation(obj)
        except EditError:
            return info
        hl = self._chain_call(src, call, "add_background_rectangle")
        if hl is not None:
            col = next((k.value for k in hl.keywords if k.arg == "color"), None)
            info["highlight"] = col.value if isinstance(col, ast.Constant) and isinstance(col.value, str) else "on"
        var = _assigned_name(stmt, top)
        if var:
            for kind in ("underline", "strike"):
                info[kind] = self._decoration_stmt(src, stmt, var, kind) is not None
        if self._columns_group(src, call) is not None:
            info["columns"] = len(self._columns_group(src, call)[0].args)
        if obj["kind"] == "text":
            try:
                tsrc = self.p.src(obj["frames"][0]["file"])
                tcall = tsrc.find_call(obj["frames"][0]["pos"])
            except Exception:
                tcall = None
            if tcall is not None and _func_name(tcall) == "Paragraph":
                kw = next((k.value for k in tcall.keywords if k.arg == "alignment"), None)
                info["align"] = kw.value if isinstance(kw, ast.Constant) and isinstance(kw.value, str) else "left"
            elif tcall is not None:
                info["align"] = "left"
            t = locate(self.p, obj["frames"], 0, "line_spacing", None, resolve_globals=True)
            if t.kind == "node" and isinstance(t.node, ast.Constant) and isinstance(t.node.value, (int, float)):
                info["lineSpacing"] = float(t.node.value)
        return info

    def plan_clear_format(self, obj: dict) -> list[Edit]:
        """Remove character formatting: bold, italic, colour, per-range styles, line spacing, highlight, under/strike."""
        edits: list[Edit] = []
        src, call, top, stmt = self._creation(obj)
        hl = self._chain_call(src, call, "add_background_rectangle")
        if hl is not None:
            edits.append(self._remove_chain_call(src, hl))
        var = _assigned_name(stmt, top)
        if var:
            for kind in ("underline", "strike"):
                s = self._decoration_stmt(src, stmt, var, kind)
                if s is not None:
                    a, b = _stmt_lines(src, s)
                    edits.append(Edit(src.rel, a, b, ""))
        last = len(obj["frames"]) - 1
        drop: dict = {}            # call -> {keyword nodes}
        for k in ("weight", "slant", "color", "t2c", "t2w", "t2s", "t2f", "t2g", "line_spacing", "gradient"):
            t = locate(self.p, obj["frames"], 0, k, None, resolve_globals=False)
            if t.kind != "node" or t.frame_index != last:
                continue
            kw = t.src.parent.get(t.node)
            c = t.src.parent.get(kw) if isinstance(kw, ast.keyword) else None
            if isinstance(c, ast.Call):
                drop.setdefault(id(c), (t.src, c, set()))[2].add(kw)
        for _, (ksrc, c, kws) in drop.items():
            edits.append(remove_kwargs(ksrc, c, kws))
        return edits

    def plan_size(self, obj: dict, w: float | None, h: float | None) -> list[tuple[str, list[Edit]]]:
        """Width and/or height in manim units, independently (stretching when both are given)."""
        attempts: list[tuple[str, list[Edit]]] = []
        last = len(obj["frames"]) - 1
        fr = obj["frames"][0]
        src0 = self.p.src(fr["file"])
        c0 = src0.find_call(fr["pos"])
        if c0 is not None and _func_name(c0) in ("Rectangle", "RoundedRectangle", "Ellipse"):
            edits: list | None = []
            for k, v in (("width", w), ("height", h)):
                if v is None:
                    continue
                t = locate(self.p, obj["frames"], 0, k, None, resolve_globals=False)
                if t.kind == "node" and t.via is None and t.frame_index == last:
                    a, b = t.src.span(t.node)
                    edits.append(Edit(t.src.rel, a, b, fmt(v, 4)))
                elif t.kind == "missing" and t.frame_index == last:
                    edits.append(insert_kwarg(t.src, t.call, k, fmt(v, 4)))
                else:
                    edits = None
                    break
            if edits:
                attempts.append(("changed the width/height arguments", edits))
        if (w is None) != (h is None):
            k, v = ("width", w) if w is not None else ("height", h)
            own = [e for e in obj["events"] if e["own"] and e["method"] == "set" and isinstance(e["kwargs"].get(k), (int, float))]
            if own:
                t = locate(self.p, own[-1]["frames"], 0, k, None, resolve_globals=False)
                e = self._size_edit(t, own[-1], v)
                if e is not None:
                    attempts.append((f"changed the set({k}=...) call", [e]))
        text = "".join(f".stretch_to_fit_{k}({fmt(v, 4)})" for k, v in (("width", w), ("height", h)) if v is not None)
        own_layout = [e for e in obj["events"] if e["own"] and e["method"] in
                      ("shift", "move_to", "next_to", "to_edge", "to_corner", "align_to", "scale", "set",
                       "set_width", "set_height", "scale_to_fit_width", "scale_to_fit_height", "rotate")]
        if own_layout:
            attempts.append(("stretched after the positioning", [self._append_chain(own_layout[-1]["frames"], text)]))
        attempts.append(("stretched where the object is created", [self._append_chain(obj["frames"], text)]))
        return attempts

    def plan_rotate(self, obj: dict, delta: float) -> list[tuple[str, list[Edit]]]:
        """Rotate by delta radians (on top of the object's current rotation)."""
        attempts: list[tuple[str, list[Edit]]] = []
        own = [e for e in obj["events"] if e["own"] and e["method"] == "rotate"
               and ((e["args"] and isinstance(e["args"][0], (int, float))) or isinstance(e["kwargs"].get("angle"), (int, float)))]
        if own:
            ev = own[-1]
            t = locate(self.p, ev["frames"], 0, "angle", 0, resolve_globals=False)
            if t.kind == "node" and t.via is None and t.frame_index == len(ev["frames"]) - 1:
                cur = ev["args"][0] if ev["args"] else ev["kwargs"]["angle"]
                a, b = t.src.span(t.node)
                attempts.append(("adjusted the rotate() angle", [Edit(t.src.rel, a, b, deg_expr(cur + delta))]))
        text = f".rotate({deg_expr(delta)})"
        own_layout = [e for e in obj["events"] if e["own"] and e["method"] in
                      ("shift", "move_to", "next_to", "to_edge", "to_corner", "align_to", "scale", "set",
                       "set_width", "set_height", "scale_to_fit_width", "scale_to_fit_height", "rotate")]
        if own_layout:
            attempts.append(("appended .rotate() after the positioning", [self._append_chain(own_layout[-1]["frames"], text)]))
        attempts.append(("appended .rotate() where the object is created", [self._append_chain(obj["frames"], text)]))
        return attempts

    def plan_table(self, obj: dict, rows: list) -> list[Edit]:
        t = locate(self.p, obj["frames"], 0, "table", 0, resolve_globals=False)
        if t.kind != "node":
            raise EditError("the table data is generated by code")
        # a plain Table builds each cell with Paragraph, which needs strings; MathTable takes numbers as they are
        call = self.p.src(obj["frames"][0]["file"]).find_call(obj["frames"][0]["pos"])
        fname = None if call is None else (call.func.id if isinstance(call.func, ast.Name) else getattr(call.func, "attr", None))
        words = fname == "Table"

        def cell(c):
            if words:
                return py_str(str(c).strip())
            if isinstance(c, (int, float)):
                return fmt(c, 6)
            c = str(c).strip()
            try:
                return str(int(c)) if c.lstrip("-").isdigit() else fmt(float(c), 6) if c.replace(".", "", 1).lstrip("-").isdigit() else py_str(c)
            except ValueError:
                return py_str(c)
        lit = "[" + ", ".join("[" + ", ".join(cell(c) for c in r) + "]" for r in rows) + "]"
        a, b = t.src.span(t.node)
        edits = [Edit(t.src.rel, a, b, lit)]
        if call is not None and fname in ("Table", "MathTable") and any(str(c).strip() == "" for r in rows for c in r):
            e = locate(self.p, obj["frames"], 0, "element_to_mobject", None, resolve_globals=False)
            if e.kind == "missing" and e.call is call:
                edits.append(insert_kwarg(e.src, call, "element_to_mobject", BLANK_CELLS["word" if words else "math"]))
        return edits


class EditError(Exception):
    pass


# Manim collapses a table row or column whose entries are all blank, so a blank cell holds an invisible placeholder
BLANK_CELLS = {
    "word": 'lambda s, **kw: Paragraph(s, **kw) if s != "" else Paragraph("Cell", **kw).set_opacity(0)',
    "math": 'lambda s, **kw: MathTex(s, **kw) if s != "" else MathTex(r"\\text{Cell}", **kw).set_opacity(0)',
}

HELPERS_FILE = "manimble_helpers.py"
HELPERS_SOURCE = '''"""Helpers Manimble adds to a deck for what it writes into slides (underline, strikethrough, sub-slide numbers).

Plain Manim code; edit or inline it as you like.
"""

from manim import VGroup, Line, BackgroundRectangle


def text_lines(mobject):
    """The glyphs of a Text / Paragraph / MathTex grouped into visual lines, top to bottom."""
    glyphs = [m for m in mobject.family_members_with_points() if not isinstance(m, (Line, BackgroundRectangle))]
    lines = []                      # [top, bottom, [glyphs]]
    for g in sorted(glyphs, key=lambda m: -m.get_top()[1]):
        top, bottom = g.get_top()[1], g.get_bottom()[1]
        if lines and top > lines[-1][1]:            # overlaps the current line vertically
            lines[-1][1] = min(lines[-1][1], bottom)
            lines[-1][2].append(g)
        else:
            lines.append([top, bottom, [g]])
    return [VGroup(*gs) for _, _, gs in lines]


def _median(values):
    v = sorted(values)
    return v[len(v) // 2]


def strike(mobject, color="#FFFFFF", stroke_width=3):
    """One line through the middle of every line of text."""
    out = VGroup()
    for line in text_lines(mobject):
        y = _median(g.get_center()[1] for g in line)
        out.add(Line((line.get_left()[0], y, 0), (line.get_right()[0], y, 0), color=color, stroke_width=stroke_width))
    return out


def underline(mobject, color="#FFFFFF", stroke_width=3, buff=0.06):
    """One line under the baseline of every line of text."""
    out = VGroup()
    for line in text_lines(mobject):
        y = _median(g.get_bottom()[1] for g in line) - buff
        out.add(Line((line.get_left()[0], y, 0), (line.get_right()[0], y, 0), color=color, stroke_width=stroke_width))
    return out
'''

SUB_SLIDES_SOURCE = '''

def sub_slides(scene, label):
    """A slide number ending in a sub-slide count ("29 / 47 · 1/3") that counts on at every scene.next_slide()."""
    import re
    from manim import Text, config, LEFT, RIGHT, ORIGIN
    m = re.fullmatch(r"(.*?)(\\d+)/(\\d+)", label.original_text)
    if not m:
        return label
    head, shown, count = m.group(1), [int(m.group(2))], int(m.group(3))
    style = dict(font=label.font, font_size=label.font_size, slant=label.slant, weight=label.weight)
    glyph = label.submobjects[0] if label.submobjects else label
    color, opacity = glyph.get_fill_color(), glyph.get_fill_opacity()
    advance = scene.next_slide

    def next_slide(*args, **kwargs):
        result = advance(*args, **kwargs)
        if shown[0] < count:
            shown[0] += 1
            new = Text(f"{head}{shown[0]}/{count}", **style).set_fill(color, opacity)
            x = label.get_center()[0]
            edge = RIGHT if x > config.frame_width / 6 else LEFT if x < -config.frame_width / 6 else ORIGIN
            label.become(new.move_to(label, aligned_edge=edge))
        return result

    scene.next_slide = next_slide
    return label
'''

# appended to an existing manimble_helpers.py that lacks them
HELPER_FUNCS = {"sub_slides": SUB_SLIDES_SOURCE}
HELPERS_SOURCE += SUB_SLIDES_SOURCE


def ensure_helpers(project, src: Src, wanted: list[str]) -> list[Edit]:
    """Edits that give the deck manimble_helpers.py with the `wanted` functions and make `src` import them."""
    edits: list[Edit] = []
    if HELPERS_FILE not in project.py_files():
        edits.append(Edit(HELPERS_FILE, 0, 0, HELPERS_SOURCE))
    else:
        have = project.read(HELPERS_FILE).decode("utf-8")
        extra = "".join(HELPER_FUNCS[n] for n in wanted if n in HELPER_FUNCS and f"def {n}(" not in have)
        if extra:                       # a deck from before this helper existed
            edits.append(Edit(HELPERS_FILE, len(have.encode("utf-8")), len(have.encode("utf-8")),
                              ("" if have.endswith("\n") else "\n") + extra))
    existing = next((n for n in src.tree.body if isinstance(n, ast.ImportFrom) and n.module == "manimble_helpers"), None)
    if existing is not None:
        names = [a.name for a in existing.names]
        if "*" not in names and not set(wanted) <= set(names):
            a, b = src.span(existing)
            edits.append(Edit(src.rel, a, b, "from manimble_helpers import "
                              + ", ".join(names + [n for n in wanted if n not in names])))
        return edits
    line = "from manimble_helpers import " + ", ".join(wanted)
    imports = [n for n in src.tree.body if isinstance(n, (ast.Import, ast.ImportFrom))]
    if imports:
        at = src.line_starts[imports[-1].end_lineno] if imports[-1].end_lineno < len(src.line_starts) else len(src.data)
    elif src.tree.body and isinstance(src.tree.body[0], ast.Expr) and isinstance(src.tree.body[0].value, ast.Constant) \
            and isinstance(src.tree.body[0].value.value, str):
        doc = src.tree.body[0]
        at = src.line_starts[doc.end_lineno] if doc.end_lineno < len(src.line_starts) else len(src.data)
    else:
        at = 0
    edits.append(Edit(src.rel, at, at, line + "\n"))
    return edits


def name_map(obj: dict, name: str):
    return name


def _func_name(call) -> str | None:
    f = call.func
    return f.id if isinstance(f, ast.Name) else getattr(f, "attr", None)


def _chain_root(expr):
    """The node a method chain hangs off: `a.b(c).d()` -> the node for `a`."""
    n = expr
    while True:
        if isinstance(n, ast.Call):
            n = n.func
        elif isinstance(n, ast.Attribute):
            n = n.value
        else:
            return n


def _ancestors(src, node):
    out = []
    p = src.parent.get(node)
    while p is not None:
        out.append(p)
        p = src.parent.get(p)
    return out


def _disjoint(edits):
    """Drop edits lying inside another edit's range (a cut argument inside a cut statement)."""
    out = []
    for e in sorted(edits, key=lambda e: (e.start, -e.end)):
        if out and out[-1].rel == e.rel and out[-1].start <= e.start and e.end <= out[-1].end:
            continue
        out.append(e)
    return out


def _assigned_name(stmt, top) -> str | None:
    """`name` when the statement is `name = <top>`."""
    if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name) and stmt.value is top:
        return stmt.targets[0].id
    return None


def _body_of(src: Src, stmt) -> list:
    """The statement list (function body, loop body, ...) that contains stmt."""
    parent = src.parent.get(stmt)
    for field in ("body", "orelse", "finalbody"):
        lst = getattr(parent, field, None)
        if isinstance(lst, list) and stmt in lst:
            return lst
    return [stmt]


def _stmt_lines(src: Src, stmt) -> tuple[int, int]:
    """Byte range of the whole lines a statement occupies (comments included)."""
    a = src.line_starts[stmt.lineno - 1]
    b = src.line_starts[stmt.end_lineno] if stmt.end_lineno < len(src.line_starts) else len(src.data)
    return a, b


def _after_stmt(src: Src, stmt, code: str) -> Edit:
    """Insert a line of code right after a statement, with its indentation."""
    indent = " " * stmt.col_offset
    at = src.line_starts[stmt.end_lineno] if stmt.end_lineno < len(src.line_starts) else len(src.data)
    if at == len(src.data) and not src.data.endswith(b"\n"):
        return Edit(src.rel, at, at, "\n" + indent + code)
    return Edit(src.rel, at, at, indent + code + "\n")


def deg_expr(rad: float) -> str:
    """An angle in radians as a readable `<degrees> * DEGREES` expression."""
    return f"{fmt(math.degrees(rad), 2)} * DEGREES"


def remove_kwargs(src: Src, call: ast.Call, kws: set) -> Edit:
    """Rewrite a call's argument list without the given keyword nodes."""
    items = sorted(list(call.args) + list(call.keywords), key=lambda n: (n.lineno, n.col_offset))
    keep = [src.text(x) for x in items if not any(x is k for k in kws)]
    a = src.span(items[0])[0]
    b = src.span(items[-1])[1]
    return Edit(src.rel, a, b, ", ".join(keep))


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


_RANGE_KEY = re.compile(r"^\[(-?\d*):(-?\d*)\]$")


def _shift_text_ranges(src: Src, call: ast.Call, old: str, new: str) -> list[Edit]:
    """Keep Text(..., t2c / t2w / t2s / t2f / t2g = {"[i:j]": ...}) ranges on the same characters after the text is
    retyped: positions are mapped through the old -> new diff, and a range whose text was deleted is dropped."""
    import difflib
    pos = [None] * (len(old) + 1)        # old index -> new index (None inside replaced text)
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1 + 1):
                pos[i1 + k] = j1 + k
        else:
            pos[i1], pos[i2] = j1, j2
    edits = []
    for kw in call.keywords:
        if kw.arg not in ("t2c", "t2w", "t2s", "t2f", "t2g") or not isinstance(kw.value, ast.Dict):
            continue
        items, changed = [], False
        for k, v in zip(kw.value.keys, kw.value.values):
            m = _RANGE_KEY.match(k.value) if isinstance(k, ast.Constant) and isinstance(k.value, str) else None
            if m is None:
                items.append(src.text(k) + ": " + src.text(v))
                continue
            i = int(m.group(1) or 0) % (len(old) + 1)
            j = int(m.group(2)) % (len(old) + 1) if m.group(2) else len(old)
            a = next((pos[x] for x in range(i, j + 1) if pos[x] is not None), None)
            b = next((pos[x] for x in range(j, i - 1, -1) if pos[x] is not None), None)
            changed = True
            if a is None or b is None or b <= a:
                continue
            items.append(py_str(f"[{a}:{b}]") + ": " + src.text(v))
        if changed:
            s, e = src.span(kw.value)
            edits.append(Edit(src.rel, s, e, "{" + ", ".join(items) + "}"))
    return edits
