#!/usr/bin/env pwsh
# =============================================================================
# psmux-assistant-resurrect end-to-end tests
# Drives a REAL psmux server using scratch sessions (asst-e2e-*) only; never
# touches existing sessions and never calls kill-server. Global options it
# changes (@resurrect-dir, @resurrect-hook-*) are restored on exit.
#
# The restore-delivery tests use tool 'codex' with a synthetic session id so
# nothing heavyweight actually launches when the command lands in the pane.
# An optional live Claude round-trip runs only when both claude is installed
# and ASSISTANT_RESURRECT_E2E_LIVE=1 (it starts a real Claude Code process).
# =============================================================================
$ErrorActionPreference = 'Continue'

$pass = 0; $fail = 0
$results = @()

function Check($name, $cond, $detail = '') {
    if ($cond) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
        $script:results += [PSCustomObject]@{ Test = $name; Result = 'PASS'; Detail = $detail }
    } else {
        Write-Host "  FAIL: $name $(if($detail){" - $detail"})" -ForegroundColor Red
        $script:fail++
        $script:results += [PSCustomObject]@{ Test = $name; Result = 'FAIL'; Detail = $detail }
    }
}

$PSMUX = $null
foreach ($n in @('psmux', 'pmux')) {
    $b = Get-Command $n -ErrorAction SilentlyContinue
    if ($b) { $PSMUX = $b.Source; break }
}
if (-not $PSMUX) {
    Write-Host "FATAL: psmux/pmux binary not found!" -ForegroundColor Red
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PluginDir = Join-Path $RepoRoot 'psmux-assistant-resurrect'
$ScriptsDir = Join-Path $PluginDir 'scripts'
$ResurrectScripts = Join-Path $RepoRoot 'psmux-resurrect\scripts'
$TestRoot = Join-Path $env:TEMP "asst-e2e-$(Get-Random)"
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

$SUFFIX = Get-Random -Minimum 1000 -Maximum 9999
$SESS_DELIVERY = "asst-e2e-d$SUFFIX"
$SESS_BUSY = "asst-e2e-b$SUFFIX"
$SESS_RESTORE = "asst-e2e-r$SUFFIX"

Write-Host "`n=== psmux-assistant-resurrect e2e tests ===" -ForegroundColor Magenta
Write-Host "Binary: $PSMUX" -ForegroundColor Cyan

# Remember global option values we are going to touch.
function Get-GlobalOption($name) {
    $v = (& $PSMUX show-options -gv $name 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $v -match 'unknown option|invalid option|error|no server|not found|refused') { return '' }
    return $v
}
function Set-OrUnset-GlobalOption($name, $value) {
    if ($value) { & $PSMUX set-option -g $name $value 2>&1 | Out-Null }
    else { & $PSMUX set-option -gu $name 2>&1 | Out-Null }
}
$origResurrectDir = Get-GlobalOption '@resurrect-dir'
$origPostSave = Get-GlobalOption '@resurrect-hook-post-save-all'
$origPostRestore = Get-GlobalOption '@resurrect-hook-post-restore-all'

function Wait-ForCondition([scriptblock]$Cond, [int]$TimeoutMs = 8000, [int]$IntervalMs = 250) {
    $elapsed = 0
    while ($elapsed -lt $TimeoutMs) {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds $IntervalMs
        $elapsed += $IntervalMs
    }
    return (& $Cond)
}

function New-ScratchSession($name) {
    $env:PSMUX_ALLOW_NESTING = '1'
    & $PSMUX new-session -d -s $name -c $env:TEMP 2>&1 | Out-Null
    return (Wait-ForCondition { & $PSMUX has-session -t $name 2>&1 | Out-Null; $LASTEXITCODE -eq 0 })
}

function Get-FirstPaneTarget($sessionName) {
    $raw = (& $PSMUX list-panes -t $sessionName -F '#{session_name}:#{window_index}.#{pane_index}' 2>&1 | Out-String).Trim()
    return (($raw -split "`n")[0]).Trim()
}

try {

# =============================================================================
# PHASE 1: Resurrect hook wiring (patched psmux-resurrect)
# =============================================================================
Write-Host "`n--- Phase 1: Resurrect hook wiring ---" -ForegroundColor Yellow

$resDir = Join-Path $TestRoot 'resurrect'
New-Item -ItemType Directory -Path $resDir -Force | Out-Null
& $PSMUX set-option -g '@resurrect-dir' $resDir 2>&1 | Out-Null

# post-save hook: append the received save-file arg to a marker file
$saveMarker = Join-Path $TestRoot 'post-save-marker.txt'
$hookCmd = "Add-Content -Path '$saveMarker' -Value"
& $PSMUX set-option -g '@resurrect-hook-post-save-all' $hookCmd 2>&1 | Out-Null

& (Join-Path $ResurrectScripts 'save.ps1') | Out-Null
Check "post-save hook fired" (Test-Path $saveMarker)
if (Test-Path $saveMarker) {
    $markerContent = (Get-Content $saveMarker -Raw).Trim()
    Check "post-save hook received save path" ($markerContent -like (Join-Path $resDir 'psmux_resurrect_*.json')) $markerContent
    Check "save file actually exists" (Test-Path $markerContent)
}

# A failing hook must not break the save
& $PSMUX set-option -g '@resurrect-hook-post-save-all' 'throw "boom"' 2>&1 | Out-Null
Remove-Item (Join-Path $resDir '*') -Force -ErrorAction SilentlyContinue
& (Join-Path $ResurrectScripts 'save.ps1') | Out-Null
$saves = @(Get-ChildItem $resDir -Filter 'psmux_resurrect_*.json' -ErrorAction SilentlyContinue)
Check "failing post-save hook does not break save" ($saves.Count -ge 1)
& $PSMUX set-option -gu '@resurrect-hook-post-save-all' 2>&1 | Out-Null

# post-restore hook: craft a minimal save containing one scratch session,
# run the patched restore.ps1, assert the hook fired with the save path.
$restoreMarker = Join-Path $TestRoot 'post-restore-marker.txt'
& $PSMUX set-option -g '@resurrect-hook-post-restore-all' "Add-Content -Path '$restoreMarker' -Value" 2>&1 | Out-Null

$tmpDir = ($env:TEMP -replace '\\', '\\')
$miniSave = Join-Path $resDir 'psmux_resurrect_99990101_000000.json'
@"
{
  "version": 2,
  "timestamp": "99990101_000000",
  "sessions": [
    {
      "name": "$SESS_RESTORE",
      "windows": [
        {
          "index": 1, "name": "e2e", "layout": "", "active": true, "zoomed": false, "flags": "",
          "panes": [ { "index": 0, "directory": "$tmpDir", "active": true, "title": "", "command": "" } ]
        }
      ]
    }
  ]
}
"@ | Set-Content $miniSave -Encoding UTF8
$miniSave | Set-Content (Join-Path $resDir 'last') -Encoding UTF8

& (Join-Path $ResurrectScripts 'restore.ps1') | Out-Null
& $PSMUX has-session -t $SESS_RESTORE 2>&1 | Out-Null
Check "restore recreated scratch session" ($LASTEXITCODE -eq 0)
Check "post-restore hook fired" (Test-Path $restoreMarker)
if (Test-Path $restoreMarker) {
    Check "post-restore hook received save path" ((Get-Content $restoreMarker -Raw).Trim() -eq $miniSave)
}
& $PSMUX set-option -gu '@resurrect-hook-post-restore-all' 2>&1 | Out-Null

# =============================================================================
# PHASE 2: Restore delivery into a live pane
# =============================================================================
Write-Host "`n--- Phase 2: Restore delivery ---" -ForegroundColor Yellow

Check "scratch session created" (New-ScratchSession $SESS_DELIVERY)
$target = Get-FirstPaneTarget $SESS_DELIVERY
Check "pane target resolved" ([bool]$target) $target

$sessId = "e2e-fake-$SUFFIX"
@"
{ "timestamp": "2026-01-01T00:00:00Z", "sessions": [
  { "pane": "$target", "tool": "codex", "session_id": "$sessId", "cwd": "$tmpDir", "pid": 1 }
] }
"@ | Set-Content (Join-Path $resDir 'assistant-sessions.json') -Encoding UTF8

Start-Sleep -Seconds 2  # let the pane shell finish starting
& (Join-Path $ScriptsDir 'restore-assistant-sessions.ps1') -ResurrectDir $resDir -SkipClientWait -StaggerMs 0 | Out-Null

$delivered = Wait-ForCondition {
    $content = (& $PSMUX capture-pane -t $target -p 2>&1 | Out-String)
    $content -match [regex]::Escape("codex resume $sessId")
}
Check "resume command delivered to pane" $delivered

# =============================================================================
# PHASE 3: Skip rules
# =============================================================================
Write-Host "`n--- Phase 3: Skip rules ---" -ForegroundColor Yellow

# Entries pointing at dead sessions / panes are skipped without error
@"
{ "timestamp": "2026-01-01T00:00:00Z", "sessions": [
  { "pane": "asst-e2e-nosuch$SUFFIX:1.0", "tool": "codex", "session_id": "x-1", "cwd": "$tmpDir", "pid": 1 },
  { "pane": "${SESS_DELIVERY}:1.99", "tool": "codex", "session_id": "x-2", "cwd": "$tmpDir", "pid": 1 }
] }
"@ | Set-Content (Join-Path $resDir 'assistant-sessions.json') -Encoding UTF8
$out = & (Join-Path $ScriptsDir 'restore-assistant-sessions.ps1') -ResurrectDir $resDir -SkipClientWait -StaggerMs 0 6>&1 | Out-String
Check "dead session skipped" ($out -match 'not found')
Check "nothing restored for dead targets" ($out -match '0 restored, 2 skipped') $out.Trim()

# A pane running a non-shell program is skipped
Check "busy scratch session created" (New-ScratchSession $SESS_BUSY)
$busyTarget = Get-FirstPaneTarget $SESS_BUSY
Start-Sleep -Seconds 2
& $PSMUX send-keys -t $busyTarget 'ping -t 127.0.0.1' Enter 2>&1 | Out-Null
$busyReady = Wait-ForCondition {
    $cmd = (& $PSMUX list-panes -t $SESS_BUSY -F '#{pane_current_command}' 2>&1 | Out-String).Trim()
    $cmd -match '(?i)ping'
}
if ($busyReady) {
    @"
{ "timestamp": "2026-01-01T00:00:00Z", "sessions": [
  { "pane": "$busyTarget", "tool": "codex", "session_id": "x-3", "cwd": "$tmpDir", "pid": 1 }
] }
"@ | Set-Content (Join-Path $resDir 'assistant-sessions.json') -Encoding UTF8
    $out = & (Join-Path $ScriptsDir 'restore-assistant-sessions.ps1') -ResurrectDir $resDir -SkipClientWait -StaggerMs 0 6>&1 | Out-String
    Check "non-shell pane skipped" ($out -match 'not a shell') $out.Trim()
} else {
    Check "non-shell pane skipped" $false 'pane never showed ping as current command'
}

# =============================================================================
# PHASE 4: Live Claude round-trip (opt-in)
# =============================================================================
Write-Host "`n--- Phase 4: Live Claude round-trip ---" -ForegroundColor Yellow

$claudeBin = Get-Command claude -ErrorAction SilentlyContinue
if ($env:ASSISTANT_RESURRECT_E2E_LIVE -eq '1' -and $claudeBin) {
    $liveSess = "asst-e2e-l$SUFFIX"
    New-ScratchSession $liveSess | Out-Null
    $liveTarget = Get-FirstPaneTarget $liveSess
    Start-Sleep -Seconds 2
    & $PSMUX send-keys -t $liveTarget 'claude' Enter 2>&1 | Out-Null

    $stateDir = if ($env:PSMUX_ASSISTANT_RESURRECT_DIR) { $env:PSMUX_ASSISTANT_RESURRECT_DIR } else { Join-Path $env:USERPROFILE '.psmux\assistant-resurrect\state' }
    $tracked = Wait-ForCondition {
        @(Get-ChildItem $stateDir -Filter 'claude-*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-1) }).Count -gt 0
    } 30000 1000
    Check "live: SessionStart hook tracked new claude" $tracked

    & (Join-Path $ScriptsDir 'save-assistant-sessions.ps1') -ResurrectDir $resDir | Out-Null
    $doc = Get-Content (Join-Path $resDir 'assistant-sessions.json') -Raw | ConvertFrom-Json
    $liveEntry = @($doc.sessions) | Where-Object { $_.pane -eq $liveTarget }
    Check "live: claude pane captured on save" ($liveEntry -and $liveEntry.tool -eq 'claude' -and $liveEntry.session_id)

    & $PSMUX kill-session -t $liveSess 2>&1 | Out-Null
} else {
    Write-Host "  SKIP: live round-trip (set ASSISTANT_RESURRECT_E2E_LIVE=1 with claude installed to enable)" -ForegroundColor DarkGray
}

}
finally {
    # Teardown: scratch sessions only, and restore touched global options.
    foreach ($s in @($SESS_DELIVERY, $SESS_BUSY, $SESS_RESTORE)) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Set-OrUnset-GlobalOption '@resurrect-dir' $origResurrectDir
    Set-OrUnset-GlobalOption '@resurrect-hook-post-save-all' $origPostSave
    Set-OrUnset-GlobalOption '@resurrect-hook-post-restore-all' $origPostRestore
    Remove-Item $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# Summary
# =============================================================================
Write-Host "`n=== Summary ===" -ForegroundColor Magenta
Write-Host "  PASS: $pass  FAIL: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) {
    Write-Host "`nFailed tests:" -ForegroundColor Red
    $results | Where-Object { $_.Result -eq 'FAIL' } | ForEach-Object { Write-Host "  - $($_.Test) $($_.Detail)" -ForegroundColor Red }
    exit 1
}
exit 0
