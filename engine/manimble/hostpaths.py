"""Where programs and fonts live on the machine running the engine: macOS and Windows.

The front ends put the usual folders on PATH before starting the engine. These lists are the fallbacks for a
tool started without them, and the places to look for fonts. Keep platform checks here, so the rest of the
engine stays the same on every system."""
from __future__ import annotations

import os
import sys
from pathlib import Path

WINDOWS = sys.platform == "win32"
MACOS = sys.platform == "darwin"


def tex_dirs() -> list[str]:
    """Folders that hold a TeX distribution's programs (latex, xelatex, kpsewhich, tlmgr)."""
    if WINDOWS:
        local = os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))
        roaming = os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))
        program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
        dirs = [os.path.join(local, "Programs", "MiKTeX", "miktex", "bin", "x64"),
                os.path.join(program_files, "MiKTeX", "miktex", "bin", "x64"),
                os.path.join(roaming, "TinyTeX", "bin", "windows"),
                os.path.join(roaming, "TinyTeX", "bin", "win32")]
        dirs += [rf"C:\texlive\{y}\bin\windows" for y in range(2031, 2019, -1)]
        return dirs
    return ["/Library/TeX/texbin", str(Path.home() / "Library/TinyTeX/bin/universal-darwin"),
            "/opt/homebrew/bin", "/usr/local/bin"]


def tool_dirs() -> list[str]:
    """Other folders where command-line tools such as ffmpeg are installed outside PATH."""
    if WINDOWS:
        local = os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))
        return [os.path.join(local, "Microsoft", "WinGet", "Links"), str(Path.home() / "scoop" / "shims"),
                r"C:\ProgramData\chocolatey\bin"]
    return ["/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local/bin")]


def exe(name: str) -> str:
    """A program's file name on this system (`ffmpeg` -> `ffmpeg.exe` on Windows)."""
    return name + ".exe" if WINDOWS and not name.lower().endswith((".exe", ".bat", ".cmd")) else name


def find_in(dirs, name: str) -> str | None:
    """The first of `dirs` holding program `name` (with .exe / .bat on Windows)."""
    names = [name] if not WINDOWS else [name + ".exe", name + ".bat", name + ".cmd", name]
    for d in dirs:
        for n in names:
            p = Path(d) / n
            if p.is_file():
                return str(p)
    return None


def font_dirs() -> tuple[str, ...]:
    """Folders of installed fonts."""
    if WINDOWS:
        windir = os.environ.get("WINDIR", r"C:\Windows")
        local = os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))
        return (os.path.join(windir, "Fonts"), os.path.join(local, "Microsoft", "Windows", "Fonts"))
    return ("/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
            str(Path.home() / "Library" / "Fonts"))


def system_roots() -> tuple[str, ...]:
    """Folders of the operating system and installed programs: files read from there are never deck dependencies."""
    if WINDOWS:
        return tuple(r for r in (os.environ.get("WINDIR"), os.environ.get("ProgramFiles"),
                                 os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramData")) if r)
    return ("/System", "/Library", "/usr", "/opt/homebrew", "/Applications")
