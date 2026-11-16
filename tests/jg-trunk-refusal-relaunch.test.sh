#!/usr/bin/env bash
# Integration test for core/trunk-landing/refusal-reach.sh, through the real caller (the landing check's sweep): a lane the landing
# returns for its own fault gets ONE new agent when it has none.
# Through tests/jg-trunk-fixture.sh it runs the check and bin/jg-trunk.sh, and it stands in for bin/jg-control.sh (the relaunch it is
# asked for), bin/jg-crew-state.sh (whether the agent runs) and bin/jg-send.sh.
#
# R1 A red the lane caused, for a lane whose agent was stopped at Built (a verified exit record): one relaunch with the refusal as its
#    note, no plain steer, and a later sweep of the same head starts no second agent.
# R2 A conflict, for a lane whose agent is gone by the crew state's own reading (it died): the same one relaunch.
# R3 The same red for a lane whose agent runs: no relaunch, the worker is steered as before.
# R4 A refusal that is not the lane's fault (the reference-transaction hook, the environment) for a stopped lane: no relaunch.
# R5 A new head with a new refusal gets its own new agent: the one agent is one per refused head.
# R6 A conflict only in the registry file every lane shares (`.done-done.yaml`), for a stopped lane: the ticket waits on the lead once,
#    no new agent and no steer (the lane's own relaunch did not clear it: jgp-r1-ledger-s1 waited 1,087 minutes). A conflict that also
#    touches the lane's own file stays the lane's.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# home_world <name>: the check runs the scripts of its own home's bin, with the two stand-ins added.
home_world() {
  world "$1"; cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"; rm -f "$W/send-calls"
  # shellcheck disable=SC2016 # the stand-in expands when it runs
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "$1" "$*" >> "%s/relaunch-calls"\n' "$W" > "$HOME_D/bin/jg-control.sh"
  # shellcheck disable=SC2016 # the stand-in expands when it runs
  printf '#!/usr/bin/env bash\nif [ -e "%s/alive-$1" ]; then echo "state: working · source: pane · agent busy"; else echo "state: unknown · source: pane · backend target gone: x (agent gone, pane shell remains)"; fi\n' "$W" > "$HOME_D/bin/jg-crew-state.sh"
  chmod +x "$HOME_D/bin/jg-control.sh" "$HOME_D/bin/jg-crew-state.sh"
}
settle() {
  local _
  for _ in $(seq 1 600); do
    if ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && ! compgen -G "$HOME_D/state/.trunk-run-*.lock" >/dev/null; then break; fi
    sleep 0.2
  done
}
relaunches() { { grep -c "^$1"$'\t' "$W/relaunch-calls" 2>/dev/null || :; } | head -n 1 | grep . || echo 0; }
steers() { { grep -c "^$1"$'\t' "$W/send-calls" 2>/dev/null || :; } | head -n 1 | grep . || echo 0; }
stopped() { printf '%s\n' 1000 > "$HOME_D/state/$1.exit"; }  # the verified exit record jg-control.sh exit writes
sweeps() { sweep >/dev/null; settle; sweep >/dev/null; settle; }

test_a_red_the_lane_caused_starts_one_new_agent_for_a_lane_stopped_at_built() {
  local h
  home_world red
  lane r BAD; stopped r; h=$(git -C "$PROJ" rev-parse fm/r)
  sweeps
  [ "$(relaunches r)" = 1 ] || fail "r must get one new agent: $(relaunches r) relaunches"
  assert_contains "$(grep "^r" "$W/relaunch-calls")" "The lander refused your lane r" "the refusal is the new agent's first instruction"
  assert_contains "$(grep "^r" "$W/relaunch-calls")" "gate 'full' failed" "the refusal names the failing gate"
  [ "$(steers r)" = 0 ] || fail "the relaunch note is the steer, so none is sent for the head: $(cat "$W/send-calls")"
  sweeps
  [ "$(relaunches r)" = 1 ] || fail "a second sweep of the same head must start no second agent: $(relaunches r)"
  [ -f "$HOME_D/data/jg-trunk-landing/r.$h.refusal.relaunched" ] || fail "the one agent of the head is recorded"
  pass 'a red the lane caused starts one new agent for a lane stopped at Built, with the refusal as its note, and no second for the head'
}

test_a_conflict_starts_one_new_agent_for_a_lane_whose_agent_died() {
  home_world conflict
  lane c three; printf 'working [at=1]: still at it\n' >> "$HOME_D/state/c.status"
  lane a one; sweeps
  [ "$(git -C "$PROJ" show trunk:work.txt)" = one ] || fail "lane a must land first"
  ready c; sweeps
  [ "$(relaunches c)" = 1 ] || fail "c must get one new agent: $(relaunches c)"
  assert_contains "$(grep "^c" "$W/relaunch-calls")" "conflicts with trunk in: work.txt" "the conflict is the first instruction"
  pass 'a conflict starts one new agent for a lane whose agent is gone by the crew state'
}

test_a_lane_whose_agent_runs_is_steered_and_not_relaunched() {
  home_world running
  lane w BAD; : > "$W/alive-w"
  sweeps
  [ "$(relaunches w)" = 0 ] || fail "a running agent is never replaced: $(relaunches w)"
  [ "$(steers w)" -ge 1 ] || fail "its worker is steered as before"
  pass 'a lane whose agent runs is steered and not relaunched'
}

test_a_refusal_that_is_not_the_lanes_fault_starts_no_agent() {
  local h
  home_world env
  mkdir -p "$W/repository-hooks"
  printf '#!/bin/sh\nexit 0\n' > "$W/repository-hooks/reference-transaction"; chmod 755 "$W/repository-hooks/reference-transaction"
  git -C "$PROJ" config core.hooksPath "$W/repository-hooks"
  lane e one; stopped e; h=$(git -C "$PROJ" rev-parse fm/e)
  sweeps
  case $(cat "$HOME_D/data/jg-trunk-landing/e.$h.state") in final*'not the trunk guard'*) ;; *) fail "e must be refused for the hook" ;; esac
  [ "$(relaunches e)" = 0 ] || fail "an environment refusal starts no agent: $(relaunches e)"
  pass 'a refusal that is not the lane fault (the hook) starts no agent'
}

test_a_new_head_with_a_new_refusal_gets_its_own_agent() {
  home_world head
  lane n BAD; stopped n; sweeps
  [ "$(relaunches n)" = 1 ] || fail "the first head gets an agent"
  relane n BAD2; ready n; sweeps
  [ "$(relaunches n)" = 2 ] || fail "the new refused head gets its own agent: $(relaunches n)"
  pass 'a new refused head gets its own new agent, one per head'
}

# also_in <id> <file> <content>: the lane's one commit also changes <file>.
also_in() { printf '%s\n' "$3" > "$W/lanes/$1/$2"; git -C "$W/lanes/$1" add "$2"; git -C "$W/lanes/$1" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit; prove "$1"; }

test_a_conflict_only_in_the_shared_registry_goes_to_the_lead_and_not_to_the_lane() {
  home_world shared
  lane s two .done-done.yaml; stopped s; printf 'working [at=1]: still at it\n' >> "$HOME_D/state/s.status"
  lane a one .done-done.yaml; sweeps
  [ "$(git -C "$PROJ" show trunk:.done-done.yaml)" = one ] || fail "lane a must land first"
  ready s; sweeps; sweeps
  [ "$(relaunches s)" = 0 ] || fail "a shared-file conflict starts no agent: $(relaunches s)"
  [ "$(steers s)" = 0 ] || fail "a shared-file conflict steers no worker: $(cat "$W/send-calls")"
  [ "$(grep -c '^wait s lead blocker' "$W/backlog-calls")" = 1 ] || fail "the ticket waits on the lead once: $(cat "$W/backlog-calls")"
  pass 'a conflict only in the shared registry puts the ticket on the lead once, with no agent and no steer'
}

test_a_conflict_touching_the_lanes_own_file_too_stays_the_lanes() {
  home_world mixed
  lane m two; also_in m .done-done.yaml two; stopped m; printf 'working [at=1]: still at it\n' >> "$HOME_D/state/m.status"
  lane a one; also_in a .done-done.yaml one; sweeps
  [ "$(git -C "$PROJ" show trunk:work.txt)" = one ] || fail "lane a must land first"
  ready m; sweeps
  [ "$(relaunches m)" = 1 ] || fail "a conflict that also touches the lane's own file is the lane's: $(relaunches m)"
  ! grep -q '^wait m lead' "$W/backlog-calls" 2>/dev/null || fail "the lead is not asked for the lane's own conflict"
  pass 'a conflict that also touches the lane own file stays the lane: one new agent, no wait on the lead'
}

test_a_red_the_lane_caused_starts_one_new_agent_for_a_lane_stopped_at_built
test_a_conflict_only_in_the_shared_registry_goes_to_the_lead_and_not_to_the_lane
test_a_conflict_touching_the_lanes_own_file_too_stays_the_lanes
test_a_conflict_starts_one_new_agent_for_a_lane_whose_agent_died
test_a_lane_whose_agent_runs_is_steered_and_not_relaunched
test_a_refusal_that_is_not_the_lanes_fault_starts_no_agent
test_a_new_head_with_a_new_refusal_gets_its_own_agent
printf 'jg-trunk-refusal-relaunch: ok\n'
