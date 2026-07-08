#!/usr/bin/env pwsh
# =============================================================================
# psmux-assistant-resurrect unit/integration tests
# No live psmux server or assistant binaries required: all system inputs
# (process tables, pane lists, state dirs, codex home) are injected.
# Companion e2e suite: test_assistant_resurrect_e2e.ps1
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

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PluginDir = Join-Path $RepoRoot 'psmux-assistant-resurrect'
$ScriptsDir = Join-Path $PluginDir 'scripts'
$HooksDir = Join-Path $PluginDir 'hooks'
$TestRoot = Join-Path $env:TEMP "asst-resurrect-test-$(Get-Random)"
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

Write-Host "`n=== psmux-assistant-resurrect unit tests ===" -ForegroundColor Magenta

try {

# =============================================================================
# PHASE 1: Static validation
# =============================================================================
Write-Host "`n--- Phase 1: Static validation ---" -ForegroundColor Yellow

$expectedFiles = @(
    'psmux-assistant-resurrect.ps1', 'plugin.conf', 'README.md',
    'scripts\lib-detect.ps1', 'scripts\save-assistant-sessions.ps1',
    'scripts\restore-assistant-sessions.ps1',
    'hooks\claude-session-track.ps1', 'hooks\claude-session-cleanup.ps1',
    'hooks\opencode-session-track.js'
)
foreach ($f in $expectedFiles) {
    Check "file exists: $f" (Test-Path (Join-Path $PluginDir $f))
}

foreach ($f in (Get-ChildItem $PluginDir -Recurse -Filter '*.ps1')) {
    $errs = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content $f.FullName -Raw), [ref]$errs) | Out-Null
    Check "parses under PS 5.1: $($f.Name)" ($errs.Count -eq 0) "$($errs.Count) errors"
}

$entryContent = Get-Content (Join-Path $PluginDir 'psmux-assistant-resurrect.ps1') -Raw
Check "entry registers post-save hook" ($entryContent -match '@resurrect-hook-post-save-all')
Check "entry registers post-restore hook" ($entryContent -match '@resurrect-hook-post-restore-all')

$confContent = Get-Content (Join-Path $PluginDir 'plugin.conf') -Raw
Check "plugin.conf: no bash-isms" (-not ($confContent -match '#!/bin/bash|\$\('))
Check "plugin.conf: no unix-only paths" (-not ($confContent -match '/tmp/|/dev/null|/usr/'))

foreach ($n in @('save.ps1', 'restore.ps1')) {
    $c = Get-Content (Join-Path $RepoRoot "psmux-resurrect\scripts\$n") -Raw
    Check "psmux-resurrect $n has Invoke-ResurrectHook" ($c -match 'function Invoke-ResurrectHook')
}

# =============================================================================
# PHASE 2: Detection library
# =============================================================================
Write-Host "`n--- Phase 2: Detection library ---" -ForegroundColor Yellow

. (Join-Path $ScriptsDir 'lib-detect.ps1')

function New-Proc($procId, $parent, $name, $cl) {
    [PSCustomObject]@{ ProcId = $procId; ParentProcId = $parent; Name = $name; CommandLine = $cl; StartTime = (Get-Date).AddHours(-1) }
}

# pane 100: shell -> claude.exe with --resume
# pane 300: shell -> cmd -> node running npm-installed claude
# pane 400: shell -> codex.exe resume
# pane 500: shell -> notepad (no assistant)
$procTable = @(
    (New-Proc 100 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 200 100 'claude.exe' '"C:\Users\u\.local\bin\claude.exe" --resume abc-123 --model opus-4 --verbose'),
    (New-Proc 300 1 'pwsh.exe' 'pwsh.exe'),
    (New-Proc 310 300 'cmd.exe' 'cmd /c claude'),
    (New-Proc 320 310 'node.exe' 'node "C:\Users\u\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"'),
    (New-Proc 400 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 410 400 'codex.exe' 'codex.exe resume xyz-9 --last'),
    (New-Proc 500 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 510 500 'notepad.exe' 'notepad.exe')
)

$desc = @(Get-PaneDescendants -PanePid 300 -ProcessTable $procTable)
Check "BFS finds nested descendants" ($desc.Count -eq 2 -and $desc[0].ProcId -eq 310 -and $desc[1].ProcId -eq 320)

$a = Find-AssistantInPane -PanePid 100 -ProcessTable $procTable
Check "detects native claude.exe" ($a -and $a.Tool -eq 'claude' -and $a.ProcId -eq 200)

$a = Find-AssistantInPane -PanePid 300 -ProcessTable $procTable
Check "detects npm claude under node" ($a -and $a.Tool -eq 'claude' -and $a.ProcId -eq 320)

$a = Find-AssistantInPane -PanePid 400 -ProcessTable $procTable
Check "detects codex.exe" ($a -and $a.Tool -eq 'codex' -and $a.ProcId -eq 410)

$a = Find-AssistantInPane -PanePid 500 -ProcessTable $procTable
Check "no assistant in plain pane" ($null -eq $a)

$nodeCodex = New-Proc 900 1 'node.exe' 'node "C:\npm\node_modules\@openai\codex\bin\codex.js"'
Check "detects npm codex under node" ((Get-ToolFromProcess -Proc $nodeCodex) -eq 'codex')

$plainNode = New-Proc 901 1 'node.exe' 'node "C:\work\my-app\server.js"'
Check "plain node app is not an assistant" ($null -eq (Get-ToolFromProcess -Proc $plainNode))

Check "resume id: --resume <id>" ((Get-ResumeIdFromArgs -Tool 'claude' -CommandLine 'claude --resume abc-123') -eq 'abc-123')
Check "resume id: --resume=<id>" ((Get-ResumeIdFromArgs -Tool 'claude' -CommandLine 'claude --resume=abc-123') -eq 'abc-123')
Check "resume id: none" ($null -eq (Get-ResumeIdFromArgs -Tool 'claude' -CommandLine 'claude --verbose'))
Check "resume id: codex resume <id>" ((Get-ResumeIdFromArgs -Tool 'codex' -CommandLine 'codex resume xyz-9') -eq 'xyz-9')
Check "resume id: codex without resume" ($null -eq (Get-ResumeIdFromArgs -Tool 'codex' -CommandLine 'codex --model o3'))

Check "session id: uuid valid" (Test-ValidSessionId -SessionId 'f47ac10b-58cc-4372-a567-0e02b2c3d479')
Check "session id: injection rejected" (-not (Test-ValidSessionId -SessionId "abc'; Remove-Item x"))
Check "session id: spaces rejected" (-not (Test-ValidSessionId -SessionId 'abc def'))
Check "session id: empty rejected" (-not (Test-ValidSessionId -SessionId ''))
Check "session id: quotes rejected" (-not (Test-ValidSessionId -SessionId 'abc"def'))

Check "model: --model <m>" ((Get-ModelFromArgs -CommandLine 'claude --model opus-4.5') -eq 'opus-4.5')
Check "model: --model=<m>" ((Get-ModelFromArgs -CommandLine 'claude --model=sonnet') -eq 'sonnet')
Check "model: absent" ($null -eq (Get-ModelFromArgs -CommandLine 'claude --verbose'))

$tokens = @(Split-CommandLine -CommandLine '"C:\Program Files\x.exe" --flag "a b" plain')
Check "tokenizer honors quotes" ($tokens.Count -eq 4 -and $tokens[0] -eq 'C:\Program Files\x.exe' -and $tokens[2] -eq 'a b')

$rem = Get-CliArgsRemainder -Tool 'claude' -CommandLine 'claude --resume abc-123 --model opus --verbose --add-dir "C:\My Dir"'
Check "cli_args: claude session/model flags stripped" ($rem -eq '--verbose --add-dir "C:\My Dir"') $rem

$rem = Get-CliArgsRemainder -Tool 'claude' -CommandLine 'claude --continue --fork-session --debug'
Check "cli_args: claude boolean session flags stripped" ($rem -eq '--debug') $rem

$rem = Get-CliArgsRemainder -Tool 'codex' -CommandLine 'codex resume xyz-9 --last --sandbox on'
Check "cli_args: codex subcommand and flags stripped" ($rem -eq '--sandbox on') $rem

# --- Detection: OpenCode, Pi, Oh My Pi, Grok ---
$nodeOpenCode = New-Proc 902 1 'node.exe' 'node "C:\npm\node_modules\opencode-ai\bin\opencode.js"'
Check "detects npm opencode under node" ((Get-ToolFromProcess -Proc $nodeOpenCode) -eq 'opencode')
Check "detects native opencode.exe" ((Get-ToolFromProcess -Proc (New-Proc 903 1 'opencode.exe' 'opencode.exe -s ses_abc')) -eq 'opencode')

$bunPi = New-Proc 904 1 'bun.exe' 'bun "C:\Users\u\.bun\install\global\node_modules\@earendil-works\pi-coding-agent\dist\cli.js"'
Check "detects npm pi under bun" ((Get-ToolFromProcess -Proc $bunPi) -eq 'pi')
Check "detects native pi.exe" ((Get-ToolFromProcess -Proc (New-Proc 905 1 'pi.exe' 'pi.exe --session abc')) -eq 'pi')

$bunOmp = New-Proc 906 1 'bun.exe' 'bun "C:\Users\u\.omp\bin\oh-my-pi\dist\cli.js"'
Check "detects npm omp under bun" ((Get-ToolFromProcess -Proc $bunOmp) -eq 'omp')
Check "detects native omp.exe" ((Get-ToolFromProcess -Proc (New-Proc 907 1 'omp.exe' 'omp.exe --resume abc')) -eq 'omp')

$nodeGrok = New-Proc 908 1 'node.exe' 'node "C:\npm\node_modules\grok-cli\bin\grok.js"'
Check "detects npm grok under node" ((Get-ToolFromProcess -Proc $nodeGrok) -eq 'grok')
Check "detects native grok.exe" ((Get-ToolFromProcess -Proc (New-Proc 909 1 'grok.exe' 'grok.exe --resume abc')) -eq 'grok')

Check "resume id: opencode -s <id>" ((Get-ResumeIdFromArgs -Tool 'opencode' -CommandLine 'opencode -s ses_abc') -eq 'ses_abc')
Check "resume id: opencode --session <id>" ((Get-ResumeIdFromArgs -Tool 'opencode' -CommandLine 'opencode --session ses_abc') -eq 'ses_abc')
Check "resume id: opencode none" ($null -eq (Get-ResumeIdFromArgs -Tool 'opencode' -CommandLine 'opencode --model gpt'))

Check "resume id: pi --session <id>" ((Get-ResumeIdFromArgs -Tool 'pi' -CommandLine 'pi --session pi-sess-1') -eq 'pi-sess-1')
Check "resume id: pi none" ($null -eq (Get-ResumeIdFromArgs -Tool 'pi' -CommandLine 'pi --verbose'))

Check "resume id: omp --resume <id>" ((Get-ResumeIdFromArgs -Tool 'omp' -CommandLine 'omp --resume omp-1') -eq 'omp-1')
Check "resume id: omp -r <id>" ((Get-ResumeIdFromArgs -Tool 'omp' -CommandLine 'omp -r omp-2') -eq 'omp-2')
Check "resume id: omp --session <id>" ((Get-ResumeIdFromArgs -Tool 'omp' -CommandLine 'omp --session omp-3') -eq 'omp-3')

Check "resume id: grok --resume <id>" ((Get-ResumeIdFromArgs -Tool 'grok' -CommandLine 'grok --resume grok-1') -eq 'grok-1')
Check "resume id: grok -r <id>" ((Get-ResumeIdFromArgs -Tool 'grok' -CommandLine 'grok -r grok-2') -eq 'grok-2')
Check "resume id: grok -s <id> (alt fork convention)" ((Get-ResumeIdFromArgs -Tool 'grok' -CommandLine 'grok -s grok-3') -eq 'grok-3')
Check "resume id: grok --session <id> (alt fork convention)" ((Get-ResumeIdFromArgs -Tool 'grok' -CommandLine 'grok --session grok-4') -eq 'grok-4')
Check "resume id: grok none" ($null -eq (Get-ResumeIdFromArgs -Tool 'grok' -CommandLine 'grok --sandbox'))
# -s must not falsely match inside a longer flag like --sandbox
Check "resume id: grok -s not fooled by --sandbox" ($null -eq (Get-ResumeIdFromArgs -Tool 'grok' -CommandLine 'grok --sandbox on'))

$rem = Get-CliArgsRemainder -Tool 'opencode' -CommandLine 'opencode -s ses_abc --continue --debug'
Check "cli_args: opencode session/continue flags stripped" ($rem -eq '--debug') $rem

$rem = Get-CliArgsRemainder -Tool 'omp' -CommandLine 'omp --resume omp-1 --session-dir "C:\My Dir" --verbose'
Check "cli_args: omp session flags stripped" ($rem -eq '--verbose') $rem

# =============================================================================
# PHASE 3: Claude session extraction
# =============================================================================
Write-Host "`n--- Phase 3: Claude session extraction ---" -ForegroundColor Yellow

$stateDir = Join-Path $TestRoot 'state'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

@'
{ "session_id": "state-sess-1", "model": "opus-4.5", "env": { "FOO": "bar", "SECRET": "x" } }
'@ | Set-Content (Join-Path $stateDir 'claude-200.json') -Encoding UTF8

$info = Get-ClaudeSessionInfo -ProcId 200 -StateDir $stateDir -CommandLine 'claude --verbose'
Check "claude: state file is primary" ($info.SessionId -eq 'state-sess-1' -and $info.Source -eq 'state-file')
Check "claude: model from state file" ($info.Model -eq 'opus-4.5')
Check "claude: env block surfaced" ($info.Env -and $info.Env.FOO -eq 'bar')

$info = Get-ClaudeSessionInfo -ProcId 999 -StateDir $stateDir -CommandLine 'claude --resume arg-sess-7 --model sonnet'
Check "claude: args fallback when no state file" ($info.SessionId -eq 'arg-sess-7' -and $info.Source -eq 'args')
Check "claude: model from args in fallback" ($info.Model -eq 'sonnet')

'not json at all {{' | Set-Content (Join-Path $stateDir 'claude-201.json') -Encoding UTF8
$info = Get-ClaudeSessionInfo -ProcId 201 -StateDir $stateDir -CommandLine 'claude --resume fb-1'
Check "claude: corrupt state file falls back to args" ($info.SessionId -eq 'fb-1' -and $info.Source -eq 'args')

$info = Get-ClaudeSessionInfo -ProcId 999 -StateDir $stateDir -CommandLine 'claude'
Check "claude: no source yields null" ($null -eq $info.SessionId)

# Transcript model beats SessionStart-time model: a /model switch mid-session
# must be reflected in what the resume passes as --model.
$transcript = Join-Path $TestRoot 'transcript.jsonl'
@'
{ "type": "user", "message": { "role": "user", "content": "hi" } }
{ "type": "assistant", "message": { "model": "claude-fable-5", "content": "hello" } }
{ "type": "user", "message": { "role": "user", "content": "switch" } }
{ "type": "assistant", "message": { "model": "claude-sonnet-5", "content": "switched" } }
{ "type": "system", "content": "unrelated model mention: model" }
'@ | Set-Content $transcript -Encoding UTF8
$tp = $transcript.Replace('\', '\\')
"{ `"session_id`": `"tr-sess-1`", `"model`": `"claude-fable-5`", `"transcript_path`": `"$tp`" }" | Set-Content (Join-Path $stateDir 'claude-300.json') -Encoding UTF8
$info = Get-ClaudeSessionInfo -ProcId 300 -StateDir $stateDir -CommandLine 'claude'
Check "claude: transcript model overrides startup model" ($info.Model -eq 'claude-sonnet-5') $info.Model

"{ `"session_id`": `"tr-sess-2`", `"model`": `"claude-fable-5`", `"transcript_path`": `"C:\\no\\such\\transcript.jsonl`" }" | Set-Content (Join-Path $stateDir 'claude-301.json') -Encoding UTF8
$info = Get-ClaudeSessionInfo -ProcId 301 -StateDir $stateDir -CommandLine 'claude'
Check "claude: missing transcript falls back to state model" ($info.Model -eq 'claude-fable-5') $info.Model

# =============================================================================
# PHASE 4: Codex session extraction
# =============================================================================
Write-Host "`n--- Phase 4: Codex session extraction ---" -ForegroundColor Yellow

$codexHome = Join-Path $TestRoot 'codex-home'
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

@'
{ "pid": 111, "session": "other-sess" }
{ "pid": 555, "session": "codex-sess-1" }
{ "pid": 555, "session": "codex-sess-2" }
'@ | Set-Content (Join-Path $codexHome 'session-tags.jsonl') -Encoding UTF8

$info = Get-CodexSessionInfo -ProcId 555 -CodexHome $codexHome -CommandLine 'codex' -Cwd 'C:\Work' -StartTime (Get-Date).AddHours(-1)
Check "codex: session-tags PID match, last wins" ($info.SessionId -eq 'codex-sess-2' -and $info.Source -eq 'session-tags')

$info = Get-CodexSessionInfo -ProcId 777 -CodexHome $codexHome -CommandLine 'codex resume arg-c-1' -Cwd 'C:\Work' -StartTime (Get-Date).AddHours(-1)
Check "codex: args fallback" ($info.SessionId -eq 'arg-c-1' -and $info.Source -eq 'args')

$rolloutDir = Join-Path $codexHome 'sessions\2026\07\07'
New-Item -ItemType Directory -Path $rolloutDir -Force | Out-Null
@'
{ "type": "session_meta", "payload": { "id": "roll-sess-1", "cwd": "C:\\Work\\ProjA", "timestamp": "2026-07-07T10:00:00Z" } }
'@ | Set-Content (Join-Path $rolloutDir 'rollout-1.jsonl') -Encoding UTF8

$info = Get-CodexSessionInfo -ProcId 777 -CodexHome $codexHome -CommandLine 'codex' -Cwd 'C:\Work\ProjA' -StartTime (Get-Date).AddHours(-2)
Check "codex: rollout cwd match fallback" ($info.SessionId -eq 'roll-sess-1' -and $info.Source -eq 'rollout')

$info = Get-CodexSessionInfo -ProcId 777 -CodexHome $codexHome -CommandLine 'codex' -Cwd 'C:\Elsewhere' -StartTime (Get-Date).AddHours(-2)
Check "codex: no match yields null" ($null -eq $info.SessionId)

$info = Get-CodexSessionInfo -ProcId 1 -CodexHome (Join-Path $TestRoot 'no-such-dir') -CommandLine 'codex' -Cwd 'C:\' -StartTime (Get-Date)
Check "codex: missing codex home is graceful" ($null -eq $info.SessionId)

# =============================================================================
# PHASE 4b: OpenCode session extraction
# =============================================================================
Write-Host "`n--- Phase 4b: OpenCode session extraction ---" -ForegroundColor Yellow

@'
{ "session_id": "oc-sess-1", "model": "gpt-5" }
'@ | Set-Content (Join-Path $stateDir 'opencode-600.json') -Encoding UTF8
$info = Get-OpenCodeSessionInfo -ProcId 600 -StateDir $stateDir -CommandLine 'opencode --verbose'
Check "opencode: state file is primary" ($info.SessionId -eq 'oc-sess-1' -and $info.Source -eq 'state-file')
Check "opencode: model from state file" ($info.Model -eq 'gpt-5')

$info = Get-OpenCodeSessionInfo -ProcId 999 -StateDir $stateDir -CommandLine 'opencode -s oc-arg-1'
Check "opencode: args fallback when no state file" ($info.SessionId -eq 'oc-arg-1' -and $info.Source -eq 'args')

'not json {{' | Set-Content (Join-Path $stateDir 'opencode-601.json') -Encoding UTF8
$info = Get-OpenCodeSessionInfo -ProcId 601 -StateDir $stateDir -CommandLine 'opencode -s oc-fb-1'
Check "opencode: corrupt state file falls back to args" ($info.SessionId -eq 'oc-fb-1' -and $info.Source -eq 'args')

$info = Get-OpenCodeSessionInfo -ProcId 999 -StateDir $stateDir -CommandLine 'opencode'
Check "opencode: no source yields null" ($null -eq $info.SessionId)

# =============================================================================
# PHASE 4c: Get-JsonlSessionByScore (shared by Pi and OMP) and Pi extraction
# =============================================================================
Write-Host "`n--- Phase 4c: JSONL scoring + Pi session extraction ---" -ForegroundColor Yellow

$scoreDir = Join-Path $TestRoot 'jsonl-score'
New-Item -ItemType Directory -Path $scoreDir -Force | Out-Null
Check "jsonl score: missing dir yields null" ($null -eq (Get-JsonlSessionByScore -SessionsDir (Join-Path $TestRoot 'no-such') -StartTime (Get-Date)))
Check "jsonl score: empty dir yields null" ($null -eq (Get-JsonlSessionByScore -SessionsDir $scoreDir -StartTime (Get-Date)))

$fileOld = Join-Path $scoreDir 'session-old.jsonl'
$fileNew = Join-Path $scoreDir 'session-new.jsonl'
'{}' | Set-Content $fileOld -Encoding UTF8
'{}' | Set-Content $fileNew -Encoding UTF8
(Get-Item $fileOld).LastWriteTime = (Get-Date).AddHours(-2)
(Get-Item $fileNew).LastWriteTime = (Get-Date).AddMinutes(-1)
Check "jsonl score: most recently modified wins" ((Get-JsonlSessionByScore -SessionsDir $scoreDir -StartTime (Get-Date)) -eq 'new')

Check "jsonl score: known session id always wins" ((Get-JsonlSessionByScore -SessionsDir $scoreDir -StartTime (Get-Date) -KnownSessionId 'old') -eq 'old')

$piHome = Join-Path $TestRoot 'pi-home'
$piEncodedCwd = '--' + ('C:\Work\Repos' -replace '[\\/:]', '-') + '--'
$piSessDir = Join-Path $piHome "agent\sessions\$piEncodedCwd"
New-Item -ItemType Directory -Path $piSessDir -Force | Out-Null
'{}' | Set-Content (Join-Path $piSessDir 'pi-sess-x.jsonl') -Encoding UTF8

$info = Get-PiSessionInfo -ProcId 700 -PiHome $piHome -CommandLine 'pi --session pi-arg-1' -Cwd 'C:\Work\Repos' -StartTime (Get-Date)
Check "pi: args primary" ($info.SessionId -eq 'pi-arg-1' -and $info.Source -eq 'args')

$info = Get-PiSessionInfo -ProcId 700 -PiHome $piHome -CommandLine 'pi' -Cwd 'C:\Work\Repos' -StartTime (Get-Date)
Check "pi: jsonl fallback by encoded cwd dir" ($info.SessionId -eq 'pi-sess-x' -and $info.Source -eq 'jsonl')

$info = Get-PiSessionInfo -ProcId 700 -PiHome $piHome -CommandLine 'pi' -Cwd 'C:\No\Such\Dir' -StartTime (Get-Date)
Check "pi: no match for unknown cwd yields null" ($null -eq $info.SessionId)

# =============================================================================
# PHASE 4d: Oh My Pi (omp) session extraction
# =============================================================================
Write-Host "`n--- Phase 4d: Oh My Pi session extraction ---" -ForegroundColor Yellow

$ompHome = Join-Path $TestRoot 'omp-home'

$info = Get-OmpSessionInfo -ProcId 800 -OmpHome $ompHome -CommandLine 'omp --resume omp-arg-1' -Cwd 'C:\Work\Repos' -StartTime (Get-Date) -PaneId '%3'
Check "omp: args primary" ($info.SessionId -eq 'omp-arg-1' -and $info.Source -eq 'args')

$termDir = Join-Path $ompHome 'agent\terminal-sessions'
New-Item -ItemType Directory -Path $termDir -Force | Out-Null
$ompSessFile = Join-Path $TestRoot 'omp-sess-y.jsonl'
'{}' | Set-Content $ompSessFile -Encoding UTF8
@("C:\Work\Repos", $ompSessFile) | Set-Content (Join-Path $termDir 'tmux-%3') -Encoding UTF8

$info = Get-OmpSessionInfo -ProcId 800 -OmpHome $ompHome -CommandLine 'omp' -Cwd 'C:\Work\Repos' -StartTime (Get-Date) -PaneId '%3'
Check "omp: breadcrumb fallback resolves session file" ($info.SessionId -eq 'omp-sess-y' -and $info.Source -eq 'breadcrumb')

$info = Get-OmpSessionInfo -ProcId 800 -OmpHome $ompHome -CommandLine 'omp' -Cwd 'C:\Work\Repos' -StartTime (Get-Date) -PaneId '%no-such-pane'
Check "omp: missing breadcrumb falls through" ($null -eq $info.SessionId -or $info.Source -ne 'breadcrumb')

$ompEncodedCwd = 'C:\Work\Elsewhere' -replace '[\\/:]', '-'
$ompSessDir = Join-Path $ompHome "agent\sessions\$ompEncodedCwd"
New-Item -ItemType Directory -Path $ompSessDir -Force | Out-Null
'{}' | Set-Content (Join-Path $ompSessDir 'omp-sess-z.jsonl') -Encoding UTF8
$info = Get-OmpSessionInfo -ProcId 800 -OmpHome $ompHome -CommandLine 'omp' -Cwd 'C:\Work\Elsewhere' -StartTime (Get-Date) -PaneId '%no-such-pane'
Check "omp: jsonl fallback by encoded cwd dir" ($info.SessionId -eq 'omp-sess-z' -and $info.Source -eq 'jsonl')

# =============================================================================
# PHASE 4e: Grok session extraction
# =============================================================================
Write-Host "`n--- Phase 4e: Grok session extraction ---" -ForegroundColor Yellow

$grokHome = Join-Path $TestRoot 'grok-home'
New-Item -ItemType Directory -Path $grokHome -Force | Out-Null
@'
[
  { "session_id": "grok-other", "pid": 111, "cwd": "C:\\Elsewhere" },
  { "session_id": "grok-live-1", "pid": 850, "cwd": "C:\\Work\\Repos" }
]
'@ | Set-Content (Join-Path $grokHome 'active_sessions.json') -Encoding UTF8

$info = Get-GrokSessionInfo -ProcId 850 -GrokHome $grokHome -CommandLine 'grok'
Check "grok: active_sessions PID match" ($info.SessionId -eq 'grok-live-1' -and $info.Source -eq 'active-sessions')

$info = Get-GrokSessionInfo -ProcId 999 -GrokHome $grokHome -CommandLine 'grok --resume grok-arg-1'
Check "grok: args fallback" ($info.SessionId -eq 'grok-arg-1' -and $info.Source -eq 'args')

$info = Get-GrokSessionInfo -ProcId 999 -GrokHome (Join-Path $TestRoot 'no-such-grok') -CommandLine 'grok'
Check "grok: missing grok home is graceful" ($null -eq $info.SessionId)

# =============================================================================
# PHASE 5: Claude hook scripts
# =============================================================================
Write-Host "`n--- Phase 5: Claude hook scripts ---" -ForegroundColor Yellow

$hookStateDir = Join-Path $TestRoot 'hook-state'
$inputJson = '{ "session_id": "hook-sess-1", "cwd": "C:\\Work\\Repos", "model": "opus-4.5", "hook_event_name": "SessionStart", "source": "startup" }'

& (Join-Path $HooksDir 'claude-session-track.ps1') -StateDir $hookStateDir -ClaudePid 4242 -InputJson $inputJson
$hookFile = Join-Path $hookStateDir 'claude-4242.json'
Check "track hook writes state file" (Test-Path $hookFile)
if (Test-Path $hookFile) {
    $state = Get-Content $hookFile -Raw | ConvertFrom-Json
    Check "track hook: session_id preserved" ($state.session_id -eq 'hook-sess-1')
    Check "track hook: tool + ppid added" ($state.tool -eq 'claude' -and $state.ppid -eq 4242)
    Check "track hook: timestamp added" ([bool]$state.timestamp)
    Check "track hook: cwd preserved" ($state.cwd -eq 'C:\Work\Repos')
}

# Real stdin delivery: pipe JSON through a child powershell process, the way
# Claude Code invokes the hook (regression: a [string]$null param coercion
# once made the script skip the stdin read entirely)
$stdinDir = Join-Path $TestRoot 'hook-state-stdin'
$inputJson | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HooksDir 'claude-session-track.ps1') -StateDir $stdinDir -ClaudePid 5151
Check "track hook reads piped stdin" (Test-Path (Join-Path $stdinDir 'claude-5151.json'))

# PID discovery: walk up from this test process to an injected claude parent
$walkTable = @(
    (New-Proc $PID 77777 'powershell.exe' 'powershell.exe'),
    (New-Proc 77777 1 'claude.exe' 'claude')
)
& (Join-Path $HooksDir 'claude-session-track.ps1') -StateDir $hookStateDir -ProcessTable $walkTable -InputJson $inputJson
Check "track hook walks up to claude pid" (Test-Path (Join-Path $hookStateDir 'claude-77777.json'))

$before = (Get-ChildItem $hookStateDir).Count
& (Join-Path $HooksDir 'claude-session-track.ps1') -StateDir $hookStateDir -ClaudePid 4243 -InputJson 'this is not json {{'
Check "track hook: malformed stdin writes nothing" ((Get-ChildItem $hookStateDir).Count -eq $before)
Check "track hook: malformed stdin exits 0" ($LASTEXITCODE -eq 0)

# Cleanup: own file removed, dead orphans pruned, live entries kept
'{"session_id":"z"}' | Set-Content (Join-Path $hookStateDir 'claude-8888.json') -Encoding UTF8
$cleanupTable = @( (New-Proc 77777 1 'claude.exe' 'claude') )  # 4242 and 8888 are gone
& (Join-Path $HooksDir 'claude-session-cleanup.ps1') -StateDir $hookStateDir -ClaudePid 4242 -ProcessTable $cleanupTable
Check "cleanup hook removes own state file" (-not (Test-Path $hookFile))
Check "cleanup hook prunes dead orphans" (-not (Test-Path (Join-Path $hookStateDir 'claude-8888.json')))
Check "cleanup hook keeps live sessions" (Test-Path (Join-Path $hookStateDir 'claude-77777.json'))

# =============================================================================
# PHASE 6: Claude settings.json merge (entry point)
# =============================================================================
Write-Host "`n--- Phase 6: settings.json merge ---" -ForegroundColor Yellow

$entryScript = Join-Path $PluginDir 'psmux-assistant-resurrect.ps1'

# Fresh file
$settingsA = Join-Path $TestRoot 'settings-a.json'
& $entryScript -SettingsPath $settingsA -SkipPsmux | Out-Null
Check "merge: creates settings when missing" (Test-Path $settingsA)
$sa = Get-Content $settingsA -Raw | ConvertFrom-Json
$startCmds = @($sa.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
$endCmds = @($sa.hooks.SessionEnd | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
Check "merge: SessionStart hook installed" (($startCmds -match 'claude-session-track\.ps1').Count -eq 1)
Check "merge: SessionEnd hook installed" (($endCmds -match 'claude-session-cleanup\.ps1').Count -eq 1)

# Existing unrelated content preserved
$settingsB = Join-Path $TestRoot 'settings-b.json'
@'
{
  "model": "opus",
  "theme": "dark",
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "existing-guard.ps1" } ] } ],
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "user-banner.ps1" } ] } ]
  }
}
'@ | Set-Content $settingsB -Encoding UTF8
& $entryScript -SettingsPath $settingsB -SkipPsmux | Out-Null
$sb = Get-Content $settingsB -Raw | ConvertFrom-Json
Check "merge: unrelated top-level keys preserved" ($sb.model -eq 'opus' -and $sb.theme -eq 'dark')
Check "merge: unrelated hook events preserved" ($sb.hooks.PreToolUse.hooks.command -eq 'existing-guard.ps1')
$sbStart = @($sb.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
Check "merge: existing SessionStart entries kept" ($sbStart -contains 'user-banner.ps1')
Check "merge: our SessionStart appended" (($sbStart -match 'claude-session-track\.ps1').Count -eq 1)
Check "merge: backup created" (Test-Path "$settingsB.assistant-resurrect.bak")

# Idempotence: second run must not rewrite the file
$hashBefore = (Get-FileHash $settingsB).Hash
Start-Sleep -Milliseconds 50
& $entryScript -SettingsPath $settingsB -SkipPsmux | Out-Null
$hashAfter = (Get-FileHash $settingsB).Hash
Check "merge: second run is a no-op" ($hashBefore -eq $hashAfter)
$sb2 = Get-Content $settingsB -Raw | ConvertFrom-Json
$sb2Start = @($sb2.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
Check "merge: no duplicate hooks after re-run" (($sb2Start -match 'claude-session-track\.ps1').Count -eq 1)

# Unparseable file left alone
$settingsC = Join-Path $TestRoot 'settings-c.json'
'{ broken json' | Set-Content $settingsC -Encoding UTF8
& $entryScript -SettingsPath $settingsC -SkipPsmux | Out-Null
Check "merge: unparseable file untouched" ((Get-Content $settingsC -Raw).Trim() -eq '{ broken json')

# =============================================================================
# PHASE 7: Save script (fully injected)
# =============================================================================
Write-Host "`n--- Phase 7: Save script ---" -ForegroundColor Yellow

$resDir = Join-Path $TestRoot 'resurrect'
$paneList = @(
    [PSCustomObject]@{ Target = 'work:1.0'; PanePid = 100; Cwd = 'C:\Work\Repos'; Command = 'claude' },
    [PSCustomObject]@{ Target = 'work:2.0'; PanePid = 500; Cwd = 'C:\Temp'; Command = 'powershell' },
    [PSCustomObject]@{ Target = 'side:1.1'; PanePid = 400; Cwd = 'C:\Work\Codex'; Command = 'codex' }
)
# claude pid 200 has a state file (phase 3); codex pid 410 resolves via session-tags
@'
{ "pid": 410, "session": "codex-live-1" }
'@ | Add-Content (Join-Path $codexHome 'session-tags.jsonl') -Encoding UTF8

& (Join-Path $ScriptsDir 'save-assistant-sessions.ps1') -ResurrectDir $resDir -StateDir $stateDir -CodexHome $codexHome `
    -PaneList $paneList -ProcessTable $procTable -PsmuxBin 'unused-not-called' -CaptureEnv 'FOO' | Out-Null

$outFile = Join-Path $resDir 'assistant-sessions.json'
Check "save: assistant-sessions.json written" (Test-Path $outFile)
$doc = Get-Content $outFile -Raw | ConvertFrom-Json
Check "save: timestamp present" ([bool]$doc.timestamp)
Check "save: two sessions recorded" (@($doc.sessions).Count -eq 2)

$claudeEntry = @($doc.sessions) | Where-Object { $_.tool -eq 'claude' }
Check "save: claude pane target" ($claudeEntry.pane -eq 'work:1.0')
Check "save: claude session from state file" ($claudeEntry.session_id -eq 'state-sess-1')
Check "save: claude cwd + pid recorded" ($claudeEntry.cwd -eq 'C:\Work\Repos' -and $claudeEntry.pid -eq 200)
Check "save: claude model recorded" ($claudeEntry.model -eq 'opus-4.5')
Check "save: cli_args stripped of session flags" ($claudeEntry.cli_args -eq '--verbose') $claudeEntry.cli_args
Check "save: env capture honors allowlist" ($claudeEntry.env.FOO -eq 'bar' -and -not $claudeEntry.env.PSObject.Properties['SECRET'])

$codexEntry = @($doc.sessions) | Where-Object { $_.tool -eq 'codex' }
Check "save: codex session via session-tags" ($codexEntry.session_id -eq 'codex-live-1')

# --- Integration: OpenCode, Pi, OMP, Grok panes through the save script ---
'{ "session_id": "oc-int-1", "model": "gpt-5" }' | Set-Content (Join-Path $stateDir 'opencode-1001.json') -Encoding UTF8
@'
[ { "session_id": "grok-int-1", "pid": 1031, "cwd": "C:\\Work\\Grok" } ]
'@ | Set-Content (Join-Path $grokHome 'active_sessions.json') -Encoding UTF8

$extProcTable = $procTable + @(
    (New-Proc 1000 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 1001 1000 'opencode.exe' 'opencode.exe'),
    (New-Proc 1010 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 1011 1010 'pi.exe' 'pi.exe'),
    (New-Proc 1020 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 1021 1020 'omp.exe' 'omp.exe'),
    (New-Proc 1030 1 'powershell.exe' 'powershell.exe'),
    (New-Proc 1031 1030 'grok.exe' 'grok.exe')
)
$extPaneList = $paneList + @(
    [PSCustomObject]@{ Target = 'oc:1.0'; PanePid = 1000; Cwd = 'C:\Work\OC'; Command = 'opencode'; PaneId = '' },
    [PSCustomObject]@{ Target = 'piw:1.0'; PanePid = 1010; Cwd = 'C:\Work\Repos'; Command = 'pi'; PaneId = '' },
    [PSCustomObject]@{ Target = 'ompw:1.0'; PanePid = 1020; Cwd = 'C:\Work\Elsewhere'; Command = 'omp'; PaneId = '' },
    [PSCustomObject]@{ Target = 'grokw:1.0'; PanePid = 1030; Cwd = 'C:\Work\Grok'; Command = 'grok'; PaneId = '' }
)

& (Join-Path $ScriptsDir 'save-assistant-sessions.ps1') -ResurrectDir $resDir -StateDir $stateDir -CodexHome $codexHome `
    -PiHome $piHome -OmpHome $ompHome -GrokHome $grokHome `
    -PaneList $extPaneList -ProcessTable $extProcTable -PsmuxBin 'unused-not-called' -CaptureEnv '' | Out-Null

$doc = Get-Content $outFile -Raw | ConvertFrom-Json
Check "save: six sessions recorded across all tools" (@($doc.sessions).Count -eq 6) (@($doc.sessions).tool -join ',')

$ocEntry = @($doc.sessions) | Where-Object { $_.tool -eq 'opencode' }
Check "save: opencode session via state file" ($ocEntry.session_id -eq 'oc-int-1' -and $ocEntry.model -eq 'gpt-5')

$piEntry = @($doc.sessions) | Where-Object { $_.tool -eq 'pi' }
Check "save: pi session via jsonl scoring" ($piEntry.session_id -eq 'pi-sess-x')

$ompEntry = @($doc.sessions) | Where-Object { $_.tool -eq 'omp' }
Check "save: omp session via jsonl scoring" ($ompEntry.session_id -eq 'omp-sess-z')

$grokEntry = @($doc.sessions) | Where-Object { $_.tool -eq 'grok' }
Check "save: grok session via active_sessions registry" ($grokEntry.session_id -eq 'grok-int-1')

# No assistants -> empty but valid file (stale data must be overwritten)
& (Join-Path $ScriptsDir 'save-assistant-sessions.ps1') -ResurrectDir $resDir -StateDir $stateDir -CodexHome $codexHome `
    -PaneList @([PSCustomObject]@{ Target = 'work:2.0'; PanePid = 500; Cwd = 'C:\Temp'; Command = 'powershell' }) `
    -ProcessTable $procTable -PsmuxBin 'unused-not-called' -CaptureEnv '' | Out-Null
$doc = Get-Content $outFile -Raw | ConvertFrom-Json
Check "save: empty run overwrites stale sessions" (@($doc.sessions).Count -eq 0)

# =============================================================================
# PHASE 8: Restore script (offline paths)
# =============================================================================
Write-Host "`n--- Phase 8: Restore script offline paths ---" -ForegroundColor Yellow

$fakePsmux = Join-Path $TestRoot 'fake-psmux.cmd'
'@exit /b 1' | Set-Content $fakePsmux -Encoding ASCII

$restoreScript = Join-Path $ScriptsDir 'restore-assistant-sessions.ps1'

# Missing file -> clean exit
$emptyDir = Join-Path $TestRoot 'empty-resurrect'
New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
& $restoreScript -ResurrectDir $emptyDir -PsmuxBin $fakePsmux -SkipClientWait -StaggerMs 0 | Out-Null
Check "restore: missing sessions file exits 0" ($LASTEXITCODE -eq 0)

# Malformed targets / invalid ids / dead sessions are all skipped, exit 0
$resDir2 = Join-Path $TestRoot 'resurrect2'
New-Item -ItemType Directory -Path $resDir2 -Force | Out-Null
@'
{ "timestamp": "2026-07-07T10:00:00Z", "sessions": [
  { "pane": "not-a-target", "tool": "claude", "session_id": "ok-1", "cwd": "C:\\", "pid": 1 },
  { "pane": "work:1.0", "tool": "claude", "session_id": "bad id; rm", "cwd": "C:\\", "pid": 1 },
  { "pane": "gone:1.0", "tool": "claude", "session_id": "ok-2", "cwd": "C:\\", "pid": 1 },
  { "pane": "work:1.0", "tool": "weirdtool", "session_id": "ok-3", "cwd": "C:\\", "pid": 1 }
] }
'@ | Set-Content (Join-Path $resDir2 'assistant-sessions.json') -Encoding UTF8

# 6>&1 folds the information stream (Write-Host) into stdout under PS 5.1
$out = & $restoreScript -ResurrectDir $resDir2 -PsmuxBin $fakePsmux -SkipClientWait -StaggerMs 0 6>&1 | Out-String
Check "restore: all invalid entries skipped, none restored" ($out -match '0 restored, 4 skipped') $out.Trim()
Check "restore: invalid entries exit 0" ($LASTEXITCODE -eq 0)

# Corrupt sessions file -> exit 1, no crash
'nonsense {{' | Set-Content (Join-Path $resDir2 'assistant-sessions.json') -Encoding UTF8
& $restoreScript -ResurrectDir $resDir2 -PsmuxBin $fakePsmux -SkipClientWait -StaggerMs 0 | Out-Null
Check "restore: corrupt sessions file exits 1" ($LASTEXITCODE -eq 1)

}
finally {
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
