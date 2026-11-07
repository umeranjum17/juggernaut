#!/usr/bin/env bash
# Receive one delivered remote-squad-lead outbox into this home's backlog.
#
# Usage:
#   jg-backlog-receive.sh state/handoff/<squad-lead-id>.outbox.md <bytes> <sha256> <generation>
#   jg-backlog-receive.sh --check    exits 3 with the reason when this home cannot file rows
#
# The delivered file must be a non-symlink backlog-format scratch file confined
# to JG_HOME/state/handoff. Every item must be Queued. Every delivered key is
# filed through the Beads store's own take verb, which a retry repeats with no
# effect. On confirmed receipt the delivered scratch file is removed; no other
# path is deletable.
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
DEST="$JG_HOME/data/backlog.md"

# shellcheck source=bin/jg-tasks-axi-lib.sh
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

backlog_key_section() { # <file> <key>
  awk -v key="$2" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ { section=$0; sub(/^##[[:space:]]+/, "## ", section); sub(/[[:space:]]+$/, "", section); next }
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id == key) { print section; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

list_keys() { # <file>
  awk '
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id != "" && !seen[id]++) print id
    }
  ' "$1"
}

if [ "$#" -eq 1 ] && [ "$1" = --check ]; then
  jg_backlog_beads_health "$JG_HOME/config" >&2 || { echo "error: this home's Beads store cannot file rows" >&2; exit 3; }
  exit 0
fi
[ "$#" -eq 4 ] || usage
REL=$1
EXPECTED_BYTES=$2
EXPECTED_HASH=$3
GENERATION=$4
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes are outside the supported range"
[ "$EXPECTED_BYTES" -le 1048576 ] || die "expected bytes are outside the supported range"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
case "$REL" in state/handoff/*.outbox.md) ;; *) die "delivered outbox path is outside state/handoff: $REL" ;; esac
case "/$REL/" in */../*|*/./*) die "delivered outbox path contains traversal" ;; esac
case "$REL" in *'//'*) die "delivered outbox path is malformed" ;; esac
[ -f "$(jg_compat_marker "$JG_HOME")" ] && [ ! -L "$(jg_compat_marker "$JG_HOME")" ] \
  || die "JG_HOME is not a seeded squad_lead home"
[ -f "$JG_HOME/AGENTS.md" ] && [ -d "$JG_HOME/bin" ] || die "JG_HOME is not a Juggernaut home"
HOME_REAL=$(CDPATH='' cd -- "$JG_HOME" 2>/dev/null && pwd -P) || die "JG_HOME cannot be resolved"
PARENT=$(dirname "$JG_HOME/$REL")
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" 2>/dev/null && pwd -P) || die "delivered outbox parent is unavailable"
case "$PARENT_REAL" in "$HOME_REAL/state/handoff") ;; *) die "delivered outbox escapes the remote scratch directory" ;; esac
DELIVERED="$PARENT_REAL/$(basename "$REL")"
NAME=$(basename "$REL")
ID=${NAME%.outbox.md}
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "delivered outbox id is unsafe" ;; esac
TRANSFER_LOCK="$PARENT_REAL/.$ID.upload.lock"
jg_lock_acquire_wait "$TRANSFER_LOCK" || die "cannot lock delivered outbox"
trap 'jg_lock_release "$TRANSFER_LOCK" || true' EXIT
[ -f "$DELIVERED" ] && [ ! -L "$DELIVERED" ] || die "delivered outbox is not a non-symlink regular file"
GENERATION_FILE="$PARENT_REAL/.$ID.upload-generation"
[ -f "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] || die "delivered outbox generation is unavailable or unsafe"
{
  IFS= read -r STORED_GENERATION \
    && IFS= read -r STORED_BYTES \
    && IFS= read -r STORED_HASH \
    && ! IFS= read -r
} < "$GENERATION_FILE" || die "delivered outbox generation is malformed"
case "$STORED_GENERATION" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_GENERATION}" -le 18 ] || die "delivered outbox generation is malformed"
case "$STORED_BYTES" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
case "$STORED_HASH" in ''|*[!A-Fa-f0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_HASH}" -eq 64 ] || die "delivered outbox generation is malformed"
[ "$STORED_GENERATION" = "$GENERATION" ] \
  && [ "$STORED_BYTES" = "$EXPECTED_BYTES" ] \
  && [ "$STORED_HASH" = "$EXPECTED_HASH" ] \
  || die "delivered outbox generation is superseded or conflicting"
ACTUAL_BYTES=$(LC_ALL=C wc -c < "$DELIVERED" | tr -d ' ')
[ "$ACTUAL_BYTES" -eq "$EXPECTED_BYTES" ] || die "delivered outbox length does not match its commitment"
ACTUAL_HASH=$(sha256_file "$DELIVERED") || die "cannot hash delivered outbox"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "delivered outbox digest does not match its commitment"
DEST="$PARENT_REAL/.$ID.store-view.md"
jg_backlog_beads_read "$JG_HOME/config" markdown > "$DEST" || die "this home's Beads store cannot be read; delivered outbox is preserved for retry"
[ ! -L "$DEST" ] || die "destination backlog must not be a symlink"
if [ -e "$DEST" ] && [ ! -f "$DEST" ]; then die "destination backlog is not a regular file"; fi

KEYS=()
while IFS= read -r key; do
  [ -n "$key" ] && KEYS+=("$key")
done < <(list_keys "$DELIVERED")
for key in "${KEYS[@]}"; do
  section=$(backlog_key_section "$DELIVERED" "$key") || die "delivered key disappeared during classification: $key"
  [ "$section" = '## Queued' ] || die "delivered outbox contains non-Queued item $key under $section"
done

TO_MOVE=()
ALREADY=()
for key in "${KEYS[@]}"; do
  if backlog_key_section "$DEST" "$key" >/dev/null 2>&1; then
    ALREADY+=("$key")
  else
    TO_MOVE+=("$key")
  fi
done

if ! MOVE_OUT=$(jg_backlog_beads_write "$JG_HOME/config" take "$DELIVERED" "${KEYS[@]}" 2>&1); then
  [ -z "$MOVE_OUT" ] || printf '%s\n' "$MOVE_OUT" >&2
  die "backlog receipt failed; delivered outbox is preserved for retry"
fi
jg_backlog_beads_read "$JG_HOME/config" markdown > "$DEST" || die "receipt verification could not read the store; delivered outbox is preserved"

for key in "${KEYS[@]}"; do
  backlog_key_section "$DEST" "$key" >/dev/null 2>&1 \
    || die "receipt verification failed for $key; delivered outbox is preserved"
done
rm -f -- "$DEST"
rm -f -- "$DELIVERED" || die "receipt succeeded but delivered scratch cleanup failed"
jg_lock_release "$TRANSFER_LOCK" || die "receipt succeeded but transfer lock cleanup failed"
trap - EXIT
printf 'received: %s moved=%s already=%s\n' "$(basename "$REL" .outbox.md)" "${#TO_MOVE[@]}" "${#ALREADY[@]}"
