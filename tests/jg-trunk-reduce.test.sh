#!/usr/bin/env bash
# Integration test for the one reducer of the verify's proof results (core/trunk-verify/reduce.py, ticket jg-ftplan.3), through its
# real command line: typed verdicts for the report's control table, the order rule read from test sources and run logs, the
# carried-progressed class, the merged first-home check, one repair owner per blocking input (reused, planned or one new lane,
# opening nothing when routed twice), the record map that names the asks a blocking script keeps out of use, and the refusal of
# the timeout and quarantine controls.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R="$ROOT/core/trunk-verify/reduce.py"
T=$(jg_test_tmproot jg-reduce)

# verdict <inputs json> [<check json>]: sets OUT and RC from the real command.
verdict() {
  printf '%s' "$1" > "$T/in.json"
  if [ -n "${2:-}" ]; then printf '%s' "$2" > "$T/check.json"; OUT=$(python3 -I "$R" verdict "$T/in.json" --check "$T/check.json" 2>&1); RC=$?
  else OUT=$(python3 -I "$R" verdict "$T/in.json" 2>&1); RC=$?; fi
}
field() { printf '%s' "$OUT" | jq -r "$1"; }
expect() {  # <name> <status> <exit>
  [ "$(field .status)" = "$2" ] || fail "$1: status is $(field .status), want $2: $OUT"
  [ "$RC" = "$3" ] || fail "$1: exit $RC, want $3"
}

# A manifest of n scripts a..; runs are given per script as JSON; every script passes at the pin unless a case says otherwise.
doc() {  # <grace> <aggregate> <runs object> [<pin object> <order object> <map object> <tickets array> <planned object>]
  local m; m=$(printf '%s' "$3" | jq -c 'keys')
  printf '{"grace":%s,"aggregate_present":%s,"manifest":%s,"runs":%s,"pin":%s,"order":%s,"map":%s,"tickets":%s,"planned":%s}' \
    "$1" "$2" "$m" "$3" "${4:-$(printf '%s' "$3" | jq -c 'map_values({state:"pass"})')}" "${5:-{\}}" "${6:-{\}}" "${7:-[]}" "${8:-{\}}"
}
P='[{"kind":"pass"}]'
F1='[{"kind":"fail","ff":"first assertion one"}]'
F2='[{"kind":"fail","ff":"first assertion one"},{"kind":"fail","ff":"first assertion one"}]'

test_counted_failures_against_the_grace() {
  verdict "$(doc 2 true "{\"tests/a\":$P,\"tests/b\":$P}")"; expect "none counted" green 0
  verdict "$(doc 2 true "{\"tests/a\":$F1,\"tests/b\":$P}")"; expect "one counted" graced 0
  verdict "$(doc 2 true "{\"tests/a\":$F1,\"tests/b\":$F1,\"tests/c\":$P}")"; expect "two counted" graced 0
  verdict "$(doc 2 true "{\"tests/a\":$F1,\"tests/b\":$F1,\"tests/c\":$F1}")"; expect "three counted" red 1
  [ "$(field '.counted|length')" = 3 ] || fail "three counted scripts are named: $OUT"
  pass "0, 1, 2 and 3 counted failures are green, graced, graced and red"
}

test_timeouts_skips_missing_and_the_aggregate_are_incomplete_never_green() {
  local t='[{"kind":"timeout"}]'
  verdict "$(doc 2 true "{\"tests/a\":$t,\"tests/b\":$P,\"tests/c\":$P}")"; expect "one timeout" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":$t,\"tests/b\":$t,\"tests/c\":$P}")"; expect "two timeouts" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":$t,\"tests/b\":$t,\"tests/c\":$t}")"; expect "three timeouts" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":$t,\"tests/b\":$F1}")"; expect "a timeout and a counted red" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"skip-marked\"}],\"tests/b\":$P}")"; expect "a skip" incomplete 1
  verdict "$(doc 2 false "{\"tests/a\":$P}")"; expect "a missing aggregate" incomplete 1
  [ "$(field '.repair_owners["official aggregate"].kind')" = "make complete" ] || fail "the aggregate gets a repair owner: $OUT"
  pass "timeouts, skips and a missing aggregate are incomplete, never red and never green"
}

test_the_mover_refuses_the_timeout_and_quarantine_controls_before_any_move() {
  verdict "$(doc 2 true "{\"tests/a\":$P,\"tests/q\":[{\"kind\":\"quarantined\"}],\"tests/t\":[{\"kind\":\"timeout\"}]}")"
  expect "quarantine control" incomplete 1
  [ "$(field '.unresolvable|length')" = 1 ] || fail "the quarantined script is the one input no rerun can clear: $OUT"
  [ "$(field '.check_pending|join(",")')" = "tests/t" ] || fail "the timeout is rerunnable and the quarantine is not: $OUT"
  verdict "$(doc 2 false "{\"tests/a\":$P}")"
  [ "$(field '.unresolvable|length')" = 1 ] || fail "a missing aggregate is refused before the move: $OUT"
  pass "the quarantine and aggregate controls are named unresolvable, the timeout is left to the check"
}

test_a_rerun_replaces_a_non_pass_and_the_merged_check_decides() {
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"skip-marked\"},{\"kind\":\"pass\"}]}")"; expect "skip then rerun pass" green 0
  verdict "$(doc 2 true "{\"tests/a\":$F1}" '{"tests/a":{"state":"pass"}}')"; expect "fail once" graced 0
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"fail\",\"ff\":\"x\"},{\"kind\":\"pass\"}]}")"; expect "fail then rerun pass is a flaky pass" green 0
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"timeout\"}],\"tests/b\":$P}")" '{"tests/a":{"kind":"pass"}}'
  expect "check completes the timeout" green 0
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"timeout\"}],\"tests/b\":$P}")" '{"tests/a":{"kind":"timeout"}}'
  expect "check times out again" incomplete 1
  verdict "$(doc 2 false "{\"tests/a\":$P}")" '{}'; expect "aggregate absent and an empty check" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":$P,\"tests/b\":$P,\"tests/c\":$P}")" '{"tests/a":{"kind":"fail","ff":"p"},"tests/b":{"kind":"fail","ff":"q"},"tests/c":{"kind":"fail","ff":"r"}}'
  expect "the check turns a pass into three counted" green 0
  pass "a rerun replaces a non-pass and the merged verdict decides whether the home is kept"
}

test_a_new_failing_assertion_seen_once_is_incomplete_and_twice_is_counted() {
  local pin='{"tests/a":{"state":"fail","ff":"old assertion"}}' ord='{"tests/a":{"pin_passed_head_case":true}}'
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"fail\",\"ff\":\"new assertion\"}]}" "$pin" "$ord")"; expect "new assertion once" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"fail\",\"ff\":\"new assertion\"},{\"kind\":\"fail\",\"ff\":\"new assertion\"}]}" "$pin" "$ord")"
  expect "new assertion twice, the pin got past it" graced 0
  [ "$(field '.counted[0]')" = tests/a ] || fail "it is counted: $OUT"
  verdict "$(doc 2 true "{\"tests/a\":$F1}" '{"tests/a":{"state":"absent"}}')"; expect "a new script red once" incomplete 1
  verdict "$(doc 2 true "{\"tests/a\":$F2}" '{"tests/a":{"state":"absent"}}')"; expect "a new script red twice" graced 0
  verdict "$(doc 2 true "{\"tests/a\":[{\"kind\":\"fail\",\"ff\":\"old assertion\"}]}" "$pin")"; expect "fails like the pin" graced 0
  [ "$(field '.carried[0]')" = tests/a ] || fail "it is carried, never a pass: $OUT"
  pass "a failure is counted only where the pin got past it and the head is red twice with the same first assertion"
}

test_carried_progressed_uses_no_grace_slot_blocks_its_asks_and_needs_its_evidence() {
  local pin='"tests/a":{"state":"fail","ff":"pin assertion"}' f='[{"kind":"fail","ff":"head assertion"}]'
  local runs="{\"tests/a\":$f,\"tests/b\":$F2,\"tests/c\":$F2}" map='{"tests/a":["jg-ask1"]}'
  local pins="{$pin,\"tests/b\":{\"state\":\"pass\"},\"tests/c\":{\"state\":\"pass\"}}"
  verdict "$(doc 2 true "$runs" "$pins" '{"tests/a":{"head_progressed_past_pin":true}}' "$map")"
  expect "carried-progressed beside two counted" graced 0
  [ "$(field '.class["tests/a"]|startswith("carried-progressed")')" = true ] || fail "the class is carried-progressed: $OUT"
  [ "$(field '.counted|length')" = 2 ] || fail "it used no grace slot: $OUT"
  [ "$(field '.asks_not_in_use["jg-ask1"][0]')" = tests/a ] || fail "it blocks its ask: $OUT"
  verdict "$(doc 2 true "$runs" "$pins" '{"tests/a":{"head_progressed_past_pin":false}}' "$map")"
  expect "the same with the progress evidence removed" incomplete 1
  [ "$(field '.unresolvable|map(select(contains("no pin baseline")))|length')" = 1 ] || fail "no pin baseline is refused before any move: $OUT"
  pass "carried-progressed is pre-existing: no grace slot, its asks blocked, and without the evidence it is refused as no pin baseline"
}

test_every_blocking_input_gets_one_deduplicated_repair_owner() {
  local runs="{\"tests/x\":$F1,\"tests/y\":[{\"kind\":\"timeout\"}],\"tests/z\":[{\"kind\":\"timeout\"}]}"
  local pins='{"tests/x":{"state":"fail","ff":"first assertion one"},"tests/y":{"state":"pass"},"tests/z":{"state":"pass"}}'
  local tickets='[{"id":"flaky-juggernaut-y","title":"t","body":"b","status":"open"},{"id":"old-z","title":"z","body":"tests/z","status":"done"}]'
  verdict "$(doc 2 false "$runs" "$pins" '{}' '{"tests/x":["ASK"]}' "$tickets" '{"tests/z":"slice 5","official aggregate":"slice 5"}')"
  [ "$(field '.repair_owners["tests/x"]|"\(.owner) \(.source) \(.kind)"')" = "fix-x new lane fix forward" ] || fail "a carried script gets a new fix-forward lane: $OUT"
  [ "$(field '.repair_owners["tests/y"].owner')" = flaky-juggernaut-y ] || fail "an open ticket that names the script is reused: $OUT"
  [ "$(field '.repair_owners["tests/z"]|"\(.owner) \(.source)"')" = "slice 5 planned slice" ] || fail "a closed ticket is not reused, the planned slice is: $OUT"
  [ "$(field '.repair_owners["official aggregate"].owner')" = "slice 5" ] || fail "the aggregate has its planned owner: $OUT"
  [ "$(field '.new_lanes|join(",")')" = fix-x ] || fail "exactly one new lane: $OUT"
  tickets=$(printf '%s' "$tickets" | jq -c '. + [{"id":"fix-x","title":"fix tests/x","body":"tests/x","status":"open"}]')
  verdict "$(doc 2 false "$runs" "$pins" '{}' '{"tests/x":["ASK"]}' "$tickets" '{"tests/z":"slice 5","official aggregate":"slice 5"}')"
  [ "$(field '.new_lanes|length')" = 0 ] || fail "routing the verdict twice opens nothing: $OUT"
  [ "$(field '.repair_owners["tests/x"].owner')" = fix-x ] || fail "the second route reuses the first route's lane: $OUT"
  pass "each blocking script has one owner: reused, planned or one new lane, and a second route opens nothing"
}

# A test source whose cases print `pass "..."`; the head failure holds its message on a line above the case it belongs to.
src() {  # <case>...: one assertion line then one pass line per case
  local c
  # shellcheck disable=SC2016 # the line is test source text, written out verbatim
  for c in "$@"; do printf '[ -n "$x" ] || fail "%s did not hold"\npass "%s"\n' "$c" "$c"; done
}
log() {  # <script> <ok case>...
  local s=$1 c; shift
  printf 'JG_TEST_BEGIN 1 %s\n' "$s"; for c in "$@"; do printf 'ok - %s\n' "$c"; done; printf 'not ok - x\nJG_TEST_END 1\n'
}

test_the_order_rule_reads_where_the_pin_and_the_head_each_stopped() {
  local s=tests/a.test.sh pin_src head_src spec
  # Lifecycle-like: the pin stopped at its fourth case, which the head no longer has; the head prints more ok cases and fails later.
  pin_src=$(src "case one" "case two" "case three" "old out-of-band case")
  head_src=$(src "case one" "case two" "case three" "case four" "case five" "case six")
  spec=$(jq -nc --arg ps "$pin_src" --arg hs "$head_src" --arg pl "$(log "$s" 'case one' 'case two' 'case three')" \
    --arg hl "$(log "$s" 'case one' 'case two' 'case three' 'case four' 'case five')" \
    '{script:"tests/a.test.sh",head_src:$hs,pin_src:$ps,head_log:$hl,pin_log:$pl,head_ff:"case six did not hold",pin_ff:"old out-of-band case did not hold"}')
  printf '%s' "$spec" > "$T/spec.json"; OUT=$(python3 -I "$R" order "$T/spec.json" 2>&1) || fail "order failed: $OUT"
  [ "$(field .head_case)" = "case six" ] && [ "$(field .pin_case)" = "old out-of-band case" ] || fail "the failing cases are found from the messages: $OUT"
  [ "$(field .pin_passed_head_case)" = false ] && [ "$(field .head_progressed_past_pin)" = true ] || fail "the head got past the pin's stopping point: $OUT"
  # Machine-hold-like: the head's failing case is one the pin printed ok for, so the pin got past it.
  spec=$(printf '%s' "$spec" | jq -c --arg pl "$(log "$s" 'case one' 'case two' 'case three' 'case four' 'case five' 'case six')" \
    '.pin_log=$pl | .pin_src=.head_src | .pin_ff="case seven did not hold"')
  printf '%s' "$spec" > "$T/spec.json"; OUT=$(python3 -I "$R" order "$T/spec.json" 2>&1) || fail "order failed: $OUT"
  [ "$(field .pin_passed_head_case)" = true ] && [ "$(field .head_progressed_past_pin)" = false ] || fail "the pin passed the head's case: $OUT"
  pass "order is read from the test source and the run logs, never from the message text alone"
}

test_the_record_map_names_the_asks_a_script_proves() {
  local g="$T/repo"
  git init -q "$g" && git -C "$g" config user.email t@t && git -C "$g" config user.name t && mkdir "$g/tests" && : > "$g/tests/jg-made.test.sh"
  git -C "$g" add . && git -C "$g" commit -q -m 'jg-child: add the made test'
  printf '%s' '{"repo":"'"$g"'","manifest":["tests/jg-made.test.sh","tests/jg-named.test.sh","tests/jg-refused.test.sh","tests/jg-none.test.sh"],
    "asks":["jg-ask"],"tickets":[{"id":"jg-ask","body":"an ask"},{"id":"jg-child","body":"parent: jg-ask"},
      {"id":"jg-grand","body":"parent: jg-child\nDone-when: tests/jg-named.test.sh passes\nrefused: tests/jg-refused.test.sh"},
      {"id":"jg-other","body":"tests/jg-none.test.sh is mentioned here"}]}' > "$T/map.json"
  OUT=$(python3 -I "$R" map "$T/map.json" 2>&1) || fail "map failed: $OUT"
  [ "$(field '.["tests/jg-made.test.sh"]|join(",")')" = jg-ask ] || fail "the commit that created the script carries a ticket that traces to the ask: $OUT"
  [ "$(field '.["tests/jg-named.test.sh"]|join(",")')" = jg-ask ] || fail "a descendant ticket names the script: $OUT"
  [ "$(field '.["tests/jg-refused.test.sh"]|length')" = 0 ] || fail "a refused: line is not a proof: $OUT"
  [ "$(field '.["tests/jg-none.test.sh"]|length')" = 0 ] || fail "a ticket outside every ask's lineage proves nothing: $OUT"
  pass "the record map reads the asks of a script from tickets that trace to an ask and from its creating commit"
}
test_counted_failures_against_the_grace
test_timeouts_skips_missing_and_the_aggregate_are_incomplete_never_green
test_the_mover_refuses_the_timeout_and_quarantine_controls_before_any_move
test_a_rerun_replaces_a_non_pass_and_the_merged_check_decides
test_a_new_failing_assertion_seen_once_is_incomplete_and_twice_is_counted
test_carried_progressed_uses_no_grace_slot_blocks_its_asks_and_needs_its_evidence
test_every_blocking_input_gets_one_deduplicated_repair_owner
test_the_order_rule_reads_where_the_pin_and_the_head_each_stopped
test_the_record_map_names_the_asks_a_script_proves
