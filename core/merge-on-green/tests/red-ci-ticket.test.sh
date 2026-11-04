#!/usr/bin/env bash
# End-to-end: drive red-ci-ticket.sh against a fixture home whose clone has a github origin, with a gh-axi stub that
# answers from recorded run lists and a jg-tasks-axi.sh stub that records every add. Covers a red run filing one ticket
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
cat > "$FM/bin/jg-tasks-axi.sh" <<'STUB'
#!/usr/bin/env bash
# add <id> <title> --kind ship --body <body>: record it; show: never found
[ "$1" = add ] || exit 1
[ ! -e "$STUB_ADD_FAIL" ] || exit 1
printf '%s\n' "$2|$3|$7" >> "$STUB_ADDS"
STUB
chmod +x "$FM/bin/jg-tasks-axi.sh"
cat > "$d/gh-axi" <<'STUB'
#!/usr/bin/env bash
[ ! -e "$STUB_FAIL" ] || { echo "error: forge unreachable" >&2; exit 1; }
[ "$1" = api ] || exit 2
run() { printf '{"id":%s,"name":"%s","workflow_id":%s,"html_url":"https://github.com/ex/r/actions/runs/%s","head_sha":"%s","conclusion":"%s","created_at":"%s"}' "$1" "$2" "$3" "$1" "$4" "$5" "$6"; }
case $2 in
  repos/ex/r) out='{"default_branch":"main"}' ;;
  repos/ex/r/pulls*) out='[{"base":{"ref":"release/c-10"},"head":{"sha":"sha104"}}]' ;;
  repos/ex/r/actions/runs\?branch=main*) out="{\"workflow_runs\":[$(run 9 CI 1 sha88 failure 2026-11-03T01:00:00Z),$(run 11 CI 1 sha99 failure 2026-11-04T01:00:00Z),$(run 12 Lint 2 sha99 success 2026-11-04T01:00:00Z)]}" ;;
  repos/ex/r/actions/runs\?branch=release/c-10*) out="{\"workflow_runs\":[$(run 13 CI 1 sha50 success 2026-11-04T02:00:00Z)]}" ;;
  repos/ex/r/actions/runs\?head_sha=sha104*) out="{\"workflow_runs\":[$(run 14 CI 1 sha104 timed_out 2026-11-04T03:00:00Z)]}" ;;
  repos/ex/r/actions/runs/11/jobs) out='{"jobs":[{"id":501,"name":"build","conclusion":"success"},{"id":502,"name":"behaviour shard 2","conclusion":"failure"}]}' ;;
  repos/ex/r/actions/runs/14/jobs) out='{"jobs":[{"id":601,"name":"lint","conclusion":"timed_out"}]}' ;;
  repos/ex/r/actions/jobs/502/logs) printf '2026-11-04T01:00:00.1Z ok 1 first\n2026-11-04T01:00:01.1Z not ok 2 journey reads the wake\n2026-11-04T01:00:02.1Z ##[error]Process completed with exit code 1.\n'; exit 0 ;;
  repos/ex/r/actions/jobs/601/logs) printf 'no failing line here\n'; exit 0 ;;
  *) echo "error: unrecorded request $2" >&2; exit 1 ;;
esac
if [ "$3" = --jq ]; then printf '%s' "$out" | jq -r "$4"; else printf '%s\n' "$out"; fi
STUB
chmod +x "$d/gh-axi"
export JG_RED_CI_GH=$d/gh-axi
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
poll() { JG_CHECK_TIMEOUT=30 "$SRC/red-ci-ticket.sh" check "$FM" 2>&1; }
U=https://github.com/ex/r/actions/runs

out=$(poll)
check "first poll alerts for exactly two red runs" "$(printf '%s\n' "$out" | wc -l)" 2
check "alert names the run, job and routing" "$(printf '%s\n' "$out" | grep "runs/11:")" "red-ci-ticket: $U/11: CI behaviour shard 2 went red; filed ci-red-run-11 (r); fix the root cause, never re-run"
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

rm -rf -- "$FM/data/jg-merge-on-green/red-ci-ticket"; : > "$STUB_ADDS"; : > "$STUB_ADD_FAIL"
check "a refused add prints nothing" "$(poll)" ""
rm -f "$STUB_ADD_FAIL"
check "a refused add is retried next poll" "$(poll | wc -l)" 2
touch "$STUB_FAIL"; rm -rf -- "$FM/data/jg-merge-on-green/red-ci-ticket"
check "a forge failure is silent" "$(poll)" ""
rm -f "$STUB_FAIL"

# The watcher check runs it: merge-on-green.sh check, with no tasks, still reaches the ticket check.
rm -rf -- "$FM/data/jg-merge-on-green/red-ci-ticket"; : > "$STUB_ADDS"
cp "$SRC/merge-on-green.sh" "$SRC/red-ci-ticket.sh" "$d/"
check "merge-on-green.sh check runs the ticket check" "$(JG_CHECK_TIMEOUT=30 "$d/merge-on-green.sh" check "$FM" 2>&1 | grep -c '^red-ci-ticket:')" 2

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all red-ci-ticket checks passed"
