<#
.SYNOPSIS
  Builds the Windows release: a self-contained Manimble (no .NET install needed) with the shared engine, the example
  deck and install_dependencies.ps1, zipped as Manimble-Windows.zip. The first-launch setup window installs Python
  with Manim (and LaTeX if wanted) into %LOCALAPPDATA%\Manimble on the user's PC. CI runs this (.github/workflows).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File apps\windows\build_release.ps1 -Out out
#>
param(
    [string]$Out = 'out',        # where Manimble-Windows.zip goes
    [string]$Dotnet = 'dotnet'   # a dotnet with the .NET 10 SDK
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = (Resolve-Path "$PSScriptRoot\..\..").Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Stage = Join-Path $Out 'Manimble'
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }

& $Dotnet publish (Join-Path $PSScriptRoot 'Manimble\Manimble.csproj') -c Release -r win-x64 --self-contained true `
    -p:PublishReadyToRun=false -o $Stage
if ($LASTEXITCODE -ne 0) { throw "The build failed" }

foreach ($f in 'Manimble.exe', 'install_dependencies.ps1', 'engine\requirements.txt', 'engine\manimble\rpc.py') {
    if (-not (Test-Path (Join-Path $Stage $f))) { throw "The build lacks $f" }
}
# the example deck, for File > Open Example Deck
$ex = Join-Path $Stage 'examples\hello\deck'
New-Item -ItemType Directory -Force $ex | Out-Null
Copy-Item (Join-Path $Root 'examples\hello\deck\*') $ex -Recurse -Force
Get-ChildItem $Stage -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
Copy-Item (Join-Path $Root 'LICENSE') $Stage

$zip = Join-Path $Out 'Manimble-Windows.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $Stage -DestinationPath $zip
"{0} ({1:N0} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)
