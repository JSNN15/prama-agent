#!/usr/bin/env bash
# lib/worktrees.sh — Isolated teams: one git worktree and branch per worker, and their integration
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# In an isolated team (swarm --isolate, PRAMA_SWARM_ISOLATE=1) each executor works in its own git
# worktree on branch prama/<team>/<name>, created from the branch the zone's checkout is on (BASE,
# stored on the coordinator). The coordinator stays in the zone's directory on BASE and integrates:
#   worktree status   ahead/behind BASE, uncommitted files, last commit of every worker branch
#   worktree merge    merges a worker branch into BASE, one at a time per repository (aborts on
#                     conflict; with tests, BASE only ever receives a merge that passed them)
#   worktree sync     merges BASE into a worker branch (keeps it current after other merges)
#   worktree clean    removes worktrees that are clean and fully merged (also on swarm stop)
# Unmerged or uncommitted work is never deleted.

# team_isolated <coordinator> → 0 when the team uses worktrees
team_isolated() { [ "$(state_get "$1" ISOLATE 0)" = 1 ]; }

# team_base <coordinator> → the integration branch of the team
team_base() {
  local b
  b=$(state_get "$1" BASE)
  [ -n "$b" ] || b=$(git -C "$(zone_dir "$(state_get "$1" ZONE)")" symbolic-ref --short -q HEAD 2>/dev/null)
  printf '%s' "${b:-main}"
}

# git_can_isolate <dir> → 0 when <dir> is a git checkout with at least one commit on a branch
git_can_isolate() {
  git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1 && git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1
}

# _wt_ident <dir> → WT_ID: git -c flags giving merge commits an author when the repository has
# no identity configured (a fresh server or container); empty when it has one.
_wt_ident() {
  WT_ID=()
  if [ -z "$(git -C "$1" config user.email 2>/dev/null)" ] && [ -z "${GIT_COMMITTER_EMAIL:-}" ]; then
    WT_ID=(-c user.name=prama-agent -c user.email=prama-agent@localhost)
  fi
}

# worker_branch <team> <session> [base-name] → prama/<team>/<short name>
worker_branch() {
  local team=$1 s=$2 base=${3:-} short
  if [ -n "$base" ] && [[ $s == "$base-"* ]]; then short=${s#"$base-"}
  else short=${s#"${PRAMA_SESSION_PREFIX}"-}; fi
  printf 'prama/%s/%s' "$team" "$(slugify "$short")"
}

# _wt_members <coordinator> → WT_S WT_B WT_D (sessions with a worktree, their branch and directory).
# Workers already closed (fleet kill) keep their worktree and branch: git lists them, under the
# team's branch prefix (prama/<team>/), with the branch as their name.
_wt_members() {
  local c=$1 s b line d='' dir
  WT_S=() WT_B=() WT_D=()
  local -A have=()
  while IFS= read -r s; do
    [ "$(state_get "$s" PARENT)" = "$c" ] || continue
    b=$(state_get "$s" WORKTREE)
    [ -n "$b" ] || continue
    WT_S+=("$s") WT_B+=("$b") WT_D+=("$(state_get "$s" TARGET_DIR)"); have[$b]=1
  done < <(prama_sessions)
  dir=$(zone_dir "$(state_get "$c" ZONE)" 2>/dev/null) || return 0
  local prefix
  prefix="refs/heads/prama/$(team_name "$c")/"
  while IFS= read -r line; do
    case $line in
      'worktree '*) d=${line#worktree } ;;
      "branch $prefix"*)
        b=${line#branch refs/heads/}
        [ -n "${have[$b]:-}" ] && continue
        WT_S+=("$b") WT_B+=("$b") WT_D+=("$d"); have[$b]=1 ;;
    esac
  done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)
  return 0
}

# _wt_dirty <dir> → number of uncommitted files, without the links PRAMA_WORKTREE_LINK put there
# (a symlinked node_modules is not work).
_wt_dirty() {
  local f n=0 line skip
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    skip=0
    for f in ${PRAMA_WORKTREE_LINK:-}; do
      [ "$line" = "?? $f" ] && [ -L "$1/$f" ] && skip=1
    done
    (( skip )) || n=$(( n + 1 ))
  done < <(git -C "$1" status --porcelain 2>/dev/null)
  printf '%d' "$n"
}

# _wt_resolve_coord [<zone>|<coordinator>|<worker>] [--team T] → WT_COORD (an agent: its own team)
_wt_resolve_coord() {
  local arg=${1:-} team=${2:-} m
  WT_COORD=''
  if [ -z "$arg" ] && [ -n "${PRAMA_SESSION:-}" ]; then arg=$PRAMA_SESSION; fi
  [ -n "$arg" ] || die "$(_t 'Which team? Give a zone (--team T), a coordinator or a worker session.')"
  if valid_session_name "$arg" && [ -f "$(state_file "$arg")" ]; then
    if [ "$(session_role "$arg")" = coordinator ]; then WT_COORD=$arg
    else WT_COORD=$(session_team "$arg") || die "$(_t "'%s' does not belong to a team." "$arg")"; fi
  else
    m=$(match_zone "$arg") || die "$(_t "Unknown zone or session: '%s'" "$arg")"
    if [ -n "$team" ]; then WT_COORD=$(find_team "$m" "$team") || die "$(_t "There is no team \"%s\" in '%s'." "$team" "$m")"
    else
      local -a cs=()
      mapfile -t cs < <(zone_teams "$m")
      (( ${#cs[@]} == 1 )) || die "$(_t "Zone '%s' has %d teams: give --team <name>." "$m" "${#cs[@]}")"
      WT_COORD=${cs[0]}
    fi
  fi
  [ -n "$WT_COORD" ] || die "$(_t 'Team not found.')"
}

# _wt_authorize <coordinator> — an agent may act only on its own team (operator: anything)
_wt_authorize() {
  [ -n "${PRAMA_SESSION:-}" ] || return 0
  local own
  if [ "$(session_role "$PRAMA_SESSION")" = coordinator ]; then own=$PRAMA_SESSION
  else own=$(session_team "$PRAMA_SESSION") || own=''; fi
  [ "$own" = "$1" ] || die "$(_t "'%s' is another team's; you can only act on your own." "$1")"
}

# worktree status [<zone>|<session>] [--team T] [--json]
wt_status() {
  local arg='' team='' json=0 i dir base ab ahead behind dirty last first=1
  while (( $# )); do
    case $1 in
      --team|-T) team=${2:?}; shift 2 ;;
      --json) json=1; shift ;;
      *) arg=$1; shift ;;
    esac
  done
  _wt_resolve_coord "$arg" "$team"
  dir=$(zone_dir "$(state_get "$WT_COORD" ZONE)")
  base=$(team_base "$WT_COORD")
  _wt_members "$WT_COORD"
  if (( json )); then printf '['; fi
  if (( ! json )); then
    printf ' %s%s%s\n' "$C_BOLD" "$(_t 'Team %s · integration branch %s' "$(team_label "$WT_COORD")" "$base")" "$C_OFF"
    team_isolated "$WT_COORD" || printf ' %s%s%s\n' "$C_MUTED" "$(_t '(shared folder: the workers of this team have no worktrees)')" "$C_OFF"
  fi
  for i in "${!WT_S[@]}"; do
    ab=$(git -C "$dir" rev-list --left-right --count "$base...${WT_B[i]}" 2>/dev/null) || ab='0 0'
    behind=${ab%%[[:space:]]*} ahead=${ab##*[[:space:]]}
    dirty=$(_wt_dirty "${WT_D[i]}")
    # "--": a branch named like a file of the repository (guia) is still the branch.
    last=$(git -C "$dir" log -1 --format='%h %s (%cr)' "${WT_B[i]}" -- 2>/dev/null)
    if (( json )); then
      (( first )) || printf ','
      first=0
      printf '{"session":"%s","branch":"%s","dir":"%s","base":"%s","ahead":%d,"behind":%d,"uncommitted":%d,"last":"%s"}' \
        "$(json_escape "${WT_S[i]}")" "$(json_escape "${WT_B[i]}")" "$(json_escape "${WT_D[i]}")" "$(json_escape "$base")" \
        "${ahead:-0}" "${behind:-0}" "${dirty:-0}" "$(json_escape "$last")"
    else
      local mark="$C_MUTED·$C_OFF" note=''
      (( ahead > 0 )) && { mark="$C_LIVE↑$C_OFF"; note=$(_t '%d commit(s) to merge' "$ahead"); }
      (( dirty > 0 )) && note+="${note:+ · }$(_t '%d uncommitted' "$dirty")"
      (( behind > 0 )) && note+="${note:+ · }$(_t '%d behind %s' "$behind" "$base")"
      [ -n "$note" ] || note=$(_t 'up to date')
      printf ' %s %-30s %-34s %s\n     %s%s%s\n' "$mark" "${WT_S[i]}" "${WT_B[i]}" "$note" "$C_MUTED" "$last" "$C_OFF"
    fi
  done
  if (( json )); then printf ']\n'
  elif (( ${#WT_S[@]} == 0 )); then printf ' %s\n' "$(_t '(no worker worktrees)')"
  else printf '\n %s\n' "$(_t 'Review: git diff %s...<branch> · integrate: prama-agent worktree merge <session>' "$base")"
  fi
}

# _wt_worker <session> → WT_W (session) WT_WB (branch) WT_WD (dir) WT_COORD
_wt_worker() {
  local s=${1:-} c i
  [ -n "$s" ] || s=${PRAMA_SESSION:-}
  # A closed worker is named by its branch (prama/<team>/<name>, as worktree status lists it).
  if [[ "$s" == prama/*/* ]]; then
    while IFS= read -r c; do
      [ "$(state_get "$c" ZONE)" ] || continue
      _wt_members "$c"
      for i in "${!WT_B[@]}"; do
        [ "${WT_B[i]}" = "$s" ] && { WT_W=$s WT_WB=$s WT_WD=${WT_D[i]} WT_COORD=$c; return 0; }
      done
    done < <(prama_sessions | while IFS= read -r c; do [ "$(session_role "$c")" = coordinator ] && printf '%s\n' "$c"; done)
    die "$(_t "No live team has a worktree on branch '%s'." "$s")"
  fi
  [ -n "$s" ] && valid_session_name "$s" && [ -f "$(state_file "$s")" ] || die "$(_t "Unknown session: '%s'" "$s")"
  WT_W=$s WT_WB=$(state_get "$s" WORKTREE) WT_WD=$(state_get "$s" TARGET_DIR)
  [ -n "$WT_WB" ] || die "$(_t "'%s' has no worktree (shared folder)." "$s")"
  WT_COORD=$(session_team "$s") || die "$(_t "'%s' does not belong to a team." "$s")"
}

# worktree merge <worker session> [--keep-conflicts] — merges its branch into the team's base,
# in the zone's checkout. The checkout must be clean and on the base branch.
# _wt_common_dir <checkout> → the repository's git directory, the same from any of its worktrees
_wt_common_dir() { ( cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P ); }

# _wt_free <command…> — exec, in a subshell, without the merge lock: something started by a git hook or
# by the tests could outlive the merge and hold the lock for the next one.
_wt_free() {
  [ -z "${WT_LOCK:-}" ] || exec {WT_LOCK}>&-
  exec "$@"
}

# _wt_merge_lock <checkout> — merges into a repository run one at a time, tests included: two at once
# test and land over each other. It is held until this process ends or closes WT_LOCK.
_wt_merge_lock() {
  local common
  command -v flock >/dev/null 2>&1 || return 0
  common=$(_wt_common_dir "$1")
  [ -n "$common" ] || die "$(_t 'Could not read the current commit of %s.' "$1")"
  exec {WT_LOCK}>"$common/prama-merge.lock" || die "$(_t 'Could not lock the merges of %s.' "$1")"
  flock -n "$WT_LOCK" && return 0
  info_msg "$(_t 'Another merge is running in this repository: waiting for it.')"
  flock -w $(( ${PRAMA_MERGE_TEST_TIMEOUT:-1800} + 120 )) "$WT_LOCK" \
    || die "$(_t 'Another merge of %s did not finish in time: nothing was merged.' "$1")"
}

# _wt_integration <checkout> <commit> → WT_IT: the repository's integration worktree, at <commit>.
# It stays between merges: what the tests need and git ignores (node_modules, .venv, caches) is there
# for the next one. Everything else goes, because an old file can stop a merge or pass a test.
# PRAMA_WORKTREE_LINK does not apply here: a linked node_modules can point into the base's own packages,
# and the tests would pass on the code from before the merge.
_wt_integration() {
  local dir=$1 at=$2 f out
  WT_IT="${PRAMA_WORKTREE_ROOT:-$(dirname "$dir")/.prama-worktrees}/$(basename "$dir")/.integration"
  if [ -e "$WT_IT" ]; then
    [ "$(_wt_common_dir "$WT_IT")" = "$(_wt_common_dir "$dir")" ] \
      && [ "$(cd "$WT_IT" && git rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$WT_IT" && pwd -P)" ] \
      || { warn "$(_t '%s exists and is not a worktree of this repository.' "$WT_IT")"; return 1; }
  else
    git -C "$dir" worktree prune >/dev/null 2>&1
    mkdir -p "$(dirname "$WT_IT")" || return 1
    out=$(git -C "$dir" worktree add -q --detach "$WT_IT" "$at" 2>&1) || { warn "$out"; return 1; }
  fi
  git -C "$WT_IT" merge --abort >/dev/null 2>&1
  out=$( { git -C "$WT_IT" checkout -q --force --detach "$at" && git -C "$WT_IT" reset -q --hard "$at" \
           && git -C "$WT_IT" clean -fdq; } 2>&1 ) || { warn "$out"; return 1; }
  for f in $PRAMA_WORKTREE_COPY_FILES; do
    if [ -f "$dir/$f" ]; then cp -p "$dir/$f" "$WT_IT/$f" && chmod 600 "$WT_IT/$f" 2>/dev/null; fi
  done
  return 0
}

# _wt_run_bounded <dir> <log> <command> [seconds] → its exit code. A limited time (by default
# PRAMA_MERGE_TEST_TIMEOUT), and nothing it started in the background outlives it (it would write into
# the next merge's tree, and hold the log open). `timeout` leads its own process group, so the whole
# group can be ended.
_wt_run_bounded() {
  local dir=$1 log=$2 cmd=$3 limit=${4:-${PRAMA_MERGE_TEST_TIMEOUT:-1800}} pid rc=0
  (
    cd "$dir" && _wt_free timeout -k 5 "$limit" bash -c "$cmd"
  ) >"$log" 2>&1 </dev/null &
  pid=$!
  # shellcheck disable=SC2064  # the pid is meant to be expanded now
  trap "kill -TERM -- -$pid 2>/dev/null; exit 130" HUP INT TERM
  wait "$pid" || rc=$?
  trap - HUP INT TERM
  kill -KILL -- "-$pid" 2>/dev/null
  return "$rc"
}

# _wt_merge_test <checkout> <base> <test> — tests the merge waiting in WT_IT and lands it: the base and
# its checkout only move, by fast-forward, to the commit that was tested. A failure leaves them as they
# were and the worktree as the tests left it, to look at. Tests run in the same folder of the repository
# as the zone (a zone can be a subfolder).
_wt_merge_test() {
  local dir=$1 base=$2 test=$3 log="$WT_IT.log" rc=0 tip out cur branch
  branch=$(git -C "$dir" rev-parse --short "$WT_WB" 2>/dev/null)
  tip=$(git -C "$WT_IT" rev-parse HEAD)
  # Before spending the tests: would the checkout accept the result?
  out=$(git -C "$dir" read-tree -n -u -m HEAD "$tip" 2>&1) \
    || die "$(_t 'The result of merging %s would overwrite files in %s, so the tests were not run: %s' "$WT_WB" "$dir" "${out:0:200}")"
  info_msg "$(_t 'Running the tests: %s' "$test")"
  _wt_run_bounded "$WT_IT/$(git -C "$dir" rev-parse --show-prefix)" "$log" "$test" || rc=$?
  if (( rc )); then
    plan_merge_hook "$WT_COORD" "$WT_WB" "$branch" "$rc" "$test"
    bus_event conflict "${PRAMA_SESSION:-operator}" "$WT_W" "tests failed on a merge of $WT_WB (rc=$rc)"
    tail -n 25 "$log" >&2
    die "$(_t 'The tests failed on the merge of %s (code %d): %s did not change. Full output: %s. They ran in %s: if something they need is not there (dependencies), install it there once; otherwise send the failure to %s.' "$WT_WB" "$rc" "$base" "$log" "$WT_IT" "$WT_W")"
  fi
  ok "$(_t 'Tests passed.')"
  [ "$(git -C "$WT_IT" rev-parse HEAD)" = "$tip" ] \
    || die "$(_t 'The tests moved the commit of %s: nothing landed, because what they checked is not what would land.' "$WT_IT")"
  cur=$(git -C "$dir" symbolic-ref --short -q HEAD)
  [ "$cur" = "$base" ] \
    || die "$(_t "The zone's checkout moved to '%s' while the tests ran: nothing landed in %s, merge again." "$cur" "$base")"
  out=$(_wt_free git -C "$dir" merge -q --ff-only "$tip" 2>&1) \
    || die "$(_t 'The tests passed, but %s could not move to the result (did it change while they ran?): nothing landed, merge again. %s' "$base" "${out:0:200}")"
  plan_merge_hook "$WT_COORD" "$WT_WB" "$branch" 0 "$test"
}

wt_merge() {
  local s='' keep=0 dir base cur out conflicts test=${PRAMA_MERGE_TEST:-} mode=${PRAMA_MERGE_MODE:-local}
  while (( $# )); do
    case $1 in
      --keep-conflicts) keep=1; shift ;;
      --pr) mode="pr"; shift ;;
      --local) mode=local; shift ;;
      --test) test=${2:?$(_t '--test requires a command')}; shift 2 ;;
      --no-test) test=''; shift ;;
      *) s=$1; shift ;;
    esac
  done
  [ -n "$s" ] || die "$(_t 'Usage: prama-agent worktree merge <worker session> [--test "<command>"] [--keep-conflicts] [--pr|--local]')"
  _wt_worker "$s"
  # Integrating into the base is the coordinator's job (or the operator's), never an executor's.
  if [ -n "${PRAMA_SESSION:-}" ] && [ "$PRAMA_SESSION" != "$WT_COORD" ]; then
    die "$(_t 'Only the coordinator of the team (%s) merges into the base branch.' "$WT_COORD")"
  fi
  dir=$(zone_dir "$(state_get "$WT_COORD" ZONE)")
  base=$(team_base "$WT_COORD")
  if [ "$mode" = pr ]; then _wt_merge_pr "$base"; return; fi
  _wt_merge_lock "$dir"
  cur=$(git -C "$dir" symbolic-ref --short -q HEAD)
  [ "$cur" = "$base" ] || die "$(_t "The zone's checkout is on '%s', not on the team's base '%s': switch it first (git -C %s switch %s)." "$cur" "$base" "$dir" "$base")"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] \
    || die "$(_t 'The checkout of %s has uncommitted changes: commit or stash them before merging.' "$dir")"
  ! git -C "$dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    || die "$(_t 'A merge is in progress in %s: finish it (git commit) or abort it (git merge --abort) first.' "$dir")"
  local dirty pre tree=$dir
  dirty=$(_wt_dirty "$WT_WD")
  (( dirty > 0 )) && warn "$(_t '%s has %d uncommitted file(s); only its commits are merged.' "$WT_W" "$dirty")"
  if [ -z "$(git -C "$dir" rev-list "$base..$WT_WB" 2>/dev/null)" ]; then
    info_msg "$(_t 'Nothing to merge: %s has no commits that %s lacks.' "$WT_WB" "$base")"; return 0
  fi
  _wt_ident "$dir"
  pre=$(git -C "$dir" rev-parse HEAD) || die "$(_t 'Could not read the current commit of %s.' "$dir")"
  # With tests, the merge is made and tried apart from the base's checkout.
  if [ -n "$test" ]; then
    _wt_integration "$dir" "$pre" || die "$(_t 'Could not prepare the integration worktree of %s.' "$dir")"
    tree=$WT_IT
  fi
  if out=$(_wt_free git -C "$tree" "${WT_ID[@]}" merge --no-ff --no-edit -m "Merge $WT_WB (prama: $WT_W)" "$WT_WB" 2>&1); then
    [ -z "$test" ] || _wt_merge_test "$dir" "$base" "$test"
    [ -n "$test" ] || plan_merge_hook "$WT_COORD" "$WT_WB" "$(git -C "$dir" rev-parse --short "$WT_WB" 2>/dev/null)" '' ''
    bus_event merged "${PRAMA_SESSION:-operator}" "$WT_W" "$WT_WB → $base${test:+ (tested)}"
    ok "$(_t 'Merged %s into %s.' "$WT_WB" "$base")"
    [ -z "${WT_LOCK:-}" ] || exec {WT_LOCK}>&-
    _wt_others_behind "$WT_COORD" "$WT_W"
    return 0
  fi
  conflicts=$(git -C "$tree" diff --name-only --diff-filter=U 2>/dev/null | paste -sd' ')
  if [ -n "$conflicts" ] && (( keep )); then
    if [ "$tree" != "$dir" ]; then
      git -C "$tree" merge --abort >/dev/null 2>&1 || true
      tree=$dir
      out=$(_wt_free git -C "$dir" "${WT_ID[@]}" merge --no-ff --no-edit -m "Merge $WT_WB (prama: $WT_W)" "$WT_WB" 2>&1)
    fi
    # An untracked file, for one, can stop git in the checkout before it opens any merge.
    if git -C "$dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      warn "$(_t 'Conflicts left in %s for you to resolve (then git commit): %s' "$dir" "$conflicts")"
      return 1
    fi
    conflicts=''
  fi
  git -C "$tree" merge --abort >/dev/null 2>&1 || true
  bus_event conflict "${PRAMA_SESSION:-operator}" "$WT_W" "$WT_WB → $base: $conflicts"
  die "$(_t 'Merge of %s aborted, %s is unchanged. Conflicts: %s. Ask %s to run prama-agent worktree sync (merges %s into its branch), resolve them and commit; then merge again.' "$WT_WB" "$base" "${conflicts:-${out:0:200}}" "$WT_W" "$base")"
}

# PRAMA_MERGE_MODE=pr (or --pr): the branch is pushed and a pull request opened against the base,
# so the zone's checkout is never written and the repository's CI and review decide. Use it when
# the zone folder is live (mounted into a running service) or when main is protected.
_wt_merge_pr() {
  local base=$1 remote=${PRAMA_MERGE_REMOTE:-origin} out url title body dirty
  command -v gh >/dev/null 2>&1 || die "$(_t 'PRAMA_MERGE_MODE=pr needs the GitHub CLI (gh), signed in.')"
  if [ -z "$(git -C "$WT_WD" rev-list "$base..$WT_WB" 2>/dev/null)" ]; then
    info_msg "$(_t 'Nothing to merge: %s has no commits that %s lacks.' "$WT_WB" "$base")"; return 0
  fi
  dirty=$(_wt_dirty "$WT_WD")
  (( dirty > 0 )) && warn "$(_t '%s has %d uncommitted file(s); only its commits are merged.' "$WT_W" "$dirty")"
  out=$(git -C "$WT_WD" push -u "$remote" "$WT_WB" 2>&1) \
    || die "$(_t 'Could not push %s to %s: %s' "$WT_WB" "$remote" "${out:0:300}")"
  # Only an OPEN pull request is reused (gh pr view <branch> also finds closed and merged ones).
  if url=$(cd "$WT_WD" && gh pr list --head "$WT_WB" --state open --json url --jq '.[0].url // empty' 2>/dev/null) && [ -n "$url" ]; then
    ok "$(_t 'Pull request already open, now updated: %s' "$url")"
  else
    title="$WT_WB (prama: $WT_W)"
    body="$(git -C "$WT_WD" log --reverse --format='- %s' "$base..$WT_WB" 2>/dev/null)

Opened by \`prama-agent worktree merge\` (PRAMA_MERGE_MODE=pr): CI and review decide the merge."
    url=$(cd "$WT_WD" && gh pr create --base "$base" --head "$WT_WB" --title "$title" --body "$body" 2>&1) \
      || die "$(_t 'Could not open the pull request: %s' "${url:0:300}")"
    url=${url##*$'\n'}
    ok "$(_t 'Pull request opened: %s' "$url")"
  fi
  bus_event merged "${PRAMA_SESSION:-operator}" "$WT_W" "$WT_WB → $base (PR $url)"
  return 0
}

# After a merge, tell which other workers are now behind the base.
_wt_others_behind() {
  local c=$1 merged=$2 i dir base n
  dir=$(zone_dir "$(state_get "$c" ZONE)") base=$(team_base "$c")
  _wt_members "$c"
  for i in "${!WT_S[@]}"; do
    [ "${WT_S[i]}" = "$merged" ] && continue
    n=$(git -C "$dir" rev-list --count "${WT_B[i]}..$base" 2>/dev/null || echo 0)
    (( n > 0 )) && info_msg "$(_t '%s is %d commit(s) behind %s: prama-agent worktree sync %s' "${WT_S[i]}" "$n" "$base" "${WT_S[i]}")"
  done
  return 0
}

# worktree sync [<worker session>] — merges the team's base into the worker's branch. Run by the
# worker itself, conflicts are left for it to resolve; run by anyone else, they are aborted.
wt_sync() {
  local s=${1:-} base out conflicts self=0
  _wt_worker "$s"
  _wt_authorize "$WT_COORD"
  [ "${PRAMA_SESSION:-}" = "$WT_W" ] && self=1
  if [ -n "${PRAMA_SESSION:-}" ] && (( ! self )) && [ "$PRAMA_SESSION" != "$WT_COORD" ]; then
    die "$(_t "Only %s itself or its coordinator can sync its branch." "$WT_W")"
  fi
  base=$(team_base "$WT_COORD")
  # A merge already open holds resolutions nobody has committed: running another would lose them.
  if git -C "$WT_WD" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    (( self )) && die "$(_t 'A merge is already in progress in your worktree: resolve what is left and finish it with git commit. Nothing was touched.')"
    die "$(_t '%s has a merge in progress: it has to finish it first.' "$WT_W")"
  fi
  if (( ! self )) && [ -n "$(git -C "$WT_WD" status --porcelain --untracked-files=no)" ]; then
    die "$(_t '%s has uncommitted changes: ask it to commit and run prama-agent worktree sync itself.' "$WT_W")"
  fi
  _wt_ident "$WT_WD"
  if out=$(git -C "$WT_WD" "${WT_ID[@]}" merge --no-edit "$base" 2>&1); then
    bus_event synced "${PRAMA_SESSION:-operator}" "$WT_W" "$base → $WT_WB"
    ok "$(_t '%s is up to date with %s.' "$WT_WB" "$base")"
    return 0
  fi
  conflicts=$(git -C "$WT_WD" diff --name-only --diff-filter=U 2>/dev/null | paste -sd' ')
  if (( self )) && [ -n "$conflicts" ]; then
    warn "$(_t 'Conflicts to resolve in your worktree (then git add + git commit): %s' "$conflicts")"
    return 1
  fi
  git -C "$WT_WD" merge --abort >/dev/null 2>&1 || true
  die "$(_t 'Sync of %s aborted (conflicts: %s); the worker has to run it and resolve them.' "$WT_W" "${conflicts:-${out:0:200}}")"
}

# wt_clean_team <coordinator> [include_live:0|1] — removes worktrees (and branches) that are clean
# and fully merged into the base; keeps and lists the rest. Live sessions are skipped unless asked.
wt_clean_team() {
  local c=$1 live=${2:-0} dir base i kept=0 removed=0
  dir=$(zone_dir "$(state_get "$c" ZONE)") base=$(team_base "$c")
  _wt_members "$c"
  for i in "${!WT_S[@]}"; do
    (( live )) || ! { valid_session_name "${WT_S[i]}" && tmx_has "${WT_S[i]}"; } || continue
    _wt_clean_one "$dir" "$base" "${WT_B[i]}" "${WT_D[i]}" && removed=$(( removed + 1 )) || kept=$(( kept + 1 ))
  done
  (( removed )) && ok "$(_t '%d merged worktree(s) removed.' "$removed")"
  return 0
}

# _wt_clean_one <repo> <base> <branch> <dir> → 0 removed, 1 kept (with a message)
_wt_clean_one() {
  local dir=$1 base=$2 b=$3 d=$4 head
  if [ -d "$d" ] && (( $(_wt_dirty "$d") > 0 )); then
    warn "$(_t 'Kept %s: uncommitted changes in %s.' "$b" "$d")"; return 1
  fi
  # What is merged is decided on what exists: the recorded branch (it may have been renamed or
  # deleted) and the worktree's own HEAD (it may be detached, or on another branch).
  if git -C "$dir" rev-parse -q --verify "refs/heads/$b" >/dev/null 2>&1; then
    if [ -n "$(git -C "$dir" rev-list "$base..refs/heads/$b" -- 2>/dev/null)" ]; then
      warn "$(_t 'Kept %s: it has commits not merged into %s (prama-agent worktree merge, or delete it by hand).' "$b" "$base")"; return 1
    fi
  elif [ ! -d "$d" ]; then
    return 1   # neither the branch nor the worktree: nothing to clean
  fi
  if [ -d "$d" ]; then
    head=$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null) || head=''
    if [ -z "$head" ] || [ -n "$(git -C "$dir" rev-list "$base..$head" -- 2>/dev/null)" ]; then
      warn "$(_t 'Kept %s: its worktree %s holds commits not merged into %s.' "$b" "$d" "$base")"; return 1
    fi
    git -C "$dir" worktree remove "$d" >/dev/null 2>&1 \
      || { warn "$(_t 'Kept %s: git could not remove the worktree %s.' "$b" "$d")"; return 1; }
  fi
  git -C "$dir" branch -d "$b" >/dev/null 2>&1 || true
  return 0
}

# Captured before swarm stop removes the state: the team's worktrees, to clean them afterwards.
# wt_snapshot_team <coordinator> → WT_SNAP ("repo|base|branch|dir" lines)
wt_snapshot_team() {
  local c=$1 dir base i
  WT_SNAP=()
  dir=$(zone_dir "$(state_get "$c" ZONE)" 2>/dev/null) || return 0
  base=$(team_base "$c")
  _wt_members "$c"
  for i in "${!WT_S[@]}"; do WT_SNAP+=("$dir|$base|${WT_B[i]}|${WT_D[i]}"); done
}

wt_clean_snapshot() {
  local line dir base b d removed=0
  for line in "${WT_SNAP[@]}"; do
    IFS='|' read -r dir base b d <<< "$line"
    _wt_clean_one "$dir" "$base" "$b" "$d" && removed=$(( removed + 1 ))
  done
  (( removed )) && ok "$(_t '%d merged worktree(s) removed.' "$removed")"
  return 0
}
