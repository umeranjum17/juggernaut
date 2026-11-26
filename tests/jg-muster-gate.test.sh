#!/usr/bin/env bash
# bin/jg-muster-gate.sh (core/muster/pack_check.py) through its real command line, on the committed example packs of
# tests/fixtures/muster/example: the help desk at complete depth and the rated help desk at full depth (change pack
# `rate-a-conversation` against the help desk before it) both pass with legacy path warnings; every planted fault is refused
# with its own line; the light and full depth rules refuse as stated; a second run prints the same lines and writes
# nothing. Every fault is applied to a throwaway copy: no live home and no real project is read.
# shellcheck disable=SC2016  # the backticks inside the single-quoted fault texts are literal markdown
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/jg-muster-gate.sh"
EX="$ROOT/tests/fixtures/muster/example"
HD="$EX/helpdesk" RT="$EX/rated" SLUG=rate-a-conversation
T=$(jg_test_tmproot jg-muster-gate)

# The one edit helper: replace one text in one file (the text must be there, so a fault never goes vacuous), or turn
# the rated change pack into a light one (no Charter section, depth light, no design page).
cat > "$T/edit.py" <<'PY'
import os, re, sys
mode, root = sys.argv[1], sys.argv[2]
if mode == 'replace':
    path, find, repl = os.path.join(root, sys.argv[3]), sys.argv[4], sys.argv[5]
    s = open(path).read()
    if find not in s:
        sys.exit('text not found in %s: %r' % (sys.argv[3], find))
    open(path, 'w').write(s.replace(find, repl, 1))
elif mode == 'light':
    path = os.path.join(root, 'docs/changes/rate-a-conversation.md')
    s = open(path).read()
    s = re.sub(r'## Charter\n.*?(?=## Changelog)', '', s, flags=re.S).replace('depth: full', 'depth: light')
    open(path, 'w').write(s)
    os.remove(os.path.join(root, 'docs/design/rate-a-conversation.md'))
PY

copy() {  # <source tree> -> a fresh throwaway copy of it
  local d
  d=$(mktemp -d "$T/tree.XXXXXX") && cp -a "$1/." "$d" && printf '%s\n' "$d"
}
edit() { python3 -I "$T/edit.py" replace "$@" || fail "the planted fault does not apply: $2"; }  # <tree> <file> <find> <replace>
gate() { "$GATE" check "$@" 2>"$T/gate.stderr"; }
refused() {  # <name> <output> <exit code> <clause text>...: refused with every clause text, and nothing but refusals
  local name=$1 out=$2 rc=$3 want
  shift 3
  expect_code 1 "$rc" "$name"
  ! printf '%s\n' "$out" | grep -q -v '^refused: ' || fail "$name: a line that is not a refusal: $out"
  for want in "$@"; do assert_contains "$out" "$want" "$name: the refusal"; done
  pass "refused: $name: $(printf '%s\n' "$out" | grep -F -- "$1" | head -n 1)"
}
complete_fault() {  # <name> <file> <find> <replace> <clause text>...: a fault in the help desk, refused at complete depth
  local name=$1 d out rc=0
  d=$(copy "$HD")
  edit "$d" "$2" "$3" "$4"
  shift 4
  out=$(gate "$d" --depth complete) || rc=$?
  refused "$name" "$out" "$rc" "$@"
}
change_fault() {  # <name> <file> <find> <replace> <clause text>...: a fault in the rated help desk, refused at full depth
  local name=$1 d out rc=0
  d=$(copy "$RT")
  edit "$d" "$2" "$3" "$4"
  shift 4
  out=$(gate "$d" --depth full --change "$SLUG" --before "$HD") || rc=$?
  refused "$name" "$out" "$rc" "$@"
}

# ---- the two examples pass, each with zero refusals, and a second run prints the same and writes nothing
before=$(cd "$EX" && find . -type f -exec sha256sum {} + | sort)
out=$(gate "$HD" --depth complete) || fail "helpdesk at complete refused: $out"
assert_equals "PASS" "$out" "legacy helpdesk at complete prints PASS on stdout"
assert_contains "$(cat "$T/gate.stderr")" "docs/design/helpdesk.md is a legacy technical design; use docs/architecture/helpdesk.md" \
  "legacy helpdesk names the migration on stderr"
pass "legacy helpdesk: PASS with a migration warning"
out=$(gate "$RT" --depth full --change "$SLUG" --before "$HD") || fail "rated at full refused: $out"
assert_equals "PASS" "$out" "legacy rated at full prints PASS on stdout"
assert_contains "$(cat "$T/gate.stderr")" "docs/design/$SLUG.md is a legacy technical design; use docs/architecture/$SLUG.md" \
  "legacy rated names the migration on stderr"
pass "legacy rated: PASS with a migration warning"
out2=$(gate "$RT" --depth full --change "$SLUG" --before "$HD")
assert_equals "$out" "$out2" "a second run prints the same"
[ "$before" = "$(cd "$EX" && find . -type f -exec sha256sum {} + | sort)" ] || fail "the gate wrote into the pack"
pass "a second run prints the same lines and the gate writes nothing"

new="$ROOT/.agents/skills/muster/examples"
out=$(gate "$new/helpdesk" --depth complete) || fail "new helpdesk refused: $out"
assert_equals "PASS" "$out" "new helpdesk passes"
[ ! -s "$T/gate.stderr" ] || fail "new helpdesk emitted a warning"
out=$(gate "$new/rated" --depth full --change "$SLUG" --before "$new/helpdesk") || fail "new rated refused: $out"
assert_equals "PASS" "$out" "new rated passes"
[ ! -s "$T/gate.stderr" ] || fail "new rated emitted a warning"
pass "complete and full packs with technical designs at docs/architecture pass without warnings"

d=$(copy "$new/rated")
mv "$d/docs/architecture/$SLUG.md" "$d/docs/design/$SLUG.md"
out=$(gate "$d" --depth full --change "$SLUG" --before "$new/helpdesk") && rc=0 || rc=$?
refused "technical design in the visual direction folder" "$out" "$rc" \
  "docs/design/$SLUG.md is a technical design; move it to docs/architecture/$SLUG.md"

d=$(copy "$new/helpdesk")
edit "$d" docs/architecture/helpdesk.md 'None.' 'Who owns the handoff?'
out=$(gate "$d" --depth complete) && rc=0 || rc=$?
refused "unresolved architecture question" "$out" "$rc" \
  "docs/architecture/helpdesk.md has unresolved questions not held on the board"

# ---- planted faults at complete depth, each refused with its own line
HANDOFF_MACHINE=$'### Handoff state machine\nStates: waiting, accepted, closed\n```mermaid\nstateDiagram-v2\n  [*] --> waiting : create\n  waiting --> accepted : accept\n  accepted --> closed : close\n```\n\n| From | To | Trigger | Guard | Effect | Journey |\n|---|---|---|---|---|---|\n| [*] | waiting | create | a reason is given | HandoffRequested | bot-hands-off-unknown |\n| waiting | accepted | accept | the handoff is waiting | HandoffAccepted | agent-closes-handoff |\n| accepted | closed | close | a note is given | HandoffClosed | agent-closes-handoff |\n'
complete_fault "idea-only ADR: one option" docs/adr/0002-keep-conversations-in-one-store-file.md $'- SQLite on the host.\n- Postgres as a separate service.\n' '' "fewer than two considered options"
complete_fault "idea-only ADR: no decision" docs/adr/0001-use-typescript-on-node.md 'We use TypeScript on Node, because' 'Maybe TypeScript on Node, because' "no decision line"
complete_fault "idea-only ADR: no consequences" docs/adr/0003-host-on-one-small-server.md '- Bad: one server is one point of failure' '- one server is one point of failure' "consequences need a Good and a Bad line"
complete_fault "idea-only ADR: no confirmation" docs/adr/0003-host-on-one-small-server.md $'Each release record names the server and the version; the done-done receipts of the objective journeys are taken on\nthat released build.\n' '' "no confirmation"
d=$(copy "$HD") && rm -f "$d/docs/vision.md" && out=$(gate "$d" --depth complete) && rc=0 || rc=$?
refused "missing vision" "$out" "$rc" "docs/vision.md is missing"
complete_fault "vision left as a template" docs/vision.md 'Two weeks of agent time for the first charter.' '<How much time this is worth>' "vision: a template placeholder"
complete_fault "fields-only object" docs/domain/model.md '- Behaviour: `create(reason)`, `accept(agent)`, `close(note)`' '- Behaviour: none' "Handoff has no behaviour"
complete_fault "invariant with no breaking journey" docs/domain/model.md '  - a closed handoff cannot be accepted (proved by `closed-handoff-cannot-be-accepted`)' '  - a closed handoff cannot be accepted' "names no journey that tries to break it"
complete_fault "no lifecycle line" docs/domain/model.md $'- Lifecycle: the Handoff state machine below.\n' '' "Handoff has no Lifecycle line"
complete_fault "start edge with no row" docs/domain/model.md $'| [*] | waiting | create | a reason is given | HandoffRequested | bot-hands-off-unknown |\n' '' "diagram edge [*] --> waiting : create has no table row"
complete_fault "empty guard" docs/domain/model.md '| answered | awaiting_answer | receive | always |' '| answered | awaiting_answer | receive |  |' "has no guard"
complete_fault "entity not in the glossary" docs/domain/model.md 'AGENT ||--o{ HANDOFF : accepts' 'SUPERVISOR ||--o{ HANDOFF : accepts' "entity SUPERVISOR is not a glossary term"
complete_fault "a journey no objective has" docs/charter.md '| C2 | Command line for the bot | B1 | - | none (the public operations) | first-question-gets-answer |' '| C2 | Command line for the bot | B1 | - | none (the public operations) | widget-loads |' "names journey widget-loads"
complete_fault "a ticket waiting on its own batch" docs/charter.md '| C2 | Command line for the bot | B1 | - |' '| C2 | Command line for the bot | B1 | C1 |' "depends on C1 in its own batch"
complete_fault "no hosting record at complete" docs/adr/0003-host-on-one-small-server.md 'kind: hosting' 'kind: other' "decision record of kind hosting"
complete_fault "a rule with no check" docs/ways-of-working.md '| Strict types, no `any` | refusals are typed, not guessed | typescript-eslint strictTypeChecked in `core/standards/typescript-react/base.js` |' '| Strict types, no `any` | refusals are typed, not guessed |  |' "names no check"
complete_fault "a charter ticket with no batch" docs/charter.md '| C2 | Command line for the bot | B1 | - |' '| C2 | Command line for the bot | B9 | - |' "ticket C2 has no known batch"
complete_fault "a charter ticket waiting on a later batch" docs/charter.md '| C1 | Conversation answers with sources | B1 | - |' '| C1 | Conversation answers with sources | B1 | C3 |' "depends on C3 of a later batch"
complete_fault "a milestone with no journey" docs/charter.md ' | first-question-gets-answer, follow-up-question, answer-without-source-refused | C1, C2 |' ' |  | C1, C2 |' "milestone M1 walking skeleton has no journey"

# Handoff's state machine removed with `Lifecycle: none`: no reason, and a state field with no machine (two lines)
d=$(copy "$HD")
edit "$d" docs/domain/model.md "$HANDOFF_MACHINE" ''
edit "$d" docs/domain/model.md '- Lifecycle: the Handoff state machine below.' '- Lifecycle: none'
out=$(gate "$d" --depth complete) && rc=0 || rc=$?
refused "machine removed, Lifecycle: none with no reason" "$out" "$rc" '"Lifecycle: none" gives no reason' "Handoff keeps a state field but has no state machine"
d=$(copy "$HD")
edit "$d" docs/domain/model.md "$HANDOFF_MACHINE" ''
edit "$d" docs/domain/model.md '- Lifecycle: the Handoff state machine below.' '- Lifecycle: none - it is simple'
out=$(gate "$d" --depth complete) && rc=0 || rc=$?
refused "machine removed, a reason given" "$out" "$rc" "Handoff keeps a state field but has no state machine"
d=$(copy "$HD") && rm -f "$d"/docs/adr/0*.md && out=$(gate "$d" --depth complete) && rc=0 || rc=$?
refused "no decision record at all" "$out" "$rc" "docs/adr holds no decision record"

# A stateless value object with a reason is a legitimate pack
d=$(copy "$HD")
edit "$d" GLOSSARY.md $'## Other terms\n\n### Message\n' $'### Answer source\nA document or page the bot may quote; every answer names at least one. Owns: a source has a link.\n_Avoid_: knowledge, context\n\n## Other terms\n\n### Message\n'
edit "$d" GLOSSARY.md $'\n### Answer source\nA document or page the bot may quote; every answer names at least one.\n_Avoid_: knowledge, context\n\n### User' $'\n### User'
edit "$d" docs/domain/model.md $'## State machines\n' $'### Answer source\n- Responsibility: name one document or page an answer quotes.\n- Behaviour: `cite(link)`\n- Invariants:\n  - a source has a link (proved by `answer-without-source-refused`)\n- Lives in: `src/domain/conversation.ts`\n- Lifecycle: none - a value: it is written once when quoted and never changes.\n- Fields: title, link\n\n## State machines\n'
out=$(gate "$d" --depth complete) || fail "a stateless value object with a reason is refused: $out"
assert_equals "PASS" "$out" "a stateless value object with a reason passes at complete"
pass "a stateless value object with Lifecycle: none - <reason> passes at complete"

# ---- planted faults in a feature's change pack, at full depth
change_fault "a change pack omitting a named journey" docs/changes/rate-a-conversation.md $'- reopen-clears-rating (new)\n' '' "names journey reopen-clears-rating, which its Objectives omit"
change_fault "a change-pack ADR reduced to an idea" docs/adr/0004-store-the-rating-on-the-conversation.md $'- A separate ratings list keyed by conversation id, written by a reporting service.\n' '' "fewer than two considered options"
change_fault "a change pack with no ADR" docs/changes/rate-a-conversation.md $'- New: [ADR 0004](../adr/0004-store-the-rating-on-the-conversation.md) store the rating on the conversation (accepted).\n' '' "no new decision record"
change_fault "a vision line not really added" docs/changes/rate-a-conversation.md 'and that score is kept with it."' 'and that score is shown to the agent."' "is not added by the real change"
change_fault "changelog lines that differ from the real ones" docs/changes/rate-a-conversation.md $'- Changed: Reopening a conversation clears its rating.\n' '' "differ from the real Unreleased lines"
change_fault "a real behaviour left out" docs/changes/rate-a-conversation.md '| Conversation | `rate(score)` |' '| Conversation | - |' "adds Conversation.rate, which Objects changed does not list"
change_fault "a feature ticket waiting on a later batch" docs/changes/rate-a-conversation.md '| R1 | Conversation can be rated | B1 | - |' '| R1 | Conversation can be rated | B1 | R2 |' "depends on R2 of a later batch"
change_fault "an unlisted vision promise" docs/vision.md 'and that score is kept with it.' 'and that score is kept with it. Support leads can export every rating to a report.' 'adds vision line "Support leads can export every rating to a report.", which Vision changes does not list'
change_fault "an unlisted vision removal" docs/vision.md ' No question waits without an owner: it is with the bot, with a person, or resolved.' '' 'removes vision line "No question waits without an owner'
change_fault "an unlisted new meaning for an existing term" GLOSSARY.md 'One turn from the user or the bot inside a conversation.' 'One turn from the user, the bot or an external auditor inside a conversation.' "the real change redefines glossary term Message, which Glossary changes does not list"
change_fault "an unlisted removed term" GLOSSARY.md $'### Resolve\nTo end a conversation: the user confirms the answer, or the agent closes the handoff.\n\n' '' "the real change removes glossary term Resolve, which Glossary changes does not list"
change_fault "a term listed with a kind the real change did not make" docs/changes/rate-a-conversation.md '| Rating | ADDED |' '| Rating | MODIFIED |' "glossary term Rating is not modified by the real change"

# ---- light and full depth check a feature: no change pack or no baseline named is refused, never checked as a project
out=$(gate "$RT" --depth full) && rc=0 || rc=$?
refused "full with no change pack named" "$out" "$rc" "full depth checks a feature"
out=$(gate "$RT" --depth light) && rc=0 || rc=$?
refused "light with no change pack named" "$out" "$rc" "light depth checks a feature"
out=$(gate "$RT" --depth light --change "$SLUG") && rc=0 || rc=$?
refused "light with no baseline named" "$out" "$rc" "light depth checks a feature"
out=$(gate "$RT" --depth skip) && rc=0 || rc=$?
refused "skip has no pack" "$out" "$rc" "unknown depth skip"
d=$(copy "$RT") && rm -f "$d"/docs/adr/0*.md
out=$(gate "$d" --depth light --change "$SLUG" --before "$HD") && rc=0 || rc=$?
refused "light with the change named and no decision records" "$out" "$rc" "docs/adr holds no decision record" "ADR 0004 is not added by the real change"

SHORT_ADR=$'---\nstatus: accepted\ndate: 2026-12-20\ndecision-makers: the captain\nkind: feature\nmuster: rating feature muster\n---\n# Store the rating on the conversation\n\n## Context and problem\nA rating needs a home that clears on reopen.\n\n## Considered options\n- A field on Conversation, set by `rate(score)`. (chosen)\n- A separate ratings list.\n\n## Decision\nWe keep the rating on Conversation, because the reopen rule lives there.\n\n## Consequences\n- Good: one owner for the rule. Bad: reports read whole conversations.\n\n## Confirmation\nThe journey `reopen-clears-rating` passes.\n'
IDEA_ADR=$'---\ndate: 2026-12-20\n---\n# Ratings\n\n## Context and problem\nMaybe store ratings somewhere; a table could work, or the conversation.\n\n## Confirmation\nTo be decided.\n'
light_case() {  # <decision record text>: the rated pack cut down to a light change, with that record as decision 0004
  local d
  d=$(copy "$RT")
  python3 -I "$T/edit.py" light "$d" || fail "the light copy does not apply"
  printf '%s' "$1" > "$d/docs/adr/0004-store-the-rating-on-the-conversation.md"
  gate "$d" --depth light --change "$SLUG" --before "$HD"
}
out=$(light_case "$SHORT_ADR") || fail "a short real decision record is refused at light depth: $out"
assert_equals "PASS" "$out" "a short real record passes at light depth"
pass "light depth: a short real decision record passes"
out=$(light_case "$IDEA_ADR") && rc=0 || rc=$?
refused "light depth: an idea-only decision record" "$out" "$rc" "an idea, not a decision"

# ---- the command line itself
out=$("$GATE" check "$T/no-such-tree" --depth complete 2>&1) && rc=0 || rc=$?
expect_code 2 "$rc" "a project that does not exist"
assert_contains "$out" "is not a directory" "a missing project is a usage error"
out=$("$GATE" check "$RT" --depth full --change '../x' --before "$HD" 2>&1) && rc=0 || rc=$?
expect_code 2 "$rc" "a change slug that is a path"
out=$("$GATE" 2>&1) && rc=0 || rc=$?
expect_code 2 "$rc" "no verb"
out=$("$GATE" --help) || fail "--help must exit 0"
assert_contains "$out" "jg-muster-gate.sh check <project> --depth complete" "--help prints the header usage"
pass "usage errors exit 2 and --help prints the header"
