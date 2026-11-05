# Themes, backgrounds and colour

## Themes

A theme sets a deck's background colour, font and text colours. Manimble includes seven:

| Theme | Background | Font | Accent |
|---|---|---|---|
| **Midnight** (default) | Black, white text | Helvetica Neue | Violet |
| **Chalkboard** | Dark green, chalk-white text | Chalkboard SE | Yellow |
| **Ember** | Near-black, warm white text | Helvetica Neue | Orange |
| **Paper** | White, near-black text | Helvetica Neue | Blue |
| **Parchment** | Warm off-white, brown text | Palatino | Brick red |
| **Slate** | Dark blue-grey, light text | Avenir Next | Teal |
| **Terminal** | Near-black, light text | Menlo | Green |

You choose a theme when you create a deck with **File ▸ New Deck…**. To change it later:

1. Choose **Format ▸ Theme**, or click **Theme** in the toolbar, and pick a theme.
2. A sheet shows the slide on screen rendered in that theme.
3. To change only the current slide, tick **Apply to selected slide only**.
4. Click **Apply**.

Applying a theme to the deck changes the theme's constants in `common.py` (`FONT`, `TEXT_COLOR` and others) and the
background colour in `manim.cfg`, as one undoable step. When you switch between a dark and a light background, the
sheet also offers to swap whites and blacks throughout the deck, so text that doesn't use the theme's colours stays
readable.

!!! note
    A theme changes text that uses its constants, such as text inserted by Manimble or typed into layouts. Text and
    shapes that set their own colours in code keep them.

## Slide background

To change the background of one slide, or of every slide:

1. Choose **Format ▸ Background…**, or right-click an empty part of the slide and choose **Format Background…**.
2. Choose a solid colour, or click **Choose Picture…** to fill the slide with a picture.
3. Drag the **Transparency** slider to blend the colour or picture with the deck's background. The slide previews
   each change.
4. Click **Apply** for this slide, or **Apply to All** for every slide. **Reset Background** returns to the deck's
   background.

The background is written as one marked line at the top of the slide's `construct` method: the camera's background
colour, or a full-slide picture at the back.

## Dark mode and inverted colours

Manimble can show your slides with different colours without changing the deck, which is useful for checking how a
deck looks in a dark room, or for presenting on a dark background.

- **View ▸ Dark Mode** (<kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd>), or the moon in the toolbar, swaps light
  and dark neutral colours: white becomes black, light grey becomes dark grey, and so on. Saturated colours such as
  red and blue are kept.
- **View ▸ Invert Colors** (<kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>I</kbd>) turns every colour into its complement,
  like the macOS accessibility setting: white and black swap, orange becomes blue.
- **View ▸ Recolor Images Too** applies the mode to pictures as well. It is off by default, so photos keep their
  colours.

These modes affect the canvas, the thumbnails and the built-in slideshow. Exports and the animated show use the real
colours.

### Make the change permanent

To write the new colours into the deck itself, choose **Format ▸ Apply Dark Mode to Deck…** or
**Format ▸ Apply Inverted Colors to Deck…**. Manimble rewrites colour values throughout the code and the background
in `manim.cfg`, and gives objects drawn in a default colour an explicit one. Every slide is re-rendered, which takes
about a second per slide. The whole change is one undo step.

The written version can differ from the view-only mode for colours that the code computes, per-character colours,
gradients and pictures, which are left as they are.
