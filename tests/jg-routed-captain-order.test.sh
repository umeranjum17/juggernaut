#!/usr/bin/env bash
# Drive Main's filed order through the lead's brief, recovery and dispatcher.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot jg-routed-captain-order)
M=$T/main L=$T/lead
export HOME=$T/user TMPDIR=$T XDG_DATA_HOME=$T/xdg-data XDG_CONFIG_HOME=$T/xdg-config
export JG_SWARM_SEND=$T/send JG_ADDONS_DIR=$ROOT/core
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
for h in "$M" "$L"; do
  jg_test_beads_home "$h"
  mkdir -p "$h/state" "$h/projects/proj"
  ln -sn "$ROOT/bin" "$h/bin"
  ln -sn "$ROOT/toolchain.versions" "$h/toolchain.versions"
  printf -- '- proj [local-trunk +yolo] - fixture project (added 2026-11-19)\n' > "$h/data/projects.md"
done
printf 'lead1\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$M" > "$L/.jg-squad-lead-parent"
printf -- '- lead1 - fixture lead (home: %s; scope: tests; projects: proj; added 2026-11-19)\n' "$L" > "$M/data/squad_leads.md"
: > "$L/config/owner-rules"
printf 'kind=squad_lead\n' > "$M/state/lead1.meta"

cat > "$T/send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JG_HOME/sent"
SH
cat > "$T/spawn" <<'SH'
#!/usr/bin/env bash
printf 'kind=ship\n' > "$JG_HOME/state/$1.meta"
printf '%s\n' "$*" >> "$JG_HOME/spawned"
SH
printf '#!/usr/bin/env bash\nexport JG_AUTO_DISPATCH_SPAWN=%q JG_AUTO_DISPATCH_RESERVE=/bin/true\nexec bash %q check %q\n' \
  "$T/spawn" "$ROOT/core/auto-dispatch/dispatch.sh" "$L" > "$L/state/auto-dispatch.check.sh"
chmod +x "$T/send" "$T/spawn" "$L/state/auto-dispatch.check.sh"
run() { local home=$1; shift; JG_HOME="$home" "$@"; }
backlog() { local home=$1; shift; run "$home" "$ROOT/bin/jg-backlog.sh" "$@"; }
approve() { backlog "$L" approve-dispatch "$row" --harness codex --model fixture --effort low; }
tick() { run "$M" env JG_SWARM_NOW="$((at + $1))" "$ROOT/bin/jg-swarm-check.sh" check "$M"; }

printf 'fixture-session\n' > "$M/state/.lock-session"
run "$M" "$ROOT/bin/jg-inbox.sh" primary-chat fixture-session 1 "File the retry order." >/dev/null
filed=$(backlog "$M" add jg-ask "[captain-ask] File retry order" --body "File the retry order." --json)
assert_contains "$filed" 'approved-by-captain: note:primary-fixture-session-1 sig=' 'filing itself signs the ask'
order=$(backlog "$M" add --parent jg-ask "Prepare retry order" --priority 0 --json | jq -r '.task.id')
rm -f "$M/state/.lock-session"
note=$(printf '[chat telegram 42:101]\nFile another retry order.\n' |
  run "$M" "$ROOT/bin/jg-inbox.sh" note --request-id tg-42-101 --json - | jq -r .id)
filed=$(backlog "$M" add "[captain-ask] File another order" --body "File another retry order." --json)
assert_contains "$filed" "approved-by-captain: note:$note sig=" 'a newer gateway message signs a minted row'
pass "Main files a signed order before returning, with no additional approval call"

printf '# Retry order\n\n## Goal\n\nBuild the retry policy.\n\n## Acceptance\n\n1. true\n' > "$T/retry.md"
jq -n --arg order "$order" '{
  plan:"jg-plan", title:"Retry policy plan", report:"/fixture/retry.md", intent:"Build the retry policy.",
  owner_order:$order, prior_art:"Prior art: none needed - fixture work.",
  slices:[{id:"a", title:"Build retry policy", owner_home:"lead1", project:"proj",
    size:"S", risk:"Low", depends_on:[], files:["retry.sh (new)"], machine:null, order:"retry.md"}]}' > "$T/plan.json"
run "$M" "$ROOT/bin/jg-swarm.sh" start "$T/plan.json" --harness codex --model fixture --effort low --agents 1 --wait
plan=$M/data/swarm/jg-plan/plan.json
row=$(jq -r '.slices[0].row' "$plan")
task=$(jq -r '.slices[0].task' "$plan")
at=$(sed -n '2p' "$L/state/routed-orders/$task")
show=$(backlog "$L" show "$row" --full)
assert_contains "$show" "approved-by-captain: route:lead1:jg-ask sig=" 'the routed row carries its own approval'
assert_contains "$(run "$M" "$ROOT/bin/jg-swarm-check.sh" status)" '1 routed, 1 received, 0 started' 'Main sees receipt before a lane exists'
assert_contains "$(run "$L" "$ROOT/bin/jg-crew-state.sh" "$task" --read-only)" 'routed, received' 'lead sees receipt'

body=$(JG_HOME="$L" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" show "$row" --json | jq -r '.[0].description')
backlog "$L" update "$row" --body "$(sed '/^approved-by-captain:/d' <<< "$body")" >/dev/null
if out=$(approve 2>&1); then fail "the unsigned routed row passed approve-dispatch"; fi
assert_contains "$out" "bin/jg-plan-route.sh $plan" 'refusal tells Main how to repair'
if out=$(run "$L" "$ROOT/bin/jg-brief.sh" "$task" proj --mode local-trunk --ticket "$row" 2>&1); then
  fail "the unsigned routed row passed the lead brief gate"
fi
assert_contains "$out" "bin/jg-plan-route.sh $plan" 'brief refusal names the same repair'
run "$M" "$ROOT/bin/jg-plan-route.sh" "$plan"
run "$L" "$ROOT/bin/jg-backlog.sh" check-route "$row"
pass "The lead refuses missing proof and Main's reroute repairs it"

tick 599
assert_equals 1 "$(wc -l < "$M/sent")" 'nothing is sent before ten minutes'
tick 600
tick 601
assert_equals 2 "$(wc -l < "$M/sent")" 'the original order is re-sent once'
assert_contains "$(tail -1 "$M/sent")" 'no brief from the lead' 'resend names the missing fact'
alert=$(run "$L" "$ROOT/bin/jg-alert.sh" show fleet-blocked--routed-order-jg-plan)
assert_contains "$alert" 'rung=2' 'the alert reaches the lead'
assert_absent "$L/spawned" 'the automatic start waits twenty minutes'
pass "At ten minutes Main re-sends once and the lead receives an alert naming the missing brief"

out=$(tick 1200)
printf '%s\n' "$out"
assert_contains "$out" 'after 20 minutes' 'Main gets an escalation'
for ((i=0; i<200; i++)); do [ ! -s "$L/spawned" ] || break; sleep 0.1; done
assert_contains "$(cat "$L/spawned")" "--ticket $row" 'the dispatcher starts the approved row'
tick 1201
assert_equals 1 "$(wc -l < "$L/spawned")" 'the stub ran exactly once'
alert=$(run "$L" "$ROOT/bin/jg-alert.sh" show fleet-blocked--routed-order-jg-plan)
assert_contains "$alert" 'state=resolved' 'a started lane clears the alert'
assert_contains "$(run "$M" "$ROOT/bin/jg-swarm-check.sh" status)" '1 routed, 1 received, 1 started' 'swarm reports the start'
assert_contains "$(run "$L" "$ROOT/bin/jg-crew-state.sh" "$task" --read-only)" 'routed, received, started' 'crew state reports the start'
pass "At twenty minutes Main receives a notification and the approved row starts with no second yes"
