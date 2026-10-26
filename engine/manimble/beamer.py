"""Export the deck to Beamer (LaTeX).

One frame per slide; with builds, each build is one overlay of that frame (`\\only<k>`). In *editable* mode text
stays real LaTeX text in its size, colour, weight and slant (and its font under XeLaTeX/LuaLaTeX), formulas are
written as LaTeX math, and everything else (backdrop, images, shapes, lines) is placed as pictures at their exact
positions. In *pictures* mode each page is the exact rendered frame. Pictures go in `<name>-figures/` next to the
.tex file; speaker notes become `\\note{...}`."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

MATH_EM_PER_FONT_SIZE = 1 / 96.4      # MathTex: 1 em = font_size / 96.4 manim units (Text: font_size / 72)
TEXT_EM_PER_FONT_SIZE = 1 / 72

_ESC = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#", "_": r"\_", "{": r"\{",
        "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}


def _math_chars() -> dict:
    """Unicode maths characters (as the Beamer importer writes them) -> LaTeX, so they typeset in any text font."""
    from .beamer_import import BB, MATH_SYMS, SUB, SUP
    out = {"−": "-", "\u2005": " "}
    for name, ch in MATH_SYMS.items():
        if len(ch) == 1 and ord(ch) > 0x2000 or (len(ch) == 1 and 0x370 <= ord(ch) < 0x400):
            out.setdefault(ch, "\\" + name)
    for k, ch in BB.items():
        out.setdefault(ch, "\\mathbb{" + k + "}")
    for k, ch in SUP.items():
        if ch != k:
            out.setdefault(ch, "^{" + k + "}")
    for k, ch in SUB.items():
        out.setdefault(ch, "_{" + k + "}")
    for ch in "…–—“”‘’•\u00a0\u2009\u2003":
        out.pop(ch, None)
    return out


_MATH = None


def tex_escape(s: str) -> str:
    global _MATH
    if _MATH is None:
        _MATH = _math_chars()
    out = []
    for c in s:
        m = _MATH.get(c)
        if m is None:
            out.append(_ESC.get(c, c))
        elif m.startswith("\\") or m.startswith(("^", "_")):
            out.append("\\ensuremath{" + ("{}" if m[0] in "^_" else "") + m + "}")
        else:
            out.append(m)
    return "".join(out)


def _text_ranges(app, obj: dict) -> list[dict] | None:
    """Per-character style of a Text from its source call's t2c / t2w / t2s / t2f "[i:j]" ranges:
    [{c, b, i, tt}] for each character of its value, or None when the call cannot be read."""
    import ast
    loc = str(obj.get("loc") or "")
    if ":" not in loc:
        return None
    rel, line = loc.rsplit(":", 1)
    try:
        tree = ast.parse((Path(str(app.deck)) / rel).read_text(encoding="utf-8"))
        line = int(line)
    except (OSError, SyntaxError, ValueError):
        return None
    value = str(obj.get("value") or "")
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and getattr(node.func, "id", None) == "Text" and node.lineno <= line
                <= (node.end_lineno or node.lineno) and node.args and isinstance(node.args[0], ast.Constant)
                and node.args[0].value == value):
            continue
        kws = {k.arg: k.value for k in node.keywords if k.arg}
        lig = kws.get("disable_ligatures")
        if not (isinstance(lig, ast.Constant) and lig.value is True):
            return None                 # without it manim's indices skip spaces; leave the text plain
        style = [{} for _ in value]
        for key, field in (("t2c", "c"), ("t2w", "b"), ("t2s", "i"), ("t2f", "tt")):
            d = kws.get(key)
            if not isinstance(d, ast.Dict):
                continue
            for k, v in zip(d.keys, d.values):
                m = re.fullmatch(r"\[(\d*):(\d*)\]", k.value if isinstance(k, ast.Constant) else "")
                if not m or not isinstance(v, ast.Constant):
                    continue
                a, b = int(m.group(1) or 0), int(m.group(2) or len(value))
                for j in range(max(0, a), min(b, len(value))):
                    val = v.value
                    style[j][field] = (val if field == "c" else str(val).upper() in ("BOLD", "ITALIC", "OBLIQUE")
                                       if field in ("b", "i") else "mono" in str(val).lower() or str(val) in ("Menlo", "Courier"))
        return style
    return None


def _styled_tex(value: str, style: list[dict] | None) -> str:
    """The text as LaTeX lines joined by \\\\, with \\textbf / \\textit / \\textcolor / \\texttt runs."""
    if not style:
        return r"\\".join(tex_escape(l.rstrip()) for l in value.split("\n"))
    lines, cur, i = [], [], 0
    for ln in value.split("\n"):
        k, out = 0, []
        while k < len(ln):
            st = style[i + k]
            e = k
            while e < len(ln) and style[i + e] == st:
                e += 1
            run = tex_escape(ln[k:e])
            if st.get("tt"):
                run = r"\texttt{" + run + "}"
            if st.get("i"):
                run = r"\textit{" + run + "}"
            if st.get("b"):
                run = r"\textbf{" + run + "}"
            c = str(st.get("c") or "").lstrip("#").upper()
            if len(c) == 6:
                run = r"\textcolor[HTML]{" + c + "}{" + run + "}"
            out.append(run)
            k = e
        lines.append("".join(out).rstrip())
        i += len(ln) + 1
    return r"\\".join(lines)


def _url(u: str) -> str:
    return u.replace("\\", "/").replace("%", r"\%").replace("#", r"\#")


def _bp(x: float) -> str:
    return f"{x:.2f}".rstrip("0").rstrip(".")


PREAMBLE = r"""%% Exported from Manimble. Compile with XeLaTeX or LuaLaTeX to keep the deck's fonts (pdfLaTeX works too).
%% !TEX program = xelatex
\documentclass[{opts}]{beamer}
{geometry}\usepackage{tikz}
\usepackage{amsmath,amssymb}
\usepackage{iftex}
\iftutex
  \usepackage{fontspec}
  \newcommand{\mfont}[1]{\IfFontExistsTF{#1}{\fontspec{#1}}{}}
\else
  \newcommand{\mfont}[1]{}
\fi
\setbeamertemplate{navigation symbols}{}
\graphicspath{{{figs}/}}
% each slide is drawn at absolute positions in bp from the top-left corner of the page
\newcommand{\slidecanvas}[1]{\begin{tikzpicture}[remember picture,overlay,x=1bp,y=-1bp,shift={(current page.north west)}]#1\end{tikzpicture}}
\begin{document}
"""


def build_beamer(app, path: str, builds: bool = True, editable: bool = True, progress=None) -> dict:
    out = Path(path)
    figs_name = out.stem + "-figures"
    figs = out.parent / figs_name
    figs.mkdir(parents=True, exist_ok=True)
    copied: dict[str, str] = {}

    def fig(src: str, stem: str) -> str:
        """Copy a frame picture next to the .tex once and return its name there."""
        if src not in copied:
            name = f"{stem}{Path(src).suffix}"
            shutil.copyfile(src, figs / name)
            copied[src] = name
        return copied[src]

    scenes = app.visible_scenes()
    total = len(scenes)
    frames: list[str] = []
    W = H = None
    for si, s in enumerate(scenes, start=1):
        if progress:
            progress(si - 1, total, s["name"])
        sc = app.api_scene(s["name"])
        if sc.get("status") != "ready":
            return {"ok": False, "error": f"{s['name']} does not render: {str(sc.get('error', ''))[-300:]}"}
        pw, ph = sc["size"]
        fw = sc["frame"][0]
        if W is None:
            W = 453.543                                     # Beamer's 160 mm wide page, in bp
            H = W * ph / pw
        k = W / pw                                          # bp per frame pixel
        bp_per_unit = W / fw
        stops = sc["stops"] if builds else sc["stops"][-1:]
        body: list[str] = []
        for bi, st in enumerate(stops, start=1):
            items: list[str] = []
            if not editable:
                f_png = fig(st["png"], f"s{si:02d}-b{bi}")
                items.append(rf"\node[anchor=north west,inner sep=0] at (0,0) "
                             rf"{{\includegraphics[width={_bp(W)}bp,height={_bp(H)}bp]{{{f_png}}}}};")
                for x0, x1, y0, y1, url in app._stop_links(sc, st):
                    items.append(rf"\node[anchor=north west,inner sep=0] at ({_bp(x0 * W)},{_bp(y0 * H)}) "
                                 rf"{{\href{{{_url(url)}}}{{\makebox[{_bp((x1 - x0) * W)}bp][l]{{\rule{{0pt}}{{{_bp((y1 - y0) * H)}bp}}}}}}}};")
            else:
                f_bg = fig(st["bg"], f"s{si:02d}-b{bi}-bg")
                items.append(rf"\node[anchor=north west,inner sep=0] at (0,0) "
                             rf"{{\includegraphics[width={_bp(W)}bp,height={_bp(H)}bp]{{{f_bg}}}}};")
                vis = {int(v[0]): v for v in st["visible"]}
                for sp in st["sprites"]:
                    oid = sp["oid"]
                    obj = sc["objects"].get(str(oid), {})
                    v = vis.get(oid)
                    fmt = obj.get("format") or {}
                    url = fmt.get("link")
                    kind = obj.get("kind")
                    if kind in ("text", "tex") and v is not None and obj.get("value"):
                        x0, y0, x1, y1 = v[1:5]
                        cx, cy = (x0 + x1) / 2 * k, (y0 + y1) / 2 * k
                        fs = obj.get("fontSize") or (30 if kind == "text" else 48)
                        em = TEXT_EM_PER_FONT_SIZE if kind == "text" else MATH_EM_PER_FONT_SIZE
                        size = fs * em * bp_per_unit
                        c = (obj.get("color") or "#FFFFFF").lstrip("#").upper()
                        c = c if len(c) == 6 else "FFFFFF"
                        rot = obj.get("rotation") or 0
                        opts = "anchor=center,inner sep=0"
                        if abs(rot) > 0.05:
                            opts += f",rotate={_bp(rot)}"
                        style = rf"\fontsize{{{_bp(size)}}}{{{_bp(size * 1.2)}}}\selectfont\color[HTML]{{{c}}}"
                        if kind == "text":
                            align = fmt.get("align") or "center"
                            opts += f",align={align if align in ('left', 'right') else 'center'}"
                            if obj.get("font"):
                                style += rf"\mfont{{{obj['font']}}}"
                            if str(obj.get("weight") or "").upper() == "BOLD":
                                style += r"\bfseries"
                            if str(obj.get("slant") or "").upper() in ("ITALIC", "OBLIQUE"):
                                style += r"\itshape"
                            content = _styled_tex(str(obj["value"]), _text_ranges(app, obj))
                        else:
                            math = str(obj["value"]).strip()
                            content = (rf"$\begin{{aligned}}{math}\end{{aligned}}$" if ("\\\\" in math or "&" in math)
                                       else rf"$\displaystyle {math}$")
                        if url:
                            content = rf"\href{{{_url(url)}}}{{{content}}}"
                        items.append(rf"\node[{opts}] at ({_bp(cx)},{_bp(cy)}) {{{style}{content}}};")
                    else:
                        f_sp = fig(sp["file"], f"s{si:02d}-o{oid}-" + Path(sp["file"]).stem)
                        pic = (rf"\includegraphics[width={_bp(sp['w'] * k)}bp,height={_bp(sp['h'] * k)}bp]"
                               rf"{{{f_sp}}}")
                        if url:
                            pic = rf"\href{{{_url(url)}}}{{{pic}}}"
                        items.append(rf"\node[anchor=north west,inner sep=0] at ({_bp(sp['x'] * k)},{_bp(sp['y'] * k)}) {{{pic}}};")
            canvas = "\\slidecanvas{%\n    " + "\n    ".join(items) + "\n  }"
            body.append(f"  \\only<{bi}>{{{canvas}}}" if len(stops) > 1 else "  " + canvas)
        notes = ""
        try:
            n = app._notes_of(s["name"])
            if n.strip():
                notes = "\n  \\note{" + tex_escape(n.strip()).replace("\n\n", "\n\\par\n") + "}"
        except Exception:                                   # noqa: BLE001
            pass
        frames.append(f"% {s['name']}\n\\begin{{frame}}[plain]\n" + "\n".join(body) + notes + "\n\\end{frame}\n")

    if W is None:
        return {"ok": False, "error": "there are no slides to export"}
    ratio = W / H
    geometry = ""
    if abs(ratio - 16 / 9) < 0.01:
        opts = "aspectratio=169"
    elif abs(ratio - 4 / 3) < 0.01:
        opts = ""
    else:
        opts = "aspectratio=169"
        geometry = rf"\geometry{{papersize={{{_bp(W)}bp,{_bp(H)}bp}}}}" + "\n"
    head = PREAMBLE.replace("{opts}", opts).replace("{geometry}", geometry).replace("{figs}", figs_name)
    extra = deck_tex_preamble(Path(str(app.deck)))
    if extra:
        head = head.replace("\\begin{document}", "% the deck's TeX template additions (its formulas use them)\n"
                            + extra + "\n\\begin{document}")
    out.write_text(head + "\n".join(frames) + "\\end{document}\n", encoding="utf-8")
    r = {"ok": True, "path": str(out), "slides": len(frames)}
    pdf, err = compile_pdf(out)
    if pdf:
        r["pdf"] = pdf
    elif err:
        r["pdfError"] = err
    return r


def deck_tex_preamble(deck: Path) -> str:
    """What the deck adds to manim's TeX template (`add_to_preamble(...)` string literals in its .py files), so
    formulas exported as LaTeX keep their macros. Packages Beamer already loads are left out."""
    import ast
    out: list[str] = []
    for f in sorted(deck.glob("*.py")):
        try:
            tree = ast.parse(f.read_text(encoding="utf-8"))
        except (OSError, SyntaxError, ValueError):
            continue
        for node in ast.walk(tree):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "add_to_preamble" and node.args
                    and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
                for line in node.args[0].value.strip().split("\n"):
                    if line.strip() and line.strip() not in out and not re.fullmatch(
                            r"\\usepackage\{(xcolor|amsmath|amssymb|hyperref|graphicx)\}", line.strip()):
                        out.append(line.strip())
    return "\n".join(out)


def _latex_error(log: Path, output: str) -> str:
    """The first LaTeX error of a failed run (its `!` line and the source line it stopped at), for the user."""
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = output
    lines = text.split("\n")
    for k, ln in enumerate(lines):
        if ln.startswith("!"):
            ctx = lines[k + 1:k + 12]
            at = next((i for i, l in enumerate(ctx) if re.match(r"l\.\d+", l.strip())), None)
            msg = ln[1:].strip()
            if msg.startswith("Undefined control sequence") and at is not None:
                # TeX prints the context up to the offending command, so it is the last one before the l.N line
                cs = re.findall(r"\\[A-Za-z@]+", " ".join(ctx[:at]))
                if cs:
                    msg = msg.rstrip(".") + f": {cs[-1]}"
            where = ctx[at].strip() if at is not None else ""
            return (msg + (f" (at {where})" if where else ""))[:400]
    return (output.strip().split("\n")[-1] if output.strip() else "LaTeX stopped without saying why")[:400]


def compile_pdf(tex: Path) -> tuple[str | None, str | None]:
    """Typeset the .tex next to it with XeLaTeX (or pdfLaTeX) when one is installed; two runs place the
    `remember picture` canvases. (pdf path, None) on success; (None, error) when LaTeX fails; (None, None) when
    no LaTeX is installed (the .tex is the deliverable)."""
    engine = shutil.which("xelatex") or shutil.which("pdflatex")
    if engine is None:
        for d in ("/Library/TeX/texbin", str(Path.home() / "Library/TinyTeX/bin/universal-darwin")):
            for e in ("xelatex", "pdflatex"):
                if Path(d, e).exists():
                    engine = str(Path(d, e))
                    break
            if engine:
                break
    if engine is None:
        return None, None
    pdf = tex.with_suffix(".pdf")
    try:
        for _ in range(2):
            r = subprocess.run([engine, "-interaction=nonstopmode", "-halt-on-error", tex.name], cwd=tex.parent,
                               capture_output=True, timeout=300)
            if r.returncode != 0:
                pdf.unlink(missing_ok=True)            # a half-typeset PDF would pass for the deck
                return None, _latex_error(tex.with_suffix(".log"), (r.stdout or b"").decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        pdf.unlink(missing_ok=True)
        return None, f"{Path(engine).name} did not finish within 5 minutes"
    except OSError as exc:
        return None, f"{Path(engine).name} could not run ({exc})"
    return (str(pdf), None) if pdf.exists() else (None, f"{Path(engine).name} wrote no PDF")
