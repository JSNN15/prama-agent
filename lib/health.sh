#!/usr/bin/env bash
# lib/health.sh — Agent health: CLI hooks → health file, and the fleet watchdog
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# Public API (see docs/ARCHITECTURE.md):
#   hook_ingest <agent> [event]         read one hook JSON payload on stdin, update the health file
#   claude_hook_settings                print the path of the --settings file with prama's hooks
#   agy_hooks_ensure / agy_hooks_remove the named "prama-agent" hook in ~/.gemini/config/hooks.json
#   statusline_ingest <agent>           status line command: usage telemetry → quota file, prints a line
#   quota_label <session>               "5h 12% · 7d 40% · ctx 23%" (empty without fresh data)
#   watchdog_running / watchdog_ensure  the internal "<prefix>-watchdog" session
#   watchdog_loop                       body of that session (state transitions → bus/alerts)
#   deliver_to_session <s> <text>       inject when the agent can take text, else queue

# ── Hook payload parsing ────────────────────────────────────────────────────
# json_field <json> <key> → first string value of "key" (jq when available, regex fallback).
json_field() {
  local json=$1 key=$2
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.. | objects | select(has($k)) | .[$k] | select(type == "string" or type == "number")' \
      <<< "$json" 2>/dev/null | head -n 1
    return 0
  fi
  local re="\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  [[ "$json" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# Maps Claude Code StopFailure error codes to prama block reasons.
_hook_reason() {
  case "$1" in
    rate_limit|overloaded)                                        printf 'limit' ;;
    authentication_failed|oauth_org_not_allowed|cloud_credential_error) printf 'auth' ;;
    billing_error|account_on_hold)                                printf 'credit' ;;
    model_not_found)                                              printf 'model' ;;
    *)                                                            printf 'error' ;;
  esac
}

# hook_ingest <agent>   (stdin: hook JSON). Never fails and never prints: a hook must not
# disturb the agent. The session comes from $PRAMA_SESSION, exported by the pane supervisor.
hook_ingest() {
  local s=${PRAMA_SESSION:-} json ev
  valid_session_name "$s" || return 0
  json=$(head -c 65536)
  [ "${1:-}" = agy ] && { _hook_ingest_agy "$s" "${2:-}" "$json"; return 0; }
  ev=$(json_field "$json" hook_event_name)
  local sid model
  sid=$(json_field "$json" session_id)
  case "$ev" in
    SessionStart)
      model=$(json_field "$json" model)
      health_set "$s" HEALTH=ok REASON= DETAIL= ACTIVITY=idle "${sid:+AGENT_SID=$sid}" "${model:+MODEL=$model}" ;;
    UserPromptSubmit)
      health_set "$s" HEALTH=ok REASON= DETAIL= ACTIVITY=working "PROMPT_TS=${EPOCHSECONDS:-$(date +%s)}" "${sid:+AGENT_SID=$sid}" ;;
    Stop)
      health_set "$s" HEALTH=ok REASON= DETAIL= ACTIVITY=idle "${sid:+AGENT_SID=$sid}"
      watchdog_revive ;;
    StopFailure)
      local err det
      err=$(json_field "$json" error)
      det=$(json_field "$json" error_details)
      det=${det//[$'\n\r\t']/ }
      health_set "$s" HEALTH=blocked "REASON=$(_hook_reason "$err")" "DETAIL=${err}${det:+: ${det:0:160}}" \
        ACTIVITY=idle "${sid:+AGENT_SID=$sid}" ;;
    Notification)
      case "$(json_field "$json" notification_type)" in
        auth_success)  health_set "$s" HEALTH=ok REASON= DETAIL= ;;
        idle_prompt)   health_set "$s" ACTIVITY=idle ;;
        permission_prompt|elicitation_dialog|agent_needs_input)
          health_set "$s" ACTIVITY=waiting ;;
      esac ;;
    PostModelSwitch)
      model=$(json_field "$json" new_model)
      [ -n "$model" ] || model=$(json_field "$json" model)
      [ -n "$model" ] && health_set "$s" "MODEL=$model" ;;
    SessionEnd)
      health_set "$s" ACTIVITY=ended ;;
  esac
  return 0
}

# Antigravity (agy) hooks: camelCase payload without the event name, so it comes on argv.
# Stop reports why the loop ended; ERROR carries the error text (quota, credits, auth…).
_hook_ingest_agy() {
  local s=$1 ev=$2 json=$3 sid model
  sid=$(json_field "$json" conversationId)
  model=$(json_field "$json" modelName)
  [ "$model" = auto ] && model=''
  case "$ev" in
    SessionStart)
      health_set "$s" HEALTH=ok REASON= DETAIL= ACTIVITY=idle "${sid:+AGENT_SID=$sid}" "${model:+MODEL=$model}" ;;
    PreInvocation)
      health_set "$s" HEALTH=ok REASON= DETAIL= ACTIVITY=working "PROMPT_TS=${EPOCHSECONDS:-$(date +%s)}" "${sid:+AGENT_SID=$sid}" "${model:+MODEL=$model}" ;;
    Stop)
      local why err info
      why=$(json_field "$json" terminationReason)
      err=$(json_field "$json" error)
      err=${err//[$'\n\r\t']/ }
      if [ "$why" = ERROR ] || [ -n "$err" ]; then
        info=$(screen_block_reason "$err") || info="error|$err"
        health_set "$s" HEALTH=blocked "REASON=${info%%|*}" "DETAIL=${err:0:200}" ACTIVITY=idle "${sid:+AGENT_SID=$sid}"
      else
        health_set "$s" HEALTH=ok REASON= DETAIL= ACTIVITY=idle "${sid:+AGENT_SID=$sid}"
      fi
      watchdog_revive ;;
  esac
  return 0
}

# agy has no per-session hooks flag (--settings rejects "hooks"), so prama keeps one named hook
# in the user's global ~/.gemini/config/hooks.json. Outside prama panes ($PRAMA_SESSION unset) the
# command only prints "{}" and exits. Other hooks in the file are preserved.
agy_hooks_file() { printf '%s/.gemini/config/hooks.json' "$HOME"; }

_agy_hooks_spec() {
  local cmd ev out='' sep=''
  for ev in SessionStart PreInvocation Stop; do
    printf -v cmd '%q --internal-hook agy %s' "$SELF_PATH" "$ev"
    out+="$sep\"$ev\":[{\"type\":\"command\",\"command\":\"$(json_escape "$cmd")\",\"timeout\":10}]"
    sep=','
  done
  printf '{%s}' "$out"
}

agy_hooks_ensure() {
  (( ${PRAMA_HOOKS:-1} )) || return 0
  command -v jq >/dev/null 2>&1 || return 1
  local f spec cur new
  f=$(agy_hooks_file) spec=$(_agy_hooks_spec)
  [ -d "$HOME/.gemini" ] || return 0     # agy never ran here: nothing to hook into
  mkdir -p "${f%/*}" || return 1
  if [ -s "$f" ]; then
    cur=$(cat "$f") || return 1
    jq -e 'type == "object"' <<< "$cur" >/dev/null 2>&1 || return 1   # never touch a file we cannot parse
    jq -e --argjson spec "$spec" '.["prama-agent"] == $spec' <<< "$cur" >/dev/null 2>&1 && return 0
  else
    cur='{}'
  fi
  new=$(jq --argjson spec "$spec" '.["prama-agent"] = $spec' <<< "$cur") || return 1
  printf '%s\n' "$new" > "$f.prama.$$" && mv -f "$f.prama.$$" "$f"
}

agy_hooks_remove() {
  local f new
  f=$(agy_hooks_file)
  [ -s "$f" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -e 'has("prama-agent")' "$f" >/dev/null 2>&1 || return 0
  new=$(jq 'del(.["prama-agent"])' "$f") || return 1
  printf '%s\n' "$new" > "$f.prama.$$" && mv -f "$f.prama.$$" "$f"
}

agy_hooks_installed() {
  local f; f=$(agy_hooks_file)
  [ -s "$f" ] && jq -e --argjson spec "$(_agy_hooks_spec)" '.["prama-agent"] == $spec' "$f" >/dev/null 2>&1
}

# ── Status line telemetry ───────────────────────────────────────────────────
# Claude: rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}.
# agy: quota.<family>[-<model>…]-{5h,weekly}.{remaining_fraction,reset_in_seconds}, family "gemini"
# for Gemini models and "3p" for the others; a bucket with a model token (gemini-argon-wtu-weekly)
# only counts when the current model's name contains it. The most used bucket wins.
_SL_JQ='
def num: if type == "number" then round | tostring else "" end;
def cost: if type == "object" then .total_cost_usd elif type == "number" then . else null end
  | if type == "number" then (. * 100 | round / 100 | tostring) else "" end;
def bucket($q): if $q == null then {u: "", r: ""}
  else {u: ((1 - ($q.remaining_fraction // 1)) * 100 | num), r: (now + ($q.reset_in_seconds // 0) | num)} end;
def pick($quota; $f; $m; $w): [$quota | to_entries[]
  | select((.key | startswith($f + "-")) and (.key | endswith("-" + $w)))
  | ((.key | ltrimstr($f + "-") | rtrimstr($w) | rtrimstr("-") | split("-"))[0] // "") as $x
  | select($x == "" or ($m | contains($x))) | .value]
  | if length == 0 then null else max_by(1 - (.remaining_fraction // 1)) end;
(if .rate_limits then
   {h: {u: (.rate_limits.five_hour.used_percentage | num), r: (.rate_limits.five_hour.resets_at | num)},
    w: {u: (.rate_limits.seven_day.used_percentage | num), r: (.rate_limits.seven_day.resets_at | num)}}
 elif .quota then
   ((.model.id // "") | ascii_downcase) as $m
   | (if ($m | contains("gemini")) then "gemini" else "3p" end) as $f
   | {h: bucket(pick(.quota; $f; $m; "5h")), w: bucket(pick(.quota; $f; $m; "weekly"))}
 else {h: {u: "", r: ""}, w: {u: "", r: ""}} end) as $q
| "Q_5H=\($q.h.u)", "Q_5H_RESET=\($q.h.r)", "Q_7D=\($q.w.u)", "Q_7D_RESET=\($q.w.r)",
  "CTX=\(.context_window.used_percentage | num)", "COST=\(.cost | cost)",
  "Q_MODEL=\(.model.display_name // .model.id // "" | gsub("[\n=]"; " "))",
  "Q_PLAN=\(.plan_tier // "" | gsub("[\n=]"; " "))"
'

statusline_ingest() {
  local agent=$1 s=${PRAMA_SESSION:-} json now line kv=()
  json=$(head -c 262144)
  now=${EPOCHSECONDS:-$(date +%s)}
  valid_session_name "$s" || return 0
  if command -v jq >/dev/null 2>&1; then
    mapfile -t kv < <(jq -r "$_SL_JQ" <<< "$json" 2>/dev/null)
    if (( ${#kv[@]} )); then
      _kv_merge "$(quota_file "$s")" "$s" "${kv[@]}" "Q_TS=$now"
      local a=() x
      for x in "${kv[@]}"; do [[ "$x" =~ ^Q_(5H|7D)=[0-9] ]] && a+=("$x"); done
      if (( ${#a[@]} )); then
        a=(); for x in "${kv[@]}"; do [[ "$x" == Q_* ]] && a+=("$x"); done
        mkdir -p "$PRAMA_BUS_DIR/accounts"
        _kv_merge "$(account_quota_file "$agent" "$(state_get "$s" PROFILE default)")" "$s" "${a[@]}" "Q_TS=$now"
      fi
    fi
  fi
  local user_cmd="$PRAMA_STATE_HOME/hooks/user-statusline.cmd"
  if [ "$agent" = claude ] && [ -s "$user_cmd" ]; then
    # The user's own status line keeps working; prama only adds the telemetry.
    line=$(sh -c "$(cat "$user_cmd")" <<< "$json" 2>/dev/null | head -n 3)
  else
    local q; q=$(quota_label "$s")
    line="⚡ prama · $s${q:+ · $q}"
  fi
  printf '%s\n' "$line"
  # Single-line output is reused by the fast path (a chained multi-line status line is not).
  if [ -n "${PRAMA_SL_CACHE:-}" ]; then
    if [[ "$line" != *$'\n'* ]]; then printf '%s\n%s\n' "$now" "$line" > "$PRAMA_SL_CACHE" 2>/dev/null
    else rm -f "$PRAMA_SL_CACHE"; fi
  fi
  return 0
}

# _fmt_reset <epoch> → "18:40" within a day, "Fri 18:40" (es: "vie 18:40") later. The weekday
# comes from the interface language, not from the system locale.
_fmt_reset() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  local now=${EPOCHSECONDS:-$(date +%s)} d hm
  if (( $1 - now < 86400 )); then date -d "@$1" +%H:%M 2>/dev/null; return 0; fi
  read -r d hm < <(date -d "@$1" '+%u %H:%M' 2>/dev/null) || return 0
  case $d in
    1) _tv d 'Mon' ;; 2) _tv d 'Tue' ;; 3) _tv d 'Wed' ;; 4) _tv d 'Thu' ;;
    5) _tv d 'Fri' ;; 6) _tv d 'Sat' ;; 7) _tv d 'Sun' ;;
  esac
  printf '%s %s\n' "$d" "$hm"
}

quota_label() {
  local s=$1 q5 q7 ctx ts out='' r
  ts=$(quota_get "$s" Q_TS 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || return 0
  (( ${EPOCHSECONDS:-$(date +%s)} - ts < ${PRAMA_QUOTA_STALE:-3600} )) || return 0
  q5=$(quota_get "$s" Q_5H) q7=$(quota_get "$s" Q_7D) ctx=$(quota_get "$s" CTX)
  [[ "$q5" =~ ^[0-9]+$ ]] || q5=''
  if [ -n "$q5" ]; then
    out="5h $q5%"
    (( q5 >= ${PRAMA_QUOTA_WARN:-90} )) && r=$(_fmt_reset "$(quota_get "$s" Q_5H_RESET)") && out+=" ↺$r"
  fi
  [ -n "$q7" ] && out+="${out:+ · }7d $q7%"
  [ -n "$ctx" ] && out+="${out:+ · }ctx $ctx%"
  printf '%s' "$out"
}

# Writes (once per content change) the settings file passed to claude with --settings.
# It only adds hooks; claude merges them with the user's own settings and hooks.
claude_hook_settings() {
  local dir="$PRAMA_STATE_HOME/hooks" f cmd ev body='' sep=''
  ensure_private_dir "$dir" || return 1
  f="$dir/claude-settings.json"
  printf -v cmd '%q --internal-hook claude' "$SELF_PATH"
  cmd=$(json_escape "$cmd")
  for ev in SessionStart UserPromptSubmit Stop StopFailure Notification PostModelSwitch SessionEnd; do
    body+="$sep\"$ev\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\",\"timeout\":10}]}]"
    sep=','
  done
  body="\"hooks\":{$body}"
  if (( ${PRAMA_STATUSLINE:-1} )); then
    # --settings wins over ~/.claude/settings.json, so a user status line is chained, not lost.
    local sl user=''
    printf -v sl '%q --internal-statusline claude' "$SELF_PATH"
    body+=",\"statusLine\":{\"type\":\"command\",\"command\":\"$(json_escape "$sl")\",\"refreshInterval\":30}"
    command -v jq >/dev/null 2>&1 && user=$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)
    if [ -n "$user" ]; then printf '%s\n' "$user" > "$dir/user-statusline.cmd"; else rm -f "$dir/user-statusline.cmd"; fi
  fi
  body="{$body}"
  if [ ! -f "$f" ] || [ "$(cat "$f" 2>/dev/null)" != "$body" ]; then
    printf '%s\n' "$body" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  fi
  printf '%s' "$f"
}

# ── Delivery ────────────────────────────────────────────────────────────────
# deliver_to_session <session> <text> → 0 injected, 2 queued
deliver_to_session() {
  local s=$1 text=$2
  if bus_can_inject "$s" && tmx_send "$s" "${text//$'\n'/ }"; then return 0; fi
  queue_push "$s" "$text"
  return 2
}

# ── Watchdog ────────────────────────────────────────────────────────────────
watchdog_session() { printf "%s-watchdog" "$PRAMA_SESSION_PREFIX"; }

watchdog_running() { tmx_has "$(watchdog_session)"; }

# watchdog_revive — brings it back if it died: called when an agent ends a turn, the moment queued
# work and alerts matter. Not if the operator stopped it, or there is no server to run it in.
watchdog_revive() {
  (( ${PRAMA_WATCHDOG:-1} )) && [ ! -e "$PRAMA_BUS_DIR/watchdog.stopped" ] || return 0
  tmx_running && ! watchdog_running || return 0
  watchdog_ensure
}

watchdog_ensure() {
  (( ${PRAMA_WATCHDOG:-1} )) || [ "${1:-}" = force ] || return 0
  rm -f "$PRAMA_BUS_DIR/watchdog.stopped" 2>/dev/null
  watchdog_running && return 0
  ensure_tmux_conf
  local cmd
  # It restarts itself when it crashes. A clean exit (no agents left) ends the session, and so does not
  # finding the program (a moved install): the session must not look alive, or nothing would replace it.
  printf -v cmd 'while :; do %q --internal-watchdog; rc=$?; case $rc in 0|126|127) exit "$rc" ;; esac; sleep 5; done' "$SELF_PATH"
  tmx new-session -d -s "$(watchdog_session)" -x 120 -y 30 -e "PATH=$PATH" \
    ${XDG_CONFIG_HOME:+-e "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"} "$cmd" 2>/dev/null || return 1
}

# Coordinators that should hear about problems of <session>: its own team's coordinator when it
# has one (other teams of the zone are not told), otherwise the coordinators of its zone.
# A coordinator's own problems go to the operator only (Telegram): other teams are not told
# (invariant 14). An agent outside any team is reported to its zone's coordinator only when the
# zone has a single team, never to several.
_watch_coordinators() {
  local s=$1 zone c
  local -a cs=()
  if c=$(session_team "$s"); then
    [ "$c" != "$s" ] && printf '%s\n' "$c"
    return 0
  fi
  zone=$(state_get "$s" ZONE)
  [ -n "$zone" ] || return 0
  mapfile -t cs < <(zone_teams "$zone")
  (( ${#cs[@]} == 1 )) && [ "${cs[0]}" != "$s" ] && printf '%s\n' "${cs[0]}"
  return 0
}

_watch_alert() {
  local s=$1 text=$2 c
  while IFS= read -r c; do
    deliver_to_session "$c" "$text" || true
  done < <(_watch_coordinators "$s")
  declare -F telegram_notify >/dev/null && telegram_notify "$text" alert "$s"
  return 0
}

_watch_log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# _watch_limit_until <session> → the known reset holding it, kept in LIMIT_UNTIL; fails when none is known.
_watch_limit_until() {
  local s=$1 now=${EPOCHSECONDS:-$(date +%s)} until
  until=$(_limit_reset_at "$s" "$(health_get "$s" TS 0)" "$now") && (( until > now )) || return 1
  [ "$(state_get "$s" LIMIT_UNTIL)" = "$until" ] || state_set "$s" "LIMIT_UNTIL=$until"
  printf '%s' "$until"
}

# _watch_limit_over <session> <state> — the turn a limit stopped is not finished: at the reset it is told
# to carry on, ahead of what is queued. Not if it got going some other way (a restart, a prompt): that
# ends the hold too, whatever the time, with nothing to say.
_watch_limit_over() {
  local s=$1 st=$2 held prompted msg
  held=$(state_get "$s" LIMIT_UNTIL)
  [ -n "$held" ] || return 0
  state_set "$s" LIMIT_UNTIL=
  [[ "$held" =~ ^[0-9]+$ ]] && [ "$st" = READY ] && (( held <= ${EPOCHSECONDS:-$(date +%s)} )) || return 0
  prompted=$(health_get "$s" PROMPT_TS 0)
  [[ "$prompted" =~ ^[0-9]+$ ]] && (( prompted >= held )) && return 0
  _tv msg '[PRAMA] Your usage limit has reset. Carry on with what you were doing.'
  queue_push_front "$s" "$msg"
}

# One pass over the fleet. Uses the global associative arrays W_PREV and W_READY.
watchdog_tick() {
  local s st info reason detail prev key msg rank
  local -a attn=()
  declare -A seen=()
  declare -p W_WAIT >/dev/null 2>&1 || declare -gA W_WAIT=()
  declare -p W_ATTN >/dev/null 2>&1 || declare -gA W_ATTN=()
  while IFS= read -r s; do
    seen[$s]=1
    # With the pane's command: a supervisor that dropped to a plain shell is SHELL, never READY
    # (a queued task typed there would run as a shell command).
    st=$(bus_session_state "$s")
    info=''
    [ "$st" = BLOCKED ] && info=$(session_block_info "$s")
    reason=${info%%|*} detail=${info#*|}
    key="$st${reason:+:$reason}"
    prev=${W_PREV[$s]:-}

    if [ "$key" != "$prev" ]; then
      case "$st" in
        BLOCKED)
          _tv msg '▲ %s blocked (%s): %s' "$s" "$reason" "$detail"; _watch_log "$msg"
          bus_event blocked watchdog "$s" "$reason: $detail"
          # A quota block belongs to the account: 'fleet agents' shows it to whoever launches next.
          if [ "$reason" = limit ]; then
            mkdir -p "$PRAMA_BUS_DIR/accounts"
            _kv_merge "$(account_quota_file "$(state_get "$s" AGENT)" "$(state_get "$s" PROFILE default)")" "$s" \
              "BLOCKED_TS=${EPOCHSECONDS:-$(date +%s)}" "BLOCKED_DETAIL=${detail//=/ }"
            # When it is known, the agent is held until then, and carries on by itself afterwards.
            local until when
            if until=$(_watch_limit_until "$s"); then
              when=$(_fmt_reset "$until")
              _tv msg 'Usage limit of %s: held until %s.' "$s" "$when"; _watch_log "$msg"
              detail+=" · ↺$when"
            fi
          fi
          _tv msg "[PRAMA ALERT] '%s' is BLOCKED (%s): %s. Its tasks stay queued. Options: 'prama-agent fleet restart %s', 'prama-agent fleet model %s <model>', reassign with 'prama-agent bus assign', or tell the operator if it needs a manual login." \
            "$s" "$reason" "${detail:0:160}" "$s" "$s"
          _watch_alert "$s" "$msg" ;;
        STANDBY|DEAD)
          if [ -n "$prev" ]; then
            _tv msg '■ %s stopped (%s)' "$s" "$st"; _watch_log "$msg"
            bus_event stopped watchdog "$s" "$st"
            _tv msg "[PRAMA ALERT] '%s' stopped (%s). Relaunch it with 'prama-agent fleet restart %s' or close it with 'prama-agent fleet kill %s'." \
              "$s" "$st" "$s" "$s"
            _watch_alert "$s" "$msg"
          fi ;;
        READY|WORKING)
          if [[ "$prev" == BLOCKED* || "$prev" == STANDBY || "$prev" == DEAD ]]; then
            _tv msg '✔ %s recovered (%s)' "$s" "$st"; _watch_log "$msg"
            bus_event recovered watchdog "$s" "$st"
            _tv msg "[PRAMA] '%s' recovered and is %s." "$s" "$st"
            _watch_alert "$s" "$msg"
          fi ;;
      esac
      # Whatever the watchdog saw meanwhile, a limit that was holding this agent is settled now.
      case $st in READY|WORKING) _watch_limit_over "$s" "$st" ;; esac
      W_PREV[$s]=$key
      W_READY[$s]=0
    fi
    # The numbers can arrive after the block.
    [ "$key" != BLOCKED:limit ] || _watch_limit_until "$s" >/dev/null
    if rank=$(_attention_rank "$s" "$st" "$reason"); then attn+=("$rank $s $key"); fi

    # A dialog only a person can answer: told once, if it stays open (agents in ask mode hit many,
    # most are answered at once).
    if [ "$st" = WAITING ]; then
      local wnow=${EPOCHSECONDS:-$(date +%s)}
      [ -n "${W_WAIT[$s]:-}" ] || W_WAIT[$s]=$wnow
      if [ "${W_WAIT[$s]}" != told ] && (( wnow - W_WAIT[$s] >= ${PRAMA_WAIT_ALERT:-120} )); then
        W_WAIT[$s]=told
        _tv msg '? %s waits for an answer on its screen' "$s"; _watch_log "$msg"
        bus_event waiting watchdog "$s" "dialog"
        _tv msg "[PRAMA ALERT] '%s' is waiting for an answer on its screen (a permission or a question), and only a person can give it: prama-agent attach %s" "$s" "$s"
        _watch_alert "$s" "$msg"
        _watch_tell_terminals "$msg"
      fi
    else
      unset 'W_WAIT[$s]'
    fi

    # Queued work for interactive agents: deliver one task once the agent has been READY for
    # two consecutive ticks (avoids typing into a CLI that is still starting up).
    if [ "$st" = READY ] && [ "$(session_role "$s")" != daemon ]; then
      # A message prama pasted while the CLI was busy can stay in the prompt unsent: press Enter
      # for it, once, and only shortly after prama typed it (a paste of the operator's is theirs).
      # Someone typing in the session since then (attached or from the cockpit) owns that paste.
      local sent; sent=$(state_get "$s" SENT_TS)
      if [[ "$sent" =~ ^[0-9]+$ ]]; then
        if (( ${EPOCHSECONDS:-$(date +%s)} - sent < 120 )) && tmx_unsent_paste "$s" \
           && ! session_human_active "$s" $(( sent + 1 )); then
          tmx send-keys -t "=$s:" Enter 2>/dev/null
          _tv msg '→ %s: unsent message submitted' "$s"; _watch_log "$msg"
          W_READY[$s]=-1
        fi
        state_set "$s" SENT_TS=   # submitted, or not prama's to submit any more
      fi
      W_READY[$s]=$(( ${W_READY[$s]:-0} + 1 ))
      if (( W_READY[$s] >= 2 )) && (( $(queue_len "$s") > 0 )) && ! bus_operator_engaged "$s"; then
        local task
        if task=$(queue_pop "$s"); then
          [[ "$task" == \[* ]] || _tv task '[QUEUED TASK]: %s' "$task"
          if tmx_send "$s" "${task//$'\n'/ }"; then
            _tv msg '→ %s: queued task delivered' "$s"; _watch_log "$msg"
            bus_event assign watchdog "$s" "$task"
          else
            queue_push_front "$s" "$task"   # keeps its place in the queue
          fi
          W_READY[$s]=0
        fi
      fi
    else
      W_READY[$s]=0
    fi
    _watch_quota_collect "$s"
    _watch_snapshot "$s"
  done < <(prama_sessions)

  for s in "${!W_PREV[@]}"; do
    [ -n "${seen[$s]:-}" ] || unset 'W_PREV[$s]' 'W_READY[$s]'
  done
  _watch_attention ${attn[@]+"${attn[@]}"}
  _watch_closed
  # The assistant the status bar calls the operator to: gone, or already found by them.
  local wa
  wa=$(tmx show-options -gqv @prama_assist 2>/dev/null)
  if [ -n "$wa" ]; then
    if ! tmx_has "$wa" || session_human_active "$wa" 0; then
      tmx set-option -gu @prama_assist 2>/dev/null
    fi
  fi
  _watch_quota_alerts
  _watch_plans
}

# _attention_rank <session> <state> <block reason> → 1 a dialog, 2 a block a person has to clear,
# 3 stopped; fails when the session can move without the operator. A usage limit is left out while a
# coordinator that can act was told (a count that never goes down stops being read); with none, or one
# stopped by the same limit, nobody else will say the team is standing still. A stopped agent whose
# coordinator is running is that coordinator's to relaunch or close; an assistant is always the
# operator's.
_attention_rank() {
  local s=$1 st=$2 reason=${3:-} c
  case "$st" in
    WAITING) printf 1 ;;
    BLOCKED)
      if [ "$reason" = limit ] && [ "$(session_role "$s")" != assistant ]; then
        c=$(_watch_coordinators "$s")
        # W_PREV holds each session's state from this pass or the one before.
        case ${c:+${W_PREV[$c]:-}} in READY*|WORKING*|WAITING*) tmx_has "$c" && return 1 ;; esac
      fi
      printf 2 ;;
    DEAD|STANDBY)
      if [ "$(session_role "$s")" != assistant ]; then
        c=$(_watch_coordinators "$s")
        if [ -n "$c" ] && tmx_has "$c"; then return 1; fi
      fi
      printf 3 ;;
    *) return 1 ;;
  esac
}

# _watch_attention ["rank session key"...] — the status bar's ▲ and the key's list, as tmux options
# (written only when they change), and the bell on the operator's terminals. A session rings once when
# it starts needing them, at most one ring every PRAMA_TERMINAL_NOTIFY_GAP seconds (agents in ask mode
# open many dialogs). The watchdog's first pass only takes note: a restart rings for nothing.
_watch_attention() {
  local rank s key list='' msg skip='' n=0 now=${EPOCHSECONDS:-$(date +%s)}
  local -a fresh=()
  local -A live=()
  while read -r rank s key; do
    [ -n "$s" ] || continue
    list+="${list:+ }$s"; (( n++ ))
    [ "${W_ATTN[$s]:-}" = "$key" ] || fresh+=("$s")
    live[$s]=$key
  done < <( (( $# )) && printf '%s\n' "$@" | LC_ALL=C sort -k1,1 -k2,2 )
  W_ATTN=()
  for s in "${!live[@]}"; do W_ATTN[$s]=${live[$s]}; done
  if [ "$list" != "${W_ATTN_LIST- }" ]; then
    W_ATTN_LIST=$list
    if (( n )); then
      tmx set-option -g @prama_attention "$n" \; set-option -g @prama_attention_top "${list%% *}" \
        \; set-option -g @prama_attention_list "$list" 2>/dev/null
    else
      tmx set-option -gu @prama_attention \; set-option -gu @prama_attention_top \
        \; set-option -gu @prama_attention_list 2>/dev/null
    fi
  fi
  if (( ! ${W_ATTN_SEEDED:-0} )); then W_ATTN_SEEDED=1; return 0; fi
  (( ${#fresh[@]} )) || return 0
  (( now - ${W_RING_AT:-0} >= ${PRAMA_TERMINAL_NOTIFY_GAP:-30} )) || return 0
  if (( ${#fresh[@]} == 1 )); then skip=${fresh[0]}; _tv msg '▲ %s needs you' "$skip"
  else _tv msg '▲ %s agents need you' "${#fresh[@]}"; fi
  if terminal_notify "$msg" "$skip"; then W_RING_AT=$now; fi
  return 0
}

# Keeps the copy `restore` uses up to date, whatever code the session's own supervisor is running
# (it keeps the version it started with) and however it ends.
_watch_snapshot() {
  local s=$1 f d sid
  is_internal_session "$s" && return 0
  f=$(state_file "$s") d=$(closed_dir "$s")
  [ -f "$f" ] || return 0
  sid=$(health_get "$s" AGENT_SID)
  if [ ! -f "$d/spec.env" ] || [ "$f" -nt "$d/spec.env" ] \
     || { [ -n "$sid" ] && [ "$sid" != "$(_kv_get "$d/spec.env" AGENT_SID)" ]; }; then
    session_archive "$s"
  fi
  return 0
}

# A message on every terminal the operator has attached (not the cockpit's nested viewers).
_watch_tell_terminals() {
  local cl term
  while IFS='|' read -r cl term; do
    [ -n "$cl" ] && [[ "$term" != tmux* ]] && tmx display-message -c "$cl" "$1" 2>/dev/null
  done < <(tmx list-clients -F '#{client_name}|#{client_termname}' 2>/dev/null)
  return 0
}

# Sessions that ended and nobody closed through prama: told once, with the way back. Read from disk,
# so a watchdog restarted in the meantime still sees them.
_watch_closed() {
  local d s p msg now=${EPOCHSECONDS:-$(date +%s)}
  local -a gone=()
  [ -d "$PRAMA_BUS_DIR/closed" ] || return 0
  for d in "$PRAMA_BUS_DIR"/closed/*/; do
    [ -f "${d}spec.env" ] || continue
    s=${d%/}; s=${s##*/}
    [ -z "$(_kv_get "${d}meta" CLOSED)" ] || continue
    tmx_gone "$s" || continue
    state_remove "$s" vanished
    gone+=("$s")
    bus_event vanished watchdog "$s" "$(_kv_get "${d}spec.env" AGENT)@$(_kv_get "${d}spec.env" ZONE)"
    _tv msg '■ %s ended and nobody closed it through prama' "$s"; _watch_log "$msg"
    # Its coordinator, when it has one running (other teams are not told).
    p=$(_kv_get "${d}spec.env" PARENT)
    if [ -n "$p" ] && [ "$p" != operator ] && valid_session_name "$p" && tmx_has "$p" && [ "$(session_role "$p")" = coordinator ]; then
      _tv msg "[PRAMA ALERT] '%s' ended and nobody closed it through prama. Bring it back with its conversation: prama-agent restore %s" "$s" "$s"
      deliver_to_session "$p" "$msg" || true
    fi
  done
  if (( ${#gone[@]} )); then
    if (( ${#gone[@]} == 1 )); then
      _tv msg "[PRAMA ALERT] '%s' ended and nobody closed it through prama. Bring it back with its conversation: prama-agent restore %s" "${gone[0]}" "${gone[0]}"
    else
      _tv msg '[PRAMA ALERT] These sessions ended and nobody closed them through prama: %s. Bring them back with their conversations: prama-agent restore --all' "${gone[*]}"
    fi
    _watch_tell_terminals "$msg"
    declare -F telegram_notify >/dev/null && telegram_notify "$msg" alert
  fi
  if (( now - ${W_PRUNE_AT:-0} >= 3600 )); then W_PRUNE_AT=$now; closed_prune; fi
  return 0
}

# Every minute: each live team's plan, checked against what its agents actually do (lib/plan.sh).
_watch_plans() {
  declare -F plan_alerts >/dev/null || return 0
  local now=${EPOCHSECONDS:-$(date +%s)} c line
  (( now - ${W_PLAN_AT:-0} >= 60 )) || return 0
  W_PLAN_AT=$now
  while IFS= read -r c; do
    [ "$(session_role "$c")" = coordinator ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      deliver_to_session "$c" "$line" || true
      declare -F telegram_notify >/dev/null && telegram_notify "📋 $(team_label "$c")
${line#\[PRAMA\] }" team "$c"
      _watch_log "$c: $line"
    done < <( plan_alerts "$c" 2>/dev/null )
  done < <(prama_sessions)
}

# Quota is per account, not per agent: sessions are grouped by agent/profile and one alert is
# sent per group and window when usage crosses PRAMA_QUOTA_WARN (default 90%).
_watch_quota_collect() {
  local s=$1 ts q5 q7 grp win pct
  ts=$(quota_get "$s" Q_TS 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || return 0
  (( ${EPOCHSECONDS:-$(date +%s)} - ts < ${PRAMA_QUOTA_STALE:-3600} )) || return 0
  q5=$(quota_get "$s" Q_5H) q7=$(quota_get "$s" Q_7D)
  grp="$(state_get "$s" AGENT)/$(state_get "$s" PROFILE default)"
  for win in 5h 7d; do
    if [ "$win" = 5h ]; then pct=$q5; else pct=$q7; fi
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    local cur=${W_QGROUP[$grp:$win]:-}
    if [ -z "$cur" ] || (( pct > ${cur%%|*} )); then
      W_QGROUP[$grp:$win]="$pct|$s|$(quota_get "$s" "Q_${win^^}_RESET")"
    fi
  done
}

_watch_quota_alerts() {
  local key pct s reset warn=${PRAMA_QUOTA_WARN:-90} label msg
  for key in "${!W_QGROUP[@]}"; do
    IFS='|' read -r pct s reset <<< "${W_QGROUP[$key]}"
    if (( pct >= warn )); then
      if [ -z "${W_QALERTED[$key]:-}" ]; then
        W_QALERTED[$key]=1
        label=${key%%:*}; label=${label%/default}
        _tv msg '◔ quota %s %s at %s%%' "$label" "${key##*:}" "$pct"; _watch_log "$msg"
        bus_event quota watchdog "$s" "$label ${key##*:} $pct%"
        _tv msg "[PRAMA ALERT] %s quota at %s%% (%s window, resets %s). It affects every %s agent on this account: move heavy tasks to other agents/models (e.g. 'prama-agent fleet spawn agy <zone>' or 'prama-agent fleet model <session> <model>') before they get blocked." \
          "$label" "$pct" "${key##*:}" "$(_fmt_reset "$reset")" "$label"
        _watch_alert "$s" "$msg"
      fi
    else
      unset 'W_QALERTED[$key]'
    fi
  done
  W_QGROUP=()
}

watchdog_loop() {
  declare -gA W_PREV=() W_READY=() W_QGROUP=() W_QALERTED=() W_WAIT=() W_ATTN=()
  local interval=${PRAMA_WATCH_INTERVAL:-5} msg
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval > 0 )) || interval=5
  tmx select-pane -t "=$(watchdog_session):" -T "watchdog" 2>/dev/null || true
  _tv msg 'Fleet watchdog running (every %ss). Ctrl+C to stop it.' "$interval"; _watch_log "$msg"
  trap 'touch "$PRAMA_BUS_DIR/watchdog.stopped" 2>/dev/null; exit 0' INT
  while true; do
    watchdog_tick
    # Exit when the fleet is empty for a while: the next launch starts it again.
    if [ -z "$(prama_sessions)" ]; then
      (( ${W_IDLE:=0} >= 60 / interval )) && { _tv msg 'No agents left; watchdog finished.'; _watch_log "$msg"; exit 0; }
      (( W_IDLE++ ))
    else
      W_IDLE=0
    fi
    sleep "$interval"
  done
}
