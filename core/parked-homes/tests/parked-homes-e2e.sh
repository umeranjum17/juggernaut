#!/usr/bin/env bash
# parked-homes e2e: a fixture fleet of two squad_lead homes, one parked, driven
# through the real supervision producers. The parked home (home-b) must get no
# message, steer, nudge, relaunch or config push, no pending-reply retry, no
# wake-loop drain ring or stalled check, and no model-outage scan; the unparked
# home (home-a) must still be acted on by every one of those paths.
#
# Usage: parked-homes/tests/parked-homes-e2e.sh <juggernaut-checkout>
#   <juggernaut-checkout> is a juggernaut checkout carrying the parked-homes
#   fork hooks (bin/jg-parked-homes-lib.sh shim + the gate lines); without it
#   the parked gates do not exist and the test fails loudly.
#
# Real surfaces: the checkout's own bin/ scripts, real tmux panes for the
# endpoint-sensitive paths (relaunch, model-outage), and the real busy-record
# contract (jg-busy-event.sh). No real fleet home, credential or worktree is
# touched. Needs bash, tmux, jq, flock on PATH.
# shellcheck disable=SC2016 # stub bodies and child scripts keep their own expansions
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
FM=${1:-}
[ -n "$FM" ] && [ -x "$FM/bin/jg-send.sh" ] || {
  echo "usage: $0 <juggernaut-checkout-with-parked-homes-hooks>" >&2
  exit 1
}
[ -f "$FM/bin/jg-parked-homes-lib.sh" ] || {
  echo "not ok - $FM/bin/jg-parked-homes-lib.sh is missing: the checkout does not carry the parked-homes fork hooks" >&2
  exit 1
}
command -v tmux >/dev/null 2>&1 || { echo "not ok - tmux is required"; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/parked-homes-e2e.XXXXXX") || exit 1
P=$work/parent
SES=fmph$$
SES2=fmpr$$
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
has() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1: $2 lacks [$3]"; fi; }
lacks() { if grep -qF -- "$3" "$2" 2>/dev/null; then no "$1: $2 must not contain [$3]"; else ok "$1"; fi; }

# shellcheck disable=SC2317 # the EXIT trap runs this; ShellCheck 0.9 cannot see that
trap '{
  rc=$?
  trap - EXIT
  tmux kill-session -t "$SES" 2>/dev/null
  tmux kill-session -t "$SES2" 2>/dev/null
  rm -rf "$work"
  echo "e2e cleanup: $rc"
  exit "$rc"
}' EXIT

# --- the fixture fleet: a supervising home with two squad_lead homes ---------
mkdir -p "$P/config" "$P/state" "$P/data" "$work/home-a/state" "$work/home-b/state"
printf '# Parked homes: no work, nothing merges.\nhome-b\n' > "$P/config/parked-homes"
printf 'manual\n' > "$P/config/backlog-backend"
printf 'Shared captain context for every mate.\n' > "$P/data/captain-shared.md"
: > "$P/data/squad_leads.md"
printf 'home-a\n' > "$work/home-a/.jg-squad-lead-home"
printf 'home-b\n' > "$work/home-b/.jg-squad-lead-home"
printf '# Fixture mate\n' > "$work/home-a/AGENTS.md"
printf '# Fixture mate\n' > "$work/home-b/AGENTS.md"
mkdir -p "$work/home-a/bin" "$work/home-b/bin"

# Real tmux panes for the endpoint-validating paths. The mo-* panes run a
# renamed sleep so the model-outage scan reads them as a live OpenCode agent,
# and their screen carries a provider limit banner. The jg-home-* panes in the
# second session are bare sleeps: the endpoint validates (jg-control requires
# the pane name jg-<id>) but the agent reads as exited, so an unparked
# relaunch fails fast without typing anywhere.
tmux new-session -d -s "$SES" -x 200 -y 50 || exit 1
for w in mo-a mo-b; do
  tmux new-window -t "$SES" -n "$w" "printf 'opencode agent pane %s\nrate limit exceeded\n'; exec -a opencode sleep 300" || exit 1
done
tmux new-session -d -s "$SES2" -x 200 -y 50 || exit 1
for w in jg-home-a jg-home-b; do
  tmux new-window -t "$SES2" -n "$w" 'sleep 300' || exit 1
done

meta_for() {  # <id> <window>
  cat > "$P/state/$1.meta" <<META
window=$2
endpoint_task_id=$1
worktree=$work/$1
project=$work/$1
harness=opencode
kind=squad_lead
mode=squad_lead
model=opencode-go/fixture-route
backend=tmux
home=$work/$1
META
}
# The send/config paths run first against dead windows (sx-*): any delivery
# attempt would fail loudly, so only the gate may act. Later sections rewrite
# the metas for their own endpoints; the home=/parked binding never changes.
meta_for home-a 'sx-a'
meta_for home-b 'sx-b'

export JG_HOME=$P
export JG_ADDONS_DIR=$addons
. "$addons/parked-homes/bin/jg-parked-homes-lib.sh"
fork() { local script=$1; shift; "$FM/bin/$script" "$@"; }

# --- 1. supervision session: steer via jg-send -------------------------------
out=$(fork jg-send.sh jg-home-b "hello parked mate" 2>&1)
is "parked steer is refused" "$?" "1"
has "parked steer names the parked rule" <(printf "%s" "$out") "parked"
[ -d "$P/state/home-b.inbox" ] && no "parked steer wrote no inbox record" || ok "parked steer wrote no inbox record"
lp=$(awk -v RS='' 'NF { n++ } END { print n + 0 }' "$P/state/reply-state.tsv" 2>/dev/null || true)
lp=${lp:-0}
is "parked steer created no pending-reply expectation" "$lp" "0"

out=$(fork jg-send.sh jg-home-a "hello mate" 2>&1)
is "unparked steer is delivered" "$?" "0"
[ -s "$P/state/home-a.inbox" ] && ok "unparked steer wrote its inbox record" || no "unparked steer wrote no inbox record"

# --- 2. relaunch: jg-control relaunch ----------------------------------------
meta_for home-a "$SES2:jg-home-a"
meta_for home-b "$SES2:jg-home-b"
out=$(fork jg-control.sh home-b relaunch 2>&1)
rc=$?
[ "$rc" -ne 0 ] && has "parked relaunch is refused" <(printf "%s" "$out") "config/parked-homes" \
  || { no "parked relaunch is refused: got exit 0"; }
out=$(fork jg-control.sh home-a relaunch 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  lacks "unparked relaunch went past the gate (non-parked failure)" <(printf "%s" "$out") "config/parked-homes"
else
  no "unparked relaunch: expected a non-parked control failure, got exit 0"
fi

# --- 3. restart pass: jg-squad-lead-restart.sh --------------------------------
before_a=$(find "$P/state/home-a.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
out=$(JG_SQUAD_LEAD_PERSIST_WAIT=1 JG_SQUAD_LEAD_IDLE_WAIT=1 fork jg-squad-lead-restart.sh home-a home-b 2>&1)
has "restart pass names the parked skip" <(printf "%s" "$out") "parked: home-b"
lacks "restart pass never reports home-b as restarted" <(printf "%s" "$out") "restarted: home-b"
now_a=$(find "$P/state/home-a.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
[ "$now_a" -gt "$before_a" ] && ok "restart pass still asks the unparked mate to persist" \
  || no "restart pass sent nothing to the unparked mate"
[ -d "$P/state/home-b.inbox" ] && no "restart pass wrote nothing to the parked home" \
  || ok "restart pass wrote nothing to the parked home"

# --- 4. config push: jg-config-push.sh ----------------------------------------
out=$(fork jg-config-push.sh 2>&1)
has "config push names the parked skip" <(printf "%s" "$out") "home-b: skipped - its home is parked"
[ -e "$work/home-b/config/backlog-backend" ] && no "config push wrote nothing into the parked home" \
  || ok "config push wrote nothing into the parked home"
[ -f "$work/home-a/config/backlog-backend" ] && ok "config push still reaches the unparked home" \
  || no "config push did not reach the unparked home"

# --- 5. pending-reply retries: jg_pending_reply_tick --------------------------
cat > "$work/recovery-hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${JG_HOME:?}/state/recovery-hook.log"
exit 0
HOOK
chmod +x "$work/recovery-hook.sh"
export JG_PENDING_REPLY_GRACE_SECS=1
export JG_PENDING_REPLY_SEND_HOOK=$work/recovery-hook.sh
bash -c '
  . "$1/bin/jg-pending-reply-lib.sh"
  c_a=$(jg_pending_reply_create "$JG_HOME" "$JG_HOME/state" home-a "please report") || exit 2
  c_b=$(jg_pending_reply_create "$JG_HOME" "$JG_HOME/state" home-b "please report") || exit 2
  jg_pending_reply_confirm_delivery "$JG_HOME/state" "$c_a" || exit 2
  jg_pending_reply_confirm_delivery "$JG_HOME/state" "$c_b" || exit 2
  past=$(( $(date +%s) - 60 ))
  jg_pending_reply_set "$(jg_pending_reply_path "$JG_HOME/state" "$c_a")" request_turn_completed_epoch "$past"
  jg_pending_reply_set "$(jg_pending_reply_path "$JG_HOME/state" "$c_b")" request_turn_completed_epoch "$past"
' _ "$FM" || no "pending-reply fixture records could not be created"
JG_WAKE_QUEUE=$P/state/.wake-queue JG_WAKE_QUEUE_LOCK=$P/state/.wake-queue.lock STATE=$P/state \
  bash -c '
  . "$1/bin/jg-pending-reply-lib.sh"
  jg_pending_reply_tick "$JG_HOME/state"
' _ "$FM" || no "pending-reply tick failed"
has "unparked record got its recovery resend" "$P/state/recovery-hook.log" "home-a"
if grep -q "home-b" "$P/state/recovery-hook.log" 2>/dev/null; then
  no "parked record got no recovery resend"
else
  ok "parked record got no recovery resend"
fi
skipped=1
for corr in $(bash -c '. "$1/bin/jg-pending-reply-lib.sh"; jg_pending_reply_corrs "$2"' _ "$FM" "$P/state"); do
  ptr="$(bash -c '. "$1/bin/jg-pending-reply-lib.sh"; jg_pending_reply_path "$2" "$3"' _ "$FM" "$P/state" "$corr")"
  [ "$(bash -c '. "$1/bin/jg-pending-reply-lib.sh"; jg_pending_reply_get "$2" task_id' _ "$FM" "$ptr")" = home-b ] || continue
  [ -n "$(bash -c '. "$1/bin/jg-pending-reply-lib.sh"; jg_pending_reply_get "$2" recovery_attempted_epoch' _ "$FM" "$ptr")" ] && skipped=0
done
is "parked record keeps its phase (no recovery attempt recorded)" "$skipped" "1"

# --- 6. wake-loop check: squad_lead_wake_stall_tick ---------------------------
# A stalled row in each home's own wake queue, with the episode's progress
# marker already old enough to be stalled: the unparked mate gets the stalled
# check; the parked mate is never touched and its episode markers are dropped.
: > "$P/state/.wake-queue"
for id in home-a home-b; do
  row_epoch=$(($(date +%s) - 3600))
  printf '%s\t1\tcheck\tfixture-row\tstalled row for %s\n' "$row_epoch" "$id" >> "$work/$id/state/.wake-queue"
  printf '%s %s-1\n' "$((row_epoch - 120))" "$row_epoch" > "$P/state/.squad-lead-wake-progress-$id"
done
JG_STATE_OVERRIDE=$P/state STATE=$P/state SQUAD_LEAD_WAKE_STALL_SECS=60 JG_WAKE_QUEUE=$P/state/.wake-queue \
  JG_WAKE_QUEUE_LOCK=$P/state/.wake-queue.lock bash -c '
  . "$1/bin/jg-watch.sh"
  wake() { :; }
  squad_lead_wake_stall_tick
' _ "$FM" || no "wake-loop stall tick failed"
has "unparked stalled queue raised the wake-loop check" "$P/state/.wake-queue" "squad_lead wake-loop stalled: mate=home-a"
if grep -q "mate=home-b" "$P/state/.wake-queue" 2>/dev/null; then
  no "parked stalled queue raised no wake-loop check"
else
  ok "parked stalled queue raised no wake-loop check"
fi
[ -e "$P/state/.squad-lead-wake-stall-home-b" ] && no "parked stall markers are dropped" \
  || ok "parked stall markers are dropped"
[ -e "$P/state/.squad-lead-wake-stall-home-a" ] && ok "unparked stall marker recorded" \
  || no "unparked stall marker missing"

# --- 7. model-outage check: jg_model_outage_tick ------------------------------
for id in home-a home-b; do
  gen=$("$FM/bin/jg-busy-event.sh" arm "$P/state" "$id") || no "busy record arm failed for $id"
  "$FM/bin/jg-busy-event.sh" apply "$P/state" "$id" idle --gen "$gen" --source opencode-plugin --event session-idle \
    || no "busy record apply failed for $id"
done
cat > "$P/state/home-a.meta" <<META
window=$SES:mo-a
endpoint_task_id=home-a
worktree=$work/home-a
harness=opencode
kind=squad_lead
backend=tmux
home=$work/home-a
META
cat > "$P/state/home-b.meta" <<META
window=$SES:mo-b
endpoint_task_id=home-b
worktree=$work/home-b
harness=opencode
kind=squad_lead
backend=tmux
home=$work/home-b
META
: > "$P/state/.wake-queue"
JG_STATE_OVERRIDE=$P/state STATE=$P/state JG_WAKE_QUEUE=$P/state/.wake-queue \
  JG_WAKE_QUEUE_LOCK=$P/state/.wake-queue.lock bash -c '
  . "$1/bin/jg-backend.sh"
  . "$1/bin/jg-busy-lib.sh"
  . "$1/bin/jg-wake-lib.sh"
  . "$1/bin/jg-model-outage-lib.sh"
  wake() { :; }
  jg_model_outage_tick
' _ "$FM" || no "model-outage tick failed"
has "unparked lane produced the outage alert" "$P/state/.wake-queue" "model outage affected=[home-a]"
if grep -q "home-b" "$P/state/.wake-queue" 2>/dev/null; then
  no "parked lane produced no outage alert"
else
  ok "parked lane produced no outage alert"
fi
[ -f "$P/state/.model-outages/lane-home-a" ] && ok "unparked lane episode recorded" \
  || no "unparked lane episode missing"
[ -e "$P/state/.model-outages/lane-home-b" ] && no "parked lane was never scanned" \
  || ok "parked lane was never scanned"

# --- 8. quota-failover: the feature script skips the parked home ---------------
Q=$work/qhome
mkdir -p "$Q/state" "$Q/config" "$Q/bin" "$Q/stub"
printf 'home-b\n' > "$Q/config/parked-homes"
for lib in jg-backend.sh jg-busy-lib.sh jg-quota-axi-lib.sh jg-parent-channel-lib.sh jg-account-pool-lib.sh; do
  # SC2016: the stub bodies are written verbatim for the fixture home to
  # source; their $1/$2 belong to the stub's own callers, not this script.
  printf '%s\n' \
    'jg_meta_get() { [ -f "$1" ] || return 0; sed -n "s|^$2=||p" "$1" | tail -n 1; }' \
    'jg_backend_of_meta() { echo fixture; }' \
    'jg_backend_target_of_meta() { jg_meta_get "$1" endpoint_task_id; }' \
    'jg_backend_visible_capture() { [ -f "$JG_HOME/state/$2.screen" ] && cat "$JG_HOME/state/$2.screen"; return 0; }' \
    'jg_busy_classify_meta() { echo "idle no-busy-record"; }' \
    'jg_busy_record_read() { echo ""; }' \
    'JG_QUOTA_ROW_JQ="def quota_lane(\$harness; \$model): \"\"; def quota_row(\$snapshot; \$provider; \$lane): null;"' \
    'jg_quota_json_valid() { jq -e ".schemaVersion == 5 and (.providers | type) == \"array\"" >/dev/null 2>&1; }' \
    'jg_quota_single_provider_for_harness() { return 1; }' \
    'jg_parent_channel_report() { printf "%s\n" "$3" >>"$1/state/parent-channel.log"; }' > "$Q/bin/$lib"
done
cat > "$Q/bin/jg-crew-state.sh" <<'CS'
#!/usr/bin/env bash
echo 'state: working · source: fixture'
CS
cat > "$Q/bin/jg-control.sh" <<'FC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$JG_HOME/state/jg-control.log"
[ "${2:-}" = relaunch ] || exit 0
id=${1:-}
rm -f "$JG_HOME/state/$id.screen"
date +%s >"$JG_HOME/state/$id.status"
FC
chmod +x "$Q/bin/jg-crew-state.sh" "$Q/bin/jg-control.sh"
printf '#!/usr/bin/env bash\necho PONG\n' > "$Q/stub/opencode"
printf '#!/usr/bin/env bash\necho '"'"'{"schemaVersion":5,"providers":[]}'"'"'\n' > "$Q/stub/quota-axi"
chmod +x "$Q/stub/opencode" "$Q/stub/quota-axi"
for id in home-a home-b; do
  cat > "$Q/state/$id.meta" <<META
endpoint_task_id=$id
kind=squad_lead
harness=opencode
model=opencode-go/fixture-route
backend=fixture
home=$work/$id
META
  printf 'usage limit reached, retry later\n' > "$Q/state/$id.screen"
  touch -d "2 hours ago" "$Q/state/$id.status"
done
cat > "$Q/config/crew-dispatch.json" <<'JSON'
{"default": [{"harness": "opencode", "model": "opencode-go/live-route"}]}
JSON
PATH="$Q/stub:$PATH" QUOTA_FAILOVER_STALL_SECS=1 QUOTA_FAILOVER_TEST_SECS=1 QUOTA_FAILOVER_PROBE_SECS=1 \
  bash "$addons/quota-failover/quota-failover" "$Q" || no "quota-failover pass failed"
has "unparked stopped worker was moved" "$Q/state/jg-control.log" "home-a relaunch"
if [ -e "$Q/state/jg-control.log" ]; then
  lacks "parked stopped worker was never moved" "$Q/state/jg-control.log" "home-b"
else
  ok "parked stopped worker was never moved"
fi
has "parked skip is logged once" "$Q/state/quota-failover.log" "home-b: parked: its home is parked"
has "unparked move is logged" "$Q/state/quota-failover.log" "home-a: switched"

# --- 9. the reader itself under set -u: remote mate without home=, ship without kind=
# jg_parked_meta_id runs inside set -u producers (jg-watch.sh, quota-failover), so a
# meta missing either line must answer silently and correctly, never abort.
M=$work/meta-probe
mkdir -p "$work/pconfig"
printf 't1\n' > "$work/pconfig/parked-homes"
printf 'kind=squad_lead\n' > "$M"          # remote squad_lead: no home=, task id stands in
printf 'worktree=/x\n' > "$M-ship"        # no kind= line at all
bash -c '
  set -u
  . "$1/parked-homes/bin/jg-parked-homes-lib.sh"
  JG_CONFIG_OVERRIDE=$2   # the override IS the config directory (fork convention)
  jg_parked_meta "$3" t1 && echo parked || echo not-parked
  err=$(jg_parked_meta "$4" t2 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$err" ]; then echo silent; else echo "FAIL rc=$rc err=$err"; fi
' _ "$addons" "$work/pconfig" "$M" "$M-ship" > "$work/reader.out" 2>&1 \
  || no "parked-home reader failed under set -u: $(cat "$work/reader.out")"
is "remote squad_lead meta without home= is parked (set -u)" "$(sed -n 1p "$work/reader.out")" "parked"
is "ship meta without kind= is silently not parked (set -u)" "$(sed -n 2p "$work/reader.out")" "silent"
lacks "reader under set -u prints no unbound-variable errors" "$work/reader.out" "unbound variable"

# --- 10. shared fork gate helpers: exact refusal text and absent-source fallback
G=$work/gate-meta
printf 'kind=squad_lead\nhome=%s\n' "$work/home-b" > "$G"
printf 'kind=squad_lead\nhome=%s\n' "$work/home-a" > "$G-allowed"
if out=$(jg_parked_refuse_meta "$G" home-b send 2>&1); then rc=0; else rc=$?; fi
is "parked send gate refuses" "$rc" "1"
is "parked send gate keeps exact error" "$out" "error: nothing sent to jg-home-b: its home is parked (config/parked-homes); a parked home gets no message, steer, answer or nudge"
if out=$(jg_parked_refuse_meta "$G" home-b relaunch 2>&1); then rc=0; else rc=$?; fi
is "parked relaunch gate refuses" "$rc" "1"
is "parked relaunch gate keeps exact error" "$out" "error: relaunch refused for home-b: its home is parked (config/parked-homes); a parked home gets no relaunch"
jg_parked_refuse_meta "$G-allowed" home-a send > "$work/allowed.out" 2>&1
is "unparked refusal gate allows" "$?" "0"
is "unparked refusal gate is silent" "$(cat "$work/allowed.out")" ""
jg_parked_skip_meta "$G" home-b config-push > "$work/skip.out" 2>&1
is "parked skip gate selects skip" "$?" "0"
is "parked skip gate keeps exact output" "$(cat "$work/skip.out")" "squad_lead home-b: skipped - its home is parked (config/parked-homes)"
if jg_parked_skip_meta "$G-allowed" home-a config-push > "$work/allowed.out" 2>&1; then rc=0; else rc=$?; fi
is "unparked skip gate allows continuation" "$rc" "1"
is "unparked skip gate is silent" "$(cat "$work/allowed.out")" ""
# This is the no-op API that the fork shim supplies when the feature is absent.
if bash -c '
  jg_parked_refuse_meta() { return 0; }
  jg_parked_skip_meta() { return 1; }
  jg_parked_refuse_meta absent home-b send || exit 1
  if jg_parked_skip_meta absent home-b config-push; then exit 1; fi
  exit 0
'; then
  ok "absent feature permits refusal and skip call sites"
else
  no "absent feature fallbacks refused a call site"
fi

if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "$fails FAILURES"
exit 1
