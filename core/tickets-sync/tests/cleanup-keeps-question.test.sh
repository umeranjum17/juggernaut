#!/usr/bin/env bash
# A question card whose linked changes are all closed unmerged is never dismissed by the card reconcile: such a
# card asks whether to delete that closed work, so the work being closed is the reason it exists. It stays on
# every route the reconcile has (the card's own link, its done ticket, its done backlog task) until the captain
# answers. The control cards, whose changes merged, are still archived, so a reconcile that kept everything
# would fail here too.
# Real jg-backlog.sh on a Beads store, real sign-off-axi board, real installed sync. The one stand-in is gh-axi, because a PR's
# state lives on GitHub: PR 11 answers closed unmerged, 20 merged.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
fork=${JG_TEST_FORK:-$(cd "$root/../.." && pwd -P)}
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/cleanup-keeps-question.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state} "$work/shim"
ln -s "$fork/bin" "$JG_HOME/bin"
cat > "$work/shim/gh-axi" <<'SHIM'
#!/usr/bin/env bash
case "${2##*/}" in
  11) printf 'merged: false\nstate: closed\ndraft: false\n' ;;
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
ticket_id() { printf 'jg-%s\n' "$(printf %s "$1" | sha256sum | cut -c1-32)"; }
(cd "$JG_HOME"
 jg-backlog.sh add jg-closed-ticket 'Umer closed work with a ticket' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh add jg-merged-ticket 'Umer shipped work with a ticket' --repo alpha --priority 2 --body "pr: $(pr 20)" >/dev/null
 jg-backlog.sh add jg-closed-task 'Umer closed work with a task card' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh add jg-merged-task 'Umer shipped work with a task card' --repo alpha --priority 2 --body "pr: $(pr 20)" >/dev/null
 for id in jg-closed-ticket jg-merged-ticket jg-closed-task jg-merged-task; do jg-backlog.sh done "$id" >/dev/null; done)
bash "$root/wiring.sh" >/dev/null
"$JG_HOME/state/tickets-sync.check.sh" >/dev/null
raise() {  # <key> <ask-ref> <title> <why> [extra raise flags]
  sign-off-axi raise "$work/board.json" --key "$1" --ask-ref "$2" --title "$3" --why "$4" \
    --outcome yes='Main deletes it.' --outcome no='It stays.' --recommend no --recommend-reason 'Nothing is lost.' --default no "${@:5}" >/dev/null
}
# 1. The card's own text links the PR.
raise q-link-closed q-link-closed 'Delete the abandoned export rewrite?' "Nobody merged it: $(pr 11)"
raise q-link-merged q-link-merged 'Keep the shipped voice picker?' "It landed: $(pr 20)"
# 2. The card answers a done board ticket.
raise q-ticket-closed q-ticket-closed 'Discard the dropped sync prototype?' 'Its branch is gone.' --ticket "$(ticket_id main/jg-closed-ticket)"
raise q-ticket-merged q-ticket-merged 'Retire the old login screen?' 'The new one is live.' --ticket "$(ticket_id main/jg-merged-ticket)"
# 3. The card answers a done backlog task (ask_ref names it).
raise q-task-closed jg-closed-task 'Remove the half-built chart tab?' 'Work stopped there.'
raise q-task-merged jg-merged-task 'Archive the finished theme work?' 'It is released.'
rm -f "$JG_HOME/state/tickets-sync/cleanup.day"
status=0
out=$("$JG_HOME/state/tickets-cleanup.check.sh") || status=$?
[ "$status" = 0 ] || { echo "FAIL: the clean-up check exited $status: $out"; exit 1; }
sign-off-axi list "$work/board.json" --json > "$work/cards.json"
answered() { jq -r --arg key "$1" '.decisions[] | select(.key == $key) | if .dismissed then "dismissed" else "waiting" end' "$work/cards.json"; }
for key in q-link-closed q-ticket-closed q-task-closed; do
  [ "$(answered $key)" = waiting ] || { echo "FAIL: $key asks about closed-unmerged work and was dismissed: $(grep "$key" "$JG_HOME/state/tickets-sync/card-reconcile.log")"; exit 1; }
done
for key in q-link-merged q-ticket-merged q-task-merged; do
  [ "$(answered $key)" = dismissed ] || { echo "FAIL: control card $key, whose change merged, was not archived: $out"; exit 1; }
done
grep -q '^cards: 3 archived, ' <<<"$out" || { echo "FAIL: the check line miscounts the archived cards: $out"; exit 1; }
if grep -q 'q-.*-closed\|q-link-closed' "$JG_HOME/state/tickets-sync/card-reconcile.log"; then echo 'FAIL: the reconcile log records a dismissal of a closed-unmerged question'; exit 1; fi
echo 'PASS: a question about closed-unmerged work is never dismissed by the card reconcile, while a card whose change merged still is'
