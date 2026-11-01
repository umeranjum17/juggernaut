# shellcheck shell=bash
# jg-public-followup-lib.sh - shared gating and private-transport helpers for the
# deterministic public-followup consumer.
#
# Juggernaut promises a public final reply when a myjuggernaut relay mention (X or
# Discord) asks for work. `tasks-axi public-followup` is the sole owner of that
# typed obligation and its state machine; state/x-context/ is the sole owner of
# the private full request context. This library owns Juggernaut's activation
# gate, private per-home transport paths, retained-loop state and locking
# helpers, follow-up window classification, and deterministic terminal-event
# identity.
#
# Sourced, never executed. No side effects on source (it creates nothing), which
# is what keeps a relay-disabled home free of public-followup artifacts.
# set -u / set -e safe.
#
# GATE ORDER - the acceptance criterion for relay-disabled homes:
#   1. jg_pf_relay_active <home>     the authoritative myjuggernaut activation
#                                    contract, a non-empty FMX_PAIRING_TOKEN in
#                                    <home>/.env. There is no second flag. When
#                                    <home>/.env is absent this is a single
#                                    [ -f ] test and nothing else runs.
#   2. jg_pf_has_registrations       O(1) presence check on the registry created
#      / jg_pf_has_events            only by the relay path (jg-public-followup.sh
#      / jg_pf_has_open_loops        register). Open loops ARE registrations:
#                                    a delivered final keeps the record, so this
#                                    same check is the fail-loud session-start
#                                    gate. Relay-enabled homes with no public
#                                    loops stop here, so no tasks-axi call and
#                                    no backlog scan happens.
#
# Private transport layout, all under <home>/state/public-followup (mode 0700,
# initialized by `jg-public-followup.sh register` and extended only by these
# public-followup commands):
#   registry/<obligation-id>   registration record: the bounded private binding
#                              (obligation, relation, work ref and canonical
#                              squad_lead path, generation, platform,
#                              request id)
#                              plus the loop fields that survive delivery (state,
#                              delivered_at, followup_expires_at,
#                              request_context_b64). Presence means the public
#                              loop is still open. Delivery
#                              stamps state=delivered; only `retire` removes the
#                              record. The obligation itself always remains
#                              tasks-axi truth.
#   events/<event-id>.json     inbound typed terminal events awaiting
#                              reconciliation, one file per event id.
#   outbox/<event-id>.json     OUTBOUND typed terminal events a worker in THIS
#                              home produced for an owning home on another
#                              machine, which no local path can reach. Same file
#                              shape as events/, staged here until that owning
#                              home collects them over the route's transport
#                              (bin/jg-public-followup-emit.sh --stage-in,
#                              bin/jg-public-followup-collect.sh). A home whose
#                              work is only ever local never has this directory.
#   consumed/<event-id>        idempotency ledger: an accepted event id is never
#                              replayed, so duplicate emits and restart replay
#                              are no-ops.
#   rejected/<event-id>.json   events tasks-axi refused, kept with a
#   rejected/<event-id>.reason one-line reason so a refusal is inspectable and
#                              never retried in a loop.
#   rejection-wakes/<event-id> one pending wake line per refusal not yet
#                              surfaced; the relay poll prints it and removes it
#                              only after that line is written, so a refusal
#                              wakes this home instead of sitting silently in
#                              rejected/ or vanishing unheard. Delivery is
#                              at-least-once: a repeat is keyed by the same
#                              event id and carries the same reason.
#   surfaced                  last surfaced pending-event signature, so the
#                              existing relay poll wakes once per new event set
#                              instead of every cycle.
#   retired/<obligation-id>    private retirement receipt containing the bounded
#                              reason and timestamp recorded before the registry
#                              entry is removed; its presence prevents replayed
#                              registration from reopening the closed loop.
#
# Event identity is DERIVED, never random: jg_pf_event_id hashes the canonical
# identity tuple, so re-emitting the same terminal result produces the same
# event id and the same destination path. Idempotency therefore holds across
# retries, restarts, and duplicate child reports without any coordination.
#
# Depends on bin/jg-x-lib.sh for .env reading and the private-artifact
# publication primitives (atomic, single-link, mode-validated, non-executable);
# those remain that file's contract and are not restated here.

_JG_PF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _JG_PF_LIB_DIR="."
# shellcheck source=bin/jg-x-lib.sh
. "$_JG_PF_LIB_DIR/jg-x-lib.sh"

JG_PF_DIRNAME='public-followup'
# Consumed by the sourcing scripts, not by this library.
# shellcheck disable=SC2034
JG_PF_EVENT_SCHEMA_VERSION=1
# Bounded so a public-safe outcome line can never carry a raw public message,
# and so one event file stays small enough to read and validate cheaply.
JG_PF_OUTCOME_TEXT_MAX=${JG_PF_OUTCOME_TEXT_MAX:-600}
JG_PF_EVENT_BYTES_MAX=${JG_PF_EVENT_BYTES_MAX:-8192}

# --- gate 1: the authoritative relay activation contract --------------------

# jg_pf_relay_active <home>: 0 when this home has opted into the myjuggernaut
# relay, 1 otherwise. Identical contract to bootstrap's X-mode activation - a
# non-empty FMX_PAIRING_TOKEN in <home>/.env - so no second activation flag
# exists to drift. FMX_PAIRING_TOKEN in the environment wins, matching
# fmx_load_config, so a direct client call and this gate agree.
jg_pf_relay_active() {
  local home=$1 token
  if [ -n "${FMX_PAIRING_TOKEN+x}" ]; then
    [ -n "${FMX_PAIRING_TOKEN-}" ]
    return $?
  fi
  [ -f "$home/.env" ] || return 1
  token=$(fmx_env_get FMX_PAIRING_TOKEN "$home/.env")
  [ -n "$token" ]
}

# --- gate 2: O(1) presence checks on relay-path-owned registrations ---------

jg_pf_root()       { printf '%s\n' "$1/$JG_PF_DIRNAME"; }
jg_pf_registry_dir() { printf '%s\n' "$1/$JG_PF_DIRNAME/registry"; }
jg_pf_events_dir()   { printf '%s\n' "$1/$JG_PF_DIRNAME/events"; }
jg_pf_outbox_dir()   { printf '%s\n' "$1/$JG_PF_DIRNAME/outbox"; }
jg_pf_consumed_dir() { printf '%s\n' "$1/$JG_PF_DIRNAME/consumed"; }
jg_pf_rejected_dir() { printf '%s\n' "$1/$JG_PF_DIRNAME/rejected"; }
jg_pf_rejection_wakes_dir() { printf '%s\n' "$1/$JG_PF_DIRNAME/rejection-wakes"; }
jg_pf_retired_dir()  { printf '%s\n' "$1/$JG_PF_DIRNAME/retired"; }

jg_pf_retirement_receipt_exists() {
  local file
  file="$(jg_pf_retired_dir "$1")/$2"
  [ -f "$file" ] && [ ! -L "$file" ]
}

# jg_pf_dir_has_entry <dir>: 0 when <dir> is a real directory holding at least
# one non-dot entry. Stops at the first hit, so cost does not grow with the
# directory's size.
jg_pf_dir_has_entry() {
  local dir=$1 entry
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    return 0
  done
  return 1
}

jg_pf_has_registrations() { jg_pf_dir_has_entry "$(jg_pf_registry_dir "$1")"; }
jg_pf_has_events()        { jg_pf_dir_has_entry "$(jg_pf_events_dir "$1")"; }
# Every retained registration is an open public loop (owed or delivered). Same
# O(1) directory presence check as jg_pf_has_registrations; the name is the
# post-retention semantic so callers do not treat "a reply is owed" as the
# only reason a record exists.
jg_pf_has_open_loops()    { jg_pf_has_registrations "$1"; }

# jg_pf_active <home> <state>: both gates, in order. The single predicate every
# caller outside the relay path should use before doing any public-followup work.
jg_pf_active() {
  jg_pf_relay_active "$1" || return 1
  jg_pf_has_registrations "$2" || jg_pf_has_events "$2"
}

# --- identifiers ------------------------------------------------------------

# jg_pf_slug_valid <value>: obligation ids, relation ids, work ids, and request
# ids all compose filenames. They arrive from tasks-axi, the relay, and child
# homes, so every one is checked against a conservative slug before use.
jg_pf_slug_valid() {
  local v=$1
  case "$v" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#v}" -le 128 ]
}

# The typed tasks-axi schema owns the home-id prefix for a squad-lead work ref,
# and the pinned release still declares it under its pre-rename spelling, so the
# value keeps that spelling: it crosses into another tool, it is not a name this
# repository chooses. Derived rather than spelled, and records written under the
# renamed spelling are still read (slice S5).
JG_PF_SQUAD_LEAD_HOME_PREFIX="$(jg_compat_legacy_of squad-lead):"
JG_PF_SQUAD_LEAD_HOME_PREFIX_ALT=squad_lead:

# Our spelling on the left, the pinned tasks-axi spelling on the right: this pair
# is the whole boundary, so everything else keeps the current name.
jg_pf_tasks_axi_home_id() {  # <home-id>
  case "${1-}" in
    "$JG_PF_SQUAD_LEAD_HOME_PREFIX_ALT"*) printf '%s%s\n' "$JG_PF_SQUAD_LEAD_HOME_PREFIX" "${1#"$JG_PF_SQUAD_LEAD_HOME_PREFIX_ALT"}" ;;
    *) printf '%s\n' "${1-}" ;;
  esac
}

# jg_pf_home_id_valid <home_id>: tasks-axi accepts "main" or a squad-lead home id.
# Validate the same shape here so a malformed source home is refused before it
# reaches a filename or a CLI call.
jg_pf_home_id_valid() {
  local v=$1
  case "$v" in
    main) return 0 ;;
    "$JG_PF_SQUAD_LEAD_HOME_PREFIX"*) jg_pf_slug_valid "${v#"$JG_PF_SQUAD_LEAD_HOME_PREFIX"}" ;;
    "$JG_PF_SQUAD_LEAD_HOME_PREFIX_ALT"*) jg_pf_slug_valid "${v#"$JG_PF_SQUAD_LEAD_HOME_PREFIX_ALT"}" ;;
    *) return 1 ;;
  esac
}

jg_pf_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# jg_pf_event_id <obligation> <relation> <source_home> <work_id> <generation>
#                <outcome_type> <deliverables-canonical>
# The stable idempotency identity. Derived from the identity tuple only, so the
# same terminal result always yields the same id no matter who emits it or how
# often. Public-safe outcome text is deliberately excluded: rewording the same
# landed outcome must not create a second event.
jg_pf_event_id() {
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    | jg_pf_sha256
}

# --- bounded public-safe text ----------------------------------------------

# jg_pf_clean_outcome_text: read stdin, drop control characters, collapse every
# whitespace run to a single space, and trim. An event line therefore stays
# single-line and a raw pasted public message cannot ride along inside it.
# Deliberately does NOT truncate: a byte-wise cut would split a multi-byte
# character, so length bounding happens where it can count codepoints - jq, at
# the point the typed event is built.
jg_pf_clean_outcome_text() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C tr '\011\012\015' '   ' \
    | LC_ALL=C tr -s ' ' \
    | sed 's/^ //; s/ $//'
}

# jg_pf_bound_bytes <max>: hard byte cap for text that never becomes JSON, such
# as a quarantined event's one-line refusal reason.
jg_pf_bound_bytes() {
  LC_ALL=C cut -b "1-$1"
}

# --- deliverable rules ------------------------------------------------------
#
# tasks-axi is the authority on deliverables, but it exposes no validation-only
# command, and its refusal of a bad value names none of it. These helpers mirror
# the rules its work-event consumer applies - EXPECTED_DELIVERABLES,
# eventMatchesExpected, failureDeliverablesAreSafe, REPORT_PATH_RE,
# COMMIT_SHA_RE, and SAFE_CODE_RE in tasks-axi's public-followup.js, and isPrUrl
# in tasks-axi's pr-url.js, which is the seam public-followup.js classifies
# pr_url through - so a bad value is refused where it is written and a refusal
# can say which value was wrong. Every rule here is keyed on the promise's
# expected final and the event's outcome together, because that is the pair
# tasks-axi keys them on.
# tasks-axi still re-validates at consume; tests/jg-public-followup.test.sh pins
# these rules against the real consumer, so re-pin both together when tasks-axi
# changes them.

# jg_pf_deliverable_format <key>: the format tasks-axi accepts for <key>, as one
# line for a brief or a refusal. Exit 1 for a key with no known format rule.
jg_pf_deliverable_format() {
  case "$1" in
    pr_url) printf '%s\n' 'a canonical pull request URL: https://github.com/<owner>/<repo>/pull/<n> (GitHub) or https://<host>/<owner>/<repo>/pulls/<n> (Forgejo), with <n> a positive number without leading zeros and no trailing slash, query, fragment, credentials, or port' ;;
    report_path) printf '%s\n' 'data/<task-id>/report.md, relative to the work home, never an absolute path' ;;
    commit_sha) printf '%s\n' 'a lowercase hex commit SHA of 7 to 64 characters' ;;
    error_code) printf '%s\n' 'a lowercase code of at most 64 characters: a letter, then letters, digits, ".", "_", or "-"' ;;
    *) return 1 ;;
  esac
}

# jg_pf_deliverable_key_valid <key>: 0 when <key> is a deliverable name tasks-axi
# accepts (DELIVERABLE_NAME_RE in its public-followup.js): a lowercase letter,
# then at most 63 more of [a-z0-9_].
jg_pf_deliverable_key_valid() {
  case "$1" in
    ''|[!a-z]*|*[!a-z0-9_]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# jg_pf_expected_outcome <expected-final>: the one outcome_type that satisfies
# that expected final (eventMatchesExpected in tasks-axi's public-followup.js).
# A promise is also answerable with 'failed', which reports that it could not be
# kept as promised rather than satisfying it. Exit 1 for an unknown type.
jg_pf_expected_outcome() {
  case "$1" in
    failure-outcome) printf 'failed\n' ;;
    explicit-answer) printf 'local-main\n' ;;
    pr-merged|report-ready|local-main) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# jg_pf_deliverable_keys <expected-final> <outcome>: the deliverable keys
# tasks-axi lets an event with <outcome> carry against a promise whose expected
# final is <expected-final>, space-separated (empty for none). That is
# EXPECTED_DELIVERABLES[expected] for the outcome the promise expects, the
# error_code of failureDeliverablesAreSafe for a failure reported against any
# other promise, and nothing for superseded. With no <expected-final> - a staged
# emit cannot read one - the outcome stands in for it, which is the same set
# whenever the event is the one the promise expects. Exit 1 when neither names a
# final tasks-axi defines, which it refuses on its own.
jg_pf_deliverable_keys() {
  local expected=${1:-$2}
  case "$2" in
    superseded) printf '\n'; return 0 ;;
    failed) [ "$expected" = failure-outcome ] || { printf 'error_code\n'; return 0; } ;;
  esac
  case "$expected" in
    pr-merged) printf 'pr_url\n' ;;
    report-ready) printf 'report_path\n' ;;
    local-main) printf 'commit_sha\n' ;;
    failure-outcome) printf 'error_code\n' ;;
    explicit-answer) printf '\n' ;;
    *) return 1 ;;
  esac
}

# jg_pf_pr_url_valid <url>: 0 when <url> is byte-for-byte a canonical pull
# request URL. Mirrors isPrUrl in tasks-axi's pr-url.js: exactly
# https://github.com/<owner>/<repo>/pull/<n> on github.com, or
# https://<lowercase-dns-host>/<owner>/<repo>/pulls/<n> on any other host, with
# <n> positive and without leading zeros. The route and the host decide each
# other, so a singular route off github.com and a plural route on it are both
# refused, as are an owner or repo of "." or "..".
jg_pf_pr_url_valid() {
  local url=$1 rest host owner repo route
  local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
  local segment='[A-Za-z0-9._-]+'
  printf '%s\n' "$url" | LC_ALL=C grep -Eq \
    "^https://${label}(\\.${label})*/${segment}/${segment}/(pull|pulls)/[1-9][0-9]*\$" \
    || return 1
  rest=${url#https://}
  host=${rest%%/*}; rest=${rest#*/}
  owner=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*}; rest=${rest#*/}
  route=${rest%%/*}
  case "$owner" in .|..) return 1 ;; esac
  case "$repo" in .|..) return 1 ;; esac
  if [ "$route" = pull ]; then
    [ "$host" = github.com ]
  else
    [ "$host" != github.com ]
  fi
}

# jg_pf_deliverable_problem <expected-final> <outcome> <key> <value>: silent exit
# 0 when tasks-axi would accept <key>=<value> on a work event with <outcome>
# against a promise whose expected final is <expected-final> (empty when the
# caller cannot read one); otherwise print one line naming the key, the specific
# problem, and the applicable correction, and exit 1. The 500-character bound
# and single-line rule are safeText's, which tasks-axi applies to every deliverable
# value whatever its key; the per-key formats follow it.
jg_pf_deliverable_problem() {
  local expected=$1 outcome=$2 key=$3 value=$4 allowed format re=''
  if allowed=$(jg_pf_deliverable_keys "$expected" "$outcome"); then
    case " $allowed " in
      *" $key "*) ;;
      *)
        if [ -n "$allowed" ]; then
          printf "deliverable '%s' is not one this promise accepts on a %s outcome; expected %s\n" "$key" "$outcome" "$allowed"
        else
          printf "deliverable '%s' is not allowed: this promise accepts no deliverable on a %s outcome\n" "$key" "$outcome"
        fi
        return 1
        ;;
    esac
  fi
  case "$value" in
    '')
      printf "deliverable '%s' has no value; tasks-axi accepts no empty deliverable\n" "$key"
      return 1
      ;;
    ' '*|*' ')
      printf "deliverable '%s' is not valid: it has leading or trailing whitespace\n" "$key"
      return 1
      ;;
    *[[:cntrl:]]*)
      printf "deliverable '%s' is not valid: it must be single-line text with no control characters\n" "$key"
      return 1
      ;;
  esac
  if [ "${#value}" -gt 500 ]; then
    printf "deliverable '%s' is %s characters long; tasks-axi accepts at most 500\n" "$key" "${#value}"
    return 1
  fi
  case "$key" in
    pr_url|report_path|commit_sha|error_code) ;;
    *) return 0 ;;
  esac
  format=$(jg_pf_deliverable_format "$key")
  case "$key" in
    pr_url) jg_pf_pr_url_valid "$value" && return 0 ;;
    report_path) re='^data/[A-Za-z0-9][A-Za-z0-9._-]*/report\.md$' ;;
    commit_sha) re='^[a-f0-9]{7,64}$' ;;
    error_code) re='^[a-z][a-z0-9._-]{0,63}$' ;;
  esac
  if [ -n "$re" ] && printf '%s\n' "$value" | LC_ALL=C grep -Eq "$re"; then
    return 0
  fi
  printf "deliverable '%s' value '%s' is not valid; expected %s\n" "$key" "$value" "$format"
  return 1
}

# --- the promised contract --------------------------------------------------

# jg_pf_obligation_json <home> <obligation-id>: the complete typed obligation
# payload on stdout, empty when that home's backlog simply has no such
# public-followup item, and a non-zero exit ONLY when the backlog could not be
# read at all. Callers depend on that distinction to report the right thing, so
# jq runs without -e here. tasks-axi is the single source of truth for what a
# promise expects, so every reader of that contract comes through this one call
# rather than a copy of it. An inherited JG_DATA_OVERRIDE is cleared because a
# caller such as bound work names the owning home in the argument while its own
# data override is still in the environment.
jg_pf_obligation_json() {
  local home=$1 id=$2 out
  out=$(JG_HOME="$home" JG_DATA_OVERRIDE='' "$_JG_PF_LIB_DIR/jg-tasks-axi.sh" \
    public-followup list --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -c --arg id "$id" \
    '(.public_followups // []) | map(select(.id == $id)) | .[0] // empty' 2>/dev/null \
    || return 1
}

# --- registry records -------------------------------------------------------

# jg_pf_registry_get <state> <obligation-id> <key>: read one key=value line from
# a registration record. Prints nothing and succeeds when absent.
jg_pf_registry_get() {
  local state=$1 id=$2 key=$3 file line
  jg_pf_slug_valid "$id" || return 1
  file="$(jg_pf_registry_dir "$state")/$id"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  printf '%s' "${line#*=}"
}

# jg_pf_registry_ids <state>: every registered obligation id, one per line.
# The registry only ever holds this home's live public commitments, so this stays
# a bounded listing rather than a backlog scan.
jg_pf_registry_ids() {
  local dir entry
  dir=$(jg_pf_registry_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for entry in "$dir"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    basename "$entry"
  done
}

# jg_pf_registry_ids_for_work <state> <work_home_id> <work_id>: the obligations
# this home registered against one exact work relation. Used by the completion
# guard so cleanup cannot declare bound work finished while its public promise is
# still open.
jg_pf_registry_ids_for_work() {
  local state=$1 home_id=$2 work_id=$3 id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(jg_pf_registry_get "$state" "$id" work_home)" = "$home_id" ] || continue
    [ "$(jg_pf_registry_get "$state" "$id" work_id)" = "$work_id" ] || continue
    printf '%s\n' "$id"
  done <<EOF
$(jg_pf_registry_ids "$state")
EOF
}

# jg_pf_now_epoch: wall clock as epoch seconds. FMX_NOW_OVERRIDE pins it for
# tests, matching bin/jg-x-lib.sh.
jg_pf_now_epoch() {
  printf '%s\n' "${FMX_NOW_OVERRIDE:-$(date +%s)}"
}

# jg_pf_now_rfc3339: UTC timestamp for delivered_at and similar stamps.
jg_pf_now_rfc3339() {
  local epoch
  epoch=$(jg_pf_now_epoch)
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ
}

# jg_pf_rfc3339_to_epoch <rfc3339>: parse a Zulu timestamp. Empty on failure.
jg_pf_rfc3339_to_epoch() {
  local ts=$1
  [ -n "$ts" ] || return 1
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null \
    || return 1
}

# jg_pf_followup_window_class <rfc3339>: ok, closing (<48h), expired, or unknown.
jg_pf_followup_window_class() {
  local ts=$1 exp now
  exp=$(jg_pf_rfc3339_to_epoch "$ts") || { printf 'unknown\n'; return 0; }
  now=$(jg_pf_now_epoch)
  if [ "$now" -ge "$exp" ]; then
    printf 'expired\n'
  elif [ $((exp - now)) -lt 172800 ]; then
    printf 'closing\n'
  else
    printf 'ok\n'
  fi
}

# jg_pf_b64_encode: stdin to a single-line base64 payload (no wrapping).
jg_pf_b64_encode() {
  base64 2>/dev/null | tr -d '\n\r'
}

# jg_pf_b64_decode: stdin (single-line or wrapped base64) to bytes on stdout.
jg_pf_b64_decode() {
  local data
  data=$(cat)
  printf '%s\n' "$data" | base64 -d 2>/dev/null \
    || printf '%s\n' "$data" | base64 -D 2>/dev/null
}

# jg_pf_registry_loop_state <state> <id>: open or delivered. A pre-change
# record with no state= is treated as open so live homes never crash.
jg_pf_registry_loop_state() {
  local v
  v=$(jg_pf_registry_get "$1" "$2" state)
  case "$v" in
    delivered) printf 'delivered\n' ;;
    *) printf 'open\n' ;;
  esac
}

# jg_pf_registry_rechainable <state> <id>: 0 when request_context_b64 is present.
jg_pf_registry_rechainable() {
  local ctx
  ctx=$(jg_pf_registry_get "$1" "$2" request_context_b64)
  [ -n "$ctx" ]
}

# jg_pf_has_delivered_open_loops <state>: 0 when any retained record is
# state=delivered (an open loop with nothing owed). Pre-change records have no
# state= and are treated as still-owed, not delivered.
jg_pf_has_delivered_open_loops() {
  local state=$1 id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(jg_pf_registry_get "$state" "$id" state)" = delivered ] || continue
    return 0
  done <<EOF
$(jg_pf_registry_ids "$state")
EOF
  return 1
}

jg_pf_registry_lock_path() {
  printf '%s/.registry-%s.lock\n' "$(jg_pf_root "$1")" "$2"
}

jg_pf_registry_lock_acquire() {
  local state=$1 id=$2
  jg_pf_slug_valid "$id" || return 1
  fmx_private_artifact_dir_prepare "$(jg_pf_root "$state")" >/dev/null || return 1
  if ! command -v jg_lock_acquire_wait >/dev/null 2>&1; then
    # shellcheck source=bin/jg-wake-lib.sh
    . "$_JG_PF_LIB_DIR/jg-wake-lib.sh"
  fi
  jg_lock_acquire_wait "$(jg_pf_registry_lock_path "$state" "$id")"
}

jg_pf_registry_lock_release() {
  jg_lock_release "$(jg_pf_registry_lock_path "$1" "$2")"
}

# jg_pf_registry_stamp_delivered <state> <id> <rfc3339>: rewrite one record
# with state=delivered and delivered_at, keeping every other field. The record
# stays; only retire removes it.
jg_pf_registry_stamp_delivered() {
  local state=$1 id=$2 delivered_at=$3 file rest rc=0
  jg_pf_slug_valid "$id" || return 1
  [ -n "$delivered_at" ] || return 1
  jg_pf_registry_lock_acquire "$state" "$id" || return 1
  file="$(jg_pf_registry_dir "$state")/$id"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    rest=$(grep -v -E '^(state|delivered_at|delivered_obligation)=' "$file" 2>/dev/null || true)
    printf '%s\nstate=delivered\ndelivered_at=%s\ndelivered_obligation=%s\n' \
      "$rest" "$delivered_at" "$id" \
      | fmx_private_artifact_publish_stdin "$(jg_pf_registry_dir "$state")" "$id" 600 \
      || rc=$?
  else
    rc=3
  fi
  jg_pf_registry_lock_release "$state" "$id"
  return "$rc"
}

# --- pending-event signature ------------------------------------------------

# Consumed by the sourcing scripts, not by this library.
# shellcheck disable=SC2034
JG_PF_SURFACED_BASENAME=surfaced

# jg_pf_events_signature <state>: a stable digest of the pending event id set.
# The relay poll compares it against the surfaced record so an unconsumed event
# wakes juggernaut once per new event, not once per poll cycle.
jg_pf_events_signature() {
  local dir entry pending_names=
  dir=$(jg_pf_events_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for entry in "$dir"/*.json; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    pending_names="$pending_names$(basename "$entry")
"
  done
  [ -n "$pending_names" ] || return 1
  printf '%s' "$pending_names" | LC_ALL=C sort | jg_pf_sha256
}
