# Editing the Python source

Every slide is Python code, and the source pane at the bottom right of the window shows the code of the current
slide. You can read it to see what Manimble wrote, and edit it to do things the canvas can't, such as adding
animations.

## Read the code

The source pane shows the slide's class, with syntax colouring.

- When you select an object, the lines that make it are highlighted.
- After an edit, the lines it changed are highlighted, so you can see exactly what Manimble wrote.
- The inspector's header names the file and line of the selected object.

## Edit the code

1. Click in the source pane. It becomes an editor for the slide's class.
2. Make your changes.
3. Click outside the pane. Manimble writes the class back into its file and renders the slide.

What happens next depends on the result:

- **The code is valid and runs.** The slide updates.
- **The code has a syntax error.** Nothing is written. The error is shown, and your draft stays in the editor so you
  can fix it.
- **The code runs into an error.** The code is kept in the working copy, the error appears above the editor, and the
  canvas keeps showing the last good picture of the slide. Click **Error Details…** for the full message. Fix the
  code and click outside the pane again.

The source pane edits one slide's class at a time. Keep the class name and its `construct` method. To edit helper
functions, the theme in `common.py`, or several slides at once, use an editor or an AI agent in the
[terminal](../ai/terminal.md).

## Common edits

Animate an object instead of having it appear:

```python
# appears at once
self.add(title)

# fades in, then the formula is written stroke by stroke
self.play(FadeIn(title))
self.play(Write(formula), run_time=1.5)
```

Split a slide into builds:

```python
self.play(FadeIn(title))
self.next_slide()                # the presenter clicks here
self.play(Create(diagram))
```

Move or transform objects between builds:

```python
self.play(title.animate.to_edge(UP), FadeIn(subtitle))
self.next_slide()
self.play(Transform(equation, simplified))
```

The [Manim documentation](https://docs.manim.community) describes every object and animation, and the
[Manim Slides documentation](https://manim-slides.eertmans.be) describes builds, loops and notes.

## Keep code editable on the canvas

Manimble edits objects by changing the code that made them. It works best when each object is made by one statement
with literal values:

```python
title = Text("Results", font_size=48).move_to((0, 3, 0))
```

Objects made in loops, from computed strings, or placed by later code can still be shown and often moved, but some
canvas edits won't apply to them. See [Limitations](../reference/limitations.md).

## Edits outside Manimble

You can edit a deck's files in any editor while Manimble has it open, as long as you edit the working copy (where the
[terminal](../ai/terminal.md) starts). Manimble notices saved changes within about two seconds and re-renders the
affected slides, the slide on screen first. While a file has a syntax error, its slides stay in the navigator and show
the error until the file is fixed.
