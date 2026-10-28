"""Shared base class and theme of the deck (Manimble theme "Ember": warm white text on charcoal, orange accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Ember"
BACKGROUND = "#17140F"
FONT = "Helvetica Neue"
TEXT_COLOR = "#FBF6F0"  # titles and body text
MUTED_COLOR = "#B8AEA3"  # subtitles and captions
ACCENT = "#FF6C0C"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
