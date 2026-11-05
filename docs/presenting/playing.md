# Playing a presentation

Manimble presents a deck full screen, in one of two forms:

- **With animations**, the real Manim animations play as video between builds. This is how a Manim presentation is
  meant to be seen.
- **As stills**, the show steps through a picture of each build, with a fade between them. Stills are ready
  immediately, because the editor has already made them.

**Play ▸ Show Animations** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>A</kbd>) chooses between the two. When it is ticked, the Play
commands, Presenter View and scripted presentations use animations; when it isn't, they use stills.

## Start and stop

| Command | Shortcut |
|---|---|
| **Play ▸ Play from Beginning** | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| **Play ▸ Play from Current Slide** | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| **Play ▸ Presenter View** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>P</kbd> |

Press <kbd>Esc</kbd> or <kbd>Q</kbd> to end the show. Hidden slides are skipped.

## Building the animations

The animations are rendered by Manim Slides into video clips. The first time you play a deck with animations, every
slide is built, which can take a few minutes; a pill in the top-right corner of the window shows the progress. After
that, only slides whose code has changed are built again. Slides that are still building when the show reaches them
show their still picture, then switch to the animation once it is ready.

Builds go into the working copy's `slides/` folder, so building never changes the builds in your original deck.
Slides you built outside Manimble with Manim Slides are used as they are, unless you have changed them since.

### Animation resolution

**Play ▸ Animation Resolution** sets the size the animations are built at: **720p** (the default, and the fastest
to build), **1080p**, **1440p** or **4K**. Higher resolutions look sharper on large screens and projectors but take
longer to build. After you change the resolution, each slide is rebuilt once, the next time it is played.

## Keys during a show

| Action | Animated show | Stills |
|---|---|---|
| Next build | <kbd>→</kbd> <kbd>↓</kbd> <kbd>↩</kbd> <kbd>Page Down</kbd>, or click | <kbd>→</kbd> <kbd>↓</kbd> <kbd>Space</kbd> <kbd>↩</kbd> <kbd>Page Down</kbd>, or click |
| Previous build | <kbd>←</kbd> <kbd>↑</kbd> <kbd>⌫</kbd> <kbd>Page Up</kbd>, or right-click | <kbd>←</kbd> <kbd>↑</kbd> <kbd>⌫</kbd> <kbd>Page Up</kbd>, or right-click |
| Next slide, skipping its remaining builds | <kbd>N</kbd> | <kbd>N</kbd> |
| First / last slide | <kbd>Home</kbd> / <kbd>End</kbd> | <kbd>Home</kbd> / <kbd>End</kbd> |
| Pause or resume the animation | <kbd>Space</kbd> | |
| Replay the current build | <kbd>R</kbd> | |
| Play the current build in reverse | <kbd>V</kbd> | |
| Jump to chapter 1–9 | <kbd>1</kbd> … <kbd>9</kbd> | |
| Black screen, and back | <kbd>B</kbd> or <kbd>.</kbd> | <kbd>B</kbd> or <kbd>.</kbd> |
| Show or hide the progress bar | <kbd>P</kbd> | <kbd>P</kbd> |
| End the show | <kbd>Esc</kbd> or <kbd>Q</kbd> | <kbd>Esc</kbd> or <kbd>Q</kbd> |

Going back to a previous build shows how that build ends, rather than playing it again.

The animated show honours what the deck's code asks of Manim Slides: builds that loop, builds that continue to the
next one automatically, and playback rates.

## Links and chapters

Text with a [hyperlink](../guide/text.md#hyperlinks) opens its link when you click it during a show. In the stills
show the pointer becomes a hand over a link.

A deck can define **chapters** and extra clickable regions in a `present.json` file in the deck folder. With chapters,
<kbd>1</kbd>–<kbd>9</kbd> jump to them, and clicking the bottom strip of the slide jumps to the chapter under the
pointer. See [Deck file format](../reference/deck-format.md#presentjson).

## Preview one slide's animations

To check a slide's animations without starting a show, choose **Play ▸ Preview Current Slide's Animations**
(<kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd>). Manimble builds the slide if needed and plays it in the editor, build after
build, with a short pause between builds. Use **Previous build**, **Next build** and **Replay**, the arrow keys, or
a click on the slide to step through it by hand, and the player's controls to pause or scrub. Click **Close** to
return to editing.

## Dark mode in a show

If **View ▸ Dark Mode** or **View ▸ Invert Colors** is on, the stills show uses those colours too. The animated show
uses them as well. Exports always use the real colours. See
[Themes, backgrounds and colour](../guide/design.md#dark-mode-and-inverted-colours).
