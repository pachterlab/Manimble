# manim 0.21 pitfalls

Manimble pins manim 0.21.0 and manim-slides 5.7.0 (`engine/requirements.txt`).
Items marked *checked* were run on that stack on 2026-11-25.

- **Text runs wider than expected.** The most common defect. Width depends on
  the letters as much as on their number. In Helvetica Neue at `font_size=30`,
  a 54-character mixed-case sentence is 9.6 units wide but 45 capitals are 12.2
  units, and 53 `x` characters at `font_size=40` are 15.2 units, wider than the
  14.2-unit frame (*checked*). Render and look rather than trusting a
  character count.
- **`Text` strips leading spaces** (*checked*), so indenting a continuation
  line does nothing; move the object instead. Multi-line `Text` is
  left-aligned; to centre several lines, make one `Text` per line and
  `arrange(DOWN)` them.
- A line break is `\n` inside the Python string; `"/n"` prints literally.
- **Tick labels turn into `2.00`.** `Axes` and `NumberLine` take the number of
  decimals from the tick step by default (2, 4, 6; 0.4, 0.8). Passing a
  `decimal_number_config` replaces that default, so `{"color": ...}` alone
  prints `2.00` (*checked*). Recolour a built axis with `.set_color(...)`, which
  keeps the format; when you do pass a `decimal_number_config`, include
  `num_decimal_places`.
- **`BarChart` and `Axes` draw the x-axis at y = 0**, which is the top of the
  chart when every value is negative, such as log values (*checked*). Offset the
  data so the axis sits at the bottom and label the ticks yourself.
- **Colouring part of a `MathTex`.** With `substrings_to_isolate=[...]` plus
  `set_color_by_tex`, or `tex_to_color_map={...}`, the formula stays one
  submobject (`len(m) == 1`, *checked*) and only the glyphs are recoloured, so
  look at the frame to confirm. To move, fade or index one piece on its own,
  pass the pieces as separate strings, `MathTex("a", r"\ge", "b")`, and use
  `m[1]`; each piece then also stays editable in Manimble. `\color{NAME}` with
  an undefined name fails to compile. Split a long formula into two `MathTex`
  lines rather than scaling one down.
- **`Code`** takes `code_string=...` in 0.21 (*checked*); `Code(code=...)` is
  the older API. Example: `Code(code_string=src, language="python",
  paragraph_config={"font": "Menlo", "font_size": 20}, background="rectangle")`.
- **`Table`:** `get_entries_without_labels()` gives the cells for one-by-one
  reveals. A table with three wide text columns needs about `font_size=18` to
  stay in the frame.
- **`LaggedStart` over hundreds of small animations is very slow.**
  `FadeIn(group)` is near instant and looks much the same. Hundreds of `Dot`s
  in one `VGroup` are fine for `FadeIn` and `Transform`.
- **Fonts** must exist on the machine: Helvetica Neue, Avenir Next, Palatino
  and Menlo do on macOS. Set `font=` on every `Text`, through the theme's
  `FONT`.
- **Pictures crash outside Manimble's renderers** with "ValueError: Invalid
  mode for data type": manim 0.21 cannot draw an `ImageMobject` under Pillow 13,
  which Manimble's Python ships (*checked*). Manimble's own renderers patch this
  (`engine/manimble/pilcompat.py`, used by the app, `slides_render.py` and the
  manimble-check skill's `render_stills.py`); plain `manim` or `manim-slides`
  run with that Python do not. Render through one of those, or call
  `pilcompat.install()` first in your own script.
- Useful primitives: `DashedVMobject(...)` for dashed curves, `GrowArrow` for
  arrows, `Indicate` to point at a table cell or a term,
  `Succession(FadeIn(dot), MoveAlongPath(dot, path))` for a particle on a path.
