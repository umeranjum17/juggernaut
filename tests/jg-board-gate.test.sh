#!/usr/bin/env bash
# tests/jg-board-gate.test.sh - the board-ask gate and its scheduled checks: a
# non-must ask is refused and routed to Overwatch, a must ask is posted and
# counted, and the check re-pings an old must ask while it moves an old or
# unclassified one off the board (bin/jg-ask-gate-lib.sh, bin/jg-board-gate.sh,
# bin/jg-question-card.sh), and withdraws asks that are acted on, superseded or
# past their time to live (bin/jg-board-ttl-lib.sh).
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
    # The real sign-off-axi takes only its own three reasons and refuses any
    # other, so this fake does too: a free-text reason is a pass that dismisses
    # nothing and re-alerts forever on the card it meant to remove.
    key=$1
    reason=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --reason) shift; reason=${1-} ;; esac
      shift
    done
    case "$reason" in
      not-relevant|replaced|done-elsewhere) ;;
      *) printf 'code: VALIDATION_ERROR\n' >&2; exit 2 ;;
    esac
    case " ${SIGNOFF_DISMISS_FAILS:-} " in *" $key "*) exit 3 ;; esac
    printf 'dismiss %s\n' "$key" >> "$SIGNOFF_LOG"
    printf 'reason %s %s\n' "$key" "$reason" >> "$SIGNOFF_LOG"
    jq --arg k "$key" '.items = [.items[] | if .key == $k then . + {dismissed: true} else . end]' "$board" > "$board.t" && mv "$board.t" "$board" ;;
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
  printf 'set mode off\n' > "$d/channel-off" # the cards raised here stay off the machine's shared bus
  printf '%s\n' "$d"
}

with_env() {  # <case dir> <command...>
  local d=$1
  shift
  env JG_CAPTAIN_CHANNEL="$d/channel-off" PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" \
    SIGN_OFF_HOME="$d/so" SIGNOFF_LOG="$d/signoff.log" JG_BOARD_GATE_NOW="$NOW" \
    JG_BOARD_GATE_REFIRE_SECS=0 "$@"
}

run() { with_env "$@" 2>&1; }  # <case dir> <command...> -> both streams

# `post` prints the card key alone on stdout and its own diagnostics, including
# the card-rule measurement, on stderr. A key read from the merged streams is a
# diagnostic line the moment the measurement has anything to say, so a key read
# takes stdout alone and the refusal text keeps the merged form above.
run_out() { with_env "$@" 2>/dev/null; }  # <case dir> <command...> -> stdout alone

POST=(post --route main --title "Rename the fleet word?" --ask-ref m1 --why "It reads oddly here."
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

test_plan_approval_is_a_must_and_a_made_up_category_is_not() {
  local d out key detail
  d=$(setup plan-approval)
  key=$(ask_key "$d" --must plan-approval) || fail "a plan-approval ask was refused: $(ask "$d" --must plan-approval)"
  detail=$(jq -r --arg k "$key" '.items[] | select(.key == $k) | .detail' "$d/so/.sign-off/decisions.json")
  assert_equals "must: plan-approval" "$detail" "the plan-approval card does not carry its category"
  assert_equals "1" "$(run "$d" "$GATE" waiting)" "the plan-approval ask was not counted as waiting"
  out=$(ask "$d" --must made-up-category --title "Rename the other word?" --ask-ref m2) \
    && fail "a made-up category was posted: $out"
  assert_equals "1" "$(open_cards "$d")" "a made-up category still reached the captain's board"
  pass "a plan-approval ask is a must and a made-up category is still refused"
}

test_release_word_is_a_must_and_a_made_up_category_is_not() {
  local d out key detail
  d=$(setup release-word)
  key=$(ask_key "$d" --must release-word) || fail "a release-word ask was refused: $(ask "$d" --must release-word)"
  detail=$(jq -r --arg k "$key" '.items[] | select(.key == $k) | .detail' "$d/so/.sign-off/decisions.json")
  assert_equals "must: release-word" "$detail" "the release-word card does not carry its category"
  assert_equals "1" "$(run "$d" "$GATE" waiting)" "the release-word ask was not counted as waiting"
  pass "a release-word ask is a must and is counted as waiting"
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

test_check_leaves_a_dismissed_card_alone() {
  local d out
  d=$(setup dismissed-card)
  # The feed rebuild put the card back after its owner dismissed it: the key is on
  # the board with no dismissal flag, and only the record says it is dismissed.
  add_card "$d" ask-rebuilt "" "$(iso_ago 7200)"
  printf '%s\n' '{"key":"ask-rebuilt","dismissed":true,"at":"2026-10-31T20:24:33Z"}' \
    > "$d/so/.sign-off/decisions.dismissed.jsonl"
  : > "$d/signoff.log"
  out=$(run "$d" "$GATE" check)
  assert_equals "" "$out" "a rebuilt card its owner dismissed woke the board owner again"
  assert_no_grep "dismiss ask-rebuilt" "$d/signoff.log" "a rebuilt card its owner dismissed was dismissed from the board again"
  assert_equals "0" "$(records "$d" | grep -c '^- Ask: ask-rebuilt' || true)" \
    "a rebuilt card its owner dismissed was routed to Overwatch again"
  assert_equals "0" "$(run "$d" "$GATE" waiting)" "a dismissed card counted as waiting on the captain"
  # The record's last line decides: an undone dismissal is the owner taking it back.
  printf '%s\n' '{"key":"ask-rebuilt","dismissed":false,"at":"2026-10-31T21:24:33Z"}' \
    >> "$d/so/.sign-off/decisions.dismissed.jsonl"
  out=$(run "$d" "$GATE" check)
  assert_contains "$out" "board ask routed to Overwatch, not a must: ask-rebuilt" \
    "a card whose dismissal was undone was still treated as dismissed"
  pass "a dismissal is a record, not an absence, so a rebuilt card stays dismissed until its owner undoes it"
}

test_check_reads_the_category_record() {
  local d out
  d=$(setup carried-category)
  # A rebuild wrote its own detail over the card, so the item itself carries no
  # must category; the card's own record still does.
  add_card "$d" ask-screen "TakeOne Mac recording needs it" "$(iso_ago 200000)"
  printf '%s\n' '{"key":"ask-screen","detail":"must: security","at":"2026-10-31T19:00:00Z"}' \
    > "$d/so/.sign-off/decisions.card-detail.jsonl"
  assert_equals "1" "$(run "$d" "$GATE" waiting)" "a card that lost its detail field kept no must category"
  out=$(run "$d" "$GATE" check)
  assert_not_contains "$out" "board ask routed to Overwatch" "a card carrying a recorded category was routed off the board"
  assert_contains "$out" "must ask waiting over 48h: ask-screen - ask-screen (security)" \
    "a must card over 48 hours was not re-pinged from its recorded category"
  pass "a card keeps its must category through a rebuild that dropped its detail field"
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

test_check_alerts_once_for_an_unchanged_set() {
  local d first second third added
  d=$(setup unchanged-set)
  add_card "$d" stuck-one "" "$(iso_ago 7200)"
  add_card "$d" stuck-two "" "$(iso_ago 7200)"
  # The board refuses these two, so the set of offending keys cannot change.
  first=$(SIGNOFF_DISMISS_FAILS="stuck-one stuck-two" run "$d" "$GATE" check)
  assert_contains "$first" "could not be dismissed: stuck-one" "the first pass did not alert on an undismissable ask"
  assert_contains "$first" "could not be dismissed: stuck-two" "the first pass alerted on one ask only"
  second=$(SIGNOFF_DISMISS_FAILS="stuck-one stuck-two" run "$d" "$GATE" check)
  assert_equals "" "$second" "the same unchanged set of offending keys alerted a second time"
  third=$(SIGNOFF_DISMISS_FAILS="stuck-one stuck-two" run "$d" "$GATE" check)
  assert_equals "" "$third" "the same unchanged set alerted a third time"
  # One ask makes one record, however often the set is looked at again.
  assert_equals "1" "$(records "$d" | grep -c '^- Ask ref: stuck-one' || true)" "a card the gate could not remove was routed to Overwatch again"
  # A new offending key changes the set, so the gate alerts once more.
  add_card "$d" stuck-three "" "$(iso_ago 7200)"
  added=$(SIGNOFF_DISMISS_FAILS="stuck-one stuck-two stuck-three" run "$d" "$GATE" check)
  assert_contains "$added" "could not be dismissed: stuck-three" "a changed set of offending keys did not alert"
  assert_equals "" "$(SIGNOFF_DISMISS_FAILS="stuck-one stuck-two stuck-three" run "$d" "$GATE" check)" \
    "the changed set alerted again with nothing further changed"
  pass "an unchanged set of offending keys alerts once, and a changed set alerts again"
}

test_check_reads_one_ask_from_a_many_line_detail() {
  local d out
  d=$(setup many-line-detail)
  # A card's detail holds one finding per line; a bare join read each line as
  # another ask and routed a key that exists nowhere on the board.
  add_card "$d" one-card "$(printf 'no-quote: main/a - first\nno-ask-card: main/b - second\n... and 333 more')" "$(iso_ago 7200)"
  out=$(run "$d" "$GATE" check)
  assert_equals "1" "$(printf '%s\n' "$out" | grep -c 'one-card')" "one card with a many-line detail did not alert once"
  assert_not_contains "$out" "no-quote: main/a" "a line of a card's detail was read as its own ask"
  assert_not_contains "$out" "... and 333 more" "the last line of a card's detail was read as its own ask"
  assert_equals "1" "$(records "$d" | grep -c '^- Ask:' || true)" "one card with a many-line detail made more than one Overwatch record"
  pass "one card is one ask, however many lines its detail holds"
}

test_dismiss_sends_a_fitting_reason_and_odd_titles_make_valid_tags() {
  local d out board tags id
  d=$(setup reasons)
  board=$d/so/.sign-off/decisions.json
  jq --arg o "$(iso_ago 7200)" --arg n "$(iso_ago 3600)" '.items += [
    {key: "plain", kind: "decision", title: "Plain ask", detail: "", filer: "a1", filed: $o},
    {key: "old-dup", kind: "decision", title: "Same ask", detail: "", filer: "a2", filed: $o},
    {key: "new-dup", kind: "decision", title: "Same ask", detail: "", filer: "a2", filed: $n},
    {key: "answered", kind: "decision", title: "Answered ask", detail: "", filer: "a3", filed: $o}]' "$board" > "$board.t" && mv "$board.t" "$board"
  add_card "$d" "Which door? a/b" "must: security" "$(iso_ago 200000)"
  id=$(with_env "$d" "$GATE" route --title "Answered ask" --ref answered | sed -n 's/^overwatch: \([^ ]*\) .*/\1/p')
  with_env "$d" "$GATE" decided "$id" --words "use the side door" >/dev/null
  out=$(run "$d" "$GATE" check)
  assert_grep "reason plain not-relevant" "$d/signoff.log" "an unremarkable ask did not leave as not-relevant"
  assert_grep "reason old-dup replaced" "$d/signoff.log" "an ask a newer one replaced did not leave as replaced"
  assert_grep "reason answered done-elsewhere" "$d/signoff.log" "an ask Main answered did not leave as done-elsewhere"
  assert_equals "1" "$(open_cards "$d")" "a non-must ask stayed on the board"
  assert_contains "$out" "must ask waiting over 48h: Which door? a/b" "the odd-titled must ask was not re-pinged"
  tags=$(ls "$d/home/state/.board-gate")
  case "$tags" in *pinged-which-door-a-b-*) ;; *) fail "the odd key did not produce a slugged tag file: $tags" ;; esac
  pass "a dismissal sends one of the three reasons it fits, and an odd title makes a valid tag file"
}

# A hold's card must leave the board when its hold does. The answer in this case
# came through the hold command (chat, not the board), so the board never saw an
# answer and the card waited as a must ask for days.
test_check_dismisses_the_card_of_a_settled_hold() {
  local d out key other
  d=$(setup settled-hold)
  jg_test_beads_home "$d/home"
  mkdir -p "$d/home/state/procevent" "$d/home/projects"
  : > "$d/home/state/procevent/signoff.source"
  printf '{"decision":"yes"}\n' > "$d/decision.json"
  hold() { with_env "$d" env JG_SIGNOFF_SCRIPT="$ROOT/bin/jg-procevent-signoff.sh" JG_STATE_OVERRIDE="$d/home/state" \
    JG_DATA_OVERRIDE="$d/home/data" JG_CONFIG_OVERRIDE="$d/home/config" "$ROOT/bin/jg-captain-hold.sh" "$@"; }
  hold hold nm-live --title "Keep the work?" --reason "Keep the unlanded work?" --repo sample --must discard-unlanded >/dev/null 2>&1 \
    || fail "the live hold was not posted"
  hold hold nm-done --title "Discard the work?" --reason "Discard the unlanded work?" --repo sample --must discard-unlanded >/dev/null 2>&1 \
    || fail "the hold to answer was not posted"
  assert_equals "2" "$(open_cards "$d")" "the two hold cards were not posted"
  assert_equals "2" "$(run "$d" "$GATE" waiting)" "two open holds were not both waiting"
  hold answer nm-done --decision-file "$d/decision.json" >/dev/null 2>&1 || fail "the hold was not answered"
  key=$(jq -r '.items[] | select(.key | contains("-nm-done-")) | .key' "$d/so/.sign-off/decisions.json")
  other=$(jq -r '.items[] | select(.key | contains("-nm-live-")) | .key' "$d/so/.sign-off/decisions.json")
  assert_equals "1" "$(run "$d" "$GATE" waiting)" "the card of an answered hold still counts as waiting"
  : > "$d/signoff.log"
  out=$(run "$d" "$GATE" check)
  assert_equals "" "$out" "dismissing a settled hold's card woke the board owner"
  assert_grep "reason $key done-elsewhere" "$d/signoff.log" "the card of an answered hold was not dismissed"
  assert_no_grep "dismiss $other" "$d/signoff.log" "the card of a hold that is still open was dismissed"
  assert_equals "1" "$(open_cards "$d")" "the answered hold's card still waits on the board"
  pass "the card of an answered hold leaves the board and the card of an open hold stays"
}

# A card with the fields the expiry rules read: type, ticket, ask-ref, answered.
add_ask() {  # <case dir> <key> <type> <detail> <age secs> [<ticket> [<ask-ref> [answered]]]
  local board=$1/so/.sign-off/decisions.json
  jq --arg k "$2" --arg ty "$3" --arg d "$4" --arg f "$(iso_ago "$5")" --arg t "${6-}" --arg r "${7-}" --arg a "${8-}" \
    '.items += [({key: $k, type: $ty, title: $k, detail: $d, filed: $f}
      + (if $t != "" then {ticket: $t} else {} end) + (if $r != "" then {ask_ref: $r} else {} end)
      + (if $a != "" then {decided: {value: "a"}} else {} end))]' "$board" > "$board.t" && mv "$board.t" "$board"
}

# A backlog that lists one done ticket; the sweep reads done tickets in one call.
fake_backlog() {  # <case dir>
  cat > "$1/backlog" <<'SH'
#!/usr/bin/env bash
printf 'count: 1\ntasks[1]{id,state,kind,repo,title}:\n  t-done,done,task,-,"x"\n'
SH
  chmod +x "$1/backlog"
}

test_expiry_withdraws_acted_on_superseded_and_stale_asks_never_owner_calls() {
  d=$(setup expiry); fake_backlog "$d"
  add_ask "$d" ticket-done decision 'must: plan-approval' 3600 t-done
  add_ask "$d" ticket-open decision 'must: plan-approval' 3600 t-open
  add_ask "$d" old-plan decision 'must: plan-approval' $((8 * 86400))
  add_ask "$d" young-plan decision 'must: plan-approval' $((6 * 86400))
  add_ask "$d" old-money decision 'must: money' $((30 * 86400))
  add_ask "$d" old-design design '' $((8 * 86400))
  add_ask "$d" first-card decision 'must: plan-approval' 7200 '' same-call
  add_ask "$d" later-answered decision 'must: plan-approval' 3600 '' same-call answered
  jq '(.items[] | select(.key == "later-answered")) |= (. + {decided: {value: "a"}})' "$d/so/.sign-off/decisions.json" > "$d/b.t" && mv "$d/b.t" "$d/so/.sign-off/decisions.json"
  out=$(JG_BOARD_BACKLOG_BIN="$d/backlog" run "$d" "$GATE" expire --dry-run)
  assert_grep "withdrawn ticket-done" <(printf '%s\n' "$out") "a done ticket's ask was not named"
  assert_equals "8" "$(open_cards "$d")" "a dry run changed the board"
  out=$(JG_BOARD_BACKLOG_BIN="$d/backlog" run "$d" "$GATE" check)
  assert_grep "reason ticket-done done-elsewhere" "$d/signoff.log" "an ask of a done ticket was not withdrawn as done-elsewhere"
  assert_grep "reason first-card replaced" "$d/signoff.log" "an ask a later answered card superseded was not withdrawn as replaced"
  assert_grep "reason old-plan not-relevant" "$d/signoff.log" "a plan ask past its time to live was not withdrawn"
  assert_grep "reason old-design not-relevant" "$d/signoff.log" "a design ask past its time to live was not withdrawn"
  for k in ticket-open young-plan old-money later-answered; do
    assert_no_grep "dismiss $k" "$d/signoff.log" "$k was withdrawn but is neither acted on, superseded nor stale"
  done
  assert_equals "4" "$(cut -f2 "$d/home/data/board-withdrawn.tsv" | wc -l | tr -d ' ')" "the cleanup report holds a row for each withdrawal"
  assert_grep "old-plan" "$d/home/data/board-withdrawn.tsv" "the cleanup report lacks the withdrawn ask"
  assert_grep "expires never" <(run "$d" "$GATE" report) "an owner call shows an expiry"
  pass "acted-on, superseded and stale asks are withdrawn with a recorded reason, owner calls stay open"
}

test_leash_ask_keeps_every_ask_on_the_board() {
  d=$(setup leash-ask)
  printf 'leash: ask\n' > "$d/so/.sign-off/config.yaml"
  add_card "$d" plain-ask '' "$(iso_ago 3600)"
  : > "$d/signoff.log"
  out=$(run "$d" "$GATE" check)
  assert_no_grep "dismiss plain-ask" "$d/signoff.log" "the check dismissed an ask while the leash is Ask me first"
  assert_equals "1" "$(open_cards "$d")" "the ask left the board"
  pass "on the Ask me first leash the gate leaves every ask on the board"
}

test_non_must_ask_is_refused_and_routed
test_dismiss_sends_a_fitting_reason_and_odd_titles_make_valid_tags
test_must_ask_is_posted_and_counted
test_plan_approval_is_a_must_and_a_made_up_category_is_not
test_check_re_pings_an_old_must_ask_once
test_check_moves_an_unclassified_ask_to_overwatch
test_check_reports_a_merge_with_no_board_evidence
test_check_leaves_a_dismissed_card_alone
test_check_reads_the_category_record
test_decided_writes_mains_decision
test_check_alerts_once_for_an_unchanged_set
test_check_reads_one_ask_from_a_many_line_detail
test_expiry_withdraws_acted_on_superseded_and_stale_asks_never_owner_calls
test_leash_ask_keeps_every_ask_on_the_board
test_check_dismisses_the_card_of_a_settled_hold
