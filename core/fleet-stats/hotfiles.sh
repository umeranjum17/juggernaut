#!/usr/bin/env bash
# hotfiles.sh - name the files that 3 or more lanes changed in a window, with a split proposal.
#
# Usage: hotfiles.sh --repo <dir> [--ref <ref>] [--days <n>] [--min-lanes <n>]
#                    [--now <unix-seconds>] [--post]
#
# A lane is one ticket: the commits of a window whose message carries a ticket id (a `Ticket: <id>`
# trailer, else a subject that starts `<id>: `); a commit with neither is not a lane. A file counts once per lane. Defaults: ref HEAD,
# 7 days, 3 lanes. The window is judged by commit time, not by git's own walk, which stops at the first
# out-of-order date. Read-only unless --post is given.
#
# Output: one tab-separated line per hot file, most lanes first:
#   <file> <lane count> <lane ids, comma separated> <split proposal>
# With --post, each hot file also becomes one [feature] board card through bin/jg-backlog.sh
# (`JG_BACKLOG` names another command), unless an open card already names the file. A failed post
# prints its cause and the script exits 1.
# Exit 2: usage error or a repo that cannot be read.
set -u

repo='' ref=HEAD days=7 min=3 now='' post=0
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:-}; shift 2 ;;
    --ref) ref=${2:-}; shift 2 ;;
    --days) days=${2:-}; shift 2 ;;
    --min-lanes) min=${2:-}; shift 2 ;;
    --now) now=${2:-}; shift 2 ;;
    --post) post=1; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "hotfiles: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] || { echo "hotfiles: --repo is required" >&2; exit 2; }
for n in "$days" "$min"; do
  case $n in ''|*[!0-9]*) echo "hotfiles: --days and --min-lanes need whole numbers" >&2; exit 2 ;; esac
done
[ -n "$now" ] || now=$(date +%s)
case $now in ''|*[!0-9]*) echo "hotfiles: --now needs unix seconds" >&2; exit 2 ;; esac

log=$(git -C "$repo" log "$ref" --no-merges --name-only --format='@@COMMIT%n%ct%n%B%n@@FILES' 2>&1) || { echo "hotfiles: cannot read $repo at $ref: $log" >&2; exit 2; }

hot=$(printf '%s' "$log" | python3 -I -c '
import re, sys
min_lanes, since, until = (int(a) for a in sys.argv[1:4])
lanes = {}
for rec in sys.stdin.read().split("@@COMMIT\n")[1:]:
    stamp, _, rest = rec.partition("\n")
    if not since <= int(stamp) <= until:
        continue
    msg, _, files = rest.partition("\n@@FILES\n")
    trailer = re.search(r"^Ticket:\s*(\S+)", msg, re.M)
    prefix = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*):\s", msg)
    lane = trailer.group(1) if trailer else (prefix.group(1) if prefix else "")
    if not lane:
        continue
    for f in files.split("\n"):
        if f.strip():
            lanes.setdefault(f.strip(), set()).add(lane)
rows = [(f, sorted(s)) for f, s in lanes.items() if len(s) >= min_lanes]
rows.sort(key=lambda r: (-len(r[1]), r[0]))
for f, s in rows:
    print("\t".join([f, str(len(s)), ",".join(s),
        "split by concern so each lane owns its own file: move the parts these lanes touch into new files under a directory named for " + f.rsplit("/", 1)[-1].split(".")[0] + ", and keep " + f + " as a thin entry point"]))
' "$min" "$((now - days * 86400))" "$now") || exit 2

[ -n "$hot" ] && printf '%s\n' "$hot"
[ "$post" = 1 ] || exit 0

backlog=${JG_BACKLOG:-${JG_BIN:-${JG_HOME:+$JG_HOME/bin}}/jg-backlog.sh}
rc=0
while IFS=$'\t' read -r file count ids proposal; do
  [ -n "$file" ] || continue
  if "$backlog" list 2>/dev/null | grep -F -q "hot file $file"; then continue; fi
  body=$(printf '%s\n\nCaptain: none, found by the weekly hot-file count.\nAsk: %s\nWhy: %s lanes (%s) changed %s in the last %s days; the spawn file hold turns that into a serial queue.\nDone when: the proposal is taken or declined on this card.\n' \
    "$file is changed by $count lanes in $days days" "$proposal" "$count" "$ids" "$file" "$days")
  if ! err=$("$backlog" add "[feature] hot file $file: $count lanes in $days days" --body "$body" 2>&1); then
    echo "hotfiles: could not post the card for $file: $err" >&2; rc=1
  fi
done <<<"$hot"
exit $rc
