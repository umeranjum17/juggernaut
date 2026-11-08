#!/usr/bin/env bash
# homes.sh - the fixture fleet of the fleet-autopilot journey (sourced by run.sh; `homes.sh runner <home>` is a pane command).
#
# A home is a git worktree of ONE fixture clone of the checkout under test, at its HEAD: the same shape as the real
# fleet (every home is a checkout of this repository holding private state/, data/, config/ and projects/). Each home
# has its own copy of an initialised Beads store, one fixture project registered local-trunk, and a Herdr workspace
# whose first pane runs that home's runner: the real bin/jg-watch.sh, or for the first FA_LEADS homes the real
# bin/jg-watch-checkpoint.sh (a lead simulated with no model), followed by the shell-only drain and acknowledgement
# of whatever wake it returned. The runner never starts a model.
# shellcheck shell=bash

FA_PROJECT=fixproj

home_dir() { printf '%s/homes/home-%02d' "$LAB" "$1"; }

# homes_provision <count>: the clone, the homes, their stores and projects (no trunk yet), the list file $LAB/homes.list
homes_provision() {
  local n=$1 i h tip tpl
  tip=$(git -C "$ROOT" rev-parse HEAD) || return 1
  git clone -q --no-checkout "$ROOT" "$LAB/clone" && git -C "$LAB/clone" checkout -q --detach "$tip" || return 1
  JG_BEADS_BD=${JG_BEADS_TEST_BD:-$(command -v bd)}; JG_BEADS_DOLT=${JG_BEADS_TEST_DOLT:-$(command -v dolt)}
  [ -n "$JG_BEADS_BD" ] && [ -n "$JG_BEADS_DOLT" ] || { echo "fleet-autopilot: bd and dolt are required (JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT)" >&2; return 1; }
  export JG_BEADS_BD JG_BEADS_DOLT
  tpl=$LAB/beads-tpl/jg; mkdir -p "$tpl"
  BEADS_DIR=$tpl/.beads "$ROOT/bin/jg-beads.sh" init --prefix jg > "$LAB/beads-init.log" 2>&1 || { cat "$LAB/beads-init.log" >&2; return 1; }
  : > "$LAB/homes.list"
  for i in $(seq 1 "$n"); do
    h=$(home_dir "$i")
    git -C "$LAB/clone" worktree add -q --detach "$h" "$tip" || return 1
    mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"
    cp -a "$tpl" "$LAB/store-$i" && printf '%s\n' "$LAB/store-$i/.beads" > "$h/config/beads-dir" || return 1
    printf 'gate-full=true\ngate-lint=true\ngate-verify=true\n' > "$h/config/trunk-policy"
    # The live hook is the recording stand-in for the home mover (slice T2): it names the home and the commit it was asked to move to.
    # shellcheck disable=SC2016 # the hook body is written literally and expands when the hook runs
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$2" "$(date +%%s)" >> "%s/live-moves"\n' "$h/data" > "$h/config/live-hook.$FA_PROJECT"
    chmod +x "$h/config/live-hook.$FA_PROJECT"
    git init -q -b main "$h/projects/$FA_PROJECT" && printf '# %s\n' "$FA_PROJECT" > "$h/projects/$FA_PROJECT/README.md" \
      && git -C "$h/projects/$FA_PROJECT" add README.md && git -C "$h/projects/$FA_PROJECT" commit -q -m initial || return 1
    printf '%s\n' "$h" >> "$LAB/homes.list"
  done
}

# home_env <home>: the environment that makes bin/ scripts run AS that home
home_env() {
  printf 'JG_HOME=%q JG_ROOT_OVERRIDE=%q JG_STATE_OVERRIDE=%q JG_DATA_OVERRIDE=%q JG_CONFIG_OVERRIDE=%q' \
    "$1" "$1" "$1/state" "$1/data" "$1/config"
}
home_run() {  # <home> <command...>: run a command as that home, with the tripwire PATH
  local h=$1; shift
  ( cd "$h" && PATH="$LAB/shims:$PATH" JG_HOME=$h JG_ROOT_OVERRIDE=$h JG_STATE_OVERRIDE=$h/state \
    JG_DATA_OVERRIDE=$h/data JG_CONFIG_OVERRIDE=$h/config "$@" )
}

# homes_register: step 2 - register the fixture project local-trunk in every home (no trunk exists yet)
homes_register() {
  local h
  while IFS= read -r h; do printf -- '- %s [local-trunk] - fleet-autopilot lab fixture\n' "$FA_PROJECT" > "$h/data/projects.md"; done < "$LAB/homes.list"
}

# homes_init_trunk: the trunk of every home, made by hand; returns 1 on a home that fails
homes_init_trunk() {
  local h
  while IFS= read -r h; do home_run "$h" "$h/bin/jg-trunk.sh" init "$h/projects/$FA_PROJECT" > "$h/data/trunk-init.log" 2>&1 || return 1; done < "$LAB/homes.list"
}

# homes_start <leads>: one Herdr workspace per home; the pane runs this file's `runner`
homes_start() {
  local leads=$1 i=0 h ws pane mode
  while IFS= read -r h; do
    i=$((i + 1)); mode=watch; [ "$i" -gt "$leads" ] || mode=lead
    read -r ws _ pane < <(lab_workspace "home-$(printf '%02d' "$i")" "$h") || return 1
    printf '%s %s\n' "$ws" "$pane" > "$h/data/lab-workspace"
    lab_pane "$pane" "$(lab_env) $(home_env "$h") JG_FAST_CHECK_INTERVAL=${FA_FAST:-3} FA_CHECKPOINT=${FA_CHECKPOINT:-180} bash $FA_DIR/homes.sh runner $h $mode"
  done < "$LAB/homes.list"
}

# runner <home> <watch|lead>: arm, absorb the wake in shell, acknowledge it, arm again. Every round is one line in data/lab-runner.log.
runner() {
  local h=$1 mode=$2 out rc ack parts
  cd "$h" || exit 1
  while :; do
    if [ "$mode" = lead ]; then out=$("$h/bin/jg-watch-checkpoint.sh" --seconds "${FA_CHECKPOINT:-180}" 2>&1); rc=$?
    else out=$("$h/bin/jg-watch.sh" 2>&1); rc=$?; fi
    printf '%s rc=%s %s\n' "$(date +%s)" "$rc" "$(printf '%s' "$out" | head -n 1 | cut -c1-200)" >> "$h/data/lab-runner.log"
    out=$("$h/bin/jg-wake-next.sh" 2>&1) || true
    ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_NEXT_ACK: //p' | tail -n 1)
    if [ -n "$ack" ] && [ "$ack" != none ]; then
      read -r -a parts <<< "$ack"
      "$h/${parts[0]}" "${parts[@]:1}" >> "$h/data/lab-runner.log" 2>&1 || true
    fi
    sleep 1
  done
}
[ "${BASH_SOURCE[0]}" != "$0" ] || { set -u; [ "${1:-}" = runner ] && runner "$2" "$3"; }
