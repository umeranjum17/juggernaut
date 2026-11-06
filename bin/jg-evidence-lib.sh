#!/usr/bin/env bash
# jg-evidence-lib.sh - the one owner of the optional `evidence=` status-line token.
#
# A lead's review-ready or landed line for UI work may end with
#   evidence=<path>,<path>
# naming the screenshots, recordings or proof files of that work. The token is
# plain note text after the first colon, so the status grammar (jg-classify-lib.sh)
# and every older line are untouched. `bin/jg-inbox.sh reply --evidence-from`
# reads the token and attaches the paths through its ordinary --attach path;
# `bin/jg-evidence-check.sh` flags a reply about a UI landing that attached nothing.
# This file decides only which paths qualify, never how evidence is captured.
#
# A path qualifies when it is absolute, a readable regular file, and free of
# whitespace, commas and control characters (the token separator and line framing).
#
# Task source: data/<id>/evidence.list, one path per line, relative to data/<id>
# (no `..`) or absolute inside it. A UI task is one whose record (state/<id>.meta)
# says `ui_change=yes` or a `screen=` value other than `none`.
#
# Sourced by the publishers and the check. No side effects on source.

JG_EVIDENCE_MAX=8

_jg_evidence_path_ok() {  # <path>
  local p=$1
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p" in *[[:space:],]*|*[[:cntrl:]]*) return 1 ;; esac
  [ -f "$p" ] && [ -r "$p" ]
}

# Print " evidence=<p>,<p>" (leading space) for the qualifying paths among the
# arguments, or nothing when none qualifies.
jg_evidence_token() {  # <path>...
  local p out='' n=0
  for p in "$@"; do
    _jg_evidence_path_ok "$p" || continue
    out="${out:+$out,}$p"
    n=$((n + 1))
    [ "$n" -lt "$JG_EVIDENCE_MAX" ] || break
  done
  [ -z "$out" ] || printf ' evidence=%s' "$out"
}

# Print the paths of a status line's evidence token, one per line.
jg_evidence_paths_of_line() {  # <line>
  local word
  for word in ${1-}; do
    case "$word" in
      evidence=?*) printf '%s\n' "${word#evidence=}" | tr ',' '\n'; return 0 ;;
    esac
  done
  return 0
}

jg_evidence_ui_task() {  # <meta-file>
  local meta=$1 v
  [ -f "$meta" ] || return 1
  [ "$(sed -n 's/^ui_change=//p' "$meta" | tail -1)" = yes ] && return 0
  v=$(sed -n 's/^screen=//p' "$meta" | tail -1)
  [ -n "$v" ] && [ "$v" != none ]
}

# Print the task's evidence files, absolute, one per line.
jg_evidence_task_paths() {  # <data-dir> <id>
  local dir=$1/$2 list line p
  list=$dir/evidence.list
  [ -f "$list" ] && [ ! -L "$list" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      */../*|../*|*/..) continue ;;
      /*) p=$line ;;
      *) p=$dir/$line ;;
    esac
    case "$p" in "$dir"/*) printf '%s\n' "$p" ;; esac
  done <"$list"
}

# The token for a UI task's line, or nothing for a non-UI task or no evidence.
jg_evidence_line_suffix() {  # <state> <data> <id>
  local -a paths=()
  local p
  jg_evidence_ui_task "$1/$3.meta" || return 0
  while IFS= read -r p; do paths+=("$p"); done < <(jg_evidence_task_paths "$2" "$3")
  [ "${#paths[@]}" -eq 0 ] || jg_evidence_token "${paths[@]}"
}
