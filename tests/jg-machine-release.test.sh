#!/usr/bin/env bash
# Behavior test for the release machine (core/machines/tables/release.tsv), report-only: a fixture release in each of its
# six states is read through the real observers, which print the ticket's sub-state delivering.joining and the release word.
# The writer half runs the lander's release-stamp step over real commits with `Ticket` trailers and a recording backlog.
set -u
export LC_ALL=C
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh" M="$ROOT/core/machines"
T=$(jg_test_tmproot jg-machine-release)
export JG_HOME="$T/home" PATH="$T/bin:$PATH" GIT_CONFIG_COUNT=0
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_MACHINES_TABLES
S=$JG_HOME/state D=$JG_HOME/data R=$JG_HOME/projects/repo
mkdir -p "$S" "$D" "$T/bin" "$T/pr" "$R"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
g() { git -C "$R" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false "$@"; }
git init -q -b trunk "$R"; g commit -q --allow-empty -m base; BASE=$(g rev-parse HEAD)
# shellcheck disable=SC2016 # the stub body is written out verbatim and expands when the stub runs
printf '#!/bin/sh\ncat "%s/pr/${3##*/}.json" 2>/dev/null || { echo "could not resolve to a PullRequest" >&2; exit 1; }\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
pr() {  # <number> <OPEN|MERGED|CLOSED> none|running|red|green
  local s=COMPLETED c=SUCCESS
  case $3 in none) printf '{"state":"%s","statusCheckRollup":[]}\n' "$2" > "$T/pr/$1.json"; return ;; running) s=IN_PROGRESS; c= ;; red) c=FAILURE ;; esac
  printf '{"state":"%s","statusCheckRollup":[{"name":"CI required","status":"%s","conclusion":"%s"}]}\n' "$2" "$s" "$c" > "$T/pr/$1.json"
}

bash "$JM" check release >/dev/null; expect_code 0 "$?" "the table lints"
bash "$JM" coverage release >/dev/null; expect_code 0 "$?" "every move names a test"
assert_equals 6 "$(grep -c '^state	' "$M/tables/release.tsv")" "six release states"

# One landed lane per release state; its release pull request is read as gh prints it.
n=0
while IFS=: read -r want state checks joining; do
  n=$((n + 1)); lane=lane-$want; sha=$(g commit-tree "$BASE^{tree}" -p "$BASE" -m "$lane")
  ln -sfn repo "$JG_HOME/projects/p$n"
  tab "$lane" "p$n" "$sha" "$(date +%s)" full >> "$D/trunk-landings.tsv"
  tab "p$n" trunk-v3 "$sha" 3 "$(date +%s)" "https://github.com/example/p$n/pull/$n" >> "$D/trunk-releases.tsv"
  git -C "$R" update-ref "refs/heads/rel$n" "$sha"; pr "$n" "$state" "$checks"
  assert_equals "$want" "$(bash "$M/observers/release.sh" "$lane")" "$lane reads $want"
  assert_contains "$(bash "$M/observers/release.sh" detail "$lane")" $'joining\t'"$joining" "$lane joining is $joining"
  if [ "$joining" = joining ]; then
    assert_equals "joining" "$(bash "$M/observers/ticket.sh" "$lane" | sed -n 's/^delivering\.//p')" "the ticket of $lane reads delivering.joining"
    assert_contains "$(bash "$JM" show delivering "$lane")" $'state\tjoining' "jg-machine shows $lane joining"
  fi
done <<'LIST'
open:OPEN:none:joining
checking:OPEN:running:joining
red:OPEN:red:joining
ready:OPEN:green:joining
merged:MERGED:green:-
abandoned:CLOSED:none:-
LIST
assert_equals "" "$(bash "$M/observers/release.sh" no-such-lane)" "a lane in no release prints nothing"
pass "a fixture release in each of its six states prints the right release word and sub-state"

# The writer: the release step stamps each ticket named by a trailer once, and a refusal never stops the release.
c1=$(g commit-tree "$BASE^{tree}" -p "$BASE" -m "one" -m "Ticket: jg-a1")
c2=$(g commit-tree "$BASE^{tree}" -p "$c1" -m "two" -m "Ticket: jg-b2")
c3=$(g commit-tree "$BASE^{tree}" -p "$c2" -m "three" -m "Ticket: jg-a1")
c4=$(g commit-tree "$BASE^{tree}" -p "$c3" -m "four" -m "Ticket: jg-bad")
cat > "$T/backlog.sh" <<'STUB'
#!/usr/bin/env bash
case $1 in
  show) grep -q "^$2 " "$LOG" 2>/dev/null && echo "metadata: release_opened_at" ;;
  update) [ "$2" != jg-bad ] || exit 1; echo "$2 $3 $4" >> "$LOG" ;;
esac
STUB
chmod +x "$T/backlog.sh"
out=$(LOG="$T/log" JG_BACKLOG="$T/backlog.sh" bash "$M/release-stamp.sh" "$R" "$BASE" "$c4" 2>&1); expect_code 0 "$?" "the stamp never fails the release"
assert_equals 2 "$(wc -l < "$T/log" | tr -d ' ')" "jg-a1 and jg-b2 are stamped once each"
assert_contains "$(cat "$T/log")" "jg-a1 --set-metadata release_opened_at=20" "the moment is RFC3339 text"
assert_contains "$out" "could not record release_opened_at on jg-bad" "a refused ticket is named"
LOG="$T/log" JG_BACKLOG="$T/backlog.sh" bash "$M/release-stamp.sh" "$R" "$BASE" "$c4" >/dev/null 2>&1
assert_equals 2 "$(wc -l < "$T/log" | tr -d ' ')" "a second push into the same release moves no moment"
pass "the release step stamps each carried ticket once, found by its Ticket trailer"
