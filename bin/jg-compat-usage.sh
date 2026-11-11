#!/usr/bin/env bash
# Which pre-rename (old) names a home or this host still uses, so the lead can tell when the compatibility layer
# (bin/jg-compat.sh, the bin/fm-*.sh aliases) has nothing left to serve.
# Usage: jg-compat-usage.sh [--home <dir>]... [--host]
#
# Read-only. It reads file names, record schema lines, setting names and unit names, never a setting's value.
# One line per old name in use, `<scope>: <kind> <old> [-> <new>] (<where>)`, then a last line `in use: <n>` with
# the count by kind. Exit 0 when none is in use, 1 when some is, 2 on bad usage or a source it could not read (the
# cause goes to stderr, so a source that was not read never passes as a clean 0).
#
# --home <dir>  One home; repeat it for each home. What bin/jg-compat.sh still accepts in its old spelling:
#   marker       .fm-secondmate-home, .fm-secondmate-parent - when the new marker is absent
#   file         data/secondmates.md, config/secondmate-harness, config/secondmates, config/firstmate-role,
#                config/.fm-inherit-firstmate-role.generation - when the new name is absent
#   setting      an FM_ name at the start of a line in a config/ file (FM_X=, export FM_X=, or a bare FM_X)
#   record       fm-custom-check-v1 (first line of state/*.check-trust), fm-mail-check-v1 (state/.mail-check),
#                fm-tool-updates-v1 (state/.tool-updates), schema=fm-decision-binding.v1
#                (state/decision-bindings/*.origin), schema=fm-reconcile-request.v1 (state/reconcile-requests/*.request),
#                kind=secondmate (state/*.meta), task_label=fm-* (state/*.herdr-presentation), and the FIRSTMATE_OP
#                marker on an unhandled message (state/operational-inbox/*.msg, state/*.inbox/*.msg)
#   slot         .fm-slot-owner beside a worktree a state/*.meta names - when .jg-slot-owner is absent
# --host  This host's systemd user units and install folders:
#   unit         a unit file whose name starts with fm- (systemctl --user list-unit-files), with its state
#   folder       an install folder ${XDG_DATA_HOME:-~/.local/share}/fm-*
#   command      a user service whose Exec line runs an fm-*.sh script
#   environment  a user service, or the user manager itself, that sets an FM_ name
#   claims       ${XDG_STATE_HOME:-~/.local/state}/firstmate/procevent-claims - when the juggernaut root is absent
#
# Not read: a home's .env (secrets, read by key and never exported), data/ beyond the one registry name, live pane
# titles, EnvironmentFile= contents, shell profiles and crontabs.
set -u

die() { echo "jg-compat-usage: $*" >&2; exit 2; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }

KINDS="marker file setting record slot unit folder command environment claims"
FOUND=""      # one kind per finding, newline separated
UNREAD=0      # a source that could not be read

# emit <scope> <kind> <old> <new or empty> <where or empty>
emit() {
  local line="$1: $2 $3"
  [ -z "$4" ] || line="$line -> $4"
  [ -z "$5" ] || line="$line ($5)"
  printf '%s\n' "$line"
  FOUND="$FOUND$2"$'\n'
}

unread() { echo "jg-compat-usage: $1 not read: $2" >&2; UNREAD=1; }

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# --- one home --------------------------------------------------------------------------------------------------------

home_names() {  # <home>: an old name the code still falls back to while the new one is absent
  local home=$1 pair kind old new
  for pair in \
    "marker .fm-secondmate-home .jg-squad-lead-home" \
    "marker .fm-secondmate-parent .jg-squad-lead-parent" \
    "file data/secondmates.md data/squad_leads.md" \
    "file config/secondmate-harness config/squad-lead-harness" \
    "file config/secondmates config/squad_leads" \
    "file config/firstmate-role config/juggernaut-role" \
    "file config/.fm-inherit-firstmate-role.generation config/.jg-inherit-juggernaut-role.generation"; do
    read -r kind old new <<<"$pair"
    if exists "$home/$old" && ! exists "$home/$new"; then emit "$home" "$kind" "$old" "$new" ""; fi
  done
}

home_settings() {  # <home>: FM_ names set or listed in the home's config files; the value is never printed
  local home=$1 file hit name
  [ -d "$home/config" ] || return 0
  while IFS= read -r file; do
    while IFS= read -r hit; do
      name=${hit#*:}; name=${name##*[[:space:]]}
      emit "$home" setting "$name" "JG_${name#FM_}" "${file#"$home"/}:${hit%%:*}"
    done < <(grep -noIE '^[[:space:]]*(export[[:space:]]+)?FM_[A-Za-z0-9_]+' -- "$file" 2>/dev/null)
  done < <(find "$home/config" -type f 2>/dev/null | LC_ALL=C sort)
}

first_line_is() {  # <file> <text>
  local line=""
  [ -f "$1" ] && IFS= read -r line < "$1"
  [ "$line" = "$2" ]
}

home_records() {  # <home>: records whose schema line or field still carries the old spelling
  local home=$1 state=$1/state f mark first
  mark=$'\xE2\x81\xA3'
  for f in "$state"/*.check-trust; do
    first_line_is "$f" fm-custom-check-v1 && emit "$home" record fm-custom-check-v1 jg-custom-check-v1 "${f#"$home"/}"
  done
  first_line_is "$state/.mail-check" fm-mail-check-v1 \
    && emit "$home" record fm-mail-check-v1 jg-mail-check-v1 state/.mail-check
  first_line_is "$state/.tool-updates" fm-tool-updates-v1 \
    && emit "$home" record fm-tool-updates-v1 jg-tool-updates-v1 state/.tool-updates
  for f in "$state"/decision-bindings/*.origin; do
    [ -f "$f" ] && grep -qx 'schema=fm-decision-binding.v1' "$f" \
      && emit "$home" record schema=fm-decision-binding.v1 schema=jg-decision-binding.v1 "${f#"$home"/}"
  done
  for f in "$state"/reconcile-requests/*.request; do
    [ -f "$f" ] && grep -qx 'schema=fm-reconcile-request.v1' "$f" \
      && emit "$home" record schema=fm-reconcile-request.v1 schema=jg-reconcile-request.v1 "${f#"$home"/}"
  done
  for f in "$state"/*.meta; do
    [ -f "$f" ] && grep -qx 'kind=secondmate' "$f" && emit "$home" record kind=secondmate kind=squad_lead "${f#"$home"/}"
  done
  for f in "$state"/*.herdr-presentation; do
    [ -f "$f" ] && grep -q '^task_label=fm-' "$f" && emit "$home" record task_label=fm- task_label=jg- "${f#"$home"/}"
  done
  for f in "$state"/operational-inbox/*.msg "$state"/*.inbox/*.msg; do
    [ -f "$f" ] || continue
    first=$(head -c 32 "$f" 2>/dev/null)
    case $first in
      "${mark}FIRSTMATE_OP: "*) emit "$home" record FIRSTMATE_OP JUGGERNAUT_OP "${f#"$home"/}" ;;
    esac
  done
}

home_slots() {  # <home>: a pool slot claimed under the old name, for a worktree this home's records name
  local home=$1 f wt slot seen=$'\n'
  for f in "$home"/state/*.meta; do
    [ -f "$f" ] || continue
    wt=$(sed -n 's/^worktree=//p' "$f" | tail -n 1)
    [ -n "$wt" ] || continue
    wt=$(CDPATH='' cd -- "$wt" 2>/dev/null && pwd -P) || continue
    slot=${wt%/*}
    case $seen in *$'\n'"$slot"$'\n'*) continue ;; esac
    seen="$seen$slot"$'\n'
    if exists "$slot/.fm-slot-owner" && ! exists "$slot/.jg-slot-owner"; then
      emit "$home" slot .fm-slot-owner .jg-slot-owner "$slot"
    fi
  done
}

check_home() {
  local home
  home=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || die "--home $1 is not a directory"
  [ -d "$home/state" ] && [ -d "$home/config" ] || die "--home $1 is not a Juggernaut home (no state/ and config/)"
  home_names "$home"
  home_settings "$home"
  home_records "$home"
  home_slots "$home"
}

# --- this host -------------------------------------------------------------------------------------------------------

# service_block <unit> <block>: the old names one service's Exec and Environment lines carry (one block of
# `systemctl show`); each name is reported once per unit.
service_block() {
  local unit=$1 block=$2 name seen=$'\n'
  while IFS= read -r name; do
    case $seen in *$'\n'"$name"$'\n'*) continue ;; esac
    seen="$seen$name"$'\n'
    emit host command "$name" "jg-${name#fm-}" "$unit"
  done < <(printf '%s\n' "$block" | grep '^Exec' | grep -oE '(^|[^A-Za-z0-9_.-])fm-[A-Za-z0-9_-]+\.sh' \
    | sed -E 's/^[^f]//')
  while IFS= read -r name; do
    case $seen in *$'\n'"$name"$'\n'*) continue ;; esac
    seen="$seen$name"$'\n'
    emit host environment "$name" "JG_${name#FM_}" "$unit"
  done < <(printf '%s\n' "$block" | sed -n 's/^Environment=//p' | tr ' ' '\n' | grep -oE '^FM_[A-Za-z0-9_]+=' \
    | sed 's/=$//')
}

host_units() {
  local list err name state rest block line services=()
  command -v systemctl >/dev/null 2>&1 || { unread "host units" "systemctl is not installed"; return 0; }
  err=$(mktemp "${TMPDIR:-/tmp}/jg-compat-usage.XXXXXX") || { unread "host units" "no temporary file"; return 0; }
  if ! list=$(systemctl --user list-unit-files --no-legend 2>"$err"); then
    unread "host units" "systemctl --user list-unit-files: $(head -n 1 "$err")"
    rm -f -- "$err"; return 0
  fi
  while read -r name state rest; do
    [ -n "$name" ] || continue
    case $name in fm-*) emit host unit "$name" "" "$state" ;; esac
    case $name in *@.service) ;; *.service) services+=("$name") ;; esac
  done <<<"$list"
  if [ "${#services[@]}" -gt 0 ]; then
    if ! list=$(systemctl --user show -p Id -p ExecStart -p ExecStartPre -p ExecStartPost -p Environment \
      -- "${services[@]}" 2>"$err"); then
      unread "host service commands" "systemctl --user show: $(head -n 1 "$err")"
    else
      # One block per unit, blocks separated by a blank line; the extra blank line closes the last one.
      block=""
      while IFS= read -r line; do
        if [ -n "$line" ]; then block="$block$line"$'\n'; continue; fi
        [ -z "$block" ] || service_block "$(printf '%s' "$block" | sed -n 's/^Id=//p' | head -n 1)" "$block"
        block=""
      done < <(printf '%s\n\n' "$list")
    fi
  fi
  if ! list=$(systemctl --user show-environment 2>"$err"); then
    unread "user manager environment" "systemctl --user show-environment: $(head -n 1 "$err")"
  else
    while IFS= read -r name; do
      emit host environment "$name" "JG_${name#FM_}" "user manager"
    done < <(printf '%s\n' "$list" | grep -oE '^FM_[A-Za-z0-9_]+=' | sed 's/=$//')
  fi
  rm -f -- "$err"
}

host_folders() {
  local share=${XDG_DATA_HOME:-$HOME/.local/share} d
  for d in "$share"/fm-*; do
    [ -d "$d" ] && emit host folder "${d##*/}" "jg-${d##*/fm-}" "$share"
  done
}

host_claims() {
  local root=${XDG_STATE_HOME:-$HOME/.local/state}
  if [ -d "$root/firstmate/procevent-claims" ] && [ ! -d "$root/juggernaut/procevent-claims" ]; then
    emit host claims firstmate/procevent-claims juggernaut/procevent-claims "$root"
  fi
}

check_host() {
  [ -n "${HOME:-}" ] || die "--host needs HOME"
  host_units
  host_folders
  host_claims
}

# --- main ------------------------------------------------------------------------------------------------------------

HOMES=()
HOST=0
while [ $# -gt 0 ]; do
  case $1 in
    --home) [ $# -ge 2 ] && [ -n "$2" ] || die "--home needs a directory"; HOMES+=("$2"); shift 2 ;;
    --host) HOST=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done
[ "${#HOMES[@]}" -gt 0 ] || [ "$HOST" = 1 ] || usage

for h in ${HOMES[@]+"${HOMES[@]}"}; do check_home "$h"; done
[ "$HOST" = 0 ] || check_host

total=$(printf '%s' "$FOUND" | grep -c . || true)
summary=""
for kind in $KINDS; do
  n=$(printf '%s' "$FOUND" | grep -cx "$kind" || true)
  [ "$n" -eq 0 ] || summary="$summary${summary:+, }$kind $n"
done
printf 'in use: %s%s\n' "$total" "${summary:+ ($summary)}"
[ "$UNREAD" = 0 ] || exit 2
[ "$total" -eq 0 ] || exit 1
exit 0
