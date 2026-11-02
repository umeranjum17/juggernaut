#!/usr/bin/env bash
# tests/jg-doorbell-missing-record.test.sh - a record-backed operational
# doorbell is dropped, never delivered, when the record it names is gone.
# Drives the real text submit against a real tmux pane (private socket) whose
# process is `cat`, so what the pane's program received is the delivery proof.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="jg-doorbell-missing-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jg-doorbell-missing.XXXXXX")
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/jg-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-operational-input.sh"
jg_backend_source tmux || fail "jg_backend_source tmux failed"

tmux new-session -d -s doorbell -x 200 -y 50 -n w || fail "tmux new-session failed"
TARGET=doorbell:w

# Start a pane program that records exactly what the pane delivers to it.
start_reader() {  # <out-file>
  : > "$1"
  tmux respawn-pane -k -t "$TARGET" "cat > '$1'" || fail "could not start the reader pane"
  sleep 0.3
}

# A fresh record and the doorbell naming it.
new_ring() {  # <state-dir> <doorbell-var> <record-var>
  local doorbell named
  jg_operational_record_write "$1" watcher "wake body" doorbell || fail "could not write a record"
  jg_operational_doorbell_path "$doorbell" named || fail "the doorbell names no record path"
  printf -v "$2" '%s' "$doorbell"
  printf -v "$3" '%s' "$named"
}

# --- ring time: a ring for a missing id is dropped before it is typed ------------
new_ring "$WORK/state" ring record
rm -f -- "$record"
start_reader "$WORK/ring-time.out"
verdict=$(jg_backend_send_text_submit tmux "$TARGET" "$ring" 2 0.2 0.2)
sleep 0.5
[ "$verdict" = record-missing ] || fail "a ring for a missing record answered '$verdict', not record-missing"
[ ! -s "$WORK/ring-time.out" ] || fail "a ring for a missing record reached the pane: $(cat "$WORK/ring-time.out")"
pass "a ring for a missing record is dropped before it is typed"

# --- delivery time: the record vanishes between typing and Enter ----------------
new_ring "$WORK/state" ring record
start_reader "$WORK/delivery-time.out"
( sleep 0.4; rm -f -- "$record" ) &
remover=$!
verdict=$(jg_backend_send_text_submit tmux "$TARGET" "$ring" 2 0.2 1.2)
wait "$remover"
sleep 0.5
[ ! -s "$WORK/delivery-time.out" ] || fail "a ring whose record vanished mid-delivery was submitted: $(cat "$WORK/delivery-time.out")"
[ "$verdict" != empty ] || fail "a ring whose record vanished mid-delivery reported delivery"
pass "a ring whose record vanishes before Enter is cleared, not submitted (verdict $verdict)"

# --- a live record still rings --------------------------------------------------
new_ring "$WORK/state" ring record
start_reader "$WORK/live.out"
jg_backend_send_text_submit tmux "$TARGET" "$ring" 2 0.2 0.2 >/dev/null
sleep 0.5
[ "$(cat "$WORK/live.out")" = "$ring" ] || fail "a ring for a live record did not reach the pane: $(cat "$WORK/live.out")"
pass "a ring for a live record is delivered"
