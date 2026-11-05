# Manimble

A slide editor for presentations made with [Manim](https://www.manim.community) and
[Manim Slides](https://github.com/jeertmans/manim-slides). Every slide is Python code: edit it on the canvas like
in PowerPoint or Keynote, in the built-in code editor, or with an AI coding agent such as Claude Code, Codex or
Gemini CLI running in Manimble's terminal. All three can work on the same deck at the same time.

**📖 Documentation: [pachterlab.github.io/Manimble](https://pachterlab.github.io/Manimble/)**. The user guide covers
everything Manimble does, from a first deck to presenting, with a chapter on
[building slides with an AI agent](https://pachterlab.github.io/Manimble/ai/agents/).

## Installation

Manimble runs on macOS 13 or later, on both Apple Silicon and Intel Macs (the app is a universal binary). Windows and
Linux versions are planned.

### Precompiled binary

Download [Manimble-macOS.dmg](https://github.com/pachterlab/Manimble/releases/latest/download/Manimble-macOS.dmg),
open it and drag Manimble to Applications. The app is signed and notarized. On first launch Manimble looks for what
it needs and offers to install whatever is missing, with no Homebrew and no Terminal:

- **Python with Manim**: a self-contained Python runtime (about 150 MB to download) in
  `~/Library/Application Support/Manimble/python`. Skipped when a Python that can import Manim is already found.
- **LaTeX** for formulas: [TinyTeX](https://yihui.org/tinytex/) (about 80 MB to download) in `~/Library/TinyTeX`,
  plus the packages Manim uses. An existing TeX installation such as MacTeX is used instead; if it lacks some of
  those packages they are added to it, which asks for your password because a system TeX lives in a system folder.

Both go into your user Library, so no administrator password is needed otherwise. *Manimble ▸ Install Dependencies…*
reopens the setup window later. All versions are on the [Releases](https://github.com/pachterlab/Manimble/releases)
page.

### Compile directly

```bash
git clone https://github.com/pachterlab/Manimble.git && cd Manimble
./install_manimble.sh                   # installs dependencies and builds the app
open "$HOME/Applications/Manimble.app"  # File ▸ Open Deck or Project… (try examples/hello/deck)
```

Requirements:
- macOS 13+, Xcode or the command line tools, and Homebrew. The installer downloads
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), creates a Python environment in
  `~/Library/Application Support/Manimble/python`, and installs Manim, Manim Slides (no Qt / PySide6: Manimble plays
  animations itself), Pillow, python-pptx, the [BioCartoon](https://biocartoon.com) icon search (`biocartoon`) and
  FFmpeg when they are missing. For formulas it installs [BasicTeX](https://www.tug.org/mactex/morepackages.html) plus
  the LaTeX packages Manim uses (about 400 MB, against several GB for the full MacTeX), and asks for your password once
  because TeX lives in a system folder. An existing TeX installation such as MacTeX is used as it is. A deck that needs
  another LaTeX package can add it with `sudo tlmgr install <package>` (Manim's Chinese `ctex` template, for instance,
  needs `ctex`).
- Keynote is needed only for Keynote import and export.

On launch Manimble checks `$MANIMBLE_PYTHON`, your saved choice, its installed Python environment, a checkout-local
`.venv`, and Python on your login shell's `PATH`. It uses the first one that can import Manim and Pillow, so no
Python chooser is needed after `install_manimble.sh` completes; with none found it offers to install one.

`~/Applications/Manimble.app` carries the engine and uses the installed Python environment. Rerun
`install_manimble.sh` after pulling changes.

### Decks

A deck is a folder of scene classes (`class MySlide(Slide): def construct(self): ...`). If it has an `order.txt`
(scene names separated by spaces or new lines), only those scenes, in that order, are the slides of the talk;
otherwise every scene class is listed. *File ▸ New Deck…* makes a new one, and *File ▸ Import* converts PowerPoint,
Keynote and Beamer presentations. See the [documentation](https://pachterlab.github.io/Manimble/) for the rest.

## Command-line tools

`manimbler` inspects, extracts, and converts portable `.manimble` projects. The installer places it at
`~/.local/bin/manimbler`; it can also be run as `./manimbler` from this repository.

```bash
manimbler --check deck.manimble
manimbler --info deck.manimble
manimbler --extract deck.manimble --output deck-unpacked
manimbler --convert deck.manimble --output talk.mp4
manimbler --convert deck.manimble --slides 1-3,7 --output excerpt.mp4
manimbler --convert deck.manimble --to pdf --output handout.pdf
manimbler --convert deck.manimble --to html --output presentation.html
```

`--check` verifies the archive and its referenced media. `--info` shows slide order, build counts, package sizes, and
estimated MP4 running time. `--extract` creates an editable project directory, defaulting to the package name without
`.manimble`. Conversion follows `order.txt`; `--slides` accepts 1-based numbers, ranges, and scene names, and keeps
their deck order. The output defaults to the package name with the requested format's extension. MP4 conversion plays
each build once at its recorded playback rate and holds its final frame for two seconds; use `--hold 0` for no pauses
or `--fps` to change the frame rate. MP4 output has no audio. PDF and HTML export use the installed Manim Slides
environment. Keep the generated HTML alongside its `_assets` directory when sharing it. Use `--force` to replace
existing conversion output.
