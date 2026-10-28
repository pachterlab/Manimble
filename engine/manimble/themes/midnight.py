"""Shared base class and theme of the deck (Manimble theme "Midnight": white text on black, violet accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Midnight"
BACKGROUND = "#000000"
FONT = "Helvetica Neue"
TEXT_COLOR = "#FFFFFF"  # titles and body text
MUTED_COLOR = "#BBBBBB"  # subtitles and captions
ACCENT = "#7C5CFF"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
