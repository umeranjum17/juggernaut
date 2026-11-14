#!/usr/bin/env bash
# Integration test for core/trunk-ci/ci-result.sh: the CI result of a trunk commit reaches the trunk by itself.
# The check runs as the registered check does (`ci-result.sh check <home>`) over a real trunk with the real bin/jg-trunk.sh; only
# the forge (gh-axi api) is a stand-in, answering from a recorded runs file through the same jq filter the check passes it.
# R1 watch mode (the default): a green and a red commit each get one row; the trunk (data/trunk-ci.tsv, green pin) is untouched.
#    A commit with a run still going, and a commit not on the trunk, get no row. A second tick writes and prints nothing.
# R2 act mode: a new green and a new red commit are sent to `jg-trunk.sh ci`: rows in data/trunk-ci.tsv, the red moves the green pin back.
# R3 act mode holds when more than 2 of the last 20 results are red: the row says held and the trunk is not sent the result.
# R4 a forge that does not answer writes nothing; the wiring installs the check and the unwiring removes it and keeps the rows.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

OBS() { echo "$HOME_D/data/trunk-ci-observed.tsv"; }
# run <sha> <id> <status> <conclusion>: one workflow run of the trunk branch on the forge
run() { jq -nc --arg s "$1" --argjson i "$2" --arg st "$3" --arg c "$4" '{head_sha:$s,id:$i,status:$st,conclusion:(if $c == "" then null else $c end),updated_at:"2026-11-14T00:00:10Z"}'; }
forge() { jq -sc '{workflow_runs: .}' > "$W/runs.json"; }
tick() { PATH="$W/fakebin:$PATH" JG_TRUNK_CI_GH="$W/fakebin/forge" bash "$ROOT/core/trunk-ci/ci-result.sh" check "$HOME_D" 2>&1; }
landed() { local id out; for id; do lane "$id" "$id"; out=$(trunk land "$id" 2>&1) || fail "$id must land: $out"; done; }

test_ci_results_reach_the_trunk() {
  local out c1 c2 c3 c4 pin rows
  world ci
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  git -C "$PROJ" remote set-url origin https://github.com/o/r.git  # the forge is read for this repository
  # shellcheck disable=SC2016 # the stand-in script expands its own variables
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && [[ "$2" == repos/o/r/actions/runs?branch=* ]] || exit 1\n[ -f "%s/forge-down" ] && exit 1\njq -r "$4" "%s/runs.json"\n' "$W" "$W" > "$W/fakebin/forge"
  chmod +x "$W/fakebin/forge"
  landed c1 c2; c1=$(git -C "$PROJ" rev-parse "trunk~1"); c2=$(tip)
  git -C "$PROJ" worktree add -q -b stray "$W/stray" "$c1"; commit_in "$W/stray" s.txt s "stray"; local stray; stray=$(git -C "$W/stray" rev-parse HEAD)
  { run "$c1" 11 completed success; run "$c1" 12 completed skipped; run "$c2" 21 completed failure; run "$c2" 22 completed success
    run "$stray" 31 completed failure; } | forge
  pin=$(cat "$HOME_D/state/trunk-green-proj")

  out=$(tick) || fail "R1: $out"
  assert_contains "$out" "red at ${c2:0:12}" "R1: the red prints one line"
  [ "$(wc -l < "$(OBS)")" = 2 ] || fail "R1: two rows expected: $(cat "$(OBS)")"
  { grep -Eq "^proj	$c1	[0-9]+	green	12	watch	-$" "$(OBS)" && grep -Eq "^proj	$c2	[0-9]+	red	21	watch	-$" "$(OBS)"; } || fail "R1: wrong rows: $(cat "$(OBS)")"
  ! grep -q "$stray" "$(OBS)" || fail "R1: a commit not on the trunk must get no row"
  [ ! -s "$HOME_D/data/trunk-ci.tsv" ] && [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$pin" ] || fail "R1: watch mode must not touch the trunk"
  out=$(tick) || fail "R1: $out"
  [ -z "$out" ] && [ "$(wc -l < "$(OBS)")" = 2 ] || fail "R1: a second tick must do nothing: $out"
  pass 'R1 watch mode records each ended commit once and leaves the trunk alone'

  landed c3 c4; c3=$(git -C "$PROJ" rev-parse "trunk~1"); c4=$(tip)
  printf 'act\n' > "$HOME_D/config/trunk-ci-result"
  { run "$c3" 41 completed success; run "$c4" 51 completed failure; run "$c4" 52 in_progress ""; } | forge
  out=$(tick) || fail "R2: $out"
  [ "$(wc -l < "$(OBS)")" = 3 ] || fail "R2: the commit with a run still going gets no row yet: $(cat "$(OBS)")"
  { run "$c3" 41 completed success; run "$c4" 51 completed failure; run "$c4" 52 completed success; } | forge
  out=$(tick) || fail "R2: $out"
  { grep -Eq "^proj	$c3	[0-9]+	green	41	act	acted$" "$(OBS)" && grep -Eq "^proj	$c4	[0-9]+	red	51	act	acted$" "$(OBS)"; } || fail "R2: wrong rows: $(cat "$(OBS)")"
  { grep -Eq "^proj	$c3	[0-9]+	green" "$HOME_D/data/trunk-ci.tsv" && grep -Eq "^proj	$c4	[0-9]+	red" "$HOME_D/data/trunk-ci.tsv"; } || fail "R2: the trunk must hold both results: $(cat "$HOME_D/data/trunk-ci.tsv")"
  pin=$(cat "$HOME_D/state/trunk-green-proj")
  { [ "$pin" != "$c4" ] && git -C "$PROJ" merge-base --is-ancestor "$pin" "$c4"; } || fail "R2: a red must move the green pin back below the red commit"
  pass 'R2 act mode sends each result to the trunk and a red moves the green pin back'

  landed c5; c5=$(tip)
  printf '%s\n' "proj	aaaa	1	red	1	act	acted" "proj	bbbb	1	red	2	act	acted" >> "$(OBS)"  # 3 reds with c4 in the window: this red is the 4th
  { run "$c5" 61 completed failure; } | forge
  out=$(tick) || fail "R3: $out"
  grep -Eq "^proj	$c5	[0-9]+	red	61	act	held$" "$(OBS)" || fail "R3: the red must be held: $(tail -n 2 "$(OBS)")"
  ! grep -q "$c5" "$HOME_D/data/trunk-ci.tsv" || fail "R3: a held result must not reach the trunk"
  pass 'R3 act mode holds when more than 2 of the last 20 results are red'

  landed c6; c6=$(tip); rows=$(wc -l < "$(OBS)")
  { run "$c6" 71 completed success; } | forge; : > "$W/forge-down"
  out=$(tick) || fail "R4: $out"
  [ -z "$out" ] && [ "$(wc -l < "$(OBS)")" = "$rows" ] || fail "R4: a silent forge must write nothing: $out"
  rm -f "$W/forge-down"

  mkdir -p "$HOME_D/bin"
  # shellcheck disable=SC2016 # the stub's own $vars must stay literal
  printf '#!/usr/bin/env bash\n[ -x "$JG_HOME/state/$1.check.sh" ] && printf "register %%s\\n" "$1" >> "$JG_HOME/register.log"\n' > "$HOME_D/bin/jg-check-register.sh"
  # shellcheck disable=SC2016 # the stub's own $vars must stay literal
  printf '#!/usr/bin/env bash\nrm -f -- "$JG_HOME/state/$1.check.sh"\n' > "$HOME_D/bin/jg-check-unregister.sh"
  chmod +x "$HOME_D/bin/jg-check-register.sh" "$HOME_D/bin/jg-check-unregister.sh"
  export XDG_DATA_HOME=$W/share
  bash "$ROOT/core/trunk-ci/wiring.sh" "$HOME_D" >/dev/null || fail "R4: the wiring failed"
  [ "$(cat "$HOME_D/register.log")" = 'register trunk-ci' ] || fail "R4: the check was not registered"
  PATH="$W/fakebin:$PATH" JG_TRUNK_CI_GH="$W/fakebin/forge" "$HOME_D/state/trunk-ci.check.sh" >/dev/null
  grep -q "^proj	$c6	" "$(OBS)" || fail "R4: the installed shim must record the result: $(tail -n 1 "$(OBS)")"
  bash "$ROOT/core/trunk-ci/unwiring.sh" "$HOME_D" >/dev/null || fail "R4: the unwiring failed"
  [ ! -e "$HOME_D/state/trunk-ci.check.sh" ] && [ ! -e "$W/share/jg-trunk-ci" ] && [ -s "$(OBS)" ] || fail "R4: the unwiring must remove the shim and keep the rows"
  pass 'R4 a silent forge writes nothing; the wiring installs the check and the unwiring removes it'
}
test_ci_results_reach_the_trunk
printf 'jg-trunk-ci-result: ok\n'
