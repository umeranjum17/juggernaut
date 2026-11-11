#!/usr/bin/env bash
# The daily clean-up ACTS: a ticket that is closed-unmerged work, a duplicate or superseded is closed with the
# reason recorded in its note, and a ticket that still holds an owner decision (the captain's ask, a captain hold,
# a design pick) or has a worker in flight is never closed, whatever it matches. This fails if the clean-up goes
# back to only flagging.
# Real jg-backlog.sh on a Beads store, real sign-off-axi board, real installed sync. The one stand-in is gh-axi, because a PR's
# state lives on GitHub: PR 11 and 12 answer closed unmerged, 20 merged, 30 open.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
fork=${JG_TEST_FORK:-$(cd "$root/../.." && pwd -P)}
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/cleanup-acts.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state} "$work/shim"
ln -s "$fork/bin" "$JG_HOME/bin"
cat > "$work/shim/gh-axi" <<'SHIM'
#!/usr/bin/env bash
case "${2##*/}" in
  11|12) printf 'merged: false\nstate: closed\ndraft: false\n' ;;
  20) printf 'merged: true\nstate: closed\ndraft: false\n' ;;
  *) printf 'merged: false\nstate: open\ndraft: false\n' ;;
esac
SHIM
chmod +x "$work/shim/gh-axi"
export PATH=$work/shim:$PATH
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# shellcheck source=core/lib/beads-test-env.sh
. "$root/../lib/beads-test-env.sh"
core_beads_home "$fork" "$JG_HOME"
pr() { echo "https://github.com/example/alpha/pull/$1"; }
(cd "$JG_HOME"
 jg-backlog.sh add jg-dead 'Umer closed work' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh add jg-dupa 'Umer same words' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-dupb 'Umer same words' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-sup 'Umer old plan' --repo alpha --priority 2 --body 'status: superseded' >/dev/null
 # Owner decisions: each one matches a closing rule and none may close.
 jg-backlog.sh add jg-ask-dead '[captain-ask] P0 Umer wants this' --repo alpha --priority 0 --body "pr: $(pr 12)" >/dev/null
 jg-backlog.sh add jg-hold-dead 'Umer held closed work' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh hold jg-hold-dead --reason 'Captain decides whether to delete it' --kind captain >/dev/null
 jg-backlog.sh add jg-design-dead '[design-ux] Umer pick a look' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh add jg-ask-dup '[captain-ask] P0 Umer same ask' --repo alpha --priority 0 >/dev/null
 jg-backlog.sh add jg-ask-dup2 '[captain-ask] P0 Umer same ask' --repo alpha --priority 0 >/dev/null
 jg-backlog.sh add jg-gone-a 'Umer old plan twice' --repo alpha --priority 2 --body 'status: superseded' >/dev/null
 jg-backlog.sh add jg-gone-b 'Umer old plan twice' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-hold-sup 'Umer held old plan' --repo alpha --priority 2 --body 'status: superseded' >/dev/null
 jg-backlog.sh hold jg-hold-sup --reason 'Captain decides' --kind captain >/dev/null
 # Not closed-unmerged: a merged PR, an open PR, a mix, and work a worker has in flight.
 jg-backlog.sh add jg-merged 'Umer shipped' --repo alpha --priority 2 --body "pr: $(pr 20)" >/dev/null
 jg-backlog.sh add jg-open 'Umer review open' --repo alpha --priority 2 --body "pr: $(pr 30)" >/dev/null
 jg-backlog.sh add jg-mixed 'Umer retried work' --repo alpha --priority 2 --body "pr: $(pr 11)"$'\n'"pr: $(pr 30)" >/dev/null
 jg-backlog.sh add jg-flight 'Umer worker running' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh start jg-flight >/dev/null)
bash "$root/wiring.sh" >/dev/null
status=0
out=$("$JG_HOME/state/tickets-cleanup.check.sh") || status=$?
[ "$status" = 0 ] || { echo "FAIL: the clean-up check exited $status: $out"; exit 1; }
state_of() { (cd "$JG_HOME"; jg-backlog.sh show "$1" --full) | sed -n 's/^  state: //p'; }
for id in jg-dead jg-dupb jg-sup; do
  [ "$(state_of $id)" = 'done' ] || { echo "FAIL: the clean-up only flagged $id, it did not close it (state $(state_of $id)): $out"; exit 1; }
  (cd "$JG_HOME"; jg-backlog.sh show "$id" --full) | grep -q 'closed by the daily clean-up' \
    || { echo "FAIL: $id was closed with no reason recorded"; exit 1; }
done
(cd "$JG_HOME"; jg-backlog.sh show jg-dead --full) | grep -q "closed-unmerged: closed without a merge: $(pr 11)" || { echo 'FAIL: dead carries the wrong reason'; exit 1; }
(cd "$JG_HOME"; jg-backlog.sh show jg-dupb --full) | grep -q 'duplicate: same title as main/jg-dupa' || { echo 'FAIL: dupb carries the wrong reason'; exit 1; }
(cd "$JG_HOME"; jg-backlog.sh show jg-sup --full) | grep -q 'superseded' || { echo 'FAIL: sup carries the wrong reason'; exit 1; }
[ "$(state_of jg-gone-a)" = 'done' ] && [ "$(state_of jg-gone-b)" != 'done' ] \
  || { echo 'FAIL: a duplicate of a ticket closed in the same pass was closed, leaving no live ticket'; exit 1; }
[ "$(state_of jg-dupa)" != 'done' ] || { echo 'FAIL: the duplicate that stays was closed too'; exit 1; }
for id in jg-ask-dead jg-hold-dead jg-design-dead jg-ask-dup jg-ask-dup2 jg-hold-sup jg-merged jg-open jg-mixed jg-flight; do
  [ "$(state_of $id)" != 'done' ] || { echo "FAIL: the clean-up closed $id, which must stay"; exit 1; }
done
grep -q '^tickets-cleanup: closed 1 closed-unmerged, 1 duplicate, 2 superseded; ' <<<"$out" \
  || { echo "FAIL: the check line does not say what it closed: $(head -n1 <<<"$out")"; exit 1; }
report=$JG_HOME/state/tickets-sync/cleanup-$(date -u +%F).txt
grep -q '^closed duplicate: main/jg-dupb - ' "$report" || { echo 'FAIL: the report file does not list the closed duplicate'; exit 1; }
grep -q '^closed-unmerged: main/jg-ask-dead - .*kept: it holds an owner decision$' "$report" \
  || { echo 'FAIL: the report file does not say the captain ask was kept'; exit 1; }
sign-off-axi list "$work/board.json" --json > "$work/cards.json"
key="ticket-cleanup-$(date -u +%F)"
jq -e --arg key "$key" '.decisions[] | select(.key == $key) | .kind == "report" and ((.options // []) | length) == 0 and (.sections[].items | map(.title) | any(startswith("closed duplicate: main/jg-dupb")))' "$work/cards.json" >/dev/null \
  || { echo 'FAIL: the report card does not name what the clean-up closed'; exit 1; }
# The next day has nothing left to close, and closing is not repeated.
rm -f "$JG_HOME/state/tickets-sync/cleanup.day"
out=$("$JG_HOME/state/tickets-cleanup.check.sh")
grep -q '^tickets-cleanup: flagged ' <<<"$out" || { echo "FAIL: a second pass closed again: $(head -n1 <<<"$out")"; exit 1; }
echo 'PASS: the daily clean-up closes closed-unmerged, duplicate and superseded tickets with the reason recorded, and never closes an owner decision or work in flight'
