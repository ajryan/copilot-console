# Copilot Console - One-click installer for Windows
# Usage: irm https://raw.githubusercontent.com/sanchar10/copilot-console/main/scripts/install.ps1 | iex
#
# Supports PowerShell-native -WhatIf for dry-run mode (messages print, no actions execute).
# Combine with -AssumeDependenciesMissing to exercise the "missing dependency" message
# formatting without uninstalling anything from the machine. Example:
#   .\install.ps1 -WhatIf -AssumeDependenciesMissing

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [switch]$AssumeDependenciesMissing
)

$REPO = "sanchar10/copilot-console"

# Returns $null when -AssumeDependenciesMissing is set so the "dependency missing"
# branches can be exercised on a fully-provisioned machine.
function Get-CommandSafe {
    param([string]$Name)
    if ($AssumeDependenciesMissing) { return $null }
    return Get-Command $Name -ErrorAction SilentlyContinue
}

# Honors -WhatIf and -AssumeDependenciesMissing so the installer keeps running
# during a dry-run instead of bailing on the first simulated failure.
function Exit-IfReal {
    param([int]$Code = 1)
    if ($WhatIfPreference -or $AssumeDependenciesMissing) {
        Write-Host "  [DRYRUN] Would exit $Code (continuing to show remaining messages)" -ForegroundColor DarkCyan
        return
    }
    exit $Code
}

# Computes terminal display width, accounting for East Asian Wide and emoji
# characters that occupy 2 cells but report a .NET .Length of 1 (BMP) or 2
# (surrogate pair → still 2 cells, so .Length already matches display).
function Get-DisplayWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $width = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $cp = [char]::ConvertToUtf32($Text, $i)
        $step = if ($cp -gt 0xFFFF) { 2 } else { 1 }
        $isWide =
            ($cp -ge 0x1100  -and $cp -le 0x115F)  -or
            ($cp -ge 0x2329  -and $cp -le 0x232A)  -or
            ($cp -ge 0x23E9  -and $cp -le 0x23F3)  -or  # ⏳ ⏰ etc.
            ($cp -ge 0x2600  -and $cp -le 0x27BF)  -or  # misc symbols + dingbats
            ($cp -ge 0x2E80  -and $cp -le 0x303E)  -or
            ($cp -ge 0x3041  -and $cp -le 0x33FF)  -or
            ($cp -ge 0x3400  -and $cp -le 0x4DBF)  -or
            ($cp -ge 0x4E00  -and $cp -le 0x9FFF)  -or
            ($cp -ge 0xA000  -and $cp -le 0xA4CF)  -or
            ($cp -ge 0xAC00  -and $cp -le 0xD7A3)  -or
            ($cp -ge 0xF900  -and $cp -le 0xFAFF)  -or
            ($cp -ge 0xFE30  -and $cp -le 0xFE4F)  -or
            ($cp -ge 0xFF00  -and $cp -le 0xFF60)  -or
            ($cp -ge 0xFFE0  -and $cp -le 0xFFE6)  -or
            ($cp -ge 0x1F300 -and $cp -le 0x1FAFF)
        if ($isWide) {
            # Surrogate pair already contributes 2 to .Length, BMP only 1.
            $width += if ($step -eq 2) { 2 } else { 2 }
        } else {
            $width += $step
        }
        $i += $step
    }
    return $width
}

# Writes a box around one or more lines, auto-sizing width to the longest line.
# Use this instead of hand-drawn box characters so $variable expansion never breaks alignment.
function Write-Boxed {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [string]$Heading,
        [ConsoleColor]$Color = [ConsoleColor]::Yellow,
        [string]$Indent = '  '
    )
    $maxLine = 0
    foreach ($line in $Lines) {
        $w = Get-DisplayWidth $line
        if ($w -gt $maxLine) { $maxLine = $w }
    }
    $headingSeg = if ($Heading) { "─ $Heading " } else { '' }
    $headingWidth = Get-DisplayWidth $headingSeg
    # Inner width = chars between ┌ and ┐. Body lines are "│  <content><pad>  │"
    # so they need maxLine + 4 of inner space; heading needs its own segment + at
    # least 2 trailing dashes for visual balance.
    $inner = [Math]::Max($maxLine + 4, $headingWidth + 2)
    $top = '┌' + $headingSeg + ('─' * ($inner - $headingWidth)) + '┐'
    $bot = '└' + ('─' * $inner) + '┘'
    Write-Host ($Indent + $top) -ForegroundColor $Color
    foreach ($line in $Lines) {
        $pad = ' ' * ($inner - 4 - (Get-DisplayWidth $line))
        Write-Host ($Indent + '│  ' + $line + $pad + '  │') -ForegroundColor $Color
    }
    Write-Host ($Indent + $bot) -ForegroundColor $Color
}

# Auto-confirms under -WhatIf or -AssumeDependenciesMissing so dry-runs always
# exercise the "user said yes" branch. Reads from the host console otherwise,
# which works correctly even when the script is piped via `irm | iex`.
function Prompt-YesNo {
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$DefaultYes = $true
    )
    if ($WhatIfPreference -or $AssumeDependenciesMissing) {
        Write-Host "  [DRYRUN] Would prompt: $Question" -ForegroundColor DarkCyan
        return $true
    }
    $suffix = if ($DefaultYes) { '(Y/n)' } else { '(y/N)' }
    $ans = Read-Host "  $Question $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
    return ($ans -match '^[Yy]')
}

# Returns the auto-install command for a known dep, or '' if no auto-install path
# applies on this machine. Copilot CLI is always installable via npm (which we
# require anyway); the rest go through winget when available.
function Get-DepInstallCmd {
    param([string]$Dep, [bool]$HasWinget)
    switch ($Dep) {
        'python'  { if ($HasWinget) { 'winget install -e --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements --disable-interactivity' } else { '' } }
        'nodejs'  { if ($HasWinget) { 'winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --disable-interactivity' } else { '' } }
        'ripgrep' { if ($HasWinget) { 'winget install -e --id BurntSushi.ripgrep.MSVC --accept-source-agreements --accept-package-agreements --disable-interactivity' } else { '' } }
        'copilot' { 'npm install -g @github/copilot' }
        default   { '' }
    }
}

# Manual install instructions shown in a box when the user declines auto-install
# or when no auto-install path is available.
function Get-DepManualLines {
    param([string]$Dep)
    switch ($Dep) {
        'python'  { @(
            'Install Python 3.11+ from https://www.python.org/downloads/',
            'Or via winget:',
            '  winget install -e --id Python.Python.3.11'
        ) }
        'nodejs'  { @(
            'Install Node.js 18+ LTS from https://nodejs.org/',
            'Or via winget:',
            '  winget install -e --id OpenJS.NodeJS.LTS'
        ) }
        'ripgrep' { @(
            'Install ripgrep via winget:',
            '  winget install -e --id BurntSushi.ripgrep.MSVC',
            'Or download a release from:',
            '  https://github.com/BurntSushi/ripgrep/releases'
        ) }
        'copilot' { @(
            'Install GitHub Copilot CLI (requires Node.js / npm):',
            '  npm install -g @github/copilot'
        ) }
        default   { @("Install $Dep manually.") }
    }
}

# Allow .ps1 wrappers (npm.ps1, pip.ps1, etc.) to run in this process only
if ($PSCmdlet.ShouldProcess('current PowerShell process', 'Set ExecutionPolicy Bypass')) {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

Write-Host ""
Write-Host "  Copilot Console Installer" -ForegroundColor Cyan
Write-Host "  ====================================" -ForegroundColor DarkGray
Write-Host ""

# Refresh PATH from registry (picks up recent installs without terminal restart)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# --- Preflight: catalog ALL missing deps, then ask ONCE -------------------
# Detect every system-level dependency we need before doing any work, show
# the user a single summary, and let them opt in to a batched install. If
# they decline (or no auto-install path is available), print per-dep manual
# instructions and bail. After a successful batched install we exit 0 and
# ask the user to re-run so the freshly-installed tools are picked up
# cleanly (PATH refresh in-process is unreliable for npm / pip / Scripts dirs).
$missingDeps = @()
$pythonOk = $false
if (Get-CommandSafe python) {
    if ($AssumeDependenciesMissing) {
        $missingDeps += 'python'
    } else {
        $pyVerOutput = (python --version 2>&1) | Out-String
        if ($pyVerOutput -match 'Python \d+\.\d+') { $pythonOk = $true } else { $missingDeps += 'python' }
    }
} else {
    $missingDeps += 'python'
}
if (-not (Get-CommandSafe node))    { $missingDeps += 'nodejs' }
if (-not (Get-CommandSafe rg))      { $missingDeps += 'ripgrep' }
if (-not (Get-CommandSafe copilot)) { $missingDeps += 'copilot' }

if ($missingDeps.Count -gt 0) {
    $hasWinget = [bool](Get-CommandSafe winget)
    $boxLines = @('The following dependencies are missing:', '')
    foreach ($d in $missingDeps) {
        $cmd = Get-DepInstallCmd -Dep $d -HasWinget $hasWinget
        if ([string]::IsNullOrEmpty($cmd)) {
            $boxLines += "  - $d  (no auto-install available — winget not found)"
        } else {
            $boxLines += "  - $d"
            $boxLines += "      $cmd"
        }
    }
    $boxLines += ''
    $boxLines += 'After installation completes, the script will exit so you can'
    $boxLines += 're-run it and pick up the freshly-installed tools cleanly.'
    Write-Host ''
    Write-Boxed -Heading 'Missing dependencies' -Lines $boxLines -Color Yellow
    Write-Host ''

    if (Prompt-YesNo -Question 'Install missing dependencies now?') {
        $manualOnly  = @()
        $installFailed = @()
        foreach ($d in $missingDeps) {
            $cmd = Get-DepInstallCmd -Dep $d -HasWinget $hasWinget
            if ([string]::IsNullOrEmpty($cmd)) {
                $manualOnly += $d
                continue
            }
            Write-Host "  Installing $d..." -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess($d, $cmd)) {
                Invoke-Expression $cmd 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  [WARN] $d install exited with code $LASTEXITCODE" -ForegroundColor Yellow
                    $installFailed += $d
                }
                # Refresh PATH after each install so a later step (e.g. copilot
                # via npm) can find tools dropped by an earlier step (node).
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            }
        }
        if ($manualOnly.Count -gt 0 -or $installFailed.Count -gt 0) {
            foreach ($d in ($manualOnly + $installFailed)) {
                Write-Host ''
                Write-Boxed -Heading "Manual install: $d" -Lines (Get-DepManualLines $d) -Color Yellow
            }
        }
        Write-Host ''
        Write-Boxed -Heading 'Next steps' -Lines @(
            'Dependency installation finished.',
            'Re-run the installer to continue setup:',
            "  irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"
        ) -Color Cyan
        if ($WhatIfPreference -or $AssumeDependenciesMissing) {
            Write-Host "  [DRYRUN] Would exit 0" -ForegroundColor DarkCyan
        } else {
            exit 0
        }
    } else {
        foreach ($d in $missingDeps) {
            Write-Host ''
            Write-Boxed -Heading "Manual install: $d" -Lines (Get-DepManualLines $d) -Color Yellow
        }
        Write-Host ''
        Write-Host '  Re-run the installer after installing the dependencies above.' -ForegroundColor Yellow
        Exit-IfReal 1
    }
}

# --- Check Python ---
$python = Get-CommandSafe python
if ($python) {
    $pyVerOutput = (python --version 2>&1) | Out-String
    if ($pyVerOutput -notmatch 'Python \d+\.\d+') {
        # Windows Store stub or broken install — treat as not found
        $python = $null
    }
}
if (-not $python -and -not $AssumeDependenciesMissing) {
    # Auto-detect Python from known install locations
    $pyExe = $null
    $searchPaths = @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "C:\Python3*\python.exe"
    )
    foreach ($pattern in $searchPaths) {
        $found = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $pyExe = $found.FullName; break }
    }
    if ($pyExe) {
        $pyDir = Split-Path $pyExe
        $env:Path = "$pyDir;$env:Path"
        $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($currentUserPath -notlike "*$pyDir*") {
            if ($PSCmdlet.ShouldProcess("User PATH", "Add $pyDir")) {
                [Environment]::SetEnvironmentVariable("Path", "$currentUserPath;$pyDir", "User")
                Write-Host "  [OK] Added Python to PATH: $pyDir" -ForegroundColor Green
            }
        }
        $python = Get-CommandSafe python
    }
}
if (-not $python) {
    Write-Host "  [ERROR] Python not found." -ForegroundColor Red
    Write-Host ""
    Write-Boxed -Heading 'What to do' -Lines @(
        '1. Install Python 3.11+ from https://www.python.org/downloads/'
        '2. Re-run:'
        "   irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"
    )
    Exit-IfReal 1
}
if ($python) {
    $pyVer = (python --version 2>&1) -replace 'Python\s*', ''
    $pyMajor, $pyMinor = $pyVer.Split('.')[0..1] | ForEach-Object { [int]$_ }
    if ($pyMajor -lt 3 -or ($pyMajor -eq 3 -and $pyMinor -lt 11)) {
        Write-Host "  [ERROR] Python 3.11+ required (found $pyVer)" -ForegroundColor Red
        Write-Host ""
        Write-Boxed -Heading 'What to do' -Lines @(
            '1. Install Python 3.11+ from https://www.python.org/downloads/'
            '2. Re-run:'
            "   irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"
        )
        Exit-IfReal 1
    }
    Write-Host "  [OK] Python $pyVer" -ForegroundColor Green
}

# --- Check Node.js ---
$node = Get-CommandSafe node
if (-not $node -and -not $AssumeDependenciesMissing) {
    # Auto-detect Node.js from known install location
    $nodeExe = "$env:ProgramFiles\nodejs\node.exe"
    if (Test-Path $nodeExe) {
        $nodeDir = Split-Path $nodeExe
        $env:Path = "$nodeDir;$env:Path"
        $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($currentUserPath -notlike "*$nodeDir*") {
            if ($PSCmdlet.ShouldProcess("User PATH", "Add $nodeDir")) {
                [Environment]::SetEnvironmentVariable("Path", "$currentUserPath;$nodeDir", "User")
                Write-Host "  [OK] Added Node.js to PATH: $nodeDir" -ForegroundColor Green
            }
        }
        $node = Get-CommandSafe node
    }
}
if (-not $node) {
    Write-Host "  [ERROR] Node.js not found." -ForegroundColor Red
    Write-Host ""
    Write-Boxed -Heading 'What to do' -Lines @(
        '1. Install Node.js 18+ from https://nodejs.org/ (LTS recommended)'
        '2. Re-run:'
        "   irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"
    )
    Exit-IfReal 1
}
if ($node) {
    $nodeVer = (node --version 2>&1) -replace 'v', ''
    $nodeMajor = [int]($nodeVer.Split('.')[0])
    if ($nodeMajor -lt 18) {
        Write-Host "  [ERROR] Node.js 18+ required (found $nodeVer)" -ForegroundColor Red
        Write-Host ""
        Write-Boxed -Heading 'What to do' -Lines @(
            '1. Install Node.js 18+ from https://nodejs.org/ (LTS recommended)'
            '2. Re-run:'
            "   irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"
        )
        Exit-IfReal 1
    }
    Write-Host "  [OK] Node.js $nodeVer" -ForegroundColor Green
}

# --- Verify Copilot CLI ---
# Auto-install was moved to the consolidated preflight at the top of this
# script. If we reach here without copilot on PATH, preflight either failed
# silently or was bypassed — surface a clear manual instruction and bail.
$copilot = Get-CommandSafe copilot
if (-not $copilot) {
    Write-Host "  [ERROR] GitHub Copilot CLI not found." -ForegroundColor Red
    Write-Host ""
    Write-Boxed -Heading 'What to do' -Lines (Get-DepManualLines 'copilot')
    Exit-IfReal 1
}
if ($copilot) {
    $copilotVer = ((copilot --version 2>&1) | Select-Object -First 1) -replace '.*?(\d+\.\d+\.\d+[-\d]*).*', '$1'
    Write-Host "  [OK] Copilot CLI $copilotVer" -ForegroundColor Green
}

# --- Install Copilot Console ---
Write-Host ""
Write-Host "  Installing Copilot Console..." -ForegroundColor Yellow
Write-Host ""

# Resolve latest wheel URL from GitHub releases
Write-Host "  Fetching latest release..." -ForegroundColor DarkGray
try {
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases/latest" -Headers @{ "User-Agent" = "copilot-console-installer" }
    $WHL_URL = ($releaseInfo.assets | Where-Object { $_.name -like "*.whl" } | Select-Object -First 1).browser_download_url
    if (-not $WHL_URL) {
        Write-Host "  [ERROR] No .whl found in latest release." -ForegroundColor Red
        Write-Host "     Check https://github.com/$REPO/releases" -ForegroundColor Yellow
        Exit-IfReal 1
    }
    Write-Host "  [OK] Found $($releaseInfo.tag_name)" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] Failed to fetch latest release from GitHub." -ForegroundColor Red
    Write-Host "     Check https://github.com/$REPO/releases for manual download." -ForegroundColor Yellow
    Exit-IfReal 1
}

Write-Host ""
Write-Boxed -Lines @('⏳ This may take 5-8 minutes — please wait...')
Write-Host ""

$installed = $false
$usedPipx = $false
$pipxAvailable = $false
if ($python -and -not $AssumeDependenciesMissing) {
    try { $pipxCheck = python -m pipx --version 2>&1 | Out-String; if ($LASTEXITCODE -eq 0) { $pipxAvailable = $true } } catch { }
}
if ($pipxAvailable) {
    if ($PSCmdlet.ShouldProcess($WHL_URL, "python -m pipx install --force")) {
        python -m pipx install --force $WHL_URL 2>&1 | ForEach-Object {
            $line = $_.ToString().Trim()
            if ($line -ne '' -and $line -notmatch 'symlink|These apps') {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
        }
        if ($LASTEXITCODE -eq 0) {
            $installed = $true
            $usedPipx = $true
        } else {
            Write-Host "  [WARN] pipx install failed, using python -m pip instead..." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [WARN] pipx not found, using python -m pip instead." -ForegroundColor Yellow
}
if (-not $installed -and -not $WhatIfPreference) {
    if ($PSCmdlet.ShouldProcess($WHL_URL, "python -m pip install --user")) {
        python -m pip install --user --no-cache-dir --force-reinstall $WHL_URL 2>&1 | ForEach-Object {
            $line = $_.ToString()
            if ($line -match 'Downloading.*copilot.agent.console|Installing collected') {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
        }
        if ($LASTEXITCODE -eq 0) {
            $installed = $true
        } else {
            Write-Host "  [ERROR] pip install failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            Write-Host "     Try running as Administrator:" -ForegroundColor Yellow
            Write-Host "     python -m pip install $WHL_URL" -ForegroundColor Yellow
        }
    }
}
if (-not $installed) {
    Exit-IfReal 1
}

# Clean up stale dist-info directories that confuse importlib.metadata
if ($python -and -not $AssumeDependenciesMissing) {
    $installedVersion = $releaseInfo.tag_name -replace '^v', ''
    $siteDir = python -c "import site; print(site.getusersitepackages())" 2>$null
    if ($installedVersion -and $siteDir -and (Test-Path $siteDir)) {
        Get-ChildItem -Path $siteDir -Directory -Filter "copilot_console-*.dist-info" | Where-Object {
            $_.Name -ne "copilot_console-$installedVersion.dist-info"
        } | ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.FullName, "Remove stale dist-info directory")) {
                Remove-Item -Recurse -Force $_.FullName 2>$null
            }
        }
    }
}

# --- Verify ---
# Refresh PATH to pick up newly installed commands (pipx or pip)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

$ac = Get-CommandSafe copilot-console
if (-not $ac -and $python -and -not $AssumeDependenciesMissing) {
    # pip --user installs to user Scripts dir - find and add to PATH
    $userScripts = $null
    try {
        $userScripts = (python -c "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))" 2>&1).Trim()
    } catch { }
    # Fallback: check common location
    if (-not $userScripts -or -not (Test-Path $userScripts)) {
        $pyVer = (python -c "import sys; print(f'Python{sys.version_info.major}{sys.version_info.minor}')" 2>&1).Trim()
        $userScripts = "$env:APPDATA\Python\$pyVer\Scripts"
    }
    if (Test-Path "$userScripts\copilot-console.exe") {
        $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($currentPath -notlike "*$userScripts*") {
            if ($PSCmdlet.ShouldProcess("User PATH", "Add $userScripts")) {
                [Environment]::SetEnvironmentVariable('Path', "$currentPath;$userScripts", 'User')
                Write-Host "  [OK] Added to PATH: $userScripts" -ForegroundColor Green
                Write-Host "  [NOTE] Restart your terminal for PATH to take effect." -ForegroundColor Yellow
            }
        }
        $env:Path = "$env:Path;$userScripts"
        $ac = Get-CommandSafe copilot-console
    }
}
if ($ac) {
    $acVer = (copilot-console --version 2>&1)
    Write-Host "  [OK] $acVer" -ForegroundColor Green
} else {
    Write-Host "  [OK] Installed" -ForegroundColor Green
    Write-Host "  [NOTE] Restart your terminal, then run 'copilot-console'." -ForegroundColor Yellow
}

# --- Verify ripgrep (for cross-session search; non-fatal) ---
# Auto-install was moved to the consolidated preflight at the top of this
# script. ripgrep is non-fatal — if missing here, just warn and show manual
# instructions; cross-session content search will be degraded but the rest
# of the installer works.
$rg = Get-CommandSafe rg
if (-not $rg) {
    Write-Host ""
    Write-Host "  [WARN] ripgrep not found. Cross-session content search will not work." -ForegroundColor Yellow
    Write-Boxed -Heading 'Manual install: ripgrep' -Lines (Get-DepManualLines 'ripgrep')
} else {
    Write-Host "  [OK] ripgrep $(rg --version | Select-Object -First 1)" -ForegroundColor Green
}

# --- Optional: Agentic Web Browsing (Playwright MCP) ---
Write-Host ""
Write-Host "  Optional: Agentic Web Browsing" -ForegroundColor Cyan
Write-Host "  Adds autonomous web navigation via Playwright MCP server." -ForegroundColor DarkGray
Write-Host "  Uses your system browser (Edge or Chrome)." -ForegroundColor DarkGray
Write-Host ""
if ($WhatIfPreference -or $AssumeDependenciesMissing) {
    Write-Host "  [DRYRUN] Would prompt: Enable agentic web browsing? (Y/n)" -ForegroundColor DarkCyan
    $setupPlaywright = 'Y'
} else {
    $setupPlaywright = Read-Host "  Enable agentic web browsing? (Y/n)"
}
if ($setupPlaywright -ne 'n' -and $setupPlaywright -ne 'N') {
    # Add Playwright MCP server to mcp-config.json (uses system browser, no extra install needed)
    $mcpConfigPath = "$env:USERPROFILE\.copilot-console\mcp-config.json"
    $addPlaywright = $true
    if (Test-Path $mcpConfigPath) {
        try {
            $existingConfig = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
            if ($existingConfig.mcpServers.PSObject.Properties.Name -contains 'playwright') {
                Write-Host "  [OK] Playwright MCP server already configured" -ForegroundColor Green
                $addPlaywright = $false
            }
        } catch { }
    }
    if ($addPlaywright) {
        # Ensure directory exists
        $mcpDir = Split-Path $mcpConfigPath
        if (-not (Test-Path $mcpDir)) {
            if ($PSCmdlet.ShouldProcess($mcpDir, "Create directory")) {
                New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
            }
        }

        if ($PSCmdlet.ShouldProcess($mcpConfigPath, "Add playwright MCP server")) {
            if (Test-Path $mcpConfigPath) {
                try {
                    $config = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
                    $playwrightServer = @{
                        type = "local"
                        command = "npx"
                        tools = @("*")
                        args = @("@playwright/mcp@latest")
                    }
                    $config.mcpServers | Add-Member -MemberType NoteProperty -Name "playwright" -Value $playwrightServer
                    $config | ConvertTo-Json -Depth 5 | Set-Content $mcpConfigPath -Encoding UTF8
                } catch {
                    Write-Host "  [WARN] Failed to update mcp-config.json. Add playwright server manually." -ForegroundColor Yellow
                }
            } else {
                $newConfig = @{
                    mcpServers = @{
                        playwright = @{
                            type = "local"
                            command = "npx"
                            tools = @("*")
                            args = @("@playwright/mcp@latest")
                        }
                    }
                }
                $newConfig | ConvertTo-Json -Depth 5 | Set-Content $mcpConfigPath -Encoding UTF8
            }
            Write-Host "  [OK] Playwright MCP server added to config" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  Skipped. Enable later — see docs/guides/INSTALL.md" -ForegroundColor DarkGray
}

# --- Optional: Mobile Access & CLI Notifications ---
$mobileEnabled = $false
Write-Host ""
Write-Host "  Optional: Mobile Access & CLI Notifications" -ForegroundColor Cyan
Write-Host "  Access sessions from your phone, get push notifications when" -ForegroundColor DarkGray
Write-Host "  any Copilot CLI session finishes. Requires devtunnel." -ForegroundColor DarkGray
Write-Host ""
if ($WhatIfPreference -or $AssumeDependenciesMissing) {
    Write-Host "  [DRYRUN] Would prompt: Enable mobile access & notifications? (Y/n)" -ForegroundColor DarkCyan
    $setupMobile = 'Y'
} else {
    $setupMobile = Read-Host "  Enable mobile access & notifications? (Y/n)"
}
if ($setupMobile -ne 'n' -and $setupMobile -ne 'N') {
    # Enable CLI notifications
    $cliNotify = Get-CommandSafe cli-notify
    if ($cliNotify) {
        if ($PSCmdlet.ShouldProcess("cli-notify", "Enable CLI notifications")) {
            cli-notify on 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] CLI notifications enabled" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Failed to enable. Run 'cli-notify on' manually." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  [WARN] cli-notify not found. Restart terminal and run 'cli-notify on'." -ForegroundColor Yellow
    }

    # Install devtunnel
    $devtunnel = Get-CommandSafe devtunnel
    if (-not $devtunnel) {
        Write-Host "  Installing devtunnel..." -ForegroundColor Yellow
        $winget = Get-CommandSafe winget
        if ($winget) {
            if ($PSCmdlet.ShouldProcess("Microsoft.devtunnel", "winget install")) {
                winget install Microsoft.devtunnel --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-Null
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                $devtunnel = Get-CommandSafe devtunnel
            }
        }
        if (-not $devtunnel) {
            # Download standalone binary (no npm/admin needed)
            $dtDir = "$env:LOCALAPPDATA\Programs\devtunnel"
            $dtExe = "$dtDir\devtunnel.exe"
            if ($PSCmdlet.ShouldProcess($dtExe, "Download devtunnel binary")) {
                try {
                    if (-not (Test-Path $dtDir)) { New-Item -ItemType Directory -Path $dtDir -Force | Out-Null }
                    Write-Host "  Downloading devtunnel binary..." -ForegroundColor Yellow
                    Invoke-WebRequest -Uri "https://aka.ms/TunnelsCliDownload/win-x64" -OutFile $dtExe -UseBasicParsing
                    if (Test-Path $dtExe) {
                        # Add to user PATH if not already there
                        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
                        if ($userPath -notlike "*$dtDir*") {
                            [System.Environment]::SetEnvironmentVariable("Path", "$userPath;$dtDir", "User")
                        }
                        $env:Path = "$env:Path;$dtDir"
                        $devtunnel = Get-CommandSafe devtunnel
                    }
                } catch {
                    # download failed — fall through to error message
                }
            }
        }
        if (-not $devtunnel) {
            Write-Host "  [ERROR] Failed to install devtunnel." -ForegroundColor Red
            Write-Host "     Install manually: https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/get-started" -ForegroundColor Yellow
        }
    }
    if ($devtunnel) {
        Write-Host "  [OK] devtunnel installed" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Signing in to devtunnel..." -ForegroundColor Yellow
        Write-Host "  TIP: Use a work or school (Entra ID) account for best iOS/Safari support." -ForegroundColor Yellow
        Write-Host "  If you only have a personal account, use --allow-anonymous mode instead." -ForegroundColor DarkGray
        if ($PSCmdlet.ShouldProcess("devtunnel", "User login")) {
            devtunnel user login
            $loginStatus = devtunnel user show 2>&1
            if ($loginStatus -notmatch "Not logged in") {
                Write-Host "  [OK] devtunnel authenticated" -ForegroundColor Green
                $mobileEnabled = $true
            } else {
                Write-Host "  [WARN] devtunnel login was not completed. Run 'devtunnel user login' later." -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host "  Skipped. Enable later with 'cli-notify on' or see docs/guides/MOBILE-COMPANION.md" -ForegroundColor DarkGray
}

# --- Done ---
Write-Host ""
if ($mobileEnabled) {
    Write-Host "  Ready! Complete mobile setup:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    1. Run:  copilot-console --expose --no-sleep" -ForegroundColor White
    Write-Host "    2. Open Settings -> scan QR code on your phone" -ForegroundColor White
    Write-Host "    3. Install as PWA when prompted" -ForegroundColor White
    Write-Host "    4. Allow notifications when the browser asks" -ForegroundColor White
    Write-Host ""
    Write-Host "  After this, CLI notifications work automatically." -ForegroundColor DarkGray
} else {
    Write-Host "  Ready! Run 'copilot-console' to start." -ForegroundColor Cyan
}
Write-Host ""
