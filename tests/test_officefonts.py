"""manimble.officefonts: Microsoft Office's fonts (Aptos, Aptos Display, Calibri, ...) found where Office keeps them,
registered for manim, and families Pango can't find (Aptos Display on macOS) drawn with their nearest relative."""

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

ENGINE = Path(__file__).resolve().parents[1] / "engine"
sys.path.insert(0, str(ENGINE))

from manimble import officefonts  # noqa: E402

try:
    import manim  # noqa: F401
    import manimpango  # noqa: F401
except ImportError:                                   # the engine's Python, not the docs' or CI's lint one
    manim = None


class FindingTests(unittest.TestCase):
    def test_resolve(self):
        have = {"Aptos", "Calibri", "Aptos Narrow"}
        self.assertEqual(officefonts.resolve("Aptos Display", have), "Aptos")      # macOS: a style of Aptos
        self.assertEqual(officefonts.resolve("aptos display", have), "Aptos")
        self.assertEqual(officefonts.resolve("Aptos Narrow", have), "Aptos Narrow")
        self.assertEqual(officefonts.resolve("Aptos Display", have | {"Aptos Display"}), "Aptos Display")
        self.assertEqual(officefonts.resolve("Aptos Display", {"Calibri"}), "Aptos Display")   # nothing better
        self.assertEqual(officefonts.resolve("Helvetica Neue", have), "Helvetica Neue")
        self.assertEqual(officefonts.resolve("", have), "")

    def test_files_once_each_and_cloud_families(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            ppt, word = t / "PowerPoint/DFonts", t / "Word/DFonts"
            cloud = t / "CloudFonts"
            for d in (ppt, word, cloud / "Aptos Display", cloud / "Aptos Serif"):
                d.mkdir(parents=True)
            for d in (ppt, word):
                (d / "Aptos.ttf").write_bytes(b"")
                (d / "Aptos-Bold.ttf").write_bytes(b"")
                (d / "readme.txt").write_bytes(b"")
            (cloud / "Aptos Display" / "30169865670.ttf").write_bytes(b"")
            (cloud / "Aptos Serif" / "30169865670.ttf").write_bytes(b"")      # same number, another family
            dirs = [str(ppt), str(word), str(cloud / "Aptos Display"), str(cloud / "Aptos Serif")]
            with mock.patch.object(officefonts, "font_dirs", return_value=dirs):
                files = officefonts.font_files()
            self.assertEqual([Path(f).name for f in files], ["Aptos-Bold.ttf", "Aptos.ttf", "30169865670.ttf", "30169865670.ttf"])
            self.assertEqual([officefonts.cloud_family(f) for f in files], [None, None, "Aptos Display", "Aptos Serif"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS paths")
    def test_mac_dirs(self):
        for d in officefonts.font_dirs():
            self.assertTrue(d.endswith("/DFonts") or "/CloudFonts/" in d, d)


@unittest.skipIf(manim is None, "needs manim and manimpango")
class DrawingTests(unittest.TestCase):
    def test_aliases_in_manim(self):
        # in a fresh process, as the render worker: Pango reads its fonts once, before the first text
        code = textwrap.dedent('''
            import sys, tempfile
            from manimble import officefonts
            officefonts.install()
            import manimpango
            from manim import Text, MarkupText, config
            config.media_dir = tempfile.mkdtemp()
            have = set(manimpango.list_fonts())
            alias = officefonts.resolve("Aptos Display", have)
            w = lambda **kw: round(float(Text("Quarterly Wavefunction", **kw).width), 4)
            m = lambda s, **kw: round(float(MarkupText(s, **kw).width), 4)
            found = [alias, w(font="Aptos Display") == w(font=alias),
                     m("Quarterly Wavefunction", font="Aptos Display") == m("Quarterly Wavefunction", font=alias),
                     m('<span font_family="Aptos Display">Quarterly Wavefunction</span>') == m("Quarterly Wavefunction", font=alias),
                     Text("x", font="Aptos Display").font]
            print("|".join(map(str, found)))
        ''')
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, cwd=tempfile.gettempdir(),
                           env={**os.environ, "PYTHONPATH": str(ENGINE)})
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        alias, same_text, same_markup, same_span, kept = r.stdout.strip().splitlines()[-1].split("|")
        self.assertEqual((same_text, same_markup, same_span), ("True", "True", "True"))
        self.assertEqual(kept, "Aptos Display")       # the slide's code keeps its font; only the drawing is aliased

    def test_text_drawn_before_is_drawn_again(self):
        # a text cached while its Office font was missing (drawn in a substitute) is drawn again once it is registered
        with tempfile.TemporaryDirectory() as media:
            code = textwrap.dedent(f'''
                import sys
                if sys.argv[1] == "1":
                    from manimble import officefonts
                    officefonts.install()
                from manim import Text, config
                config.media_dir = {media!r}
                print(round(float(Text("Quarterly Wavefunction", font="Aptos").width), 4))
            ''')
            env = {**os.environ, "PYTHONPATH": str(ENGINE)}
            run = lambda arg: subprocess.run([sys.executable, "-c", code, arg], capture_output=True, text=True,
                                             cwd=media, env=env).stdout.split()[-1]
            without, with_fonts = run("0"), run("1")
        if not officefonts.font_files():
            self.skipTest("Microsoft Office isn't installed")
        self.assertNotEqual(without, with_fonts)


if __name__ == "__main__":
    unittest.main()
