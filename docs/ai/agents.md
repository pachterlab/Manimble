# Building slides with an AI agent

Manimble is designed so that you and an AI coding agent can work on the same presentation at the same time. The agent
runs in a terminal inside Manimble's window and edits the deck's Python files. Manimble watches those files and
re-renders the slides as they change, so you see the agent's work on the canvas within seconds. In between, you keep
editing on the canvas yourself.

This chapter explains how to set that up and how to get good results. Any terminal-based coding agent works; Manimble
has built-in support for [Claude Code](https://claude.com/claude-code), [Codex](https://github.com/openai/codex) and
[Gemini CLI](https://github.com/google-gemini/gemini-cli).

## Why this works

A Manimble slide is a short Python program, and coding agents are good at writing and changing Python. An agent can:

- draft a whole slide, or a whole deck, from a description or an outline;
- build animations step by step: "first show the axes, then draw the curve, then label the maximum";
- turn a paper's figure or a table of results into a slide;
- make the same change across many slides, such as a new footer, a consistent title style or renamed terms;
- write a plot from your data file;
- fix a slide that fails to render, by reading the error.

Meanwhile you do what is quicker by hand: nudging a title, retyping a word, recolouring a label, trying a different
size. Both kinds of edit go into the same files, so neither of you overwrites the other's work.

## Before you start

You need an account with the service behind the agent you want to use (Anthropic for Claude Code, OpenAI for Codex,
Google for Gemini CLI). You don't need to install the agent in advance: Manimble offers to install it the first time
you press **Run**.

## Start an agent

1. Open a deck.
2. Choose **View ▸ Show Terminal** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>), or click **Terminal** in the toolbar. A
   terminal opens in the drawer under the slide. It is an ordinary shell, with nothing running in it yet.
3. Click **Run claude** in the drawer's header. Manimble types `claude` into the terminal and starts it.

To use a different agent, click the **▾** beside the Run button and choose **Codex (OpenAI)**, **Gemini CLI
(Google)** or **Custom Command…**. Manimble remembers the choice, so the button then reads **Run codex** or
**Run gemini**. Use Custom Command for any other tool, or for options, for example `claude --model opus` or `aider`.
You can also type the command into the terminal yourself.

If the agent isn't installed, Manimble shows the command that installs it and can type it into the terminal for you.
The first time you run an agent it asks you to sign in.

!!! tip "Give yourself room"
    Drag the divider above the drawer upwards to make the terminal taller, and hide the inspector with
    <kbd>⌥</kbd><kbd>⌘</kbd><kbd>I</kbd> if you need more width. The slide stays visible above the terminal, so you can
    watch it change.

## Where the agent works

The terminal opens in the deck's **working copy**, the same folder Manimble renders the slides from. Everything the
agent changes there appears on the slides, and nothing reaches your original files until you save. Two environment
variables tell the agent (and you) where things are:

| Variable | Contains |
|---|---|
| `$MANIMBLE_DECK` | The working copy: where to edit. |
| `$MANIMBLE_ORIGINAL_DECK` | Your original deck. Not to be edited while Manimble has it open. |

### The instructions Manimble gives the agent

When it opens a deck, Manimble writes an instructions file into the working copy under the three names agents look
for: `CLAUDE.md` (Claude Code), `AGENTS.md` (Codex) and `GEMINI.md` (Gemini CLI). The agent reads it when it starts,
so it knows from the outset:

- to edit the files in the working copy, never the original, and to leave saving to you;
- not to run Manim itself, because Manimble renders;
- how the deck is organised: one class per slide, `self.next_slide()` between builds, `order.txt` for the order of
  the show, and the `# manimble hidden` mark for hidden slides;
- that objects must be added before a build's last `self.play(...)` or `self.wait(...)` to appear in that build;
- how to refer to pictures in the deck folder;
- how to write code that stays editable on the canvas: one statement per object, literal positions in
  `.move_to((x, y, 0))`, helper functions that pass on `**kwargs`, and no renaming or reformatting of code it wasn't
  asked to change;
- to make one change at a time and say which slide it changed.

These files are never saved into your deck and are left out of packages and project copies. If your deck already has
its own `CLAUDE.md`, `AGENTS.md` or `GEMINI.md`, Manimble leaves that file alone and doesn't add its own under that
name.

## Watch the changes arrive

When the agent saves a file, Manimble notices within about two seconds. The slide on screen is re-rendered first and
refreshes by itself, usually one to three seconds after the save. Other slides catch up in the background, and their
thumbnails update in the navigator. New slides the agent adds to `order.txt` appear in the navigator.

If the agent's code fails to run, the slide shows the error, and the navigator marks it. While a file is half
written or has a syntax error, its slides stay listed and show the error until the file is fixed. You can paste the
message to the agent, or simply ask it to fix the slide.

## Work together with the agent

A typical session alternates between asking and adjusting:

1. **Ask for a draft.** "Add a slide after the title called Motivation, with three bullet points about why protein
   structure prediction matters, and a picture of `assets/fold.png` on the right."
2. **Adjust it by hand.** Drag the picture into place, retype a bullet, make a key phrase bold.
3. **Ask for the next step.** "On the Motivation slide, make the bullets appear one at a time, and fade the picture
   in last."
4. **Repeat.** The agent reads the files as they are now, so it sees and keeps your manual changes.

A few habits keep this smooth:

- **Take turns on a slide.** Let the agent finish a change before you edit the same slide by hand, and don't ask the
  agent to change a slide while you are in the middle of editing it. Different slides can be edited at the same time.
- **Name slides precisely.** Refer to slides by their name in the navigator (the class name, such as `Motivation`) or
  by what is on them.
- **Ask for one change at a time.** Small requests render quickly, and you can check each one before the next.
- **Let the agent see what you see.** If something looks wrong, describe it, or take a screenshot and give it to the
  agent if it accepts images.

!!! warning "Undo and the agent's changes"
    **Edit ▸ Undo** (<kbd>⌘</kbd><kbd>Z</kbd>) steps back through changes made in Manimble. It doesn't know about
    changes the agent made. Undo restores a whole file as it was before your change, so if the agent has edited the
    same file since then, undoing your change can also remove the agent's later work. After the agent has changed a
    file, don't use <kbd>⌘</kbd><kbd>Z</kbd> to undo your own earlier changes to it; make the correction by hand or ask
    the agent. To undo the agent's changes, ask the agent, or use **File ▸ Revert to Original…** to discard
    everything since your last save.

## Example requests

Building slides:

- "Make a title slide: *Reading the Genome*, my name underneath, and today's date at the bottom."
- "Add a slide that explains Bayes' theorem in three builds: the formula, then a tree diagram, then a worked example
  with numbers."
- "Turn the outline in `notes/outline.md` into slides, one slide per heading, using bullet points."

Animation:

- "On the Fig4C slide, draw the axes first, then trace the curve from left to right over two seconds."
- "Make the equation on the Derivation slide transform step by step into the simplified form, one step per click."

Data and figures:

- "Insert a bar chart of `data/results.csv` (method on the x axis, accuracy on the y axis) on the Results slide."
- "Recreate the table from `paper/table2.tex` as a Manim table on a new slide after Results."

Whole-deck changes:

- "Put a small grey footer with the talk title on every slide except the title slide."
- "Rename 'pseudoalignment' to 'pseudo-alignment' everywhere, including the speaker notes."
- "Check every slide for text that runs off the edge, and fix it."

Fixing problems:

- "The GroundTruth slide shows an error. Fix it."
- "The labels on the Overview slide overlap. Spread them out evenly."

## Review and save

Before saving, you can review exactly what changed. In a second terminal tab (the **+** button), run:

```bash
diff -ru "$MANIMBLE_ORIGINAL_DECK" .
```

When you are satisfied, choose **File ▸ Save to Original** (<kbd>⌘</kbd><kbd>S</kbd>). This writes every change, the
agent's and yours, to your deck. **File ▸ Revert to Original…** discards them instead.

## Working with git

The working copy is not a git repository. If you keep your deck in git, save from Manimble, then commit in the
original folder as usual.

If you prefer the terminal to start in your project's repository instead (for example, to run git commands there),
turn off **View ▸ Terminal Starts in Working Copy**. Be aware of what changes:

- edits made there go to your original files directly, and the open deck doesn't show them until you reopen it;
- saving from Manimble afterwards can overwrite those edits with the working copy's version.

For editing slides with an agent, keep the setting on, which is the default.

## Troubleshooting

**The Run button says the agent isn't installed, but it is.** Manimble looks for the command on your login shell's
`PATH`, plus `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. If yours is elsewhere, choose
**Custom Command…** and enter its full path.

**The agent prints installation or update messages when it starts.** Some agents update themselves on launch. Let
the update finish, or press <kbd>⌃</kbd><kbd>C</kbd> to skip it.

**The agent's changes don't appear.** Check that **View ▸ Terminal Starts in Working Copy** is on, and that the agent
is editing files in the folder the terminal started in (`echo $MANIMBLE_DECK` shows it).
