# shellcheck shell=bash
# core/agent-cli/wait-lib.sh - the bounded wait the proof and land verbs share. Sourced after lib.sh.

# jg_cli_wait <bound seconds> <command...>: run the command every few seconds until it exits 0 or the
# bound passes. The loop lives here so no agent writes an `until ... sleep` line. Exit 0: it passed; 1: bound.
jg_cli_wait() {
  local bound=$1 end; shift
  end=$(( $(date +%s) + bound ))
  until "$@"; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "${JG_CLI_POLL:-3}"
  done
}

# jg_cli_bound_arg <value>: a whole number of seconds, or the way out.
jg_cli_bound_arg() {
  case $1 in ''|*[!0-9]*) jg_cli_die "--bound takes whole seconds. Next: jg help" ;; esac
  printf '%s\n' "$1"
}
