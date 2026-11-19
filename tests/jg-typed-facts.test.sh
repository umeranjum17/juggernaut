#!/usr/bin/env bash
# Journey: the typed proof, writer, ready, retry and cursor facts (bin/jg-facts-lib.sh), read through `jg-machine-guard.sh fact`, each for a legal and an illegal case.
# b) I2 proof reuse: unset is on from the default; 0 is off from the env; a value that is not 0 or 1 is reported invalid, and reads as on as before.
# c) I3 writer capability: a forward move needs JG_TRUNK_WRITER, a delete needs JG_TRUNK_RETIRE equal to the ref; the real reference-transaction hook agrees.
# d) I4 admission: a done line is ready with its epoch; a working line is not ready; flush is due on request, count or age, else waits.
# e) I5 retry: a lane that never started waits, then relaunches once, then parks; the real lead sweep takes the step the fact names.
# f) I9 wake cursor: a stream with its marker is read at its classified position; a missing marker resets to 0 and says so.
# Usage: tests/jg-typed-facts.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT JG_TRUNK_SEALED_REUSE JG_TRUNK_WRITER JG_TRUNK_RETIRE
mkdir -p "$HOME"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
FM=$d/fm; mkdir -p "$FM/state" "$FM/data" "$FM/config"
export JG_HOME=$FM JG_STATE_OVERRIDE=$FM/state JG_DATA_OVERRIDE=$FM/data JG_CONFIG_OVERRIDE=$FM/config
G=$ROOT/bin/jg-machine-guard.sh
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
val() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'; }

# b) proof reuse
f=$("$G" fact reuse); check 'reuse: default is on' "$(val "$f" source)/$(val "$f" effective)" default/on
f=$(JG_TRUNK_SEALED_REUSE=0 "$G" fact reuse); check 'reuse: 0 is off from the env' "$(val "$f" source)/$(val "$f" effective)/$(val "$f" valid)" env/off/yes
f=$(JG_TRUNK_SEALED_REUSE=maybe "$G" fact reuse); check 'reuse: a stray value is invalid and reads as on' "$(val "$f" valid)/$(val "$f" effective)" no/on

# c) writer capability, against the real hook text that bin/jg-trunk.sh installs
P=$d/proj; git init -q "$P"; git -C "$P" commit -q --allow-empty -m base
tip=$(git -C "$P" rev-parse HEAD)
zero=0000000000000000000000000000000000000000
f=$("$G" fact writer refs/heads/trunk "$tip"); check 'writer: no env cannot move the trunk' "$(val "$f" capability)/$(val "$f" outcome)" none/refused
f=$(JG_TRUNK_WRITER=1 "$G" fact writer refs/heads/trunk "$tip"); check 'writer: JG_TRUNK_WRITER lets it move forward' "$(val "$f" capability)/$(val "$f" outcome)" write/allowed
f=$(JG_TRUNK_WRITER=1 "$G" fact writer refs/heads/trunk "$zero"); check 'writer: the writer alone cannot delete' "$(val "$f" capability)/$(val "$f" outcome)" none/refused
f=$(JG_TRUNK_RETIRE=refs/heads/trunk "$G" fact writer refs/heads/trunk "$zero"); check 'writer: retire for that ref can delete' "$(val "$f" capability)/$(val "$f" scope)" retire/process-env
# the hook text is rendered by ensure_guard's own `want=$(printf ...)` line, so the test runs that very line and installs its output
base=trunk
# shellcheck disable=SC2016,SC2154,SC2034 # the grep pattern is literal text; `want` is set by the evaluated line
eval "$(grep -m1 '^  want=\$(printf' "$ROOT/bin/jg-trunk.sh" | sed 's/^ *//')"
# shellcheck disable=SC2154
printf '%s' "$want" > "$P/.git/hooks/reference-transaction"; chmod +x "$P/.git/hooks/reference-transaction"
next=$(git -C "$P" commit-tree -p "$tip" -m next "$(git -C "$P" rev-parse "$tip^{tree}")")
git -C "$P" update-ref refs/heads/trunk "$next" "$tip" 2>/dev/null && rc=0 || rc=refused
check 'writer: the hook refuses a move with no capability, as the fact said' "$rc" refused
JG_TRUNK_WRITER=1 git -C "$P" update-ref refs/heads/trunk "$next" "$tip" && rc=0 || rc=$?
check 'writer: the hook allows a move with the capability, as the fact said' "$rc" 0
JG_TRUNK_WRITER=1 git -C "$P" update-ref -d refs/heads/trunk 2>/dev/null && rc=0 || rc=refused
check 'writer: the hook refuses a delete by the writer alone, as the fact said' "$rc" refused
JG_TRUNK_RETIRE=refs/heads/trunk git -C "$P" update-ref -d refs/heads/trunk && rc=0 || rc=$?
check 'writer: the hook allows the retire delete, as the fact said' "$rc" 0

# d) admission
printf 'working [at=5]: x\n' > "$FM/state/t1.status"
f=$("$G" fact ready t1); check 'ready: a working line is not ready' "$(val "$f" ready)/$(val "$f" ready_at)" no/-
printf 'done [at=1700000000]: ready in branch x\n' > "$FM/state/t1.status"
f=$("$G" fact ready t1); check 'ready: a done line is ready with its epoch' "$(val "$f" ready)/$(val "$f" ready_at)" yes/1700000000
printf 'done: ready\n' > "$FM/state/t1.status"
f=$("$G" fact ready t1); check 'ready: a done line with no time reads 0' "$(val "$f" ready_at)/$(val "$f" reason)" '0/done line names no time'
f=$("$G" fact ready none1); check 'ready: no status line is not ready' "$(val "$f" ready)/$(val "$f" reason)" 'no/no status line'
f=$("$G" fact flush "$d/nofile" 1 1000 1100 3 20); check 'flush: waits when nothing is due' "$(val "$f" flush)/$(val "$f" reason)" wait/none
f=$("$G" fact flush "$d/nofile" 3 1000 1100 3 20); check 'flush: the count is due' "$(val "$f" reason)" count
f=$("$G" fact flush "$d/nofile" 1 1000 2300 3 20); check 'flush: the age is due' "$(val "$f" reason)" age
: > "$d/asked"; f=$("$G" fact flush "$d/asked" 1 1000 1100 3 20); check 'flush: a request is due' "$(val "$f" reason)" requested

# e) retry: the real lead sweep takes the step the fact names
mkdir -p "$FM/data/lead-sweep"
printf 'kind=ship\nproject=%s\nbranch=fm/n1\n' "$P" > "$FM/state/n1.meta"; : > "$FM/state/n1.status"; : > "$FM/state/n1.status.empty"; rm -f "$FM/state/n1.status"
m=$(stat -c %Y "$FM/state/n1.meta")
f=$("$G" fact retry n1 $((m + 10)) 1800); check 'retry: a young lane waits' "$(val "$f" next)/$(val "$f" retries)/$(val "$f" clock_basis)" wait/0/record
f=$("$G" fact retry n1 $((m + 1900)) 1800); check 'retry: an old lane relaunches once' "$(val "$f" next)" relaunch
printf '%s\n' $((m + 1900)) > "$FM/data/lead-sweep/n1.relaunched"
f=$("$G" fact retry n1 $((m + 2000)) 1800); check 'retry: after a relaunch the clock restarts' "$(val "$f" next)/$(val "$f" clock_basis)/$(val "$f" retries)" wait/relaunch/1
f=$("$G" fact retry n1 $((m + 4000)) 1800); check 'retry: a second silence parks' "$(val "$f" next)" park
: > "$FM/state/.trunk-run-n1-x.lock"
f=$("$G" fact retry n1 $((m + 4000)) 1800); check 'retry: a lane under a landing lock takes no step' "$(val "$f" lock)/$(val "$f" next)" held/none
rm -f "$FM/state/.trunk-run-n1-x.lock"
cat > "$d/control" <<'STUB'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$STUB_LOG"
STUB
cat > "$d/teardown" <<'STUB'
#!/usr/bin/env bash
printf 'teardown %s\n' "$*" >> "$STUB_LOG"
STUB
printf '#!/usr/bin/env bash\necho dead\n' > "$d/agent"; chmod +x "$d/control" "$d/teardown" "$d/agent"
export STUB_LOG=$d/calls JG_LEAD_SWEEP_TEARDOWN=$d/teardown JG_LEAD_SWEEP_CONTROL=$d/control JG_LEAD_SWEEP_AGENT=$d/agent
rm -f "$FM/data/lead-sweep/n1.relaunched"
JG_LEAD_SWEEP_NOW=$((m + 10)) bash "$ROOT/core/lead-sweep/lead-sweep.sh" run "$FM" >/dev/null 2>&1 || true
check 'retry: the sweep takes no step for a young lane' "$(cat "$STUB_LOG" 2>/dev/null | wc -l | tr -d ' ')" 0
JG_LEAD_SWEEP_NOW=$((m + 1900)) bash "$ROOT/core/lead-sweep/lead-sweep.sh" run "$FM" >/dev/null 2>&1 || true
check 'retry: the sweep relaunches once, as the fact said' "$(grep -c '^control n1 relaunch' "$STUB_LOG" 2>/dev/null || true)" 1
JG_LEAD_SWEEP_NOW=$((m + 4000)) bash "$ROOT/core/lead-sweep/lead-sweep.sh" run "$FM" >/dev/null 2>&1 || true
check 'retry: the sweep parks on the second silence, as the fact said' "$(grep -c '^teardown n1 --park' "$STUB_LOG" 2>/dev/null || true)" 1

# f) wake cursor
. "$ROOT/bin/jg-wake-lib.sh"; . "$ROOT/bin/jg-classify-lib.sh"
sf=$FM/state/w1.status; printf 'working [at=1]: a\n' > "$sf"
f=$("$G" fact wake "$sf"); check 'wake: no marker resets to 0 and says so' "$(val "$f" classified)/$(val "$f" reset)/$(val "$f" reported)" 0/marker-absent/stale
size=$(stat -c %s "$sf")
sig=$(jg_wake_signal_sig "$sf")
marker=$(jg_wake_signal_seen_path "$FM/state" "$sf")
status_presentation_marker_report "$marker" "$sig"
f=$("$G" fact wake "$sf"); check 'wake: a reported marker reads current' "$(val "$f" reported)/$(val "$f" reset)" current/none
printf 'garbage' > "$marker"
f=$("$G" fact wake "$sf"); check 'wake: an unreadable marker reads as unreadable' "$(val "$f" classified)/$(val "$f" reset)" 0/unreadable
check 'wake: pending is the unclassified rest' "$(val "$f" pending)" "$size"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo 'all typed-fact checks passed'
