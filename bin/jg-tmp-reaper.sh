#!/usr/bin/env bash
# jg-tmp-reaper.sh - keep this host's temp directory from filling with leaked jg-* scratch.
#
# Usage:
#   jg-tmp-reaper.sh check    the watcher check form (see below)
#   jg-tmp-reaper.sh arm | disarm
#
# check   Looks at the top level of ${TMPDIR:-/tmp} only. It removes an entry when ALL of these hold:
#           - its name starts with jg- (the prefix every Juggernaut script gives its scratch),
#           - it is owned by the running user and is a plain file or directory (never a symlink),
#           - nothing inside it changed for JG_TMP_REAP_AGE_MIN minutes (default 120), and
#           - no process holds it open, has it as a working directory, or names it in its command line.
#         It never touches any other name, and never a task temp root: /tmp/jg-<task-id> holds the task's GOTMPDIR
#         (Go will not recreate it), and /tmp/jg-<task-id>+<launch hash> holds its launch files, so a root that has a
#         gotmp directory, a +<64 hex> suffix, or a state/<task-id>.meta in this home is left for jg-teardown. A read-only tree (the herdr presentation trees) is made
#         writable first, because a read-only directory cannot otherwise be removed.
#         Liveness is read from /proc, so a host without /proc reaps nothing.
#         Each removal is logged to state/tmp-reaper.log and is silent otherwise.
#         It raises the host alert (bin/jg-alert.sh) when the temp filesystem use reaches JG_TMP_ALERT_PCT percent (default 70),
#         once per crossing: the alert's one live record holds it, and it is resolved when use drops back. The line goes to the log.
#         The same check also reaps test sandboxes (bin/jg-tmp-sandbox-lib.sh owns the rule): a jg-trunk.* or tmp.* entry holding a
#         trunk-landing tree whose processes (or, with none, newest change) are older than its own timeout
#         (.jg-sandbox-timeout seconds in the folder, else JG_TMP_SANDBOX_TIMEOUT_SEC, default 3600) has them stopped and the
#         folder removed. A task root, a folder a task meta names, and a sandbox with a process that has a recorded task meta are left alone.
# arm     Writes state/tmp-reaper.check.sh and binds it with jg-check-register.sh, so the watcher runs
#         it on the normal check cadence. disarm removes both.
#
# Scripts that make scratch clean it up themselves on every exit path; this check is the backstop for the
# exits no trap can catch (SIGKILL, power loss), and for a script killed before it could register its trap.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
TMP_ROOT=${TMPDIR:-/tmp}
TMP_ROOT=${TMP_ROOT%/}
AGE_MIN=${JG_TMP_REAP_AGE_MIN:-120}
ALERT_PCT=${JG_TMP_ALERT_PCT:-70}
LOG=$STATE/tmp-reaper.log
# shellcheck source=bin/jg-tmp-sandbox-lib.sh
. "$SCRIPT_DIR/jg-tmp-sandbox-lib.sh"

die() { printf 'jg-tmp-reaper: %s\n' "$1" >&2; exit "${2:-1}"; }
case "$AGE_MIN$ALERT_PCT" in *[!0-9]* | '') die "JG_TMP_REAP_AGE_MIN and JG_TMP_ALERT_PCT must be whole numbers" 2 ;; esac

# Every path a live process uses under the temp root: open descriptors, working directories, command lines.
in_use_paths() {
  [ -d /proc/self ] || return 1
  find /proc/[0-9]*/fd /proc/[0-9]*/cwd -maxdepth 1 -lname "$TMP_ROOT/jg-*" -printf '%l\n' 2>/dev/null
  cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -F -- "$TMP_ROOT/jg-" || true
  return 0
}

# A task temp root belongs to jg-spawn.sh and jg-teardown.sh and may look empty and old while its task is live.
is_task_root() {  # <path>
  local base=${1##*/} id
  [ -d "$1/gotmp" ] && return 0
  case "$base" in *+[0-9a-f]*) [ "${base#*+}" = "$(printf '%s' "${base#*+}" | tr -dc '0-9a-f')" ] && [ "${#base}" -ge 64 ] && return 0 ;; esac
  id=${base#jg-}
  [ ! -e "$STATE/$id.meta" ] || return 0
  return 1
}

# A leaked read-only tree cannot be removed until its directories are writable again.
remove_entry() {  # <path under TMP_ROOT>
  case "$1" in "$TMP_ROOT"/jg-* | "$TMP_ROOT"/tmp.*) ;; *) return 1 ;; esac
  case "$1" in */../* | */..) return 1 ;; esac
  [ ! -d "$1" ] || chmod -R u+rwX -- "$1" 2>/dev/null
  rm -rf -- "$1"
}

reap() {
  local used entry base reaped=0
  used=$(mktemp "$STATE/.tmp-reaper-use.XXXXXX") || return 0
  # shellcheck disable=SC2064  # The path is fixed at this point.
  trap "rm -f -- '$used'" EXIT
  trap 'exit 143' HUP INT TERM
  in_use_paths > "$used" || { rm -f -- "$used"; trap - EXIT HUP INT TERM; return 0; }
  while IFS= read -r -d '' entry; do
    base=${entry##*/}
    case "$base" in jg-*) ;; *) continue ;; esac
    is_task_root "$entry" && continue
    # Newer content anywhere inside means the owner is still writing.
    [ -z "$(find "$entry" -mmin "-$AGE_MIN" -print -quit 2>/dev/null)" ] || continue
    grep -qxF -- "$entry" "$used" && continue
    grep -qF -- "$entry/" "$used" && continue
    if remove_entry "$entry"; then
      reaped=$((reaped + 1))
      printf '%s reaped %s\n' "$(date -u +%FT%TZ)" "$entry" >> "$LOG"
    fi
  done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -user "$(id -u)" \( -type f -o -type d \) -name 'jg-*' -mmin "+$AGE_MIN" -print0 2>/dev/null)
  rm -f -- "$used"
  trap - EXIT HUP INT TERM
}

# The host alert rings once while use stays over the line (bin/jg-alert.sh keeps its one live record) and is resolved when use drops back.
alert() {
  local pct jg_alert="$SCRIPT_DIR/jg-alert.sh"
  pct=$(df -P -- "$TMP_ROOT" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')
  case "$pct" in '' | *[!0-9]* ) return 0 ;; esac
  if [ "$pct" -ge "$ALERT_PCT" ]; then
    printf '[%s] alert: %s is %s%% full (alert at %s%%)\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$TMP_ROOT" "$pct" "$ALERT_PCT" >> "$LOG" 2>/dev/null || true
    JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" bash "$jg_alert" raise host tmp-space | JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" bash "$jg_alert" deliver
  else
    JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" bash "$jg_alert" resolve host--tmp-space >/dev/null 2>&1 || true
  fi
}

cmd_check() {
  [ -d "$STATE" ] || die "state directory is missing: $STATE"
  [ -d "$TMP_ROOT" ] || return 0
  reap_sandboxes
  reap
  alert
}

cmd_arm() {
  local shim=$STATE/tmp-reaper.check.sh tmp
  tmp=$(umask 077; mktemp "$STATE/.jg-tmp-reaper.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-tmp-reaper.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" tmp-reaper >/dev/null || die "cannot register the check"
  printf 'armed: tmp-reaper\n'
}

case "${1:-check}" in
  check) cmd_check ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" tmp-reaper ;;
  -h | --help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0" ;;
  *) die "usage: jg-tmp-reaper.sh [check|arm|disarm]" 2 ;;
esac
