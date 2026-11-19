<#
.SYNOPSIS
  Installs Manimble for Windows from this checkout: the Python environment with Manim, optionally LaTeX, and the
  app itself (in %LOCALAPPDATA%\Programs\Manimble, with a Start menu shortcut). No administrator rights are needed,
  except for LaTeX if you ask for it and winget installs it for all users.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File apps\windows\install_manimble.ps1
  powershell -ExecutionPolicy Bypass -File apps\windows\install_manimble.ps1 -WithLatex
#>
param(
    [switch]$WithLatex,       # also install MiKTeX (formulas: MathTex, Tex) with winget
    [switch]$SkipPython,      # the Python environment is already set up
    [switch]$SkipApp          # only the dependencies
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..\..").Path

# Python with Manim, and with -WithLatex MiKTeX: the same script the app's first-launch setup runs
$deps = @{ Requirements = (Join-Path $Root 'engine\requirements.txt') }
if ($WithLatex) { $deps.WithLatex = $true }
if ($SkipPython) { $deps.SkipPython = $true }
if (-not $SkipPython -or $WithLatex) { & (Join-Path $PSScriptRoot 'install_dependencies.ps1') @deps }

if (-not $SkipApp) {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet -or -not (& dotnet --list-sdks)) {
        throw "Building the app needs the .NET 10 SDK: winget install Microsoft.DotNet.SDK.10"
    }
    $Out = Join-Path $env:LOCALAPPDATA 'Programs\Manimble'
    Write-Host "Building Manimble into $Out"
    & dotnet publish (Join-Path $PSScriptRoot 'Manimble\Manimble.csproj') -c Release -r win-x64 --self-contained false -o $Out
    if ($LASTEXITCODE -ne 0) { throw "The build failed" }
    # the example deck comes along for File > Open Example Deck
    $ex = Join-Path $Out 'examples\hello\deck'
    New-Item -ItemType Directory -Force $ex | Out-Null
    Copy-Item (Join-Path $Root 'examples\hello\deck\*') $ex -Recurse -Force
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Manimble.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $Out 'Manimble.exe'
    $s.WorkingDirectory = $Out
    $s.Save()
    Write-Host "Installed. Start Manimble from the Start menu, or run $Out\Manimble.exe"
}
