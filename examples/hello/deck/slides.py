"""A tiny deck to try Manimble on."""

from common import *
from config import FORMULA, SUBTITLE, TITLE


class Welcome(Deck):
    def construct(self):
        title = label(TITLE, 56)
        subtitle = label(SUBTITLE, 28, GREY_B)
        rule = Line(LEFT * 2.2, RIGHT * 2.2, color=ACCENT, stroke_width=5)
        VGroup(title, rule, subtitle).arrange(DOWN, buff=0.35)
        self.play(FadeIn(title), Create(rule), FadeIn(subtitle), run_time=0.8)


class Shapes(Deck):
    def construct(self):
        heading = label("Shapes, lines and text", 40).to_corner(UL, buff=0.5)
        box = Rectangle(width=3.2, height=1.8, color=ACCENT, stroke_width=5).move_to((-3.5, 0, 0))
        circle = Circle(radius=1.0, color=ORANGE, stroke_width=5).move_to((3.5, 0, 0))
        arrow = Arrow((-1.7, 0, 0), (2.2, 0, 0), buff=0, color=WHITE)
        caption = label("drag, resize, retype", 26, GREY_B).move_to((0, -2.4, 0))
        self.add(heading, box, circle, arrow, caption)


class Formula(Deck):
    def construct(self):
        heading = label("A formula, in builds", 40).to_corner(UL, buff=0.5)
        formula = MathTex(FORMULA, font_size=96).move_to((0, 0.6, 0))
        self.play(FadeIn(heading), FadeIn(formula), run_time=0.6)
        self.next_slide()

        note = label("Double-click the formula to edit its LaTeX", 28, GREY_B).move_to((0, -1.6, 0))
        self.play(FadeIn(note), run_time=0.5)
        self.next_slide()

        table = MathTable([[1, 2, 3], [4, 5, 6]], include_outer_lines=True).scale(0.6).move_to((0, -3.0, 0))
        self.play(FadeIn(table), run_time=0.5)
