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
$Base = Join-Path $env:LOCALAPPDATA 'Manimble'
$PyEnv = Join-Path $Base 'python'
$PyExe = Join-Path $PyEnv 'Scripts\python.exe'
New-Item -ItemType Directory -Force $Base | Out-Null

function Find-BasePython {
    # a python.org or uv-managed CPython 3.11+; never the Microsoft Store's (it redirects writes under AppData)
    $cands = @()
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in '3.12', '3.13', '3.11') {
            try { $p = (& py "-$v" -c "import sys; print(sys.executable)" 2>$null); if ($p) { $cands += $p.Trim() } } catch {}
        }
    }
    $cands += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python31*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName
    foreach ($c in $cands) { if ($c -and (Test-Path $c) -and ($c -notmatch 'WindowsApps')) { return $c } }
    return $null
}

if (-not $SkipPython) {
    if (Test-Path $PyExe) {
        Write-Host "Python environment: $PyEnv (updating its packages)"
    } else {
        Write-Host "Creating the Python environment in $PyEnv"
        $uv = Get-Command uv -ErrorAction SilentlyContinue
        $base = Find-BasePython
        if ($base) {
            if ($uv) { & uv venv --python $base $PyEnv } else { & $base -m venv $PyEnv }
        } elseif ($uv) {
            & uv venv --python 3.12 --python-preference only-managed $PyEnv
        } else {
            Write-Host "No Python 3.11+ found. Installing Python 3.12 for this user with winget…"
            winget install --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements
            $base = Find-BasePython
            if (-not $base) { throw "Python 3.12 was installed but not found; open a new terminal and run this script again." }
            & $base -m venv $PyEnv
        }
    }
    $req = Join-Path $Root 'engine\requirements.txt'
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        & uv pip install --python $PyExe -r $req
    } else {
        & $PyExe -m pip install --upgrade pip
        & $PyExe -m pip install -r $req
    }
    if ($LASTEXITCODE -ne 0) { throw "Installing the Python packages failed" }
    Write-Host "Checking that Manim imports (the first import builds caches and takes a minute)…"
    & $PyExe -c "import manim, PIL, manim_slides; print('manim', manim.__version__)"
}

if ($WithLatex) {
    $haveTex = (Get-Command latex -ErrorAction SilentlyContinue) -or
               (Test-Path "$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64\latex.exe") -or
               (Test-Path "$env:ProgramFiles\MiKTeX\miktex\bin\x64\latex.exe")
    if ($haveTex) { Write-Host "LaTeX is already installed" }
    else {
        Write-Host "Installing MiKTeX (LaTeX for formulas)…"
        winget install --id MiKTeX.MiKTeX --scope user --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { winget install --id MiKTeX.MiKTeX --silent --accept-package-agreements --accept-source-agreements }
    }
    $initexmf = @("$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64\initexmf.exe", "$env:ProgramFiles\MiKTeX\miktex\bin\x64\initexmf.exe") |
                Where-Object { Test-Path $_ } | Select-Object -First 1
    # MiKTeX fetches a package the first time a formula needs it, without asking
    if ($initexmf) { & $initexmf --set-config-value '[MPM]AutoInstall=1' }
}

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
