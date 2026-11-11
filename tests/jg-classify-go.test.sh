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
export JG_STATE_OVERRIDE=$lab/state TMPDIR=$lab XDG_CACHE_HOME=$lab/cache
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

# Slice 2: the line grammar and the keyed-decision fold, through the same library.
check "the verb drops a correlation token and the note drops a note-head key" "$(status_line_verb 'needs-decision corr=0123456789abcdef [key=k]: pick')|$(status_line_note 'needs-decision: [key=k] pick one')" "needs-decision|pick one"
check "a stated key in either position names the decision; a bad slug is refused" "$(_jg_decision_key 'blocked [key=a.b]: x')|$(_jg_decision_key 'blocked: [key=c] x')|$(_jg_decision_key 'blocked: x')|$(yn _jg_decision_key 'blocked [key=a b]: x')" "a.b|c|default|no"
check "the stamp reader takes one canonical epoch and refuses a duplicate or a leading zero" "$(status_line_at_epoch 'done [at=1788576000]: x')|$(yn status_line_at_epoch 'done [at=01]: x')|$(yn status_line_at_epoch 'done [at=1] [at=2]: x')" "1788576000|no|no"
untimed_line=''
_jg_status_untimed 'done [at=1]: x' untimed_line
check "stamping keeps an existing tag and untimed removes a well-formed one" "$(status_stamp_line 'done [at=1]: x')|$untimed_line" "done [at=1]: x|done: x"
s=$lab/dec.status
printf 'needs-decision [key=a]: pick\nblocked [key=b]: stuck\nresolved [key=a]: ok\nneeds-decision [key=pending-reply-1]: unrelated\n' > "$s"
check "a resolved line closes only its key and a reserved key needs its own vocabulary" "$(status_open_decisions "$s" scout)" "b	blocked	stuck"
check "the current line is the most recently opened decision" "$(status_current_line "$s" ship)" "blocked [key=b]: stuck"
check "an open needs-decision is found by run id, a blocker is not" "$(yn status_has_open_needs_decision "$s")" no
printf 'needs-decision [key=nm-r1-review]: gate\nblocked [key=captain-hold-x]: relayed\n' > "$s"
check "a gate decision is found by its run id and a relayed hold is not the task's own" "$(yn status_has_open_needs_decision "$s" r1)|$(yn status_has_open_needs_decision "$s" r2)|$(status_own_open_decisions "$s" | cut -f1)" "yes|no|nm-r1-review"
printf 'needs-decision [key=k]: q\nresolved [key=k]: a\ncaptain-held [key=j]: h\n' > "$s"
check "the closing verb of a key is the line that closed it" "$(status_key_closing_verb "$s" k)|$(status_key_closing_verb "$s" j)|$(status_key_closing_verb "$s" none)" "resolved||"
printf 'needs-decision [key=k]: q\ndone: finished\n' > "$s"
check "a ship's done line closes every open decision" "$(status_open_decisions "$s" ship)|$(status_open_decisions "$s" squad_lead)" "|k	needs-decision	q"
printf 'needs-decision [key=a]: q\nblocked [key=b]: stuck\ndone [key=a]: answered\n' > "$s"
check "a done carrying a key closes that decision on a squad_lead lane and leaves the rest open" "$(status_open_decisions "$s" squad_lead)" "b	blocked	stuck"
printf 'needs-decision [key=a]: q\ndone [at=2]: the lead finished its own work\n' > "$s"
check "a keyless done on a squad_lead lane closes no child wait" "$(status_open_decisions "$s" squad_lead)" "a	needs-decision	q"

# A cold reader must classify all historical bytes in one call and keep every live event.
s=$lab/cold.status
awk 'BEGIN {print "blocked [key=old]: closed"; for(i=1;i<=20000;i++) print "working: history " i; print "resolved [key=old]: clear"; print "blocked [key=access]: waiting"; print "needs-decision [key=mode]: choose"}' > "$s"
printf 'kind=ship\n' > "$lab/cold.meta"
cp "$s" "$lab/cold.before"
span=''; needs=0
status_span_first_actionable_record "$s" 0 span needs
check "cold history retains every live opening in order" "${span#*$'\t'*$'\t'}" "blocked [key=access]: waiting ; needs-decision [key=mode]: choose"
check "cold history keeps the decision side band" "$needs" 1
check "cold history returns its complete byte endpoint" "${span%%$'\t'*}" "$(wc -c < "$s" | tr -d '[:space:]')"
check "classification preserves all history bytes" "$(cmp -s "$s" "$lab/cold.before" && echo yes)" yes
check "classification alone never creates a presentation cursor" "$(find "$lab" -name '*cursor*' -print)" ""

# The dispatcher never turns a classifier that cannot run into a yes or no answer.
JG_CLASSIFY_BIN=$lab/none/jg-classify JG_CLASSIFY_GO=$lab/no-such-go "$ROOT/bin/jg-classify.sh" is-paused 'paused: x' 2>/dev/null
check "no binary and no toolchain exits 2, not a verdict" "$?" 2
check "an unknown command exits 2" "$("$ROOT/bin/jg-classify.sh" nonsense >/dev/null 2>&1; echo $?)" 2
check "a custom captain expression replaces the default set" "$(JG_CAPTAIN_RE='deploy' yn status_is_captain_relevant 'deploy finished')|$(JG_CAPTAIN_RE='deploy' yn status_is_captain_relevant 'merged x')" "yes|no"

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-classify-go tests passed\n'
