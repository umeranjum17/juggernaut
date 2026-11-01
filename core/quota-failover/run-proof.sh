#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
home=$tmp/home; stub=$tmp/bin
mkdir -p "$home/state" "$home/config" "$home/bin" "$stub"
cat >"$home/bin/jg-stub-lib.sh" <<'LIB'
jg_meta_get() { sed -n "s|^$2=||p" "$1" | tail -n 1; }
jg_backend_of_meta() { echo fixture; }
jg_backend_target_of_meta() { jg_meta_get "$1" endpoint_task_id; }
jg_backend_visible_capture() { [ ! -f "$JG_HOME/state/$2.screen" ] || cat "$JG_HOME/state/$2.screen"; return 0; }
jg_busy_classify_meta() { echo 'idle no-busy-record'; }
jg_busy_record_read() { echo ''; }
JG_QUOTA_ROW_JQ='def quota_lane($harness; $model): ""; def quota_row($snapshot; $provider; $lane): null;'
jg_quota_json_valid() { jq -e '.schemaVersion == 5 and (.providers | type) == "array"' >/dev/null 2>&1; }
jg_quota_single_provider_for_harness() { return 1; }
jg_parent_channel_report() { :; }
jg_run_timed() { shift; "$@"; }
LIB
for lib in jg-backend.sh jg-busy-lib.sh jg-quota-axi-lib.sh jg-parent-channel-lib.sh; do ln -s jg-stub-lib.sh "$home/bin/$lib"; done
cat >"$home/bin/jg-control.sh" <<'CONTROL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$JG_HOME/state/control.log"
CONTROL
cat >"$home/bin/jg-crew-state.sh" <<'CREW'
#!/usr/bin/env bash
echo 'state: working · source: fixture'
CREW
cat >"$stub/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
echo '{"schemaVersion":5,"providers":[]}'
QUOTA
cat >"$stub/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "${CLAUDE_LIMIT:-}" = yes ]; then echo "You've hit your usage limit for your plan; try again in 3h"; exit 1; fi
echo PONG
CLAUDE
chmod +x "$home/bin/jg-control.sh" "$home/bin/jg-crew-state.sh" "$stub/quota-axi" "$stub/claude"
cat >"$home/config/crew-dispatch.json" <<'DISPATCH'
{"rules":[],"default":[{"harness":"claude","model":"claude-haiku-5-5"}]}
DISPATCH
printf 'endpoint_task_id=cw\nharness=claude\nmodel=claude-haiku-5-5\nkind=operator\nspawn_gen=s0.cw\n' >"$home/state/cw.meta"
printf 'quota exhausted' >"$home/state/cw.screen"
: >"$home/state/quota-failover.log"
export PATH="$stub:$PATH" QUOTA_FAILOVER_TEST_SECS=1 QUOTA_FAILOVER_PROBE_SECS=0 QUOTA_FAILOVER_RETEST_SECS=0 QUOTA_FAILOVER_STALL_SECS=0
"$repo/quota-failover/quota-failover" "$home"
cp "$home/state/cw.screen" "$evidence/wrapper-text.txt"
cp "$home/config/crew-dispatch.json" "$evidence/after-wrapper.json"
if ! jq -e '.default[0].model == "claude-haiku-5-5"' "$home/config/crew-dispatch.json" >/dev/null; then echo 'wrapper text unexpectedly removed route' >&2; exit 1; fi
cp "$home/state/quota-failover.log" "$evidence/wrapper-log.txt"
: >"$home/state/quota-failover.log"
printf "%s\n" "You've hit your usage limit for your plan; try again in 3h" >"$home/state/cw.screen"
cp "$home/state/cw.screen" "$evidence/real-limit-banner.txt"
CLAUDE_LIMIT=yes "$repo/quota-failover/quota-failover" "$home"
cp "$home/config/crew-dispatch.json" "$evidence/after-limit-banner.json"
cp "$home/state/quota-failover-dead.json" "$evidence/dead-routes.json"
cp "$home/state/quota-failover.log" "$evidence/limit-log.txt"
jq -e '.default | length == 0' "$home/config/crew-dispatch.json" >/dev/null
jq -e 'any(.[]; .model == "claude-haiku-5-5")' "$home/state/quota-failover-dead.json" >/dev/null
jq -n --arg wrapperScreen "$(cat "$evidence/wrapper-text.txt")" --slurpfile wrapperDispatch "$evidence/after-wrapper.json" --rawfile wrapperLog "$evidence/wrapper-log.txt" --arg limitScreen "$(cat "$evidence/real-limit-banner.txt")" --slurpfile limitDispatch "$evidence/after-limit-banner.json" --slurpfile dead "$evidence/dead-routes.json" --rawfile limitLog "$evidence/limit-log.txt" '{wrapper_case:{screen:$wrapperScreen,dispatch:$wrapperDispatch[0],log:$wrapperLog,route_retained:($wrapperDispatch[0].default[0].model == "claude-haiku-5-5")},limit_case:{screen:$limitScreen,probe:{command:"claude -p --model claude-haiku-5-5",exit:1,output:"You\u0027ve hit your usage limit for your plan; try again in 3h"},dispatch:$limitDispatch[0],dead_routes:$dead[0],log:$limitLog,route_removed:(($limitDispatch[0].default|length)==0 and any($dead[0][]; .model=="claude-haiku-5-5"))}}' >"$evidence/result.json"
printf 'PASS: wrapper screen retained route; real limit banner plus confirming one-line probe removed route.\n'
