<#
.SYNOPSIS
  Builds the Windows release: a self-contained Manimble (no .NET install needed) with the shared engine, the example
  deck and install_dependencies.ps1, zipped as Manimble-Windows.zip, and with -Installer also the installer
  Manimble-Windows-Setup.exe (Inno Setup 6, installer\Manimble.iss). The first-launch setup window installs Python
  with Manim (and LaTeX if wanted) into %LOCALAPPDATA%\Manimble on the user's PC. CI runs this (.github/workflows).

  With -Msix it also builds Manimble-Windows.msix, the package to upload to the Microsoft Store (Partner Center),
  which signs it for free: no certificate is needed for it. Its identity comes from Partner Center (Product
  management > Product identity): MANIMBLE_STORE_NAME (Package/Identity/Name), MANIMBLE_STORE_PUBLISHER
  (Package/Identity/Publisher, "CN=...") and MANIMBLE_STORE_PUBLISHER_NAME (Package/Properties/PublisherDisplayName).
  Without them it gets a local placeholder identity, fine for testing but refused by the Store. The package is left
  unsigned; to try it on a PC with Developer Mode on, register its unpacked folder:
      Add-AppxPackage -Register out\msix\AppxManifest.xml

  Code signing turns on when MANIMBLE_SIGN_PFX names a .pfx code-signing certificate (MANIMBLE_SIGN_PASSWORD is its
  password): Manimble.exe, the installer and its uninstaller are signed with signtool (Windows SDK) and timestamped.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File apps\windows\build_release.ps1 -Out out -Installer -Msix
#>
param(
    [string]$Out = 'out',        # where Manimble-Windows.zip (and Manimble-Windows-Setup.exe) go
    [string]$Dotnet = 'dotnet',  # a dotnet with the .NET 10 SDK
    [switch]$Installer,          # also build the installer (needs Inno Setup 6)
    [switch]$Msix                # also build the Microsoft Store package (needs the Windows SDK)
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = (Resolve-Path "$PSScriptRoot\..\..").Path
$Version = (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Stage = Join-Path $Out 'Manimble'
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }

# ---------------------------------------------------------------- signing (optional)

$Pfx = $env:MANIMBLE_SIGN_PFX
$SignTool = $null
if ($Pfx) {
    if (-not (Test-Path $Pfx)) { throw "MANIMBLE_SIGN_PFX is set but $Pfx does not exist" }
    $SignTool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
    if (-not $SignTool) {
        $SignTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $SignTool) { throw "Signing needs signtool.exe (the Windows SDK)" }
}
$Timestamp = 'http://timestamp.digicert.com'

function Sign([string]$File) {
    if (-not $SignTool) { return }
    $a = @('sign', '/fd', 'sha256', '/f', $Pfx, '/tr', $Timestamp, '/td', 'sha256', '/d', 'Manimble')
    if ($env:MANIMBLE_SIGN_PASSWORD) { $a += @('/p', $env:MANIMBLE_SIGN_PASSWORD) }
    & $SignTool @a $File
    if ($LASTEXITCODE -ne 0) { throw "Signing $File failed" }
}

# ---------------------------------------------------------------- the app

& $Dotnet publish (Join-Path $PSScriptRoot 'Manimble\Manimble.csproj') -c Release -r win-x64 --self-contained true `
    -p:PublishReadyToRun=false -o $Stage
if ($LASTEXITCODE -ne 0) { throw "The build failed" }

foreach ($f in 'Manimble.exe', 'ManimbleDocument.ico', 'install_dependencies.ps1', 'engine\requirements.txt', 'engine\manimble\rpc.py') {
    if (-not (Test-Path (Join-Path $Stage $f))) { throw "The build lacks $f" }
}
# the example deck, for File > Open Example Deck
$ex = Join-Path $Stage 'examples\hello\deck'
New-Item -ItemType Directory -Force $ex | Out-Null
Copy-Item (Join-Path $Root 'examples\hello\deck\*') $ex -Recurse -Force
Get-ChildItem $Stage -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
Copy-Item (Join-Path $Root 'LICENSE') $Stage
Sign (Join-Path $Stage 'Manimble.exe')

$zip = Join-Path $Out 'Manimble-Windows.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $Stage -DestinationPath $zip
"{0} ({1:N0} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)

# ---------------------------------------------------------------- the Microsoft Store package

function Find-SdkTool([string]$Name) {
    $t = (Get-Command $Name -ErrorAction SilentlyContinue).Source
    if (-not $t) {
        $t = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$Name" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $t) { throw "The Store package needs $Name (the Windows SDK)" }
    return $t
}

if ($Msix) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION ($Version) must be major.minor.patch for the Store package" }
    $identity = @{
        Name                 = if ($env:MANIMBLE_STORE_NAME) { $env:MANIMBLE_STORE_NAME } else { 'Manimble.Local' }
        Publisher            = if ($env:MANIMBLE_STORE_PUBLISHER) { $env:MANIMBLE_STORE_PUBLISHER } else { 'CN=Manimble Local' }
        PublisherDisplayName = if ($env:MANIMBLE_STORE_PUBLISHER_NAME) { $env:MANIMBLE_STORE_PUBLISHER_NAME } else { 'Pachter Lab' }
        Version              = "$Version.0"   # the Store keeps the fourth part for itself: it must be 0
    }
    if (-not $env:MANIMBLE_STORE_NAME -or -not $env:MANIMBLE_STORE_PUBLISHER) {
        Write-Warning "MANIMBLE_STORE_NAME / MANIMBLE_STORE_PUBLISHER are not set: the package gets a local identity the Store will refuse"
    }
    $makeappx = Find-SdkTool 'makeappx.exe'
    $makepri = Find-SdkTool 'makepri.exe'
    $MsixSrc = Join-Path $PSScriptRoot 'msix'

    # the unpacked package: the staged app, the tile images, the manifest and resources.pri
    $layout = Join-Path $Out 'msix'
    if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
    Copy-Item $Stage $layout -Recurse
    New-Item -ItemType Directory -Force (Join-Path $layout 'Assets') | Out-Null
    Copy-Item (Join-Path $MsixSrc 'Assets\*.png') (Join-Path $layout 'Assets') -Force
    $manifest = Get-Content (Join-Path $MsixSrc 'AppxManifest.xml') -Raw
    foreach ($k in $identity.Keys) { $manifest = $manifest.Replace("`$$k`$", [Security.SecurityElement]::Escape($identity[$k])) }
    if ($manifest -match '\$[A-Za-z]+\$') { throw "AppxManifest.xml still has a token: $($Matches[0])" }
    [IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))

    # resources.pri maps Assets\StoreLogo.png and the rest to their scale-/targetsize- variants. It indexes a
    # folder holding only the images, so the engine's files don't become resources.
    $pri = Join-Path $Out 'msix-pri'
    if (Test-Path $pri) { Remove-Item -Recurse -Force $pri }
    New-Item -ItemType Directory -Force (Join-Path $pri 'Assets') | Out-Null
    Copy-Item (Join-Path $MsixSrc 'Assets\*.png') (Join-Path $pri 'Assets')
    $cfg = Join-Path $Out 'priconfig.xml'
    & $makepri createconfig /cf $cfg /dq en-US /pv 10.0.0 /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makepri createconfig failed" }
    & $makepri new /pr $pri /cf $cfg /mn (Join-Path $layout 'AppxManifest.xml') /of (Join-Path $layout 'resources.pri') /o
    if ($LASTEXITCODE -ne 0) { throw "makepri new failed" }
    Remove-Item -Recurse -Force $pri, $cfg

    $package = Join-Path $Out 'Manimble-Windows.msix'
    & $makeappx pack /d $layout /p $package /o
    if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed" }
    "{0} ({1:N0} MB, {2} {3})" -f $package, ((Get-Item $package).Length / 1MB), $identity.Name, $identity.Version
}

# ---------------------------------------------------------------- the installer

if (-not $Installer) { return }
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
              "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw "The installer needs Inno Setup 6 (winget install JRSoftware.InnoSetup)" }
$isccArgs = @("/DStage=$Stage", "/DAppVersion=$Version", "/O$Out", '/Q')
if ($SignTool) {
    # Inno Setup signs the uninstaller it writes into the installer with this command ($f is the file, $q a quote:
    # Windows PowerShell mangles literal quotes inside an argument it passes on)
    $pw = if ($env:MANIMBLE_SIGN_PASSWORD) { ' /p $q' + $env:MANIMBLE_SIGN_PASSWORD + '$q' } else { '' }
    $isccArgs += @('/DSign', ('/Ssigntool=$q' + $SignTool + '$q sign /fd sha256 /f $q' + $Pfx + '$q' + $pw + " /tr $Timestamp /td sha256 /d Manimble " + '$f'))
}
& $iscc @isccArgs (Join-Path $PSScriptRoot 'installer\Manimble.iss')
if ($LASTEXITCODE -ne 0) { throw "Building the installer failed" }
$setup = Join-Path $Out 'Manimble-Windows-Setup.exe'
Sign $setup
"{0} ({1:N0} MB)" -f $setup, ((Get-Item $setup).Length / 1MB)
