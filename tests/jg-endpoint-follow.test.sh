#!/usr/bin/env bash
# tests/jg-endpoint-follow.test.sh - a task record follows its worker when a muxr
# account move replaces the worker's Herdr pane (bin/jg-endpoint-follow-lib.sh,
# called by bin/jg-crew-state.sh).
#
# Journey: a ship's record names pane w1:p1. muxr opens the same conversation in
# a new pane w1:p4 of the same tab and closes w1:p1. Before the follow, crew-state
# read "backend target gone" for a running worker and the fleet had to hand-edit
# window=. These cases run the real crew-state over a fake Herdr world (a JSON file
# of panes) and a fake muxr, and pin each rule the library states:
#   (a) the worker is found again by agent name AND worktree: the record's window,
#       workspace, tab and pane lines move, a pool account= follows muxr, every
#       other line is byte-identical, and crew-state reads working
#   (b) a worker that is really gone still reads gone, record untouched
#   (c) a same-named agent in another folder, two candidates, a candidate already
#       owned by another task, and a candidate that holds only a shell are no move
#   (d) a live recorded pane is never moved off
#   (e) a pinned account (ordinary or a path), an absent account line and a failing muxr leave
#       account= alone while the pane still follows
#   (f) a snapshot copy of the record is never repaired, and a second read is a no-op
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "ok - jg-endpoint-follow skipped without jq"; exit 0; }

CREW_STATE="$ROOT/bin/jg-crew-state.sh"
TMP_ROOT=$(jg_test_tmproot jg-endpoint-follow)
fakebin=$(jg_fakebin "$TMP_ROOT")
PATH="$fakebin:$PATH"

# A fake herdr over $FAKE_WORLD: {"panes": [{pane_id, tab_id, workspace_id, cwd,
# name, agent_status, process}]}. process is agent (default) or shell. It answers
# the reads crew-state and the follow make, and fails a pane that is not in the
# world with the real client's pane_not_found.
cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then shift 2; continue; fi
  args+=("$1"); shift
done
set -- "${args[@]}"
world=$FAKE_WORLD
pane_json() { jq -c --arg p "$1" '.panes[] | select(.pane_id == $p)' "$world"; }
not_found() { printf '{"error":{"code":"%s","message":"not found"},"id":"fake"}\n' "$1"; exit 1; }
case "${1:-}:${2:-}" in
  status:--json)
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  pane:get)
    p=$(pane_json "$3"); [ -n "$p" ] || not_found pane_not_found
    jq -c '{id:"fake",result:{type:"pane_info",pane:{pane_id,tab_id,workspace_id,cwd,foreground_cwd:(.foreground_cwd // .cwd)}}}' <<<"$p" ;;
  agent:get)
    p=$(pane_json "$3"); [ -n "$p" ] || not_found agent_not_found
    jq -c '{id:"fake",result:{type:"agent_info",agent:{pane_id,tab_id,workspace_id,name,agent_status}}}' <<<"$p" ;;
  agent:list)
    jq -c '{id:"fake",result:{type:"agent_list",agents:[.panes[] | {pane_id,tab_id,workspace_id,cwd,foreground_cwd:(.foreground_cwd // .cwd),name,agent_status}]}}' "$world" ;;
  pane:read)
    p=$(pane_json "$3"); [ -n "$p" ] || exit 1
    if [ "$(jq -r .agent_status <<<"$p")" = working ]; then printf 'work in progress\nesc to interrupt\n'; else printf 'all quiet\n> \n'; fi ;;
  pane:process-info)
    pane=""; for ((i=1; i<=$#; i++)); do [ "${!i}" = --pane ] && { j=$((i+1)); pane=${!j}; }; done
    p=$(pane_json "$pane"); [ -n "$p" ] || not_found pane_not_found
    if [ "$(jq -r '.process // "agent"' <<<"$p")" = shell ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "$PPID" "$PPID" "$PPID"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$pane" "$PPID"
    fi ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fakebin/herdr"

# A fake muxr: `muxr pane account --pane P --json` answers the account the world
# gives for P, or fails while FAKE_MUXR_FAIL is set.
cat > "$fakebin/muxr" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_MUXR_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}:${2:-}" = pane:account ] || exit 2
pane=$4
jq -c --arg p "$pane" --arg a "${FAKE_MUXR_ACCOUNT:-found-claude}" '{pane:$p,account:{id:$a,name:"x"}}' -n
SH
chmod +x "$fakebin/muxr"

# A fake tmux that reports nothing, so no tmux read can answer for a herdr task.
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fakebin/tmux"

ID=follow-case
world() { # <case-dir> <json panes array>
  printf '{"panes": %s}\n' "$2" > "$1/world.json"
}
pane_row() { # <pane> <name> <cwd> [<status> [<process>]]
  jq -c -n --arg p "$1" --arg n "$2" --arg c "$3" --arg s "${4:-working}" --arg pr "${5:-agent}" \
    '{pane_id:$p, tab_id:"w1:t1", workspace_id:"w1", cwd:$c, name:$n, agent_status:$s, process:$pr}'
}
new_case() { # <name> [<account line>]: a case dir with a record on the gone pane w1:p1
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/wt"
  jg_write_meta "$d/state/$ID.meta" \
    "window=default:w1:p1" "endpoint_task_id=$ID" "worktree=$d/wt" "project=$d/wt" \
    "harness=claude" "kind=scout" "mode=direct-PR" "model=default" "effort=default" \
    ${2:+"$2"} "spawn_gen=s1" "backend=herdr" "herdr_session=default" \
    "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1"
  printf '%s\n' "$d"
}
read_state() { # <case-dir> [extra env...]: the one-line crew-state answer
  local d=$1
  shift
  env "$@" FAKE_WORLD="$d/world.json" JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" "$CREW_STATE" "$ID" 2>/dev/null
}
meta_of() { cat "$1/state/$ID.meta"; }

# --- (a) the follow ---------------------------------------------------------
d=$(new_case moved "account=pa_cognify")
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt")]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_contains "$out" "state: working" "the moved worker reads working through its new pane"
assert_not_contains "$out" "backend target gone" "a followed worker is not reported gone"
after=$(meta_of "$d")
assert_contains "$after" "window=default:w1:p4" "window= names the new pane"
assert_contains "$after" "herdr_pane_id=w1:p4" "the pane id follows"
assert_contains "$after" "herdr_tab_id=w1:t1" "the tab id is the new pane's own"
assert_contains "$after" "herdr_workspace_id=w1" "the workspace id is the new pane's own"
assert_contains "$after" "account=found-claude" "a pool account follows what muxr reports"
assert_equals "$(printf '%s\n' "$before" | grep -v -E '^(window|herdr_pane_id|account)=')" \
  "$(printf '%s\n' "$after" | grep -v -E '^(window|herdr_pane_id|account)=')" \
  "every other line of the record is unchanged"
assert_equals 16 "$(printf '%s\n' "$after" | wc -l | tr -d ' ')" "no line was added or dropped"
ls "$d/state"/.*follow* >/dev/null 2>&1 && fail "a staging file was left behind"
ls "$d/state"/.meta-*.lock >/dev/null 2>&1 && fail "the record lock was left behind"
again=$(read_state "$d")
assert_equals "$out" "$again" "a second read answers the same"
assert_equals "$after" "$(meta_of "$d")" "a second read writes nothing"
pass "a worker moved by muxr is followed: pane lines and pool account rebound, the rest untouched"

# --- (b) a worker that is really gone ---------------------------------------
d=$(new_case dead)
world "$d" "[$(pane_row w1:p9 someone-else "$d/wt")]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_contains "$out" "backend target gone" "a worker with no agent anywhere still reads gone"
assert_equals "$before" "$(meta_of "$d")" "its record is untouched"
world "$d" "[]"
out=$(read_state "$d")
assert_contains "$out" "backend target gone" "an empty session reads gone"
assert_equals "$before" "$(meta_of "$d")" "its record is still untouched"
pass "a truly dead worker still reads dead and its record is not rewritten"

# --- (c) not a move ---------------------------------------------------------
d=$(new_case other-folder)
world "$d" "[$(pane_row w1:p4 "$ID" "$TMP_ROOT/elsewhere")]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_contains "$out" "backend target gone" "the right name in the wrong folder is not this worker"
assert_equals "$before" "$(meta_of "$d")" "the record is untouched"

d=$(new_case two-candidates)
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt"),$(pane_row w1:p5 "$ID" "$d/wt/sub")]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_contains "$out" "backend target gone" "two candidates are ambiguous, so nothing is followed"
assert_equals "$before" "$(meta_of "$d")" "the record is untouched"

d=$(new_case owned-by-other)
jg_write_meta "$d/state/other-task.meta" "window=default:w1:p4" "endpoint_task_id=other-task" \
  "worktree=$TMP_ROOT/o" "project=$TMP_ROOT/o" "harness=claude" "kind=scout" "backend=herdr" \
  "herdr_session=default" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p4"
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt")]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_contains "$out" "backend target gone" "a pane another task record owns is never taken"
assert_equals "$before" "$(meta_of "$d")" "the record is untouched"

d=$(new_case shell-only)
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt" idle shell)]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_not_contains "$out" "state: working" "a candidate that holds only a shell is not a live worker"
assert_equals "$before" "$(meta_of "$d")" "the record is untouched"
pass "a same-name other folder, two candidates, an owned pane and a shell-only pane are not followed"

# --- (d) a live recorded pane is never moved off ----------------------------
d=$(new_case live-recorded)
world "$d" "[$(pane_row w1:p1 "$ID" "$d/wt"),$(pane_row w1:p4 "$ID-twin" "$d/wt")]"
before=$(meta_of "$d")
out=$(read_state "$d")
assert_contains "$out" "state: working" "the recorded pane still answers for the worker"
assert_equals "$before" "$(meta_of "$d")" "the record of a live pane is untouched"
pass "a record whose pane is alive is never rebound"

# --- (e) account lines ------------------------------------------------------
for pinned in "account=ordinary" "account=/home/x/.claude-alt"; do
  d=$(new_case "pin-${pinned##*=}" "$pinned")
  world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt")]"
  out=$(read_state "$d")
  assert_contains "$out" "state: working" "the pane follows under $pinned"
  assert_contains "$(meta_of "$d")" "$pinned" "$pinned is the home's pin declaration and is kept"
  assert_contains "$(meta_of "$d")" "window=default:w1:p4" "the pane still follows under $pinned"
done
d=$(new_case no-account-line)
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt")]"
out=$(read_state "$d")
assert_not_contains "$(meta_of "$d")" "account=" "an absent account line stays absent"
assert_contains "$(meta_of "$d")" "window=default:w1:p4" "and the pane follows"
d=$(new_case muxr-fails "account=pa_cognify")
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt")]"
out=$(read_state "$d" FAKE_MUXR_FAIL=1)
assert_contains "$(meta_of "$d")" "account=pa_cognify" "a muxr that fails leaves account= as it was"
assert_contains "$(meta_of "$d")" "window=default:w1:p4" "and the pane still follows"
pass "a pin declaration, an absent line and a failing muxr never block the pane repair"

# --- (f) a snapshot copy is not repaired ------------------------------------
d=$(new_case snapshot)
world "$d" "[$(pane_row w1:p4 "$ID" "$d/wt")]"
before=$(meta_of "$d")
cp "$d/state/$ID.meta" "$d/snapshot.meta"
out=$(env FAKE_WORLD="$d/world.json" JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" \
  JG_CREW_STATE_META_OVERRIDE="$d/snapshot.meta" "$CREW_STATE" "$ID" 2>/dev/null)
assert_equals "$before" "$(meta_of "$d")" "a read of a snapshot copy does not rewrite the live record"
pass "a snapshot read never repairs the live record"

echo "all jg-endpoint-follow tests passed"
