"""manimble.pilcompat: manim 0.21 draws pictures on a blank canvas made with Image.fromarray(zeros, mode="RGBA"),
which Pillow 13 rejects; the shim gives that one call back and leaves every other call to Pillow."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))

try:
    import numpy as np
    from PIL import Image
except ImportError:                                   # the engine's Python, not the docs' or CI's lint one
    np = Image = None


@unittest.skipIf(Image is None, "needs numpy and Pillow")
class PilCompatTests(unittest.TestCase):
    def setUp(self):
        from manimble import pilcompat
        pilcompat.install()

    def test_manim_blank_canvas(self):
        img = Image.fromarray(np.zeros((4, 3)), mode="RGBA")
        self.assertEqual((img.mode, img.size), ("RGBA", (3, 4)))
        self.assertEqual(img.getpixel((0, 0)), (0, 0, 0, 0))

    def test_other_calls_unchanged(self):
        rgba = np.full((2, 5, 4), 200, dtype=np.uint8)
        self.assertEqual(Image.fromarray(rgba, mode="RGBA").getpixel((4, 1)), (200, 200, 200, 200))
        self.assertEqual(Image.fromarray(rgba).mode, "RGBA")
        if int(Image.__version__.split(".")[0]) >= 13:   # a real mismatch still fails, as Pillow 13 has it
            with self.assertRaises(ValueError):
                Image.fromarray(np.ones((4, 3)), mode="RGBA")

    def test_install_twice(self):
        from manimble import pilcompat
        pilcompat.install()
        self.assertTrue(hasattr(Image.fromarray, "__wrapped__"))
        self.assertFalse(hasattr(Image.fromarray.__wrapped__, "__wrapped__"))


if __name__ == "__main__":
    unittest.main()
