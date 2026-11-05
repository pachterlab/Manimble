# Introduction

Manimble is a presentation app for macOS whose slides are Python programs. It gives you the editing experience of
PowerPoint or Keynote on top of [Manim](https://www.manim.community), the animation library used to make
mathematical and scientific videos. This page explains what that means and why it is useful.

## Slides as programs

In most presentation apps a slide is a document: a set of boxes stored in a file format only that app fully
understands. In Manimble a slide is a small Python class. Here is a complete slide:

```python
class Results(Deck):
    def construct(self):
        title = Text("Results", font_size=48).move_to((0, 3, 0))
        curve = MathTex(r"y = e^{-x^2}").move_to((0, 0.5, 0))
        self.play(FadeIn(title), Write(curve))
```

Manim runs this code to draw the slide. The `self.play(...)` line is an animation: when you present, the title fades
in and the formula is written stroke by stroke. Manim Slides, an extension of Manim, adds the idea of *builds*: each
call to `self.next_slide()` is a point where the presentation waits for you to click.

Writing slides this way has real advantages:

- **Animations.** Objects move, grow, fade, morph into one another and follow paths. A diagram can assemble itself
  in front of the audience instead of appearing all at once.
- **Mathematics.** Formulas are typeset by LaTeX, so they look exactly as they do in a paper.
- **Data.** A plot can be drawn by your own Python code and redrawn whenever the data changes.
- **Text you can manage.** A deck is a folder of plain text files. You can keep it in git, compare versions, search
  it, and reuse code between slides.

The drawback has always been that you had to write all of it by hand: positions as coordinates, styles as keyword
arguments, and a render to see each change. Manimble removes that drawback.

## What Manimble adds

Manimble shows your slides rendered, and lets you edit them the way you would in any presentation app:

- Click an object to select it, drag it to move it, and drag a corner to resize it.
- Double-click text to retype it. Select a few words and make them bold, italic, coloured or underlined.
- Insert text, formulas, shapes, tables, pictures and plots from the toolbar.
- Add, duplicate, hide and reorder slides, and add builds.
- Present with the real animations, with Presenter View and speaker notes.

Every one of these actions is translated into a precise edit of your Python code. Move a title and its
`.move_to(...)` coordinates change. Make a word bold and the `Text(...)` call gains a style for those characters.
Insert a rectangle and one line is added to the slide. Manimble then re-runs the slide to check that the edit did
what you asked. The code stays as readable as if you had written it yourself, so you can open it at any time, change
it, and carry on editing on the canvas.

!!! info "Do I need to know Python?"
    No. You can build and present a complete deck without reading any code. Knowing a little Python and Manim helps
    when you want custom animations or plots, and the source of every slide is always one click away.

## Editing with AI agents

Because a slide is code, an AI coding agent such as Claude Code, Codex or Gemini CLI can write it too. Manimble has a
terminal built in. Start an agent there and ask it for what you want: "add a slide comparing the two methods, with
the table appearing first and the plot in a second build". The agent edits the deck's files, Manimble notices within
a couple of seconds, and the slides re-render in front of you.

You and the agent work on the same deck at the same time. Ask the agent to draft a slide, then nudge its title into
place with the mouse, retype a label, and ask the agent for the next change. Manimble gives each agent instructions
on how to keep the code in a form the canvas can edit. See
[Building slides with an AI agent](../ai/agents.md) for the complete workflow.

## How your files are kept safe

When you open a deck, Manimble makes a private *working copy* of it. Everything you do on the canvas, and everything
an agent does in the terminal, changes the working copy. Your original files change only when you choose
**File ▸ Save to Original** (<kbd>⌘</kbd><kbd>S</kbd>), and **File ▸ Revert to Original** throws away everything since
the last save. See [Key concepts](concepts.md) for details.

## Who Manimble is for

- **Scientists and mathematicians** who want equations, diagrams and data plots that animate, without giving up the
  convenience of a slide editor.
- **Teachers** who want explanations that unfold step by step.
- **Manim users** who already write slides in code and want a faster way to lay them out, format them and present
  them.
- **Anyone who works with AI coding agents** and wants a presentation format that an agent can write well and a
  person can still edit comfortably.

## Next steps

- [Install Manimble](installation.md).
- Make a first deck with the [Quick start](quick-start.md).
- Learn the vocabulary (decks, slides, builds, the working copy) in [Key concepts](concepts.md).
