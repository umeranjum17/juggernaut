#!/usr/bin/env bash
# A merge proof card's title must be the outcome sentence a reader can act on, never the
# generic "internal change passed its checks" (core/merge-card/README.md).
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
T=$(jg_test_tmproot merge-card-title)
for t in card-title retitle-old-cards; do
  bash "$ROOT/core/merge-card/tests/$t.test.sh" >"$T/$t.log" 2>&1 ||
    fail "core/merge-card/tests/$t.test.sh failed: $(tail -n 3 "$T/$t.log")"
done
pass "merge proof cards are titled with the outcome sentence"
