<#
.SYNOPSIS
  Installs what Manimble for Windows needs, for the current user only (no administrator rights):
  a Python environment with Manim in %LOCALAPPDATA%\Manimble\python, and with -WithLatex, LaTeX for formulas.
  The app's first-launch setup runs this (it ships next to Manimble.exe); install_manimble.ps1 runs it from a checkout.
  LaTeX follows install_dependencies.sh on the Mac: with no TeX on the PC, TinyTeX in %APPDATA%\TinyTeX plus the
  packages Manim uses; with a TeX that lacks them, just the packages (MiKTeX: it may fetch them by itself).

.PARAMETER Requirements   the engine's requirements.txt (needed unless -SkipPython or -CheckTex)
.PARAMETER WithLatex      also install LaTeX (formulas: MathTex, Tex), or the packages Manim uses into the TeX found
.PARAMETER SkipPython     only LaTeX
.PARAMETER CheckTex       only print ok, missing, or packages (TeX present, Manim's packages not), and exit
#>
param(
    [string]$Requirements,
    [switch]$WithLatex,
    [switch]$SkipPython,
    [switch]$CheckTex
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

# TinyTeX's own rule: %APPDATA%, unless its path has spaces or non-ASCII characters (TeX Live dislikes them)
$TinyTeXParent = if ($env:APPDATA -match '^[!-~]+$') { $env:APPDATA } else { $env:ProgramData }
$TinyTeX = Join-Path $TinyTeXParent 'TinyTeX'
$TinyTeXBin = Join-Path $TinyTeX 'bin\windows'

# Where TeX installations put their programs, TinyTeX first, as install_dependencies.sh does on the Mac
# (the app's own PATH, in Tools.cs, puts the TeX installed for the whole PC first).
$texDirs = @($TinyTeXBin, "$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64", "$env:ProgramFiles\MiKTeX\miktex\bin\x64") +
    (2031..2020 | ForEach-Object { "C:\texlive\$_\bin\windows" })
$env:PATH = (@($texDirs | Where-Object { Test-Path $_ }) + @($env:PATH)) -join ';'

# What manim's TeX templates use (its Chinese `ctex` template excepted): the same list as install_dependencies.sh.
$TexPackages = @('latex-bin', 'dvisvgm', 'standalone', 'preview', 'babel-english', 'doublestroke', 'everysel',
    'fundus-calligra', 'mathastext', 'physics', 'ragged2e', 'relsize', 'rsfs', 'setspace', 'tipa', 'wasy', 'wasysym',
    'xcolor', 'xkeyval', 'cbfonts-fd', 'jknapltx', 'microtype', 'multitoc', 'prelim2e', 'count1to', 'frcursive',
    'amsfonts', 'amsmath')

function Find-Tool($name) { (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }

# MiKTeX's configuration tool, when the LaTeX found is MiKTeX's
function Find-Initexmf {
    $latex = Find-Tool 'latex'
    if (-not $latex) { return $null }
    $p = Join-Path (Split-Path $latex) 'initexmf.exe'
    if (Test-Path $p) { return $p } else { return $null }
}

# ok, missing, or packages (TeX present, manim's packages not)
function Test-Tex {
    if (-not (Find-Tool 'latex')) { return 'missing' }
    if (-not (Find-Tool 'dvisvgm')) { return 'packages' }
    # MiKTeX fetches what a formula uses the first time it is needed, once it may do so without asking
    $initexmf = Find-Initexmf
    if ($initexmf -and ((& $initexmf --show-config-value '[MPM]AutoInstall' 2>$null) -join '').Trim() -eq '1') { return 'ok' }
    $kpsewhich = Find-Tool 'kpsewhich'
    if (-not $kpsewhich) { return 'packages' }
    $files = @('standalone.cls', 'preview.sty', 'english.ldf', 'dsfont.sty', 'relsize.sty')
    $found = @(& $kpsewhich @files 2>$null | Where-Object { $_ })
    if ($found.Count -eq $files.Count) { return 'ok' } else { return 'packages' }
}

function Install-Tex {
    if (-not (Test-Path (Join-Path $TinyTeXBin 'tlmgr.bat'))) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("manimble-tinytex-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $tmp | Out-Null
        try {
            # the newest TinyTeX: tlmgr only installs packages while its TeX Live year matches CTAN's
            $rel = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json' } 'https://api.github.com/repos/rstudio/tinytex-releases/releases/latest'
            $tag = $rel.tag_name
            $name = "TinyTeX-1-windows-$tag.exe"
            $asset = $rel.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if (-not $asset) { throw "The latest TinyTeX release ($tag) has no $name" }
            $expected = "$($asset.digest)" -replace '^sha256:', ''
            if (-not $expected) { throw "Could not get the checksum to verify TinyTeX $tag with" }
            Step "Downloading LaTeX (TinyTeX $tag, about 75 MB)"
            $exe = Join-Path $tmp $name
            Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $exe
            # checked against the SHA-256 GitHub recorded for the release file before it is run
            $got = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLowerInvariant()
            if ($got -ne $expected.ToLowerInvariant()) { throw "TinyTeX $tag failed its checksum (expected $expected, got $got)" }
            Step "Unpacking LaTeX"
            # a self-extracting archive: -y unpacks TinyTeX\ into the current folder without asking
            Push-Location $tmp
            try { & $exe -y | Out-Null; if ($LASTEXITCODE -ne 0) { throw "Unpacking TinyTeX failed (exit code $LASTEXITCODE)" } }
            finally { Pop-Location }
            if (Test-Path $TinyTeX) { Remove-Item -Recurse -Force $TinyTeX }
            New-Item -ItemType Directory -Force $TinyTeXParent | Out-Null
            Move-Item (Join-Path $tmp 'TinyTeX') $TinyTeX
        }
        finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        $env:PATH = "$TinyTeXBin;$env:PATH"
        & (Join-Path $TinyTeXBin 'tlmgr.bat') option repository ctan | Out-Null
    }
    Install-TexPackages
}

function Install-TexPackages {
    $initexmf = Find-Initexmf
    if ($initexmf) {
        Step "Letting MiKTeX fetch the packages a formula needs without asking"
        & $initexmf --set-config-value '[MPM]AutoInstall=1'
    } else {
        $tlmgr = Find-Tool 'tlmgr'
        if (-not $tlmgr) { throw "No tlmgr found to add LaTeX packages with" }
        $root = ((& (Find-Tool 'kpsewhich') -var-value TEXMFROOT) -join '').Trim()
        Step "Adding the LaTeX packages manim uses"
        $writable = $false
        try { $probe = Join-Path $root "tlpkg\.manimble-write-test"; [IO.File]::WriteAllText($probe, ''); Remove-Item $probe; $writable = $true } catch {}
        # tlmgr refuses to install packages once CTAN has a newer tlmgr than itself, so it updates itself first
        if ($writable) {
            & $tlmgr update --self
            & $tlmgr install @TexPackages
            if ($LASTEXITCODE -ne 0) { throw "tlmgr could not install the LaTeX packages (exit code $LASTEXITCODE)" }
        } else {
            # a TeX installed for all users lives in a folder only an administrator can change: Windows asks (UAC)
            $cmd = "& '$tlmgr' update --self; & '$tlmgr' install $($TexPackages -join ' '); exit `$LASTEXITCODE"
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
            if ($p.ExitCode -ne 0) { throw "Adding LaTeX packages was cancelled or failed" }
        }
    }
    if ((Test-Tex) -ne 'ok') { throw "LaTeX is still missing packages manim needs" }
    Step "LaTeX ready: $(Find-Tool 'latex')"
}

if ($CheckTex) { Write-Output (Test-Tex); exit 0 }

if (-not $SkipPython) {
    if (-not $Requirements) { throw "-Requirements (the engine's requirements.txt) is needed to install Python" }
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
    switch (Test-Tex) {
        'ok' { Step "LaTeX is already installed, with the packages Manim uses" }
        'missing' { Install-Tex }
        'packages' { Install-TexPackages }
    }
}
Step "Done"
exit 0
