#!/usr/bin/env bash
# The status classifier, proved end to end through the library the watcher, the daemon and the
# drain source: bin/jg-classify-lib.sh forwards each call to the Go command, built on first use.
# The expected answers are the shell reader's, pinned by the parity replay over recorded status
# lines (core/classify/README.md); this suite keeps the shapes that replay found interesting.
# Usage: tests/jg-classify-go.test.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-classify-go.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
export JG_STATE_OVERRIDE=$lab/state TMPDIR=$lab
unset JG_CAPTAIN_RE JG_CLASSIFY_PAUSED_VERB JG_CLASSIFY_RESOLVE_VERB JG_CLASSIFY_CAPTAIN_HELD_VERB
if ! command -v "${JG_CLASSIFY_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the classifier\n'
  exit 0
fi
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok: %s\n' "$1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
# shellcheck source=bin/jg-classify-lib.sh
. "$ROOT/bin/jg-classify-lib.sh"
yn() { "$@" && printf yes || printf no; }

check "a done line is captain-relevant and terminal" "$(yn status_is_captain_relevant 'done [at=1]: PR https://x/pull/1')|$(yn status_is_terminal_verb 'done [at=1]: x')" "yes|yes"
check "working prose naming a merge is not captain-relevant" "$(yn status_is_captain_relevant 'working: rebased onto merged #76')" no
check "a bare legacy PR ready line is relevant but not terminal" "$(yn status_is_captain_relevant 'PR ready https://x/pull/2')|$(yn status_is_terminal_verb 'PR ready https://x/pull/2')" "yes|no"
check "an unknown prefix surfaces as itself" "$(yn status_is_captain_relevant 'parked: waiting on review')" yes
check "a correlation token does not hide the verb" "$(yn status_is_captain_relevant 'needs-decision corr=0123456789abcdef [key=k]: pick')|$(yn status_is_paused 'paused corr=0123456789abcdef [key=k]: wait')" "yes|yes"
check "a clock time is prose, not a prefix" "$(yn status_is_captain_relevant 'stopped at 10:30 for lunch')" no
check "paused and captain-held share one wait test" "$(yn status_is_paused_or_captain_held 'paused: x')$(yn status_is_paused_or_captain_held 'captain-held: x')$(yn status_is_paused_or_captain_held 'working: x')" "yesyesno"
check "paused-until reads the named UTC time" "$(status_paused_until 'paused [at=1]: wait until 2026-11-02T10:00Z')" 1793613600
check "paused-until refuses a malformed time" "$(yn status_paused_until 'paused: wait until 2026-13-45T99:00Z')" no
check "jg_utc_iso_to_epoch takes seconds and refuses a non-date" "$(jg_utc_iso_to_epoch 2026-11-02T10:00:30Z)|$(yn jg_utc_iso_to_epoch 2026-02-30T10:00Z)" "1793613630|no"

s=$lab/task.status
printf 'working: start\nMore detail: prose\n\nparked: holding\nignored prose\n' > "$s"
check "the latest event is the unknown-prefix declaration" "$(last_status_line "$s")" "parked: holding"
prev=''
last_status_line "$s" prev > /dev/null
check "the event before it is the working line" "$prev" "working: start"
check "an absent file reads as nothing" "$(last_status_line "$lab/none.status")" ""
printf 'paused [key=rel]: wait until 2026-11-02T10:00Z\nresolved [key=other]: done\n' > "$s"
check "a resolved line for another key does not end a pause" "$(status_declared_wait_line "$s")" "paused [key=rel]: wait until 2026-11-02T10:00Z"
printf 'paused [key=rel]: wait\nresolved [key=rel]: answered\n' > "$s"
check "a resolved line for the pause's own key ends it" "$(status_declared_wait_line "$s")" ""
printf 'paused: wait\ndone: finished\n' > "$s"
check "a later event ends a pause" "$(status_declared_wait_line "$s")" ""

# The dispatcher never turns a classifier that cannot run into a yes or no answer.
JG_CLASSIFY_BIN=$lab/none/jg-classify JG_CLASSIFY_GO=$lab/no-such-go "$ROOT/bin/jg-classify.sh" is-paused 'paused: x' 2>/dev/null
check "no binary and no toolchain exits 2, not a verdict" "$?" 2
check "an unknown command exits 2" "$("$ROOT/bin/jg-classify.sh" nonsense >/dev/null 2>&1; echo $?)" 2
check "a custom captain expression replaces the default set" "$(JG_CAPTAIN_RE='deploy' yn status_is_captain_relevant 'deploy finished')|$(JG_CAPTAIN_RE='deploy' yn status_is_captain_relevant 'merged x')" "yes|no"

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-classify-go tests passed\n'
