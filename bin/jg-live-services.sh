#!/usr/bin/env bash
# jg-live-services.sh - the post-release check: prove, on this machine, that the
# services a release needs are running, so "is it all live?" never has to be asked.
#
# Usage: jg-live-services.sh [check]     print one line per service, then a verdict
#        jg-live-services.sh --quiet     same exit code, prints only the verdict line
#   Exit 0 when every required service runs, 1 when any is down.
#
# THE CHOSEN DESIGN. Required services:
#   nats     the JetStream server (nats-server)
#   dapr     the sidecar every publish goes through (daprd); the Go bus header
#            (core/bus/cmd/jg-bus) names it as the publish path, so it is required
#   ntfy     the delivery server
#   deliver  the Go consumer (`jg-bus deliver`) that reads the CAPTAIN stream and posts to ntfy
# A wake engine (jg-wake-engine) and a router (jg-router) are required only when this
# checkout ships them under core/*/cmd/. When it does not, the output says plainly
# that they are not part of the chosen design, and they never fail the check.
# The reply router is a one-shot command (`jg-bus reply`), not a daemon, so no process
# is expected for it.
#
# A line is `UP <service> <pid or unit status>` or `DOWN <service> <why>`; the last line
# is `LIVE_SERVICES: ok` or `LIVE_SERVICES: DOWN <names>`.
# bin/jg-live-claim.sh runs this before it lets a `live:` claim stand, and
# bin/jg-update.sh runs it after the release's `jg-stack.sh up`.
#
# Env: JG_HOME, JG_STATE_OVERRIDE, JG_STACK_UNIT_PREFIX (unit names, default jg).
# JG_LIVE_SERVICES_PROBES: a directory of fake probes for tests; <dir>/<service> is run,
# its first output line is the detail, and exit 0 means up. A service with no file there
# is down. With it set, no real process or unit is read.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
PREFIX=${JG_STACK_UNIT_PREFIX:-jg}

quiet=0
case ${1:-check} in
  check) ;;
  --quiet) quiet=1 ;;
  -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  *) echo "usage: jg-live-services.sh [check|--quiet]" >&2; exit 2 ;;
esac

# real_probe <service>: print the pid or unit status and return 0 when it runs.
real_probe() {
  local svc=$1 unit pid='' proc
  case $svc in nats) unit=$PREFIX-bus.service ;; *) unit=$PREFIX-$svc.service ;; esac
  if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl --user is-active "$unit" 2>/dev/null)" = active ]; then
    pid=$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null)
    printf 'pid %s, unit %s active\n' "${pid:-?}" "$unit"
    return 0
  fi
  pid=$([ -r "$STATE/bus/$svc.pid" ] && tr -cd '0-9' < "$STATE/bus/$svc.pid")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then printf 'pid %s, detached\n' "$pid"; return 0; fi
  case $svc in
    nats) proc=nats-server ;; dapr) proc=daprd ;; ntfy) proc=ntfy ;;
    wake-engine) proc=jg-wake-engine ;; router) proc=jg-router ;;
    deliver) pid=$(pgrep -f 'jg-bus deliver|jg-bus.* deliver' 2>/dev/null | head -n 1) ;;
  esac
  [ "$svc" = deliver ] || pid=$(pgrep -x "$proc" 2>/dev/null | head -n 1)
  if [ -n "$pid" ]; then printf 'pid %s, started by hand (no unit)\n' "$pid"; return 0; fi
  printf 'not running (no active unit %s, no live pid)\n' "$unit"
  return 1
}

probe() {  # <service>
  local f
  if [ -n "${JG_LIVE_SERVICES_PROBES:-}" ]; then
    f=$JG_LIVE_SERVICES_PROBES/$1
    if [ -x "$f" ]; then "$f" | head -n 1; return "${PIPESTATUS[0]}"; fi
    printf 'no probe result\n'; return 1
  fi
  real_probe "$1"
}

required=(nats dapr ntfy deliver)
absent=()
for opt in wake-engine router; do
  if compgen -G "$ROOT/core/*/cmd/jg-$opt" >/dev/null 2>&1; then required+=("$opt")
  else absent+=("$opt"); fi
done

down=()
for svc in "${required[@]}"; do
  detail=$(probe "$svc"); rc=$?
  if [ "$rc" -eq 0 ]; then state=UP; else state=DOWN; down+=("$svc"); fi
  [ "$quiet" = 1 ] || printf '%s %s %s\n' "$state" "$svc" "$detail"
done
if [ "$quiet" != 1 ]; then
  for svc in "${absent[@]}"; do
    printf 'NOT-IN-DESIGN %s is not part of the chosen design in this release (no jg-%s command ships); it is not checked\n' "$svc" "$svc"
  done
fi
if [ "${#down[@]}" -eq 0 ]; then echo 'LIVE_SERVICES: ok'; exit 0; fi
echo "LIVE_SERVICES: DOWN ${down[*]}"
exit 1
