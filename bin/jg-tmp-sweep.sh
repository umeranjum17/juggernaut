#!/usr/bin/env bash
# jg-tmp-sweep.sh - /tmp pressure guard: report space and inode use and sweep stale fleet scratch.
#
# A tmpfs /tmp has a fixed size and a fixed inode budget, and fleet tooling
# leaks many small entries into it (mktemp dirs, per-home agent scratch, tool
# caches). Either limit running out breaks wake acknowledgements and tools.
# bin/jg-sentinel.sh tick calls both modes below; this script owns the policy.
#
# Usage:
#   jg-tmp-sweep.sh check [--root DIR] [--warn-pct N]
#       Print the space and inode use of the filesystem holding DIR; exit 1 when
#       either reaches N percent (default JG_TMP_WARN_PCT, else 80), 0 below
#       both, 2 when a use cannot be read.
#   jg-tmp-sweep.sh top [--root DIR] [-n N]
#       Print one line naming the N (default 5) largest entries of DIR with the
#       lane of each: "<name> <MB>MB lane=<task id or none>; ...".
#   jg-tmp-sweep.sh sweep [--dry-run | --apply] [--root DIR] [--min-age-days N]
#       List (default, --dry-run) or remove (--apply) stale entries; see below.
#
# What a sweep may remove, all directly under DIR (default /tmp, JG_TMP_ROOT):
#   - an entry named tmp.*, crewhouse-*, or claude-accounts.* (file or directory);
#   - the fleet's own mktemp names: jg-test-run.* and tickets-sync* (short age, as
#     below), and jg-<task id> lane scratch of a home with a state folder, kept
#     while a state/<id>.meta of that home names its task;
#   - a browser or render leftover named com.google.Chrome.*, org.chromium.Chromium.*,
#     puppeteer_dev_chrome_profile-* or first-draft-*;
#   - an entry directly inside a container named claude-<digits> (per-home agent
#     scratch) or opencode; the container itself is never removed;
#   - a session folder directly inside a project folder of a claude-<digits>
#     container (claude-1000/<project>/<session>), when the project folder itself
#     is kept only because a live process or recent change touches it. A project
#     folder kept as a live lane's is never entered. The project folder stays.
# Anything else is never touched and is only counted by name prefix.
# An allowlisted entry is kept unless every one of these holds:
#   - it is a real file or directory (never a symlink) owned by this user;
#   - nothing in its tree, including itself, changed in the last N days
#     (default 1, JG_TMP_SWEEP_MIN_AGE_DAYS); for the browser and render leftovers
#     and for the entries of a claude-<digits> container the age is M minutes
#     (default 120, JG_TMP_SWEEP_SHORT_AGE_MIN, --short-age-min), never longer than N days;
#   - no live process has it as a cwd, an open file, a command-line argument or
#     an environment value, or inside any of those (read from /proc);
#   - no live lane owns it: no state/*.meta of JG_HOME (when set) names its
#     task id or its worktree path as part of the entry name, and it is not
#     inside or above a directory recorded in state/*.scratch.
# A host with no /proc cannot prove liveness, so a sweep there refuses (exit 3).
# Removal is find -P -xdev -depth -delete on the one checked path: symlinks are
# removed as links and never followed, and other filesystems are not entered.
# Output: one "remove <path>" (or "would remove <path>") line per entry, then a
# summary with the removed count by name prefix, the kept counts by reason and the
# not-allowlisted count by prefix.
# Exit: 0 after a pass, 1 when a removal failed, 2 for usage, 3 when unsafe.
set -u

ROOT=${JG_TMP_ROOT:-/tmp}
WARN_PCT=${JG_TMP_WARN_PCT:-80}
MIN_AGE_DAYS=${JG_TMP_SWEEP_MIN_AGE_DAYS:-1}
SHORT_AGE_MIN=${JG_TMP_SWEEP_SHORT_AGE_MIN:-120}

usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "jg-tmp-sweep: $*" >&2; exit "${2:-2}"; }

MODE=${1:-}
case "$MODE" in
  check|sweep|top) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
APPLY=0; TOP_N=5
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT=$2; shift 2 ;;
    --warn-pct) [ $# -ge 2 ] || die "--warn-pct needs a value"; WARN_PCT=$2; shift 2 ;;
    --min-age-days) [ $# -ge 2 ] || die "--min-age-days needs a value"; MIN_AGE_DAYS=$2; shift 2 ;;
    --short-age-min) [ $# -ge 2 ] || die "--short-age-min needs a value"; SHORT_AGE_MIN=$2; shift 2 ;;
    -n) [ $# -ge 2 ] || die "-n needs a value"; TOP_N=$2; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$WARN_PCT" in ''|*[!0-9]*) die "warn percent must be a number" ;; esac
case "$MIN_AGE_DAYS" in ''|*[!0-9]*) die "min age days must be a number" ;; esac
case "$SHORT_AGE_MIN" in ''|*[!0-9]*) die "short age minutes must be a number" ;; esac
case "$TOP_N" in ''|*[!0-9]*) die "-n must be a number" ;; esac
case "$ROOT" in /*) ;; *) die "root must be an absolute path" ;; esac
case "$ROOT" in *[*?[]*|*$'\n'*|*//*|*/./*|*/../*|*/.|*/..) die "root has a glob, newline or dot component" ;; esac
[ "$ROOT" = / ] || ROOT=${ROOT%/}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || die "root is not a real directory: $ROOT"
[ "$ROOT" != / ] || die "refusing to sweep /"

# "<used-percent> <human use>" for the filesystem holding ROOT in inodes (i) or KiB (k);
# fails when unreadable, and a filesystem that reports no inode limit is 0 percent, unlimited.
fs_use() {
  df -P"$1" "$ROOT" 2>/dev/null | awk -v unit="$1" 'NR == 2 {
    if ($2 == "0") { print "0 unlimited"; exit }
    if ($2 !~ /^[0-9]+$/) exit 1
    if (unit == "i") printf "%d %s of %s\n", $3 * 100 / $2, $3, $2
    else printf "%d %.1fG of %.0fG\n", $3 * 100 / $2, $3 / 1048576, $2 / 1048576
  }'
}

if [ "$MODE" = check ]; then
  iu=$(fs_use i) || die "cannot read inode use of $ROOT"
  su=$(fs_use k) || die "cannot read space use of $ROOT"
  ipct=${iu%% *}; spct=${su%% *}
  printf '%s space %s%% used (%s), inodes %s%% used (%s)\n' \
    "$ROOT" "$spct" "${su#* }" "$ipct" "${iu#* }"
  [ "$ipct" -lt "$WARN_PCT" ] && [ "$spct" -lt "$WARN_PCT" ]
  exit $?
fi

[ -d /proc/self ] || die "no /proc here, so liveness of a scratch entry cannot be proven; refusing to sweep" 3
NOW=$(date +%s)
stamp_of() { date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S'; }  # local time, which is what find -newermt reads
CUTOFF=$(( NOW - MIN_AGE_DAYS * 86400 ))
CUTOFF_STAMP=$(stamp_of "$CUTOFF")
# The short-lived class (browser and render leftovers, claude-<digits> entries) ages out sooner, never later.
SHORT_CUTOFF=$(( NOW - SHORT_AGE_MIN * 60 ))
[ "$SHORT_CUTOFF" -ge "$CUTOFF" ] || SHORT_CUTOFF=$CUTOFF
SHORT_STAMP=$(stamp_of "$SHORT_CUTOFF")

# Newline-delimited "<name>" and "<name>/<child>" keys, relative to ROOT, of the
# paths that live processes use plus recorded lane scratch. An entry is live when
# its own key is listed, which is when it holds, or contains, a path in use.
ROOT_RE=$(printf '%s' "$ROOT" | sed 's/[][\.*^$+?(){}|]/\\&/g')
LIVE_KEYS=$(
  {
    for p in /proc/[0-9]*; do
      {
        readlink "$p/cwd" "$p"/fd/*
        for f in cmdline environ; do
          tr '\0' '\n' <"$p/$f" | grep -aoE "$ROOT_RE/[^[:space:]:\"'=]+"
        done
      } 2>/dev/null
    done
    [ -z "${JG_HOME:-}" ] || cat "$JG_HOME"/state/*.scratch 2>/dev/null
  } | sed 's/ (deleted)$//' | awk -v r="$ROOT/" 'index($0, r) == 1 { n = split(substr($0, length(r) + 1), c, "/"); print c[1]; if (n > 1) print c[1] "/" c[2]; if (n > 2) print c[1] "/" c[2] "/" c[3] }' | sort -u
)

# Lane tokens: a task id or worktree path that, as an entry-name part, marks the entry as a lane's.
LANE_TOKENS=
if [ -n "${JG_HOME:-}" ]; then
  for meta in "$JG_HOME"/state/*.meta; do
    [ -f "$meta" ] || continue
    LANE_TOKENS="$LANE_TOKENS
$(basename "$meta" .meta)"
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -n 1)
    [ -z "$wt" ] || LANE_TOKENS="$LANE_TOKENS
$(printf '%s' "$wt" | tr '/.' '--')"
  done
fi

# Top-level names the sweep may remove: the long-lived class, then the short-lived class.
short_lived_name() {
  case "$1" in com.google.Chrome.*|org.chromium.Chromium.*|puppeteer_dev_chrome_profile-*|first-draft-*|jg-test-run.*|tickets-sync*) return 0 ;; esac
  return 1
}
allowlisted_name() {
  case "$1" in tmp.*|crewhouse-*|claude-accounts.*) return 0 ;; esac
  # jg-<id> lane scratch: only where this home's lane records can say which ids are live.
  case "$1" in jg-*) [ -n "${JG_HOME:-}" ] && [ -d "$JG_HOME/state" ] && return 0 ;; esac
  short_lived_name "$1"
}

# Why <path> (an absolute path under ROOT) must be kept, judged against the cutoff stamp <stamp>
# (default: the long one); prints nothing when it may go.
keep_reason() {
  local path=$1 stamp=${2:-$CUTOFF_STAMP} name=${1##*/} rel token
  [ ! -L "$path" ] || { echo symlink; return; }
  [ -O "$path" ] || { echo not-owned; return; }
  rel=${path#"$ROOT"/}
  case "
$LIVE_KEYS
" in *"
$rel
"*) echo live-process; return ;; esac
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$name$path" in *"$token"*) echo live-lane; return ;; esac
  done <<EOF
$LANE_TOKENS
EOF
  if [ -n "$(find -P "$path" -xdev -newermt "$stamp" -print -quit 2>/dev/null)" ]; then
    echo recent; return
  fi
}

if [ "$MODE" = top ]; then
  du -sxk -- "$ROOT"/* "$ROOT"/.[!.]* 2>/dev/null | sort -rn | head -n "$TOP_N" | while IFS=$'\t' read -r kb path; do
    name=${path##*/}; lane=none
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      case "$name$path" in *"$token"*) lane=$token; break ;; esac
    done <<EOT
$LANE_TOKENS
EOT
    printf '%s %sMB lane=%s\n' "$name" $(( kb / 1024 )) "$lane"
  done | paste -sd';' - | sed 's/;/; /g'
  exit 0
fi

REMOVED=0; FAILED=0; KEPT_LIST=; OTHER=0
note_keep() { KEPT_LIST="$KEPT_LIST
$1"; }
REMOVED_PREFIXES=
note_removed() {  # <path>: count it under the name prefix of its top-level entry
  local top=${1#"$ROOT"/}; top=${top%%/*}
  REMOVED_PREFIXES="$REMOVED_PREFIXES
${top%%[.+_-]*}"
}

consider() {  # <absolute path of an allowlisted entry> [<cutoff stamp>]
  local entry=$1 why
  why=$(keep_reason "$entry" "${2:-}")
  if [ -n "$why" ]; then note_keep "$why"; return; fi
  if [ "$APPLY" = 1 ]; then
    # A read-only directory (a locked hooks folder) blocks its own removal; unlock this entry's directories first.
    find -P "$entry" -xdev -type d ! -perm -u+rwx -exec chmod u+rwx {} + 2>/dev/null
    if find -P "$entry" -xdev -depth -delete 2>/dev/null; then
      printf 'remove %s\n' "$entry"; REMOVED=$((REMOVED + 1)); note_removed "$entry"
    else
      printf 'FAILED %s\n' "$entry" >&2; FAILED=$((FAILED + 1))
    fi
  else
    printf 'would remove %s\n' "$entry"; REMOVED=$((REMOVED + 1)); note_removed "$entry"
  fi
}

# Entries are walked by name only (no forks per entry); just the ones whose own
# mtime is already older than the cutoff go through the deeper keep_reason checks.
old_entries() {  # <dir> [<cutoff stamp>]: NUL-separated children whose own mtime is older than the cutoff
  find -P "$1" -mindepth 1 -maxdepth 1 ! -newermt "${2:-$CUTOFF_STAMP}" -print0 2>/dev/null
}

before=$(fs_use i) || before="? ?"; before_space=$(fs_use k) || before_space=
OTHER_PREFIXES=; ALLOWED=0; CONSIDERED=0; CONTAINERS=
for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=${entry##*/}
  if allowlisted_name "$name"; then ALLOWED=$((ALLOWED + 1)); continue; fi
  case "$name" in
    claude-[0-9]*|opencode)
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        CONTAINERS="$CONTAINERS
$entry"
        for child in "$entry"/* "$entry"/.[!.]*; do
          [ -e "$child" ] || [ -L "$child" ] || continue
          ALLOWED=$((ALLOWED + 1))
        done
      fi
      ;;
    *) OTHER=$((OTHER + 1)); OTHER_PREFIXES="$OTHER_PREFIXES
${name%%[.+_-]*}" ;;
  esac
done
while IFS= read -r -d '' entry; do
  allowlisted_name "${entry##*/}" || continue
  CONSIDERED=$((CONSIDERED + 1))
  if short_lived_name "${entry##*/}"; then consider "$entry" "$SHORT_STAMP"; else consider "$entry"; fi
done < <(old_entries "$ROOT" "$SHORT_STAMP")
# A container is never removed itself, however old; only its old children are.
# A project folder of a claude-<digits> container that is still there is entered
# whatever its own age: its old, unused session folders go and the project folder
# stays. A lane's project folder, a symlink and a foreign one are not entered.
while IFS= read -r container; do
  [ -n "$container" ] || continue
  stamp=$CUTOFF_STAMP
  case "${container##*/}" in claude-[0-9]*) stamp=$SHORT_STAMP ;; esac
  while IFS= read -r -d '' child; do
    CONSIDERED=$((CONSIDERED + 1)); consider "$child" "$stamp"
  done < <(old_entries "$container" "$stamp")
  case "${container##*/}" in claude-[0-9]*) ;; *) continue ;; esac
  for child in "$container"/* "$container"/.[!.]*; do
    [ -d "$child" ] && [ ! -L "$child" ] && [ -O "$child" ] || continue
    case "$(keep_reason "$child")" in live-lane) continue ;; esac
    while IFS= read -r -d '' session; do consider "$session" "$stamp"; done < <(old_entries "$child" "$stamp")
  done
done <<EOF
$CONTAINERS
EOF
RECENT=$((ALLOWED - CONSIDERED))
after=$(fs_use i) || after="? ?"; after_space=$(fs_use k) || after_space=

verb="would remove"; [ "$APPLY" = 0 ] || verb="removed"
printf '%s %d entries older than %s days (cutoff %s)\n' "$verb" "$REMOVED" "$MIN_AGE_DAYS" "$CUTOFF_STAMP"
printf '%s by prefix:' "$verb"
printf '%s\n' "$REMOVED_PREFIXES" | grep -v '^$' | sort | uniq -c | sort -rn | awk '{printf " %s=%s", $2, $1}'
printf '\n'
printf 'kept by reason:'
printf '%s\n' "$KEPT_LIST" | grep -v '^$' | sort | uniq -c | awk -v q="$RECENT" '{printf " %s=%s", $2, $1} END {printf " recent-by-own-mtime=%d\n", q}'
printf 'not allowlisted, left alone: %d entries; top prefixes:' "$OTHER"
printf '%s\n' "$OTHER_PREFIXES" | grep -v '^$' | sort | uniq -c | sort -rn | head -n 8 | awk '{printf " %s=%s", $2, $1}'
printf '\n'
read -r b _ <<<"$before"
read -r a _ <<<"$after"
read -r bs _ <<<"$before_space"
read -r as _ <<<"$after_space"
printf 'inode use of %s: %s%% before, %s%% after\n' "$ROOT" "$b" "$a"
printf 'space use of %s: %s%% before, %s%% after\n' "$ROOT" "$bs" "$as"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
