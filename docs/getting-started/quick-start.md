# Quick start

This walkthrough makes a short deck with a title slide, a slide with bullet points and a formula, and an animation,
then presents it. It takes about ten minutes.

## 1. Create a deck

1. Choose **File ▸ New Deck…** (<kbd>⌘</kbd><kbd>N</kbd>).
2. Type a name for the deck, for example *My First Talk*, and choose where to keep it.
3. Pick a **Theme** from the menu at the bottom of the dialog. *Midnight* (white on black) is the default; you can
   change the theme at any time.
4. Click **Save**.

Manimble creates a folder with that name and opens the new deck. It has one slide, a title slide.

## 2. Edit the title slide

1. Double-click the title text. A text box opens on the slide.
2. Type your title, then click anywhere outside the box (or press <kbd>⌘</kbd><kbd>↩</kbd>) to apply it.
3. Do the same for the subtitle.
4. Drag the title to move it. Drag a corner handle to make it bigger or smaller.

Each change is written into the slide's code and checked by re-rendering the slide in the background. The canvas
shows the change at once, so you don't wait for the render.

## 3. Add a slide with bullet points

1. Click **New Slide** in the toolbar. It adds a **Title and Content** slide after the current one.
2. Click the *Click to add title* placeholder and type a title.
3. Click the content placeholder and type three lines, pressing <kbd>↩</kbd> between them. Each line starts with a
   bullet automatically.
4. Before clicking away, select one word and press <kbd>⌘</kbd><kbd>B</kbd> to make it bold. Then click outside the
   box.

To turn bullets off, or on for other text, select the text and choose **Format ▸ Bulleted List**
(<kbd>⇧</kbd><kbd>⌘</kbd><kbd>8</kbd>).

## 4. Add a build

So far everything on the slide appears at once. A *build* is a step of the slide that waits for a click. Add a second
build for a formula:

1. Click **New Build** in the toolbar. A second build is added after the current one, starting with everything the
   first build shows, and Manimble switches to it.
2. The navigator on the left now shows the slide with two builds. Use <kbd>⌘</kbd><kbd>[</kbd> and
   <kbd>⌘</kbd><kbd>]</kbd> to step between them.

## 5. Add a formula

1. On the second build, choose **Insert ▸ Formula…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd>).
2. Type some LaTeX, for example `e^{i\pi} + 1 = 0`. The preview updates as you type.
3. Apply it. The formula appears on the slide; drag it into place.

Objects you insert are added at the build on screen, so the formula appears only when the presenter clicks past the
first build.

!!! tip
    To animate the formula (written stroke by stroke rather than appearing), open the slide's code in the source
    pane and change its `self.add(...)` into `self.play(Write(...))`. Or ask an AI agent to do it; see
    [Building slides with an AI agent](../ai/agents.md).

## 6. Present

1. Choose **Play ▸ Play from Beginning** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).
2. Click, or press <kbd>→</kbd> or <kbd>Space</kbd>, to advance. Press <kbd>Esc</kbd> to stop.

With **Play ▸ Show Animations** on, Manimble first builds the real animations (the first time takes a little longer)
and plays them. With it off, the show steps through still pictures of each build. See
[Playing a presentation](../presenting/playing.md).

## 7. Save

Choose **File ▸ Save to Original** (<kbd>⌘</kbd><kbd>S</kbd>). Until you save, your changes live in Manimble's
working copy of the deck, and the window is marked as edited. If you close the window with unsaved changes,
Manimble asks whether to save them.

## Where to go next

- [Key concepts](concepts.md) explains decks, builds and the working copy.
- [The Manimble window](../guide/window.md) tours every part of the interface.
- [Building slides with an AI agent](../ai/agents.md) shows how to draft and revise slides with Claude Code, Codex
  or Gemini CLI.
- The repository includes a small sample deck at `examples/hello/deck`. Open it with
  **File ▸ Open Deck or Project…** to experiment.
