"""Pillow 13 with manim 0.21: the one call of manim's that Pillow no longer accepts.

To draw a picture (an ImageMobject), manim 0.21's Camera.display_image_mobject starts from a blank canvas made as
`Image.fromarray(np.zeros((h, w)), mode="RGBA")`. Pillow 13 dropped the `mode` argument's reinterpretation of the
array's bytes, so a float array with mode "RGBA" raises "Invalid mode for data type" and no slide with a picture
renders. manim 0.22 makes the canvas with `Image.new("RGBA", (w, h), (0, 0, 0, 0))` instead; Manimble stays on manim
0.21 for manim-slides, so `install()` gives fromarray that one case back, with the same result as the old Pillow (a
transparent canvas). Every other call goes to Pillow unchanged. Drop this module once manim is 0.22 or later.
"""

_installed = False


def install() -> None:
    """Patch PIL.Image.fromarray in this process (idempotent)."""
    global _installed
    if _installed:
        return
    import numpy as np
    from PIL import Image

    original = Image.fromarray

    def fromarray(obj, mode=None, *args, **kwargs):
        try:
            return original(obj, mode, *args, **kwargs) if mode is not None else original(obj, *args, **kwargs)
        except ValueError:
            a = np.asarray(obj) if mode is not None else None
            if a is not None and a.ndim == 2 and not a.any():         # manim 0.21's blank canvas
                return Image.new(mode, (a.shape[1], a.shape[0]))
            raise

    fromarray.__doc__ = original.__doc__
    fromarray.__wrapped__ = original
    Image.fromarray = fromarray
    _installed = True
