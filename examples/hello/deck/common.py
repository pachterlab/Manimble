"""Shared base class and constants for the hello deck."""

from manim import *
from manim_slides import Slide

FONT = "Helvetica Neue"
ACCENT = "#7C5CFF"


class Deck(Slide):
    """Every slide of the deck derives from this."""

    skip_reversing = True


def label(text, size=30, color=WHITE, **kwargs):
    """A text label in the deck font."""
    return Text(text, font=FONT, font_size=size, color=color, **kwargs)
