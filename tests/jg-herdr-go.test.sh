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

# The dispatcher never turns a core that cannot run into an answer.
out=$(JG_HERDR_BIN=$lab/none/jg-herdr JG_HERDR_GO=$lab/no-such-go "$ROOT/bin/jg-herdr.sh" field .a </dev/null 2>/dev/null; echo "rc=$?")
check "no binary and no toolchain exits 2 with nothing on stdout" "$out" "rc=2"
check "an unknown command exits 2" "$("$ROOT/bin/jg-herdr.sh" nonsense >/dev/null 2>&1; echo $?)" 2
check "a jq-style failure exits 5 after the lines it printed" "$(printf '{"a":"x"}{"a":1}\n"s"' | "$ROOT/bin/jg-herdr.sh" field .a 2>/dev/null | tr '\n' ,; echo "${PIPESTATUS[1]}")" "x,1,5"

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-herdr-go tests passed\n'
