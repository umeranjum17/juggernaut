#!/usr/bin/env bash
# End-to-end: drive backlog-shipped-reconcile.sh against a fixture home with a real markdown backlog and the real
# tasks-axi, the real bin/ libraries and the real bin/jg-crew-state.sh. Covers an In flight row whose PR the merge
# poll recorded as merged closing when its worker is gone (and a record that names no live window), a row whose PR
# a release record lists closing, and the rows it must leave alone: a live worker, a PR with no shipped evidence,
# a different PR than the merged one, a held row, a queued row, a squad_lead record, a pending close, and a record with no pr=.
# Also covers a rerun staying silent and the check running from merge-on-green.sh check.
# Only liveness is stubbed: an id listed in $d/live answers "working", so no model or pane is needed for a live worker.
# Usage: merge-on-green/tests/backlog-shipped-reconcile.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO=$(cd "$SRC/../.." && pwd -P)
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (the reconcile moves rows through it)"; exit 0; }
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

cat > "$FM/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] merged-gone - [feature] merged PR, worker gone (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] live-merged - [feature] merged PR, worker still live (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] released-gone - [feature] released PR, worker gone (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] no-evidence - [feature] PR open, worker gone (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] other-pr - [feature] marker names another PR (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] held-merged - [feature] merged PR, but the captain holds the row (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] pending-close - [feature] teardown already owes this close (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] no-pr - [feature] no pr= in its record (repo: r) (priority: 1) (since 2026-11-04)
  body
- [ ] lead-x - [feature] a squad lead record (repo: r) (priority: 1) (since 2026-11-04)
  body

## Queued
- [ ] queued-merged - [feature] queued with a merged PR record (repo: r) (priority: 1)
  body

## Done
EOF
mkmeta() { # <id> <kind> <pr number or empty>
  printf 'window=jg:%s\nkind=%s\nbackend=tmux\nworktree=%s\n' "$1" "$2" "$d/wt" > "$FM/state/$1.meta"
  [ -z "${3:-}" ] || printf 'pr=https://github.com/ex/r/pull/%s\n' "$3" >> "$FM/state/$1.meta"
}
marker() { printf 'jg-pr-poll-merge-notified-v1\ngithub\ngithub.com\nex/r\n%s\n' "$2" > "$FM/state/$1.pr-poll-merge-notified"; }
mkmeta merged-gone ship 71;     marker merged-gone 71
mkmeta live-merged ship 72;     marker live-merged 72; echo live-merged > "$d/live"
mkmeta released-gone ship 73
mkmeta no-evidence ship 74
mkmeta other-pr ship 75;        marker other-pr 99
mkmeta held-merged ship 80;     marker held-merged 80
mkmeta pending-close ship 76;   marker pending-close 76; : > "$FM/state/pending-close.backlog-close"
mkmeta no-pr ship;              marker no-pr 77
mkmeta lead-x squad_lead 78;    marker lead-x 78
mkmeta queued-merged ship 79;   marker queued-merged 79
(cd "$FM/data" && tasks-axi hold held-merged --reason "captain decision pending" --kind captain >/dev/null)
printf '# ref  date  note\nv1.0 2026-11-01 prs=70,73\n' > "$FM/data/releases"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
reconcile() { JG_CHECK_TIMEOUT=60 "$SRC/backlog-shipped-reconcile.sh" check "$FM" 2>&1; }
section() { awk -v s="$1" '/^## /{on = ($0 == "## " s)} on && /^- \[/ {sub(/^- \[.\] /, ""); sub(/ - .*/, ""); print}' "$FM/data/backlog.md" | sort | tr '\n' ' '; }

out=$(reconcile)
P=https://github.com/ex/r/pull
check "merged PR with a gone worker is reported" "$(printf '%s\n' "$out" | grep -c 'merged-gone moved out of in flight: its PR '$P'/71 is merged')" 1
check "released PR with a gone worker is reported" "$(printf '%s\n' "$out" | grep -c 'released-gone moved out of in flight: its PR '$P'/73 is released')" 1
check "exactly two rows are reported" "$(printf '%s\n' "$out" | grep -c '^backlog-shipped-reconcile: ')" 2
check "Done holds the two shipped rows" "$(section Done)" "merged-gone released-gone "
check "In flight keeps every row that must stay" "$(section 'In flight')" "held-merged lead-x live-merged no-evidence no-pr other-pr pending-close "
check "Queued is untouched" "$(section Queued)" "queued-merged "
check "the closed row records its PR" "$(grep -c "merged-gone.*$P/71" "$FM/data/backlog.md")" 1
check "the worker record stays for teardown" "$([ -f "$FM/state/merged-gone.meta" ] && [ -f "$FM/state/released-gone.meta" ] && echo both)" both
check "a rerun is silent" "$(reconcile)" ""

check "the held row is still In flight" "$(section 'In flight' | grep -c held-merged)" 1

# A worker that stops running is picked up on the next sweep, and not before.
check "a live worker keeps its row" "$(section 'In flight' | grep -c live-merged)" 1
: > "$d/live"
out=$(reconcile)
check "the row closes once the worker is gone" "$(printf '%s\n' "$out" | grep -c 'live-merged moved out of in flight')" 1

# merge-on-green.sh check carries the reconcile: a fresh merged row closes through the one watcher check.
printf -- '- [ ] via-watcher - [feature] closes through the watcher check (repo: r) (priority: 1) (since 2026-11-04)\n  body\n' > "$d/row.md"
sed -i "/^## In flight/r $d/row.md" "$FM/data/backlog.md"
mkmeta via-watcher ship 81; marker via-watcher 81
out=$(JG_CHECK_TIMEOUT=60 "$SRC/merge-on-green.sh" check "$FM" 2>&1)
check "merge-on-green check carries the reconcile" "$(printf '%s\n' "$out" | grep -c '^backlog-shipped-reconcile: via-watcher moved out of in flight')" 1

if [ "$fails" -eq 0 ]; then echo "PASS backlog-shipped-reconcile"; else echo "$fails failed"; exit 1; fi
