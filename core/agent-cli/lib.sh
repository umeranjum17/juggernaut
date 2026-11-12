# shellcheck shell=bash
# core/agent-cli/lib.sh - what every `jg` verb shares: find the home and the ticket from the
# folder the verb runs in, and append one status line. Sourced by the verb scripts.
#
# Home: JG_HOME when set, else the home that owns the project clone this worktree belongs to
# (<home>/projects/<project>/.git is the worktree's git common dir). Ticket: JG_TASK when set,
# else the one state/<id>.meta of that home whose worktree= is this worktree.
# Sets JG_CLI_HOME, JG_CLI_STATE, JG_CLI_TASK, JG_CLI_META, JG_CLI_TOOLS (the repo root of
# this code, where the guard and the delivery scripts live).

JG_CLI_TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

jg_cli_die() { printf 'jg: %s\n' "$*" >&2; exit 2; }

jg_cli_meta_get() {  # <key>  (value of the first key= line of the ticket record)
  sed -n "s/^$1=//p" "$JG_CLI_META" | head -n1
}

jg_cli_context() {
  local common top proj m
  if [ -n "${JG_HOME:-}" ]; then
    JG_CLI_HOME=$JG_HOME
  else
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      || jg_cli_die "not in a git worktree of a Juggernaut project. Next: cd to your task worktree, or set JG_HOME"
    proj=$(dirname -- "$common")
    [ "$(basename -- "$(dirname -- "$proj")")" = projects ] \
      || jg_cli_die "this worktree's project is not under a home's projects/ folder. Next: set JG_HOME"
    JG_CLI_HOME=$(dirname -- "$(dirname -- "$proj")")
  fi
  JG_CLI_STATE=${JG_STATE_OVERRIDE:-$JG_CLI_HOME/state}
  [ -d "$JG_CLI_STATE" ] || jg_cli_die "no state folder at $JG_CLI_STATE. Next: set JG_HOME to the home that spawned you"
  if [ -n "${JG_TASK:-}" ]; then
    JG_CLI_TASK=$JG_TASK
  else
    top=$(git rev-parse --show-toplevel 2>/dev/null) || jg_cli_die "not in a git worktree. Next: cd to your task worktree, or set JG_TASK"
    top=$(cd "$top" && pwd -P)
    JG_CLI_TASK=''
    for m in "$JG_CLI_STATE"/*.meta; do
      [ -e "$m" ] || continue
      grep -qxF "worktree=$top" "$m" || continue
      [ -z "$JG_CLI_TASK" ] || jg_cli_die "two tickets name this worktree ($JG_CLI_TASK and $(basename "$m" .meta)). Next: set JG_TASK"
      JG_CLI_TASK=$(basename "$m" .meta)
    done
    [ -n "$JG_CLI_TASK" ] || jg_cli_die "no ticket record names $top. Next: set JG_TASK to your ticket id"
  fi
  JG_CLI_META=$JG_CLI_STATE/$JG_CLI_TASK.meta
  [ -f "$JG_CLI_META" ] || jg_cli_die "no record for ticket $JG_CLI_TASK at $JG_CLI_META"
  export JG_HOME=$JG_CLI_HOME
}

# jg_cli_status_append <verb> <text> [<tag>...]: one `<verb> [at=<epoch>] [tag]...: <text>` line,
# through the guard that refuses a bad line and writes nothing, then the opt-in fleet ledger.
jg_cli_status_append() {
  local verb=$1 text=$2 tags='' t status
  shift 2
  for t in "$@"; do tags="$tags [$t]"; done
  status=$JG_CLI_STATE/$JG_CLI_TASK.status
  printf '%s [at=%s]%s: %s\n' "$verb" "$(date +%s)" "$tags" "$text" \
    | "$JG_CLI_TOOLS/bin/jg-lavish-guard.sh" --append "$status" || return 1
  if [ -e "$JG_CLI_HOME/config/fleet-ledger" ]; then
    "$JG_CLI_TOOLS/bin/jg-fleet-ledger.sh" appended "$JG_CLI_HOME/config" "$status" >/dev/null 2>&1 || true
  fi
}

jg_cli_unread() {  # print the unread steer files of the ticket, in numeric order
  local f
  for f in "$JG_CLI_STATE/$JG_CLI_TASK.inbox"/*.msg; do [ -e "$f" ] && printf '%s\n' "$f"; done | sort
}
