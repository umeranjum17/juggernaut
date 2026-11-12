#!/usr/bin/env bash
# Shared fixture for the bin/jg-trunk.sh integration suites tests/jg-trunk.test.sh, tests/jg-trunk-live.test.sh,
# tests/jg-trunk-gate.test.sh, tests/jg-trunk-queue.test.sh, tests/jg-trunk-retry.test.sh and tests/jg-trunk-verify.test.sh: real git repositories,
# a local bare origin, the real gate chain and a stub for the captain-hold reader. Each suite sources it and runs only
# its own cases, so each stays well under the per-script bound. It is sourced, never run.
set -u
# The fixture lanes are judged in their own proof context: the account or done-done home of whoever runs this suite (a worker pane,
# or a sealed run with an explicit DONE_DONE_HOME) must not reach the merge-card check, which refuses a context that differs.
unset CLAUDE_CONFIG_DIR DONE_DONE_HOME
# Every fixture lane is sealed at its own head on an unmoved trunk, so the lander would take that run for its tests. The suites that
# test the gate itself need the gate to run; the case that tests the reuse sets this to 1 (tests/jg-trunk-gate.test.sh).
export JG_TRUNK_SEALED_REUSE=0

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-trunk)

# A world: a copied bin (with a stub hold reader), a home, a project with a local bare origin
# and an initialised trunk, a recording live hook and a fake gh-axi.
world() {  # <name>: sets W HOME_D PROJ
  W="$TMP_ROOT/$1"; HOME_D="$W/home"; PROJ="$HOME_D/projects/proj"
  if [ "${JG_TRUNK_FIXTURE_CACHE:-0}" = 1 ] && [ -d "$TMP_ROOT/.world-template" ]; then
    cp -a "$TMP_ROOT/.world-template" "$W"
    # Only these fixture-owned files embed the original world's path.
    sed -i "s|$TMP_ROOT/.world-source|$W|g" "$W/fakebin/gh-axi" "$HOME_D/config/live-hook.proj" \
      "$W/origin.git/config" "$PROJ/.git/config" "$W/root/bin/jg-send.sh" \
      "$W/root/bin/jg-teardown.sh" "$W/root/bin/jg-fleet-ledger.sh" "$W/root/bin/jg-backlog.sh"
    return
  fi
  mkdir -p "$W/root" "$HOME_D/state" "$HOME_D/data" "$HOME_D/config" "$W/fakebin"
  cp -r "$ROOT/bin" "$W/root/bin"
  # Legacy trunk journeys isolate release proof; its own journey restores the real helper.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/root/bin/jg-trunk-release-proof.sh"
  # Other landing journeys use a stand-in backlog; the ticket-delivery journey installs the real one.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/backlog-calls"\n' "$W" > "$W/root/bin/jg-backlog.sh"
  chmod +x "$W/root/bin/jg-backlog.sh"
  # The fixture homes are bare repositories (no beacon, overlay or supervision read); the health check has its own test.
  # shellcheck disable=SC2016 # the stub expands its own argument
  printf '#!/usr/bin/env bash\necho "ok $2"\n' > "$W/root/bin/jg-home-health.sh"
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
  # The forge's commit-status write (the release proof status) is accepted. The stand-in holds no world path, so the cached
  # world template (JG_TRUNK_FIXTURE_CACHE) can be copied to another world unchanged.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/gh"
  chmod +x "$W/fakebin/gh"
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
rm -f "$HOME_D/state/\$1.meta"  # the real teardown removes the task record the moment a landed lane is cleaned up
SH
  cat > "$W/root/bin/jg-send.sh" <<SH
#!/usr/bin/env bash
printf '%s\\t%s\\n' "\$1" "\$2" >> "$W/send-calls"
SH
  : > "$HOME_D/config/fleet-ledger"
  chmod +x "$W/root/bin/jg-send.sh" "$W/root/bin/jg-fleet-ledger.sh" "$W/root/bin/jg-teardown.sh" "$W/root/bin/jg-captain-hold.sh" "$W/fakebin/gh-axi" "$HOME_D/config/live-hook.proj"
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=! grep -q BAD work.txt\ngate-lint=! grep -q UGLY work.txt\nflush-at-ready=1\nnightly-hour=24\nlanding-gate=tests\n' > "$HOME_D/config/trunk-policy"
  # A home that can pass its merge gate (core/release-preflight): a proof board and the owner's approval key.
  printf 'jg-merge-card post --board %s/board.json\n' "$W" > "$HOME_D/config/post-merge"; printf '%s\n' 0123456789abcdef0123456789abcdef > "$HOME_D/state/captain-approval.key"
  printf -- '- proj [local-trunk] - fixture project in local-trunk mode (added 2026-11-07)\n' > "$HOME_D/data/projects.md"
  jg_git_init_commit "$PROJ"
  mkdir -p "$PROJ/bin"; printf '# proj\n' > "$PROJ/AGENTS.md"; : > "$PROJ/bin/.keep"; git -C "$PROJ" add AGENTS.md bin/.keep  # a Squad Lead home is only valid with both
  git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  jg_git_add_origin "$PROJ" "$W/origin.git"
  git -C "$PROJ" branch release/c-4
  trunk init "$PROJ" >/dev/null || fail "trunk init must work"
  if [ "${JG_TRUNK_FIXTURE_CACHE:-0}" = 1 ]; then
    cp -a "$W" "$TMP_ROOT/.world-template"
    # Normalize the paths once, so every later world is independent of the first one.
    sed -i "s|$W|$TMP_ROOT/.world-source|g" "$TMP_ROOT/.world-template/fakebin/gh-axi" \
      "$TMP_ROOT/.world-template/home/config/live-hook.proj" "$TMP_ROOT/.world-template/origin.git/config" \
      "$TMP_ROOT/.world-template/home/projects/proj/.git/config" "$TMP_ROOT/.world-template/root/bin/jg-send.sh" \
      "$TMP_ROOT/.world-template/root/bin/jg-teardown.sh" "$TMP_ROOT/.world-template/root/bin/jg-fleet-ledger.sh"
  fi
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
    card) printf '{"head":"%s","verdict":"pass","check":{"claim":"a user can land","evidence":["%s/run.log"]}}\n' "$h" "$d" > "$d/merge-card.json" ;;
    seal) printf 'ok\n' > "$d/run.log"
      printf '{"schema":1,"run_id":"20261109T000000Z-%s-ab","commit":"%s","exit":0,"dirty":false,"started_at":"2026-11-09T00:00:00Z","files":["run.log"]}\n' "${h:0:8}" "$h" > "$d/.done-done/runs/run-$h.json" ;;
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

# done_gate <id> [<mode> <done line>]: the worker's own done, judged by the shared acceptance the status path runs. Prints the refusal.
done_gate() {
  ( # shellcheck disable=SC1091
    . "$W/root/bin/jg-dod-lib.sh"
    JG_HOME="$HOME_D" jg_dod_accept_ship_done ship "${2:-local-trunk}" "$W/lanes/$1" "$PROJ" "${3:-done [at=1]: ready in branch fm/$1 (local-trunk)}" \
      "$HOME_D/state" "$1" "$HOME_D/state/$1.meta" 2>&1 )
}

U=https://github.com/o/r/pull

# One release PR (number 1), open until the merge stand-in merges it. The gh-axi stand-in answers its state; jg-pr-state
# prints what the file ci-state holds (nothing is green); jg-pr-merge records its call and merges like the forge does.
release_world() {  # <name>: world plus a release pull request that stays open until the merge stand-in merges it
  world "$1"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'state: %s\n' "\$(cat "$W/pr-state-\$3" 2>/dev/null || echo open)" ;;
  list) printf 'count: 0\n' ;;
  create) printf '$U/1\n' ;;
esac
SH
  cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2 \$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) git -C "$PROJ" rev-parse trunk ;;
  'pr view '*baseRefName*) printf 'main\ttrunk\n' ;;
  'api '*) printf '{}\n' ;;
esac
exit 0
SH
  cat > "$W/root/bin/jg-pr-state.sh" <<SH
#!/usr/bin/env bash
cat "$W/ci-state" 2>/dev/null || true
SH
  cat > "$W/root/bin/jg-pr-merge.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/merge-calls"
M=\$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "\$(git -C "$PROJ" rev-parse 'trunk^{tree}')" -p origin/main -p "\$(git -C "$PROJ" rev-parse trunk)" -m "Merge pull request #1")
git -C "$PROJ" push -q origin "\$M:refs/heads/main"; echo merged > "$W/pr-state-1"
SH
  printf '#!/usr/bin/env bash\necho "checks-lint: PASS"\n' > "$W/checks-lint"
  ln -s "$W/root/bin" "$HOME_D/bin"   # the merge check runs the home's own bin
  chmod +x "$W/fakebin/gh-axi" "$W/fakebin/gh" "$W/root/bin/jg-pr-state.sh" "$W/root/bin/jg-pr-merge.sh" "$W/checks-lint"
}
