# =============================================================================
# psmux-assistant-resurrect: shared detection library
# Port of timvw/tmux-assistant-resurrect scripts/lib-detect.sh for Windows.
# =============================================================================
# Pure functions only - no side effects at dot-source time. Every function
# that touches system state (process list, filesystem, psmux) accepts an
# injectable override so tests can run without live assistants.
# Windows PowerShell 5.1 compatible.
# =============================================================================

function Get-PsmuxBin {
    foreach ($n in @('psmux','pmux','tmux')) {
        $b = Get-Command $n -ErrorAction SilentlyContinue
        if ($b) { return $b.Source }
    }
    return 'psmux'
}

# Host PowerShell used for emitted command strings (keybindings, hook options,
# Claude settings hooks). Prefer pwsh when present, fall back to Windows
# PowerShell 5.1 which is always available.
function Get-PsHostBin {
    $b = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($b) { return $b.Source }
    $b = Get-Command 'powershell' -ErrorAction SilentlyContinue
    if ($b) { return $b.Source }
    return 'powershell.exe'
}

# State directory where Claude SessionStart hooks drop claude-<pid>.json.
# Windows replacement for upstream's $XDG_RUNTIME_DIR/tmux-assistant-resurrect.
function Get-AssistantStateDir {
    if ($env:PSMUX_ASSISTANT_RESURRECT_DIR) { return $env:PSMUX_ASSISTANT_RESURRECT_DIR }
    return (Join-Path $env:USERPROFILE '.psmux\assistant-resurrect\state')
}

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return (Join-Path $env:USERPROFILE '.codex')
}

# One snapshot of all processes: ProcId, ParentProcId, Name, CommandLine,
# StartTime. Taken once per save/restore run (upstream: single `ps -eo` pass).
function Get-ProcessSnapshot {
    $rows = @()
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate
    foreach ($p in $procs) {
        $rows += [PSCustomObject]@{
            ProcId       = [int]$p.ProcessId
            ParentProcId = [int]$p.ParentProcessId
            Name         = [string]$p.Name
            CommandLine  = [string]$p.CommandLine
            StartTime    = $p.CreationDate
        }
    }
    return $rows
}

# BFS over the process tree: all descendants of a pane's root PID, in
# breadth-first order (nearest first).
function Get-PaneDescendants {
    param([int]$PanePid, [object[]]$ProcessTable)

    $childrenOf = @{}
    foreach ($p in $ProcessTable) {
        if (-not $childrenOf.ContainsKey($p.ParentProcId)) { $childrenOf[$p.ParentProcId] = @() }
        $childrenOf[$p.ParentProcId] += $p
    }

    $result = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($PanePid)
    $seen = @{ $PanePid = $true }
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($childrenOf.ContainsKey($cur)) {
            foreach ($child in $childrenOf[$cur]) {
                if (-not $seen.ContainsKey($child.ProcId)) {
                    $seen[$child.ProcId] = $true
                    $result += $child
                    $queue.Enqueue($child.ProcId)
                }
            }
        }
    }
    return $result
}

# Map a process to an assistant tool name, or $null.
# Matches native binaries (claude.exe, codex.exe) and npm-installed variants
# running under node whose command line references the tool's CLI script.
function Get-ToolFromProcess {
    param($Proc)

    $base = ([string]$Proc.Name) -replace '\.exe$',''
    $base = $base.ToLower()
    if ($base -eq 'claude') { return 'claude' }
    if ($base -eq 'codex')  { return 'codex' }
    if ($base -eq 'node') {
        $cl = [string]$Proc.CommandLine
        if ($cl -match '(?i)[\\/](@anthropic-ai[\\/]claude-code|claude-code|claude)[\\/][^\s"]*\.[mc]?js') { return 'claude' }
        if ($cl -match '(?i)[\\/](@openai[\\/]codex|codex)[\\/][^\s"]*\.[mc]?js') { return 'codex' }
    }
    return $null
}

# First assistant process found under a pane's process tree (BFS order),
# or $null when the pane runs no known assistant.
function Find-AssistantInPane {
    param([int]$PanePid, [object[]]$ProcessTable)

    foreach ($proc in (Get-PaneDescendants -PanePid $PanePid -ProcessTable $ProcessTable)) {
        $tool = Get-ToolFromProcess -Proc $proc
        if ($tool) {
            return [PSCustomObject]@{
                Tool        = $tool
                ProcId      = $proc.ProcId
                CommandLine = [string]$proc.CommandLine
                StartTime   = $proc.StartTime
            }
        }
    }
    return $null
}

# Session IDs are embedded in send-keys strings on restore; restrict to the
# same character class upstream allows before quoting.
function Test-ValidSessionId {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    return ($SessionId -match '^[A-Za-z0-9_-]+$')
}

# Tokenize a Windows command line, honoring double quotes.
function Split-CommandLine {
    param([string]$CommandLine)
    $tokens = @()
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $tokens }
    foreach ($m in [regex]::Matches($CommandLine, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { $tokens += $m.Groups[1].Value }
        else { $tokens += $m.Groups[2].Value }
    }
    return $tokens
}

# Parse a resume/session id out of a live command line (fallback when no
# state file exists - e.g. right after a restore, before hooks fire).
#   claude: --resume <id> or --resume=<id>
#   codex:  resume <id>
function Get-ResumeIdFromArgs {
    param([string]$Tool, [string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }

    if ($Tool -eq 'claude') {
        $m = [regex]::Match($CommandLine, '--resume[=\s]\s*([A-Za-z0-9_-]+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    elseif ($Tool -eq 'codex') {
        $m = [regex]::Match($CommandLine, '(?:^|\s)resume\s+([A-Za-z0-9_-]+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function Get-ModelFromArgs {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $m = [regex]::Match($CommandLine, '--model[=\s]\s*"?([^\s"]+)"?')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Remaining CLI args after dropping the executable, session-selection flags
# and --model (stored separately). Mirrors upstream's stripped flag lists:
#   claude: --resume --continue --session-id --fork-session --from-pr
#   codex:  resume/fork subcommands, --last --all --include-non-interactive
function Get-CliArgsRemainder {
    param([string]$Tool, [string]$CommandLine)

    $tokens = @(Split-CommandLine -CommandLine $CommandLine)
    if ($tokens.Count -le 1) { return '' }
    $tokens = $tokens[1..($tokens.Count - 1)]

    $valueFlags = @('--model')
    $boolFlags = @()
    $subcommands = @()
    if ($Tool -eq 'claude') {
        $valueFlags += @('--resume', '--session-id', '--from-pr')
        $boolFlags += @('--continue', '--fork-session')
    } elseif ($Tool -eq 'codex') {
        $subcommands += @('resume', 'fork')
        $boolFlags += @('--last', '--all', '--include-non-interactive')
    }

    $kept = @()
    $skipNext = $false
    $skipSubcommandValue = $false
    foreach ($tok in $tokens) {
        if ($skipNext) { $skipNext = $false; continue }
        if ($skipSubcommandValue) {
            $skipSubcommandValue = $false
            if ($tok -notmatch '^-') { continue }  # the subcommand's id argument
        }

        $flagName = ($tok -split '=', 2)[0]
        if ($valueFlags -contains $flagName) {
            if ($tok -notmatch '=') { $skipNext = $true }
            continue
        }
        if ($boolFlags -contains $flagName) { continue }
        if ($subcommands -contains $tok) { $skipSubcommandValue = $true; continue }

        if ($tok -match '\s') { $kept += ('"' + $tok + '"') } else { $kept += $tok }
    }
    return ($kept -join ' ')
}

# --- Claude session info -----------------------------------------------------
# Primary: state file written by the SessionStart hook (claude-<pid>.json).
# Fallback: --resume id parsed from the live command line.
function Get-ClaudeSessionInfo {
    param([int]$ProcId, [string]$StateDir, [string]$CommandLine)

    $info = @{ SessionId = $null; Model = $null; Env = $null; Source = $null }

    $stateFile = Join-Path $StateDir "claude-$ProcId.json"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($state.session_id) {
                $info.SessionId = [string]$state.session_id
                $info.Source = 'state-file'
                if ($state.model) { $info.Model = [string]$state.model }
                if ($state.env) { $info.Env = $state.env }
            }
        } catch { }
    }

    if (-not $info.SessionId) {
        $argId = Get-ResumeIdFromArgs -Tool 'claude' -CommandLine $CommandLine
        if ($argId) {
            $info.SessionId = $argId
            $info.Source = 'args'
        }
    }

    if ($info.SessionId -and -not $info.Model) {
        $info.Model = Get-ModelFromArgs -CommandLine $CommandLine
    }
    return $info
}

# --- Codex session info ------------------------------------------------------
# Primary: PID match in <codex-home>\session-tags.jsonl (.pid / .session).
# Fallback 1: `codex resume <id>` on the live command line.
# Fallback 2: newest session_meta rollout under <codex-home>\sessions whose
#             cwd matches the pane and whose mtime falls in the process
#             lifetime. NOT PID-specific - last resort, same as upstream.
function Get-CodexSessionInfo {
    param([int]$ProcId, [string]$CodexHome, [string]$CommandLine, [string]$Cwd, $StartTime)

    $info = @{ SessionId = $null; Model = $null; Env = $null; Source = $null }

    $tagsFile = Join-Path $CodexHome 'session-tags.jsonl'
    if (Test-Path $tagsFile) {
        try {
            $lines = Get-Content $tagsFile -ErrorAction Stop
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $rec = $line | ConvertFrom-Json -ErrorAction Stop
                    if ([int]$rec.pid -eq $ProcId -and $rec.session) {
                        $info.SessionId = [string]$rec.session  # last match wins
                    }
                } catch { }
            }
            if ($info.SessionId) { $info.Source = 'session-tags' }
        } catch { }
    }

    if (-not $info.SessionId) {
        $argId = Get-ResumeIdFromArgs -Tool 'codex' -CommandLine $CommandLine
        if ($argId) {
            $info.SessionId = $argId
            $info.Source = 'args'
        }
    }

    if (-not $info.SessionId -and $Cwd) {
        $sessionsDir = Join-Path $CodexHome 'sessions'
        if (Test-Path $sessionsDir) {
            $candidates = Get-ChildItem $sessionsDir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
            foreach ($f in $candidates) {
                if ($StartTime -and $f.LastWriteTime -lt $StartTime) { continue }
                try {
                    $first = Get-Content $f.FullName -TotalCount 1 -ErrorAction Stop
                    if (-not $first) { continue }
                    $rec = $first | ConvertFrom-Json -ErrorAction Stop
                    if ($rec.type -ne 'session_meta') { continue }
                    $payload = $rec.payload
                    if ($payload -and $payload.cwd -and $payload.id) {
                        if (([string]$payload.cwd).TrimEnd('\','/') -eq $Cwd.TrimEnd('\','/')) {
                            $info.SessionId = [string]$payload.id
                            $info.Source = 'rollout'
                            break
                        }
                    }
                } catch { }
            }
        }
    }

    if ($info.SessionId -and -not $info.Model) {
        $info.Model = Get-ModelFromArgs -CommandLine $CommandLine
    }
    return $info
}

# --- Pane enumeration --------------------------------------------------------
# All panes across all sessions: Target (sess:win.pane), PanePid, Cwd, Command.
function Get-PaneList {
    param([string]$PsmuxBin)

    $panes = @()
    $fmt = '#{session_name}|#{window_index}|#{pane_index}|#{pane_pid}|#{pane_current_path}|#{pane_current_command}'
    $raw = (& $PsmuxBin list-panes -a -F $fmt 2>&1) | Out-String
    foreach ($line in ($raw -split "`n")) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|', 6
        if ($parts.Count -lt 5) { continue }
        $panePid = 0
        if (-not [int]::TryParse($parts[3], [ref]$panePid)) { continue }
        $cmd = ''
        if ($parts.Count -ge 6) { $cmd = $parts[5] }
        $panes += [PSCustomObject]@{
            Target  = "$($parts[0]):$($parts[1]).$($parts[2])"
            PanePid = $panePid
            Cwd     = $parts[4]
            Command = $cmd
        }
    }
    return $panes
}
