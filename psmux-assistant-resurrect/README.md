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
| OpenCode (`opencode`) | process tree | plugin-written state file, `-s`/`--session` args fallback | `opencode -s <id>` |
| Pi (`pi`) | process tree | `--session` args, else best-scoring JSONL under `~/.pi/agent/sessions/` | `pi --session <id>` |
| Oh My Pi (`omp`) | process tree | `--resume`/`-r`/`--session` args, terminal breadcrumb file, else best-scoring JSONL under `~/.omp/agent/sessions/` | `omp --resume <id>` |
| Grok CLI (`grok`) | process tree | `~/.grok/active_sessions.json` PID match, `--resume`/`-r`/`-s`/`--session` args fallback | `grok --resume <id>` |

Native binaries (`claude.exe`, `codex.exe`, `opencode.exe`, `pi.exe`,
`omp.exe`, `grok.exe`) and npm/bun installs running under `node.exe`/`bun.exe`
are both detected.

**Unverified against a live install**: Codex, OpenCode, Pi, Oh My Pi, and Grok
are all built to their upstream extraction spec and covered by unit tests
against synthetic data, but none of these five CLIs is installed on the
machine this port was developed on. Only Claude Code has been exercised
end-to-end (start → save → kill → restore → resume, with a real
conversation). Reports of what works (or doesn't) against a live install of
any of the other five are welcome.

**Grok caveat**: xAI's official Grok CLI is Mac/Linux-only, so whatever runs
on Windows is a community fork, and forks disagree on the resume flag
(`-r`/`--resume` vs `-s`/`--session`). Both conventions are accepted when
parsing a live command line, but the resume command this plugin sends
(`grok --resume <id>`) is a best guess - if your fork uses a different flag,
the retyped command may need adjusting by hand until this is verified against
a specific package.

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
3. installs the OpenCode session-tracking plugin into
   `~/.config/opencode/plugins/opencode-session-track.js` (idempotent file
   copy - only written when missing or changed);
4. creates the state directory `~/.psmux/assistant-resurrect/state/`.

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
ID extraction — Claude and OpenCode read the state file their session hooks
wrote (`claude-<pid>.json` / `opencode-<pid>.json`), Codex and Grok match
their PID in a JSON(L) registry, Pi and Oh My Pi score candidate JSONL
session files under a directory keyed by the pane's working directory.
Results are written to `assistant-sessions.json` alongside the resurrect
saves.

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
