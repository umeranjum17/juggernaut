#!/usr/bin/env bash
# Who is responsible for the open pull requests of a repository: one record, read by every home.
# Usage: jg-pr-owner.sh set <owner/repo> <lead-id>   Main only: the lead home that answers for the repository
#        jg-pr-owner.sh clear <owner/repo>           Main only: the repository goes back to Main
#        jg-pr-owner.sh get <owner/repo>             print the lead id, or `main` when no line names one
#        jg-pr-owner.sh mine <owner/repo>            exit 0 when THIS home answers for it, 1 when another home does, 2 when the record cannot be read
#        jg-pr-owner.sh list                         print the record
#
# The record is Main's data/pr-owners.tsv, one `<owner/repo><TAB><lead id>` line per repository; a repository with no
# line belongs to Main, so no pull request is ever without a responsible home. A lead home reads the same file
# through its parent binding (bin/jg-squad-lead-parent-lib.sh): a local route names the parent home directly. A
# remote lead has no path to it and reads its own copy at data/pr-owners.tsv, and with no copy `mine` exits 2, so
# the pager skips the repository instead of guessing.
# JG_HOME names the home this runs for (default: the home this script lives in).
set -euo pipefail
SELF=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
JG_HOME=${JG_HOME:-$(cd "$SELF/.." && pwd)}
# shellcheck source=bin/jg-parent-channel-lib.sh disable=SC1091
. "$SELF/jg-parent-channel-lib.sh"

die() { echo "jg-pr-owner: $*" >&2; exit 2; }
args() { local n=$1; shift; [ "$#" -eq "$n" ] && repo_ok "$1"; }
repo_ok() { case ${1-} in */*/*|''|/*|*/|*[!A-Za-z0-9_./-]*) return 1 ;; */*) return 0 ;; *) return 1 ;; esac; }

# The lead id of this home, empty for Main.
me=''
if me=$(jg_parent_channel_home_id "$JG_HOME"); then :; else
  rc=$?; me=''
  [ "$rc" -eq 1 ] || die "this home's lead identity marker is unusable"
fi

# The record to read: Main's own, the parent's through a local binding, or a remote lead's own copy.
RECORD=$JG_HOME/data/pr-owners.tsv
if [ -n "$me" ]; then
  jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$JG_HOME")" || die "this lead home has no readable parent binding"
  [ "$JG_SQUAD_LEAD_PARENT_ROUTE" != local ] || RECORD=$JG_SQUAD_LEAD_PARENT_HOME/data/pr-owners.tsv
fi

owner_of() {  # <repo> -> lead id or main
  awk -F '\t' -v r="$1" '$1 == r { o = $2 } END { print (o == "" ? "main" : o) }' "$RECORD" 2>/dev/null || echo main
}

write_record() {  # <repo> <lead id or empty>: replace the repository's line, atomically
  local file=$JG_HOME/data/pr-owners.tsv tmp
  [ -z "$me" ] || die "only Main writes the owner record"
  mkdir -p "$JG_HOME/data"
  tmp=$(mktemp "$JG_HOME/data/.pr-owners.XXXXXX")
  { awk -F '\t' -v r="$1" '$1 != r' "$file" 2>/dev/null || :; [ -z "$2" ] || printf '%s\t%s\n' "$1" "$2"; } | sort > "$tmp"
  mv -f "$tmp" "$file"
}

cmd=${1-}; [ "$#" -gt 0 ] && shift
case $cmd in
  set)   args 2 "$@" || die "usage: set <owner/repo> <lead-id>"
         _jg_parent_channel_id_valid "$2" || die "invalid lead id: $2"
         write_record "$1" "$2"; echo "$1 -> $2" ;;
  clear) args 1 "$@" || die "usage: clear <owner/repo>"
         write_record "$1" ''; echo "$1 -> main" ;;
  get)   args 1 "$@" || die "usage: get <owner/repo>"
         owner_of "$1" ;;
  mine)  args 1 "$@" || die "usage: mine <owner/repo>"
         [ -z "$me" ] || [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ] || [ -r "$RECORD" ] || exit 2
         [ "$(owner_of "$1")" = "${me:-main}" ] ;;
  list)  cat "$RECORD" 2>/dev/null || : ;;
  *)     die "usage: set|clear|get|mine|list (see the script header)" ;;
esac
