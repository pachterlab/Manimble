import Foundation

/// The instructions a coding agent started in Manimble's terminal reads first. Workspace writes them into the working
/// copy under each agent's file name; they are never saved to the original deck.
enum AgentInstructions {
    static let files = ["CLAUDE.md", "AGENTS.md", "GEMINI.md"]

    static let text = """
    # Editing this deck from Manimble

    This folder is the working copy of a Manim Slides deck that is open in Manimble, a slide editor for macOS.
    The user sees the slides in Manimble while you edit the code here. (This file was written by Manimble and is
    not part of the deck; don't edit it.)

    ## How edits reach the slides

    - Edit the deck's files **in this folder** (`$MANIMBLE_DECK`). Manimble notices saved changes within a few
      seconds and re-renders the slides they affect, so the user sees each edit almost at once.
    - Never write to `$MANIMBLE_ORIGINAL_DECK`. That is the user's real deck. The user writes the working copy
      back to it with File ▸ Save in Manimble, or throws the changes away with File ▸ Revert to Original.
    - Don't run `manim` or `manim-slides` yourself. Manimble renders. If you need to check that a file parses,
      `python -m py_compile <file>` is enough.
    - Subfolders here (and the `assets` folder next to this one) are links to the original project, so writing in
      them changes the user's files directly, with no Save or Revert. Prefer files at the top level of this folder.
    - This folder isn't a git repository. Run `diff -ru "$MANIMBLE_ORIGINAL_DECK" .` to see what has changed.

    ## How the deck is put together

    - Each slide is a `Slide` subclass (manim-slides) in one of the `.py` files here. Its `construct` builds it.
    - `self.next_slide()` separates the builds of a slide. The presenter clicks once for each build.
    - `order.txt`, if present, lists the slides' class names in show order, separated by spaces. A new slide must be
      added there to appear in the show.
    - A class line ending in `# manimble hidden` is a hidden slide: it stays in the deck but is skipped in the show.
    - Only `self.play(...)` and `self.wait(...)` record frames. An object added with `self.add(...)` after a
      build's last `play` or `wait` appears one click late, so put adds before them.
    - Code runs with this folder as the working directory. Refer to a picture next to the slide files as
      `str(__import__("pathlib").Path(__file__).resolve().parent / "name.png")`, the way Manimble does.

    ## Keep the slides editable in Manimble

    The user also edits these slides by hand: dragging, resizing, retyping text and recolouring. Manimble does it by
    rewriting the code that made each object, so write code it can follow:

    - Make each object with one expression that has literal arguments, e.g.
      `title = Text("Results", font_size=48).move_to((0, 3, 0))`.
    - Give positions as numbers in `.move_to((x, y, 0))` rather than computing them, when the object should be
      movable. The frame is normally about 14.2 units wide and 8 high, centred on the origin.
    - Use loops, list comprehensions and helper functions only for things the user won't want to move or retype
      one at a time.
    - A helper function that makes `Text` must accept and pass on `**kwargs`. Manimble stores bold, italic and
      colour on part of a text as `t2w`, `t2s` and `t2c` arguments.
    - Don't rename slide classes or reformat code you weren't asked to change. Manimble finds objects by the source
      line that made them, and the user's own edits are in that code too.
    - Leave alone the helper functions Manimble adds at the end of a file (such as `underline_chars`), and the
      `manimble_decoration` attributes they set.

    ## Working with the user

    - Make one change at a time and say which slide it's on, so the user can look at it before the next one.
    - If a slide fails to render, Manimble shows the error on that slide. Ask the user for the message if you need
      it, then fix the code.
    """
}
