#!/usr/bin/env bash
# The account-down row's recovery (core/wait-timers/README.md "Known next steps"):
# a Claude worker whose account stopped working (subscription past due, sign-in
# failed, usage or rate limit) is moved to the next account the OWNER recorded in
# config/claude-account-fallbacks, in the watcher, with no model turn. Sourced by
# jg-wait-actions-lib.sh, which supplies STATE, JG_HOME, jg_meta_get and the
# status helpers.
#
# One pass, under one lock (state/.account-outage/lock):
#   1. probe the pinned account once (a one-line Claude test, cached for
#      JG_ACCOUNT_PROBE_SECS, default 300); an account that answers is not down
#      and the wait climbs the ladder as before
#   2. pick the next recorded fallback after the pin that answers its own probe;
#      nothing else ever names an account: not the account pool, not a guess
#   3. write it to config/claude-account, then relaunch every live Claude worker
#      recorded on the dead account through bin/jg-control.sh, one after another,
#      detached
#   4. raise ONE board card (renew or not), keyed by the dead account
# With no recorded fallback, or none that answers, only step 4 happens: the pin
# and every pane stay as they are, and the wait waits for the owner.
# The episode's clear is recorded in the escalation ledger by the ladder itself.
#
# state/.account-outage/last: epoch, dead account, next account ("-" for none).
# It lets the other lanes of the same outage, whose panes still show the error
# while the relaunch runs, count as handled instead of switching twice.

JG_ACCOUNT_DOWN_RE='subscription|payment|past due|billing|usage limit|hit your limit|rate.?limit|too many requests|credit balance|invalid api key|not logged in|/login|oauth|authentication|unauthori[sz]ed|account'

_jg_account_config() { printf '%s' "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"; }

# The pinned account's declared value (ordinary or an absolute path), else 1.
_jg_account_pin() {
  local sel
  sel=$(jg_worker_account_resolve claude "$(_jg_account_config)" 2>/dev/null) || return 1
  [ -n "$sel" ] || return 1
  printf '%s\n' "${sel%%$'\t'*}"
}

# The Claude config directory a declared account selects, empty for ordinary.
_jg_account_root() { [ "$1" = ordinary ] || printf '%s' "$1"; }

# Whether a Claude worker of this home runs on a pinned account at all.
jg_account_outage_ok() {  # <task>
  [ "$(jg_meta_get "$STATE/$1.meta" harness)" = claude ] && _jg_account_pin >/dev/null
}

# The fallbacks the owner recorded, in his order, on stdout. A line is `ordinary`
# or an absolute path; blank lines and # comments are skipped; a malformed line
# ends the list there, so a typo never lets a later line be picked out of order.
_jg_account_fallbacks() {
  local file line
  file="$(_jg_account_config)/claude-account-fallbacks"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in ordinary|/*) ;; *) return 0 ;; esac
    case "$line" in *[[:cntrl:]]*) return 0 ;; esac
    printf '%s\n' "$line"
  done < "$file"
}

# One probe of <declared>: 0 when it answers, 1 when its own answer says the
# account is down (a failed run whose output names the account, payment, login or
# limit), 2 when the run failed some other way (a timeout, no network): that proves
# nothing, so nobody acts on it.
_jg_account_probe_run() {  # <declared>
  local root dir out rc name exe
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  root=$(_jg_account_root "$1")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
  exe=$(command -v claude) || return 2
  dir=$(mktemp -d) || return 2
  out=$(cd "$dir" && jg_run_timed "${JG_WORKER_ACCOUNT_CHECK_SECONDS:-30}" "${clean[@]}" \
    "$exe" -p --model "${JG_ACCOUNT_PROBE_MODEL:-claude-haiku-5-5}" 'Reply with the single word PONG.' 2>&1 </dev/null)
  rc=$?
  rm -rf -- "$dir"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q PONG; then return 0; fi
  printf '%s' "$out" | grep -qiE "$JG_ACCOUNT_DOWN_RE" && return 1
  return 2
}

# The pinned account's probe, cached per account so a poll loop asks once.
_jg_account_probe() {  # <declared> <now>
  local dir="$STATE/.account-outage" id cache at declared verdict rc
  id=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  cache="$dir/probe-$id"
  if [ -f "$cache" ] && [ ! -L "$cache" ]; then
    IFS=$'\t' read -r at verdict < "$cache" || true
    case "$at" in ''|*[!0-9]*) ;; *)
      if [ $(($2 - at)) -lt "${JG_ACCOUNT_PROBE_SECS:-300}" ]; then
        [ "$verdict" = 0 ] || [ "$verdict" = 1 ] || [ "$verdict" = 2 ] || return 2
        return "$verdict"
      fi ;;
    esac
  fi
  declared=$1
  _jg_account_probe_run "$declared"; rc=$?
  mkdir -p "$dir" && printf '%s\t%s\n' "$2" "$rc" > "$cache.tmp.$$" && mv "$cache.tmp.$$" "$cache" || true
  return "$rc"
}

# The first recorded fallback after <dead> that answers its own probe, on stdout;
# 1 when there is none. When the dead account is not in the list, the whole list
# follows it.
_jg_account_next() {  # <dead> <now>
  local line seen=0 list
  list=$(_jg_account_fallbacks)
  case "$(printf '%s\n' "$list" | grep -Fxc -- "$1")" in 0) seen=1 ;; esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$seen" -eq 0 ]; then [ "$line" != "$1" ] || seen=1; continue; fi
    [ "$line" != "$1" ] || continue
    case "$line" in /*) [ -d "$line" ] && [ -r "$line" ] && [ -x "$line" ] || continue ;; esac
    _jg_account_probe "$line" "$2" || continue
    printf '%s\n' "$line"
    return 0
  done <<EOF
$list
EOF
  return 1
}

# Every live Claude worker recorded on <dead>, one task id per line.
_jg_account_tasks() {  # <dead>
  local meta task last
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(jg_meta_get "$meta" harness)" = claude ] && [ "$(jg_meta_get "$meta" account)" = "$1" ] || continue
    task=${meta##*/}; task=${task%.meta}
    last=$(last_status_line "$STATE/$task.status" 2>/dev/null) || last=''
    case "$(status_line_verb "$last")" in done|failed) continue ;; esac
    printf '%s\n' "$task"
  done
}

# Relaunch the tasks one after another in one detached job; the outcome of each
# goes to state/.account-outage/relaunch.log. Each relaunch reads the new pin.
_jg_account_relaunch() {  # <task>...
  local ctl="$_JG_WAIT_TIMER_DIR/jg-control.sh" log="$STATE/.account-outage/relaunch.log" note detach=()
  [ -x "$ctl" ] || return 1
  [ "$#" -gt 0 ] || return 0
  note="The watcher moved this home's Claude workers to the next recorded account because the old one stopped working. Your local copy and commits are kept. Read your steering inbox, check git status and git log, then continue the task from where it stopped."
  ! command -v setsid >/dev/null 2>&1 || detach=(setsid)
  mkdir -p "${log%/*}" || return 1
  # shellcheck disable=SC2016 # The child shell expands its positional parameters.
  ( JG_HOME="$JG_HOME" nohup ${detach[@]+"${detach[@]}"} sh -c 'ctl=$1; note=$2; shift 2; for t; do "$ctl" "$t" relaunch --note "$note"; echo "relaunch $t exit=$?"; done' \
      jg-account-relaunch "$ctl" "$note" "$@" </dev/null >>"$log" 2>&1 & ) || return 1
}

# The one card to the captain: renew the account or not. The key names the dead
# account, so a repeat of the same outage keeps the one open card.
_jg_account_card() {  # <dead> <switched: yes|no>
  local key why out
  key="account-outage-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  if [ "$2" = yes ]; then
    why="The Claude account that the workers use stopped working. They moved to the next saved account and carry on."
  else
    why="The Claude account that the workers use stopped working. No saved account is ready to take over, so the stopped workers wait."
  fi
  out=$(cd "$JG_HOME" && SIGN_OFF_FILER=juggernaut-watch "$_JG_WAIT_TIMER_DIR/jg-question-card.sh" post \
    --route main --ask-ref "$key" --key "$key" --title "Renew the Claude account?" --why "$why" \
    --detail "The account stopped answering. This card stays open until you answer it." \
    --outcome yes="You renew the account, then the workers can move back." --outcome no="The account stays as it is." \
    --recommend yes --recommend-reason "Workers need a paid account to keep working." \
    --default no --must money --priority P1 2>&1) || { printf '%s\n' "$out" | tail -n 3 >&2; return 1; }
}

# The recover step for <task>. 0: handled (the outage was cleared or carded, the
# step is recorded); 1: nothing for the ladder to do here (the account answers, or
# the card could not be posted), so the wait climbs as before.
_jg_wait_action_account() {  # <task> <now>
  local dir="$STATE/.account-outage"
  mkdir -p "$dir" || return 1
  # One pass at a time: a lane of the same outage waits here, then finds it handled.
  ( flock -w 60 9 || exit 1; _jg_account_recover "$1" "$2" ) 9>"$dir/lock"
}

_jg_account_recover() {  # <task> <now>
  local dir="$STATE/.account-outage" pin acct next at last_dead rc=0 switched=no tasks tmp
  pin=$(_jg_account_pin) || return 1
  acct=$(jg_meta_get "$STATE/$1.meta" account)
  if [ -f "$dir/last" ] && [ ! -L "$dir/last" ]; then
    IFS=$'\t' read -r at last_dead _ < "$dir/last" || true
    case "$at" in ''|*[!0-9]*) ;; *)
      if [ -n "$acct" ] && [ "$acct" = "$last_dead" ] && [ $(($2 - at)) -lt 3600 ]; then return 0; fi ;;
    esac
  fi
  [ -z "$acct" ] || [ "$acct" = "$pin" ] || return 1
  _jg_account_probe "$pin" "$2"; rc=$?
  [ "$rc" -eq 1 ] || return 1
  if next=$(_jg_account_next "$pin" "$2"); then
    tmp="$(_jg_account_config)/.claude-account.tmp.$$"
    if ! { printf '%s\n' "$next" > "$tmp" && mv -f "$tmp" "$(_jg_account_config)/claude-account"; }; then rm -f "$tmp"; return 1; fi
    switched=yes
    printf '%s\t%s\t%s\n' "$2" "$pin" "$next" > "$dir/last"
    tasks=$(_jg_account_tasks "$pin")
    # shellcheck disable=SC2086 # One task id per word; ids never hold spaces.
    _jg_account_relaunch $tasks || echo "waiting timers: the relaunch of the workers on the dead account did not start" >&2
  else
    printf '%s\t%s\t-\n' "$2" "$pin" > "$dir/last"
  fi
  if ! _jg_account_card "$pin" "$switched"; then
    echo "waiting timers: the account-outage card was not posted (sign-off-axi refused or is missing)" >&2
    [ "$switched" = yes ] || return 1
  fi
  return 0
}
