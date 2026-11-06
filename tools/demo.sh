#!/usr/bin/env bash
# tools/demo.sh — renders the README demo (docs/img/demo-<lang>.gif), ~35 s: a team starts, its plan
# fills, a "done" without evidence is flagged and prama runs the task's check itself (it fails: the
# task is reopened), a silent agent is flagged and the alert reaches the phone, a merge that breaks
# the tests is undone. Every screen is real prama output, captured from the demo fleet of
# tools/screenshots.sh; tools/demo_gif.py lays out the frames and writes the GIF.
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
# Needs: tmux, git, script (util-linux), python3 with Pillow, chromium. Usage: tools/demo.sh [en|es|all]
set -euo pipefail
SHOTS_LIB=1
# shellcheck source=tools/screenshots.sh
source "$(dirname "${BASH_SOURCE[0]}")/screenshots.sh"
python3 -c 'import PIL' 2>/dev/null || { echo "python3 Pillow not found (apt install python3-pil)" >&2; exit 1; }

demo_repo() {   # the backend repo again, with a test the demo merge is going to break
  local r="$WORK/repos/backend"
  rm -rf "$r" "$WORK/repos/.prama-worktrees"
  mkdir -p "$r/src/auth" "$r/tests"
  git -C "$r" init -q -b main
  echo "# backend" > "$r/README.md"
  printf 'def active_key(ring):\n    return ring[-1]   # the newest key signs\n' > "$r/src/auth/keys.py"
  cat > "$r/tests/run.sh" <<'EOF'
#!/bin/sh
if grep -q 'ring\[0\]' src/auth/keys.py; then
  echo "FAILED tests/auth/test_keys.py::test_rotation - signed with the oldest key"
  echo "1 failed, 13 passed in 0.41s"; exit 1
fi
echo "14 passed in 0.39s"
EOF
  git -C "$r" add . && git -C "$r" commit -qm "auth: key ring"
}

cap() {   # cap <name> <cols> <rows> <command>: a full-screen view, captured with its colors
  local name=$1 cols=$2 rows=$3 cmd=$4
  tmux -L "$UI" kill-server 2>/dev/null || true
  sleep 0.5
  tmux -L "$UI" -f /dev/null new-session -d -x "$cols" -y "$rows" \
    "env HOSTNAME=server-01 PRAMA_LANG=$PRAMA_LANG COLORTERM=truecolor TERM=xterm-256color bash -c '$cmd; sleep 60'"
  sleep 3
  tmux -L "$UI" capture-pane -p -e > "$D/$name.ansi"
}

for L in $LANGS; do
  echo "== demo $L"
  D="$WORK/demo-$L"; rm -rf "$D"; mkdir -p "$D"
  demo_repo
  DEMO_REC="$D/swarm.ansi" fleet "$L"
  C=prama-backend-sec-coord P="$BIN"
  cap board 104 15 "$P plan backend --team sec watch"
  # agy's branch: a commit that signs with the oldest key; T2's acceptance check is the test suite.
  wt=$(git -C "$WORK/repos/backend" worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/prama\/sec\/agy$/{print w}')
  sed -i 's/ring\[-1\]/ring[0]/' "$wt/src/auth/keys.py"
  git -C "$wt" commit -qam "auth: rotate keys daily"
  PRAMA_SESSION=$C "$P" plan set T2 check="sh tests/run.sh" >/dev/null 2>&1
  # T2: "done", no evidence; then prama runs the check itself.
  PRAMA_SESSION=$C _tty "$D/done.ansi" "$P" plan "done" T2
  cap board-unverified 104 15 "$P plan backend --team sec watch"
  PRAMA_SESSION=$C _tty "$D/verify.ansi" "$P" plan verify T2
  # T4's owner has been silent: with a 0-minute threshold the board shows it as the watchdog sees it.
  cap board-stale 104 15 "PRAMA_PLAN_STALE_MIN=0 $P plan backend --team sec watch"
  # The watchdog's message, as Telegram receives it (same template, 20-minute threshold).
  if [ "$L" = es ]; then t4="Rate limiting en /login"; else t4="Rate limiting on /login"; fi
  bash -c 'source "$1/lib/core.sh"; prama_init >/dev/null
    printf "📋 backend · sec\n"; _t "[PRAMA] Plan: %s (\"%s\", %s) has shown no activity for over %d min. Check it (prama-agent logs %s) and update the plan." T4 "$2" prama-backend-sec-agy-2 20 prama-backend-sec-agy-2 | sed "s/^\[PRAMA\] //"; echo
    _t "👥 Team"; echo; _t "💬 Talk"; echo' _ "$REPO" "$t4" > "$D/alert.txt"
  _tty "$D/merge.ansi" "$P" worktree merge prama-backend-sec-agy --test "sh tests/run.sh"
  _tty "$D/gitlog.ansi" git -C "$WORK/repos/backend" log --oneline -1
  python3 "$REPO/tools/demo_gif.py" "$L" "$D" "$OUT/demo-$L.gif" "$CHROME"
done
