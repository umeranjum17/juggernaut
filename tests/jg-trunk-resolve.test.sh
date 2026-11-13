#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh (the landing run state `resolving`, slice J32a) through its real `land` command, with real git
# repositories and the real gate chain (tests/jg-trunk-fixture.sh). The resolver is a script of the home, set by policy conflict-resolver.
#
# T1 A lane whose rebase meets a conflict in one file: the run shows `resolving`, the resolver resolves the conflict in the lander's copy,
#    the touched file is listed on the run, conflict_at is written on the ticket, the lane lands, and no steer goes to the worker.
# T2 A resolver that gives up ends the run `returned` with its reason: the refusal carries the reason, the trunk does not move, and the
#    worker is told as before. A resolver that passes its limit is stopped and ends `returned` inside the limit.
# T3 With no resolver set, the conflict is refused as before and no resolving row is written.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# conflicting_pair <name>: lane <name>-a lands first; lane <name>-b was made on the old tip and edits the same file differently.
conflicting_pair() {
  lane "$1-a" first; lane "$1-b" second
  trunk land "$1-a" >/dev/null 2>&1 || fail "the first lane must land"
}
resolver() {  # <name> <body>: a resolver script the home sets by policy
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$W/$1.sh"; chmod +x "$W/$1.sh"
  printf 'conflict-resolver=bash %s/%s.sh\n' "$W" "$1" >> "$HOME_D/config/trunk-policy"
}

test_a_conflict_is_resolved_in_the_landers_copy_and_the_lane_lands() {
  local before out rows
  world resolve
  # shellcheck disable=SC2016 # the resolver script expands its own variables
  resolver merge 'while IFS= read -r f; do printf "merged\n" > "$f"; done < "$JG_RESOLVE_CONFLICTS"'
  conflicting_pair r
  before=$(tip); out=$(trunk land r-b 2>&1) || fail "a resolved conflict must land: $out"
  [ "$(tip)" != "$before" ] || fail "the trunk must move"
  [ "$(git -C "$PROJ" show trunk:work.txt)" = merged ] || fail "the trunk holds the resolved file"
  [ "$(git -C "$PROJ" rev-list --count "$before..trunk")" = 1 ] || fail "the resolved lane is one commit on the tip"
  git -C "$PROJ" log -1 --format=%s trunk | grep -q 'ticket r-b' || fail "the resolved commit keeps the lane's message"
  assert_contains "$out" 'touched: work.txt' 'the landing says what the resolver touched'
  rows=$(cut -f5 "$HOME_D/data/trunk-resolving.tsv" | paste -sd' ' -)
  [ "$rows" = 'resolving resolved' ] || fail "the run shows resolving and then resolved: $rows"
  [ "$(awk -F'\t' '$5 == "resolved" { print $7 }' "$HOME_D/data/trunk-resolving.tsv")" = work.txt ] || fail "the touched file is listed on the run"
  grep -q '^moment r-b conflict_at' "$W/backlog-calls" || fail "conflict_at is written on the ticket: $(cat "$W/backlog-calls")"
  [ ! -s "$W/send-calls" ] || fail "no steer goes to the worker: $(cat "$W/send-calls")"
  ! git -C "$PROJ" worktree list | grep -q resolve- || fail "the lander's copy is removed again"
  pass 'a conflict is resolved in the lander copy, the touched file is listed, conflict_at is written, the lane lands and no steer goes out'
}

test_a_resolver_that_gives_up_or_passes_its_limit_returns_the_lane() {
  local before out start
  world giveup
  resolver giveup 'echo "which side wins is a product call"; exit 3'
  conflicting_pair g
  before=$(tip); out=$(trunk land g-b 2>&1) && fail "a conflict the resolver gives up on must not land: $out"
  assert_contains "$out" 'which side wins is a product call' 'the refusal carries the resolver reason'
  assert_contains "$out" 'in: work.txt' 'the refusal still names the conflicting paths'
  [ "$(tip)" = "$before" ] || fail "a returned run leaves the trunk alone"
  [ "$(cut -f5 "$HOME_D/data/trunk-resolving.tsv" | paste -sd' ' -)" = 'resolving returned' ] || fail "the run ends returned: $(cat "$HOME_D/data/trunk-resolving.tsv")"
  grep -q 'which side wins' "$HOME_D/data/trunk-resolving.tsv" || fail "the returned row holds the reason"
  resolver slow 'sleep 30'
  printf 'conflict-limit-seconds=2\n' >> "$HOME_D/config/trunk-policy"
  sed -i '/giveup.sh/d' "$HOME_D/config/trunk-policy"
  start=$SECONDS; out=$(trunk land g-b 2>&1) && fail "a resolver past its limit must not land: $out"
  [ $((SECONDS - start)) -lt 15 ] || fail "a resolver past its limit is stopped inside the limit, took $((SECONDS - start)) s"
  assert_contains "$out" 'inside its limit of 2 seconds' 'the refusal says the limit passed'
  pass 'a resolver that gives up or passes its limit ends the run returned with the reason, the trunk unmoved'
}

test_with_no_resolver_a_conflict_is_refused_as_before() {
  local out
  world noresolve
  conflicting_pair n
  out=$(trunk land n-b 2>&1) && fail "a conflict with no resolver must not land: $out"
  assert_contains "$out" 'conflicts with trunk' 'the refusal is the old one'
  [ ! -e "$HOME_D/data/trunk-resolving.tsv" ] || fail "no resolving run without a resolver"
  pass 'with no resolver set the conflict is refused as before'
}

test_a_conflict_is_resolved_in_the_landers_copy_and_the_lane_lands
test_a_resolver_that_gives_up_or_passes_its_limit_returns_the_lane
test_with_no_resolver_a_conflict_is_refused_as_before
printf 'jg-trunk-resolve: ok\n'
