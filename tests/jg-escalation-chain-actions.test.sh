#!/usr/bin/env bash
set -eu
# shellcheck source=tests/jg-escalation-chain-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-escalation-chain-fixture.sh"

# jg-send (real-steer), so the inbox records and the decision close are real.

# A worker that has gone quiet mid-task: it says it is working and its pane and
# status have not changed for 20 minutes, so the watcher raises its silent source.
silence_worker() {  # <home> <task> <pane>
  local m=$1 n mark="$1/tmp/silent-mark"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\n' "$3" > "$m/state/$2.meta"
  printf 'working [at=1]: running the suite\n' > "$m/state/$2.status"
  prime_status_seen "$m/state" "$m/state/$2.status"
  for n in 1 2 3 4 5 6 7 8; do
    touch "$mark"
    cycle "$m"
    [ -s "$m/state/.silent-seen-fake_$3" ] && [ ! "$m/state/.silent-seen-fake_$3" -nt "$mark" ] && break
  done
  touch -d '-20 minutes' "$m/state/.silent-seen-fake_$3" "$m/state/$2.status"
  prime_status_seen "$m/state" "$m/state/$2.status"
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/$2"
  grep -q '^silent: no status line or pane change' "$m/state/.wait-sources/$2.silent" 2>/dev/null \
    || fail "$2 silent 20 minutes armed no silent wait: $(ls -a "$m/state/.wait-sources" 2>&1; cat "$m/err")"
}

# The row the metrics ledger holds for <task>, or nothing.
ledger_row() {  # <home> <task>
  awk -F '\t' -v t="$2" '$2 == t' "$1/data/metrics/escalations.tsv" 2>/dev/null
}

test_a_silent_worker_is_rung_and_clears_with_no_model_turn() {
  # Wide gaps between rungs, so arming takes no step and one test cycle takes one.
  local m row CYCLE_POLLS=100 PANES=1 ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(home silent-ring)
  : > "$m/real-steer"
  silence_worker "$m" sr 1
  backdate "$m" sr 31
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/.acted/sr"
  grep -qx 'silent	[0-9]*	ring	[0-9]*' "$m/state/.waiting-timers/.acted/sr" \
    || fail "the silent worker was not rung by the ladder: $(cat "$m/state/.waiting-timers/.acted/sr" 2>&1; cat "$m/err")"
  grep -l 'no status line and shown no new output' "$m/state/sr.inbox/"*.msg >/dev/null 2>&1 \
    || fail "the ring did not reach the worker's inbox: $(ls -la "$m/state/sr.inbox" 2>&1; cat "$m/sent" 2>&1)"
  # The worker reads the steer and reports where it is.
  printf 'working [at=%s]: back; the suite had hung on a lock\n' "$(date +%s)" >> "$m/state/sr.status"
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/sr"
  [ ! -e "$m/state/.waiting-timers/sr" ] || fail "the answered ring left the wait open: $(cat "$m/state/.waiting-timers/sr")"
  ! grep -q 'waiting-state sr' "$m/events" || fail "a rung wait still woke a model: $(cat "$m/events")"
  ! grep -q '^jg-control ' "$m/sent" 2>/dev/null || fail "an answered ring was relaunched: $(cat "$m/sent")"
  row=$(ledger_row "$m" sr)
  printf '%s\n' "$row" | grep -qE '^[0-9]+	sr	waiting-timer-[^	]+	[0-9]+	[0-9]+\.[0-9]	owner	ring	changed state$' \
    || fail "the ledger has no row with the cleared minutes: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  printf 'silent ring: cleared in %s min, no model turn\n' "$(printf '%s' "$row" | cut -f5)"
  pass "a silent worker is rung by the ladder, clears when it reports, and the ledger holds the minutes, with no owner or Main wake"
}

test_an_unanswered_ring_is_relaunched_then_reaches_main() {
  local m row CYCLE_POLLS=100 PANES=1 ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(home silent-relaunch)
  : > "$m/real-steer"
  silence_worker "$m" sq 1
  backdate "$m" sq 31
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/.acted/sq"
  # No answer: the next rung is stuck-operator recovery's relaunch, not a wake.
  backdate "$m" sq 61
  cycle_for "$m" 120 grep -q '^jg-control sq relaunch --note ' "$m/sent"
  grep -q '^jg-control sq relaunch --note The watcher relaunched you' "$m/sent" \
    || fail "an unanswered ring was not relaunched: $(cat "$m/sent" 2>&1; cat "$m/state/.waiting-timers/.acted/sq" 2>&1)"
  grep -q 'relaunch exit=0' "$m/state/.waiting-timers/.acted/sq.relaunch.log" || fail "the relaunch outcome was not logged"
  ! grep -q 'waiting-state sq' "$m/events" || fail "a wait with a step left woke a model: $(cat "$m/events")"
  # Both steps spent and still silent: the table's next owner, the lead (Main
  # in this home), gets the owner wake; only then does the Main rung follow.
  backdate "$m" sq 61
  cycle_for "$m" 120 grep -q 'waiting-state sq (silent, .*level=owner' "$m/events"
  grep -q 'check: waiting-state sq (silent, .*level=owner' "$m/events" \
    || fail "the lead was not handed the wait after the steps were spent: $(cat "$m/events"; cat "$m/state/.waiting-timers/.acted/sq")"
  ! grep -q 'waiting-state sq (silent, .*level=main' "$m/events" || fail "Main was woken before the lead: $(cat "$m/events")"
  backdate "$m" sq 61
  cycle_for "$m" 120 grep -q 'waiting-state sq (silent, .*level=main' "$m/events"
  grep -q 'check: waiting-state sq (silent, .*level=main; the ladder already took: ring, relaunch, lead; Main must unblock it now)' "$m/events" \
    || fail "Main was not told after the lead: $(cat "$m/events")"
  printf 'working [at=%s]: resumed after the relaunch\n' "$(date +%s)" >> "$m/state/sq.status"
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/sq"
  row=$(ledger_row "$m" sq)
  printf '%s\n' "$row" | grep -qE '	main	ring, relaunch, lead	changed state$' \
    || fail "the ledger row does not name the rung and the steps: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  pass "an unanswered ring is relaunched by the ladder, then the lead owns it, Main hears only after that, and the ledger names the steps"
}

test_a_ready_recon_draft_is_forwarded_to_its_critic() {
  local m w row draft=/drafts/rc/report.md CYCLE_POLLS=100 PANES='1 2 3 4'
  m=$(home critic-forward)
  : > "$m/real-steer"
  # rc's critic was started before this draft; rd's after it, so rd's critic already has its draft.
  printf 'kind=scout\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/rc.meta"
  printf 'kind=scout\nbackend=tmux\nwindow=fake:2\nharness=claude\nspawn_gen=s1000.1.1\n' > "$m/state/rc-critic.meta"
  printf 'kind=scout\nbackend=tmux\nwindow=fake:3\nharness=claude\n' > "$m/state/rd.meta"
  printf 'kind=scout\nbackend=tmux\nwindow=fake:4\nharness=claude\nspawn_gen=s%s.1.1\n' "$(($(date +%s) + 60))" > "$m/state/rd-critic.meta"
  printf 'needs-decision [at=%s]: draft 2 ready for critic round 2 - %s\n' "$(date +%s)" "$draft" > "$m/state/rc.status"
  printf 'needs-decision [at=%s]: draft ready for the separate critic - /drafts/rd/report.md\n' "$(date +%s)" > "$m/state/rd.status"
  for w in rc rd; do prime_status_seen "$m/state" "$m/state/$w.status"; done
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/rc" -a -e "$m/state/.waiting-timers/rd"
  backdate "$m" rc 3
  backdate "$m" rd 3
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/rc" -a ! -e "$m/state/.waiting-timers/rd"
  grep -l "Recon rc declared its draft ready for your next round: draft 2 ready for critic round 2 - $draft" "$m/state/rc-critic.inbox/"*.msg >/dev/null 2>&1 \
    || fail "the draft did not reach its critic: $(cat "$m/state/rc-critic.inbox/"*.msg 2>&1; cat "$m/err")"
  grep -q '^resolved \[key=default\].*forwarded to the critic rc-critic' "$m/state/rc.status" \
    || fail "the forward did not close the draft decision: $(cat "$m/state/rc.status")"
  [ ! -d "$m/state/rd-critic.inbox" ] || ! ls "$m/state/rd-critic.inbox/"*.msg >/dev/null 2>&1 \
    || fail "a critic that already had the draft was sent it again: $(cat "$m/state/rd-critic.inbox/"*.msg)"
  grep -q '^resolved \[key=default\].*rd-critic already has this draft' "$m/state/rd.status" \
    || fail "a draft its critic already had was left open: $(cat "$m/state/rd.status")"
  ! grep -qE 'waiting-state r[cd] ' "$m/events" || fail "a forwarded draft woke a model: $(cat "$m/events")"
  row=$(ledger_row "$m" rc)
  printf '%s\n' "$row" | grep -qE '	owner	forward	changed state$' \
    || fail "the ledger has no row for the forwarded draft: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  printf 'critic forward: cleared in %s min, no model turn\n' "$(printf '%s' "$row" | cut -f5)"
  pass "a ready Recon draft is forwarded to its critic and its decision closed by the ladder, a critic that has it is not sent it twice, and the ledger holds the minutes"
}

test_a_lane_blocked_for_the_herdr_lab_section_is_relaunched_once_with_it() {
  local m n CYCLE_POLLS=100 PANES='1 2'
  m=$(home herdr-lab)
  : > "$m/real-steer"
  # wl's brief has no lab section; wk's brief has it already, so its blocked line is not this state.
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/wl.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:2\nharness=claude\n' > "$m/state/wk.meta"
  mkdir -p "$m/data/wl" "$m/data/wk"
  printf '# Task\n\n# Herdr lifecycle declaration - NOT ENABLED\nGate text.\n\n# Setup\n' > "$m/data/wl/brief.md"
  printf '# Herdr isolation - HARD SAFETY CONTRACT\n\n# Setup\n' > "$m/data/wk/brief.md"
  for n in wl wk; do
    printf 'blocked [at=%s] [key=lab]: needs --herdr-lab in my brief to drive the panes\n' "$(date +%s)" > "$m/state/$n.status"
    prime_status_seen "$m/state" "$m/state/$n.status"
  done
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/wl" -a -e "$m/state/.waiting-timers/wk"
  backdate "$m" wl 3
  cycle_for "$m" 120 grep -q '^jg-control wl relaunch --note ' "$m/sent"
  grep -q '^jg-control wl relaunch --note The watcher relaunched you because you were blocked on a brief with no Herdr lab section.* --herdr-lab$' "$m/sent" \
    || fail "the blocked lane was not relaunched with the lab section: $(cat "$m/sent" 2>&1; cat "$m/err"; cat "$m/state/wl.status"; ls -la "$m/state/.waiting-timers/.acted/"; cat "$m/state/.waiting-timers/.acted/wl.relaunch.log")"
  [ "$(grep -c '^jg-control wl relaunch' "$m/sent")" = 1 ] || fail "the lane was relaunched more than once: $(cat "$m/sent")"
  grep -q '^resolved \[key=lab\]' "$m/state/wl.status" || fail "the blocked decision was left open: $(cat "$m/state/wl.status")"
  grep -qx 'herdr-lab	[0-9]*	rebrief	[0-9]*' "$m/state/.waiting-timers/.acted/wl" \
    || fail "the step was not recorded: $(cat "$m/state/.waiting-timers/.acted/wl" 2>&1)"
  ! grep -q '^jg-control wk ' "$m/sent" 2>/dev/null || fail "a lane whose brief has the section was relaunched: $(cat "$m/sent")"
  pass "a lane blocked for the Herdr lab section is answered and relaunched once with it; a lane that has it is left alone"
}

# Account outage (core/wait-timers/README.md "Known next steps"): the pinned Claude
# account dies, and the watcher moves the lanes to the owner's next recorded
# account, or only raises its one card when he recorded none.

# A home pinned to account a, whose Claude CLI answers PONG on any account but a.
# w1 and w2 are working on a, wd is finished on a, wo works on b (another account).
account_outage_home() {  # <name> -> home path
  local m
  m=$(home "$1")
  mkdir -p "$m/acct/a" "$m/acct/b" "$m/acct/c"
  printf '%s\n' "$m/acct/a" > "$m/config/claude-account"
  cat > "$m/fakebin/claude" <<'SH'
#!/usr/bin/env bash
case "${CLAUDE_CONFIG_DIR:-}" in
  */a|*/c) echo "Claude Code can't use your Claude subscription: payment past due"; exit 1 ;;
esac
echo PONG
SH
  chmod +x "$m/fakebin/claude"
  local n=0 w
  for w in w1:working w2:working wd:done wo:working; do
    n=$((n + 1))
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\naccount=%s\n' "$n" "$m/acct/$([ "${w%%:*}" = wo ] && echo b || echo a)" > "$m/state/${w%%:*}.meta"
    printf '%s [at=1]: on it\n' "${w#*:}" > "$m/state/${w%%:*}.status"
    prime_status_seen "$m/state" "$m/state/${w%%:*}.status"
  done
  printf 'Claude Code can'"'"'t use your Claude subscription\n> \n' > "$m/panes/1"
  cp "$m/panes/1" "$m/panes/2"
  cp "$m/panes/1" "$m/panes/3"
  printf '%s\n' "$m"
}

test_a_dead_account_moves_the_lanes_to_the_recorded_fallback_with_no_model_turn() {
  local m row CYCLE_POLLS=100 PANES='1 2 3 4' ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(account_outage_home account-down)
  printf '%s\n%s\n' "$m/acct/a" "$m/acct/b" > "$m/config/claude-account-fallbacks"
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/w1" -a -e "$m/state/.waiting-timers/w2"
  [ -f "$m/state/.wait-sources/w1.account" ] || fail "a subscription error in the pane raised no account wait: $(ls -a "$m/state/.wait-sources" 2>&1)"
  backdate "$m" w1 31
  backdate "$m" w2 31
  cycle_for "$m" 120 grep -q 'relaunch.*w2' "$m/state/.account-outage/relaunch.log"
  [ "$(cat "$m/config/claude-account")" = "$m/acct/b" ] \
    || fail "the pin did not move to the recorded fallback: $(cat "$m/config/claude-account"; cat "$m/err")"
  cycle_for "$m" 20 test "$(grep -c '^jg-control .* relaunch ' "$m/sent" 2>/dev/null || echo 0)" -ge 2
  [ "$(grep -cE '^jg-control w[12] relaunch --note ' "$m/sent")" = 2 ] \
    || fail "a lane on the dead account was not relaunched: $(cat "$m/sent" 2>&1; cat "$m/state/.account-outage/relaunch.log" 2>&1)"
  ! grep -qE '^jg-control (wd|wo) ' "$m/sent" || fail "a finished lane or a lane on another account was relaunched: $(cat "$m/sent")"
  [ "$(grep -c '^raise ' "$m/cards")" = 1 ] || fail "the outage did not raise exactly one card: $(cat "$m/cards" 2>&1)"
  grep -q 'Renew the Claude account?' "$m/cards" || fail "the card does not ask the owner to renew: $(cat "$m/cards")"
  ! grep -q 'waiting-state' "$m/events" 2>/dev/null || fail "the recovery woke a model: $(cat "$m/events")"
  # The relaunched lanes show a quiet pane: the waits clear and the ledger holds the minutes.
  printf 'working on it\n> \n' > "$m/panes/1"
  cp "$m/panes/1" "$m/panes/2"
  printf 'working [at=%s]: back on the new account\n' "$(date +%s)" | tee -a "$m/state/w1.status" >> "$m/state/w2.status"
  cycle_for "$m" 120 test ! -e "$m/state/.waiting-timers/w1" -a ! -e "$m/state/.waiting-timers/w2"
  row=$(ledger_row "$m" w1)
  printf '%s\n' "$row" | grep -qE '	[0-9]+\.[0-9]	(owner|card)	recover	' \
    || fail "the ledger has no row with the outage minutes: $(cat "$m/data/metrics/escalations.tsv" 2>&1)"
  printf 'account outage: cleared in %s min, no model turn\n' "$(printf '%s' "$row" | cut -f5)"
  pass "a dead account moves its lanes to the next recorded fallback, relaunches only them, raises one card and records the minutes, with no model turn"
}

test_an_empty_fallback_list_raises_one_card_and_changes_nothing() {
  local m listed CYCLE_POLLS=100 PANES='1 2 3 4' ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  for listed in empty none; do
    m=$(account_outage_home "account-down-$listed")
    [ "$listed" = none ] || : > "$m/config/claude-account-fallbacks"
    cycle_for "$m" 120 test -e "$m/state/.waiting-timers/w1" -a -e "$m/state/.waiting-timers/w2"
    backdate "$m" w1 31
    backdate "$m" w2 31
    cycle_for "$m" 120 test -s "$m/cards"
    cycle "$m"
    [ "$(cat "$m/config/claude-account")" = "$m/acct/a" ] || fail "($listed) the pin moved with no recorded fallback: $(cat "$m/config/claude-account")"
    ! grep -q '^jg-control ' "$m/sent" 2>/dev/null || fail "($listed) a pane was relaunched with no recorded fallback: $(cat "$m/sent")"
    [ "$(grep -c '^raise ' "$m/cards")" = 1 ] || fail "($listed) the outage did not raise exactly one card: $(cat "$m/cards" 2>&1)"
  done
  pass "with no recorded fallback the outage raises one card, moves no pin and relaunches nothing"
}

test_a_working_account_is_not_treated_as_down() {
  local m CYCLE_POLLS=100 PANES='1 2 3 4' ALERT_SECS=30 ESCALATE_SECS=90 CARD_SECS=600
  m=$(account_outage_home account-up)
  printf '%s\n%s\n' "$m/acct/a" "$m/acct/b" > "$m/config/claude-account-fallbacks"
  printf '%s\n' "$m/acct/b" > "$m/config/claude-account"
  sed -i "s|acct/a|acct/b|" "$m/state/w1.meta" "$m/state/w2.meta"
  cycle_for "$m" 120 test -e "$m/state/.waiting-timers/w1"
  backdate "$m" w1 31
  cycle "$m"; cycle "$m"
  [ "$(cat "$m/config/claude-account")" = "$m/acct/b" ] || fail "an account that answers its probe was switched away: $(cat "$m/config/claude-account")"
  ! grep -q '^jg-control ' "$m/sent" 2>/dev/null || fail "a lane on a working account was relaunched: $(cat "$m/sent")"
  [ ! -s "$m/cards" ] || fail "a working account raised an outage card: $(cat "$m/cards")"
  pass "an account that answers its probe is not treated as down"
}


test_a_silent_worker_is_rung_and_clears_with_no_model_turn
test_an_unanswered_ring_is_relaunched_then_reaches_main
test_a_ready_recon_draft_is_forwarded_to_its_critic
test_a_dead_account_moves_the_lanes_to_the_recorded_fallback_with_no_model_turn
test_a_lane_blocked_for_the_herdr_lab_section_is_relaunched_once_with_it
test_an_empty_fallback_list_raises_one_card_and_changes_nothing
test_a_working_account_is_not_treated_as_down
