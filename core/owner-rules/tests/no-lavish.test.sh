#!/usr/bin/env bash
# Executable contract and publishing journey; optional argument selects an features checkout.
# Real sign-off-axi, private board and HOME; no server, model, or installed home is touched.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
addons=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
work=$(mktemp -d /var/tmp/owner-no-lavish.XXXXXX)
if [ "${JG_TEST_KEEP:-0}" != 1 ]; then trap 'rm -rf -- "$work"' EXIT; fi
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff JG_HOME=$work/home
export XDG_CONFIG_HOME=$work/config XDG_CACHE_HOME=$work/cache TMPDIR=$work/tmp
mkdir -p "$HOME" "$JG_HOME/config" "$JG_HOME/data/t/.done-done/runs" "$SIGN_OFF_HOME" "$TMPDIR"
checker=$addons/owner-rules/bin/jg-owner-rules-text-check.sh
status=$addons/status-wait-check/status-wait-check
refusal='use the sign-off board (sign-off-axi) instead'
fails=0
check() { # expected-exit, label, command...
  local expected=$1 label=$2 out rc=0; shift 2
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne "$expected" ] || { [ "$expected" -ne 0 ] && [[ $out != *"$refusal"* ]]; }; then
    printf 'not ok - %s: exit %s, output %s\n' "$label" "$rc" "$out"
    fails=$((fails + 1))
  else printf 'ok - %s\n' "$label"; fi
}
text_check() { printf '%s\n' "$1" | bash "$checker"; }
check 1 'checker refuses publish command' text_check 'lavish-axi review.html'
check 1 'checker refuses publish verb' text_check 'lavish-axi publish board'
check 1 'checker refuses publish after separator' text_check 'cd x && lavish-axi .lavish/board.htm'
check 0 'checker accepts bare package name' text_check 'Installed package lavish-axi 0.4'
check 0 'checker accepts non-publish subcommand' text_check 'lavish-axi poll'
check 1 'checker refuses Lavish session URL' text_check 'http://review.example:4387/session/umer'
check 1 'checker refuses IPv6 HTTPS URL' text_check 'https://[::1]:4387/session/umer'
check 0 'checker accepts sign-off URL' text_check 'http://review.example:4388/board/umer'
check 0 'checker accepts unrelated port and prose' text_check 'Lavish was retired; http://review.example:43870/session/umer'
check 0 'checker accepts empty text' text_check ''

check 0 'uninstalled note keeps previous behavior' "$status" working 'lavish-axi review.html'
bash "$addons/owner-rules/wiring.sh" "$JG_HOME" >/dev/null
check 1 'working note refuses Lavish URL' "$status" working 'http://review.example:4387/session/umer'
check 1 'done note refuses publish command' "$status" 'done' 'lavish-axi review.html'
check 0 'done note accepts bare package name' "$status" 'done' 'Installed package lavish-axi 0.4'
check 0 'squad_lead note accepts sign-off URL' "$status" 'done' 'http://review.example:4388/board/umer'
wait_refused() {
  local out
  out=$("$status" blocked 'waiting on CI' 2>&1) && return 1
  [[ $out == *'use paused:'* ]]
}
check 0 'existing blocked wait refusal is preserved' wait_refused

if [ -n "${JG_TEST_FORK:-}" ]; then
  mkdir -p "$work/parent/state"
  printf 'umer\n' > "$JG_HOME/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$work/parent" > "$JG_HOME/.jg-squad-lead-parent"
  export JG_ADDONS_DIR=$addons
  report=$JG_TEST_FORK/bin/jg-squad-lead-report.sh
  check 2 'real helper refuses before status append' bash "$report" 'done' abcdef0123456789 'http://review.example:4387/session/umer'
  if [ ! -e "$work/parent/state/umer.status" ]; then echo 'ok - refused note wrote no status'
  else echo 'not ok - refused note wrote status'; fails=$((fails + 1)); fi
  check 0 'real helper appends sign-off note' bash "$report" 'done' abcdef0123456789 'http://review.example:4388/board/umer'
  grep -qF 'http://review.example:4388/board/umer' "$work/parent/state/umer.status"
else echo 'SKIP real squad_lead helper: set JG_TEST_FORK to a Juggernaut checkout'; fi

command -v sign-off-axi >/dev/null # Required: never silently skip the real writer.
board=$SIGN_OFF_HOME/decisions.json
printf '{"schema":2,"items":[]}\n' > "$board"
head=$(printf 'a%.0s' {1..40})
jq -n --arg c "$head" '{schema:1,run_id:"no-lavish-run",commit:$c,dirty:false,exit:0,files:[{path:"proof.log"}]}' \
  > "$JG_HOME/data/t/.done-done/runs/run.json"
printf 'screen: none\n' > "$JG_HOME/data/t/checks.md"
post() {
  jq -n --arg claim "$1" '{verdict:"pass",check:{claim:$claim,evidence:["proof.log"]}}' > "$JG_HOME/data/t/merge-card.json"
  publish
}
publish() {
  "$addons/merge-card/merge-card" post --board "$board" t - "$head" -
}
encoded_post() {
  printf '%s\n' '{"verdict":"pass","check":{"claim":"See http:\/\/review.example:4387\/session\/umer","evidence":["proof.log"]}}' > "$JG_HOME/data/t/merge-card.json"
  publish
}
cp "$board" "$work/before.json"
check 1 'merge-card refuses Lavish URL before posting' post 'See http://review.example:4387/session/umer'
check 1 'merge-card refuses publish command before posting' post 'lavish-axi review.html'
check 1 'merge-card checks decoded JSON text' encoded_post
if cmp -s "$board" "$work/before.json"; then echo 'ok - refused posts leave board unchanged'
else echo 'not ok - refused posts changed board'; fails=$((fails + 1)); fi
check 0 'merge-card posts clean sign-off URL through real writer' post 'See http://review.example:4388/board/umer'
if sign-off-axi list "$board" --json --full | jq -e '.decisions | length == 1 and .[0].evidence.outcome == "See http://review.example:4388/board/umer"' >/dev/null; then
  echo 'ok - exactly one clean card exists'
else echo 'not ok - expected one clean card'; fails=$((fails + 1)); fi
[ "$fails" -eq 0 ] || { echo "FAIL no-lavish: $fails"; exit 1; }
echo 'PASS no-lavish: checker, squad_lead notes and real merge-card posts'
