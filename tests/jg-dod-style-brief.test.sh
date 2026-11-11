#!/usr/bin/env bash
# Behavior test: the four per-mode brief texts (first ship rule and Definition of done) come out byte-equal to the recorded golden
# while jg-dod-lib.sh reads the delivery-style table for what each mode word means. An unknown mode is still refused.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GOLDEN="$ROOT/tests/fixtures/dod-style-brief/brief.golden"

render() {
  export JG_HOME=/jg-home
  # shellcheck source=bin/jg-dod-lib.sh
  . "$ROOT/bin/jg-dod-lib.sh"
  local m
  for m in no-mistakes direct-PR local-only local-trunk; do
    printf '=== %s\n' "$m"
    jg_ship_rule_one "$m" tid fm/tid none ''
    jg_dod_block "$m" tid fm/tid none ''
  done
  printf '=== no-mistakes on a base branch\n'
  jg_ship_rule_one no-mistakes tid fm/tid none feat/x
  printf '=== direct-PR on gerrit\n'
  jg_dod_block direct-PR tid fm/tid gerrit ''
}
actual=$(render 2>&1 | sed "s#$ROOT#ROOT#g")
if [ "${JG_UPDATE_GOLDEN:-}" = 1 ]; then printf '%s\n' "$actual" > "$GOLDEN"; fi
assert_equals "$(cat "$GOLDEN")" "$actual" "the per-mode brief texts match the golden byte for byte"
pass "the four per-mode brief texts ($(grep -c '^=== ' "$GOLDEN") sections, $(wc -l < "$GOLDEN") lines) are byte-equal to the golden recorded before the change"

(
  . "$ROOT/bin/jg-dod-lib.sh"
  jg_dod_block bogus tid fm/tid none '' >/dev/null 2>&1; [ $? -eq 1 ] || exit 1
  jg_dod_block local-only tid fm/tid gerrit '' >/dev/null 2>&1; [ $? -eq 1 ] || exit 2
  jg_dod_block local-trunk tid fm/tid none '' github.com/a/b >/dev/null 2>&1; [ $? -eq 1 ] || exit 3
  jg_dod_block direct-PR tid fm/tid none feat/x >/dev/null 2>&1 || exit 4
  jg_dod_block local-only tid fm/tid none feat/x >/dev/null 2>&1; [ $? -eq 1 ] || exit 5
  jg_delivery_style_is local-trunk local && ! jg_delivery_style_is direct-PR local && ! jg_delivery_style_is bogus local || exit 6
)
expect_code 0 "$?" "unknown mode, forge, consent and base-branch refusals follow the table"
pass "dod reads the delivery-style table"
