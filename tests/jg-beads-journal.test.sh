#!/usr/bin/env bash
# Slice S13 on the tickets tables: the filer is the home's name
# (`main`, `lead:<id>`), so `created_by` says who filed; `jg-backlog.sh homes --json` lists every home and its store and marks a
# lead on another machine; and the contract read holds the fields sign-off names. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the
# pinned builds; without them the run skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-beads-journal)
BD=$ROOT/core/item-store/adapters/bd_compat.py
unset BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC TMPDIR=$T JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT

main=$T/main lead=$T/lead-a
jg_test_beads_home "$main" jg
jg_test_beads_home "$lead" jg
printf 'lead-a\n' > "$lead/.jg-squad-lead-home"
store_of() { tr -d '[:space:]' < "$1/config/beads-dir"; }
axi() { local home=$1; shift; (cd "$home" && JG_HOME=$home JG_TASK_PRIORITY_CHECK=/nonexistent "$ROOT/bin/jg-backlog.sh" "$@"); }
bd_in() { local home=$1; shift; JG_HOME=$home python3 -I "$BD" "$@"; }

# A ticket filed through the CLI has the home's name as `created_by`.
axi "$main" add jg-s13-a "[feature] Filed by main" --priority 2 --body why >/dev/null || fail "file in main"
axi "$lead" add jg-s13-b "[feature] Filed by a lead" --priority 2 --body why >/dev/null || fail "file in the lead"
[ "$(bd_in "$lead" show jg-s13-b --json | jq -r '.[0].created_by')" = lead:lead-a ] || fail "a lead's ticket must name lead:lead-a"
printf 'ok - the filer is the home\n'

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

# The contract read holds every field sign-off reads.
row=$(bd_in "$main" --readonly list --all --limit 0 --include-gates --json | jq -r '[.[] | keys[]] | unique | join(" ")')
for field in id title status assignee created_by created_at issue_type priority; do
  grep -qw "$field" <<< "$row" || fail "the contract read lacks the field $field"
done
printf 'ok - the contract fields are in the contract read\n'

pass "jg-beads journal"
