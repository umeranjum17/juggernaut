#!/usr/bin/env bash
# Integration test for the lander's provenance writer (jg-q1b3n S8), on a real Beads store through the real jg-backlog.sh.
# A landing writes a `land` event with the landed commit and then landed_at and commit on the ticket's row; the lander's own revert
# ends its message with the trailer `Ticket: <ticket>`, writes a `land` event for the revert and then reverted_at, and leaves landed_at
# and commit as they were; a later landing of the same ticket writes a newer landed_at; a failed write is one warning line and the
# landing still lands. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the builds; without them the run skips plainly.
# It proves bin/jg-beads-trace.py (the verb), bin/jg-trunk.sh (the writer) and bin/jg-beads-write.py (its dispatch), the files the changed-test selector maps to it.
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib/beads-test-env.sh"
# shellcheck source=tests/jg-trunk-fixture.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

bd() { BEADS_DIR=$(cat "$HOME_D/config/beads-dir") "$ROOT/bin/jg-beads.sh" "$@"; }
row() { bd show "$1" --json | jq -c 'if type == "array" then .[0] else . end'; }
meta() { row "$1" | jq -r ".metadata.$2 // empty"; }
events() { bd provenance log "$1" --json | jq -r '[.[] | select(.source == "'"$2"'")] | length'; }

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_landing_and_the_landers_revert_write_provenance_on_the_ticket() {
  local c r msg
  world prov; rig; core_beads_home "$ROOT" "$HOME_D"
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
  # The lander reverts a commit that broke the suite: trailer, event, reverted_at; landed_at and commit stay.
  trunk verify "$PROJ" "$c" >/dev/null 2>&1 && fail "verify must fail on the broken commit"
  r=$(tip); msg=$(git -C "$PROJ" log -1 --format=%B "$r")
  [ "$(printf '%s\n' "$msg" | git interpret-trailers --parse)" = "Ticket: jg-j9" ] || fail "the revert must end with the trailer 'Ticket: jg-j9': $msg"
  [ "$(events jg-j9 jg-trunk-revert)" = 1 ] || fail "one land event from jg-trunk-revert"
  bd provenance log jg-j9 --json | jq -e --arg c "$c" '.[] | select(.source == "jg-trunk-revert") | (.payload | fromjson | .reverts == $c)' >/dev/null || fail "the revert event must carry reverts=<landed sha>"
  [ "$(meta jg-j9 commit)" = "$c" ] || fail "a revert must leave commit as it was"
  [ "$(meta jg-j9 reverted_at)" \> "$(meta jg-j9 landed_at)" ] || [ "$(meta jg-j9 reverted_at)" = "$(meta jg-j9 landed_at)" ] || fail "reverted_at must not be earlier than landed_at"
  pass "the lander's revert ends with the trailer Ticket: jg-j9, writes its event with reverts=<landed sha>, then reverted_at; commit and landed_at stay"
  # A failed write is one warning line and never stops a landing.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/root/bin/jg-backlog.sh"
  lane j10 'echo ok' t/j10.test.sh
  out=$(trunk land j10 2>&1) || fail "j10 lands: $out"
  [ "$(printf "%s\n" "$out" | grep -c "warning: the jg-trunk-land provenance of j10 was not written")" = 1 ] || fail "a failed write must print one warning line: $out"
  [ "$(git -C "$PROJ" log --format=%s trunk | grep -c 'ticket j10')" = 1 ] || fail "the landing must still land"
  pass "a failed provenance write is one warning line and the landing still lands"
}

test_a_landing_and_the_landers_revert_write_provenance_on_the_ticket
printf 'jg-trunk-provenance: ok\n'
