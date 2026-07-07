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
    'hooks\claude-session-track.ps1', 'hooks\claude-session-cleanup.ps1'
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
