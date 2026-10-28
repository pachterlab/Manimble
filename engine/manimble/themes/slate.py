"""Shared base class and theme of the deck (Manimble theme "Slate": light text on dark blue-grey, teal accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Slate"
BACKGROUND = "#1E2430"
FONT = "Avenir Next"
TEXT_COLOR = "#E8ECF2"  # titles and body text
MUTED_COLOR = "#9AA5B5"  # subtitles and captions
ACCENT = "#4FD1C5"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
