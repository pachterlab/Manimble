# Troubleshooting and FAQ

## Troubleshooting

### A slide shows an error

Select the slide. The error appears above the source pane, and **Error Details…** shows the full message, with the
line of code where it happened. The canvas keeps the last picture that rendered. Fix the code in the source pane, or
ask an AI agent in the terminal to fix it. If the error came from an edit you just made on the canvas,
<kbd>⌘</kbd><kbd>Z</kbd> undoes it.

### A formula won't render

Usually a LaTeX package is missing, and the error names a missing `.sty` file. Install the package in the terminal:

```bash
tlmgr install <package>        # TinyTeX installed by Manimble
sudo tlmgr install <package>   # a system-wide TeX such as MacTeX or BasicTeX
```

For example, Manim's Chinese template needs `ctex`. Then edit the formula again, or choose another slide and come
back.

### Manimble can't find Python or Manim

Choose **Manimble ▸ Install Dependencies…** to open the setup window, and install Manimble's own Python. Or choose
**Manimble ▸ Choose Python…** to point Manimble at a Python that can import Manim.

### Edits take a long time to appear

The canvas shows each change at once, while the slide is re-rendered in the background to confirm it. Some work takes
longer:

- **A new formula** is compiled by LaTeX once (about half a second), then cached.
- **Slides with many formulas or objects** re-render more slowly.
- **Playing, previewing or exporting animations** builds the real animations; the first time on a deck, every slide
  is built.
- **Higher animation resolutions** build more slowly.
- **Deck-wide changes**, such as applying a theme or dark mode, re-render every slide.
- **Edits from the terminal** re-render the slide on screen first, usually within one to three seconds; the others
  follow in the background.

### Slides disappeared from the navigator

If an edit made outside Manimble left a file that doesn't parse, its slides stay listed and show the error until the
file is fixed. If a slide is missing entirely, check that its class is listed in `order.txt`, or turn on
**View ▸ Show Unused Slides**.

### The AI agent's edits don't show

See [Troubleshooting](../ai/agents.md#troubleshooting) in the AI agents chapter.

## FAQ

### Why use Manimble instead of PowerPoint, Keynote or Google Slides?

- **Real animations.** Objects write, transform, grow and move between builds, instead of fixed slide transitions.
- **LaTeX formulas,** typeset by your TeX installation with a live preview.
- **Slides as Python.** Decks can live in git, be compared and searched, be edited by hand or by script, and be
  written by an AI agent in the built-in terminal.
- **Live plots,** drawn by your own Python code and updated when the data changes.
- **BioCartoon** scientific illustrations, built in.
- **Presenter tools:** Presenter View, feedback notes during practice talks, and scripted presentations that narrate
  themselves.
- **Beamer import and export,** alongside PowerPoint and Keynote, for moving between LaTeX and slide workflows.

### Do I need to know Python or Manim?

No. Moving, resizing, retyping, formatting and inserting all happen on the slide, and Manimble writes the code.
Python helps when you want custom animations or plots, and an AI agent can write those for you.

### Can I still use my deck without Manimble?

Yes. A Manimble deck is an ordinary Manim Slides project. You can render it with `manim-slides render` and present
it with `manim-slides present`, edit it in any editor, and keep it in git.

### Can I open a deck I wrote by hand?

Yes. Open its folder with **File ▸ Open Deck or Project…**. Manimble finds every slide class, and everything it can
trace to a line of code becomes editable on the canvas. See [Limitations](limitations.md) for code it edits only
partly.

### Can I import my existing PowerPoint or Keynote deck?

Yes, with **File ▸ Import**. Text, pictures, tables, shapes and lines become editable Manim objects; animations,
transitions, charts and SmartArt are not imported. See [Importing presentations](../sharing/import.md).

### Can I share my slides with people who don't have Manimble?

Yes. Export to PowerPoint, Keynote, Beamer, PDF or a movie. To share with a Manimble user, use
**File ▸ Package for Sharing…**. See [Exporting](../sharing/export.md) and
[Projects and packages](../sharing/projects.md).

### Can I put a Manimble animation into a PowerPoint, Keynote or Google Slides deck?

Yes. Export the slide as a movie (right-click it in the navigator and choose **Export Slide as Movie (.mp4)…**) and
insert the movie into the other deck.

### Which AI coding agents work with Manimble?

Any agent that runs in a terminal. Manimble's Run button has built-in entries for Claude Code, Codex and Gemini CLI,
and accepts any other command. See [Building slides with an AI agent](../ai/agents.md).

### Where are my files?

Your decks stay where you keep them. While a deck is open, Manimble works on a copy under
`~/Library/Application Support/Manimble/work`, and writes it back when you save. Render caches are kept under
`~/Library/Application Support/Manimble/cache`.

### Is Manimble free?

Yes. Manimble is free and open source under the BSD 2-Clause License. The source is on
[GitHub](https://github.com/pachterlab/Manimble).

### How do I report a problem?

Open an issue on [GitHub Issues](https://github.com/pachterlab/Manimble/issues). Include your macOS version, whether
your Mac has Apple Silicon or Intel, and, if you can, the deck or the slide code that shows the problem.
