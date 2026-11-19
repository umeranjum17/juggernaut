#!/usr/bin/env bash
# tests/jg-swarm-arm.test.sh - bin/jg-swarm-arm.sh arms an owner home for its slices of a swarm plan, on a real store and
# strict intake, with no model turn. Plan jg-plan: A; B and C after A (C has an owner word); D with a tool gate.
# Journey: arm -> briefs, the word gate, the tool gate, the switch and its record -> auto-dispatch beats start A, then B
# (not C), then C once the owner picks, and the worker's read command prints the pick -> a second arm changes nothing ->
# a row outside the plan is refused and a second plan keeps the first record's "before" values.
# JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; the suite skips without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

ARM="$ROOT/bin/jg-swarm-arm.sh" T=$(jg_test_tmproot jg-swarm-arm)
T=$(cd "$T" && pwd)
M=$T/main
jg_test_beads_home "$M"
mkdir -p "$M/state" "$M/data" "$M/projects/proj"
ln -sn "$ROOT/bin" "$M/bin"; ln -sn "$ROOT/core" "$M/core"; ln -sn "$ROOT/toolchain.versions" "$M/toolchain.versions"
printf -- '- proj [local-trunk +yolo] - the one project (added 2026-11-19)\n' > "$M/data/projects.md"
: > "$M/data/squad_leads.md"
run() { env HOME="$T" TMPDIR="$T" JG_HOME="$M" JG_STATE_OVERRIDE="$M/state" JG_DATA_OVERRIDE="$M/data" JG_CONFIG_OVERRIDE="$M/config" "$@" 2>&1; }
backlog() { run "$ROOT/bin/jg-backlog.sh" "$@"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# --- Fixture: the rows are filed while intake is loose (the filer writes no body), then intake is strict ------------------
for r in "jg-plan|[feature] The plan" "jg-plan2|[feature] The second plan" "jg-plan-word-c|[feature] Owner pick before slice c" "jg-other|[feature] A row outside the plans"; do
  jg_test_add "$M" "${r%%|*}" "${r#*|}"
done
slice() {  # <id> <deps json> [<extra json>]
  jq -n --arg id "$1" --argjson d "$2" --argjson x "${3:-null}" \
    '{id: $id, title: ("Make part " + $id + " of it"), owner_home: "main", project: "proj", size: "S", risk: "Low", depends_on: $d,
      files: ["bin/\($id).sh (new)"], machine: null, order: ($id + ".md"), owner_word: null, gate: null} + ($x // {})'
}
WORD='{"owner_word": {"question": "Which colour should the new button be?", "options": {"a": "blue", "b": "green"}, "recommend": "a", "must": "design-pick"}}'
jq -n '{plan: "jg-plan", slices: $ARGS.positional | map(fromjson)}' --args \
  "$(slice a '[]')" "$(slice b '["a"]')" "$(slice c '["a"]' "$WORD")" "$(slice d '[]' '{"gate": {"tool": "jq", "min": "1.0"}}')" > "$T/in.json"
jq -n '{plan: "jg-plan2", slices: $ARGS.positional | map(fromjson)}' --args "$(slice e '[]')" > "$T/in2.json"
filed=$(run "$ROOT/bin/jg-plan-file.sh" "$T/in.json" --owner main; run "$ROOT/bin/jg-plan-file.sh" "$T/in2.json" --owner main)
row_of() { printf '%s\n' "$filed" | sed -n "s/^filed $1 as //p" | head -1; }
A=$(row_of a) B=$(row_of b) C=$(row_of c) D=$(row_of d) E=$(row_of e)
[ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] && [ -n "$D" ] && [ -n "$E" ] || fail "the fixture rows were not filed: $filed"
body=$(printf '## Captain\nx\n\n## Ask\nBuild slice c.\n\n## Why\nx\n\n## Done when\nx\n\n## Acceptance Criteria\nx\n\nlinked-to: jg-plan-word-c')
backlog update "$C" --body "$body" >/dev/null || fail "the word row link was not written"
run "$ROOT/bin/jg-plan-gate.sh" approve "$T/in.json" --harness claude --model sonnet --effort medium >/dev/null || fail "approve failed"
rm -f "$M/config/backlog-intake-loose"   # arm itself works on strict intake

# The derived plan (interface section 2): the input plus order, goal, row, task, card and word_row on each slice.
mkdir -p "$T/orders"
for s in a b c d; do printf '# Work order %s\n\n## Goal\n\nBuild part %s of it. More words.\n\n## Acceptance\n\n1. true\n' "$s" "$s" > "$T/orders/$s.md"; done
slice_row() { case $1 in a) echo "$A" ;; b) echo "$B" ;; c) echo "$C" ;; d) echo "$D" ;; esac; }
derive() {  # <input> <out>
  local s r
  jq --arg home "$M" '. + {intent: "The owner wants the swarm run.", prior_art: "Prior art: none needed - the test fixture is neither new nor complex.", main_home: $home}' "$1" > "$2"
  for s in $(jq -r '.slices[].id' "$1"); do
    r=$(slice_row "$s"); [ "$s" != e ] || r=$E
    o=$T/orders/$s.md
    [ -e "$o" ] || { printf '# Work order\n\n## Goal\n\nBuild part %s.\n' "$s" > "$o"; }
    jq --arg s "$s" --arg r "$r" --arg o "$o" --arg sha "$(sha256sum "$o" | cut -d' ' -f1)" \
      '.slices |= map(if .id == $s then . + {row: $r, task: ($r | gsub("\\."; "-")), order_path: $o, order_sha256: $sha, goal: "Build part \($s) of it.",
        card: (if .owner_word then "card-1" else null end), word_row: (if .owner_word then "\($r | split(".")[0])-word-\($s)" else null end)} else . end)' "$2" > "$2.tmp" && mv "$2.tmp" "$2"
  done
}
derive "$T/in.json" "$T/plan.json"
derive "$T/in2.json" "$T/plan2.json"
TASK_C=${C//./-}

# --- Case 1: arm ------------------------------------------------------------------------------------------------------
out=$(run "$ARM" "$T/plan.json") || fail "arm: $out"
assert_equals "armed 4 slices of jg-plan in main; 1 wait for the owner; 1 gated" "$out" "arm must print its one line"
for s in a b c d; do
  row=$(slice_row $s) task=$(slice_row $s); task=${task//./-}
  brief=$M/data/$task/brief.md
  [ -s "$brief" ] || fail "slice $s has no brief at $brief"
  sha=$(sha256sum "$T/orders/$s.md" | cut -d' ' -f1)
  assert_contains "$(cat "$brief")" "Delivery contract: mode=local-trunk" "slice $s brief must carry the delivery contract"
  assert_contains "$(cat "$brief")" "Work order: $T/orders/$s.md (sha256 $sha)" "slice $s brief must name its order and its sha256"
  assert_contains "$(cat "$brief")" "Swarm rules: you were started because every slice this order depends on has landed." "slice $s brief must carry the rules block"
  assert_contains "$(cat "$brief")" "Prior art (survey): Prior art: none needed - the test fixture" "slice $s brief must carry the plan's prior art"
  case $(cat "$brief") in *'{TASK}'*|*'{JUGGERNAUT_SPEC}'*) fail "slice $s brief has a placeholder" ;; esac
  [ "$(readlink "$M/data/$row/brief.md")" = "../$task/brief.md" ] || fail "data/$row/brief.md must link to ../$task/brief.md"
  size=$(sed -n '/^# Task$/,/^# Prior art$/p' "$brief" | wc -c)
  [ "$size" -lt 4096 ] || fail "slice $s task part is $size bytes"
done
pick=$(grep '^Owner pick:' "$M/data/$TASK_C/brief.md") || fail "C's brief has no Owner pick line"
assert_contains "$pick" "Which colour should the new button be? Options: a blue; b green." "the pick line must carry the question and options"
assert_contains "$pick" "JG_HOME=$M $M/bin/jg-backlog.sh questions --all --json" "the pick line must carry this home's path"
assert_contains "$pick" 'select(.card == "card-1" and .state == "closed")' "the pick line must carry the card"
! grep -q '^Owner pick:' "$M/data/${A//./-}/brief.md" || fail "only an owner-word slice has the pick line"

# --- Case 2: the word gate ----------------------------------------------------------------------------------------------
q=$(backlog questions --json)
assert_equals "1 jg-plan-word-c" "$(jq -r '[.[] | select(.card == "card-1" and .state == "open")] | "\(length) \(.[0].ticket)"' <<< "$q")" "one open question with card-1 on the word row"
hold() { rc_of run "$ROOT/bin/jg-captain-hold.sh" blocking "$1"; }
assert_equals "1 1 0" "$(hold "$A") $(hold "$B") $(hold "$C")" "the gate must stop C only, not its base A or B"
assert_equals "$D" "$(jq -r '.[] | select(.title == "plan-gate: tool jq >= 1.0" and .state == "open") | .ticket' <<< "$q")" "D must wait on an open plan gate"
assert_equals "$A" "$(backlog ready --spawnable | awk -F'\t' 'NF >= 2 { print $1 }' | grep -x -F -e "$A" -e "$B" -e "$C" -e "$D" | tr '\n' ' ' | sed 's/ $//')" "only A is spawnable"

# --- Case 3: the record and the switch ----------------------------------------------------------------------------------
assert_equals "on" "$(cat "$M/config/auto-dispatch")" "the switch must be on"
REC=$M/data/swarm/jg-plan/arm.json
assert_equals "absent absent null" "$(jq -r '"\(.switch_before) \(.lane_target_before) \(.lane_target_wrote)"' "$REC")" "arm must record what was there before"
assert_equals "$A $B $C $D|jg-plan-word-c|$D" "$(jq -r '"\(.rows | join(" "))|\(.words | join(" "))|\(.gated | join(" "))"' "$REC")" "arm must record rows, words and gated"
assert_equals "$T/plan.json|armed|main" "$(jq -r '"\(.plan_file)|\(.state)|\(.home)"' "$REC")" "arm must record the plan file, state and home"
armed_at=$(jq -r '.armed_at' "$REC")
sleep 1
out=$(run "$ARM" "$T/plan.json" --agents 7) || fail "arm with --agents: $out"
assert_equals "7" "$(cat "$M/config/lane-target")" "--agents must set the lane target"
assert_equals "absent absent 7 7 $armed_at" "$(jq -r '"\(.switch_before) \(.lane_target_before) \(.lane_target_wrote) \(.agents) \(.armed_at)"' "$REC")" "a second arm keeps the first record's before values and time"
printf '25\n' > "$M/config/lane-target"

# --- Case 5: the chain, with a spawn stand-in that wants the brief at the path the real spawn reads ------------------------
cat > "$T/spawn" <<SH
#!/usr/bin/env bash
t=\$1
[ -s "$M/data/\$t/brief.md" ] || { echo "no brief for \$t" >&2; exit 1; }
printf 'kind=ship\nticket=%s\n' "\$t" > "$M/state/\$t.meta"; printf 'working [at=1]: started\n' > "$M/state/\$t.status"
echo "\$t" >> "$T/started.log"
SH
printf '#!/usr/bin/env bash\necho ok\n' > "$T/reserve"; chmod +x "$T/spawn" "$T/reserve"
beat() {
  touch "$M/state/.last-watcher-beat"
  run env JG_AUTO_DISPATCH_SPAWN="$T/spawn" JG_AUTO_DISPATCH_RESERVE="$T/reserve" bash "$ROOT/core/auto-dispatch/dispatch.sh" check "$M" >/dev/null
  sleep 2
  sort -u "$T/started.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
assert_equals "${A//./-}" "$(beat)" "the first beat must start A only"
printf 'done [at=2]: landed\n' >> "$M/state/${A//./-}.status"
backlog "done" "$A" >/dev/null || fail "A was not closed"
assert_equals "${A//./-} ${B//./-}" "$(beat)" "after A landed the next beat must start B and not C"
run "$ROOT/bin/jg-captain-hold.sh" design-pick card-1 --words "a" >/dev/null || fail "design-pick failed"
assert_equals "${A//./-} ${B//./-} $TASK_C" "$(beat)" "after the owner picked the next beat must start C"
cmd=$(printf '%s\n' "$pick" | sed -e 's/^.*Read his answer with: //' -e 's/\. Build the option he picked\..*$//')
assert_equals "a" "$(run bash -c "$cmd")" "the worker's read command must print the pick"

# --- Case 6: safe twice, after the pick -----------------------------------------------------------------------------------
before=$(sha256sum "$M/data/$TASK_C/brief.md")
sleep 1
out=$(run "$ARM" "$T/plan.json") || fail "second arm: $out"
assert_equals "$before" "$(sha256sum "$M/data/$TASK_C/brief.md")" "a second arm must write no second brief"
all=$(backlog questions --all --json)
assert_equals "1 closed" "$(jq -r '[.[] | select(.card == "card-1")] | "\(length) \(.[0].state)"' <<< "$all")" "a second arm must make no second gate"
assert_equals "1" "$(hold "$C")" "the closed gate must not stop C"
assert_equals "absent absent $armed_at" "$(jq -r '"\(.switch_before) \(.lane_target_before) \(.armed_at)"' "$REC")" "a second arm keeps the record's before values and time"

# --- Case 4: other approved rows, and a second plan ---------------------------------------------------------------------------
mkdir -p "$M/state/dispatch-approved"
printf 'harness=claude\nmodel=sonnet\neffort=medium\napproved-at=1\n' > "$M/state/dispatch-approved/jg-other"
out=$(run "$ARM" "$T/plan.json"); rc=$?
[ "$rc" = 2 ] || fail "an approved row outside the plan must be refused with 2, got $rc: $out"
assert_contains "$out" "jg-other" "the refusal must name the row"
out=$(run "$ARM" "$T/plan.json" --with-others) || fail "--with-others must arm: $out"
rm -f "$M/state/dispatch-approved/jg-other"
run "$ROOT/bin/jg-plan-gate.sh" approve "$T/in2.json" --harness claude --model sonnet --effort medium >/dev/null || fail "approve of plan 2 failed"
out=$(run "$ARM" "$T/plan2.json") || fail "a second plan must arm while the first plan's rows are approved: $out"
assert_equals "armed 1 slices of jg-plan2 in main; 0 wait for the owner; 0 gated" "$out" "the second plan's line"
assert_equals "absent absent" "$(jq -r '"\(.switch_before) \(.lane_target_before)"' "$M/data/swarm/jg-plan2/arm.json")" "the second plan must copy the first record's before values"
pass "swarm arm: briefs, word gate, plan gate, switch and record; the chain starts each slice in its turn; safe twice; others refused"
