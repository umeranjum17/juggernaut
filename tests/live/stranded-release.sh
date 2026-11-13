#!/usr/bin/env bash
# Live check 8 (stop 7, every 5 min): a release that open tickets wait for does not sit ready. data/release-readiness/state.jsonl rows
# are {at,state,...}; the current run of `ready` rows older than JG_LIVE_RELEASE_S (default 14400, the 4 h limit) is red.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=${JG_LIVE_RELEASE_S:-14400}; now=$(live_now); rows=$DATA/release-readiness/state.jsonl
[ -s "$rows" ] || live_pass "no release record"
state=$(tail -n 1 "$rows" | jq -r '.state // empty')
[ "$state" = ready ] || live_pass "release is ${state:-unknown}, nothing is stranded"
since=$(jq -rs 'reverse | . as $r | ([range(0; length)] | map(select($r[.].state != "ready")) | first // length) as $i | $r[:$i] | last | .at // empty' "$rows")
[ -n "$since" ] || live_pass "release ready, no start time"
[ $((now - since)) -le "$limit" ] || live_red "release ready for $((now - since))s, over ${limit}s"
live_pass "release ready for $((now - since))s of ${limit}s"
