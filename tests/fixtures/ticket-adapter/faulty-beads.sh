#!/usr/bin/env bash
# The wrapper the ticket adapter test names as JG_BEADS_SH: it is bin/jg-beads.sh, except that the fault the driver
# (faults.sh) left beside the store makes it fail the way a broken store does.
#   unreadable  every call fails, as a store that cannot be opened.
#   partial     `dolt sql` still answers, so a page of ids is read, but `show` fails, so the page cannot be vouched for.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
fault=$(cat "$(dirname "$BEADS_DIR")/.fault" 2>/dev/null || echo none)
case "$fault:${1-}" in
  unreadable:*) echo "store unreadable (test fault)" >&2; exit 1 ;;
  partial:show) echo "page unreadable (test fault)" >&2; exit 1 ;;
esac
exec "$here/bin/jg-beads.sh" "$@"
