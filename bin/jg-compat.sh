#!/usr/bin/env bash
# jg-compat.sh - the rename's single compatibility layer (slice S1).
#
# SHIM, deleted by slice S10 together with every caller's source line, every
# bin/fm-*.sh alias, and the legacy readers below. Nothing new may depend on it.
#
# It exists so one fleet can be half-migrated safely:
#   1. environment - an old FM_* name still resolves where the new JG_* name is
#      unset, so a shell profile, a systemd unit, a pane, or a generated
#      per-lane extension that still exports the old names keeps working.
#      Sourcing this file runs that pass; it is idempotent.
#   3. record readers - schema ids, endpoint labels, the operational input
#      marker and the second-mate home marker accept the old spelling while
#      homes are migrated. Each helper names the exact legacy value it accepts,
#      so an old spelling can never be inferred from a new one that merely
#      looks similar.
#
# Sourced by every bin/ script immediately after its shebang. It must stay
# bash 3.2 compatible (macOS stock bash runs it) and safe under set -eu.

# --- 1. environment aliases -------------------------------------------------
# The old prefix still wins only where the new name is unset, so a migrated
# home that exports JG_* is never overridden by a stale FM_* in the environment.
jg_compat_env_aliases() {
  local old new
  for old in $(compgen -v FM_ 2>/dev/null || true); do
    new="JG_${old#FM_}"
    declare -p "$new" >/dev/null 2>&1 && continue
    export "$new=${!old}"
  done
  return 0
}
jg_compat_env_aliases
unset -f jg_compat_env_aliases

# --- 2. record readers ------------------------------------------------------
# <actual> <current> [<legacy>...]: true when a live record carries the current
# spelling or one of the legacy spellings it replaced. Callers pass the legacy
# value explicitly, so migration is a list, never a guess.
jg_compat_record_ok() {
  local actual=${1-} current=${2-} legacy
  shift 2 || true
  [ "$actual" = "$current" ] && return 0
  for legacy in "$@"; do
    [ -n "$legacy" ] && [ "$actual" = "$legacy" ] && return 0
  done
  return 1
}

# Endpoint and workspace labels: fm-<task-id> was the pre-rename form of
# jg-<task-id>. Both are live at once while panes and journals outlive the
# update, so a matcher must accept either spelling of the same task.
jg_compat_label_ok() {  # <actual> <expected>
  local actual=${1-} expected=${2-}
  [ -n "$actual" ] && [ -n "$expected" ] || return 1
  [ "$actual" = "$expected" ] && return 0
  case "$expected" in
  jg-*) [ "$actual" = "fm-${expected#jg-}" ] && return 0 ;;
  esac
  case "$actual" in
  jg-*) [ "$expected" = "fm-${actual#jg-}" ] && return 0 ;;
  esac
  return 1
}

# The operational-input marker was "\u2063FIRSTMATE_OP: ". A supervisor and a
# worker can be on different sides of the update for a while, so both markers
# are recognised; the new spelling is written from now on.
jg_compat_marker_ok() {  # <marker-text>
  case "${1-}" in
  JUGGERNAUT_OP | FIRSTMATE_OP) return 0 ;;
  esac
  return 1
}

# The squad-lead home marker files and their schema line. A home that has not
# been migrated still carries the old names, so every reader and writer asks
# for the path rather than assuming the new spelling.
jg_compat_marker() {  # <home>
  local home=${1-} new old
  [ -n "$home" ] || return 0
  new="$home/.jg-squad-lead-home"
  old="$home/.fm-secondmate-home"
  if [ ! -e "$new" ] && [ -e "$old" ]; then printf '%s\n' "$old"; else printf '%s\n' "$new"; fi
}

jg_compat_parent_marker() {  # <home>
  local home=${1-} new old
  [ -n "$home" ] || return 0
  new="$home/.jg-squad-lead-parent"
  old="$home/.fm-secondmate-parent"
  if [ ! -e "$new" ] && [ -e "$old" ]; then printf '%s\n' "$old"; else printf '%s\n' "$new"; fi
}

# The pre-rename spelling of a current identifier, derived from it rather than
# listed: jg- becomes fm-, and a nested-supervisor word becomes its old word.
# Readers use it to accept a record written before the rename.
jg_compat_legacy_of() {  # <current spelling>
  local value=${1-}
  value=${value/#jg-/fm-}
  value=${value//squad-lead/secondmate}
  printf '%s\n' "$value"
}

# The same text with the product token in its pre-rename spelling. The
# operational-input marker is the one wire value a supervisor and a worker can
# be on opposite sides of mid-update, so its reader accepts both spellings.
jg_compat_legacy_product() {  # <text>
  local legacy=FIRSTMATE
  printf '%s\n' "${1//JUGGERNAUT/$legacy}"
}

# A record the pre-rename code wrote under its old file name. Prints <path>
# when it exists, else the same path with the old spelling when that exists,
# else <path> (so a new write lands under the new name). The old spelling is
# derived: jg- becomes fm-, squad-lead becomes its old word, squad_leads its
# old plural, and the product word its old token.
jg_compat_pick() {  # <path>
  local _jg_p=${1-} _jg_dir _jg_base _jg_old
  if [ -e "$_jg_p" ] || [ -L "$_jg_p" ]; then printf '%s\n' "$_jg_p"; return 0; fi
  _jg_dir=${_jg_p%/*}; _jg_base=${_jg_p##*/}
  [ "$_jg_dir" != "$_jg_p" ] || _jg_dir=.
  _jg_old=${_jg_base/#.jg-/.fm-}; _jg_old=${_jg_old/#jg-/fm-}
  _jg_old=${_jg_old//squad-lead/secondmate}; _jg_old=${_jg_old//squad_leads/secondmates}
  _jg_old=${_jg_old//juggernaut/firstmate}
  if [ "$_jg_old" != "$_jg_base" ] && { [ -e "$_jg_dir/$_jg_old" ] || [ -L "$_jg_dir/$_jg_old" ]; }; then
    printf '%s\n' "$_jg_dir/$_jg_old"
  else
    printf '%s\n' "$_jg_p"
  fi
}

# A task record written before the rename names a nested supervisor's kind
# with the old word. Prints the current kind for either spelling.
jg_compat_kind() {  # <kind value>
  case "${1-}" in
    secondmate) printf 'squad_lead\n' ;;
    *) printf '%s\n' "${1-}" ;;
  esac
}

# 0 when <meta-file> records a nested supervisor under either spelling.
jg_compat_meta_is_squad_lead() {  # <meta-file>
  grep -qE '^kind=(squad_lead|secondmate)$' "${1-}" 2>/dev/null
}

# The reverse of jg_compat_pick for the registry: a path naming the old
# registry file whose file has been renamed prints the new path.
jg_compat_pick_new() {  # <path>
  local _jg_p=${1-}
  case "$_jg_p" in
    *secondmates.md)
      if [ ! -e "$_jg_p" ] && [ -e "${_jg_p%secondmates.md}squad_leads.md" ]; then
        printf '%s\n' "${_jg_p%secondmates.md}squad_leads.md"; return 0
      fi ;;
  esac
  printf '%s\n' "$_jg_p"
}

# Copy every variable whose name starts with <JG_prefix> to its old FM_ name.
jg_compat_mirror_vars() {  # <JG_ prefix>
  local _jg_v
  for _jg_v in $(compgen -v "${1-}"); do
    printf -v "FM_${_jg_v#JG_}" '%s' "${!_jg_v-}"
  done
}

# Old function names for a library reached through its old path. A shim that
# still loads a library by its pre-rename path calls the old function names
# (fm_* for jg_*, the old nested-supervisor word for squad_lead_*), so a shim
# calls this once afterwards; a name already defined is left alone.
jg_compat_function_aliases() {
  local fn old
  for fn in $(compgen -A function); do
    case "$fn" in
      jg_compat_*) continue ;;
      jg_*) old=fm_${fn#jg_} ;;
      squad_lead_*) old=secondmate_${fn#squad_lead_} ;;
      *) continue ;;
    esac
    declare -F "$old" >/dev/null 2>&1 && continue
    case "$fn" in
      # The role resolver answers in variables; an old caller reads them under their old prefix.
      jg_role_*) eval "$old() { local _jg_rc=0; $fn \"\$@\" || _jg_rc=\$?; jg_compat_mirror_vars JG_ROLE; return \$_jg_rc; }" ;;
      # The backlog transition lib answers in variables too (the receipt writer reads FM_BACKLOG_META_SPAWN_GEN).
      jg_backlog_*) eval "$old() { local _jg_rc=0; $fn \"\$@\" || _jg_rc=\$?; jg_compat_mirror_vars JG_BACKLOG; return \$_jg_rc; }" ;;
      # The registry readers take the registry path first; an old caller may still name the old file.
      squad_lead_registry_*) eval "$old() { local _jg_p=\${1-}; [ \$# -eq 0 ] || shift; _jg_p=\$(jg_compat_pick_new \"\$_jg_p\"); $fn \"\$_jg_p\" \"\$@\"; }" ;;
      *) eval "$old() { $fn \"\$@\"; }" ;;
    esac
  done
}

# The XDG claims root for process-event sources: prefer the directory a home
# already uses, so a claim registered before the rename is still found and the
# same source is never armed twice under two roots.
jg_compat_claims_root() {  # <new-root>
  local new=${1-} old
  [ -n "$new" ] || return 0
  old=${new//\/juggernaut\//\/firstmate\/}
  if [ ! -d "$new" ] && [ -d "$old" ]; then printf '%s\n' "$old"; else printf '%s\n' "$new"; fi
}
