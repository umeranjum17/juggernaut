#!/usr/bin/env bash
# End-to-end: merge-on-green.sh against a fixture juggernaut home for a DIRECT-PR task. Such a task has no
# pipeline run, so its resolved state is the worker's own done line from the status log
# ("state: done · source: status-log · ..."), never the "checks green: PR ready" wording a run writes.
# The watcher must still merge it when the forge read shows an open pull request with every check green,
# and must stay silent (burning no head) while a check is red, the read fails, the pull request is
# merged, the worker is still working, or yolo is off.
# Measured: 0 of the last 30 merged pull requests were landed by this check; each waited for a lead turn.
# Usage: merge-on-green/tests/merge-on-green-direct-pr.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/data TMPDIR=$d
export STUB_DIR=$d/stub
FM=$d/fm
mkdir -p "$HOME" "$STUB_DIR/pr-state" "$STUB_DIR/status-log" "$STUB_DIR/status-log-working" "$FM/state" "$FM/bin" "$FM/data/t1"
export JG_MOG_CHECKS_LINT=$STUB_DIR/jg-checks-lint.sh
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
mog() { JG_CHECK_TIMEOUT=30 "$SRC/merge-on-green.sh" check "$FM" 2>&1; }
meta() { # <task> <yolo> <head> <gen> -> meta + matching PASS receipt
  printf 'yolo=%s\npr=https://github.com/ex/r/pull/%s\npr_head=%s\nspawn_gen=%s\n' "$2" "${1#t}" "$3" "$4" > "$FM/state/$1.meta"
  printf '{\n  "verdict": "PASS",\n  "head": "%s",\n  "spawn_gen": "%s"\n}\n' "$3" "$4" > "$FM/state/$1.run-receipt.json"
}
called() { [ -e "$1" ] && echo called || echo never; }

# The resolved state of a direct-PR task: the worker's own done line, or still working.
cat > "$FM/bin/jg-crew-state.sh" <<'STUB'
#!/usr/bin/env bash
if [ -f "$STUB_DIR/status-log/$1" ]; then
  echo "state: done · source: status-log · PR https://github.com/ex/r/pull/${1#t} ready, 13/13 checks green, receipt PASS"
else
  echo "state: working · source: status-log · running the sealed run"
fi
STUB
# The forge read (--all): one line per draft, conflict, unfinished or red check, or merged state; nothing when green.
# $STUB_DIR/pr-state/<task> holds the lines to print; a missing file is green (nothing), "fail" is a lookup error.
cat > "$FM/bin/jg-pr-state.sh" <<'STUB'
#!/usr/bin/env bash
t=t${2##*/}
printf '%s\n' "$*" >> "$STUB_DIR/pr-state-calls"
if [ "$(cat "$STUB_DIR/pr-state/$t" 2>/dev/null)" = fail ]; then echo "jg-pr-state: could not read $2" >&2; exit 2; fi
[ ! -f "$STUB_DIR/pr-state/$t" ] || cat "$STUB_DIR/pr-state/$t"
exit 0
STUB
cat > "$FM/bin/jg-pr-merge.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$STUB_DIR/merge-calls"
echo "merged pull request $2"
STUB
cat > "$STUB_DIR/jg-checks-lint.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$STUB_DIR/lint-calls"
echo "checks-lint: PASS: 2 evidence files"
STUB
# The merged-line latency read calls gh; there is no forge here, so it falls back to the clock.
printf '#!/bin/sh\nexit 1\n' > "$STUB_DIR/gh"
chmod +x "$FM/bin/jg-crew-state.sh" "$FM/bin/jg-pr-state.sh" "$FM/bin/jg-pr-merge.sh" "$STUB_DIR/jg-checks-lint.sh" "$STUB_DIR/gh"
export PATH=$STUB_DIR:$PATH
H1=1111111111111111111111111111111111111111

# (a) a direct-PR done line over green checks merges, through jg-pr-merge only.
meta t17 on "$H1" s17
touch "$STUB_DIR/status-log/t17"
out=$(mog)
has "a: a direct-PR done line over green checks merges" "$out" "merged t17 https://github.com/ex/r/pull/17"
check "a: jg-pr-merge was called once for it" "$(grep -c '^' "$STUB_DIR/merge-calls")" 1
has "a: it asked the forge for every non-green check" "$(cat "$STUB_DIR/pr-state-calls")" "--all https://github.com/ex/r/pull/17"
rm "$FM/state/t17.meta" "$FM/state/t17.run-receipt.json" "$STUB_DIR/status-log/t17"

# (b) a false done (a check still red or pending): silent, nothing linted or merged, and the head is not
# burned, so the same head merges as soon as the forge says green.
rm -f "$STUB_DIR/merge-calls" "$STUB_DIR/lint-calls"
meta t18 on "$H1" s18
touch "$STUB_DIR/status-log/t18"
echo "CHECK: Changed tests 2 (FAILURE)" > "$STUB_DIR/pr-state/t18"
check "b: a done line over a red check is silent" "$(mog)" ""
check "b: nothing merged while a check is red" "$(called "$STUB_DIR/merge-calls")" never
check "b: nothing linted while a check is red" "$(called "$STUB_DIR/lint-calls")" never
check "b: the head is not burned" "$([ -e "$FM/data/jg-merge-on-green/t18.head" ] && echo burned || echo free)" free
rm "$STUB_DIR/pr-state/t18"
has "b: the same head merges once the forge says green" "$(mog)" "merged t18 https://github.com/ex/r/pull/18"
rm "$FM/state/t18.meta" "$FM/state/t18.run-receipt.json" "$STUB_DIR/status-log/t18"

# (c) a forge lookup error and an already merged pull request are silent too.
rm -f "$STUB_DIR/merge-calls"
meta t19 on "$H1" s19
touch "$STUB_DIR/status-log/t19"
echo fail > "$STUB_DIR/pr-state/t19"
check "c: a forge lookup error is silent and retried next sweep" "$(mog)" ""
echo "STATE: merged at 2026-11-02T05:11:19Z" > "$STUB_DIR/pr-state/t19"
check "c: an already merged pull request is silent" "$(mog)" ""
check "c: neither merged anything" "$(called "$STUB_DIR/merge-calls")" never
rm "$FM/state/t19.meta" "$FM/state/t19.run-receipt.json" "$STUB_DIR/status-log/t19" "$STUB_DIR/pr-state/t19"

# (d) a worker still working never reaches the forge read, and yolo off still holds a done direct-PR task.
rm -f "$STUB_DIR/pr-state-calls"
meta t20 on "$H1" s20
check "d: a working task is silent" "$(mog)" ""
meta t21 off "$H1" s21
touch "$STUB_DIR/status-log/t21"
check "d: yolo off still holds a done direct-PR task" "$(mog)" ""
check "d: the forge was not read for either" "$(called "$STUB_DIR/pr-state-calls")" never

# (e) a PR 617-style done line with no pr=/pr_head= in the record: the watcher records both through
# jg-pr-check.sh --from-status, then merges with no lead turn. The stub records like the real script does.
cat > "$FM/bin/jg-pr-check.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$STUB_DIR/check-calls"
[ "$1" = --from-status ] || exit 2
url=$(sed -n 's/^done \[at=[0-9]*\]: PR \(https[^ ]*\)$/\1/p' "$JG_HOME/state/$2.status" | tail -1)
[ -n "$url" ] || exit 0
grep -v '^pr=\|^pr_head=' "$JG_HOME/state/$2.meta" > "$JG_HOME/state/$2.meta.new" || true
printf 'pr=%s\npr_head=%s\n' "$url" "$STUB_HEAD" >> "$JG_HOME/state/$2.meta.new"
mv "$JG_HOME/state/$2.meta.new" "$JG_HOME/state/$2.meta"
STUB
chmod +x "$FM/bin/jg-pr-check.sh"
export STUB_HEAD=$H1
rm -f "$STUB_DIR/merge-calls"
printf 'yolo=on\nspawn_gen=s617\n' > "$FM/state/t617.meta"
printf '{\n  "verdict": "PASS",\n  "head": "%s",\n  "spawn_gen": "s617"\n}\n' "$H1" > "$FM/state/t617.run-receipt.json"
printf 'working [at=1]: x\ndone [at=2]: PR https://github.com/ex/r/pull/617\n' > "$FM/state/t617.status"
touch "$STUB_DIR/status-log/t617"
out=$(mog)
has "e: a done line with no recorded PR is recorded and merged with no lead turn" "$out" "merged t617 https://github.com/ex/r/pull/617"
has "e: pr= was written into the record" "$(cat "$FM/state/t617.meta")" "pr=https://github.com/ex/r/pull/617"
has "e: pr_head= was written into the record" "$(cat "$FM/state/t617.meta")" "pr_head=$H1"
check "e: recorded through jg-pr-check --from-status for this home" "$(head -1 "$STUB_DIR/check-calls")" "$FM|--from-status t617"
# a task that is still working and unrecorded: the record call is not repeated for the same status line.
printf 'yolo=on\nspawn_gen=s620\n' > "$FM/state/t620.meta"
printf 'working [at=1]: x\n' > "$FM/state/t620.status"
rm -f "$STUB_DIR/check-calls"
mog >/dev/null; mog >/dev/null
check "e: an unrecorded task is looked up once per distinct status line" "$(grep -c 't620' "$STUB_DIR/check-calls")" 1
rm -f "$FM/state/t617."* "$FM/state/t620."* "$STUB_DIR/status-log/t617"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s)"; exit 1; }
echo "PASS: merge-on-green direct-PR e2e"
