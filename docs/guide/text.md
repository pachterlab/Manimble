# Text and formatting

Text on a Manimble slide is a Manim `Text` (or `Paragraph`) object. You retype and format it on the canvas, and
Manimble rewrites the string and its style arguments in the slide's code.

## Retype text

1. Double-click the text, or select it and press <kbd>↩</kbd>. A text box opens over it on the slide.
2. Type. Press <kbd>↩</kbd> for a new line.
3. Press <kbd>⌘</kbd><kbd>↩</kbd> or click outside the box to apply the change, or press <kbd>Esc</kbd> to discard it.

You can also retype text in the **Text** box of the inspector, with the same keys.

Formatting you have applied to part of the text follows the words it covers as you type: if a bold word moves to a
different position in the sentence, it stays bold.

!!! note "Text made by code"
    Text produced by computation, such as an f-string or a string built from variables, can't be retyped on the
    canvas. The inspector says so; edit it in the [source pane](source.md) instead.

### Text used in several places

Some decks define text once and use it on several slides, for example a `TITLE` constant. When you retype such text,
the inspector shows **Change everywhere (TITLE in config.py, used 3×)**. Leave it ticked to change the definition,
which changes every slide that uses it, or untick it to change this slide only.

## Text boxes and wrapping

Text inserted from a slide layout sits in a fixed-size frame, like a placeholder in PowerPoint: the frame keeps its
size whatever you type, and the text is aligned inside it. Other text can have a wrap width. Drag the left or right
side of a text box to change the width; Manimble re-wraps the lines to fit, using soft line breaks that it can undo
when the box gets wider again.

## Format characters and whole objects

The formatting commands work on two levels:

- **Part of the text.** While the text box is open, select some characters and apply a format. Only those
  characters change.
- **The whole object.** With the text selected on the canvas (and no text box open), a format applies to all of it.

| Format | Menu | Shortcut |
|---|---|---|
| Bold | **Format ▸ Bold** | <kbd>⌘</kbd><kbd>B</kbd> |
| Italic | **Format ▸ Italic** | <kbd>⌘</kbd><kbd>I</kbd> |
| Underline | **Format ▸ Underline** | <kbd>⌘</kbd><kbd>U</kbd> |
| Strikethrough | **Format ▸ Strikethrough** | |
| Superscript | **Format ▸ Superscript** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>+</kbd> |
| Subscript | **Format ▸ Subscript** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>_</kbd> |
| Text colour | The **A** on the Home bar, or the colour well in the inspector | |
| Highlight | **Format ▸ Highlight**, or the highlighter on the Home bar | |
| Bigger, Smaller | **Format ▸ Bigger**, **Format ▸ Smaller** | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd>, <kbd>⌥</kbd><kbd>⌘</kbd><kbd>-</kbd> |

The Home bar's B, I, U and S buttons light up to show the format of the selected characters.

How each format is written into the code:

- **Bold, italic and colour** of part of a text become Manim's per-character style arguments (`t2w`, `t2s` and
  `t2c`). For the whole object they become `weight=`, `slant=` and `color=`.
- **Underline and strikethrough** are drawn as lines attached to the text, because Manim text has neither. Manimble
  adds a small helper function to the deck and a line such as `title.add(underline(title))` to the slide. The lines
  move, scale and are deleted with the text.
- **Highlight** is a coloured rectangle behind the characters, or behind the whole text.
- **Superscript and subscript** replace the selected characters with their Unicode superscript or subscript forms
  (digits, signs and most letters), since Manim text has no raised or lowered characters. In formulas, use `^{}` and
  `_{}` instead.

### Font and size

Choose a font family and type a size on the Home bar, or in the **Appearance** section of the inspector. In many decks
the font is a constant shared by every slide (such as `FONT` in `common.py`); changing it then changes the whole deck.

### Clear formatting

**Format ▸ Clear Formatting** removes bold, italic, colour, per-character styles, line spacing, highlight, underline
and strikethrough. The font and size stay.

## Lists and indents

| Command | Shortcut |
|---|---|
| **Format ▸ Bulleted List** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>8</kbd> |
| **Format ▸ Numbered List** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>7</kbd> |
| **Format ▸ Increase Indent** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>]</kbd> |
| **Format ▸ Decrease Indent** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>[</kbd> |

Lists and indents are written into the string itself, as `• `, `1. ` and four spaces at the start of lines. They apply
to the lines selected in the text box, or to every line of the selected text. In a content placeholder each new line
you type starts with a bullet automatically.

## Alignment, spacing and columns

- **Format ▸ Align Left** (<kbd>⌘</kbd><kbd>L</kbd>), **Center** (<kbd>⌘</kbd><kbd>E</kbd>) and **Align Right**
  (<kbd>⌘</kbd><kbd>R</kbd>) align the lines of a multi-line text, or the text inside a placeholder. A multi-line
  `Text` written in the slide becomes a `Paragraph` with an `alignment=` argument, which Manimble edits like any text.
  Manim can't justify text that has manual line breaks.
- **Format ▸ Line Spacing** sets the space between lines: 1.0, 1.15, 1.5, 2.0, 2.5, 3.0 or a custom value, measured
  as in PowerPoint.
- **Format ▸ Columns** splits the lines of a text into two, three or four columns side by side. **One** merges them
  back. Converting to columns drops per-character styles and alignment.

Alignment and columns need text written as a plain string in the slide itself, not text made by a helper function.

## Hyperlinks

Select a text or a formula and choose **Format ▸ Hyperlink…** (<kbd>⌘</kbd><kbd>K</kbd>), or right-click it. Type a web
address;
`example.com` becomes `https://example.com`, and other schemes such as `mailto:` are kept. During a presentation,
clicking the text opens the link. Clear the box, or choose **Remove Link**, to take the link off.
