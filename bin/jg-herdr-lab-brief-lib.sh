#!/usr/bin/env bash
# The Herdr lab section of a worker brief, and the rules that decide a task needs it.
# Sourced by bin/jg-brief.sh (the section for a new brief, the need test for a
# ticket's text) and by bin/jg-control.sh (relaunch --herdr-lab, which swaps the
# section into a brief that was scaffolded without it). One owner for the text,
# so a brief made later and a brief repaired later carry the same contract.
#
#   jg_herdr_lab_need_term              the first word in stdin that names a pane,
#                                       the input box or Herdr itself; 1 when none
#   jg_herdr_lab_section <root> <id>    the section text for task <id>
#   jg_herdr_lab_swap_brief <file> <root> <id>
#                                       replace the "NOT ENABLED" gate in <file>
#                                       with the section; 0 also when the file
#                                       already has the section, 1 with a reason
#                                       on stderr when it has neither

_jg_herdr_lab_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# A task drives panes when its text names one of these. The words are the ones the
# ticket author uses for a pane, its input box, or Herdr; plain "window" and
# "session" are left out because they name far more than panes.
jg_herdr_lab_need_term() {
  local text
  text=$(cat)
  printf '%s' "$text" | grep -ioE "herdr|\bpanes?\b|input box|composer|\bkeys? into\b|send-keys|tmux (session|pane|window)" | head -n 1 | grep .
}

jg_herdr_lab_section() {  # <root> <id>
  local root=$1 id=$2 helper
  helper=$(_jg_herdr_lab_quote "$root/bin/jg-herdr-lab.sh")
  # shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand here; only the '"$VAR"' break-outs interpolate.
  printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus an explicit `--session <name>` Herdr option on every call is the only viable local isolation.' \
'' \
'For tmux-based lab primaries, `bin/jg-lab-home.sh` owns the short private socket directory; do not place `TMUX_TMPDIR` under the lab home or worktree.' \
'Use `LAB_HOME_HELPER='"$(_jg_herdr_lab_quote "$root/bin/jg-lab-home.sh")"'`, then `LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$JG_HOME")` and launch tmux with `TMUX_TMPDIR="$LAB_TMUX_DIR"`.' \
'Your single EXIT cleanup trap must kill only the server addressed through that `TMUX_TMPDIR`, call `"$LAB_HOME_HELPER" teardown "$JG_HOME"`, and call the Herdr teardown below; do not install a second trap that replaces either cleanup.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$helper"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$id"')`.' \
'   Install the combined EXIT cleanup before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper supplies the required `--session "$HERDR_LAB_SESSION"` as a Herdr option, before any `--` delimiter; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.'
}

jg_herdr_lab_swap_brief() {  # <file> <root> <id>
  local file=$1 gate='# Herdr lifecycle declaration - NOT ENABLED' section tmp
  [ -f "$file" ] || { echo "no brief at $file" >&2; return 1; }
  if grep -qxF '# Herdr isolation - HARD SAFETY CONTRACT' "$file"; then return 0; fi
  grep -qxF "$gate" "$file" || { echo "brief $file has neither the Herdr lab section nor the gate that stands in for it" >&2; return 1; }
  section=$(jg_herdr_lab_section "$2" "$3") || return 1
  tmp="$file.lab.$$"
  # The gate runs from its heading to the next top-level heading.
  awk -v gate="$gate" -v section="$section" '
    $0 == gate { print section; print ""; skip = 1; next }
    skip && /^# / { skip = 0 }
    !skip { print }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}
