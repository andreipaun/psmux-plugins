# =============================================================================
# psmux-assistant-resurrect: save assistant sessions
# Port of timvw/tmux-assistant-resurrect scripts/save-assistant-sessions.sh.
# =============================================================================
# Invoked by psmux-resurrect's @resurrect-hook-post-save-all with the save
# file path as the (unused) first argument. Detects AI assistants (claude,
# codex) running in psmux panes, extracts their session IDs and writes
# assistant-sessions.json next to the resurrect saves.
#
# All inputs are injectable for tests; defaults hit the live system.
# Windows PowerShell 5.1 compatible.
# =============================================================================
param(
    [string]$SaveFile = '',
    [string]$ResurrectDir = '',
    [string]$StateDir = '',
    [string]$CodexHome = '',
    [object[]]$PaneList = $null,
    [object[]]$ProcessTable = $null,
    [string]$PsmuxBin = '',
    $CaptureEnv = $null  # untyped: [string] would coerce $null to '' and skip the live option lookup
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib-detect.ps1')

if (-not $PsmuxBin) { $PsmuxBin = Get-PsmuxBin }
if (-not $StateDir) { $StateDir = Get-AssistantStateDir }
if (-not $CodexHome) { $CodexHome = Get-CodexHome }
if (-not $ResurrectDir) {
    $ResurrectDir = Join-Path $env:USERPROFILE '.psmux\resurrect'
    try {
        $customDir = (& $PsmuxBin show-options -gv '@resurrect-dir' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $customDir -and $customDir -notmatch 'unknown option|error|no server|not found|refused') {
            $customDir = $customDir -replace '^~', $env:USERPROFILE
            $customDir = $customDir -replace '\$HOME', $env:USERPROFILE
            $ResurrectDir = $customDir
        }
    } catch { }
}
if (-not (Test-Path $ResurrectDir)) {
    New-Item -ItemType Directory -Path $ResurrectDir -Force | Out-Null
}
$outFile = Join-Path $ResurrectDir 'assistant-sessions.json'

# User-selected env var names to persist (space separated option value).
if ($null -eq $CaptureEnv) {
    $CaptureEnv = ''
    try {
        $optVal = (& $PsmuxBin show-options -gv '@assistant-resurrect-capture-env' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $optVal -and $optVal -notmatch 'unknown option|error|no server|not found|refused') {
            $CaptureEnv = $optVal
        }
    } catch { }
}
$captureVars = @($CaptureEnv -split '\s+' | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*$' })

if ($null -eq $PaneList) { $PaneList = @(Get-PaneList -PsmuxBin $PsmuxBin) }
if ($null -eq $ProcessTable) { $ProcessTable = @(Get-ProcessSnapshot) }

$sessions = @()
foreach ($pane in $PaneList) {
    $assistant = Find-AssistantInPane -PanePid $pane.PanePid -ProcessTable $ProcessTable
    if (-not $assistant) { continue }

    $info = $null
    switch ($assistant.Tool) {
        'claude' {
            $info = Get-ClaudeSessionInfo -ProcId $assistant.ProcId -StateDir $StateDir -CommandLine $assistant.CommandLine
        }
        'codex' {
            $info = Get-CodexSessionInfo -ProcId $assistant.ProcId -CodexHome $CodexHome `
                -CommandLine $assistant.CommandLine -Cwd $pane.Cwd -StartTime $assistant.StartTime
        }
    }
    if (-not $info -or -not $info.SessionId) {
        Write-Host "assistant-resurrect: $($assistant.Tool) in $($pane.Target) (pid $($assistant.ProcId)) - no session id found, skipping" -ForegroundColor Yellow
        continue
    }
    if (-not (Test-ValidSessionId -SessionId $info.SessionId)) {
        Write-Host "assistant-resurrect: $($assistant.Tool) in $($pane.Target) - invalid session id, skipping" -ForegroundColor Yellow
        continue
    }

    # Env capture: only user-requested names, from the hook state file's env
    # block when present.
    $envOut = $null
    if ($captureVars.Count -gt 0 -and $info.Env) {
        $envOut = @{}
        foreach ($name in $captureVars) {
            $prop = $info.Env.PSObject.Properties[$name]
            if ($prop -and $null -ne $prop.Value) { $envOut[$name] = [string]$prop.Value }
        }
        if ($envOut.Count -eq 0) { $envOut = $null }
    }

    $sessions += [ordered]@{
        pane       = $pane.Target
        tool       = $assistant.Tool
        session_id = $info.SessionId
        cwd        = $pane.Cwd
        pid        = $assistant.ProcId
        model      = $info.Model
        cli_args   = (Get-CliArgsRemainder -Tool $assistant.Tool -CommandLine $assistant.CommandLine)
        env        = $envOut
    }
    Write-Host "assistant-resurrect: saved $($assistant.Tool) session $($info.SessionId) in $($pane.Target) (via $($info.Source))" -ForegroundColor Green
}

# Always write, even when empty: a stale file would resurrect dead sessions.
$doc = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    sessions  = @($sessions)
}
($doc | ConvertTo-Json -Depth 10) | Set-Content -Path $outFile -Encoding UTF8 -Force
Write-Host "assistant-resurrect: wrote $($sessions.Count) session(s) to $outFile"
exit 0
