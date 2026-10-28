"""LaTeX packages a Beamer deck needs: which are missing on this Mac, and installing them with tlmgr once the user
has agreed (never on its own). A system-wide TeX (MacTeX, BasicTeX) asks for an administrator password through
macOS, as install_dependencies.sh does; TinyTeX in the user's Library takes packages without one."""
from __future__ import annotations

import os
import re
import shlex
import subprocess
from pathlib import Path

from .beamer_import import find_tool, strip_comments

MANIFEST = "latex_pictures.json"          # in a deck's assets: pictures to typeset again and the missing files

REQUIRES = re.compile(r"\\(usepackage|RequirePackage|documentclass|usetheme|usecolortheme|useinnertheme|"
                      r"useoutertheme|usefonttheme)\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}")
THEME_FILE = {"usetheme": "beamertheme", "usecolortheme": "beamercolortheme", "useinnertheme": "beamerinnertheme",
              "useoutertheme": "beameroutertheme", "usefonttheme": "beamerfonttheme"}


def required_files(tex: str) -> list[str]:
    """The .sty/.cls files a preamble (or whole document) loads, in order, without repeats."""
    out: list[str] = []
    for m in REQUIRES.finditer(strip_comments(tex)):
        kind = m.group(1)
        for name in m.group(2).split(","):
            name = name.strip()
            if not name or "\\" in name or "#" in name:
                continue
            f = THEME_FILE[kind] + name + ".sty" if kind in THEME_FILE else \
                name + (".cls" if kind == "documentclass" else ".sty")
            if f not in out:
                out.append(f)
    return out


def missing_files(tex: str) -> list[str]:
    """The files of `required_files` this Mac's TeX does not have ([] when there is no TeX to ask)."""
    return absent(required_files(tex))


def absent(files: list[str]) -> list[str]:
    """Those of `files` kpsewhich cannot find."""
    kpse = find_tool("kpsewhich")
    if not files or not kpse:
        return []
    try:
        r = subprocess.run([kpse] + files, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return []
    found = {Path(p).name for p in r.stdout.split()}
    return [f for f in files if f not in found]


def missing_in(src: str) -> dict:
    """What a .tex file needs that is not installed: {missing: [file], tlmgr: bool}."""
    try:
        text = Path(src).read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return {"missing": [], "tlmgr": False, "error": str(exc)}
    m = re.search(r"\\begin\{document\}", text)
    return {"missing": missing_files(text[:m.start()] if m else text), "tlmgr": find_tool("tlmgr") is not None}


def package_of(tlmgr: str, f: str) -> str | None:
    """The TeX Live package that ships file `f`, asked of CTAN (`tlmgr search --global --file`)."""
    try:
        r = subprocess.run([tlmgr, "search", "--global", "--file", "/" + f], capture_output=True, text=True, timeout=180)
    except (subprocess.TimeoutExpired, OSError):
        return None
    pkg = None
    for line in r.stdout.splitlines():
        if line and not line[0].isspace() and line.rstrip().endswith(":") and not line.startswith("tlmgr"):
            pkg = line.strip()[:-1]
        elif pkg and line.strip().endswith("/" + f):
            return pkg
    return None


def install(files: list[str], progress=None) -> dict:
    """Install the TeX Live packages that ship `files`. {ok, installed: [package], missing: [file still missing],
    error?}. Only call this after the user said yes."""
    tlmgr = find_tool("tlmgr")
    if not tlmgr:
        return {"ok": False, "error": "No TeX package manager (tlmgr) was found. Install LaTeX first with "
                                      "Manimble ▸ Install Dependencies…"}
    pkgs: list[str] = []
    for i, f in enumerate(files):
        if progress:
            progress(i, len(files), f"Finding the package for {f}")
        p = package_of(tlmgr, f)
        if p and p not in pkgs:
            pkgs.append(p)
    if not pkgs:
        return {"ok": False, "error": "CTAN has no package for " + ", ".join(files) +
                " (or it could not be reached; check the internet connection)"}
    if progress:
        progress(len(files), len(files), "Installing " + ", ".join(pkgs))
    kpse = find_tool("kpsewhich")
    root = subprocess.run([kpse, "-var-value", "TEXMFROOT"], capture_output=True, text=True).stdout.strip() if kpse else ""
    # tlmgr refuses to install once CTAN has a newer tlmgr than itself, so it updates itself first
    cmd = f"{shlex.quote(tlmgr)} update --self; {shlex.quote(tlmgr)} install " + " ".join(shlex.quote(p) for p in pkgs)
    try:
        if root and os.access(os.path.join(root, "tlpkg"), os.W_OK):
            r = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, text=True, timeout=1800)
        else:
            # a system TeX lives in a folder only an administrator can change: macOS asks for the password
            script = 'do shell script "' + cmd.replace("\\", "\\\\").replace('"', '\\"') + '" with administrator privileges'
            r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=1800)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"ok": False, "error": f"tlmgr did not finish ({exc})"}
    still = absent(files)
    if r.returncode != 0 and still:
        tail = (r.stderr or r.stdout).strip().splitlines()[-3:]
        msg = "Installing was cancelled" if "User canceled" in r.stderr else "tlmgr failed: " + " ".join(tail)
        return {"ok": False, "error": msg, "installed": [], "missing": still}
    return {"ok": not still, "installed": pkgs, "missing": still,
            **({"error": "still missing after installing: " + ", ".join(still)} if still else {})}
