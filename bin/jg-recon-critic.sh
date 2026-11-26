#!/usr/bin/env bash
# jg-recon-critic.sh - start the separate critic of a deep Recon: its ticket, its brief and its one start, never twice for the same round.
#
# Usage: jg-recon-critic.sh start <recon-task> <generation>
#        jg-recon-critic.sh profile <recon-task> [<harness> <model> [<effort>]]
#
# The critic is a Recon lane of its own (.agents/skills/deep-recon/SKILL.md, "Deep: one researcher, one critic"), so it needs what any lane
# needs: a ticket (a child of the Recon's), a brief and a spawn. This command makes them, once for each <generation> (1 for the Recon's first
# critic, 2 when that critic's lane is gone and a second one takes over), and prints the critic's task id on one line. The project is the Recon's own
# (state/<recon-task>.meta). The caller names the critic to the handoff (bin/jg-recon-handoff.sh assign); this command does not, so a start and a
# naming never depend on each other's timing.
#
# The critic's model is a different family from the researcher's by default, so it does not share the researcher's blind spots: Antigravity's
# `agy` with `gemini-4-neon-high` (DEFAULT_PROFILE below, the one place that default lives). Three sources, the first that answers wins:
#   task     data/<recon-task>/critic-profile, one line `<harness> <model> [<effort>]`, which `profile <recon-task> <harness> <model> [<effort>]` writes
#   config   the rule tagged `recon-critic` in config/tool-models.json (bin/jg-tool-models.sh; docs/configuration.md "Tool models"), read at every call
#   default  DEFAULT_PROFILE
# `profile <recon-task>` prints `<source><TAB><harness> <model> [<effort>]` for the profile a start would use. A profile the spawn refuses (an
# agy that is not installed, a model the allow-list excludes) is a refused start, never a silent fall-back to another harness.
#
# The record of a generation is data/<recon-task>/critic-<generation>/: ticket, task (the critic's task id), started (epoch of the last start),
# attempts, spawn.rc (the exit code of the last start, written when it ends) and spawn.log. The start runs detached in its own session, because a spawn can wait minutes
# for a copy. Every call finds out where the start stands, prints the task id and exits:
#   0   the critic has its task record: it is live
#   75  its start is still running (up to JG_RECON_CRITIC_WAIT seconds, default 900), or was just made again after a failed one: call again later
#   1   a start failed or no ticket or brief could be made; stderr says why (the caller tells Main); failed starts are retried up to five times
# Exit 2 is a usage error. JG_RECON_CRITIC_SPAWN names the spawn command (tests point it at a wrapper that gives each lane its own copy).
# JG_HOME, JG_STATE_OVERRIDE and JG_DATA_OVERRIDE name the home.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-$ROOT}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
SPAWN=${JG_RECON_CRITIC_SPAWN:-$SCRIPT_DIR/jg-spawn.sh}
TRIES=5
WAIT=${JG_RECON_CRITIC_WAIT:-900}
DEFAULT_PROFILE='agy gemini-4-neon-high'
export JG_HOME
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-tool-models.sh disable=SC1091
. "$SCRIPT_DIR/jg-tool-models.sh"
# shellcheck source=bin/jg-version-branch-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-version-branch-lib.sh"

usage() { sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'jg-recon-critic: %s\n' "$*" >&2; exit 1; }
mval() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
one_line() { grep -v '^[[:space:]]*$' | tail -n 1 | tr '\t\r' '  ' | cut -c1-200; }

# critic_profile <recon> -> "<source><TAB><harness> <model> [<effort>]": the profile a start of this Recon's critic uses (see the header for the three sources).
critic_profile() {
  local line
  if [ -s "$DATA/$1/critic-profile" ]; then printf 'task\t%s\n' "$(head -n 1 "$DATA/$1/critic-profile")"; return 0; fi
  line=$(jg_tool_models_resolve recon-critic)
  if [ -n "$line" ]; then printf 'config\t%s\n' "$line"; else printf 'default\t%s\n' "$DEFAULT_PROFILE"; fi
}

cmd_profile() {  # <recon> [<harness> <model> [<effort>]]
  local recon=$1
  [ -d "$DATA/$recon" ] || refuse "no data directory for the Recon $recon"
  shift
  if [ "$#" -gt 0 ]; then
    { [ "$#" -ge 2 ] && [ "$#" -le 3 ]; } || usage
    printf '%s\n' "$*" > "$DATA/$recon/critic-profile"
  fi
  critic_profile "$recon"
}

# The ticket's title: a critic's own is "Critic <n> of <the first words of the Recon's title>", which the readable-title rule accepts.
critic_title() {  # <generation> <recon ticket title>
  local gen=$1 words=() n=4 title
  read -ra words <<< "$(printf '%s' "$2" | sed 's/^\[[^]]*\] *//; s/[^A-Za-z0-9 -]/ /g')"
  while [ "$n" -gt 0 ]; do
    title="Critic $gen of ${words[*]:0:$n}"
    [ "${#words[@]}" -gt 0 ] && jg_backlog_title_refusal "$title" >/dev/null && { printf '%s\n' "$title"; return 0; }
    n=$((n - 1))
  done
  printf 'Critic %s of a Recon\n' "$gen"
}

# The critic's brief: the scout scaffold at depth quick (the critic's product is critic.md, never a report), with its role and the loop's contract.
write_brief() {  # <task> <ticket row> <project> <recon> <recon ticket> <base>
  local task=$1 row=$2 project=$3 recon=$4 rticket=$5 base=$6 brief=$DATA/$1/brief.md task_text spec_text
  local brief_args=()
  [ -z "$base" ] || brief_args+=(--base-branch "$base")
  if [ -e "$brief" ]; then
    grep -qxF "Role: critic of $recon" "$brief" && ! grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief" || return 1
    if [ -n "$base" ] && ! grep -q '^Base branch: ' "$brief"; then printf '\nBase branch: %s\n' "$base" >> "$brief"; fi
    return 0
  fi
  mkdir -p "$DATA/$task"
  "$SCRIPT_DIR/jg-brief.sh" "$task" "$project" --scout --depth quick --ticket "$row" "${brief_args[@]}" >/dev/null 2>"$DATA/$task/.brief.err" \
    || { echo "the brief was not written: $(one_line < "$DATA/$task/.brief.err")"; rm -f "$brief"; return 1; }
  rm -f "$DATA/$task/.brief.err"
  task_text="Read the draft of the deep Recon $recon (ticket $rticket) as its separate critic and say which gaps it still has."
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  spec_text=$(printf 'Role: critic of %s\nThe draft is %s/%s/report.md; the Recon'"'"'s evidence files sit beside it. Read it with the critic rubric of %s/.agents/skills/deep-recon/SKILL.md.\nWrite no report.md and no backlog item.\nWrite each round in %s/%s/critic.md: the line `Critic: %s` once, then `Round <n>: new gaps <k> report <sha256 of report.md as you read it>` and one `- gap` line for each gap.\nRecord each round with `%s/bin/jg-recon-handoff.sh verdict %s --critic %s --hash <that sha256> --gaps <k>`, then append your done line.\nA new draft comes to you as a steer or a relaunch note: check each gap of your last round, look for new ones, and record the next round the same way. A round with 0 new gaps, every earlier gap closed, is the closure of the loop. A deep Recon allows 3 rounds that find new gaps.' \
    "$recon" "$DATA" "$recon" "$ROOT" "$DATA" "$task" "$task" "$ROOT" "$recon" "$task")
  TASK_FILL=$task_text SPEC_FILL=$spec_text awk '
    $0 == "{TASK}" { print ENVIRON["TASK_FILL"]; next }
    $0 == "{JUGGERNAUT_SPEC}" { print ENVIRON["SPEC_FILL"]; next }
    { print }' "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief" || { echo "the brief of $row could not be filled"; return 1; }
  ! grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief" || { echo "the brief of $row still holds a placeholder"; return 1; }
}

cmd_start() {
  local recon=$1 gen=$2 meta=$STATE/$1.meta run=$DATA/$1/critic-$2 project_dir project rticket profile harness model effort title body made row task rc tries why started base failure args
  [ -f "$meta" ] || refuse "no task record for the Recon $recon"
  case $gen in '' | *[!0-9]* | 0) usage ;; esac
  project_dir=$(mval "$meta" project); project=$(basename -- "$project_dir")
  [ -d "$project_dir" ] || refuse "the Recon's project $project_dir is not a directory"
  rticket=$(mval "$meta" ticket); rticket=${rticket:-$recon}
  base=$(mval "$meta" base_branch)
  [ -n "$base" ] || base=$(jg_current_version_branch "$project_dir") || base=
  profile=$(critic_profile "$recon" | cut -f2); read -r harness model effort <<< "$profile"
  mkdir -p "$run"
  if [ ! -s "$run/ticket" ]; then
    title=$("$SCRIPT_DIR/jg-backlog.sh" show "$rticket" 2>/dev/null | sed -n 's/^  title: *//p' | head -1 | sed 's/^"//; s/"$//')
    body=$(printf '## Captain\nThe deep Recon %s needs a separate critic.\n## Ask\nRead the draft of %s as its critic and record each round with its gaps.\n## Why\nA deep Recon is judged by a critic that is not its researcher (.agents/skills/deep-recon/SKILL.md).\n## Done when\nThe critic has recorded a round with no new gaps for the researcher'"'"'s last draft.\n## Acceptance Criteria\nThe critic'"'"'s rounds are in the Recon'"'"'s critic.md and the depth gate passes.' "$recon" "$recon")
    made=$("$SCRIPT_DIR/jg-backlog.sh" add --parent "$rticket" "$(critic_title "$gen" "$title")" --repo "$project" --priority 2 --body "$body" --json 2>&1) \
      || refuse "the critic's ticket was not filed: $(printf '%s\n' "$made" | one_line)"
    row=$(printf '%s' "$made" | jq -r '.task.id // .id // empty' 2>/dev/null)
    [ -n "$row" ] || refuse "the critic's ticket was filed but its id could not be read"
    printf '%s\n' "$row" > "$run/ticket"
  fi
  row=$(cat "$run/ticket")
  task=$(jg_backlog_task_id "$row" "$model")
  why=$(write_brief "$task" "$row" "$project" "$recon" "$rticket" "$base") || refuse "$task: $why"
  printf '%s\n' "$task" | tee "$run/task"
  # A record that only keeps a failed launch's copy is not a live one.
  if [ -f "$STATE/$task.meta" ] && ! grep -q '^cleanup_recovery=' "$STATE/$task.meta"; then return 0; fi
  started=$(cat "$run/started" 2>/dev/null); rc=$(cat "$run/spawn.rc" 2>/dev/null)
  tries=$(cat "$run/attempts" 2>/dev/null); tries=${tries:-0}
  # A start that ended with no exit code and is older than the wait is a start that died with its session: it counts as a failed try.
  if [ -n "$started" ] && [ -z "$rc" ]; then
    [ $(( $(date +%s) - started )) -ge "$WAIT" ] || return 75
    rc=lost
  fi
  failure=
  if [ -n "$rc" ]; then
    failure="$task did not start: $(one_line < "$run/spawn.log")"
    [ "$tries" -lt "$TRIES" ] || refuse "$failure"
  fi
  rm -f "$run/spawn.rc"
  date +%s > "$run/started"; printf '%s\n' "$((tries + 1))" > "$run/attempts"
  args=("$SPAWN" "$task" "$project_dir" --ticket "$row" --scout)
  [ -z "$base" ] || args+=(--base-branch "$base")
  [ -z "$harness" ] || args+=(--harness "$harness")
  [ -z "$model" ] || args+=(--model "$model")
  [ -z "$effort" ] || args+=(--effort "$effort")
  # shellcheck disable=SC2016  # the shell of the start expands its own arguments
  setsid nohup bash -c '"$@" > "$0.log" 2>&1 < /dev/null; echo $? > "$0.rc.tmp" && mv "$0.rc.tmp" "$0.rc"' "$run/spawn" "${args[@]}" > /dev/null 2>&1 < /dev/null &
  [ -z "$failure" ] || refuse "$failure"
  return 75
}

case ${1:-} in
  start) [ "$#" -eq 3 ] || usage ;;
  profile) [ "$#" -ge 2 ] || usage ;;
  *) usage ;;
esac
case $2 in '' | */* | .*) usage ;; esac
if [ "$1" = profile ]; then shift; cmd_profile "$@"; else cmd_start "$2" "$3"; fi
