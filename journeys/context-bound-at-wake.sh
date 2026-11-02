#!/usr/bin/env bash
# done-done journey: Main's context is bounded before a wake turn, and the record is kept.
# Two real Haiku sessions get the same nine ~20k-token captain notes and one wake: one with no bound,
# one with the bound the tracked project settings ship. The audit's counter reads both transcripts.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
TOOL=$REPO/bin/jg-context-bound.py
CEILING=150000
NOTES=9
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/context-bound-at-wake.txt
: >"$LOG"
fails=0
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
check() {  # <label> <command...>
  local label=$1; shift
  if "$@"; then say "ok - $label"; else say "FAIL $label"; fails=1; fi
}
command -v claude >/dev/null 2>&1 || { say "SKIP: the claude command is not installed"; exit 0; }
WAKEFACT=WAKEFACT-$(printf '%s' "$$-wake" | md5sum | cut -c1-6)
vault() { printf 'VAULT-%s-%s' "$1" "$(printf '%s' "$1" | md5sum | cut -c1-6)"; }

ask() {  # <dir> <resume-flags> <prompt>
  # shellcheck disable=SC2086
  (cd "$1" && timeout 300 claude -p --settings "$1/lab-settings.json" --model claude-haiku-5-5 --output-format json $2 "$3") 2>&1
}
lab() {  # <name> <window or empty>: nine captain notes then one wake, in one session
  local dir=$T/$1 sid i body flags
  sid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  mkdir -p "$dir"
  python3 "$TOOL" settings ${2:+--window "$2"} >"$dir/lab-settings.json"
  for i in $(seq 1 "$NOTES"); do
    body=$(python3 -c 'import random,sys; r=random.Random(int(sys.argv[1])); s="ba be bi bo ka ke ki la le lo ma me mi na ne ra re ro sa se ta te va vi".split(); print(" ".join("".join(r.choice(s) for _ in range(r.randint(2,4))) for _ in range(6000)))' "$i")
    flags="--resume $sid"; [ "$i" = 1 ] && flags="--session-id $sid"
    ask "$dir" "$flags" "CAPTAIN NOTE $i: the vault word for note $i is $(vault "$i"). Remember it. Reply only with ack-$i. Material follows, ignore it: $body" >/dev/null
  done
  ask "$dir" "--resume $sid" "Stop hook: the watcher says this needs a handling turn now. check: demo-wake $WAKEFACT. Reply with the $WAKEFACT token and the vault word of captain note 2, nothing else." >"$dir/wake.json"
  python3 "$TOOL" find "$sid" >"$dir/transcript"
}

say "== the same $NOTES captain notes and one wake, without and with the bound"
lab before 1000000
lab after ""
BT=$(cat "$T/before/transcript"); AT=$(cat "$T/after/transcript")
[ -f "$BT" ] && [ -f "$AT" ] || { say "FAIL the session records were not written"; exit 1; }
cp "$BT" "$OUT/before-session.jsonl"; cp "$AT" "$OUT/after-session.jsonl"
python3 "$TOOL" turns "$BT" >"$OUT/before-turns.jsonl"
python3 "$TOOL" turns "$AT" >"$OUT/after-turns.jsonl"
wake() {  # <turns-file> <field>
  python3 -c 'import json,sys; print([r for r in map(json.loads, open(sys.argv[1])) if r.get("kind")=="wake"][-1][sys.argv[2]])' "$1" "$2"
}
b_first=$(wake "$OUT/before-turns.jsonl" ctx_first); a_first=$(wake "$OUT/after-turns.jsonl" ctx_first)
a_max=$(wake "$OUT/after-turns.jsonl" ctx_max)
b_tot=$(wake "$OUT/before-turns.jsonl" input_total); a_tot=$(wake "$OUT/after-turns.jsonl" input_total)
a_comp=$(tail -1 "$OUT/after-turns.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["compactions"])')
say "wake turn, no bound: context at start $b_first, input tokens $b_tot"
say "wake turn, bounded:  context at start $a_first, largest call $a_max, input tokens $a_tot, compactions $a_comp (ceiling $CEILING)"

check "the unbounded session is over the ceiling at the wake, so the lab proves something" [ "$b_first" -gt "$CEILING" ]
check "every call of the bounded wake turn is at or below the ceiling" [ "$a_max" -le "$CEILING" ]
check "the wake turn read fewer input tokens ($b_tot -> $a_tot)" [ "$a_tot" -lt "$b_tot" ]
check "the bounded session compacted before the wake" [ "$a_comp" -ge 1 ]

ans=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result",""))' "$T/after/wake.json")
say "bounded wake answer: $ans"
check "the wake fact and an early captain word are answered" bash -c '[[ $1 == *"$2"* && $1 == *"$3"* ]]' _ "$ans" "$WAKEFACT" "$(vault 2)"

say "== the full history is still readable, and the captain's words come back verbatim"
for i in $(seq 1 "$NOTES"); do check "captain note $i is in the record on disk" grep -q -F "CAPTAIN NOTE $i:" "$AT"; done
mkdir -p "$T/state"
printf '{"source":"compact","transcript_path":"%s"}' "$AT" | python3 "$TOOL" emit --state "$T/state" --max-chars 400 >"$OUT/emit-output.txt"
check "the history path is named" grep -q -F "$AT" "$OUT/emit-output.txt"
for i in 2 9; do check "captain note $i is repeated verbatim" grep -q -F "the vault word for note $i is $(vault "$i")" "$OUT/emit-output.txt"; done
check "the compaction is logged" test -s "$T/state/context-bound.log"

say "== the real session-start hook prints the same after a compact, and nothing extra at startup"
H=$T/home; mkdir -p "$H/state"; git -C "$H" init -q; cp -R "$REPO/bin" "$H/bin"; echo home >"$H/AGENTS.md"
printf '#!/usr/bin/env bash\necho "DIGEST $*"\n' >"$H/bin/jg-session-start.sh"
hook() { printf '{"source":"%s","transcript_path":"%s"}' "$1" "$AT" | JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" bash "$H/bin/jg-sessionstart-run.sh" 2>&1; }
check "compact prints the digest, then the captain's note 9 verbatim" bash -c '[[ $1 == DIGEST* && $1 == *"$2"* ]]' _ "$(hook compact)" "the vault word for note 9 is $(vault 9)"
check "startup prints only the digest" bash -c '[[ $1 != *VAULT-* ]]' _ "$(hook startup)"

printf '{"target":{"version":"%s"},"result":"wake context at start %s -> %s, input tokens %s -> %s, ceiling %s"}\n' \
  "$(git -C "$REPO" rev-parse --short HEAD)" "$b_first" "$a_first" "$b_tot" "$a_tot" "$CEILING" >"$OUT/steps.json"
if [ "$fails" -eq 0 ]; then say "PASS: wake input $b_tot -> $a_tot tokens, context $b_first -> $a_first, record intact"; exit 0; fi
exit 1
