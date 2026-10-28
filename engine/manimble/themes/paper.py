"""Shared base class and theme of the deck (Manimble theme "Paper": near-black text on white, blue accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Paper"
BACKGROUND = "#FFFFFF"
FONT = "Helvetica Neue"
TEXT_COLOR = "#1D1D1F"  # titles and body text
MUTED_COLOR = "#6E6E73"  # subtitles and captions
ACCENT = "#0A66C2"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
