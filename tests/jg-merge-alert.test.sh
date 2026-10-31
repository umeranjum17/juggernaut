#!/usr/bin/env bash
# bin/jg-merge-alert.sh: every proven merge raises one board alert, and a board
# that is down queues it durably instead of blocking the merge. The forge and the
# board client are stubs; the card and the queue are real.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ALERT="$ROOT/bin/jg-merge-alert.sh"
T=$(jg_test_tmproot merge-alert)
BOARD=$T/board.json
PR=https://github.com/acme/app/pull/7

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "Show merge alerts on the board"
STUB
# The board client: list prints the board, post appends the card unless the board is down.
cat > "$T/bin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) cat -- "$2" ;;
  post)
    [ ! -e "$STUB_DOWN" ] || { echo "board is down" >&2; exit 1; }
    from=''; prev=''; for a in "$@"; do [ "$prev" != --from ] || from=$a; prev=$a; done
    echo "$*" >> "$STUB_POSTS"
    jq -c --slurpfile c "$from" '.decisions += [$c[0] + {type: "evidence"}]' "$2" > "$2.new"
    mv -f "$2.new" "$2" ;;
esac
STUB
chmod +x "$T/bin/gh" "$T/bin/sign-off-axi"
export STUB_DOWN=$T/board-down STUB_POSTS=$T/board-posts

new_home() {  # <name> [with-board]: a home with state, config and a board
  local h=$T/$1
  mkdir -p "$h/config" "$h/state" "$h/data"
  [ "${2:-board}" != board ] || printf '#!/bin/sh\nexec x post --board %s "$@"\n' "$BOARD" > "$h/config/post-merge"
  printf '{"decisions":[]}\n' > "$BOARD"; rm -f "$STUB_DOWN" "$STUB_POSTS"
  printf 'project=/x/projects/app\nharness=claude\nmodel=claude-sonnet-5-5\n' > "$h/state/t1.meta"
  printf '%s\n' "$h"
}
alert() {  # <home> <args...>
  local h=$1; shift
  JG_HOME=$h PATH="$T/bin:$PATH" bash "$ALERT" "$@" 2>&1
}
card() { jq -c --arg k "$1" '.decisions[] | select(.key == $k)' "$BOARD"; }

h=$(new_home plain)
alert "$h" post t1 --pr "$PR" >/dev/null || fail "post exits 0"
c=$(card mergealert-acme-app-pull-7)
assert_equals "Merged: Show merge alerts on the board" "$(jq -r .title <<<"$c")" "title is the PR title"
assert_equals "evidence Fixed" "$(jq -r '"\(.kind) \(.status)"' <<<"$c")" "the alert is a text-only evidence card"
assert_contains "$(jq -r .about <<<"$c")" "Project app. PR $PR." "about names the project and the full PR URL"
assert_contains "$(jq -r .about <<<"$c")" "Merged by Main (model not recorded)" "Main records no model and the card says so"
assert_contains "$(jq -r .about <<<"$c")" "Built by worker t1 (claude claude-sonnet-5-5)" "about names the worker and its model"
assert_contains "$(jq -r .about <<<"$c")" "No proof card on the board." "about says when no proof card exists"
assert_equals null "$(jq -c '.link // null' <<<"$c")" "no link without a proof card"
assert_not_contains "$(jq -r .about <<<"$c")" "$PR/" "the alert carries no PR link field that one-card-per-pr could sweep"
[ ! -e "$h/state/merge-alerts/pending/mergealert-acme-app-pull-7.json" ] && [ -e "$h/state/merge-alerts/sent/mergealert-acme-app-pull-7.json" ] || fail "a delivered alert leaves the pending queue"
out=$(alert "$h" post t1 --pr "$PR")
assert_contains "$out" "already recorded" "a repeat is a no-op"
assert_equals 1 "$(wc -l < "$STUB_POSTS" | tr -d ' ')" "a repeat posts nothing"
pass "post files one text-only alert naming project, PR, merger and worker"

# The proof card's deep link, with the board token stripped.
h=$(new_home proof)
echo 'http://100.64.0.1:4420/?token=SECRET' > "$h/state/signoff-board.url"
printf '{"decisions":[{"key":"merge-acme-app-pull-7","type":"evidence","title":"proof"}]}\n' > "$BOARD"
alert "$h" post t1 --pr "$PR" >/dev/null
c=$(card mergealert-acme-app-pull-7)
assert_equals "http://100.64.0.1:4420/#evidence/merge-acme-app-pull-7" "$(jq -r .link <<<"$c")" "link is the proof card's deep link without the token"
assert_contains "$(jq -r .about <<<"$c")" "Proof card: merge-acme-app-pull-7." "about names the proof card"
assert_not_contains "$c" SECRET "the board token never reaches the card"
pass "proof card link"

# A board that is down queues the alert and never fails post, so the merge path is untouched.
h=$(new_home down); : > "$STUB_DOWN"
out=$(alert "$h" post t1 --pr "$PR"); rc=$?
assert_equals 0 "$rc" "a down board never fails post"
assert_contains "$out" "queued" "post says the alert is queued"
q=$h/state/merge-alerts/pending/mergealert-acme-app-pull-7.json
assert_equals 1 "$(jq -r .attempts "$q")" "the failed attempt is counted on the queued alert"
assert_contains "$(jq -r .last_error "$q")" "board is down" "the queued alert keeps the board's reason"
assert_equals "" "$(card mergealert-acme-app-pull-7)" "nothing reached the board"
pass "a down board queues the alert"

# Who merged: a Squad Lead home names the lead and the model its parent recorded; an outside merge says so.
h=$(new_home lead); parent=$T/parent; mkdir -p "$parent/state"
printf 'model=claude-opus-5-5\n' > "$parent/state/lead-a.meta"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$h/.jg-squad-lead-parent"
printf 'lead-a' > "$h/.jg-squad-lead-home"
alert "$h" post t1 --pr "$PR" >/dev/null
assert_contains "$(card mergealert-acme-app-pull-7 | jq -r .about)" "Merged by Squad Lead lead-a (claude-opus-5-5)" "a lead home names the lead and its model"
h=$(new_home external)
alert "$h" post t1 --pr "$PR" --authority external >/dev/null
assert_contains "$(card mergealert-acme-app-pull-7 | jq -r .about)" "Merged outside Juggernaut." "an outside merge says so"
h=$(new_home override)
JG_MERGER_MODEL=claude-haiku-5-5 alert "$h" post t1 --pr "$PR" >/dev/null
assert_contains "$(card mergealert-acme-app-pull-7 | jq -r .about)" "Merged by Main (claude-haiku-5-5)" "JG_MERGER_MODEL names the merger's model"
pass "who merged"

h=$(new_home noboard none)
assert_equals "" "$(alert "$h" post t1 --pr "$PR")" "no board: post is silent and exits 0"
[ ! -e "$h/state/merge-alerts" ] || fail "no board: nothing is queued"
pass "no board"

h=$(new_home bad); alert "$h" post t1 >/dev/null; assert_equals 2 "$?" "a bad request is a usage error"

# A queued alert is posted by drain once the board is back, and a lead home with no board of its own files on its parent's.
h=$(new_home drain); : > "$STUB_DOWN"
alert "$h" post t1 --pr "$PR" >/dev/null
alert "$h" drain >/dev/null
assert_equals "" "$(card mergealert-acme-app-pull-7)" "drain posts nothing while the board is down"
rm -f "$STUB_DOWN"
alert "$h" drain >/dev/null
assert_contains "$(card mergealert-acme-app-pull-7 | jq -r .title)" "Merged:" "drain posts the queued alert once the board is back"
[ -e "$h/state/merge-alerts/sent/mergealert-acme-app-pull-7.json" ] && [ -z "$(ls "$h/state/merge-alerts/pending")" ] || fail "a drained alert moves to sent"
pass "drain"
h=$(new_home inherit none); parent=$T/parent-board; mkdir -p "$parent/config" "$parent/state"
printf '#!/bin/sh\nexec x post --board %s "$@"\n' "$BOARD" > "$parent/config/post-merge"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$h/.jg-squad-lead-parent"
printf 'lead-b' > "$h/.jg-squad-lead-home"
alert "$h" post t1 --pr "$PR" >/dev/null
assert_contains "$(card mergealert-acme-app-pull-7 | jq -r .about)" "Squad Lead lead-b" "a lead without a board posts to its parent's board"
pass "lead board inheritance"
