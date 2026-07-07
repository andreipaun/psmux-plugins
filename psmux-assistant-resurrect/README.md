# psmux-assistant-resurrect

Resume AI coding assistant sessions across psmux restarts.

A Windows/PowerShell port of [timvw/tmux-assistant-resurrect](https://github.com/timvw/tmux-assistant-resurrect)
for [psmux](https://github.com/psmux/psmux). When psmux-resurrect saves your
environment, this plugin records which panes run an AI assistant and which
session each one has open. After a restore, every such pane gets its assistant
relaunched with the conversation resumed instead of an empty prompt.

## Supported tools

| Tool | Detection | Session ID source | Resume command |
|------|-----------|-------------------|----------------|
| Claude Code (`claude`) | process tree | SessionStart hook state file, `--resume` args fallback | `claude --resume <id>` |
| Codex CLI (`codex`) | process tree | `~/.codex/session-tags.jsonl` PID match, `resume` args, rollout cwd match | `codex resume <id>` |

Both native binaries (`claude.exe`, `codex.exe`) and npm installs running
under `node` are detected. Codex support follows the upstream extraction spec
and has not yet been exercised against a live Codex install on Windows.

## Requirements

- psmux with `psmux-plugins/psmux-resurrect` (hook-capable version providing
  `@resurrect-hook-post-save-all` / `@resurrect-hook-post-restore-all`)
- Windows PowerShell 5.1 or PowerShell 7 (no external dependencies, no jq)
- Optional: `psmux-plugins/psmux-continuum` for periodic auto-save

## Installation

Add to `~/.psmux.conf`:

```tmux
set -g @plugin 'psmux-plugins/psmux-resurrect'
set -g @plugin 'psmux-plugins/psmux-assistant-resurrect'
```

Then press `Prefix + I` (ppm install). On first load the plugin:

1. registers itself with psmux-resurrect's post-save / post-restore hooks;
2. installs SessionStart/SessionEnd hooks into `~/.claude/settings.json`
   (idempotent; a one-time backup is written to
   `settings.json.assistant-resurrect.bak`);
3. creates the state directory `~/.psmux/assistant-resurrect/state/`.

## Usage

Nothing to do day-to-day. `Prefix + Ctrl-s` (or continuum auto-save) records
assistant sessions to `~/.psmux/resurrect/assistant-sessions.json`;
`Prefix + Ctrl-r` restores the layout and then resumes each assistant in its
pane.

## Options

```tmux
# Extra environment variables to capture at save time and re-export in the
# pane before relaunching the assistant (space separated names).
set -g @assistant-resurrect-capture-env 'ANTHROPIC_MODEL HTTPS_PROXY'
```

The state directory can be overridden with the
`PSMUX_ASSISTANT_RESURRECT_DIR` environment variable.

## How it works

**Save** (post-save hook): one `Win32_Process` snapshot, a breadth-first walk
from each pane's root PID to find assistant processes, then per-tool session
ID extraction — Claude reads the state file its SessionStart hook wrote
(`claude-<pid>.json`), Codex matches its PID in `session-tags.jsonl`. Results
are written to `assistant-sessions.json` alongside the resurrect saves.

**Restore** (post-restore hook): for every recorded pane that exists again,
sits at a shell prompt, and doesn't already run an assistant, the resume
command is typed via `send-keys`, staggered 1 s apart. Session IDs, model
names and env var names are validated against strict character classes before
being embedded in any command line.

## Safety

- Hook failures never break saves, restores, or Claude Code startup/shutdown.
- The Claude settings merge never rewrites `settings.json` when the hooks are
  already present, and never touches a file it cannot parse.
- An empty `assistant-sessions.json` is written when no assistants run, so
  stale sessions are never resurrected.

## Credits

A port of [tmux-assistant-resurrect](https://github.com/timvw/tmux-assistant-resurrect)
by Tim Van Wassenhove, reimplemented in PowerShell for psmux.
