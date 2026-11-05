# Limitations

Manimble edits real Python code, and some code can't be edited from the canvas in every way. This page lists what
Manimble can't do yet, and the cases where it behaves differently from a conventional slide editor.

## Editing on the canvas

- **Objects made in loops.** An object positioned by a loop together with `arrange()` (for example, a list built in a
  comprehension) can be retyped but not moved on its own. A line made in a loop moves every copy. More than twelve
  objects made by the same line, such as the dots of a scatter plot, can't be edited one by one.
- **Computed text.** Text produced by computation, such as an f-string, can't be retyped on the canvas; edit it in the
  source pane.
- **Alignment and columns** need a `Text("...")` with a plain string written in the slide itself, not text made by a
  helper function. Converting text to columns drops its per-character styles and alignment. Text with manual line
  breaks can't be justified.
- **Underline and strikethrough** lines are drawn in the text's colour at the time; recolouring the text later leaves
  them as they were.
- **Superscript and subscript** in plain text cover only the characters Unicode provides: no superscript *q*, and few
  subscript capitals. Use a formula for anything else.
- **Rotation** is read from the object's own `rotate()` calls, so a rotation applied to its group, or computed in
  code, shows as 0°.
- **Width and height** are Manim's measure of the object, which for circles and curves is a few percent larger than
  the visible outline.
- **Tables** can be edited only when their data is written as literals in the code.
- **Pictures** can't be replaced, cropped or relinked from the canvas. Insert the new picture and delete the old one,
  or change the file name in the code.
- **Drawing order while editing.** During a drag or before a render finishes, overlapping objects are drawn in an
  approximate order. The canvas is exact once the slide is idle.

## Shared code

Changing a shared constant, such as the deck's font or a formula used on several slides, changes every slide that
uses it. If the change breaks another slide (for example, code that selects part of a formula by its LaTeX), the error
appears on that slide once it re-renders in the background.

## Animations

Manimble has no panel for editing animations. Objects you insert appear at their build (with `self.add`) rather than
animating in. To animate them, edit the slide's `self.play(...)` calls in the source pane, or ask an
[AI agent](../ai/agents.md).

## Dark mode and inverted colours

The view-only modes recolour each object separately, so objects that Manimble doesn't track as separate objects, such
as plots and very many dots, are recoloured as part of the background. Applying a mode to the deck doesn't change
pictures, colours computed in code, per-character colours or gradients.

## Presenting

- The first time a deck is played with animations, every slide is built, which can take minutes.
- In the animated show, <kbd>V</kbd> replays a build forwards when Manim Slides didn't make a reversed clip for it.
- New and duplicated slides are added to `order.txt` only. A deck that keeps its own list of slides elsewhere, such
  as in a build script, must be updated by hand.

## Projects and packages

Manimble finds the files a deck needs by watching which files its slides open while they render. A file read only by
code that didn't run during rendering can be missed when packaging. Render every slide before packaging, and check
the report.

## Undo and saving

- Undo history is kept in memory and cleared when you close the deck.
- Undo restores whole files. Changes made to the same file by an AI agent or another editor since your edit are undone
  with it. See [Undo and the agent's changes](../ai/agents.md#work-together-with-the-agent).
- If Manimble quits unexpectedly, the working copy is left behind and replaced the next time you open the deck, so
  unsaved changes are not recovered. Save often.

## Import and export

See [Importing presentations](../sharing/import.md#what-isnt-imported) and [Exporting](../sharing/export.md) for what
those formats can and can't carry.

## Platforms

Manimble runs on macOS 13 or later. Versions for Windows and Linux are planned.
