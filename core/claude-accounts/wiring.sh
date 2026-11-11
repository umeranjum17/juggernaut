#!/usr/bin/env bash
# Point one Juggernaut home's config/account-pool at the claude-accounts chooser, so every new Claude worker
# shares signed-in accounts in proportion to quota runway. Refuses to replace a different account-pool file.
# Usage: wiring.sh <jg-home>          Undo: unwiring.sh <jg-home>
#
# The file is two lines, command=<chooser> and state=<pool state folder>. A new file names this checkout's chooser and the
# home's own state folder. A file that already names this chooser, or the one the pre-rename add-on installed
# (<checkout>/firstmate-addons/claude-accounts/bin/claude-accounts-pick), is this step's own wiring: its command line is
# set to this checkout's chooser and its state folder is kept, because a home may share another home's pool on purpose.
# A rerun is a no-op. Any other file is refused untouched.
set -euo pipefail
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: wiring.sh <jg-home>" >&2; exit 2; }
home=$(cd "$1" && pwd -P)
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cmd=$src/bin/claude-accounts-pick
state=$home/state
file=$home/config/account-pool
if [ -e "$file" ]; then
  have_cmd=$(sed -n '1s/^command=//p' "$file") have_state=$(sed -n '2s/^state=//p' "$file")
  case $have_cmd in
    "$cmd" | */firstmate-addons/claude-accounts/bin/claude-accounts-pick) ours=1 ;;
    *) ours=0 ;;
  esac
  case $have_state in /*) ;; *) ours=0 ;; esac
  if [ "$ours" = 0 ] || [ "$(wc -l < "$file")" -ne 2 ]; then
    echo "error: $file already exists and is not the claude-accounts one; leaving it alone" >&2
    exit 1
  fi
  state=$have_state
fi
want=$(printf 'command=%s\nstate=%s\n' "$cmd" "$state")
if [ -e "$file" ] && [ "$(cat "$file")" = "$want" ]; then
  echo "already installed: $file -> $cmd"
  exit 0
fi
printf '%s\n' "$want" >"$file.new.$$" && mv -f -- "$file.new.$$" "$file"
echo "installed: $file -> $cmd${have_cmd:+ (was $have_cmd)}"
