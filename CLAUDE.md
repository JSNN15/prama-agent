# CLAUDE.md — working on prama-agent

prama-agent is a control plane for terminal coding agents (Claude Code, Antigravity `agy`; OpenCode
experimental): bash ≥ 4.4 + a dedicated tmux server + git. Teams (a coordinator plus the executors
it launches), a message bus, a watchdog fed by CLI hooks, per-executor git worktrees, a live plan,
shared memory, a full-screen TUI and a Telegram bridge (Python stdlib only).

Read before changing anything:
- `docs/ARCHITECTURE.md` — module ownership, source order, internal API and the **23 security
  invariants**. A change that breaks an invariant is a bug even if the tests pass.
- `CONTRIBUTING.md` — design principles and workflow. `docs/adr/` — why bash/tmux, the private
  server, hooks, a branch per agent, the append-only plan, i18n.
- `docs/GUIDE.md` — user-facing behaviour (what the docs promise is what the code must do).

## Commands

```bash
make lint          # bash -n + shellcheck -S warning + py_compile + tools/i18n_check.py
make test          # lint, Telegram bot unit tests, then tests/test_prama_agent.sh (~several minutes)
make test-matrix   # CI images in Docker: tmux 3.2a (ubuntu:22.04), 3.3a (debian:12), 3.4 (ubuntu:24.04)
make i18n          # also lists Spanish catalog entries nobody uses
```

The e2e suite builds its own tmux socket (`prama-test-$$`), `HOME`, state dir and mock agents
(copies of bash named `claude`/`agy`), and runs the assertions in Spanish (`PRAMA_LANG=es`).

## This machine is also production

- `/usr/local/bin/prama-agent` is a **symlink into this checkout**: whatever branch is checked out
  is what the operator's live agents run (hooks, status line, watchdog, cockpits). Do not leave the
  checkout on a half-finished branch; prefer a separate `git worktree` for risky work.
- The operator's real server is `tmux -L prama` with state in `~/.local/state/prama-agent` and
  config in `/etc/prama-agent/config.env` (YOLO + remote by choice). Never run `tmux -L prama`,
  `prama-agent` with the default env, or edit `/etc/prama-agent` / `~/.gemini` / `~/.claude` while
  testing. For manual experiments export your own `HOME`, `PRAMA_STATE_HOME` and
  `PRAMA_TMUX_SOCKET` (a scratch dir and a unique socket name) and kill that server afterwards.

## Repo workflow

- `main` is protected: branch → PR → green checks (Lint, Test ×3 images, CodeQL) → squash merge.
  CodeQL can open review threads that block the merge until resolved.
- Release: bump `VERSION` in `bin/prama-agent` and add the `CHANGELOG.md` section in the PR; after the
  merge, confirm `main` has the new VERSION, then push tag `vX.Y.Z` (the release workflow publishes).
- Every bug fix ships with a regression test (`tests/test_prama_agent.sh`, or
  `tests/test_telegram_bot.py` for the bot). Gate tmux-version-dependent behaviour (see `tmux_33`).
- New behaviour is documented in **both** `docs/GUIDE.md` and `docs/GUIDE.es.md` (README.md /
  README.es.md only when it changes what prama is), plus a CHANGELOG entry.
- The repo is public: professional wording, no names of the operator's employer or clients.

## Code conventions

- User-facing text: `_t 'English msgid %s' "$arg"` (or `_tv var …` on hot paths); Spanish in
  `lib/lang/es/<module>.sh`. msgids are one-line literals; never translate JSON, events, state keys,
  `--json`/`--porcelain` output or the `[PRAMA-SWARM ROLE: …]` marker. Python: `_("…")` +
  `lib/lang/es/telegram_bot.json`.
- Every tmux call goes through `tmx` (`tmux -L $PRAMA_TMUX_SOCKET -f $PRAMA_TMUX_CONF`) with exact
  targets. State files are `KEY=value` data read with `state_get` — never `source`/`eval` them.
- Pane commands are bash built with `printf %q`; keep argument boundaries (`"${CMD[@]}"`).
- `die` inside `$(...)` only exits the subshell: follow such calls with `|| exit 1` / `|| return 1`.
- Comments in English; 2-space indent; `set -u` is on in the entrypoint (guard optional vars).

## tmux pitfalls already paid for

- Exact targets depend on the command's target *type*: `has-session`/`kill-session`/`switch-client`
  take `-t "=$s"`, but `set-option`, `show-options`, `send-keys`, `capture-pane` and `select-pane`
  take a **pane** target and need `-t "=$s:"` (with `-t "=$s"` they fail on tmux 3.4). Check new
  calls against a scratch server.
- `display-popup` does **not** expand formats in its shell command: `'#{client_name}'` arrives
  literally. Resolve the client in `run-shell` (which does expand) and open the popup from there.
- Cockpit panes are nested tmux clients of the *same* server (`client_termname` `tmux*`); hooks such
  as `client-resized` also fire for them (use `#{hook_client}`, tmux ≥ 3.3).
- `detach-on-destroy on`: killing a session detaches every client on it (cockpit rebuilds included).
- The tmux server copies the **environment of the process that starts it** into its global
  environment, and every later pane inherits it. Never start the server with per-launch variables
  (`PRAMA_TEAM=… "$SELF_PATH" …`): pass them with `new-session -e` or keep them in state files.
- `respawn-pane -k` reruns the pane's *original* command (old flags, old `--session-id`): restarts
  must go through `_fleet_restart_in_place` (`RESTART_REQ` + `compose_session_cmd`).
- Status-bar ranges, `#{hook_client}` and popup titles need tmux ≥ 3.3; Ubuntu 22.04 ships 3.2a.
