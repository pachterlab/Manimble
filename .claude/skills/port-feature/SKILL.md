---
name: port-feature
description: Bring a feature or fix made in one Manimble app to the other, so the macOS app (Swift/AppKit, apps/macos) and the Windows app (C#/WPF, apps/windows) stay in step. Finds what changed on one side (a commit, a branch, or uncommitted work), works out what part belongs in the shared engine and what is UI, writes the matching code in the other app with the same menus, shortcuts, file formats and behaviour, builds what can be built, and updates the docs. Use when asked to "port this to Windows", "port this to the Mac", "bring this feature to the other app", "keep the Mac and Windows apps in sync", "add the same feature on Windows/macOS", "port-feature", or after finishing a feature in one app.
---

# Port a feature between the Mac and Windows apps

Manimble has two front ends over **one** Python engine (`engine/manimble`, JSON lines over stdio, see
`docs/developers/protocol.md`):

| | macOS | Windows |
|---|---|---|
| code | `apps/macos/Sources/Manimble/*.swift` (Swift, AppKit, Metal) | `apps/windows/Manimble/*.cs`, `*.xaml` (C# / .NET 10, WPF) |
| build | `apps/macos/build_app.sh` | `cd apps/windows/Manimble; dotnet build` |
| app data | `~/Library/Application Support/Manimble` | `%LOCALAPPDATA%\Manimble` (`Paths.cs`) |
| status doc | `README.md`, `docs/` | `apps/windows/PLAN.md`, `apps/windows/README.md` |

The goal of a port is that a user moving between the two apps finds the same feature, in the same menu, with the
same name, the same shortcut (Cmd ↔ Ctrl) and the same files on disk, so a deck or `.manimble` package edited in one
opens unchanged in the other.

## 1. Find what changed (the source side)

Work out which commits or files hold the feature. Ask only if none of these settles it:

- the user named a commit, branch, PR or files: use them;
- otherwise uncommitted work: `git status`, `git diff` (and `git diff --staged`);
- otherwise the branch against `main`: `git log --oneline main..HEAD`, `git diff main...HEAD --stat`.

Sort the changed files into three groups:

1. `engine/` — already shared. Both apps get it with no work, as long as the other app sends the request.
2. `apps/macos/` — the source is the Mac; the target is Windows.
3. `apps/windows/` — the source is Windows; the target is the Mac.

If the change touches both apps already, compare them and port only the part one side is missing.

Read the whole of each changed source-side function, not only the diff hunks, and read the target-side counterpart
before writing anything. Other sessions may be editing the same checkout: re-read a file right before you edit it.

## 2. Decide where each piece belongs

- **Logic that knows about manim, Python source, decks, rendering or file formats belongs in the engine**, not in
  either app. If the source side put such logic in Swift or C#, propose moving it into `engine/manimble` behind a
  new or extended RPC request (document it in `docs/developers/protocol.md`), and have both apps call it. This is the
  best port: it fixes both apps at once and keeps them from drifting. Do it when the logic is more than a few lines;
  ask the user first if it means rewriting the source side's working code.
- **Platform paths** (TeX, fonts, ffmpeg, system folders) go in `engine/manimble/hostpaths.py`.
- **UI and platform glue** is ported by hand to the target app.
- **Genuinely platform-only features** (Keynote via AppleScript, macOS subject lifting for Extract Elements, ConPTY,
  Explorer file association, the Microsoft Store) are not ported. Say so, and record it in the target side's docs
  (on Windows, `apps/windows/PLAN.md` already lists such decisions; follow its style). If a reasonable equivalent
  exists (e.g. Windows text to speech for the Mac's `AVSpeechSynthesizer`), port to that and note the difference.

## 3. Find the counterpart files

Most files have a twin with the same name. The Windows files say which Mac file they port in their first comment
(`grep -n "the Mac" apps/windows/Manimble/<File>.cs`). Known pairs:

| macOS (`apps/macos/Sources/Manimble`) | Windows (`apps/windows/Manimble`) |
|---|---|
| `Engine.swift` | `Engine.cs` (+ Python discovery in `Tools.cs`) |
| `Models.swift` | `Models.cs` |
| `Workspace.swift` | `Workspace.cs` (directory junctions instead of symlinks; files copied) |
| `MainController.swift`, `Views.swift`, `AppDelegate.swift` (menus) | `MainWindow.xaml`, `MainWindow.xaml.cs` |
| `CanvasView.swift` | `SlideCanvas.cs` |
| `FormatBar.swift`, `Toolbar.swift` | `FormatRow.cs`, `Toolbar.cs` |
| `RulerView.swift` | `Ruler.cs` |
| `ZoomTiles.swift` | `ZoomTiles.cs` |
| `Player.swift`, `AnimatedPlayer.swift` | `SlideshowWindow.cs`, `AnimatedShowWindow.cs`, `ShowZoom.cs` |
| `Presenter.swift` | `PresenterWindow.cs` |
| `Script.swift`, `ScriptPane.swift`, `ScriptMovie.swift`, `CloudVoice.swift` | `Script.cs`, `ScriptPane.cs` |
| `Feedback.swift` | `Feedback.cs`, `FeedbackWiring.cs` |
| `PortableProject.swift` | `PortableProject.cs` |
| `NewDeck.swift`, exports/imports in `MainController.swift` | `Sharing.cs` |
| `Setup.swift` | `SetupWindow.cs` |
| `TerminalPanel.swift` | `TerminalPanel.cs`, `ConPty.cs` |
| `AgentInstructions.swift` | `AgentInstructions.cs` (same text) |
| `BioCartoon.swift`, `BioCartoonLibrary.swift` | `BioCartoon.cs` |
| `PythonPlot.swift` | `PythonPlot.cs` |
| `SlidePaste.swift` | `Clipboard.cs` |
| `SlideTools.swift`, `Arrange.swift`, `Background.swift`, `DeckThemes.swift`, `DarkMode.swift`, `Find.swift`, `Hyperlink.swift` | mostly `DeckTools.cs` and `MainWindow.xaml.cs` |
| sheets and alerts | `Dialogs.cs` |
| `*Test.swift` (headless `MANIMBLE_TEST_*` hooks) | `*Test` methods behind `MANIMBLE_TEST_*` in the matching `.cs` |

When there is no twin, `grep` the target side for the engine request name (e.g. `"edit_source"`), the menu title or
a distinctive setting key; that usually lands on the right place. Put a new feature in a new file when the source
side did, named the same.

## 4. Write the port

Match the target app's existing idioms, not the source language's: read neighbouring code first.

- **Same names everywhere the user sees them:** menu titles and placement, button labels, tooltips, dialog text.
  Shortcuts map Cmd → Ctrl, Option → Alt (watch for Windows conflicts, e.g. Alt+F4; pick the nearest free one and
  say so).
- **Same files on disk, byte-compatible:** `script.json`, `feedback.json`, `manimble-project.json`, `*.plot.json`,
  settings keys, guide positions, and so on. Same JSON field names and casing, forward slashes in stored paths, UTF-8.
  A deck saved by one app must open unchanged in the other.
- **Same engine calls** with the same parameters; extend `Models.swift` / `Models.cs` together if a reply grew.
- **Same behaviour around edits:** optimistic moves/resizes, undo/redo entries, dirty state, re-render after edits.
- **Platform translations:** `NSAlert`/sheets → `Dialogs.cs`; `UserDefaults` → the Windows `settings.json`;
  `FileManager` symlinks → junctions / copies; `NSWorkspace.open` → `Process.Start(new ProcessStartInfo(path)
  { UseShellExecute = true })`; `DispatchQueue.main` → `Dispatcher`; and back the other way when porting to the Mac.
- **Swift ↔ C# gotchas:** WPF image files must not be locked (load through `Images.cs`); Windows paths may contain
  spaces and backslashes (quote them, and never build a Python literal from a raw path); line endings in decks may be
  CRLF; Windows has no `fork`/signals (use the Job object in `Engine.cs` for child processes).
- If the source side has a `MANIMBLE_TEST_*` hook for the feature, add the matching hook on the target side.

Keep the scope to the feature. Do not refactor unrelated code in the target app.

## 5. Build and check

- **Mac target:** `apps/macos/build_app.sh` (on a Mac). Never overwrite a running `Manimble.app`; build elsewhere or
  quit it first. Exercise the feature headlessly with its `MANIMBLE_TEST_*` hook when there is one, or ask the user
  to try it.
- **Windows target on Windows:** `cd apps/windows/Manimble; dotnet build`, then run
  `.\bin\Debug\net10.0-windows10.0.19041.0\Manimble.exe ..\..\..\examples\hello\deck`.
- **Windows target from a Mac or Linux:** the WPF project can be *compiled* (not run) with the .NET 10 SDK:
  `dotnet build apps/windows/Manimble -p:EnableWindowsTargeting=true`. Check `dotnet --list-sdks` first; without
  .NET 10 say that the compile check was not run.
- **Mac target from Windows:** Swift/AppKit cannot be built off macOS. Say so.
- Either way, `.github/workflows/build.yml` builds **both** apps on every push and PR. When a side could not be built
  locally, tell the user to push a branch and check that workflow (`gh run watch`), and do not claim the port
  compiles until one of these builds passed.
- Engine changes: run the relevant tests in `tests/` (`python -m pytest tests -q -k <area>`).

## 6. Update the docs

- Windows target: update the status in `apps/windows/PLAN.md` (the Phase 2/3 paragraphs) and the file table in
  `apps/windows/README.md` if a file was added.
- Mac target: update `README.md` / `docs/` where the feature is described, if it was described only for Windows.
- Engine/protocol change: `docs/developers/protocol.md`.
- Anything deliberately not ported, or ported with a difference: one sentence in the target side's docs.

## 7. Report

Tell the user, briefly:
- what was ported, file by file on the target side (and anything moved into the engine);
- what was left out or behaves differently, and why;
- which builds/checks ran and their result, and which could not run here (and that CI will run them).

Do not commit unless the user asks. If they do, one commit with both sides of the feature is ideal, so the history
shows the two apps moving together.
