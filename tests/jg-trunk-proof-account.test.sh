#!/usr/bin/env bash
# Integration test: a proved head stays proved when the fleet moves to another account (merge-card's proof_context, read by
# bin/jg-trunk.sh through bin/jg-merge-gate-lib.sh's jg_dod_trunk_proof_gaps). Through tests/jg-trunk-fixture.sh it runs the real
# landing chain with the account of the lander set to account B while the proof was saved under account A.
#
# T21 The landing check clears CLAUDE_CONFIG_DIR before it reads a proof: `jg-trunk.sh proof` and `land` admit the head whose tree,
#    project and proof home are the same, and the landing row names both accounts. Seed: the refusal of 10 Nov 11:00:04Z,
#    "merge-card: explicit proof context/account differs from the passed check", which cost one whole proof.
#    The worker's own done keeps the compare: with account B set, its done is refused.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

test_a_proof_saved_under_one_account_lands_under_another() {
  local out rc=0 dd a b c row
  world acct; dd="$W/dd" a="$W/acct-a" b="$W/acct-b" c="$HOME_D/data/q1/merge-card.json"; cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  mkdir -p "$dd" "$a" "$b"; printf 'judge: {}\n' > "$dd/config.yaml"
  lane q1 'the change' q1.txt
  # The card as `merge-card check` saves it: bound to account A, the proof home and the lane's project.
  jq -c --arg home "$dd" --arg a "$a" --arg p "$PROJ" --arg h "$(git hash-object "$dd/config.yaml")" \
    '.context = {home:$home, account:$a, project:$p, config_hash:$h}' "$c" > "$c.new" && mv "$c.new" "$c"
  out=$(CLAUDE_CONFIG_DIR=$a DONE_DONE_HOME=$dd trunk proof q1 2>&1) || fail "the account the proof was saved under must be admitted: $out"
  out=$(CLAUDE_CONFIG_DIR=$b trunk proof q1 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "the landing check under account B must admit the proof saved under A, got exit $rc: $out"
  out=$(CLAUDE_CONFIG_DIR=$b done_gate q1) && fail "the worker's own done keeps the compare, so under account B it must be refused: $out"
  assert_contains "$out" "differs from the passed check" "the worker's done names the differing account"
  # Every other reader of the proof (crew state, a lead on another account) calls the gaps function without the done flag.
  out=$(CLAUDE_CONFIG_DIR=$b JG_HOME="$HOME_D" bash -c '. "$1"; shift; jg_dod_trunk_proof_gaps "$@"' _ "$W/root/bin/jg-merge-gate-lib.sh" "$HOME_D" "$HOME_D/state" q1 "$HOME_D/state/q1.meta" "$(git -C "$W/lanes/q1" rev-parse HEAD)" 2>&1 ) \
    || fail "a view of the proof under account B must show no refusal: $out"
  out=$(CLAUDE_CONFIG_DIR=$b trunk land q1 2>&1) || fail "the lane proved under A must land under B: $out"
  git -C "$PROJ" cat-file -e "trunk:q1.txt" || fail "the landed tip must hold the lane's change"
  row=$(grep -F "$(git -C "$PROJ" rev-parse trunk)" "$HOME_D/data/trunk-landing-proofs.tsv") || fail "the landing must record its proofs row"
  assert_contains "$row" "proof-account=$a" "the row names the account the proof was saved under"
  assert_contains "$row" "lander-account=$b" "the row names the account of the lander"
  pass 'a proof saved under account A lands under account B, and the row names both accounts'
}

test_a_proof_saved_under_one_account_lands_under_another
printf 'jg-trunk-proof-account: ok\n'
