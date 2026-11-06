#!/usr/bin/env bash
# Journey: the owner runs bin/jg-triage.sh against a home.
# Check mode reports and changes nothing; --fix repairs only through the guarded scripts, only
# when no other live session holds the home lock, and shows the state after the repair; an
# unreadable source is "unknown", never "dead"; --context writes a redacted facts file;
# --agent starts the home's verified harness on what is left. Every dependency is a stub in a
# fixture home, so no live fleet, network, model, or process is touched.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(jg_test_tmproot jg-triage)

# ---------------------------------------------------------------- fixture home
make_home() {  # <name> -> prints the home path
  local h="$TMP_ROOT/$1" b
  b="$h/bin"
  mkdir -p "$b" "$h/state" "$h/data" "$h/config" "$h/core/backlog-lock-reclaim"
  cp "$REPO_ROOT/bin/jg-triage.sh" "$b/jg-triage.sh"
  cat > "$b/jg-inbox.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = ready ] || exit 2
cat "$JG_HOME/ready.json"
STUB
  cat > "$b/jg-stack.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    if [ -e "$JG_HOME/stack.down" ]; then echo "STACK_FAILED: router: not running (unit inactive)"; exit 1; fi
    for p in bus wake-engine router dapr gateway; do echo "$p running pid 100"; done
    ;;
  up)
    echo up >> "$JG_HOME/calls.log"
    if [ -e "$JG_HOME/stack.stuck" ]; then echo "STACK_FAILED: router: not running (unit would not start)"; exit 1; fi
    rm -f "$JG_HOME/stack.down"
    ;;
  *) exit 2 ;;
esac
STUB
  cat > "$b/jg-bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
[ "${JG_BOOTSTRAP_DETECT_ONLY:-}" = 1 ] || { echo "bootstrap stub: detect-only is required" >&2; exit 9; }
[ ! -e "$JG_HOME/bootstrap.fail" ] || exit 1
[ ! -e "$JG_HOME/bootstrap.out" ] || cat "$JG_HOME/bootstrap.out"
STUB
  cat > "$b/jg-tmp-sweep.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  check)
    if [ -e "$JG_HOME/tmp.full" ]; then echo "/tmp space 96% used"; exit 1; fi
    echo "/tmp space 40% used"
    ;;
  sweep)
    [ "${2:-}" = --apply ] || exit 2
    echo sweep >> "$JG_HOME/calls.log"
    rm -f "$JG_HOME/tmp.full"
    echo "removed 3 stale folders"
    ;;
  *) exit 2 ;;
esac
STUB
  cat > "$b/jg-stray-nats-reap.sh" <<'STUB'
#!/usr/bin/env bash
[ "$#" -eq 0 ] || { echo "stray stub: only the dry run may be called" >> "$JG_HOME/calls.log"; exit 2; }
[ ! -e "$JG_HOME/stray.out" ] || cat "$JG_HOME/stray.out"
STUB
  cat > "$b/jg-harness.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = crew ] || exit 2
cat "$JG_HOME/harness.txt"
STUB
  cat > "$b/jg-squad-lead-liveness-lib.sh" <<'STUB'
#!/usr/bin/env bash
jg_squad_lead_liveness_probe() {  # <meta> <id> <mode>
  local v
  v=$(cat "$STATE/sl-$2.verdict" 2>/dev/null || echo alive)
  JG_SM_LIVE_STATUS=$v
  JG_SM_LIVE_STATE=dead
  JG_SM_LIVE_WHERE=pane-9
  JG_SM_LIVE_LINE="endpoint alive"
}
jg_squad_lead_liveness_lock() { return 0; }
jg_squad_lead_liveness_unlock() { return 0; }
jg_squad_lead_liveness_relaunch() {  # <meta> <id> <timeout>
  echo "relaunch $2" >> "$JG_HOME/calls.log"
  if [ -e "$STATE/sl-$2.refuse" ]; then JG_SM_LIVE_REASON="the pane is busy"; return 1; fi
  echo alive > "$STATE/sl-$2.verdict"
}
STUB
  cat > "$h/core/backlog-lock-reclaim/backlog-lock-reclaim.check.sh" <<'STUB'
#!/usr/bin/env bash
echo reclaim >> "$1/calls.log"
[ -s "$1/data/backlog.md.lock" ] || rm -f "$1/data/backlog.md.lock"
echo "reclaimed the stale backlog lock"
STUB
  chmod +x "$b"/*.sh "$h/core/backlog-lock-reclaim/backlog-lock-reclaim.check.sh"
  free_lock "$h"
  echo claude > "$h/harness.txt"
  printf '%s\n' "$h"
}
set_ready() {  # <home> <lock-state> <live> <wake-state>
  printf '{"lock":{"state":"%s","pid":"4242","live_harness":%s},"wake_consumer":{"state":"%s","reason":"fixture"}}\n' \
    "$2" "$3" "$4" > "$1/ready.json"
}
free_lock() { set_ready "$1" free false healthy; }
foreign_lock() { set_ready "$1" held true healthy; }
add_lead() {  # <home> <id> <verdict>
  printf 'kind=squad_lead\n' > "$1/state/$2.meta"
  printf '%s\n' "$3" > "$1/state/sl-$2.verdict"
}
age_file() { touch -d '10 minutes ago' "$1"; }
triage() {  # <home> args... ; sets OUT and RC
  local h=$1
  shift
  OUT=$(env -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE JG_HOME="$h" "$h/bin/jg-triage.sh" "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
}
calls() { cat "$1/calls.log" 2>/dev/null || true; }

# ---------------------------------------------------------------- 1: a healthy home
H=$(make_home healthy)
add_lead "$H" lead1 alive
triage "$H" --offline
expect_code 0 "$RC" "a healthy home exits 0"
assert_contains "$OUT" "mode check, nothing changed" "check mode says nothing changed"
assert_contains "$OUT" "0 fixable, 0 need you, 0 unreadable." "healthy summary"
assert_not_contains "$OUT" "Re-run with --fix" "a healthy home does not suggest --fix"
assert_contains "$OUT" "skip   login" "offline skips the login check"
triage "$H" --offline --porcelain
expect_code 0 "$RC" "porcelain healthy exit"
assert_contains "$OUT" "mode=check" "porcelain names the mode"
assert_contains "$OUT" "check stack=ok: 5 parts running" "porcelain stack line"
assert_contains "$OUT" "check squad-lead:lead1=ok:" "porcelain names the Squad Lead as the target"
assert_contains "$OUT" "summary fixable=0 human=0 unknown=0" "porcelain summary"
[ -z "$(calls "$H")" ] || fail "check mode must not call any repair: $(calls "$H")"
pass "a healthy home exits 0 and reports ok in both views"

# ---------------------------------------------------------------- 2: check mode reports, changes nothing
H=$(make_home broken)
touch "$H/stack.down" "$H/tmp.full"
: > "$H/data/backlog.md.lock"
age_file "$H/data/backlog.md.lock"
add_lead "$H" lead1 relaunchable
add_lead "$H" lead2 alive
printf 'MISSING: no-mistakes 1.44.0 below floor 1.46.0 (install: npm i -g no-mistakes)\nTANGLE: primary on feature/x (restore the primary with: git switch main)\n' > "$H/bootstrap.out"
printf 'would stop 777 age=90m /tmp/x/nats-server\nskip 778 young\n' > "$H/stray.out"
set_ready "$H" held true down
triage "$H" --offline
expect_code 1 "$RC" "findings exit 1"
assert_contains "$OUT" "FIX    stack" "a stopped part is a FIX"
assert_contains "$OUT" "FIX    backlog-lock" "an old 0-byte lock is a FIX"
assert_contains "$OUT" "FIX    squad-lead:lead1" "a dead lead is a FIX"
assert_contains "$OUT" "ok     squad-lead:lead2" "a live lead is ok"
assert_contains "$OUT" "FIX    tmp" "full /tmp is a FIX"
assert_contains "$OUT" "HUMAN  tools" "a missing tool is for a person"
assert_contains "$OUT" "run: npm i -g no-mistakes" "the install line is printed"
assert_contains "$OUT" "HUMAN  checkout" "a tangled checkout is for a person"
assert_contains "$OUT" "run: git switch main" "the restore step is printed"
assert_contains "$OUT" "HUMAN  wake-consumer" "a live session without a wake consumer is for a person"
assert_contains "$OUT" "INFO   stray-servers" "stray servers are reported"
assert_contains "$OUT" "run: bin/jg-stray-nats-reap.sh --stop" "the reaper command is printed, not run"
assert_contains "$OUT" "4 fixable, 3 need you, 0 unreadable. Re-run with --fix." "summary counts"
[ -z "$(calls "$H")" ] || fail "check mode changed something: $(calls "$H")"
[ -e "$H/stack.down" ] && [ -e "$H/data/backlog.md.lock" ] && [ -e "$H/tmp.full" ] || fail "check mode removed state"
pass "check mode finds every problem and changes nothing"

# ---------------------------------------------------------------- 3: --only
triage "$H" --offline --only stack,tools --porcelain
assert_contains "$OUT" "check stack=fixable:" "--only keeps the named check"
assert_contains "$OUT" "check tools=human:" "--only keeps the second named check"
assert_not_contains "$OUT" "backlog-lock" "--only drops the others"
assert_not_contains "$OUT" "squad-lead" "--only drops the Squad Lead check"
pass "--only limits the run to the named checks"

# ---------------------------------------------------------------- 4: --fix with another live session holding the lock
foreign_lock "$H"
triage "$H" --offline --fix
expect_code 1 "$RC" "a refused repair leaves findings"
assert_contains "$OUT" "FAILED gate" "the refusal is shown"
assert_contains "$OUT" "another live session" "the refusal names the reason"
[ -z "$(calls "$H")" ] || fail "a repair ran while another session held the lock: $(calls "$H")"
[ -e "$H/stack.down" ] || fail "the stack was changed under a foreign lock"
pass "--fix changes nothing while another live session holds the home lock"

# ---------------------------------------------------------------- 5: --fix repairs and shows the state after
free_lock "$H"
triage "$H" --offline --fix
expect_code 1 "$RC" "human findings keep exit 1 after a clean repair"
assert_contains "$OUT" "mode fix" "fix mode is named"
assert_contains "$OUT" "APPLIED stack" "stack repair applied"
assert_contains "$OUT" "APPLIED backlog-lock" "lock repair applied"
assert_contains "$OUT" "APPLIED squad-lead:lead1" "Squad Lead relaunched"
assert_contains "$OUT" "APPLIED tmp" "tmp swept"
assert_contains "$OUT" "ok     stack" "the check shows the state after repair"
assert_contains "$OUT" "ok     squad-lead:lead1" "the lead is ok after repair"
assert_not_contains "$OUT" "FIX    " "no fixable finding remains"
assert_contains "$OUT" "0 fixable, 2 need you, 0 unreadable." "only the person's findings remain"
assert_contains "$(calls "$H")" "up" "jg-stack.sh up ran"
assert_contains "$(calls "$H")" "reclaim" "the reclaim script ran"
assert_contains "$(calls "$H")" "relaunch lead1" "the guarded relaunch ran for the dead lead"
assert_contains "$(calls "$H")" "sweep" "the guarded sweep ran"
case "$(calls "$H")" in *"relaunch lead2"*) fail "a live lead was relaunched" ;; esac
case "$(calls "$H")" in *stray*) fail "the stray reaper was called with an argument" ;; esac
assert_absent "$H/data/backlog.md.lock" "the stale lock is gone"
triage "$H" --offline --fix --porcelain
assert_not_contains "$OUT" "fix " "a second --fix has nothing to repair"
expect_code 1 "$RC" "second run still has the person's findings"
pass "--fix repairs through the guarded scripts, shows the state after, and is idempotent"

# ---------------------------------------------------------------- 6: a repair that does not work is reported, not hidden
H=$(make_home stuck)
touch "$H/stack.down" "$H/stack.stuck"
add_lead "$H" lead1 relaunchable
touch "$H/state/sl-lead1.refuse"
triage "$H" --offline --fix --porcelain
expect_code 1 "$RC" "failed repairs exit 1"
assert_contains "$OUT" "fix stack=failed:" "a stack repair that fails says so"
assert_contains "$OUT" "fix squad-lead:lead1=failed: relaunch refused: the pane is busy" "a refused relaunch says why"
assert_contains "$OUT" "check stack=human:" "a failed repair becomes a person's finding"
assert_contains "$OUT" "--fix did not clear it" "the finding says --fix did not clear it"
assert_contains "$OUT" "summary fixable=0 human=2 unknown=0" "no fixable finding is left to retry blindly"
pass "a failed repair is reported with its reason and left for a person"

# ---------------------------------------------------------------- 7: Squad Lead guards
H=$(make_home leads)
add_lead "$H" bound relaunchable
touch "$H/state/.squad-lead-relaunch-bound-bound"
add_lead "$H" gone silent
add_lead "$H" odd weird
triage "$H" --offline --fix --porcelain
assert_contains "$OUT" "check squad-lead:bound=human:" "a paused auto-relaunch is for a person"
assert_contains "$OUT" "check squad-lead:gone=human:" "a lead with no endpoint is a provisioning gap"
assert_contains "$OUT" "check squad-lead:odd=unknown:" "an unrecognised probe result is unknown"
assert_contains "$OUT" "not treated as dead" "unknown is never read as dead"
[ -z "$(calls "$H")" ] || fail "an ambiguous or bound lead was relaunched: $(calls "$H")"
expect_code 2 "$RC" "an unreadable check exits 2"
pass "paused, missing and ambiguous Squad Leads are never relaunched"

# ---------------------------------------------------------------- 8: unreadable sources are unknown
H=$(make_home unreadable)
echo 'not json' > "$H/ready.json"
touch "$H/bootstrap.fail"
triage "$H" --offline
expect_code 2 "$RC" "unreadable sources exit 2"
assert_contains "$OUT" "??     session-lock" "an unreadable lock state is unknown"
assert_contains "$OUT" "not treated as dead" "the lock is not read as dead"
assert_contains "$OUT" "??     sentinel" "an unfinished detect run is unknown"
triage "$H" --offline --fix
assert_contains "$OUT" "the home lock could not be read" "--fix refuses when the lock cannot be read"
[ -z "$(calls "$H")" ] || fail "a repair ran with an unreadable lock: $(calls "$H")"
pass "an unreadable state is unknown, exits 2, and blocks every repair"

# ---------------------------------------------------------------- 9: a stale lock does not block a repair
H=$(make_home stale)
touch "$H/stack.down"
set_ready "$H" stale false down
triage "$H" --offline --fix --only stack
assert_contains "$OUT" "APPLIED stack" "a stale lock (dead holder) allows a repair"
assert_contains "$OUT" "ok     stack" "the stack is up again"
expect_code 0 "$RC" "a fully repaired home exits 0"
pass "a dead lock holder does not block repair; fully repaired exits 0"

# ---------------------------------------------------------------- 10: young lock, owned lock file
H=$(make_home youth)
: > "$H/data/backlog.md.lock"
triage "$H" --offline --only backlog-lock
assert_contains "$OUT" "ok     backlog-lock" "a fresh 0-byte lock may still be starting"
printf 'owner-token\n' > "$H/data/backlog.md.lock"
age_file "$H/data/backlog.md.lock"
triage "$H" --offline --only backlog-lock
assert_contains "$OUT" "ok     backlog-lock" "a lock with an owner token is held, not stale"
pass "only an old 0-byte backlog lock is a finding"

# ---------------------------------------------------------------- 11: login
H=$(make_home login)
FB="$TMP_ROOT/fakebin-gh"
mkdir -p "$FB"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/gh"
chmod +x "$FB/gh"
OUT=$(PATH="$FB:$PATH" JG_HOME="$H" "$H/bin/jg-triage.sh" --only login 2>&1)
RC=$?
expect_code 1 "$RC" "a signed-out gh is a finding"
assert_contains "$OUT" "HUMAN  login" "a signed-out gh is for a person"
assert_contains "$OUT" "run: gh auth login" "the login command is printed, never run"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/gh"
OUT=$(PATH="$FB:$PATH" JG_HOME="$H" "$H/bin/jg-triage.sh" --only login 2>&1)
assert_contains "$OUT" "ok     login" "a signed-in gh is ok"
pass "the login check prints the command and signs nothing in"

# ---------------------------------------------------------------- 12: usage errors
for args in "--nope" "--only" "--only bogus" "--context"; do
  # shellcheck disable=SC2086
  OUT=$(JG_HOME="$H" "$H/bin/jg-triage.sh" $args 2>&1)
  RC=$?
  expect_code 2 "$RC" "bad usage '$args' exits 2"
done
OUT=$(env -u JG_HOME "$H/bin/jg-triage.sh" 2>&1)
RC=$?
expect_code 2 "$RC" "no JG_HOME exits 2"
assert_contains "$OUT" "JG_HOME must be set" "the missing home is named"
OUT=$(JG_HOME="$H" "$H/bin/jg-triage.sh" --help 2>&1)
RC=$?
expect_code 0 "$RC" "--help exits 0"
assert_contains "$OUT" "Default is CHECK ONLY" "--help prints the header"
pass "a missing home, a bad flag and an unknown check exit 2; --help works"

# ---------------------------------------------------------------- 13: --context redacts and is private
H=$(make_home context)
SECRET="ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd"
printf 'MISSING: tool token=hunter2 %s in %s (install: brew install tool)\n' "$SECRET" "$HOME/private/dir" > "$H/bootstrap.out"
CTX="$TMP_ROOT/facts.md"
triage "$H" --offline --context "$CTX"
assert_present "$CTX" "the facts file is written"
mode=$(stat -c %a "$CTX" 2>/dev/null || stat -f %Lp "$CTX")
assert_equals 600 "$mode" "the facts file is private"
facts=$(cat "$CTX")
assert_contains "$facts" "# jg-triage facts" "the facts file has a title"
assert_contains "$facts" "tools: human" "the facts file carries the findings"
assert_not_contains "$facts" "hunter2" "a token value is redacted"
assert_not_contains "$facts" "$SECRET" "a long credential-shaped string is redacted"
assert_not_contains "$facts" "$HOME/private" "the user's home path is redacted"
assert_contains "$facts" "<redacted>" "the redaction is visible"
ln -s "$CTX" "$TMP_ROOT/link.md"
OUT=$(JG_HOME="$H" "$H/bin/jg-triage.sh" --offline --context "$TMP_ROOT/link.md" 2>&1)
RC=$?
expect_code 2 "$RC" "a symlink target is refused"
pass "--context writes a private, redacted facts file and refuses a link"

# ---------------------------------------------------------------- 14: --agent
H=$(make_home agent)
AB="$TMP_ROOT/agentbin"
mkdir -p "$AB"
cat > "$AB/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP_ROOT/agent.args"
for f in \$1 \$(printf '%s' "\$1" | grep -o '/[^ ]*\\.md'); do [ -r "\$f" ] && cat "\$f" >> "$TMP_ROOT/agent.docs"; done
exit 0
STUB
chmod +x "$AB/claude"
# nothing left to triage: no agent
OUT=$(PATH="$AB:$PATH" JG_HOME="$H" "$H/bin/jg-triage.sh" --offline --agent 2>&1)
RC=$?
expect_code 0 "$RC" "a healthy home with --agent exits 0"
assert_contains "$OUT" "no agent was started" "no agent starts when nothing is left"
assert_absent "$TMP_ROOT/agent.args" "the agent did not run"
# a finding only a person can settle: the agent starts with the facts and the playbook
printf 'MISSING: tool (install: brew install tool)\n' > "$H/bootstrap.out"
PATH="$AB:$PATH" JG_HOME="$H" "$H/bin/jg-triage.sh" --offline --agent >"$TMP_ROOT/agent.out" 2>&1
assert_present "$TMP_ROOT/agent.args" "the agent ran"
prompt=$(cat "$TMP_ROOT/agent.args")
assert_contains "$prompt" "facts.md" "the prompt names the facts file"
assert_contains "$prompt" "playbook.md" "the prompt names the playbook"
assert_contains "$(cat "$TMP_ROOT/agent.docs")" "Ask before every fix" "the playbook asks before each fix"
assert_contains "$(cat "$TMP_ROOT/agent.docs")" "Never read a secret" "the playbook forbids reading secrets"
assert_contains "$(cat "$TMP_ROOT/agent.docs")" "tools: human" "the facts reach the agent"
# an unsupported harness is refused, not guessed
echo pi > "$H/harness.txt"
OUT=$(PATH="$AB:$PATH" JG_HOME="$H" "$H/bin/jg-triage.sh" --offline --agent 2>&1)
RC=$?
expect_code 2 "$RC" "an unsupported harness exits 2"
assert_contains "$OUT" "supports the claude and codex harnesses" "the unsupported harness is named"
pass "--agent starts the home's harness on what is left, with the playbook, and nothing otherwise"

jg_test_cleanup 2>/dev/null || true
echo "jg-triage: all passed"
