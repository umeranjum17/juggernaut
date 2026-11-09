#!/usr/bin/env bash
# Integration: run the real quality reader over a fixture home and pin each measure on a small sample:
# repeated done (a lead message between two, a row outside the window left out), first-check proof,
# brief size by file time, the notification table (digest, turn-ended after a status line, rows that
# wake at once by the rule table), and the exit-2 paths. Fixture home only: no live record is read.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/quality.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
home="$d/home"
mkdir -p "$home/state" "$home/data"

fail() { echo "quality test: $1" >&2; exit 1; }
T0=1793491200 # 2026-11-01T00:00:00Z
SINCE=2026-11-01T00:00:00Z
UNTIL=2026-11-02T00:00:00Z
row() { printf '{"at":%s,"thread":"#fleet","from":"%s","to":"%s","kind":"%s","text":"%s","status":null}\n' "$1" "$2" "$3" "$4" "$5"; }

{
  row $((T0 + 100)) a main status 'done [at=1]: ready'
  row $((T0 + 200)) main a agent 'rebase and say done again'
  row $((T0 + 300)) a main status 'done [at=2]: ready again'
  row $((T0 + 400)) b main status 'done [at=3]: ready'
  row $((T0 + 500)) b main status 'done [at=4]: ready again'
  row $((T0 + 600)) c main status 'done [at=5]: ready'
  row $((T0 - 1000)) d main status 'done [at=6]: before the window'
  row $((T0 + 700)) d main status 'done [at=7]: in the window'
  row $((T0 + 90000)) e main status 'done [at=8]: after the window'
  row $((T0 + 310)) a.turn-ended main wake 'signal: a.turn-ended signal: /s/a.status /s/a.turn-ended'
  row $((T0 + 5000)) c.turn-ended main wake 'signal: c.turn-ended signal: /s/c.status /s/c.turn-ended'
  row $((T0 - 900)) d.turn-ended main wake 'signal: d.turn-ended signal: before the window'
  row $((T0 + 800)) wake-digest main wake 'check: wake-digest 5 routine rows'
  row $((T0 + 900)) /h/state/foo.check.sh main wake 'check: foo-check foo is red'
  row $((T0 + 1000)) w1 main wake 'stale: w1 stale: w1'
  row $((T0 + 1100)) b main wake 'signal: b.status signal: /s/b.status [status=done]'
  echo 'this line is not json'
} >"$home/state/chat.jsonl"

{
  printf '2026-10-31T23:00:00Z\tT0\thead\tpass\t1 evidence files\n'
  printf '2026-11-01T01:00:00Z\tT1\thead\tpass\t2 evidence files\n'
  printf '2026-11-01T02:00:00Z\tT2\thead\tfail\tproof: names no command\n'
  printf '2026-11-01T03:00:00Z\tT2\thead\tpass\t1 evidence files\n'
  printf '2026-11-01T04:00:00Z\tT3\thead\tfail\tsome other failure\n'
} >"$home/data/checks-gate.log"

# Briefs: two in the window, one before it, one after it, one with no Task section.
brief() { mkdir -p "$home/data/$1"; printf '%b' "$2" >"$home/data/$1/brief.md"; touch -d "@$3" "$home/data/$1/brief.md"; }
brief t1 '# Intro\nabcdefghij\n# Task\nwork\n# Rules\nrules\n' $((T0 + 60))
brief t2 '# Task - ship\nwork on it now\n# Rules\nrules rules rules\n' $((T0 + 120))
brief told '# Task\nold\n' $((T0 - 60))
brief tlate '# Task\nlate\n' $((T0 + 90060))
brief tnone '# Intro\nno task here\n' $((T0 + 180))
size() { wc -c <"$home/data/$1/brief.md" | tr -d ' '; }
half_up() { echo $((($1 + $2 + 1) / 2)); }
brief_median=$(half_up "$(size t1)" "$(size t2)")
# The Task part of a brief is its Task heading and body (bytes after the "# ") plus the two bytes of "# ".
task_bytes() { echo $(($(printf '%b' "$1" | wc -c) + 2)); }
task_median=$(half_up "$(task_bytes 'Task\nwork\n')" "$(task_bytes 'Task - ship\nwork on it now\n')")

printf 'set digest-count 5\nbatch signal *.turn-ended *\nbatch check wake-digest *\nnow * * done*\n' >"$d/routing"

out=$("$CLI" --home "$home" --since "$SINCE" --until "$UNTIL" --routing "$d/routing")
has() { printf '%s\n' "$out" | grep -qF -- "$1" || { printf '%s\n' "$out" >&2; fail "missing: $1"; }; }
lacks() { ! printf '%s\n' "$out" | grep -qF -- "$1" || { printf '%s\n' "$out" >&2; fail "must not print: $1"; }; }

# Six done lines in the window by four tasks: two repeats, one of them after a lead message.
has '33% repeat done: 2 of 6 done lines'
has '2 of 4 tasks wrote done twice or more (50%)'
has '50% of the repeats (1 of 2) follow a lead message to that task'
# First checks in the window: T1 passes, T2 fails on form, T3 fails otherwise; T0 is before the window.
has '33% proof first-check: 1 of 3 targets passed their first check'
has '33% form errors: 1 first checks'
# Briefs written in the window with a Task section: t1 and t2; one without a Task section is left out.
has "$(printf '%s-byte brief median over 2 briefs; the Task part is %s bytes' "$brief_median" "$task_median")"
has '1 brief files with no Task section are left out'
# Notifications in the window: six rows, one digest, one turn-ended after a status line of two.
has '6 rows sent to the lead in the window'
has '2026-11-01  6'
has 'foo.check.sh 1'
lacks '/h/state'
has '1 digest rows'
has '1 turn-ended rows after a status line (50% of 2 turn-ended rows)'
has '3 rows wake at once (50%), by kind:'
has 'signal done 1'
has 'check 1'
has 'stale 1'
has '1 lines of state/chat.jsonl were not readable'

# Bad input exits 2 and says why; an absent record is named, not guessed.
rc=0
msg=$(env -u JG_HOME "$CLI" --since "$SINCE" --until "$UNTIL" 2>&1) || rc=$?
[ "$rc" = 2 ] || fail "no home exits $rc"
case $msg in *'--home is not a directory'*) ;; *) fail "no home message: $msg" ;; esac
rc=0
"$CLI" --home "$home" --since "$UNTIL" --until "$SINCE" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "since after until exits $rc"
rc=0
"$CLI" --home "$home" --since yesterday >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "bad time exits $rc"
rm -f "$home/state/chat.jsonl" "$home/data/checks-gate.log"
out=$("$CLI" --home "$home" --since "$SINCE" --until "$UNTIL" --routing "$d/routing")
has 'no record: state/chat.jsonl is absent'
has 'no record: data/checks-gate.log is absent'
has '2 briefs'

echo "quality test: ok"
