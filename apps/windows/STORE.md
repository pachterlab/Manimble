# Releasing Manimble for Windows through the Microsoft Store

The Store signs the package itself, so a Store release needs no code-signing certificate and costs nothing (individual
developer accounts are free). Users install and update Manimble from the Store with no SmartScreen warning.

What is in the repository:
- [`msix/AppxManifest.xml`](msix/AppxManifest.xml): the package manifest (a full-trust desktop app, the `.manimble`
  file association, write virtualization off; see the comment at its top).
- [`msix/Assets`](msix/Assets): the tile and Store images, made from the app's icons by
  [`msix/make_assets.py`](msix/make_assets.py).
- `build_release.ps1 -Msix`: builds `out\Manimble-Windows.msix` (the file to upload) and leaves its unpacked folder in
  `out\msix`.
- The release workflow builds the package on every run, as the workflow artifact **Manimble-Windows-Store**.

## Once: the Partner Center account and the app's identity

1. Sign up for a developer account at <https://storedeveloper.microsoft.com> (Individual is free; Company asks for a
   business verification). Microsoft checks your identity before you can submit, which can take a few days.
2. In Partner Center: **Apps and games > New product > MSIX or PWA app**, and reserve the name **Manimble**.
3. Open the app's **Product management > Product identity** page and copy three values into repository variables
   (Settings > Secrets and variables > Actions > *Variables*, not secrets; they are public in every package anyway):

   | Partner Center field | Repository variable |
   |---|---|
   | Package/Identity/Name | `MANIMBLE_STORE_NAME` |
   | Package/Identity/Publisher (`CN=...`) | `MANIMBLE_STORE_PUBLISHER` |
   | Package/Properties/PublisherDisplayName | `MANIMBLE_STORE_PUBLISHER_NAME` |

   ```sh
   gh variable set MANIMBLE_STORE_NAME --body '<Package/Identity/Name>'
   gh variable set MANIMBLE_STORE_PUBLISHER --body 'CN=<...>'
   gh variable set MANIMBLE_STORE_PUBLISHER_NAME --body '<PublisherDisplayName>'
   ```

   A tagged release refuses to build without them. A package built without them gets a placeholder identity
   (`Manimble.Local`), which is fine for testing on your own PC but which the Store refuses.

## Each release

1. Bump `VERSION`, commit, tag and push as usual (the top of `.github/workflows/release.yml`). The Store version is
   `VERSION` plus `.0`, and each submission's version has to be higher than the last one.
2. When the release workflow finishes, download the **Manimble-Windows-Store** artifact from the run. It holds
   `Manimble-Windows.msix`.
3. In Partner Center, start a submission (the first time it walks through every section; later ones copy the last):
   - **Packages**: upload `Manimble-Windows.msix`. Leave device families at Windows 10/11 Desktop.
   - **Pricing and availability**: Free.
   - **Properties**: category *Productivity* (or *Education*). Privacy policy URL: the docs site's privacy page
     (`docs/reference/privacy.md`).
   - **Age ratings**: the questionnaire (no user-to-user content, no purchases).
   - **Store listing**: description, at least one screenshot (1366×768 or larger), and the Store logo.
   - **Submission options > Notes for certification**: paste the text below.
4. Submit. Certification usually takes from a few hours to three business days; the first review of an app with
   restricted capabilities can take longer.

### Why the restricted capabilities (paste into the justification boxes)

> **runFullTrust**: Manimble is a WPF desktop app (.NET). It starts a Python process to render slides with the
> Manim library, a terminal (ConPTY) for command-line tools, and PowerShell for its first-launch setup.
>
> **unvirtualizedResources**: on first launch Manimble's setup window, with the user's consent, creates a Python
> environment in %LOCALAPPDATA%\Manimble and can install Python (with winget) and TinyTeX (a LaTeX distribution) for the current user
> in %APPDATA%TinyTeX. These have to land in the real user profile, not a per-package copy: the user runs the same Python and
> LaTeX from their own terminal and editors, TinyTeX installs packages into its own folder on demand, and the decks
> the user writes import that Python environment. The app writes nothing outside the user's profile.

### Notes for certification (paste into Submission options)

> Manimble makes presentation slides from Python code with the open-source Manim library. On first launch a setup
> window asks to install Python with Manim (from PyPI, with pip) and optionally TinyTeX for formulas (from GitHub, checked against its SHA-256); the user can
> decline, and File > Install Dependencies… brings it back. Nothing is downloaded without the user choosing it.
> Without Python installed the app opens and shows the setup window. To test it fully, accept the setup (a few
> minutes), then File > Open Example Deck.

Store policy 10.2.2 covers apps that download code. The setup only installs the user's own development tools
(Python, packages from PyPI, LaTeX), with consent, the way an IDE does, but a reviewer may still ask about it. If they
do, explain that again and point to the setup window.

## Trying the package before submitting

On a Windows PC with **Settings > System > For developers > Developer Mode** on, after
`build_release.ps1 -Out out -Msix`:

```powershell
Add-AppxPackage -Register out\msix\AppxManifest.xml      # installs the unpacked package as if from the Store
# ... try it: Start menu > Manimble, double-click a .manimble file, run the first-launch setup ...
Get-AppxPackage *Manimble* | Remove-AppxPackage            # uninstall
```

The Windows App Certification Kit runs most of the Store's automated checks locally (it comes with the Windows SDK):
`& "${env:ProgramFiles(x86)}\Windows Kits\10\App Certification Kit\appcert.exe" test -appxpackagepath out\Manimble-Windows.msix -reportoutputpath out\wack.xml`.

How the packaged app differs from the zip and installer builds:
- Its install folder is read-only, so it runs a copy of the engine from `%LOCALAPPDATA%\Manimble\engine\<version>`,
  made on the first start of each version (`Paths.cs`). That way Python can keep the engine's compiled bytecode.
- The `.manimble` association comes from the manifest, not the registry (`FileAssociation.cs` skips it).
- Uninstalling it leaves `%LOCALAPPDATA%\Manimble` (Python, settings, logs) in place, as the installer's uninstaller
  does.
