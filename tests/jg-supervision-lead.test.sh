#!/usr/bin/env bash
# Lead-home supervision truths (autopilot slice W3): what a checkpoint lead's home reads as, and which
# ready work may wake it. Every verdict comes from the real bin/jg-supervision-lib.sh and the real
# bin/jg-watch-checkpoint.sh; only the backlog text source and the watcher or host a checkpoint runs are
# stand-ins, the same seam tests/jg-trunk-scope.test.sh uses.
#
# C1 A checkpoint lead is healthy between its checkpoints: the checkpoint writes state/.checkpoint-cadence
#    (any harness), and a home whose beacon is stale but whose checkpoint marker is within cadence plus
#    grace is not reported as unsupervised.
# C2 A dead lead does not hide behind the marker: past cadence plus grace the same home reads as
#    unsupervised again, and a marker with no usable cadence never counts.
# R1 A lead is never woken for work it cannot dispatch: a ready row naming a project this home does not
#    register is not counted, is handed back to the parent once, and a home holding only such rows needs
#    no supervision. A row naming no project, a registered project, and a main home keep their rows.
# B1 A checkpoint ends itself: a supervision host that ignores TERM is killed at its bound plus grace, and a
#    watcher that ignores INT is killed at the cleanup bound; the checkpoint records why in its marker.
set -u

# Usage: jg-supervision-lead.test.sh [C|R|B ...]: with no argument every section runs.
SECTIONS=("$@")
want() {  # <section>
  local s
  [ "${#SECTIONS[@]}" -gt 0 ] || return 0
  for s in "${SECTIONS[@]}"; do [ "$s" != "$1" ] || return 0; done
  return 1
}

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-supervision-lead)

# The status classifier is Go, built on first use per checkout path; a fixture home has none beside it, so
# build it once here (the parent channel's hand-back needs it) and point every call at it.
if [ -z "${JG_CLASSIFY_BIN:-}" ] && command -v "${JG_CLASSIFY_GO:-go}" >/dev/null 2>&1; then
  JG_CLASSIFY_BIN="$TMP_ROOT/classify/jg-classify" "$ROOT/bin/jg-classify.sh" is-paused 'paused: warm' >/dev/null 2>&1 || :
  [ -x "$TMP_ROOT/classify/jg-classify" ] && export JG_CLASSIFY_BIN="$TMP_ROOT/classify/jg-classify"
fi
now=$(date +%s)

# lead_home <name> [projects-line...]: a squad_lead home whose parent is a local main home.
lead_home() {
  local name=$1 home parent
  shift
  home="$TMP_ROOT/$name/lead"; parent="$TMP_ROOT/$name/parent"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/bin" "$parent/state"
  printf 'lead1\n' > "$home/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.jg-squad-lead-parent"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$home/data/projects.md"
  # The real scripts, reached through links so each keeps its own directory; only the backlog is a stand-in.
  local f
  for f in "$ROOT"/bin/*; do
    [ "${f##*/}" = jg-backlog.sh ] || ln -s "$f" "$home/bin/${f##*/}"
  done
  cat > "$home/bin/jg-backlog.sh" <<'SH'
#!/usr/bin/env bash
case $1 in ready) cat "$JG_HOME/ready.txt" ;; list) cat "$JG_HOME/priorities.txt" ;; esac
SH
  chmod +x "$home/bin/jg-backlog.sh"
  : > "$home/priorities.txt"
  printf 'ready[0]:\n' > "$home/ready.txt"
  printf '%s\n' "$home"
}

ready() {  # <home> <id,repo>...
  local home=$1 row
  shift
  { printf 'ready[%s]:\n' "$#"; for row in "$@"; do printf '  %s,work,queued,%s\n' "${row%%,*}" "${row#*,}"; done; } > "$home/ready.txt"
}

rows() { JG_HOME=$1 bash -c '. "$1/bin/jg-supervision-lib.sh"; jg_ready_work_rows "$1"' _ "$1"; }
status() {  # <home>: prints "<needed> <fresh> <ready-count> <desc>"
  JG_HOME=$1 bash -c '. "$1/bin/jg-supervision-lib.sh"; jg_supervision_status "$1/state" 300
    printf "%s %s %s %s\n" "$JG_SUP_NEEDED" "$JG_SUP_WATCHER_FRESH" "$JG_SUP_READY_WORK" "$JG_SUP_BEACON_DESC"' _ "$1"
}
age_file() { touch -d "@$(( now - $2 ))" "$1"; }  # <file> <seconds-old>

# Writer: the real checkpoint, with a stand-in watcher that returns a wake at once (any harness: no codex config).
fx="$TMP_ROOT/checkpoint-bin"; mkdir -p "$fx"
for f in jg-watch-checkpoint.sh jg-supervision-engine-lib.sh jg-tool-models.sh jg-compat.sh; do
  [ ! -e "$ROOT/bin/$f" ] || ln -s "$ROOT/bin/$f" "$fx/$f"
done
printf '#!/usr/bin/env bash\nprintf "heartbeat: fixture\\n"\n' > "$fx/jg-watch.sh"; chmod +x "$fx/jg-watch.sh"
if want C; then
# --- C1, C2: the checkpoint marker -------------------------------------------------------------
# A lead with one lane in flight and a watcher beacon that is long stale: the checkpoint gap.
home=$(lead_home c)
printf 'kind=ship\n' > "$home/state/lane-a.meta"
: > "$home/state/.last-watcher-beat"; age_file "$home/state/.last-watcher-beat" 3000
case "$(status "$home")" in "true false 0 30"??"s ago") ;; *) fail "C0 without a marker the stale beacon reads unsupervised: $(status "$home")" ;; esac
pass "C0 a lead with a stale beacon and no checkpoint marker still reads unsupervised"

checkpoint() {  # <home> <seconds>
  JG_HOME=$1 JG_ROOT_OVERRIDE=$1 JG_STATE_OVERRIDE=$1/state JG_CONFIG_OVERRIDE=$1/config "$fx/jg-watch-checkpoint.sh" --seconds "$2"
}
out=$(checkpoint "$home" 180 2>&1) || fail "C1 the checkpoint stand-in run failed: $out"
[ -f "$home/state/.checkpoint-cadence" ] || fail "C1 the checkpoint must write state/.checkpoint-cadence on any harness"
grep -qx 'cadence=180' "$home/state/.checkpoint-cadence" || fail "C1 the marker must carry the cadence: $(cat "$home/state/.checkpoint-cadence")"
case "$(status "$home")" in "true true 0 checkpoint "*) ;; *) fail "C1 a lead within its cadence must read as supervised: $(status "$home")" ;; esac
pass "C1 a checkpoint lead within cadence plus grace is healthy, with the beacon still stale"

# Past cadence plus grace (180 + 300): the dead-lead case reads unsupervised again.
age_file "$home/state/.checkpoint-cadence" 470
case "$(status "$home")" in "true true "*) ;; *) fail "C2 just inside cadence plus grace is healthy: $(status "$home")" ;; esac
age_file "$home/state/.checkpoint-cadence" 490
case "$(status "$home")" in "true false "*) ;; *) fail "C2 past cadence plus grace must alarm: $(status "$home")" ;; esac
printf 'cadence=banana\n' > "$home/state/.checkpoint-cadence"
case "$(status "$home")" in "true false "*) ;; *) fail "C2 a marker with no usable cadence must not count: $(status "$home")" ;; esac
pass "C2 past cadence plus grace, or with an unusable marker, the lead alarms"

fi

if want R; then
# --- R1: ready rows are filtered by the home's registry -----------------------------------------
home=$(lead_home r '- acme [local-trunk] - fixture (added 2026-11-09)' '- plain - bare entry (added 2026-11-09)')
ready "$home" jg-in,acme jg-out,elsewhere jg-none,- jg-bare,plain
got=$(rows "$home" | paste -sd, -)
[ "$got" = "jg-bare plain,jg-in acme,jg-none -" ] \
  || fail "R1 only rows of registered projects, and a row naming none, may remain: $got"
grep -q 'jg-out' "$TMP_ROOT/r/parent/state/lead1.status" 2>/dev/null || fail "R1 the out-of-scope row must be handed back to the parent"
[ "$(grep -c 'jg-out' "$TMP_ROOT/r/parent/state/lead1.status")" -eq 1 ] || fail "R1 the hand-back must be one line"
rows "$home" >/dev/null; rows "$home" >/dev/null
[ "$(grep -c 'jg-out' "$TMP_ROOT/r/parent/state/lead1.status")" -eq 1 ] || fail "R1 repeated reads must hand a row back once"
pass "R1 an out-of-scope ready row is dropped and handed back once"

home=$(lead_home r2 '- acme [local-trunk] - fixture (added 2026-11-09)')
ready "$home" jg-out,elsewhere
case "$(status "$home")" in "false false 0 never") ;; *) fail "R1 a lead holding only out-of-scope rows needs no supervision: $(status "$home")" ;; esac
ready "$home" jg-in,acme
case "$(status "$home")" in "true false 1 never") ;; *) fail "R1 an in-scope ready row still needs supervision: $(status "$home")" ;; esac
pass "R1 only in-scope ready work makes a lead need supervision"

# A main home (no marker) and a lead with no registry keep every row.
home=$(lead_home r3)
ready "$home" jg-out,elsewhere
[ -n "$(rows "$home")" ] || fail "R1 a lead with no registry cannot tell scope, so it keeps every row"
rm -f "$home/.jg-squad-lead-home"; printf -- '- acme [local-trunk] - fixture\n' > "$home/data/projects.md"
[ -n "$(rows "$home")" ] || fail "R1 a main home keeps every row"
pass "R1 a main home and a lead with no registry keep every row"

fi

if want B; then
# --- B1: the checkpoint's own bound -------------------------------------------------------------
# A host that ignores TERM was the unbounded case: its outer bound sent TERM and never KILL.
home=$(lead_home b)
printf 'codex fixture\n' > "$home/config/supervision-host"
cat > "$fx/jg-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT HUP
echo $$ > "$JG_HOME/host.pid"
for _ in $(seq 100); do sleep 1; done
SH
chmod +x "$fx/jg-supervision-host.sh"
start=$(date +%s)
JG_HOME=$home JG_ROOT_OVERRIDE=$home JG_STATE_OVERRIDE=$home/state JG_CONFIG_OVERRIDE=$home/config \
  JG_SUPERVISION_HOST_TURN_TIMEOUT=1 JG_SUPERVISION_ENGINE_GRACE=1 JG_CHECKPOINT_HOST_GRACE=1 JG_CHECKPOINT_KILL_GRACE=2 \
  timeout 40 "$fx/jg-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
pid=$(cat "$home/host.pid" 2>/dev/null || true)
[ "$rc" -ne 124 ] || fail "B1 a host that ignores TERM must not hang the checkpoint: still running after 40s"
[ "$elapsed" -lt 30 ] || fail "B1 the checkpoint must end within its bound plus grace (took ${elapsed}s)"
[ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || { kill -KILL "$pid" 2>/dev/null; fail "B1 the host child must be dead once the checkpoint ends"; }
grep -q 'hard-bound' "$home/state/.checkpoint-cadence" || fail "B1 the checkpoint must record why it ended: $(cat "$home/state/.checkpoint-cadence" 2>/dev/null)"
pass "B1 a host that ignores TERM is killed at the bound plus grace, and the marker says why"

# A watcher that ignores INT is killed at the cleanup bound (the path the checkpoint already bounded).
home=$(lead_home b2)
cat > "$fx/jg-watch.sh" <<'SH'
#!/usr/bin/env bash
trap '' INT TERM HUP
echo $$ > "$JG_HOME/watch.pid"
for _ in $(seq 100); do sleep 1; done
SH
start=$(date +%s)
JG_HOME=$home JG_ROOT_OVERRIDE=$home JG_STATE_OVERRIDE=$home/state JG_CONFIG_OVERRIDE=$home/config \
  timeout 40 "$fx/jg-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -ne 124 ] || [ "$elapsed" -lt 30 ] || fail "B1 a watcher that ignores INT must not hang the checkpoint"
pid=$(cat "$home/watch.pid" 2>/dev/null || true)
[ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || { kill -KILL "$pid" 2>/dev/null; fail "B1 the watcher child must be dead once the checkpoint ends"; }
pass "B1 a watcher that ignores INT is killed at the cleanup bound"

fi

printf 'jg-supervision-lead: ok\n'
