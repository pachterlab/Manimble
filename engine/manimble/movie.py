"""Write the animated show as one MP4.

Every build's clip (what Manim Slides renders for `manim-slides present`) plays once at its recorded playback rate and
holds its final frame for `hold` seconds; image builds are shown for `hold` seconds. Each clip is encoded as its own
segment, scaled and padded to the frame size, then the segments are joined with a stream copy. The same recipe as the
`manimbler --convert` command line tool, applied to the deck's own `slides/` folder instead of a package. No audio."""

from __future__ import annotations

import math
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

# frame height -> frame size, the build sizes of Manimble.CLIP_SIZES
SIZES = {720: (1280, 720), 1080: (1920, 1080), 1440: (2560, 1440), 2160: (3840, 2160)}


def find_ffmpeg() -> str | None:
    """ffmpeg on PATH, or in the usual places when the app was started without a shell's PATH."""
    for c in (shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
              os.path.expanduser("~/.local/bin/ffmpeg")):
        if c and os.access(c, os.X_OK):
            return c
    try:  # the ffmpeg that the app's Python runtime carries (imageio-ffmpeg)
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def write_movie(clips: list[dict], size: tuple[int, int], destination: str, *, hold: float = 2.0, fps: int = 30,
                progress=None, ffmpeg: str | None = None, run=None) -> list[float]:
    """clips: [{"path", "kind" ("video" or "image"), "rate", "label", "hold" (optional, overrides `hold`)}] in playing
    order. `progress(i, n, label)` is called before each clip is encoded. `run(args, **popen_kw) -> returncode` runs
    each ffmpeg command instead of subprocess.run (the engine passes one whose process the app can cancel). Returns
    each clip's length in the movie, in seconds. Raises RuntimeError with the tail of ffmpeg's output on failure."""
    if not clips:
        raise RuntimeError("there are no animation clips to export")
    if not math.isfinite(hold) or hold < 0:
        raise RuntimeError("the hold must be a nonnegative number of seconds")
    if fps <= 0:
        raise RuntimeError("the frame rate must be positive")
    ffmpeg = ffmpeg or find_ffmpeg()
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is needed to write movies (brew install ffmpeg)")
    width, height = size
    dest = Path(destination)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".manimble-movie-", dir=dest.parent) as temporary:
        work = Path(temporary)
        segments: list[str] = []
        lengths: list[float] = []
        for index, clip in enumerate(clips, 1):
            if progress:
                progress(index - 1, len(clips), clip.get("label", ""))
            segment = f"segment-{index:04d}.mp4"
            held = clip.get("hold", hold)
            if not math.isfinite(held) or held < 0:
                raise RuntimeError("the hold must be a nonnegative number of seconds")
            filters = [f"scale={width}:{height}:force_original_aspect_ratio=decrease",
                       f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black",
                       "setsar=1", "format=yuv420p"]
            command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
            if clip["kind"] == "image":
                command += ["-loop", "1", "-framerate", str(fps), "-i", clip["path"], "-t", str(max(held, 1 / fps))]
            else:
                command += ["-i", clip["path"]]
                rate = float(clip.get("rate") or 1.0)
                filters = [f"setpts=(PTS-STARTPTS)/{rate}", f"fps={fps}"] + filters
                if held:
                    filters.append(f"tpad=stop_mode=clone:stop_duration={held}")
            command += ["-vf", ",".join(filters), "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
                        "-pix_fmt", "yuv420p", "-video_track_timescale", str(fps * 1000), segment]
            _run(command, cwd=work, context=f"encoding {clip.get('label', 'a build')}", run=run)
            segments.append(segment)
            lengths.append(_length(ffmpeg, work / segment))
        listing = work / "segments.ffconcat"
        listing.write_text("ffconcat version 1.0\n" + "".join(f"file '{name}'\n" for name in segments))
        movie = work / "movie.mp4"
        _run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "concat", "-safe", "0",
              "-i", str(listing), "-c", "copy", "-movflags", "+faststart", str(movie)],
             cwd=work, context="joining the builds", run=run)
        os.replace(movie, dest)
    return lengths


def _length(ffmpeg: str, path: Path) -> float:
    """A movie's length in seconds, from the Duration line ffmpeg prints for its input (0 when there is none)."""
    out = subprocess.run([ffmpeg, "-hide_banner", "-nostdin", "-i", str(path)], capture_output=True, text=True).stderr
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", out)
    return int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3]) if m else 0.0


def _run(command: list[str], *, cwd: Path, context: str, run=None) -> None:
    if run is None:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
        code, stderr = result.returncode, result.stderr
    else:
        log = Path(cwd) / "ffmpeg.log"
        with open(log, "w") as lf:
            code = run(command, cwd=cwd, stdout=subprocess.DEVNULL, stderr=lf)
        stderr = log.read_text(errors="replace") if log.exists() else ""
    if code:
        detail = "\n".join(stderr.strip().splitlines()[-5:]) or "command failed"
        raise RuntimeError(f"Error {context}: {detail}")
