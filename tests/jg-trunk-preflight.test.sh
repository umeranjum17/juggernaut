#!/usr/bin/env bash
# Integration test for bin/jg-trunk-preflight.sh: the lane-side run of the landing chain, against real git repositories,
# the real merge-card, the real owner-rules gate (a real key pair and signature) and the real local landing gates.
#
# P1 A lane missing the run's steps.json, the checks-lint row and the owner signature gets all three named in ONE run, in
#    landing order, and no record is written; adding them makes it PASS and writes data/<id>/preflight.<head>.json.
#    The signature is the signer's step after the lane's ready line, so a lane run lists it as awaiting; --landing judges it too.
# P2 --at-start prints the exact commands for gates 1-5 and the list of gates 6-9, runs nothing and writes nothing.
# P3 Every later gate names itself when it fails: the captain hold, the design call, the Nav lines, owner-guard, gate-lint
#    and a tool the gate command needs that is not on the PATH.
# P4 Drift: preflight --landing and `jg-trunk.sh land` agree on the same lanes (they call the same owner commands and
#    the same gate functions), and a lane that passed preflight lands.
# P5 The owner-rules gate's checks-lint refusal names the report file, never a placeholder.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A lane's launch injects git config through GIT_CONFIG_COUNT/KEY/VALUE (identity and a core.hooksPath overlay), which a fixture
# repository under /tmp must not inherit. Lane jg-dzgb0 owns the shared helper for this; this line is replaced by it once it lands.
for _v in $(compgen -e | grep '^GIT_CONFIG_\(COUNT\|KEY_\|VALUE_\)'); do unset "$_v"; done; unset _v

TMP_ROOT=$(jg_test_tmproot jg-trunk-preflight)

# A world: a copied bin (with a stub hold reader), a home with owner rules and a real key pair, a project with a trunk.
world() {  # <name>: sets W HOME_D PROJ
  W="$TMP_ROOT/$1"; HOME_D="$W/home"; PROJ="$HOME_D/projects/proj"
  mkdir -p "$W/root" "$HOME_D/state" "$HOME_D/data" "$HOME_D/config" "$W/fakebin"
  cp -r "$ROOT/bin" "$W/root/bin"
  ln -s "$ROOT/core" "$W/root/core"; ln -s "$ROOT/policy" "$W/root/policy"
  cat > "$W/root/bin/jg-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open) [ -f "$JG_STATE_OVERRIDE/held-$2" ] && exit 0; exit 1 ;;
  blocking) exit 1 ;;
esac
SH
  # done-done is the external tool: with no answer, merge-card finds only the run records under the task folder.
  printf '#!/bin/sh\nexit 1\n' > "$W/fakebin/done-done"
  chmod +x "$W/root/bin/jg-captain-hold.sh" "$W/fakebin/done-done"
  printf 'gate-full=git --version && jq --version\ngate-lint=! grep -q UGLY work.txt\n' > "$HOME_D/config/trunk-policy"
  printf -- '- proj [local-trunk] - fixture project in local-trunk mode (added 2026-11-07)\n' > "$HOME_D/data/projects.md"
  : > "$HOME_D/config/owner-rules"
  printf '#!/usr/bin/env bash\nexec "%s/core/owner-rules/bin/jg-owner-rules-gate.sh" "$@"\n' "$W/root" > "$HOME_D/config/merge-gate"
  chmod +x "$HOME_D/config/merge-gate"
  PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" "$ROOT/core/owner-rules/bin/jg-owner-rules-gate.sh" init-key >/dev/null || fail "the fixture needs a key pair"
  jg_git_init_commit "$PROJ"
  env_run "$W/root/bin/jg-trunk.sh" init "$PROJ" >/dev/null || fail "trunk init must work"
}

env_run() { PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" \
  JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$@"; }
pf() { env_run "$W/root/bin/jg-trunk-preflight.sh" "$@"; }
trunk() { env_run "$W/root/bin/jg-trunk.sh" "$@"; }
tip() { git -C "$PROJ" rev-parse trunk; }
head_of() { git -C "$PROJ" rev-parse "fm/$1"; }

commit_in() {  # <worktree> <file> <content> <message>
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m "$4"
}
# lane <id> <content> [<meta line>...]: a lane off the trunk tip with one commit, a PASS receipt and nothing else.
lane() {
  local id=$1 content=$2 wt="$W/lanes/$1"; shift 2
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" work.txt "$content" "ticket $id"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=local-only" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id" "design_call=no" "ui_change=no" "$@"
  printf '{"schema":1,"task":"%s","mode":"local-only","spawn_gen":"g-%s","head":"%s","pr":"","verdict":"PASS","at":1,"evidence":"done-done run: ok"}\n' \
    "$id" "$id" "$(head_of "$id")" > "$HOME_D/state/$id.run-receipt.json"
}
# The inputs, one each: the sealed run (with or without the steps record), merge-card's check record, the Checks text,
# the checks-lint row and the owner's signature.
seal() {  # <id> [nosteps]
  local d="$HOME_D/data/$1/.done-done/runs"; mkdir -p "$d"
  jq -n --arg h "$(head_of "$1")" --arg s "${2:-steps}" '{schema: 1, run_id: "r1", commit: $h, exit: 0, dirty: false, files: ["cap.txt"]}
    + (if $s == "steps" then {steps: {target: {version: "x"}, start: "s", steps: ["a"], result: "r"}} else {} end)' > "$d/r1.json"
}
mccard() { mkdir -p "$HOME_D/data/$1"; jq -n --arg h "$(head_of "$1")" '{head: $h, pr: "-", verdict: "pass", check: {}}' > "$HOME_D/data/$1/merge-card.json"; }
checks() { mkdir -p "$HOME_D/data/$1"; printf 'outcome: x\nscreen: none\n' > "$HOME_D/data/$1/checks.md"; }
lintrow() { printf '2026-11-08T00:00:00Z\t%s\t-\tpass\t1 evidence files\n' "$HOME_D/data/$1/checks.md" >> "$HOME_D/data/checks-gate.log"; }
sign() { PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" "$ROOT/core/owner-rules/bin/jg-owner-rules-gate.sh" sign "$1" "$(head_of "$1")" - >/dev/null || fail "the fixture must sign $1"; }
# ready <id> <content>: a lane with every input in place except the signature.
ready() { lane "$1" "$2" "${@:3}"; seal "$1"; mccard "$1"; checks "$1"; lintrow "$1"; }

line_of() { printf '%s\n' "$1" | grep -n -- "$2" | head -1 | cut -d: -f1; }

test_a_lane_missing_three_inputs_gets_all_three_named_in_landing_order() {
  local out rc=0 h s l g
  world p1; lane l1 good; seal l1 nosteps; mccard l1; checks l1; h=$(head_of l1)
  out=$(pf l1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a lane missing inputs must not pass: $out"
  assert_contains "$out" "steps.json" "the missing steps record must be named"
  assert_contains "$out" "checks-lint" "the missing lint row must be named"
  assert_contains "$out" "owner-signature" "the missing signature must be named"
  s=$(line_of "$out" 'sealed-run'); l=$(line_of "$out" 'checks-lint'); g=$(line_of "$out" 'owner-signature')
  { [ -n "$s" ] && [ -n "$l" ] && [ -n "$g" ] && [ "$s" -lt "$l" ] && [ "$l" -lt "$g" ]; } || fail "the gates must come in landing order (sealed-run $s, checks-lint $l, owner-signature $g): $out"
  [ ! -e "$HOME_D/data/l1/preflight.$h.json" ] || fail "a failing preflight must write no PASS record"
  seal l1; lintrow l1
  out=$(pf l1 2>&1) || fail "with the inputs in place the lane run must pass: $out"
  assert_contains "$out" "PREFLIGHT PASS" "a pass must say so"
  assert_contains "$out" "awaiting" "the signer's step must be listed as awaiting"
  [ "$(jq -r '.verdict + " " + .signature + " " + .head' "$HOME_D/data/l1/preflight.$h.json")" = "PASS awaiting $h" ] || fail "the PASS record must bind the head and say the signature is awaiting"
  rc=0; out=$(pf --landing l1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "--landing must refuse an unsigned lane: $out"
  assert_contains "$out" "owner-signature" "--landing must name the signature"
  [ "$(jq -r .verdict "$HOME_D/data/l1/preflight.$h.json" 2>/dev/null)" != PASS ] || [ "$(jq -r .signature "$HOME_D/data/l1/preflight.$h.json")" != valid ] || fail "an unsigned lane must not get a valid-signature record"
  sign l1
  out=$(pf --landing l1 2>&1) || fail "a signed lane must pass --landing: $out"
  [ "$(jq -r .signature "$HOME_D/data/l1/preflight.$h.json")" = valid ] || fail "the record must say the signature is valid"
  pass 'a lane missing the steps record, the lint row and the signature gets all three named in landing order; adding them passes and writes the record'
}

test_at_start_lists_the_gates_and_runs_nothing() {
  local out
  world p2; lane l2 good
  out=$(pf --at-start l2 2>&1) || fail "--at-start must succeed: $out"
  for want in "done-done run --" "merge-card check l2" "merge-card receipt l2" "checks-lint" "jg-owner-rules-gate.sh sign l2" captain-hold owner-guard gate-lint gate-tools; do
    assert_contains "$out" "$want" "--at-start must print $want"
  done
  [ -z "$(ls "$HOME_D/data/l2" 2>/dev/null)" ] || fail "--at-start must write nothing: $(ls "$HOME_D/data/l2")"
  pass '--at-start prints the commands for gates 1-5 and the list of 6-9 and writes nothing'
}

test_each_later_gate_names_itself() {
  local out rc
  world p3
  ready held a; sign held; touch "$HOME_D/state/held-held"
  ready dsg b design_call=bogus; sign dsg
  ready nav c ui_change=yes; sign nav
  ready leak SECRETWORD; sign leak; printf 'SECRETWORD\n' > "$HOME_D/config/owner-details-patterns"
  ready ugly UGLY; sign ugly
  ready tool d; sign tool
  chk() {  # <id> <gate name>
    rc=0; out=$(pf --landing "$1" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$1 must not pass: $out"
    assert_contains "$out" "$2" "$1 must name the $2 gate"
  }
  chk held captain-hold; chk dsg design; chk nav nav; chk leak owner-guard; chk ugly gate-lint
  printf 'gate-full=no-such-tool-xyz --go\ngate-lint=true\n' > "$HOME_D/config/trunk-policy"
  chk tool no-such-tool-xyz
  pass 'the hold, design, nav, owner-guard, gate-lint and missing-tool findings each name their gate'
}

test_preflight_and_landing_agree() {
  local out rc=0 id
  world p4
  ready nolint a1; : > "$HOME_D/data/checks-gate.log"; sign nolint
  ready unsigned a2
  ready held a3; sign held; touch "$HOME_D/state/held-held"
  ready ugly UGLY; sign ugly
  ready good ok; sign good
  for id in nolint unsigned held ugly; do
    rc=0; pf --landing "$id" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "preflight must refuse $id"
    rc=0; trunk land "$id" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "landing must refuse $id too: preflight and landing drifted"
  done
  lintrow good
  out=$(pf --landing good 2>&1) || fail "the good lane must pass preflight: $out"
  out=$(trunk land good 2>&1) || fail "a lane that passed preflight must land: $out"
  [ "$(tip)" = "$(head_of good)" ] || fail "the trunk must be at the landed lane"
  pass 'preflight --landing and the lander agree on the same lanes, and a lane that passed preflight lands'
}

test_the_lint_refusal_names_the_report_file() {
  local out
  world p5
  lane l5 good; seal l5; checks l5; sign l5
  out=$(PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" "$HOME_D/config/merge-gate" l5 - "$(head_of l5)" - 2>&1) && fail "a lane with no lint row must be refused"
  assert_contains "$out" "$HOME_D/data/l5/checks.md" "the refusal must name the checks file"
  case $out in *"<report file>"*) fail "the refusal must not print a placeholder: $out" ;; esac
  pass 'the owner-rules lint refusal names the report file'
}

test_a_lane_missing_three_inputs_gets_all_three_named_in_landing_order
test_at_start_lists_the_gates_and_runs_nothing
test_each_later_gate_names_itself
test_preflight_and_landing_agree
test_the_lint_refusal_names_the_report_file
printf 'jg-trunk-preflight: ok\n'
