# Architecture Decision Records

Records of prama-agent's main design decisions: context, decision, costs and the alternatives.

| # | Title | Status | Summary |
| --- | --- | --- | --- |
| [0001](0001-bash-and-tmux.md) | Plain bash on top of tmux | Accepted | bash ≥ 4.4, tmux ≥ 3.2 and git; no daemon, database or Node/Go runtime; held together by lint, an isolated e2e suite and a tmux version matrix. |
| [0002](0002-dedicated-tmux-server-and-private-state.md) | A dedicated tmux server and private, data-only state | Accepted | `tmux -L prama` with exact targets; state in a 0700 directory, read as data and never sourced. |
| [0003](0003-health-from-cli-hooks.md) | Agent health from the CLIs' hooks, the screen as a fallback | Accepted | Hooks decide BLOCKED and its reason; with healthy hooks the screen only adds pre-hook dialogs; blocked agents get a queue, never typed text. |
| [0004](0004-a-branch-per-agent.md) | A git worktree and branch per executor; the coordinator integrates | Accepted | `prama/<team>/<name>` per executor; merges refuse a dirty base, abort on conflict and undo failing tests. |
| [0005](0005-append-only-plan-with-derived-checks.md) | The team plan as an append-only log with checks derived at read time | Accepted | Task table, append-only log and revision under `flock`; stale, orphan, unverified, overlap and ready computed on read; `plan verify` runs the acceptance check itself. |
| [0006](0006-english-msgids-and-catalogs.md) | English source strings as message ids, per-module catalogs | Accepted | `_t` / `_tv` with English ids, Spanish catalogs in `lib/lang/es`, machine output never translated, checked in lint. |

Module ownership and the security invariants the records refer to are in
[ARCHITECTURE.md](../ARCHITECTURE.md).
