#!/usr/bin/env bash
# End-to-end: run undelivered-alert.sh against a fixture home. The first run records the count and stays
# silent; a new row (whose text holds a raw newline) raises the undelivered alert once with its kind, key and reason; a repeat
# poll is silent; a second new row wakes again; a rotated file stays silent; wiring.sh --dry-run writes nothing.
# Usage: undelivered-alert/tests/undelivered-alert.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
FM=$d/fm; mkdir -p "$FM/state"
R=$FM/state/captain-channel-undelivered.jsonl
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
# poll prints the note of each alert wake the check newly raised: the payload's text after " - ".
poll() {  # the offset lives in a file: poll runs in a command substitution
  local seen; seen=$(cat "$d/seen" 2>/dev/null || echo 0)
  JG_HOME="$FM" "$SRC/undelivered-alert.sh" check "$FM" 2>&1
  [ -f "$FM/state/.wake-queue" ] || return 0
  tail -n +$((seen + 1)) "$FM/state/.wake-queue" | awk -F'\t' '$3=="check" && $4 ~ /^alert-undelivered--/ {sub(/^.* - undelivered-alert:/, "undelivered-alert:", $5); sub(/ +$/, "", $5); print $5}'
  wc -l < "$FM/state/.wake-queue" > "$d/seen"
}
row() { printf '{"at":1,"target":"http://x","error":"%s","event":{"at":1,"kind":"%s","key":"%s","subject":"s","text":"line one\nline two"}}\n' "$1" "$2" "$3"; }

check "no row file stays silent" "$(poll)" ""
row "old reason" outcome old-key > "$R"
check "first run records the count and stays silent" "$(poll)" ""
row "voice check refused: link not in the original https://x/1, cut" outcome new-card-1 >> "$R"
want='undelivered-alert: 1 captain message(s) not delivered; newest: kind=outcome key=new-card-1 reason=voice check refused: link not in the original https://x/1, cut. Re-word and send it through the normal path.'
check "a new row wakes once with kind, key and reason" "$(poll)" "$want"
check "a repeat poll is silent" "$(poll)" ""
row "gateway down" decision ask-2 >> "$R"
check "a second new row wakes again" "$(poll | sed -n 's/.*newest: \(kind=[a-z]* key=[a-z0-9-]*\) .*/\1/p')" "kind=decision key=ask-2"
row "fresh" outcome after-rotate > "$R"
check "a rotated file stays silent" "$(poll)" ""
mkdir -p "$FM/bin"; printf '#!/bin/sh\n' > "$FM/bin/jg-check-register.sh"; chmod +x "$FM/bin/jg-check-register.sh"
HOME=$d "$SRC/wiring.sh" --dry-run "$FM" >/dev/null
check "wiring --dry-run writes nothing" "$(find "$FM/state" -name '*.check.sh' | wc -l | tr -d ' ')" 0
[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
