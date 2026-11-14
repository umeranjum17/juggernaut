#!/usr/bin/env bash
# bin/jg-contract-carrier.sh through its real callers: the script itself, and bin/jg-session-start.sh run
# in a fixture home under a fake harness. `check` names one proof for each of the nine verified primary
# harnesses; `ensure` writes the carrier file with its one import line and then `check` reads `file`;
# the digest holds the contract at the start and in the re-emit after a compaction when the proof is not
# `file`, for harness `unknown`, and when `ensure` wrote the file just now; a home above a worker copy gets
# no file; and once AGENTS.md is the core file no verified primary may read `none`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-contract-carrier)
CARRIER="$ROOT/bin/jg-contract-carrier.sh"
SESSION_START="$ROOT/bin/jg-session-start.sh"
NINE="claude pi pi-signed omp codex cursor opencode grok kimi"
MARK='CONTRACT-FIXTURE-SENTENCE-7f3a'

# A fixture home: its own root, state, data and config, a git repository, and an AGENTS.md holding MARK.
home() {  # <name>
  local h=$TMP_ROOT/$1
  mkdir -p "$h/state" "$h/data" "$h/config" "$h/fakebin"
  git init -q -b main "$h"
  printf '# Juggernaut\n%s\n' "$MARK" > "$h/AGENTS.md"
  cat > "$h/fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=; prev=
for a in "$@"; do [ "$prev" = -p ] && pid=$a; prev=$a; done
case "$*" in
  *-eo*) exec /bin/ps "$@" ;;
  *comm=*) if [ "$pid" = "${JG_FAKE_HARNESS_PID:-}" ]; then printf '/usr/local/bin/%s\n' "${JG_FAKE_HARNESS:-claude}"; else printf '/bin/bash\n'; fi; exit 0 ;;
  *args=*) if [ "$pid" = "${JG_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' "${JG_FAKE_HARNESS:-claude}"; else printf 'bash\n'; fi; exit 0 ;;
  *ppid=*) /bin/ps -o ppid= -p "$pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$h/fakebin/ps"
  echo "$h"
}
carrier() {  # <home> <args>...: the carrier as a home's session start calls it
  local h=$1; shift
  JG_HOME="$h" JG_ROOT_OVERRIDE="$h" "$CARRIER" "$@"
}
# The stage file stands in for the runtime bound's child, which sits too deep under the test shell for the
# fake harness process to be found by its ancestry walk.
start() {  # <home> <harness> <session-start args>...: the real session start under a fake harness
  local h=$1 harness=$2; shift 2
  env -u CLAUDECODE -u PI_CODING_AGENT -u JG_PI_HARNESS -u GROK_AGENT \
    JG_FAKE_HARNESS="$harness" JG_FAKE_HARNESS_PID=$$ JG_HOME="$h" JG_ROOT_OVERRIDE="$h" \
    JG_SESSION_START_STAGE_FILE=/dev/null \
    PATH="$h/fakebin:/usr/bin:/bin" "$SESSION_START" "$@" 2>&1
}

test_check_names_one_proof_for_each_verified_primary() {
  local h proof harness
  h=$(home table)
  for harness in $NINE; do
    proof=$(carrier "$h" check "$harness")
    case "$proof" in file | reemit | none) ;; *) fail "check $harness printed '$proof'" ;; esac
  done
  assert_equals none "$(carrier "$h" check codex)" "codex has no tracked channel after a compaction"
  assert_equals none "$(carrier "$h" check cursor)" "cursor has no tracked channel after a compaction"
  for harness in claude pi pi-signed omp; do
    assert_equals reemit "$(carrier "$h" check "$harness")" "$harness re-runs session start after a compaction"
  done
  assert_equals none "$(carrier "$h" check unknown)" "a harness outside the table reads none"
  pass "check prints file, reemit or none for each of the nine verified primaries"
}

test_ensure_writes_the_one_import_line_and_check_reads_file() {
  local h out code
  h=$(home ensure)
  out=$(carrier "$h" ensure claude); code=$?
  assert_equals 3 "$code" "ensure exits 3 when it had to write"
  assert_contains "$out" "wrote CLAUDE.local.md" "ensure prints one line when it wrote"
  assert_equals "@AGENTS.md" "$(cat "$h/CLAUDE.local.md")" "the file holds the contract's one import line and nothing else"
  assert_equals file "$(carrier "$h" check claude)" "check reads file once the carrier file holds the line"
  out=$(carrier "$h" ensure claude); code=$?
  assert_equals 0 "$code" "a second ensure has nothing to write"
  assert_equals "" "$out" "a second ensure prints nothing"
  assert_equals 1 "$(wc -l < "$h/CLAUDE.local.md" | tr -d ' ')" "the line is not added twice"
  assert_equals "$h/CLAUDE.local.md" "$(carrier "$h" path claude)" "path names the carrier file in the home root"
  pass "ensure writes the file with its one import line, then check passes"
}

test_ensure_keeps_text_the_owner_wrote_in_the_file() {
  local h
  h=$(home keep)
  printf 'my own note\n' > "$h/CLAUDE.local.md"
  carrier "$h" ensure claude >/dev/null
  assert_equals "my own note
@AGENTS.md" "$(cat "$h/CLAUDE.local.md")" "ensure appends the line and keeps the owner's text"
  pass "ensure never rewrites text it did not write"
}

test_ensure_writes_nothing_for_unknown_harness_and_for_a_worker_copy() {
  local h w out
  h=$(home unknown)
  out=$(carrier "$h" ensure unknown) || fail "ensure unknown must not fail the start"
  assert_contains "$out" "not in the table" "ensure says why it wrote nothing for harness unknown"
  assert_absent "$h/CLAUDE.local.md" "harness unknown gets no carrier file"
  # The code root is a worker copy; the home root is elsewhere.
  w=$(home workercopy)
  out=$(JG_HOME="$h" JG_ROOT_OVERRIDE="$w" "$CARRIER" ensure claude) || fail "ensure above a worker copy must not fail the start"
  assert_contains "$out" "worker copy" "ensure says why it wrote nothing above a worker copy"
  assert_absent "$h/CLAUDE.local.md" "a home above a worker copy gets no carrier file"
  assert_absent "$w/CLAUDE.local.md" "a worker copy gets no carrier file"
  pass "ensure writes nothing and says why for harness unknown and above a worker copy"
}

test_digest_holds_the_contract_when_the_proof_is_not_file() {
  local h out
  h=$(home unk-digest)
  out=$(start "$h" unknown --source startup)
  assert_contains "$out" "SUPERVISOR CONTRACT - AGENTS.md" "the digest of harness unknown has the contract section"
  assert_contains "$out" "carrier proof: none" "the digest of harness unknown reads its proof as none"
  assert_contains "$out" "$MARK" "the digest of harness unknown holds the contract text"
  assert_absent "$h/CLAUDE.local.md" "session start wrote no carrier file for harness unknown"

  h=$(home pi-digest)
  start "$h" pi --source startup >/dev/null
  out=$(start "$h" pi --reemit --source compact)
  assert_contains "$out" "carrier proof: reemit" "the pi re-emit reads its proof as reemit"
  assert_contains "$out" "$MARK" "the re-emit after a pi compaction holds the contract"

  h=$(home codex-digest)
  out=$(start "$h" codex --source startup)
  assert_contains "$out" "carrier proof: none" "the codex digest reads its proof as none"
  assert_contains "$out" "$MARK" "a harness whose row is none gets the contract in the digest"
  pass "the digest holds the contract at the start and after a compaction when the proof is not file"
}

test_claude_gets_its_contract_from_the_file_after_the_first_start() {
  local h out
  h=$(home claude-digest)
  out=$(start "$h" claude --source startup)
  assert_contains "$out" "wrote CLAUDE.local.md" "the first start writes the carrier file and says so"
  assert_contains "$out" "$MARK" "the first start still holds the contract: this session did not load the file"
  assert_equals file "$(carrier "$h" check claude)" "the carrier file stands after the start"
  out=$(start "$h" claude --reemit --source compact)
  assert_not_contains "$out" "$MARK" "with a file row the digest after a compaction no longer repeats the contract"
  assert_not_contains "$out" "SUPERVISOR CONTRACT" "no contract section when the harness loads the file by itself"
  pass "a claude home holds the contract in its file and the digest stops repeating it"
}

test_once_agents_md_is_the_core_file_no_verified_primary_reads_none() {
  local harness core=0 none=''
  [ -f "$ROOT/docs/contract/supervisor.md" ] && core=1
  for harness in $NINE; do
    [ "$(JG_HOME="$ROOT" JG_ROOT_OVERRIDE="$ROOT" "$CARRIER" check "$harness")" != none ] || none="$none $harness"
  done
  if [ "$core" -eq 1 ] && [ -n "$none" ]; then
    fail "AGENTS.md is the core file and these verified primaries read none:$none"
  fi
  # The same rule on a fixture whose contract has moved: the import names the moved file.
  local h
  h=$(home moved)
  mkdir -p "$h/docs/contract"
  printf 'moved contract\n' > "$h/docs/contract/supervisor.md"
  assert_equals docs/contract/supervisor.md "$(carrier "$h" contract)" "the contract is the file the core file points at once it exists"
  carrier "$h" ensure claude >/dev/null
  assert_equals "@docs/contract/supervisor.md" "$(cat "$h/CLAUDE.local.md")" "the import line follows the contract file"
  pass "no verified primary reads none once AGENTS.md is the core file (core now: $core; reading none:${none:- no harness})"
}

test_check_names_one_proof_for_each_verified_primary
test_ensure_writes_the_one_import_line_and_check_reads_file
test_ensure_keeps_text_the_owner_wrote_in_the_file
test_ensure_writes_nothing_for_unknown_harness_and_for_a_worker_copy
test_digest_holds_the_contract_when_the_proof_is_not_file
test_claude_gets_its_contract_from_the_file_after_the_first_start
test_once_agents_md_is_the_core_file_no_verified_primary_reads_none

echo "# jg-contract-carrier.test.sh: all assertions passed"
