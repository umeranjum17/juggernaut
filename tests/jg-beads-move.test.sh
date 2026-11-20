#!/usr/bin/env bash
# A move keeps its link and its log: two fixture homes with ticket tables, a ticket moved from main to a lead through the real hand-off.
# The moved child names its parent that stayed behind as external:main:<id> and the parent tracks it; its provenance log equals the old one
# plus one handoff event; an open and an answered gate arrive with it, the answer with his words; `tree --homes` prints ask, moved ticket
# and child as one tree; a second hand-off of the same ticket adds nothing.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  echo 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset'; exit 0
fi

T=$(jg_test_tmproot jg-beads-move) CLI="$ROOT/bin/jg-backlog.sh" BD="$ROOT/core/item-store/adapters/bd_compat.py"
M=$T/main L=$T/lead
for h in "$M" "$L"; do
  mkdir -p "$h/config" "$h/data" "$h/state" "$h/bin"
  printf '%s\n' "$h-store" > "$h/config/beads-dir"   # kept until bin/jg-backlog-lib.sh stops asking for a store path
  : > "$h/config/backlog-intake-loose"
done
: > "$L/AGENTS.md"
printf 'design\n' > "$L/.jg-squad-lead-home"
printf -- '- design - work (home: %s; scope: work; projects: acme; added 2026-07-09)\n' "$L" > "$M/data/squad_leads.md"

as() {  # <home> <command...>: that home's reader, with a throwaway HOME and a bare PATH beside the checkout's bin.
  local home=$1
  shift
  env HOME="$T/user" TMPDIR="$T" PATH="$ROOT/bin:/usr/bin:/bin" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" JG_BOOTSTRAP_NETWORK=skip "$@" 2>&1
}
bd_() { local home=$1; shift; JG_HOME=$home python3 -I "$BD" "$@" 2>/dev/null; }
row() { bd_ "$1" list --all --include-gates --limit 0 --json | jq -c ".[] | select(.id == \"$2\")"; }
log() { bd_ "$1" provenance log "$2" --json | jq -c '[.[] | {kind, source, ref, ref_kind, actor, occurred_at}] | sort_by(.occurred_at, .kind)'; }

# The ask and its part, filed in main with real work behind the part: two events, one open and one answered question.
ask=$(as "$M" "$CLI" add --mint "[captain-ask] Plan the move" --body why --json | jq -r .task.id) || fail "file the ask"
part=$(as "$M" "$CLI" add --parent "$ask" "[feature] Part that moves" --body why --json | jq -r .task.id) || fail "file the part"
bd_ "$M" provenance record --issue "$part" --kind cut --source jg-spawn --ref-kind work-id --ref w1 --at 2026-11-10T10:00:00Z --actor lane1 >/dev/null || fail "first event"
bd_ "$M" provenance record --issue "$part" --kind claim --source jg-spawn --ref-kind branch --ref feature/x --at 2026-11-10T11:00:00Z --actor lane1 >/dev/null || fail "second event"
open_gate=$(bd_ "$M" gate create --blocks "$part" --type human --title "Which way" --reason "pick one" --json | jq -r .id)
done_gate=$(bd_ "$M" gate create --blocks "$part" --type human --title "Ship it" --reason "may it ship" --json | jq -r .id)
bd_ "$M" gate resolve "$done_gate" --reason "Yes, ship it on Friday." >/dev/null || fail "answer a gate"
before=$(log "$M" "$part")

# The hand-off is the real script; it stops once at the lead's wake because no endpoint is live here, after the move.
out=$(as "$M" "$ROOT/bin/jg-backlog-handoff.sh" design "$part") || true
assert_contains "$out" "handed off 1 item(s) to design" "the move must finish"
[ -z "$(row "$M" "$part")" ] || fail "the moved part must leave main"

moved=$(row "$L" "$part")
assert_equals "$(jq -r .parent <<<"$moved")" "external:main:$ask" "the moved part names its parent in the home it left"
assert_contains "$(row "$M" "$ask")" "\"depends_on_id\":\"external:lead:design:$part\"" "the parent must track the moved part"
assert_contains "$(row "$M" "$ask")" '"type":"tracks"' "the edge must be a tracks edge"
assert_equals "$(row "$L" "$part" | jq -r '.created_by')" "$(jq -r .created_by <<<"$moved")" "the filer is kept"

# The log is the old one plus one handoff event naming main.
after=$(log "$L" "$part")
assert_equals "$(jq -c '[.[] | select(.kind != "handoff")]' <<<"$after")" "$before" "the moved log must equal the old one"
assert_equals "$(jq -c '[.[] | select(.kind == "handoff") | .ref] ' <<<"$after")" "[\"main:$part\"]" "one handoff event must name the old home"

# Both questions arrive; the answered one keeps his words.
assert_equals "$(row "$L" "$open_gate" | jq -r .status)" open "the open gate must arrive open"
assert_equals "$(row "$L" "$done_gate" | jq -r .close_reason)" "Yes, ship it on Friday." "the answered gate must arrive with his words"
[ -z "$(row "$M" "$open_gate")$(row "$M" "$done_gate")" ] || fail "the gates must leave main with the part"

# One tree across both homes.
tree=$(as "$M" "$CLI" tree --homes)
assert_contains "$tree" "main:$ask  [open]  Plan the move" "the tree must start at the ask"
assert_contains "$tree" "  lead:design:$part  [open]  Part that moves" "the moved part must hang under the ask, in its new home"

# A second hand-off of the same ticket adds nothing: the part is no longer in main, so replay the take from the same staged rows.
rows=$T/rows.jsonl
printf '%s\n' "$(jq -cn --arg i "$part" --argjson e "$(jq -c '[.[] | select(.kind != "handoff")]' <<<"$after")" '{_type: "provenance", issue: $i, from: "main", events: $e}')" > "$rows"
JG_HOME=$L python3 "$ROOT/bin/jg-beads-write.py" take "$rows" "$part" >/dev/null 2>&1 || true
assert_equals "$(log "$L" "$part")" "$after" "a repeated move must record nothing twice"
printf 'ok - a move keeps the link, the log and both questions, and tree --homes prints one tree\n'
