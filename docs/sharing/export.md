# Exporting

Manimble exports a deck for people who don't use Manimble: as PowerPoint, Keynote or Beamer slides, as a PDF, or as a
movie. Use **File ▸ Export To**, or the **Share** button in the toolbar. Hidden slides are left out of every export.

## PowerPoint and Keynote

1. Choose **File ▸ Export To ▸ PowerPoint (.pptx)…** or **File ▸ Export To ▸ Keynote (.key)…**.
2. Choose the options in the Save panel:
    - **Every build as its own slide.** On, each build becomes a slide, so the slide reveals its content click by
      click as it does in Manimble. Off, each slide is exported as its final build.
    - **Editable text boxes (recommended)** keeps plain text as real text boxes, with font, size, colour, bold and
      italic, over a picture of everything else on the slide. **Pictures only (exact look)** exports each slide as its
      exact rendered picture.
3. Click **Save**.

Formulas, shapes, lines, tables, pictures and plots are exported as pictures; only plain text stays editable.
Animations aren't exported, although builds can become separate slides. Text positions can shift slightly if a font
is missing on the computer that opens the file.

Keynote export creates a PowerPoint file and has Keynote convert it, so Keynote must be installed. If Keynote shows a
dialog during the conversion, for example about a missing font, the export waits until you answer it.

A slide that is exported as a single picture carries the slide's [alt text](../guide/notes.md#alt-text) as the
picture's description.

## Beamer

Choose **File ▸ Export To ▸ Beamer (.tex)…**. The deck becomes a LaTeX Beamer presentation:

- each slide becomes a frame, and each build an overlay of that frame;
- with **Editable text and LaTeX formulas (recommended)**, text stays real LaTeX text in its size, colour, weight and
  slant, formulas are written as LaTeX maths, and everything else is placed as pictures at its exact position;
- with **Pictures only (exact look)**, each page is the exact rendered picture;
- speaker notes become `\note{...}`.

Pictures go in a `<name>-figures` folder next to the `.tex` file. Keep the two together.

## PDF

- **File ▸ Export To ▸ PDF…** saves a PDF with one page per slide, showing each slide's final build.
- **Share ▸ Share PDF (every build)…** makes a PDF with one page per build, for handouts that follow the talk step by
  step. **Share ▸ Share PDF (one page per slide)…** makes the shorter version. Both open the macOS share menu, so you
  can send the PDF by Mail, Messages or AirDrop.
- **Share ▸ Save PDF…** saves the one-page-per-slide PDF to a file, like **File ▸ Export To ▸ PDF…**.

## Movie

Choose **File ▸ Export To ▸ Movie (.mp4, with animations)…**, or right-click a slide in the navigator and choose
**Export Slide as Movie (.mp4)…**. The movie is the animated show: every build plays once, at its playback rate, and
then holds its last frame.

The Save panel asks for:

| Option | Choices |
|---|---|
| Slides | All, the current slide, or a list of navigator numbers, ranges and slide names, such as `1-3, 7, Results` |
| Resolution | 720p to 4K. Slides not yet built at that size are built first. |
| Hold | How long each build's last frame is held, in seconds. The default is two. |
| Frame rate | Frames per second |
| Export with script | Includes the deck's [script](../presenting/scripted.md): narration as the soundtrack and the pointer drawn over the slides |

Without a script the movie has no sound. Loops play once, and builds that continue automatically pause for the hold
like any other. Exporting at a resolution other than the one in **Play ▸ Animation Resolution** builds the slides
again at that size.

To include a Manimble animation in a PowerPoint, Keynote or Google Slides deck, export the slide as a movie and insert
the movie into that deck.

## Python

**File ▸ Export To ▸ Python (whole deck in one file)…** writes the whole deck as a single `.py` file: helper modules
inlined, the slides in show order, and a `SLIDES` list at the end. It is a convenient one-file copy for sharing code.
Save it in the deck folder so relative paths, such as those of pictures, still work.

To share a deck with someone who uses Manimble, use **File ▸ Package for Sharing…** instead. See
[Projects and packages](projects.md).
