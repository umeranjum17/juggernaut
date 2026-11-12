#!/usr/bin/env bash
# merge-on-green watcher check: merge a yolo task's PR through bin/jg-pr-merge.sh once its required
# checks are green, so the merge wait after green (about 21 min per change) disappears.
# Usage: merge-on-green.sh check <jg-home>
#
# Per home, for each state/<task>.meta with yolo=on and a recorded pr= and pr_head= (recorded here from
# the worker's `done: PR <url>` line when the record has none), it acts only when the
# task's resolved state (bin/jg-crew-state.sh <task>) says checks green / PR ready. It silently skips a task
# marked merge=manual and a PR whose evidence-gate PASS is a not-proven PASS (the gate reads the PR's
# newest "## Checks" block; the lead files the proof gap first). Then, in this order and as separate
# sequential commands, never piped and never in parallel:
#   1. JG_HOME=<home> checks-lint.sh <PR URL> <home>/data/<task> - use done-done lint, or the legacy Juggernaut lint if unavailable.
#   2. state/<task>.run-receipt.json - require verdict PASS, head == pr_head, spawn_gen == the meta's spawn_gen.
#   3. JG_HOME=<home> bin/jg-pr-merge.sh <task> <PR URL> - never --auto, never gh merge directly.
# A release record (kind=release, written by bin/jg-trunk.sh release) is merged on the captain's standing word,
# config/trunk-release-waiver, or the answer given at `gated` (jg-trunk.sh): its merge=approved counts only while that line or answer stands, so removing the rule stops the
# merge; its done is the release proof's receipt; and after its merge `jg-trunk.sh rollover` cuts the next trunk
# version in the same pass. Every other gate below applies to it unchanged.
# Any refusal or FAIL: one wake line naming the task, the PR URL and the first refusal reason, so the lead
# acts; the refusal is remembered per task+head+reason+receipt state and repeats stay silent until pr_head,
# the run receipt or the reason changes. An evidence gate or the merge this check itself kills on its
# timeout wakes truthfully once per task+head+reason like a refusal, records no merge attempt, and is
# retried next sweep; a jg-crew-state timeout stays silent and is retried next sweep. A merge:
# one wake line with the verified merged URL, so the lead does the post-merge steps (install from main,
# teardown), and the normal "done [at=<epoch>]: merged <PR URL>" line in state/<task>.status, so the
# lead relays it.
# One merge attempt per task per head: the attempted head and the last gate refusal are remembered in this
# feature's own data dir (<home>/data/jg-merge-on-green/<task>.head, <task>.refused), never in state/.
# Nothing is printed when nothing happened.
# Every command is bounded with timeout; a merge always finishes before the watcher's kill, a gate cut
# by it is retried next sweep.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: merge-on-green.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
LINT=${JG_MOG_CHECKS_LINT:-$SRC/checks-lint.sh}
DATA=$FMH/data/jg-merge-on-green
ALERT=${JG_STRANDED_ALERT:-$FMH/bin/jg-alert.sh}
# The release record's standing word is read through the trunk policy lib, from this script's own checkout; where it is absent no release merges.
# shellcheck source=bin/jg-trunk-policy-lib.sh
[ ! -r "$SRC/../../bin/jg-trunk-policy-lib.sh" ] || . "$SRC/../../bin/jg-trunk-policy-lib.sh"
type jg_trunk_waiver_rule >/dev/null 2>&1 || jg_trunk_waiver_rule() { :; }
umask 077
# One third of the watcher's per-check bound per command (floor 5s). Gate commands start only while
# under 80% of the bound and a merge only when it fits inside the whole bound, so the watcher's kill
# at JG_CHECK_TIMEOUT can at worst cut a gate command (harmlessly retried next sweep), never a merge.
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
START=$(date +%s)
DEADLINE=$(( START + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))

meta_get() { # <meta-file> <key> -> last value, the same rule jg_meta_get applies
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

first_reason() { # first reason line of a command's output, trimmed to keep the wake line short.
  # `armed:` (jg-pr-check) and `WARNING:` (jg-guard) lines are notices, not refusals: skipped.
  local r
  r=$(printf '%s' "$1" | sed -E '/^[[:space:]]*$/d; /^[[:space:]]*(armed:|WARNING:)/d' | head -1)
  [ -n "$r" ] || r="exit code ${2:-?} with no output"
  [ "${#r}" -le 140 ] || r=${r:0:137}'...'
  printf '%s' "$r"
}

# Every "NOT merging" wake line ends with this routing: a green lead-owned PR is the lead's to merge
# (standing authority), not a card for Main; only a genuine hold goes up.
LEAD_NOTE='lead: clear it and merge through bin/jg-pr-merge.sh; only a genuine hold (owner review, red CI, missing proof, security, destructive) goes to Main'

timed_out() { [ "$1" = 124 ] || [ "$1" = 137 ]; }

# merge_minutes <task>: the whole minutes from the ticket's ready time to its landed time, read from
# `jg-backlog.sh times <task>`; empty when the ticket has no ready time or no landed time. The merge itself
# writes landed_at (bin/jg-merge-outcome-lib.sh), so the number is the record's own, and a merge over
# JG_MERGE_LATENCY_LIMIT_MINUTES (default 5) is called out in the wake line the lead relays.
MERGE_LATENCY_LIMIT=${JG_MERGE_LATENCY_LIMIT_MINUTES:-5}
case "$MERGE_LATENCY_LIMIT" in ''|*[!0-9]*) MERGE_LATENCY_LIMIT=5 ;; esac
merge_minutes() { # <task>
  local rows ready landed
  rows=$(JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-backlog.sh" times "$1" 2>/dev/null) || rows=
  ready=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "ready" { print $2 }')
  landed=$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "landed" { print $2 }')
  # A release has no worker and no ready time: its hand-off is the release proof's completion receipt, and its merge is now.
  if [ -z "$ready" ] && [ "$kind" = release ]; then
    ready=$(jq -r '.at // empty' "$STATE/$1.run-receipt.json" 2>/dev/null) || ready=
    [ -z "$ready" ] || { printf '%s' $(( ($(date +%s) - ready) / 60 )); return 0; }
  fi
  [ -n "$ready" ] && [ -n "$landed" ] || return 0
  ready=$(date -u -d "$ready" +%s 2>/dev/null) && landed=$(date -u -d "$landed" +%s 2>/dev/null) || return 0
  [ "$landed" -ge "$ready" ] || { printf 0; return 0; }
  printf '%s' $(( (landed - ready) / 60 ))
}

refuse() { # <reason> <receipt-stamp>: the wake line prints once per task+head+reason+receipt state,
  # remembered like the merge path in <task>.refused; silent while all three hold.
  [ "$(cat "$DATA/$task.refused" 2>/dev/null)" = "$(printf '%s\n%s\n%s\n' "$pr_head" "$1" "$2")" ] && return 0
  echo "merge-on-green: NOT merging $task $pr: $1; $LEAD_NOTE"
  mkdir -p "$DATA" 2>/dev/null
  printf '%s\n%s\n%s\n' "$pr_head" "$1" "$2" > "$DATA/$task.refused" 2>/dev/null || :
}

for m in "$STATE"/*.meta; do
  [ -f "$m" ] || break
  task=$(basename "$m" .meta)
  case "$task" in [A-Za-z0-9]*) ;; *) continue ;; esac
  yolo=$(meta_get "$m" yolo); pr=$(meta_get "$m" pr); pr_head=$(meta_get "$m" pr_head); gen=$(meta_get "$m" spawn_gen)
  approved=$(meta_get "$m" merge); kind=$(meta_get "$m" kind)
  # Authority is the project's yolo posture or the captain's own recorded word:
  # the lead writes `merge=approved` into the task's record when he says to land
  # that change, which is the durable form of an approval that would otherwise
  # live only in chat. Neither is inferred from anything else.
  [ "$yolo" = on ] || [ "$approved" = approved ] || continue
  # A release record's approval is the standing release word: gone when that rule is gone, whatever the record says.
  if [ "$kind" = release ]; then
    rproj=$(basename "$(meta_get "$m" project)")
    # The standing word, or the answer given at `gated` (merge_rule=gated:<yolo|word>, backed by a row in data/trunk-gated.tsv).
    [ -n "$(jg_trunk_waiver_rule "$FMH/config/trunk-release-waiver" "$rproj")" ] \
      || { case $(meta_get "$m" merge_rule) in gated:*) jg_trunk_gated_any "$FMH/data/trunk-gated.tsv" "$rproj" ;; *) false ;; esac; } || continue
  fi
  # The lead marks merge=manual at intake on destructive, irreversible or security-sensitive work and
  # on work waiting for the captain's own review.
  [ "$(meta_get "$m" merge)" = manual ] && continue
  # A worker's `done [at=..]: PR <url>` line is the only place the PR is named until something records it
  # in the task's record. When nothing has (the lead was busy, or the line never reached a lead turn), this
  # check records it itself through bin/jg-pr-check.sh --from-status, which keeps every refusal that
  # script owns (a draft, a wrong base, a head not pushed) and writes pr= and pr_head= exactly as the
  # lead's own call does. That call is made once per distinct last status line, so a refusal is not
  # re-run against the forge every sweep.
  if [ -z "$pr" ] || [ -z "$pr_head" ]; then
    last=$(awk 'NF { l = $0 } END { print l }' "$STATE/$task.status" 2>/dev/null | cksum)
    if [ -x "$FMH/bin/jg-pr-check.sh" ] && [ "$(cat "$DATA/$task.recorded" 2>/dev/null)" != "$last" ]; then
      mkdir -p "$DATA" 2>/dev/null && printf '%s\n' "$last" > "$DATA/$task.recorded" 2>/dev/null || :
      JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-pr-check.sh" --from-status "$task" >/dev/null 2>&1 || :
      pr=$(meta_get "$m" pr); pr_head=$(meta_get "$m" pr_head)
    fi
  fi
  [ -n "$pr" ] && [ -n "$pr_head" ] || continue
  # One merge attempt per head: a head already attempted (merged or refused) is never retried.
  [ "$(cat "$DATA/$task.head" 2>/dev/null)" = "$pr_head" ] && continue
  [ "$(date +%s)" -lt "$DEADLINE" ] || break

  # Gate: the task's resolved state must say checks green / PR ready. "PR merged" means the work
  # already landed; nothing happened, so nothing is printed.
  # Only a pipeline run says "checks green: PR ready". A direct-PR task has no run, so its resolved state
  # is the worker's own done line in free text ("state: done · source: status-log · ..."): for it the
  # forge decides. bin/jg-pr-state.sh --all prints one line per open draft, conflict, unfinished or red
  # check, or a merged or closed state, and nothing when the pull request is open with every reported
  # check green. A false done, a lookup error and a merged pull request therefore stay silent, burn no
  # head and are read again next sweep; jg-pr-merge below still makes the final live green call.
  # A release has no worker and no status log, so its forge state alone decides, read the same way.
  if [ "$kind" = release ]; then cs="state: done · source: status-log"
  else cs=$(JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-crew-state.sh" "$task" 2>/dev/null) || continue; fi
  case "$cs" in
    *"checks green: PR ready"*|*"checks green: PR held for merge"*) ;;
    "state: done · source: status-log"*)
      ws=$(JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-pr-state.sh" --all "$pr" 2>/dev/null) || continue
      [ -z "$ws" ] || continue
      ;;
    *) continue ;;
  esac

  # 1. The evidence gate, run as its own command, must print PASS; a not-proven PASS is the lead's
  # proof gap to file first: skip silently before the receipt or merge.
  lint_out=$(JG_HOME="$FMH" timeout "$BUDGET" "$LINT" "$pr" "$FMH/data/$task" 2>&1); lint_rc=$?
  if timed_out "$lint_rc"; then
    refuse "checks lint timed out after ${BUDGET}s, no verdict; retrying next sweep" ''
    continue
  fi
  if [ "$lint_rc" -ne 0 ] || ! printf '%s\n' "$lint_out" | grep -q 'PASS'; then
    refuse "checks lint refused: $(first_reason "$lint_out" "$lint_rc")" ''
    continue
  fi
  printf '%s\n' "$lint_out" | grep -q 'checks-lint: PASS: not-proven:' && continue

  # 2. The completion receipt must be a PASS for exactly this head and spawn generation.
  rcpt=$STATE/$task.run-receipt.json
  # The lane's one slot may hold another member's receipt: put back the one published for this head, if any.
  "$SRC/../receipts/bin/jg-receipt-restore.sh" "$STATE" "$task" "$pr_head" >/dev/null 2>&1 || :
  if [ ! -f "$rcpt" ]; then
    refuse "no run receipt at state/$task.run-receipt.json" ''
    continue
  fi
  if ! command -v jq >/dev/null 2>&1; then
    refuse "jq is unavailable, cannot read the run receipt" ''
    continue
  fi
  rstamp=$(cksum < "$rcpt" 2>/dev/null)
  verdict=$(timeout "$BUDGET" jq -r '.verdict // ""' "$rcpt" 2>/dev/null); jq_rc=$?
  if timed_out "$jq_rc"; then
    refuse "reading the run receipt timed out after ${BUDGET}s; retrying next sweep" "$rstamp"
    continue
  fi
  rhead=$(timeout "$BUDGET" jq -r '.head // ""' "$rcpt" 2>/dev/null)
  rgen=$(timeout "$BUDGET" jq -r '.spawn_gen // ""' "$rcpt" 2>/dev/null)
  if [ "$jq_rc" -ne 0 ] || [ -z "$verdict$rhead$rgen" ]; then
    refuse "run receipt is unreadable JSON" "$rstamp"
    continue
  fi
  if [ "$verdict" != PASS ]; then
    refuse "run receipt verdict is ${verdict:-empty}, not PASS" "$rstamp"
    continue
  fi
  if [ "$rhead" != "$pr_head" ]; then
    refuse "run receipt head ${rhead:-empty} != meta pr_head" "$rstamp"
    continue
  fi
  if [ "$rgen" != "$gen" ]; then
    refuse "run receipt spawn_gen ${rgen:-empty} != meta spawn_gen" "$rstamp"
    continue
  fi

  # 3. Merge through jg-pr-merge.sh only: its own live green check, head pin and refusal rules stay in
  # charge, no --auto is ever passed. The attempted head is recorded first, so a check killed between
  # record and merge cannot retry the same head next sweep.
  # A merge killed by the watcher after the head was recorded burns it with no wake line:
  # start one only when it still fits inside the watcher's whole-check bound; the fit arithmetic
  # doubles as the merge's bound, so the whole remaining window is available to it.
  mbudget=$(( START + ${JG_CHECK_TIMEOUT:-30} - $(date +%s) - 1 ))
  # A merge needs two command-bounds of room (a third of the check bound each, so two thirds): the
  # forge call plus the read-back. Less than that only gets the merge cut mid-way and retried forever.
  [ "$mbudget" -ge $(( BUDGET * 2 )) ] || break
  mkdir -p "$DATA" || { echo "merge-on-green: NOT merging $task $pr: cannot write $DATA; $LEAD_NOTE"; continue; }
  printf '%s\n' "$pr_head" > "$DATA/$task.head" || { echo "merge-on-green: NOT merging $task $pr: cannot write $DATA/$task.head; $LEAD_NOTE"; continue; }
  merge_out=$(JG_HOME="$FMH" timeout "$mbudget" "$FMH/bin/jg-pr-merge.sh" "$task" "$pr" 2>&1); merge_rc=$?
  if timed_out "$merge_rc"; then
    rm -f "$DATA/$task.head" 2>/dev/null || :
    refuse "jg-pr-merge timed out, no verdict; retrying next sweep" ''
    continue
  fi
  if [ "$merge_rc" -eq 0 ]; then
    # The merge wrote landed_at on the ticket; the number is its ready time to that landing.
    latency=$(merge_minutes "$task")
    if [ -n "$latency" ] && [ "$latency" -gt "$MERGE_LATENCY_LIMIT" ]; then
      echo "merge-on-green: merged $task $pr through jg-pr-merge, but it took ${latency}m from its done line to merged, over the ${MERGE_LATENCY_LIMIT}-minute target (jg-backlog.sh times $task); lead: run the post-merge steps (install from main, teardown)"
    elif [ -n "$latency" ]; then
      echo "merge-on-green: merged $task $pr through jg-pr-merge in ${latency}m from its done line; lead: run the post-merge steps (install from main, teardown)"
    else
      echo "merge-on-green: merged $task $pr through jg-pr-merge; lead: run the post-merge steps (install from main, teardown)"
    fi
    if [ "$kind" = release ]; then
      # The release merged: cut the next trunk version now. A cut that fails or is cut short is retried by the landing check.
      roll=$(JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-trunk.sh" rollover "$(meta_get "$m" project)" 2>&1); roll_rc=$?
      echo "merge-on-green: rollover after $task: $(first_reason "$roll" "$roll_rc")"
    else
      # The normal merged line, so the lead relays it, plus the fleet-ledger hook every status append runs.
      echo "done [at=$(date +%s)]: merged $pr" >> "$STATE/$task.status"
      [ ! -e "$FMH/config/fleet-ledger" ] \
        || "$FMH/bin/jg-fleet-ledger.sh" appended "$FMH/config" "$STATE/$task.status" >/dev/null 2>&1 || :
    fi
  else
    echo "merge-on-green: NOT merging $task $pr: jg-pr-merge refused: $(first_reason "$merge_out" "$merge_rc"); $LEAD_NOTE"
  fi
done

# Open-PR cap: ten green PRs once sat unmerged behind one red release PR and nobody saw the pile.
# A merge never waits on another PR's colour (each task above is judged on its own PR), so the pile is
# raised here instead. For every repo named by a task's recorded pr= URL, count its open PRs; over
# <home>/config/open-pr-cap (a whole number, default 8) one central `stranded` alert (bin/jg-alert.sh raise, then
# deliver; subject <owner>__<repo>.open-prs) rings the lead. The count is remembered per repo in <home>/data/jg-merge-on-green/open-pr-cap/, so it repeats
# only when the count changes, and a repo back under the cap forgets it. Runs after the merges and only
# while a gh call still fits in the bound; a gh failure is silent and retried next sweep.
CAP=; [ ! -f "$FMH/config/open-pr-cap" ] || read -r CAP _ < "$FMH/config/open-pr-cap" || :
case "$CAP" in ''|*[!0-9]*|0) CAP=8 ;; esac
repos=$(for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  { meta_get "$m" pr; echo; } | sed -n 's#^https://github\.com/\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)/pull/[0-9]*$#\1#p'
done | sort -u)
for repo in $repos; do
  [ "$(( $(date +%s) + BUDGET ))" -lt "$(( START + ${JG_CHECK_TIMEOUT:-30} ))" ] || break
  seen=$DATA/open-pr-cap/${repo//\//__}
  open=$(timeout "$BUDGET" gh pr list --repo "$repo" --state open --limit 500 --json number --jq length 2>/dev/null) || continue
  case "$open" in ''|*[!0-9]*) continue ;; esac
  if [ "$open" -le "$CAP" ]; then rm -f "$seen" 2>/dev/null || :; JG_HOME=$FMH "$ALERT" resolve "stranded--${seen##*/}.open-prs" >/dev/null 2>&1; continue; fi
  [ "$(cat "$seen" 2>/dev/null)" = "$open" ] && continue
  JG_HOME=$FMH "$ALERT" resolve "stranded--${seen##*/}.open-prs" >/dev/null 2>&1
  JG_HOME=$FMH "$ALERT" raise stranded "${seen##*/}.open-prs" | JG_HOME=$FMH "$ALERT" deliver
  mkdir -p "$DATA/open-pr-cap" 2>/dev/null && printf '%s\n' "$open" > "$seen" 2>/dev/null || :
done

# Stale-PR alarm: an open PR with no checks and no update for 24 h, or based on an already merged release
# branch, raises one alert per PR. It lives in stale-pr-alarm.sh beside this script and is skipped when absent.
[ ! -x "$SRC/stale-pr-alarm.sh" ] || JG_STALE_PR_LIMIT=$DEADLINE "$SRC/stale-pr-alarm.sh" check "$FMH"

# Merge-ready batch: PR-ready outcomes reach the lead as ONE line per ten-minute window, each with its authority
# verdict (mergeable, needs the captain's word, NOT mergeable). It lives in merge-ready-batch.sh beside this script,
# merges nothing itself, and is skipped when absent.
[ ! -x "$SRC/merge-ready-batch.sh" ] || JG_CHECK_TIMEOUT=${JG_CHECK_TIMEOUT:-30} "$SRC/merge-ready-batch.sh" check "$FMH"

# Stranded-merge sweep: a closed release branch ahead of the default branch for 48 h raises one alert. It lives in
# stranded-merge-sweep.sh beside this script, asks the forge at most once an hour, and is skipped when absent.
[ ! -x "$SRC/stranded-merge-sweep.sh" ] || JG_STRANDED_LIMIT=$DEADLINE "$SRC/stranded-merge-sweep.sh" check "$FMH"

# Red-CI ticket: a red run on the default branch, a version branch or an open PR files one root-cause ticket, once
# per run id. It lives in red-ci-ticket.sh beside this script and is skipped when absent.
[ ! -x "$SRC/red-ci-ticket.sh" ] || JG_RED_CI_LIMIT=$DEADLINE "$SRC/red-ci-ticket.sh" check "$FMH"

# Shipped-backlog reconcile: an In flight row whose PR merged or whose release shipped, with no live worker, moves
# to Done. It lives in backlog-shipped-reconcile.sh beside this script and is skipped when absent.
[ ! -x "$SRC/backlog-shipped-reconcile.sh" ] || JG_SHIPPED_RECONCILE_LIMIT=$DEADLINE "$SRC/backlog-shipped-reconcile.sh" check "$FMH"
