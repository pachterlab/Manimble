# Notes and alt text

The drawer under the canvas has three tabs for words that go with a slide but are not drawn on it: **Slide Notes**,
**Build Notes** and **Alt Text**. Choose **View ▸ Speaker Notes** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>K</kbd>) to open or
close the drawer on the notes. Drag the divider above the drawer to give it more or less room.

## Speaker notes

Speaker notes are shown to you in [Presenter View](../presenting/presenter.md), never to the audience.

- **Slide Notes** belong to the whole slide and are shown on every build of it.
- **Build Notes** belong to the build on screen only, and are shown after the slide's notes when that build is up.

Click in the tab and type; the notes are saved when you click elsewhere. Adding or changing notes doesn't re-render
the slide.

In the code, notes are written as the `notes=` argument of a `self.next_slide(...)` call, marked
`# manimble notes`. This is the format Manim Slides itself uses, so notes written in Manimble also appear in Manim
Slides' own presenter.

### Pictures in notes

Notes can include pictures, such as a figure to remember or a screenshot of a reference. Paste a picture into the
notes, or click the picture button on the notes tab to choose files. Each picture is copied into the deck folder and
stored in the notes as a Markdown image (`![](note_1a2b3c4d.png)`), which the notes tabs and Presenter View show
inline.

### Typing notes during a presentation

In Presenter View, click a notes panel to type into it. Press <kbd>Esc</kbd> or <kbd>⌘</kbd><kbd>↩</kbd>, or click
elsewhere, to save the notes and give the keys back to the show.

## Alt text

**Alt Text** is a description of the slide for people who can't see it, such as people using a screen reader. Type a
sentence or two describing what the slide shows.

Alt text is stored in the slide's class as `alt_text = "..."`. It isn't drawn and doesn't re-render the slide. When
you export to PowerPoint, a slide that becomes a single picture carries its alt text as the picture's description, so
screen readers read it aloud.
