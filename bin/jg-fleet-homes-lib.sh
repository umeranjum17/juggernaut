#!/usr/bin/env bash
# The homes of the fleet that one go-live moves, and the one place that lists them.
# Usage: . bin/jg-fleet-homes-lib.sh      (needs jg-compat.sh, jg-squad-lead-parent-lib.sh, jg-squad-lead-registry-lib.sh)
#
# The registry (data/squad_leads.md) is Main's, so a go-live run from a lead home reads Main's, never its own: a lead's own
# registry lists only its children, so reading it would move the lead alone and leave Main and every sibling behind.
#   jg_fleet_root_home <home>               follow the .jg-squad-lead-parent records up to Main's home (itself when it has none)
#   jg_fleet_homes <active-home> <active-root>
#       one line per local home, `<kind><TAB><id><TAB><dir>`, in move order: every registered lead (`lead`; the active home,
#       when it is one, is `self` and uses <active-root>), then Main (`primary`, id `primary`) last. Main's code dir is
#       <active-root> when the active home is Main, else Main's home itself. Remote leads are not listed: they update on their host.

jg_fleet_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"; }

jg_fleet_root_home() {  # <home>
  local home n=0
  home=$(jg_fleet_realpath "$1")
  while [ "$n" -lt 8 ] && jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$home")" \
    && [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ] && [ -d "$JG_SQUAD_LEAD_PARENT_HOME" ]; do
    home=$(jg_fleet_realpath "$JG_SQUAD_LEAD_PARENT_HOME"); n=$((n + 1))
  done
  printf '%s\n' "$home"
}

jg_fleet_homes() {  # <active-home> <active-root>
  local active root main line dir kind main_dir
  active=$(jg_fleet_realpath "$1"); root=$(jg_fleet_realpath "$2"); main=$(jg_fleet_root_home "$active")
  main_dir=$main; [ "$main" != "$active" ] || main_dir=$root
  if [ -f "$(jg_compat_pick "$main/data/squad_leads.md")" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      squad_lead_registry_parse_line "$line" || continue
      [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 0 ] || continue
      dir=$(jg_fleet_realpath "$SQUAD_LEAD_REGISTRY_HOME"); kind=lead
      [ "$dir" != "$main_dir" ] || continue
      if [ "$main" != "$active" ] && { [ "$dir" = "$active" ] || [ "$dir" = "$root" ]; }; then kind=self; dir=$root; fi
      printf '%s\t%s\t%s\n' "$kind" "$SQUAD_LEAD_REGISTRY_ID" "$dir"
    done < "$(jg_compat_pick "$main/data/squad_leads.md")"
  fi
  printf 'primary\tprimary\t%s\n' "$main_dir"
}
