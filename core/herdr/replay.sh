#!/usr/bin/env bash
# replay.sh - the parity replay for the herdr adapter port: the shell adapter at the base commit
# against the adapter that forwards to the Go command, over recorded herdr answers.
#
# Both adapters are sourced in their own shell and every function the port touched is called
# with the same arguments over the same answers, where the answer comes from a stand-in for the
# `herdr` client that replays a recorded file. The two result lists must be identical, byte for
# byte: stdout (trailing newlines kept) and exit status of every call.
#
# The recorded answers are real: record them from a lab session (bin/jg-herdr-lab.sh run <lab>
# ...) as <recorded-dir>/{status,workspace-list,tab-list,pane-list,pane-get-p2,pane-get-missing,
# agent-get-live,agent-get-none,terminal-title-clear,session-list}.json and so on - every *.json
# there is replayed through every slot a function reads. A set of malformed and unusual answers
# is added to each slot so a failure shape no lab produced is still compared.
#
# Usage: core/herdr/replay.sh <old-herdr.sh> <recorded-dir> [--control]
#   exit 0  the two adapters agreed on every call
#   exit 1  they differed (the differences are printed)
#   --control corrupts the Go side on purpose (it must exit 1: a replay that cannot fail proves
#             nothing)
set -u

OLD=${1:?usage: replay.sh <old-herdr.sh> <recorded-dir> [--control]}
REC=${2:?usage: replay.sh <old-herdr.sh> <recorded-dir> [--control]}
CONTROL=${3:-}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/herdr-replay.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

# The old adapter sources its libraries relative to its own location, so give it a root whose
# bin/ holds the current libraries beside the base adapter.
mkdir -p "$work/old/bin/backends"
for f in "$ROOT"/bin/*; do
  case "${f##*/}" in backends) ;; *) ln -s "$f" "$work/old/bin/${f##*/}" ;; esac
done
cp "$OLD" "$work/old/bin/backends/herdr.sh"

# Synthetic answers: every shape a broken or future herdr could send that the readers meet.
syn=$work/synthetic
mkdir -p "$syn"
i=0
while IFS= read -r line; do
  i=$((i + 1))
  printf '%s' "$line" > "$syn/s$(printf '%02d' "$i").json"
done <<'EOF'
{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"workspace_id":"w2","label":"juggernaut"},{"workspace_id":"w3","label":"lead-alpha"},{"workspace_id":"w4","label":"2ndmate-alpha"}]}}
{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"label":"juggernaut"},{"workspace_id":null,"label":"lead-alpha"}]}}
{"result":{"workspaces":[]}}
{"result":{"workspaces":"none"}}
{"result":{"workspaces":[7,{"workspace_id":"w1","label":"juggernaut"}]}}
{"result":{"tabs":[{"tab_id":"w1:t1","label":"jg-a","workspace_id":"w1"},{"tab_id":"w1:t2","label":"jg-b","workspace_id":"w1"},{"tab_id":"w2:t1","label":"plain","workspace_id":"w2"}]}}
{"result":{"tabs":[{"tab_id":"w1:t1","label":5}]}}
{"result":{"tabs":[{"tab_id":7,"label":"jg-num"},{"label":"jg-notab"}]}}
{"result":{"tabs":null}}
{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t1"},{"pane_id":"w1:p3","tab_id":"w1:t2"}]}}
{"result":{"panes":[{"tab_id":"w1:t2"}]}}
{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","foreground_cwd":"/x y"}}}
{"result":{"pane":{"pane_id":"w1:p9"}}}
{"error":{"code":"pane_not_found","message":"pane gone"}}
{"error":{"code":"something_else","message":"a long message that goes past the one hundred and twenty character cut so the cut is compared too, not only short messages"}}
{"error":"flat string"}
{"error":{"code":null}}
{"result":{"agent":{"agent":"codex","agent_status":"unknown","agent_session":{"kind":"path","value":"/abs/session.jsonl"}}}}
{"result":{"agent":{"agent":"pi","agent_status":"working","agent_session":{"kind":"id","value":"abc123"}}}}
{"result":{"agent":{"agent":"pi","agent_status":"done","agent_session":{"kind":"id","value":"a/b"}}}}
{"result":{"agent":{"agent":"","agent_status":"stale","agent_session":{"kind":"path","value":"rel/path"}}}}
{"result":{"agent":{"agent":"claude","agent_status":"blocked"}}}
{"result":{"agent":{"agent":"claude\tx","agent_status":"idle\\y"}}}
{"result":{"agent":{"agent":false,"agent_status":null}}}
{"result":{"agent":{"agent":{"a":1},"agent_status":"idle"}}}
{"result":{"agent":{"agent":["x"],"agent_status":3}}}
{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}{"result":{"agent":{"agent":"codex","agent_status":"working"}}}
{"server":{"running":true,"protocol":22,"version":"0.9.1","compatible":true},"client":{"protocol":22,"version":"0.9.1"}}
{"server":{"running":true,"protocol":19,"version":"0.8.0","compatible":false},"client":{"protocol":22,"version":"0.9.1"}}
{"server":{"running":true,"protocol":16,"version":"0.7.3"},"client":{"protocol":22,"version":"0.9.1"}}
{"server":{"running":true,"protocol":22},"client":{"protocol":22}}
{"server":{"running":false,"protocol":null,"version":null,"compatible":null},"client":{"protocol":18,"version":"0.8.0-preview.2"}}
{"server":{"running":"yes"},"client":{"protocol":"19","version":"0.8.0"}}
{"server":{"running":null},"client":{}}
{"server":"down","client":{"protocol":22,"version":"0.9.1"}}
{"server":{"running":true,"protocol":22},"client":"old"}
{"client":{"protocol":14,"version":"0.7.1"}}
{"client":{"protocol":22,"version":"0.9.1"},"server":{"running":false}}
{"sessions":[{"name":"default","running":true,"socket_path":"/s/default.sock"},{"name":"lab-a","running":false,"socket_path":"/s/lab-a.sock"},{"name":"lab-b","running":true,"socket_path":null},{"name":"lab-c","running":true}]}
{"sessions":[{"name":"lab-a","running":"true","socket_path":"/s/a"}]}
{"sessions":{"a":{"name":"x","running":true}}}
{"result":{"changed":false,"reason":"no_foreground_client"}}
{"result":{"changed":true,"reason":"cleared"}}
{"result":{"reason":"other"}}
{"result":{"reason":5}}
[]
null
{}
{"result":null}
{"result":"text"}
not json at all
{"unterminated":
EOF
printf '' > "$syn/empty.json"
printf '\n' > "$syn/newline.json"
printf 'error: herdr: protocol_mismatch\n' > "$syn/stderr.json"

# The stand-in client: replays a recorded file for the subcommand it is asked, to the caller.
cat > "$work/driver.sh" <<'DRV'
#!/usr/bin/env bash
# driver.sh <adapter.sh> <results-file>: call every touched function over every answer.
set -u
adapter=$1 results=$2
export JG_BACKEND_HERDR_READ_TIMEOUT=5
# shellcheck disable=SC1090
. "$adapter"

fake=$(mktemp -d "${TMPDIR:-/tmp}/herdr-fake.XXXXXX")
trap 'rm -rf -- "$fake"' EXIT
cat > "$fake/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "session list") [ -z "${R_SESSIONS:-}" ] || cat "$R_SESSIONS" ;;
  *) [ -z "${R_STATUS:-}" ] || cat "$R_STATUS" ;;
esac
exit "${R_RC:-0}"
SH
chmod +x "$fake/herdr"
PATH="$fake:$PATH"

# Replays the file named by the slot the subcommand reads.
jg_backend_herdr_cli() {
  local f=
  shift
  case "$1 $2" in
    "workspace list") f=${R_WSLIST:-} ;;
    "tab list") f=${R_TABLIST:-} ;;
    "pane list") f=${R_PANELIST:-} ;;
    "pane get") f=${R_PANEGET:-} ;;
    "agent get") f=${R_AGENTGET:-} ;;
    "terminal title") f=${R_TITLE:-} ;;
    "status --json") f=${R_STATUS:-} ;;
  esac
  [ -z "$f" ] || cat "$f"
  return "${R_RC:-0}"
}

# release_supported_probe: the verdict and the release name the caller's warning would carry.
release_supported_probe() {
  local r
  jg_backend_herdr_presentation_release_supported s
  r=$?
  printf '%s|' "$JG_BACKEND_HERDR_PRESENTATION_RELEASE"
  return "$r"
}
# preference_probe: the answer with its warning, which goes to stderr.
preference_probe() { jg_backend_herdr_presentation_preference "$1" 2>&1; }

: > "$results"
n=0
# call <label> <function> [args...]: run the function, record its stdout exactly and its status.
call() {
  local label=$1 out rc
  shift
  n=$((n + 1))
  out=$("$@" 2>/dev/null; printf 'x%d' "$?")
  rc=${out##*x}
  out=${out%x*}
  printf '%s %s rc=%s %q\n' "$n" "$label" "$rc" "$out" >> "$results"
}

homes=$(mktemp -d "${TMPDIR:-/tmp}/herdr-home.XXXXXX")
trap 'rm -rf -- "$fake" "$homes"' EXIT
mkdir -p "$homes/lead" "$homes/primary"
printf 'alpha\n' > "$homes/lead/.jg-squad-lead-home"

mapfile -t answers < <(ls "$REC"/*.json "$SYN"/*.json)
for a in "${answers[@]}"; do
  tag=${a##*/}
  for rc in 0 1; do
    export R_RC=$rc
    export R_WSLIST=$a R_TABLIST=$a R_PANELIST=$a R_PANEGET=$a R_AGENTGET=$a R_TITLE=$a R_STATUS=$a R_SESSIONS=$a
    for ws in w1 w2 w9 ''; do call "ws-presence $tag $ws" jg_backend_herdr_workspace_presence_state s "$ws"; done
    for p in w1:p2 w1:p9 w9:p9 ''; do call "pane-presence $tag $p" jg_backend_herdr_pane_presence_state s "$p"; done
    for t in w1:t1 w1:t2 w1:t3 ''; do call "pane-for-tab $tag $t" jg_backend_herdr_pane_for_tab s w1 "$t"; done
    for h in lead primary; do
      JG_HOME=$homes/$h call "ws-find-all $tag $h" jg_backend_herdr_workspace_find_all s
      JG_HOME=$homes/$h call "ws-find $tag $h" jg_backend_herdr_workspace_find s
      JG_HOME=$homes/$h call "list-live $tag $h" jg_backend_herdr_list_live s
    done
    call "agent-status-raw $tag" jg_backend_herdr_agent_status_raw s w1:p2
    call "agent-identity-raw $tag" jg_backend_herdr_agent_identity_raw s w1:p2
    call "agent-session-ref $tag" jg_backend_herdr_pane_agent_session_ref s w1:p2
    call "server-running $tag" jg_backend_herdr_server_running_state s
    call "client-status $tag" jg_backend_herdr_client_status "$fake/herdr" s
    call "release-supported $tag" release_supported_probe
    call "foreground-client $tag" jg_backend_herdr_foreground_client_present s
    call "socket-path $tag" jg_backend_herdr_socket_path lab-a
    call "bare-selector $tag" jg_backend_herdr_resolve_bare_selector jg-a
    call "version-check $tag" jg_backend_herdr_version_check
  done
done
# The recovery scan reads three different answers in one call: the workspace list, the tab list
# and the pane list. Replay it with the lab's own three, and with the lab's workspace list
# against each synthetic tab and pane list.
export R_RC=0
for tabs in "$REC/tab-list-w1.json" "$REC/tab-list.json" "$SYN"/*.json; do
  for panes in "$REC/pane-list-w1.json" "$REC/pane-list.json" "$SYN"/*.json; do
    export R_WSLIST=$REC/workspace-list.json R_TABLIST=$tabs R_PANELIST=$panes
    for h in lead primary; do
      JG_HOME=$homes/$h call "list-live-triple ${tabs##*/} ${panes##*/} $h" jg_backend_herdr_list_live s
    done
  done
done
unset R_WSLIST R_TABLIST R_PANELIST R_PANEGET R_AGENTGET R_TITLE R_STATUS R_SESSIONS R_RC

# Pure decisions.
versions=(0.8.0 0.8.0-preview.2 0.7.5-preview 0.7.5+build 0.9.1 1 1.0 10.0.0 0.10.0 0.8 0.8.0.1 08.0 '' . .. 0..1 a.b 0.8.x 0.8.0\  -1 0.8.0-)
floors=(0.8.0 0.8 0.7.5 1 '' 0..1 x 18446744073709551616 007)
for v in "${versions[@]}"; do
  for f in "${floors[@]}"; do
    call "version-at-least [$v] [$f]" jg_backend_herdr_version_at_least "$v" "$f"
  done
done
protocols=(19 18 16 22 '' x 019 -1 0 99999999999999999999 '19 ')
for p in "${protocols[@]}"; do
  for v in "${versions[@]}"; do
    call "floor-verdict [$p] [$v]" jg_backend_herdr_release_floor_verdict "$p" "$v"
  done
done

cfg=$WORKDIR/cfg
rm -rf -- "$cfg"
mkdir -p "$cfg"
call "preference no dir" jg_backend_herdr_presentation_preference ''
call "preference no file" jg_backend_herdr_presentation_preference "$cfg"
values=('off' 'OFF' ' Off ' 'on' 'ON' '' $'\n' $'o\nff' 'maybe' 'Of F' $'on\r\n' 'enabled' $'\toff')
for v in "${values[@]}"; do
  printf '%s' "$v" > "$cfg/$JG_BACKEND_HERDR_PRESENTATION_CONFIG"
  call "preference [$v]" preference_probe "$cfg"
done
mkdir -p "$cfg/dir"
rm -f "$cfg/$JG_BACKEND_HERDR_PRESENTATION_CONFIG"
mkdir "$cfg/$JG_BACKEND_HERDR_PRESENTATION_CONFIG"
call "preference directory" jg_backend_herdr_presentation_preference "$cfg"

# Agent names over the home's recorded task ids plus the shapes the rules turn on.
ids=(a task-1 Task_Upper 1-starts-with-digit _under -dash UPPER-and-lower-case-words a.b/c:d 'has space' 'tab	in' $'new\nline' $'trail\n' ü-umlaut 日本語 \
  abcdefghijklmnopqrstuvwxyz012345 abcdefghijklmnopqrstuvwxyz0123456 abcdefghijklmnopqrstuvwxyz-_-_-_-_-_-extra \
  port-shell-core-part5-herdr-backend-and-then-a-much-longer-tail-to-make-it-past-the-limit 1111111111111111111111111111111111111111 \
  'x-' 'x_' 'abcdefghijklmnopqrstuvwxyz_' '___' '---' '*' '$HOME' '`id`' "q'uote" '"dq"')
for id in $(ls "${REPLAY_STATE:-/nonexistent}" 2>/dev/null | sed -n 's/\.status$//p'); do ids+=("$id"); done
for id in "${ids[@]}" ''; do
  call "agent-name-for [$id]" jg_backend_herdr_agent_name_for "$id"
done
salts=(s:w1:p2 default:w1:p1 '' x $'multi\nline' 'üñí' w1:p2 'a long salt value for the checksum over many bytes in a row, past 255 bytes ...........................................................................................................................................................................................................................................................................................................')
for name in "${ids[@]}" ''; do
  for salt in "${salts[@]}"; do
    call "agent-name-variant [$name] [$salt]" jg_backend_herdr_agent_name_variant "$name" "$salt"
  done
done

# Submit budgets.
for b in 0 1 2 3 5 10 30 0.5 0.6 1.25 1e1 1E-1 .5 5. -1 -0 +3 abc '' ' 4' 4x 1.23456789 0x10 99999999999 inf nan 1,5; do
  for m in 0.6 0 1 -2 x 2.5 '' 10; do
    JG_BACKEND_HERDR_SUBMIT_MIN_SLEEP=$m call "submit-budget [$b] [$m]" jg_backend_herdr_submit_confirm_budget "$b"
  done
done
DRV
chmod +x "$work/driver.sh"

side_new=$work/new.txt side_old=$work/old.txt
export REC SYN=$syn WORKDIR=$work
export JG_HERDR_BIN="$work/state/bin/jg-herdr" JG_STATE_OVERRIDE=$work/state
if [ "$CONTROL" = --control ]; then
  # A Go side that answers wrongly on purpose: it swaps verdicts and a name prefix.
  mkdir -p "$work/ctl"
  "$ROOT/bin/jg-herdr.sh" version-at-least 1 1 >/dev/null || { echo "replay: cannot build the Go command" >&2; exit 2; }
  mv "$JG_HERDR_BIN" "$work/ctl/real"
  # shellcheck disable=SC2016 # the wrapper body is written literally, not expanded here
  printf '#!/usr/bin/env bash\n"%s" "$@" | sed -e "s/present/dead/" -e "s/^busy/idle/" -e "s/running/stopped/" -e "s/^0$/1/" -e "s/^task-/tusk-/"\nexit "${PIPESTATUS[0]}"\n' "$work/ctl/real" > "$JG_HERDR_BIN"
  chmod +x "$JG_HERDR_BIN"
  touch -t 209901010000 "$JG_HERDR_BIN"
fi

JG_ROOT_OVERRIDE=$work/old bash "$work/driver.sh" "$work/old/bin/backends/herdr.sh" "$side_old" || { echo "replay: base adapter run failed" >&2; exit 2; }
bash "$work/driver.sh" "$ROOT/bin/backends/herdr.sh" "$side_new" || { echo "replay: ported adapter run failed" >&2; exit 2; }

total=$(wc -l < "$side_old" | tr -d ' ')
# The answers themselves, for a reader who wants to see what was compared (REPLAY_KEEP=<dir>).
[ -z "${REPLAY_KEEP:-}" ] || cp "$side_old" "$REPLAY_KEEP/replay-answers.txt"
if diff -u "$side_old" "$side_new" > "$work/diff.txt"; then
  printf 'replay: %s calls (%s with output), 0 differences\n' "$total" "$(grep -vc " rc=[0-9]* ''$" "$side_old")"
  exit 0
fi
diffs=$(grep -c '^-[0-9]' "$work/diff.txt")
cat "$work/diff.txt"
printf 'replay: %s calls, %s differences\n' "$total" "$diffs"
exit 1
