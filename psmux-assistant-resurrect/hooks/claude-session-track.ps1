# =============================================================================
# psmux-assistant-resurrect: Claude Code SessionStart hook
# Port of timvw/tmux-assistant-resurrect hooks/claude-session-track.sh.
# =============================================================================
# Claude Code pipes hook input JSON (session_id, cwd, transcript_path, ...)
# on stdin. We locate the claude process this hook belongs to by walking UP
# the parent chain from this script's own process, then write the merged
# state to <state-dir>\claude-<pid>.json for the save script to pick up.
#
# Never blocks or fails Claude startup: all errors exit 0 silently.
# Windows PowerShell 5.1 compatible.
# =============================================================================
param(
    [string]$StateDir = '',
    [int]$ClaudePid = 0,
    [object[]]$ProcessTable = $null,
    $InputJson = $null  # untyped: [string] would coerce $null to '' and skip the stdin read
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\lib-detect.ps1')

try {
    if (-not $StateDir) { $StateDir = Get-AssistantStateDir }
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    if ($null -eq $InputJson) {
        # Claude Code runs shell-form hooks through a shell on Windows; the
        # $input pipeline variable receives stdin reliably there, while
        # [Console]::In can come up empty. Try $input first.
        $InputJson = @($input) -join "`n"
        if (-not $InputJson.Trim()) { $InputJson = [Console]::In.ReadToEnd() }
    }
    if ([string]::IsNullOrWhiteSpace($InputJson)) { exit 0 }
    $state = $InputJson | ConvertFrom-Json -ErrorAction Stop
    if (-not $state -or -not $state.session_id) { exit 0 }

    # Walk up from this hook process to the claude process that spawned it.
    if ($ClaudePid -le 0) {
        if ($null -eq $ProcessTable) { $ProcessTable = @(Get-ProcessSnapshot) }
        $byId = @{}
        foreach ($p in $ProcessTable) { $byId[$p.ProcId] = $p }
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
    if ($ClaudePid -le 0) { exit 0 }

    # Env capture: names from @assistant-resurrect-capture-env, values from
    # this hook's environment (inherited from claude, which inherited the
    # pane shell's).
    $envBlock = @{}
    foreach ($name in @('PSMUX_PANE', 'PSMUX', 'PSMUX_SESSION')) {
        $val = [Environment]::GetEnvironmentVariable($name)
        if ($val) { $envBlock[$name] = $val }
    }
    try {
        $psmux = Get-PsmuxBin
        $optVal = (& $psmux show-options -gv '@assistant-resurrect-capture-env' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $optVal -and $optVal -notmatch 'unknown option|error|no server|not found|refused') {
            foreach ($name in ($optVal -split '\s+')) {
                if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
                $val = [Environment]::GetEnvironmentVariable($name)
                if ($null -ne $val) { $envBlock[$name] = $val }
            }
        }
    } catch { }

    $state | Add-Member -NotePropertyName 'tool' -NotePropertyValue 'claude' -Force
    $state | Add-Member -NotePropertyName 'ppid' -NotePropertyValue $ClaudePid -Force
    $state | Add-Member -NotePropertyName 'timestamp' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
    $state | Add-Member -NotePropertyName 'env' -NotePropertyValue $envBlock -Force

    $stateFile = Join-Path $StateDir "claude-$ClaudePid.json"
    ($state | ConvertTo-Json -Depth 10) | Set-Content -Path $stateFile -Encoding UTF8 -Force
} catch { }
exit 0
