#!/usr/bin/env bash
# /muster survey reads an existing project first: bin/jg-muster-survey.sh writes five drafts and a gap list from the committed fixture
# project tests/fixtures/muster-survey/shopfront (a small TypeScript shop with docs, tests, CI and a CONSTRAINTS.md). The real script
# runs on a copy of the fixture under a throwaway home; no live home and no live project is read.
#
# S1 glossary: terms from type names and doc headings, a doc's first sentence as the proposed definition, a doc-only term kept.
# S2 core objects: Order, Invoice and Parcel with their state values (a type alias, an inline union, an enum), behaviour and fields;
#    Customer and Order Line (no state) stay glossary terms; every file is marked draft.
# S3 standards: eslint, strict tsc, vitest, bash tests, CI and folders detected; CONSTRAINTS.md read into the ways-of-working sections.
# S4 preserve journeys: one candidate for each existing test name, from it(), describe() and `# T<n>` lines.
# S5 gaps: five to a round, most important first, in the council's question format; the owner's questions say owner: yes.
# S6 safety: the project is byte for byte unchanged, a second run writes identical files, --ticket writes under the ticket's muster folder.
# S7 refusals: unknown project exit 4, no argument exit 2, an output folder inside the project exit 1 with nothing written.
# S8 contract: the fragment has the frozen shape (formats.md section 6).
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-muster-survey)
HOME_DIR="$TMP_ROOT/home"; PROJ="$HOME_DIR/projects/shopfront"; OUT="$HOME_DIR/data/muster-survey/shopfront"
mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data"
cp -r "$ROOT/tests/fixtures/muster-survey/shopfront" "$PROJ"
export JG_HOME="$HOME_DIR" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_PROJECTS_OVERRIDE="$HOME_DIR/projects"
SURVEY="$ROOT/bin/jg-muster-survey.sh"
digest() { (cd "$1" && find . -type f | sort | xargs sha256sum | sha256sum); }

before=$(digest "$PROJ")
run_out=$("$SURVEY" shopfront 2>&1); rc=$?
[ $rc -eq 0 ] || fail "survey should exit 0, got $rc: $run_out"
case $run_out in *"3 core objects"*) ;; *) fail "the summary should count 3 core objects: $run_out" ;; esac
for f in GLOSSARY.draft.md core-objects.draft.md ways-of-working.draft.md preserve-journeys.draft.md gaps.md; do
  [ -s "$OUT/$f" ] || fail "missing draft $f"
done
for f in GLOSSARY.draft.md core-objects.draft.md ways-of-working.draft.md preserve-journeys.draft.md; do
  grep -q 'Draft for the drafter' "$OUT/$f" || fail "$f should be marked draft for the drafter"
done

has() { grep -qF -- "$2" "$OUT/$1" || fail "$3: $1 should hold: $2"; }
hasnt() { ! grep -qF -- "$2" "$OUT/$1" || fail "$3: $1 should not hold: $2"; }

has GLOSSARY.draft.md '### Order' S1; has GLOSSARY.draft.md '### Customer' S1; has GLOSSARY.draft.md '### Return Window' S1
has GLOSSARY.draft.md 'An order is what a customer places to buy goods.' S1
has GLOSSARY.draft.md 'The return window is the number of days after delivery' S1
hasnt GLOSSARY.draft.md '### Installation' S1; hasnt GLOSSARY.draft.md '### OrderStatus' S1; hasnt GLOSSARY.draft.md '### Order Status' S1
pass "S1 glossary: code and doc terms, the doc sentence as the proposed definition, generic headings and state types left out"

for o in Order Invoice Parcel; do has core-objects.draft.md "### $o" S2; done
has core-objects.draft.md 'draft, paid, shipped, cancelled' S2; has core-objects.draft.md 'open, settled' S2
has core-objects.draft.md 'packed, in-transit, delivered' S2; has core-objects.draft.md '`pay()`, `ship()`, `cancel()`' S2
has core-objects.draft.md 'Lives in: `src/orders/order.ts`' S2
hasnt core-objects.draft.md '### Customer' S2; hasnt core-objects.draft.md '### Order Line' S2
has GLOSSARY.draft.md '### Order Line' S2
pass "S2 core objects: three state-bearing objects with their state values, behaviour and files; stateless types stay terms"

has ways-of-working.draft.md 'Lint with eslint' S3; has ways-of-working.draft.md 'Type-check with tsc (strict)' S3
has ways-of-working.draft.md 'vitest (vitest.config.ts), bash tests' S3; has ways-of-working.draft.md '.github/workflows/ci.yml' S3
has ways-of-working.draft.md 'Under src: src/billing, src/customers, src/orders, src/shipping' S3
has ways-of-working.draft.md '## Floor (numbers)' S3; has ways-of-working.draft.md 'No new `eslint-disable` comments' S3
has ways-of-working.draft.md 'Line coverage stays at or above 80 percent' S3
has ways-of-working.draft.md '## Measured, not yet enforced' S3; has ways-of-working.draft.md 'Bundle size is 212 KB today' S3
has ways-of-working.draft.md '## Exceptions (time-limited)' S3; has ways-of-working.draft.md '`src/billing/legacy.ts` may use `any`' S3
has ways-of-working.draft.md 'until 2026-12-31' S3; has ways-of-working.draft.md '## From CONSTRAINTS.md: Reviews' S3
pass "S3 standards: lint, type-check, test, CI and folders detected; CONSTRAINTS.md sections carried into the ways-of-working sections"

has preserve-journeys.draft.md 'Order: pays a draft order' S4; has preserve-journeys.draft.md 'Order: refuses to cancel a shipped order' S4
has preserve-journeys.draft.md 'a refund inside the return window is accepted' S4; has preserve-journeys.draft.md 'a refund after the return window is refused' S4
[ "$(grep -c 'preserve (draft)' "$OUT/preserve-journeys.draft.md")" -eq 4 ] || fail "S4 expected exactly four candidates"
pass "S4 preserve journeys: four candidates from the existing tests, each kind preserve"

[ "$(grep -c '^- Q: ' "$OUT/gaps.md")" -ge 8 ] || fail "S5 expected at least eight gap questions"
for n in 1 2 3; do
  c=$(awk -v r="## Round $n" '$0 == r { on = 1; next } /^## / { on = 0 } on && /^- Q: /' "$OUT/gaps.md" | wc -l)
  [ "$c" -ge 1 ] && [ "$c" -le 5 ] || fail "S5 round $n holds $c questions, expected 1 to 5"
done
first=$(awk '$0 == "## Round 1" { on = 1; next } /^## / { on = 0 } on && /^- Q: /' "$OUT/gaps.md")
case $first in *"What moves the Order between its states"*) ;; *) fail "S5 round 1 should ask what moves the Order" ;; esac
case $first in *"Why does this product exist, and for whom? | A: | owner: yes"*) ;; *) fail "S5 round 1 should ask the purpose as an owner question" ;; esac
grep -qE '^- Q: .+ \| A: \| owner: (yes|no)$' "$OUT/gaps.md" || fail "S5 questions follow the council format"
has gaps.md 'No test drives the Order state(s) cancelled' S5; has gaps.md '"Return Window" is in the docs' S5
has gaps.md 'No decision records exist' S5; has gaps.md 'languages the survey does not read (Python)' S5
hasnt gaps.md 'No linter was found' S5; hasnt gaps.md 'No test runner was found' S5
pass "S5 gaps: only what reading could not settle, five to a round, owner questions marked"

[ "$(digest "$PROJ")" = "$before" ] || fail "S6 the survey changed the project"
first_run=$(digest "$OUT"); "$SURVEY" shopfront >/dev/null 2>&1 || fail "S6 second run failed"
[ "$(digest "$OUT")" = "$first_run" ] || fail "S6 a second run should write identical files"
"$SURVEY" shopfront --ticket jg-demo >/dev/null 2>&1 || fail "S6 --ticket run failed"
[ -s "$HOME_DIR/data/jg-demo/muster/survey/gaps.md" ] || fail "S6 --ticket should write under data/<ticket>/muster/survey"
[ "$(digest "$PROJ")" = "$before" ] || fail "S6 the project changed after the ticket run"
pass "S6 the project is untouched, a second run is identical, --ticket writes under the ticket's muster folder"

"$SURVEY" nosuchproject >/dev/null 2>&1; [ $? -eq 4 ] || fail "S7 an unknown project should exit 4"
"$SURVEY" >/dev/null 2>&1; [ $? -eq 2 ] || fail "S7 no argument should exit 2"
"$SURVEY" shopfront --bogus >/dev/null 2>&1; [ $? -eq 2 ] || fail "S7 an unknown option should exit 2"
mkdir -p "$TMP_ROOT/inside"; cp -r "$ROOT/tests/fixtures/muster-survey/shopfront" "$TMP_ROOT/inside/proj"
refusal=$(JG_DATA_OVERRIDE="$TMP_ROOT/inside/proj/data" "$SURVEY" "$TMP_ROOT/inside/proj" 2>&1); rc=$?
[ $rc -eq 1 ] || fail "S7 an output folder inside the project should exit 1, got $rc"
case $refusal in *"inside the project"*) ;; *) fail "S7 the refusal should name the cause: $refusal" ;; esac
[ ! -e "$TMP_ROOT/inside/proj/data/muster-survey/proj/gaps.md" ] || fail "S7 a refused survey wrote a draft"
pass "S7 refusals: unknown project 4, usage 2, output inside the project 1 with nothing written"

frag="$ROOT/core/agent-cli/contract/muster-survey.json"
jq -e '(.area|type=="string") and (.owner|type=="string") and (.entries|length>0) and all(.entries[];
  (.path|type=="array" and length>0) and (.meaning|type=="string" and length>0) and (.roles|type=="array") and
  (.changes|type=="boolean") and (.method == (if .changes then "POST" else "GET" end)) and
  ((.changes|not) or (.repeat_key|type=="string")) and (.script|startswith("bin/")) and (.operation|type=="string"))' "$frag" >/dev/null \
  || fail "S8 the fragment does not have the frozen shape"
[ "$(jq -r '.owner' "$frag")" = m8 ] || fail "S8 the fragment owner is m8"
[ "$(jq -r '.entries[0].path | join(" ")' "$frag")" = "muster survey" ] || fail "S8 the path is 'muster survey'"
[ "$(jq -r ".entries[0].form" "$frag")" = "bin/$(sed -n "s/^# Usage: //p" "$SURVEY" | head -1)" ] || fail "S8 the form is the script's own usage line"
pass "S8 the fragment holds 'muster survey' in the frozen shape with the script's own usage line"
