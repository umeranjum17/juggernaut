#!/usr/bin/env bash
# End-to-end: drive merge-ready-batch.sh against a fixture home with a fake clock and a pr-state stub.
# Proves (1) the ten-minute batch: nothing before the window ends, ONE line at the end that carries every
# outcome including one that arrived mid-window, nothing repeated; (2) the authority check inside the batch:
# no standing authority, merge=manual, a red check and a stale receipt are never called mergeable, a green
# authorised outcome with a PASS receipt is; (3) an outcome that turns red is named, a merged one says so;
# (4) the batch runs from merge-on-green.sh check.
# Usage: merge-on-green/tests/merge-ready-batch.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
FM=$d/fm; mkdir -p "$FM/state" "$FM/data" "$FM/bin"
U=https://github.com/ex/r/pull
cat > "$d/pr-state" <<'STUB'
#!/usr/bin/env bash
# jg-pr-state.sh --all <url>: blockers from $STUB_DIR/<number>, empty when green
f=$STUB_DIR/${2##*/}; [ ! -f "$f" ] || cat "$f"
STUB
chmod +x "$d/pr-state"
export STUB_DIR=$d/prs JG_MRB_PR_STATE=$d/pr-state JG_CHECK_TIMEOUT=30; mkdir -p "$STUB_DIR"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) printf 'FAIL: %s\n  want to contain: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)) ;; esac; }
ship() { # <task> <pr-number> <meta extras...>: a ship whose newest status line is its PR-ready report
  local t=$1 n=$2; shift 2
  printf 'kind=ship\npr=%s/%s\npr_head=h%s\n' "$U" "$n" "$n" > "$FM/state/$t.meta"
  for x in "$@"; do printf '%s\n' "$x" >> "$FM/state/$t.meta"; done
  printf 'done [at=1]: PR %s/%s\n' "$U" "$n" > "$FM/state/$t.status"
}
receipt() { printf '{"verdict":"%s","head":"%s"}\n' "$2" "$3" > "$FM/state/$1.run-receipt.json"; }
T0=1000000
run() { JG_MERGE_READY_NOW=$1 "$SRC/merge-ready-batch.sh" check "$FM" 2>&1; }

ship alpha 1 yolo=on;  receipt alpha PASS h1
ship bravo 2;          receipt bravo PASS h2
ship charlie 3 yolo=on; receipt charlie PASS h3; echo 'CHECK: build (failure)' > "$STUB_DIR/3"
ship delta 4 yolo=on merge=manual; receipt delta PASS h4
check "an outcome opens the window and wakes nothing" "$(run $T0)" ""
ship echo 5 yolo=on;   receipt echo PASS stale-head
check "still silent one second before the window ends" "$(run $((T0 + 599)))" ""
out=$(run $((T0 + 600)))
check "one line for the whole batch" "$(printf '%s\n' "$out" | wc -l)" 1
has "line names the batch size" "$out" "merge-ready batch, 5 outcome(s)"
has "a green authorised outcome with a PASS receipt is mergeable" "$out" "alpha $U/1: mergeable;"
has "no standing authority needs the captain's word" "$out" "bravo $U/2: needs the captain's word;"
has "a red check is not mergeable" "$out" "charlie $U/3: NOT mergeable: CHECK: build (failure);"
has "merge=manual needs the captain's word even with yolo on" "$out" "delta $U/4: needs the captain's word;"
has "a receipt for another head is not mergeable" "$out" "echo $U/5: NOT mergeable: no PASS run receipt for this head;"
check "a reported outcome is not repeated" "$(run $((T0 + 700)))" ""

# alpha is mergeable and unmerged: it is read again each batch and named when it turns red.
echo 'CHECK: lint (failure)' > "$STUB_DIR/1"
check "no new wake inside the next window" "$(run $((T0 + 800)))" ""
out=$(run $((T0 + 1400)))
has "an outcome that turned red is named" "$out" "alpha $U/1: NOT mergeable: CHECK: lint (failure);"
check "only the changed outcome is listed" "$(printf '%s' "$out" | grep -o 'outcome(s)' | wc -l)" 1

# merged outcomes leave the list; a PR closed on the forge says so
printf 'done [at=2]: merged %s/1\n' "$U" >> "$FM/state/alpha.status"
ship bravo 2 yolo=on; sed -i 's/pr_head=h2/pr_head=h2b/' "$FM/state/bravo.meta"; receipt bravo PASS h2b; echo closed > "$STUB_DIR/2"
out=$(run $((T0 + 2000))); out=$out$(run $((T0 + 2700)))
has "a closed PR says so" "$out" "bravo $U/2: no longer waiting: closed;"
case "$out" in *"alpha $U/1"*) echo "FAIL: a merged outcome was listed again"; fails=$((fails + 1)) ;; *) echo "ok: a merged outcome leaves the list" ;; esac

# the batch rides merge-on-green.sh check
rm -rf "$FM/data/jg-merge-on-green" "$FM/state"/*; ship foxtrot 6 yolo=on; receipt foxtrot PASS h6
JG_MERGE_READY_NOW=$T0 "$SRC/merge-on-green.sh" check "$FM" >/dev/null 2>&1 || true
out=$(JG_MERGE_READY_NOW=$((T0 + 600)) "$SRC/merge-on-green.sh" check "$FM" 2>&1 || true)
has "merge-on-green.sh check carries the batch" "$out" "merge-ready batch, 1 outcome(s): foxtrot $U/6: mergeable;"
[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
