# The Manimble window

Each open deck has its own window. This page names the parts of the window; the rest of the guide refers to them.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Toolbar                                                                      │
├──────────────────────────────────────────────────────────────────────────────┤
│ Home bar                                                         Find        │
├────────────┬────────────────────────────────────────────┬────────────────────┤
│            │                                            │                    │
│ Navigator  │                 Canvas                     │    Inspector       │
│ (slides    │            (the slide, with                │                    │
│  and       │          rulers when shown)                │                    │
│  builds)   │                                            ├────────────────────┤
│            │                                            │   Source pane      │
│            ├────────────────────────────────────────────┤   (Python)         │
│            │ Drawer: notes · alt text · terminals       │                    │
└────────────┴────────────────────────────────────────────┴────────────────────┘
```

Drag the dividers between the parts to resize them; Manimble remembers the sizes. **View ▸ Hide/Show Slide
Navigator** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>N</kbd>) and **View ▸ Hide/Show Inspector and Source**
(<kbd>⌥</kbd><kbd>⌘</kbd><kbd>I</kbd>) give the canvas more room.

## Toolbar

From left to right:

| Button | What it does |
|---|---|
| **New Slide** | Adds a Title and Content slide after the current one. Its arrow menu offers the other layouts. See [Slides and builds](slides.md). |
| **New Build** | Adds a build after the one on screen, starting with everything it shows. |
| **Expand All** | Lists the builds of every slide in the navigator, or folds them away again. |
| **Table**, **Text**, **Formula**, **Shape**, **BioCartoon**, **Image** | Insert content. See [Inserting content](inserting.md). The Shape menu also has the drawing tools and the pen. |
| **Theme** | Switches the deck to another theme. See [Themes, backgrounds and colour](design.md). |
| **Python Plot** | Inserts a picture drawn by Python code. See [Pictures and Python plots](pictures.md#python-plots). |
| **Zoom** | Zooms the canvas. |
| **Dark Mode** | Shows the slides with whites and blacks swapped, without changing the deck. |
| **Terminal** | Shows or hides the terminal. See [The terminal](../ai/terminal.md). |
| **Share** | Exports the deck as PDF, PowerPoint, Keynote, Beamer or a movie. See [Exporting](../sharing/export.md). |

## Home bar

The Home bar sits under the toolbar, like the Home tab in PowerPoint. It holds the formatting controls for the
selected text: font, size, bold, italic, underline, strikethrough, superscript and subscript, highlight and text
colour, clear formatting, lists and indents, alignment, line spacing and columns. It also has the grid, snapping and
guide controls, the **Script** and **View Feedback** buttons, and, at the right end, the find box.

Every control on the Home bar is also in the **Format**, **View** or **Insert** menu, usually with a keyboard
shortcut.

## Navigator

The navigator lists the slides of the show, each with a thumbnail and its number. The current slide is outlined;
its builds are listed under it as smaller thumbnails.

- Click a slide to show it, or a build to show that build.
- Drag a slide to reorder the show.
- Right-click a slide for New Slide, New Build, Duplicate Slide, Hide Slide, Delete Slide, Expand All Builds and
  Export Slide as Movie.
- A slide whose code fails to run is marked with an error; select it to see the message.
- Hidden slides are dimmed, with their number struck through.

Use <kbd>⌘</kbd><kbd>↑</kbd> and <kbd>⌘</kbd><kbd>↓</kbd> to move between slides, and <kbd>⌘</kbd><kbd>[</kbd> and
<kbd>⌘</kbd><kbd>]</kbd> to move between builds.

## Canvas

The canvas shows the slide, at the build selected in the navigator. Click an object to select it, double-click to
edit its text or formula, and drag to move it. Right-click an object for the commands that apply to it, or the empty
slide for slide commands such as Format Background.

Zoom with **View ▸ Zoom In** (<kbd>⌘</kbd><kbd>=</kbd>), **View ▸ Zoom Out** (<kbd>⌘</kbd><kbd>-</kbd>) and
**View ▸ Fit in Window** (<kbd>⌘</kbd><kbd>0</kbd>), or pinch on a trackpad. Scroll to pan when zoomed in.

## Inspector

The inspector shows the properties of the selected object: its kind, the line of code that made it, its text or
formula, its appearance, and its position and size. With nothing selected it shows the slide's name and a few tips.
Some panels open in the inspector's place: the Script panel, the feedback list and the BioCartoon icon search.

## Source pane

The source pane shows the Python code of the current slide, with the lines of the selected object highlighted. Lines
changed by your last edit are highlighted too. Click into the code to edit it; see
[Editing the Python source](source.md).

## Drawer

The drawer under the canvas holds tabs:

- **Slide Notes:** speaker notes for the whole slide.
- **Build Notes:** notes for the build on screen only.
- **Alt Text:** a description of the slide for people who can't see it.
- **Terminal 1**, **Terminal 2**, …: shells, where you can run an AI agent. The **+** button opens another.

**View ▸ Speaker Notes** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>K</kbd>) and **View ▸ Show Terminal**
(<kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>) open the drawer on those tabs. See [Notes and alt text](notes.md) and
[The terminal](../ai/terminal.md).

## Tips and messages

After many actions Manimble shows a short message at the bottom of the canvas, for example that a move applied to one
build only. Errors are always shown. Turn on **View ▸ Show Tips** to also see a confirmation after every action.

A pill in the top-right corner shows long-running work, such as building animations or exporting. Click its **×** to
cancel it.
