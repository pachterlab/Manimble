<#
.SYNOPSIS
  Installs what Manimble for Windows needs, for the current user only (no administrator rights):
  a Python environment with Manim in %LOCALAPPDATA%\Manimble\python, and with -WithLatex, MiKTeX for formulas.
  The app's first-launch setup runs this (it ships next to Manimble.exe); install_manimble.ps1 runs it from a checkout.

.PARAMETER Requirements   the engine's requirements.txt
.PARAMETER WithLatex      also install MiKTeX (formulas: MathTex, Tex) and let it fetch missing packages by itself
.PARAMETER SkipPython     only LaTeX
#>
param(
    [Parameter(Mandatory = $true)][string]$Requirements,
    [switch]$WithLatex,
    [switch]$SkipPython
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Base = Join-Path $env:LOCALAPPDATA 'Manimble'
$PyEnv = Join-Path $Base 'python'
$PyExe = Join-Path $PyEnv 'Scripts\python.exe'
New-Item -ItemType Directory -Force $Base | Out-Null

function Step($text) { Write-Output "== $text" }
# a failure prints one plain line (the app's setup window shows it) and exits 1, without PowerShell's error record
trap { Write-Output "Error: $($_.Exception.Message)"; exit 1 }

function Find-BasePython {
    # a python.org or uv-managed CPython 3.11+; never the Microsoft Store's (it redirects writes under AppData)
    $cands = @()
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in '3.12', '3.13', '3.11') {
            try { $p = (& py "-$v" -c "import sys; print(sys.executable)" 2>$null); if ($p) { $cands += $p.Trim() } } catch {}
        }
    }
    $cands += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python31[123]\python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName
    foreach ($c in $cands) { if ($c -and (Test-Path $c) -and ($c -notmatch 'WindowsApps')) { return $c } }
    return $null
}

function Refresh-Path {
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'Machine')
}

if (-not $SkipPython) {
    if (-not (Test-Path $PyExe)) {
        Step "Creating the Python environment in $PyEnv"
        $base = Find-BasePython
        $uv = Get-Command uv -ErrorAction SilentlyContinue
        if (-not $base -and -not $uv) {
            Step "Installing Python 3.12 for this user (winget)"
            winget install --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            Refresh-Path
            $base = Find-BasePython
            if (-not $base) { throw "Python 3.12 was installed but could not be found. Install it from python.org and run the setup again." }
        }
        if ($base) {
            if ($uv) { & uv venv --python $base $PyEnv } else { & $base -m venv $PyEnv }
        } else {
            & uv venv --python 3.12 --python-preference only-managed $PyEnv
        }
        if (-not (Test-Path $PyExe)) { throw "Could not create the Python environment" }
    } else {
        Step "Updating the Python environment in $PyEnv"
    }
    Step "Installing Manim, Manim Slides and the rest (a few minutes the first time)"
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        & uv pip install --python $PyExe -r $Requirements
    } else {
        & $PyExe -m pip install --disable-pip-version-check --upgrade pip
        & $PyExe -m pip install --disable-pip-version-check -r $Requirements
    }
    if ($LASTEXITCODE -ne 0) { throw "Installing the Python packages failed" }
    Step "Checking that Manim imports (the first import builds caches and takes a minute)"
    $env:PYTHONWARNINGS = 'ignore::SyntaxWarning'
    & $PyExe -c "import manim, PIL, manim_slides; print('manim', manim.__version__)"
    if ($LASTEXITCODE -ne 0) { throw "Manim does not import" }
}

if ($WithLatex) {
    $texDirs = @("$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64", "$env:ProgramFiles\MiKTeX\miktex\bin\x64", "$env:APPDATA\TinyTeX\bin\windows")
    $have = (Get-Command latex -ErrorAction SilentlyContinue) -or ($texDirs | Where-Object { Test-Path (Join-Path $_ 'latex.exe') })
    if ($have) { Step "LaTeX is already installed" }
    else {
        Step "Installing MiKTeX for formulas (winget, about 150 MB)"
        winget install --id MiKTeX.MiKTeX --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) { throw "Installing MiKTeX failed (winget exit code $LASTEXITCODE)" }
    }
    $initexmf = $texDirs | ForEach-Object { Join-Path $_ 'initexmf.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($initexmf) {
        Step "Letting MiKTeX fetch the packages a formula needs without asking"
        & $initexmf --set-config-value '[MPM]AutoInstall=1'
    }
}
Step "Done"
exit 0
