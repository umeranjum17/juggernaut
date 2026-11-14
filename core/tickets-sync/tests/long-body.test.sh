#!/usr/bin/env bash
# A task body past the board's 4000-character description limit is trimmed to fit, ending with a link to the full ticket,
# so the ticket still shows; a short body stays whole. Asserts the bytes that reach the board.
# Real jg-backlog.sh on a Beads store, the real installer and the real sign-off-axi in an isolated home.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync-longbody.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -sn "$fork/bin" "$JG_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$root/lib/beads-test-env.sh"
core_beads_home "$fork" "$JG_HOME"
long=$(printf 'Umer long line %.0s' {1..400})
short='Umer short body stays whole.'
(cd "$JG_HOME"
 jg-backlog.sh add jg-long 'Umer long item' --repo alpha --priority 2 --body "$long" >/dev/null
 jg-backlog.sh add jg-short 'Umer short item' --repo alpha --priority 2 --body "$short" >/dev/null)
[ "${#long}" -ge 5000 ] || { echo 'FAIL: fixture body must pass 5000 characters'; exit 1; }
bash "$root/tickets-sync/wiring.sh"
out=$(env -u JG_HOME "$JG_HOME/state/tickets-sync.check.sh" 2>&1) || { printf '%s\n' "$out"; echo 'FAIL: the pass failed'; exit 1; }
! grep -q 'skipped' <<<"$out" || { printf '%s\n' "$out"; echo 'FAIL: a ticket was skipped'; exit 1; }
desc() { sign-off-axi ticket "$work/board.json" --id "jg-$(printf '%s' "main/$1" | sha256sum | cut -c1-32)" --json | jq -r '.ticket.description // ""'; }
got=$(desc jg-long)
[ "${#got}" -le 4000 ] && [ "${#got}" -gt 3500 ] || { echo "FAIL: expected a trimmed body of at most 4000 characters, got ${#got}"; exit 1; }
[ "${got:0:30}" = "${long:0:30}" ] || { echo 'FAIL: the trimmed body must keep the start of the ticket'; exit 1; }
[[ "$got" == *'Full ticket: main/jg-long' ]] || { printf 'FAIL: expected the link to the full ticket at the end, got tail: %s\n' "${got: -80}"; exit 1; }
[ "$(desc jg-short)" = "$short" ] || { echo 'FAIL: a short body must stay whole'; exit 1; }
echo 'PASS: a long body is trimmed with a link to the full ticket and a short body stays whole'
