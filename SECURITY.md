# Security policy

**English** · [Español](#español)

prama-agent drives coding agents that can run commands on your machine, so security reports are taken
seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/JSNN15/prama-agent/security/advisories/new) and
include the version (`prama-agent --version`), the steps to reproduce and the impact. You should get a
first answer within a week.

## Scope

In scope: command injection through session names, zones, task text or Telegram messages; state or
queue files being executed; secrets exposed on a command line or in world-readable files; prama acting
on tmux sessions or processes it does not own; secrets reaching a feedback report unredacted.

Also in scope: a way around the host policy (`PRAMA_ALLOW_YOLO=0`, `PRAMA_PROFILES`,
`PRAMA_TG_SCREENS=0`) or around the permission ceiling (an agent giving another more permissions than
it has) that does not need the agent to edit prama's files or leave its pane.

Out of scope: what an agent does once you run it in YOLO mode (`--yolo`), and vulnerabilities in the
agent CLIs themselves (report those to their vendors).

## Security model

The rules between agents are guard rails against mistakes, not a security boundary: every agent runs
as your Unix user and can read prama's state and the user's credentials. prama identifies the caller
by the pane it runs under, keeps permissions from growing from agent to agent and enforces the host
policy; containing a hostile or manipulated agent takes a separate user, a container or a VM. How to
set prama up on a shared or production host: [docs/HARDENING.md](docs/HARDENING.md).

The design invariants that prama must uphold are listed in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security-invariants).

## Español

prama-agent controla agentes que pueden ejecutar comandos en tu máquina, así que los reportes de
seguridad se atienden con prioridad. **No** abras un issue público: usa el
[reporte privado de vulnerabilidades](https://github.com/JSNN15/prama-agent/security/advisories/new)
de GitHub con la versión, los pasos para reproducir y el impacto. Recibirás una primera respuesta en
menos de una semana.

Las reglas entre agentes son barandas contra errores, no una barrera de seguridad: todos los agentes
corren con tu usuario Unix. Para usar prama en un servidor compartido o de producción, ver
[docs/HARDENING.es.md](docs/HARDENING.es.md).
