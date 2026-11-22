#!/usr/bin/env bash
# A dispatch check advances a workflow and dispatches its freshly approved step in the same pass.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home=$(jg_test_tmproot jg-auto-dispatch-workflow) || fail 'could not create a fixture home'
export JG_HOME=$home JG_CONFIG_OVERRIDE=$home/config JG_STATE_OVERRIDE=$home/state JG_DATA_OVERRIDE=$home/data
jg_test_beads_home "$home"
mkdir -p "$home/bin" "$home/state"
printf -- '- demo [local-trunk] - fixture project (added 2026-11-01)\n' > "$home/data/projects.md"
printf 'on\n' > "$home/config/auto-dispatch"
printf '2\n' > "$home/config/lane-target"
: > "$home/state/.last-watcher-beat"
# Run the repository command from its own path so it finds its workflow modules.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/bin/jg-workflow.sh" > "$home/bin/jg-workflow.sh"
chmod +x "$home/bin/jg-workflow.sh"

export JG_AUTO_DISPATCH_BACKLOG=$ROOT/bin/jg-backlog.sh JG_AUTO_DISPATCH_PROJECT_MODE=$ROOT/bin/jg-project-mode.sh
export JG_AUTO_DISPATCH_HOLD=$home/hold JG_AUTO_DISPATCH_SPAWN=$home/spawn JG_WORKFLOW_BACKLOG=$home/approve
printf '#!/bin/sh\nprintf "blocking-batch: ok\\n"\n' > "$home/hold"
cat > "$home/spawn" <<'SH'
#!/bin/sh
printf 'kind=ship\n' > "$JG_HOME/state/$1.meta"
SH
cat > "$home/approve" <<'SH'
#!/bin/sh
# Give dispatch time to miss the approval if advance returns immediately.
sleep 2
exec "$JG_AUTO_DISPATCH_BACKLOG" "$@"
SH
chmod +x "$home/hold" "$home/spawn" "$home/approve"

check() { timeout 25 bash "$ROOT/core/auto-dispatch/dispatch.sh" check "$home"; }
bd() { python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@"; }
started() { # <ticket row>: the check claimed a spawn and the stand-in published the lane
  local row=$1 i lane=$home/state/${1//./-}.meta
  assert_present "$home/data/auto-dispatch/$row.start.1" "dispatch claimed $row in this pass"
  for ((i = 0; i < 80; i++)); do [ ! -s "$lane" ] || return 0; sleep 0.1; done
  fail "the spawn did not publish a lane for $row"
}

jg_test_add "$home" jg-t1 '[feature] Workflow fixture' --body 'Owner order: Main1. Workflow fixture.'
"$home/bin/jg-workflow.sh" set jg-t1 'worker > worker' --by main --order Main1 >/dev/null || fail 'could not set the workflow'
rows=$(bd list --parent jg-t1 --all --limit 0 --json) || fail 'could not read the workflow steps'
first=$(jq -er '.[] | select(.metadata.wf_stage == "1").id' <<< "$rows") || fail 'missing step 1'
second=$(jq -er '.[] | select(.metadata.wf_stage == "2").id' <<< "$rows") || fail 'missing step 2'

# No dispatch kick shim is installed here. Only this check can claim the spawn.
out=$(check 2>&1) || fail "T1 first check failed: $out"
started "$first"
assert_not_contains "$out" "started $first" 'T1 advance output stays quiet'
assert_absent "$home/state/${second//./-}.meta" 'T1 the second worker still waits'
pass 'T1 one dispatch check starts the first worker'

printf '%s\tdemo\tcommit\t1\n' "${first//./-}" > "$home/data/trunk-landings.tsv"
out=$(check 2>&1) || fail "T2 landing check failed: $out"
assert_equals closed "$(bd show "$first" --json | jq -r '.[0].status')" 'T2 the landing closes the first step'
assert_not_contains "$out" "closed $first" 'T2 advance output stays quiet'
started "$second"
pass 'T2 a landing closes the first step and dispatch starts the second in the same pass'

jg_test_add "$home" jg-plain '[feature] Plain dispatch fixture'
"$JG_AUTO_DISPATCH_BACKLOG" approve-dispatch jg-plain --harness claude --model sonnet --effort medium >/dev/null || fail 'could not approve the plain ticket'
mkdir -p "$home/data/jg-plain"
printf 'Delivery contract: mode=local-trunk\n' > "$home/data/jg-plain/brief.md"
printf '3\n' > "$home/config/lane-target"
cat > "$home/bin/jg-workflow.sh" <<'SH'
#!/bin/sh
printf 'advance entered\n' > "$JG_HOME/advance-entered"
exec sleep 60
SH
out=$(check 2>&1) || fail "T3 dispatch did not finish within 25 seconds: $out"
assert_present "$home/advance-entered" 'T3 the slow advance ran'
started jg-plain
pass 'T3 a slow advance times out and dispatch still starts an approved ticket'
