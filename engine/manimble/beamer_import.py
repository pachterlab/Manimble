"""Import a Beamer (LaTeX) presentation as a new Manim Slides deck.

Every frame becomes a scene class laid out the way Beamer's default theme lays it out (positions calibrated on
pdfLaTeX output, 11pt): the frame title top left, then the body centred vertically. Paragraphs become `Text(...)`
in Latin Modern Sans (Beamer's font; copied from the TeX installation into the deck), wrapped like LaTeX wraps them
and remembered as `# manimble box` widths; bold, italic, colours and typewriter text become t2w / t2s / t2c / t2f
ranges. itemize / enumerate / description become one Text per item with Beamer's triangles or numbers, display maths
`MathTex(...)` (the document's macros and maths packages go into the deck's TeX template), \\includegraphics an
`ImageMobject`. Overlays become builds: \\pause, <+->, \\item<n->, \\only / \\uncover / \\onslide<n->. Anything else
LaTeX draws (tikzpicture, tabular, ...) is typeset with the document's own preamble and placed as a picture.
Themes: the default look, and the "rounded + infolines" family (Madrid, Boadilla, CambridgeUS, AnnArbor, Rochester,
Warsaw, ...) with its title bar, ball bullets, rounded title page box and footline; \\setbeamercolor / \\setbeamerfont /
\\setbeamertemplate overrides of the frame title, footline and items are read. Positions were calibrated on compiled
decks (default theme with pdfLaTeX, Madrid with XeLaTeX), see MARGIN, TITLE_X and the Theme class."""

from __future__ import annotations

import datetime
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .importer import _num, _slug

TEXT = "#000000"
STRUCTURE = "#3333B3"          # the default theme's structure colour (RGB 51, 51, 179)
ALERT = "#FF0000"
EXAMPLE = "#008000"
MARGIN = 28.35                 # \beamer@leftmargin / rightmargin: 1 cm, in bp
TITLE_X = 8.5                  # frame title inset (0.3 cm)
MANIM_TEXT_EM = 72.0           # Text: 1 em = font_size / 72 units
MANIM_MATH_EM = 96.4           # MathTex: 1 em = font_size / 96.4 units

# LaTeX size commands at 11pt (Beamer's default); other base sizes scale these
SIZES_11 = {"tiny": 6, "scriptsize": 8, "footnotesize": 9, "small": 10, "normalsize": 10.95, "large": 12,
            "Large": 14.4, "LARGE": 17.28, "huge": 20.74, "Huge": 24.88}
# ... and their baseline skips (size11.clo), in pt
BASELINESKIP_11 = {"tiny": 7, "scriptsize": 9.5, "footnotesize": 11, "small": 12, "normalsize": 13.6, "large": 14,
                   "Large": 18, "LARGE": 22, "huge": 25, "Huge": 30}
PT = 72 / 72.27                # bp per pt
TEXTHEIGHT_INSET = 12.6        # \textheight = \paperheight - this (bp), measured at 16:9 and 4:3
ITEMSEP = 3 * PT               # beamer's \itemsep and \topsep at level 1
NO_OPS = {"strut", "selectfont", "relax", "noindent", "arraybackslash", "leavevmode", "nointerlineskip",
          "ignorespaces", "unskip", "frenchspacing", "nonfrenchspacing", "sloppy", "fussy", "clearpage", "newpage",
          "mathstrut", "indent", "displaystyle", "textstyle", "protect"}
ASPECTS = {"169": (160, 90), "1610": (160, 100), "149": (140, 90), "141": (148.5, 105), "54": (125, 100),
           "43": (128, 96), "32": (135, 90), "2013": (200, 130)}
MM = 72 / 25.4

XCOLORS = {"red": "#FF0000", "green": "#00FF00", "blue": "#0000FF", "black": "#000000", "white": "#FFFFFF",
           "gray": "#808080", "grey": "#808080", "darkgray": "#404040", "lightgray": "#BFBFBF", "cyan": "#00FFFF",
           "magenta": "#FF00FF", "yellow": "#FFFF00", "orange": "#FF8000", "purple": "#BF0040", "brown": "#BF8040",
           "violet": "#800080", "teal": "#008080", "olive": "#808000", "lime": "#BFFF00", "pink": "#FFBFBF",
           "structure": STRUCTURE, "alerted text": ALERT, "example text": EXAMPLE}

MATH_PACKAGES = {"amsmath", "amssymb", "amsfonts", "mathtools", "bm", "physics", "siunitx", "mathrsfs", "bbm",
                 "dsfont", "esint", "cancel", "xfrac", "nicefrac", "upgreek", "stmaryrd", "braket", "commath"}

MATH_ENVS = {"equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*",
             "eqnarray", "eqnarray*", "displaymath", "math", "flalign", "flalign*", "alignat", "alignat*"}
THEOREMS = {"theorem": "Theorem", "lemma": "Lemma", "corollary": "Corollary", "definition": "Definition",
            "definitions": "Definitions", "fact": "Fact", "proof": "Proof", "example": "Example",
            "examples": "Examples", "proposition": "Proposition", "remark": "Remark", "claim": "Claim"}
RELATIONS = set("=<>∈∉∋≤≥≠≈∼≃≅≡∝→←⇒⇐⇔↔⟺⟹↦⊂⊆⊃⊇+−±∓×÷·∪∩∧∨⊕⊗|")
VERBATIM = ("verbatim", "verbatim*", "lstlisting", "minted", "Verbatim", "semiverbatim")


# ------------------------------------------------------------------------------------------- LaTeX scanning

def strip_comments(s: str) -> str:
    out = []
    for line in s.split("\n"):
        m = re.search(r"(?<!\\)(?:\\\\)*%", line)
        if m:
            line = line[:m.end() - 1]
            out.append(line)
            out.append("\x00")                 # a comment eats the newline: no paragraph break comes from it
        else:
            out.append(line + "\n")
    return "".join(out).replace("\n\x00", "").replace("\x00", "")


def skip_ws(s: str, i: int) -> int:
    while i < len(s) and s[i] in " \t\n":
        i += 1
    return i


def balanced(s: str, i: int, open_: str = "{", close: str = "}") -> tuple[str, int]:
    """s[i] is `open_`: the text up to its matching `close` and the index after it."""
    depth, j = 0, i
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "{" or (c == open_ and open_ != "{" and depth == 0):
            depth += 1
        elif c == "}" or (c == close and close != "}" and depth == 1):
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
        j += 1
    return s[i + 1:], len(s)


def arg(s: str, i: int) -> tuple[str | None, int]:
    """A mandatory argument: {group}, \\command, or one character."""
    j = skip_ws(s, i)
    if j >= len(s):
        return None, i
    if s[j] == "{":
        return balanced(s, j)
    if s[j] == "\\":
        m = re.match(r"\\([A-Za-z@]+|.)", s[j:])
        return m.group(0), j + m.end()
    if s[j] in "}]":
        return None, i
    return s[j], j + 1


def opt(s: str, i: int) -> tuple[str | None, int]:
    j = skip_ws(s, i)
    if j < len(s) and s[j] == "[":
        depth, k = 0, j
        while k < len(s):
            if s[k] == "\\":
                k += 2
                continue
            if s[k] == "{":
                depth += 1
            elif s[k] == "}":
                depth -= 1
            elif s[k] == "]" and depth == 0:
                return s[j + 1:k], k + 1
            k += 1
    return None, i


def overlay(s: str, i: int) -> tuple[str | None, int]:
    j = skip_ws(s, i)
    if j < len(s) and s[j] == "<":
        k = s.find(">", j)
        if k > 0:
            return s[j + 1:k], k + 1
    return None, i


def env_end(s: str, i: int, name: str) -> tuple[str, int]:
    """Body of the environment `name` whose \\begin ends at i, and the index after its \\end."""
    pat = re.compile(r"\\(begin|end)\{" + re.escape(name) + r"\}")
    depth = 1
    for m in pat.finditer(s, i):
        depth += 1 if m.group(1) == "begin" else -1
        if depth == 0:
            return s[i:m.start()], m.end()
    return s[i:], len(s)


def overlay_start(spec: str | None, st: dict) -> int | None:
    """The first build (0-based) an overlay specification shows on; `+` takes the next build."""
    if not spec:
        return None
    spec = spec.strip().split(",")[0].split("|")[-1].strip()
    if spec.startswith("+"):
        b = st["next"]
        st["next"] = b + 1
        return b
    if spec.startswith("."):
        return max(0, st["next"] - 1)
    m = re.match(r"(\d+)", spec)
    if m:
        return int(m.group(1)) - 1
    return 0


# ------------------------------------------------------------------------------------- colours and sizes

class Colors:
    def __init__(self):
        self.named = dict(XCOLORS)

    def define(self, name: str, model: str, spec: str):
        try:
            model = model.strip()
            vals = [v.strip() for v in spec.split(",")]
            if model == "HTML":
                self.named[name] = "#" + spec.strip().upper()
            elif model == "RGB":
                self.named[name] = "#%02X%02X%02X" % tuple(int(float(v)) for v in vals[:3])
            elif model == "rgb":
                self.named[name] = "#%02X%02X%02X" % tuple(round(float(v) * 255) for v in vals[:3])
            elif model == "gray":
                g = round(float(vals[0]) * 255)
                self.named[name] = "#%02X%02X%02X" % (g, g, g)
            elif model == "cmyk":
                c, m, y, k = (float(v) for v in vals[:4])
                self.named[name] = "#%02X%02X%02X" % tuple(round(255 * (1 - x) * (1 - k)) for x in (c, m, y))
        except (ValueError, TypeError):
            pass

    def get(self, expr: str, model: str | None = None) -> str | None:
        expr = (expr or "").strip()
        if model:
            tmp = Colors()
            tmp.define("x", model, expr)
            return tmp.named.get("x")
        parts = expr.split("!")
        base = self.named.get(parts[0].strip())
        if base is None:
            return None
        rgb = [int(base[i:i + 2], 16) for i in (1, 3, 5)]
        k = 1
        while k < len(parts):
            try:
                pct = float(parts[k]) / 100
            except ValueError:
                return None
            other = self.named.get(parts[k + 1].strip(), "#FFFFFF") if k + 1 < len(parts) else "#FFFFFF"
            o = [int(other[i:i + 2], 16) for i in (1, 3, 5)]
            rgb = [round(a * pct + b * (1 - pct)) for a, b in zip(rgb, o)]
            k += 2
        return "#%02X%02X%02X" % tuple(rgb)


# ---------------------------------------------------------------------------------------------- themes

def mix(a: str, b: str, pct: float) -> str:
    """xcolor's a!pct!b."""
    ra = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    rb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02X%02X%02X" % tuple(round(x * pct / 100 + y * (1 - pct / 100)) for x, y in zip(ra, rb))


# presentation themes as (inner theme, outer theme, colour themes); only the parts the importer draws matter
PRESENTATION_THEMES = {
    "default": ("default", "default", []),
    "Madrid": ("rounded", "infolines", ["whale", "orchid"]),
    "Boadilla": ("rounded", "infolines", []),
    "AnnArbor": ("rounded", "infolines", ["wolverine"]),
    "CambridgeUS": ("rounded", "infolines", ["beaver"]),
    "Rochester": ("rounded", "default", ["whale", "orchid"]),
    "Warsaw": ("rounded", "shadow", ["whale", "orchid"]),
    "Copenhagen": ("rounded", "split", ["whale", "orchid"]),
    "Luebeck": ("rounded", "split", ["whale", "orchid"]),
    "Malmoe": ("rounded", "split", ["whale", "orchid"]),
    "Berlin": ("rounded", "miniframes", ["whale", "orchid"]),
    "Ilmenau": ("rounded", "miniframes", ["whale", "orchid"]),
    "Dresden": ("rounded", "miniframes", ["whale", "orchid"]),
    "Darmstadt": ("rounded", "smoothbars", ["whale", "orchid"]),
    "Frankfurt": ("rounded", "smoothbars", ["whale", "orchid"]),
    "Singapore": ("circles", "smoothbars", ["lily"]),
    "Szeged": ("rectangles", "smoothbars", ["lily"]),
    "Antibes": ("circles", "tree", ["whale", "orchid"]),
    "JuanLesPins": ("circles", "smoothtree", ["whale", "orchid"]),
    "Montpellier": ("default", "tree", ["lily"]),
    "Pittsburgh": ("default", "default", []),
    "Bergen": ("rectangles", "sidebar", []),
    "Berkeley": ("rectangles", "sidebar", ["whale", "orchid"]),
    "PaloAlto": ("rectangles", "sidebar", ["whale", "orchid"]),
    "Goettingen": ("rectangles", "sidebar", ["lily"]),
    "Marburg": ("rectangles", "sidebar", ["lily"]),
    "Hannover": ("rectangles", "sidebar", ["lily"]),
    "EastLansing": ("default", "default", ["beaver"]),
}
BAR_OUTER = {"infolines", "shadow", "split", "miniframes", "smoothbars", "tree", "smoothtree"}


class Theme:
    """What the importer draws of a Beamer theme: colours of the frame title (a bar when it has a background),
    the item shape, the rounded title page / blocks, the footline, the text margins and \\setbeamerfont sizes."""

    def __init__(self):
        self.structure = STRUCTURE
        self.text = TEXT
        self.frametitle_fg = STRUCTURE
        self.frametitle_bg: str | None = None
        self.items = "triangle"                   # triangle | ball | circle | square
        self.rounded = False                      # rounded inner theme: boxed title page, rounded blocks
        self.shadow = False
        self.footline: str = "none"               # none | infolines | page
        self.footline_src: str | None = None      # a custom \setbeamertemplate{footline}
        self.frametitle_src: str | None = None    # a custom \setbeamertemplate{frametitle}
        self.margin_l = MARGIN
        self.margin_r = MARGIN
        self.fonts: dict[str, dict] = {}          # \setbeamerfont: name -> {size, bold, italic}
        self.colors: dict[str, dict] = {}         # \setbeamercolor: name -> {fg, bg}
        self.block_title_bg: str | None = None
        self.block_title_fg = STRUCTURE
        self.block_body_bg: str | None = None
        self.frame_keys: dict[str, str] = {}      # \define@key{beamerframe}{key}{\def\macro{#1}}: key -> macro
        self.names: list[str] = []
        self.warnings: list[str] = []

    def apply_color_theme(self, name: str):
        s = self.structure
        if name == "whale":
            self.frametitle_fg, self.frametitle_bg = "#FFFFFF", s
            self.colors.setdefault("palette primary", {"fg": "#FFFFFF", "bg": s})
            self.colors.setdefault("palette secondary", {"fg": "#FFFFFF", "bg": mix(s, "#000000", 75)})
            self.colors.setdefault("palette tertiary", {"fg": "#FFFFFF", "bg": mix(s, "#000000", 50)})
        elif name == "orchid":
            self.block_title_bg, self.block_title_fg = mix(s, "#000000", 75), "#FFFFFF"
            self.block_body_bg = mix(mix(s, "#000000", 75), "#FFFFFF", 10)
        elif name == "beaver":
            self.structure = s = "#CC0000"
            self.frametitle_fg, self.frametitle_bg = s, None
            self.colors.setdefault("palette primary", {"fg": s, "bg": "#D9D9D9"})
            self.colors.setdefault("palette secondary", {"fg": s, "bg": "#E6E6E6"})
            self.colors.setdefault("palette tertiary", {"fg": "#FFFFFF", "bg": s})
            self.block_title_bg, self.block_title_fg = "#D9D9D9", s
        elif name == "seagull":
            self.structure = s = "#000000"
            self.frametitle_fg, self.frametitle_bg = "#000000", "#B3B3B3"
            self.colors.setdefault("palette primary", {"fg": "#000000", "bg": "#B3B3B3"})
            self.colors.setdefault("palette secondary", {"fg": "#000000", "bg": "#999999"})
            self.colors.setdefault("palette tertiary", {"fg": "#FFFFFF", "bg": "#808080"})
        elif name == "dove":
            self.structure = s = "#000000"
            self.frametitle_fg, self.frametitle_bg = "#000000", None
        elif name == "seahorse":
            self.frametitle_fg, self.frametitle_bg = "#000000", mix(s, "#FFFFFF", 20)
            self.colors.setdefault("palette primary", {"fg": "#000000", "bg": mix(s, "#FFFFFF", 20)})
            self.colors.setdefault("palette secondary", {"fg": "#000000", "bg": mix(s, "#FFFFFF", 30)})
            self.colors.setdefault("palette tertiary", {"fg": "#000000", "bg": mix(s, "#FFFFFF", 50)})
        elif name == "crane":
            self.structure = s = "#CC9933"
            self.frametitle_fg, self.frametitle_bg = "#000000", "#FFCC00"
            self.colors.setdefault("palette primary", {"fg": "#000000", "bg": "#FFCC00"})
            self.colors.setdefault("palette secondary", {"fg": "#000000", "bg": "#E6B800"})
            self.colors.setdefault("palette tertiary", {"fg": "#000000", "bg": "#E6A500"})
        elif name == "wolverine":
            self.structure = s = "#1A1AB3"
            self.frametitle_fg, self.frametitle_bg = "#000000", "#FFE199"
            self.colors.setdefault("palette primary", {"fg": "#000000", "bg": "#FFE199"})
            self.colors.setdefault("palette secondary", {"fg": "#000000", "bg": "#F7C545"})
            self.colors.setdefault("palette tertiary", {"fg": "#FFFFFF", "bg": "#B38F00"})
        elif name in ("lily", "rose", "dolphin", "albatross", "beetle", "fly", "monarca", "spruce", "sidebartab",
                      "structure", "default"):
            if name in ("dolphin", "albatross", "beetle", "fly", "monarca", "spruce"):
                self.warnings.append(f"the colour theme '{name}' is only approximated")
        else:
            self.warnings.append(f"the colour theme '{name}' is not known; the default colours are used")

    def apply_inner(self, name: str, opts: str):
        if name == "rounded":
            self.rounded, self.items = True, "ball"
            self.shadow = "shadow=true" in opts.replace(" ", "")
        elif name == "circles":
            self.items = "circle"
        elif name == "rectangles":
            self.items = "square"
        elif name == "inmargin":
            self.warnings.append("the 'inmargin' inner theme is not reproduced")

    def apply_outer(self, name: str):
        if name == "infolines":
            self.footline = "infolines"
            self.margin_l = self.margin_r = None               # 1em, resolved once the base size is known
        elif name in BAR_OUTER:
            self.footline = "infolines" if name in ("shadow", "split", "smoothbars") else "none"
            self.warnings.append(f"the '{name}' outer theme's headline is not reproduced")
        elif name == "sidebar":
            self.warnings.append("the 'sidebar' outer theme's sidebar is not reproduced")

    def apply_presentation(self, name: str):
        if name not in PRESENTATION_THEMES:
            self.warnings.append(f"the Beamer theme '{name}' is not known; frames use the default look")
            return
        inner, outer, colors = PRESENTATION_THEMES[name]
        self.apply_inner(inner, "shadow=true" if inner == "rounded" else "")
        self.apply_outer(outer)
        for c in colors:
            self.apply_color_theme(c)

    def font(self, name: str, default: str) -> dict:
        """{size name, bold, italic} of a beamer font, with `default` as its size when not set."""
        f = dict(self.fonts.get(name, {}))
        f.setdefault("size", default)
        return f

    def palette(self, name: str, fallback_fg: str, fallback_bg: str | None) -> tuple[str, str | None]:
        c = self.colors.get(name, {})
        return c.get("fg") or fallback_fg, c.get("bg", fallback_bg)


# -------------------------------------------------------------------------------------- inline text

GREEK = {n: c for n, c in zip(
    "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi pi rho sigma tau upsilon phi chi psi "
    "omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega varepsilon vartheta varphi varrho varsigma "
    "varpi".split(), "αβγδϵζηθικλμνξπρστυϕχψωΓΔΘΛΞΠΣΥΦΨΩεϑφϱςϖ")}
MATH_SYMS = dict(GREEK, **{
    "in": "∈", "notin": "∉", "ni": "∋", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠",
    "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡", "propto": "∝", "times": "×", "cdot": "·",
    "pm": "±", "mp": "∓", "div": "÷", "infty": "∞", "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←",
    "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "leftrightarrow": "↔", "iff": "⟺",
    "implies": "⟹", "mapsto": "↦", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪",
    "cap": "∩", "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃", "partial": "∂", "nabla": "∇",
    "sum": "∑", "prod": "∏", "int": "∫", "ell": "ℓ", "ldots": "…", "dots": "…", "cdots": "⋯", "prime": "′",
    "circ": "∘", "star": "⋆", "ast": "∗", "mid": "|", "vert": "|", "Vert": "‖", "|": "‖", "langle": "⟨",
    "rangle": "⟩", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "oplus": "⊕",
    "otimes": "⊗", "perp": "⊥", "parallel": "∥", "angle": "∠", "ll": "≪", "gg": "≫", "uparrow": "↑",
    "downarrow": "↓", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "top": "⊤", "bot": "⊥", "setminus": "∖",
    "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "{": "{", "}": "}", "%": "%", "$": "$", "#": "#",
    "&": "&", "_": "_", ",": "\u2009", ";": " ", ":": " ", "!": "", " ": " ", "quad": "\u2003",
    "qquad": "\u2003\u2003", "colon": ":", "lvert": "|", "rvert": "|", "bullet": "•", "dagger": "†",
    "degree": "°", "checkmark": "✓", "square": "□", "Box": "□", "triangle": "△", "dag": "†"})
MATH_OPS = {"log", "ln", "exp", "sin", "cos", "tan", "max", "min", "arg", "det", "lim", "Pr", "sup", "inf",
            "dim", "ker", "deg", "gcd", "sinh", "cosh", "tanh", "argmax", "argmin", "var", "Var", "Cov", "E"}
BB = {"R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "E": "𝔼", "1": "𝟙"}
SUP = dict(zip("0123456789+-=()niaeoxyjklmrstuvwbcdfghpABDEGHIJKLMNOPRTUVW",
               "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱᵃᵉᵒˣʸʲᵏˡᵐʳˢᵗᵘᵛʷᵇᶜᵈᶠᵍʰᵖᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ"))
SUP.update({"T": "ᵀ", "*": "*", "′": "′", "\u2032": "′"})
SUB = dict(zip("0123456789+-=()aeoxijklmnprstuvh", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₒₓᵢⱼₖₗₘₙₚᵣₛₜᵤᵥₕ"))
ACCENTS = {"hat": "\u0302", "bar": "\u0304", "overline": "\u0305", "tilde": "\u0303", "vec": "\u20d7",
           "dot": "\u0307", "ddot": "\u0308", "widehat": "\u0302", "widetilde": "\u0303"}


def math_unicode(s: str, macros: dict) -> list[tuple[str, bool]] | None:
    """Inline maths as (character, italic) pairs, or None when it needs real typesetting."""
    out: list[tuple[str, bool]] = []
    i = 0
    s = expand_macros(s, macros)

    def atom(j: int) -> tuple[list | None, int]:
        j = skip_ws(s, j)
        if j >= len(s):
            return None, j
        if s[j] == "{":
            inner, k = balanced(s, j)
            return math_unicode(inner, macros), k
        if s[j] == "\\":
            m = re.match(r"\\([A-Za-z]+|.)", s[j:])
            sub = math_unicode(m.group(0), macros)
            return sub, j + m.end()
        return [(s[j], s[j].isalpha())], j + 1

    while i < len(s):
        c = s[i]
        if c in " \t\n":
            i += 1
            continue
        if c in "^_":
            got, i = atom(i + 1)
            if got is None:
                return None
            table = SUP if c == "^" else SUB
            if not all(ch in table for ch, _ in got):
                return None
            out += [(table[ch], False) for ch, _ in got]
            continue
        if c == "{":
            inner, i = balanced(s, i)
            got = math_unicode(inner, macros)
            if got is None:
                return None
            out += got
            continue
        if c == "\\":
            m = re.match(r"\\([A-Za-z]+\*?|.)", s[i:])
            name = m.group(1)
            i += m.end()
            if name in MATH_SYMS:
                out += [(ch, False) for ch in MATH_SYMS[name]]
            elif name in MATH_OPS:
                out += [(ch, False) for ch in name]
            elif name in ("mathbb", "mathds", "mathbbm"):
                a, i = arg(s, i)
                if a is None or any(ch not in BB for ch in a):
                    return None
                out += [(BB[ch], False) for ch in a]
            elif name in ("mathrm", "text", "textrm", "textsf", "mathsf", "operatorname", "mathbf", "textbf",
                          "boldsymbol", "bm", "mbox", "mathit", "textit", "mathnormal", "emph", "texttt", "mathtt"):
                a, i = arg(s, i)
                got = math_unicode(a or "", macros) if name not in ("text", "textrm", "textsf", "mbox", "texttt",
                                                                     "textit", "textbf", "emph") else [(ch, False) for ch in a or ""]
                if got is None:
                    return None
                if name in ("mathrm", "operatorname", "mathsf", "mathtt"):
                    got = [(ch, False) for ch, _ in got]
                out += got
            elif name in ACCENTS:
                got, i = atom(i)
                if not got or len(got) != 1:
                    return None
                out += [got[0], (ACCENTS[name], False)]
            elif name == "sqrt":
                got, i = atom(i)
                if not got or len(got) > 2:
                    return None
                out += [("√", False)] + got
            elif name in ("frac", "tfrac", "dfrac"):
                a, i = atom(i)
                b, i = atom(i)
                if not a or not b or len(a) > 3 or len(b) > 3:
                    return None
                out += a + [("/", False)] + b
            elif name in ("left", "right", "big", "Big", "bigl", "bigr", "Bigl", "Bigr", "displaystyle",
                          "textstyle", "limits", "nolimits"):
                continue
            else:
                return None
            continue
        out.append((c, c.isalpha()))
        i += 1
    return out


def expand_macros(s: str, macros: dict, depth: int = 0) -> str:
    """Expand the document's \\newcommand macros (with #1..#9 arguments) a few levels deep."""
    if not macros or depth > 6 or "\\" not in s:
        return s
    out, i, changed = [], 0, False
    while i < len(s):
        if s[i] == "\\":
            m = re.match(r"\\([A-Za-z]+)", s[i:])
            if m and m.group(1) in macros:
                n, default, body = macros[m.group(1)]
                j = i + m.end()
                args = []
                if default is not None:
                    o, j2 = opt(s, j)
                    args.append(o if o is not None else default)
                    j = j2
                while len(args) < n:
                    a, j = arg(s, j)
                    args.append(a or "")
                rep = body
                for k, a in enumerate(args, start=1):
                    rep = rep.replace(f"#{k}", a)
                out.append(rep + (" " if not args and j < len(s) and s[j].isalpha() else ""))
                i, changed = j, True
                continue
            if m:
                out.append(m.group(0))
                i += m.end()
                continue
            out.append(s[i:i + 2])
            i += 2
            continue
        out.append(s[i])
        i += 1
    r = "".join(out)
    return expand_macros(r, macros, depth + 1) if changed else r


TEXT_SYMS = {"ldots": "…", "dots": "…", "textellipsis": "…", "LaTeX": "LaTeX", "TeX": "TeX", "ss": "ß", "o": "ø",
             "O": "Ø", "ae": "æ", "AE": "Æ", "oe": "œ", "aa": "å", "AA": "Å", "l": "ł", "L": "Ł", "S": "§", "P": "¶",
             "textbackslash": "\\", "textasciitilde": "~", "textasciicircum": "^", "textbullet": "•",
             "textendash": "–", "textemdash": "—", "textdegree": "°", "copyright": "©", "textregistered": "®",
             "texttrademark": "™", "dag": "†", "ddag": "‡", "pounds": "£", "euro": "€", "checkmark": "✓",
             "quad": "\u2003", "qquad": "\u2003\u2003", "enspace": "\u2002", "hfill": " ", "hspace": "",
             "textbar": "|", "textless": "<", "textgreater": ">", "slash": "/", "lq": "‘", "rq": "’", "i": "ı"}
COMBINING = {"'": "\u0301", "`": "\u0300", "^": "\u0302", '"': "\u0308", "~": "\u0303", "=": "\u0304", ".": "\u0307",
             "c": "\u0327", "v": "\u030c", "u": "\u0306", "H": "\u030b", "r": "\u030a", "k": "\u0328"}
DROP_WITH_ARG = {"label", "footnote", "footnotemark", "footnotetext", "index", "vspace", "vspace*", "hspace",
                 "hspace*", "phantom", "hphantom", "vphantom", "setlength", "addtolength", "setcounter",
                 "usebeamercolor", "usebeamerfont", "usebeamertemplate", "pgfimage", "rule", "addplot",
                 "setbeamercolor", "setbeamertemplate", "setbeamerfont", "nocite", "bibliographystyle"}
PASS_WITH_ARG = {"textrm", "textsf", "textnormal", "mbox", "hbox", "text", "textup", "textmd", "underline", "uline",
                 "textsc", "MakeUppercase", "MakeLowercase", "makebox", "fbox", "framebox", "parbox", "raisebox",
                 "resizebox", "scalebox", "visible", "uncover", "only", "onslide", "action", "invisible", "temporal",
                 "alt", "centerline", "ensuremath", "texorpdfstring", "emph", "textit", "textsl", "textbf",
                 "texttt", "alert", "structure", "small", "inst"}


class Inline:
    """Turns a LaTeX paragraph into styled characters: (char, style) with style = dict(b, i, c, tt, url, size)."""

    def __init__(self, colors: Colors, macros: dict, size_pt):
        self.colors, self.macros, self.size_pt = colors, macros, size_pt
        self.needs_math = False

    def run(self, s: str, style: dict) -> list[tuple[str, dict]]:
        out: list[tuple[str, dict]] = []
        style = dict(style)
        i = 0
        while i < len(s):
            c = s[i]
            if c == "\\":
                m = re.match(r"\\([A-Za-z@]+\*?|.)", s[i:])
                name = m.group(1)
                j = i + m.end()
                i = self.command(name, s, j, style, out)
                continue
            if c == "{":
                inner, i = balanced(s, i)
                out += self.run(inner, style)
                continue
            if c == "}":
                i += 1
                continue
            if c == "$" or (c == "\\" and s[i:i + 2] == "\\("):
                dbl = s[i:i + 2] == "$$"
                k = s.find("$$" if dbl else "$", i + (2 if dbl else 1))
                k = len(s) if k < 0 else k
                math = s[i + (2 if dbl else 1):k]
                i = k + (2 if dbl else 1)
                self.math(math, style, out)
                continue
            if c in " \t\n":
                if not (out and out[-1][0] in " \n"):
                    out.append((" ", dict(style)))
                i += 1
                continue
            if c == "~":
                out.append(("\u00a0", dict(style)))
                i += 1
                continue
            if s.startswith("---", i):
                out.append(("—", dict(style)))
                i += 3
                continue
            if s.startswith("--", i):
                out.append(("–", dict(style)))
                i += 2
                continue
            if s.startswith("``", i):
                out.append(("“", dict(style)))
                i += 2
                continue
            if s.startswith("''", i):
                out.append(("”", dict(style)))
                i += 2
                continue
            if c == "`":
                out.append(("‘", dict(style)))
                i += 1
                continue
            if c == "'" and not style.get("tt"):
                out.append(("’", dict(style)))
                i += 1
                continue
            if c == "&":
                out.append((" ", dict(style)))
                i += 1
                continue
            out.append((c, dict(style)))
            i += 1
        return out

    def math(self, math: str, style: dict, out: list):
        got = math_unicode(math, self.macros)
        if got is None:
            self.needs_math = True
            out.append(("\x01", dict(style, math=math)))
            return
        for k, (ch, it) in enumerate(got):
            ch = "−" if ch == "-" else ch
            spaced = ch in RELATIONS and 0 < k < len(got) - 1         # TeX's thick space around relations
            if spaced:
                out.append(("\u2005", dict(style)))
            out.append((ch, dict(style, i=style.get("i") or it)))
            if spaced:
                out.append(("\u2005", dict(style)))

    def command(self, name: str, s: str, j: int, style: dict, out: list) -> int:
        if name in ("(",):
            k = s.find("\\)", j)
            k = len(s) if k < 0 else k
            self.math(s[j:k], style, out)
            return k + 2
        if name in ("\\", "newline", "linebreak", "par"):
            _, j = opt(s, j)
            if name == "\\" and j < len(s) and s[j] == "*":
                j += 1
            _, j = opt(s, j)
            while out and out[-1][0] == " ":
                out.pop()
            out.append(("\n", dict(style)))
            return j
        if name in COMBINING:
            a, j = arg(s, j)
            a = a or ""
            if a.startswith("\\"):
                a = TEXT_SYMS.get(a[1:], "")
            out += [(a[:1] + COMBINING[name] + a[1:], dict(style))] if a else []
            return j
        if name in TEXT_SYMS:
            if name in ("hspace",):
                _, j = arg(s, j)
            out += [(ch, dict(style)) for ch in TEXT_SYMS[name]]
            if j < len(s) and s[j:j + 2] == "{}":
                j += 2
            return j
        if len(name) == 1 and not name.isalpha():
            out.append(({" ": " ", ",": "\u2009", ";": " ", ":": " ", "!": "", "-": "", "/": ""}.get(name, name),
                        dict(style)))
            return j
        if name == "today":
            out += [(ch, dict(style)) for ch in datetime.date.today().strftime("%B %-d, %Y")]
            return j
        if name in NO_OPS:
            return j
        if name == "fontsize":
            a, j = arg(s, j)
            b, j = arg(s, j)
            try:
                style["size"] = float(re.sub(r"[a-z]+", "", a or "")) * PT
                style["pitch"] = float(re.sub(r"[a-z]+", "", b or "")) * PT
            except ValueError:
                pass
            return j
        if name in ("newcommand", "renewcommand", "providecommand", "def", "setlength", "addtolength"):
            _, j = arg(s, j)
            _, j = opt(s, j)
            _, j = opt(s, j)
            _, j = arg(s, j)
            return j
        size = self.size_pt(name)
        if size is not None:
            style["size"] = size
            style.pop("pitch", None)
            return j
        if name in ("bfseries", "bf"):
            style["b"] = True
            return j
        if name in ("itshape", "it", "em", "slshape", "sl"):
            style["i"] = True
            return j
        if name in ("ttfamily", "tt"):
            style["tt"] = True
            return j
        if name in ("normalfont", "rmfamily", "sffamily", "upshape", "mdseries"):
            for k in ("b", "i", "tt") if name == "normalfont" else (("i",) if name == "upshape" else ()):
                style[k] = False
            return j
        if name == "color":
            model, j = opt(s, j)
            a, j = arg(s, j)
            col = self.colors.get(a or "", model)
            if col:
                style["c"] = col
            return j
        if name in ("textcolor", "colorbox"):
            model, j = opt(s, j)
            a, j = arg(s, j)
            body, j = arg(s, j)
            col = self.colors.get(a or "", model)
            out += self.run(body or "", dict(style, c=col) if col and name == "textcolor" else style)
            return j
        if name in ("href",):
            url, j = arg(s, j)
            body, j = arg(s, j)
            out += self.run(body or "", dict(style, url=(url or "").strip()))
            return j
        if name in ("url", "nolinkurl"):
            url, j = arg(s, j)
            out += [(ch, dict(style, tt=True, url=(url or "").strip())) for ch in (url or "")]
            return j
        if name in ("cite", "citep", "citet", "ref", "eqref", "pageref", "autoref", "cref"):
            _, j = opt(s, j)
            a, j = arg(s, j)
            out += [(ch, dict(style)) for ch in ("[" + (a or "") + "]" if name.startswith("cite") else "?")]
            return j
        if name in DROP_WITH_ARG:
            o, j = overlay(s, j)
            _, j = opt(s, j)
            _, j = arg(s, j)
            if name in ("rule", "setlength", "addtolength", "setcounter", "setbeamercolor", "setbeamertemplate",
                        "setbeamerfont", "usebeamertemplate"):
                _, j = arg(s, j)
            return j
        if name in ("alt", "temporal"):
            _, j = overlay(s, j)
            a, j = arg(s, j)
            _, j = arg(s, j)
            out += self.run(a or "", style)
            return j
        if name in PASS_WITH_ARG or True:
            # unknown commands keep the text of their first argument
            _, j = overlay(s, j)
            if name in ("makebox", "framebox", "parbox", "raisebox", "resizebox", "scalebox"):
                _, j = opt(s, j)
                _, j = opt(s, j)
                if name in ("parbox", "raisebox", "scalebox"):
                    _, j = arg(s, j)
                if name == "resizebox":
                    _, j = arg(s, j)
                    _, j = arg(s, j)
            k = skip_ws(s, j)
            if k < len(s) and s[k] == "{":
                body, j = balanced(s, k)
                st = dict(style)
                if name in ("textbf",):
                    st["b"] = True
                elif name in ("emph", "textit", "textsl"):
                    st["i"] = not style.get("i") if name == "emph" else True
                elif name == "texttt":
                    st["tt"] = True
                elif name == "alert":
                    st["c"] = ALERT
                elif name == "structure":
                    st["c"] = STRUCTURE
                elif name == "inst":
                    out += [(SUP.get(ch, ch), dict(style)) for ch in body]
                    return j
                elif name in ("MakeUppercase", "textsc"):
                    body = body.upper()
                out += self.run(body, st)
            return j
        return j


def plain(chars: list[tuple[str, dict]]) -> str:
    return "".join(c for c, _ in chars).strip()


# -------------------------------------------------------------------------------------------- the importer

class BeamerImport:
    def __init__(self, src: Path, dest: Path):
        self.src = src
        self.dest = dest
        self.deck = dest / "deck"
        self.assets = dest / "assets"
        self.warnings: list[str] = []
        self.colors = Colors()
        self.macros: dict = {}
        self.macro_src: list[str] = []
        self.math_pkgs: list[str] = []
        self.graphics_dirs: list[Path] = [src.parent]
        self.meta: dict = {}
        self.snippets: list[tuple[str, str]] = []           # (kind, latex) typeset in one batch
        self.snippet_out: dict[int, tuple[str, float, float]] = {}
        self.n_img = 0
        self.fonts: dict[str, Path | None] = {}
        self.pil: dict = {}
        self.widths: dict = {}
        self.verbs: list[str] = []
        self.theme = Theme()
        self.sans: str | None = None                        # \setsansfont / helvet family, if any
        self.cur_frame: dict = {}
        self.pdf_pages: list[str] | None = None             # text of the sibling PDF's pages (picture fallback)
        self.pdf_used: dict[int, int] = {}

    # ------------------------------------------------------------ preamble
    def read(self) -> tuple[str, str]:
        text = self.src.read_text(encoding="utf-8", errors="replace")
        text = self.inline_inputs(text, self.src.parent, 0)
        # verbatim bodies keep their % and braces
        def keep(m):
            self.verbs.append(m.group(2))
            return f"\\begin{{{m.group(1)}}}\\manimbleverb{{{len(self.verbs) - 1}}}\\end{{{m.group(1)}}}"
        text = re.sub(r"\\begin\{(" + "|".join(re.escape(v) for v in VERBATIM) + r")\}(?:\[[^\]]*\]|\{[^}]*\})*(.*?)\\end\{\1\}",
                      keep, text, flags=re.S)
        text = strip_comments(text)
        m = re.search(r"\\begin\{document\}", text)
        if not m:
            raise ValueError("this file has no \\begin{document}")
        end = text.find("\\end{document}", m.end())
        return text[:m.start()], text[m.end(): end if end > 0 else len(text)]

    def inline_inputs(self, text: str, base: Path, depth: int) -> str:
        if depth > 4:
            return text

        def sub(m):
            name = m.group(2).strip()
            for cand in (base / name, base / (name + ".tex")):
                if cand.is_file():
                    return self.inline_inputs(cand.read_text(encoding="utf-8", errors="replace"), cand.parent, depth + 1)
            return ""
        return re.sub(r"(?<!\\)\\(input|include)\{([^}]*)\}", sub, text)

    # ------------------------------------------------------------ engine conditionals
    def resolve_conditionals(self, pre: str) -> str:
        """\\ifPDFTeX / \\ifXeTeX / \\ifLuaTeX ... \\else ... \\fi and \\IfFontExistsTF{font}{yes}{no}, decided the
        way the document is most likely compiled (XeLaTeX when it loads fontspec) and by the fonts installed here."""
        xe = bool(re.search(r"\\usepackage\s*(?:\[[^\]]*\])?\{[^}]*fontspec", pre))
        truth = {"ifPDFTeX": not xe, "ifpdftex": not xe, "ifpdf": not xe, "ifXeTeX": xe, "ifxetex": xe,
                 "ifLuaTeX": False, "ifluatex": False, "ifTUTeX": xe, "ifLuaHBTeX": False}
        pat = re.compile(r"\\(if[A-Za-z@]*|else|fi)(?![A-Za-z@])")
        out, i = [], 0
        while True:
            m = pat.search(pre, i)
            if not m:
                out.append(pre[i:])
                break
            name = m.group(1)
            if name not in truth:
                out.append(pre[i:m.end()])
                i = m.end()
                continue
            out.append(pre[i:m.start()])
            # find the matching \else / \fi
            depth, j, branch_true, branch_false, cur = 0, m.end(), [], None, None
            cur = branch_true
            k = j
            while True:
                mm = pat.search(pre, k)
                if not mm:
                    cur.append(pre[k:])
                    k = len(pre)
                    break
                tok = mm.group(1)
                if tok.startswith("if"):
                    depth += 1
                    cur.append(pre[k:mm.end()])
                elif tok == "else" and depth == 0:
                    cur.append(pre[k:mm.start()])
                    branch_false = []
                    cur = branch_false
                elif tok == "fi" and depth == 0:
                    cur.append(pre[k:mm.start()])
                    k = mm.end()
                    break
                else:
                    if tok == "fi":
                        depth -= 1
                    cur.append(pre[k:mm.end()])
                k = mm.end()
            chosen = branch_true if truth[name] else (branch_false or [])
            out.append("".join(chosen))
            i = k
        pre = "".join(out)

        def font_exists(m):
            name = m.group(1).strip()
            yes, k = balanced(pre, m.end() - 1)
            no, k2 = balanced(pre, skip_ws(pre, k))
            from .importer import _font
            ok = _font(name, False, False) is not None or name.lower() in {f.lower() for f in pango_fonts()}
            # a fallback font that ships with TeX (TeX Gyre, Latin Modern) is what a standard TeX build uses
            # and can travel with the deck, so it wins over a font that merely happens to be installed here
            fb = re.search(r"\\set(?:sans|main)font\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}", no)
            if ok and fb and self.tex_fonts({"r": re.sub(r"\s+", "", fb.group(1).lower()).removesuffix(".otf") + "-regular.otf"}).get("r"):
                self.warnings.append(f"the document uses '{name}' when it is installed and {fb.group(1).strip()} otherwise; "
                                     f"the deck uses the latter (it ships with TeX and travels with the deck)")
                ok = False
            return (yes if ok else no) + "\x02" + str(k2 - m.start())
        # \IfFontExistsTF{name}{yes}{no}: rebuild by hand because the branches nest braces
        while True:
            m = re.search(r"\\IfFontExistsTF\s*\{([^}]*)\}\s*\{", pre)
            if not m:
                break
            rep = font_exists(m)
            body, n = rep.rsplit("\x02", 1)
            pre = pre[:m.start()] + body + pre[m.start() + int(n):]
        return pre

    def preamble(self, pre: str):
        self.preamble_src = pre                               # as written, for LaTeX
        pre = self.resolve_conditionals(pre)
        m = re.search(r"\\documentclass\s*(?:\[([^\]]*)\])?\s*\{([^}]*)\}", pre)
        opts = [o.strip() for o in (m.group(1) or "").split(",")] if m else []
        if m and m.group(2).strip() != "beamer":
            self.warnings.append(f"the document class is {m.group(2).strip()}, not beamer; its frames are imported anyway")
        w_mm, h_mm = ASPECTS["43"]
        base = 11.0
        for o in opts:
            mm = re.fullmatch(r"aspectratio\s*=\s*(\d+)", o)
            if mm and mm.group(1) in ASPECTS:
                w_mm, h_mm = ASPECTS[mm.group(1)]
            mm = re.fullmatch(r"(\d+)pt", o)
            if mm:
                base = float(mm.group(1))
        self.W, self.H = w_mm * MM, h_mm * MM
        self.base = base
        self.u = 8.0 / self.H                               # manim units per bp
        self.FW = self.W * self.u
        for mm in re.finditer(r"\\(?:definecolor)\s*(?:\[[^\]]*\])?\{([^}]*)\}\{([^}]*)\}\{([^}]*)\}", pre):
            self.colors.define(mm.group(1).strip(), mm.group(2), mm.group(3))
        for mm in re.finditer(r"\\colorlet\{([^}]*)\}\{([^}]*)\}", pre):
            c = self.colors.get(mm.group(2))
            if c:
                self.colors.named[mm.group(1).strip()] = c
        for mm in re.finditer(r"\\graphicspath\s*\{((?:\{[^}]*\})+)\}", pre):
            for d in re.findall(r"\{([^}]*)\}", mm.group(1)):
                self.graphics_dirs.append((self.src.parent / d).resolve())
        for mm in re.finditer(r"\\usepackage\s*(?:\[[^\]]*\])?\{([^}]*)\}", pre):
            for p in mm.group(1).split(","):
                if p.strip() in MATH_PACKAGES and p.strip() not in self.math_pkgs:
                    self.math_pkgs.append(p.strip())
        self.read_theme(pre)
        # macros: \newcommand{\x}[n][default]{body}, \def\x{body}, \DeclareMathOperator{\x}{name}
        i = 0
        pat = re.compile(r"\\(newcommand|renewcommand|providecommand|DeclareMathOperator\*?|def|DeclareRobustCommand)\*?")
        while True:
            mm = pat.search(pre, i)
            if not mm:
                break
            j = mm.end()
            kind = mm.group(1)
            start = mm.start()
            if kind == "def":
                nm = re.match(r"\s*\\([A-Za-z@]+)((?:#\d)*)", pre[j:])
                if not nm:
                    i = j
                    continue
                j += nm.end()
                k = skip_ws(pre, j)
                if k >= len(pre) or pre[k] != "{":
                    i = j
                    continue
                body, j = balanced(pre, k)
                if "#" in body and not nm.group(2):          # \def inside \define@key etc.: not a macro of its own
                    i = j
                    continue
                self.macros[nm.group(1)] = (len(nm.group(2)) // 2, None, body)
            else:
                name, j = arg(pre, j)
                name = (name or "").strip().lstrip("\\")
                if kind.startswith("DeclareMathOperator"):
                    body, j = arg(pre, j)
                    self.macros[name] = (0, None, r"\operatorname{" + (body or "") + "}")
                else:
                    n, j = opt(pre, j)
                    default, j = opt(pre, j)
                    body, j = arg(pre, j)
                    try:
                        n = int(n) if n else 0
                    except ValueError:
                        n = 0
                    self.macros[name] = (n, default, body or "")
            self.macro_src.append(pre[start:j])
            i = j
        self.meta_short: dict = {}
        for key in ("title", "subtitle", "author", "institute", "date", "titlegraphic"):
            mm = re.search(r"\\" + key + r"\s*(?:\[([^\]]*)\])?\s*\{", pre)
            if mm:
                body, _ = balanced(pre, mm.end() - 1)
                self.meta[key] = body
                if mm.group(1) is not None:
                    self.meta_short[key] = mm.group(1)

    def read_theme(self, pre: str):
        """\\usetheme & co., \\setbeamercolor / font / template / size and frame keys, in document order."""
        th = self.theme
        pat = re.compile(r"\\(usetheme|usecolortheme|useinnertheme|useoutertheme|usefonttheme|setbeamercolor\*?|"
                         r"setbeamerfont\*?|setbeamertemplate|setbeamersize|define@key|setsansfont|setmainfont|"
                         r"usepackage)(?![A-Za-z@])")
        i = 0
        while True:
            m = pat.search(pre, i)
            if not m:
                break
            name, j = m.group(1).rstrip("*"), m.end()
            o, j = opt(pre, j)
            a, j = arg(pre, j)
            a = (a or "").strip()
            if name == "usetheme":
                for t in a.split(","):
                    th.apply_presentation(t.strip())
            elif name == "usecolortheme":
                for t in a.split(","):
                    th.apply_color_theme(t.strip())
            elif name == "useinnertheme":
                th.apply_inner(a, o or "")
            elif name == "useoutertheme":
                th.apply_outer(a)
            elif name == "usefonttheme":
                if a in ("serif",):
                    self.warnings.append("the serif font theme is not reproduced (sans-serif text is used)")
            elif name == "setbeamercolor":
                spec, j = arg(pre, j)
                d = th.colors.setdefault(a, {})
                for kv in re.split(r",(?![^{]*\})", spec or ""):
                    if "=" in kv:
                        k, v = (x.strip() for x in kv.split("=", 1))
                        if k in ("fg", "bg"):
                            v = v.strip("{}")
                            d[k] = self.colors.get(v.replace("structure.fg", "structure")) if v else None
                        elif k in ("parent", "use"):
                            for p in v.strip("{}").split(","):
                                d.update({kk: vv for kk, vv in th.colors.get(p.strip(), {}).items() if kk not in d})
                if a == "structure" and d.get("fg"):
                    th.structure = d["fg"]
                    if th.frametitle_fg == STRUCTURE:
                        th.frametitle_fg = d["fg"]
                    self.colors.named["structure"] = d["fg"]
                if a in ("frametitle", "titlelike"):
                    if "fg" in d:
                        th.frametitle_fg = d["fg"] or th.frametitle_fg
                    if "bg" in d:
                        th.frametitle_bg = d["bg"]
                if a == "block title":
                    th.block_title_fg = d.get("fg") or th.block_title_fg
                    th.block_title_bg = d.get("bg", th.block_title_bg)
                if a == "block body" and "bg" in d:
                    th.block_body_bg = d["bg"]
            elif name == "setbeamerfont":
                spec, j = arg(pre, j)
                f = th.fonts.setdefault(a, {})
                for kv in (spec or "").split(","):
                    if "=" in kv:
                        k, v = (x.strip() for x in kv.split("=", 1))
                        if k == "size":
                            mm = re.match(r"\\([A-Za-z]+)", v)
                            if mm and mm.group(1) in SIZES_11:
                                f["size"] = mm.group(1)
                            mm = re.match(r"\{?\s*([\d.]+)\s*\}?", v)
                            if mm and mm.group(1):
                                f["size"] = float(mm.group(1))
                        elif k == "series":
                            f["bold"] = "bf" in v
                        elif k == "shape":
                            f["italic"] = "it" in v or "sl" in v
            elif name == "setbeamertemplate":
                k = skip_ws(pre, j)
                if k < len(pre) and pre[k] == "{":
                    body, j = balanced(pre, k)
                    body = body.strip()
                else:
                    body = None
                    o2, j = opt(pre, j)                        # \setbeamertemplate{x}[variant]
                if a == "footline":
                    if body is not None:
                        th.footline = "none" if not body else "custom"
                        th.footline_src = body or None
                    elif o2 and "frame number" in o2:
                        th.footline = "page"
                elif a == "headline" and body is not None:
                    pass
                elif a == "frametitle" and body is not None:
                    th.frametitle_src = body or None
                elif a in ("itemize items", "itemize item", "items", "itemize subitem", "itemize subsubitem") and body is None:
                    if o2:
                        v = o2.strip()
                        if v in ("ball", "circle", "square", "triangle", "default"):
                            th.items = {"default": "triangle"}.get(v, v)
                elif a == "blocks" and body is None and o2:
                    th.rounded = th.rounded or "rounded" in o2
                    o3, j = opt(pre, j)
                    th.shadow = th.shadow or bool(o3 and "shadow=true" in o3.replace(" ", ""))
                elif a == "background canvas" and body is not None:
                    pass
            elif name == "setbeamersize":
                for kv in a.split(","):
                    if "=" in kv:
                        k, v = (x.strip() for x in kv.split("=", 1))
                        if k == "text margin left":
                            th.margin_l = self.length(v, {"width": self.W, "size": self.size("normalsize")})
                        elif k == "text margin right":
                            th.margin_r = self.length(v, {"width": self.W, "size": self.size("normalsize")})
            elif name == "define@key":
                key, j = arg(pre, j)
                body, j = arg(pre, j)
                mm = re.search(r"\\def\s*\\([A-Za-z@]+)\s*\{#1\}", body or "")
                if a == "beamerframe" and mm and key:
                    th.frame_keys[key.strip()] = mm.group(1)
            elif name in ("setsansfont", "setmainfont"):
                fam = a
                if o is None:
                    o, j = opt(pre, j)                         # \setsansfont{name}[options]
                if name == "setsansfont" or not self.sans:
                    self.sans = fam
                    self.sans_opts = o or ""
            elif name == "usepackage":
                if re.search(r"(^|,)\s*helvet\s*(,|$)", a):
                    self.sans = self.sans or "helvet"
            i = j
        for w in th.warnings:
            self.warnings.append(w)
        th.warnings.clear()
        self.colors.named["structure"] = th.structure
        if th.margin_l is None:
            th.margin_l = self.size("normalsize") * PT          # 1em (infolines)
        if th.margin_r is None:
            th.margin_r = self.size("normalsize") * PT

    # ------------------------------------------------------------ fonts and measuring
    def tex_fonts(self, files: dict[str, str]) -> dict[str, Path | None]:
        found: dict[str, Path | None] = {}
        kpse = find_tool("kpsewhich")
        if kpse:
            try:
                r = subprocess.run([kpse] + list(files.values()), capture_output=True, text=True, timeout=30)
                paths = [Path(p) for p in r.stdout.split()]
                for k, f in files.items():
                    found[k] = next((p for p in paths if p.name == f and p.is_file()), None)
            except (subprocess.TimeoutExpired, OSError):
                pass
        return found

    def setup_fonts(self):
        """The deck's text font: the document's \\setsansfont / helvet family when it is installed here or ships with
        TeX (TeX Gyre, Latin Modern: copied into assets/fonts), else Beamer's Latin Modern Sans."""
        lm = {"regular": "lmsans10-regular.otf", "bold": "lmsans10-bold.otf", "italic": "lmsans10-oblique.otf",
              "bolditalic": "lmsans10-boldoblique.otf"}
        mono = self.tex_fonts({"mono": "lmmono10-regular.otf"})
        found: dict[str, Path | None] = {}
        self.font = None
        self.font_bundled = False
        sans = (self.sans or "").strip()
        if sans:
            fam = sans
            if sans == "helvet":
                fam = "texgyreheros"
            stem = re.sub(r"\s+", "", fam.lower()).removesuffix(".otf")
            tgs = {"texgyreheros": "TeX Gyre Heros", "texgyreadventor": "TeX Gyre Adventor", "texgyretermes": "TeX Gyre Termes",
                   "texgyrepagella": "TeX Gyre Pagella", "texgyrebonum": "TeX Gyre Bonum", "texgyreschola": "TeX Gyre Schola",
                   "texgyrecursor": "TeX Gyre Cursor", "latinmodernsans": "Latin Modern Sans", "lmsans10": "Latin Modern Sans"}
            if stem in tgs or stem in ("helvetica", "arial") and sans == "helvet":
                if stem.startswith("texgyre"):
                    files = {k: f"{stem}-{s}.otf" for k, s in (("regular", "regular"), ("bold", "bold"),
                                                               ("italic", "italic"), ("bolditalic", "bolditalic"))}
                else:
                    files = lm
                found = self.tex_fonts(files)
                if found.get("regular"):
                    self.font, self.font_bundled = tgs[stem], True
            if self.font is None:
                from .importer import _font
                installed = {f.lower(): f for f in pango_fonts()}
                if fam.lower() in installed or _font(fam, False, False) is not None:
                    self.font = installed.get(fam.lower(), fam)
                elif sans == "helvet":
                    self.font = "Helvetica"
                else:
                    self.warnings.append(f"the document's font '{fam}' is not installed here; Latin Modern Sans is used")
        if self.font is None:
            found = self.tex_fonts(lm)
            self.font = "Latin Modern Sans" if found.get("regular") else "Helvetica Neue"
            self.font_bundled = bool(found.get("regular"))
            if not found.get("regular"):
                self.warnings.append("Latin Modern Sans (Beamer's font) was not found in a TeX installation; Helvetica Neue is used")
        found["mono"] = mono.get("mono")
        self.mono = "Latin Modern Mono" if found.get("mono") else "Menlo"
        fonts_dir = self.assets / "fonts"
        for k, p in found.items():
            if p:
                fonts_dir.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, fonts_dir / p.name)
        self.font_files = found

    def measure(self, text: str, st: dict) -> float:
        """Width in bp of text in style st (at st's size)."""
        from PIL import ImageFont
        key = "mono" if st.get("tt") else ("bold" if st.get("b") else "regular") + ("italic" if st.get("i") else "")
        key = {"regularitalic": "italic"}.get(key, key)
        if key not in self.pil:
            p = self.font_files.get(key) or self.font_files.get("regular")
            try:
                self.pil[key] = ImageFont.truetype(str(p), 1000) if p else None
            except Exception:                                # noqa: BLE001
                self.pil[key] = None
            if self.pil[key] is None:
                from .importer import _font_or_fallback
                self.pil[key] = _font_or_fallback(self.font if not st.get("tt") else "Menlo", bool(st.get("b")),
                                                  bool(st.get("i")))
        f = self.pil[key]
        size = st.get("size") or self.size("normalsize")
        if f is None:
            return 0.5 * size * len(text)
        ck = (key, text)
        if ck not in self.widths:
            self.widths[ck] = f.getlength(text) / 1000
        return self.widths[ck] * size

    def ink_top(self, text: str, st: dict) -> float:
        """How far the ink of a line reaches above its baseline, in bp."""
        f = self.pil.get("regular")
        size = st.get("size") or self.size("normalsize")
        if f is None or not text.strip():
            return 0.7 * size
        try:
            bb = f.getbbox(text, anchor="ls")
            return max(0.3 * size, -bb[1] / 1000 * size)
        except Exception:                                    # noqa: BLE001
            return 0.7 * size

    def size(self, name: str) -> float | None:
        if name not in SIZES_11:
            return None
        return SIZES_11[name] * self.base / 11

    def size_of(self, name: str, default: str) -> float:
        """Size in pt of a beamer font (\\setbeamerfont{name}{size=...}), `default` when not set."""
        f = self.theme.font(name, default)
        s = f["size"]
        return float(s) if not isinstance(s, str) else (self.size(s) or self.size(default))

    def pitch(self, size: float) -> float:
        """Baseline skip (bp) for a font size: LaTeX's table at this base size, 1.2 em otherwise."""
        for name, pt in SIZES_11.items():
            if abs(pt * self.base / 11 - size) < 0.05:
                return BASELINESKIP_11[name] * self.base / 11 * PT
        return 1.2 * size

    def textheight(self) -> float:
        return self.H - TEXTHEIGHT_INSET

    def ux(self, x: float) -> float:
        return x * self.u - self.FW / 2

    def uy(self, y: float) -> float:
        return 4.0 - y * self.u

    def fs_text(self, pt: float) -> float:
        return pt * self.u * MANIM_TEXT_EM

    def fs_math(self, pt: float) -> float:
        return pt * self.u * MANIM_MATH_EM

    # ------------------------------------------------------------ frames
    def frames(self, body: str) -> list[dict]:
        """The frames of the document, in order: {opts, title, subtitle, body}."""
        out = []
        i = 0
        pat = re.compile(r"\\begin\{frame\}|\\frame(?![A-Za-z])|\\(?:maketitle)(?![A-Za-z])|\\section\*?|\\againframe")
        sections: list[str] = []
        while True:
            m = pat.search(body, i)
            if not m:
                break
            tok = m.group(0)
            j = m.end()
            if tok.startswith("\\section"):
                _, j = opt(body, j)
                t, j = arg(body, j)
                sections.append(t or "")
                i = j
                continue
            if tok == "\\againframe":
                _, j = overlay(body, j)
                _, j = opt(body, j)
                _, j = arg(body, j)
                self.warnings.append("\\againframe is not imported")
                i = j
                continue
            if tok == "\\maketitle":
                out.append({"opts": "", "title": None, "subtitle": None, "body": "\\titlepage", "sections": list(sections)})
                i = j
                continue
            ov, j = overlay(body, j)
            o, j = opt(body, j)
            ov2, j = overlay(body, j)
            if tok == "\\frame":
                inner, j = arg(body, j)
                fr = {"opts": o or "", "title": None, "subtitle": None, "body": inner or ""}
            else:
                k = skip_ws(body, j)
                title = subtitle = None
                if k < len(body) and body[k] == "{":
                    title, j = balanced(body, k)
                    k = skip_ws(body, j)
                    if k < len(body) and body[k] == "{":
                        subtitle, j = balanced(body, k)
                inner, j = env_end(body, j, "frame")
                fr = {"opts": o or "", "title": title, "subtitle": subtitle, "body": inner}
            if (ov or ov2 or "") .strip() == "0":
                i = j
                continue
            fr["sections"] = list(sections)
            fr["keys"] = {}
            for kv in re.split(r",(?![^{]*\})", fr["opts"]):
                if "=" in kv:
                    k, v = (x.strip() for x in kv.split("=", 1))
                    fr["keys"][k] = v.strip("{}")
            out.append(fr)
            i = j
        return out

    # ------------------------------------------------------------ body parsing into blocks
    def blocks(self, s: str, st: dict, ctx: dict) -> list[dict]:
        """Block-level items of a frame body. st holds the overlay state {vis, next}; ctx {align, size}."""
        out: list[dict] = []
        buf: list[str] = []
        buf_build = [st["vis"]]

        def flush():
            text = "".join(buf)
            if text.strip():
                for para in re.split(r"\n[ \t]*\n", text):
                    if para.strip():
                        out.append({"t": "para", "src": para, "build": buf_build[0], "align": ctx["align"],
                                    "size": ctx["size"], "pitch": ctx.get("pitch"), "color": ctx.get("color"),
                                    "italic": ctx.get("italic")})
            buf.clear()
            buf_build[0] = st["vis"]

        def add(block):
            flush()
            out.append(block)

        i = 0
        while i < len(s):
            c = s[i]
            if c == "\n" and re.match(r"\n[ \t]*\n", s[i:]):
                flush()
                i = s.index("\n", i + 1) + 1
                continue
            if s.startswith("\\[", i) or s.startswith("$$", i):
                close = "\\]" if s.startswith("\\[", i) else "$$"
                k = s.find(close, i + 2)
                k = len(s) if k < 0 else k
                add({"t": "math", "src": s[i + 2:k], "build": st["vis"], "align": "center"})
                i = k + 2
                continue
            if c != "\\":
                if not buf:
                    buf_build[0] = st["vis"]
                buf.append(c)
                i += 1
                continue
            m = re.match(r"\\([A-Za-z@]+\*?)", s[i:])
            if not m:
                buf.append(s[i:i + 2])
                i += 2
                continue
            name = m.group(1)
            j = i + m.end()
            if name == "begin":
                env, j = arg(s, j)
                env = (env or "").strip()
                i = self.environment(env, s, j, st, ctx, add, out)
                continue
            if name == "pause":
                flush()
                _, j = opt(s, j)
                st["vis"] = max(st["vis"] + 1, st["next"])
                st["next"] = st["vis"]
                buf_build[0] = st["vis"]
                i = j
                continue
            if name == "par":
                flush()
                i = j
                continue
            if name in NO_OPS:
                i = j
                continue
            if name in ("newcommand", "renewcommand", "providecommand", "def", "setlength", "addtolength",
                        "setcounter", "setbeamercolor", "setbeamerfont", "setbeamertemplate", "usebeamercolor",
                        "usebeamerfont", "usebeamertemplate"):
                _, j = opt(s, j)
                _, j = arg(s, j)
                _, j = opt(s, j)
                _, j = opt(s, j)
                k = skip_ws(s, j)
                if name not in ("usebeamercolor", "usebeamerfont", "usebeamertemplate") and k < len(s) and s[k] == "{":
                    _, j = balanced(s, k)
                i = j
                continue
            if name == "fontsize" and not "".join(buf).strip():
                a, j = arg(s, j)
                b, j = arg(s, j)
                try:
                    ctx["size"] = float(re.sub(r"[a-z]+", "", a or "")) * PT
                    ctx["pitch"] = float(re.sub(r"[a-z]+", "", b or "")) * PT
                except ValueError:
                    pass
                i = j
                continue
            if name in ("frametitle", "framesubtitle"):
                _, j = overlay(s, j)
                _, j = opt(s, j)
                t, j = arg(s, j)
                ctx["frame"][name] = t
                i = j
                continue
            if name in ("titlepage", "maketitle"):
                add({"t": "titlepage", "build": st["vis"]})
                i = j
                continue
            if name == "tableofcontents":
                _, j = opt(s, j)
                secs = ctx["frame"].get("sections") or []
                add({"t": "list", "kind": "enumerate", "build": st["vis"], "items": [
                    {"label": None, "level": 1, "kind": "enumerate", "build": st["vis"],
                     "blocks": [{"t": "para", "src": sec, "build": st["vis"], "align": "left",
                                 "size": ctx["size"], "color": STRUCTURE}]} for sec in secs]})
                i = j
                continue
            if name == "includegraphics":
                ov, j = overlay(s, j)
                o, j = opt(s, j)
                f, j = arg(s, j)
                b = overlay_start(ov, st)
                add({"t": "image", "file": (f or "").strip(), "opts": o or "", "build": st["vis"] if b is None else b,
                     "align": ctx["align"], "width": ctx["width"]})
                i = j
                continue
            if name in ("only", "uncover", "onslide", "visible", "alt", "invisible", "temporal") and not "".join(buf).strip():
                ov, j = overlay(s, j)
                k = skip_ws(s, j)
                b = overlay_start(ov, st)
                if name == "invisible":
                    if k < len(s) and s[k] == "{":
                        _, j = balanced(s, k)
                    i = j
                    continue
                if k < len(s) and s[k] == "{":
                    inner, j = balanced(s, k)
                    if name in ("alt", "temporal"):
                        _, j = arg(s, j)
                        if name == "temporal":
                            _, j = arg(s, j)
                    if ov and ov.strip() and not ov.strip().endswith("-") and "+" not in ov:
                        if name == "only" or name == "alt":
                            self.warnings.append(f"\\{name}<{ov}> content stays on after its last overlay")
                    flush()
                    saved = st["vis"]
                    st["vis"] = saved if b is None else b
                    out += self.blocks(inner, st, ctx)
                    st["vis"] = saved
                    i = j
                    continue
                if name == "onslide":                       # \onslide<n-> without braces: from here on
                    flush()
                    if b is not None:
                        st["vis"] = b
                        buf_build[0] = b
                    i = j
                    continue
                i = j
                continue
            if name in ("vspace", "vspace*", "vskip"):
                if name == "vskip":
                    mm = re.match(r"\s*(-?[\d.]+\s*[a-z]{2})", s[j:])
                    amount = mm.group(1) if mm else "0pt"
                    j += mm.end() if mm else 0
                else:
                    a, j = arg(s, j)
                    amount = a or "0pt"
                add({"t": "vspace", "h": self.length(amount, ctx), "fill": "fill" in amount})
                i = j
                continue
            if name in ("bigskip", "medskip", "smallskip"):
                add({"t": "vspace", "h": {"bigskip": 12, "medskip": 6, "smallskip": 3}[name] * self.base / 11})
                i = j
                continue
            if name in ("centering", "raggedright", "raggedleft"):
                # inside a group that has not shown text yet ({\tiny\raggedright ...}) the alignment applies to
                # the paragraph being collected; otherwise it starts a new one
                sofar = re.sub(r"\\fontsize\s*\{[^}]*\}\s*\{[^}]*\}|\\\\\*?\s*(\[[^\]]*\])?", "", "".join(buf))
                if re.sub(r"\\[A-Za-z@]+\*?|[{}\s]", "", sofar):
                    flush()
                ctx["align"] = {"centering": "center", "raggedright": "left"}.get(name, "right")
                i = j
                continue
            if name == "note":
                _, j = overlay(s, j)
                _, j = opt(s, j)
                a, j = arg(s, j)
                ctx["frame"].setdefault("notes", []).append(a or "")
                i = j
                continue
            if name == "manimbleverb":
                a, j = arg(s, j)
                add({"t": "verb", "text": self.verbs[int(a)], "build": st["vis"]})
                i = j
                continue
            if name == "item":
                i = j        # handled by lists; a stray \item is text
                continue
            if name in SIZES_11 and not "".join(buf).strip():
                ctx["size"] = self.size(name)
                ctx.pop("pitch", None)
                i = j
                continue
            if name in ("caption",):
                _, j = opt(s, j)
                a, j = arg(s, j)
                add({"t": "para", "src": "\\structure{Figure:} " + (a or ""), "build": st["vis"], "align": "center",
                     "size": self.size("small"), "color": None})
                i = j
                continue
            if name in ("hfill",) and not "".join(buf).strip():
                i = j
                continue
            buf.append(s[i:j])
            i = j
        flush()
        return out

    def environment(self, env: str, s: str, j: int, st: dict, ctx: dict, add, out: list) -> int:
        body_start = j
        if env in VERBATIM:
            body, k = env_end(s, j, env)
            mm = re.search(r"\\manimbleverb\{(\d+)\}", body)
            if mm:
                add({"t": "verb", "text": self.verbs[int(mm.group(1))], "build": st["vis"]})
            return k
        if env in ("itemize", "enumerate", "description"):
            dflt, j = opt(s, j)
            ov_dflt = None
            if dflt and dflt.strip().startswith("<"):
                ov_dflt = dflt.strip()[1:-1]
            body, k = env_end(s, j, env)
            blk = {"t": "list", "kind": env, "items": self.list_items(body, env, st, ctx, ov_dflt), "build": st["vis"]}
            mm = re.search(r"\\setlength\s*\{\\itemsep\}\s*\{([^}]*)\}", re.split(r"\\item(?![A-Za-z])", body, 1)[0])
            if mm:                                          # \setlength{\itemsep}{..} inside the list
                blk["itemsep"] = self.length(mm.group(1), ctx)
            add(blk)
            return k
        if env in MATH_ENVS:
            body, k = env_end(s, j, env)
            if env.startswith("alignat"):
                _, body2 = arg(body, 0)
                body = body[body2:]
            add({"t": "math", "src": body, "env": env, "build": st["vis"], "align": "center"})
            return k
        if env in ("center", "flushleft", "flushright", "figure", "figure*", "table", "table*", "minipage",
                   "overlayarea", "overprint", "quote", "quotation", "small", "footnotesize", "scriptsize",
                   "large", "Large", "tiny", "onlyenv", "uncoverenv", "visibleenv", "actionenv", "altenv"):
            ov, j = overlay(s, j)
            _, j = opt(s, j)
            if env in ("minipage",):
                w, j = arg(s, j)
            elif env == "overlayarea":
                _, j = arg(s, j)
                _, j = arg(s, j)
            body, k = env_end(s, j, env)
            sub = dict(ctx)
            if env in ("center", "figure", "figure*", "table", "table*"):
                sub["align"] = "center"
            elif env == "flushright":
                sub["align"] = "right"
            elif env == "flushleft":
                sub["align"] = "left"
            if env in SIZES_11:
                sub["size"] = self.size(env)
            if env in ("quote", "quotation"):
                sub["indent"] = sub.get("indent", 0) + 2 * self.size("normalsize")
            saved = st["vis"]
            b = overlay_start(ov, st)
            if b is not None:
                st["vis"] = b
            inner = self.blocks(body, st, sub)
            st["vis"] = saved if b is not None else st["vis"]
            if env == "overprint":
                self.warnings.append("overprint areas show all their \\onslide parts at once")
            for blk in inner:
                add(blk)
            return k
        if env in ("block", "alertblock", "exampleblock") or env in THEOREMS:
            ov, j = overlay(s, j)
            title = None
            if env in ("block", "alertblock", "exampleblock"):
                title, j = arg(s, j)
            else:
                name, j = opt(s, j)
                title = THEOREMS[env] + (f" ({name})" if name else "")
            ov2, j = overlay(s, j)
            body, k = env_end(s, j, env)
            saved = st["vis"]
            b = overlay_start(ov or ov2, st)
            if b is not None:
                st["vis"] = b
            sub = dict(ctx, italic=env in ("theorem", "lemma", "corollary", "proposition", "claim", "fact"))
            add({"t": "block", "kind": env, "title": title, "build": st["vis"],
                 "blocks": self.blocks(body + (" \u220e" if env == "proof" else ""), st, sub)})
            if b is not None:
                st["vis"] = saved
            return k
        if env == "columns":
            o, j = opt(s, j)
            body, k = env_end(s, j, "columns")
            cols = []
            for mm in re.finditer(r"\\begin\{column\}", body):
                jj = mm.end()
                ov, jj = overlay(body, jj)
                copt, jj = opt(body, jj)
                w, jj = arg(body, jj)
                inner, _ = env_end(body, jj, "column")
                width = self.length(w or "0.5\\textwidth", ctx)
                saved = st["vis"]
                b = overlay_start(ov, st)
                if b is not None:
                    st["vis"] = b
                sub = dict(ctx, width=width, align="left")
                cols.append({"width": width, "valign": (copt or o or "c").strip()[:1],
                             "blocks": self.blocks(inner, st, sub)})
                st["vis"] = saved
            if not cols:                                    # \column{w} form
                parts = re.split(r"\\column\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}", body)
                for w, inner in zip(parts[1::2], parts[2::2]):
                    width = self.length(w, ctx)
                    cols.append({"width": width, "valign": (o or "c").strip()[:1],
                                 "blocks": self.blocks(inner, st, dict(ctx, width=width, align="left"))})
            copts = (o or "").replace(" ", "")
            tw = re.search(r"totalwidth=([^,\]]*)", copts)
            add({"t": "columns", "cols": cols, "build": st["vis"], "valign": (o or "c").strip()[:1],
                 "onlytextwidth": "onlytextwidth" in copts, "total": self.length(tw.group(1), ctx) if tw else None})
            return k
        # anything else LaTeX draws is typeset with the document's preamble and placed as a picture, at the
        # size in force here
        body, k = env_end(s, j, env)
        raw = f"\\begin{{{env}}}" + s[body_start:k]
        size = ctx.get("size")
        if size:
            name = next((n for n, pt in SIZES_11.items() if abs(pt * self.base / 11 - size) < 0.05), None)
            raw = ("\\" + name if name else f"\\fontsize{{{size / PT:.2f}}}{{{(ctx.get('pitch') or 1.2 * size) / PT:.2f}}}\\selectfont") + raw
        idx = len(self.snippets)
        self.snippets.append(("picture", raw))
        add({"t": "snippet", "idx": idx, "build": st["vis"], "align": ctx["align"], "env": env})
        return k

    def list_items(self, body: str, env: str, st: dict, ctx: dict, ov_dflt: str | None) -> list[dict]:
        # split at top-level \item
        cuts, depth, i = [], 0, 0
        while i < len(body):
            if body.startswith("\\begin{", i):
                depth += 1
            elif body.startswith("\\end{", i):
                depth -= 1
            elif body[i] == "{":
                depth += 1
                i += 1
                continue
            elif body[i] == "}":
                depth -= 1
                i += 1
                continue
            elif body[i] == "\\" and depth == 0 and re.match(r"\\item(?![A-Za-z])", body[i:]):
                cuts.append(i)
            if body[i] == "\\":
                i += 2
                continue
            i += 1
        items = []
        level = ctx.get("level", 0) + 1
        for n, a in enumerate(cuts):
            b = cuts[n + 1] if n + 1 < len(cuts) else len(body)
            j = a + len("\\item")
            ov, j = overlay(body, j)
            label, j = opt(body, j)
            ov2, j = overlay(body, j)
            spec = ov or ov2 or ov_dflt
            saved = st["vis"]
            start = overlay_start(spec, st)
            if start is not None:
                st["vis"] = start
            # level 1 keeps the surrounding size (beamer's "itemize/enumerate body" font is empty); deeper levels
            # are \small and \footnotesize whatever surrounds them
            sub = dict(ctx, level=level, align="left",
                       size=ctx["size"] if level == 1 else self.size(["small", "footnotesize"][min(level, 3) - 2]))
            if level > 1:
                sub.pop("pitch", None)
            build = st["vis"]
            blocks = self.blocks(body[j:b], st, sub)
            items.append({"label": label, "build": build, "blocks": blocks, "level": level, "kind": env})
            if start is not None:
                st["vis"] = saved
        return items

    def length(self, expr: str, ctx: dict) -> float:
        """A TeX length in bp (\\textwidth, \\linewidth, \\paperwidth, ... and absolute units)."""
        expr = (expr or "").strip().replace("\\dimexpr", "").replace("\\relax", "").strip()
        parts = re.split(r"(?<=[a-z}])\s*([+-])\s*(?=[\d.\\])", expr)      # "\paperwidth-.6cm": a sum of terms
        if len(parts) > 1:
            total, sign = 0.0, 1
            for p in parts:
                if p in ("+", "-"):
                    sign = 1 if p == "+" else -1
                else:
                    total += sign * self.length(p, ctx)
            return total
        m = re.fullmatch(r"(-?[\d.]*)\s*\\(textwidth|linewidth|columnwidth|hsize|paperwidth|textheight|paperheight)", expr)
        if m:
            f = float(m.group(1)) if m.group(1) not in ("", "-", ".") else 1.0
            ref = {"paperwidth": self.W, "textheight": self.textheight(), "paperheight": self.H}.get(m.group(2), ctx["width"])
            return f * ref
        m = re.fullmatch(r"(-?[\d.]+)\s*(pt|bp|cm|mm|in|em|ex|pc|sp)?(?:\s*plus.*)?", expr)
        if m:
            v = float(m.group(1))
            unit = m.group(2) or "pt"
            size = ctx.get("size") or self.size("normalsize")
            return v * {"pt": 72 / 72.27, "bp": 1, "cm": 72 / 2.54, "mm": MM, "in": 72, "em": size,
                        "ex": 0.45 * size, "pc": 12 * 72 / 72.27, "sp": 72 / 72.27 / 65536}[unit]
        if "fill" in expr:
            return 0.0
        return 0.0

    # ------------------------------------------------------------ snippets typeset by LaTeX
    def typeset_snippets(self):
        """Typeset every picture snippet (and every display formula, to measure it) in one LaTeX run with the
        document's preamble; crop each page to its ink. snippet_out[i] = (png name or "", width bp, height bp)."""
        if not self.snippets:
            return
        pre = self.preamble_src
        engine = "xelatex" if re.search(r"\\usepackage\s*(?:\[[^\]]*\])?\{[^}]*fontspec", pre) else "pdflatex"
        tex = find_tool(engine)
        ppm = find_tool("pdftoppm")
        if tex is None or ppm is None:
            self.warnings.append("LaTeX or pdftoppm was not found, so TikZ pictures and tables could not be imported")
            return
        pages = []
        for kind, src in self.snippets:
            if kind == "math":
                src = "$\\displaystyle " + src + "$" if "\\\\" not in src and "&" not in src else \
                      "$\\begin{aligned}" + src + "\\end{aligned}$"
            pages.append("\\begin{frame}[plain]\\centering\n" + src + "\n\\end{frame}")
        doc = (pre + "\n\\setbeamertemplate{background}{}\\setbeamercolor{background canvas}{bg=white}"
               "\\setbeamertemplate{navigation symbols}{}\n\\begin{document}\n" + "\n".join(pages) + "\n\\end{document}\n")
        work = Path(tempfile.mkdtemp(prefix="manimble-beamer-"))
        (work / "snippets.tex").write_text(doc, encoding="utf-8")
        try:
            subprocess.run([tex, "-interaction=nonstopmode", "-output-directory", str(work), str(work / "snippets.tex")],
                           cwd=self.src.parent, capture_output=True, timeout=600)
        except (subprocess.TimeoutExpired, OSError) as exc:
            self.warnings.append(f"LaTeX could not typeset the pictures ({exc})")
            return
        pdf = work / "snippets.pdf"
        if not pdf.exists():
            self.warnings.append("LaTeX could not typeset the TikZ pictures and tables (see the document's preamble)")
            return
        try:
            subprocess.run([ppm, "-r", "288", "-png", str(pdf), str(work / "p")], capture_output=True, timeout=600)
        except (subprocess.TimeoutExpired, OSError):
            return
        from PIL import Image, ImageChops
        pngs = sorted(work.glob("p-*.png"), key=lambda p: int(p.stem.split("-")[-1]))
        for idx, png in enumerate(pngs[:len(self.snippets)]):
            im = Image.open(png).convert("RGB")
            bbox = ImageChops.difference(im, Image.new("RGB", im.size, "white")).getbbox()
            if not bbox:
                self.snippet_out[idx] = ("", 0.0, 0.0)
                continue
            pad = 4
            bbox = (max(0, bbox[0] - pad), max(0, bbox[1] - pad), min(im.width, bbox[2] + pad), min(im.height, bbox[3] + pad))
            w_bp, h_bp = (bbox[2] - bbox[0]) / 4, (bbox[3] - bbox[1]) / 4
            if self.snippets[idx][0] == "math":
                self.snippet_out[idx] = ("", w_bp - 2, h_bp - 2)
                continue
            self.n_img += 1
            name = f"latex{self.n_img:02d}.png"
            im.crop(bbox).save(self.assets / name)
            self.snippet_out[idx] = (name, w_bp, h_bp)
        shutil.rmtree(work, ignore_errors=True)

    def collect_math(self, blocks: list[dict]):
        """Queue every display formula for measuring."""
        for b in blocks:
            if b["t"] == "math":
                b["idx"] = len(self.snippets)
                self.snippets.append(("math", self.clean_math(b["src"], b.get("env"))))
            for sub in b.get("blocks", []):
                self.collect_math([sub])
            for it in b.get("items", []):
                self.collect_math(it["blocks"])
            for col in b.get("cols", []):
                self.collect_math(col["blocks"])

    @staticmethod
    def clean_math(src: str, env: str | None) -> str:
        s = re.sub(r"\\(label|tag)\s*\{[^}]*\}", "", src)
        s = re.sub(r"\\(nonumber|notag)\b", "", s).strip()
        if env and env.startswith(("gather", "multline")):
            s = "\\begin{gathered}" + s + "\\end{gathered}"
        if env and env.startswith("eqnarray"):
            s = s.replace("&", "", 1) if s.count("&") == 1 else s
        return s

    # ------------------------------------------------------------ images
    def image(self, file: str) -> tuple[str, float, float] | None:
        """Copy an \\includegraphics file into assets (PDF/EPS rasterised); (name, natural width bp, height bp)."""
        cands = []
        for d in self.graphics_dirs:
            p = d / file
            cands += [p] if p.suffix else [p.with_name(p.name + e) for e in (".png", ".pdf", ".jpg", ".jpeg", ".eps")]
        p = next((c for c in cands if c.is_file()), None)
        if p is None:
            got = self.image_from_pdf(file)
            if got:
                return got
            self.warnings.append(f"the picture {file} was not found")
            return None
        from PIL import Image
        self.n_img += 1
        if p.suffix.lower() in (".pdf", ".eps", ".ps"):
            ppm = find_tool("pdftoppm")
            name = f"img{self.n_img:02d}_{_slug(p.stem, 'image')}.png"
            src_pdf = p
            if p.suffix.lower() != ".pdf":
                conv = find_tool("epstopdf") or find_tool("ps2pdf")
                if conv is None:
                    self.warnings.append(f"{p.name} is EPS and no epstopdf was found")
                    return None
                tmp = Path(tempfile.mkdtemp()) / (p.stem + ".pdf")
                subprocess.run([conv, str(p), str(tmp)] if "ps2pdf" in conv else [conv, str(p), f"--outfile={tmp}"],
                               capture_output=True, timeout=120)
                src_pdf = tmp
            if ppm:
                subprocess.run([ppm, "-r", "200", "-png", "-singlefile", str(src_pdf), str(self.assets / Path(name).stem)],
                               capture_output=True, timeout=120)
            else:
                subprocess.run(["sips", "-s", "format", "png", str(src_pdf), "--out", str(self.assets / name)],
                               capture_output=True, timeout=120)
            if not (self.assets / name).exists():
                self.warnings.append(f"{p.name} could not be converted to a picture")
                return None
            w, h = Image.open(self.assets / name).size
            return name, w * 72 / 200, h * 72 / 200
        name = f"img{self.n_img:02d}_{_slug(p.stem, 'image')}{p.suffix.lower()}"
        shutil.copyfile(p, self.assets / name)
        try:
            im = Image.open(p)
            dpi = im.info.get("dpi", (72, 72))[0] or 72
            return name, im.width * 72 / dpi, im.height * 72 / dpi
        except Exception:                                    # noqa: BLE001
            return name, 200.0, 150.0

    def image_from_pdf(self, file: str) -> tuple[str, float, float] | None:
        """A picture whose file is missing, taken from a compiled PDF next to the .tex (same stem): the page whose
        text holds this frame's title, and on it the k-th picture for the frame's k-th \\includegraphics."""
        pdf = self.src.with_suffix(".pdf")
        title = plain(self.styled(self.cur_frame.get("title") or "", 10, None)[0])
        pdfimages, pdftotext = find_tool("pdfimages"), find_tool("pdftotext")
        if not pdf.is_file() or not title or not pdfimages or not pdftotext:
            return None
        if self.pdf_pages is None:
            try:
                r = subprocess.run([pdftotext, "-layout", str(pdf), "-"], capture_output=True, text=True, timeout=120)
                self.pdf_pages = r.stdout.split("\f")
            except (subprocess.TimeoutExpired, OSError):
                self.pdf_pages = []
        if not hasattr(self, "pdf_rows"):
            try:
                r = subprocess.run([pdfimages, "-list", str(pdf)], capture_output=True, text=True, timeout=120)
                self.pdf_rows = [ln.split() for ln in r.stdout.splitlines()[2:]]
            except (subprocess.TimeoutExpired, OSError):
                self.pdf_rows = []
        norm = lambda s: re.sub(r"\s+", " ", s).strip().lower()           # noqa: E731
        want = norm(title)[:60]
        k = self.cur_frame.get("n_images", 0)
        self.cur_frame["n_images"] = k + 1
        # the first page (from the last one used) whose text holds the title and that has enough pictures
        start = self.cur_frame.get("pdf_page", self.pdf_used.get("last", 0))
        page, imgs, rows = None, [], []
        for i in range(start, len(self.pdf_pages)):
            if want in norm(self.pdf_pages[i]):
                rows = [row for row in self.pdf_rows if len(row) > 12 and row[0] == str(i + 1)]
                imgs = [row for row in rows if row[2] == "image"]
                if k < len(imgs):
                    page = i
                    break
        if page is None:
            return None
        self.cur_frame["pdf_page"] = page
        self.pdf_used["last"] = page
        row = imgs[k]
        pos, ppi = rows.index(row), float(row[12]) or 72.0        # pdfimages numbers the files of one run from 0
        work = Path(tempfile.mkdtemp(prefix="manimble-pdfimg-"))
        try:
            subprocess.run([pdfimages, "-png", "-f", str(page + 1), "-l", str(page + 1), str(pdf), str(work / "i")],
                           capture_output=True, timeout=120)
        except (subprocess.TimeoutExpired, OSError):
            return None
        src = work / f"i-{pos:03d}.png"
        if not src.is_file():
            return None
        from PIL import Image
        im = Image.open(src).convert("RGBA")
        mask = work / f"i-{pos + 1:03d}.png"
        if pos + 1 < len(rows) and rows[pos + 1][2] == "smask" and mask.is_file():
            try:
                im.putalpha(Image.open(mask).convert("L").resize(im.size))
            except Exception:                                   # noqa: BLE001
                pass
        self.n_img += 1
        name = f"img{self.n_img:02d}_{_slug(Path(file).stem, 'image')}.png"
        im.save(self.assets / name)
        shutil.rmtree(work, ignore_errors=True)
        self.warnings.append(f"the picture {file} was not found; a copy was taken from {pdf.name} (page {page + 1})")
        return name, im.width * 72 / ppi, im.height * 72 / ppi

    # ------------------------------------------------------------ layout
    def layout(self, blocks: list[dict], x0: float, x1: float, y: float, placed: list, ctx: dict) -> float:
        """Place blocks top-down from y (bp) between x0 and x1; append placed items; return the new y.
        y is the bottom of the previous line box (its baseline + 0.3 of the baseline skip), so consecutive lines
        sit one baseline skip apart; lists and pictures add LaTeX's \\topsep (3pt) above and below."""
        prev = None
        for b in blocks:
            t = b["t"]
            if t == "vspace":
                y += b["h"]
                continue
            if prev is not None and prev in ("para", "verb") and t in ("list", "block", "math"):
                y += ITEMSEP * self.base / 11
            if t == "para":
                y = self.place_para(b, x0, x1, y, placed, ctx)
            elif t == "verb":
                y = self.place_verb(b, x0, y, placed)
            elif t == "list":
                y = self.place_list(b, x0, x1, y, placed, ctx)
            elif t == "math":
                y = self.place_math(b, x0, x1, y, placed)
            elif t in ("image", "snippet"):
                y = self.place_picture(b, x0, x1, y, placed)
            elif t == "block":
                y = self.place_block(b, x0, x1, y, placed, ctx)
            elif t == "columns":
                y = self.place_columns(b, x0, x1, y, placed, ctx)
            elif t == "titlepage":
                self.place_titlepage(b, placed)
            prev = t
        return y

    def styled(self, src: str, size: float, color: str | None, italic=False) -> tuple[list, bool]:
        inl = Inline(self.colors, self.macros, self.size)
        chars = inl.run(expand_macros(src, self.macros), {"b": False, "i": bool(italic), "c": color or TEXT,
                                                          "tt": False, "url": None, "size": size})
        while chars and chars[0][0] in " \n":
            chars.pop(0)
        while chars and chars[-1][0] in " \n":
            chars.pop()
        return chars, inl.needs_math

    def wrap(self, chars: list, width: float) -> list[list]:
        """Greedy wrap into lines of styled characters; hard breaks stay."""
        lines, cur, i = [], [], 0
        words: list[list] = []
        w: list = []
        for ch in chars:
            if ch[0] == "\n":
                if w:
                    words.append(w)
                words.append([ch])
                w = []
            elif ch[0] == " ":
                w.append(ch)
                words.append(w)
                w = []
            else:
                w.append(ch)
        if w:
            words.append(w)

        def width_of(seq):
            total = 0.0
            for c, st in seq:
                total += self.measure(c, st) if c != "\x01" else self.math_width(st["math"], st)
            return total

        cur_w, shrink = 0.0, 0.0
        for wd in words:
            if wd[0][0] == "\n":
                lines.append(cur)
                cur, cur_w, shrink = [], 0.0, 0.0
                continue
            ww = width_of([c for c in wd if c[0] != " "])
            # TeX justifies: every inter-word space may shrink by a third of its width. Text() cannot, so only
            # a small overrun (2% of the width) is allowed to keep LaTeX's line breaks
            if cur and cur_w + ww > width + 0.5 + min(shrink, 0.02 * width):
                lines.append(cur)
                cur, cur_w, shrink = [], 0.0, 0.0
            cur = cur + wd
            cur_w += width_of(wd)
            if wd and wd[-1][0] == " ":
                shrink += self.measure(" ", wd[-1][1]) / 3
        if cur:
            lines.append(cur)
        return [ln for ln in lines] or [[]]

    def math_width(self, math: str, st: dict) -> float:
        return 0.55 * (st.get("size") or self.size("normalsize")) * max(1, len(re.sub(r"\\[A-Za-z]+|[{}^_ ]", "x", math)) * 0.8)

    def text_code(self, lines: list[list], size: float, align: str, box_w: float | None, pitch: float | None = None,
                  font: str = "FONT") -> tuple[str, str]:
        """Text(...) call for wrapped styled lines (soft breaks are ' \\n'), and its trailing comment."""
        text_parts, styles = [], []
        for k, ln in enumerate(lines):
            while ln and ln[-1][0] == " ":
                ln = ln[:-1]
            if k:
                text_parts.append(" \n")
                styles += [styles[-1] if styles else {}] * 2
            for c, st in ln:
                text_parts.append(c)
                styles += [st] * len(c)
        text = "".join(text_parts)
        chars = [s for s in styles]
        colors = [s.get("c") or TEXT for s in chars]
        base_color = max(set(colors), key=colors.count) if colors else TEXT
        kw = [f"font={font}", f"font_size={_num(self.fs_text(size), 1)}", f'color="{base_color}"']
        bold = [bool(s.get("b")) for s in chars]
        ital = [bool(s.get("i")) for s in chars]
        mono = [bool(s.get("tt")) for s in chars]
        visible = [k for k, ch in enumerate(text) if not ch.isspace()]
        if visible and all(bold[k] for k in visible):
            kw.append("weight=BOLD")
            bold = [False] * len(bold)
        if visible and all(ital[k] for k in visible):
            kw.append("slant=ITALIC")
            ital = [False] * len(ital)

        def ranges(vals, skip):
            out, k = [], 0
            while k < len(vals):
                v = vals[k]
                e = k
                while e < len(vals) and vals[e] == v:
                    e += 1
                if v != skip:
                    a, b = k, e
                    while a < b and text[a].isspace():
                        a += 1
                    while b > a and text[b - 1].isspace():
                        b -= 1
                    if a < b:
                        out.append((a, b, v))
                k = e
            return out
        for key, rs in (("t2c", ranges(colors, base_color)), ("t2w", [(a, b, "BOLD") for a, b, _ in ranges(bold, False)]),
                        ("t2s", [(a, b, "ITALIC") for a, b, _ in ranges(ital, False)]),
                        ("t2f", [(a, b, self.mono) for a, b, _ in ranges(mono, False)])):
            if rs:
                kw.append(f"{key}={{" + ", ".join(f'"[{a}:{b}]": "{v}"' for a, b, v in rs) + "}")
        n = len(lines)
        if n > 1:
            pitch = pitch or self.pitch(size)
            kw.append(f"line_spacing={_num(pitch * self.u * 96 / self.fs_text(size) - 1, 2)}")
        kw.append("disable_ligatures=True")
        urls = [s.get("url") for s in chars if s.get("url")]
        link = max(set(urls), key=urls.count) if urls else None
        if align in ("center", "right") and n > 1:
            call = f"Paragraph({', '.join(repr(l.rstrip()) for l in text.split(chr(10)))}, alignment=\"{align}\", {', '.join(kw)})"
            comment = "# manimble"
        else:
            call = f"Text({text!r}, {', '.join(kw)})"
            comment = f"# manimble box w={_num(box_w * self.u, 3)}" if box_w else "# manimble"
        if link:
            call += f".set(manimble_link={link!r})"
        return call, comment

    def place_para(self, b: dict, x0: float, x1: float, y: float, placed: list, ctx: dict, first_line_x=None,
                   font: str = "FONT") -> float:
        size = b.get("size") or self.size("normalsize")
        indent = ctx.get("indent", 0)
        x0 += indent
        chars, needs_math = self.styled(b["src"], size, b.get("color"), b.get("italic"))
        if not chars:
            return y
        # the paragraph's size is the size most of its characters have ({\small ...} groups)
        sizes = [st.get("size") or size for c, st in chars if not c.isspace()]
        if sizes:
            size = max(set(sizes), key=sizes.count)
        pitch = b.get("pitch") or next((st["pitch"] for c, st in chars if st.get("pitch") and st.get("size") == size), None) \
            or self.pitch(size)
        width = x1 - x0
        lines = self.wrap(chars, width)
        baseline = y + 0.7 * pitch
        b["_baseline"], b["_size"] = baseline, size
        align = b.get("align") or "left"
        if needs_math:
            for k, ln in enumerate(lines):
                code = self.math_line(ln, size)
                if code is None:
                    continue
                cy = baseline + k * pitch - 0.3 * size
                if align == "center":
                    pos = f".move_to(({_num(self.ux((x0 + x1) / 2))}, {_num(self.uy(cy))}, 0))"
                else:
                    pos = f".move_to(({_num(self.ux(x0))}, {_num(self.uy(cy))}, 0), aligned_edge=LEFT)"
                placed.append((b["build"], f"self.add({code}{pos})  # manimble", y, y + pitch))
            return baseline + (len(lines) - 1) * pitch + 0.3 * pitch
        line0 = "".join(c for c, _ in lines[0])
        top = baseline - self.ink_top(line0, {"size": size})
        call, comment = self.text_code(lines, size, align, width if align == "left" else None, pitch, font)
        if align == "center":
            pos = f".move_to(({_num(self.ux((x0 + x1) / 2))}, {_num(self.uy(top))}, 0), aligned_edge=UP)"
        elif align == "right":
            pos = f".move_to(({_num(self.ux(x1))}, {_num(self.uy(top))}, 0), aligned_edge=UR)"
        else:
            pos = f".move_to(({_num(self.ux(x0))}, {_num(self.uy(top))}, 0), aligned_edge=UL)"
        last = baseline + (len(lines) - 1) * pitch
        placed.append((b["build"], f"self.add({call}{pos})  {comment}", top, last + 0.3 * size))
        return last + 0.3 * pitch

    def math_line(self, line: list, size: float) -> str | None:
        """A MathTex for one line mixing text and maths LaTeX could not turn into characters."""
        parts, txt = [], []

        def flush():
            if txt:
                t = "".join(txt).replace("\u00a0", "~")
                t = "".join("\\" + c if c in "&%$#_{}" else c for c in t)
                parts.append("\\textsf{" + t + "}")
                txt.clear()
        for c, st in line:
            if c == "\x01":
                flush()
                parts.append(st["math"])
            else:
                txt.append(c)
        flush()
        tex = "".join(parts).strip()
        if not tex:
            return None
        color = next((st.get("c") for _, st in line if st.get("c")), TEXT)
        return f"MathTex({pyraw(tex)}, font_size={_num(self.fs_math(size), 1)}, color=\"{color}\")"

    def place_verb(self, b: dict, x0: float, y: float, placed: list) -> float:
        size = self.size("small")
        lines = b["text"].strip("\n").split("\n")
        pitch = self.pitch(size)
        baseline = y + 0.7 * pitch
        top = baseline - 0.7 * size
        ls = pitch * self.u * 96 / self.fs_text(size) - 1
        call = (f"Text({chr(10).join(lines)!r}, font={self.mono!r}, font_size={_num(self.fs_text(size), 1)}, "
                f"color=\"{TEXT}\", line_spacing={_num(ls, 2)}, disable_ligatures=True)")
        placed.append((b["build"], f"self.add({call}.move_to(({_num(self.ux(x0))}, {_num(self.uy(top))}, 0), "
                                   f"aligned_edge=UL))  # manimble", top, baseline + (len(lines) - 1) * pitch + 0.3 * size))
        return baseline + (len(lines) - 1) * pitch + 0.3 * size + 0.3 * size

    def place_list(self, b: dict, x0: float, x1: float, y: float, placed: list, ctx: dict) -> float:
        """Beamer's list spacing: \\topsep 3pt above and below a level-1 list, \\itemsep 3pt between its items
        (1.35pt before an item that holds a nested list), 2pt above a nested list and no gap between its items."""
        base = self.size("normalsize")
        items = b["items"]
        if not items:
            return y
        level = items[0]["level"]
        size = ctx["size"] if level == 1 else self.size(["small", "footnotesize"][min(level, 3) - 2])
        kind = b["kind"]
        text_x = x0 + 1.98 * base
        if kind == "description":
            widest = max((self.measure(plain(self.styled(it["label"] or "", size, None)[0]), {"size": size})
                          for it in items), default=0)
            text_x = x0 + max(1.98 * base, widest + 0.9 * base)
        k = self.base / 11
        sep = ITEMSEP * k
        isep = b.get("itemsep")
        y += sep if level == 1 else 2 * PT * k
        for n, it in enumerate(items):
            inner = it["blocks"]
            if n and level == 1:
                y += (1.35 * PT * k if any(blk["t"] == "list" for blk in inner) else sep) if isep is None else isep
            start_y = y
            sub_ctx = dict(ctx, level=level, indent=0, size=size)
            for blk in inner:
                if blk["t"] == "para":
                    blk["size"] = blk.get("size") or size
            y = self.layout(inner, text_x, x1, y, placed, sub_ctx) if inner else y + self.pitch(size)
            first = next((blk for blk in inner if blk["t"] == "para"), None)
            if first and first.get("_baseline") is not None:
                baseline, lsize = first["_baseline"], first["_size"]
            else:
                baseline, lsize = start_y + 0.7 * self.pitch(size), size
            self.place_label(it, kind, n, level, lsize, text_x, baseline, placed)
        return y + (sep if level == 1 else 0.0)

    def place_label(self, it: dict, kind: str, n: int, level: int, size: float, text_x: float, baseline: float, placed: list):
        th = self.theme
        if it["label"] is not None or kind in ("enumerate", "description"):
            if it["label"] is not None:
                chars, _ = self.styled(it["label"], size, th.structure)
                label = plain(chars)
            else:
                label = (f"{n + 1}." if level == 1 else "abcdefghijklmnopqrstuvwxyz"[n % 26] + ".")
            if not label:
                return
            if kind == "enumerate" and it["label"] is None and th.items == "ball":
                # the rounded theme's "item projected": a white number on a ball
                r = 0.44 * size
                cx, cy = text_x - 1.03 * size, baseline - 0.37 * size
                self.ball(it["build"], cx, cy, r, placed)
                num = label.rstrip(".")
                code = (f"Text({num!r}, font=FONT, font_size={_num(self.fs_text(0.55 * size), 1)}, color=\"#FFFFFF\", "
                        f"weight=BOLD, disable_ligatures=True).move_to(({_num(self.ux(cx))}, {_num(self.uy(cy))}, 0))")
                placed.append((it["build"], f"self.add({code})  # manimble", cy - r, cy + r))
                return
            right = text_x - 0.4 * size
            top = baseline - self.ink_top(label, {"size": size})
            code = (f"Text({label!r}, font=FONT, font_size={_num(self.fs_text(size), 1)}, color=\"{th.structure}\", "
                    f"disable_ligatures=True).move_to(({_num(self.ux(right))}, {_num(self.uy(top))}, 0), aligned_edge=UR)")
            placed.append((it["build"], f"self.add({code})  # manimble", top, baseline))
            return
        if th.items == "ball":
            r = (0.25 if level == 1 else 0.215) * size
            self.ball(it["build"], text_x - 0.8 * size, baseline - (0.32 if level == 1 else 0.29) * size, r, placed)
            return
        if th.items in ("circle", "square"):
            r = (0.2 if level == 1 else 0.16) * size
            cx, cy = text_x - 0.8 * size, baseline - 0.3 * size
            shape = (f"Circle(radius={_num(r * self.u, 3)}" if th.items == "circle" else
                     f"Square(side_length={_num(2 * r * self.u, 3)}")
            code = (f"{shape}, color=\"{th.structure}\", fill_opacity=1, stroke_width=0)"
                    f".move_to(({_num(self.ux(cx))}, {_num(self.uy(cy))}, 0))")
            placed.append((it["build"], f"self.add({code})  # manimble", cy - r, cy + r))
            return
        h = (0.6 if level == 1 else 0.45) * size
        cx = text_x - (1.27 if level == 1 else 1.2) * size + h * 0.43
        cy = baseline - 0.33 * size
        code = (f"Triangle(color=\"{th.structure}\", fill_opacity=1, stroke_width=0).rotate(-PI / 2)"
                f".scale_to_fit_height({_num(h * self.u, 3)}).move_to(({_num(self.ux(cx))}, {_num(self.uy(cy))}, 0))")
        placed.append((it["build"], f"self.add({code})  # manimble", cy - h / 2, cy + h / 2))

    def ball(self, build: int, cx: float, cy: float, r: float, placed: list):
        """A shaded sphere bullet (the rounded inner theme), lit from the top left."""
        code = (f"Circle(radius={_num(r * self.u, 3)}, color=\"{self.theme.structure}\", fill_opacity=1, stroke_width=0)"
                f".set_sheen(0.35, UL).move_to(({_num(self.ux(cx))}, {_num(self.uy(cy))}, 0))")
        placed.append((build, f"self.add({code})  # manimble", cy - r, cy + r))

    def place_math(self, b: dict, x0: float, x1: float, y: float, placed: list) -> float:
        size = self.size("normalsize")
        src = self.clean_math(b["src"], b.get("env"))
        meas = self.snippet_out.get(b.get("idx", -1))
        rows = src.count("\\\\") + 1
        if meas and meas[2] > 0:
            h = meas[2]
        else:
            h = rows * 1.5 * size + (0.6 * size if re.search(r"\\(frac|sum|int|prod)", src) else 0)
        y += 0.5 * size
        cy = y + h / 2
        if not src:
            return y
        code = (f"MathTex({pyraw(src)}, font_size={_num(self.fs_math(size), 1)}, color=\"{TEXT}\")"
                f".move_to(({_num(self.ux((x0 + x1) / 2))}, {_num(self.uy(cy))}, 0))")
        placed.append((b["build"], f"self.add({code})  # manimble", y, y + h))
        return y + h + 0.6 * size

    def place_picture(self, b: dict, x0: float, x1: float, y: float, placed: list) -> float:
        if b["t"] == "image":
            got = self.image(b["file"])
            if not got:
                return y
            name, nw, nh = got
            opts = dict(kv.split("=", 1) if "=" in kv else (kv, "") for kv in (o.strip() for o in b["opts"].split(",")) if kv)
            ctx = {"width": x1 - x0, "size": self.size("normalsize")}
            w = self.length(opts["width"], ctx) if "width" in opts else None
            h = self.length(opts["height"], ctx) if "height" in opts else None
            if "scale" in opts:
                try:
                    k = float(opts["scale"])
                    w, h = nw * k, nh * k
                except ValueError:
                    pass
            if w and h and "keepaspectratio" in opts:
                k = min(w / nw, h / nh)
                w, h = nw * k, nh * k
            elif w and not h:
                h = w * nh / nw
            elif h and not w:
                w = h * nw / nh
            elif not w and not h:
                w, h = nw, nh
            fit = f".set(width={_num(w * self.u)})"
            if abs((w / h) / (nw / nh) - 1) > 0.03:
                fit += f".stretch_to_fit_height({_num(h * self.u)})"
            obj = f'ImageMobject(ASSETS / "{name}"){fit}'
        else:
            name, w, h = self.snippet_out.get(b["idx"], ("", 0.0, 0.0))
            if not name:
                self.warnings.append(f"a {b.get('env', 'LaTeX')} environment could not be typeset")
                return y
            if w > x1 - x0:
                h, w = h * (x1 - x0) / w, x1 - x0
            obj = f'ImageMobject(ASSETS / "{name}").set(width={_num(w * self.u)})'
        align = b.get("align") or "left"
        cx = {"center": (x0 + x1) / 2, "right": x1 - w / 2}.get(align, x0 + w / 2)
        sep = ITEMSEP * self.base / 11
        y += sep
        placed.append((b["build"], f"self.add({obj}.move_to(({_num(self.ux(cx))}, {_num(self.uy(y + h / 2))}, 0)))  # manimble",
                       y, y + h))
        return y + h + sep

    def place_block(self, b: dict, x0: float, x1: float, y: float, placed: list, ctx: dict) -> float:
        size = self.size("normalsize")
        th = self.theme
        color = {"alertblock": ALERT, "exampleblock": EXAMPLE}.get(b["kind"], th.structure)
        if th.rounded and th.block_title_bg:
            # the rounded inner theme: a title bar, a tinted body, rounded corners and a shadow below
            pitch = self.pitch(size)
            title_bg = {"alertblock": "#BF0000", "exampleblock": "#008000"}.get(b["kind"], th.block_title_bg)
            body_bg = mix(title_bg, "#FFFFFF", 10)
            y += 0.3 * size
            top = y
            start = len(placed)
            if b.get("title"):
                head_h = pitch + 0.85
                self.place_para({"src": b["title"], "build": b["build"], "size": size, "color": th.block_title_fg,
                                 "align": "left"}, x0, x1, y + 0.11 * pitch, placed, ctx)
                y = top + head_h
            else:
                head_h = 0.0
            body = self.layout(b["blocks"], x0, x1, y - 0.2, placed, ctx)
            bottom = body + 0.1 * pitch
            w, r = (x1 - x0) * self.u, 4 * PT * self.u
            code = []
            if th.shadow:
                code.append(f"RoundedRectangle(corner_radius={_num(r, 3)}, width={_num(w)}, height={_num((bottom - top) * self.u)}, "
                            f"color=\"#808080\", fill_opacity=0.45, stroke_width=0)"
                            f".move_to(({_num(self.ux((x0 + x1) / 2) + 0.012)}, {_num(self.uy((top + bottom) / 2) - 0.02)}, 0))")
            code.append(f"RoundedRectangle(corner_radius={_num(r, 3)}, width={_num(w)}, height={_num((bottom - top) * self.u)}, "
                        f"color=\"{body_bg}\", fill_opacity=1, stroke_width=0)"
                        f".move_to(({_num(self.ux((x0 + x1) / 2))}, {_num(self.uy((top + bottom) / 2))}, 0))")
            if head_h:
                code.append(f"Rectangle(width={_num(w)}, height={_num(head_h * self.u)}, color=\"{title_bg}\", fill_opacity=1, "
                            f"stroke_width=0).move_to(({_num(self.ux((x0 + x1) / 2))}, {_num(self.uy(top + head_h / 2))}, 0))")
            backs = [(b["build"], f"self.add({c})  # manimble", top, bottom) for c in code]
            placed[start:start] = backs
            return bottom + 0.5 * size
        y += 0.2 * size
        if b.get("title"):
            y = self.place_para({"src": b["title"], "build": b["build"], "size": size, "color": color, "align": "left"},
                                x0, x1, y, placed, ctx)
            y += 0.1 * size
        y = self.layout(b["blocks"], x0, x1, y, placed, ctx)
        return y + 0.5 * size

    def place_columns(self, b: dict, x0: float, x1: float, y: float, placed: list, ctx: dict) -> float:
        cols = b["cols"]
        total = sum(c["width"] for c in cols)
        # beamer (beamerbaseframecomponents.sty): the columns sit in a box as wide as the paper (text width plus
        # both margins) with \hfill before the first and after each one, so what is left is shared between n+1
        # gaps; with onlytextwidth / totalwidth the box is that wide and has no leading \hfill
        if b.get("total") or b.get("onlytextwidth"):
            span = b.get("total") or (x1 - x0)
            gap = max(0.0, (span - total) / len(cols))
            x = x0
        else:
            left, right = x0 - self.theme.margin_l, x1 + self.theme.margin_r
            gap = max(0.0, (right - left - total) / (len(cols) + 1))
            x = left + gap
        results = []
        for c in cols:
            sub: list = []
            bottom = self.layout(c["blocks"], x, x + c["width"], y, sub, dict(ctx, width=c["width"]))
            top = min((p[2] for p in sub), default=y)
            bot = max((p[3] for p in sub), default=bottom)
            results.append((sub, top, bot, c["valign"]))
            x += c["width"] + gap
        tallest = max((r[2] - r[1] for r in results), default=0)
        for sub, top, bot, va in results:
            h = bot - top
            dy = {"T": 0.0, "t": 0.0, "b": tallest - h}.get(va, (tallest - h) / 2) + (y - top)
            for p in sub:
                placed.append(shift(p, dy, self))
        return y + tallest + 0.2 * self.size("normalsize")

    def place_titlepage(self, b: dict, placed: list):
        """Title, subtitle, author, institute and date, centred as Beamer's default title page; the rounded inner
        theme (Madrid & co.) puts the title in a rounded, shadowed box in the title colours."""
        th = self.theme
        rounded = th.rounded
        title_fg = th.frametitle_fg if rounded and th.frametitle_bg else th.structure
        rows = [("title", "Large", title_fg, 0), ("subtitle", "normalsize", title_fg, 16.9),
                ("author", "normalsize", TEXT, 43.5 if rounded else 35.4),
                ("institute", "scriptsize", TEXT, 25.2 if rounded else 22.5),
                ("date", "normalsize", TEXT, 26.9 if rounded else 24.5)]
        items, y = [], 0.0
        for key, sz, color, gap in rows:
            if key not in self.meta or not self.meta[key].strip():
                continue
            if items:
                y += gap * self.base / 11
            src = self.meta[key].replace("\\and", ",\\ ")
            size = self.size_of(key, sz)
            items.append((key, y, src, size, color))
        if "titlegraphic" in self.meta:
            self.warnings.append("\\titlegraphic is not imported")
        if not items:
            return
        k = self.base / 11
        in_box = [it for it in items if it[0] in ("title", "subtitle")]
        if rounded and in_box and th.frametitle_bg:
            tsize = in_box[0][3]
            box_top = in_box[0][1] - 1.69 * tsize
            box_bot = in_box[-1][1] + 0.98 * in_box[-1][3] + (4 * k if len(in_box) > 1 else 0)
            span_top, span_bot = box_top, items[-1][1] + 0.3 * items[-1][3]
            y0 = 105.9 * self.H / 255.12 - 0.4 * (span_bot - span_top) - span_top
            x0, x1 = 7.0 * self.W / 453.5, self.W - 7.1 * self.W / 453.5
            w, h, r = (x1 - x0) * self.u, (box_bot - box_top) * self.u, 4 * PT * self.u
            cx, cy = self.ux((x0 + x1) / 2), self.uy(y0 + (box_top + box_bot) / 2)
            if th.shadow:
                placed.append((b["build"], f"self.add(RoundedRectangle(corner_radius={_num(r, 3)}, width={_num(w)}, height={_num(h)}, "
                               f"color=\"#808080\", fill_opacity=0.5, stroke_width=0).move_to(({_num(cx + 0.03)}, {_num(cy - 0.06)}, 0)))  # manimble",
                               y0 + box_top, y0 + box_bot))
            placed.append((b["build"], f"self.add(RoundedRectangle(corner_radius={_num(r, 3)}, width={_num(w)}, height={_num(h)}, "
                           f"color=\"{th.frametitle_bg}\", fill_opacity=1, stroke_width=0).move_to(({_num(cx)}, {_num(cy)}, 0)))  # manimble",
                           y0 + box_top, y0 + box_bot))
        else:
            span = items[-1][1] - items[0][1]
            y0 = self.H / 2 + 4 - span / 2
        for key, yb, src, size, color in items:
            sub: list = []
            pitch = self.pitch(size)
            self.place_para({"src": src, "build": b["build"], "size": size, "color": color, "align": "center"},
                            th.margin_l, self.W - th.margin_r, y0 + yb - 0.7 * pitch, sub, {})
            placed += sub

    # ------------------------------------------------------------ frame title, footline
    def place_frametitle(self, fr: dict, title: str | None, subtitle: str | None, head: list) -> float:
        """The frame title (and a theme's title bar); returns the y (bp) where the body may start."""
        th = self.theme
        keys = {th.frame_keys[k]: v for k, v in fr.get("keys", {}).items() if k in th.frame_keys}
        if not title and not (th.frametitle_src and keys):
            return 0.0
        tsize = self.size_of("frametitle", "Large")
        tfont = th.font("frametitle", "Large")
        pitch = self.pitch(tsize)
        if th.frametitle_src:
            lines, bar_h = self.frametitle_template(th.frametitle_src, title or "", subtitle, keys)
        else:
            lines = []
            xh = self.ink_top("x", {"size": tsize})
            baseline = TITLE_X + pitch - xh                          # sep=0.3cm, \vbox{}\vskip-1ex, then the strut line
            lines.append({"src": title, "size": tsize, "bold": tfont.get("bold"), "italic": tfont.get("italic"),
                          "align": "left", "baseline": baseline, "x0": TITLE_X, "x1": self.W - TITLE_X})
            n = self.n_lines(title, tsize, self.W - 2 * TITLE_X, tfont)
            bottom = baseline + (n - 1) * pitch + 0.3 * pitch
            if subtitle:
                ssize = self.size_of("framesubtitle", "footnotesize")
                sp = self.pitch(ssize)
                sb = baseline + (n - 1) * pitch + sp
                lines.append({"src": subtitle, "size": ssize, "bold": False, "italic": False, "align": "left",
                              "baseline": sb, "x0": TITLE_X, "x1": self.W - TITLE_X})
                bottom = sb + 0.3 * sp
            bar_h = bottom + 0.6
        if th.frametitle_bg:
            head.append((0, f"self.add(Rectangle(width={_num(self.FW)}, height={_num(bar_h * self.u)}, color=\"{th.frametitle_bg}\", "
                            f"fill_opacity=1, stroke_width=0).move_to((0, {_num(self.uy(bar_h / 2))}, 0)))  # manimble",
                         0.0, bar_h))
        for ln in lines:
            if not (ln["src"] or "").strip():
                continue
            src = ln["src"]
            if ln.get("bold"):
                src = "\\textbf{" + src + "}"
            if ln.get("italic"):
                src = "\\textit{" + src + "}"
            p = self.pitch(ln["size"])
            self.place_para({"src": src, "build": 0, "size": ln["size"], "color": th.frametitle_fg, "align": ln["align"]},
                            ln["x0"], ln["x1"], ln["baseline"] - 0.7 * p, head, {})
        if th.frametitle_bg:
            return bar_h
        return max(27.0 * self.base / 11, bar_h - 0.6)

    def n_lines(self, src: str, size: float, width: float, font: dict | None = None) -> int:
        """How many lines LaTeX needs for src at this size in this width."""
        if not (src or "").strip():
            return 1
        if font and font.get("bold"):
            src = "\\textbf{" + src + "}"
        chars, _ = self.styled(src, size, None)
        return max(1, len(self.wrap(chars, width))) if chars else 1

    def frametitle_template(self, src: str, title: str, subtitle: str | None, keys: dict) -> tuple[list, float]:
        """A custom \\setbeamertemplate{frametitle}: its lines (\\hbox{...} and ...\\par runs) stacked the way TeX
        stacks them (\\vskip, struts, interline glue), with \\usebeamerfont sizes and frame-key macros."""
        th = self.theme
        k = self.base / 11
        src = re.sub(r"\\ifx\\insertframesubtitle\\@empty(.*?)(?:\\else(.*?))?\\fi",
                     lambda m: (m.group(1) if not subtitle else (m.group(2) or "")), src, flags=re.S)
        src = re.sub(r"\\if@tempswa.*?\\fi", "", src, flags=re.S)
        for macro, val in keys.items():
            src = re.sub(r"\\" + macro + r"(?![A-Za-z@])", lambda m: "{" + val + "}", src)
        for macro in th.frame_keys.values():
            src = re.sub(r"\\" + macro + r"(?![A-Za-z@])", "{}", src)
        src = src.replace("\\insertframetitle", "{" + title + "}").replace("\\insertframesubtitle", "{" + (subtitle or "") + "}")
        leftskip = rightskip = 0.0
        sep = 0.0
        m = re.search(r"\\begin\{beamercolorbox\}\s*(?:\[([^\]]*)\])?", src)
        if m:
            for kv in (m.group(1) or "").split(","):
                if "=" in kv:
                    kk, vv = (x.strip() for x in kv.split("=", 1))
                    L = self.length(vv, {"width": self.W, "size": self.size("normalsize")})
                    if kk == "leftskip":
                        leftskip = L
                    elif kk == "rightskip":
                        rightskip = L
                    elif kk == "sep":
                        sep = L
        src = re.sub(r"\\begin\{beamercolorbox\}\s*(?:\[[^\]]*\])?\s*\{[^}]*\}|\\end\{beamercolorbox\}", "", src)
        y = 7.5 * k + sep
        pending = 0.0
        prevdepth = None
        lines: list[dict] = []
        cur_font = "frametitle"
        text: list[str] = []
        pat = re.compile(r"\\vskip\s*(-?[\d.]+\s*[a-z]{2})|\\vbox\s*\{\s*\}|\\hbox(\s+to\s*([^{]*))?\s*\{|\\par(?![A-Za-z])|"
                         r"\\usebeamerfont\s*\{([^}]*)\}|\\usebeamercolor\s*(?:\[[^\]]*\])?\s*\{[^}]*\}|"
                         r"\\(nointerlineskip|strut|relax|leavevmode|noindent)(?![A-Za-z])")

        def emit(content: str, font: str, x0: float, x1: float):
            nonlocal y, pending, prevdepth
            fsize = self.size_of(font, "Large" if font == "frametitle" else "normalsize")
            f = th.font(font, "normalsize")
            bs = self.pitch(fsize)
            h, d = 0.7 * bs, 0.3 * bs
            if prevdepth is None:
                baseline = y + pending + h
            else:
                glue = bs - prevdepth - h
                baseline = y + pending + (glue if glue >= 0 else PT) + h
            align = "left"
            c = content.strip()
            if c.startswith("\\hfill"):
                c = c[len("\\hfill"):]
                align = "right"
                if c.rstrip().endswith("\\hfill"):
                    c = c.rstrip()[:-len("\\hfill")]
                    align = "center"
            n = self.n_lines(c, fsize, x1 - x0, f)
            y, pending, prevdepth = baseline + (n - 1) * bs + d, 0.0, d
            lines.append({"src": c, "size": fsize, "bold": f.get("bold"), "italic": f.get("italic"), "align": align,
                          "baseline": baseline, "x0": x0, "x1": x1})

        i = 0
        while i < len(src):
            m = pat.search(src, i)
            if not m:
                text.append(src[i:])
                break
            text.append(src[i:m.start()])
            tok = m.group(0)
            i = m.end()
            if tok.startswith("\\vskip"):
                pending += self.length(m.group(1), {"width": self.W, "size": self.size("normalsize")})
            elif tok.startswith("\\vbox"):
                if prevdepth is None:
                    y += pending
                    pending = 0.0
                prevdepth = 0.0
            elif tok.startswith("\\hbox"):
                body, i = balanced(src, i - 1)
                fm = re.search(r"\\usebeamerfont\s*\{([^}]*)\}", body)
                font = fm.group(1).strip() if fm else cur_font
                body = re.sub(r"\\usebeamerfont\s*\{[^}]*\}|\\usebeamercolor\s*(?:\[[^\]]*\])?\s*\{[^}]*\}|\\strut", "", body)
                L = self.length(m.group(3).replace("\\dimexpr", "").replace("\\relax", "").strip(), {"width": self.W, "size": self.size("normalsize")}) \
                    if m.group(3) else self.W - leftskip - rightskip
                emit(body, font, leftskip, leftskip + L - rightskip)
                text = []
            elif tok.startswith("\\par"):
                if "".join(text).strip():
                    emit("".join(text), cur_font, leftskip, self.W - rightskip)
                text = []
            elif tok.startswith("\\usebeamerfont"):
                cur_font = m.group(4).strip()
        if "".join(text).strip():
            emit("".join(text), cur_font, leftskip, self.W - rightskip)
        bar_h = y + pending + sep
        return lines, bar_h

    def place_footline(self, n: int, total: int, head: list):
        th = self.theme
        k = self.base / 11
        tiny = self.size_of("page number in head/foot", "tiny")
        if th.footline == "infolines":
            fh = 10.1 * k
            boxes = [("palette tertiary", mix(th.structure, "#000000", 50), "author", "center"),
                     ("palette secondary", mix(th.structure, "#000000", 75), "title", "center"),
                     ("palette primary", th.structure, "date", "right")]
            bw = self.W / 3
            for bi, (pal, dflt_bg, key, align) in enumerate(boxes):
                fg, bg = th.palette(pal, "#FFFFFF", dflt_bg)
                x0, x1 = bi * bw, (bi + 1) * bw
                if bg:
                    head.append((0, f"self.add(Rectangle(width={_num(bw * self.u)}, height={_num(fh * self.u)}, color=\"{bg}\", "
                                    f"fill_opacity=1, stroke_width=0).move_to(({_num(self.ux((x0 + x1) / 2))}, {_num(self.uy(self.H - fh / 2))}, 0)))  # manimble",
                                 self.H - fh, self.H))
                if key == "author":
                    src = self.meta_short.get("author", self.meta.get("author", ""))
                    inst = self.meta_short.get("institute", self.meta.get("institute", ""))
                    if inst.strip():
                        src += "~~(" + inst + ")"
                elif key == "title":
                    src = self.meta_short.get("title", self.meta.get("title", ""))
                else:
                    src = self.meta_short.get("date", self.meta.get("date", "")) + f"\\hspace*{{2em}}{n} / {total}"
                src = src.replace("\\and", ", ")
                if not src.strip():
                    continue
                pitch = self.pitch(tiny)
                baseline = self.H - 3.9 * k
                inset = 2 * 0.5 * tiny
                self.place_para({"src": src, "build": 0, "size": tiny, "color": fg, "align": align},
                                x0 + inset, x1 - inset, baseline - 0.7 * pitch, head, {})
            return
        if th.footline == "page":
            src, right_inset, bottom, color = f"{n} / {total}", 2 * self.size("normalsize"), 2 * PT * k, th.structure
        elif th.footline == "custom" and th.footline_src and "\\insertframenumber" in th.footline_src:
            fs = th.footline_src
            m = re.search(r"\\insertframenumber\s*(?:\{\})?(.*?)\\inserttotalframenumber", fs, flags=re.S)
            src = f"{n}{m.group(1)}{total}" if m else str(n)
            fm = re.search(r"\\usebeamerfont\s*\{([^}]*)\}", fs)
            tiny = self.size_of(fm.group(1).strip(), "tiny") if fm else tiny
            hm = re.search(r"\\hspace\*?\s*\{([^}]*)\}\s*(?:\\vskip|$)", fs.replace("\n", " ").strip())
            right_inset = self.length(hm.group(1), {"width": self.W, "size": tiny}) if hm else 0.0
            vm = re.search(r"\\vskip\s*(-?[\d.]+\s*[a-z]{2})", fs)
            bottom = self.length(vm.group(1), {"width": self.W, "size": tiny}) if vm else 0.0
            cm = re.search(r"\\usebeamercolor\s*\[fg\]\s*\{([^}]*)\}", fs)
            color = (th.colors.get(cm.group(1).strip(), {}).get("fg") if cm else None) or TEXT
            if "beamercolorbox" in fs:
                self.warnings.append("the custom footline's boxes are not drawn; only its frame number is")
        else:
            if th.footline == "custom":
                self.warnings.append("the custom footline is not reproduced")
            return
        pitch = self.pitch(tiny)
        baseline = self.H - bottom
        self.place_para({"src": src, "build": 0, "size": tiny, "color": color, "align": "right"},
                        th.margin_l, self.W - right_inset, baseline - 0.7 * pitch, head, {})

    # ------------------------------------------------------------ the deck
    def run(self, progress=None) -> dict:
        pre, body = self.read()
        self.preamble(pre)
        self.deck.mkdir(parents=True, exist_ok=True)
        self.assets.mkdir(parents=True, exist_ok=True)
        self.setup_fonts()
        frames = self.frames(body)
        if not frames:
            return {"ok": False, "error": "no frames were found in this file"}
        all_sections = [s for f in frames for s in f.get("sections", [])]
        all_sections = list(dict.fromkeys(all_sections))
        parsed = []
        for fi, fr in enumerate(frames, start=1):
            st = {"vis": 0, "next": 0}
            ctx = {"align": "left", "size": self.size("normalsize"), "width": self.W - 2 * MARGIN,
                   "frame": {"frametitle": fr["title"], "framesubtitle": fr["subtitle"], "sections": all_sections},
                   "all_sections": all_sections}
            try:
                blocks = self.blocks(fr["body"], st, ctx)
            except Exception as exc:                         # noqa: BLE001
                self.warnings.append(f"frame {fi}: could not be read ({exc})")
                blocks = []
            self.collect_math(blocks)
            parsed.append((fr, ctx, blocks))
            if "allowframebreaks" in fr["opts"]:
                self.warnings.append(f"frame {fi}: allowframebreaks is not split into several slides")
        if progress:
            progress(0, len(parsed) + 1, "typesetting")
        self.typeset_snippets()
        classes, names = [], []
        th = self.theme
        for fi, (fr, ctx, blocks) in enumerate(parsed, start=1):
            if progress:
                progress(fi, len(parsed) + 1, f"frame {fi}")
            placed: list = []
            title = ctx["frame"].get("frametitle")
            subtitle = ctx["frame"].get("framesubtitle")
            self.cur_frame = {"title": title, "index": fi, "n_images": 0}
            head: list = []
            title_bottom = self.place_frametitle(fr, title, subtitle, head)
            is_title = any(b["t"] == "titlepage" for b in blocks)
            if not is_title or th.footline == "custom":
                self.place_footline(fi, len(parsed), head)
            self.layout(blocks, th.margin_l, self.W - th.margin_r, 0.0, placed, ctx)
            body_items = [p for p in placed if not is_title]
            if body_items:
                top = min(p[2] for p in body_items)
                bot = max(p[3] for p in body_items)
                opts = fr["opts"].replace(" ", "").split(",")
                if "t" in opts:
                    dy = title_bottom + 12.7 * self.base / 11 - top
                elif "b" in opts:
                    dy = self.H - 12 - bot
                else:
                    # beamer leaves 40% of the free space above the content and 60% below (measured)
                    dy = (0.4 * self.H + 17 * self.H / 255.12) - 0.4 * (bot - top) - top
                    dy = max(dy, title_bottom + 4 - top)
                if bot + dy > self.H + 2:
                    self.warnings.append(f"frame {fi}: the content runs off the bottom of the slide")
                placed = [shift(p, dy, self) if p in body_items else p for p in placed]
            placed = head + placed
            plain_title = plain(self.styled(title or "", 10, None)[0]) if title else ""
            if not plain_title and any(b["t"] == "titlepage" for b in blocks):
                plain_title = plain(self.styled(self.meta.get("title", "Title"), 10, None)[0])
            name = f"S{fi:02d}_{_slug(plain_title, 'Frame')}"
            while name in names:
                name += "_"
            names.append(name)
            code = [f"class {name}(Deck):", f'    """Imported from frame {fi}."""', "", "    def construct(self):",
                    f'        self.camera.background_color = "#FFFFFF"']
            notes = "\n\n".join(plain(self.styled(n, 10, None)[0]) for n in ctx["frame"].get("notes", []))
            if notes.strip():
                code.append(f"        self.next_slide(notes={notes!r})")
            last = max((p[0] for p in placed), default=0)
            for bi in range(last + 1):
                if bi:
                    code.append("        self.next_slide()")
                code += ["        " + p[1] for p in placed if p[0] == bi]
                code.append("        self.wait(0.1)")
            classes.append("\n".join(code))
        self.write(classes, names)
        seen: set = set()
        warnings = [w for w in self.warnings if not (w in seen or seen.add(w))]
        return {"ok": True, "deck": str(self.deck), "slides": len(names), "warnings": warnings[:20]}

    def write(self, classes: list[str], names: list[str]):
        tpl = ["\\usepackage{xcolor}"]
        pkgs = [p for p in self.math_pkgs if p not in ("amsmath", "amssymb")]   # manim's template loads these
        if pkgs:
            tpl.append("\\usepackage{" + ",".join(pkgs) + "}")
        tpl += self.macro_src
        colors = [f"\\definecolor{{{n}}}{{HTML}}{{{c[1:]}}}" for n, c in self.colors.named.items()
                  if n not in XCOLORS and re.fullmatch(r"[A-Za-z0-9]+", n)]
        tpl += colors
        tpl += ["\\providecommand{\\alert}[1]{\\textcolor{red}{#1}}", "\\providecommand{\\structure}[1]{#1}",
                "\\providecommand{\\href}[2]{#2}", "\\providecommand{\\url}[1]{\\texttt{#1}}"]
        template = ""
        if len(tpl) > 1 or self.macro_src:
            template = ("\n# the document's maths packages and macros, for MathTex\nTEMPLATE = TexTemplate()\n"
                        "TEMPLATE.add_to_preamble(r\"\"\"\n" + "\n".join(tpl).replace('"""', '\\"\\"\\"') + "\n\"\"\")\n"
                        "config.tex_template = TEMPLATE\n")
            setup = ("\n    def setup(self):\n        super().setup()\n"
                     "        config.tex_template = TEMPLATE       # manim resets the config between scenes\n")
        else:
            setup = ""
        fonts = ""
        if any(self.font_files.values()):
            fonts = ('\n\ndef _register_fonts():\n    """The document\'s TeX fonts, copied from the TeX installation into assets/fonts."""\n'
                     "    try:\n        import manimpango\n    except Exception:\n        return\n"
                     '    for f in sorted((ASSETS / "fonts").glob("*.[ot]tf")):\n        try:\n'
                     "            manimpango.register_font(str(f))\n        except Exception:\n            pass\n\n\n"
                     "_register_fonts()\n")
        (self.deck / "common.py").write_text(
            '"""Shared base class for the imported deck."""\n\nfrom pathlib import Path\n\nfrom manim import *\n'
            'from manim_slides import Slide\n\nASSETS = Path(__file__).resolve().parent.parent / "assets"\n'
            f'FONT = "{self.font}"\n' + fonts + template + '\n\nclass Deck(Slide):\n    skip_reversing = True\n' + setup)
        (self.deck / "slides.py").write_text(
            f'"""Slides imported from {self.src.name}."""\n\nfrom common import *\n\n\n' + "\n\n\n".join(classes) + "\n",
            encoding="utf-8")
        (self.deck / "order.txt").write_text(" ".join(names) + "\n")
        (self.deck / "manim.cfg").write_text("[CLI]\nbackground_color = #FFFFFF\npixel_width = 1280\npixel_height = "
                                             + str(int(round(1280 * self.H / self.W))) + "\nframe_rate = 30\n")


def shift(p: tuple, dy: float, imp: BeamerImport) -> tuple:
    """A placed item moved down by dy bp (its code's y coordinates rewritten)."""
    if abs(dy) < 1e-6:
        return p
    build, code, top, bot = p
    du = -dy * imp.u

    def mv(m):
        return f"{m.group(1)}{_num(float(m.group(2)) + du)}, 0)"
    code = re.sub(r"(\.move_to\(\(-?[\d.]+, )(-?[\d.]+), 0\)", mv, code)
    return (build, code, top + dy, bot + dy)


def pyraw(s: str) -> str:
    if '"' not in s and not s.endswith("\\") and "\n" not in s:
        return 'r"' + s + '"'
    return repr(s)


_PANGO_FONTS: list[str] | None = None


def pango_fonts() -> list[str]:
    """Font families Pango (manim's Text) can use on this machine."""
    global _PANGO_FONTS
    if _PANGO_FONTS is None:
        try:
            import manimpango
            _PANGO_FONTS = list(manimpango.list_fonts())
        except Exception:                                        # noqa: BLE001
            _PANGO_FONTS = []
    return _PANGO_FONTS


def find_tool(name: str) -> str | None:
    hit = shutil.which(name)
    if hit:
        return hit
    for d in ("/Library/TeX/texbin", str(Path.home() / "Library/TinyTeX/bin/universal-darwin"),
              "/opt/homebrew/bin", "/usr/local/bin"):
        p = Path(d) / name
        if p.exists():
            return str(p)
    return None


def import_beamer(src: str, dest: str, progress=None) -> dict:
    try:
        return BeamerImport(Path(src), Path(dest)).run(progress)
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": f"Could not read the Beamer file: {exc}"}
