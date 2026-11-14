#!/usr/bin/env bash
# Integration test: a wait for a ticket ends by itself when that ticket lands (jg-7v6uw slice 12).
# Through tests/jg-trunk-fixture.sh it runs the real core/trunk-landing/trunk-landing.sh over real git lanes, and reads the real
# core/wait-timers/bin/jg-wait-actions-lib.sh; only the steer endpoint (bin/jg-send.sh) is a recorder that keeps jg-send's
# documented --resolve-key contract (it appends the `resolved [key=...]` line to the lane's status).
#
# T1 Lane B is blocked `waits-for: A`; A lands; B gets ONE steer and its blocker closes with a `resolved` line, in the landing's own
#    run, with no owner wake queued. A lane that waits for another ticket, or that is blocked for another reason, is left alone.
# T2 A lane that declares its wait after A landed is taken by the ladder's waits-for row at the owner alert (the backstop).
# T3 The wait is quiet while the awaited ticket's lane still runs, and rings again once that lane is gone without landing.
# The done-done journey journeys/wait-next-step.sh runs this file and seals its output.
# shellcheck disable=SC2030,SC2031,SC2329 # the helpers run in subshells on purpose; the fixture state is shared by design
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# shellcheck disable=SC2016 # the recorder body is written out verbatim and expands when it runs
rig_send() {  # the steer recorder in the home's own bin, which the landing check calls
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  cat > "$HOME_D/bin/jg-send.sh" <<SH
#!/usr/bin/env bash
t=\$1; shift
printf '%s\\t%s\\n' "\$t" "\$*" >> "$W/steers"
if [ "\${1:-}" = --resolve-key ]; then printf 'resolved [key=%s]: answered: %s\\n' "\$2" "\${3:0:60}" >> "$HOME_D/state/\$t.status"; fi
SH
  chmod +x "$HOME_D/bin/jg-send.sh"
}

# waiter <id> <status line>: a lane that is working (not done), with the given declaration as its last line.
waiter() {
  jg_write_meta "$HOME_D/state/$1.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$1" "kind=ship"
  printf '%s\n' "$2" > "$HOME_D/state/$1.status"
}

steers_for() { grep -c "^$1	" "$W/steers" 2>/dev/null || true; }

# The ladder's own view of a task, in a shell that sources the same libraries the watcher does.
ladder() {  # <task> <function and args...>: runs in the home's state, prints what the function prints
  local task=$1; shift
  ( export JG_HOME="$HOME_D" STATE="$HOME_D/state" _JG_WAIT_TIMER_DIR="$HOME_D/bin" JG_DATA_OVERRIDE="$HOME_D/data"
    # shellcheck disable=SC1091
    . "$HOME_D/bin/jg-classify-lib.sh"
    # shellcheck disable=SC1091
    . "$ROOT/core/wait-timers/bin/jg-wait-actions-lib.sh"
    "$@" "$task" )
}

test_a_lane_waiting_for_a_ticket_resumes_when_it_lands() {
  local base start
  world resume; rig_send; base=$(tip); : > "$W/steers"
  waiter b1 'blocked [at=1000] [key=wf]: waits-for: a1 my change builds on a1'
  waiter c1 'blocked [at=1000] [key=other]: waits-for: zz9 another ticket'
  waiter d1 'blocked [at=1000] [key=vendor]: waiting on the vendor, nothing about a ticket'
  lane a1 one f1.txt
  start=$(date +%s)
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 1 ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 1 ] || fail "A must land first: $(cat "$HOME_D"/data/jg-trunk-landing/*.log 2>/dev/null)"
  # The landing writes its state, then resumes the waiters; the steer follows within the same run.
  for _ in $(seq 1 50); do [ "$(steers_for b1)" -ge 1 ] && break; sleep 0.2; done
  [ "$(steers_for b1)" = 1 ] || fail "B gets exactly one steer when A lands, got $(steers_for b1): $(cat "$W/steers")"
  grep -q "^b1	--resolve-key wf Ticket a1, the one you waited for, has landed" "$W/steers" || fail "the steer closes B's blocker key and names A: $(cat "$W/steers")"
  grep -q '^resolved \[key=wf\]' "$HOME_D/state/b1.status" || fail "B's blocker closes with a resolved line: $(cat "$HOME_D/state/b1.status")"
  [ -z "$(ladder b1 jg_wait_action_waiting_on)" ] || fail "B holds no open wait after the landing"
  [ "$(steers_for c1)" = 0 ] && [ "$(steers_for d1)" = 0 ] || fail "a lane that waits for another ticket, or for no ticket, is left alone: $(cat "$W/steers")"
  [ "$(( $(date +%s) - start ))" -lt 60 ] || fail "B's answer must come inside 60 s of the landing check starting"
  [ ! -s "$HOME_D/data/jg-trunk-landing/resume.log" ] || fail "the resume reported an error: $(cat "$HOME_D/data/jg-trunk-landing/resume.log")"
  ! grep -qsE '(^|[^A-Za-z0-9._-])b1([^A-Za-z0-9._-]|$)' "$HOME_D"/state/.wake-queue "$HOME_D"/state/.wake-bus.outbox.jsonl || fail "no owner wake is queued for this wait: $(cat "$HOME_D"/state/.wake-queue)"
  # A second landing does not steer B again: its blocker is closed.
  lane a2 two f2.txt
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 2 ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  [ "$(steers_for b1)" = 1 ] || fail "a later landing leaves B alone, got $(steers_for b1) steers"
  pass 'a lane blocked waits-for A gets one steer and a resolved line when A lands, with no owner wake'
}

test_the_ladder_row_takes_a_wait_declared_after_the_landing() {
  local state
  world backstop; rig_send; : > "$W/steers"
  mkdir -p "$HOME_D/data/jg-trunk-landing"
  printf 'landed cleaned up\n' > "$HOME_D/data/jg-trunk-landing/a9.$(printf '%040d' 7).state"
  waiter e1 'blocked [at=1000] [key=late]: waits-for: a9 declared after a9 landed'
  state=$(ladder e1 _wait_state_of) || true
  [ "$state" = waits-for ] || fail "the wait has the waits-for row once its ticket landed, got [$state]"
  ( export JG_HOME="$HOME_D" STATE="$HOME_D/state" _JG_WAIT_TIMER_DIR="$HOME_D/bin" JG_DATA_OVERRIDE="$HOME_D/data"
    # shellcheck disable=SC1091
    . "$HOME_D/bin/jg-classify-lib.sh"
    # shellcheck disable=SC1091
    . "$ROOT/core/wait-timers/bin/jg-wait-actions-lib.sh"
    age_of() { echo 0; }; jg_meta_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
    jg_wait_action_next e1 "$(date +%s)" '' blocked late 'blocked [key=late]: waits-for: a9 declared after a9 landed' \
      && [ "$WAIT_ACT_NEXT" = resume ] && [ "$WAIT_ACT_NEXT_STATE" = waits-for ] \
      && jg_wait_action_take e1 waits-for resume "$(date +%s)" late 'blocked [key=late]: waits-for: a9 declared after a9 landed' 0 ) \
    || fail "the ladder takes the resume step for a wait whose ticket landed"
  [ "$(steers_for e1)" = 1 ] || fail "the backstop sends one steer: $(cat "$W/steers")"
  grep -q '^resolved \[key=late\]' "$HOME_D/state/e1.status" || fail "the backstop closes the blocker"
  # A head that is not a full hash is no landing record, and a ticket whose id is a prefix of another is not that ticket.
  mkdir -p "$HOME_D/data/jg-trunk-landing"
  printf 'landed cleaned up\n' > "$HOME_D/data/jg-trunk-landing/a8.12.$(printf '%040d' 7).state"
  ladder a8 jg_wait_action_landed && fail "a landing record of the ticket a8.12 is not a landing of a8"
  pass 'the ladder row resumes a lane whose wait was declared after the landing; a record of another ticket is not a landing'
}

test_the_wait_is_quiet_while_the_awaited_lane_runs_and_rings_when_it_is_gone() {
  world quiet; rig_send
  waiter f1 'blocked [at=1000] [key=wq]: waits-for: g1 g1 is still building'
  ladder f1 jg_wait_action_awaiting && fail "with no lane for g1 in this home the wait is not quiet"
  jg_write_meta "$HOME_D/state/g1.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/g1" "kind=ship"
  ladder f1 jg_wait_action_awaiting || fail "while g1's lane runs the wait is quiet"
  mkdir -p "$HOME_D/data/jg-trunk-landing"
  printf 'landed cleaned up\n' > "$HOME_D/data/jg-trunk-landing/g1.$(printf '%040d' 9).state"
  ladder f1 jg_wait_action_awaiting && fail "once g1 landed the wait is no longer quiet (the resume takes it)"
  pass 'a wait for a running lane is quiet; with no lane or after the landing it is not'
}

# What the ladder reads: the table state of a declared wait on <task>.
_wait_state_of() {  # <task>
  local row key
  row=$(jg_wait_action_waiting_on "$1") || return 1
  key=${row%%$'\t'*}
  jg_wait_action_state "$1" '' blocked "$key" "blocked [key=$key]: waits-for: ${row#*$'\t'}"
}

test_a_lane_waiting_for_a_ticket_resumes_when_it_lands
test_the_ladder_row_takes_a_wait_declared_after_the_landing
test_the_wait_is_quiet_while_the_awaited_lane_runs_and_rings_when_it_is_gone
