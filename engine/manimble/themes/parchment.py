"""Shared base class and theme of the deck (Manimble theme "Parchment": dark brown serif on cream, red accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Parchment"
BACKGROUND = "#F5EFE3"
FONT = "Palatino"
TEXT_COLOR = "#3B2F24"  # titles and body text
MUTED_COLOR = "#8A7A66"  # subtitles and captions
ACCENT = "#A23B2A"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
