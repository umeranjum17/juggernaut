# shellcheck shell=bash
# The name a home goes by in a Beads store: `main`, or `lead:<id>` for a Squad Lead home. It is the actor of the home's own
# writes (so `created_by` and the journal name the filer) and the assignee of a row the home holds with no worker.
# Usage: . bin/jg-home-name-lib.sh; jg_home_actor <home>   (no home prints `juggernaut`, the name before a home is known)
jg_home_actor() {  # <home>
  local home=${1-} marker id
  [ -n "$home" ] || { printf 'juggernaut\n'; return 0; }
  for marker in "$home/.jg-squad-lead-home" "$home/.fm-secondmate-home"; do
    [ -r "$marker" ] || continue
    id=$(tr -d '[:space:]' < "$marker")
    [ -z "$id" ] || { printf 'lead:%s\n' "$id"; return 0; }
  done
  printf 'main\n'
}
