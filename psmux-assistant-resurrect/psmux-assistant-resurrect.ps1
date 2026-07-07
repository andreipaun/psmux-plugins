# =============================================================================
# psmux-assistant-resurrect - resume AI assistant sessions across restarts
# Port of timvw/tmux-assistant-resurrect for psmux
# =============================================================================
#
# Preserves AI coding assistant sessions (Claude Code, Codex CLI) when psmux
# restarts: on every psmux-resurrect save, running assistants and their
# session IDs are recorded; after a restore, each pane gets its assistant
# relaunched with the session resumed (claude --resume <id> / codex resume <id>).
#
# Requires psmux-resurrect with hook support (@resurrect-hook-post-save-all /
# @resurrect-hook-post-restore-all).
#
# Options (set in ~/.psmux.conf):
#   set -g @assistant-resurrect-capture-env 'VAR1 VAR2'  # env vars to persist
#
# Windows PowerShell 5.1 compatible.
# =============================================================================

param(
    [string]$SettingsPath = '',
    [switch]$SkipPsmux
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'scripts\lib-detect.ps1')

$PSMUX = Get-PsmuxBin
$PSHOST_BIN = Get-PsHostBin

$scriptsDir = Join-Path $PSScriptRoot 'scripts'
$hooksDir = Join-Path $PSScriptRoot 'hooks'

# --- Ensure state directory --------------------------------------------------
$stateDir = Get-AssistantStateDir
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

# --- Wire into psmux-resurrect hooks ----------------------------------------
# Register our save/restore scripts unless the user configured their own hook.
function Register-ResurrectHook {
    param([string]$OptionName, [string]$ScriptPath)

    $wanted = "& '$PSHOST_BIN' -NoProfile -ExecutionPolicy Bypass -File '$ScriptPath'"
    $existing = ''
    try {
        $existing = (& $PSMUX show-options -gv $OptionName 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $existing = '' }
    } catch { $existing = '' }
    if ($existing -match 'unknown option|invalid option|error|no server|not found|refused') { $existing = '' }

    if (-not $existing) {
        & $PSMUX set-option -g $OptionName $wanted 2>&1 | Out-Null
    } elseif ($existing -notmatch 'assistant-sessions') {
        Write-Host "assistant-resurrect: $OptionName already set to a different hook, leaving it alone" -ForegroundColor Yellow
    } elseif ($existing -ne $wanted) {
        # Ours, but stale (e.g. plugin moved) - refresh.
        & $PSMUX set-option -g $OptionName $wanted 2>&1 | Out-Null
    }
}

if (-not $SkipPsmux) {
    Register-ResurrectHook '@resurrect-hook-post-save-all' (Join-Path $scriptsDir 'save-assistant-sessions.ps1')
    Register-ResurrectHook '@resurrect-hook-post-restore-all' (Join-Path $scriptsDir 'restore-assistant-sessions.ps1')
}

# --- Install Claude Code hooks into ~/.claude/settings.json ------------------
# Idempotent: if our hooks are already present the file is not touched at all.
# A one-time backup is written before the first modification.
function Install-ClaudeHooks {
    param([string]$Path)

    $trackCmd = "`"$PSHOST_BIN`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $hooksDir 'claude-session-track.ps1')`""
    $cleanupCmd = "`"$PSHOST_BIN`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $hooksDir 'claude-session-cleanup.ps1')`""

    $settings = $null
    if (Test-Path $Path) {
        try {
            $raw = Get-Content $Path -Raw -ErrorAction Stop
            if ($raw.Trim()) { $settings = $raw | ConvertFrom-Json -ErrorAction Stop }
        } catch {
            Write-Host "assistant-resurrect: cannot parse $Path, not touching it: $_" -ForegroundColor Red
            return $false
        }
    }
    if ($null -eq $settings) { $settings = [PSCustomObject]@{} }

    # Already installed? (match on script names, not full paths, so a moved
    # plugin still counts and gets left alone rather than duplicated)
    $needTrack = $true
    $needCleanup = $true
    if ($settings.PSObject.Properties['hooks']) {
        foreach ($evt in @('SessionStart', 'SessionEnd')) {
            $prop = $settings.hooks.PSObject.Properties[$evt]
            if (-not $prop) { continue }
            foreach ($matcher in @($prop.Value)) {
                foreach ($h in @($matcher.hooks)) {
                    if ($h.command -match 'claude-session-track\.ps1') { $needTrack = $false }
                    if ($h.command -match 'claude-session-cleanup\.ps1') { $needCleanup = $false }
                }
            }
        }
    }
    if (-not $needTrack -and -not $needCleanup) { return $false }

    if (Test-Path $Path) {
        $bak = "$Path.assistant-resurrect.bak"
        if (-not (Test-Path $bak)) { Copy-Item $Path $bak -Force }
    }

    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($needTrack) {
        $entry = [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = 'command'; command = $trackCmd }) }
        if ($settings.hooks.PSObject.Properties['SessionStart']) {
            $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + @($entry)
        } else {
            $settings.hooks | Add-Member -NotePropertyName 'SessionStart' -NotePropertyValue @($entry)
        }
    }
    if ($needCleanup) {
        $entry = [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = 'command'; command = $cleanupCmd }) }
        if ($settings.hooks.PSObject.Properties['SessionEnd']) {
            $settings.hooks.SessionEnd = @($settings.hooks.SessionEnd) + @($entry)
        } else {
            $settings.hooks | Add-Member -NotePropertyName 'SessionEnd' -NotePropertyValue @($entry)
        }
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    ($settings | ConvertTo-Json -Depth 20) | Set-Content -Path $Path -Encoding UTF8 -Force
    return $true
}

if (-not $SettingsPath) { $SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json' }
$installed = Install-ClaudeHooks -Path $SettingsPath
if ($installed) {
    Write-Host "assistant-resurrect: Claude Code hooks installed in $SettingsPath" -ForegroundColor Green
}

Write-Host "psmux-assistant-resurrect: loaded (tools: claude, codex)" -ForegroundColor DarkGray
