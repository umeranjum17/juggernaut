#!/usr/bin/env bash
# Slice S13 on real Beads stores: the journal is on, so a reader asks `events tail` for the changes since its last read; the filer
# is the home's name (`main`, `lead:<id>`), so `created_by` says who filed; `jg-backlog.sh homes --json` lists every home and its
# store and marks a lead on another machine; and every field the contract for sign-off names is in `bd schema`. JG_BEADS_TEST_BD and
# JG_BEADS_TEST_DOLT name the pinned builds; without them the run skips plainly. JG_BEADS_REAL_STORE (a copy of a real store's
# .beads folder) adds a timed full read of it, which the proof run sets and a plain run leaves out.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-beads-journal)
WRAPPER=$ROOT/bin/jg-beads.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC TMPDIR=$T JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT

main=$T/main lead=$T/lead-a
jg_test_beads_home "$main" jg
jg_test_beads_home "$lead" jg
printf 'lead-a\n' > "$lead/.jg-squad-lead-home"
store_of() { tr -d '[:space:]' < "$1/config/beads-dir"; }
axi() { local home=$1; shift; (cd "$home" && JG_HOME=$home JG_TASK_PRIORITY_CHECK=/nonexistent "$ROOT/bin/jg-backlog.sh" "$@"); }
bd_in() { local home=$1; shift; BEADS_DIR=$(store_of "$home") "$WRAPPER" "$@"; }

# The journal is on in a store init made, and check proves it; a store with it off is refused and init turns it back on.
bd_in "$main" check | grep -qx 'journal: on (events-journal true)' || fail "check must prove the journal"
bd_in "$main" config set events-journal false >/dev/null || fail "turn the journal off"
bd_in "$main" check >/dev/null 2>&1 && fail "check must refuse a store with the journal off"
bd_in "$main" init --prefix jg >/dev/null || fail "init must turn the journal back on"
bd_in "$main" check >/dev/null || fail "the store must pass check again"
printf 'ok - check proves the journal and init repairs it\n'

# A ticket filed through the CLI is a `create` in the journal, from the home, and `created_by` is the home's name.
axi "$main" add jg-s13-a "[feature] Filed by main" --priority 2 --body why >/dev/null || fail "file in main"
axi "$lead" add jg-s13-b "[feature] Filed by a lead" --priority 2 --body why >/dev/null || fail "file in the lead"
tail_main=$(bd_in "$main" events tail --since 0 --limit 10)
op=$(jq -rs 'map(select(.issue_id == "jg-s13-a")) | .[0] | "\(.op) \(.actor) \(.issue.created_by)"' <<< "$tail_main")
[ "$op" = "create main main" ] || fail "events tail must return the create from main, got [$op]"
[ "$(bd_in "$lead" show jg-s13-b --json | jq -r '.[0].created_by')" = lead:lead-a ] || fail "a lead's ticket must name lead:lead-a"
seq=$(jq -rs 'map(select(.issue_id == "jg-s13-a")) | .[0].seq' <<< "$tail_main")
axi "$main" update jg-s13-a --priority 1 >/dev/null || fail "change the ticket"
since=$(bd_in "$main" events tail --since "$seq" --limit 10 | jq -rs 'map(select(.issue_id == "jg-s13-a" and .op == "update")) | length')
[ "$since" -ge 1 ] || fail "a read since the last seq must return the change"
printf 'ok - events tail returns the create and the later change, and the filer is the home\n'

# A row the home holds with no worker has the home's name as assignee; a named caller keeps its own name.
axi "$main" add jg-s13-c "[feature] Held with no worker" --priority 2 --body why >/dev/null || fail "file the held row"
axi "$main" start jg-s13-c >/dev/null || fail "start with no lane"
[ "$(bd_in "$main" show jg-s13-c --json | jq -r '.[0].assignee')" = main ] || fail "a start with no worker must name the home"
printf 'ok - a row held with no worker names the home\n'

# homes --json: this home first, a local lead with its store, a lead on another machine marked remote.
mkdir -p "$main/data"
cat > "$main/data/squad_leads.md" <<REG
- lead-a - A local lead (home: $lead; scope: everything local; projects: demo; added 2026-11-01)
- lead-r - A lead on another machine (host: other.example; root: /srv/jg; home: /srv/jg/home; scope: remote work; projects: demo; added 2026-11-02)
REG
homes=$(axi "$main" homes --json) || fail "homes --json"
want=$(jq -cn --arg m "$(store_of "$main")" --arg l "$(store_of "$lead")" \
  '[{home:"main",beads_dir:$m},{home:"lead:lead-a",beads_dir:$l},{home:"lead:lead-r",beads_dir:null,remote:true}]')
[ "$(jq -c . <<< "$homes")" = "$want" ] || fail "homes --json lists the wrong homes: $homes"
[ "$(axi "$lead" homes --json | jq -r '.[0].home')" = lead:lead-a ] || fail "a lead's own home is first in its list"
printf 'ok - homes --json lists the homes and marks the remote one\n'

# Every field the contract for sign-off names (section 6.5 of the plan) is a field of the pinned bd's own schema.
issue='acceptance_criteria assignee await_type close_reason closed_at created_at created_by defer_until dependencies description external_ref heartbeat_at id issue_type labels lease_expires_at metadata priority started_at status title updated_at'
dependency='created_at created_by depends_on_id issue_id type'
schema=$(bd_in "$main" schema) || fail "bd schema"
gap=$(jq -r --arg i "$issue" --arg d "$dependency" \
  '(.types.issue.properties | keys) as $ik | (.types.dependency.properties | keys) as $dk
   | ([$i | split(" ")[] | select(. as $f | $ik | index($f) | not)] + [$d | split(" ")[] | select(. as $f | $dk | index($f) | not)]) | join(" ")' <<< "$schema")
[ -z "$gap" ] || fail "the pinned bd's schema lacks fields the contract names: $gap"
row=$(bd_in "$main" --readonly list --all --limit 0 --include-gates --json | jq -r '[.[] | keys[]] | unique | join(" ")')
for field in id title status assignee created_by created_at issue_type priority; do
  grep -qw "$field" <<< "$row" || fail "the contract read lacks the field $field"
done
printf 'ok - the contract fields are in bd schema and in the contract read\n'

# A full read of a copy of a real store, timed (the proof run supplies the copy).
if [ -n "${JG_BEADS_REAL_STORE:-}" ]; then
  start=$(date +%s%N)
  rows=$(BEADS_DIR=$JG_BEADS_REAL_STORE "$WRAPPER" --readonly list --all --limit 0 --include-gates --json | jq length) || fail "read the real store"
  printf 'timed: full read of %s rows took %s ms\n' "$rows" "$((($(date +%s%N) - start) / 1000000))"
fi
pass "jg-beads journal"
