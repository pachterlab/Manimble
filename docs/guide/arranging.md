# Selecting and arranging objects

## Select objects

- **Click** an object to select it. Its handles appear, and the inspector shows its properties.
- **Shift-click** more objects to add them to the selection, or **drag a rectangle** on an empty part of the slide to
  select everything inside it. Selected objects move, nudge and delete together.
- Click an empty part of the slide, or press <kbd>Esc</kbd>, to deselect.
- Press <kbd>↩</kbd> to edit the selected object: retype its text, or open its formula.

To see every object on the slide at once, choose **View ▸ Show Objects** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>J</kbd>). Each
object gets a faint outline, which helps with objects that are hard to find, such as text on a picture.

## Move objects

- **Drag** a selected object.
- Press the **arrow keys** to nudge it, and hold <kbd>⇧</kbd> for bigger steps.
- Hold <kbd>⇧</kbd> while dragging to move only horizontally or only vertically.
- Type exact coordinates into **X** and **Y** under **Arrange** in the inspector.

While you drag, the object snaps to the edges and centres of other objects, to guides and to the slide's edges and
centre. Hold <kbd>⌥</kbd> to drag freely. See [Grids, guides and rulers](layout-aids.md).

### Moving in one build or in all builds

On a slide with several builds, a drag moves the object in the build on screen only. Earlier and later builds keep
its position, so you can lay out each step of a slide separately. Manimble writes this as a marked `shift` at the
start of the build and the opposite shift at its end.

To move the object in every build instead, press <kbd>⌘</kbd><kbd>A</kbd> right after the move.

## Resize and rotate

- Drag a **corner handle** to resize the object about its centre.
- Type a **Width** and **Height** in the inspector. For pictures and shapes, turn off **Keep aspect ratio** to
  stretch one dimension on its own.
- Type a **Rotation** in degrees in the inspector.

For text, **Format ▸ Bigger** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd>) and **Format ▸ Smaller**
(<kbd>⌥</kbd><kbd>⌘</kbd><kbd>-</kbd>) change the font size instead.

## Lines and arrows

Select a line or arrow to show a handle at each end. Drag an end to move it; hold <kbd>⇧</kbd> to snap the angle to
15° steps.

When you drag a line end near another object, that object's attach points appear: its corners, the middles of its
edges, and its centre. Release on one to attach the end to it. An attached end is written as a point of the object
(for example `box.get_corner(UR)`), so it stays on that point. Hold <kbd>⌘</kbd> to place the end without
attaching it.

## Stacking order

When objects overlap, the **Arrange** menu changes which is in front:

| Command | Shortcut |
|---|---|
| **Bring to Front** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| **Bring Forward** | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| **Send Backward** | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd> |
| **Send to Back** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>B</kbd> |

Forward and Backward step past the next object that overlaps the selection. Manimble writes the order as
`set_z_index(...)` calls, changing as few objects as it can. The same commands are in an object's right-click menu.

## Group objects

Select two or more objects and choose **Arrange ▸ Group** (<kbd>⌘</kbd><kbd>G</kbd>). The objects become one group,
written as `group1 = Group(a, b)  # manimble group`. Clicking any member then selects the whole group, so it moves,
nudges, deletes and stacks as one.

**Arrange ▸ Ungroup** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd>) removes the group and leaves its members selected.

## Copy, cut and paste

Copy (<kbd>⌘</kbd><kbd>C</kbd>), cut (<kbd>⌘</kbd><kbd>X</kbd>) and paste (<kbd>⌘</kbd><kbd>V</kbd>) work on
selected objects, within a slide, between slides and between decks.

- A copied object carries the code that makes it. Pasted into a slide of the same deck, it becomes the same code on
  the new slide, at the same position, so the copy is fully editable.
- Pasting into the same slide places each copy slightly offset, so it doesn't hide the original.
- Some objects can't be copied as code: an object made together with others by one call, one made in a loop, or one
  whose code depends on other names in the slide. These are pasted as a picture instead, and Manimble tells you so.
- Between decks, and into other apps, objects are pasted as pictures. Text is also put on the clipboard as plain
  text.

You can also paste from other apps, such as a picture from a browser, a screenshot, or a selection copied in Google
Slides. See [Inserting content](inserting.md#paste-from-other-apps).

## Delete objects

Select objects and press <kbd>⌫</kbd>. Manimble removes the code that makes and shows each object.

When other code depends on a named object (for example `SurroundingRectangle(title)` or `title.get_right()`), the
name and those statements stay, and only the statements that show the object are removed. Deleting an object made
in a loop removes all the objects of that loop. An object built inside a larger expression, such as a list
comprehension, has to be removed in the source.

## Undo and redo

**Edit ▸ Undo** (<kbd>⌘</kbd><kbd>Z</kbd>) and **Edit ▸ Redo** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd>) step through
every change made in Manimble while the deck is open, including slide changes such as deleting or reordering slides.
