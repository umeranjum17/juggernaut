#!/usr/bin/env bash
# Journey: an ask's measurement record is joined from a fixture home's own records by the real command, bin/jg-ask-record.sh.
# The fixture home holds a git project, the trunk records, a sealed done-done run record, a task record with a Claude transcript and a
# stub backlog command that prints the ticket's moments. Cases:
# a) `show` joins every field of the record with no hand input: moments, minutes, run IDs from landing to release, per-home rows;
# b) a verify of a later tip is not the candidate's proof, a rerun at the same tip counts, a home that never got the commit is no row;
# c) `observe` writes a behaviour row that the next `show` binds to its home and version; an unobserved home is named in `missing`;
# d) a pin-back after the live moment leaves in_use_at to the first live install row, never the undone moment;
# e) `turns` counts distinct model responses of the worker since its spawn, and `show` reports them; another harness writes nothing;
# f) a ticket with no moments, and a usage error, are refused.
# Usage: tests/jg-ask-record.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN=$ROOT/bin/jg-ask-record.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
H=$d/home P=$H/projects/proj
mkdir -p "$H/data/tk1/.done-done/runs" "$H/state" "$P"
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/ask-record.log}
fails=0
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$P" init -q -b trunk
mkc() { echo "$1" > "$P/$1"; git -C "$P" add "$1"; git -C "$P" commit -q -m "$1"; git -C "$P" rev-parse HEAD; }
A=$(mkc a); B=$(mkc b); C=$(mkc c)   # A is the ask's commit; B and C come after it
T=1700000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# the stub backlog: `times --json` and `trace landing`, the two verbs the command reads
cat > "$d/backlog.sh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "times --json") cat "$d/times.json" ;;
  "trace landing") printf '%s\t%s\t%s\n' - "$(iso $((T + 4000)))" '{"gate_s": 30, "landing_s": 90, "queue_s": 500}' ;;
esac
STUB
chmod +x "$d/backlog.sh"
mk_times() {  # <live_at> <pinned_back_at>
  jq -n --arg req "$(iso "$T")" --arg st "$(iso $((T + 600)))" --arg rd "$(iso $((T + 3600)))" --arg ld "$(iso $((T + 4000)))" \
    --arg lv "$1" --arg pb "$2" '[{ticket: "tk1", task: "tk1", kind: "ship", project: "proj", pr: "", requested_at: $req, started: $st, closed: "",
      models: [["claude", "m", "high"]], ready_at: $rd, landed_at: $ld, live_at: $lv, released_at: "", pinned_back_at: $pb, reverted_at: ""}]' > "$d/times.json"
}
mk_times "$(iso $((T + 4500)))" ""

# trunk records
printf 'tk1\tproj\t%s\t%s\tno-landing-gate\n' "$A" "$((T + 4000))" > "$H/data/trunk-landings.tsv"
printf 'tk1\tproj\t%s\t%s\treceipt=PASS@%s\tsignature=absent\n' "$A" "$((T + 4000))" "${A:0:12}" > "$H/data/trunk-landing-proofs.tsv"
{
  printf 'proj\t%s\tproj-v1-%s\t%s\tgreen\t120\t/x\tok\n' "$((T + 4100))" "${B:0:12}" "$B"
  printf 'proj\t%s\tproj-v1-rerun\t%s\tgreen\t60\t/x\tok\n' "$((T + 4200))" "$B"
  printf 'proj\t%s\tproj-v2-%s\t%s\tgreen\t300\t/x\tok\n' "$((T + 9000))" "${C:0:12}" "$C"
} > "$H/data/trunk-verify.tsv"
{
  printf 'proj:alpha\t%s\t%s\tlive\t%s\n' "$B" "$((T + 4500))" "$A"
  printf 'proj:beta\t%s\t%s\tbootstrap-start,waiver=owner-rule-x,verdict=green\t%s\n' "$B" "$((T + 4510))" "$A"
  printf 'proj:gamma\t%s\t%s\tlive,behavior=pass\t%s\n' "$B" "$((T + 4520))" "$A"
  printf 'proj:delta\t%s\t%s\tlive\t%s\n' "$A" "$((T + 4530))" "$A"
} > "$H/data/trunk-in-use.tsv"
printf 'proj\trelease/v1\t%s\t3\t%s\thttps://example.test/pull/9\n' "$C" "$((T + 9500))" > "$H/data/trunk-releases.tsv"
# the sealed run of the lane
cat > "$H/data/tk1/.done-done/runs/RUN1.json" <<JSON
{"schema": 1, "run_id": "RUN1", "commit": "$A", "dirty": false, "exit": 0, "started_at": "$(iso $((T + 3000)) | sed s/Z/.100Z/)", "ended_at": "$(iso $((T + 3360)) | sed s/Z/.900Z/)"}
JSON

show() { JG_HOME=$H JG_ASK_BACKLOG=$d/backlog.sh bash "$BIN" show "$1"; }
f() { show tk1 | jq -c "$1"; }

# a) the whole record
rc=0; show tk1 > "$d/rec.json" 2>"$d/err" || rc=$?
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || cp "$d/rec.json" "$DONE_DONE_EVIDENCE_ROOT/ask-record.json"
check "a: show exits 0" "$rc" 0
check "a: no stderr" "$(cat "$d/err")" ""
check "a: commit and moments" "$(f '[.commit, .requested_at, .ready_at, .landed_at, .in_use_at]')" "[\"${A:0:12}\",$T,$((T + 3600)),$((T + 4000)),$((T + 4500))]"
check "a: ask to in use minutes" "$(f .ask_to_in_use_min)" 75
check "a: ready to in use minutes" "$(f .ready_to_in_use_min)" 15
check "a: sealed run id and minutes" "$(f '[.run_ids.sealed, .machine_minutes.sealed]')" '[["RUN1"],6]'
check "a: landing, receipt and release ids" "$(f '[.run_ids.landing, .run_ids.receipt, .run_ids.release]')" "[\"tk1@${A:0:12}\",\"PASS@${A:0:12}\",\"https://example.test/pull/9\"]"
check "a: landing machine minutes (gate + landing, no queue)" "$(f .machine_minutes.landing)" 2
# b) the candidate's own proof
check "b: the earliest covering tip's runs, rerun included, a later tip's verify left out" "$(f '[(.run_ids.verify | length), .proofs_per_candidate, .machine_minutes.verify]')" '[2,2,3]'
check "b: total is the sum of the three" "$(f .machine_minutes.total)" 11
check "b: install ids cover every home row of a descendant" "$(f '.run_ids.install | length')" 4
check "b: each home row binds waiver, verdict and previous version" "$(f '.homes[] | select(.home == "beta") | [.status, .waiver, .verdict, .previous]')" "[\"bootstrap-start\",\"owner-rule-x\",\"green\",\"${A:0:12}\"]"
# c) behaviour observations
check "c: a row's own behavior word is read" "$(f '.homes[] | select(.home == "gamma") | .behavior')" '"pass"'
check "c: an unobserved home is named in missing" "$(f '.missing | map(select(startswith("behavior:")))')" '["behavior:alpha","behavior:beta","behavior:delta"]'
JG_HOME=$H bash "$BIN" observe tk1 alpha "${B}" pass "the new check ran"
JG_HOME=$H bash "$BIN" observe tk1 beta "${B:0:12}" fail "the switch stayed off"
JG_HOME=$H bash "$BIN" observe tk1 beta "${B:0:12}" pass "the switch is on"
check "c: an observation binds to its home and version" "$(f '.homes[] | select(.home == "alpha") | [.behavior, .seen]')" '["pass","the new check ran"]'
check "c: the latest observation of a home wins" "$(f '.homes[] | select(.home == "beta") | [.behavior, .seen]')" '["pass","the switch is on"]'
check "c: observed homes leave missing" "$(f '.missing | map(select(startswith("behavior:")))')" '["behavior:delta"]'
rc=0; JG_HOME=$H bash "$BIN" observe tk1 alpha "$B" maybe "x" 2>/dev/null || rc=$?
check "c: a verdict other than pass or fail is refused" "$rc" 64
# d) pin-back after the live moment
mk_times "$(iso $((T + 4500)))" "$(iso $((T + 4800)))"
check "d: an undone live moment gives way to the first live install row" "$(f .in_use_at)" "$((T + 4500))"
mk_times "" ""
check "d: no live moment and a live row still dates in use" "$(f .in_use_at)" "$((T + 4500))"
mk_times "$(iso $((T + 4500)))" ""
# e) model turns
check "e: no turns recorded is named, never zero" "$(f '[.model_turns, (.missing | index("model_turns") != null)]')" '[null,true]'
WT=/work/tree.x ACC=$d/account
mkdir -p "$ACC/projects/-work-tree-x"
printf 'window=w\nticket=tk1\nharness=claude\nworktree=%s\naccount=%s\n' "$WT" "$ACC" > "$H/state/tk1.meta"
printf '%s\tclaude\tm\thigh\n' "$((T + 600))" > "$H/state/tk1.models"
tr=$ACC/projects/-work-tree-x
printf '%s\n' '{"type":"assistant","message":{"id":"m1"}}' '{"type":"assistant","message":{"id":"m1"}}' '{"type":"user"}' \
  '{"type":"assistant","message":{"id":"m2"}}' '{"type":"assistant","message":{"id":"m3"}}' > "$tr/new.jsonl"
printf '%s\n' '{"type":"assistant","message":{"id":"old1"}}' > "$tr/old.jsonl"
touch -d "@$((T + 100))" "$tr/old.jsonl"   # a session before the spawn belongs to an earlier task of the slot
JG_HOME=$H bash "$BIN" turns tk1
check "e: distinct responses since spawn are counted" "$(f .model_turns)" 3
check "e: turns leave missing" "$(f '.missing | index("model_turns")')" null
printf 'window=w\nticket=tk1\nharness=codex\n' > "$H/state/tk2.meta"
rc=0; JG_HOME=$H bash "$BIN" turns tk2 2>"$d/err2" || rc=$?
check "e: another harness is named unrecorded and writes nothing" "$rc:$(grep -c . "$H/data/ask-turns.tsv"):$(grep -c unrecorded "$d/err2")" "1:1:1"
# f) refusals
rc=0; show nope >/dev/null 2>"$d/err3" || rc=$?
check "f: an ask with no moments is refused" "$rc" 1
rc=0; bash "$BIN" show 2>/dev/null || rc=$?
check "f: a usage error exits 64" "$rc" 64

[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say "all ask-record checks passed"
