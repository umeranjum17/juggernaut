#!/usr/bin/env bash
# The detached jobs a tick starts (verify, nightly, live, publish) run each in its own systemd user unit when systemd-run exists, so
# that the host's cleanup of the tick's cgroup (a watcher's process-group stop, a session ending) cannot kill a verify half way. The
# unit's name is recorded per kind and project, so a tick that finds that unit still active starts nothing: one verify at a time, and a
# tip a verify is working on is not started twice. With no systemd-run (or a user manager that refuses it) the job keeps `setsid nohup`.
# Sourced by trunk-landing.sh, which sets SELF, FMH and MEM.
#
# Test seam (JG_TEST_SEAM=1 only, so a test never starts a real unit of the host): JG_TRUNK_SYSTEMD_RUN and JG_TRUNK_SYSTEMCTL name the
# tools; unset means the tool is absent and the job falls back to setsid.

# unit_tool <systemd-run|systemctl>: the tool's path, or nothing when it is absent.
unit_tool() {
  if [ "${JG_TEST_SEAM:-}" = 1 ]; then
    case $1 in systemd-run) printf '%s\n' "${JG_TRUNK_SYSTEMD_RUN:-}" ;; *) printf '%s\n' "${JG_TRUNK_SYSTEMCTL:-}" ;; esac
  else
    command -v "$1" 2>/dev/null || :
  fi
}

# unit_active <unit>: whether systemd reports the unit active (or starting). Without systemctl nothing is known to be running.
unit_active() {
  local ctl; ctl=$(unit_tool systemctl)
  [ -n "$ctl" ] && "$ctl" --user is-active --quiet "$1" 2>/dev/null
}

# start_job <verify|nightly|live|publish> <project>: start `trunk-landing.sh <kind> <home> <project>` detached.
start_job() {
  local kind=$1 pn=$2 run rec log unit
  run=$(unit_tool systemd-run)
  if [ -n "$run" ]; then
    rec=$MEM/unit-$kind-$pn; log=$MEM/unit-$kind-$pn.log
    if [ -s "$rec" ] && unit_active "$(cat "$rec")"; then return 0; fi
    unit=jg-$kind-$pn-$(date +%s)
    if "$run" --user --collect --quiet --property=KillMode=process --unit="$unit" --working-directory="$FMH" \
        --setenv=PATH="$PATH" --property=StandardOutput=append:"$log" --property=StandardError=append:"$log" \
        "$SELF" "$kind" "$FMH" "$pn" >/dev/null 2>&1; then
      printf '%s\n' "$unit" > "$rec"
      return 0
    fi
  fi
  setsid nohup "$SELF" "$kind" "$FMH" "$pn" >/dev/null 2>&1 < /dev/null &
}
