#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh release: the release keeps one pull-request URL and takes an open release
# pull request as success (report fable-why-no-landing, row 24, slice S14). Before the fix the release stored the whole
# answer of the create call as the URL, so the next run did not see the open pull request, called create again after
# the push and ended with "the release PR was not opened".
#
# T1 The ledger holds this home's nine lines of 10:15:05Z as they are and pull request 813 is open: the release makes no
#    create call, prints one URL, moves the released mark and writes a row of one line.
# T2 No pull request is open and the create call fails: the error of today stays and nothing is recorded.
# T3 The create call fails and one pull request from the trunk into the default branch is open: that one is the release.
# T4 The create call answers in full (number, url, help): the row holds the one URL.
# T5 Two open pull requests go from the trunk into the default branch: the release stops and prints both.
# T6 The release PR has an owning task (report fable-why-no-landing, row fric-release-task-record): the release writes
#    state/release-<project>-<trunk>.meta (kind=release, no worker, yolo=off) and records the PR through the real
#    bin/jg-pr-check.sh, whose version-branch guard admits the trunk as the release head although the project still
#    carries release/c-16; a pull request from any other head into main is still refused. Before the fix the release
#    recorded no task ("task metadata is unavailable") and the guard refused the trunk head.
# T7 A release already pushed whose record is missing (the record was cleaned up, report fable-goal-triage S3c): the
#    release writes the record (kind=release, its pull-request line, no receipt line), arms the check, pushes nothing,
#    prints one line and exits 0; a record of another kind under the id is refused with one line naming it; a record
#    already kind=release is left as it is and nothing is pushed.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/umeranjum17/juggernaut/pull
LEDGER=; MARK=

# A world whose project is named juggernaut, so the ledger holds the home's row byte for byte, and a gh-axi stand-in:
# a pull request's state is the file state-<n> (closed when absent), the open list is the file open-prs, and the create
# call fails unless create-ok exists, when it answers as gh-axi does.
release_world() {  # [<name>]
  world "${1:-rel}"
  PROJ="$HOME_D/projects/juggernaut"; LEDGER="$HOME_D/data/trunk-releases.tsv"; MARK="$HOME_D/state/trunk-released-juggernaut"
  printf -- '- juggernaut [local-trunk] - fixture named like the real project (added 2026-11-10)\n' >> "$HOME_D/data/projects.md"
  jg_git_init_commit "$PROJ"; jg_git_add_origin "$PROJ" "$W/origin-j.git"
  trunk init "$PROJ" >/dev/null || fail "trunk init must work"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'pull_request:\n  number: %s\n  state: %s\n' "\$3" "\$(cat "$W/state-\$3" 2>/dev/null || echo closed)" ;;
  list) cat "$W/open-prs" 2>/dev/null || printf 'count: 0\npull_requests: []\n' ;;
  create) [ -e "$W/create-ok" ] || { echo 'error: a pull request for branch "trunk" into branch "main" already exists'; exit 1; }
    printf 'created:\n  number: 815\n  url: "%s/815"\n  base: main\n  head: trunk\nhelp[2]:\n  Run \`gh-axi pr view 815 -R umeranjum17/juggernaut\` to see the full PR\n' "$U" ;;
esac
SH
  # A gh stand-in for the PR check the release runs: not a draft, base main, head the file gh-head (the trunk when absent)
  # at the trunk's commit, no open pull request on an older release branch, and every status write accepted.
  cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-real-calls"
case "\$1 \$2 \$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) git -C "$PROJ" rev-parse trunk ;;
  'pr view '*baseRefName*) printf 'main\t%s\n' "\$(cat "$W/gh-head" 2>/dev/null || echo trunk)" ;;
  'pr list '*) ;;
  'api '*) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$W/fakebin/gh"
  { printf 'juggernaut\ttrunk\tb96c903b\t1\t1794110341\t%s/810\n' "$U"
    printf 'juggernaut\ttrunk-v3\t9e050a451a9cfb8511735d603a15c3f722853c07\t59\t1794219305\tcreated:\n'
    cat <<ROW
  number: 813
  url: "$U/813"
  base: main
  head: trunk-v3
help[2]:
  Run \`gh-axi pr view 813 -R umeranjum17/juggernaut\` to see the full PR
  Run \`gh-axi pr checks 813 -R umeranjum17/juggernaut\` to monitor CI
ROW
  } > "$LEDGER"
  [ "$(wc -l < "$LEDGER")" = 9 ] || fail "fixture: the ledger must hold the nine lines"
}

batch() {  # <id>: one landed, fully green commit on the trunk and the captain's word to release it
  lane "$1" "$1"; trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"
  trunk word release "$PROJ" "ship $1" >/dev/null 2>&1 || fail "the captain's word must record"
}
open_prs() {  # <n>...: the open pull requests from the trunk into main, as gh-axi lists them
  printf 'count: %s\npull_requests[%s]{number,title,state,author,draft,review,url}:\n' "$#" "$#"
  for n; do printf '  %s,"Release: 1 tickets from the local trunk",open,umeranjum17,no,none,"%s/%s"\n' "$n" "$U" "$n"; done
}
creates() { grep -c 'pr create' "$W/gh-calls" 2>/dev/null || true; }
one_url_row() {  # <url> <what>: the ledger grew by exactly one line, a row of six fields whose URL is <url>
  [ "$(wc -l < "$LEDGER")" = "$((rows + 1))" ] || fail "$2 must write a row of one line"
  [ "$(tail -1 "$LEDGER" | awk -F'\t' '{ print NF "|" $1 "|" $3 "|" $6 }')" = "6|juggernaut|$(tip)|$1" ] || fail "$2 must write a row of six fields with the one URL: $(tail -1 "$LEDGER")"
}

test_a_release_keeps_one_url_and_takes_the_open_release_pr_as_success() {
  local out rows
  release_world
  batch j1; echo open > "$W/state-813"; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) || fail "T1: the open release PR 813 must be success: $out"
  [ "$(creates)" = 0 ] || fail "T1: a release while 813 is open must make no create call"
  [ "$(grep -o 'https://' <<<"$out" | wc -l)" = 1 ] || fail "T1: the release must print one URL: $out"
  assert_contains "$out" "$U/813" "T1: the URL must be that of 813"
  [ "$(cat "$MARK")" = "$(tip)" ] || fail "T1: the released mark must move to the tip"
  one_url_row "$U/813" T1
  pass 'T1 with this home'"'"'s nine ledger lines and 813 open, the release exits 0 with no create call, one URL, a moved mark and a one-line row'

  echo closed > "$W/state-813"; batch j2; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) && fail "T2: no open PR and a failed create call must fail: $out"
  assert_contains "$out" 'the release PR was not opened; run release again' "T2: the error of today must stay"
  assert_contains "$out" 'already exists' "T2: the create call's own answer must show"
  [ "$(cat "$MARK")" != "$(tip)" ] && [ "$(wc -l < "$LEDGER")" = "$rows" ] || fail "T2: a failed release must record nothing"
  pass 'T2 with no open PR and a failed create call, the error of today stays and nothing is recorded'

  open_prs 814 > "$W/open-prs"
  out=$(trunk release "$PROJ" 2>&1) || fail "T3: the one open PR from the trunk must be success: $out"
  assert_contains "$(cat "$W/gh-calls")" 'pr list --state open --head trunk --base main' "T3: the look-up must ask for the trunk into main"
  [ "$(cat "$MARK")" = "$(tip)" ] || fail "T3: the released mark must move"
  one_url_row "$U/814" T3
  pass 'T3 a failed create call takes the one open PR from the trunk into main as the release'

  rm "$W/open-prs"; : > "$W/create-ok"; batch j3; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) || fail "T4: a create call that answers must release: $out"
  [ "$(grep -o 'https://' <<<"$out" | wc -l)" = 1 ] || fail "T4: the release must print one URL: $out"
  one_url_row "$U/815" T4
  pass 'T4 a create call that answers in full stores only its one URL in a one-line row'

  rm "$W/create-ok"; open_prs 816 817 > "$W/open-prs"; batch j4; rows=$(wc -l < "$LEDGER")
  out=$(trunk release "$PROJ" 2>&1) && fail "T5: two open PRs from the trunk must stop the release: $out"
  assert_contains "$out" "$U/816" "T5: the release must print the first open PR"
  assert_contains "$out" "$U/817" "T5: the release must print the second open PR"
  [ "$(cat "$MARK")" != "$(tip)" ] && [ "$(wc -l < "$LEDGER")" = "$rows" ] || fail "T5: a stopped release must record nothing"
  pass 'T5 two open PRs from the trunk into main stop the release, both printed, nothing recorded'
}

test_the_release_pr_has_an_owning_task_the_guard_admits() {
  local out meta rc=0
  release_world rel-task; git -C "$PROJ" branch release/c-16; meta="$HOME_D/state/release-juggernaut-trunk.meta"
  batch j1; echo open > "$W/state-813"
  out=$(trunk release "$PROJ" 2>&1) || fail "T6: the release with its task record must succeed: $out"
  assert_not_contains "$out" "targets the default branch" "T6: the guard must admit the trunk as the release head"
  assert_contains "$out" "release task: release-juggernaut-trunk owns the release PR" "T6: the release must name its task"
  [ -f "$meta" ] || fail "T6: the release must write its task record"
  for row in kind=release "project=$(cd "$PROJ" && pwd -P)" mode=local-trunk yolo=off "pr=$U/813"; do
    grep -qxF -- "$row" "$meta" || fail "T6: the task record must hold $row: $(cat "$meta")"
  done
  ! grep -qE '^(window|worktree|branch)=' "$meta" || fail "T6: no worker owns the release, so the record names no window, worktree or branch: $(cat "$meta")"
  [ -e "$HOME_D/state/release-juggernaut-trunk.check.sh" ] || fail "T6: the release PR must be armed for the merge watch"
  echo fm/feature-x > "$W/gh-head"
  out=$(PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" \
    JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-pr-check.sh" release-juggernaut-trunk "$U/900" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T6: a pull request from another head into main must still be refused: $out"
  assert_contains "$out" "current version branch is release/c-16" "T6: the refusal must name the version branch"
  grep -qxF "pr=$U/813" "$meta" || fail "T6: a refused pull request must leave the record as it was: $(cat "$meta")"
  pass 'T6 the release records its own task, the guard admits the trunk head into main, and any other head is refused'
}

test_a_pushed_release_without_its_record_gets_the_record_and_no_second_push() {
  local out meta rows sum
  release_world rel-pushed; meta="$HOME_D/state/release-juggernaut-trunk.meta"
  batch j1; echo open > "$W/state-813"
  trunk release "$PROJ" >/dev/null 2>&1 || fail "T7: the first release must succeed"
  rm -f "$meta" "$HOME_D/state/release-juggernaut-trunk.check.sh"; rows=$(wc -l < "$LEDGER")
  git -C "$PROJ" config remote.origin.pushurl "$W/no-such-remote.git"  # any push now fails, so a success pushed nothing
  out=$(trunk release "$PROJ" 2>/dev/null) || fail "T7a: a pushed release with no record must write it and exit 0"
  [ "$(wc -l <<<"$out")" = 1 ] || fail "T7a: the release must say so in one line: $out"
  assert_contains "$out" "already pushed" "T7a: the line must say the release was already pushed"
  for row in kind=release "project=$(cd "$PROJ" && pwd -P)" mode=local-trunk yolo=off "pr=$U/813"; do
    grep -qxF -- "$row" "$meta" || fail "T7a: the record must hold $row: $(cat "$meta")"
  done
  ! grep -q '^receipt_required' "$meta" || fail "T7a: a release record asks for no receipt: $(cat "$meta")"
  [ -e "$HOME_D/state/release-juggernaut-trunk.check.sh" ] || fail "T7a: the release PR must be armed"
  [ "$(wc -l < "$LEDGER")" = "$rows" ] || fail "T7a: no new release row"
  pass 'T7a a pushed release with its record missing gets the record and the armed check, with no push and one line'

  sum=$(cksum < "$meta"); out=$(trunk release "$PROJ" 2>&1) || fail "T7c: the existing release must resume proof: $out"
  [ "$(cksum < "$meta")" = "$sum" ] && [ "$(wc -l < "$LEDGER")" = "$rows" ] || fail "T7c: the record and the ledger must stay as they were"
  assert_contains "$out" "resuming its proof" "T7c: the retry must say why it ran"
  assert_not_contains "$out" "push of" "T7c: no push is tried"
  pass 'T7c an existing release resumes proof without another push'

  printf 'kind=ship\nproject=x\nreceipt_required=1\n' > "$meta"; sum=$(cksum < "$meta")
  out=$(trunk release "$PROJ" 2>&1) && fail "T7b: a record of another kind must refuse: $out"
  assert_contains "$out" "kind=ship" "T7b: the refusal must name the kind"
  [ "$(wc -l <<<"$out")" = 1 ] && [ "$(cksum < "$meta")" = "$sum" ] || fail "T7b: one line and the record untouched: $out"
  pass 'T7b a record of another kind under the id is refused in one line naming it'
}

test_release_proof_at_its_head() {
world release-proof
cp "$ROOT/bin/jg-trunk-release-proof.sh" "$W/root/bin/jg-trunk-release-proof.sh"
export DONE_DONE_HOME="$W/done-done"
mkdir -p "$DONE_DONE_HOME" "$W/account"
printf '%s\n' "$W/account" > "$HOME_D/config/claude-account"
export JG_PROOF_BOARD="$W/board.json"
url=https://github.com/o/r/pull/9
id=release-proj-trunk
# Use an independent clone for the lane, not a worktree of the shared repository.
git clone -q "$PROJ" "$W/lane" || fail 'clone lane'
git -C "$W/lane" checkout -q -b fm/proof origin/trunk || fail 'create lane branch'
commit_in "$W/lane" work.txt proof 'ticket proof'
git -C "$PROJ" fetch -q "$W/lane" fm/proof:refs/heads/fm/proof || fail 'import lane'
jg_write_meta "$HOME_D/state/proof.meta" "project=$PROJ" 'mode=local-trunk' 'branch=fm/proof' "worktree=$W/lane" 'spawn_gen=g-proof'
prove proof; ready proof
trunk land proof >/dev/null 2>&1 || fail 'fixture lane must land'
trunk word release "$PROJ" 'release fixture' >/dev/null || fail 'record release word'
cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"api PATCH"*) for arg in "\$@"; do case "\$arg" in body=*) printf '%s' "\${arg#body=}" > "$W/pr-body" ;; esac; done ;;
  *".head.sha"*) git -C "$PROJ" rev-parse trunk ;;
  *".body"*) cat "$W/pr-body" 2>/dev/null || true ;;
  *"pr view"*) echo 'state: open' ;;
  *) echo '$url' ;;
esac
SH
chmod +x "$W/fakebin/gh-axi"
cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *author,body,title,files,headRefOid*) jq -n --rawfile body "$W/pr-body" --arg head "\$(git -C "$PROJ" rev-parse trunk)" '{body:\$body,title:"Fixture release",headRefOid:\$head,headRefName:"trunk",files:[],author:{login:"fixture"}}' ;;
  *isDraft*) echo '{"isDraft":false}' ;;
  *headRefOid*) git -C "$PROJ" rev-parse trunk ;;
  *baseRefName*) printf 'main\ttrunk\n' ;;
  *'pr create'*) echo '$url' ;;
  *'--jq .body'*) cat "$W/pr-body" 2>/dev/null || printf '## Checks\nscreen: none\n' ;;
  *'pr view'*) echo '{"body":"","headRefName":"trunk"}' ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$W/fakebin/gh"
# The run and judge boundaries are deterministic; the capture command and proof gates are real.
cat > "$W/fakebin/done-done" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = run ]; then
  shift
  [ "${1:-}" != --json ] || shift
  [ "${1:-}" = -- ] && shift
  head=$(git rev-parse HEAD)
  run="20261110T000000Z-${head:0:8}-ab"
  root="$DONE_DONE_HOME/evidence"
  mkdir -p "$root/$run" "$root/.done-done/runs"
  if [ -e "$JG_TEST_CHANGE_PIN" ]; then
    original=$(cat "$JG_STATE_OVERRIDE/trunk-green-proj")
    git -C "$JG_RELEASE_PROJECT" rev-parse trunk^ > "$JG_STATE_OVERRIDE/trunk-green-proj"
  fi
  rc=0
  DONE_DONE_EVIDENCE_ROOT="$root/$run" "$@" || rc=$?
  if [ -n "${original:-}" ]; then printf '%s\n' "$original" > "$JG_STATE_OVERRIDE/trunk-green-proj"; fi
  [ "$rc" -eq 0 ] || exit "$rc"
  record="$root/.done-done/runs/$run.json"
  hash=$(sha256sum "$root/$run/run.log" | cut -d' ' -f1)
  bytes=$(wc -c < "$root/$run/run.log")
  tree=$(git rev-parse HEAD^{tree})
  jq -n --arg id "$run" --arg head "$head" --arg tree "$tree" --arg hash "$hash" --argjson bytes "$bytes" \
    --slurpfile steps "$root/$run/steps.json" \
    '{schema:1,run_id:$id,journey:null,command:"bash release-proof capture",commit:$head,tree:$tree,dirty:false,started_at:"2026-11-10T00:00:00Z",ended_at:"2026-11-10T00:00:01Z",exit:0,files:[{path:($id + "/run.log"),sha256:$hash,bytes:$bytes}],tool:"0.6.26",steps:$steps[0]}' > "$record"
  jq -n --arg id "$run" --arg head "$head" --arg record "$record" '{run_id:$id,commit:$head,dirty:false,record:$record}'
elif [ "${1:-}" = check ] && [ "${2:-}" != --help ]; then
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-}" > "$JG_TEST_JUDGE_ACCOUNT"
  name=$(sed -n 's/^evidence: //p' "$JG_TEST_PR_BODY" | tail -n 1)
  jq -n --arg file "$JG_DATA_OVERRIDE/release-proj-trunk/$name" --arg claim 'release proof' '{result:"pass",claim:$claim,evidence:[$file]}'
else
  printf 'unexpected done-done command: %s\n' "$*" >&2
  exit 1
fi
SH
export JG_TEST_CHANGE_PIN="$W/change-pin" JG_TEST_JUDGE_ACCOUNT="$W/judge-account" JG_TEST_PR_BODY="$W/pr-body"
chmod +x "$W/fakebin/done-done"
# The first proof refuses a missing landing row after publishing; retry needs no new word or push.
proofs="$HOME_D/data/trunk-landing-proofs.tsv"
cp "$proofs" "$W/saved-proofs"; : > "$proofs"
out=$(trunk release "$PROJ" 2>&1) && fail 'a missing landing proof row must refuse'
assert_contains "$out" 'no landing proof row' 'the failure must identify the missing proof'
[ ! -e "$HOME_D/state/trunk-word-release-proj" ] || fail 'publication must spend the release word'
rows=$(wc -l < "$HOME_D/data/trunk-releases.tsv")
cp "$W/saved-proofs" "$proofs"
# An old trunk with an uncarried hotfix must also refuse, and be retryable.
cp "$HOME_D/data/trunk-versions.tsv" "$W/saved-versions"
git -C "$W/lane" checkout -q -b old-hotfix "$(tip)^" || fail 'create old trunk fixture'
commit_in "$W/lane" hotfix.txt old 'old trunk hotfix'
git -C "$PROJ" fetch -q "$W/lane" old-hotfix:refs/heads/trunk-old || fail 'import old trunk fixture'
printf 'proj\t0\ttrunk-old\t%s\n' "$(git -C "$W/lane" rev-parse HEAD^)" >> "$HOME_D/data/trunk-versions.tsv"
out=$(trunk release "$PROJ" 2>&1) && fail 'an uncarried old trunk hotfix must refuse'
assert_contains "$out" 'hotfix on trunk-old is not carried' 'the refusal must identify the old trunk'
cp "$W/saved-versions" "$HOME_D/data/trunk-versions.tsv"
: > "$W/change-pin"
out=$(trunk release "$PROJ" 2>&1) && fail 'a changed green pin must refuse'
assert_contains "$out" 'green pin changed' 'the refusal must identify the changed pin'
rm "$W/change-pin"
git -C "$PROJ" config remote.origin.pushurl "$W/no-such-remote.git"
out=$(trunk release "$PROJ" 2>&1) || fail "proof retry failed: $out"
[ "$(wc -l < "$HOME_D/data/trunk-releases.tsv")" = "$rows" ] || fail 'retry must not publish a second release'
head=$(tip)
# Drive the merge's real proof gate before inspecting the missing receipt.
gate_out=$(PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_PROOF_BOARD="$W/board.json" \
  bash -c '. "$1/bin/jg-merge-gate-lib.sh"; jg_dod_proof_gate "$2" "$3" "$4" "$5"' _ \
  "$W/root" "$HOME_D" "$id" "$head" "$url" 2>&1) || gate_rc=$?
[ "${gate_rc:-0}" -eq 0 ] || fail "release merge proof refused: $gate_out"
[ -f "$HOME_D/state/$id.run-receipt.json" ] || fail "release head $head has no completion receipt"
[ "$(jq -r .head "$HOME_D/state/$id.run-receipt.json")" = "$head" ] || fail 'receipt must bind the release head'
[ -f "$HOME_D/data/$id/merge-card.json" ] || fail 'release has no approved merge-card evidence'
[ "$(cat "$W/judge-account")" = "$W/account" ] || fail 'judge did not use the home account pin'
pass 'release produces proof at its own head'
}

test_a_release_keeps_one_url_and_takes_the_open_release_pr_as_success
test_a_pushed_release_without_its_record_gets_the_record_and_no_second_push
test_the_release_pr_has_an_owning_task_the_guard_admits
test_release_proof_at_its_head
printf 'jg-trunk-release-open-pr: ok\n'
