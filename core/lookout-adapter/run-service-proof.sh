#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# Live proof journey for the service, never applying it: fleet-serve on a spare loopback port against the real home,
# then curl for the fleet and retired routes plus wiring.sh's dry-run. No Lookout source clone is needed.
set -Eeuo pipefail
: "${JG_HOME:?}" "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
ev=$DONE_DONE_EVIDENCE_ROOT
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$here/fleet-serve" --port "$port" >"$ev/serve.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 100); do curl -fs "http://127.0.0.1:$port/api/fleet" -o "$ev/fleet.json" && break; sleep 0.3; done
{
  python3 -c 'import json; f = json.load(open("'"$ev"'/fleet.json"))["fleet"]; print("Lookout answers with", f["name"], "-", len(f["lanes"]), "lanes,", len(f["homes"]), "homes,", len(f["quota"]), "quota windows")'
  for r in tickets needs backlog measure overview; do curl -s -o /dev/null -w "/$r -> %{http_code} %{redirect_url}\n" "http://127.0.0.1:$port/$r"; done
  curl -s "http://127.0.0.1:$port/" | grep -o '<title>[^<]*'
} >"$ev/spare-port-check.txt"
export CHROME_DEVTOOLS_AXI_SESSION=lookout-service-proof-$$
chrome-devtools-axi open "http://127.0.0.1:$port/?theme=light#/overview" >/dev/null
chrome-devtools-axi resize 390 844 >/dev/null
chrome-devtools-axi wait updated >/dev/null; sleep 1
chrome-devtools-axi screenshot "$ev/spare-port-overview-390.png" >/dev/null
chrome-devtools-axi stop >/dev/null
"$here/wiring.sh" --dry-run >"$ev/install-dry-run.txt" 2>&1
python3 - "$(git -C "$here" rev-parse HEAD)" >"$ev/steps.json" <<'P'
import json, sys
print(json.dumps({'target': {'version': sys.argv[1]}, 'start': 'the real home, read only; no service installed',
  'steps': ['serve the Lookout command on a spare port', 'fetch the fleet and retired Tickets and Needs routes', 'print the install plan without applying it'],
  'result': 'the spare port serves the real fleet through Lookout, retired routes redirect to sign-off with no token, and the dry run prints the service replacement'}, indent=2))
P
