# Manimble for Windows

The Windows front end of Manimble. It is a second client of the shared Python engine in [`../../engine`](../../engine),
speaking the JSON protocol in [`../../docs/developers/protocol.md`](../../docs/developers/protocol.md), so a fix to the
engine reaches the macOS and the Windows app alike. Everything that understands manim, source code and decks lives in
the engine. This folder holds only the UI, the working-copy manager and the platform glue. See [PLAN.md](PLAN.md) for
what is done and what comes next.

## Install a release

Download `Manimble-Windows.zip` from the [latest release](https://github.com/pachterlab/Manimble/releases/latest/download/Manimble-Windows.zip),
unzip it anywhere and run `Manimble.exe`. It needs no .NET install. On first launch a setup window offers to install
Python with Manim (and MiKTeX for formulas) for your user account; File > Install Dependencies… brings it back.

## Install from a checkout

```powershell
git clone https://github.com/pachterlab/Manimble.git; cd Manimble
powershell -ExecutionPolicy Bypass -File apps\windows\install_manimble.ps1 -WithLatex
```

The script:
- creates a Python environment with Manim in `%LOCALAPPDATA%\Manimble\python` (using uv when it is installed);
- with `-WithLatex`, installs MiKTeX for formulas and lets it fetch missing LaTeX packages on its own;
- builds the app into `%LOCALAPPDATA%\Programs\Manimble` and adds a Start menu shortcut.

No administrator rights are needed. Building needs the .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`).

## Develop

```powershell
cd apps\windows\Manimble
dotnet build
.\bin\Debug\net10.0-windows\Manimble.exe ..\..\..\examples\hello\deck
```

A build inside the checkout runs the checkout's `engine` folder directly, so engine changes need no rebuild. A
published build carries a copy of the engine next to `Manimble.exe`. `MANIMBLE_ENGINE` and `MANIMBLE_PYTHON` override
both, as on the Mac.

| file | role |
|---|---|
| `Engine.cs` | starts `python -m manimble.rpc`, JSON-lines requests, responses and events; a Job object so render workers die with the app |
| `Tools.cs` | finds Python (`MANIMBLE_PYTHON`, the saved choice, `%LOCALAPPDATA%\Manimble\python`, the checkout `.venv`, `PATH`) and TeX |
| `PortableProject.cs` | portable projects: Save Project Copy (a folder) and Package for Sharing (`.manimble`), the same format as the Mac app's, and unpacking them |
| `FileAssociation.cs` | opens `.manimble` packages from Explorer (registered per user by an installed or unzipped copy) |
| `SetupWindow.cs` | first-launch setup: offers to install a missing Python or LaTeX with `install_dependencies.ps1` (later: File > Install Dependencies…) |
| `Workspace.cs` | the working copy (a port of `apps/macos/Sources/Manimble/Workspace.swift`; directory junctions instead of symlinks) |
| `MainWindow.xaml(.cs)` | navigator, canvas, builds, notes, inspector, source pane, menus and shortcuts |
| `Ruler.cs` | the rulers along the canvas, in manim units; drag a guide off them onto the slide |
| `TableEditing.cs` | table cells: typed into on the slide, or in the inspector's grid (rows and columns added or removed there) |
| `BioCartoon.cs` | the BioCartoon icon search panel (the `biocartoon` command line) and inserting its icons |
| `SlideCanvas.cs` | the canvas: the exact frame when idle, backdrop and sprites while dragging or while an optimistic edit waits for its render |
| `SlideshowWindow.cs` | the full-screen show of the exact frames |
| `Models.cs` | the engine's replies |

Files live in `%LOCALAPPDATA%\Manimble`: `python`, `work` (working copies), `cache` (renders), `manimble.log`,
`setup.log` (the last install) and `settings.json`.

## Platform notes

- Keynote import and export use AppleScript and stay macOS-only; the engine says so. PowerPoint works everywhere.
- Platform paths (TeX, fonts, ffmpeg, system folders) are in `engine/manimble/hostpaths.py`.
- Avoid the Microsoft Store Python for the environment: it redirects writes under `AppData`. The installer skips it.
