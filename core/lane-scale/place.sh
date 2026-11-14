#!/usr/bin/env bash
# lane-scale place: where a new lead home starts (H30e). This host while its budget has room, a runner host when it is full.
# Usage: place.sh pick <jg-home> [--private]
#          print `local`, `runner <id> <ssh alias> <code root> <runner home>`, or `stop <why>`; exit 0 for the first two, 1 for stop
#        place.sh seed <jg-home> <lead-id> [--private] {<project>[=<origin-url>]...|--no-projects}
#          pick, then on a runner start the home through bin/jg-remote-home-seed.sh (the remote Squad Lead path) at <runner home>/<lead-id>;
#          prints `local` and starts nothing when this host has room, so the caller takes its ordinary local path
# Rule  fleet.sh verdict decides this host: `go` keeps the home here. Anything else looks at the registered runners
#   (core/runners/registry.sh usable: probe passed, own machines first): the first one with a free core wins. A paid runner needs
#   core/runners/ledger.sh allow. With --private only a runner with private_ok=yes is eligible, so a private repository never leaves
#   owned machines (D5); a stop then says it was the private rule that left no runner. With no runner the answer is the host's own.
set -u
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
case "${1:-}" in pick) [ "$#" -ge 2 ] ;; seed) [ "$#" -ge 4 ] ;; *) false ;; esac || usage
CMD=$1; HOME_DIR=$2; shift 2
[ -d "$HOME_DIR" ] || { echo "place.sh: no home $HOME_DIR" >&2; exit 2; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$HERE/../.." && pwd)}"
LEAD=
[ "$CMD" = seed ] && { LEAD=$1; shift; }
PRIVATE=
ARGS=()
for a in "$@"; do case "$a" in --private) PRIVATE=--private ;; *) ARGS+=("$a") ;; esac; done
[ "$CMD" = pick ] && [ "${#ARGS[@]}" -gt 0 ] && usage

pick() {
  local verdict id rec free cost ssh root home any=
  verdict=$("$HERE/fleet.sh" verdict "$HOME_DIR") || verdict=hold
  case "$verdict" in go*) echo local; return 0 ;; esac
  for id in $("$HERE/../runners/registry.sh" usable "$HOME_DIR" ${PRIVATE:+"$PRIVATE"}); do
    any=1
    rec=$("$HERE/../runners/registry.sh" get "$HOME_DIR" "$id") || continue
    cost=$(printf '%s\n' "$rec" | sed -n 's/^cost_per_hour=//p')
    case "$cost" in *[1-9]*) "$HERE/../runners/ledger.sh" allow "$HOME_DIR" || continue ;; esac
    free=$("$HERE/../runners/registry.sh" free "$HOME_DIR" "$id") || continue
    [ "${free:-0}" -ge 1 ] || continue
    ssh=$(printf '%s\n' "$rec" | sed -n 's/^ssh=//p'); root=$(printf '%s\n' "$rec" | sed -n 's/^root=//p')
    home=$(printf '%s\n' "$rec" | sed -n 's/^home=//p')
    echo "runner $id $ssh $root $home"; return 0
  done
  if [ -n "$PRIVATE" ] && [ -z "$any" ] && [ -n "$("$HERE/../runners/registry.sh" usable "$HOME_DIR")" ]; then
    echo "stop this host is full and no owned runner (private_ok=yes) can take a private repository; host: $verdict"
  else
    echo "stop this host is full and no usable runner has a free core; host: $verdict"
  fi
  return 1
}

out=$(pick); rc=$?
[ "$CMD" = pick ] && { printf '%s\n' "$out"; exit "$rc"; }
[ "$rc" -eq 0 ] || { printf '%s\n' "$out"; exit 1; }
case "$out" in
  local) echo local ;;
  runner*) read -r _ id ssh root home <<< "$out"
    JG_HOME="$HOME_DIR" "$ROOT/bin/jg-remote-home-seed.sh" "$LEAD" "$ssh" "$root" "$home/$LEAD" "${ARGS[@]}" || exit 1
    echo "runner $id" ;;
esac
