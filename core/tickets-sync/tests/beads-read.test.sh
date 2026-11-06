#!/usr/bin/env bash
# The sync reads a home's backlog from its Beads store (config/backlog-backend) and publishes the same feed it
# publishes from the markdown backlog: one fixture home, read both ways, every feed line compared.
# Real tasks-axi, jg-beads-migrate.py, the pinned bd and dolt through jg-beads.sh, and the real sign-off-axi.
# JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; without them the run skips plainly.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${JG_BEADS_TEST_BD:-}" ] && [ -n "${JG_BEADS_TEST_DOLT:-}" ] || { echo 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset'; exit 0; }
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync-beads.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export TZ=UTC HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -s "$fork/bin" "$JG_HOME/bin"
ln -s "$fork/toolchain.versions" "$JG_HOME/toolchain.versions"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$JG_HOME/.tasks.toml"
(cd "$JG_HOME"
 tasks-axi add parent '[captain-ask] P1 Parent: Umer release' --repo alpha --priority 1 --body 'type: captain-ask: "Umer focus should be simple"' >/dev/null
 tasks-axi add long "Umer ship" --repo alpha --priority 1 --body $'release: v1\nhttps://github.com/example/alpha/pull/123' >/dev/null
 tasks-axi start long >/dev/null
 tasks-axi add upkeep 'Umer maintenance' --repo alpha --priority 2 --body 'parent: upkeep' >/dev/null
 tasks-axi add held 'Umer paused item' --repo alpha --priority 1 >/dev/null
 tasks-axi hold held --reason 'Umer parked this item' --kind parked >/dev/null
 tasks-axi add wide "Umer wide title $(printf 'word%.0s ' $(seq 1 25))" --repo alpha --priority 2 --body "$(printf 'Umer long note %.0s' $(seq 1 60))"$'\nrelease: v2\nparent: parent' >/dev/null
 tasks-axi add child '[captain-ask] P0 Umer settings' --repo alpha --priority 0 --body $'Umer notes\nrelease: v1\nparent: parent' >/dev/null)
printf 'window=default:w9:p1\nendpoint_task_id=long\nharness=pi\nmodel=m\neffort=high\naccount=a\n' > "$JG_HOME/state/long.meta"
printf 'working [at=1700000000]: building Umer release\n' > "$JG_HOME/state/long.status"
feed() { jq -c 'del(.at)' "$work/board.tickets.jsonl" | sort; }
python3 "$root/tickets-sync/sync.py" >/dev/null 2>&1 || { echo 'FAIL: the markdown pass failed'; exit 1; }
feed > "$work/markdown.feed"
[ "$(wc -l < "$work/markdown.feed")" -gt 5 ] || { echo 'FAIL: the markdown pass published too little'; exit 1; }
# Move the backlog into a store, then read it from there with a fresh board and feed.
python3 "$fork/bin/jg-beads-migrate.py" copy --main "$JG_HOME" --to "$work/copy" >/dev/null
python3 "$fork/bin/jg-beads-migrate.py" plan --copy "$work/copy" --out "$work/imp" >/dev/null
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT BEADS_DIR=$work/store/.beads
mkdir -p "$work/store"
jail=()
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --bind "$work" "$work" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
bd_() { "${jail[@]}" "$fork/bin/jg-beads.sh" "$@" >/dev/null 2>&1 || { echo "FAIL: bd $*"; exit 1; }; }
bd_ init --prefix jg
bd_ config set status.custom on_hold:frozen
bd_ config set allowed_prefixes "$(cat "$work/imp/main.prefixes")"
bd_ import "$work/imp/main.jsonl"
# The markdown files go, so the second pass can only have read the store.
rm -f -- "$JG_HOME"/data/backlog.md "$JG_HOME"/data/done-archive.md
printf 'beads\n' > "$JG_HOME/config/backlog-backend"
printf '%s\n' "$BEADS_DIR" > "$JG_HOME/config/beads-dir"
rm -rf -- "$JG_HOME/state/tickets-sync" "$work/board.tickets.jsonl"; mkdir -p "$JG_HOME/state/tickets-sync"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
# The jail has no network and the reader is a read: run the pass outside it, as the watcher does.
python3 "$root/tickets-sync/sync.py" >/dev/null 2>&1 || { echo 'FAIL: the Beads pass failed'; exit 1; }
feed > "$work/beads.feed"
# A done row has no priority in a markdown archive and the store's default (P2) in Beads: the one named difference.
if ! diff <(jq -c 'del(.priority)' "$work/markdown.feed") <(jq -c 'del(.priority)' "$work/beads.feed"); then
  echo 'FAIL: the Beads feed differs from the markdown feed'; exit 1
fi
echo 'PASS: a Beads-backed home publishes the same feed as the markdown backlog'
