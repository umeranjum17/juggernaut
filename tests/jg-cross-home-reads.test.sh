#!/usr/bin/env bash
# A call made from one home that reads another home's tickets names that home with JG_HOME: the tickets tables are keyed by home,
# so a read that named no home would answer from the caller's own home. Two homes hold the same row id with different
# titles; every cross-home reader must return the other home's title.
# shellcheck disable=SC2016 # each bash -c body expands its positional arguments inside the child shell
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-cross-home-reads)
M=$T/main L=$T/lead
for h in "$M" "$L"; do mkdir -p "$h/config" "$h/state" "$h/data"; : > "$h/config/backlog-intake-loose"; done
printf 'lead1\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$M" > "$L/.jg-squad-lead-parent"
printf -- '- lead1 - the test lead (home: %s; scope: tests; projects: juggernaut; added 2026-11-12)\n' "$L" > "$M/data/squad_leads.md"
in_home() { local h=$1; shift; env JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" "$@" </dev/null 2>&1; }
in_home "$M" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" create "Main row" -p 1 --id jg-same --silent >/dev/null || fail "file the main row"
in_home "$L" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" create "Lead row" -p 1 --id jg-same --silent >/dev/null || fail "file the lead row"

title_of() { jq -r '(if type == "array" then .[0] else . end).title'; }
# bin/jg-backlog-lib.sh: a read given another home's config dir answers from that home, whoever calls it.
got=$(in_home "$M" bash -c '. "$1"; jg_backlog_beads_read "$2" show jg-same' _ "$ROOT/bin/jg-backlog-lib.sh" "$L/config") || fail "cross-home read: $got"
assert_contains "$got" "Lead row" "a read from main of the lead's config answers with the lead's row"
case $got in *"Main row"*) fail "the read answered from the caller's own home" ;; esac
# bin/jg-plan-gate.sh bd_in: the helper every gate read and write goes through.
got=$(in_home "$M" bash -c 'sed -n "/^bd_in()/,/^}/p" "$1" > "$2"; . "$3"; . "$2"; SCRIPT_DIR=$4; bd_in "$5" show jg-same --json' _ "$ROOT/bin/jg-plan-gate.sh" "$T/bd_in.sh" "$ROOT/bin/jg-backlog-lib.sh" "$ROOT/bin" "$L" | title_of)
[ "$got" = "Lead row" ] || fail "plan-gate bd_in from main for the lead's home answered '$got'"
# bin/jg-proof-minimum-lib.sh: the proof field is written in the config's own home.
in_home "$M" bash -c '. "$1"; jg_proof_minimum_write "$2" jg-same "a-journey" lead' _ "$ROOT/bin/jg-proof-minimum-lib.sh" "$L/config" >/dev/null || fail "write the proof field in the lead home"
[ "$(in_home "$L" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" show jg-same --json | jq -r '.[0].metadata.proof // ""')" = minimum ] || fail "the proof field did not reach the lead's row"
[ "$(in_home "$M" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" show jg-same --json | jq -r '.[0].metadata.proof // ""')" = "" ] || fail "the proof field reached the caller's own row"
pass "cross-home reads and writes name the other home: backlog-lib read, plan-gate bd_in, proof-minimum write"
