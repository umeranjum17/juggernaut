#!/usr/bin/env bash
# Integration test for the lander's provenance writer (jg-q1b3n S8), on the home's ticket tables through the real jg-backlog.sh.
# A landing writes a `land` event with the landed commit and then landed_at and commit on the ticket's row; a verify that finds the
# commit red reverts nothing (docs/trunk-flow.md), so it writes no revert event and no reverted_at and leaves landed_at and commit as
# they were; a failed write is one warning line and the landing still lands.
# The registered landing check closes the matching ticket from the receipt, independently of cleanup, and repairs a stranded close.
# shellcheck source=tests/jg-trunk-fixture.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

bd() { JG_HOME=$HOME_D python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@"; }
row() { bd show "$1" --json | jq -c 'if type == "array" then .[0] else . end'; }
meta() { row "$1" | jq -r ".metadata.$2 // empty"; }
events() { bd provenance log "$1" --json | jq -r '[.[] | select(.source == "'"$2"'")] | length'; }

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_landing_writes_provenance_and_a_red_verify_reverts_nothing() {
  local c r
  world prov; rig; jg_test_beads_home "$HOME_D"
  cp "$ROOT/bin/jg-backlog.sh" "$W/root/bin/jg-backlog.sh"
  ln -sfn "$ROOT/toolchain.versions" "$W/root/toolchain.versions"
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" add jg-j9 "[feature] fixture j9" --priority 2 --body why >/dev/null || fail "file the ticket"
  bd update jg-j9 --set-metadata task=j9 >/dev/null || fail "join the ticket to its task name"
  lane j9 'echo "not ok - j9 breaks the suite" >&2; exit 1' t/j9.test.sh 'Ticket: jg-j9'
  out=$(trunk land j9 2>&1) || fail "j9 lands: $out"; c=$(tip)
  [ "$(meta jg-j9 commit)" = "$c" ] || fail "the row must hold the landed commit, got [$(meta jg-j9 commit)]"
  [ -n "$(meta jg-j9 landed_at)" ] || fail "the row must hold landed_at"
  [ "$(events jg-j9 jg-trunk-land)" = 1 ] || fail "one land event from jg-trunk-land"
  [ "$(bd provenance log jg-j9 --json | jq -r '[.[] | select(.source == "jg-trunk-land")][0].ref')" = "$c" ] || fail "the event must hold the landed commit"
  [ "$(bd provenance log jg-j9 --json | jq -r '[.[] | select(.source == "jg-trunk-land")][0].occurred_at')" = "$(meta jg-j9 landed_at)" ] || fail "the event and the row must carry the same time"
  pass "a landing writes a land event with the landed commit, then landed_at and commit on the ticket's row, with the same time"
  # A verify that finds the commit red reports it and reverts nothing: the tip, the row and the trail stay as the landing left them.
  r=$(meta jg-j9 landed_at)
  trunk verify "$PROJ" "$c" >/dev/null 2>&1 && fail "verify must fail on the broken commit"
  [ "$(tip)" = "$c" ] || fail "verify must not revert the red commit, the tip moved to $(tip)"
  [ "$(events jg-j9 jg-trunk-revert)" = 0 ] || fail "no land event from jg-trunk-revert"
  [ -z "$(meta jg-j9 reverted_at)" ] || fail "the row must hold no reverted_at"
  [ "$(meta jg-j9 commit)" = "$c" ] || fail "a red verify must leave commit as it was"
  [ "$(meta jg-j9 landed_at)" = "$r" ] || fail "a red verify must leave landed_at as it was"
  pass "a red verify reverts nothing: no revert event, no reverted_at; commit and landed_at stay"
  # A failed write is one warning line and never stops a landing.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/root/bin/jg-backlog.sh"
  lane j10 'echo ok' t/j10.test.sh
  out=$(trunk land j10 2>&1) || fail "j10 lands: $out"
  [ "$(printf "%s\n" "$out" | grep -c "warning: the jg-trunk-land provenance of j10 was not written")" = 1 ] || fail "a failed write must print one warning line: $out"
  [ "$(git -C "$PROJ" log --format=%s trunk | grep -c 'ticket j10')" = 1 ] || fail "the landing must still land"
  pass "a failed provenance write is one warning line and the landing still lands"
}

test_a_landing_receipt_repairs_an_open_ticket() {
  local out head piece _
  local -x JG_TEST_SEAM=1
  world close-ticket; jg_test_beads_home "$HOME_D"
  cp "$ROOT/bin/jg-backlog.sh" "$W/root/bin/jg-backlog.sh"
  cp -r "$W/root/bin" "$HOME_D/bin"
  ln -sn "$ROOT/core" "$HOME_D/core"
  ln -sn "$ROOT/policy" "$HOME_D/policy"
  # Give the landing check a dispatch stand-in so it never spawns a worker.
  printf '#!/usr/bin/env bash\ndate +%%s >> "%s/dispatch-calls"\n' "$W" > "$HOME_D/state/auto-dispatch.check.sh"
  chmod +x "$HOME_D/state/auto-dispatch.check.sh"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" add jg-close.1 "Close fixture lane" --priority 2 --repo proj --body why >/dev/null || fail "file the lane ticket"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" add jg-follow "Start dependent lane" --priority 2 --repo proj --blocked-by jg-close.1 --body why >/dev/null || fail "file the dependent"
  out=$(JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" add "Finish open piece" --priority 2 --repo proj --parent jg-close.1 --body why --json) || fail "file an open piece: $out"
  piece=$(jq -er '.task.id' <<< "$out") || fail "read the piece id"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" task jg-close.1 >/dev/null || fail "bind the lane ticket"
  lane jg-close-1 one work.txt 'Ticket: jg-close.1'
  printf 'ticket=jg-close.1\n' >> "$HOME_D/state/jg-close-1.meta"
  out=$(trunk land jg-close-1 2>&1) || fail "the lane must land: $out"
  head=$(tip)
  # Simulate an interrupted landing after the receipt was recorded, with no lane metadata left.
  rm -f "$HOME_D/state/jg-close-1.meta"
  printf '%s\n' "$head" > "$HOME_D/state/trunk-green-proj"
  out=$(sweep)
  assert_contains "$out" 'jg-close.1' "a landed ticket that cannot close must be reported"
  assert_contains "$out" 'open pieces' "the alert must name the close refusal"
  [ "$(row jg-close.1 | jq -r .status)" != closed ] || fail "the existing close guard must keep a ticket with open pieces open"
  out=$(sweep)
  [[ $out != *'jg-close.1'* ]] || fail "the same refusal must not alert again: $out"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" 'done' "$piece" >/dev/null || fail "close the piece"
  sweep >/dev/null
  [ "$(row jg-close.1 | jq -r .status)" = closed ] || fail "the next tick must close the lane ticket from the receipt"
  [ "$(tip)" = "$head" ] && [ ! -e "$W/teardown-calls" ] || fail "ticket repair must not retry landing or run cleanup"
  for _ in $(seq 1 50); do [ -s "$W/dispatch-calls" ] && break; sleep 0.1; done
  [ -s "$W/dispatch-calls" ] || fail "ticket repair must kick dispatch"
  out=$(JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" ready --repo proj) || fail "read ready dependents"
  assert_contains "$out" jg-follow "closing the ticket unblocks the dependent"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" reopen jg-close.1 >/dev/null || fail "reopen the resolved ticket"
  sweep >/dev/null
  [ "$(row jg-close.1 | jq -r .status)" = open ] || fail "the settled receipt must not close a later reopening"
  [ "$(wc -l < "$W/dispatch-calls")" -eq 1 ] || fail "the receipt starts dispatch once"
  pass "a stranded ticket alerts once, repairs from its receipt and unblocks its dependent"
}

test_a_landing_closes_the_ticket_when_cleanup_refuses() {
  local out head
  local -x JG_TEST_SEAM=1
  world close-without-cleanup; jg_test_beads_home "$HOME_D"
  cp "$ROOT/bin/jg-backlog.sh" "$W/root/bin/jg-backlog.sh"
  cp -r "$W/root/bin" "$HOME_D/bin"
  ln -sn "$ROOT/core" "$HOME_D/core"
  ln -sn "$ROOT/policy" "$HOME_D/policy"
  printf '#!/usr/bin/env bash\necho "cleanup refused, reason: uncommitted" >&2\nexit 1\n' > "$HOME_D/bin/jg-teardown.sh"
  JG_HOME=$HOME_D "$ROOT/bin/jg-backlog.sh" add jg-finish "Finish fixture lane" --priority 2 --repo proj --body why >/dev/null || fail "file the lane ticket"
  lane jg-finish one
  head=$(git -C "$PROJ" rev-parse fm/jg-finish)
  out=$(PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" run "$HOME_D" jg-finish "$head" 2>&1) || fail "land the lane: $out"
  [ "$(tip)" = "$head" ] || fail "the lane must land"
  [ "$(row jg-finish | jq -r .status)" = closed ] || fail "the landed receipt must close the ticket on this run"
  [ -f "$HOME_D/state/jg-finish.meta" ] || fail "refused cleanup must keep the lane"
  grep -q 'reason: uncommitted' "$HOME_D/data/jg-trunk-landing/outbox" || fail "the cleanup refusal must still alert"
  pass "landing closes its ticket while refused cleanup keeps the lane"
}

test_a_landing_writes_provenance_and_a_red_verify_reverts_nothing
test_a_landing_receipt_repairs_an_open_ticket
test_a_landing_closes_the_ticket_when_cleanup_refuses
printf 'jg-trunk-provenance: ok\n'
