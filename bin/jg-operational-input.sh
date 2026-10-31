#!/usr/bin/env bash
# jg-operational-input.sh - canonical Juggernaut operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 JUGGERNAUT_OP: v1 <kind>: <body>
#
# The landed U+2063 + "JUGGERNAUT_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-juggernaut routing
# marker remains a current compatibility carrier because already-running
# squad_leads have its leading label in their charter context.
#
# Record-backed carrier. Some harnesses remove invisible characters, U+2063
# included, from every submitted prompt (Claude Code 2.1.280 does so for typed,
# pasted, and launch-prompt input), so a typed envelope reaches them as plain
# ASCII that no consumer can tell apart from human text. For a harness named in
# JG_OPERATIONAL_RECORD_HARNESSES a producer instead writes the complete current
# envelope to a durable record and types only a constant ASCII doorbell naming
# it. The doorbell text alone proves nothing: it counts as Juggernaut input only
# when the record it names exists and holds a current generic envelope. Records
# are not consumed on delivery, so a verbatim copy of a live doorbell line,
# pasted back by anyone while its record exists, is treated as Juggernaut's.
#   Record:   <state>/operational-inbox/<name>.msg, <name> matching [0-9a-z-]+,
#             exactly the encoded envelope bytes, published by atomic rename.
#             Records are never re-rung or acknowledged; every write prunes
#             records at about JG_OPERATIONAL_RECORD_RETENTION_DAYS (7) elapsed days.
#   Doorbell: JG_OPERATIONAL_DOORBELL_PREFIX <absolute physical record path>
#             JG_OPERATIONAL_DOORBELL_SUFFIX, one printable-ASCII line whose
#             leading ": " is the shell no-op, as for the steering doorbell.
# Verification has two strengths: jg_operational_doorbell_record_kind checks only
# the named record, which presentation-only consumers mirror (the Claude Code
# Calm mod), while jg_operational_doorbell_kind also requires the record to sit in
# the given home's own operational inbox, which the away-mode return check uses.
# `doorbell-shaped` is the third, weakest strength and touches no filesystem: its
# first line starts with the doorbell prefix. A counter that must never mistake a
# doorbell for a typed captain message uses it, so a new doorbell wording that
# stops matching the full line cannot slip a false record in.
#
# CLI:
#   jg-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   jg-operational-input.sh kind           # current input on stdin, kind stdout
#   jg-operational-input.sh classify       # current or legacy input on stdin
#   jg-operational-input.sh body           # current generic input on stdin
#   jg-operational-input.sh record <kind>  # body on stdin, doorbell stdout
#   jg-operational-input.sh doorbell-kind  # doorbell on stdin, record kind stdout
#   jg-operational-input.sh doorbell-shaped # doorbell line on stdin, exit 0
#   jg-operational-input.sh open <path>    # this home's record body stdout
#   jg-operational-input.sh --help
#
# `record` and `open` resolve this home's state as JG_STATE_OVERRIDE, else
# ${JG_HOME:-${JG_ROOT_OVERRIDE:-<code root>}}/state. `classify` stays a pure text
# classifier: a doorbell is recognized only through `doorbell-kind` or `open`.
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d

JG_OPERATIONAL_MARK=$'\xE2\x81\xA3'
JG_OPERATIONAL_PREFIX="${JG_OPERATIONAL_MARK}JUGGERNAUT_OP: "
JG_OPERATIONAL_VERSION=v1
JG_OPERATIONAL_HEADER_PREFIX="${JG_OPERATIONAL_PREFIX}${JG_OPERATIONAL_VERSION} "
# Compatibility (slice S5): a supervisor and its worker can be on opposite
# sides of the update, so a marshalled message may still carry the marker's
# pre-rename spelling. Readers accept either; writers emit this one.
JG_OPERATIONAL_LEGACY_PREFIX="${JG_OPERATIONAL_MARK}$(jg_compat_legacy_product JUGGERNAUT_OP): "
JG_OPERATIONAL_LEGACY_HEADER_PREFIX="${JG_OPERATIONAL_LEGACY_PREFIX}${JG_OPERATIONAL_VERSION} "
JG_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome'

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
JG_INJECT_MARK=$JG_OPERATIONAL_MARK

# The from-juggernaut carrier stays byte-compatible with live squad_lead charter
# context while this owner supplies its construction and structural kind.
JG_FROMFIRST_LABEL='[jg-from-juggernaut]'
JG_FROMFIRST_SEPARATOR=$JG_OPERATIONAL_MARK
JG_FROMFIRST_MARK="${JG_FROMFIRST_LABEL}${JG_FROMFIRST_SEPARATOR}"

jg_operational_kind_is_current() {  # <kind>
  case " $JG_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

jg_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  jg_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  printf -v "$result_var" '%s%s: %s' "$JG_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

jg_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-juggernaut ]; then
    jg_message_mark_from_juggernaut "$body" "$result_var"
    return
  fi
  jg_operational_input_encode "$kind" "$body" "$result_var"
}

jg_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$JG_OPERATIONAL_HEADER_PREFIX"*': '*) ;;
    "$JG_OPERATIONAL_LEGACY_HEADER_PREFIX"*': '*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$JG_OPERATIONAL_HEADER_PREFIX"}
  [ "$remainder" != "$message" ] || remainder=${message#"$JG_OPERATIONAL_LEGACY_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  jg_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

jg_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if jg_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$JG_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-juggernaut
      return 0
      ;;
  esac
  return 1
}

jg_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if jg_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${JG_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    [ "$parsed_body" != "$message" ] || parsed_body=${message#"${JG_OPERATIONAL_LEGACY_HEADER_PREFIX}${current_kind}: "}
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$JG_FROMFIRST_MARK"?*)
      parsed_body=${message#"$JG_FROMFIRST_MARK"}
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
JG_LEGACY_SESSIONSTART='Run `bin/jg-session-start.sh` now, exactly once, before executing any other instructions.'
JG_LEGACY_WATCHER_PREFIX='JUGGERNAUT WATCHER WAKE: '
JG_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/jg-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
JG_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
JG_LEGACY_AWAY_PREFIX="${JG_OPERATIONAL_MARK}Supervisor escalate ("

jg_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped JUGGERNAUT_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$JG_OPERATIONAL_PREFIX"?* | "$JG_OPERATIONAL_LEGACY_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$JG_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$JG_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$JG_LEGACY_WATCHER_PREFIX"*"$JG_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#JG_LEGACY_WATCHER_PREFIX} + ${#JG_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$JG_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

jg_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if jg_operational_input_kind "$message" classified_kind ||
     jg_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

jg_message_from_juggernaut() {  # <message>
  local kind
  jg_operational_input_kind "${1-}" kind && [ "$kind" = from-juggernaut ]
}

jg_message_mark_from_juggernaut() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if jg_message_from_juggernaut "$message"; then
    transformed=$message
  else
    transformed="${JG_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

# --- record-backed carrier (see header) ---------------------------------------
JG_OPERATIONAL_RECORD_HARNESSES='claude'
JG_OPERATIONAL_RECORD_DIRNAME='operational-inbox'
JG_OPERATIONAL_DOORBELL_PREFIX=": Juggernaut operational input waiting: read '"
JG_OPERATIONAL_DOORBELL_SUFFIX="' and handle its contents as Juggernaut operational input."
JG_OPERATIONAL_RECORD_RETENTION_DAYS=7

# Whether operational input to <harness> must travel as a record plus doorbell.
jg_operational_harness_needs_record() {  # <harness>
  case " $JG_OPERATIONAL_RECORD_HARNESSES " in
    *" ${1-} "*) return 0 ;;
  esac
  return 1
}

jg_operational_record_prune() {  # <record-dir>
  local stat_cmd path mtime cutoff
  if [ "$(uname)" = Darwin ]; then
    stat_cmd=(/usr/bin/stat -f '%m %N')
  else
    stat_cmd=(stat -c '%Y %n')
  fi
  cutoff=$(( $(date +%s) - JG_OPERATIONAL_RECORD_RETENTION_DAYS * 86400 ))
  find "$1" -maxdepth 1 -type f \( -name '*.msg' -o -name '.record.*' \) \
    -exec "${stat_cmd[@]}" {} + 2>/dev/null | while read -r mtime path; do
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -lt "$cutoff" ]; then printf '%s\0' "$path"; fi
  done | xargs -0 rm -f
  return 0
}

# Write one generic-kind record under <state-dir> and return its doorbell line.
# Exits 2 for invalid input and 1 when the record cannot be published or its
# physical path cannot be carried by a printable-ASCII doorbell.
jg_operational_record_write() {  # <state-dir> <kind> <body> <doorbell-var>
  local state=${1-} kind=${2-} body=${3-} result_var=${4-} encoded dir abs nonce name tmp
  local LC_ALL=C
  [ -n "$state" ] && [ -n "$result_var" ] || return 2
  jg_operational_input_encode "$kind" "$body" encoded || return 2
  dir="$state/$JG_OPERATIONAL_RECORD_DIRNAME"
  mkdir -p "$dir" 2>/dev/null || return 1
  abs=$(cd -P "$dir" 2>/dev/null && pwd -P) || return 1
  case "$abs" in
    *"'"*|*[![:print:]]*) return 1 ;;
  esac
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$nonce" in ''|*[!0-9a-f]*) return 1 ;; esac
  name="$(date +%s)-$nonce.msg"
  tmp=$(mktemp "$dir/.record.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$encoded" >"$tmp" || ! mv -f "$tmp" "$dir/$name"; then
    rm -f "$tmp"
    return 1
  fi
  jg_operational_record_prune "$dir"
  printf -v "$result_var" '%s%s/%s%s' "$JG_OPERATIONAL_DOORBELL_PREFIX" "$abs" "$name" \
    "$JG_OPERATIONAL_DOORBELL_SUFFIX"
}

# The record path a well-formed doorbell names; no filesystem access.
jg_operational_doorbell_path() {  # <message> <result-var>
  local message=${1-} result_var=${2-} candidate dir name
  local LC_ALL=C
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$JG_OPERATIONAL_DOORBELL_PREFIX"*"$JG_OPERATIONAL_DOORBELL_SUFFIX") ;;
    *) return 1 ;;
  esac
  candidate=${message#"$JG_OPERATIONAL_DOORBELL_PREFIX"}
  candidate=${candidate%"$JG_OPERATIONAL_DOORBELL_SUFFIX"}
  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$candidate" in
    *"'"*|*[![:print:]]*) return 1 ;;
  esac
  dir=${candidate%/*}
  name=${candidate##*/}
  [ "${dir##*/}" = "$JG_OPERATIONAL_RECORD_DIRNAME" ] || return 1
  case "$name" in
    *.msg) name=${name%.msg} ;;
    *) return 1 ;;
  esac
  case "$name" in
    ''|*[!0-9a-z-]*) return 1 ;;
  esac
  printf -v "$result_var" '%s' "$candidate"
}

# The generic kind of the envelope a record holds.
jg_operational_record_kind() {  # <record-path> <result-var>
  local record=${1-} result_var=${2-} record_content
  [ -n "$result_var" ] || return 2
  [ -f "$record" ] || return 1
  record_content=$(cat "$record" 2>/dev/null && printf x) || return 1
  jg_operational_generic_kind "${record_content%x}" "$result_var"
}

# Whether <message>'s first line starts with the doorbell prefix. No filesystem
# access and no record check: shape alone.
jg_operational_doorbell_shaped() {  # <message>
  local message=${1-} first
  case "$message" in
    "$JG_OPERATIONAL_DOORBELL_PREFIX"*) return 0 ;;
    *$'\n'*)
      first=${message%%$'\n'*}
      case "$first" in
        "$JG_OPERATIONAL_DOORBELL_PREFIX"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# <message> with every leading doorbell-shaped line removed: what remains is the
# captain's own text when a doorbell was left in his composer and his next
# sentence was submitted glued onto it (captured in a real primary's message box). Returns 1
# and prints nothing when the first line is not a doorbell, so a caller can tell
# the two apart; otherwise prints the remainder, even when it is empty.
jg_operational_strip_doorbell() {  # <message> <result-var>
  local message=${1-} result_var=${2-} first
  [ -n "$result_var" ] || return 2
  first=${message%%$'\n'*}
  case "$first" in
    "$JG_OPERATIONAL_DOORBELL_PREFIX"*) ;;
    *) printf -v "$result_var" '%s' "$message"; return 1 ;;
  esac
  while :; do
    first=${message%%$'\n'*}
    case "$first" in
      "$JG_OPERATIONAL_DOORBELL_PREFIX"*) ;;
      *) break ;;
    esac
    case "$message" in
      *$'\n'*) message=${message#*$'\n'} ;;
      *) message= ;;
    esac
  done
  printf -v "$result_var" '%s' "$message"
}

# A doorbell whose named record exists and holds a current generic envelope.
jg_operational_doorbell_record_kind() {  # <message> <result-var>
  local named_record
  jg_operational_doorbell_path "${1-}" named_record || return 1
  jg_operational_record_kind "$named_record" "${2-}"
}

# The same, bound to <state-dir>: the record must sit in that home's own inbox.
jg_operational_doorbell_kind() {  # <message> <state-dir> <result-var>
  local message=${1-} state=${2-} result_var=${3-} named_record want have
  [ -n "$state" ] && [ -n "$result_var" ] || return 2
  jg_operational_doorbell_path "$message" named_record || return 1
  want=$(cd -P "$state/$JG_OPERATIONAL_RECORD_DIRNAME" 2>/dev/null && pwd -P) || return 1
  have=$(cd -P "${named_record%/*}" 2>/dev/null && pwd -P) || return 1
  [ "$want" = "$have" ] || return 1
  jg_operational_record_kind "$named_record" "$result_var"
}

jg_operational_home_state() {
  local root
  if [ -n "${JG_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$JG_STATE_OVERRIDE"
    return
  fi
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
  printf '%s/state' "${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}"
}

jg_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

jg_operational_usage() {
  cat <<'EOF'
Usage:
  bin/jg-operational-input.sh encode <kind>  # body on stdin
  bin/jg-operational-input.sh kind           # current input on stdin
  bin/jg-operational-input.sh classify       # current or legacy input on stdin
  bin/jg-operational-input.sh body           # current input on stdin
  bin/jg-operational-input.sh record <kind>  # body on stdin; prints the doorbell
  bin/jg-operational-input.sh doorbell-kind  # doorbell on stdin; record's kind
  bin/jg-operational-input.sh doorbell-shaped # doorbell-shaped text on stdin; exit 0
  bin/jg-operational-input.sh strip-doorbell  # text on stdin; leading doorbell lines removed
  bin/jg-operational-input.sh open <path>    # this home's record; prints its body

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-juggernaut launch-brief
  branch-outcome

`doorbell-shaped` reads shape only: the first line starts with the doorbell
prefix. It proves nothing about a record, so use it only where a false positive
costs nothing and a false negative is a bug - a counter that must not record a
doorbell as a typed captain message.

`strip-doorbell` removes every leading doorbell-shaped line and prints what is
left, so a message the captain submitted glued after a stuck doorbell is still
his own words. A message whose first line is not a doorbell is printed
unchanged and exits 1.

The from-juggernaut kind uses its established live-charter-compatible carrier.
A record-backed doorbell counts as operational input only when the record it
names holds a current generic envelope; `open` also requires that record to be
in this home's own state/operational-inbox.
EOF
}

jg_operational_main() {
  local command=${1-} argument=${2-} input output state rc
  case "$command" in
    -h|--help|help)
      jg_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      jg_operational_read_stdin input || return 2
      jg_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      jg_operational_read_stdin input || return 2
      jg_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      jg_operational_read_stdin input || return 2
      jg_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      jg_operational_read_stdin input || return 2
      jg_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    record)
      [ "$#" -eq 2 ] || return 2
      jg_operational_read_stdin input || return 2
      state=$(jg_operational_home_state) || return 1
      jg_operational_record_write "$state" "$argument" "$input" output || return
      printf '%s\n' "$output"
      ;;
    doorbell-kind)
      [ "$#" -eq 1 ] || return 2
      jg_operational_read_stdin input || return 2
      jg_operational_doorbell_record_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    doorbell-shaped)
      [ "$#" -eq 1 ] || return 2
      jg_operational_read_stdin input || return 2
      jg_operational_doorbell_shaped "$input" || return 1
      ;;
    strip-doorbell)
      [ "$#" -eq 1 ] || return 2
      jg_operational_read_stdin input || return 2
      if jg_operational_strip_doorbell "$input" output; then rc=0; else rc=1; fi
      printf '%s' "$output"
      return "$rc"
      ;;
    open)
      [ "$#" -eq 2 ] || return 2
      state=$(jg_operational_home_state) || return 1
      jg_operational_doorbell_kind "${JG_OPERATIONAL_DOORBELL_PREFIX}${argument}${JG_OPERATIONAL_DOORBELL_SUFFIX}" \
        "$state" output || return 1
      input=$(cat "$argument" 2>/dev/null && printf x) || return 1
      jg_operational_input_body "${input%x}" output || return 1
      printf '%s' "$output"
      ;;
    *)
      jg_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  jg_operational_main "$@"
  exit $?
fi
