#!/usr/bin/env bash
# Real hosted OpenCode failures, grouped automatic wake, and squad-lead
# watcher continuity in a named Herdr lab. No user credentials or settings.
# JG_MODEL_OUTAGE_LIVE=1 bin/jg-test-run.sh tests/jg-model-outage-live-e2e.test.sh
# JG_MODEL_OUTAGE_EVIDENCE selects a retained private evidence directory.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_live_gate opt-in JG_MODEL_OUTAGE_LIVE opencode herdr jq
mkdir -p "$ROOT/data"
E=${JG_MODEL_OUTAGE_EVIDENCE:-$(mktemp -d "$ROOT/data/model-outage-live.XXXXXX")}
mkdir -p "$E"
export JG_HERDR_LAB_STATE_DIR="$E/labstate"
(umask 077; mkdir -p "$JG_HERDR_LAB_STATE_DIR")
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/jg-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name model-outage)
ORIGINAL_PATH=$PATH
export JG_HOME="$E/home" JG_ROOT_OVERRIDE="$E/home"
export JG_STATE_OVERRIDE="$JG_HOME/state" JG_CONFIG_OVERRIDE="$JG_HOME/config" JG_DATA_OVERRIDE="$JG_HOME/data"
unset STATE JG_WAKE_QUEUE JG_WAKE_QUEUE_LOCK JG_TASK_INBOX
PANES=()
cleanup() {
  local rc=$? p pid cmd watcher arm
  trap - EXIT
  if [ "$rc" != 0 ]; then
    for p in "${PANES[@]}"; do
      echo "OpenCode proof failed at $p (version $VERSION)"
      PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane read "$p" --source visible || true
    done
  fi
  watcher=$(cat "$JG_HOME/state/.watch.lock/pid" 2>/dev/null) || watcher=
  arm=$(ps -o ppid= -p "$watcher" 2>/dev/null | tr -d ' ') || arm=
  rm -f "$JG_HOME/state/.lock"
  for pid in "$arm" "$watcher"; do
    [ -n "$pid" ] || continue
    cmd=$(ps -o args= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *"$JG_HOME/bin/jg-watch"*) kill -TERM "$pid" 2>/dev/null || true ;; esac
  done
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  echo "lab cleanup: $rc"; exit "$rc"
}
trap cleanup EXIT
VERSION=$(opencode --version | tail -1)
"$LAB_HELPER" provision "$SESSION"
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
mkdir -p "$E/bin" "$JG_HOME/state" "$JG_HOME/config" "$JG_HOME/data" "$JG_HOME/.opencode/plugins/lib"
cat > "$E/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$E/bin/herdr"
export PATH="$E/bin:$ORIGINAL_PATH" JG_BACKEND_HERDR_BIN="$E/bin/herdr" JG_BACKEND_HERDR_CLIENT_SESSION="$SESSION"
cp -a "$ROOT/bin" "$JG_HOME/"
cp "$ROOT/.opencode/plugins/jg-primary-watch-arm.js" "$JG_HOME/.opencode/plugins/"
cp "$ROOT/.opencode/plugins/lib/jg-operational-input.js" "$JG_HOME/.opencode/plugins/lib/"
printf '{"type":"module"}\n' > "$JG_HOME/.opencode/plugins/package.json"
printf 'manual\n' > "$JG_HOME/config/backlog-backend"
printf 'lead\n' > "$JG_HOME/.jg-squad-lead-home"
printf '# Isolated verification agent\nNo real fleet work. Only after an actual WATCHER FIRED message: run bin/jg-wake-drain.sh | tee -a data/drain.txt, execute its printed WAKE_ACK_REQUIRED command, then cp state/.wake-queue.seq state/lead-handled. Never manually arm monitoring. Reply briefly.\n' > "$JG_HOME/AGENTS.md"
git -C "$JG_HOME" init -q
for id in lanea laneb; do
  project="$E/$id"
  mkdir -p "$project/.opencode/plugins"
  git -C "$project" init -q
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$JG_HOME/state" "$id")
  printf '%s\n' "$gen" > "$E/$id.gen"
  cat > "$project/.opencode/plugins/busy.js" <<EOF
import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
export const Busy = async () => ({event: async ({event}) => {
  if (/session\\.(error|idle|status)/.test(event.type)) appendFileSync('$E/$id.events.jsonl', JSON.stringify(event)+'\\n');
  if(event.type === 'session.status') execFileSync('$ROOT/bin/jg-busy-event.sh', ['apply','$JG_HOME/state','$id',event.properties.status.type==='idle'?'idle':'busy','--gen','$gen','--source','opencode-plugin','--event','session-'+event.properties.status.type]);
}});
EOF
  jq -n --arg plugin "file://$project/.opencode/plugins/busy.js" '{plugin:[$plugin],provider:{opencode:{models:{"outage-unavailable":{id:"outage-unavailable",name:"Outage unavailable",limit:{context:4096,output:128}}}}}}' > "$project/config.json"
  pane=$(lab workspace create --cwd "$project" --label "$id" --no-focus | jq -er '.result.root_pane.pane_id')
  PANES+=("$pane")
  printf 'backend=herdr\nwindow=%s:%s\nharness=opencode\nworktree=%s\nkind=ship\n' "$SESSION" "$pane" "$project" > "$JG_HOME/state/$id.meta"
  lab pane run "$pane" "OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG='$project/config.json' OPENCODE_DISABLE_AUTOUPDATE=1 opencode --model opencode/outage-unavailable --prompt 'Reply briefly.'" >/dev/null
  printf '%s\n' "$pane" > "$E/$id.pane"
done
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"
for id in lanea laneb; do
  for ((i=0;i<120;i++)); do lab pane read "$(<"$E/$id.pane")" --source visible | grep -q 'Model outage-unavailable is not supported' && break; sleep 1; done
  [ "$i" -lt 120 ] || fail "OpenCode $VERSION: no hosted failure for $id"
done
failure_at=$(date +%s)
printf '{"plugin":["file://%s/.opencode/plugins/jg-primary-watch-arm.js"]}\n' "$JG_HOME" > "$JG_HOME/opencode.json"
pane=$(lab workspace create --cwd "$JG_HOME" --label lead --no-focus | jq -er '.result.root_pane.pane_id')
PANES+=("$pane")
# shellcheck disable=SC2016 # The real model expands its own isolated environment.
prompt='For this initial turn only: run printf ready > state/lead-ready, then respond READY. Do not drain or handle any notification until a later WATCHER FIRED message arrives.'
printf 'printf "%%s\\n" "$$" > %q; JG_POLL=2 JG_SIGNAL_GRACE=0 JG_HEARTBEAT=99999 OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG=%q OPENCODE_DISABLE_AUTOUPDATE=1 exec opencode --model opencode/big-pickle --prompt %q\n' "$JG_HOME/state/.lock" "$JG_HOME/opencode.json" "$prompt" > "$JG_HOME/launch.sh"
lab pane run "$pane" "bash '$JG_HOME/launch.sh'" >/dev/null
for ((i=0;i<180;i++)); do [ -s "$JG_HOME/state/lead-handled" ] && break; sleep 1; done
[ "$i" -lt 180 ] || fail "OpenCode $VERSION: squad lead did not receive the automatic outage wake"
elapsed=$(( $(date +%s) - failure_at ))
[ "$elapsed" -lt 300 ] || fail "outage delivery took ${elapsed}s"
printf 'outage delivered and handled in %ss\n' "$elapsed" > "$E/latency.txt"
cp "$JG_HOME/state/.last-watcher-beat" "$E/first-beacon"
sleep 4
[ "$JG_HOME/state/.last-watcher-beat" -nt "$E/first-beacon" ] || fail 'squad-lead beacon stopped'
# Delivery ledger records successful automatic delivery, not just queued text.
cp "$JG_HOME/state/.watch-deliveries.log" "$E/grouped-wake.txt"
grep -q 'affected=\[lanea,laneb\]: Model outage-unavailable is not supported' "$E/grouped-wake.txt"
[ "$(grep -c 'check: model outage' "$E/grouped-wake.txt")" = 1 ] || fail 'outage duplicated or not grouped'
mv "$JG_HOME/state/lead-handled" "$E/outage-handled"
before=$(cat "$E/outage-handled")
printf 'working [at=%s]: isolated worker notification\n' "$(date +%s)" >> "$JG_HOME/state/lanea.status"
for ((i=0;i<180;i++)); do
  after=$(cat "$JG_HOME/state/lead-handled" 2>/dev/null) || after=0
  [[ "$after" =~ ^[0-9]+$ ]] && [ "$after" -gt "$before" ] && grep -q 'lanea.status' "$JG_HOME/state/.watch-deliveries.log" && break
  sleep 1
done
[ "$i" -lt 180 ] || fail 'squad lead did not wake for its own worker'
cp "$JG_HOME/state/.last-watcher-beat" "$E/second-beacon"
sleep 4
[ "$JG_HOME/state/.last-watcher-beat" -nt "$E/second-beacon" ] || fail 'beacon stopped after the second turn'
lab pane read "$pane" --source visible > "$E/lead-final.txt"
echo "PASS OpenCode $VERSION: grouped hosted outage delivered automatically; squad lead keeps monitoring across turns"
