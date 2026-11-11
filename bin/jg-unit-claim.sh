#!/usr/bin/env bash
# jg-unit-claim.sh - which home the machine's four long-running Juggernaut
# services serve, who may move them, and the line that says when one is wrong.
#
# The four are systemd USER units, so exactly one home can run each of them:
# jg-sentinel (restart recovery), jg-wake-engine, jg-wake-watcher and jg-router
# (the bus consumers that make a raise reach every reader without a caller
# having to render it). Their unit names are one per machine, so a home that
# installs them for itself takes them from the home that had them.
#
# WHAT WENT WRONG (7 Nov). A Squad Lead home ran its install command, which
# rewrote the units for its own home. Main kept running and looked healthy, and
# every stuck-worker, blocked-pane and stopped-service alert went to the lead's
# home instead: notes sat unseen for 78 minutes, a worker sat on a dialog for 12
# minutes and a lead sat on a usage limit, all silently. The units were active
# the whole time, so nothing that only asks "is it running" could see it.
#
# SO: Main claims them, and a Squad Lead home may not.
#   claim   Runs at Main's own session start (bin/jg-session-start.sh). Each
#           installed unit that is not running, or that serves another home, is
#           rewritten from this home's own unit text, reloaded, restarted and
#           then VERIFIED to serve this home. One line per unit claimed or
#           failed, nothing when all four already serve here. It only acts from
#           the home's own copy of Juggernaut and never in a Squad Lead home, so
#           a test or throwaway home that runs another checkout's scripts can
#           never take the machine's units; nor can a throw-away home under a
#           temp root that is its own copy (bin/jg-lab-home-lib.sh).
#   status  One line per unit that is installed but not running, or that serves
#           another home; nothing when all four serve here. The watcher's fast
#           check runs it every 30 s (bin/jg-watch.sh), so a wrong unit reaches
#           Main inside two minutes instead of never. bin/jg-bootstrap.sh prints
#           the same line at session start.
#   refuse  The one sentence bin/jg-sentinel.sh and bin/jg-stack.sh hand a Squad
#           Lead home's install, so the reason is stated once. Exit 2.
#
# A unit that is absent is not wrong: the first install belongs to
# bin/jg-stack.sh up (the bus parts) and the SENTINEL line (the sentinel).
#
# Env: JG_HOME (required), JG_STACK_UNIT_PREFIX (unit names, default jg),
#      XDG_CONFIG_HOME (where the user units live, default ~/.config).
# Exit: claim 0 when every installed unit serves this home and 1 when one could
#       not be moved or started; status 0 always; refuse 2.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
JG_HOME=$(cd "$JG_HOME" 2>/dev/null && pwd -P) || { echo "jg-unit-claim: JG_HOME is not a directory" >&2; exit 2; }
PREFIX=${JG_STACK_UNIT_PREFIX:-jg}
UNITS="jg-sentinel $PREFIX-wake-engine $PREFIX-wake-watcher $PREFIX-router"
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
# shellcheck source=bin/jg-lab-home-lib.sh
. "$SCRIPT_DIR/jg-lab-home-lib.sh"

# Main owns these units; a Squad Lead home never installs or moves them.
reason() {
  printf 'Main owns the machine services (%s) and runs them for its own home, so a Squad Lead home never installs or moves them' \
    "${UNITS// /, }"
}

squad_lead_home() { [ -e "$JG_HOME/.jg-squad-lead-home" ] || [ -L "$JG_HOME/.jg-squad-lead-home" ]; }
# The machine's units are this home's only when the home's own copy of Juggernaut
# reads them: a test or throwaway home that runs another checkout's scripts must
# never take, report or move them.
own_copy() { [ "$SCRIPT_DIR/.." -ef "$JG_HOME" ]; }
user_session() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }

# served <unit>: the home the installed unit names, or nothing.
served() {
  local env
  env=$(systemctl --user show -p Environment --value "$1" 2>/dev/null) || return 0
  # A home path may hold spaces, so cut at the next NAME= word, not at the first space.
  printf '%s\n' "$env" \
    | sed -n 's/^\(.* \)\{0,1\}"\{0,1\}JG_HOME=\(.*\)$/\2/p' \
    | sed 's/[[:space:]]\{1,\}"\{0,1\}[A-Za-z_][A-Za-z0-9_]*=.*$//; s/"$//'
}

# problem <unit>: the phrase saying why this unit does not serve this home, or nothing.
problem() {
  local unit=$1 other
  systemctl --user is-enabled --quiet "$unit" 2>/dev/null || return 0
  if ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    printf 'is installed but not running'
    return 0
  fi
  other=$(served "$unit")
  # A unit that names no home is served by nobody in particular, which is not this
  # section's case; the line exists for a unit another home is being served by.
  [ -n "$other" ] || return 0
  [ "$other" -ef "$JG_HOME" ] 2>/dev/null || printf 'serves %s, not this home' "$other"
}

# move <unit>: write this home's own unit text, reload, restart, and prove it serves here.
move() {
  local unit=$1 text file out why
  file="$UNIT_DIR/$unit.service"
  if [ "$unit" = jg-sentinel ]; then
    text=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-sentinel.sh" unit 2>&1) || {
      printf 'jg-unit-claim: cannot write %s: %s\n' "$unit" "$text"
      return 1
    }
  else
    text=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-bus.sh" unit "${unit#"$PREFIX"-}" 2>&1) || {
      printf 'jg-unit-claim: cannot write %s: %s\n' "$unit" "$text"
      return 1
    }
  fi
  mkdir -p "$UNIT_DIR" || { printf 'jg-unit-claim: cannot create %s\n' "$UNIT_DIR"; return 1; }
  if ! { printf '%s\n' "$text" > "$file.new.$$" && chmod 0644 "$file.new.$$" && mv -f -- "$file.new.$$" "$file"; }; then
    rm -f -- "$file.new.$$"
    printf 'jg-unit-claim: cannot write %s\n' "$file"
    return 1
  fi
  systemctl --user daemon-reload
  systemctl --user enable "$unit" >/dev/null 2>&1 || true
  if ! out=$(systemctl --user restart "$unit" 2>&1); then
    printf 'jg-unit-claim: %s did not restart: %s\n' "$unit" "${out:-no reason given}"
    return 1
  fi
  why=
  for _ in $(seq 1 25); do
    why=$(problem "$unit")
    [ -n "$why" ] || break
    sleep 0.2
  done
  if [ -n "$why" ]; then
    printf 'jg-unit-claim: %s did not take: %s\n' "$unit" "$why"
    return 1
  fi
  printf 'claimed: %s now serves %s\n' "$unit" "$JG_HOME"
}

cmd_status() {
  local unit why
  squad_lead_home && return 0
  user_session || return 0
  own_copy || return 0
  for unit in $UNITS; do
    why=$(problem "$unit") || continue
    [ -n "$why" ] || continue
    printf 'UNIT_HOME: %s %s, so this home gets no alert from it\n' "$unit" "$why"
  done
  return 0
}

cmd_claim() {
  local unit why rc=0
  if squad_lead_home; then
    printf 'jg-unit-claim: refused: %s\n' "$(reason)" >&2
    return 2
  fi
  user_session || return 0
  own_copy || return 0
  # Nor does a throw-away home that is its own copy (a test's fixture under a temp root)
  # move the units when they are this account's own (bin/jg-lab-home-lib.sh owns the rule).
  jg_lab_home_guard "$JG_HOME" jg-unit-claim "$UNIT_DIR" 2>/dev/null || return 0
  for unit in $UNITS; do
    why=$(problem "$unit") || continue
    [ -n "$why" ] || continue
    move "$unit" || rc=1
  done
  return "$rc"
}

case "${1:-}" in
  claim) cmd_claim ;;
  status) cmd_status ;;
  refuse) printf '%s: %s refused: %s\n' "${2:-jg-unit-claim}" "${3:-install}" "$(reason)" >&2; exit 2 ;;
  -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  *) echo "usage: jg-unit-claim.sh claim|status|refuse <caller> <action>" >&2; exit 2 ;;
esac
