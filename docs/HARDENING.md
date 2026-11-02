# Running prama-agent on a shared or production host

**English** · [Español](HARDENING.es.md)

prama-agent was built on a server its author owns, running agents in YOLO mode on purpose. That is a
choice for a machine you control. On a host that also runs production services, holds credentials or
belongs to an organization with rules about AI tools, set it up as described here.

## What prama protects, and what it does not

prama's rules between agents (an agent cannot act on itself or on a coordinator, stays in its zone and
team, cannot merge unless it is the team's coordinator, cannot give another agent more permissions than
it has) are **guard rails against mistakes**. They are not a security boundary.

- **The caller is identified by process, and that is still the same Unix user.** When a command runs
  under an agent's pane, prama takes the pane's session as the caller, whatever `PRAMA_SESSION` says,
  so `env -u PRAMA_SESSION prama-agent fleet kill …` no longer makes an agent the operator, and the
  attempt is logged as an `identity` event. But every agent runs as your user and can read and write
  prama's state files, kill processes or detach itself from its pane. An agent that is trying to get
  around prama (one that read a malicious file and follows it, for example) can.
- **Messages between agents are typed into their terminals.** Tasks and reports reach an agent as text
  in its prompt. A report is what another agent wrote: an agent that read a hostile file can pass its
  instructions on to the coordinator. Coordinators are told to treat reports as data, which lowers the
  risk; it does not remove it.
- **An agent can do what your user can do.** If your user is in the `docker`, `sudo` or `lxd` group, an
  agent effectively has root. If your user can read `~/.pgpass` or a secrets folder, so can the agent.

Real isolation comes from the operating system: a dedicated user, a container or a VM.

## Checklist

1. **A dedicated Unix user** for prama and its agents, outside the `docker`, `sudo` and `lxd` groups,
   without access to credentials it does not need (`~/.pgpass`, secrets folders, cloud keys). A VM is
   better still.
2. **Zones that point to clones**, never to folders mounted into running services. With hot reload, a
   local merge into such a folder is an instant deploy.
3. **Pull requests instead of local merges**: `PRAMA_MERGE_MODE=pr` makes `worktree merge` push the
   branch and open a pull request against the team's base (it needs `gh`, signed in), so your CI and
   your review decide. The zone's checkout is never written.
4. **No YOLO on this host**: `PRAMA_ALLOW_YOLO=0` refuses `--yolo` everywhere (CLI, menu, fleet API,
   restarts of agents saved as yolo) and overrides `PRAMA_SKIP_PERMISSIONS=1`.
5. **Only the providers you are allowed to use**: list the agents in `AGENTS=(claude)`, leave
   `PRAMA_EXPERIMENTAL` unset (opencode talks to OpenRouter) and set `PRAMA_PROFILES="default"` so no
   agent can be pointed at another endpoint (OpenRouter, DeepSeek, GLM). Free tiers often keep prompts
   or train on them: never send code you may not share.
6. **Telegram without screens**, or no Telegram: `PRAMA_TG_SCREENS=0` keeps agent screens (which can
   show credentials or customer data) on the host, and `PRAMA_TG_NOTIFY=alerts` sends only alerts, not
   the text of tasks and reports.
7. **Do not share dependency folders between worktrees** on this host: leave `PRAMA_WORKTREE_LINK`
   unset. One agent's `pip install` or `npm install` would change every other agent's environment. Keep
   an eye on disk space: each executor of an isolated team has its own worktree.
8. **Pin a version**: `prama-agent update v6.7.0` checks out that tag; `update` with no version follows
   the branch you are on.
9. **Ask first.** If your organization has a policy for AI coding tools or for the providers they talk
   to, a tool that launches many agents needs that approval too.

## A hardened `config.env`

```bash
# Agents and providers
AGENTS=(claude)
PRAMA_PROFILES="default"          # only the agents' own accounts, no third-party endpoints
# PRAMA_EXPERIMENTAL is left unset

# Permissions
PRAMA_ALLOW_YOLO=0                # nothing runs without confirmations, whatever the default
PRAMA_SKIP_PERMISSIONS=0
PRAMA_FLEET_SCOPE="children"      # a coordinator manages only the agents it launched
PRAMA_FLEET_MAX=4

# Integration through your CI, never into a live folder
PRAMA_MERGE_MODE="pr"
PRAMA_MERGE_TEST="make test"      # used only by local merges
# PRAMA_WORKTREE_LINK is left unset

# Telegram, if used at all
PRAMA_TG_SCREENS=0
PRAMA_TG_NOTIFY="alerts"
```

Check the result with `prama-agent doctor`, and report anything that gets past these settings as
described in [SECURITY.md](../SECURITY.md).
