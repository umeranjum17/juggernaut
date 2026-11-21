#!/usr/bin/env bash
# Behavior test for the muster objectives run and the muster machine (bin/jg-muster-objectives.sh, core/machines/tables/muster.tsv,
# core/machines/observers/muster.sh). Everything runs on a throwaway home and throwaway projects the test builds itself: a skeleton
# commit (the base: stale journeys, code that knows one command), then a pack (spec, journeys, model) and a head commit with the code.
# The objectives run: base = the base's code with the head's journeys; new fails its named assertion on the base and passes on the
# head; preserve passes on both; exit 77 is a setup error. The code check finds each model behaviour in its module. The observer
# walks one two-objective ticket from approval to secured through its receipts and the release record.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OBJ="$ROOT/bin/jg-muster-objectives.sh"; JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-muster-objectives)
jg_git_identity
run() { OUT=$("$@" 2>&1); RC=$?; }
oj() { run bash "$OBJ" "$@"; }

# --- the throwaway project ---------------------------------------------------------------------------------------------------------
P=$T/proj; mkdir -p "$P/src" "$P/journeys" "$P/docs/specs" "$P/docs/domain"; git -C "$P" init -q -b main
# the skeleton: code that knows `keep` only, and a stale journey runner that passes everything (the head's runner must replace it)
cat > "$P/src/app.sh" <<'EOF'
case $1 in keep) echo kept ;; *) echo "app: unknown command $1"; exit 2 ;; esac
EOF
printf '#!/usr/bin/env bash\necho stale runner\nexit 0\n' > "$P/journeys/run.sh"
git -C "$P" add -A; git -C "$P" commit -qm skeleton; SKEL=$(git -C "$P" rev-parse HEAD)

# the pack, uncommitted: journeys written before code
cat > "$P/journeys/run.sh" <<'EOF'
#!/usr/bin/env bash
# usage: run.sh <journey id>; exit 0 passes, 1 + `assert: <name>` fails an assertion, 77 is a setup error
expect() { [ "$(bash src/app.sh "$1" 2>&1)" = "$2" ] || { echo "assert: $3"; exit 1; }; }
case $1 in
  greet) expect greet hello "greeting said hello" ;;
  shout) expect shout HELLO "shout said HELLO" ;;
  keep) expect keep kept "keep still works" ;;
  needs-tool) command -v no-such-tool-anywhere >/dev/null || { echo "no-such-tool-anywhere is missing"; exit 77; } ;;
  *) echo "unknown journey $1"; exit 2 ;;
esac
EOF
journeys() {  # <id>... -> .done-done.yaml
  { echo 'journeys:'; for j in "$@"; do echo "  $j: {tier: local, command: bash journeys/run.sh $j}"; done; } > "$P/.done-done.yaml"; }
spec() {  # <id kind>... -> docs/specs/app.md
  { printf -- '---\ntitle: App\nslug: app\nstatus: planned\n---\n# Spec: App\n\n## Objectives (proof first)\n| Journey id | Kind | Key example |\n|---|---|---|\n'
    for r in "$@"; do read -r a b <<< "$r"; printf '| %s | %s | given, when, then |\n' "$a" "$b"; done
    printf '\n## Verification\nthe journeys\n'; } > "$P/docs/specs/app.md"; }
journeys greet shout keep; spec "greet new" "shout new" "keep preserve"

oj objectives "$P" --base "$SKEL"
expect_code 0 "$RC" "the base half alone is accepted: every new journey fails on its named assertion, the preserve one passes"
assert_contains "$OUT" 'ok   greet (new): base exit 1 "assert: greeting said hello"' "a new journey fails on its named assertion on the base"
assert_contains "$OUT" 'ok   keep (preserve): base exit 0' "a preserve journey passes on the base"
assert_not_contains "$OUT" "stale runner" "the head's journeys replaced the base's stale runner"
assert_equals PASS "$(printf '%s\n' "$OUT" | tail -n 1)" "the base-only form ends in PASS"
pass "objectives <project> --base <ref>: the base half runs the head's journeys over the base's code"

# a new journey that passes on the base is refused
spec "greet new" "shout new" "keep new"; oj objectives "$P" --base "$SKEL"
expect_code 1 "$RC" "a new journey that passes on the base is refused"
assert_contains "$OUT" 'FAIL keep (new): base exit 0' "the refusal names the journey"
assert_contains "$OUT" "refused: objectives: 1 journey(s) break the rule" "the verdict counts it"
# a preserve journey that fails on the base is refused
spec "greet preserve" "shout new" "keep preserve"; oj objectives "$P" --base "$SKEL"
expect_code 1 "$RC" "a preserve journey that fails on the base is refused"
assert_contains "$OUT" 'FAIL greet (preserve): base exit 1' "the refusal names the preserve journey"
# exit 77 is a setup error, never the expected failure
journeys greet shout keep needs-tool; spec "greet new" "shout new" "keep preserve" "needs-tool new"; oj objectives "$P" --base "$SKEL"
expect_code 1 "$RC" "exit 77 is not the expected failure"
assert_contains "$OUT" 'FAIL needs-tool (new): base exit 77 "no-such-tool-anywhere is missing" [setup error]' "it is named a setup error"
# a spec row with no command in .done-done.yaml, and one journey with two kinds
journeys greet shout keep; spec "greet new" "shout new" "keep preserve" "ghost new"; oj objectives "$P" --base "$SKEL"
expect_code 1 "$RC" "a journey with no command is refused"
assert_contains "$OUT" "FAIL ghost (new): no journey command in .done-done.yaml" "the refusal names it"
spec "greet new" "greet preserve"; oj objectives "$P" --base "$SKEL"
expect_code 1 "$RC" "a journey with two kinds is refused"
assert_contains "$OUT" "journey greet has two kinds" "the refusal names it"
oj objectives "$P"; expect_code 2 "$RC" "no --base is a usage error"
oj objectives "$P" --base no-such-ref; expect_code 2 "$RC" "an unknown base is a usage error"
pass "a new journey that passes on the base, a failing preserve, exit 77, a missing command and two kinds are each refused"

# --- the head: code written, pack committed ----------------------------------------------------------------------------------------
cat > "$P/src/app.sh" <<'EOF'
case $1 in keep) echo kept ;; greet) echo hello ;; shout) echo HELLO ;; *) echo "app: unknown command $1"; exit 2 ;; esac
EOF
spec "greet new" "shout new" "keep preserve"
git -C "$P" add -A; git -C "$P" commit -qm "head: pack and code"; HEAD1=$(git -C "$P" rev-parse HEAD)
oj objectives "$P" --base "$SKEL" --head "$HEAD1"
expect_code 0 "$RC" "both halves: new fails on the base and passes on the head, preserve passes on both"
assert_contains "$OUT" 'ok   greet (new): base exit 1 "assert: greeting said hello"; head exit 0' "the head column is filled"
assert_contains "$OUT" 'ok   keep (preserve): base exit 0 ""; head exit 0' "preserve passes on both"
# the base ref's own journeys never decide: with the head's runner restored, a head that is the base passes nothing new
oj objectives "$P" --base "$HEAD1" --head "$HEAD1"
expect_code 1 "$RC" "a new journey that already passes on the base is refused with both halves too"
assert_contains "$OUT" 'FAIL greet (new): base exit 0' "named"
# a head whose code breaks a new journey is refused
# shellcheck disable=SC2016  # program text for the fixture, written literally
printf 'case $1 in keep) echo kept ;; greet) echo hello ;; *) echo "app: unknown command $1"; exit 2 ;; esac\n' > "$P/src/app.sh"
git -C "$P" commit -qam "head: shout not built"; BROKEN=$(git -C "$P" rev-parse HEAD)
oj objectives "$P" --base "$SKEL" --head "$BROKEN"
expect_code 1 "$RC" "a new journey that fails on the head is refused"
assert_contains "$OUT" 'FAIL shout (new): base exit 1 "assert: shout said HELLO"; head exit 1' "the head's exit is shown"
# a feature's change pack names its own objectives
mkdir -p "$P/docs/changes"; printf '# Change: shout\n\n## Objectives\n- shout (new)\n- keep (preserve)\n\n## Charter\n' > "$P/docs/changes/shout.md"
git -C "$P" checkout -q "$HEAD1" -- src/app.sh; git -C "$P" add -A; git -C "$P" commit -qm "change pack"; HEAD2=$(git -C "$P" rev-parse HEAD)
oj objectives "$P" --base "$SKEL" --head "$HEAD2" --change shout
expect_code 0 "$RC" "--change <slug> reads the change pack's Objectives"
assert_not_contains "$OUT" "greet" "only the change pack's journeys run"
oj objectives "$P" --base "$SKEL" --head "$HEAD2" --change nope; expect_code 2 "$RC" "an unknown change pack is a usage error"
pass "objectives --base --head: both halves; a broken head and a base that already passes are refused; --change picks a change pack"

# --- the code check ----------------------------------------------------------------------------------------------------------------
cat > "$P/docs/domain/model.md" <<'EOF'
# Model

## Core objects

### Greeter
- Responsibility: greet.
- Behaviour: `greet(name)`, `shout(name)`
- Lives in: `src/greeter.ts`

### Keeper
- Behaviour: `keep()`
- Lives in: `src/keeper.ts`

## State machines
EOF
mkdir -p "$P/src"; printf 'export class Greeter {\n  greet(name: string) { return "hello"; }\n  static shout(name: string) { return "HELLO"; }\n}\n' > "$P/src/greeter.ts"
printf 'keep() { echo kept; }\n' > "$P/src/keeper.ts"
run bash "$OBJ" code "$P"; expect_code 0 "$RC" "every behaviour is defined in its module"; assert_equals PASS "$OUT" "code passes"
printf 'export class Greeter {\n  greet(name: string) { return "hello"; }\n}\n' > "$P/src/greeter.ts"
run bash "$OBJ" code "$P"; expect_code 1 "$RC" "a missing behaviour is refused"
assert_equals "refused: code: Greeter.shout not found in src/greeter.ts" "$OUT" "it names the object, the method and the module"
rm "$P/src/keeper.ts"; run bash "$OBJ" code "$P"
assert_contains "$OUT" "refused: code: Keeper.keep not found: its module src/keeper.ts is missing" "a missing module is named"
run bash "$OBJ" code "$T/empty"; expect_code 1 "$RC" "no model, no pass"
printf '# Model\n\n## Core objects\n\n## State machines\n' > "$P/docs/domain/model.md"; run bash "$OBJ" code "$P"
expect_code 1 "$RC" "a model that names no behaviour proves nothing"
assert_contains "$OUT" "names no behaviour" "the refusal says so"
pass "code <project>: each model behaviour is found in its Lives-in module, each miss is named"

# --- the muster machine ------------------------------------------------------------------------------------------------------------
run python3 -I "$ROOT/core/machines/bin/tablelint.py" "$ROOT/core/machines/tables/muster.tsv"; expect_code 0 "$RC" "the table lints"
run bash "$JM" enum muster; expect_code 0 "$RC" "the enum lints"
run bash "$JM" coverage muster; expect_code 0 "$RC" "every edge names its test"
run bash "$JM" events muster; expect_code 0 "$RC" "events lists the table"
for e in "round	triage	intent" "check	objectives	check" "ask	check	approval" "approve	approval	war-room" "prove	blitz	landed" "release	landed	secured"; do
  assert_contains "$OUT" "$e" "event ${e%%	*} is declared"; done
if grep -q "^muster-machine	" "$ROOT/core/machines/changes.tsv"; then pass "changes.tsv declares muster-machine"; else fail "changes.tsv has no muster-machine row"; fi

export JG_HOME=$T/home; export JG_DATA_OVERRIDE=$JG_HOME/data JG_STATE_OVERRIDE=$JG_HOME/state
unset JG_ROOT_OVERRIDE; mkdir -p "$JG_STATE_OVERRIDE"; TK=m-1; D=$JG_DATA_OVERRIDE/$TK/muster
show() { run bash "$JM" show muster "$TK"; }
shows() { show; assert_equals "$1" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }')" "$2"; }
shows_none() { show; expect_code 1 "$RC" "a ticket with no muster folder is in no state"; }
shows_none
mkdir -p "$D"; echo "$P" > "$D/project"
Q=$T/q; mkdir -p "$Q"; git -C "$Q" init -q -b main; printf 'x\n' > "$Q/f"; git -C "$Q" add -A; git -C "$Q" commit -qm first   # a bare project
echo "$Q" > "$D/project"; shows triage "no round and no document: triage"
: > "$D/rounds.tsv"; shows intent "a round record: intent"
mkdir -p "$Q/docs/domain" "$Q/docs/specs"; echo v > "$Q/docs/vision.md"; shows intent "a vision: intent"
echo g > "$Q/GLOSSARY.md"; shows lexicon "a glossary: lexicon"
echo w > "$Q/docs/ways-of-working.md"; shows rules "ways of working: rules"
echo m > "$Q/docs/domain/model.md"; shows terrain "a model: terrain"
echo c > "$Q/docs/charter.md"; shows charter "a charter: charter"
printf '## Objectives\n| Journey id | Kind |\n|---|---|\n| greet | new |\n| shout | new |\n' > "$Q/docs/specs/app.md"; shows objectives "objectives in a spec: objectives"
pass "before the manifest the state is the latest stage whose output exists"

# the checked pack: a manifest with a check line and two journeys; the approval verifier is a stand-in the test controls
printf 'check complete - pass abcdef123456\njourney greet new\njourney shout new\n' > "$D/manifest-aaaaaaaaaaaa.tsv"
VERIFY=$T/verify.sh; printf '#!/usr/bin/env bash\n[ -f "%s/approved" ]\n' "$T" > "$VERIFY"; chmod +x "$VERIFY"; export JG_MUSTER_APPROVAL_VERIFY="bash $VERIFY"
shows check "a checked pack nobody asked about: check"
printf '1\tapprove\taaaaaaaaaaaa\tg-1\tApprove the agreed documents for proj, version 1?\t1\n' > "$D/approvals.tsv"
shows approval "asked and not answered yes: approval"
touch "$T/approved"; shows war-room "approved, no receipt yet: war-room"
git -C "$Q" add -A; git -C "$Q" commit -qm "built"; C=$(git -C "$Q" rev-parse HEAD); OLD=$(git -C "$Q" rev-parse HEAD~1)
RUNS=$Q/.done-done/runs; mkdir -p "$RUNS"
receipt() {  # <journey> <commit> <dirty> <exit>
  printf '{"schema":1,"journey":"%s","commit":"%s","dirty":%s,"exit":%s}\n' "$1" "$2" "$3" "$4" > "$RUNS/$1-$2-$3-$4.json"; }
receipt greet "$OLD" false 0; receipt greet "$C" true 0; receipt greet "$C" false 1; shows war-room "a receipt on an older commit, a dirty one and a failed one count for nothing"
receipt greet "$C" false 0; shows blitz "one receipt of two: blitz"
assert_contains "$OUT" "landed, not secured" "its sentence says landed, not secured"
receipt shout "$C" false 0; shows landed "both receipts, no release record: landed"
assert_contains "$OUT" "landed, not released" "its sentence says landed, not released"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/services.sh"; chmod +x "$T/services.sh"; export JG_LIVE_SERVICES_BIN=$T/services.sh
printf '# releases\nv0.0.1 prs=1\n' > "$JG_DATA_OVERRIDE/releases"; shows landed "a release record that does not name the commit: still landed"
printf '%s prs=2\n' "$C" >> "$JG_DATA_OVERRIDE/releases"
shows landed "a release names the commit but the model names no behaviour in the code: landed"
mkdir -p "$Q/src"; printf 'greet() { :; }\nshout() { :; }\n' > "$Q/src/g.sh"
# shellcheck disable=SC2016  # program text for the fixture, written literally
printf '## Core objects\n\n### Greeter\n- Behaviour: `greet(n)`, `shout(n)`\n- Lives in: `src/g.sh`\n' > "$Q/docs/domain/model.md"
git -C "$Q" add -A; git -C "$Q" commit -qm "code"; C2=$(git -C "$Q" rev-parse HEAD)
shows war-room "a new commit has no receipts yet: back to war-room"
receipt greet "$C2" false 0; receipt shout "$C2" false 0; shows landed "receipts on the new commit, no release names it: landed"
printf '%s prs=3\n' "$C2" >> "$JG_DATA_OVERRIDE/releases"; shows secured "both receipts, a release names the commit, the code has the behaviour: secured"
assert_contains "$OUT" "Secured" "its sentence says secured"
rm "$T/approved"; shows approval "his yes no longer holds: back to approval"
pass "the observer: war-room, blitz, landed, secured from the receipts and the release record, and approval from the verifier"

# --- the command contract fragment ------------------------------------------------------------------------------------------------
F=$ROOT/core/agent-cli/contract/muster-state.json
jq -e '(.area|type=="string") and (.owner|type=="string") and (.entries|length>0) and all(.entries[];
(.path|type=="array" and length>0) and (.meaning|type=="string" and length>0) and (.roles|type=="array") and
(.changes|type=="boolean") and (.method == (if .changes then "POST" else "GET" end)) and
((.changes|not) or (.repeat_key|type=="string")) and (.script|startswith("bin/")) and (.operation|type=="string"))' "$F" >/dev/null || fail "the fragment does not have the frozen shape"
pass "the fragment has the frozen shape"
assert_equals "muster objectives
muster code
muster status" "$(jq -r '.entries[] | .path | join(" ")' "$F")" "it names the three paths"
# every entry is GET: its form ran above on fixtures and changed no file (the project tree is unchanged by a base run)
run git -C "$P" status --porcelain; BEFORE=$OUT; oj objectives "$P" --base "$SKEL" --head "$HEAD2" --change shout; run git -C "$P" status --porcelain
assert_equals "$BEFORE" "$OUT" "a run changes no file of the project"
jq -e 'all(.entries[]; .method == "GET" and .changes == false)' "$F" >/dev/null || fail "an entry is not a read"
pass "all three entries are reads"
