#!/usr/bin/env pwsh
# =============================================================================
# bootstrap.ps1 - set up psmux-assistant-resurrect (and friends) on a machine
# =============================================================================
# Personal setup script for the andreipaun/psmux-plugins fork,
# `assistant-resurrect` branch. On a new machine:
#
#   git clone -b assistant-resurrect https://github.com/andreipaun/psmux-plugins.git
#   cd psmux-plugins
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#
# What it does:
#   1. Confirms psmux is on PATH (does not install it - see message if missing)
#   2. Copies the requested plugin folders from this clone into
#      ~/.psmux/plugins/ (overwriting any existing copy - this script is the
#      source of truth, not ppm, since ppm's `psmux-plugins/<name>` shorthand
#      resolves to the official upstream monorepo, not this fork)
#   3. Adds `source-file` lines to ~/.psmux.conf for each plugin that ships a
#      plugin.conf (idempotent - skips plugins already wired in)
#   4. Runs psmux-assistant-resurrect's entry point, if a psmux server is
#      already running, to register the resurrect hooks and install the
#      Claude Code / OpenCode session-tracking hooks
#   5. Adds a PowerShell profile prompt-hook that keeps the process working
#      directory in sync with $PWD, so idle PowerShell panes restore to the
#      right folder (Set-Location alone only changes PowerShell's internal
#      location, not the process cwd psmux reads for #{pane_current_path})
#
# Idempotent: safe to re-run any time (e.g. after `git pull` picks up updates
# from this fork). Windows PowerShell 5.1 compatible.
# =============================================================================
param(
    [switch]$SkipProfileHook,
    [string[]]$Plugins = @('ppm', 'psmux-sensible', 'psmux-pain-control', 'psmux-resurrect', 'psmux-assistant-resurrect')
)

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$PluginDir = Join-Path $env:USERPROFILE '.psmux\plugins'
$ConfPath = Join-Path $env:USERPROFILE '.psmux.conf'

Write-Host "`n=== psmux-assistant-resurrect bootstrap ===" -ForegroundColor Magenta

# --- Step 1: psmux present? -------------------------------------------------
$psmuxCmd = Get-Command psmux, pmux -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $psmuxCmd) {
    Write-Host "psmux not found on PATH." -ForegroundColor Red
    Write-Host "Install it first, e.g.:  winget install marlocarlo.psmux" -ForegroundColor Yellow
    Write-Host "Then re-run this script." -ForegroundColor Yellow
    exit 1
}
$PSMUX = $psmuxCmd.Source
Write-Host "Found psmux: $PSMUX ($(& $PSMUX --version 2>&1))" -ForegroundColor Cyan

# --- Step 2: install/update plugin folders ----------------------------------
Write-Host "`n--- Installing plugins into $PluginDir ---" -ForegroundColor Yellow
if (-not (Test-Path $PluginDir)) { New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null }

foreach ($p in $Plugins) {
    $src = Join-Path $RepoRoot $p
    if (-not (Test-Path $src)) {
        Write-Host "  SKIP $p (not found in this clone)" -ForegroundColor Yellow
        continue
    }
    $dst = Join-Path $PluginDir $p
    Copy-Item $src $dst -Recurse -Force
    Write-Host "  Installed: $p" -ForegroundColor Green
}

# --- Step 3: wire source-file lines into ~/.psmux.conf ----------------------
Write-Host "`n--- Wiring $ConfPath ---" -ForegroundColor Yellow
if (-not (Test-Path $ConfPath)) { New-Item -ItemType File -Path $ConfPath -Force | Out-Null }

$confLines = @(Get-Content $ConfPath -ErrorAction SilentlyContinue)
$confText = $confLines -join "`n"
$added = 0

foreach ($p in $Plugins) {
    $confFile = Join-Path $PluginDir "$p\plugin.conf"
    if (-not (Test-Path $confFile)) { continue }  # e.g. ppm has no plugin.conf, uses `run` instead
    if ($confText -match [regex]::Escape("plugins/$p/plugin.conf")) { continue }  # already wired
    $confLines += "source-file '~/.psmux/plugins/$p/plugin.conf'"
    $confText += "`nplugins/$p/plugin.conf"
    $added++
    Write-Host "  Added: $p" -ForegroundColor Green
}

# ppm itself is activated via `run`, not source-file (see ppm/README.md)
if (('ppm' -in $Plugins) -and (Test-Path (Join-Path $PluginDir 'ppm\ppm.ps1')) -and ($confText -notmatch [regex]::Escape('plugins/ppm/ppm.ps1'))) {
    $confLines += "run '~/.psmux/plugins/ppm/ppm.ps1'"
    $added++
    Write-Host "  Added: ppm (run)" -ForegroundColor Green
}

if ($added -gt 0) {
    $confLines | Set-Content -Path $ConfPath -Encoding UTF8
} else {
    Write-Host "  Already fully wired, nothing to add" -ForegroundColor DarkGray
}

# --- Step 4: register hooks (needs a live psmux server) ---------------------
Write-Host "`n--- Registering hooks ---" -ForegroundColor Yellow
$entry = Join-Path $PluginDir 'psmux-assistant-resurrect\psmux-assistant-resurrect.ps1'
if (Test-Path $entry) {
    $serverUp = $false
    try {
        & $PSMUX list-sessions 2>&1 | Out-Null
        $serverUp = ($LASTEXITCODE -eq 0)
    } catch { }

    if ($serverUp) {
        & $entry
    } else {
        Write-Host "  psmux server not running - start psmux, then re-run this script" -ForegroundColor Yellow
        Write-Host "  (registering @resurrect-hook-* options and installing the Claude/" -ForegroundColor Yellow
        Write-Host "   OpenCode session hooks both need a live server)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  psmux-assistant-resurrect not installed, skipping" -ForegroundColor DarkGray
}

# --- Step 5: PowerShell profile cwd-sync hook -------------------------------
Write-Host "`n--- PowerShell profile cwd-sync hook ---" -ForegroundColor Yellow
if ($SkipProfileHook) {
    Write-Host "  Skipped (-SkipProfileHook)" -ForegroundColor DarkGray
} else {
    # $PROFILE resolves correctly even when Documents is redirected (e.g. a
    # Parallels VM mapping it to C:\Mac\Home\Documents\...) - don't hardcode
    # the Documents\WindowsPowerShell path.
    #
    # Detect by the functional marker (__psmuxPrevPrompt), not the comment
    # text: two blocks with the same $global:__psmuxPrevPrompt name but
    # different wrapping comments would both pass a comment-only check, and
    # since that variable is looked up dynamically (not captured at
    # definition time), a second copy makes the prompt call itself forever
    # the moment it runs - this must never install twice.
    $profilePath = $PROFILE
    $marker = '__psmuxPrevPrompt'
    $hookExists = (Test-Path $profilePath) -and ((Get-Content $profilePath -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($marker))

    if ($hookExists) {
        Write-Host "  Already present ($profilePath)" -ForegroundColor DarkGray
    } else {
        $profileDir = Split-Path -Parent $profilePath
        if ($profileDir -and -not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        if (-not (Test-Path $profilePath)) {
            New-Item -ItemType File -Path $profilePath -Force | Out-Null
        }

        $snippet = @"

$marker - keeps the process cwd in sync with `$PWD, so idle
# PowerShell panes restore to the right folder (Set-Location alone only
# changes PowerShell's internal location, not the process cwd psmux reads
# for #{pane_current_path}).
`$global:__psmuxPrevPrompt = `$function:prompt
function prompt {
    if (`$PWD.Provider.Name -eq 'FileSystem') {
        [Environment]::CurrentDirectory = `$PWD.ProviderPath
    }
    if (`$global:__psmuxPrevPrompt) { & `$global:__psmuxPrevPrompt } else { "PS `$(`$PWD.Path)> " }
}
"@
        Add-Content -Path $profilePath -Value $snippet -Encoding UTF8
        Write-Host "  Added to $profilePath" -ForegroundColor Green
        Write-Host "  (takes effect in new shells - restart open panes to pick it up)" -ForegroundColor DarkGray
    }
}

# --- Summary -----------------------------------------------------------------
Write-Host "`n=== Done ===" -ForegroundColor Magenta
Write-Host "psmux version: $(& $PSMUX --version 2>&1)" -ForegroundColor Cyan
Write-Host "Note: join-pane/move-pane no-ops, swap-pane being focus-only, and" -ForegroundColor DarkGray
Write-Host "per-pane capture-pane targeting were fixed on psmux master after" -ForegroundColor DarkGray
Write-Host "v3.3.6 but may not be in a release yet - compare 'psmux -V' against" -ForegroundColor DarkGray
Write-Host "the latest GitHub release if any of those misbehave." -ForegroundColor DarkGray
