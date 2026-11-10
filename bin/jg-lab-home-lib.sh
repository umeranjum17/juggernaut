#!/usr/bin/env bash
# jg-lab-home-lib.sh - a throw-away (lab) home never writes the account's own host state.
#
# The sentinel unit, the stack's units, the unit claim and every host wiring step write into the
# account's own home: ~/.config/systemd/user (one unit name per machine), copies under
# ~/.local/share, and the agents' hook settings. Run for a test's home against the real account,
# they hand the machine to that home. On 9 Nov a remote squad-lead suite rewrote the real
# jg-sentinel.service to JG_HOME=/tmp/jg-test-run.*/.../remote-root, and Main had no restart
# recovery for 21 hours.
#
#   jg_lab_home <home>          0, printing the root it matched, when <home> is a lab home: under
#                               TMPDIR, /tmp, /var/tmp or /dev/shm (the temp roots of
#                               core/bus/cmd/jg-bus/owner.go labHome) or in a jg-test-run.* directory.
#   jg_lab_home_guard <home> <who> <dir>...
#                               0 when <home> may write the <dir>s it names. A lab home is refused,
#                               with one line on stderr and 2, when one <dir> lies in an account home:
#                               the password database's home for this user (bash reads it for ~ when
#                               HOME is unset), and JG_ACCOUNT_HOME when set (the remote job worker
#                               names the account it runs for, bin/jg-remote-job-worker.sh). Both
#                               only add protection. A test that gives the home a throw-away HOME and
#                               XDG dirs passes, because those lie in no account home, or in the lab
#                               root itself when that root is inside one (a TMPDIR under ~); an
#                               account home that is itself inside the lab root (a test's simulated
#                               host account) is that account's own all the same.

# _jg_lab_resolve <path>: the path with symlinks resolved; a part that does not exist yet is kept as written.
_jg_lab_resolve() {
  local path=$1 rest='' dir
  case $path in /*) ;; *) path=$PWD/$path ;; esac
  while [ "$path" != / ] && [ ! -d "$path" ]; do
    rest=/${path##*/}$rest
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  dir=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || dir=$path
  [ "$dir" != / ] || dir=''
  printf '%s\n' "$dir${rest:-}"
}

# _jg_lab_within <path> <root>: 0 when <path> is <root> or lies below it (both already resolved).
_jg_lab_within() { case $1 in "$2" | "$2"/*) return 0 ;; esac; return 1; }

jg_lab_home() {  # <home>
  local home root rest
  home=$(_jg_lab_resolve "$1")
  case $home/ in
    */jg-test-run.*/*)
      rest=${home#*/jg-test-run.}
      printf '%s/jg-test-run.%s\n' "${home%%/jg-test-run.*}" "${rest%%/*}"
      return 0
      ;;
  esac
  for root in "${TMPDIR:-}" /tmp /var/tmp /dev/shm; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    root=$(_jg_lab_resolve "$root")
    [ -n "$root" ] || continue  # a TMPDIR of / would make every home a lab home
    _jg_lab_within "$home" "$root" && { printf '%s\n' "$root"; return 0; }
  done
  return 1
}

jg_lab_home_guard() {  # <home> <who> <dir>...
  local home=$1 who=$2 lab account dir resolved
  shift 2
  lab=$(jg_lab_home "$home") || return 0
  for account in "$(unset HOME; CDPATH='' cd ~ 2>/dev/null && pwd -P)" "${JG_ACCOUNT_HOME:-}"; do
    [ -n "$account" ] || continue
    account=$(_jg_lab_resolve "$account")
    [ -n "$account" ] || continue
    for dir in "$@"; do
      [ -n "$dir" ] || continue
      resolved=$(_jg_lab_resolve "$dir")
      _jg_lab_within "$resolved" "$account" || continue
      if _jg_lab_within "$resolved" "$lab" && ! _jg_lab_within "$account" "$lab"; then continue; fi
      printf '%s: refused: %s is a throw-away home under %s, and %s is this account'\''s own (in %s); a test gives it a throw-away HOME and XDG dirs\n' \
        "$who" "$home" "$lab" "$dir" "$account" >&2
      return 2
    done
  done
  return 0
}
