---
title: Manimble
hide:
  - navigation
  - toc
---

<div class="mb-hero" markdown>
<img src="assets/manimble-icon.png" alt="Manimble icon">
<div markdown>
# Manimble
A slide editor for presentations made with [Manim](https://www.manim.community), the animation engine behind
mathematical videos. Edit your slides with the mouse, write them in Python, or ask an AI coding agent to build
them, all on the same deck.
</div>
</div>

<div class="mb-buttons" markdown>
[Download for macOS](https://github.com/pachterlab/Manimble/releases/latest/download/Manimble-macOS.dmg){ .md-button .md-button--primary }
[Manual](getting-started/introduction.md){ .md-button }
[View on GitHub](https://github.com/pachterlab/Manimble){ .md-button }
</div>

## What Manimble does

Manimble looks and works like a presentation app: a list of slides on the left, the slide in the middle, and an
inspector on the right. You click a title to retype it, drag a picture to move it, and press <kbd>⌘</kbd><kbd>B</kbd>
to make a word bold. Underneath, every slide is a short Python program written for Manim and
[Manim Slides](https://github.com/jeertmans/manim-slides). Each change you make on the canvas is written back into
that program as a small, readable edit.

Because the slides are code, a presentation can do what slide software can't. Formulas are typeset by LaTeX, objects
move and transform with real animations, and plots are drawn by Python from your data. And because Manimble keeps the
code clean and editable, you can open a terminal in the app, start Claude Code, Codex or Gemini CLI, and have the
agent write or revise slides while you watch them update and keep editing them by hand.

<div class="grid cards" markdown>

-   :material-cursor-default-click-outline:{ .lg .middle } **Edit on the slide**

    ---

    Move, resize and retype text, formulas, pictures, shapes and tables. Format individual words, add slides from
    layouts, and arrange objects with guides and snapping.

    [:octicons-arrow-right-24: Editing slides](guide/window.md)

-   :material-robot-outline:{ .lg .middle } **Build slides with an AI agent**

    ---

    Run an AI coding agent in Manimble's terminal. Its edits appear on the slides within seconds, side by side with
    your own.

    [:octicons-arrow-right-24: AI agents and the terminal](ai/agents.md)

-   :material-presentation-play:{ .lg .middle } **Present with animations**

    ---

    Play the real Manim animations full screen, with Presenter View, speaker notes, a timer, and scripted
    presentations that narrate themselves.

    [:octicons-arrow-right-24: Presenting](presenting/playing.md)

-   :material-share-variant-outline:{ .lg .middle } **Import and share**

    ---

    Bring in PowerPoint, Keynote and Beamer decks. Export to PowerPoint, Keynote, Beamer, PDF and MP4, or package a
    deck for another Manimble user.

    [:octicons-arrow-right-24: Sharing](sharing/import.md)

</div>

## Get started

1. [Install Manimble](getting-started/installation.md) on a Mac running macOS 13 or later.
2. Read the [Introduction](getting-started/introduction.md) to see how Manimble differs from other presentation
   apps.
3. Follow the [Quick start](getting-started/quick-start.md) to make your first deck.

Manimble is free and open source under the BSD 2-Clause License. Report problems and suggest features on
[GitHub Issues](https://github.com/pachterlab/Manimble/issues).
