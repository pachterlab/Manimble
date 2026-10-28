# Deck themes

Each `<id>.py` here is a complete `common.py` for a new deck (File ▸ New Deck… lists them; `midnight` is the default).
A theme is plain Python: it defines the `Deck` base class every slide derives from, plus these top-level constants,
which Manimble reads from the deck's source:

| constant      | used for                                                                   |
|---------------|----------------------------------------------------------------------------|
| `THEME`       | the name shown in the New Deck picker                                      |
| `BACKGROUND`  | `#RRGGBB`, written to the deck's `manim.cfg` as `background_color`         |
| `FONT`        | font of the title slide and of text Manimble inserts or types into layouts |
| `TEXT_COLOR`  | colour of that text, and of inserted shapes, lines and formulas            |
| `MUTED_COLOR` | the title slide's subtitle                                                 |
| `ACCENT`      | free for the deck's own use (rules, highlights)                            |

To add a theme, drop another file in this folder with the same constants. Keep values plain string literals.
