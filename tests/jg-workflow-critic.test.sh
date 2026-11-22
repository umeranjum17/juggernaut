#!/usr/bin/env bash
# Drive the critic kind through workflow advance, the real depth gate and the handoff.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(jg_test_tmproot jg-workflow-critic)
export HOME=$TMP/os-home XDG_DATA_HOME=$TMP/xdg-data XDG_CONFIG_HOME=$TMP/xdg-config
export XDG_STATE_HOME=$TMP/xdg-state XDG_CACHE_HOME=$TMP/xdg-cache
mkdir -p "$HOME"
WF=$ROOT/bin/jg-workflow.sh
HO=$ROOT/bin/jg-recon-handoff.sh
GATE=$ROOT/bin/jg-recon-gate.sh
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")
export JG_WORKFLOW_ALERT=$TMP/alert JG_WORKFLOW_HOLD=$TMP/hold JG_WORKFLOW_SEND=$TMP/send
export JG_WORKFLOW_CREW_STATE=$TMP/crew JG_WAR_ROOM_NEXT=0
# shellcheck disable=SC2016 # The generated tools read their own arguments and environment.
{
  printf '#!/bin/sh\necho "$*" >> "$JG_HOME/alerts"\n' > "$JG_WORKFLOW_ALERT"
  printf '#!/bin/sh\necho "$*" >> "$JG_HOME/holds"\n' > "$JG_WORKFLOW_HOLD"
  printf '#!/bin/sh\necho "$*" >> "$JG_HOME/sends"\n' > "$JG_WORKFLOW_SEND"
}
printf '#!/bin/sh\necho "source: pane"\n' > "$JG_WORKFLOW_CREW_STATE"
chmod +x "$TMP/alert" "$TMP/hold" "$TMP/send" "$TMP/crew"

wait_for() {
  local i
  for ((i = 0; i < 150; i++)); do [ ! -s "$1" ] || return 0; sleep 0.1; done
  fail "no record at $1"
}
rows() { "${BD[@]}" list --parent jg-t1 --all --limit 0 --json; }
row() {
  rows | jq -er --arg kind "$1" --argjson index "${2:-0}" \
    '[.[] | select(.metadata.wf_kind == $kind)] | sort_by(.metadata.wf_index | tonumber) | .[$index].id'
}
status() { "${BD[@]}" show "$1" --json | jq -r '.[0].status'; }
adv() { "$WF" advance "$JG_HOME"; }
setup() {
  export JG_HOME=$TMP/$1 JG_STATE_OVERRIDE=$TMP/$1/state JG_DATA_OVERRIDE=$TMP/$1/data JG_CONFIG_OVERRIDE=$TMP/$1/config
  jg_test_beads_home "$JG_HOME"
  mkdir -p "$JG_STATE_OVERRIDE"
  printf '%s\n' '- demo' > "$JG_DATA_OVERRIDE/projects.md"
  jg_test_add "$JG_HOME" jg-t1 "[feature] Faster sign in" --body "Owner order: Main42747. Review the design."
  "$WF" set jg-t1 "${2:-deep-slices}" --by main > /dev/null
  R=$(row recon); C=$(row critic); O=$(row owner)
  research=${R//./-}; critic=${C//./-}
  draft=$JG_DATA_OVERRIDE/$research
  brief=$JG_DATA_OVERRIDE/$critic/brief.md
  jobs=$JG_DATA_OVERRIDE/workflows
  adv > /dev/null
  draft_for "$R"
}
draft_for() {
  local research=${1//./-} draft=$JG_DATA_OVERRIDE/${1//./-}
  wait_for "$jobs/$1.start.rc"
  assert_contains "$(cat "$jobs/$1.start.rc")" "0 started" "the researcher starts"
  local n=1 kind kinds=(code docs upstream oss community run)
  for ((n = 1; n <= 20; n++)); do
    kind=${kinds[n % 6]}
    printf '{"id":"S-%s","kind":"%s","title":"source","link":"x/%s","read":"2026-11-05"}\n' "$n" "$kind" "$n"
  done > "$draft/sources.jsonl"
  printf '%s\n' '{"id":"C-1","text":"a claim","kind":"fact","sources":["S-1"],"load_bearing":true}' > "$draft/claims.jsonl"
  printf '%s\n' '{"claim":"C-1","status":"verified","method":"run","note":"re-measured"}' > "$draft/checks.jsonl"
  {
    printf '# Draft for %s\n\n' "$research"
    n=1
    local title
    for title in "Answer" "What was asked" "Method and depth record" "Prior art and options" "Findings" "Design" "Not checked" \
      "Implementation plan" "Risks and mitigations" "Open decisions" "Acceptance test" "Sources and evidence" "Revision log"; do
      printf '## %s. %s\nBody of %s, citing [C-1].\n\n' "$n" "$title" "$title"
      n=$((n + 1))
    done
  } > "$draft/report.md"
  printf 'kind=scout\nticket=%s\n' "$1" > "$JG_STATE_OVERRIDE/$research.meta"
  printf 'done [at=1]: draft ready for the separate critic\n' > "$JG_STATE_OVERRIDE/$research.status"
  assert_contains "$("$GATE" "$research" --step)" 'STEP critic' "the real gate recognizes the draft"
}
close_recon() { "$ROOT/bin/jg-backlog.sh" 'done' "$R" --note 'fixture for an already closed workflow step' > /dev/null; }
critic_started() {
  wait_for "$jobs/$C.start.rc"
  assert_contains "$(cat "$jobs/$C.start.rc")" "0 started" "the critic starts"
}
moves() { "$HO" show "$research" | cut -f2 | paste -s -d ' ' -; }
verdict() { "$HO" verdict "$research" --critic "$critic" --hash "$(sha256sum "$draft/report.md" | cut -d' ' -f1)" --gaps "$1" > /dev/null; }

setup t1
close_recon
adv
critic_started
assert_contains "$(cat "$brief")" "Role: critic of $research" "T1 the brief names its role"
assert_contains "$(cat "$brief")" "$draft/report.md" "T1 the brief names the report"
assert_contains "$(cat "$brief")" "jg-recon-handoff.sh verdict $research --critic $critic --hash" "T1 the verdict binds both tasks and the hash"
assert_not_contains "$(cat "$brief")" "Recon depth:" "T1 the critic has a quick brief"
assert_equals "draft assign" "$(moves)" "T1 the handoff records a draft then an assignment"
assert_contains "$("$HO" assignee "$research")" "$critic" "T1 the row-derived critic owns the draft"
assert_contains "$(cat "$JG_STATE_OVERRIDE/dispatch-approved/$C")" "model=claude-opus-5-5" "T1 the critic route is approved"
pass "T1 an unrecorded draft gets a quick critic brief, assignment and approval"

before=$(stat -c '%i' "$brief")
adv
assert_equals "$before" "$(stat -c '%i' "$brief")" "T5 another advance keeps the same brief"
assert_equals "draft assign" "$(moves)" "T5 no duplicate assignment"
pass "T5 another advance leaves the critic start intact"

verdict 4
adv
wait_for "$JG_HOME/sends"
assert_contains "$(cat "$JG_HOME/sends")" "$research Critic round 1" "T2 the researcher receives the gaps"
adv
assert_equals 1 "$(wc -l < "$JG_HOME/sends")" "T2 each round is sent once"
pass "T2 the critic result forwards gaps to the researcher once"

for n in 2 3 4; do
  printf '\nRevision %s\n' "$n" >> "$draft/report.md"
  "$HO" revise "$research" > /dev/null
  verdict 4
  adv
done
assert_equals open "$(status "$C")" "T4 the failed critic step stays open"
assert_contains "$(cat "$jobs/$C.failed")" "three critic rounds and gaps remain" "T4 the cap is reported"
adv
assert_equals 1 "$(wc -l < "$JG_HOME/alerts")" "T4 the alert is raised once"
pass "T4 a fourth critiqued draft fails after three rounds with gaps"

setup t1b
close_recon
"$HO" draft "$research" > /dev/null
adv
critic_started
assert_equals "draft assign" "$(moves)" "T1b the existing draft is reused"
pass "T1b a recorded draft gets an assignment without a duplicate draft"
verdict 0
adv
wait_for "$jobs/$O.start.rc"
assert_equals closed "$(status "$C")" "T3 acceptance closes the critic step"
assert_contains "$(cat "$JG_HOME/holds")" "$O" "T3 the owner step starts"
pass "T3 an accepted verdict starts the downstream owner step"

setup open 'recon(deep)*2 > critic*2 + owner'
R2=$(row recon 1); C2=$(row critic 1)
adv > /dev/null
assert_absent "$jobs/$C.started" "the critic stage waits for the other Recon draft"
draft_for "$R2"
for ((i = 0; i < 150; i++)); do
  adv > /dev/null
  [ ! -s "$jobs/$C.start.rc" ] || [ ! -s "$jobs/$C2.start.rc" ] || break
  sleep 0.1
done
critic_started
assert_contains "$(cat "$jobs/$C2.start.rc")" "0 started" "the second critic starts"
assert_contains "$(cat "$JG_DATA_OVERRIDE/${C2//./-}/brief.md")" "Role: critic of ${R2//./-}" "the second critic reads its paired Recon"
assert_equals open "$(status "$R")" "the researcher's step remains open"
assert_equals open "$(status "$R2")" "the second researcher remains open"
ready=$("$ROOT/bin/jg-backlog.sh" ready --spawnable)
assert_contains "$ready" "$(printf '%s\tdemo' "$C")" "dispatch sees the first critic"
assert_contains "$ready" "$(printf '%s\tdemo' "$C2")" "dispatch sees the second critic"
pass "paired critics start from STEP critic while both Recons remain open"
assert_absent "$jobs/$O.started" "the owner with the same dependency still waits"
assert_not_contains "$ready" "$(printf '%s\tdemo' "$O")" "dispatch keeps the same dependency for the owner"
pass "other steps still wait for the Recon to close"
