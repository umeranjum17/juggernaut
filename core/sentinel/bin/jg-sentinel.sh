#!/usr/bin/env bash
# jg-sentinel.sh - recovery that runs OUTSIDE the agent runtime.
#
# Every Juggernaut watcher, Stop-hook arm, and away daemon runs inside the Herdr
# server's process tree, so when the server is killed (an out-of-memory kill of
# its service unit, for example) they all die with it. Herdr restarts and
# resumes the agent sessions it recorded, but nothing re-arms supervision: a
# Claude primary whose turn had ended sits at its prompt, leads and workers sit
# idle, and Herdr resumes each agent in its pane's creation folder, which for a
# freshly spawned worker is the PRIMARY checkout rather than its worktree. This
# script is the piece that must live in its own process (a systemd user service
# from `unit`), never inside Herdr.
#
# Usage (JG_HOME is required; the backend session defaults to Herdr's default):
#   JG_HOME=<home> jg-sentinel.sh tick       one pass; what a scheduler runs
#   JG_HOME=<home> jg-sentinel.sh loop       tick every JG_SENTINEL_INTERVAL seconds
#   JG_HOME=<home> jg-sentinel.sh ring       ring the primary now for a queued captain note (jg-inbox.sh runs it)
#   JG_HOME=<home> jg-sentinel.sh reconcile  nudge or relaunch this home's direct reports, once per episode
#   JG_HOME=<home> jg-sentinel.sh unit       print a systemd user service running `loop`
#                             (Main only: a Squad Lead home is refused, and
#                             bin/jg-unit-claim.sh owns why Main owns the units)
#   JG_HOME=<home> jg-sentinel.sh model-reconcile       restore a recorded Claude model, this home
#   JG_HOME=<home> jg-sentinel.sh lead-model-reconcile  the same for each local, unparked lead home
#
# One copy: this file is the sentinel. bin/jg-sentinel.sh is a forwarder that
# execs it with JG_BIN set to that checkout's bin/, and core/sentinel/wiring.sh
# installs this file as the host's copy. The Juggernaut scripts and libraries it
# runs come from JG_BIN when set, else from the home's checkout ($JG_HOME/bin),
# which is what the installed copy uses. `unit` names the entry it was run
# through: the forwarder when JG_BIN is set, else this file.
#
# tick, under the home's state/.sentinel.lock:
#   1. Reads the Herdr server identity for JG_SENTINEL_HERDR_SESSION (default the
#      backend's own HERDR_SESSION, else `default`) as the inode and bind time of its API socket, which the server
#      recreates on every start. A stopped server is left alone: its supervisor
#      restarts it, and this script never starts one.
#   2. On the first identity it records it in state/.sentinel-herdr-identity.
#      On a changed identity it runs `reconcile`, leaves one pending restart
#      wake per identity in state/.sentinel-wake-pending (state/.sentinel-woken-for
#      keeps the identity it was left for), and records the new identity once no
#      lane is unsettled or 30 minutes have passed since the restart, logging any
#      lane still unsettled then; until that, every tick reconciles again.
#   3. Wakes the primary session when a restart wake is pending, or when
#      supervision is needed and the watcher beacon is older than the grace
#      (bin/jg-supervision-lib.sh owns that predicate). A beacon-only wake is
#      repeated at most once per JG_SENTINEL_REWAKE_SECS for one beacon age.
#      The primary is the Herdr pane whose agent session is state/.lock-session.
#      The wake is typed only when that pane reads not busy and its composer
#      reads exactly empty, as the away daemon's injection does, so it never
#      lands mid-turn or on top of a person's typing; a deferred wake stays
#      pending for the next tick and is logged, and the captain is never told
#      (task jg-7v6uw-s32). Text of our own doorbell left in the box, whole or
#      a leading part of one, is repaired first (jg_backend_repair_own_line):
#      cleared by key in a turn or when partial, submitted when whole and the
#      agent is idle, one row each in data/composer-repairs.tsv. A repair that
#      fails twice in a row for the same wake calls the guarded relaunch of the
#      primary once (JG_SENTINEL_PRIMARY_RELAUNCH replaces its command). The typed text is an operational-input
#      doorbell whose record says what happened; handling it is an ordinary
#      turn, and that turn's end re-arms supervision through the primary's own
#      re-arm owner (docs/watcher-continuity.md).
#
# After those steps, whatever they decided and whether or not a Herdr server runs, each tick
# runs the delivery pass (bin/jg-delivery-tick.sh) for this home and for each registered, local,
# unparked lead home, each with that home's own checkout's entry and bounded by
# JG_SENTINEL_DELIVERY_TIMEOUT: a worker's done lands, and the go-live and rollover start, with
# no model awake and no watcher running. A live watcher runs the same pass on its fast tick; the
# pass's lock lets only one of them run it at a time, and its result row goes to that home's wake
# queue whoever ran it. A failed pass is logged and makes the tick exit 1.
#
# A captain note is the exception to the grace: while a note's wake row waits in
# the queue and no watcher is live (beacon older than JG_SENTINEL_INBOX_GRACE,
# default 60 s), the primary is rung at once, with no need for lanes in flight
# and no 300 s beacon wait. Each tick checks it, and `ring` runs only that check;
# bin/jg-inbox.sh runs `ring` the moment it queues the note, so the note reaches
# a turn in seconds whatever the unit's own tick phase. One ring per queued set
# of notes, repeated after JG_SENTINEL_INBOX_REWAKE_SECS (default 300); a
# deferred ring (mid-turn, composer not empty) is retried by the next tick.
#
# Before step 1, each tick also guards /tmp pressure through bin/jg-tmp-sweep.sh,
# which owns the policy: a WARNING log line and a primary wake when /tmp space or
# inode use reaches JG_TMP_WARN_PCT (80), repeated at most once per
# JG_SENTINEL_TMP_REWARN_SECS, and a sweep of stale fleet scratch once per
# JG_SENTINEL_TMP_SWEEP_SECS (86400; 0 turns the sweep off), whose summary goes
# to the log. At JG_TMP_PRESSURE_PCT (70) it does not wait for the day: it logs one
# "tmp pressure" line naming the 5 largest folders with their lanes and sweeps in
# the same tick, again at most each JG_SENTINEL_TMP_PRESSURE_SECS (900) while the
# use stays over; the sweep rules are the daily sweep's, and a lane's folder stays
# (JG_SENTINEL_TMP_SWEEP_SECS=0 turns it off too). It runs even while no Herdr
# server is up, and a failure never changes the tick's own result.
#
# reconcile, for each local direct report in state/*.meta on the watched Herdr
# session (bin/jg-session-start.sh also runs it detached at every locked
# startup, so each home resumes its own lanes):
#   - The restart epoch is the server's socket bind time, the second half of the
#     identity. A lane whose busy record (state/<id>.busy-state ts=) or spawn or
#     relaunch (spawn_gen=) is at or after it acted since the restart and gets
#     no nudge or order; its placement and exit corrections below still run. A
#     lane whose agent reads busy is mid-turn and is left alone.
#   - An agent state other than alive, dead, or missing is not settled yet (a
#     server still resuming its sessions): the lane is left for the next pass.
#   - A squad_lead whose agent is alive gets one recovery order through
#     bin/jg-send.sh, telling it to run bin/jg-session-start.sh, which resumes
#     its own lanes, and end its turn so its supervision re-arms. A dead
#     squad_lead is left to the watcher's squad_lead liveness relaunch; a
#     remote one is skipped.
#   - A ship or scout whose current state (bin/jg-crew-state.sh) is not done or
#     failed is relaunched in its recorded worktree through bin/jg-control.sh,
#     with a note carrying its current status line, when its agent is dead,
#     missing, or alive outside that worktree. A dead lane that acted since the
#     restart is left alone, as is a dead lane whose state/<id>.exit epoch (the
#     last verified jg-control exit) is newer than its spawn_gen, and no lane is
#     relaunched while it is an open captain call (bin/jg-captain-hold.sh open
#     exits 0, or 2 when unreadable).
#     Alive inside the worktree, the lane is
#     properly waiting and left alone when crew state reads parked, paused, or
#     blocked or its status log's current line (jg-classify-lib.sh) is an open
#     needs-decision or blocked, a paused wait, or a captain hold; otherwise its
#     turn was lost and it gets one resume nudge through bin/jg-send.sh.
#   - A done or failed ship or scout alive outside its worktree is exited
#     through bin/jg-control.sh, so no worker stays live in a primary checkout.
#   Orders and nudges are sent once per lane state: state/<id>.restart-nudged
#   keeps the key (its busy record, spawn_gen, and status log length), and a
#   lane whose key still matches is not nudged again until it moves.
#   One line per task goes to stdout and state/.sentinel.log.
# A one-shot reconcile whose episode state/.sentinel-herdr-identity already
# records prints that it is reconciled and does nothing else. After a one-shot
# reconcile that returns success it records the episode under the same settle
# rule tick uses, so a later session start in that episode skips it.
#
# Knobs: JG_SENTINEL_HERDR_SESSION (HERDR_SESSION, else default), JG_SENTINEL_INTERVAL (60),
# JG_SENTINEL_REWAKE_SECS (1800), JG_GUARD_GRACE (300), JG_SENTINEL_TMP_REWARN_SECS (21600),
# JG_SENTINEL_TMP_SWEEP_SECS (86400), JG_SENTINEL_DELIVERY_TIMEOUT (120).
# JG_SENTINEL_DRY_RUN=1 with reconcile decides as usual and prints each line to
# stdout, but runs no jg-control action, takes no lock, and writes nothing to the
# home; it is refused for tick and loop.
# Exit: 0 after a pass (including deferred work), 1 when the pass hit an error
# it logged, 2 for usage or a missing JG_HOME.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '/^# Usage/,/^#$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  tick|loop|ring|reconcile|unit|model-reconcile|lead-model-reconcile) CMD=$1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ -n "${JG_HOME:-}" ] || { echo "jg-sentinel: JG_HOME must be set explicitly" >&2; exit 2; }
JG_HOME=$(cd "$JG_HOME" 2>/dev/null && pwd -P) || { echo "jg-sentinel: JG_HOME is not a directory" >&2; exit 2; }
export JG_HOME
# The Juggernaut scripts and libraries this sentinel runs (see One copy above).
BIN=${JG_BIN:-$JG_HOME/bin}
ENTRY=$SCRIPT_DIR/jg-sentinel.sh
[ -z "${JG_BIN:-}" ] || ENTRY=$JG_BIN/jg-sentinel.sh
STATE="$JG_HOME/state"
SESSION=${JG_SENTINEL_HERDR_SESSION:-${HERDR_SESSION:-default}}
INTERVAL=${JG_SENTINEL_INTERVAL:-60}
REWAKE=${JG_SENTINEL_REWAKE_SECS:-1800}
GRACE=${JG_GUARD_GRACE:-300}
INBOX_GRACE=${JG_SENTINEL_INBOX_GRACE:-60}
INBOX_REWAKE=${JG_SENTINEL_INBOX_REWAKE_SECS:-300}
TMP_REWARN=${JG_SENTINEL_TMP_REWARN_SECS:-21600}
TMP_SWEEP=${JG_SENTINEL_TMP_SWEEP_SECS:-86400}
TMP_PRESSURE_PCT=${JG_TMP_PRESSURE_PCT:-70}
TMP_PRESSURE_EVERY=${JG_SENTINEL_TMP_PRESSURE_SECS:-900}
DELIVERY_TIMEOUT=${JG_SENTINEL_DELIVERY_TIMEOUT:-120}
LOG="$STATE/.sentinel.log"
DRY_RUN=${JG_SENTINEL_DRY_RUN:-0}
case "$DRY_RUN" in 0|1) ;; *) echo "jg-sentinel: JG_SENTINEL_DRY_RUN must be 0 or 1" >&2; exit 2 ;; esac
[ "$DRY_RUN" = 0 ] || [ "$CMD" = reconcile ] || { echo "jg-sentinel: JG_SENTINEL_DRY_RUN applies only to reconcile" >&2; exit 2; }

if [ "$CMD" = unit ]; then
  # The machine's services belong to Main (bin/jg-unit-claim.sh owns why): a
  # Squad Lead home that installs its own takes Main's alerts away with them.
  if [ -e "$JG_HOME/.jg-squad-lead-home" ] || [ -L "$JG_HOME/.jg-squad-lead-home" ]; then
    "$BIN/jg-unit-claim.sh" refuse jg-sentinel unit
    exit 2
  fi
  unit_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    printf '"%s"' "$value"
  }
  cat <<EOF
[Unit]
Description=Juggernaut sentinel for ${JG_HOME//%/%%} (recovers supervision after an agent-runtime restart)

[Service]
Environment=$(unit_quote "JG_HOME=$JG_HOME")
Environment=$(unit_quote "PATH=$PATH")
ExecStart=$(unit_quote "$ENTRY") loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  exit 0
fi

# shellcheck source=bin/jg-gate-refuse-lib.sh
. "$BIN/jg-gate-refuse-lib.sh"
jg_refuse_if_gate_agent
# shellcheck source=bin/jg-backend.sh
. "$BIN/jg-backend.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$BIN/jg-wake-lib.sh"
# shellcheck source=bin/jg-supervision-lib.sh
. "$BIN/jg-supervision-lib.sh"
# shellcheck source=bin/jg-operational-input.sh
. "$BIN/jg-operational-input.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$BIN/jg-classify-lib.sh"
jg_backend_source herdr || { echo "jg-sentinel: cannot load the Herdr adapter" >&2; exit 1; }

say() {
  printf '%s\n' "$*"
  [ "$DRY_RUN" = 1 ] && return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true
}

# Inode and bind time of the server's API socket; empty when it is not running.
herdr_identity() {
  local status sock
  status=$(jg_backend_herdr_cli "$SESSION" status --json 2>/dev/null) || return 0
  [ "$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)" = true ] || return 0
  sock=$(printf '%s' "$status" | jq -r '.server.socket // empty' 2>/dev/null)
  [ -S "$sock" ] || return 0
  # shellcheck disable=SC2012 # the socket path is Herdr's own, and ls -i is the portable inode read.
  printf '%s:%s\n' "$(ls -di "$sock" | awk '{print $1}')" "$(jg_path_mtime "$sock")"
}

# Run one recovery action, logging its outcome; a failure sets RECONCILE_RC.
act() {  # <task-id> <done-message> <command...>
  local id=$1 done=$2 out
  shift 2
  if [ "$DRY_RUN" = 1 ]; then
    say "$id: dry run, no action: $done"
    return 0
  fi
  if out=$("$@" 2>&1); then
    say "$id: $done"
  else
    say "$id: FAILED ($done): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    RECONCILE_RC=1
    return 1
  fi
}

delivery_id() {
  printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}

# Epoch of a lane's latest spawn or relaunch, from its spawn_gen; 0 when absent.
lane_spawn_epoch() {  # <meta>
  local spawn
  spawn=$(jg_meta_get "$1" spawn_gen)
  spawn=${spawn#s}
  spawn=${spawn%%.*}
  case "$spawn" in ''|*[!0-9]*) spawn=0 ;; esac
  printf '%s\n' "$spawn"
}

# Newest epoch a lane is recorded acting at: its busy record or its spawn.
lane_acted_at() {  # <id> <meta>
  local ts spawn
  ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' "$STATE/$1.busy-state" 2>/dev/null | head -n 1)
  spawn=$(lane_spawn_epoch "$2")
  [ "${ts:-0}" -gt "$spawn" ] && spawn=$ts
  printf '%s\n' "$spawn"
}

# Epoch jg-control exit recorded for a lane's last verified stop; 0 when none.
lane_exited_at() {  # <id>
  local ts
  ts=$(head -n 1 "$STATE/$1.exit" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  printf '%s\n' "$ts"
}

# Why a lane idle in its worktree is properly waiting; fails for a lost turn.
lane_waiting() {  # <id> <kind> <crew-state>
  local verb
  case "$3" in parked|paused|blocked) printf '%s' "crew state $3"; return 0 ;; esac
  status_line_verb "$(status_current_line "$STATE/$1.status" "$2")" verb
  case "$verb" in
    needs-decision|blocked|paused|captain-held) printf '%s' "status $verb" ;;
    *) return 1 ;;
  esac
}

# Send <text> once per lane state, keyed in state/<id>.restart-nudged; the key
# is also a squad_lead order's delivery id (jg-send takes one only for those).
nudge_once() {  # <id> <meta> <done-message> <text>
  local rec="$STATE/$1.restart-nudged" key ff=()
  key=$(delivery_id "$(cat "$STATE/$1.busy-state" 2>/dev/null)|$(jg_meta_get "$2" spawn_gen)|$(wc -l <"$STATE/$1.status" 2>/dev/null)")
  if [ "$(cat "$rec" 2>/dev/null)" = "$key" ]; then
    say "$1: already nudged in this state; left alone"
    return 0
  fi
  [ "$(jg_meta_get "$2" kind)" != squad_lead ] || ff=(--fire-and-forget "$key")
  act "$1" "$3" "$BIN/jg-send.sh" "$1" ${ff[@]+"${ff[@]}"} "$4" || return 1
  [ "$DRY_RUN" = 1 ] || printf '%s\n' "$key" >"$rec"
}

# Whether <id> is an open captain call, which no automatic relaunch may touch.
# Exit 1 (not open, or absent from the backlog) lets the lane through; exit 0
# (open) and exit 2 (cannot tell) hold it, so an unreadable hold fails closed.
captain_held() {  # <id>
  local rc=0
  "$BIN/jg-captain-hold.sh" open "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ] || return 1
  if [ "$rc" -eq 0 ]; then
    say "$1: captain hold open; left alone"
  else
    say "$1: captain hold unreadable (exit $rc); left alone"
  fi
  return 0
}

reconcile() {  # <episode>
  local restarted=${1##*:} meta id kind target agent cwd wt current note why acted harness model
  RECONCILE_RC=0
  RECONCILE_UNSETTLED=
  case "$restarted" in ''|*[!0-9]*) say "no Herdr server identity for $SESSION; nothing to reconcile"; return 0 ;; esac
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue; [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(jg_backend_of_meta "$meta")" = herdr ] || continue
    [ -z "$(jg_meta_get "$meta" remote_host)" ] || { say "$id: skipped (remote)"; continue; }
    kind=$(jg_meta_get "$meta" kind)
    case "$kind" in ship|scout|squad_lead) ;; *) continue ;; esac
    target=$(jg_backend_target_of_meta "$meta")
    [ "${target%%:*}" = "$SESSION" ] || continue
    acted=0
    [ "$(lane_acted_at "$id" "$meta")" -lt "$restarted" ] || acted=1
    agent=$(jg_backend_agent_state herdr "$target" "$meta" "$id" 2>/dev/null)
    case "$agent" in
      alive|dead|missing) ;;
      *) say "$id: agent ${agent:-unreadable}; not settled, left for the next pass"; RECONCILE_UNSETTLED="$RECONCILE_UNSETTLED $id"; continue ;;
    esac
    if [ "$agent" = alive ] && [ "$(jg_backend_busy_state herdr "$target")" = busy ]; then
      say "$id: mid-turn; left alone"
      continue
    fi
    if [ "$agent" != alive ] && [ "$(lane_exited_at "$id")" -gt "$(lane_spawn_epoch "$meta")" ]; then
      say "$id: stopped on purpose; left alone"
      continue
    fi
    if [ "$kind" = squad_lead ]; then
      if [ "$agent" != alive ]; then
        say "$id: squad_lead agent $agent; left to the watcher's squad_lead liveness relaunch"
        continue
      fi
      [ "$acted" -eq 0 ] || { say "$id: acted since the restart; left alone"; continue; }
      nudge_once "$id" "$meta" "ordered to recover" \
        "The host session restarted, so your last turn was lost and your supervision stopped. Run bin/jg-session-start.sh, which resumes your own home's lanes, then reconcile what remains and end the turn so your supervision re-arms."
      continue
    fi
    current=$(JG_CREW_STATE_NO_FORGE=1 "$BIN/jg-crew-state.sh" "$id" 2>/dev/null | awk '{print $2}')
    note="The host session restarted and stopped this task's agent; this relaunch put it back in its recorded worktree. Your last recorded status: $(status_current_line "$STATE/$id.status" "$kind" | cut -c1-300). Continue the brief you are already on from the local copy as it stands; this is not new work."
    harness=$(jg_meta_get "$meta" harness)
    model=$(jg_meta_get "$meta" model)
    wt=$(jg_canonical_existing_dir "$(jg_meta_get "$meta" worktree)")
    cwd=
    if [ "$agent" = alive ]; then
      cwd=$(jg_canonical_existing_dir "$(jg_backend_herdr_current_path "$target")")
    fi
    if [ -z "$wt" ]; then
      case "$agent:$current" in
        alive:done|alive:failed)
          act "$id" "$current, was live in ${cwd:-an unreadable folder}; exited" "$BIN/jg-control.sh" "$id" exit
          ;;
        *)
          say "$id: worktree missing; skipped"
          RECONCILE_RC=1
          ;;
      esac
      continue
    fi
    case "$agent:$current" in
      alive:done|alive:failed)
        case "$cwd/" in
          "$wt"/*) say "$id: $current, in its worktree; left alone" ;;
          *) act "$id" "$current, was live in ${cwd:-an unreadable folder}; exited" \
               "$BIN/jg-control.sh" "$id" exit ;;
        esac
        ;;
      *:done|*:failed) say "$id: $current, agent $agent; left alone" ;;
      alive:*)
        case "$cwd/" in
          "$wt"/*)
            if [ "$acted" -eq 1 ]; then
              say "$id: acted since the restart; left alone"
            elif why=$(lane_waiting "$id" "$kind" "$current"); then
              say "$id: properly waiting ($why); left alone"
            else
              nudge_once "$id" "$meta" "idle with its turn lost; nudged" \
                "The host session restarted, so your last turn was lost. Continue the brief you are already on from its durable records: your status log, your worktree, and your steering inbox. This is not new work and the task is unchanged."
            fi
            ;;
          *)
            captain_held "$id" && continue
            if [ -z "$model" ]; then
              say "$id: stored model missing; relaunch refused"
              RECONCILE_RC=1
              continue
            fi
            act "$id" "was live in ${cwd:-an unreadable folder}; relaunched in $wt with $harness model $model" \
              "$BIN/jg-control.sh" "$id" relaunch --harness "$harness" --model "$model" --note "$note"
            ;;
        esac
        ;;
      *)
        captain_held "$id" && continue
        [ "$acted" -eq 0 ] || { say "$id: acted since the restart; left alone"; continue; }
        if [ -z "$model" ]; then
          say "$id: stored model missing; relaunch refused"
          RECONCILE_RC=1
          continue
        fi
        act "$id" "agent $agent; relaunched in $wt with $harness model $model" \
          "$BIN/jg-control.sh" "$id" relaunch --harness "$harness" --model "$model" --note "$note"
        ;;
    esac
  done
  return "$RECONCILE_RC"
}

# The Herdr pane whose agent session is this home's locked primary session.
primary_target() {
  local sid panes
  sid=$(head -n 1 "$STATE/.lock-session" 2>/dev/null)
  [ -n "$sid" ] || return 1
  panes=$(jg_backend_herdr_cli "$SESSION" api snapshot 2>/dev/null \
    | jq -r --arg sid "$sid" '.result.snapshot.agents[]? | select(.agent_session.value == $sid) | .pane_id' 2>/dev/null)
  [ -n "$panes" ] && [ "$(printf '%s\n' "$panes" | wc -l)" -eq 1 ] || return 1
  printf '%s:%s\n' "$SESSION" "$panes"
}

# A deferred wake is normal for a moment (a turn is running, a person is typing). It waits for
# the next tick and says so in the sentinel log, one line per tick; it never writes to the captain,
# because a busy or occupied primary is the fleet's own business (task jg-7v6uw-s32). The lead
# sees the waits in that log and in the repair rows below.
defer_wake() {  # <log line>
  say "$1"
  return 1
}

# One row per repair of the primary's input box in data/composer-repairs.tsv: epoch, UTC time,
# pane, what was found, what was done, and the wake it was for. A person's draft is a wait, not a
# repair, so it gets a log line and no row.
repair_row() {  # <pane> <found> <action> <wake-sum>
  [ "$DRY_RUN" = 0 ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" \
    >>"$JG_HOME/data/composer-repairs.tsv" 2>/dev/null || say "primary: could not write the composer repair row"
}

# Count a repair that did not clear the box. The second failure in a row for the same wake calls
# the guarded relaunch of the primary (jg-control.sh primary relaunch --clear-composer, slice 34;
# JG_SENTINEL_PRIMARY_RELAUNCH names a stand-in command) once, and never again for that wake.
# state/.sentinel-repair-failed holds "<wake-sum> <failures> <relaunched>"; any other wake, or
# a box that cleared, resets it.
repair_failed() {  # <pane> <wake-sum>
  local file="$STATE/.sentinel-repair-failed" sum fails relaunched cmd=("$BIN/jg-control.sh" primary relaunch --clear-composer)
  [ "$DRY_RUN" = 0 ] || return 0
  [ -z "${JG_SENTINEL_PRIMARY_RELAUNCH:-}" ] || cmd=("$JG_SENTINEL_PRIMARY_RELAUNCH")
  read -r sum fails relaunched <"$file" 2>/dev/null || true
  [ "${sum:-}" = "$2" ] || { fails=0; relaunched=0; }
  fails=$(( ${fails:-0} + 1 ))
  if [ "$fails" -ge 2 ] && [ "${relaunched:-0}" = 0 ]; then
    relaunched=1
    repair_row "$1" own-line-stuck relaunch "$2"
    if "${cmd[@]}" >/dev/null 2>&1; then
      say "primary: $1 input box would not clear twice; relaunch requested"
    else
      say "primary: $1 input box would not clear twice; the relaunch command failed"
    fi
  fi
  printf '%s %s %s\n' "$2" "$fails" "${relaunched:-0}" >"$file"
}

# Remove the record a wake wrote when the wake did not go out: the next tick writes its own.
drop_wake_record() {  # <doorbell>
  local record
  jg_operational_doorbell_path "$1" record && rm -f "$record"
}

wake_primary() {  # <body>
  local target doorbell verdict sum
  target=$(primary_target) || { defer_wake "primary: no single Herdr pane runs session $(head -n 1 "$STATE/.lock-session" 2>/dev/null); wake deferred"; return 1; }
  jg_operational_record_write "$STATE" watcher "$1" doorbell || { say "primary: could not write the wake record"; return 1; }
  # A captain at the screen (no away record, or quiet mode) never gets a typed
  # doorbell: it can stick in his message box and swallow his own words. The
  # record above and the Stop-hook wake reach the primary without typing.
  if ! jg_afk_unattended "$STATE"; then
    say "primary: $target attended; wake left to the Stop hook and the record"
    return 0
  fi
  # Text of OUR OWN doorbell left in the box is repaired, never waited behind; anything else in
  # the box is a person's, and the wake waits for it (jg_backend_repair_own_line owns the test).
  sum=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  case "$(jg_backend_repair_own_line herdr "$target" "$doorbell" "$JG_OPERATIONAL_DOORBELL_PREFIX" "$JG_OPERATIONAL_DOORBELL_SUFFIX")" in
    clear) ;;
    cleared) repair_row "$target" own-line cleared-by-key "$sum"; say "primary: $target stale doorbell line cleared" ;;
    submitted) repair_row "$target" own-line submitted "$sum"; say "primary: $target stale doorbell line submitted" ;;
    stuck) repair_row "$target" own-line-stuck none "$sum"; repair_failed "$target" "$sum"
      drop_wake_record "$doorbell"; defer_wake "primary: $target stale doorbell line would not clear; wake deferred"; return 1 ;;
    *) drop_wake_record "$doorbell"; defer_wake "primary: $target input box holds someone else's text; wake deferred"; return 1 ;;
  esac
  rm -f "$STATE/.sentinel-repair-failed"
  [ "$(jg_backend_busy_state herdr "$target")" != busy ] || { drop_wake_record "$doorbell"; defer_wake "primary: $target mid-turn; wake deferred"; return 1; }
  [ "$(jg_backend_composer_state herdr "$target")" = empty ] || { drop_wake_record "$doorbell"; defer_wake "primary: $target composer not empty; wake deferred"; return 1; }
  verdict=$(jg_backend_send_nudge herdr "$target" "$doorbell" 3 0.5 0.5 2>/dev/null)
  if [ "$verdict" != empty ]; then
    # The record stays: typed text that was not confirmed can still be submitted,
    # and a ring whose record is gone sends its reader to a missing file.
    defer_wake "primary: wake typed into $target but not confirmed ($verdict)"; return 1;
  fi
  say "primary: woke $target"
}

# Record <episode> as reconciled once the pass left no lane unsettled, or 30
# minutes after the restart; until then the next pass reconciles again.
settle_episode() {  # <episode>
  [ "$DRY_RUN" = 0 ] || return 0
  if [ -z "$RECONCILE_UNSETTLED" ] || [ $(( $(date +%s) - ${1##*:} )) -ge 1800 ]; then
    [ -z "$RECONCILE_UNSETTLED" ] || say "still not settled 30 minutes after the restart; left to the primary:$RECONCILE_UNSETTLED"
    printf '%s\n' "$1" >"$STATE/.sentinel-herdr-identity"
  fi
}

# The one-shot reconcile: skipped for an episode already recorded as reconciled.
reconcile_episode() {  # <episode>
  local rc=0
  if [ -n "$1" ] && [ "$(cat "$STATE/.sentinel-herdr-identity" 2>/dev/null)" = "$1" ]; then
    say "herdr episode $1 already reconciled; nothing to do"
    return 0
  fi
  reconcile "$1" || rc=$?
  [ "$rc" -ne 0 ] || [ -z "$1" ] || settle_episode "$1"
  return "$rc"
}

# Each registered local lead home in data/squad_leads.md, one "<lead> <home>" line each; a remote
# lead and a line with no home are left out.
lead_homes() {
  local line lead home
  while IFS= read -r line; do
    case "$line" in *'(host:'*) continue ;; esac
    lead=$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*\([^[:space:]]*\).*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home: \([^;)]*\).*/\1/p')
    [ -n "$lead" ] && [ -n "$home" ] || continue
    printf '%s %s\n' "$lead" "$home"
  done < <(grep -E '^[[:space:]]*-[[:space:]]' "$JG_HOME/data/squad_leads.md" 2>/dev/null || true)
}

lead_parked() {  # <lead>
  [ -f "$JG_HOME/config/parked-homes" ] && grep -Eq "^[[:space:]]*$1([[:space:]]|$|#)" "$JG_HOME/config/parked-homes"
}

# Restore Claude's recorded model after Herdr's bare --resume restart.
# The pane process-info API is read-only; all relaunches use their guarded owner.
relaunch_lead_model_mismatches() {
  local lead home rc=0
  while read -r lead home; do
    if lead_parked "$lead"; then
      say "$lead: parked lead home skipped"
      continue
    fi
    [ -d "$home/state" ] && [ -x "$home/bin/jg-control.sh" ] || { say "$lead: unavailable lead home skipped"; continue; }
    # The lead home runs its own checkout's tools, so JG_BIN does not follow it.
    if ! env -u JG_BIN JG_HOME="$home" JG_SENTINEL_MODEL_EVENT="$JG_SENTINEL_MODEL_EVENT" "$SCRIPT_DIR/jg-sentinel.sh" model-reconcile; then
      say "$lead: lead model reconciliation failed"
      rc=1
    fi
  done < <(lead_homes)
  return "$rc"
}

relaunch_model_mismatches() {
  local meta id harness model kind pane info cmd rc=0 has_model event marker
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(jg_backend_of_meta "$meta")" = herdr ] || continue
    [ -z "$(jg_meta_get "$meta" remote_host)" ] || continue
    [ "$(jg_meta_get "$meta" herdr_session)" = "$SESSION" ] || continue
    harness=$(jg_meta_get "$meta" harness)
    [ "$harness" = claude ] || continue
    model=$(jg_meta_get "$meta" model)
    if [ -z "$model" ]; then
      say "$id: stored model missing; model restore refused"
      rc=1
      continue
    fi
    kind=$(jg_meta_get "$meta" kind)
    pane=$(jg_meta_get "$meta" herdr_pane_id)
    [ -n "$pane" ] || continue
    info=$(jg_backend_herdr_cli "$SESSION" pane process-info --pane "$pane" 2>/dev/null) || { say "$id: model check failed; skipped"; rc=1; continue; }
    cmd=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[]? | select((.name // "") == "claude" or (((.argv // [])[0] // .argv0 // "") | test("(^|/)claude$"))) | (.cmdline // ((.argv // []) | join(" ")))' 2>/dev/null | head -n 1)
    [ -n "$cmd" ] || continue
    has_model=0
    case " $cmd " in *" --model $model "*|*" --model=$model "*) has_model=1 ;; esac
    [ "$has_model" -eq 0 ] || continue
    event=${JG_SENTINEL_MODEL_EVENT:-unknown}
    marker="$STATE/$id.model-relaunch"
    [ "$(cat "$marker" 2>/dev/null)" = "$event" ] && continue
    printf '%s\n' "$event" >"$marker"
    if [ "$kind" = squad_lead ]; then
      act "$id" "Claude model missing; guarded lead restart requested" "$BIN/jg-squad-lead-restart.sh" "$id" || rc=1
    else
      act "$id" "Claude model missing; guarded worker relaunch requested" "$BIN/jg-control.sh" "$id" relaunch --model "$model" || rc=1
    fi
  done
  return "$rc"
}

# /tmp pressure guard: warn at the threshold, sweep stale scratch once a day; never fails the tick.
tmp_hygiene() {
  local out now last_try last_ok mode pressure='' rc=0
  now=$(date +%s)
  out=$("$BIN/jg-tmp-sweep.sh" check 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$STATE/.sentinel-tmp-warn"
  elif [ "$rc" -eq 1 ]; then
    read -r last_try last_ok <"$STATE/.sentinel-tmp-warn" 2>/dev/null || true
    if [ $(( now - ${last_ok:-0} )) -ge "$TMP_REWARN" ] && [ $(( now - ${last_try:-0} )) -ge 600 ]; then
      say "WARNING: $out; a daily sweep clears stale scratch, bin/jg-tmp-sweep.sh sweep lists what it would remove"
      if wake_primary "Warning: $out. Fleet scratch is filling the inode budget; wake acknowledgements and tools fail when it reaches 100%. The sentinel sweeps stale scratch daily; run bin/jg-tmp-sweep.sh sweep to list what it would remove."; then
        printf '%s %s\n' "$now" "$now" >"$STATE/.sentinel-tmp-warn"
      else
        printf '%s %s\n' "$now" "${last_ok:-0}" >"$STATE/.sentinel-tmp-warn"
      fi
    fi
  fi
  [ "$TMP_SWEEP" -gt 0 ] 2>/dev/null || return 0
  last_ok=$(cat "$STATE/.sentinel-tmp-sweep" 2>/dev/null)
  mode=--apply; rc=0
  "$BIN/jg-tmp-sweep.sh" check --warn-pct "$TMP_PRESSURE_PCT" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 1 ]; then
    [ $(( now - ${last_ok:-0} )) -ge "$TMP_SWEEP" ] || return 0
  else
    # Over the pressure line: sweep now, at most once per TMP_PRESSURE_EVERY.
    [ "$(cat "$STATE/.sentinel-tmp-pressure" 2>/dev/null || echo 0)" -le $(( now - TMP_PRESSURE_EVERY )) ] || return 0
    printf '%s\n' "$now" >"$STATE/.sentinel-tmp-pressure"
    pressure=1
  fi
  printf '%s\n' "$now" >"$STATE/.sentinel-tmp-sweep"
  # In the background: a sweep of a crowded /tmp takes about a minute and must not delay recovery.
  (
    rc=0
    # The first sweep on a home only reports; the marker records that its report was logged.
    if [ -n "${pressure:-}" ]; then
      say "tmp pressure: $("$BIN/jg-tmp-sweep.sh" check --warn-pct "$TMP_PRESSURE_PCT" 2>&1 | head -n 1); largest: $("$BIN/jg-tmp-sweep.sh" top -n 5 2>&1)"
    elif [ ! -e "$STATE/.sentinel-tmp-sweep-reported" ]; then mode=--dry-run; : >"$STATE/.sentinel-tmp-sweep-reported"; fi
    out=$("$BIN/jg-tmp-sweep.sh" sweep "$mode" 2>&1) || rc=$?
    printf '%s\n' "$out" | grep -E '^(remove|would remove|FAILED) ' | while IFS= read -r line; do say "tmp sweep: $line"; done
    say "tmp sweep $mode (exit $rc): $(printf '%s' "$out" | grep -E '^(removed|would remove [0-9]|space use|inode use|FAILED|jg-tmp-sweep)' | tr '\n' ';')"
  ) >/dev/null 2>&1 &
}

# Ring the primary now when a captain note waits in the wake queue and no watcher is live.
# The ring is recorded per set of queued notes, only after it was typed and confirmed.
ring_for_inbox() {
  local keys sum last woken
  keys=$(jg_wake_queued_keys check 2>/dev/null | grep '^inbox:' | sort) || true
  [ -n "$keys" ] || return 0
  jg_supervision_status "$STATE" "$INBOX_GRACE"
  [ "$JG_SUP_WATCHER_FRESH" = false ] || return 0
  sum=$(printf '%s\n' "$keys" | cksum | cut -d' ' -f1)
  read -r last woken <"$STATE/.sentinel-inbox-woken" 2>/dev/null || true
  [ "${woken:-}" != "$sum" ] || [ $(( $(date +%s) - ${last:-0} )) -ge "$INBOX_REWAKE" ] || return 0
  if wake_primary "A captain note waits in the inbox and no watcher is running. Run bin/jg-session-start.sh if this session was resumed, drain the wake queue, handle the note, then end the turn so supervision re-arms."; then
    printf '%s %s\n' "$(date +%s)" "$sum" >"$STATE/.sentinel-inbox-woken"
  else
    return 1
  fi
}

tick() {
  local id prev beat woken_beat age last body gap_class gap_progress=unknown rc=0
  tmp_hygiene || true
  if jg_supervision_unhealthy "$STATE" "$GRACE"; then
    if gap_class=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$BIN/jg-supervision-gap.sh" detect); then
      gap_progress=$(awk -F '\t' '{for (i=1;i<=NF;i++) if ($i ~ /^progress=/) {sub(/^progress=/,"",$i); print $i}}' "$STATE/.supervision-gap")
    else
      say "supervision gap: record failed"; gap_class=unknown-current
    fi
  else
    JG_STATE_OVERRIDE="$STATE" "$BIN/jg-supervision-gap.sh" clear || say "supervision gap: clear failed"
    gap_class=none
  fi
  id=$(herdr_identity)
  [ -n "$id" ] || return 0
  prev=$(cat "$STATE/.sentinel-herdr-identity" 2>/dev/null)
  if [ "$prev" != "$id" ]; then
    if [ -n "$prev" ]; then
      say "herdr session $SESSION restarted (socket $prev -> $id)"
      if reconcile "$id"; then
        [ "$(cat "$STATE/.sentinel-woken-for" 2>/dev/null)" = "$id" ] || {
          printf '%s\n' "$id" >"$STATE/.sentinel-woken-for"
          printf '%s\n' "The Herdr server restarted at $(date -u +%Y-%m-%dT%H:%M:%SZ), which stopped every agent and watcher in it. The sentinel already reconciled this home's direct reports; its lines are in $LOG. Run bin/jg-session-start.sh if this session was resumed, reconcile what remains, then end the turn so supervision re-arms." \
          >"$STATE/.sentinel-wake-pending"
        }
        settle_episode "$id"
      else
        rc=1
      fi
      JG_SENTINEL_MODEL_EVENT=$id relaunch_model_mismatches || rc=1
      # The lead pane is handled above; each lead owns its worker pass.
      JG_SENTINEL_MODEL_EVENT=$id relaunch_lead_model_mismatches || rc=1
    else
      printf '%s\n' "$id" >"$STATE/.sentinel-herdr-identity"
    fi
  fi
  if [ -f "$STATE/.sentinel-wake-pending" ]; then
    wake_primary "$(cat "$STATE/.sentinel-wake-pending")" && rm -f "$STATE/.sentinel-wake-pending"
    return "$rc"
  fi
  ring_for_inbox || true
  jg_supervision_unhealthy "$STATE" "$GRACE" || return "$rc"
  beat=$(jg_path_mtime "$STATE/.last-watcher-beat")
  read -r last woken_beat <"$STATE/.sentinel-wake-last" 2>/dev/null || true
  age=$(( $(date +%s) - ${last:-0} ))
  [ "${woken_beat:-}" != "${beat:-none}" ] || [ "$age" -ge "$REWAKE" ] || return "$rc"
  body="Supervision is needed but the watcher beacon is $JG_SUP_BEACON_DESC old and no turn is running. Gap $gap_class, last progress ${gap_progress:-unknown}, is in state/.supervision-gap. Run bin/jg-session-start.sh if this session was resumed, reconcile, then end the turn so supervision re-arms."
  # defaults/wake-routing decides whether this doorbell costs a turn: it settles while a
  # live watcher holds the lock, and it is recorded and counted like any settled wake.
  if [ "$(jg_wake_route_class check sentinel-beacon-old "$body")" != now ]; then
    jg_wake_settle check sentinel-beacon-old "$body" || true
    say "primary: beacon doorbell settled without a wake (defaults/wake-routing)"
    printf '%s %s\n' "$(date +%s)" "${beat:-none}" >"$STATE/.sentinel-wake-last"
    return "$rc"
  fi
  wake_primary "$body" && printf '%s %s\n' "$(date +%s)" "${beat:-none}" >"$STATE/.sentinel-wake-last"
  return "$rc"
}

# One home's delivery pass, bounded by DELIVERY_TIMEOUT; a failure is logged.
deliver_home() {  # <home> <entry>
  local out rc=0 bound=()
  [ -x "$2" ] || return 0
  if command -v timeout >/dev/null 2>&1; then bound=(timeout "$DELIVERY_TIMEOUT"); fi
  out=$(env -u JG_BIN -u JG_STATE_OVERRIDE -u JG_CONFIG_OVERRIDE -u JG_DATA_OVERRIDE JG_HOME="$1" \
    ${bound[@]+"${bound[@]}"} "$2" "$1" </dev/null 2>&1) || rc=$?
  [ -z "$out" ] || say "delivery: $1: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
  [ "$rc" -eq 0 ] || { say "delivery: $1: FAILED (exit $rc)"; return 1; }
}

# The delivery pass of this home and of each local, unparked lead home, which needs no Herdr
# server and no model (bin/jg-delivery-tick.sh owns the pass, its lock and its result row). Each
# lead home runs its own checkout's entry; a checkout without one is left to its watcher.
deliver() {
  local lead home rc=0
  deliver_home "$JG_HOME" "$BIN/jg-delivery-tick.sh" || rc=1
  while read -r lead home; do
    lead_parked "$lead" && continue
    [ -d "$home/state" ] && [ "$(cd "$home" && pwd -P)" != "$JG_HOME" ] || continue
    deliver_home "$home" "$home/bin/jg-delivery-tick.sh" || rc=1
  done < <(lead_homes)
  return "$rc"
}

# One sentinel pass: recovery first, then delivery, which runs whatever recovery found.
pass() {
  local rc=0
  tick || rc=$?
  deliver || rc=1
  return "$rc"
}

locked() {
  local lock="$STATE/.sentinel.lock" rc=0
  if [ "$DRY_RUN" = 1 ]; then "$@"; return $?; fi
  jg_lock_try_acquire "$lock" || return 0
  "$@" || rc=$?
  jg_lock_release "$lock"
  if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 1000 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
  return "$rc"
}

case "$CMD" in
  tick) locked pass ;;
  ring) locked ring_for_inbox ;;
  reconcile) locked reconcile_episode "${JG_SENTINEL_EPISODE:-$(herdr_identity)}" ;;
  model-reconcile) locked relaunch_model_mismatches ;;
  lead-model-reconcile) locked relaunch_lead_model_mismatches ;;
  loop)
    while :; do
      locked pass || true
      sleep "$INTERVAL"
    done
    ;;
esac
