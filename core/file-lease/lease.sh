#!/usr/bin/env bash
# lease.sh - a lane holds a lease on the files its ticket names (slice H43).
#
# Usage: lease.sh acquire <task-id> <file>...   take the lease, or refuse and name the holder
#        lease.sh release <task-id>             end the lease (idempotent)
#        lease.sh holders                       one `<task-id><TAB><file>` line per live lease
#
# The spawn calls `acquire` for a fresh ship after the ticket is admitted and before any copy or
# record exists, so a refusal costs nothing: the ticket stays in ready. A lease is one file,
# state/file-leases/<task-id>: line 1 `at=<epoch>`, then one repository path per line.
#
# Only a HOT file is exclusive. A second lane whose files overlap a live lease on a hot file is
# refused (exit 1) with `lease-held: <file> is leased by the live lane <id>`; an overlap on any
# other file is recorded, never refused (the spawn's own admission already refuses a file that
# another in-flight ticket holds). Hot files are the lines of config/hot-files; without that file
# they are the files hotfiles.sh names for the repository in JG_FILE_LEASE_REPO (3 or more lanes in
# a week, H37), cached in state/file-leases/.hot for JG_FILE_LEASE_HOT_TTL seconds (default 3600).
#
# A lease is live while its holder's task record state/<id>.meta exists, or for JG_FILE_LEASE_GRACE_S
# seconds (default 900) after it was taken, which covers the spawn that has not written the record
# yet. Cleanup removes the record, so the lease ends there at the latest; a lease that is no longer
# live is deleted by the next call that reads it. Calls take one lock, so two spawns never both pass.
#
# Environment: JG_HOME (required), JG_STATE_OVERRIDE, JG_CONFIG_OVERRIDE, JG_FILE_LEASE_NOW (clock seam).
# Exit 0 done; 1 refused; 2 usage or an environment that cannot be read (the cause is on stderr).
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
die() { echo "lease: $*" >&2; exit 2; }
[ -n "${JG_HOME:-}" ] || die "JG_HOME is not set"
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
DIR=$STATE/file-leases
GRACE=${JG_FILE_LEASE_GRACE_S:-900}
now=${JG_FILE_LEASE_NOW:-$(date +%s)}
valid_id() { case $1 in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac; }

mkdir -p -- "$DIR" || die "cannot create $DIR"
command -v flock >/dev/null 2>&1 || die "flock is not installed; the lease needs it to keep two spawns apart"
exec 9>"$DIR/.lock" || die "cannot open the lease lock in $DIR"
flock 9 || die "cannot take the lease lock in $DIR"

# live <task-id> <lease file>: the holder's record exists, or the lease is younger than the grace.
live() {
  [ -e "$STATE/$1.meta" ] && return 0
  local at; at=$(sed -n '1s/^at=//p' "$2" 2>/dev/null)
  case $at in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - at)) -lt "$GRACE" ]
}

# live_leases: print the path of each live lease, delete the rest.
live_leases() {
  local f id
  for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    id=${f##*/}
    if live "$id" "$f"; then printf '%s\n' "$f"; else rm -f -- "$f"; fi
  done
}

hot_files() {
  if [ -f "$CONFIG/hot-files" ]; then grep -v '^[[:space:]]*\(#\|$\)' "$CONFIG/hot-files"; return 0; fi
  [ -n "${JG_FILE_LEASE_REPO:-}" ] || return 0
  local cache=$DIR/.hot ttl=${JG_FILE_LEASE_HOT_TTL:-3600} stamp out
  stamp=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
  if [ $((now - stamp)) -ge "$ttl" ]; then
    if out=$("$SCRIPT_DIR/../fleet-stats/hotfiles.sh" --repo "$JG_FILE_LEASE_REPO" 2>&1); then
      printf '%s\n' "$out" | cut -f1 > "$cache.$$" && mv -f -- "$cache.$$" "$cache"
    else
      echo "lease: hot files could not be read, so no file is exclusive for now: $out" >&2
      return 0
    fi
  fi
  cat -- "$cache"
}

acquire() {
  local id=${1:-}; shift
  valid_id "$id" || die "acquire needs a task id"
  [ $# -gt 0 ] || return 0
  local hot f other held=0 tmp
  hot=$(hot_files)
  while IFS= read -r other; do
    [ "${other##*/}" = "$id" ] && continue
    for f in "$@"; do
      printf '%s\n' "$hot" | grep -qxF -- "$f" || continue
      if sed '1d' "$other" | grep -qxF -- "$f"; then
        echo "lease-held: $f is leased by the live lane ${other##*/}; the ticket waits in ready until that lane lands or is cleaned up" >&2
        held=1
      fi
    done
  done < <(live_leases)
  [ "$held" -eq 0 ] || return 1
  tmp=$DIR/.new.$$
  { printf 'at=%s\n' "$now"; printf '%s\n' "$@"; } > "$tmp" || die "cannot write the lease of $id in $DIR"
  mv -f -- "$tmp" "$DIR/$id" || die "cannot write the lease of $id in $DIR"
}

release() { valid_id "${1:-}" || die "release needs a task id"; rm -f -- "$DIR/$1"; }

holders() {
  local f
  while IFS= read -r f; do sed '1d' "$f" | sed "s|^|${f##*/}\t|"; done < <(live_leases)
}

cmd=${1:-}; [ $# -eq 0 ] || shift
case $cmd in
  acquire) acquire "$@" ;;
  release) release "$@" ;;
  holders) holders ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "usage: lease.sh acquire <task-id> <file>... | release <task-id> | holders" ;;
esac
