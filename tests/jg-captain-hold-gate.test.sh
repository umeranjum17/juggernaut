#!/usr/bin/env bash
# The owner's question is one gate row on the home's tickets tables: `hold` makes it (a readable title, the must category), his
# answer closes it with his words, and no list of work, ready list or count ever shows it. The cases are the S17a proof:
# a dated hold also defers the ticket, a parked hold makes no gate and writes no text into the ticket, an armed board
# still refuses a hold with no must, `answer --release` leaves the ticket open, spawn and merge blocking see an open gate,
# `done` is refused past one, and a ticket with no gate has no question to answer.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

T=$(jg_test_tmproot jg-captain-hold-gate)
home=$T/home
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample"
jg_test_beads_home "$home"
: > "$home/config/backlog-intake-loose"
fb=$(jg_fakebin "$home")
jg_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi

hold() {  # <args...>: the hold script on the fixture home
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}
tasks() { jg_test_backlog "$home" "$@"; }
words() {  # <file> <text>
  printf '%s\n' "$2" > "$1"
}
questions_json() { tasks questions --json "$@"; }

for id in jg-w1 jg-w2 jg-w3 jg-w4; do
  tasks add "$id" "[feature] Work $id" --repo sample --body "why $id" >/dev/null || fail "add $id"
done

# hold makes one gate with a readable title and its must; the ticket keeps its status and reads as held by the owner.
out=$(hold hold jg-w1 --must design-pick --reason "Which route should the build take? Take A or B, the owner decides.") \
  || fail "hold: $out"
[ "$out" = jg-w1 ] || fail "hold prints the ticket id: $out"
q=$(questions_json --ticket jg-w1)
[ "$(jq length <<<"$q")" = 1 ] || fail "hold must make exactly one gate: $q"
gate=$(jq -r '.[0].id' <<<"$q")
[ "$(jq -r '.[0].title' <<<"$q")" = "Which route should the build take?" ] || fail "the gate title must be the question in a few words: $q"
[ "$(jq -r '.[0].must' <<<"$q")" = design-pick ] || fail "the gate must carry its must category: $q"
[ "$(jq -r '.[0].question' <<<"$q")" = "Which route should the build take? Take A or B, the owner decides." ] || fail "the gate must keep the whole question: $q"
show=$(tasks show jg-w1)
assert_contains "$show" "held: yes" "an open gate must read as held"
assert_contains "$show" "hold_kind: captain" "an open gate must read as the owner's hold"
assert_contains "$show" "blocked: no" "a gate is never the ticket's blocker"
assert_not_contains "$show" "Captain hold set" "a gate hold writes no stamp into the ticket body"
# A second hold with the same question makes no second gate.
hold hold jg-w1 --must design-pick --reason "Which route should the build take? Take A or B, the owner decides." >/dev/null || fail "a repeated hold"
[ "$(questions_json --ticket jg-w1 | jq length)" = 1 ] || fail "a repeated hold must not make a second gate"
pass "hold makes one gate with a readable title and its must, and no stamp"

# The gate is never work: list, ready, markdown, show and the counts leave it out.
tasks list --all | grep -q "$gate" && fail "list shows the gate row"
tasks ready | grep -q "$gate" && fail "ready shows the gate row"
tasks markdown | grep -q "$gate" && fail "markdown shows the gate row"
out=$(tasks show "$gate") && fail "show must not treat the gate as a ticket: $out"
[ "$(tasks list --all | sed -n 's/^count: //p')" = 4 ] || fail "the count of tickets must be 4 with a gate in the store: $(tasks list --all | head -2)"
tasks list --state held | grep -q "jg-w1" || fail "a ticket with an open gate must read as held in list --state held"
tasks ready | grep -q "jg-w1" && fail "a ticket with an open gate is not ready work"
tasks times jg-w1 >/dev/null 2>&1 || :
tasks times 2>&1 | grep -q "$gate" && fail "times shows the gate row"
pass "list, ready, markdown, show and the counts show no gate row"

# questions lists the open ones, with ticket, must, age and deferral date.
out=$(tasks questions)
assert_contains "$out" "$gate,jg-w1,design-pick,0" "questions must list the open gate with its ticket, must and age"
pass "questions lists the open questions"

# spawn and merge ask `blocking`: an open gate on the ticket, and on a ticket linked to it, stops the work.
out=$(hold blocking jg-w1) || fail "blocking must report the open gate on the ticket: $out"
assert_contains "$out" "jg-w1" "blocking must name the gated ticket"
tasks update jg-w2 --body "why jg-w2
linked-to: jg-w1" >/dev/null || fail "link jg-w2 to jg-w1"
out=$(hold blocking jg-w2) || fail "blocking must see the gate one edge away: $out"
assert_contains "$out" "jg-w1" "blocking must name the linked gated ticket"
assert_contains "$(tasks show jg-w2)" "blocked_by: jg-w1" "work linked to a ticket with an open gate waits on that ticket"
hold blocking jg-w3 >/dev/null && fail "a ticket with no gate and no link is not blocked"
hold open jg-w1 || fail "an open gate is an open call"
hold open jg-w1 --identity | grep -qx "$gate" || fail "the identity of an open call must be its gate"
hold phase jg-w1 | grep -qx raised || fail "the machine's word for an open gate is raised"
pass "blocking and open see an open gate, on the ticket and one edge away"

# done never forces past an open gate.
out=$(tasks "done" jg-w1) && fail "done must refuse a ticket with an open gate: $out"
assert_contains "$out" "open question to the owner" "the refusal must say why"
assert_contains "$out" "$gate" "the refusal must name the gate"
tasks show jg-w1 | grep -q "state: done" && fail "the refused done closed the ticket"
pass "done on a ticket with an open gate is refused and names the gate"

# answer --release closes the gate with his words and leaves the ticket open.
words "$T/answer" "Take route A. Do not ask again."
out=$(hold answer jg-w1 --decision-file "$T/answer" --release) || fail "answer --release: $out"
assert_contains "$out" "released: jg-w1" "answer --release must say released"
q=$(questions_json --all --ticket jg-w1)
[ "$(jq -r '.[0].state' <<<"$q")" = closed ] || fail "the gate must be closed: $q"
[ "$(jq -r '.[0].words' <<<"$q")" = "Take route A. Do not ask again." ] || fail "the gate must carry his words: $q"
[ "$(jq -r '.[0].resolution' <<<"$q")" = released ] || fail "the gate must record released: $q"
show=$(tasks show jg-w1)
assert_contains "$show" "state: queued" "a released ticket stays open"
assert_contains "$show" "held: no" "a released ticket is no longer held"
assert_contains "$show" "approved-by-captain: answer:" "his answer is the approval a build needs"
hold answered jg-w1 || fail "answered must be yes for a closed gate with his words"
assert_contains "$(tasks show jg-w2)" "blocked: no" "the answer frees the work that waited on the ticket"
hold blocking jg-w1 >/dev/null && fail "a released ticket is no longer blocked"
[ "$(tasks questions)" = "questions: 0 open owner questions" ] || fail "no question is open now: $(tasks questions)"
# A retry with the same words is a no-op; other words never replace the first answer.
out=$(hold answer jg-w1 --decision-file "$T/answer" --release) || fail "an exact retry must succeed: $out"
words "$T/other" "Take route B instead."
out=$(hold answer jg-w1 --decision-file "$T/other" --release 2>&1) && fail "a second answer must not replace the first: $out"
assert_contains "$out" "second answer does not replace the first" "the refusal must say why"
[ "$(questions_json --all --ticket jg-w1 | jq -r '.[0].words')" = "Take route A. Do not ask again." ] || fail "his first words must stay"
pass "answer --release closes the gate with his words and leaves the ticket open"

# answer without --release closes a ticket that was only the question, after the gate.
hold hold jg-w3 --reason "Should the sample ship on Friday?" >/dev/null || fail "hold jg-w3"
words "$T/yes" "Yes, ship it on Friday."
out=$(hold answer jg-w3 --decision-file "$T/yes") || fail "answer: $out"
assert_contains "$out" "answered: jg-w3" "answer must say answered"
tasks show jg-w3 | grep -q "state: done" || fail "an answered question closes its ticket"
[ "$(questions_json --all --ticket jg-w3 | jq -r '.[0].resolution')" = answered ] || fail "the gate must record answered"
pass "answer closes the gate and then the ticket"

# A hold with a date also defers the ticket; questions --due leaves it out until then.
out=$(hold hold jg-w2 --reason "Is the rollout wording final?" --until 2099-01-01) || fail "dated hold: $out"
show=$(tasks show jg-w2)
assert_contains "$show" "hold_until: 2099-01-01" "a dated hold must defer the ticket"
assert_contains "$show" "held: yes" "a dated hold is held"
[ "$(questions_json --due | jq length)" = 0 ] || fail "questions --due must leave out a deferred question: $(questions_json --due)"
[ "$(questions_json | jq -r '.[0].until')" = 2099-01-01 ] || fail "questions must show the deferral date"
hold phase jg-w2 | grep -qx deferred || fail "the machine's word for a dated hold is deferred"
words "$T/later" "Wording is final."
hold answer jg-w2 --decision-file "$T/later" --release >/dev/null || fail "answer the dated hold"
tasks show jg-w2 | grep -q "hold_until: 2099-01-01" && fail "releasing lifts the deferral date"
pass "a dated hold defers the ticket, and questions --due leaves it out"

# A parked hold (his own instruction) makes no gate.
out=$(hold hold jg-w4 --reason "captain stop order holds this lane; branch preserved unmerged") || fail "parked hold: $out"
[ "$(questions_json --ticket jg-w4 | jq length)" = 0 ] || fail "a parked hold must make no gate"
show=$(tasks show jg-w4 --full)
assert_contains "$show" "hold_kind: captain" "a parked hold is held for the owner"
assert_not_contains "$show" "Captain hold set" "a parked hold writes no stamp into the ticket"
hold open jg-w4 --identity | grep -q . || fail "a plain hold still has an identity"
hold phase jg-w4 | grep -qx raised || fail "the machine's word for a plain hold is raised"
words "$T/none" "Never mind."
out=$(hold answer jg-w4 --decision-file "$T/none" 2>&1) && fail "a ticket with no gate has no question to answer: $out"
assert_contains "$out" "no question to the owner" "the refusal must say why"
pass "a parked hold makes no gate and writes no text into the ticket"

# An armed board still refuses a hold with no must category and routes it, with no gate made.
tasks add jg-w5 "[feature] Work jg-w5" --repo sample --body "why jg-w5" >/dev/null || fail "add jg-w5"
mkdir -p "$home/state/procevent"
: > "$home/state/procevent/signoff.source"
out=$(JG_SIGNOFF_SCRIPT="$ROOT/bin/jg-procevent-signoff.sh" hold hold jg-w5 --reason "Should we rename the project?" 2>&1) \
  && fail "an armed board must refuse a hold with no must: $out"
assert_contains "$out" "needs a must category" "the refusal must name the rule"
[ "$(questions_json --ticket jg-w5 | jq length)" = 0 ] || fail "a refused hold must make no gate"
rm -f "$home/state/procevent/signoff.source"
pass "a hold with no must on an armed board is refused and routed, with no gate"

# reconcile close closes a gate with evidence, never as his words.
tasks add jg-w6 "[feature] Work jg-w6" --repo sample --body "why jg-w6" >/dev/null || fail "add jg-w6"
hold hold jg-w6 --reason "Is the release still on track?" >/dev/null || fail "hold jg-w6"
hold bind chan-1 >/dev/null || fail "bind"
printf 'jg-w6\n' | hold reconcile-requests --source-id chan-1 --source "captured board result" >/dev/null || fail "reconcile request"
words "$T/evidence" "The release shipped on 2026-11-01."
out=$(hold reconcile close jg-w6 --evidence-file "$T/evidence") || fail "reconcile close: $out"
q=$(questions_json --all --ticket jg-w6)
[ "$(jq -r '.[0].resolution' <<<"$q")" = reconciled ] || fail "reconcile records reconciled: $q"
assert_contains "$(jq -r '.[0].words' <<<"$q")" "Reconciliation evidence: The release shipped" "the evidence is on the gate"
hold answered jg-w6 && fail "a reconciled gate is not an answer of his"
pass "reconcile close resolves the gate with evidence"

# reconcile note adds a comment on the gate and leaves it open, with no text in the ticket body.
tasks add jg-w7 "[feature] Work jg-w7" --repo sample --body "why jg-w7" >/dev/null || fail "add jg-w7"
hold hold jg-w7 --reason "Is the plan still right?" >/dev/null || fail "hold jg-w7"
printf 'jg-w7\n' | hold reconcile-requests --source-id chan-1 --source "captured board result" >/dev/null || fail "reconcile request w7"
words "$T/found" "Still open: nothing has shipped."
out=$(hold reconcile note jg-w7 --note-file "$T/found") || fail "reconcile note: $out"
assert_contains "$out" "still-open: jg-w7" "the note must say the call is still open"
q=$(questions_json --ticket jg-w7)
[ "$(jq length <<<"$q")" = 1 ] || fail "the gate must stay open after a note: $q"
gate_id=$(jq -r '.[0].id' <<<"$q")
assert_contains "$(JG_HOME=$home python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" comments "$gate_id" --json | jq -r '.[].text')" "Still open: nothing has shipped." "the finding is a comment on the gate"
case "$(tasks show jg-w7 --full)" in *"Still open: nothing"*|*"Captain hold reconciled"*) fail "the note must not go into the ticket body" ;; esac
hold answered jg-w7 && fail "a note is not an answer"
pass "reconcile note comments on the gate and leaves it open"

# An old ticket carries its hold as text in the description: the stamp line, the origin line and the hold itself.
stamped_hold() {  # <id> <reason> [<origin> [<until>]]
  tasks update "$1" --body "Captain hold set: 2026-10-01T10:00:00Z${3:+
Captain hold origin: $3}

why $1" >/dev/null || fail "stamp $1"
  tasks hold "$1" --reason "$2" --kind captain ${4:+--until "$4"} >/dev/null || fail "hold $1"
}

# The pass moves each open old owner hold to a gate: it keeps the deferral date and the origin, leaves a stop order stamped,
# prints the count, takes the stamp out of the body, and a second run changes nothing.
for id in jg-m1 jg-m2 jg-m3 jg-m4; do
  tasks add "$id" "[feature] Work $id" --repo sample --body "why $id" >/dev/null || fail "add $id"
done
stamped_hold jg-m1 "Should the build take route A or B? The owner decides." || fail "stamped hold m1"
stamped_hold jg-m2 "Do we ship in January?" jg-m4 2099-01-02 || fail "stamped dated hold m2"
stamped_hold jg-m3 "Captain stop order: keep this parked until he says go." || fail "stamped stop order m3"
tasks add jg-m5 "Is the plan still right?" --kind captain --repo sample >/dev/null || fail "add m5"
stamped_hold jg-m5 "Is the plan still right?" || fail "stamped hold that made its own ticket m5"
before=$(questions_json --all | jq length)
out=$(hold to-gates) || fail "to-gates: $out"
assert_contains "$out" "moved 3 of " "the pass prints its count: $out"
[ "$(questions_json --all | jq length)" = $((before + 3)) ] || fail "the pass must make one gate per moved hold"
m1=$(questions_json --ticket jg-m1)
[ "$(jq length <<<"$m1")" = 1 ] && [ "$(jq -r '.[0].question' <<<"$m1")" = "Should the build take route A or B? The owner decides." ] || fail "m1 gate keeps the whole reason: $m1"
[ "$(jq -r '.[0].title' <<<"$m1")" = "Should the build take route A or B?" ] || fail "m1 gate has the question as its title: $m1"
m2=$(questions_json --ticket jg-m2)
[ "$(jq -r '.[0].until' <<<"$m2")" = 2099-01-02 ] || fail "the deferral date must stay: $m2"
[ "$(jq -r '.[0].origin' <<<"$m2")" = jg-m4 ] || fail "the origin must move onto the gate: $m2"
[ "$(questions_json --ticket jg-m5 | jq -r '.[0].close')" = 'done' ] || fail "a ticket the hold made closes with its answer"
[ "$(questions_json --ticket jg-m3 | jq length)" = 0 ] || fail "a stop order must make no gate"
tasks show jg-m3 --full | grep -q "Captain hold set:" || fail "a stop order keeps its stamp"
for id in jg-m1 jg-m2 jg-m5; do
  tasks show "$id" --full | grep -q "Captain hold set:\|Captain hold origin:" && fail "$id must lose its stamp lines"
  assert_contains "$(tasks show "$id" --full)" "held: yes" "$id reads as held by its gate"
done
assert_contains "$(tasks show jg-m1 --full)" "why jg-m1" "the rest of the body stays"
hold blocking jg-m1 >/dev/null || fail "a moved hold still blocks"
snap=$(tasks list --all --fields held,hold_kind,hold_until,hold_reason; questions_json --all; tasks show jg-m1 --full; tasks show jg-m2 --full)
out=$(hold to-gates) || fail "second to-gates: $out"
assert_contains "$out" "moved 0 of " "a second run moves none: $out"
[ "$(tasks list --all --fields held,hold_kind,hold_until,hold_reason; questions_json --all; tasks show jg-m1 --full; tasks show jg-m2 --full)" = "$snap" ] || fail "a second run must change nothing"
words "$T/m1" "Take route B."
hold answer jg-m1 --decision-file "$T/m1" >/dev/null || fail "answer a moved hold"
[ "$(questions_json --all --ticket jg-m1 | jq -r '.[0].words')" = "Take route B." ] || fail "a moved hold answers by its gate"
pass "to-gates moves old owner holds to gates, keeps dates and origins, leaves stop orders, and a second run changes nothing"

# The answers intake closes gates: a gate id is the key; a ticket id with one open gate closes that gate; with two
# open gates it is refused naming both; an answer with no words and the value `reconcile` are refused.
for id in jg-k1 jg-k2 jg-k3 jg-k4; do
  tasks add "$id" "[feature] Work $id" --repo sample --body "why $id" >/dev/null || fail "add $id"
done
hold hold jg-k1 --reason "Take route A or B? The owner decides." >/dev/null || fail "hold k1"
hold hold jg-k2 --reason "Ship the small slice first? The owner decides." >/dev/null || fail "hold k2"
hold hold jg-k3 --reason "Which colour? The owner decides." >/dev/null || fail "hold k3"
hold hold jg-k3 --reason "Which width? The owner decides." >/dev/null || fail "second hold k3"
hold hold jg-k4 --reason "Reconcile this one? The owner decides." >/dev/null || fail "hold k4"
k1=$(questions_json --ticket jg-k1 | jq -r '.[0].id')
k3=$(questions_json --ticket jg-k3 | jq -r '.[].id' | paste -sd' ')
[ "$(wc -w <<<"$k3")" = 2 ] || fail "k3 must have two open gates: $k3"
out=$(printf '%s\tTake route A.\tRoute A\n' "$k1" | hold answers --source board-test 2>&1) || fail "a gate id key must close its gate: $out"
assert_contains "$out" "closed: $k1" "the keyed answer must report the gate closed"
q=$(questions_json --all --ticket jg-k1)
[ "$(jq -r '.[0].state' <<<"$q")" = closed ] || fail "the keyed gate must be closed: $q"
assert_contains "$(jq -r '.[0].words' <<<"$q")" "Answer: Take route A." "the gate must carry his words"
[ "$(jq -r ".[0].resolution" <<<"$q")" = released ] || fail "the gate must close the way its own close mode says (a ticket that is work is released): $q"
hold answered jg-k1 >/dev/null || fail "a keyed answer must read as answered"
out=$(printf 'jg-k2\tYes, small first.\tYes\n' | hold answers --source board-test 2>&1) || fail "a ticket id with one open gate must close it: $out"
[ "$(questions_json --all --ticket jg-k2 | jq -r '.[0].state')" = closed ] || fail "the ticket's one gate must close"
out=$(printf 'jg-k3\tBlue.\tBlue\n' | hold answers --source board-test 2>&1) && fail "a ticket with two open gates must be refused: $out"
for g in $k3; do assert_contains "$out" "$g" "the refusal must name both gates: $out"; done
[ "$(questions_json --ticket jg-k3 | jq length)" = 2 ] || fail "a refused answer must close neither gate"
out=$(printf '%s\t\tNothing\n' "$(awk '{print $1}' <<<"$k3")" | hold answers --source board-test 2>&1) && fail "an answer with no words must be refused: $out"
assert_contains "$out" "refused" "the empty answer must be refused"
out=$(printf '%s\treconcile\tReconcile\n' "$(awk '{print $1}' <<<"$k3")" | hold answers --source board-test 2>&1) && fail "reconcile must stay refused on a gate id: $out"
assert_contains "$out" "refused" "reconcile must be refused"
[ "$(questions_json --ticket jg-k3 | jq length)" = 2 ] || fail "refused answers must close no gate"
pass "the answers intake closes a gate by its id or its ticket's one gate, refuses two, empty words and reconcile"

pass "jg-captain-hold-gate"
