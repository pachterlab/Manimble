# The terminal

Manimble has a terminal built into the drawer under the slide. It runs your login shell, so your usual commands,
aliases and tools are available. Use it to run an AI agent (see
[Building slides with an AI agent](agents.md)), to edit files, or to run any command-line tool on the deck.

## Show and hide the terminal

- **View ▸ Show Terminal** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>), or **Terminal** in the toolbar, shows the terminal,
  or hides it if it is already showing.
- The first time you show it, Manimble starts a shell in the deck's working copy.

The terminal shares the drawer with the notes tabs. Click a tab to switch between them.

## Several terminals

You can run several shells side by side, for example an agent in one and a plain shell in another.

| To | Do this |
|---|---|
| Open another terminal in a new tab | Click **+** in the drawer's tab strip, or choose **View ▸ New Terminal** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd>) |
| Open another shell beside the active one | Click the split button in the drawer's header, or choose **View ▸ Split Terminal** (<kbd>⌘</kbd><kbd>\\</kbd>) |
| Switch terminals | Click its tab, or click a pane in a split tab |
| Close a terminal | Hover over its tab and click its close button, or click the trash button in the header |

## The header buttons

The buttons in the drawer's header act on the active terminal:

| Button | What it does |
|---|---|
| **Run claude** (or the agent you chose) | Types the agent's command into the terminal and starts it. |
| **▾** | Chooses the agent: Claude Code, Codex (OpenAI), Gemini CLI (Google), or a custom command. Agents that aren't installed are marked. |
| Split | Opens another shell beside the active one. |
| Restart (↻) | Ends the shell and starts a fresh one in the same folder. |
| Trash | Ends the shell and closes the terminal. Closing the last one hides the drawer. |
| Hide (⌄) | Hides the drawer; the shells keep running. |

When you choose an agent that isn't installed, Manimble shows how to install it and offers to type the install
command into the terminal.

## Edit commands in the terminal

While you're typing in the terminal, the Edit menu acts on the terminal, never on the slide:

| Command | In the terminal |
|---|---|
| **Copy** (<kbd>⌘</kbd><kbd>C</kbd>) | Copies the text you selected with the mouse. |
| **Paste** (<kbd>⌘</kbd><kbd>V</kbd>) | Types the clipboard into the shell. |
| **Select All** (<kbd>⌘</kbd><kbd>A</kbd>) | Selects everything in the terminal, including the scrollback. |
| **Undo** (<kbd>⌘</kbd><kbd>Z</kbd>) | The shell's own undo, the same as <kbd>⌃</kbd><kbd>_</kbd>. |
| **Find…** (<kbd>⌘</kbd><kbd>F</kbd>) | Opens a find bar that searches the terminal's text. |

Cut and Redo are greyed out: a terminal has no Cut, and shells have no standard key for redo.

## Where the terminal starts

By default every terminal starts in the deck's **working copy**: the folder Manimble renders the slides from. Files
you change there update the slides within about two seconds.

To start terminals in the original deck's project repository instead (its git root, or the folder that contains the
deck), turn off **View ▸ Terminal Starts in Working Copy**. Running terminals restart in the new folder. Edits made
there change your original files directly and don't show on the open deck. See
[Working with git](agents.md#working-with-git).

## Environment

Each shell has these environment variables set:

| Variable | Value |
|---|---|
| `MANIMBLE_DECK` | The deck's working copy |
| `MANIMBLE_ORIGINAL_DECK` | The original deck |
| `TERM` | `xterm-256color`, with true colour |

`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` are added to the front of `PATH`, so tools installed in those
places are found even if your shell profile doesn't add them.

## Notes

- The terminal's scrollback isn't kept after you close the deck.
- Closing a deck's window ends its shells and anything running in them.
- The terminals restart, ending any running agent, if Manimble's engine is restarted with
  **Manimble ▸ Choose Python…**.
