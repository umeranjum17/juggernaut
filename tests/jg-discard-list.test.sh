#!/usr/bin/env bash
# tests/jg-discard-list.test.sh - bin/jg-discard-list.sh sorts old lanes and shows each unlanded
# result to the owner once. Four old lanes through the real tool, the real landed-work test
# (bin/jg-teardown-core.sh) and the real card poster (bin/jg-question-card.sh):
#   - patch-equal to the trunk: cleaned with the ordinary unforced teardown, no card
#   - pull request closed unmerged: one card with its diff size and age, nothing discarded
#   - no pull request, work not on the trunk, worker stopped: one card, nothing discarded
#   - pull request still open: left alone
# plus a lane too young to judge, a second run that adds no second card, and --dry-run.
# The forge is a fake `gh`; the teardown is a recorder, so the test can prove --force is never used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "${JG_TEARDOWN_CORE_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the landed-work check\n'
  exit 0
fi

LAB=$(jg_test_tmproot jg-discard-list)
LAB=$(cd "$LAB" && pwd)
TOOL=$ROOT/bin/jg-discard-list.sh
g() { git -c user.email=t@t -c user.name=t "$@"; }

HOMEDIR=$LAB/home
mkdir -p "$HOMEDIR/state" "$HOMEDIR/data" "$HOMEDIR/config" "$LAB/bin" "$LAB/so/.sign-off" "$LAB/forge"
printf '{"schema":2,"items":[]}\n' > "$LAB/so/.sign-off/decisions.json"
printf 'leash: matters\n' > "$LAB/so/.sign-off/config.yaml"
printf 'set mode off\n' > "$LAB/channel-off"

# A fake forge: `gh pr view <url>` answers from forge/<pull number>; no branch has a pull request otherwise.
cat > "$LAB/bin/gh" <<'GH'
#!/usr/bin/env bash
f=$FORGE/$(basename "$3")
[ -f "$f" ] || exit 1
cat "$f"
GH
cat > "$LAB/bin/gh-axi" <<'AXI'
#!/usr/bin/env bash
printf 'count: 0\npull_requests: []\n'
AXI
cat > "$LAB/bin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  list) jq -c '{decisions: [.items[]]}' "$board" ;;
  raise)
    key='' title='' why=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --key) key=$2; shift ;; --title) title=$2; shift ;; --why) why=$2; shift ;; esac
      shift
    done
    if jq -e --arg k "$key" '[.items[]? | select(.key == $k)] | length > 0' "$board" >/dev/null 2>&1; then
      printf 'raised: %s is already on the board\n' "$key"; exit 0
    fi
    jq --arg k "$key" --arg t "$title" --arg w "$why" '.items += [{key: $k, kind: "decision", title: $t, why: $w}]' "$board" > "$board.t" && mv "$board.t" "$board"
    printf '%s\n' "$key" ;;
esac
SH
# The teardown recorder: every call is logged; nothing is removed.
cat > "$LAB/bin/teardown" <<'TD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEARDOWN_LOG"
TD
chmod +x "$LAB/bin/gh" "$LAB/bin/gh-axi" "$LAB/bin/sign-off-axi" "$LAB/bin/teardown"

# The project: a local origin whose default branch is main.
g init -q --bare -b main "$LAB/origin.git"
g clone -q "$LAB/origin.git" "$LAB/proj" 2>/dev/null
( cd "$LAB/proj" && g checkout -q -b main && echo base > f && g add f && g commit -q -m base && g push -q origin main && git remote set-head origin main >/dev/null )

tab=$(printf '\t')
lane() {  # <id> <pr number or -> <age in days>: a copy with one commit of its own, and its record
  local id=$1 pr=$2 days=$3 wt=$LAB/wt-$1
  g clone -q "$LAB/origin.git" "$wt" 2>/dev/null
  ( cd "$wt" && g checkout -q -b "feature/$id" && printf '%s\n' "$id" > "w-$id" && g add . && g commit -q -m "jg-x-$id: add the $id report" )
  {
    printf 'kind=ship\nmode=direct-PR\nbranch=feature/%s\nbase_branch=main\n' "$id"
    printf 'worktree=%s\nproject=%s\n' "$wt" "$LAB/proj"
    [ "$pr" = - ] || printf 'pr=https://github.com/o/r/pull/%s\n' "$pr"
  } > "$HOMEDIR/state/$id.meta"
  printf 'done [at=1]: ready\n' > "$HOMEDIR/state/$id.status"
  touch -d "$days days ago" "$HOMEDIR/state/$id.meta" "$HOMEDIR/state/$id.status"
}
lane same - 5
lane closed 2 5
lane stopped - 5
lane open 4 5
lane young - 0
# The closed and the open pull requests, as the forge reports them.
printf 'CLOSED%s%s%shttps://github.com/o/r/pull/2\n' "$tab" "$(git -C "$LAB/wt-closed" rev-parse HEAD)" "$tab" > "$LAB/forge/2"
printf 'OPEN%s%s%shttps://github.com/o/r/pull/4\n' "$tab" "$(git -C "$LAB/wt-open" rev-parse HEAD)" "$tab" > "$LAB/forge/4"
# "same": its content reached the trunk under another commit (a squash), the branch was never merged.
( cd "$LAB/proj" && printf 'same\n' > w-same && g add . && g commit -q -m "squash (#9)" && g push -q origin main )

export TEARDOWN_LOG=$LAB/teardown.log
: > "$TEARDOWN_LOG"
run() {  # [tool args...]
  env PATH="$LAB/bin:$PATH" FORGE="$LAB/forge" TEARDOWN_LOG="$TEARDOWN_LOG" \
    JG_HOME="$HOMEDIR" JG_ROOT_OVERRIDE="$HOMEDIR" JG_STATE_OVERRIDE="$HOMEDIR/state" JG_TEARDOWN_CORE_BIN="$LAB/core-bin" \
    JG_DISCARD_LIST_TEARDOWN="$LAB/bin/teardown" JG_CAPTAIN_CHANNEL="$LAB/channel-off" \
    SIGN_OFF_HOME="$LAB/so" SIGNOFF_LOG="$LAB/signoff.log" "$TOOL" "$@" 2>"$LAB/err"
}
cards() { jq -r '.items | length' "$LAB/so/.sign-off/decisions.json"; }

# A dry run changes nothing and says what it would do.
out=$(run --dry-run) || fail "dry run failed: $out $(cat "$LAB/err")"
assert_contains "$out" "same${tab}would clean" "dry run: the patch-equal lane is not marked for cleaning"
assert_contains "$out" "closed${tab}would card" "dry run: the closed lane is not marked for a card"
assert_equals "0" "$(cards)" "dry run posted a card"
assert_equals "0" "$(wc -l < "$TEARDOWN_LOG" | tr -d ' ')" "dry run ran a teardown"
pass "a dry run lists every lane and changes nothing"

out=$(run) || fail "run failed: $out $(cat "$LAB/err")"
assert_contains "$out" "same${tab}cleaned" "the patch-equal lane was not cleaned"
assert_contains "$out" "open${tab}open" "the lane with an open pull request was not left"
assert_contains "$out" "young${tab}left${tab}only 0 hours old" "the young lane was not left"
assert_contains "$out" "closed${tab}carded${tab}card discard-closed" "the closed lane has no card"
assert_contains "$out" "stopped${tab}carded${tab}card discard-stopped" "the stopped lane has no card"
assert_contains "$out" "1 files, +1 -0 lines in 1 commits" "the card line does not carry the diff size"
assert_contains "$out" "120 hours old" "the card line does not carry the age"
assert_contains "$out" "cleaned=1 carded=2 open=1 left=1" "the counts are wrong"
pass "four lanes: one cleaned, two carded, one open, plus one too young"

assert_equals "2" "$(cards)" "there is not exactly one card for each unlanded lane"
assert_equals "discard-closed discard-stopped" "$(jq -r '[.items[].key] | sort | join(" ")' "$LAB/so/.sign-off/decisions.json")" "the cards are not keyed by lane"
assert_contains "$(jq -r '.items[] | select(.key == "discard-closed") | .why' "$LAB/so/.sign-off/decisions.json")" "closed without a merge" "the closed card does not say why"
assert_contains "$(jq -r '.items[] | select(.key == "discard-stopped") | .title' "$LAB/so/.sign-off/decisions.json")" "add the stopped report" "the card does not use the work's own words"
pass "each unlanded lane has one card with its size and age"

assert_equals "same" "$(cat "$TEARDOWN_LOG")" "the teardown was not run once, for the landed lane only"
case $(cat "$TEARDOWN_LOG") in *--force*) fail "the tool passed --force" ;; esac
[ -d "$LAB/wt-closed" ] && [ -d "$LAB/wt-stopped" ] || fail "an unlanded copy was removed"
pass "the landed lane is cleaned without --force, and unlanded copies are untouched"

out=$(run) || fail "second run failed"
assert_equals "2" "$(cards)" "a second run posted a second card"
pass "a second run adds no second card"

