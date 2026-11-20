<#
.SYNOPSIS
  Builds the Windows release: a self-contained Manimble (no .NET install needed) with the shared engine, the example
  deck and install_dependencies.ps1, zipped as Manimble-Windows.zip, and with -Installer also the installer
  Manimble-Windows-Setup.exe (Inno Setup 6, installer\Manimble.iss). The first-launch setup window installs Python
  with Manim (and LaTeX if wanted) into %LOCALAPPDATA%\Manimble on the user's PC. CI runs this (.github/workflows).

  Code signing turns on when MANIMBLE_SIGN_PFX names a .pfx code-signing certificate (MANIMBLE_SIGN_PASSWORD is its
  password): Manimble.exe, the installer and its uninstaller are signed with signtool (Windows SDK) and timestamped.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File apps\windows\build_release.ps1 -Out out -Installer
#>
param(
    [string]$Out = 'out',        # where Manimble-Windows.zip (and Manimble-Windows-Setup.exe) go
    [string]$Dotnet = 'dotnet',  # a dotnet with the .NET 10 SDK
    [switch]$Installer           # also build the installer (needs Inno Setup 6)
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
