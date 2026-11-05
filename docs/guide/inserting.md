# Inserting content

The **Insert** menu and the toolbar add new objects to the slide. Each inserted object appears at once and is written
into the slide's code as one marked line, for example:

```python
self.add(Text("Text", font_size=36).move_to((0, 0, 0)))  # manimble
```

The object is added to the build on screen, so it appears at that step of the slide. Once inserted, it is an ordinary
object: move it, resize it, format it and delete it like any other.

## Text

Choose **Insert ▸ Text** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd>) or click **Text** in the toolbar. A text box opens on
the slide, ready for typing. Inserted text uses the deck theme's font and colour. See
[Text and formatting](text.md).

## Formulas

Choose **Insert ▸ Formula…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd>). See [Formulas](formulas.md).

## Shapes

Choose a shape from **Insert ▸ Shape** or the toolbar's **Shape** menu: rectangle, rounded rectangle, circle,
ellipse, triangle, line, arrow or double arrow. The shape appears in the middle of the slide in the theme's colour.
Select it to change its colour in the inspector.

## Draw shapes and lines

To place a shape exactly, draw it:

1. Choose a tool from **Insert ▸ Draw (drag on the slide)**, or from the Shape menu: line, arrow, double arrow,
   rectangle or ellipse.
2. Drag on the slide. Hold <kbd>⇧</kbd> to snap a line's angle, or to draw a square or circle.

The shape is inserted with the endpoints or box you drew. Line and arrow ends attach to the objects you start or end
on; see [Lines and arrows](arranging.md#lines-and-arrows). Press <kbd>Esc</kbd> to put the tool away without drawing.

## Pen

The pen draws freehand strokes, for annotations or quick sketches.

1. Choose **Insert ▸ Draw ▸ Pen (freehand)** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>), or the pen in the toolbar's
   Shape menu.
2. Draw on the slide. Each stroke is smoothed and inserted as one curve. The pen stays active for the next stroke.
3. Press <kbd>Esc</kbd> to stop drawing.

Choose the colour with **Insert ▸ Draw ▸ Pen Color**; Manimble remembers it. A pen stroke is a real object of the
slide: select it to move, resize, recolour or delete it.

## Tables

Choose **Insert ▸ Word Table…** or **Insert ▸ Math Table…**, or click **Table** in the toolbar (a click inserts a word
table; its menu offers both).

- A **word table** holds plain text in each cell.
- A **math table** typesets each cell as LaTeX math, for numbers and formulas.

To edit the cells, double-click a cell to type into it on the slide, or edit the **Cells** grid in the inspector.
<kbd>⇥</kbd> moves to the next cell and <kbd>↩</kbd> applies. **+ Row**, **− Row**, **+ Col** and **− Col** add or
remove the last row or column. Click **Apply Table** to write the changes.

## Pictures, plots and icons

- **Insert ▸ Image…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>I</kbd>) adds a picture from a file. You can also copy a picture
  file in the Finder and paste it onto the slide.
- **Insert ▸ Python Plot…** adds a picture drawn by Python code, which you can run again whenever the code or data
  changes.
- **Insert ▸ Extract Elements from Image…** splits a selected picture into separate objects.
- **Insert ▸ BioCartoon Icons…** searches a library of scientific illustrations.

These are described in [Pictures and Python plots](pictures.md).

## Slide numbers

Choose **Insert ▸ Slide Numbers…** to put a number on every slide of the show.

- Choose the position: bottom right, bottom centre or bottom left.
- Choose the first number, whether the title slide shows its number, and whether to show the total (`3 / 10`).

Each number is an ordinary `Text` object at the top of the slide's code, marked `# manimble page number`, so you can
move it or change its size. When you move or restyle one slide's number, Manimble offers to make every slide's number
match. Numbers are updated in the same undo step whenever slides are added, duplicated, deleted or reordered. Open the
dialog again to change the options or remove the numbers.

## Paste from other apps

**Edit ▸ Paste** (<kbd>⌘</kbd><kbd>V</kbd>) accepts content copied from other apps:

| You copy | Manimble pastes |
|---|---|
| A selection in Google Slides or a web page | The pictures it contains, or its text with bold, italic and colour kept |
| Formatted text from an app that copies it as HTML, such as a browser, Google Docs or Word | Text with its bold, italic and colour |
| A picture, a screenshot, or a PDF | A picture, saved into the deck folder |
| A picture file in the Finder | That picture |
| Any other text | Plain text |

Each paste lands slightly offset from the last, so repeated pastes don't hide each other. Pictures copied from a web
page are downloaded and saved into the deck.

To copy objects between slides or decks, see
[Copy, cut and paste](arranging.md#copy-cut-and-paste).
