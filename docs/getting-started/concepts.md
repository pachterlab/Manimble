# Key concepts

A few ideas come up throughout this guide. Knowing them makes the rest of Manimble easy to predict.

## Decks and projects

A **deck** is a folder of Python files that together make a presentation. A **project** is the folder around it,
which also holds shared material such as pictures:

```
My First Talk/            the project
├── assets/               pictures and other files the slides use
└── deck/                 the deck
    ├── common.py         the theme: fonts, colours and the base class of every slide
    ├── slides.py         the slides
    ├── manim.cfg         Manim settings, such as the background colour
    └── order.txt         which slides are in the show, and in what order
```

A deck can have several `.py` files; Manimble finds every slide in all of them. You open a deck with
**File ▸ Open Deck or Project…**, choosing the deck folder, its project folder, a file inside the deck, or a
`.manimble` package. See [Deck file format](../reference/deck-format.md) for every file Manimble reads and writes.

## Slides

A **slide** is a Python class with a `construct` method, usually derived from the deck's `Deck` class:

```python
class Overview(Deck):
    def construct(self):
        ...
```

The class name, here `Overview`, is the slide's name. It appears under the slide's thumbnail in the navigator.

The **show** is the list of slides in `order.txt`, in that order. A slide class that isn't listed there is an
*unused* slide: it stays in the deck but is not presented. **View ▸ Show Unused Slides** lists those too. A slide can
also be *hidden*: it stays in the show's list but is skipped when presenting, like a hidden slide in PowerPoint.

## Builds

A **build** is one step of a slide. Each `self.next_slide()` call in a slide's code ends a build, and in a
presentation the slide waits there for a click. A slide with two `self.next_slide()` calls between its content has
three builds.

The navigator shows a slide's builds under its thumbnail. The canvas always shows one build: what the audience sees
when that build has finished. Use <kbd>⌘</kbd><kbd>[</kbd> and <kbd>⌘</kbd><kbd>]</kbd> to move between builds.

Objects you insert are added to the build on screen, so they appear at that step. When a slide has several builds,
dragging an object moves it in the build on screen only, and the other builds keep its old position. To move it in
every build instead, press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>A</kbd> right after the move. Restyling an object (its text, colour or
size) changes it wherever it appears.

## Objects

Everything Manimble can select on a slide is an **object**: text, a formula, a picture, a shape, a line or arrow, a
table, or a drawing. Manimble knows which line of code made each object, which is how it turns a drag on the canvas
into an edit of that line.

Some objects are made in ways that limit what the canvas can do with them. Text computed by code, such as an
f-string, can't be retyped on the canvas. Many objects made by one loop move together. In these cases the inspector
explains what is possible, and the slide's code is always available in the source pane.

## The working copy

When you open a deck, Manimble copies it into a private **working copy** under
`~/Library/Application Support/Manimble/work`. Everything that changes the deck changes the working copy:

- your edits on the canvas, in the inspector and in the source pane;
- edits made in Manimble's terminal, by you or by an AI agent (with the default settings).

Your original files stay as they were until you choose **File ▸ Save to Original** (<kbd>⌘</kbd><kbd>S</kbd>).
**File ▸ Revert to Original…** discards every change since the last save. When you close a deck with unsaved
changes, Manimble asks what to do with them. The working copy is deleted when the deck is closed.

!!! note
    Subfolders of the deck and the project's `assets` folder are not copied; the working copy links to the originals.
    A file written into one of them changes the original at once.

## Rendering and the canvas

To show a slide, Manimble runs its code with Manim, quickly, skipping the animations. It records every object, where
it is and which code made it, and draws the canvas from that. After an edit, the canvas updates at once from what
Manimble already knows, while the slide is rendered again in the background to confirm the edit. If the code moves
the object somewhere else later, so the edit can't take effect as written, Manimble tries another way of making the
edit, and tells you which line of code controls the position if none works.

Renders are cached, so a slide is rendered again only when something it depends on changes. The slide on screen is
always rendered first; the others catch up in the background.

## Animations and stills

Manimble shows slides in two forms:

- **Stills** are pictures of each build. They are what the canvas, the thumbnails and the basic slideshow show, and
  they are quick to make.
- **Animations** are the real Manim animations, rendered as video clips with Manim Slides. They take longer to build
  the first time and are rebuilt only for slides whose code changed.

**Play ▸ Show Animations** chooses which form the Play commands use. See
[Playing a presentation](../presenting/playing.md).

## Undo

Every change you make in Manimble can be undone with <kbd>⌘</kbd><kbd>Z</kbd> and redone with
<kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd>, while the deck is open. Undo history is kept in memory and is cleared when you
close the deck.

<kbd>⌘</kbd><kbd>Z</kbd> acts on whatever you're typing in. In the Python pane it takes back your typing first, then
undoes changes to the deck. In a terminal it is the shell's own undo (the same as <kbd>⌃</kbd><kbd>_</kbd>, which zsh,
bash and Claude Code understand), and it never undoes the deck.
