# ADR-0003: Agent health from the CLIs' hooks, the screen as a fallback

Status: Accepted · Date: 2026-11-01

## Context

A supervisor has to know when an agent cannot work (login, invalid key, no credit, usage limit,
trust dialog, missing model); a task typed into such an agent is lost. The obvious source is the
screen, but the screen also shows text the agent is reading. In production, the watchdog's own
alert about another agent's 429, typed into a coordinator and wrapped over several lines by the CLI
in a narrow cockpit pane, matched the quota patterns. The coordinator was marked BLOCKED and its
queue stopped draining (16 messages queued). Commit f310bf8 fixed it; the lesson was that the screen
cannot be the authority.

## Decision

Health comes from the CLIs' lifecycle hooks, written to a per-session health file
(`HEALTH REASON DETAIL ACTIVITY MODEL AGENT_SID TS`):

- **Claude Code**: hooks are injected per session with `--settings <file>` at launch
  (SessionStart, UserPromptSubmit, Stop, StopFailure, Notification, PostModelSwitch, SessionEnd);
  `~/.claude/settings.json` is not edited. StopFailure error codes map to reasons: `limit`, `auth`,
  `credit`, `model`, else `error`.
- **agy** has no per-session hook flag, so prama owns one named key, `prama-agent`, in
  `~/.gemini/config/hooks.json` (SessionStart, PreInvocation, Stop), preserves every other entry and
  refuses to touch a file `jq` cannot parse. Outside a prama pane (`PRAMA_SESSION` unset) the hook
  prints `{}` ("no decision") and exits before sourcing anything. Hooks never fail.
- The screen is the fallback: `session_block_info` reads hook health first. When hooks report the
  agent healthy, the screen may only add the dialogs shown before hooks run (`login`, `trust`,
  `model`). Typed messages are skipped whole, from the prompt marker or a prama tag to the next border
  or agent output. Hook-reported `limit` and `error` expire after `PRAMA_BLOCK_TTL` (900 s).
- Nothing is typed into an agent that is not READY or WORKING (`bus_can_inject`). Otherwise the text
  goes to its queue, and the watchdog delivers one queued task after the agent has been READY for two
  consecutive ticks.

## Consequences

Good:
- BLOCKED is deterministic for the failures the CLIs report themselves, with the CLI's own error text
  as the reason.
- Hooks also report the model and the conversation id, which in-place restarts use to resume
  (`--resume` for Claude Code, `--conversation` for agy).
- A wrong BLOCKED delays work (it waits in the queue) instead of losing it.

Bad:
- READY versus WORKING is still read from the screen (`detect_session_state`); the hook's
  `ACTIVITY` is only exposed in `fleet status --json`.
- Pre-hook dialogs and CLIs without hooks (OpenCode, experimental) rely on English screen patterns
  that break when a CLI changes its wording.
- The hook contract belongs to each CLI; a renamed event silently degrades health to the screen.
- agy's hook is global: every agy run on the machine starts `prama-agent` briefly, even outside prama.
  It needs `jq`; without it agy agents run with screen detection only.
- Each hook event costs a bash start.

## Alternatives considered

- **Screen scraping only** (v5): simple and CLI-agnostic, but it cannot tell an agent that is blocked
  from one that is reading about a block (quoted alerts, pasted logs, reports from other agents), long
  messages wrap without a marker, and it yields no model or conversation id.
- **Writing hooks into the user's global settings for Claude Code too**: unnecessary when `--settings`
  exists, and it would change the user's configuration. For agy there is no per-session option, so
  the global file is the one exception, kept to one named key and removable with
  `prama-agent fleet hooks uninstall`.

## Where in the code

- `lib/health.sh`: `hook_ingest`, `_hook_ingest_agy`, `_hook_reason`, `claude_hook_settings`,
  `agy_hooks_ensure` / `agy_hooks_remove`, `deliver_to_session`, `watchdog_tick`
- `lib/core.sh`: `health_set` / `health_get`, `detect_session_state`, `session_block_info`,
  `screen_block_reason`, `BLOCK_PATTERNS`
- `lib/bus.sh`: `bus_can_inject`, `bus_session_state`
- `lib/agents.sh`: `--settings` injection in the Claude Code command builder
- `bin/prama-agent`: `--internal-hook` fast paths
- `tests/test_prama_agent.sh`: "A quoted alert wrapped over several lines is not a block"
- `git show f310bf8`
