# ADR-0002: A dedicated tmux server and private, data-only state

Status: Accepted · Date: 2026-11-01

## Context

v5 ran agents on the user's own tmux server and managed the user's `~/.tmux.conf`: it overwrote the
file (keeping a `.bak`) and reloaded it into the running server. Targets were plain `-t name`, which
tmux matches by prefix, so stopping `prama-claude` could hit `prama-claude-backend`. Its bus lived in
`/tmp/prama-bus`, a fixed, predictable path inside a world-writable directory, and the session list
`source`d every `state/*.env` file it found there. Another local user who created that directory first
could get code run as the operator. The 6.0.0 rewrite addressed all of this.

## Decision

- prama runs its own tmux server: every call goes through `tmx`, which is
  `tmux -L "$PRAMA_TMUX_SOCKET" -f "$PRAMA_TMUX_CONF"` (socket `prama` by default). The config file is
  generated into the state directory; `~/.tmux.conf` and the user's server are never touched.
- Targets are exact: `-t "=$session"` for a session, `-t "=$session:"` for its active pane.
- All mutable state lives in `$PRAMA_STATE_HOME` (`~/.local/state/prama-agent`, honouring
  `XDG_STATE_HOME`). `ensure_private_dir` creates each directory with `umask 077`, refuses a symlink or
  a directory owned by another uid, and sets mode 0700; `events.jsonl` is 0600. Nothing of prama's goes
  to `/tmp` (the socket is wherever tmux keeps its own per-user sockets).
- State is data. Session state is `KEY=value` lines read by `state_get` in a `while read` loop, never
  `source`d or `eval`ed; merges are atomic (temp file + `mv`) under `flock`. Pass-through agent
  arguments are stored NUL-separated and never evaluated. `zones.conf` and presets are parsed the same
  way.
- `doctor` removes a leftover `/tmp/prama-bus` if the user owns it, and warns if someone else does.

## Consequences

Good:
- `prama-agent stop --all` cannot close the user's own sessions, and the user's tmux config and
  plugins never change. The suite checks both: a session on a separate "user" socket survives, and a
  `~/.tmux.conf` with a marker line is unchanged, with no `.bak` created.
- prama can set server-wide options it needs (`default-shell` bash for its generated commands, mouse,
  hooks for the phone layout) without imposing them on the user's terminals.
- Tests use a throwaway socket (`prama-test-$$`), so they never touch a live fleet.

Bad:
- Plain `tmux ls` does not show the agents; you need `tmux -L prama ls` or prama's own attach.
  Attaching from inside the user's tmux is a nested client (`tmx_attach` unsets `TMUX` for it).
- The user's key bindings and theme do not apply inside agent sessions; prama ships its own bindings.
- tmux does not pass the client's environment to `run-shell` / `display-popup`, so key bindings embed
  the socket and state directory explicitly.
- `config.env` and `providers.env` (user and `/etc/prama-agent`) are still bash and are `source`d. That
  is deliberate: they are configuration written by the operator, with the same trust as a shell rc
  file. They are not state. prama writes `config.env` only through `_config_set`, which replaces one
  whitelisted key with a value limited to `[A-Za-z0-9:,._-]`, so nothing it writes can become code.

## Alternatives considered

- **Keep the user's server, with a session prefix** (v5): no isolation of options, keys or `kill`
  mistakes, and the user's config had to be rewritten to get prama's status bar.
- **State in `/tmp` with tighter permissions**: still a shared, predictable namespace; the per-user
  XDG state directory avoids the squatting problem.
- **A database for state**: a dependency for small key/value files that `flock` and atomic renames
  already cover.

## Where in the code

- `lib/core.sh`: `tmx`, `tmx_has`, `tmx_kill`, `tmx_send`, `tmx_capture`, `tmx_attach`,
  `ensure_tmux_conf`, `ensure_private_dir`, `prama_init`, `prama_load_config`, `state_write`,
  `state_get`, `state_set` / `_kv_merge`, `state_args_file`
- `lib/setup.sh`: `_config_set`
- `bin/prama-agent`: `doctor` cleanup of `/tmp/prama-bus`
- `tests/test_prama_agent.sh`: "State dir is 0700", "User .tmux.conf untouched",
  "stop --all keeps the user's own sessions alive"
- `docs/ARCHITECTURE.md`: security invariants 1 to 4
