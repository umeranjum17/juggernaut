#!/usr/bin/env bash
# The SLO alerts: rules whose limits live in config, each proven to fire in a lab
# and to stay quiet inside its limit, plus Alertmanager's grouping, repeat
# interval and inhibition, and the routing of one alert from the owning lead to
# Main and to the captain channel. This part carries the first three rules.
#
# Nothing here starts a service, reads a real home or touches GitHub: the numbers
# are a sample set this test writes, and the captain channel is a stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLO="$ROOT/bin/jg-slo-alerts.sh"
TMP=$(jg_test_tmproot jg-slo-alerts)
HOME_DIR=$TMP/home
LEAD_DIR=$TMP/lead
PARENT=$TMP/parent
CAPTAIN=$TMP/captain.log
BUS=$TMP/bus-stub
SAMPLES=$TMP/samples.tsv
T0=1793510000

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$LEAD_DIR/config" "$LEAD_DIR/state" "$PARENT/state"
cp "$ROOT/defaults/slo-alerts.json" "$HOME_DIR/config/slo-alerts.json"
cp "$ROOT/defaults/slo-alerts.json" "$LEAD_DIR/config/slo-alerts.json"

# The captain channel is a stub: the alert must ask it to deliver, and this
# records the line it asked for, without a bus or a Go toolchain.
cat >"$BUS" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${JG_TEST_CAPTAIN_LOG:?}"
SH
chmod +x "$BUS"

run() {  # <home> <now> <samples> <subcommand...>
  local home=$1 now=$2 samples=$3
  shift 3
  JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_CONFIG_OVERRIDE="$home/config" \
    JG_SLO_ALERTS="$home/config/slo-alerts.json" JG_SLO_ALERTS_BUS="$BUS" \
    JG_SLO_ALERTS_NOW="$now" JG_TEST_CAPTAIN_LOG="$CAPTAIN" SAMPLES="$samples" "$SLO" "$@"
}

sample() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$SAMPLES"; }
set_limit() {  # <home> <rule> <limit>
  local f=$1/config/slo-alerts.json
  jq --arg id "$2" --argjson n "$3" '(.alerts[] | select(.id == $id) | .limit) |= $n' \
    "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}

# --- the rules are data, and each limit is in config ------------------------
out=$(run "$HOME_DIR" "$T0" "$SAMPLES" show) || fail "show failed: $out"
for id in pr-red done-merge worker-idle; do
  assert_contains "$out" "$id" "show does not name the $id rule"
done
assert_contains "$out" 'jg_slo_pr_red_seconds > 30 minutes' 'show does not print the pr-red limit'
assert_contains "$out" 'pr-red mutes worker-idle when owner' 'show does not print the inhibition in force'
pass 'show prints the rules, every limit and the inhibition from config'

# A limit moved in config moves the alert, with no code change: 600s is quiet at
# the shipped 30 minutes and fires at a 5-minute limit.
: >"$SAMPLES"
sample jg_slo_pr_red_seconds 600 '{"owner":"main","pr":"https://example.invalid/pull/1"}'
set_limit "$HOME_DIR" pr-red 5
out=$(run "$HOME_DIR" "$T0" "$SAMPLES" eval) || fail "eval at a 5 minute limit failed: $out"
assert_contains "$out" '"alertname":"pr-red"' 'a 10 minute red pull request is quiet at a 5 minute limit'
rm -rf "$HOME_DIR/state/.slo-alerts"
set_limit "$HOME_DIR" pr-red 30
out=$(run "$HOME_DIR" "$T0" "$SAMPLES" eval) || fail "eval at a 30 minute limit failed: $out"
assert_not_contains "$out" '"alertname":"pr-red"' 'a 10 minute red pull request fired at a 30 minute limit'
rm -rf "$HOME_DIR/state/.slo-alerts"
pass 'a limit is config: the same number fires or stays quiet as config says'

# --- each rule fires over its limit, and stays quiet inside it -------------
# <rule> <metric> <over the limit> <at the limit> <labels> <its for window>
case_table() {
  cat <<'EOF'
pr-red	jg_slo_pr_red_seconds	2400	1800	{"owner":"main","pr":"https://example.invalid/pull/2"}	0
done-merge	jg_slo_done_unmerged_seconds	3600	1800	{"owner":"main","task":"lane","pr":"https://example.invalid/pull/3"}	0
worker-idle	jg_slo_worker_idle_seconds	1800	1500	{"owner":"main","task":"lane"}	0
EOF
}

while IFS=$'\t' read -r id metric over at_limit labels for_min; do
  rm -rf "$HOME_DIR/state/.slo-alerts"
  : >"$SAMPLES"
  sample "$metric" "$over" "$labels"
  # A rule with a `for` window is pending at its first evaluation, so the clock
  # is pinned one second past that window.
  if [ "$for_min" -gt 0 ]; then run "$HOME_DIR" "$T0" "$SAMPLES" eval >/dev/null; fi
  out=$(run "$HOME_DIR" "$(( T0 + for_min * 60 + 1 ))" "$SAMPLES" eval) || fail "$id: eval failed"
  assert_contains "$out" "\"alertname\":\"$id\"" "$id does not fire over its limit"
  assert_contains "$out" '"kind":"send"' "$id reports no notification to send"

  rm -rf "$HOME_DIR/state/.slo-alerts"
  : >"$SAMPLES"
  sample "$metric" "$at_limit" "$labels"
  out=$(run "$HOME_DIR" "$(( T0 + 86400 ))" "$SAMPLES" eval) || fail "$id: eval failed"
  assert_not_contains "$out" "\"alertname\":\"$id\"" "$id fires at its own limit"
  if [ "$for_min" -gt 0 ]; then
    : >"$SAMPLES"
    sample "$metric" "$over" "$labels"
    run "$HOME_DIR" "$T0" "$SAMPLES" eval >/dev/null
    out=$(run "$HOME_DIR" "$(( T0 + 1 ))" "$SAMPLES" eval) || fail "$id: eval failed"
    assert_not_contains "$out" "\"alertname\":\"$id\"" "$id fires before its for window elapses"
  fi
  pass "$id fires over its limit and stays quiet inside it"
done < <(case_table)

# --- Alertmanager shapes: grouping, repeat, inhibition ---------------------
rm -rf "$HOME_DIR/state/.slo-alerts"
: >"$SAMPLES"
sample jg_slo_pr_red_seconds 2400 '{"owner":"main","pr":"https://example.invalid/pull/4"}'
sample jg_slo_pr_red_seconds 3000 '{"owner":"main","pr":"https://example.invalid/pull/5"}'
sample jg_slo_pr_red_seconds 2400 '{"owner":"lead-b","pr":"https://example.invalid/pull/6"}'
out=$(run "$HOME_DIR" "$T0" "$SAMPLES" eval) || fail 'grouping eval failed'
groups=$(printf '%s\n' "$out" | grep -c '"alertname":"pr-red"')
[ "$groups" -eq 2 ] || fail "grouping: expected 2 notifications (main, lead-b), got $groups: $out"
assert_contains "$out" '"count":2' 'grouping: the two main pull requests are not one notification'
pass 'instances sharing the group-by labels are one notification'

# A still-firing group re-notifies once per repeat interval and no more.
rm -rf "$HOME_DIR/state/.slo-alerts"
: >"$SAMPLES"
sample jg_slo_pr_red_seconds 2400 '{"owner":"main","pr":"https://example.invalid/pull/7"}'
run "$HOME_DIR" "$T0" "$SAMPLES" eval >/dev/null
for at in 60 120; do
  out=$(run "$HOME_DIR" "$(( T0 + at ))" "$SAMPLES" eval) || fail 'repeat eval failed'
  assert_not_contains "$out" '"alertname":"pr-red"' "a repeat fired at +${at}s, inside the repeat interval"
done
out=$(run "$HOME_DIR" "$(( T0 + 60 + 3600 ))" "$SAMPLES" eval) || fail 'repeat eval failed'
assert_contains "$out" '"alertname":"pr-red"' 'the repeat interval does not re-notify a still-firing group'
pass 'a still-firing group re-notifies only at the repeat interval'

# A red pull request mutes the idle-worker alert for the same owner and leaves
# another owner's lane alone: the pair the config names.
rm -rf "$HOME_DIR/state/.slo-alerts"
: >"$SAMPLES"
sample jg_slo_pr_red_seconds 2400 '{"owner":"main","pr":"https://example.invalid/pull/8"}'
sample jg_slo_worker_idle_seconds 1800 '{"owner":"main","task":"lane-a"}'
sample jg_slo_worker_idle_seconds 1800 '{"owner":"lead-b","task":"lane-b"}'
out=$(run "$HOME_DIR" "$T0" "$SAMPLES" eval) || fail 'inhibition eval failed'
assert_contains "$out" '"alertname":"pr-red"' 'the source alert did not fire, so nothing is inhibited'
assert_not_contains "$out" '"task":"lane-a"' 'the red pull request did not mute the same owner idle worker'
assert_contains "$out" '"task":"lane-b"' 'inhibition reached another owner lane'
pass 'inhibition mutes the target for the same owner and no other'

# --- routing: lead first, Main only when the lead does not act, one digest ---
# A Squad Lead home, so the escalation is the real one: the parent channel.
printf '%s\n' 'lane-a' >"$LEAD_DIR/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" >"$LEAD_DIR/.jg-squad-lead-parent"
rm -f "$CAPTAIN"
rm -rf "$LEAD_DIR/state/.slo-alerts"
: >"$SAMPLES"
sample jg_slo_pr_red_seconds 2400 '{"owner":"lane-a","pr":"https://example.invalid/pull/9"}'
sample jg_slo_done_unmerged_seconds 3600 '{"owner":"lane-a","task":"lane-b","pr":"https://example.invalid/pull/10"}'

run "$LEAD_DIR" "$T0" "$SAMPLES" tick >/dev/null || fail 'tick failed'
queue=$(cat "$LEAD_DIR/state/.wake-queue" 2>/dev/null || true)
assert_contains "$queue" 'slo-pr-red-' 'the owning lead was not woken'
assert_contains "$queue" 'slo-done-merge-' 'the second alert did not queue an owner wake'
assert_not_contains "$queue" 'slo-main-' 'the escalation fired before the lead had its chance'
assert_absent "$PARENT/state/lane-a.status" 'the escalation reached Main before the lead had its chance'
assert_absent "$CAPTAIN" 'a batch alert jumped the captain digest'
pass 'the owning lead is told first and Main is left alone'

# Past its escalation window the same alert reaches Main through the parent
# channel, and both alerts ride one captain digest line.
out=$(run "$LEAD_DIR" "$(( T0 + 91 * 60 ))" "$SAMPLES" tick) || fail "escalation tick failed: $out"
assert_contains "$(cat "$PARENT/state/lane-a.status" 2>/dev/null || true)" \
  'a pull request is red with no new push' 'the escalation did not reach Main through the parent channel'
assert_contains "$out" 'slo-escalation' 'the escalation did not ask the watcher to wake this cycle'
captain=$(cat "$CAPTAIN" 2>/dev/null || true)
assert_contains "$captain" '2 choke point(s) waiting' 'the captain never got the batched digest'
assert_equals "$(printf '%s\n' "$captain" | grep -c 'choke point')" 1 \
  'the digest did not stay one batched line for two alerts'
pass 'Main hears only when the lead does not act, and the captain gets one digest line'

# --- off is the switch ------------------------------------------------------
rm -rf "$LEAD_DIR/state/.slo-alerts" "$LEAD_DIR/state/.wake-queue"
rm -f "$CAPTAIN"
f=$LEAD_DIR/config/slo-alerts.json
jq '.mode = "off"' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
run "$LEAD_DIR" "$T0" "$SAMPLES" tick >/dev/null || fail 'tick with mode off failed'
assert_absent "$LEAD_DIR/state/.wake-queue" 'mode off still queued a wake'
assert_absent "$CAPTAIN" 'mode off still published to the captain'
pass 'mode off queues and publishes nothing'

# --- the numbers come from the fleet's own records --------------------------
# The lab above evaluates a sample set; this case proves the collection reads the
# records the fleet already writes. The forge reader is the one a lab must not
# call, so the forge interval is held open.
rm -rf "$HOME_DIR/state/.slo-alerts" "$HOME_DIR"/state/*
mkdir -p "$HOME_DIR/state"

# A lane finished an hour ago and nothing merged it: the newest line is not a
# merge, so the done-to-merged clock is running.
jg_write_meta "$HOME_DIR/state/lane-done.meta" 'kind=ship' 'project=/nonexistent'
{
  printf 'working [at=%s]: implementation\n' "$(( T0 - 4000 ))"
  printf 'done [at=%s]: PR https://example.invalid/pull/10\n' "$(( T0 - 3600 ))"
  printf 'paused [at=%s]: waiting on CI\n' "$(( T0 - 3500 ))"
} >"$HOME_DIR/state/lane-done.status"
jg_touch_epoch "$(( T0 - 3500 ))" "$HOME_DIR/state/lane-done.status"

# A second lane with no status for half an hour and no commit for an hour.
jg_git_identity
export GIT_AUTHOR_DATE="@$(( T0 - 3600 )) +0000" GIT_COMMITTER_DATE="@$(( T0 - 3600 )) +0000"
jg_git_init_commit "$TMP/lane-idle-copy"
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
jg_write_meta "$HOME_DIR/state/lane-idle.meta" 'kind=ship' "worktree=$TMP/lane-idle-copy" 'project=/nonexistent'
printf 'working [at=%s]: implementation\n' "$(( T0 - 1800 ))" >"$HOME_DIR/state/lane-idle.status"
jg_touch_epoch "$(( T0 - 1800 ))" "$HOME_DIR/state/lane-idle.status"

# Hold the forge interval open, so no case reaches GitHub.
mkdir -p "$HOME_DIR/state/.slo-alerts"
printf '%s\n' "$T0" >"$HOME_DIR/state/.slo-alerts/.forge-at"
out=$(run "$HOME_DIR" "$T0" "" collect) || fail "collect failed: $out"
collected=$(cat "$HOME_DIR/state/.slo-alerts/samples")
assert_contains "$collected" "$(printf 'jg_slo_done_unmerged_seconds\t3600')" \
  'the unmerged done task is not measured from its done line'
assert_contains "$collected" "$(printf 'jg_slo_worker_idle_seconds\t1800')" \
  'the idle lane is not measured from the newer of its status and its commit'
assert_not_contains "$collected" 'jg_slo_pr_red_seconds' 'the forge was read inside its interval'
pass 'collect measures its numbers from the records that own them'
