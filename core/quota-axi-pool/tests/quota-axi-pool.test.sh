#!/usr/bin/env bash
# Multi-account: workers A=70%/B=40%, Main's own login reserved at 5%; quota-axi --json, the quota wake and the dashboard agree.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
wrap=$addons/quota-axi-pool/bin/quota-axi-pool
helper=$addons/account-pool/bin/jg-model-pool
pool=$addons/claude-accounts/bin/claude-accounts-pick
w=$(mktemp -d "${TMPDIR:-/tmp}/quota-axi-pool-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/config" "$w/home/state" "$w/a" "$w/b" "$w/pool" "$w/bin" "$w/log"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
row_pct() { jq -r --arg p "$2" --arg k "$3" '[.providers[]|select(.provider==$p and (.accountKey // "default")==$k)|.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining]|first' <<<"$1"; }

cat >"$w/bin/quota-axi-real" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  --version|-v) printf 'quota-axi 0.1.54 (stub)\n'; exit 0 ;;
  --json) printf '%s\n' '{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"five_hour","percentRemaining":11},{"id":"seven_day","percentRemaining":11}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":11,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["seven_day"],"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":0.11}}]}},{"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"weekly","percentRemaining":50}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":0.5}}]}}]}'; exit 0 ;;
esac; done; exit 2
SH
chmod +x "$w/bin/quota-axi-real"
cat >"$w/bin/pool-cmd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$w/log/pool-cmd.log"
exec env JG_HOME="$w/home" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" JG_CLAUDE_ACCOUNTS_FRESH=999999 \
  JG_ACCOUNT_POOL_REST_FLOOR=15 JG_MODEL_POOL_FLOOR=15 "$pool" "\$@"
SH
chmod +x "$w/bin/pool-cmd"
for name in claude codex cursor opencode pi; do
  printf '#!/bin/sh\necho blocked:%s >&2; exit 97\n' "$name" >"$w/bin/$name"; chmod +x "$w/bin/$name"
done
printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/bin/pool-cmd" >"$w/home/config/account-pool"
cat >"$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"$w/a"},
 {"id":"pa_umer_b","provider":"claude","name":"Umer B","folder":"$w/b"}]}
R
reading() {
  local now; now=$(date +%s)
  jq -n --argjson at "$now" --arg a pa_umer_a --arg b pa_umer_b --arg fa "$w/a" --arg fb "$w/b" \
    --argjson h1 "$1" --argjson d1 "$2" --argjson h2 "$3" --argjson d2 "$4" \
    '{schema:1,generated_at:$at,accounts:[
      {id:$a,name:"Umer A",folder:$fa,five_hour:{left:$h1},seven_day:{left:$d1,resets_at:"2030-01-02T00:00:00Z"},read_at:$at,problem:null},
      {id:$b,name:"Umer B",folder:$fb,five_hour:{left:$h2},seven_day:{left:$d2,resets_at:"2030-01-02T00:00:00Z"},read_at:$at,problem:null}]}' \
    >"$w/pool/claude-accounts.json"
  cp "$w/pool/claude-accounts.json" "$w/home/state/claude-accounts.json"
}
run_json() {
  out=$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" JG_HOME="$w/home" \
    JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" JG_MODEL_POOL="$helper" \
    JG_MODEL_POOL_FLOOR=15 JG_ACCOUNT_POOL_REST_FLOOR=15 JG_CLAUDE_ACCOUNTS_LOW=5 \
    JG_CLAUDE_ACCOUNTS_FRESH=999999 JG_QUOTA_AXI_REAL="$w/bin/quota-axi-real" \
    JG_QUOTA_AXI_POOL_ATTEMPTED="${1:-[]}" "$wrap" --json 2>"$w/err"); rc=$?
}

# Multi-account journey: Main's own login (found, 5% left) is reserved; workers A=70 and B=40 hold the room.
# One view feeds dispatch (this wrapper), the quota wake, and the dashboard.
reading 70 70 40 40
jq '.accounts += [{id:"found-main",name:"default",folder:"main",five_hour:{left:5},seven_day:{left:5,resets_at:"2030-01-02T00:00:00Z"},read_at:.generated_at,problem:null}]' \
  "$w/pool/claude-accounts.json" >"$w/x" && mv "$w/x" "$w/home/state/claude-accounts.json"
jq '.accounts += [{id:"found-main",name:"",provider:"claude",folder:"main",found:true}]' "$w/registry.json" >"$w/x" && mv "$w/x" "$w/registry.json"
run_json '[]'
is "exit 0" "$rc" 0
is "schema 6" "$(jq -r .schemaVersion <<<"$out")" 6
is "Claude default row is the best worker A=70, not ambient 11" "$(row_pct "$out" claude default)" 70
is "worker B row" "$(row_pct "$out" claude pa_umer_b)" 40
is "Main's login shown apart, reserved" "$(jq -r '[.providers[]|select(.provider=="claude" and .accountKey=="main")|"\(.account.reserved):\(.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)"]|first' <<<"$out")" true:5
is "codex passthrough" "$(row_pct "$out" codex default)" 50
# shellcheck source=../../../bin/jg-quota-axi-lib.sh disable=SC1091
. "$addons/../bin/jg-quota-axi-lib.sh"
jg_quota_json_valid <<<"$out" && echo "ok - snapshot valid for dispatch" || { echo "not ok - snapshot valid for dispatch"; fails=$((fails + 1)); }
is "dispatch binds a Claude candidate to A=70" "$(jq -r "$JG_QUOTA_ROW_JQ"'quota_row(.; "claude"; "")|.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining' <<<"$out")" 70
# The quota wake's own classifier, taken from its script so the test cannot drift from it.
# shellcheck disable=SC1090
. <(sed -n '/^condition_status()/,/^}/p' "$addons/../bin/jg-procevent-quota.sh")
export DEFAULT_THRESHOLD=20
is "quota wake: Claude healthy while a worker has room" "$(condition_status "$out" claude)" healthy
lookout=$(JG_HOME="$w/home" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" python3 -c '
import importlib.machinery as m, json, sys
mod = m.SourceFileLoader("l", sys.argv[1]).load_module()
print(json.dumps(mod.quota_doc(sys.argv[2])))' "$addons/lookout-adapter/lookout-juggernaut" "$w/home")
is "dashboard lists A, B and reserved Main" "$(jq -r '[.[].account]|unique|join(",")' <<<"$lookout")" "Umer A (pa_umer_a),Umer B (pa_umer_b),default (Main, reserved)"
reading 0 0 0 0
run_json '[]'
is "all workers drained: Claude default reads exhausted, not ambient" "$(jq -r '[.providers[]|select(.provider=="claude" and .accountKey=="default")|.quotaSemantics.effectiveAvailability[0].runway.status]|first' <<<"$out")" exhausted_now
is "quota wake: Claude exhausted when no worker has room" "$(condition_status "$out" claude)" exhausted
rm -f "$w/home/state/claude-accounts.json" "$w/pool/claude-accounts.json" "$w/registry.json" "$w/home/config/account-pool"
run_json '[]'
is "no registered accounts and no pool: ambient 11" "$(row_pct "$out" claude default)" 11
ver=$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" JG_QUOTA_AXI_REAL="$w/bin/quota-axi-real" "$wrap" --version 2>/dev/null) || true
is "version passthrough" "$ver" "quota-axi 0.1.54 (stub)"

# Install/uninstall: temp HOME only; fake upstream symlink; never touch real ~/.local/bin.
inst=$addons/quota-axi-pool/wiring.sh
uninst=$addons/quota-axi-pool/unwiring.sh
ih=$(mktemp -d "${TMPDIR:-/tmp}/quota-axi-pool-install.XXXXXX") || exit 1
mkdir -p "$ih/.local/bin" "$ih/real"
printf '#!/bin/sh\nprintf upstream-ok\n' >"$ih/real/quota-axi"
chmod +x "$ih/real/quota-axi"
ln -s "$ih/real/quota-axi" "$ih/.local/bin/quota-axi"
orig_target=$(readlink -- "$ih/.local/bin/quota-axi")
orig_resolved=$(readlink -f "$ih/.local/bin/quota-axi")
# Refuse when no upstream (empty HOME bin, no PATH hit).
empty=$(mktemp -d "${TMPDIR:-/tmp}/quota-axi-pool-empty.XXXXXX") || exit 1
mkdir -p "$empty/.local/bin"
refuse_rc=0
env -i PATH="$empty/.local/bin:/usr/bin:/bin" HOME="$empty" XDG_DATA_HOME="$empty/.local/share" \
  bash "$inst" >"$empty/out" 2>"$empty/err" || refuse_rc=$?
is "refuse install without upstream exit nonzero" "$refuse_rc" 1
is "refuse left link absent" "$( [ -e "$empty/.local/bin/quota-axi" ] && echo yes || echo no )" no
is "refuse wrote no share dir" "$( [ -d "$empty/.local/share/jg-quota-axi-pool" ] && echo yes || echo no )" no
grep -q 'no upstream quota-axi found' "$empty/err" && echo "ok - refuse message" || { echo "not ok - refuse message"; fails=$((fails + 1)); }
# Install over existing foreign symlink: record resolved upstream + original link target.
inst_rc=0
env -i PATH="$ih/.local/bin:/usr/bin:/bin" HOME="$ih" XDG_DATA_HOME="$ih/.local/share" \
  bash "$inst" >"$ih/install.out" 2>"$ih/install.err" || inst_rc=$?
is "install over foreign link exit 0" "$inst_rc" 0
is "upstream recorded resolved" "$(head -n 1 "$ih/.local/share/jg-quota-axi-pool/upstream")" "$orig_resolved"
is "link-target recorded original" "$(head -n 1 "$ih/.local/share/jg-quota-axi-pool/link-target")" "$orig_target"
is "link now our wrapper" "$(readlink -f "$ih/.local/bin/quota-axi")" \
  "$(readlink -f "$ih/.local/share/jg-quota-axi-pool/quota-axi-pool")"
# Idempotent re-install keeps recorded upstream.
saved_up=$(head -n 1 "$ih/.local/share/jg-quota-axi-pool/upstream")
saved_lt=$(head -n 1 "$ih/.local/share/jg-quota-axi-pool/link-target")
env -i PATH="$ih/.local/bin:/usr/bin:/bin" HOME="$ih" XDG_DATA_HOME="$ih/.local/share" \
  bash "$inst" >"$ih/reinstall.out" 2>"$ih/reinstall.err" || inst_rc=$?
is "reinstall exit 0" "$inst_rc" 0
is "reinstall kept upstream" "$(head -n 1 "$ih/.local/share/jg-quota-axi-pool/upstream")" "$saved_up"
is "reinstall kept link-target" "$(head -n 1 "$ih/.local/share/jg-quota-axi-pool/link-target")" "$saved_lt"
# Wrapper finds recorded upstream (no JG_QUOTA_AXI_REAL).
wrap_out=$(env -i PATH="$ih/.local/bin:/usr/bin:/bin" HOME="$ih" XDG_DATA_HOME="$ih/.local/share" \
  quota-axi 2>"$ih/wrap.err") || true
is "wrapper runs recorded upstream" "$wrap_out" upstream-ok
# Uninstall restores original link.
env -i PATH="$ih/.local/bin:/usr/bin:/bin" HOME="$ih" XDG_DATA_HOME="$ih/.local/share" \
  bash "$uninst" >"$ih/uninstall.out" 2>"$ih/uninstall.err" || true
is "uninstall restored link target" "$(readlink -- "$ih/.local/bin/quota-axi")" "$orig_target"
is "uninstall restored resolved" "$(readlink -f "$ih/.local/bin/quota-axi")" "$orig_resolved"
is "uninstall removed share dir" "$( [ -d "$ih/.local/share/jg-quota-axi-pool" ] && echo yes || echo no )" no
rm -rf -- "$ih" "$empty"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails assertions"; exit 1; }
echo "PASS: quota-axi-pool forced-limit and install journeys"
exit 0
