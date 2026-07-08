// psmux-assistant-resurrect: OpenCode session tracker plugin
// Port of timvw/tmux-assistant-resurrect hooks/opencode-session-track.js
// for the psmux (Windows) fork.
//
// Installed by psmux-assistant-resurrect.ps1 (Install-OpenCodeHook) into
// OpenCode's plugin directory, where OpenCode auto-loads it - no PowerShell
// involved here, this runs in OpenCode's own Node/Bun process.
//
// Writes <state-dir>\opencode-<pid>.json on session.created/session.updated
// so scripts/save-assistant-sessions.ps1 can read the session id back out
// (Get-OpenCodeSessionInfo in scripts/lib-detect.ps1). Never throws: a
// tracking-write failure must not break the assistant itself.

import { writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

function stateDir() {
  if (process.env.PSMUX_ASSISTANT_RESURRECT_DIR) return process.env.PSMUX_ASSISTANT_RESURRECT_DIR
  // Mirrors Get-AssistantStateDir in scripts/lib-detect.ps1.
  return join(homedir(), '.psmux', 'assistant-resurrect', 'state')
}

function writeState(sessionId, directory, model) {
  try {
    const dir = stateDir()
    mkdirSync(dir, { recursive: true })
    const payload = {
      tool: 'opencode',
      session_id: sessionId,
      pid: process.pid,
      cwd: directory || null,
      model: model || null,
      timestamp: new Date().toISOString(),
    }
    writeFileSync(join(dir, `opencode-${process.pid}.json`), JSON.stringify(payload), 'utf8')
  } catch {
    // Swallow - tracking is best-effort and must never break OpenCode.
  }
}

export const SessionTracker = async ({ directory }) => {
  return {
    event: async ({ event }) => {
      if (event.type !== 'session.created' && event.type !== 'session.updated') return
      const info = event.properties && (event.properties.info || event.properties.session)
      if (!info || !info.id) return
      writeState(info.id, directory, info.model)
    },
  }
}
