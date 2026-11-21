#!/usr/bin/env bash
# Journey: lead-sweep.sh run sweeps a lane whose last status line is `resolved` (answered), through the real caller.
# a) a resolved lane whose head is on the trunk is torn down once, with its id and no --force;
# b) a resolved lane whose head is not landed is not torn down and is reported once; the next beat prints nothing;
# c) a done lane that has not landed prints nothing; a paused lane is never touched.
# Usage: tests/jg-lead-sweep-end-states.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../core/lead-sweep" && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT
mkdir -p "$HOME"; git config --global user.email umer@example.test; git config --global user.name Umer; git config --global init.defaultBranch trunk
FM=$d/fm; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$P"
ln -sn "$SRC/../../bin" "$FM/bin"; ln -sn "$SRC/../../core" "$FM/core"
mkdir -p "$FM/config"; echo off > "$FM/config/wake-bus"
git -C "$P" init -q; echo 1 > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm base
export STUB_LOG=$d/calls
cat > "$d/teardown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ -f "$JG_STATE_OVERRIDE/refuse-$1" ]; then cat "$JG_STATE_OVERRIDE/refuse-$1" >&2; exit 1; fi
if [ -f "$JG_STATE_OVERRIDE/lost-$1" ]; then echo 'error: slot lost' >&2; exit 4; fi
if [ "${2:-}" = --park ]; then : > "$JG_STATE_OVERRIDE/$1.parked"; fi
rm -f "$JG_STATE_OVERRIDE/$1.meta"
STUB
cat > "$d/control" <<'STUB'
#!/usr/bin/env bash
date +%s > "$JG_STATE_OVERRIDE/$1.exit"
STUB
cat > "$d/agent" <<'STUB'
#!/usr/bin/env bash
echo alive
STUB
chmod +x "$d/teardown" "$d/control" "$d/agent"
export JG_LEAD_SWEEP_TEARDOWN=$d/teardown JG_LEAD_SWEEP_CONTROL=$d/control JG_LEAD_SWEEP_AGENT=$d/agent
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
lane() {
  git -C "$P" branch "fm/$1" trunk; git -C "$P" checkout -q "fm/$1"; echo "$1" > "$P/$1"; git -C "$P" add "$1"
  git -C "$P" commit -qm "$1"; git -C "$P" checkout -q trunk
  printf 'kind=ship\nproject=%s\nbranch=fm/%s\nspawn_gen=s1\nworktree=%s\n' "$P" "$1" "$P" > "$FM/state/$1.meta"
  printf '%s\n' "$2" > "$FM/state/$1.status"
}
onto() { git -C "$P" merge -q --no-ff "fm/$1" -m "land $1"; git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"; }
git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"
sweep() { : > "$STUB_LOG"; "$SRC/lead-sweep.sh" run "$FM" > "$d/out" 2>&1; }
tore() { grep -c "^$1\$" "$STUB_LOG" || true; }

lane answered 'resolved [at=1]: answered'; lane open 'resolved [at=1]: answered'; lane waiting 'done [at=1]: ready'; lane parked 'paused [at=1]: wait'
onto answered
sweep
check "a: the landed resolved lane is torn down once" "$(tore answered)" 1
check "a: it is reported cleaned up" "$(grep -c '^lead-sweep: answered cleaned up (its head is on the trunk)' "$d/out")" 1
check "b: the unlanded resolved lane is not torn down" "$(tore open)" 0
check "b: it is reported once" "$(grep -c 'open ended as resolved, left alone' "$FM/state/.wake-queue")" 1
sweep
check "b: the next beat prints nothing" "$(wc -c < "$d/out" | tr -d ' ')" 0
check "c: the unlanded done lane and the paused lane are not torn down" "$(tore waiting)$(tore parked)" 00
# The real central alert owns age and state; the snapshot owns only the observed return action.
field() { sed -n "s/^$2=//p" "$1"; }
record=$FM/state/alerts/drift--lead-sweep-open-s1.rec
snapshot=$FM/data/lead-sweep/open-s1.capacity
check "d: refusal is owned by the lead" "$(field "$snapshot" owner)" lead
check "d: snapshot identifies the home and exact generation" "$(field "$snapshot" home):$(field "$snapshot" task):$(field "$snapshot" generation)" "$FM:open:s1"
check "d: snapshot links the central obligation" "$(field "$snapshot" alert_key)" drift--lead-sweep-open-s1
check "d: snapshot retains branch head" "$(field "$snapshot" head)" "$(git -C "$P" rev-parse fm/open)"
check "d: copy presence is not reusable capacity" "$(field "$snapshot" inventory)" copy-present-slot-unverified
check "d: next action requires guarded return" "$(field "$snapshot" next_action)" 'preserve bytes and branch; use guarded return; prove reusable slot'
since=$(field "$record" since)
lane dirty 'done [at=1]: ready'; onto dirty
echo 'REFUSED: tracked work remains' > "$FM/state/refuse-dirty"
JG_ALERT_NOW=100 sweep
dirty=$FM/state/alerts/drift--lead-sweep-dirty-s1.rec
check "e: normal cleanup refusal creates a pending obligation" "$(field "$dirty" state):$(field "$dirty" since)" open:100
echo 'REFUSED: ignored valuable artifact remains' > "$FM/state/refuse-dirty"
JG_ALERT_NOW=200 sweep
check "e: changed refusal keeps the original action age" "$(field "$dirty" since)" 100
check "e: current reason is printed for the lead" "$(grep -c 'ignored valuable artifact remains' "$d/out")" 1
check "e: central record retains the current reason" "$(field "$dirty" text | grep -c 'ignored valuable artifact remains')" 1
check "e: repeated raise actually delivers the current reason" "$(grep -c 'ignored valuable artifact remains' "$FM/state/.wake-queue")" 1
check "e: repeated refusal does not resolve the obligation" "$(field "$dirty" state)" open
printed=$(JG_HOME=$FM JG_STATE_OVERRIDE=$FM/state "$FM/bin/jg-alert.sh" raise drift lead-sweep-dirty-s1 --repeat --print)
check "e: repeated print returns a payload instead of an undelivered ring" "$(printf '%s\n' "$printed" | grep -c '^alert drift (P2)')" 1
cat > "$d/refuse-bus" <<'STUB'
#!/usr/bin/env bash
echo 'lab transport refused' >&2
exit 1
STUB
chmod +x "$d/refuse-bus"
echo 'REFUSED: retention needs repair' > "$FM/state/refuse-dirty"
JG_BUS_BIN=$d/refuse-bus sweep
check "e: failed repeated delivery exposes its real cause" "$(grep -c 'lab transport refused' "$d/out")" 1
check "e: failed delivery leaves the original age and duty" "$(field "$dirty" state):$(field "$dirty" since)" open:100
sweep
check "e: failed repeated delivery is retried" "$(grep -c 'retention needs repair' "$d/out")" 1
check "e: retry delivers the new reason" "$(grep -c 'retention needs repair' "$FM/state/.wake-queue")" 1
rm "$FM/state/refuse-dirty"; : > "$FM/state/lost-dirty"; sweep
check "f: lost slot remains an open obligation" "$(field "$dirty" state):$(field "$dirty" since)" open:100
check "f: lost slot names repair and proof" "$(grep -c 'repair and prove reusable capacity' "$FM/data/lead-sweep/dirty-s1.capacity")" 1
rm "$FM/state/lost-dirty"; sweep
check "f: command success alone cannot close capacity duty" "$(field "$dirty" state):$(field "$dirty" since)" open:100
check "f: success still requires actual reusable-slot proof" "$(field "$FM/data/lead-sweep/dirty-s1.capacity" next_action)" 'verify preserved bytes and authoritative reusable slot; command success alone is not recovery'
printf '%s\n' 'paused [at=1] [wait=lead] [reason=parked]: retain' > "$FM/state/open.status"
echo 'REFUSED: dirty park' > "$FM/state/refuse-open"; sweep
check "g: refused park preserves the same obligation" "$(field "$record" state):$(field "$record" since)" "open:$since"
rm "$FM/state/refuse-open"; sweep
check "g: successful park is not fulfilled work" "$(field "$record" state):$(field "$record" since)" "open:$since"
check "g: retained branch remains reachable" "$(git -C "$P" rev-parse fm/open)" "$(field "$snapshot" head)"
check "g: no force is used" "$(grep -c -- '--force' "$STUB_LOG" || true)" 0
lane again 'resolved [at=1]: answered'; sweep
sed 's/spawn_gen=s1/spawn_gen=s2/' "$FM/state/again.meta" > "$d/meta"; mv "$d/meta" "$FM/state/again.meta"; sweep
check "h: new generation gets its own duty without closing old one" "$(field "$FM/state/alerts/drift--lead-sweep-again-s1.rec" state):$(field "$FM/state/alerts/drift--lead-sweep-again-s2.rec" state)" open:open
lane legacy 'resolved [at=1]: answered'; sed '/^spawn_gen=/d' "$FM/state/legacy.meta" > "$d/meta"; mv "$d/meta" "$FM/state/legacy.meta"; sweep
check "h: absent generation stays explicitly unknown" "$(field "$FM/data/lead-sweep/legacy.capacity" generation)" unknown
lane retry 'resolved [at=1]: answered'
ln -sn "$d/no-write" "$FM/data/lead-sweep/retry-s1.capacity"; sweep
check "i: failed retention destination is visible" "$(grep -c 'retry capacity snapshot failed' "$d/out")" 1
check "i: failed retention is not cached as handled" "$(test ! -e "$FM/data/lead-sweep/retry.reported" && echo absent)" absent
rm "$FM/data/lead-sweep/retry-s1.capacity"; sweep
check "i: next sweep retries the owned action" "$(field "$FM/state/alerts/drift--lead-sweep-retry-s1.rec" state)" open
lane unread 'paused [at=1] [wait=lead] [reason=parked]: retain'
mkdir -p "$FM/state/unread.inbox"; echo retain > "$FM/state/unread.inbox/001.msg"; sweep
check "j: unread input prevents the park" "$(tore 'unread --park')" 0
check "j: an unrelated done line cannot close an old capacity duty" "$(field "$record" state)" open
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
