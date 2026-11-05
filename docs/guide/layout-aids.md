# Grids, guides and rulers

## Coordinates on a slide

Manim measures a slide in its own units: a standard 16:9 slide is about 14.2 units wide and 8 units high, with the
origin `(0, 0)` at the centre, *x* increasing to the right and *y* increasing upwards. Positions in the code, such as
`.move_to((2, 1, 0))`, use these units.

The inspector's **X** and **Y** fields show the position of the selected object's centre in pixels of the rendered
frame (1280 × 720 for a standard deck), measured from the top-left corner. Manimble converts between the two when it
writes the code.

## Grid lines

Choose **View ▸ Grid Lines** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>G</kbd>) to show a grid one Manim unit apart, with the axes
through the centre of the slide marked. When the grid is shown, dragged objects also snap to it.

## Snapping

**View ▸ Snap to Objects** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd>) is on by default. While you drag an object, its edges
and centre snap to:

- the edges and centres of other objects,
- your guides,
- the edges and centre of the slide,
- the grid, when it is shown.

Orange lines show what the object has snapped to. Hold <kbd>⌥</kbd> while dragging to move freely.

## Guides

Guides are lines you place to line objects up across a slide.

- Choose **View ▸ Add Vertical Guide** or **View ▸ Add Horizontal Guide**, or use the guide buttons on the Home bar.
  A cyan guide appears in the middle of the slide.
- Drag a guide to move it. Drag it off the slide to remove it.
- **View ▸ Clear Guides** removes them all.

Guides are remembered for each deck, are shown on every slide, and are never part of the slides themselves.

## Rulers

Choose **View ▸ Ruler** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>U</kbd>) to show rulers along the top and left of the slide. They
are graduated in Manim units, with 0 at the centre of the slide, and follow the zoom. They mark the extent of the
slide and of the selection, the pointer's position, and each guide.

Drag from a ruler onto the slide to add a guide, or drag a guide's marker on the ruler to move it.

## Show objects

**View ▸ Show Objects** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>J</kbd>) outlines every object on the slide, which helps you find
objects that are small, transparent or hidden behind others.

## Zoom

| Command | Shortcut |
|---|---|
| **View ▸ Zoom In** | <kbd>⌘</kbd><kbd>=</kbd> |
| **View ▸ Zoom Out** | <kbd>⌘</kbd><kbd>-</kbd> |
| **View ▸ Fit in Window** | <kbd>⌘</kbd><kbd>0</kbd> |

You can also pinch on a trackpad to zoom, and scroll to pan.
