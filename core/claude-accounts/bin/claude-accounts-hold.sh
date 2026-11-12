#!/usr/bin/env bash
# claude-accounts-hold.sh - the owner of the account hold: an account that is signed in and cannot be used (a billing error, a payment
# hold) is `on-hold` (core/machines/tables/account.tsv, machine 11). Nothing new starts on it, and its lanes move to the next account of
# the pool, or, when the pool has no other account, every start stops and one capacity alert goes to the owner.
#
# Usage: claude-accounts-hold.sh hold <account id> --reason <text>   put it on hold, raise the alert, move its lanes
#        claude-accounts-hold.sh release <account id>                lift the hold
#        claude-accounts-hold.sh status <account id>                 print held or free
#        claude-accounts-hold.sh scan                                one tick: hold each account whose lane ended on a billing error
# Env:   JG_HOME (required), JG_CLAUDE_ACCOUNTS_REGISTRY (default ~/.muxr/plans/accounts-v1.json),
#        JG_HOLD_CONTROL (the lifecycle command; default <home>/bin/jg-control.sh), JG_HOLD_ALERT (default <home>/bin/jg-alert.sh).
# Records: state/<provider>-accounts-held/<id> holds "epoch<TAB>folder<TAB>reason"; read by the picker (claude-accounts-pick skips it), by
#          bin/jg-worker-account-lib.sh (a pinned launch on its folder refuses) and by the account observer (the word on-hold). The pool
#          state folder is the one the quota reader uses (config/account-pool state=, else <home>/state). No pin file is ever changed.
# scan reads state/beats/<task> (bin/jg-beat.sh): a last line "<epoch> StopFailure error=<type>" with a billing type holds the account the
#          task's meta names (account=<id>). A lane that is on a held account is moved with `relaunch --account <id>` to the account the
#          pick chooses; with no other account it is left as it is.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:?set JG_HOME to the Juggernaut home}
REGISTRY=${JG_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
CONTROL=${JG_HOLD_CONTROL:-$JG_HOME/bin/jg-control.sh}
ALERT=${JG_HOLD_ALERT:-$JG_HOME/bin/jg-alert.sh}
HOME_STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
pool_state=$(sed -n 's/^state=//p' "$JG_HOME/config/account-pool" 2>/dev/null | head -n 1)
case "$pool_state" in /*) ;; *) pool_state=$HOME_STATE ;; esac
BILLING='billing|payment|insufficient_funds|account_hold'

die() { echo "error: $*" >&2; exit 1; }
# <id>: print "<tool><TAB><folder>" of a pool account, or fail.
lookup() {
  local row
  row=$(jq -r --arg id "$1" 'first(.accounts[]? | select(.id == $id and (.provider == "claude" or .provider == "codex")) | "\(.provider)\t\(.folder)") // empty' "$REGISTRY" 2>/dev/null)
  [ -n "$row" ] || die "no account $1 in the pool"
  printf '%s\n' "$row"
}
held_file() { printf '%s/%s-accounts-held/%s' "$pool_state" "$1" "$2"; }  # <tool> <id>
# <tool> <id>: how many accounts of the tool are in the pool and not on hold, the account itself excluded.
others() {
  local n=0 a
  for a in $(jq -r --arg t "$1" --arg id "$2" '.accounts[]? | select(.provider == $t and .id != $id) | .id' "$REGISTRY"); do
    [ -s "$(held_file "$1" "$a")" ] || n=$((n + 1))
  done
  echo "$n"
}
# <id>: the tasks whose meta says they run on the account and have not exited since.
lanes() {
  local meta task
  for meta in "$HOME_STATE"/*.meta; do
    [ -e "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    grep -qx "account=$1" "$meta" || continue
    { [ -e "$HOME_STATE/$task.exit" ] && [ "$HOME_STATE/$task.exit" -nt "$meta" ]; } && continue
    echo "$task"
  done
}

cmd_hold() {
  local id=${1:-} reason='' tool folder left lanes_moved='' task next text
  [ -n "$id" ] || die "usage: hold <account id> --reason <text>"
  shift
  while [ $# -gt 0 ]; do case "$1" in --reason) reason=${2:-}; shift ;; esac; shift; done
  [ -n "$reason" ] || die "hold needs --reason <text>"
  IFS=$'\t' read -r tool folder < <(lookup "$id") || exit 1
  mkdir -p "$(dirname "$(held_file "$tool" "$id")")" || die "cannot write the hold folder"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$folder" "${reason//$'\n'/ }" > "$(held_file "$tool" "$id")" || die "cannot write the hold of $id"
  left=$(others "$tool" "$id")
  if [ "$left" -gt 0 ]; then
    text="account $id is on hold ($reason); its lanes move to another account of the pool"
  else
    text="account $id is on hold ($reason) and the pool has no other account: no worker starts until it is released"
  fi
  "$ALERT" capacity claude-accounts-hold "$text" --print >/dev/null 2>&1 || echo "warning: the capacity alert was not raised" >&2
  if [ "$left" -gt 0 ]; then
    for task in $(lanes "$id"); do
      next=$(JG_HOME=$JG_HOME "$here/claude-accounts-pick" pick "$tool" --json --state "$pool_state" 2>/dev/null | jq -r '.id // empty')
      if [ -n "$next" ] && "$CONTROL" "$task" relaunch --account "$next" >/dev/null 2>&1; then lanes_moved="$lanes_moved $task"
      else echo "warning: lane $task did not move off $id" >&2; fi
    done
  fi
  jq -cn --arg id "$id" --argjson left "$left" --arg moved "${lanes_moved# }" '{ok: true, id: $id, held: true, other_accounts: $left, moved: ($moved | split(" ") | map(select(. != "")))}'
}
cmd_release() {
  local id=${1:-} tool folder
  [ -n "$id" ] || die "usage: release <account id>"
  IFS=$'\t' read -r tool folder < <(lookup "$id") || exit 1
  rm -f -- "$(held_file "$tool" "$id")"
  jq -cn --arg id "$id" '{ok: true, id: $id, held: false}'
}
cmd_status() {
  local id=${1:-} tool folder
  [ -n "$id" ] || die "usage: status <account id>"
  IFS=$'\t' read -r tool folder < <(lookup "$id") || exit 1
  if [ -s "$(held_file "$tool" "$id")" ]; then echo held; else echo free; fi
}
cmd_scan() {
  local beat task ev rest id
  for beat in "$HOME_STATE"/beats/*; do
    [ -s "$beat" ] || continue
    task=${beat##*/}
    read -r _at ev rest < <(tail -n 1 "$beat") || continue
    [ "$ev" = StopFailure ] || continue
    case "$rest" in error=*) ;; *) continue ;; esac
    printf '%s' "${rest#error=}" | grep -Eqi "$BILLING" || continue
    id=$(sed -n 's/^account=//p' "$HOME_STATE/$task.meta" 2>/dev/null | head -n 1)
    [ -n "$id" ] && [ "$(cmd_status "$id" 2>/dev/null)" = free ] || continue
    cmd_hold "$id" --reason "lane $task ended on ${rest#error=}"
  done
}

case "${1:-}" in
  hold | release | status | scan) c=$1; shift; "cmd_$c" "$@" ;;
  *) die "usage: claude-accounts-hold.sh hold <id> --reason <text> | release <id> | status <id> | scan" ;;
esac
