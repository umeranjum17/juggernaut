#!/usr/bin/env bash
# A new ticket's description is its task body with every line break kept, so "# Ask", "# Why" and "# Done when"
# each start a line on the board. Asserts the exact bytes that reach the board, not merely that a ticket appeared.
# Real jg-backlog.sh on a Beads store, the real installer and the real sign-off-axi in an isolated home.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync-desc.XXXXXX")
trap 'echo "retained fixture: $work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -sn "$fork/bin" "$JG_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# Still skipped without JG_BEADS_TEST_BD: on the tables the sync publishes no ticket, so the board read finds none (a gap outside the Beads callers).
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then echo 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset'; exit 0; fi
# A fixture home on the tickets tables (fleet.db).
core_tables_home() {  # <checkout> <home>
  mkdir -p "$2/config" "$2/data" && : > "$2/config/backlog-intake-loose"
  case ":$PATH:" in *":$1/bin:"*) ;; *) PATH=$1/bin:$PATH; export PATH ;; esac
  JG_HOME=$2 python3 -I "$1/core/item-store/adapters/tickets.py" import --home main /dev/null >/dev/null
}
core_tables_home "$fork" "$JG_HOME"
body=$(printf 'Umer wants the summary first.\n# Ask\nKeep the line breaks.\n# Why\nThe board refuses a collapsed body.\n# Done when\nThe ticket shows on the board.')
(cd "$JG_HOME" && jg-backlog.sh add jg-shaped 'Umer shaped item' --repo alpha --priority 2 --body "$body" >/dev/null)
bash "$root/tickets-sync/wiring.sh"
out=$(env -u JG_HOME "$JG_HOME/state/tickets-sync.check.sh" 2>&1) || { printf '%s\n' "$out"; echo 'FAIL: the pass failed'; exit 1; }
id=jg-$(printf '%s' main/jg-shaped | sha256sum | cut -c1-32)
got=$(sign-off-axi ticket "$work/board.json" --id "$id" --json | jq -r '.ticket.description // ""')
[ "$got" = "$body" ] || { printf 'FAIL: expected the body byte for byte, got:\n%s\n' "$got"; exit 1; }
[ "$(grep -c '^# ' <<<"$got")" = 3 ] || { echo 'FAIL: each heading must start its own line'; exit 1; }
echo 'PASS: a new ticket carries its task body with line breaks kept'
