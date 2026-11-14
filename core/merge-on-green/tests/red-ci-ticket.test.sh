#!/usr/bin/env bash
# End-to-end: drive red-ci-ticket.sh against a fixture home whose clone has a github origin, with a gh-axi stub that
# answers from recorded run lists and a jg-backlog.sh stub that records every add. Covers a red run filing one ticket
# with the run id, URL, failing job and first failing log line, a second poll filing none, a green run and a superseded
# old red run filing none, a red run on an open PR head filing its own ticket, a failed add retried next poll, a forge
# failure staying silent, and the check running from merge-on-green.sh check.
# Usage: merge-on-green/tests/red-ci-ticket.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/data" "$FM/bin" "$FM/projects/r"
printf -- '- r [direct-PR +yolo] - fixture project (ex/r) (added 2026-11-04)\n' > "$FM/data/projects.md"
git -C "$FM/projects/r" init -q
git -C "$FM/projects/r" remote add origin https://github.com/ex/r.git
export STUB_FAIL=$d/fail STUB_ADDS=$d/adds STUB_ADD_FAIL=$d/addfail
cat > "$FM/bin/jg-backlog.sh" <<'STUB'
#!/usr/bin/env bash
# add <id> <title> --kind ship --body <body>: record it; show: never found
[ "$1" = add ] || exit 1
[ ! -e "$STUB_ADD_FAIL" ] || exit 1
printf '%s\n' "$2|$3|$7" >> "$STUB_ADDS"
STUB
chmod +x "$FM/bin/jg-backlog.sh"
# The real alert function, run from the repository so it reads the real alert table.
printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$SRC/../../bin/jg-alert.sh" > "$FM/bin/jg-alert.sh"
chmod +x "$FM/bin/jg-alert.sh"
cp "$SRC/tests/fixtures/red-ci-ticket/gh-axi" "$d/gh-axi"
export JG_RED_CI_GH=$d/gh-axi
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
poll() { JG_CHECK_TIMEOUT=30 "$SRC/red-ci-ticket.sh" check "$FM" 2>&1; }
U=https://github.com/ex/r/actions/runs

out=$(poll)
check "first poll alerts for exactly two red runs" "$(printf '%s\n' "$out" | wc -l)" 2
check "alert names the run, job and routing" "$(printf '%s\n' "$out" | grep "runs/11:")" "alert line-red (P1) at rung 2 for lead: ci-red-run-11 - red-ci-ticket: $U/11: CI behaviour shard 2 went red; filed ci-red-run-11 (r); fix the root cause, never re-run"
check "the alert is recorded open for the project" "$(grep -c '^state=open$\|^project=r$' "$FM/state/alerts/line-red--ci-red-run-11.rec")" 2
check "exactly two tickets filed" "$(grep -c "^ci-red-run-" "$STUB_ADDS" || true)" 2
check "ticket 11 id and title" "$(grep '^ci-red-run-11|' "$STUB_ADDS" | cut -d'|' -f1-2)" "ci-red-run-11|[blocker] CI red: CI behaviour shard 2: find the root cause"
body=$(grep -A8 '^ci-red-run-11|' "$STUB_ADDS" | sed '1s/^[^|]*|[^|]*|//')
check "body carries the run id" "$(printf '%s\n' "$body" | grep -c '^Run: 11$')" 1
check "body carries the run URL" "$(printf '%s\n' "$body" | grep -c "^URL: $U/11\$")" 1
check "body names the failing job" "$(printf '%s\n' "$body" | grep -c '^Failing job: behaviour shard 2$')" 1
check "body carries the first failing log line" "$(printf '%s\n' "$body" | grep '^First failing line:')" "First failing line: not ok 2 journey reads the wake"
check "body says never re-run" "$(printf '%s\n' "$body" | grep -c 'Never re-run; fix the root cause')" 1
check "PR head run files its own ticket" "$(grep -c '^ci-red-run-14|' "$STUB_ADDS")" 1
check "a log with no failing line says so" "$(grep -c 'no failing line found in the log' "$STUB_ADDS")" 1
check "green run files none" "$(grep -c 'ci-red-run-12\|ci-red-run-13' "$STUB_ADDS" || true)" 0
check "superseded old red run files none" "$(grep -c 'ci-red-run-9|' "$STUB_ADDS" || true)" 0
check "second poll files and prints nothing" "$(poll)" ""
check "second poll adds no ticket" "$(grep -c "^ci-red-run-" "$STUB_ADDS" || true)" 2

rm -rf -- "$FM/data/jg-merge-on-green/red-ci-ticket" "$FM/state/alerts"; : > "$STUB_ADDS"; : > "$STUB_ADD_FAIL"
check "a refused add prints nothing" "$(poll)" ""
rm -f "$STUB_ADD_FAIL"
check "a refused add is retried next poll" "$(poll | wc -l)" 2
touch "$STUB_FAIL"; rm -rf -- "$FM/data/jg-merge-on-green/red-ci-ticket" "$FM/state/alerts"
check "a forge failure is silent" "$(poll)" ""
rm -f "$STUB_FAIL"

# The watcher check runs it: merge-on-green.sh check, with no tasks, still reaches the ticket check.
rm -rf -- "$FM/data/jg-merge-on-green/red-ci-ticket" "$FM/state/alerts"; : > "$STUB_ADDS"
cp "$SRC/merge-on-green.sh" "$SRC/red-ci-ticket.sh" "$d/"
check "merge-on-green.sh check runs the ticket check" "$(JG_CHECK_TIMEOUT=30 "$d/merge-on-green.sh" check "$FM" 2>&1 | grep -c '^alert line-red')" 2

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all red-ci-ticket checks passed"
