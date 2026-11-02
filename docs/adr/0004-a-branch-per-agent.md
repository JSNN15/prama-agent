# ADR-0004: A git worktree and branch per executor; the coordinator integrates

Status: Accepted · Date: 2026-11-01

## Context

Before 6.5.0 a team shared the zone's folder. Several agents editing one checkout overwrite each
other's files, see each other's half-finished changes in test runs, and leave one undifferentiated
diff that nobody can review or revert per task. Coordination by prompt ("only touch src/auth") helps
but is not enforced.

## Decision

- A new team in a git zone is isolated by default (`PRAMA_SWARM_ISOLATE=1`; `swarm --shared` opts
  out). Each executor gets its own worktree on branch `prama/<team>/<name>`, created from the branch
  the zone's checkout is on, which becomes the team's base (`BASE` on the coordinator). Worktrees live
  outside the repository, under `<parent>/.prama-worktrees/<repo>/<branch>`, so tools scanning the repo
  do not see duplicate trees. An existing branch is reused, never reset.
- The coordinator stays on the base in the zone's folder and integrates with
  `prama-agent worktree status | merge | sync | clean`.
- `worktree merge` refuses to run unless the zone's checkout is on the base with no tracked changes,
  merges with `--no-ff`, and on conflict runs `git merge --abort` (unless `--keep-conflicts`), so the
  base is left as it was. With `--test "<cmd>"` or `PRAMA_MERGE_TEST`, a merge whose tests fail is undone
  with `git reset --merge ORIG_HEAD`.
- Only the team's coordinator or the operator merges. An executor commits to its branch and runs
  `worktree sync` itself, which merges the base into its branch and leaves conflicts for it to
  resolve; anyone else's sync aborts on conflict.
- `swarm stop` and `worktree clean` remove a worktree only if it is clean and fully merged
  (`git branch -d`); anything else is kept and listed.
- A zone that is not a git checkout with a commit on a branch falls back to the shared folder.

## Consequences

Good:
- Each task is a branch: reviewable with `git diff base...branch`, mergeable one at a time, and
  revertible.
- The base stays buildable: conflicts and failing tests never land on it.
- Worktrees share one object store and one set of refs, so the coordinator sees every branch from the
  zone's repository without fetching.

Bad:
- Isolation covers files only. Agents still share the machine, ports, databases, caches and the
  user's credentials.
- Each worktree is a fresh checkout: dependencies must be installed again, or shared with
  `PRAMA_WORKTREE_LINK="node_modules .venv"`, which symlinks the main checkout's directory and so
  shares its mutable state too. `.env`-style files are copied (`PRAMA_WORKTREE_COPY_FILES`).
- Integration becomes a serial step on the coordinator; merges are as good as the `--test` command.
- "Only the coordinator merges" is a guard rail keyed on `PRAMA_SESSION`, not a security boundary:
  an executor with a shell can still run `git merge` by hand. Role prompts tell it not to.
- Merging needs the base checkout free of uncommitted changes to tracked files, so the operator cannot
  keep work in progress there.

## Alternatives considered

- **Shared folder**: no setup cost and right for small or read-only teams; still available with
  `--shared` and used automatically outside git.
- **Containers per agent**: real process, network and filesystem isolation, but a container runtime
  as a dependency, agent CLIs and their logins inside each image, and tmux panes attached into
  containers. Too heavy for prama's dependency budget (ADR-0001).
- **One clone per agent**: the same file isolation, but N object stores on disk, and integrating
  needs fetches between clones or a shared remote. Worktrees give the same separation with shared
  refs.

## Where in the code

- `lib/worktrees.sh`: `worker_branch`, `team_base`, `git_can_isolate`, `wt_status`, `wt_merge`,
  `wt_sync`, `_wt_authorize`, `wt_clean_team`, `_wt_clean_one`, `wt_snapshot_team`
- `lib/agents.sh`: `worktree_path`, `provision_worktree`
- `lib/swarm.sh`: `--isolate` / `--shared` handling when a team is created
- `lib/roles.sh`: executor and coordinator branch protocol in the role prompts
- `tests/test_prama_agent.sh`: "An executor cannot merge into the base", "A conflicting merge is
  aborted", "merge --test undoes a merge that breaks the tests", "…and keeps unmerged work"
- `docs/ARCHITECTURE.md`: invariant 18
