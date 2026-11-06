# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [6.14.0] - 2026-11-06

### Fixed
- **`main` could hold code that had not passed, and merges could undo each other.** `worktree merge --test`
  merged into the base, tested in the zone's folder and undid on failure: `main` and a folder that services
  may mount held untested code meanwhile; two merges at once could report success with neither branch in
  `main`, and an edit made during the tests was lost. The merge is now made and tried in the repository's
  integration worktree (`.prama-worktrees/<repo>/.integration`), merges into a repository run one at a time,
  and the base moves by fast-forward only after the tests pass. **Tests now run from another folder**: whatever
  depends on the folder's name has to be set (for `docker compose`, `name:` in the file).
- `PRAMA_MERGE_TEST_TIMEOUT` could be overrun by anything the tests left in the background; it is now also ended.
- The `merged` event says whether the merge was tested.
- **`restore` could hand a conversation to the wrong agent.** With no tmux server running, the conversation id
  reached the server's environment, and every agent launched afterwards resumed that conversation.
- **`worktree sync` threw away a resolution.** Run again before committing a resolved conflict, it aborted the
  merge. It now refuses, and `worktree merge` refuses over an open merge too.
- **A usage limit drained the queue into an agent with no quota.** The block expired after `PRAMA_BLOCK_TTL`
  whatever the reset time said, so a queued task was typed every 15 minutes and failed, and nothing woke the
  agent at the reset. A limit with a known reset now holds until then, and the agent is told to carry on,
  ahead of its queue.
- **`send` to a stopped agent ran the text as a shell command.** It now refuses (`--force` for the operator).
- **One failed call to tmux wiped the state of live agents**, reported as `vanished`. Only tmux answering that
  a session does not exist counts now.
- **The watchdog died silently.** A non-numeric value in a quota file ended it, and nothing brought it back
  until the next launch. Those values are ignored; it restarts itself if it crashes, and comes back when an agent
  ends a turn unless the operator stopped it.
- `bus report --help` was delivered as a report.
- The scratch recipe in `CLAUDE.md` still loaded the real zones from `/etc/prama-agent`.

## [6.13.0] - 2026-11-06

### Added
- **What needs you, in the status bar.** `▲ 2 <first>` (`▲2` on a phone) counts the agents that cannot move
  without the operator: a dialog, a block a person has to clear, a stopped agent no running coordinator
  handles (an assistant always counts). A usage limit counts only when no running coordinator can act on it,
  because otherwise it clears by itself and the coordinator is told.
- **`Alt+o` (`PRAMA_ASSIST_KEY`) now goes to what needs you**, the most urgent first and the next one on each
  press, then the assistant that called; with nothing pending, the newest assistant, as before. Tapping `▲`
  does the same. Inside a cockpit it moves the focus and keeps the team view.
- **A ring on the operator's terminals** when something starts needing them: a bell and an OSC 9 notification,
  except on a terminal already on that agent. At most one every `PRAMA_TERMINAL_NOTIFY_GAP` seconds (30);
  `PRAMA_TERMINAL_NOTIFY=0` turns it off. A terminal that stopped reading costs the watchdog 2 seconds and
  cannot hang it. An assistant calling rings too.

### Fixed
- `★` showed the first 14 characters of the name, so an auto-named assistant read `prama-backend-`: it now
  drops the prefix, like the status bar's session name.

## [6.12.0] - 2026-11-04

### Security
- **A bus message could approve a permission dialog.** Reproduced with real Claude Code: prama read the
  dialog as "working" (it shows `Esc to cancel`), pasted the message and pressed Enter, and Enter on that
  dialog means *Yes*: the command ran and the message was lost. A session showing a dialog is now `WAITING`:
  nothing is typed into it, queued messages wait, an agent can never answer it, and `prama-agent send` (also
  Telegram's Talk) refuses unless the operator adds `--force`. If it stays open `PRAMA_WAIT_ALERT` seconds
  (120) the operator is told once.
- **`--ask` did not ask.** With no flag Claude Code takes the account's default mode, which can be auto mode:
  prama showed "confirm each action" while nothing was confirmed. `ask` now passes
  `--permission-mode default`. Agents launched with `--ask` will start prompting.
- A server started from inside a Claude Code session passed that session's identity to every pane, tokens
  included; `claude` then refused to start. The generated tmux.conf unsets them.

### Added
- **`bus assign --wait [seconds]`**: returns once the CLI's own hook saw the prompt submitted; exit code 3
  when it was only typed or queued. Plain `assign` now says it *typed* the task, not that it was delivered.

### Fixed
- "Working" was read from the words anywhere on the screen: an agent writing "Working directory…" looked busy
  and its queue stalled, while agy's real footer (`esc to cancel`, lowercase) and Braille spinner were missed.
  It now follows each CLI's own footer and spinner line, with rules from Herdr's manifests (Apache-2.0) and
  tests on real captured screens. agy's rules were not checked against a live agy (its quota was exhausted).
- Two messages sent to one session at the same time could merge: sending now takes a lock per session.

## [6.11.0] - 2026-11-03

### Added
- **`prama-agent restore [<session>|--all|--json]`** (also `fleet restore`): a session that ended comes
  back with the same spec, folder and conversation; its queued tasks are still there and a member
  rejoins its team (`--all` restores coordinators first). It refuses a conversation another process
  still uses, a folder that changed, and daemons (their task is not saved). An agent can bring back
  only an agent it launched, never a coordinator.
- **The watchdog tells when a session ends and nobody closed it through prama**, once, to its
  coordinator, the operator's terminals and Telegram, with the command to bring it back, and it is
  logged as a `vanished` event. Closing on purpose raises no alert; closing from the session's own menu
  is now logged too. `prama-agent status` lists what ended, for a server that rebooted. The newest
  `PRAMA_CLOSED_KEEP` (30) sessions stay saved.

### Fixed
- The watchdog logged `bad array subscript` when a session ended while it was being checked.

### Changed
- README: Herdr in the comparison table.

## [6.10.1] - 2026-11-03

### Removed
- `prama-agent demo` (added in 6.10.0) and `lib/demo.sh`: code the project does not need. The README
  demo and its generator (`make demo`, `tools/demo.sh`) are a different thing and stay.

## [6.10.0] - 2026-11-03

### Added
- **`prama-agent demo`**: try prama in a minute with no account and no tokens. A sandbox with its own
  tmux server, state, HOME and git repository runs simulated agents through the real prama commands:
  the coordinator plans and delegates, the executors commit on their own branches and report, the
  merges run the tests, the plan closes with evidence and an assistant waits for you. Nothing real is
  touched (the host's config, `~/.claude`, `~/.gemini`, the live fleet); `demo stop` deletes it.
- **Agent types of a team**: the coordinator saves the kinds of agents its work needs (a code
  executor, a guide to the project's CLI, a marketing assistant…) with
  `fleet type add <name> --role assistant|executor|reader --agent A [--model M] [--plan] --brief "…"`
  and launches them with `fleet spawn --type <name> [--brief "…"]`; the operator sees them with
  `fleet type list`. Types are data in the team's private state and hold no tools, MCP servers or
  skills, and nothing above ask.

## [6.9.0] - 2026-11-03

### Added
- **Assistants: agents that work for the operator.** A new role, `assistant`: the coordinator (or the
  operator) launches one with a brief, `fleet spawn <agent> <zone> --role assistant --brief "…"`, and
  the operator talks to it directly while the team goes on building (a guide to the codebase, help
  with the project's CLI or services, marketing copy, research). The brief is its system prompt (agy:
  its first message), kept beside its state so restarts keep it; it stays within the brief and sends
  what needs the team (a code change, a bug, a decision) to its coordinator with `bus report`.
  Coordinators are told when and how to launch one.
- **The operator is told, the screen is not moved**: `★ <name>` in the status bar (tap it, or
  `Alt+o`, `PRAMA_ASSIST_KEY`), a message on every terminal attached to prama, and a Telegram
  notification with **💬 Talk**. The agent list shows assistants first. `PRAMA_ASSIST_OPEN=switch`
  takes an operator who has been idle for `PRAMA_ASSIST_IDLE` seconds (60) straight to it.
- **Nobody types over the operator**: while they type in an agent (attached or from the cockpit), bus
  messages to it wait in its queue, `PRAMA_HUMAN_HOLD` seconds (20) after the last key, or
  `PRAMA_ASSIST_HOLD` (180) for an assistant; the watchdog delivers them afterwards.
- What the operator types into an assistant is private: other agents cannot read its screen with
  `logs`/`capture` (`PRAMA_ASSIST_PRIVATE=0` allows it). A plan task an assistant holds is never
  flagged stale.

### Changed
- README: the coordinator choosing its executors and launching assistants; the comparison table is
  dated by month and lists OpenCode (experimental).

## [6.8.1] - 2026-11-03

A review of v6.8.0 found these, each reproduced on an isolated tmux server; every fix has a
regression test.

### Fixed
- **`Alt+a` did nothing on Enter**: `display-popup` does not expand `#{client_name}`, so the picker
  switched a client that does not exist. The key now goes through `run-shell`, like the `☰` button.
- **The cockpit was rebuilt on every use** (`Alt+c`, the picker's cockpit row, the menu), kicking
  whoever was watching: its layout signature was stored with a session target that tmux 3.4 refuses.
  When the team changes, the new layout is built beside the old one and its viewers are moved over.
- **Per-launch variables leaked into the tmux server**: a server started by `swarm` kept
  `PRAMA_TEAM`, `PRAMA_TEAM_ISOLATE` and `PRAMA_TEAM_BASE` in its global environment, so later agents of
  other teams were recorded in the wrong team and told they were isolated. The generated tmux.conf
  unsets them, and an agent a coordinator launches takes its team from that coordinator.
- **agy never got its role prompt** (bus, team, branch, plan): it has no system-prompt flag. A new agy
  conversation now gets it as its first message (`--prompt-interactive`).
- **`prama-agent restart` and Telegram's restart button** reran the pane's original command: changes
  made with `fleet edit` were lost, Claude refused the reused `--session-id`, and the killed runner
  wiped the session's state. They now restart in place from the saved spec, like `fleet restart`.
- A team executor restarted in place (`fleet model`, `fleet edit`) lost its role prompt.
- A Claude agent restarted before its first message tried to resume a conversation that did not exist.
- **The watchdog could type a queued task into a plain shell** (an agent dropped to `[s] shell`), which
  ran it as a command; it now reads the pane's command like every other sender.
- Control characters in a message were typed as keys (ESC ended the paste, `ESC [ Z` is Shift+Tab,
  Claude's permission mode). Only text is typed.
- `capture`/`logs N` and state detection read N lines **plus the whole screen**: stale text kept agents
  WORKING or STANDBY, and a block reported by hooks lost to a "Working…" line still on screen.
- An expired limit block never cleared while its error text was still on screen (the queue stalled).
- **Guard rails** were skipped by the top-level commands: an agent could `stop --all`, stop, restart or
  type into a coordinator, or launch a coordinator directly. They now follow `fleet`'s rules.
- **Teams leaked into each other** (invariant 14): a coordinator's report went to another team's
  coordinator, alerts about a coordinator reached every coordinator of the zone, and `bus assign <role>`
  fell back to other teams.
- `worktree merge --test` could leave the merge in the base when the tests wrote to a merged file,
  while saying it was undone. It now resets to the exact commit from before and checks it.
- Queued messages lost their sender, and one starting with `[` was delivered as is (it could pose as
  `[TASK FROM operator]`). Queued text now carries its real sender; a failed delivery keeps its turn.
- `worktree status/merge/clean` ignored workers closed with `fleet kill`, and `worktree clean` never
  removed anything. Cleaning now checks the worktree's own commits too (a renamed or deleted branch, a
  detached HEAD) and reports a worktree git could not remove.
- An agent could write another team's memory (invariant 17); `bus assign --task` to an agent outside
  any team exited 1 silently; `plan verify` checked the base checkout when the owner of a task in an
  isolated team was gone.
- A coordinator of an isolated team that added an executor with `fleet spawn` got one editing the base
  checkout: it now gets its own worktree.
- The permission ceiling missed agy's `--mode` and opencode's `--auto` in pass-through arguments; a
  launch could reuse the pass-through flags of a dead session with the same name; agents could take
  names reserved for prama's own sessions; branches whose names slugify alike shared a worktree folder;
  a linked `node_modules` counted as uncommitted work.
- A session without a zone emptied every listing; `--internal-hook` exited 1 when prama could not
  start; `cockpit --team` without a value looped forever; the cockpit of an agent outside any team
  mixed every team of the zone; the watchdog could press Enter on a paste of the operator's;
  `worktree merge --pr` reused a closed pull request; `git log` read a branch named like a file as a
  path; a daemon reconfigured in place kept its old permissions and provider.
- tmux.conf is regenerated when the navigation keys, the compact width or prama's path change.

### Added
- `CLAUDE.md`: how to work on prama-agent (commands, the live-checkout warning, conventions and the
  tmux pitfalls behind these fixes).

## [6.8.0] - 2026-11-02

### Added
- **The coordinator picks its executors**: `swarm --workers auto` creates a team with its coordinator
  alone, told to plan and launch the cheapest agent and model that fits each task; `--workers ask`
  makes it propose the team (agent, model, how many, why, which quota) and wait for the operator's OK.
  The new-team menu offers both before the list of agents.
- **`fleet agents [--json]`**: the agents that can be launched, each account's quota (5h and 7d windows,
  resets), whether a 429 blocked it recently and a cost hint per agent. Quota is now kept per account
  (agent + profile), so it outlives the sessions that reported it. Coordinators are told to check it
  before launching anyone and to ask the operator when the choice is costly or nothing fits.

### Fixed
- A message typed into an agent that was still starting up (the team brief, typically) could stay in
  Claude Code's prompt as `[Pasted text #1 +1 lines]` until someone pressed Enter: the Enter arrived
  inside the paste. Messages are now pasted as one bracketed paste with a short pause before Enter
  (`PRAMA_SEND_DELAY`, 0.3 s), and the watchdog submits a message prama typed that is still sitting in
  the prompt, once, within two minutes (never a paste of the operator's).

## [6.7.0] - 2026-11-01

### Added
- **`plan verify <task>`** (and `plan done <task> --verify`): prama runs the task's acceptance check
  (its `--accept` command) where the work is, the owner's worktree in an isolated team, and records the
  exit code and the commit. A pass is evidence prama saw itself (**✓ checked by prama** on the board,
  the menu, Telegram and the HTML export); a failure (**✖**) reopens a task that was marked done, is
  kept in the plan's history and reaches Telegram. At a terminal the operator confirms the command
  first (`--yes` skips). `PRAMA_VERIFY_TIMEOUT` (1800 s) bounds it.
- Plan alerts (stale, unverified, overlap, owner gone, ready) now reach Telegram too, with the team's
  buttons, not only the coordinator.
- README demo: a 35-second GIF in each language, rebuilt by `make demo` from the same demo fleet as
  the screenshots; every screen is real prama output.
- `docs/GUIDE.md` / `docs/GUIDE.es.md`: the full user guide, moved out of the README.
- `docs/adr/`: six architecture decision records (bash and tmux, the dedicated tmux server and
  private state, health from hooks, a branch per agent, the append-only plan, i18n).
- `docs/HOW-IT-WAS-BUILT.md` (and `.es.md`): how prama-agent was built with AI coding agents,
  including the ones it orchestrated itself, and what broke on the way.

### Security
Hardening after two independent reviews of v6.6.0. See [docs/HARDENING.md](docs/HARDENING.md) for
running prama on a shared or production host.
- **The caller is identified by process.** When a command runs under an agent's pane, that pane's
  session is the caller, whatever `PRAMA_SESSION` says: `env -u PRAMA_SESSION prama-agent fleet kill …`
  no longer turns an agent into the operator, and the attempt is logged as an `identity` event.
- **Permissions never grow from agent to agent.** An agent cannot launch another (`fleet spawn`, a
  direct launch) or raise one (`fleet edit --perm`) above its own mode, nor pass a permission flag
  (`--dangerously-skip-permissions`, `--permission-mode`, `--settings`…) through `--`. A yolo default
  (`PRAMA_SKIP_PERMISSIONS=1`) is lowered to the calling agent's mode.
- **Host policy:** `PRAMA_ALLOW_YOLO=0` forbids yolo everywhere, including restarts of agents saved as
  yolo; `PRAMA_PROFILES` lists the provider profiles allowed; `PRAMA_TG_SCREENS=0` keeps agent screens
  off Telegram. `prama-agent doctor` shows the policy and warns when the user is in the `docker`,
  `sudo` or `lxd` group.
- **`worktree merge --pr`** (or `PRAMA_MERGE_MODE=pr`): pushes the branch and opens a pull request
  against the team's base with `gh`, so the zone's checkout is never written and CI decides.
- `IS_SANDBOX=1` is exported only for yolo **as root**, where Claude Code needs it to accept
  `--dangerously-skip-permissions`.
- Coordinators are told that reports are what an agent wrote, not the operator's instructions, and to
  treat them as data (a manipulated executor can repeat a hostile file's instructions).
- `plan verify` on a tree with uncommitted changes records `<commit>+dirty` and never shows the task
  as checked by prama.
- `jq` is required: the installer refuses to install without it, and the test suite stops with a clear
  message instead of failing dozens of checks.
- The security model is stated plainly in SECURITY.md and the guide: guard rails against mistakes, not
  a boundary against a hostile agent running as the same user.

### Changed
- **README rewritten around one idea, "don't trust what your agents say; check it"**: what prama
  checks, an honest comparison with Claude Squad, Agent of Empires, Gas Town and Claude Code agent
  teams (sourced, dated 2026-11-01), why bash, install, and why the name. Under 11 KB.
- Documentation wording tightened to match the code after an audit: hooks decide *blocked* (idle or
  working is still read from the screen), roles are guard rails against mistakes rather than a
  sandbox, process-group termination, watchdog alert routing and Telegram alert buttons.
- The unverified alert and the "done without evidence" warning point to `plan verify`.

## [6.6.0] - 2026-11-01

### Added
- **The live plan.** `prama-agent plan` keeps a team's tasks: id, owner, dependencies, estimate,
  files (scope), how it is checked, progress and evidence. The coordinator writes it with one-line
  commands (`plan add | start | done | review | block | drop | set | replan`), and
  `bus assign --task T3` / `bus report --task T3` move tasks as work is handed out and reported.
  - **Views:** a board by status and a timeline per agent (real work, estimate left, ↻ re-plans),
    live in the team's cockpit (its own pane), in the menu (Teams → 📋 Plan, `v` switches views), in
    Telegram (team → 📋 Plan), as `plan watch`, and as a self-contained HTML file (`plan html`).
  - **Plans that change:** every `replan` is a numbered revision with its reason, kept in an
    append-only history (`plan log`); tasks changed in the latest revision are marked Δ.
  - **Honesty checks** (watchdog, once an hour per task): in progress with no activity from its owner
    (stale), owner gone, done without evidence (unverified), two tasks in progress on the same files,
    a ready task nobody has. The coordinator is told; the board shows them.
  - Only the coordinator or the operator changes the plan; an executor reports progress and evidence
    on its own task. The plan outlives the team (`$PRAMA_STATE_HOME/plans`).
- Role prompts teach the plan protocol (coordinator) and plan task reports (executors).
- README: real screenshots (rebuilt by `make screenshots` from a demo fleet) and Mermaid diagrams of
  how teams, the plan, memory, branches and the watchdog fit together.

### Changed
- Executors restarted in place keep their team prompt (and branch) like at launch.
- The agent banner shows `Alt+m` instead of `M-m` and `~` instead of the home path.

## [6.5.0] - 2026-11-01

### Added
- **Isolated teams: a git worktree and branch per executor.** A new team in a git zone (default,
  `PRAMA_SWARM_ISOLATE=1`; `swarm --shared` opts out) gives each executor its own worktree on
  `prama/<team>/<name>` from the zone's branch; the coordinator stays on it and integrates with
  `prama-agent worktree status | merge | sync | clean`. `merge` aborts on conflict and refuses a dirty
  base, so the base never stays broken; `merge --test "<cmd>"` (or `PRAMA_MERGE_TEST`) undoes a merge
  that breaks the tests. Only the coordinator or the operator merges. `swarm stop` removes clean,
  merged worktrees and keeps unmerged or uncommitted work. `PRAMA_WORKTREE_LINK` shares heavy
  directories (node_modules, .venv) with the main checkout. Menu: isolation step in the new-team
  wizard, Teams → Branches; Telegram: team → ⎇ Branches.
- Executors launched into a team now get their role prompt (bus, reports, their branch).
- Role prompts carry multi-agent practices backed by recent studies: plan with explicit dependencies
  and disjoint files, done means verified with evidence, announce shared-interface changes, merge one
  branch at a time with tests, the coordinator coordinates and does not implement.
- A coordinator can close its own team, itself last (`swarm stop <its session>`), and the operator is
  notified.

### Fixed
- `swarm stop` did not check who called it: an agent could close another team. Agents can now close
  only their own team, and only its coordinator can.

## [6.4.0] - 2026-11-01

### Added
- **English and Spanish.** The whole tool speaks both: menu, CLI, help, doctor, setup, the agents' role
  prompts and bus messages (agents report in your language) and the Telegram bot (commands in both:
  `/teams` = `/equipos`, `/alerts` = `/alertas`…). It follows the locale (`es_*` → Spanish) or
  `prama-agent lang en|es|auto` (`PRAMA_LANG`; the environment wins over config.env). The setup wizard
  asks first. English is the source language; translations live in `lib/lang/es/` (one catalog per
  module) and `tools/i18n_check.py` (part of `make lint`) fails on a missing translation, a placeholder
  mismatch or two catalogs translating the same text differently.
- **Color themes.** `prama-agent theme` lists seven (midnight, ocean, forest, ember, violet, light for
  light terminals, mono for high contrast) with swatches; a theme paints the menu, the tmux status bar
  and pane borders of every agent (regenerated and reloaded live) and the fzf inspector.
- **⚙ Preferences** in the menu (`,`): language, theme (moving through the list previews it live; esc
  restores) and mouse/touch, saved in config.env.
- **Teams screen** (`m`, ▤ Teams): every team with its agents, how many are working and its objective;
  per team: cockpit, message the coordinator, add agents, read or add to its memory, enter the
  coordinator, close it. `+` on a coordinator adds agents to its team from anywhere in the menu.
- **Shared team and zone memory**: `prama-agent memory show|add|clear|list` keeps short dated notes per
  team and per zone (`--zone-wide`) on the server, redacted, capped at `PRAMA_MEMORY_MAX_LINES`. Role
  prompts tell agents to read it at start and to record decisions; the coordinator's brief says how
  many notes are waiting. Agents write to their own team and cannot clear a memory.
- **Telegram alerts you can act on**: the watchdog's alerts (blocked, stopped, quota) arrive with
  buttons (view screen, talk, restart); team and report notifications carry theirs. New views:
  `/alerts` (agents that need you), `/daemons` (queues; queue a task), team memory (read, add a note),
  `/notify` (all · important · alerts · off) and `/mute 30m|1h|8h|24h|off` (silent delivery); also
  `prama-agent telegram alerts <level>` and `telegram mute <time>`.
- Keyboard help (`?`) grouped by task, in two columns when there is room and scrollable on a phone;
  the keybar shows the keys of what is selected, destructive ones in red; tmux keys are shown as
  `Alt+a` instead of `M-a`.
- Code of Conduct (Contributor Covenant 2.1).

### Changed
- The session list is grouped by team: the coordinator row is the team (`▍ backend · sec (2)`, one color
  per team, using the role column too) and its agents hang below with `├` / `└`, named by their last
  part (`agy`, `agy-2`).
- The repository is now `JSNN15/prama-agent` (GitHub redirects the old URLs).
- `status` aligns its columns by display width (accented headers).

### Fixed
- `LICENSE` is now the canonical Apache License 2.0 text (the previous copy differed in one word and
  lacked the appendix, so GitHub could not detect the license).
- `PRAMA_TUI_MOUSE` / `PRAMA_TUI_TICK` from config.env were ignored by the menu (read before the
  configuration was loaded).

## [6.3.0] - 2026-10-31

### Added
- **Several teams per zone.** `swarm <zone> --team <name>` creates a team with its own coordinator,
  objective and cockpit (architecture, security, docs… on the same repository); an existing name adds
  workers to that team. `prama-agent teams` (also `swarm list`, `--json`) lists them;
  `swarm stop <zone> --team <name> | --all | <coordinator>` and `cockpit <zone> --team <name>`. Named
  teams get readable session names (`prama-backend-seguridad-coord`, `…-seguridad-agy`); the zone's
  first team, `principal`, keeps the classic names. The menu's new-team wizard asks for the team name;
  Telegram lists every team and offers existing, suggested or typed names.
- **First steps for new users.** `prama-agent setup` (re-runnable; `--check` only reports): dependencies,
  each agent's sign-in, zones, default permissions, phone options. `prama-agent login [agent]` shows
  whether each CLI is signed in and opens its own login (credentials stay with the CLI).
  `prama-agent zones add|remove|scan` registers working folders under short names in `zones.conf`
  (data, never sourced), next to the zones of `config.env`. The installer and the empty menu point to
  `setup`. New guide: [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) (also in Spanish).
- `fleet status --json` includes each agent's `team`.

### Changed
- `swarm <zone>` without `--team` no longer joins an existing team silently: it creates the zone's
  `principal` team, or asks for a name when the zone already has teams.
- Teams are isolated: an agent's reports (`bus report`) and the watchdog's alerts go to its own
  coordinator; `bus assign <role>` prefers the sender's own agents, then its team, then its zone; with
  `PRAMA_FLEET_SCOPE=zone` a coordinator cannot manage, grow or stop another team's agents.

### Fixed
- `bus report` delivered to the most recently started coordinator anywhere on the server (even another
  zone's); it now goes to the reporter's own coordinator.
- A cockpit built while other cockpits were open could come out tiny on tmux 3.2 ("no space for new
  pane"): it is now built at a fixed size and then follows the attached client.
- `main` is protected (pull requests with green CI); Discussions are enabled for questions.

## [6.2.0] - 2026-10-31

### Added
- **Phone layout.** On clients narrower than `PRAMA_COMPACT_COLS` (100) the cockpit shows one agent at a
  time (zoomed pane) and the status bar becomes large tap targets: `◂` menu · `◀` previous · `☰`
  agents · `▶` next · `▦` cockpit. Back to the split view on a wide client; a zoom chosen by the
  operator is left alone. tmux hooks drive it (tmux ≥ 3.3). Inside the cockpit, next / previous
  (`Ctrl+b n/p`, `◀ ▶`) move between its panes.
- **Teams from Telegram**: `/equipos` (team status with model and quota, talk to the coordinator, view
  its screen, add a worker, close the team), *new team* (zone → workers → objective), `/cuota`.
- **Feedback channel** for prama-agent bugs: `prama-agent feedback "<what happened>"` (any agent or the
  operator), `list | show | export | close`. Reports keep their context (version, agent, model, state,
  recent bus events), are redacted, deduplicated, announced on the bus and Telegram (`/reportes`), and
  `export` produces a GitHub issue body. Every role prompt includes it; doctor and the menu show the
  open count.
- `x` on a coordinator in the menu closes its whole team with one confirmation.
- Doctor checks for mosh; the README has an "On your phone" section (mosh, compact layout, Telegram).
- Telegram bot unit tests (fake Telegram API and CLI, no network).
- CI: test matrix in clean containers (Ubuntu 22.04 / Debian 12 / Ubuntu 24.04: tmux 3.2a, 3.3a, 3.4;
  unprivileged user with a `/bin/sh` login shell), actionlint, CodeQL, OpenSSF Scorecard, SHA-pinned
  actions with Dependabot, release workflow from the tag and this changelog. Issue forms, PR template,
  CODEOWNERS, `.editorconfig`, `make test-matrix`.

### Changed
- `prama-agent update` restarts the watchdog and the Telegram bot when the version changes (they are
  long-running and kept the old code until then).
- The quick guide (`prama-agent info`) describes teams and the phone workflow.
- The menu's action rows show only their label on a phone instead of a description cut short.
- Telegram's *Enjambre* (coordinator + one executor) became *Nuevo equipo* with a choice of workers.

### Fixed
- **Agents died on launch for users whose login shell is not bash** (dash, fish): tmux ran prama's pane
  commands, which use bash quoting, with the user's shell. prama's tmux server now runs commands with
  bash (`default-shell`) while plain panes still open the user's own shell (`default-command`). Found
  by the new container matrix.
- **A coordinator could be marked BLOCKED by an alert about another agent.** The watchdog's
  "[ALERTA PRAMA] … RESOURCE_EXHAUSTED (code 429)" message, wrapped by the CLI over several lines in a
  narrow cockpit pane, matched the screen quota patterns; the coordinator then stopped receiving its
  queue. Typed messages are now skipped whole, and when an agent's hooks report it healthy the screen
  can only add pre-hook dialogs (login, trust, model). Found in production; regression tests added.

## [6.1.0] - 2026-10-30

### Added
- **Teams**: `prama-agent swarm <zone> --workers agy:3 [--coord claude] [--task "…"]` launches a
  coordinator and N workers in one step; the coordinator receives its team and the objective, and can
  grow its own team. `swarm stop <zone>` closes a team.
- **Dynamic cockpit**: one pane per team member (coordinator large on the left) plus the live bus;
  rebuilt automatically when agents join or leave. `cockpit <zone|session>`.
- **Navigation inside tmux**: `Alt+a` agent picker (teams, state, model, quota), `Alt+c` cockpit ⇄
  agent, `Ctrl+b n/p` next/previous agent; tappable `◂ MENU · ☰ AGENTES · ▦ COCKPIT` status-bar
  buttons (tmux ≥ 3.3).
- TUI: sessions grouped as teams, `s` new-team wizard, cockpit action with team picker; restart keeps
  the conversation.
- One-line installer (`curl … | bash`, per-user without root) and `prama-agent update [version]`.
- NOTICE, CITATION.cff and author information.

### Changed
- The swarm submenu was replaced by "Nuevo equipo" and "Cockpit"; `bus swarm-start` remains as a
  compatibility alias.
- `make install` without `sudo` installs for the current user.

## [6.0.0] - 2026-10-30

A rewrite focused on safety, determinism and fleet management.

### Added
- **Fleet API** (`prama-agent fleet`): `status`, `spawn`, `kill`, `model`, `edit`, `restart`,
  `presets`, `models`, `watchdog`, `hooks`, with JSON output and guard rails for agents (scope,
  maximum size, never itself, never a coordinator).
- **Agent health**: Claude Code hooks injected per session with `--settings`; Antigravity hooks through
  a named entry in `~/.gemini/config/hooks.json`. New `BLOCKED` state with a reason (`login`, `auth`,
  `credit`, `limit`, `trust`, `model`); screen detection as a fallback.
- **Quota telemetry** from the agents' status lines: 5-hour and weekly usage, reset times, context
  usage and cost, in `fleet status`, the TUI and JSON.
- **Watchdog** session: alerts coordinators and Telegram on blocked, stopped and recovered agents and
  on quota above `PRAMA_QUOTA_WARN`; delivers queued tasks when an agent is ready.
- **In-place restarts**: model, effort, preset or permission changes relaunch the agent in the same
  pane and resume the same conversation (`--resume` for Claude Code, `--conversation` for agy).
- **Presets**: reusable agent profiles with model, effort, role, prompt and a skills folder mounted as
  a plugin.
- Display-width-aware UI engine, responsive full-screen TUI, cockpit view.
- Telegram bot with one-time pairing and argument whitelists.
- OpenCode integration, **experimental** and off by default (`PRAMA_EXPERIMENTAL=1`).
- Bilingual documentation (English and Spanish), architecture guide and roadmap.

### Changed
- prama runs on its **own tmux server** (`tmux -L prama`) and never touches the user's tmux or
  `~/.tmux.conf`.
- All state moved to `~/.local/state/prama-agent` (mode `0700`); state files are data, never sourced.
- Permissions default to **ASK**; YOLO is opt-in.
- Provider secrets are applied inside the pane and never appear on a command line.

### Removed
- Kimi CLI, Gemini CLI and Qwen CLI agents.

### Fixed
- Stopping a session now terminates its whole process group, so agents that ignore `SIGHUP` (agy)
  are not left running orphaned.
- Exact tmux targets everywhere: `stop prama-claude` can no longer close `prama-claude-backend`.

### Security
- Removed the world-writable `/tmp/prama-bus` used by v5 (`doctor` cleans it up).

## [5.0.0]

Initial public release: double-buffered TUI, swarm wizard and Telegram bot.
