# =============================================================================
# psmux-assistant-resurrect: Claude Code SessionEnd hook
# Port of timvw/tmux-assistant-resurrect hooks/claude-session-cleanup.sh.
# =============================================================================
# Removes this claude process's state file so ended sessions are not
# resurrected. Also prunes stale state files whose PID no longer runs claude.
# Never blocks or fails Claude shutdown: all errors exit 0 silently.
# Windows PowerShell 5.1 compatible.
# =============================================================================
param(
    [string]$StateDir = '',
    [int]$ClaudePid = 0,
    [object[]]$ProcessTable = $null
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\lib-detect.ps1')

try {
    if (-not $StateDir) { $StateDir = Get-AssistantStateDir }
    if (-not (Test-Path $StateDir)) { exit 0 }

    if ($null -eq $ProcessTable) { $ProcessTable = @(Get-ProcessSnapshot) }
    $byId = @{}
    foreach ($p in $ProcessTable) { $byId[$p.ProcId] = $p }

    # Walk up from this hook process to the claude process that spawned it.
    if ($ClaudePid -le 0) {
        $cur = $PID
        for ($depth = 0; $depth -lt 15; $depth++) {
            if (-not $byId.ContainsKey($cur)) { break }
            $proc = $byId[$cur]
            if ((Get-ToolFromProcess -Proc $proc) -eq 'claude') {
                $ClaudePid = $proc.ProcId
                break
            }
            if ($proc.ParentProcId -le 0 -or $proc.ParentProcId -eq $cur) { break }
            $cur = $proc.ParentProcId
        }
    }

    if ($ClaudePid -gt 0) {
        $stateFile = Join-Path $StateDir "claude-$ClaudePid.json"
        if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
    }

    # Prune orphans: state files whose PID is gone or no longer claude.
    foreach ($f in (Get-ChildItem $StateDir -Filter 'claude-*.json' -File)) {
        if ($f.BaseName -match '^claude-(\d+)$') {
            $filePid = [int]$Matches[1]
            $alive = $byId.ContainsKey($filePid) -and ((Get-ToolFromProcess -Proc $byId[$filePid]) -eq 'claude')
            if (-not $alive) { Remove-Item $f.FullName -Force }
        }
    }
} catch { }
exit 0
