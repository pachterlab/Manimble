# Projects and packages

## Save your work

| Command | Shortcut | What it does |
|---|---|---|
| **File ▸ Save to Original** | <kbd>⌘</kbd><kbd>S</kbd> | Writes every change in the working copy back to your deck. |
| **File ▸ Revert to Original…** | | Discards every change since the last save. |
| **File ▸ Save Project Copy…** | | Writes a complete, editable copy of the project to a new folder. |
| **File ▸ Package for Sharing…** | | Writes the project as a single `.manimble` file. |

If the original deck was changed by someone else since you opened it (for example by a sync service or another
editor), Manimble warns you before saving over those changes. If the deck folder was moved, renamed or deleted while
it was open, Save refuses rather than make a new folder at the old place; use **File ▸ Save Project Copy…** to keep
your edits.

**File ▸ Save Project Copy…** saves a copy, not a "Save As": the window goes on editing the original, whose unsaved
edits stay unsaved. Open the copy with **File ▸ Open Deck or Project…** to work on it instead.

## Share a deck with another Manimble user

**File ▸ Package for Sharing…** creates one `.manimble` file containing everything the deck needs: its code, the
pictures and other files it uses, and its existing animation builds, so the recipient can present it without
rendering it again. Send the file by email, a file-sharing service or AirDrop. The recipient opens it with
**File ▸ Open Deck or Project…**.

**File ▸ Save Project Copy…** writes the same contents as an ordinary folder instead of a single file.

Both commands:

- find the files the deck uses by watching which files the slides open while they render;
- keep paths relative to the project, so the copy works wherever it is put;
- report files that are missing, or that lie outside the project and so can't be included.

!!! tip
    A file that a slide reads only in a branch of code that didn't run while rendering can be missed. Render every
    slide (for example by stepping through the deck) before packaging, and check the report.

## Open a deck

**File ▸ Open Deck or Project…** (<kbd>⌘</kbd><kbd>O</kbd>) opens any of these:

- a deck folder, or any file inside it;
- a Manim Slides project: its folder, or the `.py` file with its slides;
- a project folder that contains a deck;
- a `.manimble` package. Manimble asks where to unpack it (beside the package by default) and opens the project
  folder it makes. That folder is what you edit and save, and what **Open Recent** opens again; the package itself
  never changes. Package the deck again to send the edited version.

**File ▸ Open Recent** lists the decks you opened lately. Each deck opens in its own window; opening a deck that is
already open brings its window to the front.

## The manimbler command-line tool

`manimbler` inspects, unpacks and converts `.manimble` packages without opening Manimble, for example on a server or
in a script. Building from source installs it at `~/.local/bin/manimbler`; it can also be run as `./manimbler` from a
copy of the repository.

```bash
manimbler --check talk.manimble                       # verify the package and every file it refers to
manimbler --info talk.manimble                        # slides, builds, sizes and running time
manimbler --extract talk.manimble --output talk       # unpack into an editable project folder
manimbler --convert talk.manimble --output talk.mp4   # the animated show as a movie
manimbler --convert talk.manimble --slides 1-3,7 --output excerpt.mp4
manimbler --convert talk.manimble --to pdf --output handout.pdf
manimbler --convert talk.manimble --to html --output talk.html
manimbler --submit talk.manimble --title "My talk" --authors "Ada Lovelace"   # share it on the Examples page
```

| Option | Meaning |
|---|---|
| `--check FILE` | Verify the package and the media it refers to. |
| `--info FILE` | Show the slide order, build counts, package size and the estimated running time of the movie. |
| `--extract FILE` | Unpack into a project folder (by default, the package name without `.manimble`). |
| `--convert FILE` | Convert to MP4, PDF or HTML. |
| `--submit FILE` | Check the package, then upload it with the details below for review for the [Examples page](../examples.md). |
| `--to {mp4,pdf,html}` | The format, if the output name doesn't make it clear. |
| `-o`, `--output` | The output file or folder. |
| `--slides LIST` | Only these slides, by number, range or name. They keep their order in the deck. |
| `--hold SECONDS` | How long each build's last frame is held in a movie (default 2; `0` for no pauses). |
| `--fps N` | The movie's frame rate (default 30). |
| `--force` | Replace existing output. |
| `--title`, `--authors`, `--institution`, `--date`, `--keywords`, `--description` | The example's details, for `--submit`. You are asked for a missing title and authors. |
| `--yes` | With `--submit`, confirm that you may share the presentation instead of being asked. |

Conversion follows the deck's `order.txt`. Movies have no sound. PDF and HTML conversion use the installed Manim
Slides; keep a generated HTML file together with its `_assets` folder when you share it.
