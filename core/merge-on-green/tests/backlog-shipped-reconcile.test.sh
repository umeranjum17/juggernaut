#!/usr/bin/env bash
# End-to-end: drive backlog-shipped-reconcile.sh against a fixture home with a real Beads backlog and the real
# Beads store, the real bin/ libraries and the real bin/jg-crew-state.sh. Covers an In flight row whose PR the merge
# poll recorded as merged closing when its worker is gone (and a record that names no live window), a row whose PR
# a release record lists closing, and the rows it must leave alone: a live worker, a PR with no shipped evidence,
# a different PR than the merged one, a held row, a queued row, a squad_lead record, a pending close, and a record with no pr=.
# Also covers a rerun staying silent and the check running from merge-on-green.sh check.
# Only liveness is stubbed: an id listed in $d/live answers "working", so no model or pane is needed for a live worker.
# Usage: merge-on-green/tests/backlog-shipped-reconcile.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO=$(cd "$SRC/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/data" "$FM/config" "$FM/bin" "$d/wt"
for f in "$REPO"/bin/*; do ln -s "$f" "$FM/bin/${f##*/}"; done
rm "$FM/bin/jg-crew-state.sh"
cat > "$FM/bin/jg-crew-state.sh" <<STUB
#!/usr/bin/env bash
if grep -qx -- "\$1" "$d/live" 2>/dev/null; then echo 'state: working · source: pane · harness busy (stub)'; else exec "$REPO/bin/jg-crew-state.sh" "\$@"; fi
STUB
chmod +x "$FM/bin/jg-crew-state.sh"

# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$REPO/core/lib/beads-test-env.sh"
core_beads_home "$REPO" "$FM"
export JG_HOME=$FM
ta() { jg-backlog.sh "$@" >/dev/null; }
row() { ta add "jg-$1" "[feature] $2" --repo r --priority 1 --body body; }
for id in merged-gone live-merged released-gone no-evidence other-pr held-merged pending-close no-pr lead-x; do
  row "$id" "in flight $id"; ta start "jg-$id"
done
row queued-merged "queued with a merged PR record"
mkmeta() { # <id> <kind> <pr number or empty>
  printf 'window=jg:%s\nkind=%s\nbackend=tmux\nworktree=%s\n' "$1" "$2" "$d/wt" > "$FM/state/$1.meta"
  [ -z "${3:-}" ] || printf 'pr=https://github.com/ex/r/pull/%s\n' "$3" >> "$FM/state/$1.meta"
}
marker() { printf 'jg-pr-poll-merge-notified-v1\ngithub\ngithub.com\nex/r\n%s\n' "$2" > "$FM/state/$1.pr-poll-merge-notified"; }
mkmeta jg-merged-gone ship 71;     marker jg-merged-gone 71
mkmeta jg-live-merged ship 72;     marker jg-live-merged 72; echo jg-live-merged > "$d/live"
mkmeta jg-released-gone ship 73
mkmeta jg-no-evidence ship 74
mkmeta jg-other-pr ship 75;        marker jg-other-pr 99
mkmeta jg-held-merged ship 80;     marker jg-held-merged 80
mkmeta jg-pending-close ship 76;   marker jg-pending-close 76; : > "$FM/state/jg-pending-close.backlog-close"
mkmeta jg-no-pr ship;              marker jg-no-pr 77
mkmeta jg-lead-x squad_lead 78;    marker jg-lead-x 78
mkmeta jg-queued-merged ship 79;   marker jg-queued-merged 79
BEADS_DIR=$(cat "$FM/config/beads-dir") "$REPO/bin/jg-beads.sh" update jg-held-merged --status on_hold --set-metadata hold_reason="captain decision pending" --set-metadata hold_kind=captain >/dev/null
printf '# ref  date  note\nv1.0 2026-11-01 prs=70,73\n' > "$FM/data/releases"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
reconcile() { JG_CHECK_TIMEOUT=60 "$SRC/backlog-shipped-reconcile.sh" check "$FM" 2>&1; }
section() { # <state>: the ids in that state, without the jg- prefix, sorted
  jg-backlog.sh list --state "$1" --fields id | sed -nE 's/^ +(jg-[A-Za-z0-9._-]+).*/\1/p' | sed 's/^jg-//' | sort | tr '\n' ' '; }

out=$(reconcile)
P=https://github.com/ex/r/pull
check "merged PR with a gone worker is reported" "$(printf '%s\n' "$out" | grep -c 'jg-merged-gone moved out of in flight: its PR '$P'/71 is merged')" 1
check "released PR with a gone worker is reported" "$(printf '%s\n' "$out" | grep -c 'jg-released-gone moved out of in flight: its PR '$P'/73 is released')" 1
check "exactly two rows are reported" "$(printf '%s\n' "$out" | grep -c '^backlog-shipped-reconcile: ')" 2
check "Done holds the two shipped rows" "$(section 'done')" "merged-gone released-gone "
check "In flight keeps every row that must stay" "$(section in_flight)" "held-merged lead-x live-merged no-evidence no-pr other-pr pending-close "
check "Queued is untouched" "$(section queued)" "queued-merged "
check "the closed row records its PR" "$(jg-backlog.sh show jg-merged-gone --full | grep -q "$P/71" && echo 1)" 1
check "the worker record stays for teardown" "$([ -f "$FM/state/jg-merged-gone.meta" ] && [ -f "$FM/state/jg-released-gone.meta" ] && echo both)" both
check "a rerun is silent" "$(reconcile)" ""

check "the held row is still In flight" "$(section in_flight | grep -c held-merged)" 1

# A worker that stops running is picked up on the next sweep, and not before.
check "a live worker keeps its row" "$(section in_flight | grep -c live-merged)" 1
: > "$d/live"
out=$(reconcile)
check "the row closes once the worker is gone" "$(printf '%s\n' "$out" | grep -c 'jg-live-merged moved out of in flight')" 1

# merge-on-green.sh check carries the reconcile: a fresh merged row closes through the one watcher check.
row via-watcher "closes through the watcher check"; ta start jg-via-watcher
mkmeta jg-via-watcher ship 81; marker jg-via-watcher 81
out=$(JG_CHECK_TIMEOUT=60 "$SRC/merge-on-green.sh" check "$FM" 2>&1)
check "merge-on-green check carries the reconcile" "$(printf '%s\n' "$out" | grep -c '^backlog-shipped-reconcile: jg-via-watcher moved out of in flight')" 1

if [ "$fails" -eq 0 ]; then echo "PASS backlog-shipped-reconcile"; else echo "$fails failed"; exit 1; fi
