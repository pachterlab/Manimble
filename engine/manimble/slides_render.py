"""`python slides_render.py render ...`: manim's command line, with manim-slides patched so that a slide which only
adds objects and never plays an animation still builds (as a 0.1 s clip of what it shows).

manim-slides refuses such a slide ("You have to play at least one animation ... before pausing"): its last build is
recorded when the scene ends, and a build with no animation in it is an error. New slides and builds that Manimble
writes end in `self.wait(0.1)` for that reason; slides written by hand (`self.add(...)` and nothing else) get the
same wait here, at build time, so Play from Beginning and the movie export do not stop on them.

Every wait() also runs the updaters first, as manim does before a play(), so lines redrawn from the objects they are
attached to (`always_redraw`) follow an object moved by a statement since the last animation.
"""
import functools
import os
import shutil
import sys

# Running a script puts its folder first on sys.path; the engine's modules must not shadow the deck's.
if sys.path and os.path.realpath(sys.path[0]) == os.path.realpath(os.path.dirname(os.path.abspath(__file__))):
    sys.path.pop(0)

from manim_slides.slide.manim import Slide  # noqa: E402

_tear_down = Slide.tear_down


def _tear_down_with_animation(self) -> None:
    # the last build is recorded once the scene has rendered, from the animations since the last next_slide(): an
    # empty range is an error there, so play a short wait while clips are still being written
    settled = len(self._slides) > 0 and self._current_animation == self._slides[-1].end_animation
    if not settled and self._current_animation == self._start_animation:
        self.wait(0.1)
    _tear_down(self)


Slide.tear_down = _tear_down_with_animation

_wait = Slide.wait


def _wait_updated(self, *args, **kwargs):
    # a wait() with no time-based updater is a frozen frame: manim runs no updaters, so an arrow redrawn from an
    # object (`always_redraw(lambda: Arrow(box.get_right(), ...))`) moved since the last play() would not follow it
    self.update_mobjects(0)
    return _wait(self, *args, **kwargs)


Slide.wait = _wait_updated


# Builds run several at a time, each in a media dir of its own (LaTeX's cleanup deletes every non-SVG file in its
# tex dir). The SVGs are shared through the editor workers' pool (worker.py does the same): a formula or text that
# was ever built, in the editor or by another build, is not built again.
_POOL = os.environ.get("MANIMBLE_SHARED_MEDIA")


def _pool_fetch(target, sub: str):
    try:
        if target.exists():
            return
        src = os.path.join(_POOL, sub, target.name)
        if os.path.exists(src):
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = f"{target}.{os.getpid()}.tmp"
            shutil.copyfile(src, tmp)
            os.replace(tmp, target)
    except OSError:
        pass


def _pool_publish(path, sub: str):
    try:
        path = str(path)
        dst = os.path.join(_POOL, sub, os.path.basename(path))
        if not path.endswith(".svg") or os.path.exists(dst) or not os.path.exists(path):
            return
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = f"{dst}.{os.getpid()}.tmp"
        try:
            os.link(path, tmp)
        except OSError:
            shutil.copyfile(path, tmp)
        os.replace(tmp, dst)
    except OSError:
        pass


def _share_svgs():
    from manim import config, Text, MarkupText, ManimColor
    import manim.utils.tex_file_writing as tfw
    import manim.mobject.text.tex_mobject as tm

    def share_text(cls, colour_of):
        orig = cls._text2svg

        @functools.wraps(orig)
        def wrapper(self, color):
            try:
                _pool_fetch(config.get_dir("text_dir") / (self._text2hash(colour_of(color)) + ".svg"), "texts")
            except Exception:                  # noqa: BLE001 - the pool is only a shortcut
                pass
            out = orig(self, color)
            _pool_publish(out, "texts")
            return out
        cls._text2svg = wrapper

    orig_tex = tfw.tex_to_svg_file

    @functools.wraps(orig_tex)
    def tex_wrapper(expression, environment=None, tex_template=None):
        try:
            _pool_fetch(tfw.generate_tex_file(expression, environment, tex_template).with_suffix(".svg"), "Tex")
        except Exception:                      # noqa: BLE001
            pass
        out = orig_tex(expression, environment, tex_template)
        _pool_publish(out, "Tex")
        return out

    share_text(Text, lambda c: c)
    share_text(MarkupText, ManimColor)
    tfw.tex_to_svg_file = tex_wrapper
    tm.tex_to_svg_file = tex_wrapper


if _POOL:
    _share_svgs()

if __name__ == "__main__":
    from manim.__main__ import main

    sys.argv = ["manim"] + sys.argv[1:]
    main()
