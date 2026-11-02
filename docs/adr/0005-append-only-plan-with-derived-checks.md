# ADR-0005: The team plan as an append-only log with checks derived at read time

Status: Accepted · Date: 2026-11-01

## Context

The operator should not have to ask the coordinator what is going on, and the coordinator's own
account is what most needs checking. Two findings shaped the design. arXiv:2603.12229 reported
1.36× for teams working from pre-assigned tasks against 0.88× when agents coordinated themselves,
which argues for an explicit plan written before delegating. The MAST
taxonomy (Cemri et al., "Why Do Multi-Agent LLM Systems Fail?", 2025) groups failures into
specification and system design, inter-agent misalignment, and task verification; the last two are
the ones a supervisor can observe from outside the agents: work claimed but not verified, agents
silently stalled, two agents on the same files.

## Decision

A plan belongs to a team and outlives its sessions, in `$PRAMA_STATE_HOME/plans/<zone>/<team>/`:

- `tasks`: one line per task, 16 fields separated by `\x1f` (id, status, owner, deps, estimate,
  progress, timestamps, revision, title, scope, accept, evidence, checked). Rewritten atomically;
  older files without the last field still load.
- `log`: append-only history, `ts|rev|actor|action|task|detail`. Nothing truncates it.
- `rev`: the revision, incremented only by `plan replan "<reason>"`.

Every change runs in `_plan_tx`: `flock`, load, mutate, append to the log, save. Only the
coordinator or the operator edits the plan; an executor may move and report on its own task
(progress, evidence). `bus assign --task T` starts a task and `bus report --task T` sends it
to review, so the plan moves as a side effect of normal delegation.

Flags are never stored. `_plan_flags` derives them whenever the plan is read (board, timeline, JSON,
HTML, watchdog):

- **stale**: in progress, and neither the task's `updated` time nor the owner's tmux
  `window_activity` is newer than `PRAMA_PLAN_STALE_MIN` (20 min).
- **orphan**: in progress, and the owner's session no longer exists.
- **unverified**: done with empty evidence.
- **checked** / **failed**: the last acceptance check prama ran itself passed / failed (below).
- **overlap**: two tasks in progress whose scopes share a prefix (the part before the first wildcard).
- **ready**: todo, with every dependency done or dropped.

Once a minute the watchdog runs `plan_alerts` for each live coordinator and delivers at most one alert
per task and kind per hour (`.alerted` keeps the times); a ready task is only reported if nobody owns
it and it has not changed for the stale window.

Evidence written by an agent is a claim. `plan verify T` turns it into an observation: it runs the
task's `accept` command where the work is (the owner's worktree in an isolated team, otherwise the
zone's checkout) and stores `time:exit code:commit` in `checked`. A pass also becomes the evidence; a
failure reopens a task that was marked done and is sent to Telegram. The command was written by the
coordinator and runs as the same user; it is printed first, and the operator confirms it at a terminal.

## Consequences

Good:
- A claim (status, progress) is shown next to an observation (activity, evidence), never instead of
  it. A flag cannot be stale itself, because nothing has to clear it.
- Re-plans are numbered with a reason, and the history is never rewritten.
- The plan is cheap for the coordinator to keep (one-line commands) and does not depend on its context
  surviving.

Bad:
- Stale measures silence, not progress: any output in the owner's window counts as activity, so a busy
  agent going in circles is not flagged.
- Hand-written evidence is still free text, and a task without an `accept` command can only be
  claimed, not checked. A check proves the command passed at that commit, not that the command tests
  the right thing.
- `plan verify` runs a command stored in the plan: an explicit exception to "state is data", bounded by
  the same user, the printed command and the operator's confirmation.
- Overlap by path prefix is coarse: no scope means no check, and `src/` overlaps everything below it.
- Permissions are keyed on `PRAMA_SESSION`: a guard rail, not a security boundary.
- Reads take no lock; since `tasks` is replaced by a rename, a reader sees the previous or the next
  table, never a partial one.

## Alternatives considered

- **A database (SQLite)**: transactions and queries, but a new runtime dependency (ADR-0001) for a
  table of tens of rows that `flock` and an atomic rename already protect.
- **A Kanban app** (GitHub Projects, Linear…): network, accounts and tokens for every agent, and the
  watchdog would still need tmux activity, which only exists locally.
- **The plan in the coordinator's context**: free, but lost on restart or compaction, invisible to the
  operator, and unverifiable by construction.

## Where in the code

- `lib/plan.sh`: `_plan_tx`, `_plan_load`, `_plan_save`, `_plan_log`, `_plan_can_edit`,
  `_plan_m_add`, `_plan_m_status`, `_plan_m_set`, `_plan_m_replan`, `_plan_flags`, `_plan_activity`,
  `_plan_scopes_overlap`, `_plan_ready`, `plan_bus_hook`, `plan_alerts`, `plan_json`
- `lib/health.sh`: `_watch_plans`
- `lib/bus.sh`: `--task` handling in assign and report
- `lib/roles.sh`: the plan protocol in the coordinator's prompt
- `docs/ARCHITECTURE.md`: invariant 19
