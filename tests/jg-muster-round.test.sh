#!/usr/bin/env bash
# tests/jg-muster-round.test.sh - board rounds and the answer loop of a muster (bin/jg-muster.sh).
# Every case runs on a throwaway home: the real backlog gates (bin/jg-captain-hold.sh), the real card tool posting
# into a throwaway board through the real sign-off-axi, and the real chat intake (bin/jg-inbox.sh note with the
# gateway's `[chat telegram <chat>:<message>]` first line). No live home, board or channel is read.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sign-off-axi >/dev/null 2>&1 || { printf 'skip - sign-off-axi is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf 'skip - jq is not installed\n'; exit 0; }

TMP_ROOT=$(jg_test_tmproot jg-muster-round)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
MUSTER="$ROOT/bin/jg-muster.sh"
T=jg-rt

setup() {  # <name> -> a case dir: a home, a board, the round ticket, a vision document
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/so/.sign-off" "$d/tmp" "$d/project/docs"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  printf 'leash: matters\n' > "$d/so/.sign-off/config.yaml"
  printf 'set mode off\n' > "$d/channel-off"
  : > "$d/home/config/backlog-intake-loose"
  printf -- '---\nstatus: draft\n---\n# Vision: Helpdesk bot\n\n## FAQ\n- **Can it answer?** Yes.\n\n## Decisions\n- <YYYY-MM-DD> <question id>: "<his words>" (revision <n>)\n' \
    > "$d/project/docs/vision.md"
  run "$d" "$ROOT/bin/jg-backlog.sh" add "$T" "[feature] Helpdesk bot muster round" --priority 2 --kind ship --repo demo --body "A fixture round ticket" >/dev/null 2>&1 \
    || fail "could not file the round ticket"
  printf '%s\n' "$d"
}

run() {  # <case dir> command...: a throwaway environment for every call
  local d=$1
  shift
  env -u JG_TASK_ID HOME="$d" TMPDIR="$d/tmp" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" JG_STATE_OVERRIDE="$d/home/state" \
    JG_DATA_OVERRIDE="$d/home/data" JG_CONFIG_OVERRIDE="$d/home/config" JG_CAPTAIN_CHANNEL="$d/channel-off" \
    SIGN_OFF_HOME="$d/so" SIGN_OFF_FILER=muster-test "$@"
}
mu() { local d=$1; shift; run "$d" "$MUSTER" "$@" 2>&1; }
doc() { printf '%s/project/docs/vision.md' "$1"; }
rounds() { printf '%s/home/data/%s/muster/rounds.tsv' "$1" "$T"; }
board() { printf '%s/so/.sign-off/decisions.json' "$1"; }

# A question file: <name> <file> <title> <option a> <option b> [<recommend> [<extra json>]]
q() {  # <title> <a> <b> <recommend> [<extra object members, no braces>]
  jq -n --arg t "$1" --arg a "$2" --arg b "$3" --arg r "$4" --argjson x "{${5:-}}" '{
    question: $t, why: "The bot needs one answer here before the plan.",
    options: [{value: "a", label: $a, outcome: ("The plan uses " + $a + ".")}, {value: "b", label: $b, outcome: ("The plan uses " + $b + ".")}],
    recommend: $r, recommend_reason: "It keeps the first version small."} + $x'
}
round1() {  # -> three questions of round 1
  jq -s '.' <(q "Which language should the bot use?" "TypeScript" "Python" a '"default":"a"') \
            <(q "Where should the documents live?" "In the project" "In the home" a) \
            <(q "How long do we keep transcripts?" "Thirty days" "Forever" b '"label":"architecture"')
}
round2() {  # -> two more questions
  jq -s '.' <(q "How many agents answer at once?" "One" "Many" a) <(q "Who may close a handoff?" "A person only" "The bot too" a)
}
gate_of() { jq -r --arg q "$2" '.[] | select(.id == $q) | .state' <<<"$1"; }
gates() { run "$1" "$ROOT/bin/jg-backlog.sh" questions --ticket "$T" --all --json; }
state_of() { jq -r --arg id "$2" '.[] | select(.id == $id) | .state' <<<"$(gates "$1")"; }
answer_of() { jq -r --arg id "$2" '.[] | select(.id == $id) | .words // "" | split("\n") | map(select(startswith("Answer: "))) | (first // "none")' <<<"$(gates "$1")"; }
gate_for() { awk -F'\t' -v q="$2" '$3 == q { g = $4 } END { print g }' "$(rounds "$1")"; }   # the gate of a question id
card_for() { awk -F'\t' -v q="$2" '$3 == q { k = $5 } END { print k }' "$(rounds "$1")"; }
note() {  # <case dir> <message id> <text>: the gateway's filing of one chat message through the ordinary intake
  printf '[chat telegram 42:%s]\n%s\n' "$2" "$3" | run "$1" "$ROOT/bin/jg-inbox.sh" note --request-id "tg-42-$2" --json - | jq -r .id
}
chat() { mu "$1" answer "$T" --note "$(note "$1" "$2" "$3")"; }
shown() {  # <case dir> <round file> <round number>: show one round
  mu "$1" round "$T" --questions "$2" --round "$3" --doc "$(doc "$1")"
}
two_rounds() {  # <case dir>: round 1 (three questions) and round 2 (two) both shown
  local d=$1
  round1 > "$d/r1.json"; round2 > "$d/r2.json"
  shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  shown "$d" "$d/r2.json" 2 >/dev/null || fail "round 2 was not shown"
}
close_round_on_board() {  # <case dir> <round>: a board pick for every question of the round
  local d=$1 qid
  while read -r qid; do
    mu "$d" answer "$T" --card "$(card_for "$d" "$qid")" --value a >/dev/null
  done < <(awk -F'\t' -v r="$2" '$1 == r { print $3 }' "$(rounds "$d")" | sort -u)
}

test_round_posts_one_card_per_question_and_records_the_gate() {
  local d out g k
  d=$(setup posts)
  round1 > "$d/r1.json"
  out=$(shown "$d" "$d/r1.json" 1) || fail "round 1 was refused: $out"
  assert_equals "3" "$(wc -l < "$(rounds "$d")" | tr -d ' ')" "rounds.tsv does not hold one row per question"
  assert_equals "3" "$(jq '.items | length' "$(board "$d")")" "the board does not hold one card per question"
  assert_equals "0" "$(jq '[.items[] | select(.options == null)] | length' "$(board "$d")")" "a yes/no card reached the board"
  for k in 1 2 3; do
    g=$(gate_for "$d" "R1Q$k")
    assert_equals "open" "$(state_of "$d" "$g")" "R1Q$k has no open gate $g in the backlog"
    assert_equals "$(jq -r --argjson i "$((k - 1))" '.[$i].question' "$d/r1.json")" \
      "$(jq -r --arg g "$g" '.[] | select(.id == $g) | .title' <<<"$(gates "$d")")" "the gate $g is not the gate of R1Q$k"
  done
  assert_equals "3" "$(awk -F'\t' '{ print $6 }' "$(rounds "$d")" | sort -u | wc -l | tr -d ' ' | awk '{ print ($1 == 1) ? 3 : 0 }')" "the three rows do not share one question set"
  assert_equals "3" "$(awk -F'\t' '$2 == 1 { n++ } END { print n }' "$(rounds "$d")")" "the rows are not revision 1"
  assert_equals "3" "$(awk -F'\t' '{ print $5 }' "$(rounds "$d")" | sort -u | wc -l | tr -d ' ')" "two questions share one card key"
  assert_equals "3" "$(jq -r '.items[].ask_ref' "$(board "$d")" | grep -c "^$T$")" "a card does not name the round ticket"
  assert_not_contains "$(jq -r '.items[].why' "$(board "$d")" | head -1)" "Reply to this card" "the first presentation already carries the revision hint"
  pass "round posts one multi-option card per question and records R1Qk -> its gate, card key, revision and question set"
}

test_council_questions_keep_their_ids_when_first_shown() {
  local d data council lane out key gate
  d=$(setup council-handoff)
  data=$d/home/data
  council=$data/war-room/$T
  lane=$T-user
  mkdir -p "$council" "$data/$lane"
  printf 'kind=lenses\n' > "$council/record"
  printf 'user\t%s\n' "$lane" > "$council/lanes"
  cat > "$data/$lane/report.md" <<'EOF'
## Questions
- Q: Which language should the bot use? | A: | owner: yes
- Q: Where should the documents live? | A: In the project | owner: no
EOF
  JG_WAR_ROOM_NEXT=0 run "$d" "$ROOT/bin/jg-recon-handoff.sh" draft "$lane" >/dev/null
  run "$d" "$ROOT/bin/jg" muster council "$T" >/dev/null || fail 'merge the council'
  out=$(mu "$d" round-status "$T" --json)
  assert_equals false "$(jq -r '.rounds[0].complete' <<<"$out")" 'an unpresented owner question is outstanding'
  out=$(chat "$d" 170 'yes to the rest')
  assert_contains "$out" '0 presentations' 'an unpresented council draft cannot receive a reply'

  round1 | jq '.[0:2]' > "$d/r1.json"
  out=$(run "$d" "$ROOT/bin/jg" muster round "$T" --questions "$d/r1.json" --round 1 --doc "$(doc "$d")" 2>&1) \
    || fail "first presentation of merged round 1 refused: $out"
  key=$(card_for "$d" R1Q1)
  gate=$(gate_for "$d" R1Q1)
  [ -n "$key" ] && [ -n "$gate" ] || fail 'R1Q1 did not get a card and gate'
  assert_equals '' "$(gate_for "$d" R1Q2)" 'an agreed answer needs no gate'
  assert_equals 1 "$(jq '.items | length' "$(board "$d")")" 'only the unresolved question goes to the board'
  shown "$d" "$d/r1.json" 1 >/dev/null || fail 'repeat of the merged round'
  assert_equals "$key" "$(card_for "$d" R1Q1)" 'repeat keeps the first card'
  out=$(chat "$d" 171 'R1Q1 b')
  assert_contains "$out" 'closed R1Q1' 'the first shown choices bind at the original id'
  assert_contains "$(cat "$(doc "$d")")" 'R1Q1: "Python" (revision 1)' 'the merged question keeps revision 1'
  assert_equals true "$(mu "$d" round-status "$T" --json | jq -r '.rounds[0].complete')" 'the round is complete'
  pass 'a merged council question keeps its id at its first board presentation'
}

test_a_card_the_rules_refuse_records_nothing() {
  local d out
  d=$(setup refused)
  q "Is the lane ready for jg-abc?" "Yes it is" "No it is not" a | jq -s '.' > "$d/bad.json"
  out=$(shown "$d" "$d/bad.json" 1) && fail "a card naming a ticket id was posted: $out"
  assert_contains "$out" "refused" "the refusal does not say so"
  assert_equals "0" "$(jq '.items | length' "$(board "$d")")" "a refused card reached the board"
  assert_equals "0" "$(gates "$d" | jq length)" "a refused card left a gate"
  [ ! -s "$(rounds "$d")" ] || fail "a refused card left a round row"
  q "Keep it?" "Yes" "No" a '"default":"b","label":"irreversible"' | jq -s '.' > "$d/irr.json"
  out=$(shown "$d" "$d/irr.json" 1) && fail "an irreversible question with a default was accepted: $out"
  pass "a card the rules refuse, and an irreversible question with a default, record no card, gate or row"
}

test_a_single_board_pick_closes_only_its_own_gate() {
  local d out
  d=$(setup board)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  out=$(mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value b) || fail "the board pick was refused: $out"
  assert_equals "closed" "$(state_of "$d" "$(gate_for "$d" R1Q1)")" "the picked gate is not closed"
  assert_equals "Answer: b" "$(answer_of "$d" "$(gate_for "$d" R1Q1)")" "the picked gate holds another answer"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R1Q2)")" "another gate closed with the pick"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R1Q3)")" "another gate closed with the pick"
  assert_contains "$(cat "$(doc "$d")")" '- '"$(date -u +%F)"' R1Q1: "Python" (revision 1)' "the Decisions line was not written"
  assert_not_contains "$(cat "$(doc "$d")")" "<YYYY-MM-DD>" "the Decisions placeholder stayed"
  pass "a single board pick closes only its own gate and writes its Decisions line"
}

test_a_chat_note_closes_that_rounds_open_gates_only() {
  local d out
  d=$(setup chatgroup)
  two_rounds "$d"
  out=$(chat "$d" 301 "R1Q2 b; yes to the rest") || fail "the note was refused: $out"
  assert_equals "Answer: b" "$(answer_of "$d" "$(gate_for "$d" R1Q2)")" "R1Q2 did not take b"
  assert_equals "Answer: a" "$(answer_of "$d" "$(gate_for "$d" R1Q1)")" "R1Q1 did not take its recommended option"
  assert_equals "Answer: b" "$(answer_of "$d" "$(gate_for "$d" R1Q3)")" "R1Q3 did not take its recommended option"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R2Q1)")" "round 2 closed with a note about round 1"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R2Q2)")" "round 2 closed with a note about round 1"
  pass "a chat note 'R1Q2 b; yes to the rest' closes round 1's open gates only"
}

test_a_bare_reply_binds_only_while_one_presentation_exists() {
  local d out
  d=$(setup bare)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  out=$(chat "$d" 401 "yes to the rest") || fail "the bare reply was refused: $out"
  assert_equals "Answer: a" "$(answer_of "$d" "$(gate_for "$d" R1Q1)")" "the bare reply did not take the recommended option"
  assert_equals "closed" "$(state_of "$d" "$(gate_for "$d" R1Q3)")" "the bare reply left a gate open"
  pass "on a ticket that has shown one presentation, a bare 'yes to the rest' closes that round's gates with their recommended options"
}

test_the_delayed_bare_reply_closes_nothing() {
  local d out
  d=$(setup delayed)
  round1 > "$d/r1.json"; round2 > "$d/r2.json"
  shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  out=$(note "$d" 505 "yes to the rest")   # sent while round 1 was open: filed now, read after round 2 opened
  close_round_on_board "$d" 1
  shown "$d" "$d/r2.json" 2 >/dev/null || fail "round 2 was not shown"
  out=$(mu "$d" answer "$T" --note "$out") || fail "the delayed note was refused: $out"
  assert_contains "$out" "unbound" "the delayed reply was not stored as unbound"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R2Q1)")" "the delayed reply closed a gate of round 2"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R2Q2)")" "the delayed reply closed a gate of round 2"
  assert_equals "1" "$(awk -F'\t' '$8 == "unbound" { n++ } END { print n + 0 }' "$(rounds "$d")")" "the unbound reply is not in rounds.tsv"
  pass "a delayed bare 'yes to the rest' after round 1 closed on the board and round 2 opened closes nothing and is stored unbound"
}

test_two_open_rounds_and_named_rounds() {
  local d out
  d=$(setup named)
  two_rounds "$d"
  out=$(chat "$d" 601 "yes to the rest") || fail "refused: $out"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R1Q1)")" "a bare reply closed a gate with two rounds open"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R2Q1)")" "a bare reply closed a gate with two rounds open"
  pass "with rounds 1 and 2 both open, a bare reply closes nothing"
  out=$(chat "$d" 602 "R2 yes to the rest") || fail "refused: $out"
  assert_equals "closed" "$(state_of "$d" "$(gate_for "$d" R2Q1)")" "'R2 yes to the rest' did not close round 2"
  assert_equals "closed" "$(state_of "$d" "$(gate_for "$d" R2Q2)")" "'R2 yes to the rest' did not close round 2"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R1Q1)")" "'R2 yes to the rest' closed round 1"
  pass "'R2 yes to the rest' closes round 2 only"
  out=$(chat "$d" 603 "R1Q1 a and R2Q1 b") || fail "refused: $out"
  assert_contains "$out" "unbound" "a note naming two rounds was bound"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R1Q1)")" "a note naming two rounds closed a gate"
  pass "a note naming two rounds is unbound and closes nothing"
  close_round_on_board "$d" 1
  out=$(chat "$d" 604 "R1Q2 b") || fail "refused: $out"
  assert_equals "Answer: a" "$(answer_of "$d" "$(gate_for "$d" R1Q2)")" "'R1Q2 b' after round 1 closed changed the answer"
  pass "'R1Q2 b' after round 1 closed changes nothing"
}

test_a_revised_card_binds_only_what_it_names() {
  local d out old new
  d=$(setup revised)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  old=$(gate_for "$d" R1Q1)
  out=$(note "$d" 701 "R1 yes to the rest")   # sent while R1.1 recommended a, delivered after R1.2
  jq '.[0].recommend = "b" | .[0].recommend_reason = "Python has the better libraries."' "$d/r1.json" > "$d/r1b.json"
  out2=$(mu "$d" revise "$T" 1 --questions "$d/r1b.json") || fail "the revision was refused: $out2"
  assert_contains "$out2" "R1.2" "the revision did not say how to answer"
  assert_contains "$(jq -r '.items[].why' "$(board "$d")" | tail -1)" "Reply to this card, or start with R1.2." "the revised card does not say how to answer"
  new=$(gate_for "$d" R1Q1)
  [ "$new" != "$old" ] || fail "the changed question kept its old gate"
  assert_equals "closed" "$(state_of "$d" "$old")" "the superseded gate stayed open"
  assert_equals "Answer: superseded" "$(answer_of "$d" "$old")" "the superseded gate was not closed as superseded"
  assert_equals "open" "$(state_of "$d" "$new")" "the revised question has no open gate"
  assert_equals "$(gate_for "$d" R1Q2)" "$(awk -F'\t' '$3 == "R1Q2" && $2 == 2 { print $4 }' "$(rounds "$d")")" "an unchanged question lost its gate"
  out=$(mu "$d" answer "$T" --card "$(awk -F'\t' '$3 == "R1Q1" && $2 == 1 { print $5 }' "$(rounds "$d")")" --value a)
  assert_contains "$out" "stale" "a reply naming revision 1 of a question now at revision 2 was not stale"
  assert_equals "open" "$(state_of "$d" "$new")" "a stale reply closed the revised question"
  pass "a reply naming revision 1 of a question now at revision 2 closes nothing (stale)"
  out=$(mu "$d" answer "$T" --note "$(note "$d" 701 "R1 yes to the rest")")
  assert_contains "$out" "unbound" "the delayed round-only note was bound after the round was revised"
  assert_equals "open" "$(state_of "$d" "$new")" "the delayed round-only note closed the revised question"
  assert_equals "open" "$(state_of "$d" "$(gate_for "$d" R1Q2)")" "the delayed round-only note closed R1Q2"
  pass "the delayed 'R1 yes to the rest' filed while R1.1 recommended a, read after R1.2 recommends b, closes nothing and is stored unbound"
  out=$(chat "$d" 702 "R1Q1 a")
  assert_contains "$out" "unbound" "'R1Q1 a' with no revision on the changed question was bound"
  assert_equals "open" "$(state_of "$d" "$new")" "'R1Q1 a' closed the changed question"
  pass "'R1Q1 a' with no revision on the changed question closes nothing"
  out=$(chat "$d" 703 "R1Q2 b")
  assert_equals "Answer: b" "$(answer_of "$d" "$(gate_for "$d" R1Q2)")" "'R1Q2 b' did not close the question whose words did not change"
  pass "'R1Q2 b' on a question whose words did not change closes it"
  out=$(chat "$d" 704 "R1.3 yes to the rest")
  assert_contains "$out" "never shown" "R1.3 was bound"
  assert_equals "open" "$(state_of "$d" "$new")" "'R1.3 ...' closed a question"
  pass "'R1.3 ...' for a revision never shown binds nothing"
  out=$(chat "$d" 705 "R1.2 yes to the rest")
  assert_equals "Answer: b" "$(answer_of "$d" "$new")" "'R1.2 yes to the rest' did not close the revised question with b"
  pass "'R1.2 yes to the rest' closes the revised question with b"
}

test_a_duplicate_answer_changes_nothing_and_free_text_is_verbatim() {
  local d out g
  d=$(setup dup)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value a >/dev/null || fail "first answer refused"
  assert_equals "1" "$(awk -F'\t' '$3 == "R1Q1" && $8 == "a" && $12 != "" { n++ } END { print n }' "$(rounds "$d")")" "the first answer is not recorded once"
  out=$(mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value a) || fail "a repeat was refused: $out"
  assert_contains "$out" "nothing changes" "a repeat did not say it changed nothing"
  assert_equals "1" "$(awk -F'\t' '$3 == "R1Q1" && $8 == "a" && $12 != "" { n++ } END { print n }' "$(rounds "$d")")" "a repeat added a row"
  out=$(mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value b) && fail "a different answer to an answered gate was accepted: $out"
  assert_equals "Answer: a" "$(answer_of "$d" "$(gate_for "$d" R1Q1)")" "a different answer replaced the first"
  pass "a duplicate answer changes nothing and a different answer to an answered gate is refused"
  g=$(gate_for "$d" R1Q2)
  mu "$d" answer "$T" --card "$(card_for "$d" R1Q2)" --words "Keep them in the repo, but never the secrets" >/dev/null || fail "free text refused"
  assert_equals "Answer: Keep them in the repo, but never the secrets" "$(answer_of "$d" "$g")" "free text was not kept verbatim"
  assert_contains "$(cat "$(doc "$d")")" 'R1Q2: "Keep them in the repo, but never the secrets" (revision 1)' "the free text is not in the Decisions line"
  out=$(chat "$d" 801 "R1Q3: use the cheapest plan, then revisit")
  assert_equals "Answer: use the cheapest plan, then revisit" "$(answer_of "$d" "$(gate_for "$d" R1Q3)")" "free text in a chat note was not kept verbatim"
  pass "free text is kept verbatim, on a card and in a chat note"
}

test_a_late_answer_after_a_default_is_revision_two() {
  local d out g
  d=$(setup late)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  g=$(gate_for "$d" R1Q1)
  out=$(mu "$d" answer "$T" --default R1Q1) || fail "the default was refused: $out"
  assert_equals "default" "$(awk -F'\t' '$3 == "R1Q1" && $8 == "a" { t = $10 } END { print t }' "$(rounds "$d")")" "the default is not taken=default"
  assert_contains "$(cat "$(doc "$d")")" 'R1Q1: "default: TypeScript" (revision 1)' "the default is not marked in the document"
  out=$(mu "$d" answer "$T" --default R1Q3) && fail "a question with no default took one: $out"
  out=$(mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value b) || fail "the late answer was refused: $out"
  assert_equals "2:b:owner" "$(awk -F'\t' '$3 == "R1Q1" { r = $2 ":" $8 ":" $10 } END { print r }' "$(rounds "$d")")" "the late answer is not revision 2 with taken=owner"
  assert_equals "Answer: a" "$(answer_of "$d" "$g")" "the gate lost its first answer"
  assert_contains "$(cat "$(doc "$d")")" 'R1Q1: "Python" (revision 2)' "the Decisions line was not rewritten"
  assert_equals "1" "$(grep -c ' R1Q1:' "$(doc "$d")")" "the document holds two lines for R1Q1"
  pass "a late answer after a default replaces it as revision 2 with taken=owner"
}

test_revise_adds_a_revision_and_rewrites_the_decisions_line() {
  local d out
  d=$(setup revise)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  mu "$d" answer "$T" --card "$(card_for "$d" R1Q2)" --value a >/dev/null || fail "answer refused"
  out=$(mu "$d" revise "$T" R1Q2 --words "In the home, after all") || fail "the correction was refused: $out"
  assert_contains "$(cat "$(doc "$d")")" 'R1Q2: "In the home, after all" (revision 2)' "the Decisions line was not rewritten"
  assert_equals "1" "$(grep -c ' R1Q2:' "$(doc "$d")")" "the correction left two lines"
  assert_equals "2" "$(awk -F'\t' '$3 == "R1Q1" { r = $2 } END { print r }' "$(rounds "$d")")" "the round was not shown again at revision 2"
  out=$(mu "$d" revise "$T" R1Q1 --value a) && fail "a correction to an open question was accepted: $out"
  pass "revise adds a revision and rewrites the document's Decisions line"
}

test_round_status_repairs_an_answer_saved_before_its_document() {
  local d out
  d=$(setup repair)
  round1 > "$d/r1.json"; shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  mv "$(doc "$d")" "$d/vision.away"                 # the worker stops after the answer is saved, before the line is written
  out=$(mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value b) && fail "an answer with no document was reported done: $out"
  assert_equals "closed" "$(state_of "$d" "$(gate_for "$d" R1Q1)")" "the answer was not saved before the document step"
  mv "$d/vision.away" "$(doc "$d")"
  out=$(mu "$d" round-status "$T") || fail "round-status failed: $out"
  assert_contains "$out" "owing a document line: R1Q1" "round-status does not name the unwritten document line"
  assert_not_contains "$(cat "$(doc "$d")")" 'R1Q1: "Python"' "round-status wrote the document"
  out=$(mu "$d" repair "$T") || fail "repair failed: $out"
  assert_contains "$(cat "$(doc "$d")")" 'R1Q1: "Python" (revision 1)' "repair did not write the Decisions line"
  assert_not_contains "$(mu "$d" round-status "$T")" "owing a document line" "round-status still names a line after the repair"
  out=$(mu "$d" repair "$T"); assert_contains "$out" "repaired 0 row" "a second repair changed something"
  pass "a worker stopped after the answer was saved but before the document was written is repaired by round-status's repair"
  # the same gap when the gate was closed by another channel and the round never saw it
  printf '%s\t%s\t%s\n' "$(gate_for "$d" R1Q2)" a "a) In the project" | run "$d" "$ROOT/bin/jg-captain-hold.sh" answers --source "board fixture" >/dev/null
  out=$(mu "$d" repair "$T"); assert_contains "$out" "repaired: R1Q2" "a gate closed outside the round was not taken up"
  assert_contains "$(cat "$(doc "$d")")" 'R1Q2: "In the project" (revision 1)' "the outside answer is not in the document"
  pass "repair takes up a gate closed by another channel and writes its line"
}

test_a_round_completes_only_when_no_required_gate_is_open() {
  local d out before after
  d=$(setup complete)
  jq -s '.' <(q "Which language should the bot use?" "TypeScript" "Python" a) \
            <(q "May the bot greet by name?" "Yes" "No" a '"required":false') > "$d/r1.json"
  shown "$d" "$d/r1.json" 1 >/dev/null || fail "round 1 was not shown"
  before=$(find "$d/home/data" "$d/project" -type f -exec sha256sum {} + | sort | sha256sum)
  out=$(mu "$d" round-status "$T"); assert_contains "$out" "round 1 (revision 1): open" "an open round reads complete"
  after=$(find "$d/home/data" "$d/project" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equals "$before" "$after" "round-status changed a file"
  assert_contains "$out" "(optional)" "the optional question is not marked"
  mu "$d" answer "$T" --card "$(card_for "$d" R1Q1)" --value a >/dev/null
  out=$(mu "$d" round-status "$T"); assert_contains "$out" "round 1 (revision 1): complete" "the round did not complete with only an optional question open"
  assert_equals "true" "$(mu "$d" round-status "$T" --json | jq -r '.rounds[0].complete')" "the json does not say complete"
  pass "the round completes only when no required gate is open, and round-status changes no file"
}

test_no_two_cards_share_a_key() {
  local d
  d=$(setup keys)
  two_rounds "$d"
  jq '.[0].recommend = "b"' "$d/r1.json" > "$d/r1b.json"
  mu "$d" revise "$T" 1 --questions "$d/r1b.json" >/dev/null || fail "revision refused"
  assert_equals "0" "$(jq -r '.items[].key' "$(board "$d")" | sort | uniq -d | wc -l | tr -d ' ')" "two cards share a key"
  assert_equals "0" "$(awk -F'\t' '{ print $5 }' "$(rounds "$d")" | sort -u | grep -c 'chat' | tr -d ' ')" "an unexpected presentation id"
  assert_equals "6" "$(jq '.items | length' "$(board "$d")")" "the board does not hold 3+2+1 cards (one superseded)"
  pass "no two cards share a key, across rounds and revisions"
}

test_the_command_fragment_has_the_frozen_shape() {
  local f=$ROOT/core/agent-cli/contract/muster-rounds.json
  jq -e '(.area|type=="string") and (.owner|type=="string") and (.entries|length>0) and all(.entries[];
    (.path|type=="array" and length>0) and (.meaning|type=="string" and length>0) and (.roles|type=="array") and
    (.changes|type=="boolean") and (.method == (if .changes then "POST" else "GET" end)) and
    ((.changes|not) or (.repeat_key|type=="string")) and (.script|startswith("bin/")) and (.operation|type=="string"))' "$f" >/dev/null \
    || fail "the fragment does not have the frozen shape"
  assert_equals "m5" "$(jq -r .owner "$f")" "the fragment owner is not m5"
  assert_equals "muster answer,muster repair,muster revise,muster round,muster round-status" \
    "$(jq -r '[.entries[].path | join(" ")] | sort | join(",")' "$f")" "the fragment names other operations"
  assert_equals "GET" "$(jq -r '.entries[] | select(.path == ["muster","round-status"]) | .method' "$f")" "round-status is not the one read"
  assert_equals "0" "$(jq -r '[.entries[] | [.script, .operation]] | group_by(.) | map(select(length > 1)) | length' "$f")" "a (script, operation) pair has two entries"
  local op
  for op in round answer revise round-status repair; do
    jq -e --arg op "$op" '.entries[] | select(.operation == $op) | .form | startswith("bin/jg-muster.sh " + $op)' "$f" >/dev/null \
      || fail "the form of $op does not start with the script and its operation word"
  done
  pass "the fragment holds round, answer, revise, round-status (the one read) and repair in the frozen shape"
}

if [ -n "${JG_MUSTER_CASE:-}" ]; then "$JG_MUSTER_CASE"; exit 0; fi
jg_test_run_cases test_round_posts_one_card_per_question_and_records_the_gate \
  test_council_questions_keep_their_ids_when_first_shown \
  test_a_card_the_rules_refuse_records_nothing \
  test_a_single_board_pick_closes_only_its_own_gate \
  test_a_chat_note_closes_that_rounds_open_gates_only \
  test_a_bare_reply_binds_only_while_one_presentation_exists \
  test_the_delayed_bare_reply_closes_nothing \
  test_two_open_rounds_and_named_rounds \
  test_a_revised_card_binds_only_what_it_names \
  test_a_duplicate_answer_changes_nothing_and_free_text_is_verbatim \
  test_a_late_answer_after_a_default_is_revision_two \
  test_revise_adds_a_revision_and_rewrites_the_decisions_line \
  test_round_status_repairs_an_answer_saved_before_its_document \
  test_a_round_completes_only_when_no_required_gate_is_open \
  test_no_two_cards_share_a_key \
  test_the_command_fragment_has_the_frozen_shape
