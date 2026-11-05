# Slides and builds

The **Slide** menu adds, duplicates, deletes, hides and reorders slides, and adds builds. Every one of these commands
edits the deck's code and `order.txt`, and can be undone.

## Add a slide

Choose **Slide ▸ New Slide** and a layout, or click **New Slide** in the toolbar (its arrow menu shows the layouts).
The new slide is added after the current one.

| Layout | Contents |
|---|---|
| **Title Slide** | A title and a subtitle |
| **Title and Content** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd>) | A title and a bulleted content box |
| **Two Content** | A title and two content boxes side by side |
| **Title Only** | A title |
| **Blank** | Nothing |

Empty placeholders show prompts such as *Click to add title* in the editor only; nothing is drawn on the slide until
you type into one. Click a placeholder to type into it. It becomes an ordinary text object in a fixed-size frame, in
the deck theme's font and colour. A slide's name is its Python class name, which Manimble chooses when it creates the
slide.

## Add a build

A build is a step of a slide that waits for a click. Choose **Slide ▸ New Build**, or click **New Build** in the
toolbar, to add a build after the one on screen. The new build starts out showing everything the current build
shows. Manimble switches to it, so what you insert next appears at that step.

To step between builds, click them in the navigator, or use **Slide ▸ Previous Build** (<kbd>⌘</kbd><kbd>[</kbd>) and
**Slide ▸ Next Build** (<kbd>⌘</kbd><kbd>]</kbd>).

To delete a build, click it in the navigator and press <kbd>⌫</kbd>. In the code, builds are separated by
`self.next_slide()` calls; a new build is a `self.next_slide()` followed by a short `self.wait()`, since Manim Slides
skips a build in which nothing happens.

## Duplicate, delete and hide slides

| Command | Shortcut | What it does |
|---|---|---|
| **Slide ▸ Duplicate Slide** | <kbd>⌘</kbd><kbd>D</kbd> | Copies the slide's class under a new name and adds it after the original. |
| **Slide ▸ Delete Slide** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>⌫</kbd> | Removes the slide. Pressing <kbd>⌫</kbd> in the navigator does the same. <kbd>⌘</kbd><kbd>Z</kbd> brings it back. |
| **Slide ▸ Hide Slide** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>H</kbd> | Keeps the slide in the deck but leaves it out of presentations and exports. Choose it again to unhide. |

A hidden slide stays in the navigator, dimmed and with its number struck through. It is skipped by the slideshow,
Presenter View, and the PDF, PowerPoint, Keynote and movie exports. In the code it is a `# manimble hidden` comment
on the class line.

## Reorder slides

- Drag a slide up or down in the navigator.
- Or choose **Slide ▸ Move Slide Up** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>↑</kbd>) or **Slide ▸ Move Slide Down**
  (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>↓</kbd>).

The order is saved in `order.txt`.

## Unused slides

A slide class that isn't listed in `order.txt` is an unused slide: it is in the deck's code but not in the show. This
happens when a deck keeps spare or old slides. Choose **View ▸ Show Unused Slides** to list them at the end of the
navigator. Select one and choose **Slide ▸ Restore Slide to Show** (also in its right-click menu) to add it to the end
of the show, then move it into place.

## Navigate

| Command | Shortcut |
|---|---|
| **Slide ▸ Previous Slide** | <kbd>⌘</kbd><kbd>↑</kbd> |
| **Slide ▸ Next Slide** | <kbd>⌘</kbd><kbd>↓</kbd> |
| **Slide ▸ Previous Build** | <kbd>⌘</kbd><kbd>[</kbd> |
| **Slide ▸ Next Build** | <kbd>⌘</kbd><kbd>]</kbd> |

**Expand All** in the toolbar lists the builds of every slide in the navigator, not just the current one; click it
again (**Collapse All**) to fold them away.

!!! note "Decks with their own slide lists"
    New and duplicated slides are added to `order.txt` only. If your deck keeps its own list of slides elsewhere,
    for example in a build script or a progress bar drawn on every slide, update that list by hand.
