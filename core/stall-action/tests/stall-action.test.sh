#!/usr/bin/env bash
# Journey: stall-action.sh check against a fixture home. The watcher's own per-window records stand in for live
# panes: `.hash-<key>` (rewritten only when the pane tail changes, so its age is the time the output stayed the same)
# and `.count-<key>` (rewritten on every poll, so a fresh one proves the watcher is looking). The interrupt and the
# re-ring are recorders; the status classifier is the real one.
# a) a worker whose pane output stayed unchanged past 5 min gets one interrupt and one re-ring, and the check prints nothing;
# b) the next sweep does nothing (one action per hash); a pane that changes and stalls again is acted on again;
# c) a changing pane, a declared `paused:` worker, a finished worker, an exited worker, a pane the watcher is not
#    polling, and a worker with no pane record are untouched;
# d) a lead has a 10 min bound; config/stall-bound-workers and config/stall-bound-leads replace the defaults;
# e) a failed interrupt is retried once on the next sweep and then given up for that hash;
# f) the wiring installs a shim that registers, and the unwiring removes it.
# Usage: stall-action/tests/stall-action.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=$(cd "$SRC/../.." && pwd -P)
[ -x "$SRC/stall-action.sh" ] || { echo "FAIL: $SRC/stall-action.sh is missing or not executable" >&2; exit 1; }
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}   # the real classifier binary is built once into the user cache
export HOME=$d/home TMPDIR=$d XDG_DATA_HOME=$d/share
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/data" "$FM/config" "$FM/bin"
export JG_STALL_ACTION_CLASSIFY=$ROOT/bin/jg-classify.sh   # the real status classifier
export STUB_LOG=$d/calls STUB_FAIL=$d/fail
cat > "$d/rec" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
[ "$(basename "$0")" != control ] || [ ! -e "$STUB_FAIL" ] || exit 1
STUB
chmod +x "$d/rec"
ln -s "$d/rec" "$d/control"; ln -s "$d/rec" "$d/send"
cat > "$d/peek" <<'STUB'
#!/usr/bin/env bash
cat "$PANES/$1"
STUB
chmod +x "$d/peek"; export PANES=$d/panes; mkdir -p "$PANES"
export JG_STALL_ACTION_CONTROL=$d/control JG_STALL_ACTION_SEND=$d/send JG_STALL_ACTION_PEEK=$d/peek
NOW=$(date +%s); export JG_STALL_ACTION_NOW=$NOW
fails=0
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/stall-action.log}  # the sealed run keeps this log
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

# lane <task> <kind> <minutes unchanged> [hash text]: a task with a pane whose output has stayed the same that long.
# A worker's evidence is the watcher's hash record; a lead's is this check's own first-seen record of its pane.
lane() {
  local t=$1 kind=$2 min=$3 text=${4:-tail-of-$1} key=default_w1_p$1
  printf 'window=default:w1:p%s\nkind=%s\n' "$t" "$kind" > "$FM/state/$t.meta"
  if [ "$kind" = squad_lead ]; then
    printf '%s' "$text" > "$PANES/$t"; mkdir -p "$FM/data/stall-action/seen"
    printf '%s %s\n' "$(printf '%s' "$text" | md5sum | cut -c1-32)" "$(( NOW - min * 60 ))" > "$FM/data/stall-action/seen/$key"
    return 0
  fi
  printf '%s' "$text" > "$FM/state/.hash-$key"
  touch -d "@$(( NOW - min * 60 ))" "$FM/state/.hash-$key"
  echo 9 > "$FM/state/.count-$key"          # the watcher polled it just now
  touch -d "@$(( NOW - 20 ))" "$FM/state/.count-$key"
}
status() { printf '%s\n' "$2" >> "$FM/state/$1.status"; }
sweep() { : > "$STUB_LOG"; "$SRC/stall-action.sh" check "$FM" > "$d/out" 2>&1; }
calls() { grep -c "^$1 $2" "$STUB_LOG" || true; }
actions() { grep -c "\"task\":\"$1\"" "$FM/data/stall-action/actions.jsonl" 2>/dev/null || true; }

# a: a stalled worker is interrupted once and re-rung once, with no output.
lane w1 ship 6
status w1 "working [at=$NOW]: fixing the test"
sweep
check "a: one interrupt through the control plane" "$(calls control 'w1 interrupt')" 1
check "a: one re-ring through the data plane" "$(calls send 'w1 Your last call')" 1
check "a: the re-ring tells the worker what happened" "$(grep -c 'interrupted' <(grep '^send w1' "$STUB_LOG"))" 1
check "a: the check prints nothing" "$(cat "$d/out")" ""
check "a: both steps are recorded" "$(actions w1)" 2
sweep
check "b: a second sweep over the same hash does nothing" "$(calls control w1)$(calls send w1)" 00
lane w1 ship 7 other-tail     # the pane changed, then stalled again, 10 minutes after the first action
sweep
check "b: a new stalled hash inside the 30 minute cooldown is left alone" "$(calls control w1)$(calls send w1)" 00
NOW=$(( NOW + 2400 )); export JG_STALL_ACTION_NOW=$NOW
lane w1 ship 7 other-tail
sweep
check "b: a new stalled hash after the cooldown is acted on again" "$(calls control 'w1 interrupt')$(calls send w1)" 11

# c: panes that are not stalled are untouched.
rm -f "$FM/state/w1.meta"
: > "$FM/data/stall-action/actions.jsonl"
lane changing ship 1;                      status changing "working [at=$NOW]: x"
lane paused ship 30;                       status paused "paused [at=$NOW]: waiting for the pipeline run"
lane finished ship 30;                     status finished "done [at=$NOW]: ready in branch b"
lane exited ship 30;                       touch "$FM/state/exited.exit"
lane unpolled ship 30;                     touch -d "@$(( NOW - 3600 ))" "$FM/state/.count-default_w1_punpolled"
lane idle ship 30;                         echo "v1 gen=g seq=2 state=idle source=claude-hook event=stop ts=$NOW" > "$FM/state/idle.busy-state"
printf 'window=default:w1:pnopane\nkind=ship\n' > "$FM/state/nopane.meta"
printf 'kind=ship\n' > "$FM/state/nowindow.meta"
sweep
check "c: changing, paused, finished, exited, idle, unpolled and pane-less tasks are untouched" "$(wc -l < "$STUB_LOG")" 0
lane paused ship 30; status paused "working [at=$NOW]: the pipeline finished"
sweep
check "c: a pause that was resolved no longer exempts" "$(calls control 'paused interrupt')" 1

# d: a lead has its own bound; the config files replace the defaults.
: > "$FM/data/stall-action/actions.jsonl"
printf 'window=default:w1:pnew\nkind=squad_lead\n' > "$FM/state/newlead.meta"; printf 'a pane' > "$PANES/newlead"
sweep
check "d: a lead seen for the first time starts its clock and is not acted on" "$(calls control newlead)$(test -s "$FM/data/stall-action/seen/default_w1_pnew" && echo seen)" 0seen
printf 'a different pane' > "$PANES/newlead"; sweep
check "d: a lead whose pane changed restarts its clock" "$(cut -d' ' -f2 "$FM/data/stall-action/seen/default_w1_pnew")" "$NOW"
rm -f "$FM/state/newlead.meta"
lane lead1 squad_lead 7; lane lead2 squad_lead 11; lane w2 ship 4
sweep
check "d: a lead stalled 7 min is untouched and one stalled 11 min is interrupted" "$(calls control 'lead1')$(calls control 'lead2 interrupt')" 01
check "d: a lead is re-rung as a fire-and-forget record with a 16-hex delivery id" "$(grep -c '^send lead2 --fire-and-forget [0-9a-f]\{16\} ' "$STUB_LOG")" 1
check "d: a worker stalled 4 min is untouched" "$(calls control w2)" 0
echo 3 > "$FM/config/stall-bound-workers"; echo 6 > "$FM/config/stall-bound-leads"
sweep
check "d: the configured bounds apply (worker 3 min, lead 6 min)" "$(calls control 'w2 interrupt')$(calls control 'lead1 interrupt')" 11
rm -f "$FM/config/stall-bound-workers" "$FM/config/stall-bound-leads"

# e: a failed interrupt is tried once more on the next sweep, then given up for that hash.
: > "$FM/data/stall-action/actions.jsonl"
for t in w1 changing paused finished exited idle unpolled lead1 lead2 w2; do rm -f "$FM/state/$t.meta"; done
lane f1 ship 9; touch "$STUB_FAIL"
sweep; sweep; sweep
check "e: a failing interrupt is tried twice for one hash and no re-ring is sent" "$(grep -c '"step":"interrupt","ok":false' "$FM/data/stall-action/actions.jsonl")$(grep -c '"step":"ring"' "$FM/data/stall-action/actions.jsonl" || true)" 20
rm -f "$STUB_FAIL"
sweep
check "e: no third try on the same hash" "$(calls control f1)$(calls send f1)" 00

# f: the wiring installs and registers, the unwiring removes.
cat > "$FM/bin/jg-check-register.sh" <<'STUB'
#!/bin/sh
echo "$1" >> "$JG_HOME/state/registered"
STUB
cat > "$FM/bin/jg-check-unregister.sh" <<'STUB'
#!/bin/sh
rm -f "$JG_HOME/state/$1.check.sh"
STUB
chmod +x "$FM/bin/"jg-check-*.sh
"$SRC/wiring.sh" "$FM" >/dev/null
check "f: the shim runs the installed check for this home" "$(sed -n 2p "$FM/state/stall-action.check.sh")" "exec $XDG_DATA_HOME/jg-stall-action/stall-action.sh check $FM"
check "f: the check is registered" "$(cat "$FM/state/registered")" stall-action
"$SRC/unwiring.sh" "$FM" >/dev/null
gone=0; [ -e "$FM/state/stall-action.check.sh" ] || gone=$((gone + 1)); [ -e "$XDG_DATA_HOME/jg-stall-action" ] || gone=$((gone + 1))
check "f: the unwiring removes the shim and the command" "$gone" 2
[ "$fails" -eq 0 ] && say "PASS stall-action" || { say "FAIL stall-action: $fails" >&2; exit 1; }
