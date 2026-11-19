#!/usr/bin/env bash
# jg-stack.sh - the one command that installs, starts and checks the whole stack a home runs on.
#
#   bin/jg-stack.sh [up]      install what is missing, start what is stopped, then report every part
#   bin/jg-stack.sh status    report every part and change nothing
#
# THE PARTS, in the order each one needs the one before it.
#   jg-bus   the Go command that owns the channel, built from core/bus (needs a Go toolchain)
#   gateway  the chat gateway, only where this home has a bot token file
# The chat sends in-process, the wake queue keeps its local files and the task leases live in
# state/kv.db, so no bus or consumer service runs. The gateway runs as a systemd user
# service (installed, enabled, started) when this account has a user session whose unit directory
# is this HOME's; otherwise (CI, a container, a throwaway HOME) nothing is started detached.
#
# CONTRACT.
#   report   one line per part and a final `stack: up (<supervisor>)` line. A second run prints the
#            same lines and changes nothing.
#   stop     the first part that cannot be made whole stops the run with exit 1 and ONE line,
#            `STACK_FAILED: <part>: <what is missing>; blocks <what depends on it>`.
#   retire   `up` removes a part an earlier release ran and this one does not (RETIRED below): its
#            unit is disabled, stopped and deleted, a detached process it recorded is stopped, and its
#            runtime files go, so a home upgraded across that release ends with nothing of it left.
#   callers  bin/jg-bootstrap.sh and bin/jg-update.sh run `up`, so a release never lands on a machine
#            without its services; install.sh runs it last.
#   refuse   the machine's long-running services (jg-sentinel) belong to Main, and bin/jg-unit-claim.sh owns
#            why: a Squad Lead home that installs them takes Main's alerts away with
#            them, so `up` refuses there with exit 2 and `status` still reports. `up` also
#            refuses, exit 2, a throw-away home writing this account's own units or tools
#            (bin/jg-lab-home-lib.sh).
# Env: JG_HOME, JG_STATE_OVERRIDE; JG_STACK_UNIT_PREFIX (unit names, default jg); JG_STACK_SUPERVISOR
# (auto|systemd|detached); JG_STACK_SKIP=1 makes `up` a no-op for a fixture that must bind no port.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
BUS="$SCRIPT_DIR/jg-bus.sh"
PREFIX=${JG_STACK_UNIT_PREFIX:-jg}
export JG_STACK_UNIT_PREFIX=$PREFIX
export NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.local}
export PATH=$NPM_CONFIG_PREFIX/bin:$PATH

mode=${1:-up}
case $mode in up|status) ;; -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;; *) echo "usage: jg-stack.sh [up|status]" >&2; exit 2 ;; esac
[ "$mode" = status ] || [ "${JG_STACK_SKIP:-0}" != 1 ] || exit 0
# A Squad Lead home never claims the machine's services: it would take Main's
# alerts away with them (bin/jg-unit-claim.sh owns the reason).
if [ "$mode" = up ] && { [ -e "$JG_HOME/.jg-squad-lead-home" ] || [ -L "$JG_HOME/.jg-squad-lead-home" ]; }; then
  "$SCRIPT_DIR/jg-unit-claim.sh" refuse jg-stack up
  exit 2
fi
# A throw-away home (a test's) never installs units or tools into this account's own home
# (bin/jg-lab-home-lib.sh owns the rule and the refusal sentence).
if [ "$mode" = up ]; then
  # shellcheck source=bin/jg-lab-home-lib.sh
  . "$SCRIPT_DIR/jg-lab-home-lib.sh"
  jg_lab_home_guard "$JG_HOME" "jg-stack up" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" "$NPM_CONFIG_PREFIX" || exit 2
fi

fail() {  # <part> <what is missing> <what it blocks>
  printf 'STACK_FAILED: %s: %s; blocks %s\n' "$1" "$2" "$3"
  exit 1
}

# The user manager reads units from the account's own home, so a HOME that is not that home (a
# throwaway one) cannot install a unit the manager will see.
supervisor() {
  local want=${JG_STACK_SUPERVISOR:-auto} account_home
  [ "$want" != detached ] || { echo detached; return; }
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then echo detached; return; fi
  account_home=$(getent passwd "$(id -u)" | cut -d: -f6)
  [ "$want" = systemd ] || [ "$account_home" = "$HOME" ] || { echo detached; return; }
  echo systemd
}

unit_name() { echo "$PREFIX-$1.service"; }

# install_unit <part>: write the unit when it differs from the installed one; 0 when it changed.
install_unit() {
  local part=$1 dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user name tmp
  name=$(unit_name "$part")
  mkdir -p "$dir" "$STATE/bus"
  tmp="$STATE/bus/$name.new"
  "$BUS" unit "$part" > "$tmp" || { rm -f -- "$tmp"; fail "$part" "cannot generate its unit" "its service"; }
  if cmp -s "$tmp" "$dir/$name"; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$dir/$name"
  return 0
}

mkdir -p "$STATE/bus" || fail state "cannot create $STATE/bus" "everything"

# 1. The Go command. A host with no toolchain and no built binary cannot run any service.
"$BUS" status >/dev/null 2>"$STATE/bus/build.log" \
  || fail jg-bus "the Go command is not built and there is no Go toolchain (install go), see $STATE/bus/build.log" "every service"
printf 'jg-bus built, state %s\n' "$STATE/bus"

sup=$(supervisor)

# retire_part <part>: remove a part this release no longer runs, once and quietly when nothing is left.
RETIRED="ntfy deliver"
retire_part() {
  local part=$1 name dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user pid what=''
  name=$(unit_name "$part")
  if [ "$sup" = systemd ] && [ -e "$dir/$name" ]; then
    systemctl --user disable --now "$name" >/dev/null 2>&1 || true
    rm -f -- "$dir/$name"
    systemctl --user daemon-reload || fail "$part" "systemctl daemon-reload failed" "retiring $name"
    systemctl --user reset-failed "$name" >/dev/null 2>&1 || true
    what="$name removed"
  fi
  # A detached process is stopped only when the pid this stack recorded still runs this part.
  pid=$([ -r "$STATE/bus/$part.pid" ] && tr -cd '0-9' < "$STATE/bus/$part.pid")
  if [ -n "$pid" ] && ps -o args= -p "$pid" 2>/dev/null | grep -Eq "[ /]$part( |\$)"; then
    kill "$pid" 2>/dev/null || true
    what="${what:+$what, }process $pid stopped"
  fi
  if compgen -G "$STATE/bus/$part*" >/dev/null || compgen -G "$STATE/bus/install-$part.log" >/dev/null; then
    rm -f -- "$STATE/bus/$part".* "$STATE/bus/$part"-* "$STATE/bus/install-$part.log"
    what="${what:+$what, }runtime files removed"
  fi
  [ -z "$what" ] || echo "retired $part: $what"
}
if [ "$mode" = up ]; then for part in $RETIRED; do retire_part "$part"; done; fi

# The chat gateway is optional: it runs only where this home has a bot token file. A home without one gets
# no unit, no line and no failure; a token file removed later retires the unit it had.
if "$BUS" gateway enabled; then
  gw=$(unit_name gateway)
  if [ "$mode" = up ] && [ "$sup" = systemd ]; then
    changed=0; install_unit gateway && changed=1
    [ "$changed" = 0 ] || systemctl --user daemon-reload || fail gateway "systemctl daemon-reload failed" "the captain's chat"
    systemctl --user enable "$gw" >/dev/null 2>&1 || fail gateway "cannot enable $gw" "the captain's chat"
    if [ "$changed" = 1 ] && systemctl --user is-active --quiet "$gw"; then systemctl --user restart "$gw"; else systemctl --user start "$gw"; fi \
      || fail gateway "cannot start $gw, see journalctl --user -u $gw" "the captain's chat"
  fi
  echo "gateway     enabled ($gw)"
elif [ "$mode" = up ]; then
  retire_part gateway
fi
echo "stack: up ($sup)"
echo "stack: up ($sup)"
