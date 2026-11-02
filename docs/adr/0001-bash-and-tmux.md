# ADR-0001: Plain bash on top of tmux

Status: Accepted · Date: 2026-11-01

## Context

prama-agent starts interactive CLI agents (Claude Code, `agy`), keeps them alive across SSH drops,
reads their screens, types into them and coordinates them, usually on a server reached over SSH or
from a phone. The agents are terminal programs. tmux already provides persistent terminals, attach
from anywhere, `capture-pane` and `send-keys`. What is left is glue: launching, supervising, routing
messages and showing state.

## Decision

The control plane is bash ≥ 4.4 over tmux ≥ 3.2 and git. Nothing else is required: no daemon to
install (the watchdog is a tmux session prama starts on launch and that exits after the fleet has been
empty for about a minute), no database (state is plain files), no Node.js or Go runtime. `jq`, `fzf`
and `less` are optional. Python 3, standard library only, is used for the optional Telegram bridge and
developer tools. Agents use the same CLI as the operator (`prama-agent bus | plan | fleet …`), so the
agents' API is a command line.

## Consequences

Good:
- Installing means copying files; any machine with bash, tmux and git runs it.
- Everything is inspectable with `cat` and `tmux -L prama`.

Bad:
- About 11,000 lines of bash in `bin/` and `lib/` (`lib/tui.sh` alone is ~2,700) is near what bash
  carries well: no types, globals as return values (`WT_*`, `PL_*`, `P_*`), `die` inside `$(…)` only
  exits the subshell (invariant 8), and quoting leaks into design (`printf %q` can emit `$'…'`, so
  prama's tmux server must use bash as `default-shell`; the CI matrix found agents dying for users
  whose login shell was dash).
- Every hook event and status line refresh starts a bash process; `bin/prama-agent` has fast paths
  that answer before sourcing any module.
- Some features quietly need `jq`: agy hooks and quota telemetry.

Mitigations: one owner per module and written security invariants (`docs/ARCHITECTURE.md`);
`make lint` (`bash -n`, `shellcheck -S warning -x` on every shell file, `tools/i18n_check.py`);
`tests/test_prama_agent.sh` (~260 assertions) end to end on an isolated tmux server with a temporary
`HOME` and mock agents; CI runs it on Ubuntu 22.04, Debian 12 and Ubuntu 24.04 (tmux 3.2a, 3.3a, 3.4)
as an unprivileged user with a `/bin/sh` login shell. State is data only (`KEY=value` files,
`\x1f`-separated tables, JSON lines), so another implementation could read it without a migration.

We would revisit this if remote hosts (see `docs/ROADMAP.md`) need a long-lived connection rather than
one-shot `ssh host prama-agent … --json` calls, if the TUI cannot stay responsive in bash, or if
coordination needs more than `flock` and atomic renames. A rewrite would go module by module behind the
existing CLI and on-disk formats, the TUI being the first candidate.

## Alternatives considered

- **A single Go binary** (the approach Claude Squad takes): types, real concurrency, one file to ship.
  It still needs tmux and git at runtime for this job, adds a per-platform build and release
  pipeline, and the agents would still talk to it through a CLI.
- **Node.js / Electron**: a runtime many servers do not have, and a GUI does not work over SSH or on a
  phone terminal.
- **Python**: a better language for the TUI and the plan views, and already present for Telegram. Most
  of the work is calling tmux and git and moving text, which bash does directly; v5 existed in bash and
  v6 was a rewrite for safety, not a language change. This is the strongest alternative.

## Where in the code

- `bin/prama-agent`: hook and status line fast paths, module source loop, `prama_init`
- `lib/core.sh`: `tmx`, `state_get`, `_kv_merge`, `queue_push` / `queue_pop`
- `Makefile`: `lint`, `test`, `test-matrix`
- `tests/test_prama_agent.sh` (`tmux_33` gating), `.github/workflows/ci.yml`,
  `.github/scripts/ci-container.sh`
- `CONTRIBUTING.md`: design principles 1 and 3
