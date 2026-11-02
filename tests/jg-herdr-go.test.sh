#!/usr/bin/env bash
# The herdr adapter's decisions and answer readers, proved end to end through the adapter the
# fleet sources: bin/backends/herdr.sh forwards each call to core/herdr's Go command, built on
# first use. The expected answers are the shell adapter's, pinned by the parity replay over
# recorded herdr answers (core/herdr/README.md); this suite keeps the shapes that replay found
# interesting, with canned answers standing in for the `herdr` client.
# Usage: tests/jg-herdr-go.test.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-herdr-go.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
export JG_STATE_OVERRIDE=$lab/state TMPDIR=$lab
if ! command -v "${JG_HERDR_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the herdr core\n'
  exit 0
fi
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok: %s\n' "$1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
rc() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# Release floors: a prerelease compares as its release, and either signal can carry the verdict.
check "0.8.0-preview is at the 0.8.0 floor" "$(rc jg_backend_herdr_version_at_least 0.8.0-preview.2 0.8.0)" 0
check "0.7.5-preview is below it" "$(rc jg_backend_herdr_version_at_least 0.7.5-preview 0.8.0)" 1
check "an unparseable version is indeterminate, not below" "$(rc jg_backend_herdr_version_at_least latest 0.8.0)" 2
check "protocol 19 carries the floor with no version" "$(rc jg_backend_herdr_release_floor_verdict 19 '')" 0
check "a readable low protocol is below the floor" "$(rc jg_backend_herdr_release_floor_verdict 17 '')" 1
check "losing both signals is indeterminate" "$(rc jg_backend_herdr_release_floor_verdict '' '')" 2
check "a version at the floor carries it with no protocol" "$(rc jg_backend_herdr_release_floor_verdict '' 0.9.1)" 0

# The opt-out file: off, on (empty is the historical opt-in), and a typo that warns and defaults.
cfg=$lab/cfg
mkdir -p "$cfg"
check "no file means the default" "$(jg_backend_herdr_presentation_preference "$cfg")" default
printf ' OFF\n' > "$cfg/$JG_BACKEND_HERDR_PRESENTATION_CONFIG"
check "off, in any case and spacing" "$(jg_backend_herdr_presentation_preference "$cfg")" off
: > "$cfg/$JG_BACKEND_HERDR_PRESENTATION_CONFIG"
check "an empty file is an explicit on" "$(jg_backend_herdr_presentation_preference "$cfg")" on
printf 'maybe\n' > "$cfg/$JG_BACKEND_HERDR_PRESENTATION_CONFIG"
check "a typo falls back to the default and says so" "$(jg_backend_herdr_presentation_preference "$cfg" 2>&1 | grep -c 'unrecognized value "maybe".*fall back')|$(jg_backend_herdr_presentation_preference "$cfg" 2>/dev/null)" "1|default"

# Agent names: a valid short id is itself; a long one keeps 27 characters and a POSIX checksum.
check "a valid id is the name" "$(jg_backend_herdr_agent_name_for task-1)" task-1
check "an id that starts with a digit gains a prefix" "$(jg_backend_herdr_agent_name_for 7-fix)" t-7-fix
check "upper case and odd characters map into the rules" "$(jg_backend_herdr_agent_name_for 'Fix/It:Now')" fix-it-now
long=port-shell-core-part5-herdr-backend-and-a-longer-tail-still
sum=$(printf '%s' "$long" | cksum | awk '{ printf "%04x", $1 % 65536 }')
check "a long id is cut to 27 and carries its cksum" "$(jg_backend_herdr_agent_name_for "$long")" "${long:0:27}-$sum"
check "an empty id has no name" "$(rc jg_backend_herdr_agent_name_for '')" 1

# Answers: canned herdr JSON through the readers the adapter used to feed to jq.
canned() { printf '%s' "$1"; }
jg_backend_herdr_cli() { canned "$R_ANSWER"; }
R_ANSWER='{"id":"x","result":{"pane":{"pane_id":"w1:p2"}}}'
check "a pane that names itself is present" "$(jg_backend_herdr_pane_presence_state s w1:p2)" present
check "a pane that names another is unknown" "$(jg_backend_herdr_pane_presence_state s w1:p3)" unknown
R_ANSWER='{"error":{"code":"pane_not_found","message":"gone"}}'
check "pane_not_found is dead" "$(jg_backend_herdr_pane_presence_state s w1:p2)" dead
R_ANSWER='{"error":{"code":"server_not_running"}}'
check "any other error is unknown, never dead" "$(jg_backend_herdr_pane_presence_state s w1:p2)" unknown
R_ANSWER='{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"workspace_id":"w2","label":"juggernaut"}]}}'
check "a workspace listed once is present, twice-labelled ones are both found" "$(jg_backend_herdr_workspace_presence_state s w1)|$(JG_HOME=$lab jg_backend_herdr_workspace_find_all s | tr '\n' ,)" "present|w1,w2,"
check "an absent workspace is dead" "$(jg_backend_herdr_workspace_presence_state s w9)" dead
R_ANSWER='not json'
check "an unreadable list is unknown, never dead" "$(jg_backend_herdr_workspace_presence_state s w1)" unknown
R_ANSWER='{"result":{"agent":{"agent":"claude","agent_status":"working"}}}'
check "agent identity is agent and status, tab separated" "$(jg_backend_herdr_agent_identity_raw s w1:p2)" "$(printf 'claude\tworking')"
R_ANSWER='{"result":{"agent":{"agent":"pi","agent_session":{"kind":"path","value":"rel/path"}}}}'
check "a relative session path is not a resumable reference" "$(rc jg_backend_herdr_pane_agent_session_ref s w1:p2)" 1
R_ANSWER='{"server":{"running":false}}'
check "a stopped server reads stopped" "$(jg_backend_herdr_server_running_state s)" stopped
R_ANSWER='{"server":"down"}'
check "a malformed status reads unknown" "$(jg_backend_herdr_server_running_state s)" unknown

# The `jq -e` programs: a proved answer exits 0, and everything else - a false answer (1), no
# output (4), an unreadable answer or a bad argument (5) - exits non-zero, so a caller that asks
# `if ! ... check` refuses on anything it cannot prove.
verdict() { local want=$1 doc=$2; shift 2; printf '%s' "$doc" | "$ROOT/bin/jg-herdr.sh" check "$@" >/dev/null 2>&1; printf '%s' "$?"; }
tab='{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1"}}}'
check "a tab that names itself and its workspace is proved" "$(verdict '' "$tab" tab-binds w1:t1 w1)" 0
check "a tab in another workspace is false" "$(verdict '' "$tab" tab-binds w1:t1 w2)" 1
check "an empty answer proves nothing" "$(verdict '' '' tab-binds w1:t1 w1)" 4
check "an unreadable answer is an error, never a proof" "$(verdict '' 'not json' tab-binds w1:t1 w1)" 5
check "the last of several answers decides, as jq -e decides" "$(verdict '' "$tab"'{"result":{"tab":{}}}' tab-binds w1:t1 w1)" 1
check "a bad JSON argument is refused before any answer is read" "$(verdict '' '' order-verify w3 juggernaut w1 'not json')" 5
check "an unknown check exits 2" "$(verdict '' '' no-such-check)" 2
check "a check with the wrong argument count exits 2" "$(verdict '' '' tab-binds w1:t1)" 2
check "one focused tab, the named one, is proved" "$(verdict '' '{"result":{"tabs":[{"tab_id":"a","focused":true},{"tab_id":"b"}]}}' focus-tab-is a)" 0
check "two focused tabs prove nothing" "$(verdict '' '{"result":{"tabs":[{"tab_id":"a","focused":true},{"tab_id":"b","focused":true}]}}' focus-tab-is a)" 1
list='{"result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","focused":true},{"workspace_id":"w3"},{"workspace_id":"w2"}]}}'
check "a move to the end is proved against the order before and the focus" "$(verdict '' "$list" move-verify w2 w1 '["w1","w2","w3"]')" 0
check "a move that left the order alone is false" "$(verdict '' "$list" move-verify w3 w1 '["w1","w2","w3"]')" 1
check "a rollback is proved against the recorded order" "$(verdict '' "$list" restore-verify '["w1","w3","w2"]' w1)" 0
check "the child sits right after its parent: ordering is proved" "$(verdict '' '{"result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"workspace_id":"w3"},{"workspace_id":"w2"}]}}' order-verify w3 juggernaut '' 1)" 0
check "a process-info shell pid below 2 is no value" "$(verdict '' '{"result":{"process_info":{"shell_pid":1}}}' process-field shell-pid)" 4
check "a process-info pid is floored like jq prints it" "$(printf '{"result":{"process_info":{"shell_pid":4242.9}}}' | "$ROOT/bin/jg-herdr.sh" check process-field shell-pid)" 4242
check "the first process name is its string" "$(printf '{"result":{"process_info":{"foreground_processes":[{"name":"bash"}]}}}' | "$ROOT/bin/jg-herdr.sh" check process-field first-name)" bash
check "argv0 falls to the first argv entry" "$(printf '{"result":{"process_info":{"foreground_processes":[{"argv":["zsh","-l"]}]}}}' | "$ROOT/bin/jg-herdr.sh" check process-field first-argv0)" zsh

# Through the adapter: each reader sees the answer for the subcommand it asks.
jg_backend_herdr_cli() {
  shift
  case "$1 $2" in
    "status --json") canned "$R_STATUS" ;;
    "api schema") canned "$R_SCHEMA" ;;
    "session list") canned "$R_SESSIONS" ;;
    "workspace list") canned "$R_WS" ;;
    "tab list") canned "$R_TABS" ;;
    "pane list") canned "$R_PANES" ;;
    "pane process-info") canned "$R_PROC" ;;
  esac
}
R_STATUS='{"client":{"protocol":19}}'
# shellcheck disable=SC2016 # a JSON key named $defs, not an expansion
R_SCHEMA='{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}'
check "a server that offers workspace.move can reposition" "$(rc jg_backend_herdr_workspace_move_capable s)" 0
R_SCHEMA='{"schemas":{"request":{"oneOf":[]}}}'
check "a schema without workspace.move cannot (status 5)" "$(rc jg_backend_herdr_workspace_move_capable s)" 5
R_STATUS='{"client":{"protocol":14}}'
check "a protocol below the move floor cannot (status 3)" "$(rc jg_backend_herdr_workspace_move_capable s)" 3
R_SESSIONS='{"sessions":[{"name":"lab-a","running":true,"socket_path":"/s/a.sock"},{"name":"lab-b","running":true,"socket_path":"/s/b1.sock"},{"name":"lab-b","running":true,"socket_path":"/s/b2.sock"}]}'
check "a session socket needs exactly one running session of the name" "$(rc jg_backend_herdr_presentation_session_socket_path lab-a)|$(rc jg_backend_herdr_presentation_session_socket_path lab-b)|$(rc jg_backend_herdr_presentation_session_socket_path lab-z)" "0|1|1"
R_WS='{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut","focused":true,"active_tab_id":"w1:t1"}]}}'
R_TABS='{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}'
check "the focus snapshot is the focused workspace and its focused tab" "$(jg_backend_herdr_projection_focus_snapshot s | tr '\t' ,)" "w1,w1:t1"
R_TABS='{"result":{"tabs":[{"tab_id":"w1:t9","focused":true}]}}'
check "a focused tab that is not the workspace's active tab gives no snapshot" "$(rc jg_backend_herdr_projection_focus_snapshot s)" 1
R_WS='{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"workspace_id":"w2","label":"lead-alpha"}]}}'
check "a parent workspace is found by its label, once (no match keeps jq -e's status 4)" "$(jg_backend_herdr_projection_parent_workspace_exact s lead-alpha)|$(rc jg_backend_herdr_projection_parent_workspace_exact s nothing)" "w2|4"
R_WS='{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"workspace_id":"w3","label":"└ task · p:AAAAAAAAAAAAAAAAAAAAAA"}]}}'
R_TABS='{"result":{"tabs":[{"tab_id":"w3:t1","label":"jg-a"}]}}'
R_PANES='{"result":{"panes":[{"pane_id":"w3:p1","tab_id":"w3:t1"}]}}'
check "a projected workspace that sits right after its parent is bound" "$(rc jg_backend_herdr_projection_live_binding_matches s AAAAAAAAAAAAAAAAAAAAAA w3 w3:t1 w3:p1 w1 juggernaut '└ task · p:AAAAAAAAAAAAAAAAAAAAAA' jg-a)" 0
check "another token binds nothing" "$(rc jg_backend_herdr_projection_live_binding_matches s BBBBBBBBBBBBBBBBBBBBBB w3 w3:t1 w3:p1 w1 juggernaut '└ task · p:BBBBBBBBBBBBBBBBBBBBBB' jg-a)" 1

# The pane process proofs, with a stand-in process table holding one idle shell.
fakebin=$lab/fakebin
mkdir -p "$fakebin"
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-o stat="*) printf 'Ss\n' ;;
  *"pid=,ppid=,comm="*) printf '4242 1 bash\n' ;;
  *"pid=,ppid="*) printf '4242 1\n' ;;
esac
SH
chmod +x "$fakebin/ps"
export JG_HERDR_PS_BIN=$fakebin/ps
R_PROC='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"/bin/bash","argv0":"-bash"}]}}}'
check "a lone idle shell is proved" "$(jg_backend_herdr_pane_idle_shell_sample s w1:p1)" 4242
check "the pane process state of a lone shell is shell" "$(jg_backend_herdr_pane_process_state_sample s w1:p1)" shell
R_PROC='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv0":"bash"},{"pid":7,"name":"vim","argv0":"vim"}]}}}'
check "two foreground processes are not an idle shell" "$(rc jg_backend_herdr_pane_idle_shell_sample s w1:p1)" 1
R_PROC='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242}}}'
check "an answer for another pane is unreadable, not a shell" "$(jg_backend_herdr_pane_process_state_sample s w1:p1)" unreadable

# The dispatcher never turns a core that cannot run into an answer.
out=$(JG_HERDR_BIN=$lab/none/jg-herdr JG_HERDR_GO=$lab/no-such-go "$ROOT/bin/jg-herdr.sh" field .a </dev/null 2>/dev/null; echo "rc=$?")
check "no binary and no toolchain exits 2 with nothing on stdout" "$out" "rc=2"
check "an unknown command exits 2" "$("$ROOT/bin/jg-herdr.sh" nonsense >/dev/null 2>&1; echo $?)" 2
check "a jq-style failure exits 5 after the lines it printed" "$(printf '{"a":"x"}{"a":1}\n"s"' | "$ROOT/bin/jg-herdr.sh" field .a 2>/dev/null | tr '\n' ,; echo "${PIPESTATUS[1]}")" "x,1,5"

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-herdr-go tests passed\n'
