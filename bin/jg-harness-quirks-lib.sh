#!/usr/bin/env bash
# jg-harness-quirks-lib.sh - the ONE reader of the per-harness quirk tables.
#
# What a runtime does on a trust prompt, on composer submission, on interrupt, on resume,
# and in what its pane shows is DATA, not a `case "$harness"` arm in each core:
# bin/harness-quirks/<harness>.json holds it, one file per runtime, in the same when /
# use / why shape as config/crew-dispatch.json, with a home override at
# config/harness-quirks/. Every `use` value is a string.
# A runtime with NO table is unknown: each lookup warns on stderr and returns nonzero,
# so the caller keeps its own documented refusal; a key absent from an existing table is a
# recorded "this runtime has none". The tables sit under bin/ beside this reader, so a
# fixture that copies or symlinks bin/ carries them.
_jg_hq_self=${BASH_SOURCE[0]}
while [ -L "$_jg_hq_self" ]; do
  _jg_hq_link=$(readlink "$_jg_hq_self")
  case "$_jg_hq_link" in /*) _jg_hq_self=$_jg_hq_link ;; *) _jg_hq_self=$(dirname "$_jg_hq_self")/$_jg_hq_link ;; esac
done
_jg_hq_dir=$(cd "$(dirname "$_jg_hq_self")" && pwd)
unset _jg_hq_self _jg_hq_link

# The table a recorded harness value resolves to, or nonzero. pi-signed is Pi under
# a signed launcher, so one table covers both; every other runtime records a command
# basename, and the separator keeps a short name (omp) from claiming a longer one.
jg_hq_name() {  # <recorded-harness>
  local h=${1-} n
  case "$h" in pi|pi-signed) printf 'pi'; return 0 ;; esac
  for n in claude codex opencode grok kimi cursor gemini muse rovo omp agy devin; do
    case "$h" in "$n"|"$n"-*|"$n".*) printf '%s' "$n"; return 0 ;; esac
  done
  return 1
}

# One value from <recorded-harness>'s table, or nothing. Read with grep/sed
# rather than jq: the busy fold runs on a deliberately narrow PATH that carries
# no jq, so a table read must never depend on one being installed.
jg_hq_value() {  # <recorded-harness> <key>
  local name file line
  if ! name=$(jg_hq_name "${1-}"); then
    printf "HARNESS_QUIRKS: no quirk table for harness '%s'; no verified %s, so the caller keeps its own refusal\n" \
      "${1-}" "${2-}" >&2
    return 1
  fi
  if [ -n "${JG_HOME:-}" ] && [ -f "$JG_HOME/config/harness-quirks/$name.json" ]; then
    file=$JG_HOME/config/harness-quirks/$name.json
  else
    file=$_jg_hq_dir/harness-quirks/$name.json
    [ -f "$file" ] || file=
  fi
  [ -n "$file" ] || return 1
  line=$(grep -o "\"$2\": \"[^\"]*\"" "$file" 2>/dev/null | head -n 1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*: \"}" | sed 's/"$//'
}
