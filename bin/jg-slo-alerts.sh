#!/usr/bin/env bash
# jg-slo-alerts.sh - the SLO alerts for a failed pipeline and a slow choke point:
# the rules with their limits, the evaluation, and the routing. LIVE: the watcher
# runs one `tick` per poll, so a choke point raises its own alert instead of
# someone finding it by hand.
#
# WHY THIS EXISTS (migration step 5h). The measured choke points: pull requests
# done but unmerged for 1-2 h, lanes idle 40-110 min, red checks nobody picked up.
# The stack report decided the shape: numbers in Prometheus, alert rules in config
# with a test per rule, and Alertmanager's own grouping, repeat interval and
# inhibition. This step puts the config-driven rules in charge of those
# conditions, reading Prometheus when a server answers and the fleet's own records
# otherwise, so they are provable in a lab and work with no exporter.
# This part carries the first three rules.
#
# CONTRACT (this header is the one owner of the alerting shape).
#   definition  defaults/slo-alerts.json, overridable per home at
#               config/slo-alerts.json or by JG_SLO_ALERTS: it owns the rules,
#               every limit, the grouping labels, the repeat and digest
#               intervals, the inhibition rules, the routing and the mode.
#   rule        One metric, one limit in that metric's own unit, and the minutes
#               the condition must hold: Alertmanager's own `for`. It fires when
#               the value exceeds the limit and has held that long.
#   instance    One sample, keyed by its alert id and labels.
#               $STATE/.slo-alerts/inst-<id>-<hash> is its state record.
#   grouping    Instances sharing every group-by label are ONE notification.
#   repeat      A group still firing re-notifies at most once per
#               repeat-interval-minutes; a resolved instance notifies nothing.
#   inhibit     An instance stays muted while an inhibit rule's source alert
#               fires with the same value for every `equal` label, whichever rule
#               is evaluated first.
#   route       The owning lead first, always, in this home's own queue. Main only
#               when the lead has not cleared the alert by
#               escalate-to-main-minutes: a Squad Lead home appends that to its
#               parent channel and a Main home re-wakes as an escalation. The
#               captain channel gets a blocker at once and everything else as ONE
#               batched digest per digest interval.
#   mode        live records, wakes and publishes; shadow records and prints what
#               it would send, the one-step reversal; off does nothing.
#   cadence     A tick evaluates at most once per eval-interval-seconds, so a
#               15-second poll does not pay a full evaluation every cycle.
#   samples     collect reads each number from the fleet's own records. A home
#               with prometheus-url evaluates the same rules against the server
#               instead. The forge is read at most once per
#               forge-interval-minutes, so a poll never becomes a GitHub sweep.
#   urgency     blocker or batch, and defaults/wake-routing decides the cost: a
#               blocker prints its reason for this cycle and a batch queues its
#               row. This script never re-decides the class.
#
# Usage: jg-slo-alerts.sh show | collect | eval [--at <epoch>] [--samples <file>] | tick
#
# Environment: JG_HOME, JG_ROOT_OVERRIDE, JG_STATE_OVERRIDE, JG_CONFIG_OVERRIDE,
# JG_SLO_ALERTS (the definition), JG_SLO_ALERTS_NOW (a pinned clock),
# JG_SLO_ALERTS_BUS (the captain-channel entry point, for a lab).
set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
ALERTS_DIR=$STATE/.slo-alerts
DIGEST=$ALERTS_DIR/digest
SAMPLES_FILE=$ALERTS_DIR/samples

die() { printf 'jg-slo-alerts: %s\n' "$*" >&2; exit 2; }

definition() {
  local f
  for f in "${JG_SLO_ALERTS:-}" "$CONFIG/slo-alerts.json" "$ROOT/defaults/slo-alerts.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

wf() { jq -er "$1" "$DEF"; }  # one field of the definition in force

# A time limit as plain decimal seconds, so the comparison is in one unit and the
# config keeps the number a reviewer thinks in.
unit_secs() {  # <value> <unit>
  case "$2" in
    minutes) printf '%s' "$(( $1 * 60 ))" ;;
    seconds) printf '%s' "$1" ;;
    jobs | items | count) printf '%s' "$1" ;;
    *) die "unsupported limit unit: $2" ;;
  esac
}

# The fact libraries the collectors read: the status classification that decides
# a declared wait is not an idle worker, the supervision ready-backlog reader, and
# the wake queue every delivery lands in. Sourced once, on the commands that need
# them, so `show` reads nothing and starts nothing.
load_fact_libs() {
  [ -z "${SLO_FACT_LIBS:-}" ] || return 0
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-classify-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-supervision-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-wake-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-busy-lib.sh" || return 1
  SLO_FACT_LIBS=1
  return 0
}

# --- collection ------------------------------------------------------------
# Each number is read from the record that already owns the fact. Nothing here
# invents a measurement: every field is a file this fleet writes or a forge read
# the fleet already performs elsewhere.
stat_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

age_of() {  # <path>
  local m
  m=$(stat_mtime "$1") || { printf '0'; return 0; }
  case "$m" in '' | *[!0-9]*) printf '0'; return 0 ;; esac
  [ "$m" -le "$NOW" ] || { printf '0'; return 0; }
  printf '%s' "$(( NOW - m ))"
}

emit() {  # <metric> <value> <labels-json>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# The owner label names the home that owns the lane, so an alert is routed
# without a second question: a Squad Lead home is its own owner, a Main home is
# main.
owner_label() {
  local id
  if [ -e "$JG_HOME/.jg-squad-lead-home" ]; then
    id=$(sed -n '1p' "$JG_HOME/.jg-squad-lead-home" 2>/dev/null) || id=
    printf '%s' "${id:-main}"
  else
    printf 'main'
  fi
}

forge_due() {
  local at
  at=$(cat "$ALERTS_DIR/.forge-at" 2>/dev/null) || at=0
  case "$at" in '' | *[!0-9]*) at=0 ;; esac
  [ "$(( NOW - at ))" -ge "$(( FORGE_INTERVAL * 60 ))" ]
}

forge_mark() { printf '%s\n' "$NOW" >"$ALERTS_DIR/.forge-at" 2>/dev/null || true; }

# 1. A pull request red with no new push. The clock starts at the head that went
# red, so a new push restarts it: that is the "nobody is touching it" the captain
# described. One forge read per pull request, once per forge interval.
collect_pr_red() {
  local meta pr json head red hash rec old_head old_since since labels
  command -v gh >/dev/null 2>&1 || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    pr=$(grep -m1 '^pr=' "$meta" 2>/dev/null | cut -d= -f2-) || pr=
    case "$pr" in https://*) ;; *) continue ;; esac
    json=$(gh pr view "$pr" --json state,headRefOid,statusCheckRollup 2>/dev/null) || continue
    head=$(printf '%s' "$json" | jq -r '.headRefOid // empty' 2>/dev/null) || continue
    [ -n "$head" ] || continue
    red=$(printf '%s' "$json" | jq -r '[(.statusCheckRollup // [])[] | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED" or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE")] | length > 0' 2>/dev/null) || red=false
    hash=$(printf '%s\t%s' "${meta##*/}" "$pr" | cksum | cut -d' ' -f1)
    rec="$ALERTS_DIR/pr-$hash"
    if [ "$red" = true ]; then
      old_head='' old_since=''
      [ -f "$rec" ] && IFS=$'\t' read -r old_head old_since <"$rec"
      if [ "$old_head" = "$head" ] && [ -n "$old_since" ]; then since=$old_since; else since=$NOW; fi
      printf '%s\t%s\n' "$head" "$since" >"$rec"
      labels=$(jq -cn --arg owner "$(owner_label)" --arg pr "$pr" '{owner: $owner, pr: $pr}')
      emit jg_slo_pr_red_seconds "$(( NOW - since ))" "$labels"
    else
      rm -f "$rec"
    fi
  done
  return 0
}

# 2. Done to merged. A task whose newest done line is older than the limit while it
# is still in flight is the wait the captain measured, and both halves are local:
# a merged task records the merge in its last line.
collect_done_merge() {
  local meta task status done_at last pr labels
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    status=$STATE/$task.status
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    done_at=$(awk '/^done \[at=[0-9]+\]/{ match($0, /at=[0-9]+/); print substr($0, RSTART + 3, RLENGTH - 3) }' "$status" | tail -n 1)
    case "$done_at" in '' | *[!0-9]*) continue ;; esac
    last=$(tail -n 1 "$status" 2>/dev/null) || last=
    case "$last" in *merged*) continue ;; esac
    [ "$NOW" -ge "$done_at" ] || continue
    pr=$(grep -m1 '^pr=' "$meta" 2>/dev/null | cut -d= -f2-) || pr=
    labels=$(jq -cn --arg owner "$(owner_label)" --arg task "$task" --arg pr "$pr" \
      '{owner: $owner, task: $task, pr: $pr}')
    emit jg_slo_done_unmerged_seconds "$(( NOW - done_at ))" "$labels"
  done
  return 0
}

# 3. A worker with no commit and no status. The newer of the two is the lane's
# last sign of life, and a declared wait is the worker doing the right thing:
# bin/jg-classify-lib.sh owns that verdict. A lane whose PANE is busy is working
# whatever its status log last said, so it is never idle; bin/jg-busy-lib.sh owns
# that reading.
collect_worker_idle() {
  local meta task status decl status_age commit_age wt idle labels
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    pane_busy "$STATE" "$task" "$meta" && continue
    status=$STATE/$task.status
    if [ -f "$status" ] && [ ! -L "$status" ]; then
      decl=$(tail -n 1 "$status" 2>/dev/null) || decl=
      status_is_paused "$decl" && continue
      case "$decl" in blocked* | needs-decision* | paused* | done*) continue ;; esac
      status_age=$(age_of "$status")
    else
      status_age=$(age_of "$meta")
    fi
    commit_age=$status_age
    wt=$(grep -m1 '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-) || wt=
    if [ -n "$wt" ]; then
      commit_age=$(git -C "$wt" log -1 --format=%ct 2>/dev/null) || commit_age=
      case "$commit_age" in
        '' | *[!0-9]*) commit_age=$status_age ;;
        *) commit_age=$(( NOW - commit_age )); [ "$commit_age" -ge 0 ] || commit_age=$status_age ;;
      esac
    fi
    idle=$status_age
    [ "$commit_age" -lt "$idle" ] && idle=$commit_age
    labels=$(jq -cn --arg owner "$(owner_label)" --arg task "$task" '{owner: $owner, task: $task}')
    emit jg_slo_worker_idle_seconds "$idle" "$labels"
  done
  return 0
}

# pane_busy <state-dir> <task> <meta>: 0 when the lane's own pane reports busy
# through the semantic busy contract, with the harness that trusts that source.
# Anything else - idle, missing, untrusted, unreadable - is not busy, so the lane
# stays a candidate and the status-log reading decides.
pane_busy() {
  local state=$1 task=$2 meta=$3 rec pane source harness
  harness=$(grep -m1 '^harness=' "$meta" 2>/dev/null | cut -d= -f2-) || harness=
  rec=$(jg_busy_record_read "$state" "$task" 2>/dev/null) || return 1
  read -r pane source _ <<<"$rec"
  [ "$pane" = busy ] || return 1
  jg_busy_source_trusted "${harness:-}" "$source" 2>/dev/null
}

cmd_collect() {
  local out=$SAMPLES_FILE tmp=$SAMPLES_FILE.tmp.$$ forge=0
  mkdir -p "$ALERTS_DIR" 2>/dev/null || die "cannot create $ALERTS_DIR"
  load_fact_libs || die 'the fact libraries are not in this tree'
  : >"$tmp" || die "cannot write $tmp"
  { collect_done_merge; collect_worker_idle; } >>"$tmp" || return 1
  if forge_due; then
    forge=1
    collect_pr_red >>"$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$out" || return 1
  [ "$forge" -eq 0 ] || forge_mark
  printf '%s\n' "$out"
}

# --- state and evaluation --------------------------------------------------
# Alertmanager's own machine, one file per instance: pending until the condition
# has held for `for`, firing after that, resolved silently. Two passes keep
# inhibition order-independent: one writes the state and the firing table, the
# other turns that table into notifications.

inst_hash() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

# read_inst <file>: sets I_PHASE I_PENDING I_FIRING I_SENT I_ESCALATED I_LABELS
read_inst() {
  local line
  I_PHASE='' I_PENDING='' I_FIRING='' I_SENT='' I_ESCALATED='' I_LABELS=''
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  line=$(head -n 1 "$1" 2>/dev/null) || return 1
  # shellcheck disable=SC2034 # I_LABELS keeps the record's own field order.
  IFS=$'\t' read -r I_PHASE I_PENDING I_FIRING I_SENT I_ESCALATED I_LABELS <<<"$line" || return 1
  [ "$I_FIRING" != - ] || I_FIRING=''
  return 0
}

write_inst() {  # <file> <phase> <pending> <firing> <sent> <escalated> <labels>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "${4:--}" "$5" "$6" "$7" >"$1" || return 1
}

label_value() { printf '%s' "$2" | jq -r --arg k "$1" '.[$k] // ""' 2>/dev/null || printf ''; }

group_values() {  # <labels-to-join> <labels-json>
  local g out=''
  for g in $1; do out="$out$(label_value "$g" "$2")/"; done
  printf '%s' "${out%/}"
}

# Every sample of one metric in the sample set: <labels-json>\t<value>
metric_rows() {  # <metric>
  local m v l
  while IFS=$'\t' read -r m v l; do
    [ "$m" = "$1" ] || continue
    case "$v" in '' | *[!0-9]*) continue ;; esac
    printf '%s\t%s\n' "$l" "$v"
  done <"$SAMPLES_PATH"
}

alert_rows() {
  wf '.alerts[] | [.id, .metric, (.limit | tostring), .["limit-unit"],
        (.["for-minutes"] | tostring), .urgency, (.["escalate-to-main-minutes"] | tostring),
        (if ((.["group-by"] // []) | length) > 0 then (.["group-by"] | join(" ")) else "-" end),
        .summary] | @tsv'
}

# Pass one: every instance's state, and the firing table inhibition reads.
evaluate_state() {  # <firing-table>
  local firing=$1 id metric limit unit for_min urgency escalate group_by summary
  local labels value file key phase pending firing_at sent escalated
  : >"$firing"
  while IFS=$'\t' read -r id metric limit unit for_min urgency escalate group_by summary; do
    [ -n "$id" ] || continue
    limit=$(unit_secs "$limit" "$unit")
    [ "$group_by" != - ] || group_by=''
    for_min=$(unit_secs "$for_min" minutes)
    while IFS=$'\t' read -r labels value; do
      [ -n "$labels" ] || continue
      key=$id-$(inst_hash "$labels")
      file=$ALERTS_DIR/inst-$key
      if [ "$value" -le "$limit" ]; then
        read_inst "$file" && { rm -f "$file"; }
        continue
      fi
      read_inst "$file" || true
      case "$I_PHASE" in pending | firing) phase=$I_PHASE ;; *) phase=pending ;; esac
      case "$I_PENDING" in '' | *[!0-9]*) I_PENDING=$NOW ;; esac
      case "$I_FIRING" in '' | *[!0-9]*) I_FIRING= ;; esac
      case "$I_SENT" in '' | *[!0-9]*) I_SENT=0 ;; esac
      case "$I_ESCALATED" in '' | *[!0-9]*) I_ESCALATED=0 ;; esac
      pending=$I_PENDING
      firing_at=$I_FIRING
      sent=$I_SENT
      escalated=$I_ESCALATED
      if [ "$phase" = pending ] && [ "$(( NOW - pending ))" -ge "$for_min" ]; then
        phase=firing
        firing_at=$pending
        sent=0
        escalated=0
      fi
      [ "$phase" = firing ] || firing_at=''
      write_inst "$file" "$phase" "$pending" "$firing_at" "$sent" "$escalated" "$labels" || return 1
      [ "$phase" = firing ] || continue
      printf '%s\t%s\n' "$id" "$labels" >>"$firing"
    done <<EOF
$(metric_rows "$metric")
EOF
  done <<EOF
$(alert_rows)
EOF
  return 0
}

# inhibited <id> <labels-json> <firing-table>
inhibited() {
  local id=$1 labels=$2 table=$3 source target equal l match fid firing_labels
  while IFS=$'\t' read -r source target equal; do
    [ -n "$source" ] || continue
    [ "$target" = "$id" ] || continue
    while IFS=$'\t' read -r fid firing_labels; do
      [ "$fid" = "$source" ] || continue
      match=1
      for l in $equal; do
        [ "$(label_value "$l" "$labels")" = "$(label_value "$l" "$firing_labels")" ] || match=0
      done
      [ "$match" -eq 1 ] && return 0
    done <"$table"
  done <<EOF
$(jq -r '.["inhibit-rules"][]? | [.source, .target, ((.equal // []) | join(" "))] | @tsv' "$DEF" 2>/dev/null)
EOF
  return 1
}

# Pass two: one JSON line per instance that needs a send or an escalation, with
# inhibition applied. Grouping is jq's, in notifications().
evaluate_notify() {  # <cand-file> <firing-table>
  local cands=$1 firing=$2 id metric limit unit for_min urgency escalate group_by summary
  local labels value file key firing_at sent escalated waited link text kind send_due esc_due
  : >"$cands"
  while IFS=$'\t' read -r id metric limit unit for_min urgency escalate group_by summary; do
    [ -n "$id" ] || continue
    limit=$(unit_secs "$limit" "$unit")
    escalate=$(unit_secs "$escalate" minutes)
    [ "$group_by" != - ] || group_by=''
    [ -n "$group_by" ] || group_by=$GROUP_BY
    while IFS=$'\t' read -r labels value; do
      [ -n "$labels" ] || continue
      [ "$value" -gt "$limit" ] || continue
      key=$id-$(inst_hash "$labels")
      file=$ALERTS_DIR/inst-$key
      read_inst "$file" || continue
      [ "$I_PHASE" = firing ] || continue
      firing_at=$I_FIRING
      sent=$I_SENT
      escalated=$I_ESCALATED
      case "$firing_at" in '' | *[!0-9]*) continue ;; esac
      case "$sent" in '' | *[!0-9]*) sent=0 ;; esac
      case "$escalated" in '' | *[!0-9]*) escalated=0 ;; esac
      # A send and an escalation are two separate notifications, and either can
      # fall due while the other is not: a still-firing alert both repeats and
      # escalates, and neither may swallow the other.
      send_due=0
      esc_due=0
      [ "$(( NOW - sent ))" -ge "$REPEAT" ] && send_due=1
      [ "$escalated" -eq 0 ] && [ "$(( NOW - firing_at ))" -ge "$escalate" ] && esc_due=1
      # Inhibition mutes the instance entirely: an alert that may not notify may
      # not escalate either, or the muted alert would still reach Main.
      if { [ "$send_due" -eq 1 ] || [ "$esc_due" -eq 1 ]; } && inhibited "$id" "$labels" "$firing"; then
        send_due=0
        esc_due=0
      fi
      [ "$send_due" -eq 1 ] || [ "$esc_due" -eq 1 ] || continue
      waited=$(( NOW - firing_at ))
      link=$(printf '%s' "$labels" | jq -r '[.[] | strings | select(startswith("https://"))][0] // ""' 2>/dev/null) || link=
      for kind in send escalate; do
        case "$kind" in send) [ "$send_due" -eq 1 ] || continue ;; *) [ "$esc_due" -eq 1 ] || continue ;; esac
        text=$(jq -cn \
          --arg id "$id" --arg group "$(group_values "$group_by" "$labels")" \
          --arg urgency "$urgency" --arg summary "$summary" --arg link "${link:-}" \
          --arg kind "$kind" --argjson labels "$labels" --argjson waited "$waited" \
          '{alertname: $id, group: $group, urgency: $urgency, summary: $summary,
            link: $link, labels: $labels, waited: $waited, kind: $kind}')
        printf '%s\n' "$text" >>"$cands"
      done
      # A live send consumes the repeat window and a live escalation is spent
      # once. Shadow reads the same state and delivers nothing.
      if [ "$MODE" = live ]; then
        [ "$send_due" -eq 0 ] || sent=$NOW
        [ "$esc_due" -eq 0 ] || escalated=$NOW
        write_inst "$file" "$I_PHASE" "$I_PENDING" "$firing_at" "$sent" "$escalated" "$labels" || return 1
      fi
    done <<EOF
$(metric_rows "$metric")
EOF
  done <<EOF
$(alert_rows)
EOF
  return 0
}

notifications() {  # <cand-file>
  jq -s -c '
    sort_by([.alertname, .group, (if .kind == "send" then 0 else 1 end)])
    | group_by([.alertname, .group, .kind])
    | .[]
    | { alertname: .[0].alertname, group: .[0].group, urgency: .[0].urgency,
        summary: .[0].summary, link: (map(.link) | map(select(. != "")) | .[0] // ""),
        kind: .[0].kind, count: length, waited: (map(.waited) | max),
        labels: map(.labels) }' "$1" 2>/dev/null
}

# --- delivery --------------------------------------------------------------
# One notification becomes: an owner wake (always), an escalation to Main when the
# lead has not cleared it in time, and a captain-channel line (now for a blocker,
# a digest for everything else).

captain_publish() {  # <key> <text> <link>
  local key=$1 text=$2 link=$3 bus=${JG_SLO_ALERTS_BUS:-$ROOT/bin/jg-bus.sh}
  [ -x "$bus" ] || return 0
  if [ "$MODE" = shadow ]; then
    printf 'shadow: captain %s\n' "$text" >&2
    return 0
  fi
  if [ -n "$link" ]; then
    "$bus" publish alert "$key" "$text" --link "$link" >/dev/null 2>&1 || true
  else
    "$bus" publish alert "$key" "$text" >/dev/null 2>&1 || true
  fi
}

digest_append() {  # <alertname> <text>
  # The window opens with the first batched alert, so a digest is never published
  # the moment it is created just because no digest had been sent before.
  [ -e "$ALERTS_DIR/.digest-at" ] || printf '%s\n' "$NOW" >"$ALERTS_DIR/.digest-at" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$NOW" "$1" "$2" >>"$DIGEST" 2>/dev/null || true
}

# One batched captain line per repeat interval, never one per alert: that is what
# makes a run of routine choke points cost the captain a single line.
digest_publish() {
  local last n text
  [ -s "$DIGEST" ] || return 0
  last=$(cat "$ALERTS_DIR/.digest-at" 2>/dev/null) || last=0
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ "$(( NOW - last ))" -ge "$DIGEST_INTERVAL" ] || return 0
  # One line names the distinct rules that are waiting, so a repeat inside the
  # window cannot inflate the digest the captain reads.
  n=$(cut -f2 "$DIGEST" | sort -u | wc -l | tr -d ' ')
  text="$n choke point(s) waiting: $(cut -f2 "$DIGEST" | sort -u | paste -sd ', ' -)"
  captain_publish 'slo-digest' "$text" ''
  printf '%s\n' "$NOW" >"$ALERTS_DIR/.digest-at" 2>/dev/null || true
  : >"$DIGEST" 2>/dev/null || true
}

escalate_to_main() {  # <alertname> <text>
  local home=$JG_HOME state=$STATE rc=0
  if [ ! -e "$home/.jg-squad-lead-home" ]; then
    # A Main home already owns its queue, so the escalation is the louder row.
    jg_wake_append check "slo-main-$1" "check: escalated $2" || return 1
    return 0
  fi
  # A Squad Lead's escalation is the parent channel its charter names, so Main
  # reads it as any other status line.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/jg-classify-lib.sh" || exit 1
    # shellcheck source=/dev/null
    . "$ROOT/bin/jg-parent-channel-lib.sh" || exit 1
    jg_parent_channel_report "$home" "$state" "$2"
  ) || rc=$?
  [ "$rc" -eq 0 ] || printf 'jg-slo-alerts: parent channel refused (%s)\n' "$rc" >&2
  return 0
}

cmd_tick() {
  local cands=$ALERTS_DIR/candidates firing=$ALERTS_DIR/firing
  local notif alertname group urgency kind count waited link summary key text printed=''
  local last_eval
  mkdir -p "$ALERTS_DIR" 2>/dev/null || die "cannot create $ALERTS_DIR"
  [ "$MODE" = off ] && return 0
  last_eval=$(cat "$ALERTS_DIR/.eval-at" 2>/dev/null) || last_eval=0
  case "$last_eval" in '' | *[!0-9]*) last_eval=0 ;; esac
  [ "$NOW" -ge "$(( last_eval + EVAL_INTERVAL ))" ] || return 0
  printf '%s\n' "$NOW" >"$ALERTS_DIR/.eval-at" 2>/dev/null || true
  load_fact_libs || die 'the fact libraries are not in this tree'
  SAMPLES_PATH=$(samples_for_eval) || return 1
  evaluate_state "$firing" || return 1
  evaluate_notify "$cands" "$firing" || return 1
  while IFS= read -r notif; do
    [ -n "$notif" ] || continue
    alertname=$(printf '%s' "$notif" | jq -r '.alertname')
    group=$(printf '%s' "$notif" | jq -r '.group')
    urgency=$(printf '%s' "$notif" | jq -r '.urgency')
    kind=$(printf '%s' "$notif" | jq -r '.kind')
    count=$(printf '%s' "$notif" | jq -r '.count')
    waited=$(printf '%s' "$notif" | jq -r '.waited')
    link=$(printf '%s' "$notif" | jq -r '.link')
    summary=$(printf '%s' "$notif" | jq -r '.summary')
    key=$(printf '%s\t%s\t%s' "$alertname" "$group" "$kind" | cksum | cut -d' ' -f1)
    text="$summary ($count waiting $(human_secs "$waited"))"
    [ -z "$group" ] || text="$text group $group"
    if [ "$MODE" = shadow ]; then printf 'shadow: %s %s\n' "$kind" "$text" >&2; continue; fi
    case "$kind:$urgency" in
      escalate:*)
        escalate_to_main "$alertname" "$alertname-$key: $text" || true
        [ -n "$printed" ] || printed="check: slo-escalation $alertname-$key: $text - Main must act, the lead did not clear it"
        ;;
      send:blocker)
        jg_wake_append check "slo-blocker-$alertname-$key" "check: slo-blocker $alertname-$key: $text - blocker, act now" || true
        captain_publish "slo-$alertname-$key" "$text" "$link"
        [ -n "$printed" ] || printed="check: slo-blocker $alertname-$key: $text - blocker, act now"
        ;;
      send:*)
        jg_wake_append check "slo-$alertname-$key" "check: slo $alertname-$key: $text" || true
        digest_append "$alertname" "$text"
        ;;
    esac
  done <<EOF
$(notifications "$cands")
EOF
  [ "$MODE" = shadow ] || digest_publish
  if [ -n "$printed" ]; then printf '%s\n' "$printed"; fi
  return 0
}

# The sample set this run evaluates: an explicit file, the Prometheus answer, or
# the last local collection. The first that answers wins, so the lab and a host
# with no server both evaluate real numbers.
samples_for_eval() {
  local metric result out=$ALERTS_DIR/prometheus.samples ok=0
  if [ -n "${SAMPLES:-}" ]; then
    [ -f "$SAMPLES" ] || die "no sample file at $SAMPLES"
    printf '%s' "$SAMPLES"
    return 0
  fi
  if [ -n "$PROM_URL" ] && command -v curl >/dev/null 2>&1; then
    : >"$out" || return 1
    while IFS= read -r metric; do
      [ -n "$metric" ] || continue
      result=$(curl -sS --max-time "$PROM_TIMEOUT" --get --data-urlencode "query=$metric" \
        "$PROM_URL/api/v1/query" 2>/dev/null) || { ok=1; break; }
      printf '%s' "$result" | jq -r --arg m "$metric" '
        .data.result[]? | [ $m, (.value[1] | tonumber | floor | tostring),
                            ((.metric | del(.__name__)) | tojson) ] | @tsv
      ' >>"$out" 2>/dev/null || { ok=1; break; }
    done <<EOF
$(wf '.alerts[].metric')
EOF
    if [ "$ok" -eq 0 ]; then printf '%s' "$out"; return 0; fi
  fi
  cmd_collect >/dev/null || return 1
  printf '%s' "$SAMPLES_FILE"
}

human_secs() {  # <seconds>
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  elif [ "$s" -ge 60 ]; then printf '%dm' "$(( s / 60 ))"
  else printf '%ds' "$s"; fi
}

# --- show ------------------------------------------------------------------
cmd_show() {
  printf 'slo alerts: %s\nmode: %s\ngroup-by: %s\nrepeat-interval: %s\nsamples: %s\n' \
    "$DEF" "$MODE" "$GROUP_BY" "$(human_secs "$REPEAT")" \
    "$([ -n "$PROM_URL" ] && printf 'prometheus %s' "$PROM_URL" || printf 'local records')"
  jq -r '.alerts[] | "  \(.id)  \(.metric) > \(.limit) \(.["limit-unit"]) for \(.["for-minutes"])m  \(.urgency)  escalate +\(.["escalate-to-main-minutes"])m"' "$DEF"
  printf 'inhibit: '
  jq -r '[.["inhibit-rules"][]? | "\(.source) mutes \(.target) when \(((.equal // []) | join(", ")))"] | join("; ")' "$DEF"
  printf 'route: owning lead first; Main at the escalation above; captain channel as a digest, at once for a blocker\n'
}

# --- commands --------------------------------------------------------------
cmd_eval() {
  local at=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) at=$2; shift 2 ;;
      --samples) SAMPLES=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$at" in '' | *[!0-9]*) ;; *) NOW=$at ;; esac
  mkdir -p "$ALERTS_DIR" 2>/dev/null || die "cannot create $ALERTS_DIR"
  load_fact_libs || die 'the fact libraries are not in this tree'
  SAMPLES_PATH=$(samples_for_eval) || return 1
  evaluate_state "$ALERTS_DIR/firing" || return 1
  evaluate_notify "$ALERTS_DIR/candidates" "$ALERTS_DIR/firing" || return 1
  notifications "$ALERTS_DIR/candidates"
}

main() {
  local cmd=${1:-}
  shift 2>/dev/null || true
  command -v jq >/dev/null 2>&1 || die 'jq is required to read the definition'
  DEF=$(definition) || die 'no slo-alerts definition found'
  MODE=$(wf '.mode') || die 'the definition carries no mode'
  case "$MODE" in live | shadow | off) ;; *) die "unsupported mode: $MODE" ;; esac
  GROUP_BY=$(jq -r '.["group-by"] // ["alertname","owner"] | join(" ")' "$DEF") || GROUP_BY='alertname owner'
  REPEAT=$(unit_secs "$(wf '.["repeat-interval-minutes"]')" minutes)
  FORGE_INTERVAL=$(wf '.["forge-interval-minutes"]') || FORGE_INTERVAL=10
  EVAL_INTERVAL=$(wf '.["eval-interval-seconds"]') || EVAL_INTERVAL=60
  DIGEST_INTERVAL=$(unit_secs "$(wf '.["digest-interval-minutes"]')" minutes)
  PROM_URL=$(jq -r '.["prometheus-url"] // ""' "$DEF") || PROM_URL=''
  PROM_TIMEOUT=$(wf '.["prometheus-timeout-seconds"]') || PROM_TIMEOUT=3
  NOW=${JG_SLO_ALERTS_NOW:-$(date +%s)}
  SAMPLES=${SAMPLES:-}
  case "$cmd" in
    show) cmd_show "$@" ;;
    collect) cmd_collect "$@" ;;
    eval) cmd_eval "$@" ;;
    tick) cmd_tick "$@" ;;
    *) die 'usage: jg-slo-alerts.sh show | collect | eval | tick' ;;
  esac
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
