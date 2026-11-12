#!/usr/bin/env bash
# Integration test for J26c: a bypassed change says so wherever it is shown. Through tests/jg-trunk-fixture.sh it runs the real tick
# (which writes the bypass record), then the real callers that show it: bin/jg-pr-check.sh, bin/jg-trunk.sh release,
# bin/jg-live-claim.sh and bin/jg-beads-view.py / bin/jg-beads-moment.py.
#
# T1 A fixture pull request of a bypassed ticket gets a green proof status reading "bypassed: no proof ran (word <id>)"; a ticket
#    with no bypass gets none.
# T2 A release of three tickets, one bypassed, lists that one in the body of the release pull request, with its word.
# T3 The live-claim check prints "not proven: bypassed by the owner" for a done report that names the bypassed ticket, and leaves
#    a report of an ordinary ticket, and a hand-written record, alone.
# T4 The ticket's trace says `unproved` and its board card shows the mark; a card of an ordinary ticket shows none.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/example/repo/pull
setup() {  # <name>
  world "$1"; cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/done-done"; chmod +x "$W/fakebin/done-done"
}
pb() { JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" JG_CONFIG_OVERRIDE="$HOME_D/config" JG_DATA_OVERRIDE="$HOME_D/data" bash "$W/root/bin/jg-proof-bypass.sh" "$@"; }
apply() { PATH="$W/fakebin:$PATH" bash "$W/root/bin/jg-proof-bypass-apply.sh" "$HOME_D" >/dev/null; }
record() { printf '%s/state/%s.bypass-record.json' "$HOME_D" "$1"; }
unproved() {  # <id> <file>: a lane with one commit and a done line
  local id=$1 wt="$W/lanes/$1"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" "$2" "the change of $id" "ticket $id"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id"
  ready "$id"
}
claim() { JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" bash "$W/root/bin/jg-live-claim.sh" "$@" 2>&1; }

test_a_pull_request_of_a_bypassed_ticket_has_a_green_proof_status_that_says_so() {
  setup p1; pb grant --ticket a1 --word owner-rule-p1 >/dev/null || fail "the grant"
  unproved a1 a1.txt; unproved a2 a2.txt; apply
  [ -f "$(record a1)" ] || fail "fixture: the tick must write the record of a1"
  cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh.log"
case "\$1 \$2 \$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) git -C "$PROJ" rev-parse "fm/\${GH_LANE:-a1}" ;;
  'pr view '*baseRefName*) printf 'release/c-4\tfm/%s\n' "\${GH_LANE:-a1}" ;;
  'api '*) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$W/fakebin/gh"; : > "$W/gh.log"
  PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" \
    bash "$W/root/bin/jg-pr-check.sh" a1 "$U/1" >/dev/null 2>&1
  assert_contains "$(cat "$W/gh.log")" 'context=juggernaut/proof' "the bypassed pull request gets the proof status"
  assert_contains "$(cat "$W/gh.log")" 'state=success' "the proof status is green"
  assert_contains "$(cat "$W/gh.log")" 'description=bypassed: no proof ran (word owner-rule-p1)' "the status reads bypassed, with the word id"
  : > "$W/gh.log"
  GH_LANE=a2 PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" \
    bash "$W/root/bin/jg-pr-check.sh" a2 "$U/2" >/dev/null 2>&1
  ! grep -q 'juggernaut/proof' "$W/gh.log" || fail "a ticket with no bypass must get no proof status"
  pass 'a fixture pull request of a bypassed ticket has a green proof status that says bypassed, with the word id'
}

test_a_release_of_three_tickets_lists_the_bypassed_one() {
  local body
  setup p2; pb grant --ticket b2 --word owner-rule-p2 >/dev/null || fail "the grant"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\$2" in
  view) printf 'pull_request:\n  number: 7\n  state: open\n' ;;
  list) printf 'count: 0\npull_requests: []\n' ;;
  create) while [ "\$#" -gt 0 ]; do [ "\$1" != --body-file ] || cp "\$2" "$W/release-body"; shift; done
    printf 'created:\n  number: 7\n  url: "%s/7"\n  base: main\n  head: trunk\n' "$U" ;;
esac
SH
  cp "$W/fakebin/gh" "$W/fakebin/gh.keep" 2>/dev/null; printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/gh"
  chmod +x "$W/fakebin/gh-axi" "$W/fakebin/gh"
  # b2 lands first, so its landed commit is the one its record names; the other two land after it.
  unproved b2 b2.txt; apply; trunk land b2 >/dev/null 2>&1 || fail "b2 must land under its bypass"
  [ -f "$(record b2)" ] || fail "fixture: b2 must hold a bypass record"
  for id in b1 b3; do lane "$id" "$id"; trunk land "$id" >/dev/null 2>&1 || fail "$id must land"; done
  trunk verify "$PROJ" >/dev/null 2>&1; trunk word release "$PROJ" "ship three" >/dev/null 2>&1 || fail "the release word must record"
  trunk release "$PROJ" >/dev/null 2>&1 || true
  [ -f "$W/release-body" ] || fail "the release must open a pull request with a body"
  body=$(cat "$W/release-body")
  assert_contains "$body" "Bypassed, no proof ran:" "the body has the bypassed list"
  assert_contains "$body" "b2: unproved, bypassed by the owner (word owner-rule-p2)" "the bypassed ticket is listed with its word"
  assert_not_contains "$body" "b1: unproved" "an ordinary ticket is not listed"
  assert_not_contains "$body" "b3: unproved" "an ordinary ticket is not listed"
  pass 'a release of three tickets, one bypassed, lists that one in the body of the release pull request'
}

test_the_live_claim_check_says_not_proven_for_a_bypassed_ticket() {
  local out rc=0
  setup p3; pb grant --ticket c1 --word owner-rule-p3 >/dev/null || fail "the grant"
  unproved c1 c1.txt; unproved c2 c2.txt; apply
  out=$(claim "done" "c1 is fixed and works now") || rc=$?
  assert_equals 3 "$rc" "a downgraded claim exits 3"
  assert_contains "$out" "not proven: bypassed by the owner" "the check prints not proven for the bypassed ticket"
  out=$(claim "done" "c2 is fixed and works now") || true
  assert_not_contains "$out" "not proven" "an ordinary ticket is not marked"
  printf '{"kind":"bypass","task":"c2","ticket":"c2","commit":"%s","bypass":"bp-0-forged","word":"w"}\n' "$(git -C "$PROJ" rev-parse fm/c2)" > "$(record c2)"
  out=$(claim "done" "c2 is fixed and works now") || true
  assert_not_contains "$out" "not proven" "a hand-written record is not believed"
  pass 'the live-claim check prints not proven for a bypassed ticket only'
}

test_the_trace_and_the_board_show_the_unproved_mark() {
  local card
  grep -q 'payload\["mark"\] = "unproved"' "$ROOT/bin/jg-beads-moment.py" || fail "the bypass moment must put the mark in the trace event"
  card=$(printf '%s' '[{"id":"jg-x1","title":"t","status":"open","metadata":{"bypassed_at":"2026-11-12T01:00:00Z"}},{"id":"jg-x2","title":"t","status":"open","metadata":{}}]' \
    | python3 -I "$ROOT/bin/jg-beads-view.py" show jg-x1 2>&1)
  assert_contains "$card" "unproved: yes" "the board card of a bypassed ticket shows the mark"
  card=$(printf '%s' '[{"id":"jg-x2","title":"t","status":"open","metadata":{}}]' | python3 -I "$ROOT/bin/jg-beads-view.py" show jg-x2 2>&1)
  assert_not_contains "$card" "unproved" "the board card of an ordinary ticket shows no mark"
  pass 'the trace event carries the unproved mark and the board card shows it'
}

test_a_pull_request_of_a_bypassed_ticket_has_a_green_proof_status_that_says_so
test_a_release_of_three_tickets_lists_the_bypassed_one
test_the_live_claim_check_says_not_proven_for_a_bypassed_ticket
test_the_trace_and_the_board_show_the_unproved_mark
printf 'jg-bypass-says-so: ok\n'
