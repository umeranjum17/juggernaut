#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh publish and the landing check's publish step (report jg-7v6uw, slice 23): under the
# captain's standing release word (config/trunk-release-waiver) the green pin is pushed to origin/<trunk> by itself once the trunk
# holds enough, one batch at a time and never forced, and after a red the fix is pushed as a candidate once for each new tip.
# Real git repositories, a local bare origin, a recording forge (gh-axi and gh stand-ins) and a checks reader driven by a file.
#
# T1 No waiver: a trunk that holds enough pushes nothing.
# T2 A waiver and fewer commits than release-after-commits, the oldest one young: nothing is pushed.
# T3 The trunk holds enough: the green pin (not an older or newer commit) is pushed to origin/<trunk> by a fast-forward, the batch
#    pull request opens once and the release row is written.
# T4 More commits land while that batch pull request is open: nothing is pushed into it.
# T5 A red is recorded on the pushed commit and a later commit lands: the pin stays down; while a CI run of the batch is in flight
#    the tip is not pushed; once it is not, the tip is pushed as a candidate, once (a second publish pushes nothing). A green result
#    on the candidate moves the pin past the red, and the next landing moves it again.
# T6 The registered landing check starts the publish step itself within one tick and reports the push in its outbox.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/o/r/pull
ORIGIN=
pubworld() {  # <name>: a world whose forge records, answers the PR state from state-<n> and the checks from pr-checks
  world "$1"; ORIGIN="$W/origin.git"
  printf 'release-after-commits=3\n' >> "$HOME_D/config/trunk-policy"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'pull_request:\n  number: %s\n  state: %s\n' "\$3" "\$(cat "$W/state-\$3" 2>/dev/null || echo closed)" ;;
  list) printf 'count: 0\npull_requests: []\n' ;;
  create) n=\$(( \$(grep -c 'pr create' "$W/gh-calls") + 40 )); echo open > "$W/state-\$n"
    printf 'created:\n  number: %s\n  url: "%s/%s"\n' "\$n" "$U" "\$n" ;;
esac
SH
  # shellcheck disable=SC2016 # the stand-in script expands its own arguments
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr view") printf "{}\\n" ;; esac\nexit 0\n' > "$W/fakebin/gh"
  printf '#!/usr/bin/env bash\ncat "%s/pr-checks" 2>/dev/null || true\n' "$W" > "$W/root/bin/jg-pr-state.sh"
  chmod +x "$W/fakebin/gh-axi" "$W/fakebin/gh" "$W/root/bin/jg-pr-state.sh"
}
waive() { trunk waiver "$PROJ" --rule owner-rule-standing --release >/dev/null 2>&1 || fail "the release waiver must record"; }
landed() {  # <id>...: each lane lands, the trunk and the pin move
  local id out; for id; do lane "$id" "$id"; out=$(trunk land "$id" 2>&1) || fail "$id must land: $out"; done
}
pushed() { git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/trunk || true; }
creates() { grep -c "pr create" "$W/gh-calls" 2>/dev/null || echo 0; }
green() { cat "$HOME_D/state/trunk-green-proj"; }

test_publish_pushes_the_green_pin_only_when_the_trunk_holds_enough_and_only_under_the_waiver() {
  local out pin
  pubworld pub; waive; landed q1 q2
  out=$(trunk publish "$PROJ" 2>&1) || fail "T2: $out"
  assert_contains "$out" "does not hold enough" "T2: it must say why nothing was pushed"
  [ -z "$(pushed)" ] || fail "T2: fewer commits and a young oldest commit must push nothing"
  pass 'T2 under the waiver a trunk with fewer commits and a young oldest commit is not pushed'

  landed q3; mv "$HOME_D/config/trunk-release-waiver" "$W/waiver.off"
  out=$(trunk publish "$PROJ" 2>&1) || fail "T1: publish must exit 0 with no waiver: $out"
  assert_contains "$out" "no release waiver" "T1: it must say why nothing was pushed"
  [ -z "$(pushed)" ] && [ "$(creates)" = 0 ] || fail "T1: with no waiver nothing may be pushed or opened"
  pass 'T1 with no waiver a trunk that holds enough pushes nothing'
  mv "$W/waiver.off" "$HOME_D/config/trunk-release-waiver"; pin=$(green)
  out=$(trunk publish "$PROJ" 2>&1) || fail "T3: publish must push the green pin: $out"
  [ "$(pushed)" = "$pin" ] || fail "T3: origin/trunk must hold the green pin $pin, holds '$(pushed)'"
  [ "$(creates)" = 1 ] || fail "T3: exactly one batch pull request must open"
  [ "$(tail -1 "$HOME_D/data/trunk-releases.tsv" | cut -f3)" = "$pin" ] || fail "T3: the release row must name the pin"
  [ "$(cat "$HOME_D/state/trunk-released-proj")" = "$pin" ] || fail "T3: the released mark must move to the pin"
  grep -q 'merge=approved' "$HOME_D/state/release-proj-trunk.meta" || fail "T3: the release record must carry the standing word"
  pass 'T3 a trunk that holds enough pushes the green pin by a fast-forward and opens the one batch pull request'

  landed q4 q5 q6
  out=$(trunk publish "$PROJ" 2>&1) || fail "T4: $out"
  [ "$(pushed)" = "$pin" ] && [ "$(creates)" = 1 ] || fail "T4: nothing may be pushed into the open batch pull request: $out"
  pass 'T4 a due trunk pushes nothing into an open batch pull request'

  # A red on the pushed commit pins back; a commit lands above it.
  trunk ci "$PROJ" "$pin" red >/dev/null 2>&1 || fail "T5: the red must record"
  [ "$(green)" != "$(tip)" ] || fail "T5: the pin must stay below the red"
  landed q7; [ "$(green)" != "$(tip)" ] || fail "T5: a landing must leave the pin below the red"
  printf 'CHECK: CI required (IN_PROGRESS)\n' > "$W/pr-checks"
  out=$(trunk publish "$PROJ" 2>&1) || fail "T5: $out"
  assert_contains "$out" "in flight" "T5: a run in flight must hold the candidate"
  [ "$(pushed)" = "$pin" ] || fail "T5: nothing is pushed while a CI run is in flight"
  : > "$W/pr-checks"
  out=$(trunk publish "$PROJ" 2>&1) || fail "T5: the candidate must push: $out"
  [ "$(pushed)" = "$(tip)" ] || fail "T5: origin/trunk must hold the tip as a candidate: $out"
  [ "$(creates)" = 1 ] || fail "T5: the candidate goes into the same batch pull request"
  git -C "$ORIGIN" merge-base --is-ancestor "$pin" "$(pushed)" || fail "T5: the candidate must be a fast-forward of the pushed pin"
  out=$(trunk publish "$PROJ" 2>&1) || fail "T5: $out"
  assert_contains "$out" "candidate already" "T5: a tip is pushed once"
  trunk ci "$PROJ" "$(tip)" green >/dev/null 2>&1 || fail "T5: the green result must record"
  [ "$(green)" = "$(tip)" ] || fail "T5: a green result on the candidate must move the pin past the red"
  landed q8; [ "$(green)" = "$(tip)" ] || fail "T5: the next landing must move the pin again"
  pass 'T5 after a red the tip is pushed once as a candidate, not while a run is in flight, and its green moves the pin past the red'
}

test_the_landing_check_publishes_by_itself() {
  local out
  pubworld tick; waive; landed t1
  printf 'release-after-commits=1\n' >> "$HOME_D/config/trunk-policy"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>&1) || fail "T6: the check must not fail: $out"
  for _ in $(seq 1 100); do [ -z "$(pushed)" ] || break; sleep 0.2; done
  [ "$(pushed)" = "$(green)" ] || fail "T6: one tick must push the green pin: $out"
  pass 'T6 the registered landing check publishes the green pin within one tick'
}

test_publish_pushes_the_green_pin_only_when_the_trunk_holds_enough_and_only_under_the_waiver
test_the_landing_check_publishes_by_itself
printf 'jg-trunk-publish: ok\n'
