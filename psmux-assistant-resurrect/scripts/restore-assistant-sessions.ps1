# =============================================================================
# psmux-assistant-resurrect: restore assistant sessions
# Port of timvw/tmux-assistant-resurrect scripts/restore-assistant-sessions.sh.
# =============================================================================
# Invoked by psmux-resurrect's @resurrect-hook-post-restore-all after the
# session layout is rebuilt. Reads assistant-sessions.json and sends each
# recorded pane its resume command (claude --resume <id> / codex resume <id> /
# opencode -s <id> / pi --session <id> / omp --resume <id> / grok --resume <id>).
#
# All inputs are injectable for tests; defaults hit the live system.
# Windows PowerShell 5.1 compatible.
# =============================================================================
param(
    [string]$SaveFile = '',
    [string]$ResurrectDir = '',
    [object[]]$ProcessTable = $null,
    [string]$PsmuxBin = '',
    [int]$StaggerMs = 1000,
    [switch]$SkipClientWait
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib-detect.ps1')

if (-not $PsmuxBin) { $PsmuxBin = Get-PsmuxBin }
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

$inFile = Join-Path $ResurrectDir 'assistant-sessions.json'
if (-not (Test-Path $inFile)) {
    Write-Host "assistant-resurrect: no assistant-sessions.json, nothing to restore"
    exit 0
}

$doc = $null
try {
    $doc = Get-Content $inFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "assistant-resurrect: could not parse ${inFile}: $_" -ForegroundColor Red
    exit 1
}
if (-not $doc.sessions -or @($doc.sessions).Count -eq 0) {
    Write-Host "assistant-resurrect: no assistant sessions recorded"
    exit 0
}

# TUI assistants probe the terminal on startup and cache bad answers when no
# client is attached yet (upstream waits the same way). Poll up to 5 s.
if (-not $SkipClientWait) {
    for ($i = 0; $i -lt 50; $i++) {
        $clients = (& $PsmuxBin list-clients 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $clients -and $clients -notmatch 'no server|error') { break }
        Start-Sleep -Milliseconds 100
    }
}

# Commands whose presence in a pane means "safe to type into" - a shell prompt.
$shellCommands = @('powershell', 'pwsh', 'cmd', 'bash', 'zsh', 'fish', 'sh', 'nu')

if ($null -eq $ProcessTable) { $ProcessTable = @(Get-ProcessSnapshot) }

$restored = 0
$skipped = 0
$paneInventory = @{}
foreach ($entry in @($doc.sessions)) {
    $target = [string]$entry.pane
    $tool = [string]$entry.tool
    $sessionId = [string]$entry.session_id

    $m = [regex]::Match($target, '^(.+):(\d+)\.(\d+)$')
    if (-not $m.Success) {
        Write-Host "assistant-resurrect: malformed pane target '$target', skipping" -ForegroundColor Yellow
        $skipped++
        continue
    }
    $sessName = $m.Groups[1].Value
    $winIdx = $m.Groups[2].Value
    $paneIdx = $m.Groups[3].Value

    if (-not (Test-ValidSessionId -SessionId $sessionId)) {
        Write-Host "assistant-resurrect: invalid session id for $target, skipping" -ForegroundColor Yellow
        $skipped++
        continue
    }

    $null = & $PsmuxBin has-session -t $sessName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "assistant-resurrect: session '$sessName' not found, skipping $target" -ForegroundColor Yellow
        $skipped++
        continue
    }

    # Build (once per session) an inventory of every pane: window index,
    # pane index, pid, current command, current path.
    if (-not $paneInventory.ContainsKey($sessName)) {
        $inv = @()
        $winIdxs = ((& $PsmuxBin list-windows -t $sessName -F '#{window_index}' 2>&1 | Out-String).Trim() -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($wi in $winIdxs) {
            $raw = (& $PsmuxBin list-panes -t "${sessName}:${wi}" -F '#{pane_index}|#{pane_pid}|#{pane_current_command}|#{pane_current_path}' 2>&1) | Out-String
            foreach ($line in ($raw -split "`n")) {
                $line = $line.Trim()
                if (-not $line -or $line -notmatch '^\d+\|') { continue }
                $parts = $line -split '\|', 4
                $invPid = 0
                [void][int]::TryParse($parts[1], [ref]$invPid)
                $inv += [PSCustomObject]@{
                    WinIdx  = $wi
                    PaneIdx = $parts[0]
                    PanePid = $invPid
                    Cmd     = (($parts[2]) -replace '\.exe$', '').ToLower()
                    Path    = if ($parts.Count -ge 4) { $parts[3] } else { '' }
                    Claimed = $false
                }
            }
        }
        $paneInventory[$sessName] = $inv
    }
    $inv = $paneInventory[$sessName]

    # Locate the target pane by its restored working directory first - pane
    # and window indices can shift when psmux-resurrect restores into a
    # reused fresh session - falling back to the exact saved index.
    $wantPath = ([string]$entry.cwd).TrimEnd('\', '/')
    $pane = $null
    if ($wantPath) {
        $dirMatches = @($inv | Where-Object { -not $_.Claimed -and $_.Path.TrimEnd('\', '/') -eq $wantPath })
        if ($dirMatches.Count -gt 0) {
            $pane = $dirMatches | Where-Object { $_.WinIdx -eq $winIdx -and $_.PaneIdx -eq $paneIdx } | Select-Object -First 1
            if (-not $pane) { $pane = $dirMatches[0] }
        }
    }
    if (-not $pane) {
        $pane = $inv | Where-Object { -not $_.Claimed -and $_.WinIdx -eq $winIdx -and $_.PaneIdx -eq $paneIdx } | Select-Object -First 1
    }
    if (-not $pane) {
        Write-Host "assistant-resurrect: no pane found for $target (cwd $wantPath), skipping" -ForegroundColor Yellow
        $skipped++
        continue
    }
    $paneTarget = "${sessName}:$($pane.WinIdx).$($pane.PaneIdx)"

    # Idempotence: never launch into a pane that already runs an assistant.
    if ($pane.PanePid -gt 0) {
        $existing = Find-AssistantInPane -PanePid $pane.PanePid -ProcessTable $ProcessTable
        if ($existing) {
            Write-Host "assistant-resurrect: $paneTarget already runs $($existing.Tool), skipping" -ForegroundColor DarkGray
            $pane.Claimed = $true
            $skipped++
            continue
        }
    }

    # Only type into an idle shell prompt, not into vim/less/whatever.
    if ($pane.Cmd -and ($shellCommands -notcontains $pane.Cmd)) {
        Write-Host "assistant-resurrect: $paneTarget is running '$($pane.Cmd)', not a shell - skipping" -ForegroundColor Yellow
        $skipped++
        continue
    }

    # Build the resume command.
    $cmd = ''
    switch ($tool) {
        'claude' {
            $cmd = "claude --resume $sessionId"
            $cliArgs = [string]$entry.cli_args
            $model = [string]$entry.model
            if ($model -and $model -match '^[A-Za-z0-9._\[\]-]+$' -and $cliArgs -notmatch '--model') {
                $cmd += " --model $model"
            }
            if ($cliArgs) { $cmd += " $cliArgs" }
        }
        'codex' {
            $cmd = "codex resume $sessionId"
        }
        'opencode' {
            $cmd = "opencode -s $sessionId"
            $cliArgs = [string]$entry.cli_args
            if ($cliArgs) { $cmd += " $cliArgs" }
        }
        'pi' {
            $cmd = "pi --session $sessionId"
        }
        'omp' {
            $cmd = "omp --resume $sessionId"
        }
        'grok' {
            # Community fork flag convention, unverified against a specific
            # package - see README caveat. Upstream deliberately ignores
            # captured cli_args here to avoid re-submitting a stale prompt.
            $cmd = "grok --resume $sessionId"
        }
        default {
            Write-Host "assistant-resurrect: unknown tool '$tool' for $target, skipping" -ForegroundColor Yellow
            $skipped++
            continue
        }
    }

    # Restore the working directory before launching: psmux-resurrect
    # recreates pane cwds at split time, but reused fresh sessions and shell
    # profiles can land elsewhere - and claude resolves --resume against the
    # current project directory, so the wrong cwd means a failed resume plus
    # a folder-trust prompt. (Upstream prefixes cd the same way.)
    $cwd = [string]$entry.cwd
    if ($cwd -and (Test-Path -LiteralPath $cwd)) {
        $cmd = "Set-Location -LiteralPath '" + ($cwd -replace "'", "''") + "'; " + $cmd
    }

    # Env prefix: only validated names, values single-quoted for PowerShell.
    if ($entry.env) {
        $envPrefix = ''
        foreach ($prop in $entry.env.PSObject.Properties) {
            if ($prop.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            $val = [string]$prop.Value -replace "'", "''"
            $envPrefix += "`$env:$($prop.Name)='$val'; "
        }
        if ($envPrefix) { $cmd = $envPrefix + $cmd }
    }

    # Type the command and press Enter as two separate keystrokes: a single
    # send-keys with trailing Enter can race a freshly-spawned shell (the
    # text lands but the newline is swallowed, leaving the command untyped).
    $pane.Claimed = $true
    & $PsmuxBin send-keys -t $paneTarget $cmd 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $PsmuxBin send-keys -t $paneTarget Enter 2>&1 | Out-Null
    Write-Host "assistant-resurrect: restored $tool session $sessionId in $paneTarget" -ForegroundColor Green
    $restored++

    # Stagger launches so simultaneous TUI startups don't fight for resources.
    if ($StaggerMs -gt 0) { Start-Sleep -Milliseconds $StaggerMs }
}

Write-Host "assistant-resurrect: restore complete ($restored restored, $skipped skipped)"
& $PsmuxBin display-message "assistant-resurrect: $restored assistant(s) resumed" 2>&1 | Out-Null
exit 0
