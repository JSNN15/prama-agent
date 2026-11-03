#!/usr/bin/env bash
# lib/demo.sh — `prama-agent demo`: try prama in a minute, with simulated agents
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# A sandbox under $PRAMA_STATE_HOME/demo with its own tmux server (prama-demo), state, config and
# HOME, and a small git repository as its only zone. The agents are simulated: copies of bash named
# claude and agy that plan, delegate, commit and report through the real prama commands, so the
# cockpit, the plan board, the bus, the worktrees, the test-gated merges and the assistant are the
# real ones. Nothing of the real fleet, the real agent CLIs, ~/.claude or ~/.gemini is touched, and no
# tokens are spent.
#
#   prama-agent demo [start]   build it (from scratch) and open its cockpit
#   prama-agent demo attach    open its cockpit again
#   prama-agent demo stop      close it and delete the sandbox

DEMO_SOCKET=${PRAMA_DEMO_SOCKET:-prama-demo}

demo_root() { printf '%s/demo' "$PRAMA_STATE_HOME"; }

subcmd_demo() {
  case "${1:-start}" in
    start|run)      _demo_start ;;
    attach|open)    _demo_running || die "$(_t "The demo is not running: prama-agent demo")"
                    _demo_env "$SELF_PATH" cockpit shop; _demo_after ;;
    stop|clean)     _demo_stop; ok "$(_t 'Demo closed and its sandbox deleted.')" ;;
    help|-h|--help) _demo_usage ;;
    *)              _demo_usage >&2; return 1 ;;
  esac
}

_demo_usage() {
  printf '%s\n' "$(_t 'Usage: prama-agent demo [start|attach|stop]   simulated agents in a sandbox: no tokens, no real fleet touched')"
}

_demo_running() { tmux -L "$DEMO_SOCKET" has-session 2>/dev/null; }

# Runs a command inside the sandbox: its own tmux server, state, config and HOME (agy's hooks and
# Claude's settings land there), the simulated CLIs first in PATH, the host's /etc config ignored.
_demo_env() {
  local r; r=$(demo_root)
  env -u PRAMA_SESSION -u PRAMA_BUS_DIR -u PRAMA_TMUX_CONF -u PRAMA_ROLE -u PRAMA_PARENT -u PRAMA_TEAM \
    HOME="$r/home" XDG_CONFIG_HOME="$r/home/.config" XDG_STATE_HOME="$r/home/.local/state" \
    PRAMA_STATE_HOME="$r/state" PRAMA_TMUX_SOCKET="$DEMO_SOCKET" PRAMA_SYSTEM_CONFIG_DIR="$r/no-system-config" \
    PATH="$r/bin:$PATH" PRAMA_LANG="${PRAMA_UI_LANG:-en}" PRAMA_THEME="${PRAMA_THEME:-midnight}" \
    PRAMA_HOOKS=0 PRAMA_STATUSLINE=0 PRAMA_SKIP_PERMISSIONS=0 PRAMA_EXPERIMENTAL=0 PRAMA_DEFAULT_REMOTE=0 \
    PRAMA_WATCHDOG=1 PRAMA_WATCH_INTERVAL=2 PRAMA_SEND_DELAY=0.2 PRAMA_SWARM_ISOLATE=1 PRAMA_DEMO=1 "$@"
}

_demo_stop() {
  local r; r=$(demo_root)
  tmux -L "$DEMO_SOCKET" kill-server 2>/dev/null || true
  # Only ever a directory this module built (it carries the marker).
  if [ -f "$r/.prama-demo" ] && [ "${r%/demo}" = "$PRAMA_STATE_HOME" ]; then rm -rf -- "$r"; fi
  return 0
}

_demo_start() {
  local r a bash_bin
  r=$(demo_root)
  command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || die "$(_t 'The demo needs git and jq.')"
  _demo_stop
  ensure_private_dir "$r"
  : > "$r/.prama-demo"
  mkdir -p "$r/bin" "$r/interp" "$r/home/.config/prama-agent" "$r/state" "$r/repos/shop"
  # Simulated CLIs. The interpreter is a copy of bash named like the agent: prama tells agents from
  # plain shells by process name.
  bash_bin=$(command -v bash)
  for a in claude agy; do
    cp "$bash_bin" "$r/interp/$a"
    { printf '#!%s\n' "$r/interp/$a"; _demo_agent_script; } > "$r/bin/$a"
    chmod +x "$r/bin/$a"
  done
  printf '#!/bin/sh\nexec %q "$@"\n' "$SELF_PATH" > "$r/bin/prama-agent"; chmod +x "$r/bin/prama-agent"
  _demo_repo "$r/repos/shop"
  info_msg "$(_t 'Building the demo sandbox in %s (simulated agents: no tokens are spent).' "$r")"
  _demo_env "$SELF_PATH" zones add shop "$r/repos/shop" "Demo shop" >/dev/null || die "$(_t 'Could not create the demo zone.')"
  _demo_env "$SELF_PATH" swarm shop --workers claude:1,agy:1 --task "$(_t 'Add a /health endpoint and document the API')" --no-open \
    || die "$(_t 'Could not start the demo team.')"
  printf '\n %s\n %s\n\n' "$(_t 'Watch the coordinator plan and delegate, the executors commit on their own branches and report, and the merges run the tests.')" \
    "$(_t 'An assistant for you appears too (★ in the status bar, Alt+o). Alt+m leaves; prama-agent demo stop deletes it all.')"
  if [ -t 0 ] && [ -t 1 ]; then
    sleep 1
    _demo_env "$SELF_PATH" cockpit shop
    _demo_after
  else
    info_msg "$(_t 'Open it with: prama-agent demo attach')"
  fi
}

_demo_after() {
  _demo_running && info_msg "$(_t 'The demo keeps running: prama-agent demo attach to go back, prama-agent demo stop to delete it.')"
  return 0
}

# A tiny project: a CLI, its test and a README. The executors add to it on their own branches.
_demo_repo() {
  local d=$1
  git -C "$d" init -q -b main
  git -C "$d" config user.name "prama demo"
  git -C "$d" config user.email "demo@prama.invalid"
  mkdir -p "$d/src" "$d/tests"
  printf '# shop\n\nA demo project for prama-agent.\n' > "$d/README.md"
  printf '#!/bin/sh\n# shop CLI: sh src/app.sh <command>\ncase "$1" in\n  health) sh "$(dirname "$0")/health.sh" ;;\n  *) echo "usage: sh src/app.sh health" ;;\nesac\n' > "$d/src/app.sh"
  printf '#!/bin/sh\n# The suite: the CLI runs, and /health answers OK once it exists.\nsh src/app.sh >/dev/null || exit 1\nif [ -f src/health.sh ]; then [ "$(sh src/health.sh)" = OK ] || { echo "FAIL health"; exit 1; }; fi\necho "tests: all passed"\n' > "$d/tests/run.sh"
  git -C "$d" add . && git -C "$d" commit -qm "shop: CLI and tests"
}

# The simulated agent (one script for both CLIs). prama's runner exports PRAMA_SESSION and PRAMA_ROLE;
# the agent answers to what reaches its prompt, like a real one, and acts through prama's commands.
_demo_agent_script() {
  cat <<'EOF'
me=${PRAMA_SESSION:-agent} role=${PRAMA_ROLE:-executor} lang=${PRAMA_LANG:-en}
say() { if [ "$lang" = es ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
work() { local i; for (( i = 1; i <= $1; i++ )); do printf '\r✻ Working… (esc to interrupt) %ds ' "$i"; sleep 1; done; printf '\r\033[K'; }
prompt() { printf '\n❯ '; }
stty -echo 2>/dev/null
say "✻ $(basename "$0") · simulated agent of the prama demo (no model, no tokens)" \
    "✻ $(basename "$0") · agente simulado de la demo de prama (sin modelo, sin tokens)"
case $role in
  coordinator)
    merged=0
    prompt
    while IFS= read -r line; do
      printf '%s\n' "← ${line:0:160}"
      case $line in
        *"[PRAMA]"*)
          say "● Planning the objective: three tasks, two executors in parallel, one review." \
              "● Planifico el objetivo: tres tareas, dos ejecutores en paralelo y una revisión."
          work 3
          mapfile -t ex < <(prama-agent fleet status --json | jq -r --arg c "$me" '.[] | select(.parent==$c and .role=="executor") | .session')
          if [ "$lang" = es ]; then
            prama-agent plan add "Agregar GET /health" --est 15m --scope "src/health.sh" --accept "sh tests/run.sh"
            prama-agent plan add "Documentar la API" --est 10m --scope "docs/**" --accept "sh tests/run.sh"
            prama-agent plan add "Revisar e integrar" --deps T1,T2 --est 5m
            prama-agent bus assign "${ex[0]}" "Crea src/health.sh que imprima OK y haz commit" --task T1
            prama-agent bus assign "${ex[1]:-${ex[0]}}" "Escribe docs/API.md (GET /health) y haz commit" --task T2
            prama-agent fleet spawn claude shop --role assistant --name guia --brief "Ayuda al operador a usar la CLI de la tienda (sh src/app.sh). Solo lectura: los cambios van al coordinador." --plan
          else
            prama-agent plan add "Add GET /health" --est 15m --scope "src/health.sh" --accept "sh tests/run.sh"
            prama-agent plan add "Document the API" --est 10m --scope "docs/**" --accept "sh tests/run.sh"
            prama-agent plan add "Review and merge" --deps T1,T2 --est 5m
            prama-agent bus assign "${ex[0]}" "Create src/health.sh printing OK and commit it" --task T1
            prama-agent bus assign "${ex[1]:-${ex[0]}}" "Write docs/API.md (GET /health) and commit it" --task T2
            prama-agent fleet spawn claude shop --role assistant --name guide --brief "Help the operator use the shop's CLI (sh src/app.sh). Read-only: changes go to the coordinator." --plan
          fi ;;
        *"[REPORT FROM "*|*"[REPORTE DE "*)
          who=$(sed -E 's/.*\[(REPORT FROM|REPORTE DE) ([^]]+)\].*/\2/' <<< "$line")
          t=$(grep -oE '\[T[0-9]+\]' <<< "$line" | head -n 1 | tr -d '[]')
          say "● Reviewing $who's branch, then merging it with the tests." \
              "● Reviso la rama de $who y la integro con los tests."
          work 2
          prama-agent worktree merge "$who" --test "sh tests/run.sh" && [ -n "$t" ] && prama-agent plan verify "$t" --done --yes
          merged=$(( merged + 1 ))
          if (( merged == 2 )); then
            prama-agent plan start T3 >/dev/null 2>&1
            prama-agent plan "done" T3 --evidence "$(git log -1 --format=%h): sh tests/run.sh — tests: all passed"
            if [ "$lang" = es ]; then prama-agent memory add "Demo: /health y docs/API.md integrados en main con los tests en verde."
            else prama-agent memory add "Demo: /health and docs/API.md merged into main with the tests green."; fi
            say "✔ Objective done: both branches merged, tests green, plan closed with evidence." \
                "✔ Objetivo listo: ambas ramas integradas, tests en verde, plan cerrado con evidencia."
          fi ;;
      esac
      prompt
    done ;;
  assistant)
    say "★ I work for you. Ask me how to use the shop's CLI (sh src/app.sh): a real assistant would answer here." \
        "★ Trabajo para ti. Pregúntame cómo usar la CLI de la tienda (sh src/app.sh): aquí respondería un asistente real."
    prompt
    while IFS= read -r line; do
      printf '%s\n' "← ${line:0:160}"
      case $line in \[*) prompt; continue ;; esac
      work 2
      say "(simulated) Try: sh src/app.sh health. What needs the team, I send to the coordinator with prama-agent bus report." \
          "(simulado) Prueba: sh src/app.sh health. Lo que necesita al equipo se lo envío al coordinador con prama-agent bus report."
      prompt
    done ;;
  *)
    prompt
    while IFS= read -r line; do
      printf '%s\n' "← ${line:0:160}"
      case $line in
        *"[TASK FROM "*|*"[TAREA DE "*)
          t=$(grep -oE '\[T[0-9]+\]' <<< "$line" | head -n 1 | tr -d '[]')
          say "● On it ($t): editing, then the tests, then a commit." "● En eso ($t): edito, corro los tests y hago commit."
          work $(( 5 + RANDOM % 5 ))
          case $t in
            T1) printf '#!/bin/sh\necho OK\n' > src/health.sh ;;
            T2) mkdir -p docs; printf '# shop API\n\nGET /health → OK\n' > docs/API.md ;;
            *)  printf '%s\n' "$line" >> NOTES.md ;;
          esac
          sh tests/run.sh && git add -A && git commit -qm "$t: ${line##*: }" \
            && prama-agent bus report "$(git log -1 --format=%h) on $(git rev-parse --abbrev-ref HEAD): sh tests/run.sh passes" ${t:+--task "$t"} ;;
      esac
      prompt
    done ;;
esac
EOF
}
