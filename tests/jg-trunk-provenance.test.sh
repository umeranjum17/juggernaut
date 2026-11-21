#!/usr/bin/env bash
# Integration test for the lander's provenance writer (jg-q1b3n S8), on the home's ticket tables through the real jg-backlog.sh.
# A landing writes a `land` event with the landed commit and then landed_at and commit on the ticket's row; a verify that finds the
# commit red reverts nothing (docs/trunk-flow.md), so it writes no revert event and no reverted_at and leaves landed_at and commit as
# they were; a failed write is one warning line and the landing still lands.
# It proves bin/jg-beads-trace.py (the verb), bin/jg-trunk.sh (the writer) and bin/jg-beads-write.py (its dispatch), the files the changed-test selector maps to it.
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

test_a_landing_writes_provenance_and_a_red_verify_reverts_nothing
printf 'jg-trunk-provenance: ok\n'
