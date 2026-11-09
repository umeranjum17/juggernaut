#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # W, HOME_D and PROJ are read by the suites that source this file
# Shared fixture for the local trunk flow suites (tests/jg-trunk.test.sh, tests/jg-trunk-check.test.sh and
# tests/jg-trunk-queue.test.sh): a world to land in, the lane and proof builders, and the stand-in test rig.
# Source it after tests/lib.sh, with TMP_ROOT set. It runs nothing by itself.
# shellcheck source=tests/jg-trunk-proof-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-proof-fixture.sh"

# A world: a copied bin (with a stub hold reader), a home, a project with a local bare origin
# and an initialised trunk, a recording live hook and a fake gh-axi.
world() {  # <name>: sets W HOME_D PROJ
  W="$TMP_ROOT/$1"; HOME_D="$W/home"; PROJ="$HOME_D/projects/proj"
  mkdir -p "$W/root" "$HOME_D/state" "$HOME_D/data" "$HOME_D/config" "$W/fakebin"
  cp -r "$ROOT/bin" "$W/root/bin"
  ln -s "$ROOT/core" "$W/root/core"; ln -s "$ROOT/policy" "$W/root/policy"
  cat > "$W/root/bin/jg-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open) exit 1 ;;
  blocking) [ -f "$JG_STATE_OVERRIDE/linked-open" ] && { printf 'ticket-x\n'; exit 0; }; exit 1 ;;
esac
SH
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
if [ "\$2" = view ]; then
  [ "\$3" = 9 ] && [ "\$4" = --repo ] && [ "\$5" = o/r ] || { echo 'error: gh-axi requires a PR number and --repo' >&2; exit 1; }
  printf 'state: %s\n' "\$(cat "$W/pr-state" 2>/dev/null || echo open)"; exit 0; fi
printf 'https://github.com/o/r/pull/9\n'
SH
  cat > "$HOME_D/config/live-hook.proj" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$W/live-moves"
SH
  cat > "$W/root/bin/jg-fleet-ledger.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$W/ledger-calls"
SH
  cat > "$W/root/bin/jg-teardown.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$W/teardown-calls"
SH
  : > "$HOME_D/config/fleet-ledger"
  chmod +x "$W/root/bin/jg-fleet-ledger.sh" "$W/root/bin/jg-teardown.sh" "$W/root/bin/jg-captain-hold.sh" "$W/fakebin/gh-axi" "$HOME_D/config/live-hook.proj"
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=! grep -q BAD work.txt\ngate-lint=! grep -q UGLY work.txt\nflush-at-ready=1\n' > "$HOME_D/config/trunk-policy"
  printf -- '- proj [local-trunk] - fixture project in local-trunk mode (added 2026-11-07)\n' > "$HOME_D/data/projects.md"
  jg_git_init_commit "$PROJ"
  mkdir -p "$PROJ/bin"; printf '# proj\n' > "$PROJ/AGENTS.md"; : > "$PROJ/bin/.keep"; git -C "$PROJ" add AGENTS.md bin/.keep  # a Squad Lead home is only valid with both
  git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  jg_git_add_origin "$PROJ" "$W/origin.git"
  git -C "$PROJ" branch release/c-4
  trunk init "$PROJ" >/dev/null || fail "trunk init must work"
}

trunk() { PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="${CODE_ROOT:-$W/root}" JG_STATE_OVERRIDE="$HOME_D/state" \
  JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-trunk.sh" "$@"; }

commit_in() {  # <worktree> <file> <content> <message> [<note>]
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m "$4" ${5:+-m "$5"}
}
# prove <id> [PASS|FAIL]: the complete proof for the lane's current head: the completion receipt, the merge-card's approved cited evidence
# and a sealed clean done-done run holding that evidence. `prove_part` writes one input alone.
prove() { prove_part "$1" receipt "${2:-PASS}"; prove_part "$1" card; prove_part "$1" seal; }
prove_part() {  # <id> receipt [PASS|FAIL] | card | seal
  local id=$1 h d="$HOME_D/data/$1"; h=$(git -C "$PROJ" rev-parse "fm/$id"); mkdir -p "$d/.done-done/runs"
  case $2 in
    receipt) printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"g-%s","head":"%s","pr":"","verdict":"%s","at":1,"evidence":"done-done run: ok"}\n' \
      "$id" "$id" "$h" "${3:-PASS}" > "$HOME_D/state/$id.run-receipt.json" ;;
    card | seal) jg_test_trunk_proof "$d" "$h" "$2" ;;
  esac
}
# lane <id> <content> [<file>] [<note>]: a lane off the trunk tip with one commit and a PASS receipt.
lane() {
  local id=$1 wt="$W/lanes/$1"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" "${3:-work.txt}" "$2" "ticket $id" "${4-}"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id"
  prove "$id"; ready "$id"
}
# ready <id>: the worker's own report that the lane is done, the only signal the landing check waits for.
READY_AT=1000
ready() { READY_AT=$((READY_AT + 1)); printf 'done [at=%s]: ready in branch fm/%s (local-trunk)\n' "$READY_AT" "$1" >> "$HOME_D/state/$1.status"; }
# relane <id> <content>: the lane is rebased onto the trunk tip with one new commit and proved again.
relane() { git -C "$W/lanes/$1" reset -q --hard trunk; commit_in "$W/lanes/$1" work.txt "$2" "ticket $1"; prove "$1"; }
# plain_git: git with no machine-wide hooks path, so the project's own reference-transaction hook is the one that runs.
plain_git() { env GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
tip() { git -C "$PROJ" rev-parse trunk; }
refused() {  # <what> <id> <expect>: landing refuses, mentions <expect>, and leaves the trunk alone
  local before out rc=0
  before=$(tip); out=$(trunk land "$2" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$1 must refuse, but it landed: $out"
  assert_contains "$out" "$3" "$1 must say why"
  [ "$(tip)" = "$before" ] || fail "$1 moved the trunk"
}

sweep() {  # one check sweep over the fixture home, then wait for the detached landings it started
  local out
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D") || fail "the check must not fail: $out"
  for _ in $(seq 1 100); do grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state || break; sleep 0.2; done
  printf '%s' "$out"
}

# A stand-in for bin/jg-test-run.sh that keeps its marker contract: it runs t/*.test.sh (or the paths it is given) in the clone.
rig() {
  cat > "$W/rig.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --all ] || set -- t/*.test.sh
total=0 failed=0
for s in "$@"; do
  echo "JG_TEST_BEGIN 2026-01-01T00:00:00Z $s family=x expected_gate_skip=none"
  bash "$s" 2>&1; rc=$?
  echo "JG_TEST_END 2026-01-01T00:00:00Z $s exit=$rc duration_ms=1 gate_skip=false"
  total=$((total + 1)); [ "$rc" -eq 0 ] || failed=$((failed + 1))
done
echo "JG_TEST_SUMMARY total=$total failed=$failed skipped_gate=0 duration_ms=1"
[ "$failed" -eq 0 ]
SH
  printf 'gate-full=export GATE_MARK=yes; bash %s/rig.sh --all\ngate-rerun=bash %s/rig.sh\ngate-red-ticket=ticket-red\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/backlog-calls"\n' "$W" > "$W/root/bin/jg-backlog.sh"; chmod +x "$W/root/bin/jg-backlog.sh"
}
# The tip carries a red that shows only in the gate's environment, and a script that passes.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
seed_red_tip() {
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  commit_in "$W/seed" t/a.test.sh '[ "${GATE_MARK:-}" = yes ] && { echo "not ok - tip case" >&2; exit 1; }; exit 0' "seed a"
  commit_in "$W/seed" t/c.test.sh 'exit 0' "seed c"
  # A red whose only line is a Go package result: its elapsed seconds differ on every run, so they are not part of how it fails.
  commit_in "$W/seed" t/h.test.sh 'echo "FAIL	pkg	0.$((RANDOM % 900 + 100))s" >&2; exit 1' "seed h"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
}
