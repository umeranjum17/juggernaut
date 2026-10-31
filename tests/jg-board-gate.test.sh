#!/usr/bin/env bash
# tests/jg-board-gate.test.sh - the board-ask gate and its scheduled checks: a
# non-must ask is refused and routed to Overwatch, a must ask is posted and
# counted, and the check re-pings an old must ask while it moves an old or
# unclassified one off the board (bin/jg-ask-gate-lib.sh, bin/jg-board-gate.sh,
# bin/jg-question-card.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-board-gate)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CARD="$ROOT/bin/jg-question-card.sh"
GATE="$ROOT/bin/jg-board-gate.sh"
NOW=1793350000

setup() {  # <name> -> the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/fakebin" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  list) jq -c '{decisions: [.items[]]}' "$board" ;;
  dismiss)
    printf 'dismiss %s\n' "$1" >> "$SIGNOFF_LOG"
    jq --arg k "$1" '.items = [.items[] | if .key == $k then . + {dismissed: true} else . end]' "$board" > "$board.t" && mv "$board.t" "$board" ;;
  raise)
    key='' title='' detail=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --key) key=$2; shift ;; --title) title=$2; shift ;; --detail) detail=$2; shift ;; esac
      shift
    done
    jq --arg k "${key:-card}" --arg t "$title" --arg d "$detail" --arg f "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
      '.items += [{key: $k, kind: "decision", title: $t, detail: $d, filed: $f}]' "$board" > "$board.t" && mv "$board.t" "$board"
    printf '%s\n' "${key:-card}" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  printf '%s\n' "$d"
}

with_env() {  # <case dir> <command...>
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" \
    SIGN_OFF_HOME="$d/so" SIGNOFF_LOG="$d/signoff.log" JG_BOARD_GATE_NOW="$NOW" \
    JG_BOARD_GATE_REFIRE_SECS=0 "$@"
}

run() { with_env "$@" 2>&1; }  # <case dir> <command...> -> both streams

# `post` prints the card key alone on stdout and its own diagnostics, including
# the card-rule measurement, on stderr. A key read from the merged streams is a
# diagnostic line the moment the measurement has anything to say, so a key read
# takes stdout alone and the refusal text keeps the merged form above.
run_out() { with_env "$@" 2>/dev/null; }  # <case dir> <command...> -> stdout alone

POST=(post --title "Rename the fleet word?" --ask-ref m1 --why "It reads oddly here."
  --outcome yes="It is renamed." --outcome no="It stays." --recommend yes
  --recommend-reason "It reads better." --default no)

ask() {  # <case dir> [post flags...] -> both streams, for refusal text
  local d=$1
  shift
  run "$d" "$CARD" "${POST[@]}" "$@"
}

ask_key() {  # <case dir> [post flags...] -> the card key the post printed
  local d=$1
  shift
  run_out "$d" "$CARD" "${POST[@]}" "$@"
}

add_card() {  # <case dir> <key> <detail> <filed-iso>
  local board=$1/so/.sign-off/decisions.json
  jq --arg k "$2" --arg d "$3" --arg f "$4" \
    '.items += [{key: $k, kind: "decision", title: $k, detail: $d, filed: $f}]' "$board" > "$board.t" \
    && mv "$board.t" "$board"
}

iso_ago() {  # <seconds> -> a sign-off style UTC stamp
  local ago=$1 t
  t=$((NOW - ago))
  date -u -j -f %s "$t" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
    || date -u -d "@$t" +%Y-%m-%dT%H:%M:%S.000Z
}

records() { cat "$1/home/data/overwatch-decisions.md" 2>/dev/null; }
open_cards() { jq -r '[.items[] | select(.dismissed != true)] | length' "$1/so/.sign-off/decisions.json"; }

test_non_must_ask_is_refused_and_routed() {
  local d out
  d=$(setup refuse)
  out=$(ask "$d") && fail "a non-must ask posted under the when-it-matters leash: $out"
  assert_contains "$out" "needs a must category" "the refusal did not name the requirement"
  assert_contains "$out" "money, security, public-release" "the refusal did not name the category list"
  assert_contains "$out" "recorded for Overwatch: owd-" "the refusal did not name its Overwatch record"
  assert_equals "0" "$(open_cards "$d")" "a refused ask still reached the captain's board"
  assert_grep "- Ask: Rename the fleet word?" "$d/home/data/overwatch-decisions.md" "no Overwatch record for the refused ask"
  assert_grep "- Main decided: open" "$d/home/data/overwatch-decisions.md" "the record does not say Main answers it"
  assert_equals "0" "$(run "$d" "$GATE" waiting)" "a refused ask counted as waiting"
  pass "a non-must ask is refused, named, routed to Overwatch, and never reaches the board"
}

test_must_ask_is_posted_and_counted() {
  local d out key detail
  d=$(setup accept)
  key=$(ask_key "$d" --must money) || fail "a must ask was refused: $(ask "$d" --must money)"
  [ -n "$key" ] || fail "the post printed no card key"
  detail=$(jq -r --arg k "$key" '.items[] | select(.key == $k) | .detail' "$d/so/.sign-off/decisions.json")
  assert_equals "must: money" "$detail" "the card does not carry its must category"
  assert_equals "1" "$(run "$d" "$GATE" waiting)" "the must ask was not counted as waiting"
  add_card "$d" unclassified "" "$(iso_ago 600)"
  assert_equals "1" "$(run "$d" "$GATE" waiting)" "the waiting count included an ask with no must category"
  printf 'leash: ask\n' > "$d/so/.sign-off/config.yaml"
  out=$(ask "$d" "--title" "Rename the other word?" "--ask-ref" m2) \
    || fail "the ask-me-first leash refused a plain ask: $out"
  pass "a must ask is posted with its category and is the only thing the waiting count holds"
}

test_check_re_pings_an_old_must_ask_once() {
  local d out
  d=$(setup old-must)
  add_card "$d" old-must "must: security" "$(iso_ago 200000)"
  add_card "$d" fresh-must "must: design-pick" "$(iso_ago 3600)"
  out=$(run "$d" "$GATE" check)
  assert_contains "$out" "must ask waiting over 48h: old-must - old-must (security)" "an old must ask was not re-pinged"
  assert_not_contains "$out" "fresh-must" "a must ask under 48 hours was re-pinged"
  assert_equals "2" "$(open_cards "$d")" "a must ask left the board"
  out=$(run "$d" "$GATE" check)
  assert_equals "" "$out" "the re-ping repeated"
  pass "an old must ask stays and is re-pinged once"
}

test_check_moves_an_unclassified_ask_to_overwatch() {
  local d out
  d=$(setup stale)
  add_card "$d" stale-ask "" "$(iso_ago 7200)"
  out=$(run "$d" "$GATE" check)
  assert_contains "$out" "board ask routed to Overwatch, not a must: stale-ask" "the unclassified ask was not routed"
  assert_grep "dismiss stale-ask" "$d/signoff.log" "the routed card was not dismissed from the board"
  assert_equals "0" "$(open_cards "$d")" "the routed card still waits on the board"
  assert_grep "- Ask: stale-ask" "$d/home/data/overwatch-decisions.md" "no Overwatch record for the routed card"
  out=$(run "$d" "$GATE" check)
  assert_equals "" "$out" "the routed ask reported twice"
  pass "an unclassified waiting ask is recorded for Overwatch and leaves the board"
}

test_check_reports_a_merge_with_no_board_evidence() {
  local d out board
  d=$(setup merge)
  board=$d/so/.sign-off/decisions.json
  printf 'pr=https://github.com/o/r/pull/7\n' > "$d/home/state/m1.meta"
  : > "$d/home/state/m1.pr-poll-merge-notified"
  out=$(run "$d" "$GATE" check)
  assert_contains "$out" "merge landed with no board Evidence card: m1 https://github.com/o/r/pull/7" "an unproven merge did not wake the board owner"
  jq --arg f "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.items += [{key: "merge-github.com-o-r-pull-7", kind: "evidence", link: "https://github.com/o/r/pull/7", filed: $f}]' \
    "$board" > "$board.t" && mv "$board.t" "$board"
  out=$(run "$d" "$GATE" check)
  assert_equals "" "$out" "a merge with its Evidence card still woke the board owner"
  pass "a merge with no Evidence card wakes the board owner and one with it stays silent"
}

test_decided_writes_mains_decision() {
  local d out id
  d=$(setup decided)
  out=$(run "$d" "$GATE" route --title "Pick a name for the tool" --filer main --ref m3)
  id=$(printf '%s\n' "$out" | sed -n 's/^overwatch: \([^ ]*\).*/\1/p')
  [ -n "$id" ] || fail "route printed no record id: $out"
  run "$d" "$GATE" decided "$id" --words "It keeps the current name." >/dev/null || fail "decided refused its own record"
  assert_grep "- Main decided: It keeps the current name." "$d/home/data/overwatch-decisions.md" "the record does not carry Main's decision"
  assert_equals "1" "$(records "$d" | grep -c '^- Main decided:')" "the open line was not replaced"
  pass "Main's decision replaces the record's open line"
}

test_non_must_ask_is_refused_and_routed
test_must_ask_is_posted_and_counted
test_check_re_pings_an_old_must_ask_once
test_check_moves_an_unclassified_ask_to_overwatch
test_check_reports_a_merge_with_no_board_evidence
test_decided_writes_mains_decision
