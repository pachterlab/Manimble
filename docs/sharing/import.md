# Importing presentations

Manimble turns PowerPoint, Keynote and Beamer presentations into new Manimble decks. Every element becomes an
ordinary line of Manim code, so the imported slides can be edited on the canvas like any others.

## Import a PowerPoint or Keynote file

1. Choose **File ▸ Import ▸ PowerPoint (.pptx)…** or **File ▸ Import ▸ Keynote (.key)…**.
2. Choose the presentation.
3. Type a name for the new deck, choose where to put it, and click **Create Deck**. A folder with that name is made.

Manimble converts the file and opens the new deck. Keynote files, and old `.ppt` files, are first converted by
Keynote, so Keynote must be installed for them.

### What is imported

| In the presentation | In the deck |
|---|---|
| Slides | One slide (scene class) each, in the same order |
| Text boxes | `Text` objects with the font, size, colour and bold or italic down to the word, alignment, and line spacing; lines are wrapped to the box with the real font metrics |
| Pictures | Saved to the project's `assets` folder and placed as `ImageMobject` |
| Rectangles, rounded rectangles, ellipses, triangles, lines and arrows | The matching Manim shapes, with their fill and outline |
| Tables | `Table` objects laid out with PowerPoint's column widths and row heights |
| Groups | Their contents, with the group's position, scaling, rotation and flips applied |
| Slide background colours | The slide's background colour |
| Speaker notes | Kept as comments in each slide's code |

Theme colours, placeholder styles and inherited text styles are resolved the way PowerPoint resolves them, so text
gets the colours and sizes it shows in PowerPoint.

### What isn't imported

- Animations and transitions. Add animations afterwards in the [source pane](../guide/source.md), or ask an
  [AI agent](../ai/agents.md).
- Charts, SmartArt, and gradient or picture backgrounds.
- Unusual shapes, which become rectangles; Manimble warns you when this happens.

Text is positioned by its box, so line breaks can differ slightly from the original. Space between paragraphs is
dropped, since a Manim text has even line spacing, and a paragraph with a different size or alignment becomes its
own text object. Slides that aren't 16:9 are stretched to fit a 16:9 slide.

## Import a Beamer presentation

Choose **File ▸ Import ▸ Beamer (.tex)…** and choose the LaTeX file of a Beamer presentation.

Each frame becomes a slide laid out the way Beamer lays it out:

- The frame title and body text become `Text` objects in Beamer's font, wrapped as LaTeX wraps them, with bold,
  italic, colours and typewriter text kept.
- `itemize`, `enumerate` and `description` lists become one text object per item, with Beamer's bullets or numbers.
- Display maths becomes `MathTex`, using the document's own macros and maths packages.
- `\includegraphics` becomes a picture.
- Overlays become builds: `\pause`, `<+->`, `\item<n->`, `\only`, `\uncover` and `\onslide`.
- Anything else LaTeX draws, such as a TikZ picture or a `tabular`, is typeset with the document's own preamble and
  placed as a picture.

The default theme and the rounded and infolines family (Madrid, Boadilla, CambridgeUS, AnnArbor, Rochester, Warsaw
and others) are recognised, including their title bars, bullets and footlines.

### Missing LaTeX packages

If the presentation uses LaTeX packages your TeX installation lacks, Manimble asks before the import whether to
install them. Nothing is downloaded without asking. If you import without them, the parts that need them are shown as
placeholders, and a banner under the Home bar offers **Install**, **Not Now** and **Don't Ask Again**. Once the
packages are installed, the placeholders are typeset in place, keeping any edits you have made to the slides.

## After importing

An imported deck is an ordinary Manimble deck. Choose a [theme](../guide/design.md), add builds and animations,
and edit everything on the canvas. Save with **File ▸ Save to Original**.
