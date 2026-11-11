#!/usr/bin/env bash
# lanes.sh - the lanes of the fleet-autopilot journey (sourced by run.sh; `lanes.sh worker ...` is a pane command).
#
# A lane is a shell worker in its own Herdr tab of its home's workspace. It makes ONE commit on a branch off the local
# trunk tip, publishes the completion receipt with the real core/receipts/bin/jg-run-receipt.sh, and appends `done`
# through the real status append owner (bin/jg-lavish-guard.sh --append). Nothing lands it: the home's watcher runs
# core/trunk-landing, which lands the branch and cleans the lane up unforced. The lane's meta carries the Herdr endpoint
# (backend, session, workspace, tab, pane) exactly as a spawn records it, so teardown closes this lane's own tab.
# The last lane publishes NO receipt: it is the lane whose sealed run is missing.
# shellcheck shell=bash

lane_id() { printf 'lane-%02d' "$1"; }

# lanes_start <count>: round-robin over the homes; the last lane skips its receipt
lanes_start() {
  local n=$1 i h homes=() nh skip
  while IFS= read -r h; do homes+=("$h"); done < "$LAB/homes.list"
  nh=${#homes[@]}
  for i in $(seq 1 "$n"); do
    skip=0; [ "$i" -ne "$n" ] || skip=1
    lane_start "${homes[$(( (i - 1) % nh ))]}" "$(lane_id "$i")" "$skip" || return 1
  done
}

# lane_start <home> <id> [<skip-receipt 0|1>]: one lane in its own Herdr tab of the home's workspace
lane_start() {
  local h=$1 id=$2 skip=${3:-0} proj tab pane wsid wt
  proj=$h/projects/$FA_PROJECT; wt=$LAB/lanes/$id; wsid=$(cut -d' ' -f1 "$h/data/lab-workspace")
  git -C "$proj" worktree add -q -b "fm/$id" "$wt" trunk || return 1
  read -r tab pane < <(lab_tab "$wsid" "$id" "$wt") || return 1
  {
    printf 'project=%s\nmode=local-only\nbranch=fm/%s\nworktree=%s\nspawn_gen=g-%s\n' "$proj" "$id" "$wt" "$id"
    printf 'backend=herdr\nendpoint_task_id=%s\nwindow=%s:%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$id" "$SESSION" "$pane" "$SESSION" "$wsid" "$tab" "$pane"
  } > "$h/state/$id.meta"
  printf '%s %s %s\n' "$id" "$h" "$tab" >> "$LAB/lanes.list"
  lab_pane "$pane" "$(lab_env) $(home_env "$h") FA_SKIP_SEAL=$skip bash $FA_DIR/lanes.sh worker $h $id $wt"
}

# worker <home> <id> <worktree>: the whole lane, in shell
worker() {
  local h=$1 id=$2 wt=$3 ev
  cd "$wt" || exit 1
  printf '%s %s\n' "$id" "$(date +%s)" > "change-$id.txt"
  git add "change-$id.txt" && git commit -q -m "lab change for $id" -m "ticket: $id" || exit 1
  ev=$h/data/lab-evidence-$id.txt
  printf 'commands: git commit (one commit on the trunk tip)\nresult: committed %s\nlimitations: fixture lane; no done-done sealed run yet (slices L1-L2)\n' \
    "$(git rev-parse --short HEAD)" > "$ev"
  [ "${FA_SKIP_SEAL:-0}" = 1 ] || "$h/core/receipts/bin/jg-run-receipt.sh" "$id" PASS "$ev" > "$h/data/lab-receipt-$id.log" 2>&1 || exit 1
  say_done "$h" "$id"
  [ "${FA_SKIP_SEAL:-0}" != 1 ] || sleep 3600
  # A refusal because the trunk moved (the other lane of this home landed first) is the worker's to fix, as in the
  # real flow: rebase the one commit on the latest trunk tip and prove again. Slice L4 moves this onto the lander.
  while :; do
    sleep 2
    git merge-base --is-ancestor HEAD refs/heads/trunk 2>/dev/null && break
    case $(cat "$h/data/jg-trunk-landing/$id.$(git rev-parse HEAD).state" 2>/dev/null) in
      final*moved*)
        git rebase -q refs/heads/trunk || exit 1
        "$h/core/receipts/bin/jg-run-receipt.sh" "$id" PASS "$ev" > "$h/data/lab-receipt-$id.log" 2>&1 || exit 1
        say_done "$h" "$id" ;;
    esac
  done
  sleep 3600
}
say_done() {  # <home> <id>: the worker's done line through the status append owner; the exit code is kept for the journey
  echo "done [at=$(date +%s)]: ready in branch fm/$2 (local-trunk)" | "$1/bin/jg-lavish-guard.sh" --append "$1/state/$2.status" > "$1/data/lab-done-$2.log" 2>&1
  printf '%s\n' "$?" > "$1/data/lab-done-$2.rc"
}

# lane_seal <home> <id>: the fixture rebases the lane that skipped its receipt on the latest trunk tip and proves it
lane_seal() {
  local h=$1 id=$2
  git -C "$LAB/lanes/$id" rebase -q refs/heads/trunk || return 1
  home_run "$h" "$h/core/receipts/bin/jg-run-receipt.sh" "$id" PASS "$h/data/lab-evidence-$id.txt" "$LAB/lanes/$id" > /dev/null
}

# lanes_landed <id> <home>: 0 when the lane's commit (found by its ticket line) is on the home's trunk
lanes_landed() {
  [ -n "$(git -C "$2/projects/$FA_PROJECT" log refs/heads/trunk -1 --format=%H --grep="^ticket: $1\$" 2>/dev/null)" ]
}
[ "${BASH_SOURCE[0]}" != "$0" ] || { set -u; [ "${1:-}" = worker ] && worker "$2" "$3" "$4"; }
