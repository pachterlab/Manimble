# Collecting feedback

Feedback notes are short red notes pinned to a point on a slide: comments from a practice talk, reminders to fix
something, or reviewers' suggestions. The audience never sees them, and they are not part of the slides' code. They
are stored in `feedback.json` beside the deck, so adding them never re-renders a slide.

## Add feedback during a practice talk

1. Start [Presenter View](presenter.md).
2. Click **Feedback Mode** at the top of the presenter window, or press <kbd>F</kbd>.
3. Click the current slide where the comment belongs, and type. Clicks now add notes instead of advancing the show.
4. Press <kbd>Esc</kbd> or <kbd>⌘</kbd><kbd>↩</kbd> to finish a note.
5. Click **Feedback Mode** again, or press <kbd>F</kbd>, to go back to advancing with clicks.

Slides with notes get a red dot in the presenter window's sidebar.

## Edit feedback in the editor

Feedback notes are shown over the canvas in the editor, on the slide they belong to. There you can:

- Drag a note's frame to move it.
- Click its text to edit it.
- Click its close button to delete it, or empty its text and press <kbd>⌫</kbd>.

Each note remembers the build it was written on.

## Review feedback

Click **View Feedback** on the Home bar. The feedback list opens in the inspector's place, with every note grouped by
slide.

- Click a note to go to its slide with the note outlined, ready to edit.
- Use **Previous** and **Next** to walk through the notes in order.
- Delete notes one at a time, or all of them with **Delete All**.

Click **Done** to return to the inspector.

## Save and share feedback

Feedback notes are part of the working copy, so **File ▸ Save to Original** saves them with the deck, and closing
without saving discards them. They travel with the deck when you package it for sharing, so a reviewer can add notes
and send the deck back.
