# How prama-agent was built

**English** · [Español](HOW-IT-WAS-BUILT.es.md)

prama-agent was written with AI coding agents, and lately by teams of agents that prama-agent itself
was running. The history says so: most commits carry a `Co-Authored-By: Claude` trailer. This page
explains who did what, how the work was checked, and what broke along the way.

## Why it exists

I build **pramatic**, a product with several repositories (platform, landing page, monitoring) that I
develop with coding agents on a remote server, often from a phone. prama-agent started as the scripts
that kept those agents alive. Each feature came from a problem I hit while doing that work:

| Problem | Feature |
| --- | --- |
| An SSH drop killed the agents | a dedicated tmux server; sessions survive (v6.0) |
| An agent sat for an hour on a login prompt or a usage limit | health from the CLI's hooks, BLOCKED with a reason, queued work (v6.0) |
| The weekly quota ran out mid-task | quota telemetry and an alert at 90 % (v6.0) |
| One coordinator could not hold several workstreams | several teams per zone (v6.3) |
| Agents in one folder overwrote each other | a git worktree and branch per agent, with a test-gated merge (v6.5) |
| I had to keep asking the coordinator what it was doing | the live plan (v6.6) |
| "Done" turned out to mean "I think so" | `plan verify`: prama runs the task's check itself (v6.7) |

## Who did what

**Me:** what to build and in which order, the constraints, the design calls, review, and the decision
to release. The constraints have not changed since v6:

- persistence: an agent's session outlives my connection;
- survive SSH drops;
- determinism: exact tmux targets, state as data, nothing typed into an agent that is not ready;
- the scrollback is never lost.

I asked for research before designing the plan, from papers and from practitioners' repositories and
forums. Two findings shaped it: pre-assigned tasks beat agents coordinating themselves, and most
multi-agent failures are specification and verification failures.

**The agents:** most of the code, the tests and the documentation, under those constraints. Claude
Code sessions did most of it. From v6.4 on, the work was also split across teams that prama-agent
ran. The Spanish translation of the interface, for example, was split across four agents in parallel,
each on its own git worktree. The tool also runs real work on pramatic: a prama team took a pramatic
work package to production while v6.6 was being written.

**What the agents are not trusted with:**
- They cannot merge into `main`. Every change goes through a pull request, and `main` is protected:
  required checks, linear history, no force pushes, rules enforced for admins too.
- They cannot publish. Bug reports that agents file stay on the server, and turning one into a GitHub
  issue is an explicit step I take.

## How it was checked

- **About 270 end-to-end checks** run on an isolated tmux server, with a private HOME and state. They
  use mock agents whose process names are `claude` and `agy`. There are also 31 unit tests for the
  Telegram bot.
- **CI** runs the suite on Ubuntu 22.04, Debian 12 and Ubuntu 24.04 (tmux 3.2a, 3.3a and 3.4), as an
  unprivileged user whose login shell is `/bin/sh`. CI also runs shellcheck, actionlint, CodeQL and
  OpenSSF Scorecard. Actions are pinned by commit SHA.
- **Translations** are checked in lint by `tools/i18n_check.py`: missing entries, mismatched
  placeholders and dynamic message ids.
- **The screenshots and the demo** are rendered from a real demo fleet (`make screenshots`,
  `make demo`), not drawn by hand.

## What broke

- **Reading the screen was not enough.** An agent that *quoted* an error message in its answer was
  marked BLOCKED (`f310bf8`). Since then, the hooks decide BLOCKED, and the screen only counts dialogs
  that appear before the hooks run.
- **Portability.** A screen filter that worked with gawk failed with mawk, Debian's default awk
  (`74ef686`). The CI matrix exists because of bugs like this.
- **Authorization gaps found in review.** Before v6.5 shipped, an executor could merge *another*
  executor's branch. Now only the coordinator or the operator merges.
- **Bash's evaluation order.** In `local i=$1 st=${P_status[i]}`, the second assignment expands before
  the first one exists. That put plan tasks in the wrong board columns. The tests caught it before the
  release.
- **A release tag on the wrong commit.** A CodeQL review thread silently blocked the v6.6.0 merge, and
  the tag went onto the previous commit. The release workflow failed safe and nothing was published.
  The tag was redone. The release steps now confirm the merge before tagging.
- **The README promised more than the code did.** A pre-launch audit compared every claim with the
  source and found two gaps. First, the hooks decide *blocked*, but *idle* versus *working* still comes
  from the screen. Second, "unverified" only meant that nobody had written any evidence, and that
  evidence was the agent's own text. The README now says exactly what the code does, and v6.7 added
  `plan verify` so that "checked" means prama ran the check itself.

## Numbers (v6.7.0)

| | |
| --- | --- |
| bash | ~11,000 lines in `bin/` and `lib/`, split into 17 modules |
| Python | the Telegram bridge (~1,300 lines) and the dev tools |
| Tests | ~270 end-to-end checks, 31 bot unit tests |
| Public history | v5.0.0 on 2026-10-28 to v6.7.0 on 2026-11-01. Versions before 5.0 were never published. |

The design decisions, with their costs and the alternatives, are in the [ADRs](adr/README.md).
