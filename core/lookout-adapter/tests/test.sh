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
trap 'kill "${srv:-}" "${fleet:-}" 2>/dev/null || true; rm -rf -- "$t"' EXIT
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
echo 'lookout-juggernaut: PASS'
