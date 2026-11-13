#!/usr/bin/env bash
# Journey: critical-stall.sh check against a fixture home. The real bin/jg-critical-path.sh reads a stub probe
# (nats pending, accounts pending, one PR); a gh stub answers the PR's commit time; the card poster
# is a recorder; the real bin/jg-alert.sh raises the alert. a) a row pending 30 h with a 30 h old commit raises one stranded alert and one card; b) the next sweep
# raises nothing; c) a new 1 h old commit raises nothing; d) a row with no PR raises one "no PR" alert;
# e) a row turning live clears its first-seen time; f) stale-pr-alarm's record skips the card, not the alert;
# g) the wiring installs a shim that registers, and the unwiring removes it.
# Usage: critical-stall/tests/critical-stall.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=$(cd "$SRC/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d XDG_DATA_HOME=$d/share
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/data" "$FM/config" "$FM/bin"
cp "$ROOT/bin/jg-critical-path.sh" "$FM/bin/"
printf 'critical=nats,accounts\nproject=proj\n' > "$FM/config/migration-card"
echo "$d/board.json" > "$FM/config/fleet-board"
PR=https://github.com/o/r/pull/7
export STUB_PROBE=$d/probe.state STUB_COMMIT=$d/commit STUB_LOG=$d/calls
cat > "$d/probe" <<'STUB'
#!/usr/bin/env bash
st=$(awk -v s="$1" '$1 == s { print $2 }' "$STUB_PROBE"); pr=$(awk -v s="$1" '$1 == s { print $3 }' "$STUB_PROBE")
printf 'part %s\t%s\tmeasured\t%s\n' "$1" "${st:-absent}" "${pr:-no open pull request}"
STUB
cat > "$d/gh-axi" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$2" = "repos/o/r/pulls/7/commits?per_page=100" ] || exit 1
cat "$STUB_COMMIT"
STUB
cat > "$d/rec" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
STUB
chmod +x "$d/probe" "$d/gh-axi" "$d/rec"
ln -s "$d/rec" "$d/card"
export JG_MIGRATION_LIVE_BIN=$d/probe JG_STALL_GH=$d/gh-axi JG_STALL_ALERT=$SRC/../../bin/jg-alert.sh JG_STALL_CARD=$d/card
NOW=$(date +%s); export JG_STALL_NOW=$NOW
ago() { date -u -d "@$(( NOW - $1 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ; }
commit() { printf '%s\t%s\n' "$1" "$(ago "$2")" > "$STUB_COMMIT"; }
pending_since() { printf 'nats\t%s\n' "$(( NOW - $1 * 3600 ))" > "$FM/data/critical-stall/seen.tsv"; }
sweep() { : > "$STUB_LOG"; : >> "$FM/state/.wake-queue"; WAKES=$(wc -l < "$FM/state/.wake-queue"); "$SRC/critical-stall.sh" check "$FM" > "$d/out" 2>&1; }
# The note is now the central stranded alert: the real jg-alert.sh raises it and its wake reaches the queue.
calls() { if [ "$1" = note ]; then tail -n +"$(( WAKES + 1 ))" "$FM/state/.wake-queue" | grep -c "alert stranded (P3) at rung 2 for lead: nats" || true; else grep -c "^$1 " "$STUB_LOG" || true; fi; }
fails=0
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/critical-stall.log}  # the sealed run keeps this log
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

printf 'nats pending %s\naccounts live -\n' "$PR" > "$STUB_PROBE"
mkdir -p "$FM/data/critical-stall"
pending_since 30; commit sha1 30
sweep
check "a: one note" "$(calls note)" 1
check "a: one card" "$(calls card)" 1
check "a: the alert is the lead's stranded alert for the row" "$(calls note)" 1
check "a: the card is a design pick on the board" "$(grep '^card' "$STUB_LOG" | grep -c -- "--board $d/board.json --must design-pick")" 1
check "a: the check prints nothing" "$(cat "$d/out")" ""
sweep
check "b: a second sweep raises nothing" "$(calls note)$(calls card)" 00
commit sha2 1
sweep
check "c: a new commit 1 h old raises nothing" "$(calls note)$(calls card)" 00
commit sha3 40
sweep
check "c: a later stall on another commit alerts again" "$(calls note)$(calls card)" 11
printf 'nats pending no open pull request\naccounts live -\n' > "$STUB_PROBE"
sweep
check "d: no PR for 30 h raises one alert" "$(calls note)" 1
sweep
check "d: and only one" "$(calls note)" 0
pending_since 10; : > "$FM/data/critical-stall/alerts.jsonl"
sweep
check "d: a row pending under 24 h raises nothing" "$(calls note)$(calls card)" 00
printf 'nats live -\naccounts live -\n' > "$STUB_PROBE"
sweep
check "e: a live row clears its first-seen time" "$(cat "$FM/data/critical-stall/seen.tsv")" ""

# f: stale-pr-alarm already alerted on this pull request after its newest commit: the note goes, the card does not.
printf 'nats pending %s\naccounts live -\n' "$PR" > "$STUB_PROBE"
pending_since 30; commit sha4 30; : > "$FM/data/critical-stall/alerts.jsonl"
mkdir -p "$FM/data/jg-merge-on-green/stale-pr-alarm"
echo "no checks and no update for 24 h" > "$FM/data/jg-merge-on-green/stale-pr-alarm/o__r.7"
sweep
check "f: the note is sent and the card is skipped" "$(calls note)$(calls card)" 10

# g: the wiring installs and registers, the unwiring removes.
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
check "g: the shim runs the installed check for this home" "$(sed -n 2p "$FM/state/critical-stall.check.sh")" "exec $XDG_DATA_HOME/jg-critical-stall/critical-stall.sh check $FM"
check "g: the check is registered" "$(cat "$FM/state/registered")" critical-stall
"$SRC/unwiring.sh" "$FM" >/dev/null
gone=0; [ -e "$FM/state/critical-stall.check.sh" ] || gone=$((gone + 1)); [ -e "$XDG_DATA_HOME/jg-critical-stall" ] || gone=$((gone + 1))
check "g: the unwiring removes the shim and the command" "$gone" 2
[ "$fails" -eq 0 ] && say "PASS critical-stall" || { say "FAIL critical-stall: $fails" >&2; exit 1; }
# The sealed run keeps the steps of the journey beside its log, so the claim can be judged against them.
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<'J'
{"target":{"version":"critical-stall.sh and the real bin/jg-alert.sh from this checkout, run against a fixture home"},
 "start":"a fixture home where the critical row nats has been pending 30 hours with a 30 hour old commit",
 "steps":["the critical-stall check runs and finds the stalled row","the check raises the central stranded alert for the row through jg-alert.sh raise and deliver","the next sweep runs with the alert still live"],
 "result":"the lead's wake queue holds exactly one stranded alert wake for the row and the check printed nothing; the next sweep adds none; the transcript ends with PASS critical-stall"}
J
fi
