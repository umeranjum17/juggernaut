#!/usr/bin/env bash
# run-live-proof.sh: a controlled real route failure recovers with no human. A disposable live lab (JG_CHECKOUT's
# jg-live-lab.sh, Haiku main) gets one real jg-spawn worker on pi, pinned to a local provider that answers HTTP 429, and
# this checkout's watcher in a lab-only data path; PASS is the lab watcher moving it to Claude Haiku and the worker
# finishing there. The lab pi agent dir defines only that provider and holds no credential. The evidence is one readable
# route.log (setup, the 429 calls, the move, the finish, teardown) and steps.json; raw lab output stays in $work/raw.
# A set CLAUDE_CONFIG_DIR (a pool account) reaches every lab Claude and its trust store, as jg-live-lab.sh does.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
# The real pi first on PATH: in a lab, jg-spawn's `pi --help` probe through the mise shim never returned (24 Oct).
real_pi=$(mise which pi 2>/dev/null) && PATH=$(dirname "$real_pi"):$PATH
repo=$(cd "$(dirname "$0")/.." && pwd -P)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
FMC=${JG_CHECKOUT:?set JG_CHECKOUT to a Juggernaut checkout}
port=${LAB_429_PORT:-18429} wait=${LAB_WAIT_SECS:-1800} ID=lab429-worker
mkdir -p "$evidence" && work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/jg-quota-failover-live.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
ROOT=$work/lab raw=$work/raw srv='' downed=''
mkdir -p "$raw"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$evidence/route.log"; }
lab_down() { downed=1 # deletes nothing itself: a refused `down` leaves the lab for a later one
  if "$FMC/bin/jg-live-lab.sh" down "$ROOT" >"$raw/lab-down.txt" 2>&1; then
    log "teardown: the lab's tmux server and processes stopped and the lab home was removed"
  else log "teardown: lab down refused, lab kept for a later down: $ROOT"; fi; }
done_lab() { local rc=$?; [ -z "$srv" ] || kill "$srv" 2>/dev/null; [ -n "$downed" ] || lab_down; exit "$rc"; }
trap done_lab EXIT

mkdir -p "$work/pi-agent"
printf '{"providers":{"lab429":{"name":"Lab 429","baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"lab-placeholder","models":[{"id":"rl-model","name":"Lab rate-limited model","contextWindow":8000,"maxTokens":1000,"input":["text"],"reasoning":false}]}}}\n' "$port" >"$work/pi-agent/models.json"
python3 -I -c '
import http.server, json, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def _go(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        open(sys.argv[2], "a").write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + self.path + " -> 429\n")
        b = json.dumps({"error": {"message": "Rate limit exceeded: too many requests", "type": "rate_limit_error", "code": 429}}).encode()
        self.send_response(429); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_POST = do_GET = _go
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$port" "$raw/provider-429-hits.txt" &
srv=$!

log "setup: a local provider on 127.0.0.1:$port answers every model call with HTTP 429"
"$FMC/bin/jg-live-lab.sh" up --harness claude --model claude-haiku-5-5 "$ROOT" >"$raw/lab-up.txt" 2>&1
log "setup: disposable lab home up; $(grep '^ok probe:' "$raw/lab-up.txt") on claude-haiku-5-5"
rec() { sed -n "s/^$1=//p" "$ROOT/.jg-live-lab" | head -n 1; }
LAB=$(rec home) TMUX_DIR=$(rec tmux_dir)
lab_run() { (cd "$LAB" && env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL="${SHELL:-/bin/bash}" \
  TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" JG_BACKEND=tmux \
  DISABLE_AUTOUPDATER=1 JG_HOME="$LAB" ${CLAUDE_CONFIG_DIR:+CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"} "$@"); }

git init -q -b main "$work/seed" && mkdir -p "$work/seed/notes"
printf 'NOTES = []\n\n\ndef add_note(text):\n    NOTES.append(text)\n    return len(NOTES) - 1\n' >"$work/seed/notes/__init__.py"
git -C "$work/seed" add -A && git -C "$work/seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "seed notes"
git clone -q --bare "$work/seed" "$ROOT/origins/notes.git" && git clone -q "$ROOT/origins/notes.git" "$LAB/projects/notes"
printf 'root = "%s"\n' "$ROOT/treehouse" >"$LAB/projects/notes/treehouse.toml"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' >"$LAB/data/projects.md"
printf '{"rules":[{"when":"Lab work on the notes project.","use":[{"harness":"pi","model":"lab429/rl-model","effort":"low"},{"harness":"claude","model":"claude-haiku-5-5","effort":"low"}]}],"default":[{"harness":"claude","model":"claude-haiku-5-5","effort":"low"}]}\n' >"$LAB/config/crew-dispatch.json"
# shellcheck disable=SC2016 # "$1" belongs to the hook it writes
printf '#!/bin/sh\nprintf "export PI_CODING_AGENT_DIR=%%s\\n" %q >"$1"\n' "$work/pi-agent" >"$LAB/config/launch-env-hook" && chmod +x "$LAB/config/launch-env-hook"
XDG_DATA_HOME=$ROOT/xdg "$repo/quota-failover/wiring.sh" "$LAB" >"$raw/install.txt"
log "setup: this checkout's quota-failover watcher installed into the lab home ($(grep -c '^installed:' "$raw/install.txt") home)"
inst=$ROOT/xdg/jg-quota-failover # the only pool library line the installed watcher sources is the feature's own copy
# shellcheck disable=SC2016 # matches the literal source line
[ "$(grep -c 'jg-account-pool-lib\.sh' "$inst/quota-failover/quota-failover")" = 1 ] &&
  grep -q '^\. "\$_JG_POOL_DIR/jg-account-pool-lib\.sh"' "$inst/quota-failover/quota-failover" &&
  cmp -s "$inst/account-pool/bin/jg-account-pool-lib.sh" "$repo/account-pool/bin/jg-account-pool-lib.sh" ||
  { log "FAIL: the installed watcher does not load the feature's own account-pool library"; exit 1; }
log "setup: the installed watcher sources only the feature's own account-pool/bin/jg-account-pool-lib.sh (installed beside it, identical to this checkout's), not the Juggernaut checkout's bin/ copy"

lab_run "$LAB/bin/jg-brief.sh" "$ID" notes --mode local-only >/dev/null
sed -i 's|{TASK}|Add count_notes(), which returns how many notes are stored, to notes/__init__.py.|; s|{JUGGERNAUT_SPEC}|Implement count_notes(), commit, and report done. Nothing else is in scope.|' "$LAB/data/$ID/brief.md"
lab_run "$LAB/bin/jg-tasks-axi.sh" add "$ID" "[feature] lab worker on a rate-limited route" --kind ship --repo notes --priority 3 --body "the lab proves quota failover on a live worker" >/dev/null
lab_run timeout "${LAB_SPAWN_SECS:-120}" "$LAB/bin/jg-spawn.sh" "$ID" "$LAB/projects/notes" --mode local-only --yolo on --harness pi --model lab429/rl-model --effort low >"$raw/spawn.txt" 2>&1
wt=$(sed -n "s/^spawned $ID .* worktree=//p" "$raw/spawn.txt")
log "setup: worker $ID spawned on harness=pi model=lab429/rl-model (the 429 route) to add count_notes()"
# The move lands on Claude: trust the lab worktree as a Claude spawn does (lab down removes every entry under the lab).
lab_run "$LAB/bin/jg-claude-trust.sh" "$wt" "$LAB/projects/notes"
"$FMC/bin/jg-live-lab.sh" say "$ROOT" "Lab note: one worker, $ID, is running; keep watcher supervision on. This lab tests the quota-failover watcher: do not message, relaunch, steer or stop $ID yourself, whatever its screen or status shows. End your turn."

end=$(($(date +%s) + wait)) qlog=$LAB/state/quota-failover.log
until grep -q "^[^ ]* $ID: switched pi lab429/rl-model -> claude claude-haiku-5-5" "$qlog" 2>/dev/null || [ "$(date +%s)" -gt "$end" ]; do
  grep -q 'Error: 429' "$raw/screen-before.txt" 2>/dev/null ||
    "$FMC/bin/jg-live-lab.sh" pane "$ROOT" --window "jg-$ID" --lines 12 >"$raw/screen-before.txt" 2>&1 || true
  sleep 15
done
log "429: the provider answered $(wc -l <"$raw/provider-429-hits.txt") calls with 429; the worker's screen shows: $(grep -o 'Error: 429.*}' "$raw/screen-before.txt" | head -n 1)"
moved=$(grep "$ID: switched" "$qlog" 2>/dev/null | tail -n 1) || true
[ -n "$moved" ] || { log "FAIL: no move in ${wait}s"; exit 1; }
log "move: the lab watcher's own pass logged: $moved"
end=$(($(date +%s) + wait))
until grep -q '^done' "$LAB/state/$ID.status" 2>/dev/null || [ "$(date +%s)" -gt "$end" ]; do sleep 15; done
route=$(grep "^harness=\|^model=" "$LAB/state/$ID.meta" | paste -sd' ')
grep -q '^done' "$LAB/state/$ID.status" || { log "FAIL: the worker did not finish on $route"; exit 1; }
log "finish: the worker, now on $route, reported: $(grep '^done' "$LAB/state/$ID.status" | tail -n 1)"
log "finish: its branch holds the work: $(git -C "$wt" log -1 --format=%s fm/$ID)"
lab_down
log "PASS: $ID moved off the 429 route to $route and finished there with no human step"
jq -n --arg v "$(git -C "$repo" rev-parse --short HEAD)" --arg moved "$moved" \
  '{target: {version: $v}, start: "a disposable live lab home with a Claude Haiku main and no quota-failover watcher",
    steps: ["install the quota-failover watcher into the lab home with one command (quota-failover/wiring.sh)",
      "spawn one real worker on pi pinned to a local route that answers every call with HTTP 429", "wait, with no human step"],
    result: ("the worker stopped on the real HTTP 429 rate limit; the watcher moved it to Claude Haiku and it finished there: " + $moved)}' >"$evidence/steps.json"
