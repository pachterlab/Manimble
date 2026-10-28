"""Shared base class and theme of the deck (Manimble theme "Chalkboard": chalk-white handwriting on green, yellow accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Chalkboard"
BACKGROUND = "#23352B"
FONT = "Chalkboard SE"
TEXT_COLOR = "#F4F1E8"  # titles and body text
MUTED_COLOR = "#B9C2B0"  # subtitles and captions
ACCENT = "#F2C14E"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
