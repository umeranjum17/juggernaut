#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/jg-watch.sh) and the away-mode daemon (bin/jg-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# JG_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
# Status-span classification captures one file endpoint and reports every
# actionable event through that endpoint before the endpoint may be committed.
# An absent status file is a successful empty span, while an existing status
# object that cannot be read or identified is a classification failure with no
# committable endpoint.
# A presentation marker independently stores the last reported file signature
# and the last successfully classified position.
# Successful classification advances both facts through the captured endpoint;
# after a failure is reported, only the reported signature advances, so the same
# observed state alarms once while every unclassified byte remains for recovery.
# The reported signature includes path type, mode, symlink target, and observable
# failure kind, so a readability change is a new state that triggers another read.
# A missing, malformed, identity-mismatched, or past-end classified position reads
# from byte 0, preferring a bounded duplicate over a lost event.
#
# There are four documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/jg-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time. status_home_appends_record writes the per-task home-owned
# append ledger (see "home-owned status-append ledger" below) so the wake scan
# can treat this home's own bookkeeping bytes as already owned.
# crew_worktree_written_since reads the task's meta file and walks a bounded slice
# of its worktree instead of a status file, so callers run it only at the moment
# they would otherwise escalate.

# Directory of this library, used to locate the sibling jg-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_JG_CLASSIFY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _JG_CLASSIFY_LIB_DIR="."

# The kernel name, read once at source time rather than forked by every status
# stat helper below. These helpers mostly run inside $() subshells, where a lazy
# cache would never persist. jg-wake-lib.sh's _JG_UNAME is reused when it is
# already loaded; either value is compared only against Darwin.
_JG_CLASSIFY_UNAME_S=${_JG_UNAME:-$(uname -s 2>/dev/null)}

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
JG_CREW_STATE_BIN="${JG_CREW_STATE_BIN:-$_JG_CLASSIFY_LIB_DIR/jg-crew-state.sh}"

# jg_run_timed, the shared hard bound the worktree write probe below puts around
# its one filesystem walk. bin/jg-timeout-lib.sh owns bounded execution for this
# repo, so nothing here re-derives the coreutils/BSD/perl selection. That library
# declares `set -u` for its own hygiene, which a sourced sibling must not impose on
# THIS library's consumers - several of them deliberately run without it - so the
# caller's setting is restored around the source.
case $- in *u*) _jg_classify_nounset=on ;; *) _jg_classify_nounset=off ;; esac
# shellcheck source=bin/jg-timeout-lib.sh
# shellcheck disable=SC1091
. "$_JG_CLASSIFY_LIB_DIR/jg-timeout-lib.sh"
[ "$_jg_classify_nounset" = on ] || set +u
unset _jg_classify_nounset

# Forward one status-classifier call to the Go command (bin/jg-classify.sh). The tests answer by
# exit status (0 yes, 1 no, 2 the classifier could not run); the reads print their result.
_jg_classify_go() {
  "$_JG_CLASSIFY_LIB_DIR/jg-classify.sh" "$@"
}

# Captain-relevant status verbs. A status line carrying any of these is work
# juggernaut must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. JG_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
# A declaration whose prefix is not one of those verbs is still an event, shown
# as the line itself. That covers an unknown word such as parked: or holding:,
# and a known verb whose correlation token is missing or mismatched, so the
# declaration cannot disappear behind an earlier recognized line. Continuation
# prose is not a prefix and stays off that path. Recognized verbs keep the
# classification below.
# The default set itself is owned by the Go command (core/classify/cmd/jg-classify/classify.go).

# The declared-wait verb. A crew (or juggernaut steering it) appends
#   paused: <reason>
# to declare a known wait expected to clear on its own. The legacy "external
# wait" name and "awaiting external" reason also cover the worker's own work;
# they do not identify a separate classification or liveness source.
# bin/jg-brief.sh owns worker-facing declaration and resolution instructions.
# Unlike `blocked:` (stuck, juggernaut must help), an idle `paused:` pane is EXPECTED, so
# the stale path bounds repeats instead of escalating a possible wedge; a live
# idle worker can still surface a first-sight stale alert. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. JG_CLASSIFY_PAUSED_VERB overrides it.
JG_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared external-wait pause.
# Far longer than the wedge threshold (JG_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten wait cannot rot
# invisibly - it re-surfaces once for a recheck every window. Four hours by
# default: a declared wait is by definition expected to clear on its own, so a
# recheck is a backstop, not progress, and an hourly one only produced nagging
# (the 2026-09-07 away-window audit). A worker that knows when its wait clears
# names it with `until` (status_paused_until below) and is rechecked at that
# time or this cadence bound, whichever comes first. Both consumers read
# JG_PAUSE_RESURFACE_SECS with this default so
# the cadence has one owner. An item held for the captain is not rechecked at all
# while the away-posture record exists (bin/jg-watch.sh owns that rule).
# shellcheck disable=SC2034 # Read by the watcher and daemon (jg-watch.sh, jg-supervise-daemon.sh), not this lib.
JG_PAUSE_RESURFACE_SECS_DEFAULT=14400

# jg_utc_iso_to_epoch <YYYY-MM-DDTHH:MM[:SS]Z>: the one portable UTC ISO 8601
# reader shared by the declared-wait vocabulary and the away-posture record
# (bin/jg-afk-contract.sh). Prints epoch seconds; returns 1 on any other shape
# so a malformed time is refused rather than read as "now".
jg_utc_iso_to_epoch() {  # <timestamp>
  _jg_classify_go utc-epoch "${1-}"
}

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# jg-captain-hold.sh has verified the corresponding captain-held backlog item.
JG_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
JG_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# JG_CLASSIFY_EVENT_WINDOW_LINES (default 200) bounds the latest-event read; the Go command reads it.

# Return the last recognized status event, ignoring continuation prose and blanks
# (empty if missing/blank), and with <previous-event-var> the event before it.
# The optional previous event is what this reader returned before the latest one
# was appended, so a consumer can name the head it is superseding; asking for it
# always reads the whole file, since a bounded window cannot bound two events.
# This is an event read; status_current_line below reconciles open decisions.
last_status_line() {  # <status-file> [<previous-event-var>]
  [ "$#" -gt 1 ] || { _jg_classify_go last-line "${1-}"; return; }
  [ -f "$1" ] && [ -r "$1" ] || return 0
  printf -v "$2" '%s' "$(_jg_classify_go last-line --previous "$1")"
  _jg_classify_go last-line "$1"
}

# 0 when <verb> is exactly one recognized status verb, with no leftover token.

# 0 when <word> is a correlation-token attempt the strict parser did not accept.
# A well-formed token is stripped before this sees the verb, so only a missing
# or mismatched token remains here.

# 0 when <line> declares a status prefix that did not parse as a recognized verb.
# An unknown lowercase word (parked:, holding:) is one shape. A recognized verb
# followed only by a missing or mismatched correlation token is the other, as is
# a token written ahead of the verb. The line stays that text: it does not
# become the verb the token failed to separate. Continuation prose is not a
# prefix, including a sentence that merely starts with a known verb, a label
# such as Reason: or e.g.:, a URL, or a clock time such as 10:30.

# Print "<previous event>\n<latest event>" for the status lines on stdin, and
# return 1 when the stream holds no event at all, so a caller reading a bounded
# window knows to widen it. A stream without events keeps its last nonblank
# line as the latest, matching the read this replaced.
# Keep decision-closing events: skipping a resolved line would revive its opener.
# A bare legacy free-text line counts as an event only when a captain token leads
# it, so continuation prose that merely mentions one cannot hide a declaration.
# An unrecognized status prefix is an event too, so that declaration is the
# latest line instead of disappearing behind an earlier recognized one.

# 0 when a nonblank <line> is a recognized status event for the scan above.

# 0 when <line> matches the extended regex <pattern> case-insensitively, leaving
# the caller's nocasematch setting untouched.

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  _jg_classify_go is-terminal "${1-}"
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
# Regex matching ignores any emission-time tag before the first colon - here and
# in the shared event scan, the module's two JG_CAPTAIN_RE sites - so an override
# keeps matching a stamped event however the worker spelled the stamp; other
# metadata and note text remain intact, as do the stored and surfaced event bytes.
status_is_captain_relevant() {
  _jg_classify_go is-relevant "${1-}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a jg-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  _jg_classify_go is-paused "${1-}"
}

# 0 if a status line's leading verb is the verified captain-held transfer verb.
# The same pure verb read as status_is_paused, and the discriminator a supervisor
# needs once a declared wait has already been recognized: the two declarations get
# the same bounded cadence, but they block on DIFFERENT humans, so a recheck that
# names an external dependency for a hold points the captain away from the fact
# that they are the one who can clear it.
status_is_captain_held() {  # <status-line>
  _jg_classify_go is-held "${1-}"
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave a crew's endpoint idle, so both
# supervisors give them one cadence: the away-mode daemon defers the wedge and
# ages a pause marker instead, and the watcher applies its bounded pause cadence
# once pause_state_class has admitted the wait (jg-watch.sh owns which liveness
# evidence each kind of crew must supply for that).
status_is_paused_or_captain_held() {  # <status-line>
  _jg_classify_go is-paused-or-held "${1-}"
}

# The status line that holds a crew in a declared wait, or nothing when it is in
# none. Supervisors decide the wait from this line, never from the raw latest
# event: a resolved line is also how juggernaut answers a decision (jg-send
# --resolve-key), and one that lands after a pause for a different phase key -
# including the stated default key a keyless decision shares - does not end the
# pause. Only a resolved line for the pause's own phase key (the keyed
# activity fold's key, where a keyless line is its own phase) retracts it, as
# does any other later event. A captain-held line counts only while it is the
# latest event. Bounded like last_status_line: only a tail window made wholly of
# resolved events widens the read to the whole file.
status_declared_wait_line() {  # <status-file>
  _jg_classify_go declared-wait "${1-}"
}

# Walk the status lines on stdin back from the newest event past resolved lines
# to the first other event, and print it when it is a pause none of those
# resolved lines share a phase key with. Returns 1 when every event is a
# resolved line, so a caller reading a bounded window knows to widen it.

# A `blocked:` line that names a clearing time still ahead the same way is a planned wait on a known
# future event (a change held for the next release branch): the classifier reads it as a declared pause
# until that time passes (core/classify/cmd/jg-classify/classify.go plannedBlocked), then as a blocker.
# A condition-aware declared wait: a `paused:` line may say WHEN it expects to
# clear with `until <YYYY-MM-DDTHH:MM[:SS]Z>` anywhere in its text (UTC only, so
# no local-zone guess is ever recorded). Prints that time as epoch seconds so a
# supervisor rechecks the wait when the worker said it would clear instead of on
# the flat cadence; returns 1 when the line is not a pause or declares no time,
# or the time is malformed, so a bad token falls back to the cadence rather than
# silencing the wait.
status_paused_until() {  # <status-line> -> epoch on stdout
  _jg_classify_go paused-until "${1-}"
}

# --- status-line grammar and the keyed-decision fold --------------------------
#
# The optional "[at=<epoch>]" emission stamp, the verb, note and "[key=<slug>]" readers, the
# reserved decision-key namespaces and the fold that turns an append-only status stream into the
# decisions still open are owned by the Go command (core/classify/cmd/jg-classify/decide.go);
# its header is the one statement of that grammar. These functions keep the names the other
# libraries call and forward each one. A reader that took an <out-var> still assigns it, so a
# caller's own variable names stay free of this library's.

# Assign <out-var> from the command's output (trailing newlines dropped), keeping its status.
_jg_classify_into() {  # <out-var> <command> [args]
  local __jg_into_val __jg_into_rc
  __jg_into_val=$(_jg_classify_go "${@:2}")
  __jg_into_rc=$?
  printf -v "$1" '%s' "$__jg_into_val"
  return "$__jg_into_rc"
}

# Print the command's output, or assign it to <out-var> when one is named.
_jg_classify_print_or_into() {  # <out-var-or-empty> <command> [args]
  if [ -n "$1" ]; then _jg_classify_into "$1" "${@:2}"; else _jg_classify_go "${@:2}"; fi
}

_jg_status_at_epoch() {  # <status-line> <out-var> -> 0 and the epoch when known
  _jg_classify_into "$2" at-epoch "$1"
}

status_line_at_epoch() {  # <status-line> -> epoch; nonzero when unknown
  _jg_classify_go at-epoch "$1"
}

# Stamp only a newly emitted event; never use this to timestamp a copied historical line.
status_stamp_line() {  # <new-status-line> -> line (without newline)
  _jg_classify_go stamp-line "$1"
}

# Characters status_stamp_line would insert into a line it stamps, so a writer that caps a line
# before the append stamps it can subtract them.
status_stamp_width() {  # -> characters a stamp adds to a line
  _jg_classify_go stamp-width
}

# The line without the one well-formed time tag, the identity a retry is compared by.
_jg_status_untimed() {  # <status-line> <out-var> -> line without a time tag
  _jg_classify_into "$2" untimed "$1"
}

# 0 when the file already holds <new-status-line>, ignoring a well-formed time tag on either side.
status_event_recorded() {  # <status-file> <new-status-line>
  _jg_classify_go event-recorded "$1" "$2"
}

# The leading verb word, printed or assigned to <out-var>; correlation tokens are not part of it.
status_line_verb() {  # <status-line> [<out-var>] -> leading verb word
  _jg_classify_print_or_into "${2-}" verb "$1"
}

_jg_key_before_colon() {  # <status-line>
  _jg_classify_go key-before-colon "$1"
}

_jg_key_at_note_head() {  # <status-line> [<out-var>] -> raw slug
  [ "$#" -le 1 ] || printf -v "$2" '%s' ''
  _jg_classify_print_or_into "${2-}" key-at-note-head "$1"
}

status_line_note() {  # <status-line> [<out-var>] -> text after the first colon, trimmed
  _jg_classify_print_or_into "${2-}" note "$1"
}

_jg_decision_key() {  # <status-line> [<keyless> [<out-var>]] -> key slug, or <keyless> (default "default") when no token
  local __jg_key_val
  [ "$#" -le 2 ] || printf -v "$3" '%s' ''
  __jg_key_val=$(_jg_classify_go key "${2-default}" "$1") || return $?
  if [ "$#" -gt 2 ]; then printf -v "$3" '%s' "$__jg_key_val"; else printf '%s' "$__jg_key_val"; fi
}

# Drop the record for <key> from a "<key>\t<verb>\t<note>" open set into <out-var>.
_jg_decision_drop() {  # <open-set> <key> <out-var>
  _jg_classify_into "$3" drop "$1" "$2"
}

# Reserved decision-key namespaces: a key like `pending-reply-<id>` is raised and closed only by
# the library that owns it, so the fold lets such a key move only on a note that begins with the
# namespace's own `<namespace>...:` vocabulary.
JG_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT='pending-reply- waiting-timer-'

_jg_decision_key_transition_allowed() {  # <key> <note>
  _jg_classify_go transition-allowed "$1" "$2"
}

_jg_is_pending_reply_escalation() {  # <key> <note>
  _jg_classify_go pending-reply-escalation "$1" "$2"
}

_jg_status_kind() {  # <status-file> [<kind>] -> ship, scout, squad_lead or unknown
  _jg_classify_go kind "$1" "${2:-}"
}

# Fold ONE status line into an open set (no file I/O), assigning the new set to <out-var>. The
# whole-file fold, the cursor-backed incremental fold and the key reader all use this one rule.
_jg_decision_fold_line() {  # <open-set> <status-line> <kind> <out-var>
  _jg_classify_into "$4" fold-line "$1" "$2" "$3"
}

# The decisions still open in a status file, one "<key>\t<verb>\t<summary>" per line with none
# trailing, most recently opened last. Use this instead of trusting the last status line.
status_open_decisions() {  # <status-file> [<kind>]
  _jg_classify_go open-decisions "$1" "${2:-}"
}

# The log's current declaration: the most recently opened decision, else a standing declared
# wait, else the latest recognized event.
status_current_line() {  # <status-file> <kind>
  _jg_classify_go current-line "$1" "${2-}"
}

# The open decisions the task raised about its own work: not a supervisor library's reserved key,
# the parent's remote-reply-continuity blocker, or a relayed captain-hold decision.
status_own_open_decisions() {  # <status-file>
  _jg_classify_go own-open-decisions "$1"
}

# 0 when a decision opened by `needs-decision` is still open; with a <run-id>, only one keyed
# `nm-<run-id>-<step>`. Whole-file and cursor-free, and no evidence answers 1.
status_has_open_needs_decision() {  # <status-file> [<run-id>]
  _jg_classify_go has-open-needs-decision "$@"
}

_jg_open_set_has() {  # <open-set> <key>
  _jg_classify_go open-set-has "$1" "$2"
}

_jg_open_set_verb() {  # <open-set> <key> [<out-var>]
  _jg_classify_print_or_into "${3-}" open-set-verb "$1" "$2"
}

# The verb that last moved <key> in a status stream: the opening verb while it is open, the
# closing verb (resolved, or the verified captain-held transfer) once it is closed, nothing when no
# line ever stated a transition for it. A captain-held close means the durable task holds the
# question; a resolved close claims it settled, so a structured row still open behind it is a
# contradiction (bin/jg-captain-hold.sh's `diverged`).
status_key_closing_verb() {  # <status-file> <key>
  _jg_classify_go key-closing-verb "$1" "$2"
}

# The status file inside <state> that is this home's outbound parent channel
# rather than a self-home task status log, printed; empty when there is none.
# Only a remote mate home resolves one - its state/parent-replies.status is the
# parent channel (bin/jg-parent-channel-lib.sh owns that resolution, sourced
# lazily here because that library sources this one at its top level, so a
# top-level source would be circular). A main home, a local mate - whose
# channel lives in the parent home - or an unusable identity or binding keeps
# every file, so ordinary task logs fold and wake exactly as before. The home
# is the directory containing <state>, the <home>/state layout every caller of
# these fleet-wide scans shares; a state dir outside such a home excludes
# nothing. Callers compare the resolved path, never the file name, so a
# parent-replies.status in any other home shape stays an ordinary task log.
status_scan_parent_channel_exclude() {  # <state>
  local state=$1 exclude
  if ! command -v jg_parent_channel_outbound_status >/dev/null 2>&1; then
    # shellcheck source=bin/jg-parent-channel-lib.sh
    . "$_JG_CLASSIFY_LIB_DIR/jg-parent-channel-lib.sh"
  fi
  exclude=$(jg_parent_channel_outbound_status "$(dirname "$state")" "$state") || return 0
  printf '%s\n' "$exclude"
}

# --- incremental (cursor-backed) open-decisions fold ------------------------
# status_open_decisions_incremental reads only the bytes a status file gained since its own last
# call, folds those into a persisted open set through the same rule status_open_decisions uses,
# and rewrites its byte cursor. A per-drain fleet-wide scan is therefore bounded by new appends
# rather than by total lifetime log size. cursor.go owns the cursor format, the fold version, the
# invalidation and read-failure rules, and the atomic write; each function below forwards to it.
_jg_open_decisions_cursor_path() {  # <status-file>
  _jg_classify_go cursor-path "$1"
}

_jg_open_decisions_file_ident() {  # <file> -> strongest available identity
  _jg_classify_go file-ident "$1"
}

_jg_status_file_size() {  # <status-file>
  _jg_classify_go file-size "$1"
}

_jg_status_file_mtime() {  # <status-file>
  _jg_classify_go file-mtime "$1"
}

# Private scratch path for a one-shot span read, alongside the status file the same way the cursor
# above is, and PID-scoped so concurrent readers of one log (the watcher and the away-mode daemon
# both classify the same stream) never truncate each other's chunk.
_jg_status_span_scratch() {  # <status-file>
  printf '%s.span.%s' "$(_jg_open_decisions_cursor_path "$1")" "$$"
}

_jg_status_read_span() {  # <status-file> <start-offset> <byte-length>
  _jg_classify_go read-span "$1" "$2" "$3"
}

status_open_decisions_incremental() {  # <status-file> [<captured-end-offset>]
  _jg_classify_go open-decisions-incremental "$@"
}

# Incremental sibling of status_open_decisions: the same fleet-wide walk and output shape
# ("<task>\t<key>\t<verb>\t<note>" per open decision), folding each task's status log through
# the cursor-backed fold instead of the whole-file one.
scan_open_decisions_incremental() {  # <state>
  _jg_classify_go scan-open-decisions-incremental "$1" "$(status_scan_parent_channel_exclude "$1")"
}

status_presentation_snapshot() {  # <state>
  local state=$1 f task size ident exclude
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    size=$(_jg_status_file_size "$f") || return 1
    size=${size//[[:space:]]/}
    ident=$(_jg_open_decisions_file_ident "$f") || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$ident" ] || return 1
    printf '%s\t%s\t%s\n' "$task" "$size" "$ident" || return 1
  done
}

# Read the latest non-blank event through one captured presentation endpoint.
# This is the bounded latest-event owner for fleet-wide backstops: at most the
# final 64 KiB is inspected, and a file that changes during the read is deferred
# to the next snapshot instead of combining a line from one state with the mtime
# from another. The status log is append-only and ordinary event lines are far
# below this bound. A pathological latest line that crosses the fixed bound is
# intentionally unclassifiable and omitted: bounded memory and never presenting
# a possibly routine line as captain-facing take precedence on that edge.
JG_STATUS_SNAPSHOT_EVENT_LINE=
JG_STATUS_SNAPSHOT_EVENT_MTIME=
JG_STATUS_SNAPSHOT_EVENT_ENDPOINT=
# shellcheck disable=SC2034 # Output globals are consumed by sourcing drain scripts.
status_snapshot_latest_event() {  # <status-file> <captured-endpoint> <captured-identity>
  local f=$1 endpoint=$2 expected_ident=$3 limit=65536 start length scratch record line event_endpoint
  local before_mtime after_mtime before_size after_size before_ident after_ident skip_first=0
  JG_STATUS_SNAPSHOT_EVENT_LINE=
  JG_STATUS_SNAPSHOT_EVENT_MTIME=
  JG_STATUS_SNAPSHOT_EVENT_ENDPOINT=
  case "$endpoint" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$expected_ident" ] || return 1

  before_mtime=$(_jg_status_file_mtime "$f") || return 1
  before_size=$(_jg_status_file_size "$f") || return 1
  before_size=${before_size//[[:space:]]/}
  before_ident=$(_jg_open_decisions_file_ident "$f") || return 1
  case "$before_mtime:$before_size" in *[!0-9:]*) return 1 ;; esac
  [ "$before_size" -eq "$endpoint" ] && [ "$before_ident" = "$expected_ident" ] || return 1

  if [ "$endpoint" -gt "$limit" ]; then
    start=$((endpoint - limit))
    skip_first=1
  else
    start=0
  fi
  length=$((endpoint - start))
  scratch="$(_jg_status_span_scratch "$f").latest"
  _jg_status_read_span "$f" "$start" "$length" > "$scratch" 2>/dev/null \
    || { rm -f "$scratch"; return 1; }
  if record=$(LC_ALL=C perl -e '
    my ($path, $start, $skip_first) = @ARGV;
    open my $file, "<", $path or exit 1;
    binmode $file;
    scalar(<$file>) if $skip_first;
    my ($latest, $end);
    while (defined(my $line = <$file>)) {
      next unless $line =~ /[^\s]/;
      $line =~ s/[\r\n]+\z//;
      ($latest, $end) = ($line, $start + tell($file));
    }
    exit 1 unless defined $end;
    print "$end\t$latest";
  ' "$scratch" "$start" "$skip_first"); then :; else rm -f "$scratch"; return 1; fi
  rm -f "$scratch"
  event_endpoint=${record%%$'\t'*}
  line=${record#*$'\t'}
  case "$event_endpoint" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$line" ] || return 1

  after_mtime=$(_jg_status_file_mtime "$f") || return 1
  after_size=$(_jg_status_file_size "$f") || return 1
  after_size=${after_size//[[:space:]]/}
  after_ident=$(_jg_open_decisions_file_ident "$f") || return 1
  case "$after_mtime:$after_size" in *[!0-9:]*) return 1 ;; esac
  [ "$after_mtime" = "$before_mtime" ] \
    && [ "$after_size" -eq "$endpoint" ] \
    && [ "$after_ident" = "$expected_ident" ] \
    || return 1

  JG_STATUS_SNAPSHOT_EVENT_LINE=$line
  JG_STATUS_SNAPSHOT_EVENT_MTIME=$before_mtime
  JG_STATUS_SNAPSHOT_EVENT_ENDPOINT=$event_endpoint
}

status_presentation_cursor_offset() {  # <status-file>
  local f=$1 state task manifest data row_task offset ident backstop extra cur_ident size legacy
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
    data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
    offset=
    while IFS=$(printf '\t') read -r row_task ident legacy backstop extra; do
      [ -n "$row_task" ] || continue
      [ -z "$extra" ] || return 1
      case "$legacy:$backstop" in *[!0-9:]*) return 1 ;; esac
      [ -n "$legacy" ] && [ -n "$ident" ] || return 1
      if [ "$row_task" = "$task" ]; then
        [ -z "$offset" ] || return 1
        offset=$legacy
        cur_ident=$ident
      fi
    done <<EOF
$data
EOF
    if [ -z "$offset" ]; then
      printf '0'
      return 0
    fi
    ident=$cur_ident
  else
    legacy=$(_jg_open_decisions_cursor_path "$f")
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      status_open_decisions_cursor_offset "$f"
      return
    fi
    offset=0
    ident=$(_jg_open_decisions_file_ident "$f") || return 1
  fi
  cur_ident=$(_jg_open_decisions_file_ident "$f") || return 1
  size=$(_jg_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size:$offset" in *[!0-9:]*) return 1 ;; esac
  if [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then offset=0; fi
  printf '%s' "$offset"
}

status_outcome_backstop_cursor_offset() {  # <status-file>
  local f=$1 state task manifest data row_task ident presented row_backstop backstop extra current size
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  [ -e "$manifest" ] || { printf '0'; return 0; }
  [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
  data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
  backstop=0
  while IFS=$(printf '\t') read -r row_task ident presented row_backstop extra; do
    [ -n "$row_task" ] || continue
    [ -z "$extra" ] || return 1
    case "$presented:$row_backstop" in *[!0-9:]*) return 1 ;; esac
    [ -n "$presented" ] && [ -n "$ident" ] || return 1
    if [ "$row_task" = "$task" ]; then
      current=$(_jg_open_decisions_file_ident "$f") || return 1
      size=$(_jg_status_file_size "$f") || return 1
      size=${size//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) return 1 ;; esac
      [ "$ident" = "$current" ] || { printf '0'; return 0; }
      backstop=${row_backstop:-0}
      [ "$backstop" -le "$size" ] || backstop=0
      printf '%s' "$backstop"
      return 0
    fi
  done <<EOF
$data
EOF
  printf '0'
}

status_signal_seen_marker_path() {  # <state> <task-id>
  printf '%s/.seen-%s' "$1" "$(printf '%s.status' "$2" | tr '.' '_')"
}

status_heartbeat_seen_marker_path() {  # <state> <task-id>
  printf '%s/.hb-surfaced-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

status_daemon_seen_marker_path() {  # <state> <task-id>
  printf '%s/.subsuper-seen-status-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

_status_presentation_signature_valid() {
  local value=$1 size ident encoded
  [ "$value" = unverifiable ] && return 0
  case "$value" in
    r1:*)
      encoded=${value#r1:}
      case "$encoded" in ''|*[!0-9a-f]*) return 1 ;; esac
      return 0
      ;;
  esac
  case "$value" in *@*) size=${value%%@*}; ident=${value#*@} ;; *) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$ident" in ''|*$'\t'*|*$'\n'*) return 1 ;; esac
}

STATUS_PRESENTATION_REPORTED=
STATUS_PRESENTATION_CLASSIFIED=
status_presentation_marker_parse() {
  local raw=$1 rest reported classified
  STATUS_PRESENTATION_REPORTED=
  STATUS_PRESENTATION_CLASSIFIED=
  case "$raw" in
    v2$'\t'*)
      rest=${raw#v2$'\t'}
      case "$rest" in *$'\t'*) reported=${rest%%$'\t'*}; classified=${rest#*$'\t'} ;; *) return 1 ;; esac
      case "$classified" in *$'\t'*) return 1 ;; esac
      _status_presentation_signature_valid "$reported" || return 1
      if [ "$classified" != - ]; then
        _status_presentation_signature_valid "$classified" || return 1
        case "$classified" in unverifiable|r1:*) return 1 ;; esac
      fi
      ;;
    *)
      _status_presentation_signature_valid "$raw" || return 1
      case "$raw" in unverifiable|r1:*) return 1 ;; esac
      reported=$raw
      classified=$raw
      ;;
  esac
  STATUS_PRESENTATION_REPORTED=$reported
  STATUS_PRESENTATION_CLASSIFIED=$classified
}

_status_observed_path_state() {
  if [ "$_JG_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%HT:%p' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%F:%f' "$1" 2>/dev/null
  fi
}

status_observed_signature() {
  local f=$1 size=${2-} ident=${3-} path_state link_target=- access kind encoded
  path_state=$(_status_observed_path_state "$f") || path_state=stat-error
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then
    kind=absent
  elif [ ! -f "$f" ]; then
    kind=nonregular
  elif [ -r "$f" ]; then
    kind=readable
  else
    kind=unreadable
  fi
  if [ -z "$size" ]; then
    size=$(_jg_status_file_size "$f") || size='size-error'
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  fi
  if [ -z "$ident" ]; then
    ident=$(_jg_open_decisions_file_ident "$f") || ident=identity-error
    [ -n "$ident" ] || ident=identity-error
  fi
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  encoded=$(printf '%s\0%s\0%s\0%s\0%s\0%s' \
    "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  printf 'r1:%s' "$encoded"
}

status_presentation_marker_reported_matches() {
  local raw
  raw=$(cat "$1" 2>/dev/null) || return 1
  status_presentation_marker_parse "$raw" || return 1
  [ "$STATUS_PRESENTATION_REPORTED" = "$2" ]
}

status_presentation_marker_offset() {
  local raw classified offset ident current
  raw=$(cat "$1" 2>/dev/null) || { printf '0'; return 0; }
  status_presentation_marker_parse "$raw" || { printf '0'; return 0; }
  classified=$STATUS_PRESENTATION_CLASSIFIED
  [ "$classified" != - ] || { printf '0'; return 0; }
  offset=${classified%%@*}; ident=${classified#*@}
  current=$(_jg_open_decisions_file_ident "$2") || { printf '0'; return 0; }
  [ "$ident" = "$current" ] || { printf '0'; return 0; }
  printf '%s' "$offset"
}

status_presentation_marker_report() {
  local marker=$1 reported=$2 raw classified=-
  _status_presentation_signature_valid "$reported" || return 1
  if raw=$(cat "$marker" 2>/dev/null) && status_presentation_marker_parse "$raw"; then
    classified=$STATUS_PRESENTATION_CLASSIFIED
  fi
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}

status_presentation_marker_commit() {
  local marker=$1 file=$2 endpoint=$3 ident=$4 current reported classified
  case "$endpoint" in ''|*[!0-9]*) return 1 ;; esac
  current=$(_jg_open_decisions_file_ident "$file") || return 1
  [ -n "$ident" ] && [ "$ident" = "$current" ] || return 1
  reported=$(status_observed_signature "$file" "$endpoint" "$ident") || return 1
  classified="${endpoint}@${ident}"
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}

status_retire_presentation_task() {  # <state> <task-id>
  local state=$1 task=$2 lock manifest tmp data row_task ident offset backstop extra rc=0 found=0
  local signal_marker heartbeat_marker daemon_marker home_appends home_appends_lock
  lock="$state/.status-presentation-lock"
  manifest="$state/.status-presentation-cursor"
  tmp="$manifest.tmp.$$"
  signal_marker=$(status_signal_seen_marker_path "$state" "$task")
  heartbeat_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  daemon_marker=$(status_daemon_seen_marker_path "$state" "$task")
  home_appends="$state/.$task.home-appends"
  home_appends_lock="$home_appends.lock"

  # A remote-home teardown can legitimately retire an endpoint ID that has no
  # status log in that home. Do not contend with that home's unrelated status
  # presenter in this no-op case. A concurrent presenter cannot add this task
  # without its status file, so a valid manifest with no matching row is a
  # durable proof that there is nothing to retire.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ] \
    && [ ! -e "$state/.$task.open-decisions-cursor" ] \
    && [ ! -L "$state/.$task.open-decisions-cursor" ] \
    && [ ! -e "$home_appends" ] && [ ! -L "$home_appends" ] \
    && [ ! -e "$home_appends_lock" ] && [ ! -L "$home_appends_lock" ] \
    && [ ! -e "$signal_marker" ] && [ ! -L "$signal_marker" ] \
    && [ ! -e "$heartbeat_marker" ] && [ ! -L "$heartbeat_marker" ] \
    && [ ! -e "$daemon_marker" ] && [ ! -L "$daemon_marker" ]; then
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
      return 0
    fi
    if [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] \
      && data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      while IFS=$(printf '\t') read -r row_task ident offset backstop extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset:$backstop" in *[!0-9:]*) rc=1; break ;; esac
        [ -n "$offset" ] || { rc=1; break; }
        [ "$row_task" != "$task" ] || found=1
      done <<EOF
$data
EOF
      [ "$rc" -ne 0 ] || [ "$found" -ne 0 ] || return 0
      rc=0
    fi
  fi

  jg_lock_acquire_wait "$lock" || return 1
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if [ ! -f "$manifest" ] || [ ! -r "$manifest" ] || [ -L "$manifest" ]; then
      rc=1
    elif ! data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      rc=1
    elif ! : > "$tmp"; then
      rc=1
    else
      while IFS=$(printf '\t') read -r row_task ident offset backstop extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset:$backstop" in *[!0-9:]*) rc=1; break ;; esac
        [ -n "$offset" ] || { rc=1; break; }
        if [ "$row_task" != "$task" ]; then
          printf '%s\t%s\t%s\t%s\n' "$row_task" "$ident" "$offset" "${backstop:-0}" >> "$tmp" \
            || { rc=1; break; }
        fi
      done <<EOF
$data
EOF
      if [ "$rc" -eq 0 ]; then mv -f "$tmp" "$manifest" || rc=1; fi
      [ "$rc" -eq 0 ] || rm -f "$tmp"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$state/$task.status" "$state/.$task.open-decisions-cursor" \
      "$home_appends" "$signal_marker" "$heartbeat_marker" "$daemon_marker" || rc=1
    jg_lock_remove_path "$home_appends_lock" 2>/dev/null || true
  fi
  jg_lock_release "$lock" || rc=1
  return "$rc"
}

status_acknowledge_presented_snapshot() {  # <state> <snapshot> [<fully-presented-task-ids>]
  local state=$1 snapshot=$2 fully_presented=${3:-} task endpoint ident f offset lines line safe
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    safe=false
    case "
$fully_presented
" in *$'\n'"$task"$'\n'*) safe=true ;; esac
    if [ "$safe" = false ]; then
      f="$state/$task.status"
      offset=$(status_presentation_cursor_offset "$f") || return 1
      lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
      # Once any informational line in this span is presented fleet-wide, the
      # contiguous cursor may advance through the captured endpoint. Routine
      # lines remain unacknowledged only while they are the sole unread content,
      # preserving delayed signal annotations without replaying a handled note
      # that happened to follow a routine line.
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *[![:space:]]*)
            if status_line_is_unread_surface "$line"; then safe=true; break; fi
            ;;
        esac
      done <<EOF
$lines
EOF
      if [ "$safe" = false ]; then endpoint=$offset; fi
    fi
    printf '%s\t%s\t%s\n' "$task" "$endpoint" "$ident" || return 1
  done <<EOF
$snapshot
EOF
}

status_commit_presentation_snapshot() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f cur_ident size tmp backstop acknowledged_task acknowledged_endpoint
  tmp="$state/.status-presentation-cursor.tmp.$$"
  : > "$tmp" || return 1
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ -n "$ident" ] || { rm -f "$tmp"; return 1; }
    f="$state/$task.status"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { rm -f "$tmp"; return 1; }
    cur_ident=$(_jg_open_decisions_file_ident "$f") || { rm -f "$tmp"; return 1; }
    size=$(_jg_status_file_size "$f") || { rm -f "$tmp"; return 1; }
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$cur_ident" = "$ident" ] && [ "$endpoint" -le "$size" ] \
      || { rm -f "$tmp"; return 1; }
    backstop=$(status_outcome_backstop_cursor_offset "$f") || { rm -f "$tmp"; return 1; }
    while IFS=$(printf '\t') read -r acknowledged_task acknowledged_endpoint; do
      if [ "$acknowledged_task" = "$task" ]; then backstop=$acknowledged_endpoint; fi
    done <<EOF
${STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED:-}
EOF
    case "$backstop" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$backstop" -le "$size" ] || { rm -f "$tmp"; return 1; }
    printf '%s\t%s\t%s\t%s\n' "$task" "$ident" "$endpoint" "$backstop" >> "$tmp" \
      || { rm -f "$tmp"; return 1; }
  done <<EOF
$snapshot
EOF
  mv -f "$tmp" "$state/.status-presentation-cursor" || { rm -f "$tmp"; return 1; }
}

scan_open_decisions_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f open line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    open=$(status_open_decisions_incremental "$f" "$endpoint") || return 1
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done <<EOF
$snapshot
EOF
}

# --- unread status lines since the presentation cursor ----------------------
#
# The drain annotation historically printed only the newest status line, so a
# substantive `note:` answer immediately followed by a routine `note:` (or a
# pending-reply resolution buried under a later unrelated append) never reached
# the supervisor. Those verbs also never enter the OPEN DECISIONS fold, so they
# had no other surfacing path.
# These helpers are the ONE owner of "what is still unread since the last drain
# presentation": one fleet manifest records each status identity and last-
# presented byte offset, and one atomic replacement commits only the contiguous
# status spans that were successfully presented. A quiet fleet scan leaves
# routine working/done bytes unacknowledged so a subsequently published signal
# can still annotate them. A missing manifest row or changed file identity is
# offset 0 for the current file, while malformed or unreadable cursor state
# aborts presentation without advancing any offset. A trusted cursor at EOF
# prints nothing, so already-presented bytes are not replayed as new. Teardown
# retires a task's manifest row with its status file, so reusing a task ID starts
# the replacement log unread at byte 0. Informational `note:` lines and
# reserved-key pending-reply resolutions are the fleet-wide unread surface;
# they are not open decisions and are not persisted in the folded open-set.

# Read the legacy per-task open-decisions cursor used to seed the presentation
# offset before the fleet manifest exists. A fold-version mismatch, identity
# mismatch, or offset past the current size falls back to 0. Never writes unless
# a caller explicitly requests a migration snapshot.
status_open_decisions_cursor_offset() {  # <status-file>
  _jg_classify_go legacy-cursor-offset "$1"
}

# Print every non-blank status line whose bytes begin at or after the persisted
# presentation offset. Does not write the cursor. A missing manifest row or
# changed status identity reads the current file from offset 0; malformed or
# unreadable cursor state fails the scan. Symlinks and unreadable status files
# print nothing.
status_new_lines_since_cursor() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset size actual_size chunk_file line rc=0
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_jg_open_decisions_cursor_path "$f")
  chunk_file="$cf.unread.$$"
  offset=$(status_presentation_cursor_offset "$f") || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  actual_size=$(_jg_status_file_size "$f") || return 1
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in ''|*[!0-9]*) return 1 ;; esac
    [ "$captured_end" -le "$actual_size" ] || return 1
    size=$captured_end
  else
    size=$actual_size
  fi
  [ "$offset" -lt "$size" ] || return 0
  _jg_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *[![:space:]]*) printf '%s\n' "$line" || { rc=1; break; } ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file"
  return "$rc"
}

# 0 when a status line is an informational `note:` or a reserved-key
# pending-reply resolution. Those lines never fold into OPEN DECISIONS, so the
# drain's unread-status surface is their only guaranteed presentation.
status_line_is_unread_surface() {  # <status-line>
  local line=$1 verb key note resolve held prefix
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = note ] && return 0
  resolve=${JG_CLASSIFY_RESOLVE_VERB:-$JG_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${JG_CLASSIFY_CAPTAIN_HELD_VERB:-$JG_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    "$resolve"|"$held") ;;
    *) return 1 ;;
  esac
  key=$(_jg_decision_key "$line") || return 1
  note=$(status_line_note "$line")
  for prefix in ${JG_CLASSIFY_RESERVED_KEY_PREFIXES:-$JG_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        _jg_decision_key_transition_allowed "$key" "$note"
        return
        ;;
    esac
  done
  return 1
}

# Fleet-wide unread informational lines: one "<task>\t<status-line>" row per
# still-unread `note:` or pending-reply resolution, in glob (task id) order.
# Prints nothing when none are unread. Directory scan rejects status symlinks
# the same way status_open_decisions does.
scan_unread_surface_lines() {  # <state>
  local state=$1 f task lines line exclude
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=$(basename "$f"); task="${task%.status}"
    lines=$(status_new_lines_since_cursor "$f") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done
  return 0
}

scan_unread_surface_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f lines line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done <<EOF
$snapshot
EOF
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event prints as the default key, preserving one-phase behavior.
# That printed key is not the decision fold's shared default bucket: a line with
# no stated key is a different phase from an explicit "[key=default]" line, so a
# stated default-key retraction cannot cancel an unrelated keyless wait, while a
# keyless retraction still closes only the keyless phase.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or jg-crew-state result.
# Internal stand-in for a keyless phase. Outside the decision-key charset so it
# cannot collide with a stated slug, and rewritten to "default" only on output.
_JG_CLASSIFY_KEYLESS_PHASE=$'\036default'

# Rewrite the keyless stand-in back to the public "default" key. Only the key
# field is rewritten, so a note that happens to contain the stand-in stays put.
_jg_activity_publish_keys() {  # <open-set>
  local line key rest
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    rest=${line#*$'\t'}
    [ "$key" = "$_JG_CLASSIFY_KEYLESS_PHASE" ] && key=default
    printf '%s\t%s\n' "$key" "$rest"
  done <<EOF
$1
EOF
}

_jg_status_open_activities_stream() {
  local line verb key note resolve held open='' pause
  resolve=${JG_CLASSIFY_RESOLVE_VERB:-$JG_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${JG_CLASSIFY_CAPTAIN_HELD_VERB:-$JG_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${JG_CLASSIFY_PAUSED_VERB:-$JG_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    # Blank-line guard; see _jg_decision_fold_line for why this is a glob.
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    status_line_verb "$line" verb
    _jg_decision_key "$line" "$_JG_CLASSIFY_KEYLESS_PHASE" key || continue
    case "$verb" in
      working|"$pause")
        status_line_note "$line" note
        _jg_decision_drop "$open" "$key" open
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        _jg_decision_drop "$open" "$key" open
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  _jg_activity_publish_keys "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _jg_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _jg_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:jg-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${JG_STATE_OVERRIDE:-}}} meta mw mt t line
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      # The last window= and terminal= values, read in one pass without the
      # grep | tail -1 | cut -d= -f2- pipelines this once forked per key.
      mw=
      mt=
      {
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            window=*) mw=${line#window=} ;;
            terminal=*) mt=${line#terminal=} ;;
          esac
        done < "$meta"
      } 2>/dev/null
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=${meta##*/}
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#jg-}"; printf '%s' "$t"
}

# --- home-owned status-append ledger ----------------------------------------
#
# This home's bookkeeping closes (jg_wake_status_append_self_announced) record
# the exact byte range they appended so the wake scan can tell this home's own
# growth from a foreign write. That is the multi-answer path: two distinct
# --resolve-key closes must not each force a captain-facing wake solely because
# each one appended a status line, while a worker-authored line that is not in
# this ledger still signals.
# jg_wake_signal_seen_current (bin/jg-wake-lib.sh) is the ONLY consumer. The
# ledger decides whether growth wakes this home and nothing else: it never
# removes a line from presentation, so the drain's signal annotation and its
# UNREAD STATUS section both still print these bytes.
# The ledger does not use lag verbs to hide a worker `resolved` line; only
# bytes this home itself recorded as owned are ever treated as owned.
#
# Path: state/.<task>.home-appends
# Format:
#   v1
#   ident=<file-ident>
#   <start><TAB><end>
# Ranges are half-open [start, end), written in the order they were appended.
# The only writer is jg_wake_status_append_self_announced, which records the
# pre- and post-append size of an append-only log it just grew, so each new
# start is at or after the last recorded end; a new range that begins exactly
# where the last one ended extends that line instead of adding another.
# status_home_appends_covers depends on that ascending order: it walks the
# ledger once and ignores any range starting past the point it has reached, so
# a ledger written out of order would refuse to prove coverage and fail toward
# waking, never toward silence.
# An identity mismatch (file rotated) discards the ledger. Teardown deletes it.
# Not a pure status-file read: status_home_appends_record writes this sidecar.
# That read-merge-write serializes through bin/jg-wake-lib.sh's jg_lock_*
# helpers, exactly as status_retire_presentation_task above does, so a caller
# that touches this ledger must have sourced that library first.

status_home_appends_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.home-appends' "$dir" "${base%.status}"
}

status_home_appends_ranges() {  # <status-file> -> start<TAB>end lines
  local f=$1 path ident data first rest line start end extra
  path=$(status_home_appends_path "$f")
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 0
  ident=$(_jg_open_decisions_file_ident "$f") || return 0
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) || return 0
  first=${data%%$'\n'*}
  [ "$first" = v1 ] || return 0
  rest=${data#*$'\n'}
  [ "$rest" != "$data" ] || return 0
  line=${rest%%$'\n'*}
  case "$line" in ident=*) ;; *) return 0 ;; esac
  [ "${line#ident=}" = "$ident" ] || return 0
  case "$rest" in
    *$'\n'*) rest=${rest#*$'\n'} ;;
    *) return 0 ;;
  esac
  while IFS=$(printf '\t') read -r start end extra || [ -n "$start" ]; do
    [ -n "$start" ] || continue
    [ -z "$extra" ] || continue
    case "$start:$end" in *[!0-9:]*) continue ;; esac
    [ "$end" -gt "$start" ] || continue
    printf '%s\t%s\n' "$start" "$end" || return 1
  done <<EOF
$rest
EOF
}

status_home_appends_covers() {  # <status-file> <start> <end>
  local start=$2 end=$3 range_start range_end
  case "$start:$end" in *[!0-9:]*) return 1 ;; esac
  [ "$end" -ge "$start" ] || return 1
  while IFS=$(printf '\t') read -r range_start range_end; do
    [ -n "$range_start" ] || continue
    case "$range_start:$range_end" in *[!0-9:]*) continue ;; esac
    [ "$range_start" -le "$start" ] || continue
    if [ "$range_end" -gt "$start" ]; then
      start=$range_end
    fi
    if [ "$start" -ge "$end" ]; then
      return 0
    fi
  done <<EOF
$(status_home_appends_ranges "$1")
EOF
  [ "$start" -ge "$end" ]
}

status_home_appends_record() {  # <status-file> <start> <end>
  local f=$1 start=$2 end=$3 path lock rc=0
  case "$start:$end" in *[!0-9:]*) return 1 ;; esac
  [ "$end" -gt "$start" ] || return 1
  path=$(status_home_appends_path "$f")
  lock="$path.lock"
  jg_lock_acquire_wait "$lock" || return 1
  _jg_status_home_appends_merge_locked "$f" "$path" "$start" "$end" || rc=1
  jg_lock_release "$lock" || rc=1
  return "$rc"
}

_jg_status_home_appends_merge_locked() {  # <status-file> <ledger-path> <start> <end>
  local f=$1 path=$2 start=$3 end=$4 ident tmp line last='' body='' coalesced=0
  local LC_ALL=C
  ident=$(_jg_open_decisions_file_ident "$f") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$last" ]; then body="${body}${last}"$'\n'; fi
    last=$line
  done <<EOF
$(status_home_appends_ranges "$f")
EOF
  if [ -n "$last" ]; then
    if [ "${last#*$'\t'}" = "$start" ]; then
      last="${last%%$'\t'*}"$'\t'"$end"
      coalesced=1
    fi
    body="${body}${last}"$'\n'
  fi
  if [ "$coalesced" -eq 0 ]; then
    body="${body}${start}"$'\t'"${end}"$'\n'
  fi
  tmp="$path.tmp.$$"
  printf 'v1\nident=%s\n%s' "$ident" "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Capture the bytes of an append-only status log at or after <start-offset> under
# one size-and-identity snapshot.
# The record form produces `<endpoint>\t<identity>\t<events>` and returns 0 when
# the span has actionable events, joining every such event in source order with
# ` ; ` so callers report the complete captured span before committing it.
# With optional <record-var>, it assigns that record instead of printing it; with
# optional <needs-decision-var>, it also assigns 1 when the span newly surfaces a
# needs-decision, captain-held declaration, or pending-reply escalation, otherwise
# 0. This side-band classification never changes the event text.
# It returns 1 after a successful classification with no actionable event; an
# existing log still produces its committable endpoint and identity, while an absent
# log is the ordinary empty case and produces no record.
# It returns 2 with no committable endpoint when an existing status object cannot
# be classified.
# The simpler wrapper prints only the event field, and the predicate discards the
# record; all three inherit the library-header contract above.
#
# A keyed `needs-decision` or `blocked` opening is included only when the
# captured span's fold still names that exact opening as live.
# Earlier log lines cannot change whether an opening in the span survives:
# only later lines can close or supersede it. Folding only the span therefore
# gives the same verdict for its openings without rereading the log's history.
# A transition rejected by the reserved-key vocabulary is surfaced instead as a
# reconciliation signal and never treated here as an open decision.
# status_open_decisions remains the single owner of open/closed semantics,
# including same-key reopening and reserved-key handling.
# Every other captain-relevant event is terminal and always actionable.
status_span_first_actionable_record() {  # <status-file> <start-offset> [record-var] [needs-decision-var]
  local f=$1 start=${2:-0} output_var=${3-} needs_var=${4-} size ident cur_ident scratch chunk_file result
  local rc=0 events='' classified kind _jg_span_needs_decision=0
  [ -e "$f" ] || { [ -L "$f" ] && return 2; return 1; }
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 2
  ident=$(_jg_open_decisions_file_ident "$f") || return 2
  size=$(_jg_status_file_size "$f") || return 2
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 2 ;; esac
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$start" -le "$size" ] || start=0
  if [ "$start" -ge "$size" ]; then
    result="${size}"$'\t'"${ident}"
    if [ -n "$output_var" ]; then
      printf -v "$output_var" '%s' "$result"
      [ -z "$needs_var" ] || printf -v "$needs_var" '%s' 0
    else
      printf '%s' "$result"
    fi
    return 1
  fi
  scratch=$(_jg_status_span_scratch "$f") || return 2
  chunk_file="${scratch}.span"
  _jg_status_read_span "$f" "$start" "$((size - start))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file"; return 2; }
  cur_ident=$(_jg_open_decisions_file_ident "$f") || {
    rm -f "$chunk_file"; return 2;
  }
  [ "$cur_ident" = "$ident" ] || { rm -f "$chunk_file"; return 2; }
  kind=$(_jg_status_kind "$f") || { rm -f "$chunk_file"; return 2; }
  classified=$(_jg_classify_go span-events "$kind" < "$chunk_file") || rc=$?
  rm -f "$chunk_file"
  [ "$rc" -le 1 ] || return 2
  _jg_span_needs_decision=${classified%%$'\t'*}
  events=${classified#*$'\t'}
  if [ "$rc" -eq 0 ]; then result="${size}"$'\t'"${ident}"$'\t'"${events}"; else result="${size}"$'\t'"${ident}"; fi
  if [ -n "$output_var" ]; then
    printf -v "$output_var" '%s' "$result"
    [ -z "$needs_var" ] || printf -v "$needs_var" '%s' "$_jg_span_needs_decision"
  else
    printf '%s' "$result"
  fi
  return "$rc"
}

status_span_first_actionable() {  # <status-file> <start-offset>
  local record rc rest
  record=$(status_span_first_actionable_record "$1" "${2:-0}")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rest=${record#*$'\t'}
    printf '%s' "${rest#*$'\t'}"
  fi
  return "$rc"
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/jg-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One jg-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: jg-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# JG_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$JG_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-on-positive-evidence. This is the sole proof for stale wakes and the
# shared authoritative proof for no-verb signals. Where a home opts in, jg-watch.sh
# may additionally absorb a bare turn-end on bounded pane churn, while every other
# failed verdict surfaces
# because the crew may be done, waiting on a decision, or wedged. For stale panes
# it is checked before trusting the status log so a pre-validation captain-relevant
# line does not override an active run. See crew_absorb_class for the exact
# working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# The one spelling of the verdict component that says a parked gate's answer is
# owed by a HUMAN. bin/jg-crew-state.sh mints it (nm_gate_awaits_human_decision
# owns the derivation: the findings table's `action` column, read by position);
# crew_gate_awaits_human_decision below is its only consumer.
JG_GATE_HUMAN_DECISION='ask-user: authority decision'

# 0 if crew <id>'s authoritative current state is a no-mistakes gate whose answer
# is owed by a human rather than by the operator itself.
#
# `parked` alone cannot answer this: the gate's shape (awaiting_approval,
# fix_review, awaiting_agent) is reported parked in every case and does not by
# itself say who owes the answer; only a findings row whose `action` column is
# exactly `ask-user` does. A operator that goes quiet before answering its OWN
# gate is precisely the wedge the escalation ladder exists to catch, so only the
# minted component above - never the parked verdict, the gate name, or the
# finding text - admits a lane here.
#
# The whole component is compared for equality rather than searched for, so a
# gate name or a reconciliation note that happens to contain the words cannot
# mint it downstream either.
# On success it prints the reported run id, read from the line's whole
# `run: <id>` component, so the caller can bind the gate to the decision that
# names that run; a line carrying no run id is not evidence, since nothing could
# then tie a decision to this gate.
# Same cost and the same caveat as crew_absorb_class: one jg-crew-state.sh read,
# which may make a bounded no-mistakes call, so callers take it only where they
# already accept that cost.
crew_gate_awaits_human_decision() {  # <id> -> <run-id> on stdout
  local id=$1 line state src rest part human='' run=''
  [ -n "$id" ] || return 1
  line=$("$JG_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = parked ] || return 1
  src=${line#*source: }; src=${src%% *}
  [ "$src" = run-step ] || return 1
  rest="$line · "
  while [ -n "$rest" ]; do
    part=${rest%% · *}
    rest=${rest#* · }
    [ "$part" = "$JG_GATE_HUMAN_DECISION" ] && human=1
    case "$part" in "run: "?*) run=${part#run: } ;; esac
  done
  [ -n "$human" ] && [ -n "$run" ] || return 1
  case "$run" in *[[:space:]]*) return 1 ;; esac
  printf '%s\n' "$run"
}

# Directories excluded from the worktree write probe below, and the depth it walks.
# The excluded set is everything a supervisor read or a package manager can write
# without the crew doing any work - .git first, so juggernaut's own read-only git
# commands against the worktree can never make the probe self-fulfilling - plus the
# large generated trees that would make the walk expensive. Both are overridable so
# a home with an unusual layout can widen or narrow the probe. The list is a skip
# list, so clearing it skips nothing and widens the walk to the whole depth-bounded
# tree; it never disables the probe, which would quietly cost the wedge detector a
# liveness input on a home that meant to widen it. Defaulted with the plain form so
# an explicitly empty value stays empty: clearing the knob in the environment is the
# documented way to ask for that wider walk, and treating empty as unset would hand
# the default skip list back to exactly the home that asked for more coverage.
JG_WORKTREE_WRITE_PRUNE=${JG_WORKTREE_WRITE_PRUNE-'.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'}
JG_WORKTREE_WRITE_MAXDEPTH=${JG_WORKTREE_WRITE_MAXDEPTH:-6}

# Wall-clock seconds the probe's single walk may take. The walk runs synchronously
# inside the caller's poll loop at the exact moment an escalation would otherwise
# fire, and -xdev keeps it out of a nested mount but cannot help when the worktree
# root ITSELF sits on a hung network or container mount; unbounded, such a walk
# would wedge the very supervisor that exists to notice a wedge, stalling its
# heartbeat instead of escalating. Hitting the bound is a negative outcome like
# every other: it reads as no evidence, so the caller's escalation schedule is
# untouched and a stall that writes nothing still escalates on the existing
# schedule. A value that is not a positive integer is not a bound at all (`timeout
# 0` and the perl fallback's `alarm 0` both disable the deadline), so the default
# applies instead; the check lives at the point of use so an in-process override
# gets it too.
JG_WORKTREE_WRITE_TIMEOUT=${JG_WORKTREE_WRITE_TIMEOUT:-10}

# 0 when some regular file under <id>'s recorded worktree is newer than
# <anchor-file>: positive evidence the crew is still producing work even though its
# rendered pane has gone quiet. This is the third liveness input the wedge detector
# has, after pane quietness and the run step, and it exists because neither of
# those can see a crew that is writing source, then tests, then documentation
# behind a static pane - the 2026-08-14 case of eight consecutive possible-wedge
# escalations against a crew that was demonstrably working the whole time.
#
# 1 for every other outcome, including an id with no recorded worktree, a worktree
# that is gone, a missing anchor, and a walk that fails or finds nothing. Absence of
# evidence therefore always leaves the caller's existing escalation schedule
# untouched, so a crew that writes nothing still escalates exactly as before.
#
# A kind=squad_lead task records a provisioned juggernaut home, not a code tree, and
# such a home runs its OWN supervision inside it: its state/ directory churns a
# watcher beacon, pane hashes, and heartbeats whether or not the mate is producing
# anything, so a walk there would report liveness for a mate that has done nothing.
# Those homes are excluded outright rather than by pruning "state", which would also
# hide a legitimate source directory of that name in an ordinary worktree. The
# exclusion is a negative outcome like any other, so an unproductive mate keeps
# escalating on the caller's unchanged schedule.
#
# The anchor is the caller's own idle-window timer file, whose mtime already marks
# when the quiet window opened, so `-newer` needs no clock arithmetic, no temp
# file, and no portable mtime-setting. Not a pure status-file read (see the header):
# one pruned, depth-bounded, wall-clock-bounded walk per call, which callers must
# reach only when they are otherwise about to escalate, never on every poll. A walk
# that outlives JG_WORKTREE_WRITE_TIMEOUT is killed and reported as no evidence, so
# a hung mount costs the escalation nothing but the bound. -xdev holds that walk to the
# worktree's own filesystem rather than descending into a nested network or container
# mount, so a write that lands only under such a mount is one more negative outcome.
crew_worktree_written_since() {  # <id> <state> <anchor-file>
  local id=$1 state=$2 anchor=$3 wt kind name hit bound
  local -a names=() prune=()
  [ -n "$id" ] || return 1
  [ -f "$anchor" ] || return 1
  wt=$(grep '^worktree=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  kind=$(jg_compat_kind "$(grep '^kind=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)")
  [ "$kind" != squad_lead ] || return 1
  if [ -e "$(jg_compat_marker "$wt")" ] || [ -L "$(jg_compat_marker "$wt")" ]; then
    return 1
  fi
  read -r -a names <<< "$JG_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=$JG_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(jg_run_timed "$bound" find "$wt" -xdev -maxdepth "$JG_WORKTREE_WRITE_MAXDEPTH" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  else
    hit=$(jg_run_timed "$bound" find "$wt" -xdev -maxdepth "$JG_WORKTREE_WRITE_MAXDEPTH" \
      -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  fi
  [ -n "$hit" ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list the caller classified with the span read above.
# Files are mapped to task ids by stripping the .status / .turn-ended suffix;
# a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
# A kind=squad_lead task's .status stream doubles as its routed-reply channel,
# so the lines new since the watcher's classified position are read before any
# busy evidence counts: a decision, blocker, terminal outcome, `note:`, any line
# carrying a correlation marker (jg_pending_reply_corr_token, bracketed or not),
# and any verb this library does not know is parent-directed content the
# supervisor must read, so it surfaces regardless of how busy the mate is. Only
# unmarked routine `working:` and `paused:` progress falls through
# to the same provably-working absorb an ordinary operator gets, so a healthy
# mate's progress no longer wakes the primary on every append while an unproven
# mate still surfaces. The span starts at the classified position its owner
# reports (jg_wake_signal_seen_size, bin/jg-wake-lib.sh, loaded by every watcher
# caller); a caller without that library reads the whole log, which can only
# surface more. An unreadable span surfaces. Scoped to .status files - a mate's
# bare turn-ended ping always used the ordinary provably-working absorb.
_jg_squad_lead_status_new_lines_routine() {  # <status-file> <state>
  local f=$1 state=$2 start=0 size chunk line verb
  if command -v jg_wake_signal_seen_size >/dev/null 2>&1; then
    start=$(jg_wake_signal_seen_size "$state" "$f")
  fi
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  size=$(_jg_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$start" -le "$size" ] || start=0
  [ "$start" -lt "$size" ] || return 0
  chunk=$(_jg_status_read_span "$f" "$start" "$((size - start))") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    case "$line" in *corr=*) return 1 ;; esac
    status_line_verb "$line" verb
    case "$verb" in
      working|"${JG_CLASSIFY_PAUSED_VERB:-$JG_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
      *) return 1 ;;
    esac
  done <<EOF
$chunk
EOF
  return 0
}
signal_crew_provably_working() {  # <file> ...
  local f base dir task seen=""
  for f in "$@"; do
    base=${f##*/}
    dir=${f%/*}
    [ "$dir" != "$f" ] || dir=.
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case "$base" in
      *.status)
        if [ "$(jg_compat_kind "$(grep '^kind=' "$dir/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2-)")" = squad_lead ]; then
          _jg_squad_lead_status_new_lines_routine "$f" "$dir" || return 1
        fi
        ;;
    esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's latest recognized status event is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# A stale wake names its task and its reason, so the primary does not spend a model turn
# mapping a bare endpoint to a task. stale_wake_decorate prints <text> with a trailing
# " [task=<id> reason=<kind>]" and nothing else changed, so every prefix and substring
# match on the wake text (the routing rules, the declared-pause read) keeps working.
# The task comes from the recorded metadata of the endpoint the text names ("unknown"
# when none records it). The reason comes from what the text says, then from the verb of
# the task's latest status line:
#   permission  a permission prompt is waiting on someone
#   unread      a steering instruction sits unhandled (or its inbox cannot be written)
#   wedge       an idle pane past the wedge timer
#   looping     the pane repeats the same output
#   blocked     a blocked, needs-decision or paused status, or a declared wait
#   finished    the latest status is done
#   failed      the latest status is failed
#   stopped     none of the above: an idle pane or an exited agent
# Text that is not a stale wake, or already carries the suffix, is printed unchanged.
stale_wake_decorate() {  # <text> [<state-dir>]
  local text=$1 state=${2:-${STATE:-${JG_STATE_OVERRIDE:-}}} w task reason last verb
  case "$text" in
    'stale: '*) ;;
    *) printf '%s' "$text"; return 0 ;;
  esac
  case "$text" in
    *' [task='*' reason='*']') printf '%s' "$text"; return 0 ;;
  esac
  w=${text#stale: }
  w=${w%% *}
  task=unknown
  if [ -n "$state" ]; then
    task=$(window_to_task "$w" "$state")
    [ -e "$state/$task.meta" ] || task=unknown
  fi
  case "$text" in
    *'permission prompt'*) reason=permission ;;
    *'unread juggernaut instruction'*|*'steering-inbox'*) reason=unread ;;
    *'possible wedge'*) reason=wedge ;;
    *[Ll]ooping*|*'repeating the same'*) reason=looping ;;
    *'declared pause'*|*'paused '*|*'waiting on human'*|*'awaiting external'*) reason=blocked ;;
    *)
      reason=stopped
      if [ "$task" != unknown ]; then
        last=$(last_status_line "$state/$task.status")
        verb=''
        [ -z "$last" ] || status_line_verb "$last" verb
        case "$verb" in
          done) reason=finished ;;
          failed) reason=failed ;;
          blocked|needs-decision|paused) reason=blocked ;;
        esac
      fi
      ;;
  esac
  printf '%s [task=%s reason=%s]' "$text" "$task" "$reason"
}

# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
