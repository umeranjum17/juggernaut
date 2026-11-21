#!/usr/bin/env bash
# Journey: the acceptance trial is measured by the real command bin/jg-acceptance-trial.sh, which calls the real bin/jg-ask-record.sh
# on a fixture home (git project, trunk records, turns, observations, a stub backlog that prints the ticket moments).
# a) an empty roster is PENDING (exit 2) before the deadline and FAIL (exit 1) after it, with no ask invented;
# b) ten asks inside the window with every bound met is MEASURED-PASS (exit 0) with the exact median and p90;
# c) one ask that is slow to in use, one that was proved twice, and one that is not in use everywhere are each named;
# d) an ask requested before T0, and a roster line with a missing field, never count.
# Usage: tests/jg-acceptance-trial.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN=$ROOT/bin/jg-acceptance-trial.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
H=$d/home P=$H/projects/proj
mkdir -p "$H/data" "$H/state" "$P"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$P" init -q -b trunk
T0=1794817225 DEADLINE=$((1794817225 + 86400))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
: > "$d/rows.jsonl"; : > "$H/data/trunk-landings.tsv"; : > "$H/data/trunk-verify.tsv"; : > "$H/data/trunk-in-use.tsv"; : > "$H/data/ask-turns.tsv"
# ask <n> <requested offset s> <ask-to-in-use s> <ready-to-in-use s> <verify runs>: one ask with its records
ask() {
  local n=$1 req=$((T0 + $2)) live rd c i
  live=$((req + $3)); rd=$((live - $4))
  echo "c$n $RANDOM$SECONDS" >> "$P/c$n"; git -C "$P" add "c$n"; git -C "$P" commit -q -m "c$n"; c=$(git -C "$P" rev-parse HEAD)
  jq -nc --arg t "ask$n" --arg q "$(iso "$req")" --arg r "$(iso "$rd")" --arg l "$(iso "$live")" \
    '{ticket: $t, task: $t, kind: "ship", project: "proj", pr: "", requested_at: $q, started: $q, closed: "", ready_at: $r, landed_at: $r, live_at: $l, released_at: "", pinned_back_at: "", reverted_at: ""}' >> "$d/rows.jsonl"
  printf 'ask%s\tproj\t%s\t%s\tno-landing-gate\n' "$n" "$c" "$rd" >> "$H/data/trunk-landings.tsv"
  for ((i = 1; i <= $5; i++)); do printf 'proj\t%s\tv%s-%s\t%s\tgreen\t60\t/x\tok\n' "$((rd + i))" "$n" "$i" "$c" >> "$H/data/trunk-verify.tsv"; done
  printf 'proj:alpha\t%s\t%s\tlive,behavior=pass\t\n' "$c" "$live" >> "$H/data/trunk-in-use.tsv"
  [ "${6:-both}" = alpha ] || printf 'proj:beta\t%s\t%s\tlive,behavior=pass\t\n' "$c" "$live" >> "$H/data/trunk-in-use.tsv"
  printf '%s\task%s\task%s\tclaude\t%s\ttranscript\n' "$T0" "$n" "$n" "$((n * 10))" >> "$H/data/ask-turns.tsv"
}
cat > "$d/backlog.sh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "times --json") jq -s . "$d/rows.jsonl" ;;
  "trace landing") printf '%s\t%s\t%s\n' - x '{"gate_s": 30, "landing_s": 30}' ;;
esac
STUB
chmod +x "$d/backlog.sh"
trial() {  # <extra roster lines...>: write the trial record
  { printf '# trial\nT0: %s (x)\nDeadline: T0 + 24 h = %s (x)\n## Roster (ask id | requested_at | home | original message | intended homes)\n' "$T0" "$DEADLINE"; printf '%s\n' "$@"; } > "$d/trial.md"
}
run() { JG_HOME=$H JG_ASK_BACKLOG=$d/backlog.sh bash "$BIN" --trial "$d/trial.md" --now "$1" "${@:2}"; }
rc() { local r=0; run "$@" > "$d/out" 2>&1 || r=$?; echo "$r"; }

trial '(empty)'
check "a: empty roster before the deadline exits 2" "$(rc $((T0 + 10)))" 2
check "a: it says 0 of 10" "$(grep -c 'PENDING - 0 of 10' "$d/out")" 1
check "a: empty roster after the deadline exits 1" "$(rc $((DEADLINE + 1)))" 1
check "a: it says fewer than ten" "$(grep -c 'FAIL - fewer than ten qualified asks at the deadline (0)' "$d/out")" 1

lines=()
for n in 1 2 3 4 5 6 7 8 9 10; do ask "$n" $((n * 100)) $((3600 + n * 60)) $((600 + n * 60)) 1; lines+=("ask$n | $((T0 + n * 100)) | alpha | message $n | alpha,beta"); done
trial "${lines[@]}"
check "b: ten good asks exit 0" "$(rc $((T0 + 90000)))" 0
check "b: verdict" "$(grep -c 'MEASURED-PASS' "$d/out")" 1
run $((T0 + 90000)) --json > "$d/r.json"
check "b: exact speed numbers" "$(jq -c '[.speed.ask_to_in_use_min.median, .speed.ask_to_in_use_min.p90, .speed.ready_to_in_use_min.median, .speed.ready_to_in_use_min.p90]' "$d/r.json")" '[65,69,15,19]'
check "b: turns reported per ask" "$(jq -c '.efficiency.model_turns.ask3' "$d/r.json")" 30
check "b: unmeasured criteria are named, never passed" "$(jq '.unmeasured | length' "$d/r.json")" 6

: > "$d/rows.jsonl"; : > "$H/data/trunk-landings.tsv"; : > "$H/data/trunk-verify.tsv"; : > "$H/data/trunk-in-use.tsv"
lines=()
for n in 1 2 3 4 5 6 7 8 9 10; do
  case $n in 1) ask 1 100 $((9 * 3600)) 600 1;; 2) ask 2 200 $((9 * 3600)) 600 1;; 9) ask 9 900 3600 600 2;; 10) ask 10 1000 3600 600 1 alpha;; *) ask "$n" $((n * 100)) 3600 600 1;; esac
  lines+=("ask$n | $((T0 + n * 100)) | alpha | message $n | alpha,beta")
done
trial "${lines[@]}"
check "c: broken bounds exit 1" "$(rc $((T0 + 90000)))" 1
check "c: the double proof is named" "$(grep -c '^  - ask9: 2 proofs for one candidate' "$d/out")" 1
check "c: the missing home is named" "$(grep -c '^  - ask10: not in use in beta' "$d/out")" 1
check "c: the speed bound is named" "$(grep -c '^  - ask_to_in_use_min: median 60 p90 540 over the bound 240/480' "$d/out")" 1

trial "ask1 | $((T0 - 5)) | alpha | early | alpha" "ask2 | $((T0 + 5)) | alpha | | alpha" "ask3 | $((T0 + 5)) | alpha | ok | alpha"
run $((T0 + 10)) --json > "$d/r.json" || true
check "d: before T0 is out of the window, a missing field is malformed, one ask counts" "$(jq -c '[.asks.qualified, .asks.out_of_window, .asks.malformed_lines]' "$d/r.json")" '[1,["ask1"],1]'
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo 'all ok'
