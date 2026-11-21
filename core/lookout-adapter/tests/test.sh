#!/usr/bin/env bash
# Fixture-home test for lookout-juggernaut: builds a throwaway JG_HOME with the dashboard builder's output files, then checks the
# document (every list, no secret from a lane's .meta), the Lookout contract check when LOOKOUT_DIR holds a lookout clone, and the
# HTTP source. Usage: lookout-adapter/tests/test.sh
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# Integration: map durable fleet-flow output to Lookout's public adapter interface.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'kill "${srv:-}" "${fleet:-}" "${qs:-}" 2>/dev/null || true; rm -rf -- "$t"' EXIT
# An unused registry path inside the fixture: quota checks never consult installed account records.
export JG_CLAUDE_ACCOUNTS_REGISTRY="$t/unused-claude-accounts-registry"
mkdir -p "$t/home/state" "$t/home/data" "$t/alpha/state" "$t/alpha/data" "$t/proc"
now=$(date +%s)
printf 'MemTotal: 1000 kB\nMemAvailable: 400 kB\n' > "$t/proc/meminfo"
printf '0.50 0.4 0.3 1/2 3\n' > "$t/proc/loadavg"
printf '%s\n' "- alpha - Alpha (home: $t/alpha; scope: app)" > "$t/home/data/squad_leads.md"
printf 'kind=ship\nmodel=claude-haiku-5-5\nharness=claude\naccount=fixture\napi_key=SECRET\npr=https://github.com/o/r/pull/1\n' > "$t/alpha/state/a-one.meta"
printf 'kind=ship\nmodel=claude-haiku-5-5\nharness=claude\naccount=fixture\napi_key=SECRET\npr=https://github.com/o/r/pull/1\n' > "$t/home/state/a-one.meta"
printf 'working [at=%s]: building\n' "$((now-60))" > "$t/home/state/a-one.status"
printf '## Queued\n' > "$t/home/data/backlog.md"
printf 'kind=ship\npr=https://github.com/o/r/pull/2\n' > "$t/alpha/state/old.meta"
cat > "$t/flow.json" <<JSON
{"schema":"jg-flow.v1","at":$now,"homes":["main","alpha"],"lanes":[
 {"home":"alpha","task":"a-one","open":true,"stage":"working","kind":"ship","project":"alpha-app","reason":"building","seconds_in_stage":5,"open_waits":[{"reason":"building"}],"times":{"dispatched":$((now-60)),"working":$((now-50)),"merged":null}},
 {"home":"alpha","task":"old","open":false,"stage":"done","kind":"ship","project":"alpha-app","times":{"dispatched":$((now-7200)),"merged":$((now-3600))}}]}
JSON
printf '{"at":1,"services":{"bus":{"open":true,"since":%s,"cause":"the service is off"},"disk":{"open":false}}}\n' "$((now-300))" > "$t/home/state/health.json"
printf '{"service":"bus","start":%s,"end":%s,"cause":"the service is off"}\n{"service":"bus","start":%s,"end":%s,"cause":"the service is off"}\n{"service":"disk","start":%s,"end":%s,"cause":"old"}\n' \
  "$((now-7200))" "$((now-6900))" "$((now-4000))" "$((now-3700))" "$((now-9*86400))" "$((now-9*86400+60))" > "$t/home/state/outage-history.jsonl"
out="$t/fleet.json"
"$here/lookout-juggernaut" --home "$t/home" --proc "$t/proc" --flow-json "$t/flow.json" > "$out"
python3 - "$out" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert 'SECRET' not in raw
assert d['schema'] == 'lookout.fleet.v1'
assert [h['id'] for h in d['homes']] == ['main', 'alpha']
assert d['homes'][1]['name'] == 'Alpha'
lane = d['lanes'][0]
assert (lane['id'], lane['stage'], lane['project'], lane['waiting_on'], lane['pr_url']) == (
    'alpha/a-one', 'working', 'alpha-app', 'building', 'https://github.com/o/r/pull/1')
assert d['workers'][0]['model'] == 'claude-haiku-5-5'
inc = d['incidents']
assert [i['id'] for i in inc] == ['outage-open-bus', 'outage-7d-0'], inc
assert inc[0]['summary'] == 'Open outage, bus: the service is off' and 'resolved_at' not in inc[0]
assert inc[1]['summary'] == 'the service is off: 2 outages, 10 min in 7 days', inc[1]
assert d['merges'][0]['repo'] == 'o/r' and d['merges'][0]['lane'] == 'alpha/old'
PY
npx --yes lookout-axi@0.1.0 check --adapter "$out"
printf '\n' > "$t/home/data/squad_leads.md"
JG_HOME="$t/home" JG_BIN="$(cd "$here/../.." && pwd)/bin" LOOKOUT_PROC="$t/proc" "$here/lookout-juggernaut" > "$t/from-home.json"
npx --yes lookout-axi@0.1.0 check --adapter "$t/from-home.json"
python3 - "$t/from-home.json" <<'PY'
import json, sys
fleet = json.load(open(sys.argv[1]))
assert [lane['id'] for lane in fleet['lanes']] == ['main/a-one'], fleet['lanes']
assert fleet['lanes'][0]['stage'] == 'working'
assert 'SECRET' not in open(sys.argv[1]).read()
PY
"$here/lookout-juggernaut" --home "$t/home" --proc "$t/proc" --flow-json "$t/flow.json" --serve --port 0 > "$t/serve.log" & srv=$!
for _ in $(seq 50); do grep -q serving "$t/serve.log" && break; sleep 0.1; done
url=$(sed 's/.*serving //' "$t/serve.log")
curl -fsS "$url" > "$t/served.json"
npx --yes lookout-axi@0.1.0 check --adapter "$t/served.json"
[ "$(curl -s -o /dev/null -w '%{http_code}' "${url%fleet.json}nope")" = 404 ]
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
JG_HOME="$t/home" JG_BIN="$(cd "$here/../.." && pwd)/bin" LOOKOUT_PROC="$t/proc" \
  "$here/fleet-serve" --bind 127.0.0.1 --port "$port" > "$t/service.log" 2>&1 & fleet=$!
for _ in $(seq 100); do curl -fsS "http://127.0.0.1:$port/api/fleet" > "$t/service.json" && break; sleep 0.2; done
python3 - "$t/service.json" <<'PY'
import json, sys
fleet = json.load(open(sys.argv[1]))['fleet']
assert fleet['name'] == 'Juggernaut fleet' and len(fleet['lanes']) == 1, fleet
PY
# Changed-only refresh: a counting fixture quota view shows how many full builds ran; synthetic registry, owned loopback server.
mkdir -p "$t/q/state" "$t/q/data"; : > "$t/builds"
printf '%s\n' "- alpha - Alpha (home: $t/alpha; scope: app)" > "$t/q/data/squad_leads.md"
printf '{"event":"seed"}\n' | tee "$t/q/state/fleet-ledger.jsonl" > "$t/alpha/state/fleet-ledger.jsonl"
printf '#!/usr/bin/env bash\necho x >> "%s/builds"\necho "{\\"providers\\":{}}"\n' "$t" > "$t/qv.sh"
pr() { curl -fsS "$url" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lanes"][0]["pr_url"])'; }
builds() { wc -l < "$t/builds" | tr -d ' '; }
setpr() { local f="$t/alpha/state/a-one.meta"; sed "s#^pr=.*#pr=https://github.com/o/r/pull/$1#" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
JG_QUOTA_VIEW="$t/qv.sh" "$here/lookout-juggernaut" --home "$t/q" --proc "$t/proc" --flow-json "$t/flow.json" --serve --port 0 --every 1 --repair-every 5 > "$t/q.log" 2>&1 & qs=$!
for _ in $(seq 50); do grep -q serving "$t/q.log" && break; sleep 0.1; done
url=$(sed -n 's/.*serving //p' "$t/q.log" | head -1)
case "$url" in http://127.0.0.1:*) ;; *) echo "not loopback: $url"; exit 1 ;; esac
for _ in $(seq 50); do pr > /dev/null 2>&1 && break; sleep 0.1; done
[ "$(pr)" = https://github.com/o/r/pull/1 ]; first=$(builds)
[ "$first" = 1 ] || { echo "startup builds: want 1, got $first"; exit 1; }
sleep 2; [ "$(builds)" = "$first" ] || { echo "unchanged fleet rebuilt"; exit 1; }
setpr 9; printf '{"event":"pr","task":"a-one"}\n' >> "$t/alpha/state/fleet-ledger.jsonl"
for _ in $(seq 30); do [ "$(pr)" = https://github.com/o/r/pull/9 ] && break; sleep 0.1; done
[ "$(pr)" = https://github.com/o/r/pull/9 ] || { echo "ledger event not seen"; exit 1; }
evb=$(builds)
[ "$evb" = "$((first + 1))" ] || { echo "event builds: want $((first + 1)), got $evb"; exit 1; }
setpr 10; sleep 1.5
[ "$(pr)" = https://github.com/o/r/pull/9 ] && [ "$(builds)" = "$evb" ] || { echo "unlogged change seen before repair"; exit 1; }
for _ in $(seq 80); do [ "$(pr)" = https://github.com/o/r/pull/10 ] && break; sleep 0.1; done
[ "$(pr)" = https://github.com/o/r/pull/10 ] || { echo "repair did not pick up the change"; exit 1; }
rb=$(builds)
[ "$rb" = "$((evb + 1))" ] || { echo "repair builds: want $((evb + 1)), got $rb"; exit 1; }
sleep 1.5
[ "$(pr)" = https://github.com/o/r/pull/10 ] && [ "$(builds)" = "$rb" ] || { echo "idle response changed"; exit 1; }
echo "lookout changed-only refresh: builds first=$first event=$evb repair=$rb PASS"
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  printf '{"target":{"version":"lookout-juggernaut --serve"},"start":"a fixture home with a fleet ledger, a counting quota view and a loopback server run with --every 1 --repair-every 5","steps":["wait through ticks on an unchanged fleet","change the lane PR and append a ledger event","change the PR again with no ledger event","read the response while idle"],"result":"exactly one build at startup and none for the unchanged fleet, the ledger event shows the new PR before repair with exactly one more build, the unlogged change shows within the repair bound with exactly one more build, and the last good response is served while idle"}\n' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
fi
echo 'lookout-juggernaut: PASS'
