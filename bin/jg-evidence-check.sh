#!/usr/bin/env bash
# jg-evidence-check.sh - flag a captain reply about a UI landing that attached nothing.
# Usage: jg-evidence-check.sh [<jg-home>]      (default: $JG_HOME, else this repository)
#
# A UI landing is a task whose record (state/<id>.meta) has `ui_change=yes` or a
# `screen=` value other than `none`, and a recorded `pr=<url>`. A reply recorded by
# `bin/jg-inbox.sh reply` (state/inbox/.replies/<note-id>) is about that landing when
# its text names the PR url. The reply must carry an `attach=` line (reply --attach or
# --evidence-from, bin/jg-evidence-lib.sh).
# Prints one line per such reply that has none, once per reply and task, then is silent.
# Replies older than a day are not looked at, so a home that adopts this check does not
# hear about its history. It reads files only and makes no model call.
#
# Watcher registration (single-link 0700 file, then bind its bytes):
#   printf '#!/usr/bin/env bash\nexec %q %q\n' "$JG_HOME/bin/jg-evidence-check.sh" "$JG_HOME" \
#     > state/reply-evidence.check.sh && chmod 0700 state/reply-evidence.check.sh
#   bin/jg-check-register.sh reply-evidence
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR=${1:-${JG_HOME:-$(cd "$SELF_DIR/.." && pwd)}}
STATE=${JG_STATE_OVERRIDE:-$HOME_DIR/state}
SEEN=$STATE/.reply-evidence-seen
# shellcheck source=bin/jg-evidence-lib.sh
. "$SELF_DIR/jg-evidence-lib.sh"

[ -d "$STATE/inbox/.replies" ] || exit 0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  jg_evidence_ui_task "$meta" || continue
  id=$(basename "$meta" .meta)
  url=$(sed -n 's/^pr=//p' "$meta" | tail -1)
  [ -n "$url" ] || continue
  while IFS= read -r reply; do
    [ -f "$reply" ] || continue
    rid=$(basename "$reply")
    case "$rid" in .*) continue ;; esac
    grep -qxF -- "$rid|$id" "$SEEN" 2>/dev/null && continue
    # Header lines run to the first `--`; the text after it must name the PR.
    sed -n '/^--$/,$p' "$reply" | grep -qF -- "$url" || continue
    sed -n '/^--$/q;p' "$reply" | grep -q '^attach=' && continue
    printf '%s|%s\n' "$rid" "$id" >>"$SEEN"
    printf 'check: reply %s names the UI landing %s (%s) but attaches no screenshot or proof; the owner asked for pictures with UI work\n' "$rid" "$id" "$url"
  done < <(find "$STATE/inbox/.replies" -maxdepth 1 -type f -mmin -1440 2>/dev/null | sort)
done
exit 0
