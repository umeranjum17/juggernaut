#!/usr/bin/env bash
# jg-captain-hold.sh - deterministic mechanics for tasks held for the captain.
#
# The semantic policy is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
# report, visual-review, chat, or terminal prose to guess whether the captain
# owes an answer. The invoking agent decides what is genuinely waiting on the
# captain; this script supplies guarded creation, a durable record of what the
# captain actually said, the investigation completion gate, and the one
# keyed-answer intake every channel feeds.
#
# There is no separate decision type. A captain call is an ordinary backlog
# task held for the captain through this script's mandatory `hold` subcommand,
# and its identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/jg-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog reads and mutations address the active home's configured data
# directory the way bin/jg-backlog-transition-lib.sh does, which keeps main-home
# and squad-lead-home ownership aligned with the work that discovered the call.
#
# Usage:
#   jg-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--priority 0-3] [--origin <origin-id>] [--until YYYY-MM-DD] \
#     [--must <category>]
#   jg-captain-hold.sh answer <task-id> --decision-file <path> [--release [--card <card-key>]]
#   jg-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance>   (keyed answers on stdin)
#   jg-captain-hold.sh reconcile-requests --source-id <source-id> --source <provenance>   (task ids on stdin)
#   jg-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   jg-captain-hold.sh unbind <source-id>
#   jg-captain-hold.sh binding <source-id>
#   jg-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   jg-captain-hold.sh verify <origin-id>
#   jg-captain-hold.sh answered <task-id>
#   jg-captain-hold.sh open <task-id> [--identity] [--distinguish-absent]
#   jg-captain-hold.sh blocking <task-id>
#   jg-captain-hold.sh design-card <card-key> --raised-by <ticket> --title <question>
#   jg-captain-hold.sh design-pick <card-key> --words <the captain's words>
#   jg-captain-hold.sh to-gates   (the pass that moves each old stamped owner hold to a gate, prints the count; a second run moves none)
#   jg-captain-hold.sh phase <task-id>
#   jg-captain-hold.sh reconcile list
#   jg-captain-hold.sh reconcile close <task-id> --evidence-file <path>
#   jg-captain-hold.sh reconcile note <task-id> --note-file <path>
#
# THE OWNER'S QUESTION IS A GATE. A `hold` that asks the owner something makes one human gate row that blocks the
# ticket (bin/jg-beads-write.py `gate`): its title is the question in a few words, its description the whole question,
# its metadata the `must`, the origin and the close mode. The ticket keeps its status, reads as held by the owner while
# the gate is open (and is dated and deferred with `--until`), and no list of work or count shows the gate;
# `jg-backlog.sh questions [--ticket <id>] [--due] [--all] [--json]` lists the questions. `answer` closes the gate
# with his whole words (`resolution` answered, or released with `--release`), then a ticket that was only the question;
# `--gate <id>` names one of several open gates. `reconcile close` closes it on evidence (`resolution` reconciled).
# `open`, `answered`, `blocking`, `phase` and `complete`/`verify` read the gate. `done` refuses a ticket with an open gate.
# No hold text goes into the description. What a stamp and a resolution block used to record is on the gate: the hold-set
# time is its `created_at`, the origin its `metadata.origin`, his words its `close_reason`, the mode its `metadata.resolution`.
# A parked hold, a stop order and the owner's own instruction are a plain hold: the status and its reason are the whole record.
# An old ticket that still carries a `Captain hold set:` stamp is read only by `to-gates`, which moves it to a gate.
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. `--must <category>` is the board gate
# (bin/jg-ask-gate-lib.sh): on the when-it-matters leash an armed sign-off card
# needs a must category, and a hold with none is refused and recorded for
# Overwatch (bin/jg-board-gate.sh route) instead of held. Creating a missing row uses
# `add --kind captain`: that kind is backlog metadata, and the Beads
# store keeps it as native issue type `decision`. Captain holds have no due
# semantics (`--until` is the optional hold deferral). A created task goes
# through `add`, so strict intake there (bin/jg-backlog.sh) reads its title and priority.
# Repeating an active hold makes no second gate, while re-holding released work
# starts a new lifecycle. A task already closed is refused rather than reopened.
# `--origin` records the origin in the gate's metadata, which `complete` and
# `verify` check. The reason may hold parentheses and line breaks.
# `--until` records the captain's own deferral date through `hold
# --until`, so a "revisit later" answer is stored as a date instead of a live
# card.
# When this home has armed the sign-off adapter, an undated `hold` also
# posts a sign-off board card keyed by this home's tag, the task id and the gate; the card goes through bin/jg-question-card.sh post, which owns what a
# board card is, or through core/signoff/bin/jg-procevent-signoff.sh when that
# installed adapter authors the ask itself,
# and a card it cannot post or raise fails the command (the hold stays recorded).
# A hold that is the captain's own instruction raises nothing at all: one whose
# hold kind is `parked`, or whose reason names a stop order or a branch we
# preserved instead of landing. Those records are his words, not a question back
# to him, so the hold is the whole result and no card and no Overwatch record are
# created for it (bin/jg-ask-gate-lib.sh owns the words).
#
# `answer` closes the ticket's open gate with the captain's exact words, whole (a non-empty decision file of at most
# 8192 bytes), then closes a ticket that was only the question with `done` - or, with `--release`, lifts the hold with
# `unhold` so a captain-gated WORK item resumes without closing. An exact retry finishes what the first call left
# undone and is idempotent; other words on an answered question are refused. A ticket with no gate is refused: there is
# no question to answer.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer resolves its matching captain-held task" is a single
# capability, owned here and nowhere else. `answers` reads
# `<key>\t<answer>\t<label>[\t<mode>]` lines on stdin and resolves each named
# question through the very same `answer` path above, so every guard applies
# identically no matter which channel the answer arrived on. The key is a
# question's gate id; a key that is a ticket id (a card posted before gates) resolves that ticket's one open
# question, and is refused naming both when the ticket has two. An answer with no words is refused. The close
# comes from the question's `close` unless the line names a mode. The optional fourth field selects the close:
# empty or `done` completes the task, `release` lifts the hold so held work
# resumes; anything else is skipped. A key that names no task, a task that is
# not held for the captain, or a task already closed is reported as `skipped:`
# and feeds nothing. A replayed delivery that matches the closed question's words
# is reported `closed:` and is a no-op. The command exits 3 when every skip was permanent
# (the reserved reconcile value, already closed, not held for the captain, or
# unknown close mode) and 1 for any other skip; the reserved
# reconcile value is refused for good, reported once on
# stderr, and counts as a permanent skip. `--source` is provenance text recorded in the
# durable decision, never a behavior switch: this command has no per-channel
# branch and no knowledge of chat, review decks, or any transport.
# Legacy input: an optional positional origin (or a stored concrete-origin
# binding) makes a key that names no task fall back to the old
# `<origin>-decision-<key>` identity, so an in-flight pre-collapse channel
# keeps closing its rows; `--any-origin` and the stored `(any)` marker mean
# what an absent origin means and are accepted for the same reason.
#
# RECONCILE IS RESERVED AT THIS INTAKE, NOT FILTERED IN A CHANNEL.
# The exact answer value `reconcile` means "go re-check reality", never "the
# captain answered". `answers` matches it before it reads the close mode,
# visibly refuses it, and never passes it to `answer`, so no channel and no
# card-declared mode can turn it into a close, release, or request. A separate
# `reconcile-requests` intake verifies a captured source's binding before it
# records a durable request under `state/reconcile-requests/`.
#
# `reconcile` is the verify-then-decide half. Both outcomes require the pending
# request created by the captain's board selection. `close` is the moot outcome:
# it requires the evidence that made the call moot, closes the gate with
# `Reconciliation evidence:` as its reason and `resolution` reconciled so it can never read as the
# captain's words, and closes the task. `note` is the still-active outcome: it
# appends one dated `Captain hold reconciled:` note and leaves the hold in
# place. A normal answer also retires the request because the call is settled.
# `list` is the read-only enumeration. On a question held as a gate, `note` adds the finding as a comment on the gate
# and the gate stays open; only a hold with no gate takes the dated note in its body.
# docs/captain-hold-lifecycle.md owns the semantics.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines
# and pipe them here. It must never map keys to tasks, build decision records,
# choose a close mode beyond what its card declared, or close anything itself.
#
# `bind`, `unbind`, and `binding` record that a captured-answer SOURCE feeds
# this intake, for any channel whose answers arrive detached from their origin
# (a process-event source id, for example). The binding is a private record
# under `state/decision-bindings/`; a source with no binding feeds nothing, so
# this whole path is opt-in per source and an unbound source behaves as if it
# did not exist. `bind` deliberately does not require the source to exist yet,
# so a channel can be bound BEFORE it is armed. The optional second argument
# exists only for legacy pre-collapse records and callers: a concrete origin is
# stored verbatim and used as the composition fallback above, and
# `--any-origin` stores the same `(any)` marker a plain `bind <source-id>`
# stores. `binding` prints the stored value verbatim and `answers` accepts it,
# so the process-event runner's feed seam is unchanged.
#
# `complete` is the shared investigation and visual-review completion gate.
# It attests, in the origin task's metadata, the reviewed inventory of
# captain-held tasks that carry the origin's unresolved captain calls.
# `--none` is an explicit semantic attestation that the just-reviewed surface
# has no unresolved captain call, and is refused while the origin still has an
# open keyed status decision. With a non-empty inventory, every listed task is
# verified durable (an entry is a gate id, or a ticket id that has a gate, open or
# answered; a ticket held for the owner with no gate counts too),
# is never the origin itself, and, when its gate's metadata names an origin, was held
# for this origin; a hold with no recorded origin is accepted on durability
# alone and named in the output,
# the inventory is unioned idempotently into the metadata, and every still-open
# keyed status decision is transferred to its durable owner with a
# `captain-held [key=...]` status close naming the inventory. Later review
# passes may add ids. A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still satisfy the same durability and origin checks as `complete`,
# and no keyed status decision may be open.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by jg-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task. On a Beads
# store an attested old id reaches its row through the name the provider's own
# `show` answers to, so no id here needs a second lookup.
#
# `open` is the read-only predicate a mechanical closer asks before it may
# retire a task's row: is this task still an open captain call? Exit 0 means it
# is (not Done, hold kind captain), 1 means it is not, and 2 means the answer
# could not be established, so a caller that must never close a live call can
# treat "cannot tell" as its own case instead of as a no. With
# `--distinguish-absent`, an absent local task returns 3 instead of 1; a home
# with no backlog file counts as absent, because it records no captain calls.
# It prints nothing on these predicate results and mutates nothing, unless
# `--identity` asks it to print this call's
# LIFECYCLE identity, which it does on an exit 0 only. That identity - the
# open gate's id, or for a plain hold a digest of its reason and date - is what distinguishes two
# successive calls on one task id: re-holding released work starts a new
# lifecycle without necessarily touching the task's status log, so a consumer
# that bounds repeated work per call cannot use the task id alone.
# bin/jg-teardown.sh asks it before its automatic
# backlog close and, on 0, returns the row to Queued with its deliverable
# recorded instead (bin/jg-backlog-transition-lib.sh owns that transition), so
# holding the very work item a question gates is safe; only `answer` with the
# captain's words or evidence-backed `reconcile close` closes the call.
# bin/jg-watch.sh asks it when an ordinary
# crew task reaches a due stale alarm - its open backlog hold need not appear in
# the task's last status line - and on a 0 bounds repeated alarms from new pane
# hashes for the decision.
#
# `blocking` is the read-only predicate bin/jg-spawn.sh (a ship start) and
# bin/jg-pr-merge.sh (a merge) ask: is a captain call open on this task or on
# any task linked to it, in either direction? A call is open when its task is
# held (`open`'s reading), or when it is a not-done `[design-ux]` ticket with no
# recorded pick, from the moment it is filed. A `[captain-ask]` ticket is an
# order, not a question: it counts only while held.
# Links are read one hop, live; only this home's backlog is seen. Exit 0 prints
# `<task-id><TAB><title>` per open call; 1 means none; 2 means it could not be
# established, which a caller must treat as a refusal.
#
# `design-card` and `design-pick` are the two ends of a design card, called by
# bin/jg-question-card.sh (post, --must design-pick) and bin/jg-board-answers.sh. The
# post makes one human gate on the raising ticket, with the card key in its metadata, so
# `blocking` finds it from that ticket; a card naming no raising ticket (or one this
# home lacks) is refused. The answer closes the gate with the captain's whole words.
#
# `answered` is the read-only predicate bin/jg-backlog.sh asks before it lets a
# `[captain-ask]` row leave the backlog: exit 0 when no gate of the ticket is open and one is closed with
# his words (a gate closed on evidence, `reconciled`, does not count),
# 1 when it does not, and any other non-zero status when the task cannot be read.
# It prints nothing.
#
# `phase` is the read-only word of the hold machine (core/machines/tables/hold.tsv):
# raised, deferred, answered, closed or none. An answer recorded and not yet completed
# is `answered`; a hold dated in the future is `deferred`; a settled call is `closed`.
#
# Parent channel: inside a squad_lead home a task held for the captain, and its
# answer, are captain-facing facts the moment they are recorded, so `hold`
# publishes `needs-decision [key=<gate id>]` and `answer` (and `answers`) the
# matching `resolved` line on the parent channel through
# bin/jg-parent-channel-lib.sh, whether or not the mate model appends anything.
# The key is the id of the question's gate, so the channel line and the gate are
# one decision and a released and re-held task opens and closes a distinct parent
# decision; an exact retry republishes the same line, which the channel
# deduplicates. A hold that makes no gate (a parked hold, a stop order) keeps the
# key `captain-hold-<task>-<n>`. A main home has no channel and publishes nothing.
# The hold or answer is already durable in the backlog, so a channel that
# cannot be written is reported as `actionable:` on stderr rather than undoing
# the record; bin/jg-inactive-reconcile.sh's diagnostics name a broken binding.
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

# shellcheck source=bin/jg-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-backlog-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-parent-channel-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"
# The one owner of a hold card's board key (bin/jg-question-lib.sh).
# shellcheck source=bin/jg-question-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=core/signoff/bin/jg-signoff-feedback-lib.sh
. "$SCRIPT_DIR/../core/signoff/bin/jg-signoff-feedback-lib.sh"

PARENT_HOLD_PUBLISHED=0
publish_parent_hold() {  # <task-id> <gate-id-or-empty> <occurrence> <verb> <note>
  local id=$1 key=$2 occurrence=$3 verb=$4 note=$5 rc=0
  [ -n "$key" ] || key=captain-hold-$id-$occurrence  # no gate: the call is no question the store keeps
  PARENT_HOLD_PUBLISHED=0
  jg_parent_channel_report "$JG_HOME" "$STATE" \
    "$verb [key=$key]: captain hold $id: $(jg_parent_channel_clean_note "$note")" || rc=$?
  case "$rc" in
    0|1) PARENT_HOLD_PUBLISHED=1 ;;
    *) printf 'actionable: task %s is held for the captain in this home but that did not reach the parent channel (rc=%s)\n' "$id" "$rc" >&2 ;;
  esac
}

# --- the hold's board card ---------------------------------------------------
# One posting path for a card: bin/jg-question-card.sh post. This holds the board
# rules, the ask gate, the must category beside the board and the captain channel
# event, so the words below are the hold's own and the posting is not.
ANSWER_NOTE='Answer yes or no. The hold stays open until you answer.'

# Card text per sign-off's question standard.
strip_tags() {
  local s=$1 prev=
  while [ "$s" != "$prev" ]; do
    prev=$s
    s=$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(\[[^]]*\]|[Cc][Aa][Pp][Tt][Aa][Ii][Nn] [Hh][Oo][Ll][Dd]:|[Cc][Aa][Pp][Tt][Aa][Ii][Nn]:|[Ss][Aa][Yy] [Yy][Ee][Ss] [Oo][Rr] [Nn][Oo]:)[[:space:]]*//')
  done
  printf '%s' "$s"
}

card_flat() {
  printf '%s' "$1" | tr '\t\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

card_title() {  # <reason>; prints the last question sentence, or the first sentence when it has none; empty when nothing is left
  local flat head sentence
  flat=$(card_flat "$1")
  head=$(printf '%s' "$flat" | sed -nE 's/^(.*\?)( |$).*/\1/p')
  if [ -n "$head" ]; then
    sentence=$(printf '%s' "${head%\?}" | sed -E 's/^(.*(\. |\? ))?//')
  else
    sentence=$(printf '%s' "$flat" | sed -E 's/[.!] .*$//')
  fi
  title=$(strip_tags "$sentence" | sed -E 's/[[:space:].?!]+$//' | awk '{n = NF < 12 ? NF : 12; for (i = 1; i <= n; i++) printf "%s%s", $i, i < n ? " " : ""}')
  [ -n "$title" ] && printf '%s?' "$title"
  return 0
}

card_why() {  # <reason>
  printf '%s %s' "$(card_flat "$1" | cut -c1-$((200 - ${#ANSWER_NOTE} - 1)))" "$ANSWER_NOTE"
}

built_title() {  # <task-title>
  local words
  words=$(strip_tags "$(card_flat "$1")" | tr -d '?' | awk '{n = NF < 6 ? NF : 6; for (i = 1; i <= n; i++) printf "%s%s", $i, i < n ? " " : ""}')
  printf 'What is your call on %s?' "$words"
}

# Post the hold's card through the one card path. <must> is the board gate's
# category (empty when the hold carries none). Returns nonzero when the card was
# not posted, so the caller fails the command and the hold stays recorded.
raise_hold_card() {  # <task-id> <task-title> <reason> <done|release> <must>
  local id=$1 task_title=$2 reason=$3 close=$4 must=$5
  local title key identity ticket='' out
  title=$(card_title "$reason")
  [ -n "$title" ] || title=$(built_title "$task_title")
  identity=$("$SCRIPT_DIR/jg-captain-hold.sh" open "$id" --identity 2>/dev/null) || {
    printf 'the hold identity of %s could not be read\n' "$id" >&2
    return 1
  }
  key=$(jg_question_hold_card_key "$id" "$identity")
  # Name the ticket the board shows, so the reason this hold records renders
  # beside that ticket's On hold row (bin/jg-ticket.sh owns the ticket id).
  ticket=$("$SCRIPT_DIR/jg-ticket.sh" id "$id" 2>/dev/null) || ticket=''
  out=$("$SCRIPT_DIR/jg-question-card.sh" post \
    --route main \
    --ask-ref "$id" --key "$key" --title "$title" --about "$reason" --why "$(card_why "$reason")" \
    ${must:+--must "$must"} ${ticket:+--ticket "$ticket"} --filer captain-hold \
    --outcome yes="Answer recorded: yes." \
    --outcome no="Answer recorded: no." \
    --recommend yes --recommend-reason "The hold records no recommendation." \
    --default no --close "$close") || {
    printf 'the board card was not posted for %s\n' "$id" >&2
    return 1
  }
  printf 'board card %s posted for %s\n' "$out" "$id" >&2
  return 0
}

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
CAPTAIN_CONTROL_LOCK=
CAPTAIN_CONTROL_LOCK_HELD=0
captain_hold_cleanup() {
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    jg_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
  fi
  if [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ]; then
    jg_lock_release "$CAPTAIN_CONTROL_LOCK" || true
    CAPTAIN_CONTROL_LOCK_HELD=0
  fi
}
trap captain_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'jg-captain-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

acquire_task_control_lock() {  # <task-id>
  CAPTAIN_CONTROL_LOCK="$STATE/.control-$1.lock"
  jg_lock_acquire_wait "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=1
}

release_task_control_lock() {
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] || return 0
  jg_lock_release "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=0
  CAPTAIN_CONTROL_LOCK=
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

# The legacy derived identity older installs minted for a captain call.
# Kept only to resolve pre-collapse rows, metadata entries, and channel keys.
legacy_hold_id() {  # <origin-id> <key>
  printf '%s-decision-%s' "$1" "$2"
}

# The legacy any-origin binding marker. Slug validation rejects parentheses, so
# no real origin id or task id can collide with it.
BINDING_ANY='(any)'

DECISION_TEXT=''
DECISION_DIGEST=''

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

# Mutations address this home's Beads store, named by config/beads-dir.
backlog_cmd() {
  local data
  data=$(jg_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  jg_backlog_beads_serve "$(jg_backlog_config_of "$data")" "$@"
}

# shellcheck source=bin/jg-captain-ask-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-captain-ask-lib.sh"
require_backlog() {
  jg_backlog_beads_store "$(jg_backlog_config_of "$(jg_backlog_data_absolute "$DATA")")" >/dev/null || exit 2
}

# Read one row into TASK_SHOW_OUTPUT; a non-zero return means the row is
# absent. A read that could not finish inside its bound is NOT absence, and
# every caller below would otherwise spend it as one - minting a duplicate task,
# skipping a keyed answer, or reporting a task that exists as missing. So the
# bound's own status stops the command instead, loudly and by name, and it
# leaves 124 intact rather than collapsing to fail's 1 so a caller running this
# inside a command substitution can still tell a wedged backend from a
# genuinely unknown id.
TASK_SHOW_OUTPUT=
task_show() {  # <id>; sets TASK_SHOW_OUTPUT
  local data status=0 reason
  data=$(jg_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  TASK_SHOW_OUTPUT=$(jg_backlog_row_show "$data" "$1" --full 2>/dev/null) || status=$?
  if [ "$status" -eq 124 ]; then
    reason=${TASK_SHOW_OUTPUT%%$'\n'*}
    printf 'jg-captain-hold: %s\n' \
      "${reason:-backlog show $1 exceeded its backlog read bound}" >&2
    exit 124
  fi
  return "$status"
}

# Read one row into `show`, failing with <absence-message> only when the read
# genuinely failed; a read-bound hit (124) stops the command by name instead.
# task_show must be called in THIS shell, not inside a command substitution:
# it carries the row in TASK_SHOW_OUTPUT, which a subshell cannot hand back.
task_show_or_fail() {  # <id> <absence-message>; sets show
  task_show "$1" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $1"
    fail "$2"
  }
  show=$TASK_SHOW_OUTPUT
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# A shown scalar field arrives as a JSON-encoded bare string, which decode_json
# accepts only where the installed JSON::PP defaults allow_nonref on. Older
# libraries default it off and reject the whole value as "must be object or
# array", so ask for it explicitly rather than inheriting the local default.
decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
show_field_value() {  # <show-output> <field>
  local value
  value=$(decode_shown_value "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1"
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Resolve one inventory entry or channel key to the task that carries it: the exact task id when it exists, else the
# ticket a gate id belongs to, else the legacy derived identity. Prints "<resolved id> <how>", where <how> is exact,
# gate or legacy, so a caller can record which evidence carried the attestation.
resolve_entry() {  # <origin-or-empty> <entry>; prints "<id> <how>" or fails
  local origin=$1 entry=$2 legacy ticket
  if task_show "$entry"; then
    printf '%s exact' "$entry"
    return 0
  fi
  ticket=$(backlog_cmd questions --json --all | jq -r --arg g "$entry" '.[] | select(.id == $g and .ticket != "-") | .ticket' | head -1)
  if [ -n "$ticket" ]; then
    printf '%s gate' "$ticket"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if task_show "$legacy"; then
      printf '%s legacy' "$legacy"
      return 0
    fi
    fail "no captain-held task or question $entry in this home's configured backlog (data directory $DATA); the nearest legacy identity $legacy also resolves to nothing"
  fi
  fail "no captain-held task or question $entry in this home's configured backlog (data directory $DATA)"
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}

# The origin a hold was recorded for lives in the held task's own body, on a
# line of its own, so `complete` can tell a call held for this origin from one
# held for another. Omitting --origin leaves any existing association intact.
body_hold_origin() {  # <decoded-task-body>
  printf '%s\n' "$1" | sed -n 's/^Captain hold origin: \(.*\)$/\1/p' | head -1
}

task_identity() {
  local id=$1
  if task_show "$id"; then
    id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
    validate_slug backend-task-id "$id"
  elif ! printf '%s\n' "$TASK_SHOW_OUTPUT" | grep -q '^code: NOT_FOUND$'; then
    fail "could not resolve the backend identity of $id"
  fi
  printf '%s' "$id"
}

refuse_self_inventory() {
  local origin=$1 entry=$2 meta="$STATE/$1.meta"
  if list_has_key "$(meta_value "$meta" decision_keys)" "$entry"; then
    fail "origin $origin cannot be its own captain-call inventory entry; historical decision_keys in $meta still contains $entry; hold a separate captain task with --origin $origin, replace only $entry in the final decision_keys= line with that task id while preserving all other entries, then re-run complete $origin <task-id>"
  fi
  fail "origin $origin cannot be its own captain-call inventory entry; hold a separate captain task for the call and list that task"
}

# Resolve one entry and verify the ticket it names still carries its owner call. The call is durable while its gate
# exists, open or answered, or while the ticket is held for the owner with no gate (his own instruction). The origin
# is read from the gate's metadata. A resolution failure that is not the read bound keeps resolve_entry's own status -
# its stderr already named the entry; 124 means the backend never answered, which is not the same as an unknown entry
# and must not be spent as absence. The result says whether an origin was recorded, so completion can disclose it.
verify_entry_durable() {  # <origin-or-empty> <entry>; prints "<id> <how> <origin-state>"
  local origin=$1 entry=$2 resolved resolve_status=0 id how stored origin_id stored_id origin_state=unrecorded gates
  # The origin task is never its own captain-call inventory: it is the work the
  # calls were found in, so accepting it would let a refused hold look recorded.
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ] && [ "$entry" = "$origin" ]; then
    refuse_self_inventory "$origin" "$entry"
  fi
  resolved=$(resolve_entry "$origin" "$entry") || resolve_status=$?
  if [ "$resolve_status" -ne 0 ]; then
    [ "$resolve_status" -ne 124 ] \
      || fail "the backlog backend exceeded its read bound resolving $entry"
    exit "$resolve_status"
  fi
  id=${resolved%% *}
  how=${resolved##* }
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  gates=$(gate_rows "$id" --all)
  if [ -z "$gates" ] && { [ "$(show_field "$TASK_SHOW_OUTPUT" state)" = "done" ] || [ "$(show_field_value "$TASK_SHOW_OUTPUT" hold_kind)" != captain ]; }; then
    fail "captain-held task $id is neither held for the captain nor closed with a recorded captain answer"
  fi
  id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
  validate_slug backend-task-id "$id"
  stored=$(printf '%s\n' "$gates" | jq -r 'select(.origin != "-") | .origin' | head -1)
  origin_id=$origin
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    origin_id=$(task_identity "$origin") || exit $?
    [ "$id" != "$origin_id" ] || refuse_self_inventory "$origin" "$entry"
  fi
  if [ -n "$stored" ]; then
    if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
      stored_id=$(task_identity "$stored") || exit $?
      if [ "$stored_id" != "$origin_id" ]; then
        fail "captain-held task $id was held for origin $stored, not $origin; hold a task for $origin or list the right one"
      fi
    fi
    origin_state=recorded
  fi
  printf '%s %s %s\n' "$id" "$how" "$origin_state"
}

# The hold machine's move log (core/machines/tables/hold.tsv): a writer reports the move it made, with its time, to
# bin/jg-machine-guard.sh. A report never fails the writer, and a move to the state it is already in is no move.
hold_word() {  # <task-id>; the machine's word for the task now, or - when it has no hold
  local word
  word=$(command_phase "$1" 2>/dev/null) || word=''
  case "$word" in raised|deferred|answered|closed) printf '%s\n' "$word" ;; *) printf -- '-\n' ;; esac
}

report_hold_move() {  # <task-id> <from-word-or--> <to-word>
  [ "$2" != "$3" ] || return 0
  "$SCRIPT_DIR/jg-machine-guard.sh" edge hold "$2" "$3" "$1" >/dev/null 2>&1 || true
}

# --- the owner's question as a gate ------------------------------------------
# A hold that asks the owner something is one human gate row that blocks the ticket (bin/jg-beads-write.py
# `gate`), and his answer closes the gate with his words. A parked hold, a stop order, and a ticket still
# carrying an old hold-set stamp keep the stamped path below until the pass that moves them.
gate_rows() {  # <ticket> [--all]: the ticket's questions, one JSON record per line (open ones unless --all)
  local rows
  rows=$(backlog_cmd questions --ticket "$1" --json "${@:2}") || fail "the questions on $1 could not be read"
  printf '%s' "$rows" | jq -c '.[]'
}

open_gate_ids() {  # <ticket>
  gate_rows "$1" | jq -r '.id'
}

# Make the gate, and defer the ticket to its date when the owner said "ask me again later".
HELD_GATE=''  # the id of the gate hold_by_gate made or found: the key the parent channel carries
hold_by_gate() {  # <task-id> <task-title> <reason> <until> <must> <origin> <done|release>
  local id=$1 reason=$3 until=$4 must=$5 origin=$6 title
  title=$(card_title "$reason")
  [ -n "$title" ] || title=$(built_title "$2")
  HELD_GATE=$(backlog_cmd gate "$id" --title "$title" --reason "$reason" --close "$7" ${must:+--must "$must"} ${origin:+--origin "$origin"}) \
    || fail "could not make the owner's question on task $id"
  if [ -n "$until" ]; then
    backlog_cmd hold "$id" --reason "$reason" --kind captain --until "$until" >/dev/null \
      || fail "could not defer task $id to $until"
  fi
  jg_backlog_ticket_note "$DATA" hold "$id" --reason "$reason"
}

command_hold() {
  local id=${1:-} priority='' title='' reason='' repo='' origin='' until='' show state existing_title body='' occurrence held_from
  local signoff_script existing_hold_kind='' existing_held='' preserve_hold=0 card_close=release must='' refusal rec own_instruction='' raise_rc=0
  HELD_GATE=''
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --priority) shift; priority=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      --must) shift; must=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  # A hold carries a reason, in words a reader can act on: the board renders it
  # beside the ticket, so a blank one is refused before anything is recorded.
  if [ -z "${reason//[[:space:]]/}" ]; then
    fail 'hold needs --reason "<what the captain has to decide>"; nothing was recorded'
  fi
  if [ -n "$origin" ]; then
    validate_slug origin-id "$origin"
  fi
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) fail "--until must be a YYYY-MM-DD date: $until" ;;
    esac
  fi
  # A hold that is our own parked work, his own stop order, or a branch we
  # preserved instead of landing is his instruction, so it records the hold and
  # raises nothing: no card reaches him and no ask goes to Overwatch either
  # (bin/jg-ask-gate-lib.sh owns the words that say so).
  own_instruction=''
  if jg_ask_own_instruction "$reason"; then
    own_instruction=1
  elif jg_backlog_row_probe "$DATA" "$id" && [ "$JG_BACKLOG_ROW_HOLD_KIND" = parked ]; then
    own_instruction=1
  fi
  # The board gate before anything is recorded: an ask that is not a must never
  # becomes a captain hold card while the leash is when-it-matters; it becomes an
  # Overwatch record Main answers (bin/jg-ask-gate-lib.sh owns the list and words).
  # core/signoff owns the card: it authors the owner-must class itself, decides
  # whether the home is armed, and refuses an ask it cannot author. The older
  # bin/jg-procevent-signoff.sh remains the board's answer intake.
  # JG_SIGNOFF_SCRIPT names another card path, a test seam.
  signoff_script=${JG_SIGNOFF_SCRIPT:-$SCRIPT_DIR/../core/signoff/bin/jg-procevent-signoff.sh}
  if [ -z "$own_instruction" ] && [ "$signoff_script" = "$SCRIPT_DIR/jg-procevent-signoff.sh" ] && [ -z "$until" ] \
    && [ -f "$STATE/procevent/signoff.source" ] && ! refusal=$(jg_ask_gate_refusal "$must"); then
    rec=$("$SCRIPT_DIR/jg-board-gate.sh" route --title "${title:-$reason}" --filer captain-hold --ref "$id" 2>&1) || rec=''
    printf '%s\n' "$refusal" >&2
    [ -z "$rec" ] || printf 'recorded for Overwatch: %s\n' "${rec#overwatch: }" >&2
    exit 1
  fi
  acquire_task_control_lock "$id"
  require_backlog
  held_from=-
  if task_show "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    existing_hold_kind=$(show_field_value "$show" hold_kind)
    [ "$existing_hold_kind" != captain ] || held_from=$(hold_word "$id")
    existing_held=$(show_field_value "$show" held)
    if [ "$existing_hold_kind" = captain ] && [ "$existing_held" = yes ]; then
      preserve_hold=1
    fi
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
  else
    [ -n "$title" ] || fail "--title is required to create task $id"
    card_close='done'
    validate_one_line title "$title"
    if [ -z "$repo" ] && [ -n "$origin" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=juggernaut
    validate_one_line repo "$repo"
    [ -z "$origin" ] || body=$(printf 'Origin: %s' "$origin")
    # --kind captain is Beads native type decision.
    if [ -n "$body" ]; then
      backlog_cmd add "$id" "$title" --kind captain --repo "$repo" ${priority:+--priority "$priority"} --body "$body" >/dev/null \
        || fail "could not create task $id"
    else
      backlog_cmd add "$id" "$title" --kind captain --repo "$repo" ${priority:+--priority "$priority"} >/dev/null \
        || fail "could not create task $id"
    fi
  fi
  task_show_or_fail "$id" "task $id disappeared before holding it"
  if [ -z "$own_instruction" ]; then
    [ -z "$origin" ] || origin=$(task_identity "$origin") || exit $?
    hold_by_gate "$id" "$(show_field_value "$show" title)" "$reason" "$until" "$must" "$origin" "$card_close"
    occurrence=$(gate_rows "$id" --all | wc -l)
  else
    # His own instruction is a plain hold: the status and its reason are the whole record, and no text goes into the
    # description. A re-hold of a held ticket keeps the hold and starts no second one.
    if [ "$preserve_hold" = 0 ]; then
      backlog_cmd hold "$id" --reason "$reason" --kind captain ${until:+--until "$until"} >/dev/null \
        || fail "could not hold task $id for the captain"
      jg_backlog_ticket_note "$DATA" hold "$id" --reason "$reason"
    fi
    task_show "$id" || fail "task $id disappeared while holding it"
    [ "$(show_field_value "$TASK_SHOW_OUTPUT" hold_kind)" = captain ] || fail "task $id did not retain its captain hold"
    occurrence=1
  fi
  publish_parent_hold "$id" "$HELD_GATE" "$occurrence" needs-decision "$reason"
  # A call is raised first and deferred by its date, so a new dated hold reports both moves.
  [ "$held_from" != - ] || { report_hold_move "$id" - raised; held_from=raised; }
  if [ -n "$until" ] && [[ "$until" > "$(date -u +%F)" ]]; then report_hold_move "$id" "$held_from" deferred; else report_hold_move "$id" "$held_from" raised; fi
  # Optional sign-off card, raised only while the sign-off adapter is armed here.
  # core/signoff owns the card when it is installed and authors the ask itself;
  # the answer-intake adapter this repo also ships (bin/jg-procevent-signoff.sh)
  # carries no raise, so that case posts through bin/jg-question-card.sh post, the
  # one card path. A created question closes on answer, held work is released; a
  # dated deferral gets no live card, and a card failure exits nonzero (the hold
  # stays recorded).
  if [ -z "$until" ]; then
    release_task_control_lock
  fi
  if [ -z "$until" ] && [ -z "$own_instruction" ]; then
    if [ -f "$STATE/procevent/signoff.source" ]; then
      if [ "$signoff_script" = "$SCRIPT_DIR/jg-procevent-signoff.sh" ]; then
        # That adapter carries the answer intake only, so the card goes through
        # the one card path instead of a raise it no longer has.
        raise_hold_card "$id" "$(show_field_value "$show" title)" "$reason" "$card_close" "$must" \
          || { printf 'error: task %s is held, but no board card was posted for it\n' "$id" >&2; exit 1; }
      else
        # The installed adapter takes exactly these four arguments and authors its
        # own must class (core/signoff raise), so --must is never passed to it.
        # Exit 3 is the adapter saying the hold is a direction with no question for
        # the captain: no card is the right result, so the recorded hold is a success.
        raise_rc=0
        JG_HOME=$JG_HOME JG_CODE_ROOT=${JG_CODE_ROOT:-$SCRIPT_DIR/..} "$signoff_script" raise "$id" "$(show_field_value "$show" title)" "$reason" "$card_close" \
          || raise_rc=$?
        if [ "$raise_rc" -ne 0 ] && [ "$raise_rc" -ne 3 ]; then
          printf 'error: task %s is held, but no sign-off card was raised for it\n' "$id" >&2
          exit 1
        fi
      fi
    fi
  fi
  printf '%s\n' "$id"
}

report_retained_artifact_failure() {  # <task-id> <marker-path>
  printf 'jg-captain-hold: cannot apply the artifact recorded for %s in %s: %s\n' \
    "$1" "$2" "${JG_BACKLOG_TRANSITION_ERROR:-no reason reported}" >&2
}

apply_pending_retained_artifact() {  # <task-id>
  local id=$1 marker
  local -a args=()
  RETAINED_CLOSE_ARGS=()
  marker=$(jg_backlog_close_marker_path "$STATE" "$id") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  jg_backlog_close_marker_validate "$marker" "$DATA" "$id" "$STATE" \
    || { report_retained_artifact_failure "$id" "$marker"; return 1; }
  [ "$JG_BACKLOG_CLOSE_VALIDATED_MODE" = retain ] || return 0
  args=("${JG_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${JG_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  case "${args[0]-}" in
    --pr|--report)
      if [ "${args[0]}" = --pr ] && jg_backlog_pr_is_gerrit_change "${args[1]-}"; then
        RETAINED_CLOSE_ARGS=(--note "Gerrit change ${args[1]}")
        return 0
      fi
      jg_backlog_row_artifact_supported "$id" "${args[@]}" || return 0
      jg_backlog_mutate "$DATA" update "$id" "${args[@]}" \
        || { report_retained_artifact_failure "$id" "$marker"; return 1; }
      ;;
  esac
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    backlog_cmd unhold "$1" >/dev/null && jg_backlog_ticket_note "$DATA" unhold "$1"
  else
    apply_pending_retained_artifact "$1" || return 1
    backlog_cmd "done" "$1" "${RETAINED_CLOSE_ARGS[@]+"${RETAINED_CLOSE_ARGS[@]}"}" >/dev/null \
      && jg_backlog_ticket_note "$DATA" "done" "$1" "${RETAINED_CLOSE_ARGS[@]+"${RETAINED_CLOSE_ARGS[@]}"}"
  fi
}

# A release from a board answer tells the owner what started: one reply on the
# card (sign-off-axi feedback --reply, 500 characters at most). A feedback
# failure is said on stderr and never fails the release.
reply_release() {  # <task-id> <title> <card-key>
  local board text rc=0
  [ -n "$3" ] && jg_question_signoff_available || return 0
  board=$(jg_question_board)
  text="Released $1: $(sanitize_field "$2")"
  jg_signoff_feedback "$3" ${board:+"$board"} --reply "${text:0:500}" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || printf 'the release of %s was not reported on card %s\n' "$1" "$3" >&2
  return 0
}

# The owner's answer to a question held as a gate: his words close the gate whole, and then a ticket that was only
# the question closes too (--release leaves it open and lifts a date it was deferred to). An exact retry finishes
# what the first call left undone; a different answer to an answered question is refused.
write_gate_approval() {  # <task-id> <show-output>
  local id=$1 line body tmp
  line=$(captain_ask_approval_line "$id" "answer:$DECISION_DIGEST")
  body=$(decode_shown_value "$(show_field "$2" body)") || fail "could not decode the body of $id"
  case "$body" in *"$line"*) return 0 ;; esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-captain-hold-body.XXXXXX") || fail "cannot stage the approval for $id"
  printf '%s\n' "${body:+$body$'\n\n'}$line" > "$tmp"
  backlog_cmd update "$id" --body-file "$tmp" --archive-body >/dev/null \
    || { rm -f -- "$tmp"; fail "could not record the captain decision on $id"; }
  rm -f -- "$tmp"
}

answer_by_gate() {  # <task-id> <release-0-or-1> <card-key> <gate-id-or-empty> <show-output>
  local id=$1 release=$2 card=$3 gate=$4 show=$5 outcome=answered gates open row shut occurrence from until tmp title
  [ "$release" = 0 ] || outcome=released
  gates=$(gate_rows "$id" --all)
  open=$(printf '%s\n' "$gates" | jq -r 'select(.state == "open") | .id')
  if [ -z "$gate" ]; then
    [ "$(printf '%s' "$open" | grep -c .)" -le 1 ] \
      || fail "task $id has several open questions ($(printf '%s' "$open" | tr '\n' ' ')); name one with --gate <id>"
    gate=$open
  fi
  if [ -z "$gate" ]; then  # none open: the last answer given in these words is the one a retry means
    gate=$(printf '%s\n' "$gates" | jq -rs --arg w "$DECISION_TEXT" '[.[] | select(.words == $w)] | last | .id // empty')
  fi
  [ -n "$gate" ] || fail "the question on task $id was already answered; a second answer does not replace the first"
  row=$(printf '%s\n' "$gates" | jq -c --arg g "$gate" 'select(.id == $g)')
  [ -n "$row" ] || fail "task $id has no question $gate"
  shut=$(printf '%s' "$row" | jq -r 'select(.state == "closed") | .words')
  if [ -n "$(printf '%s' "$row" | jq -r 'select(.state == "closed") | .id')" ] && [ "$shut" != "$DECISION_TEXT" ]; then
    fail "the question $gate on task $id was already answered; a second answer does not replace the first"
  fi
  occurrence=$(printf '%s\n' "$gates" | jq -rs '[.[] | select(.state == "closed")] | length')
  from=raised
  until=$(show_field_value "$show" hold_until)
  if [ -n "$until" ] && [[ "$until" > "$(date -u +%F)" ]]; then from=deferred; fi
  if [ -z "$(printf '%s' "$row" | jq -r 'select(.state == "closed") | .id')" ]; then
    occurrence=$((occurrence + 1))
    write_gate_approval "$id" "$show"
    [ "$release" = 1 ] || report_hold_move "$id" "$from" answered
    tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-captain-hold-words.XXXXXX") || fail "cannot stage the captain decision"
    printf '%s' "$DECISION_TEXT" > "$tmp"
    backlog_cmd resolve "$gate" --words-file "$tmp" --resolution "$outcome" >/dev/null \
      || { rm -f -- "$tmp"; fail "could not close the question $gate on task $id"; }
    rm -f -- "$tmp"
  fi
  task_show_or_fail "$id" "task $id disappeared after answering it"
  show=$TASK_SHOW_OUTPUT
  title=$(show_field_value "$show" title)
  if [ "$release" = 1 ]; then
    # A date the ticket was deferred to is lifted; a ticket held for another reason keeps its hold.
    if [ "$(show_field_value "$show" held)" = yes ] && [ "$(show_field_value "$show" hold_kind)" = captain ]; then
      close_answered "$id" 1 || fail "could not release task $id"
    fi
    report_hold_move "$id" "$from" closed
  else
    if [ "$(show_field "$show" state)" != "done" ]; then
      close_answered "$id" 0 || fail "could not close answered captain-held task $id"
    fi
    report_hold_move "$id" answered closed
  fi
  publish_parent_resolution_then_retire "$id" "$gate" "$occurrence" "$outcome"
  [ "$release" = 0 ] || reply_release "$id" "$title" "$card"
  printf '%s: %s\n' "$outcome" "$id"
}

command_answer() {
  local id=${1:-} decision_file='' release=0 card='' show hold_kind gate=
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --release) release=1 ;;
      --card) shift; card=${1:-}; validate_slug card-key "$card" ;;
      --gate) shift; gate=${1:-}; validate_slug gate-id "$gate" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  load_decision "$decision_file"
  acquire_task_control_lock "$id"
  require_backlog
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  show=$TASK_SHOW_OUTPUT
  hold_kind=$(show_field_value "$show" hold_kind)
  if [ "$release" = 1 ] && [ -z "$card" ] && [ "$hold_kind" = captain ]; then
    card=$(jg_question_hold_card_key "$id" "$("$SCRIPT_DIR/jg-captain-hold.sh" open "$id" --identity 2>/dev/null)") || card=''
  fi
  [ -n "$(gate_rows "$id" --all)" ] || fail "task $id has no question to the owner; hold it first or name the right task"
  answer_by_gate "$id" "$release" "$card" "$gate" "$show"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=jg-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The stored binding value, or empty when the source is unbound. An unreadable
# or wrong-schema record is a hard error rather than a silent "unbound":
# feeding nothing is the safe direction only when it is a deliberate choice,
# never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  jg_compat_record_ok "$schema" "$BINDING_SCHEMA" "$(jg_compat_legacy_of "$BINDING_SCHEMA")" \
    || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  if [ "$origin" != "$BINDING_ANY" ]; then
    case "$origin" in
      ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
    esac
  fi
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  if [ -z "$origin" ] || [ "$origin" = --any-origin ]; then
    origin=$BINDING_ANY
  else
    validate_slug legacy-origin "$origin"
  fi
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <task-id> <answer> <label>
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

sanitize_reconcile_provenance() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1024
}

gate_row_of() {  # <key>: the question record whose id is the key, or nothing when the key is no question
  backlog_cmd questions --all --json 2>/dev/null | jq -c --arg k "$1" '.[] | select(.id == $k)' 2>/dev/null
}

# A keyed answer whose key is a question's own id: the question's ticket takes the answer, closed the way the question
# says (`close` on the gate, unless the line names a mode), and the same `answer` path writes his words on the gate.
answer_gate_key() {  # <key> <source> <answer> <label> <mode> <decision-tmp> <err-tmp>; prints closed:/skipped:
  local key=$1 row ticket close reason release_flag=''
  row=$(gate_row_of "$key")
  ticket=$(jq -r '.ticket' <<<"$row")
  close=${5:-$(jq -r '.close' <<<"$row")}
  case "$close" in release) release_flag=--release ;; ''|-|done) : ;; *)
    printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$close")"; return 1 ;;
  esac
  keyed_decision_text "$2" "$ticket" "$3" "$4" > "$6" || fail "cannot stage the captain decision for $key"
  # shellcheck disable=SC2086  # release_flag is empty or a single literal flag.
  if "$0" answer "$ticket" --gate "$key" --decision-file "$6" $release_flag ${release_flag:+--card "$key"} </dev/null >/dev/null 2>"$7"; then
    [ ! -s "$7" ] || cat "$7" >&2
    printf 'closed: %s\n' "$key"
    return 0
  fi
  reason=$(tr -d '\n' < "$7" | sed 's/^jg-captain-hold: //')
  printf 'skipped: %s (%s)\n' "$key" "$reason"
  return 1
}

command_answers() {
  local origin='' source='' row rest key answer label mode id show state hold_kind
  local tmp err closed=0 skipped=0 permanent=0 reason release_flag tab=$'\t'
  local resolve_rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      --any-origin) origin=$BINDING_ANY ;;
      --*) usage >&2; exit 2 ;;
      *)
        [ -z "$origin" ] || { usage >&2; exit 2; }
        origin=$1
        ;;
    esac
    shift
  done
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    validate_slug legacy-origin "$origin"
  fi
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_backlog
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS= read -r row; do
    key=${row%%"$tab"*}
    rest=''
    case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; esac
    answer=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    label=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) mode=${rest#*"$tab"} ;; *) mode='' ;; esac
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    if [ -z "$answer" ]; then
      printf 'refused: %s (an answer needs his words)\n' "$key" >&2
      skipped=$((skipped + 1)); permanent=$((permanent + 1))
      continue
    fi
    label=$(sanitize_field "${label:-}")
    if [ "$answer" = "$RECONCILE_VALUE" ]; then
      printf 'refused: %s (reconcile requests require a bound captured source)\n' "$key" >&2
      skipped=$((skipped + 1)); permanent=$((permanent + 1))
      continue
    fi
    release_flag=''
    case "${mode:-}" in
      ''|done) : ;;
      release) release_flag=--release ;;
      *)
        printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$mode")"
        skipped=$((skipped + 1)); permanent=$((permanent + 1))
        continue
        ;;
    esac
    resolve_rc=0
    id=$(resolve_entry "$origin" "$key" 2>"$err") || resolve_rc=$?
    # A gate id names the question, not its ticket: it closes that gate and reports the gate.
    case "$id" in *' gate') resolve_rc=1; id='' ;; esac
    id=${id%% *}
    if [ "$resolve_rc" -ne 0 ]; then
      # resolve_entry runs in a command substitution, so task_show's exit
      # cannot stop this loop; only its status crosses back. 124 means the
      # backend never answered, which is not the same as an unknown key and
      # must not be spent as a skip.
      [ "$resolve_rc" -ne 124 ] \
        || fail "the backlog backend exceeded its read bound resolving $key"
      if [ -n "$(gate_row_of "$key")" ]; then
        answer_gate_key "$key" "$source" "$answer" "$label" "$mode" "$tmp" "$err" && closed=$((closed + 1)) || skipped=$((skipped + 1))
        continue
      fi
      printf 'skipped: %s (no captain-held task with that id)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    if [ -z "${mode:-}" ] && [ "$(gate_rows "$id" 2>/dev/null | jq -rs 'if length == 1 then .[0].close else "" end')" = release ]; then
      release_flag=--release  # the one open question says it releases
    fi
    keyed_decision_text "$source" "$id" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $id"
    task_show "$id" || { printf 'skipped: %s (absent)\n' "$id"; skipped=$((skipped + 1)); continue; }
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    # A ticket whose question is answered and closed takes an exact retry through `answer`, which replays it or refuses it.
    if [ "$state" = "done" ] && [ -z "$(gate_rows "$id" --all)" ]; then
      printf 'skipped: %s (already closed)\n' "$id"
      skipped=$((skipped + 1)); permanent=$((permanent + 1))
      continue
    fi
    if [ "$state" != "done" ] && [ "$hold_kind" != captain ] && [ -z "$(gate_rows "$id" --all)" ]; then
      printf 'skipped: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1)); permanent=$((permanent + 1))
      continue
    fi
    # shellcheck disable=SC2086  # release_flag is empty or a single literal flag.
    if "$0" answer "$id" --decision-file "$tmp" $release_flag ${release_flag:+--card "$key"} </dev/null >/dev/null 2>"$err"; then
      # A parent-channel delivery problem is reported on stderr by the answer
      # path even when the close succeeded; keep it visible.
      [ ! -s "$err" ] || cat "$err" >&2
      printf 'closed: %s\n' "$id"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^jg-captain-hold: //')
      printf 'skipped: %s (%s)\n' "$id" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s\n' "$closed" "$skipped"
  [ "$skipped" -eq 0 ] && return 0
  [ "$skipped" -eq "$permanent" ] && return 3
  return 1
}

# --- reconcile: verify latest state, then close with evidence or annotate ----
#
# The semantics are owned by docs/captain-hold-lifecycle.md; this section owns
# the durable record and the two terminal operations that retire it. Nothing
# here closes a captain call on the strength of a reconcile alone: `close`
# demands the evidence that made the call moot, and `note` leaves it open.

RECONCILE_DIR="$STATE/reconcile-requests"
RECONCILE_SCHEMA=jg-reconcile-request.v1
RECONCILE_VALUE=reconcile

reconcile_request_path() { printf '%s/%s.request\n' "$RECONCILE_DIR" "$1"; }

# Idempotent per task: a repeated reconcile keeps the one request and its
# original timestamp, so a re-delivered board answer never resets the clock on
# an obligation that is already open.
reconcile_request_record() {  # <task-id> <provenance>
  local id=$1 source=$2 path tmp
  path=$(reconcile_request_path "$id")
  [ ! -e "$path" ] || return 0
  (umask 077; mkdir -p "$RECONCILE_DIR") || return 1
  [ -d "$RECONCILE_DIR" ] && [ ! -L "$RECONCILE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RECONCILE_DIR/.request.XXXXXX") || return 1
  if {
    printf 'schema=%s\n' "$RECONCILE_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'requested=%s\n' "${JG_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf 'source=%s\n' "$(sanitize_reconcile_provenance "$source")"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

reconcile_request_read() {  # <task-id>; sets RECONCILE_REQUESTED/RECONCILE_SOURCE
  local id=$1 path schema task
  path=$(reconcile_request_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  jg_compat_record_ok "$schema" "$RECONCILE_SCHEMA" "$(jg_compat_legacy_of "$RECONCILE_SCHEMA")" \
    || fail "reconcile request has an incompatible schema: $path"
  task=$(sed -n 's/^task=//p' "$path" | head -1)
  [ "$task" = "$id" ] || fail "reconcile request names a different task: $path"
  RECONCILE_REQUESTED=$(sed -n 's/^requested=//p' "$path" | head -1)
  RECONCILE_SOURCE=$(sed -n 's/^source=//p' "$path" | head -1)
}

reconcile_request_retire() {  # <task-id>
  rm -f -- "$(reconcile_request_path "$1")" \
    || fail "could not retire the pending reconcile request for $1"
}

publish_parent_resolution_then_retire() {  # <task-id> <gate-id> <occurrence> <note>
  local id=$1 gate=$2 occurrence=$3 note=$4 request
  request=$(reconcile_request_path "$id")
  publish_parent_hold "$id" "$gate" "$occurrence" resolved "$note"
  if [ -e "$request" ] && [ "$PARENT_HOLD_PUBLISHED" != 1 ]; then
    fail "could not publish the answered captain-held task $id to its parent"
  fi
  reconcile_request_retire "$id"
}

command_reconcile_requests() {
  local source_id='' source='' origin row id note provenance show show_status=0 created=0 skipped=0 tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) shift; source_id=${1:-} ;;
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_source_id "$source_id"
  [ -n "$source" ] || fail "--source provenance is required"
  origin=$(read_binding "$source_id") || fail "cannot verify the binding for source $source_id"
  [ -n "$origin" ] || fail "source $source_id is not bound; no reconcile requests were created"
  require_backlog
  while IFS= read -r row; do
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*) printf 'refused: %s (invalid task id)\n' "$id"; skipped=$((skipped + 1)); continue ;;
    esac
    [ "${#id}" -le 128 ] \
      || { printf 'refused: %s (task id is too long)\n' "$id"; skipped=$((skipped + 1)); continue; }
    acquire_task_control_lock "$id"
    show_status=0
    show=''
    task_show "$id" || show_status=$?
    [ "$show_status" -ne 0 ] || show=$TASK_SHOW_OUTPUT
    if [ "$show_status" -eq 124 ]; then
      fail "the backlog backend exceeded its read bound reading $id"
    fi
    if [ -z "$show" ]; then
      printf 'refused: %s (absent)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field "$show" state)" = "done" ]; then
      printf 'refused: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field_value "$show" hold_kind)" != captain ]; then
      printf 'refused: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
    else
      provenance=$source
      [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
      if reconcile_request_record "$id" "$provenance"; then
        printf 'reconcile: %s\n' "$id"
        created=$((created + 1))
      else
        printf 'refused: %s (cannot record the reconcile request)\n' "$id"
        skipped=$((skipped + 1))
      fi
    fi
    release_task_control_lock || fail "cannot release task control for $id"
  done
  printf 'reconcile-requests: created=%s skipped=%s\n' "$created" "$skipped"
  [ "$skipped" -eq 0 ]
}

command_reconcile() {
  local action=${1:-}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$action" in
    list)    reconcile_list "$@" ;;
    close)   reconcile_close "$@" ;;
    note)    reconcile_note "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

reconcile_list() {
  local path id count=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$RECONCILE_DIR" ] || { printf 'reconcile-requests: 0\n'; return 0; }
  for path in "$RECONCILE_DIR"/*.request; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.request}
    RECONCILE_REQUESTED=''
    RECONCILE_SOURCE=''
    reconcile_request_read "$id" || continue
    printf '%s\trequested=%s\tsource=%s\n' "$id" "$RECONCILE_REQUESTED" "$RECONCILE_SOURCE"
    count=$((count + 1))
  done
  printf 'reconcile-requests: %s\n' "$count"
}

# The moot outcome. The evidence is what closes the call, and the `reconciled`
# resolution mode is what keeps the record from claiming the captain answered.
# A moot question held as a gate closes on evidence: the gate records it as reconciled, never as his words, and the ticket closes.
reconcile_close_gate() {  # <task-id> <show-output>
  local id=$1 show=$2 gate evidence tmp occurrence
  evidence="Reconciliation evidence: $DECISION_TEXT"
  gate=$(open_gate_ids "$id" | head -1)
  if [ -z "$gate" ]; then  # none open: an exact retry finishes the close the first call began
    gate=$(gate_rows "$id" --all | jq -rs --arg w "$evidence" '[.[] | select(.resolution == "reconciled" and .words == $w)] | last | .id // empty')
    [ -n "$gate" ] || fail "task $id has no open question to reconcile"
  else
    guard_captain_ask "$id"
    tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-captain-hold-words.XXXXXX") || fail "cannot stage the evidence"
    printf '%s' "$evidence" > "$tmp"
    backlog_cmd resolve "$gate" --words-file "$tmp" --resolution reconciled >/dev/null \
      || { rm -f -- "$tmp"; fail "could not close the question $gate on task $id"; }
    rm -f -- "$tmp"
  fi
  if [ "$(show_field "$show" state)" != "done" ]; then
    close_answered "$id" 0 || fail "could not close reconciled captain-held task $id"
  fi
  occurrence=$(gate_rows "$id" --all | jq -rs '[.[] | select(.state == "closed")] | length')
  publish_parent_hold "$id" "$gate" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
    || fail "could not publish the reconciled captain-held task $id to its parent"
  reconcile_request_retire "$id"
  printf 'reconciled: %s\n' "$id"
}

reconcile_close() {
  local id=${1:-} evidence_file='' show
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$evidence_file" ] || fail "--evidence-file is required; a moot call closes on evidence, never on assertion"
  load_decision "$evidence_file"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_backlog
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  [ -n "$(gate_rows "$id" --all)" ] || fail "task $id has no question to the owner; there is no captain call to reconcile"
  reconcile_close_gate "$id" "$show"
}

# The still-active outcome. The hold survives, so the call stays the captain's
# and stays on Captain's Call, now carrying what the re-check found.
reconcile_note() {
  local id=${1:-} note_file='' note show body stamp tmp note_digest marker gate
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-file) shift; note_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$note_file" ] || fail "--note-file is required; leaving a call open records what the re-check found"
  [ -f "$note_file" ] || fail "note file does not exist: $note_file"
  note=$(cat "$note_file")
  [ -n "$note" ] || fail "note file must not be empty"
  [ "$(printf '%s' "$note" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "note file exceeds 8192 bytes"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_backlog
  command_open "$id" \
    || fail "task $id is not an open captain call; a note cannot keep a closed call open"
  gate=$(open_gate_ids "$id" | head -1)
  if [ -n "$gate" ]; then  # a question is a gate: the finding is a comment on it, and the gate stays open
    backlog_cmd note "$gate" --note-file "$note_file" >/dev/null \
      || fail "could not record the reconcile note on the question $gate of task $id"
    reconcile_request_retire "$id" \
      || fail "could not retire the applied reconcile request for $id"
    command_open "$id" || fail "recording the reconcile note released captain-held task $id"
    report_hold_reconciled "$id" raised
    printf 'still-open: %s\n' "$id"
    return 0
  fi
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  note_digest=$(sha256_text "$note")
  marker="Reconcile request: $RECONCILE_REQUESTED | $RECONCILE_SOURCE | note digest: $note_digest"
  case "$body" in
    *"$marker"*)
      reconcile_request_retire "$id" \
        || fail "could not retire the applied reconcile request for $id"
      command_open "$id" || fail "recording the reconcile note released captain-held task $id"
      printf 'still-open: %s\n' "$id"
      return 0
      ;;
  esac
  stamp=${JG_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-captain-hold-note.XXXXXX") \
    || fail "cannot stage the reconcile note"
  if ! printf '%s\n\nCaptain hold reconciled: %s\n%s\n%s\n' "$body" "$stamp" "$marker" "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the reconcile note for $id"
  fi
  if ! backlog_cmd update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the reconcile note on $id"
  fi
  rm -f -- "$tmp"
  reconcile_request_retire "$id" \
    || fail "could not retire the applied reconcile request for $id"
  command_open "$id" || fail "recording the reconcile note released captain-held task $id"
  printf 'still-open: %s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' entry key status_file open has_meta=0 transfer_rc transfers=() resolved
  local origin_state unrecorded_origin=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    CAPTAIN_META_LOCK=$(jg_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    jg_lock_acquire_wait "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_backlog
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $JG_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with task ids"
      validate_slug task-id "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      resolved=$(verify_entry_durable "$origin" "$entry") || exit $?
      origin_state=${resolved##* }
      resolved=${resolved% *}
      resolved=${resolved%% *}
      if [ "$origin_state" = unrecorded ]; then
        unrecorded_origin="${unrecorded_origin}${unrecorded_origin:+ }$resolved"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  open=$(status_open_decisions "$status_file")
  if [ -n "$open" ] && [ -z "$keys" ]; then
    fail "origin $origin still has open captain decisions in its status stream; hold a captain task for what remains, or answer them, before attesting --none"
  fi

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    jg_lock_release "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=0

    # Transfer every still-open status decision to the durable captain-held
    # inventory so the live status fold does not duplicate the same Captain's
    # Call item. The transfer lines are this home's own bookkeeping closes,
    # written by the turn that just reviewed the inventory, so they go through
    # ONE guarded self-announced append (bin/jg-wake-lib.sh) and do not wake
    # this same session; an append failure still fails this command loudly.
    if [ -n "$keys" ]; then
      while IFS=$'\t' read -r key _verb _summary; do
        [ -n "$key" ] || continue
        transfers+=("captain-held [key=$key]: tracked by $keys")
      done <<EOF
$open
EOF
      if [ "${#transfers[@]}" -gt 0 ]; then
        transfer_rc=0
        jg_wake_status_append_self_announced "$STATE" "$status_file" "${transfers[@]}" || transfer_rc=$?
        [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin"
      fi
    fi
  fi
  printf 'complete: %s captain-call inventory reviewed%s%s\n' "$origin" "${keys:+ ($keys)}" \
    "${unrecorded_origin:+ [no recorded origin on: $unrecorded_origin; not checked against $origin]}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open resolved
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_backlog
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_entry_durable "$origin" "$entry" >/dev/null
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(status_open_decisions "$STATE/$origin.status")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    fail "open captain decision $origin/$key is not transferred to the captain-held inventory; re-run complete"
  done <<EOF
$open
EOF
  printf 'verified: %s captain-call inventory\n' "$origin"
}

command_answered() {  # <task-id>: a closed question carries his words, or a ticket released by them
  local gates
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  task_show "$1" || exit 2
  gates=$(gate_rows "$1" --all)
  [ -z "$(printf '%s\n' "$gates" | jq -r 'select(.state == "open") | .id')" ] || return 1
  [ -n "$(printf '%s\n' "$gates" | jq -r 'select(.resolution == "answered" or .resolution == "released") | .id')" ]
}

# The hold machine's word for one task, from the same record `open` and `answered` read plus
# the body's own completion line (core/machines/observers/hold.sh prints it). Exit 2 when the row cannot be read.
command_phase() {  # <task-id>
  local id=${1:-} status=0 show until
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  (command_open "$id" --distinguish-absent) || status=$?
  case "$status" in 0|1) ;; 3) echo none; return 0 ;; *) exit 2 ;; esac
  task_show "$id" || exit 2
  show=$TASK_SHOW_OUTPUT
  if [ "$status" -eq 0 ]; then
    until=$(show_field_value "$show" hold_until)
    if [ -n "$until" ] && [[ "$until" > "$(date -u +%F)" ]]; then echo deferred; else echo raised; fi
    return 0
  fi
  if [ "$(show_field "$show" state)" = "done" ] && [ "$(show_field_value "$show" hold_kind)" = captain ]; then echo closed; return 0; fi
  (command_answered "$id") && echo closed || echo none
}

# Still an open captain call? Exit 0 yes, 1 no, 2 cannot tell (see the header).
# A row this home does not carry is 3 when the caller requests the distinction,
# and so is a home with no backlog file at all, because a backlog that does not
# exist holds nothing. Every read failure over a record that DOES exist is a 2,
# printed to stderr, because a mechanical closer must never read "cannot tell"
# as permission to close.
command_open() {  # <task-id> [--identity] [--distinguish-absent]
  local id='' identity=0 distinguish_absent=0 data state show
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=1 ;;
      --distinguish-absent) distinguish_absent=1 ;;
      -*) usage >&2; exit 2 ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 2; }
        id=$1
        ;;
    esac
    shift
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'jg-captain-hold: task id must be a non-empty privacy-safe slug: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  data=$(jg_backlog_data_absolute "$DATA") \
    || { printf 'jg-captain-hold: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }
  if jg_backlog_row_probe "$data" "$id"; then
    state=${JG_BACKLOG_ROW_STATE%% *}
    if [ "$state" != "done" ] && [ "$JG_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      if [ "$identity" -eq 1 ] && [ -n "$(open_gate_ids "$id")" ]; then
        open_gate_ids "$id" | head -1  # a question held as a gate is told apart by its gate
      elif [ "$identity" -eq 1 ]; then  # a plain hold, his own instruction: its reason and date tell one hold from the next
        task_show "$id" || {
          printf 'jg-captain-hold: captain call %s is open but its record could not be read\n' "$id" >&2
          exit 2
        }
        printf '%s' "$(show_field_value "$TASK_SHOW_OUTPUT" hold_reason)$(show_field_value "$TASK_SHOW_OUTPUT" hold_until)" | cksum | awk '{printf "%08x\n", $1}'
      fi
      return 0
    fi
    return 1
  fi
  if [ "$JG_BACKLOG_ROW_RESULT" = not_found ]; then
    [ "$distinguish_absent" = 0 ] || return 3
    return 1
  fi
  printf 'jg-captain-hold: %s\n' "$JG_BACKLOG_ROW_ERROR" >&2
  exit 2
}

# Ids a body links to: the words on `linked-to:` and `parent:` lines; a word that
# is no task links nothing, and `upkeep` (a bucket) is dropped.
body_link_targets() {  # <decoded body>
  printf '%s\n' "$1" | sed -n -E 's/^[[:space:]]*(linked-to|parent):[[:space:]]*(.*)$/\2/p' \
    | tr ',;[:space:]' '\n' | LC_ALL=C grep -E '^[A-Za-z0-9._-]+$' | LC_ALL=C grep -vix upkeep | LC_ALL=C sort -u
}

# Is <task-id> an open decision (see `blocking`)? 0 yes, 1 no; unreadable exits 2.
decision_open() {  # <task-id>
  local target=$1 status=0 show
  (command_open "$target" --distinguish-absent) || status=$?
  case "$status" in
    0) return 0 ;;
    1) ;;
    3) return 1 ;;
    *) exit 2 ;;
  esac
  task_show "$target" || { printf 'jg-captain-hold: task %s could not be read\n' "$target" >&2; exit 2; }
  show=$TASK_SHOW_OUTPUT
  [ "$(show_field "$show" state)" != "done" ] || return 1
  case "$(show_field_value "$show" labels)$(show_field_value "$show" title)" in *"design-ux"*) ;; *) return 1 ;; esac  # the one design mark: its label, or the old title tag
  status=0
  (command_answered "$target") || status=$?
  case "$status" in 0) return 1 ;; 1) ;; *) exit 2 ;; esac
  captain_ask_build_approved "$target" "$show" && return 1
  return 0
}

# THE place that scopes which open decisions stop which work: only those LINKED
# to <task-id> (either direction); unrelated work keeps moving. To make every
# open decision stop all work, print every open decision here instead. A
# `parent:` id links only when it is a real task, so `parent: upkeep` links nothing.
# One pass over the backlog finds the rows linking here; only those are checked.
# That pass is the provider's `links` read, which is every edge.
linked_open_decisions() {  # <task-id>; prints the open decisions linked to it, one id per line
  local id=$1 mine target
  mine=$(backlog_cmd links "$id") \
    || { printf 'jg-captain-hold: task %s could not be read for its links\n' "$id" >&2; exit 2; }
  while IFS= read -r target; do
    [ -z "$target" ] || ! decision_open "$target" || printf '%s\n' "$target"
  done <<<"$mine"
}

command_blocking() {  # <task-id>
  local id=${1:-} status=0 target blockers n=0
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  (command_open "$id" --distinguish-absent) || status=$?
  case "$status" in
    0) blockers=$id ;;
    1) blockers='' ;;
    3) return 1 ;;
    *) exit 2 ;;
  esac
  blockers="$blockers"$'\n'"$(linked_open_decisions "$id")" || exit 2
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    n=$((n + 1))
    task_show "$target" || true
    printf '%s\t%s\n' "$target" "$(sanitize_field "$(show_field_value "$TASK_SHOW_OUTPUT" title)")"
  done <<EOF
$(printf '%s\n' "$blockers" | LC_ALL=C sort -u)
EOF
  [ "$n" -gt 0 ]
}

# A design card (`jg-question-card.sh post --must design-pick`) is one human gate on the
# ticket that raised it (bin/jg-beads-write.py `gate`): the gate blocks that ticket, so
# `blocking` finds it, and carries the card key in its metadata so the board answer finds
# it. No `[design-ux]` row is filed. A retry finds the open gate; a card naming no raising
# ticket, or one this home does not carry, is refused.
command_design_card() {  # <card-key> --raised-by <ticket> --title <question>
  local key=${1:-} raised='' title='' mark gate
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --raised-by) shift; raised=${1:-} ;;
      --title) shift; title=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug card-key "$key"
  [ -n "$raised" ] || fail "refused: a design card must name the ticket that raised it; pass --raised-by <ticket>"
  validate_slug raised-by "$raised"
  validate_one_line title "$title"
  [ -n "${title//[[:space:]]/}" ] || fail "a design card needs --title"
  require_backlog
  task_show "$raised" || fail "refused: $raised, named as the ticket that raised the design card, is not in this home's backlog"
  # The marker lets the board-answers check find the card's answer without reading the backlog for every answer.
  mark=$STATE/design-cards/$key
  mkdir -p "$STATE/design-cards" || fail "cannot create $STATE/design-cards"
  gate=$(card_gate_rows "$key" | jq -r 'select(.state == "open") | .id' | head -1)
  if [ -n "$gate" ]; then : > "$mark"; printf 'design-card: %s already filed\n' "$key"; return 0; fi
  backlog_cmd gate "$raised" --title "$title" --reason "$title" --must design-pick --card "$key" --close release >/dev/null \
    || fail "could not make the design question for card $key on $raised"
  : > "$mark"
  printf 'design-card: %s linked to %s\n' "$key" "$raised"
}

card_gate_rows() {  # <card-key>: the gates made for that card, one JSON record per line
  backlog_cmd questions --all --json | jq -c --arg k "$1" '.[] | select(.card == $k)' \
    || fail "the questions could not be read for card $1"
}

# The captain answered the card: close its gate with his whole words, which releases the work
# it blocked; the raising ticket stays open. A card with no gate (an old design row, closed with
# his words on it as before) or no row at all is no gate card, so that is a quiet no-op; an
# unreadable backlog is not.
command_design_pick() {  # <card-key> --words <the captain's words>
  local key=${1:-} words='' mark gate tmp
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --words) shift; words=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug card-key "$key"
  [ -n "${words//[[:space:]]/}" ] || fail "design-pick needs --words \"<the captain's words>\""
  mark=$STATE/design-cards/$key
  require_backlog
  gate=$(card_gate_rows "$key" | jq -r 'select(.state == "open") | .id' | head -1)
  if [ -n "$gate" ]; then
    tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-captain-hold-words.XXXXXX") || fail "cannot stage the captain's pick"
    printf '%s' "$words" > "$tmp"
    backlog_cmd resolve "$gate" --words-file "$tmp" --resolution answered >/dev/null \
      || { rm -f -- "$tmp"; fail "could not record the pick on the design question $gate"; }
    rm -f -- "$tmp"
    rm -f -- "$mark"
    printf 'design-pick: %s recorded\n' "$key"
    return 0
  fi
  # No open gate: a design row filed before gates (a `[design-ux]` ticket keyed by the card) closes with his words.
  task_show "$key" || { rm -f -- "$mark"; return 0; }
  case "$(show_field_value "$TASK_SHOW_OUTPUT" labels)$(show_field_value "$TASK_SHOW_OUTPUT" title)" in *"design-ux"*) ;; *) rm -f -- "$mark"; return 0 ;; esac
  [ "$(show_field "$TASK_SHOW_OUTPUT" state)" != "done" ] || { rm -f -- "$mark"; return 0; }
  backlog_cmd "done" "$key" --note "Captain's pick: $(printf '%s' "$words" | tr '\n\r' '  ' | cut -c1-500)" >/dev/null \
    || fail "could not record the pick on design row $key"
  rm -f -- "$mark"
  printf 'design-pick: %s recorded\n' "$key"
}

# --- the pass that moves old holds to gates -----------------------------------
# An open owner hold of the old kind carries a stamp (and perhaps an origin line) in its body. The pass makes its gate
# from the hold's own reason and origin, then takes the two lines out of the body. The ticket keeps its status, so a
# deferral date stays, and a stop order stays stamped because it is his instruction and asks him nothing. The gate is made
# first and a retry finds it, so a pass that stopped half way is finished by the next run, and a second run changes nothing.
body_without_hold_lines() {  # <decoded-task-body>
  printf '%s\n' "$1" | awk 'NR == 1 && /^Captain hold set: / { next } /^Captain hold origin: / { next } NF || started { started = 1; print }'
}

hold_to_gate() {  # <task-id>: prints moved, kept or skipped
  local id=$1 show reason origin body tmp title close=release
  acquire_task_control_lock "$id"
  task_show "$id" || { release_task_control_lock; printf 'skipped\n'; return 0; }
  show=$TASK_SHOW_OUTPUT
  reason=$(show_field_value "$show" hold_reason)
  if [ "$(show_field "$show" state)" = "done" ] || [ "$(show_field_value "$show" hold_kind)" != captain ] \
    || [ -z "$(body_hold_set_timestamp "$(decode_shown_value "$(show_field "$show" body)")")" ]; then
    release_task_control_lock; printf 'skipped\n'; return 0
  fi
  if jg_ask_own_instruction "$reason"; then
    release_task_control_lock; printf 'kept\n'; return 0
  fi
  body=$(decode_shown_value "$(show_field "$show" body)") || fail "could not decode the body of $id"
  origin=$(body_hold_origin "$body")
  [ "$(show_field_value "$show" kind)" != captain ] || close="done"
  title=$(card_title "$reason")
  [ -n "$title" ] || title=$(built_title "$(show_field_value "$show" title)")
  backlog_cmd gate "$id" --title "$title" --reason "$reason" --close "$close" ${origin:+--origin "$origin"} >/dev/null \
    || fail "could not make the owner's question on task $id"
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-captain-hold-gate.XXXXXX") || fail "cannot stage the body of $id"
  body_without_hold_lines "$body" > "$tmp"
  backlog_cmd update "$id" --body-file "$tmp" >/dev/null || { rm -f -- "$tmp"; fail "could not take the old hold lines out of $id"; }
  rm -f -- "$tmp"
  release_task_control_lock
  printf 'moved\n'
}

command_to_gates() {
  local id outcome moved=0 kept=0 skipped=0 total=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_backlog
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    outcome=$(hold_to_gate "$id") || exit $?
    case "$outcome" in
      moved) moved=$((moved + 1)) ;;
      kept) kept=$((kept + 1)) ;;
      *) skipped=$((skipped + 1)) ;;
    esac
    total=$((total + 1))
  done < <(backlog_cmd list --state held --fields hold_kind | awk -F, '/^  [^ ]/ && $NF == "captain" { sub(/^  /, "", $1); print $1 }')
  printf 'to-gates: moved %d of %d owner holds to gates (%d stop orders kept as holds, %d already gates)\n' "$moved" "$total" "$kept" "$skipped"
}

case "${1:-}" in
  hold) shift; command_hold "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  reconcile-requests) shift; command_reconcile_requests "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  answered) shift; command_answered "$@" ;;
  phase) shift; command_phase "$@" ;;
  open) shift; command_open "$@" ;;
  blocking) shift; command_blocking "$@" ;;
  design-card) shift; command_design_card "$@" ;;
  design-pick) shift; command_design_pick "$@" ;;
  to-gates) shift; command_to_gates "$@" ;;
  reconcile) shift; command_reconcile "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
