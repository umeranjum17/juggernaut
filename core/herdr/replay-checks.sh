#!/usr/bin/env bash
# replay-checks.sh - the program-level half of the herdr parity replay (core/herdr/replay.sh).
#
# The adapter's `jq -e` programs moved to the Go command's `check`. Each program is kept here
# word for word as the base adapter ran it, and every one is run beside its Go check over every
# recorded and synthetic answer and a set of argument tuples chosen to make the check true on some
# answer and false on the rest. The two must agree on stdout (byte for byte) and on the jq -e
# exit status (jq's parse-error status 2 is the Go command's 5).
#
# Usage: replay-checks.sh <recorded-dir> <synthetic-dir> [--control]
#   exit 0  every program agreed on every call
#   exit 1  some program differed (printed)
#   --control runs the Go side with the wrong verdict on purpose; it must exit 1.
set -u
REC=${1:?usage: replay-checks.sh <recorded-dir> <synthetic-dir> [--control]}
SYN=${2:?usage: replay-checks.sh <recorded-dir> <synthetic-dir> [--control]}
CONTROL=${3:-}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

# One function per check: the jq program of the base adapter, called with the check's arguments.
o_is_array() { jq -e "($1 | type) == \"array\""; }
o_session_socket() { jq -er --arg want "$1" '
    [.sessions[]?
      | select(.name == $want and .running == true)
      | select((.socket_path | type) == "string")
      | select((.socket_path | length) > 0)
      | .socket_path]
    | if length == 1 then .[0] else empty end
  '; }
o_focus_tab_is() { jq -e --arg tab "$1" '
    (.result.tabs | type) == "array"
    and ([.result.tabs[] | select(.focused == true)] | length) == 1
    and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)
  '; }
o_tab_binds() { jq -e --arg tab "$1" --arg workspace "$2" '
    .result.tab.tab_id == $tab and .result.tab.workspace_id == $workspace
  '; }
o_tab_binds_reversed() { jq -e --arg workspace "$2" --arg tab "$1" '
    .result.tab.workspace_id == $workspace and .result.tab.tab_id == $tab
  '; }
o_pane_binds() { jq -e --arg pane "$1" --arg tab "$2" --arg workspace "$3" '
    .result.pane.pane_id == $pane
    and .result.pane.tab_id == $tab
    and .result.pane.workspace_id == $workspace
  '; }
o_workspace_unique() { jq -e --arg workspace "$1" '
    (.result.workspaces | type) == "array"
    and ([.result.workspaces[] | select(.workspace_id == $workspace)] | length) == 1
  '; }
o_move_schema() { jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "workspace.move")
    and .schemas.request["$defs"].WorkspaceMoveParams.required == ["workspace_id", "insert_index"]
    and .schemas.request["$defs"].WorkspaceMoveParams.properties.insert_index.type == "integer"
  '; }
o_sole_tab() { jq -e --arg tab "$1" '
    (.result.tabs | type) == "array" and (.result.tabs | length) == 1
    and .result.tabs[0].tab_id == $tab
  '; }
o_sole_pane() { jq -e --arg pane "$1" '
    (.result.panes | type) == "array" and (.result.panes | length) == 1
    and .result.panes[0].pane_id == $pane
  '; }
o_sole_tab_labelled() { jq -e --arg tab "$1" --arg task_label "$2" '
    (.result.tabs | type) == "array"
    and (.result.tabs | length) == 1
    and .result.tabs[0].tab_id == $tab
    and .result.tabs[0].label == $task_label
  '; }
o_sole_pane_in_tab() { jq -e --arg pane "$1" --arg tab "$2" '
    (.result.panes | type) == "array"
    and (.result.panes | length) == 1
    and .result.panes[0].pane_id == $pane
    and .result.panes[0].tab_id == $tab
  '; }
o_shape_tabs() { jq -e --arg task "$1" --arg seeded "$2" \
  '.result.tabs[0].tab_id == $task and ([.result.tabs[] | select(.tab_id == $seeded)] | length) == 0'; }
o_shape_panes() { jq -e --arg pane "$1" --arg tab "$2" \
  '.result.panes[0].pane_id == $pane and .result.panes[0].tab_id == $tab'; }
o_move_verify() { jq -e --arg ws "$1" --arg focused "$2" --argjson before "$3" '
        ($before | map(select(. != $ws)) + [$ws]) as $expected
        | .result.type == "workspace_list"
        and ([.result.workspaces[].workspace_id] == $expected)
        and ([.result.workspaces[] | select(.focused == true) | .workspace_id] == [$focused])
      '; }
o_restore_verify() { jq -e --argjson expected "$1" --arg focused "$2" '
      .result.type == "workspace_list"
      and ([.result.workspaces[].workspace_id] == $expected)
      and ([.result.workspaces[] | select(.focused == true) | .workspace_id] == [$focused])
    '; }
o_order_verify() { jq -e --arg created "$1" --arg parent "$2" --arg parent_ws "$3" --argjson desired "$4" '
    def is_parent:
      if ($parent_ws | length) > 0
      then .workspace_id == $parent_ws
      else (.label | type) == "string" and .label == $parent
      end;
    .result.type == "workspace_list"
    and (.result.workspaces | type) == "array"
    and .result.workspaces[$desired].workspace_id == $created
    and ([.result.workspaces[] | select(is_parent)] | length) == 1
    and (
      [range(0; .result.workspaces | length) as $i
        | select(.result.workspaces[$i] | is_parent)
        | $i][0] < $desired
    )
  '; }
o_process_info_pane() { jq -e --arg pane "$1" '
    .result.type == "pane_process_info"
    and .result.process_info.pane_id == $pane
  '; }
o_process_field() {
  case "$1" in
    shell-pid) jq -er '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' ;;
    foreground-pgid) jq -er '.result.process_info.foreground_process_group_id | select(type == "number" and . > 1) | floor' ;;
    count) jq -er '.result.process_info.foreground_processes | select(type == "array") | length' ;;
    first-pid) jq -er '.result.process_info.foreground_processes[0].pid | select(type == "number") | floor' ;;
    first-name) jq -er '.result.process_info.foreground_processes[0].name | select(type == "string" and length > 0)' ;;
    first-argv0) jq -er '
    .result.process_info.foreground_processes[0] as $process
    | ($process.argv0 // $process.argv[0])
    | select(type == "string" and length > 0)
  ' ;;
  esac
}
o_parent_workspace() { jq -er --arg parent_label "$1" --arg old "$2" '
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array")
    | [$spaces[]? | select(.label == $parent_label or (($old | length) > 0 and .label == $old))]
    | if length == 1
        and (.[0].workspace_id | type) == "string"
        and (.[0].workspace_id | length) > 0
      then .[0].workspace_id
      else empty
      end
  '; }
o_live_binding() { jq -e \
    --arg token "$1" \
    --arg workspace "$2" \
    --arg parent_workspace "$3" \
    --arg parent_label "$4" \
    --arg parent_old "$5" \
    --arg workspace_label "$6" '
      def is_new_child:
        (.label | type) == "string"
        and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
      def is_legacy_child_for($owner):
        (.label | type) == "string"
        and (.label | test("^(juggernaut|(lead|2ndmate)-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"))
        and (.label | startswith($owner + "/"));
      (.result.workspaces // null) as $spaces
      | select(($spaces | type) == "array")
      | select(([$spaces[]? | select(.workspace_id == $workspace)] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $workspace and .label == $workspace_label)] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)))] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)) and .workspace_id == $workspace)] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $parent_workspace and (.label == $parent_label or (($parent_old | length) > 0 and .label == $parent_old)))] | length) == 1)
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $parent_workspace)]) as $parents
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $workspace)]) as $children
      | select(($parents | length) == 1 and ($children | length) == 1)
      | ($parents[0]) as $parent_index
      | ($children[0]) as $child_index
      | select($child_index > $parent_index)
      | reduce range($parent_index + 1; $child_index) as $i
          (true; . and (($spaces[$i] | is_new_child) or ($spaces[$i] | (is_legacy_child_for($parent_label) or (($parent_old | length) > 0 and is_legacy_child_for($parent_old))))))
      | select(. == true)
    '; }
o_pane_info_matches() { jq -e --arg pane "$1" --arg workspace "$2" \
    --arg tab "$3" --arg cwd "$4" '
      .result.type == "pane_info" and .result.pane.pane_id == $pane
      and .result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab
      and .result.pane.foreground_cwd == $cwd and .result.pane.agent_status == "unknown"
    '; }
o_agent_info_matches() { jq -e --arg pane "$1" --arg workspace "$2" \
    --arg tab "$3" --arg cwd "$4" '
      .result.type == "agent_info" and .result.agent.pane_id == $pane
      and .result.agent.workspace_id == $workspace and .result.agent.tab_id == $tab
      and .result.agent.foreground_cwd == $cwd and .result.agent.agent_status == "unknown"
    '; }

work=$(mktemp -d "${TMPDIR:-/tmp}/herdr-checks.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export JG_STATE_OVERRIDE=$work/state JG_HERDR_BIN=$work/state/bin/jg-herdr
"$ROOT/bin/jg-herdr.sh" check is-array .a </dev/null >/dev/null 2>&1
[ -x "$JG_HERDR_BIN" ] || { echo "replay-checks: cannot build the Go command" >&2; exit 2; }
GO=$JG_HERDR_BIN
if [ "$CONTROL" = --control ]; then
  mv "$GO" "$work/real"
  # A Go side that answers wrongly on purpose: every verdict flips.
  # shellcheck disable=SC2016 # the wrapper body is written literally, not expanded here
  printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\n[ "$rc" = 0 ] && exit 1\n[ "$rc" = 1 ] && exit 0\nexit "$rc"\n' "$work/real" > "$GO"
  chmod +x "$GO"
fi

# The argument tuples of each check. A tuple is one line, fields separated by the unit separator
# so a field may hold anything; an empty field is written as an empty string.
US=$'\x1f'
declare -A TUPLES
TUPLES[is-array]=$(printf '%s\n' ".result.tabs" ".result.panes" ".result.workspaces" ".result" ".sessions" ".a.b")
TUPLES[session-socket]=$(printf '%s\n' lab-a lab-b lab-c default missing '')
TUPLES[focus-tab-is]=$(printf '%s\n' w1:t1 w1:t2 w2:t1 '')
TUPLES[tab-binds]=$(printf "%s${US}%s\n" w1:t1 w1  w1:t2 w1  w1:t1 w2  w2:t1 w2  '' '')
TUPLES[pane-binds]=$(printf "%s${US}%s${US}%s\n" w1:p1 w1:t1 w1  w1:p2 w1:t2 w1  w1:p9 w1:t1 w1  w1:p2 w1:t1 w1)
TUPLES[workspace-unique]=$(printf '%s\n' w1 w2 w9 '')
TUPLES[move-schema]=$(printf '\n')
TUPLES[sole-tab]=$(printf '%s\n' w1:t1 w1:t2 w9:t9 '')
TUPLES[sole-pane]=$(printf '%s\n' w1:p1 w1:p2 w1:p9 '')
TUPLES[sole-tab-labelled]=$(printf "%s${US}%s\n" w1:t1 jg-a  w1:t1 other  w1:t2 jg-b  w1:t1 '')
TUPLES[sole-pane-in-tab]=$(printf "%s${US}%s\n" w1:p1 w1:t1  w1:p2 w1:t1  w1:p1 w1:t2  w1:p9 w1:t1)
TUPLES[shape-tabs]=$(printf "%s${US}%s\n" w1:t1 w1:t2  w1:t1 w1:t1  w1:t2 w1:t1  w1:t1 '')
TUPLES[shape-panes]=$(printf "%s${US}%s\n" w1:p1 w1:t1  w1:p2 w1:t1  w1:p3 w1:t2  w1:p1 w1:t2)
TUPLES[move-verify]=$(printf "%s${US}%s${US}%s\n" \
  w2 w1 '["w1","w2","w3"]'  w1 w3 '["w1","w2","w3"]'  w3 w1 '["w1","w2","w3"]'  w2 w1 '["w1","w3"]' \
  w2 w1 '{"a":"w1","b":"w2"}'  w2 w1 'null'  w2 w1 '"str"'  w2 w1 'not json'  w2 w1 ''  w1 w1 '[1,"w1",null]')
TUPLES[restore-verify]=$(printf "%s${US}%s\n" '["w1","w2","w3"]' w1  '["w1","w3","w2"]' w3  '["w1","w2"]' w2  '[]' w1 \
  '{"a":1}' w1  'null' w1  'bad' w1  '' w1  '["w1","w3","w2"]' w2)
TUPLES[order-verify]=$(printf "%s${US}%s${US}%s${US}%s\n" \
  w3 juggernaut w1 2  w2 juggernaut w1 1  w3 juggernaut '' 2  w3 juggernaut w1 0  w2 juggernaut '' 1  w3 other w1 2 \
  w3 juggernaut w1 -1  w3 juggernaut w1 2.5  w3 juggernaut w1 '"2"'  w3 juggernaut w1 null  w3 juggernaut w1 true \
  w3 juggernaut w1 '[2]'  w3 juggernaut w1 bad  w3 juggernaut w1 ''  w3 juggernaut w1 99  w3 juggernaut w1 1e30)
TUPLES[process-info-pane]=$(printf '%s\n' w1:p1 w1:p2 w9:p9 '')
TUPLES[process-field]=$(printf '%s\n' shell-pid foreground-pgid count first-pid first-name first-argv0)
TUPLES[parent-workspace]=$(printf "%s${US}%s\n" juggernaut ''  juggernaut 2ndmate-alpha  lead-alpha 2ndmate-alpha  2ndmate-alpha lead-alpha  '' ''  nothing '')
TUPLES[live-binding]=$(printf "%s${US}%s${US}%s${US}%s${US}%s${US}%s\n" \
  AAAAAAAAAAAAAAAAAAAAAA w3 w1 juggernaut '' '└ task-a · p:AAAAAAAAAAAAAAAAAAAAAA' \
  AAAAAAAAAAAAAAAAAAAAAA w4 w1 juggernaut '' '└ task-b · p:AAAAAAAAAAAAAAAAAAAAAA' \
  BBBBBBBBBBBBBBBBBBBBBB w4 w1 juggernaut '' 'juggernaut/task-b · p:BBBBBBBBBBBBBBBBBBBBBB' \
  BBBBBBBBBBBBBBBBBBBBBB w4 w5 lead-alpha 2ndmate-alpha '2ndmate-alpha/task-b · p:BBBBBBBBBBBBBBBBBBBBBB' \
  BBBBBBBBBBBBBBBBBBBBBB w4 w5 lead-alpha 2ndmate-alpha 'lead-alpha/task-b · p:BBBBBBBBBBBBBBBBBBBBBB' \
  CCCCCCCCCCCCCCCCCCCCCC w6 w1 juggernaut '' '└ task-c · p:CCCCCCCCCCCCCCCCCCCCCC' \
  AAAAAAAAAAAAAAAAAAAAAA w3 w1 juggernaut '' 'wrong label' \
  AAAAAAAAAAAAAAAAAAAAAA w9 w1 juggernaut '' 'x' \
  '' w3 w1 juggernaut '' '' \
  AAAAAAAAAAAAAAAAAAAAAA w3 w9 juggernaut '' '└ task-a · p:AAAAAAAAAAAAAAAAAAAAAA')
TUPLES[pane-info-matches]=$(printf "%s${US}%s${US}%s${US}%s\n" w1:p1 w1 w1:t1 /wt  w1:p1 w1 w1:t1 '/x y'  w1:p2 w1 w1:t1 /wt  w1:p1 w2 w1:t1 /wt  '' '' '' '')
TUPLES[agent-info-matches]=${TUPLES[pane-info-matches]}

# The oracle name and the Go check name differ only in that a check also has variants run on
# the same program.
declare -A ORACLE=(
  [is-array]=o_is_array [session-socket]=o_session_socket [focus-tab-is]=o_focus_tab_is
  [tab-binds]=o_tab_binds [pane-binds]=o_pane_binds [workspace-unique]=o_workspace_unique
  [move-schema]=o_move_schema [sole-tab]=o_sole_tab [sole-pane]=o_sole_pane
  [sole-tab-labelled]=o_sole_tab_labelled [sole-pane-in-tab]=o_sole_pane_in_tab
  [shape-tabs]=o_shape_tabs [shape-panes]=o_shape_panes [move-verify]=o_move_verify
  [restore-verify]=o_restore_verify [order-verify]=o_order_verify
  [process-info-pane]=o_process_info_pane [process-field]=o_process_field
  [parent-workspace]=o_parent_workspace [live-binding]=o_live_binding
  [pane-info-matches]=o_pane_info_matches [agent-info-matches]=o_agent_info_matches
)

mapfile -t answers < <(ls "$REC"/*.json "$SYN"/*.json)
calls=0 diffs=0 trues=0
declare -A TRUE_BY
: > "$work/diffs.txt"
for name in "${!ORACLE[@]}"; do
  oracle=${ORACLE[$name]}
  while IFS= read -r tuple; do
    if [ "$name" = move-schema ]; then
      args=()
    else
      IFS=$US read -r -a args <<< "$tuple$US"
    fi
    for a in "${answers[@]}"; do
      old_out=$($oracle "${args[@]}" < "$a" 2>/dev/null; printf 'x%d' "$?")
      old_rc=${old_out##*x}
      old_out=${old_out%x*}
      [ "$old_rc" != 2 ] || old_rc=5
      [ "$old_rc" != 3 ] || old_rc=5
      new_out=$("$GO" check "$name" "${args[@]}" < "$a" 2>/dev/null; printf 'x%d' "$?")
      new_rc=${new_out##*x}
      new_out=${new_out%x*}
      calls=$((calls + 1))
      [ "$old_rc" != 0 ] || { trues=$((trues + 1)); TRUE_BY[$name]=$((${TRUE_BY[$name]:-0} + 1)); }
      if [ "$old_rc" != "$new_rc" ] || [ "$old_out" != "$new_out" ]; then
        diffs=$((diffs + 1))
        printf 'DIFF %s [%s] %s\n  jq: rc=%s %q\n  go: rc=%s %q\n' "$name" "${args[*]}" "${a##*/}" "$old_rc" "$old_out" "$new_rc" "$new_out" >> "$work/diffs.txt"
      fi
    done
  done <<< "${TUPLES[$name]}"
done
if [ -s "$work/diffs.txt" ]; then
  # The first three differences of each check, then the count per check.
  awk '/^DIFF /{ n[$2]++ } /^DIFF /{ show = n[$2] <= 3 } show' "$work/diffs.txt"
  grep '^DIFF ' "$work/diffs.txt" | awk '{ n[$2]++ } END { for (k in n) printf "  %s: %d differences\n", k, n[k] }'
  [ -z "${REPLAY_KEEP:-}" ] || cp "$work/diffs.txt" "$REPLAY_KEEP/replay-checks-diffs.txt"
fi
# A check that never reads true on any answer proves only its false side.
for name in "${!ORACLE[@]}"; do
  [ -n "${TRUE_BY[$name]:-}" ] || { printf 'replay-checks: %s never reads true on any answer\n' "$name"; diffs=$((diffs + 1)); }
done
printf 'replay-checks: %s calls (%s true verdicts), %s differences\n' "$calls" "$trues" "$diffs"
[ "$diffs" -eq 0 ]
