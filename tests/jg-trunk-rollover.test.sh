#!/usr/bin/env bash
# Integration test for the rollover of bin/jg-trunk.sh (fable execution plan, slice S3b fric-rollover-carries): no landed
# commit is lost at a release. The lab: a release of the first trunk is open; three commits land on the trunk above the
# released head, the green pin on the second; the release PR merges (a merge commit on the default branch); a home stands
# on the old green commit.
#
# T1 The rollover replays the three commits onto the new trunk one by one, each with the tree of its original; the green
#    pin is the replayed second; the version row names the default-branch commit the trunk was cut from, so release_base
#    is the new row; the old trunk retires (every commit carried by patch) and the home at the old green commit is
#    re-pointed by the fleet mover, where before it was skipped:unlanded.
# T2 A second release from the new trunk opens a new pull request under a new release record, and it ships the replayed
#    commits with the lane that landed after the rollover.
# T3 A replay that cannot be proved equal stops with one line and changes nothing: no ref, no record, no row moves and the
#    old trunk is untouched.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/o/r/pull

# A gh-axi stand-in that numbers its pull requests: create answers the next number, a pull request's state is the file
# pr-state-<n> (open when absent), and no other pull request is open.
numbered_prs() {
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'state: %s\n' "\$(cat "$W/pr-state-\$3" 2>/dev/null || echo open)" ;;
  list) printf 'count: 0\n' ;;
  create) n=\$(( \$(cat "$W/pr-count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$W/pr-count"; printf '$U/%s\n' "\$n" ;;
esac
SH
  # The PR check the release runs: not a draft, base main, head the trunk at its commit, no older release branch open.
  cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2 \$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) git -C "$PROJ" rev-parse "\$(cat "$W/state-trunk" 2>/dev/null || cat "$HOME_D/state/trunk-branch-proj")" ;;
  'pr view '*baseRefName*) printf 'main\t%s\n' "\$(cat "$HOME_D/state/trunk-branch-proj")" ;;
  'api '*) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$W/fakebin/gh-axi" "$W/fakebin/gh"
}

# lane_on <branch> <id> <content>: a lane off <branch>, with one commit, a PASS proof and its done line.
lane_on() {
  local wt="$W/lanes/$2"
  git -C "$PROJ" worktree add -q -b "fm/$2" "$wt" "$1"
  commit_in "$wt" "${4:-work.txt}" "$3" "ticket $2"
  jg_write_meta "$HOME_D/state/$2.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$2" "worktree=$wt" "spawn_gen=g-$2"
  prove "$2"; ready "$2"
}
land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; }
subjects() { git -C "$PROJ" log --reverse --format=%s "$1"; }
trees() { git -C "$PROJ" log --reverse --format=%T "$1"; }

# The lab: release R of the first trunk is open; c1, c2, c3 land above it, the suite passes at c2 only; the release PR
# merges into main as a merge commit; a Main clone and a lead home stand ready, the lead on the old green commit c2.
# Sets R C1 C2 C3 M OLD.
lab() {  # <name>
  world "$1"; numbered_prs
  lane_on trunk a1 released; land a1
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "a1 must verify"
  trunk word release "$PROJ" "ship a1" >/dev/null 2>&1 || fail "the release word must record"
  trunk release "$PROJ" >"$W/release-1.out" 2>&1 || fail "the first release must open: $(cat "$W/release-1.out")"
  R=$(tip)
  lane_on trunk c1 one w1.txt; land c1; C1=$(tip)
  lane_on trunk c2 two w2.txt; land c2; C2=$(tip)
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "c2 must verify"
  lane_on trunk c3 three w3.txt; land c3; C3=$(tip)
  # Each landing moves the green pin to its head, so the pin goes back to c2 by hand: c3 stands for a commit past the last green.
  printf '%s\n' "$C2" > "$HOME_D/state/trunk-green-proj"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$C2" ] || fail "fixture: the green pin must stand on the second commit above the release"
  OLD=$(tip)
  # The merged release is a merge commit of the released head into main, as the forge makes it.
  git -C "$PROJ" fetch -q origin main
  M=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$(git -C "$PROJ" rev-parse "$R^{tree}")" -p origin/main -p "$R" -m "Merge pull request #1")
  git -C "$PROJ" push -q origin "$M:refs/heads/main"; echo merged > "$W/pr-state-1"
  # Main's clone and a lead home on the old green commit: the homes the fleet mover moves.
  git clone -q "$PROJ" "$W/main"
  git -C "$W/main" worktree add -q --detach "$W/lead" "$C2"; printf 'lead\n' > "$W/lead/.jg-squad-lead-home"
  printf -- '- lead - fixture (home: %s; scope: x; projects: proj; added 2026-11-10)\n' "$W/lead" > "$HOME_D/data/squad_leads.md"
}

# The fleet mover over every home, to <sha> on <branch> of the project, with the health check the fixture stubs.
move_homes() {  # <sha> <branch>
  JG_ROOT_OVERRIDE="$W/main" JG_HOME="$HOME_D" JG_STACK_SKIP=1 JG_HOST_WIRING_SKIP=1 \
    "$W/root/bin/jg-update.sh" --base "$1" --project "$PROJ" --branch "$2" 2>&1
}
live_row() { awk -F'\t' '$1 == "proj:lead" { r = $4 } END { print r }' "$HOME_D/data/trunk-live.tsv" 2>/dev/null; }

test_version_two_release_rolls_over_and_names_its_commit() {
  local out sha
  world version2
  sha=$(tip)
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk-v2 "$sha"
  git -C "$PROJ" push -q origin "$sha:refs/heads/merged"
  git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/merged
  printf '%s\n' "$sha" > "$HOME_D/state/trunk-tip-proj"
  printf '%s\n' "$sha" > "$HOME_D/state/trunk-green-proj"
  printf '%s\n' trunk-v2 > "$HOME_D/state/trunk-branch-proj"
  printf '%s\n' 2 > "$HOME_D/state/trunk-version-proj"
  printf 'proj\ttrunk-v2\t%s\t1\t1\thttps://github.com/o/r/pull/9\n' "$sha" > "$HOME_D/data/trunk-releases.tsv"
  printf '%s\n' merged > "$W/pr-state"
  out=$(trunk rollover "$PROJ" 2>&1) || fail "version 2 must roll over: $out"
  [ "$(git -C "$PROJ" rev-parse refs/heads/trunk-v3)" = "$sha" ] || fail "version 3 must hold the release"
  assert_contains "$out" "$sha" "rollover must name the exact commit"
  pass 'version 2 release rolls to version 3 and names its commit'
}

test_a_rollover_replays_every_landed_commit_and_the_green_pin_follows() {
  local out new g n
  lab roll
  out=$(trunk rollover "$PROJ" 2>&1) || fail "T1: the merged release must roll over: $out"
  new=$(git -C "$PROJ" rev-parse --verify -q refs/heads/trunk-v2) || fail "T1: the next trunk must exist"
  [ "$(git -C "$PROJ" rev-list --count "$M..$new")" = 3 ] || fail "T1: the next trunk must hold the three landed commits above the default branch, got $(git -C "$PROJ" rev-list --count "$M..$new") (today it is cut at the merge commit alone)"
  [ "$(git -C "$PROJ" rev-parse "$new~3")" = "$M" ] || fail "T1: the replay must start on the merge commit"
  [ "$(subjects "$M..$new" | paste -sd,)" = "ticket c1,ticket c2,ticket c3" ] || fail "T1: the replayed commits keep their messages and order: $(subjects "$M..$new" | paste -sd,)"
  [ "$(trees "$M..$new")" = "$(printf '%s\n%s\n%s' "$(git -C "$PROJ" rev-parse "$C1^{tree}")" "$(git -C "$PROJ" rev-parse "$C2^{tree}")" "$(git -C "$PROJ" rev-parse "$C3^{tree}")")" ] \
    || fail "T1: each replayed commit must have the tree of its original"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$new" ] || fail "T1: the tip record must be the replayed third commit"
  g=$(cat "$HOME_D/state/trunk-green-proj")
  [ "$g" = "$(git -C "$PROJ" rev-parse "$new~1")" ] || fail "T1: the green pin must be the replayed second commit, not main (pin ${g:0:12}, main ${M:0:12})"
  [ "$(cat "$HOME_D/state/trunk-released-proj")" = "$M" ] || fail "T1: the released mark is the default-branch commit the release became"
  n=$(awk -F'\t' '$1 == "proj" && $2 == 2' "$HOME_D/data/trunk-versions.tsv")
  [ "$(echo "$n" | cut -f1-4)" = "$(printf 'proj\t2\ttrunk-v2\t%s' "$M")" ] || fail "T1: the version row names the commit the trunk was cut from: $n"
  git -C "$PROJ" merge-base --is-ancestor "$M" "$new" || fail "T1: the new trunk's tip must sit on its version base, so the release is judged against it"
  assert_contains "$out" "deleted local trunk" "T1: the old trunk, carried by patch, must retire"
  assert_contains "$out" "deleted remote trunk" "T1: the old trunk's remote branch must retire"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null && fail "T1: the old local trunk must be gone"
  out=$(move_homes "$g" trunk-v2) || fail "T1: the move must reach every home: $out"
  [ "$(git -C "$W/lead" rev-parse HEAD)" = "$g" ] || fail "T1: the home at the old green commit must be on the new green commit: $out"
  [ "$(live_row)" = "live,re-pointed-from:${C2:0:12}" ] || fail "T1: the home must be re-pointed, not skipped: $(live_row)"
  pass 'T1 three landed commits are replayed with equal trees, the green pin is the replayed second, the old trunk retires and the home is re-pointed'
}

test_a_second_release_opens_a_new_pull_request_under_a_new_record() {
  local out meta1 meta2 new
  lab again
  trunk rollover "$PROJ" >/dev/null 2>&1 || fail "T2: the merged release must roll over"
  lane_on trunk-v2 d1 four w4.txt; land d1
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "T2: d1 must verify on the new trunk"
  trunk word release "$PROJ" "ship the next" >/dev/null 2>&1 || fail "T2: the release word must record"
  out=$(trunk release "$PROJ" 2>&1) || fail "T2: the second release must open: $out"
  assert_contains "$out" "$U/2" "T2: the second release must open a new pull request"
  [ "$(grep -c 'pr create' "$W/gh-calls")" = 2 ] || fail "T2: two releases make two create calls"
  assert_contains "$(grep 'pr create' "$W/gh-calls" | tail -n 1)" "--head trunk-v2" "T2: the second pull request goes from the new trunk"
  new=$(awk -F'\t' '$2 == "trunk-v2"' "$HOME_D/data/trunk-releases.tsv")
  [ "$(echo "$new" | cut -f1,2,4,6)" = "$(printf 'proj\ttrunk-v2\t4\t%s/2' "$U")" ] || fail "T2: the second release ships the three replayed commits and the new one: $new"
  meta1="$HOME_D/state/release-proj-trunk.meta"; meta2="$HOME_D/state/release-proj-trunk-v2.meta"
  [ -f "$meta1" ] && [ -f "$meta2" ] || fail "T2: each release has its own record (release-proj-trunk, release-proj-trunk-v2)"
  grep -qxF "pr=$U/1" "$meta1" || fail "T2: the first record names the first pull request: $(cat "$meta1")"
  grep -qxF "pr=$U/2" "$meta2" || fail "T2: the second record names the second pull request: $(cat "$meta2")"
  pass 'T2 a second release from the new trunk opens a new pull request under a new record and ships the carried commits'
}

test_a_replay_that_cannot_be_proved_equal_stops_and_changes_nothing() {
  local out before extra
  lab stop
  # The default branch holds a change the release did not: the replayed trees cannot equal their originals.
  git -C "$PROJ" worktree add -q --detach "$W/mainwt" "$M"; commit_in "$W/mainwt" extra.txt only-on-main "another change on main"
  extra=$(git -C "$W/mainwt" rev-parse HEAD); git -C "$PROJ" push -q origin "$extra:refs/heads/main"
  before=$(cat "$HOME_D/data/trunk-versions.tsv" "$HOME_D/data/trunk-retired.tsv" 2>/dev/null | md5sum)
  out=$(trunk rollover "$PROJ" 2>&1) && fail "T3: an unprovable replay must stop the rollover: $out"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "T3: it must stop with one line: $out"
  assert_contains "$out" "tree" "T3: the line says the trees differ"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk-v2 >/dev/null && fail "T3: no next trunk may be cut"
  [ "$(git -C "$PROJ" rev-parse trunk)" = "$OLD" ] || fail "T3: the old trunk is untouched"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$OLD" ] && [ "$(cat "$HOME_D/state/trunk-branch-proj")" = trunk ] \
    && [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$C2" ] || fail "T3: the records stay where they were"
  [ "$(cat "$HOME_D/data/trunk-versions.tsv" "$HOME_D/data/trunk-retired.tsv" 2>/dev/null | md5sum)" = "$before" ] || fail "T3: no row is written"
  pass 'T3 a replay that cannot be proved equal stops with one line and changes no ref, record or row'
}

test_version_two_release_rolls_over_and_names_its_commit
test_a_rollover_replays_every_landed_commit_and_the_green_pin_follows
test_a_second_release_opens_a_new_pull_request_under_a_new_record
test_a_replay_that_cannot_be_proved_equal_stops_and_changes_nothing
printf 'jg-trunk-rollover: ok\n'
