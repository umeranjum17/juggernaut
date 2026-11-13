#!/usr/bin/env bash
# The four delivery words as the live-claim tool speaks them, driven through the tool Main's reports call, and the lead
# report helper a lead reports through: a change two homes run reads `In use, <version>, homes <ids>`, a change on the trunk that no home
# runs reads `Landed, not in use`, and a recorded release reads `Released`. The old word merged-not-released is never
# written, though a claim that already says it is accepted.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/jg-squad-lead-report.sh"
TMP_ROOT=$(jg_test_tmproot jg-live-claim-stages)
g() { git -c user.email=t@t -c user.name=t "$@"; }

# Main with two commits on its trunk; lead1 runs only the first. The parent channel of a lead report is a directory.
MAIN="$TMP_ROOT/main"; LEAD="$TMP_ROOT/lead1"
mkdir -p "$MAIN/data" "$MAIN/state" "$MAIN/parent/state"
g init -q "$MAIN" && g -C "$MAIN" commit -q --allow-empty -m base && g -C "$MAIN" tag c-1
g -C "$MAIN" commit -q --allow-empty -m 'h49b-a: first' -m 'Ticket: h49b-a'
git clone -q "$MAIN" "$LEAD"
g -C "$MAIN" commit -q --allow-empty -m 'h49b-b: second' -m 'Ticket: h49b-b'
printf -- '- lead1 - test lead (home: %s; scope: all; projects: juggernaut; added 2026-11-13)\n' "$LEAD" > "$MAIN/data/squad_leads.md"
# The reporting home is a lead home with its own release record; it sees only itself, so the homes a claim names are
# read from Main.
REP="$TMP_ROOT/reporter"
mkdir -p "$REP/data" "$REP/state" "$MAIN/parent/state"
printf 'umer\n' > "$REP/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN/parent" > "$REP/.jg-squad-lead-parent"
mkdir -p "$TMP_ROOT/probes"
for svc in nats dapr; do printf '#!/bin/sh\necho up\n' > "$TMP_ROOT/probes/$svc"; chmod +x "$TMP_ROOT/probes/$svc"; done
export JG_LIVE_SERVICES_PROBES="$TMP_ROOT/probes"

report() {  # <claim> -> the note the parent channel received
  rm -f "$MAIN/parent/state/umer.status"
  JG_HOME=$REP bash "$REPORT" "done" abcdef0123456789 "$1" 2>/dev/null || fail "the report helper refused: $1"
  cat "$MAIN/parent/state/umer.status"
}

claim() { JG_HOME=$MAIN bash "$ROOT/bin/jg-live-claim.sh" "done" "$1" 2>/dev/null; }

out=$(claim 'Fixed the first slice, ticket h49b-a. ')
assert_contains "$out" 'In use, c-1-1-g' 'a change both homes run is In use with its version'
assert_contains "$out" 'homes lead1, primary' 'it names every home that runs it'
case "$out" in *'not yet in'*) fail 'a home that runs it was named as behind' ;; esac

out=$(claim 'Fixed the second slice, ticket h49b-b.')
assert_contains "$out" 'In use, c-1-2-g' 'the newer change carries its own version'
assert_contains "$out" 'homes primary; not yet in: lead1' 'a home behind the change is named, not counted as running it'

g -C "$MAIN" commit -q --allow-empty -m 'h49b-c: third' -m 'Ticket: h49b-c'
git -C "$MAIN" update-ref refs/heads/side "$(g -C "$MAIN" commit-tree -p "$(git -C "$MAIN" rev-parse HEAD)" -m 'h49b-d: x' -m 'Ticket: h49b-d' 'HEAD^{tree}')"
git -C "$MAIN" rev-parse side > "$MAIN/state/trunk-tip-juggernaut"
out=$(claim 'Fixed the side slice, ticket h49b-d.')
assert_contains "$out" 'Landed, not in use: Fixed the side slice' 'a change no home runs is Landed, not in use'
case "$out" in *merged-not-released*|*'In use,'*) fail 'the old word or In use was written for a change no home runs' ;; esac

printf 'v2.0.0 2026-11-13T10:00Z repo=o/r prs=5 npm=2.0.0\n' > "$REP/data/releases"
out=$(report 'Fixed it; live: v2.0.0 @ https://app.test #tickets/jg-abc')
assert_contains "$out" 'Released, v2.0.0 on GitHub main and npm 2.0.0' 'a recorded release reads Released with npm'
printf 'v2.0.0 2026-11-13T10:00Z repo=o/r prs=5\n' > "$REP/data/releases"
out=$(report 'Fixed it; live: v2.0.0 @ https://app.test #tickets/jg-abc')
assert_contains "$out" 'Released, v2.0.0 on GitHub main (npm not recorded)' 'a release with no npm record says so'

if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  jq -n --arg v "$(git -C "$ROOT" describe --tags --always 2>/dev/null)" '{
    target: {version: $v},
    start: "a Main home and a lead home on one trunk, the lead one commit behind, and a release record",
    steps: ["report done for a ticket both homes run", "report done for a ticket only Main runs", "report done for a ticket no home runs", "report done with a recorded release"],
    result: "In use, <version>, homes a, b; not yet in: for the lagging home; Landed, not in use; Released, <ref> on GitHub main and npm"
  }' > "$DONE_DONE_EVIDENCE_ROOT/steps.json" || fail 'could not write the step record'
fi
pass 'the four delivery words'
printf 'jg-live-claim-stages: ok\n'
