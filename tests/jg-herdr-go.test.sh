#!/usr/bin/env bash
# The herdr adapter's decisions, proved end to end through the adapter the
# fleet sources: bin/backends/herdr.sh forwards each call to core/herdr's Go command, built on
# first use. The expected answers are the shell adapter's, pinned by the parity replay over
# recorded herdr answers (core/herdr/README.md); this suite keeps the shapes that replay found
# interesting.
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

# The dispatcher never turns a core that cannot run into an answer.
out=$(JG_HERDR_BIN=$lab/none/jg-herdr JG_HERDR_GO=$lab/no-such-go "$ROOT/bin/jg-herdr.sh" version-at-least 1 1 </dev/null 2>/dev/null; echo "rc=$?")
check "no binary and no toolchain exits 2 with nothing on stdout" "$out" "rc=2"
check "an unknown command exits 2" "$("$ROOT/bin/jg-herdr.sh" nonsense >/dev/null 2>&1; echo $?)" 2

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-herdr-go tests passed\n'
