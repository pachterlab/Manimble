"""Shared base class and theme of the deck (Manimble theme "Terminal": monospace on near-black, green accent).

Manimble writes new text in FONT and TEXT_COLOR, and new shapes in TEXT_COLOR; manim.cfg holds BACKGROUND.
"""

from pathlib import Path

from manim import *
from manim_slides import Slide

ASSETS = Path(__file__).resolve().parent.parent / "assets"

THEME = "Terminal"
BACKGROUND = "#0D1117"
FONT = "Menlo"
TEXT_COLOR = "#E6EDF3"  # titles and body text
MUTED_COLOR = "#8B949E"  # subtitles and captions
ACCENT = "#3FB950"  # rules and highlights


class Deck(Slide):
    skip_reversing = True
