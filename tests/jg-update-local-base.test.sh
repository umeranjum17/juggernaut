#!/usr/bin/env bash
# Integration test for the fleet live move (slice ap-t2-fleet-live-move): bin/jg-update.sh --base <sha>,
# `jg-trunk.sh live` / `waiver`, and the landing check's auto-live, against real git repositories.
#
# T1 One move, one row per home: a clean detached lead behind the tip fast-forwards, a clean lead whose HEAD is
#    not an ancestor but whose content the tip holds is re-pointed by `reset --keep` (row says re-pointed-from),
#    a dirty lead and a lead holding an uncontained commit are SKIPPED with the reason and not touched, Main
#    moves last with a restart-pending marker, and a pool worktree on a lane branch is not touched.
# T2 --home moves exactly one lead (the canary) and leaves Main alone.
# T3 A failed health check pins that home back to its recorded pre-move HEAD and stops the rollout.
# T4 A local-trunk project is refused without --base ("update this project from its trunk").
# T5 `jg-trunk.sh live` runs the mover from an export of the tip, never from the home's own bin; the waiver
#    record is written only by the Overwatch path, spends no word and marks the row; a project without a
#    waiver still needs the captain's word.
# T6 The landing check runs the suite after a landing and, under a waiver, the batched live step on its own, and reports a go-live,
#    a failed move, a new hold or a red suite; tests/jg-trunk.test.sh owns the quiet-window, hourly-cap, red and pin-back journeys.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/jg-update.sh"
jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-update-local-base)

# No machine-wide hooks path and a fixed identity, so fixture commits run no host hook.
export GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
commit_file() {  # <dir> <file> <content> <message>
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "$4"
}

# A world: the project (main at c0, branch trunk c0 -> c1 -> c2 made AFTER Main cloned, so Main must fetch it),
# Main's clone, a home, four leads (worktrees of Main) in the four shapes, and a pool worktree on a lane branch.
mover_world() {  # <name>: sets W C0 C2 X
  W="$TMP_ROOT/$1"; mkdir -p "$W/home/state" "$W/home/data" "$W/home/config"
  git init -q -b main "$W/proj"
  commit_file "$W/proj" AGENTS.md v1 c0; mkdir -p "$W/proj/bin"; commit_file "$W/proj" bin/tool.sh a c0b
  git clone -q "$W/proj" "$W/main"
  git -C "$W/proj" checkout -q -b trunk
  commit_file "$W/proj" a.txt alpha c1; commit_file "$W/proj" b.txt beta c2
  git -C "$W/proj" checkout -q main
  C0=$(git -C "$W/main" rev-parse HEAD); C2=$(git -C "$W/proj" rev-parse trunk)
  local id
  for id in lead-ff lead-repoint lead-dirty lead-unlanded; do
    git -C "$W/main" worktree add -q --detach "$W/$id" "$C0"; printf '%s\n' "$id" > "$W/$id/.jg-squad-lead-home"
    printf -- '- %s - fixture (home: %s; scope: x; projects: proj; added 2026-11-08)\n' "$id" "$W/$id" >> "$W/home/data/squad_leads.md"
  done
  commit_file "$W/lead-repoint" a.txt alpha "squashed c1"; X=$(git -C "$W/lead-repoint" rev-parse HEAD)
  printf 'edit\n' >> "$W/lead-dirty/AGENTS.md"
  commit_file "$W/lead-unlanded" secret.txt mine "only here"
  git -C "$W/main" worktree add -q -b fix/lane "$W/pool" "$C0"
}
run_mover() {  # <extra args>
  JG_ROOT_OVERRIDE="$W/main" JG_HOME="$W/home" JG_STACK_SKIP=1 JG_HOST_WIRING_SKIP=1 \
    "${MOVER:-$UPDATE}" --base "$C2" --project "$W/proj" --branch trunk "$@" 2>&1
}
head_of() { git -C "$W/$1" rev-parse HEAD; }
row_of() { awk -F'\t' -v k="proj:$1" '$1 == k' "$W/home/data/trunk-live.tsv"; }

test_every_home_moves_or_is_skipped_with_one_row() {
  local out rows
  mover_world t1
  out=$(run_mover) || fail "the move must succeed when only leads are skipped: $out"
  [ "$(head_of lead-ff)" = "$C2" ] || fail "a clean lead behind the tip must fast-forward: $out"
  [ "$(head_of lead-repoint)" = "$C2" ] || fail "a clean lead whose content the tip holds must be re-pointed: $out"
  [ "$(head_of lead-dirty)" = "$C0" ] || fail "a dirty lead must not move"
  [ "$(head_of lead-unlanded)" != "$C2" ] || fail "a lead holding an uncontained commit must not move"
  [ "$(git -C "$W/main" rev-parse main)" = "$C2" ] || fail "Main's main must reach the tip by fast-forward: $out"
  [ "$(head_of pool)" = "$C0" ] && [ "$(git -C "$W/pool" symbolic-ref --short HEAD)" = fix/lane ] || fail "a pool worktree on a lane branch must not be touched"
  git -C "$W/lead-repoint" merge-base --is-ancestor "$X" HEAD 2>/dev/null && fail "the re-point must be reset --keep, not a merge"
  rows=$(wc -l < "$W/home/data/trunk-live.tsv" | tr -d ' ')
  [ "$rows" = 5 ] || fail "four leads and Main make five rows, got $rows"
  [ "$(row_of lead-ff | cut -f4)" = live ] && [ "$(row_of lead-ff | cut -f5)" = "$C0" ] || fail "a fast-forward row is live with the pre-move HEAD: $(row_of lead-ff)"
  [ "$(row_of lead-repoint | cut -f4)" = "live,re-pointed-from:${X:0:12}" ] && [ "$(row_of lead-repoint | cut -f5)" = "$X" ] || fail "a re-point row names the old sha: $(row_of lead-repoint)"
  [ "$(row_of lead-dirty | cut -f4)" = "skipped:dirty" ] || fail "a dirty lead is skipped:dirty: $(row_of lead-dirty)"
  [ "$(row_of lead-unlanded | cut -f4)" = "skipped:unlanded:secret.txt" ] || fail "an uncontained lead is skipped:unlanded:<paths>: $(row_of lead-unlanded)"
  [ "$(tail -1 "$W/home/data/trunk-live.tsv" | cut -f1)" = "proj:primary" ] || fail "Main must be the last row"
  assert_contains "$(cat "$W/home/state/trunk-live-restart-pending" 2>/dev/null)" "$C2" "Main must get a restart-pending marker for the new commit"
  pass 'T1 one row per home: two move, two skipped with a reason, Main last, a pool worktree untouched'
}

test_cache_is_cleared_after_a_move() {
  mover_world t1b
  mkdir -p "$W/home/state/squad-lead-summary-cache"; : > "$W/home/state/squad-lead-summary-cache/old.json"
  run_mover >/dev/null || fail "the move must succeed"
  [ ! -e "$W/home/state/squad-lead-summary-cache/old.json" ] || fail "a move must clear the lead summary cache"
  pass 'T1b the lead summary cache is cleared after a move'
}

test_home_moves_one_canary_only() {
  local out
  mover_world t2
  out=$(run_mover --home "$W/lead-ff") || fail "the canary move must succeed: $out"
  [ "$(head_of lead-ff)" = "$C2" ] || fail "the canary lead must move"
  [ "$(head_of lead-repoint)" != "$C2" ] && [ "$(git -C "$W/main" rev-parse main)" = "$C0" ] || fail "--home must leave every other home, Main included, alone"
  [ "$(wc -l < "$W/home/data/trunk-live.tsv" | tr -d ' ')" = 1 ] || fail "the canary writes one row"
  [ ! -e "$W/home/state/trunk-live-restart-pending" ] || fail "a canary must not mark Main for restart"
  pass 'T2 --home moves exactly one lead'
}

test_failed_health_pins_the_home_back_and_stops() {
  local out rc=0
  mover_world t3
  mkdir -p "$W/bin"; cp -r "$ROOT/bin/." "$W/bin/"
  printf '#!/usr/bin/env bash\necho "overlay stale" >&2\nexit 1\n' > "$W/bin/jg-home-health.sh"; chmod +x "$W/bin/jg-home-health.sh"
  out=$(MOVER="$W/bin/jg-update.sh" run_mover) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed health check must fail the move: $out"
  [ "$(head_of lead-ff)" = "$C0" ] || fail "the failed home must be pinned back to its pre-move HEAD"
  [ "$(row_of lead-ff | cut -f4)" = "rolled-back:overlay stale" ] || fail "the row says rolled-back:<reason>: $(row_of lead-ff)"
  [ "$(head_of lead-repoint)" != "$C2" ] && [ "$(git -C "$W/main" rev-parse main)" = "$C0" ] || fail "the rollout must stop at the first failed health check"
  pass 'T3 a failed health check pins that home back and stops the rollout'
}

test_a_local_trunk_project_is_refused_without_base() {
  local out rc=0
  mover_world t4
  printf -- '- juggernaut [local-trunk] - fixture (added 2026-11-08)\n' > "$W/home/data/projects.md"
  out=$(JG_ROOT_OVERRIDE="$W/main" JG_HOME="$W/home" "$UPDATE" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a local-trunk project must refuse jg-update without --base: $out"
  assert_contains "$out" "update this project from its trunk" "the refusal says where the code comes from"
  pass 'T4 jg-update without --base refuses a local-trunk project'
}

# --- the trunk side ---------------------------------------------------------
trunk_world() {  # <name>: sets TW TH PROJ PROJ2 MAINCODE; a trunk whose tip carries the real bin/
  TW="$TMP_ROOT/$1"; TH="$TW/home"; PROJ="$TH/projects/proj"; PROJ2="$TH/projects/other"
  mkdir -p "$TH/state" "$TH/data" "$TH/config" "$TW/root"
  cp -r "$ROOT/bin" "$TW/root/bin"; ln -s "$ROOT/core" "$TW/root/core"; ln -s "$ROOT/policy" "$TW/root/policy"
  printf '#!/usr/bin/env bash\necho "the home own stale jg-update ran" >&2\nexit 99\n' > "$TW/root/bin/jg-update.sh"
  printf -- '- proj [local-trunk] - fixture (added 2026-11-08)\n- other [local-trunk] - fixture (added 2026-11-08)\n' > "$TH/data/projects.md"
  local p
  for p in "$PROJ" "$PROJ2"; do jg_git_init_commit "$p"; jg_git_add_origin "$p" "$p.origin.git"; done
  git clone -q "$(git -C "$PROJ" remote get-url origin)" "$TW/maincode"
  for p in "$PROJ" "$PROJ2"; do ttrunk init "$p" >/dev/null || fail "trunk init must work"; done
  mkdir -p "$PROJ/bin"; cp -r "$ROOT/bin/." "$PROJ/bin/"; git -C "$PROJ" add bin; git -C "$PROJ" commit -q -m "tip with tools"
  local tip; tip=$(git -C "$PROJ" rev-parse HEAD)
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$tip" "$(git -C "$PROJ" rev-parse trunk)"
  printf '%s\n' "$tip" > "$TH/state/trunk-tip-proj"; printf '%s\n' "$tip" > "$TH/state/trunk-green-proj"
  TIP=$tip
}
ttrunk() { JG_HOME="$TH" JG_ROOT_OVERRIDE="${CODE:-$TW/maincode}" JG_STATE_OVERRIDE="$TH/state" JG_DATA_OVERRIDE="$TH/data" \
  JG_CONFIG_OVERRIDE="$TH/config" JG_STACK_SKIP=1 JG_HOST_WIRING_SKIP=1 "$TW/root/bin/jg-trunk.sh" "$@"; }

test_live_runs_the_exported_tool_and_the_waiver_spends_no_word() {
  local out rc=0
  trunk_world t5
  out=$(ttrunk live "$PROJ" 2>&1) && fail "live must refuse without the captain's word or a waiver: $out"
  assert_contains "$out" "no recorded word from the captain" "no waiver means the word is still needed"
  out=$(ttrunk waiver "$PROJ" 2>&1) && fail "a waiver without the owner rule must refuse"
  out=$(JG_TASK_ID=t1 ttrunk waiver "$PROJ" --rule owner-rule-686826b5 2>&1) && fail "a worker must not write the waiver"
  out=$(ttrunk waiver "$TW/maincode" --rule owner-rule-686826b5 2>&1) && fail "a project that is not registered local-trunk must refuse a waiver"
  ttrunk waiver "$PROJ" --rule owner-rule-686826b5 >/dev/null 2>&1 || fail "the Overwatch path must write the waiver"
  grep -Eq '^proj owner-rule-686826b5 [0-9]+ until=stable$' "$TH/config/trunk-live-waiver" || fail "waiver line format: $(cat "$TH/config/trunk-live-waiver")"
  out=$(ttrunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "live under the waiver must move the home: $out"
  assert_contains "$out" "$TH/state/trunk-live-tool/$TIP/bin/jg-update.sh" "the mover must run from the exported copy of the tip"
  [ "$(git -C "$TW/maincode" rev-parse HEAD)" = "$TIP" ] || fail "Main's code must be at the tip: $out"
  grep -q "waiver=owner-rule-686826b5" "$TH/data/trunk-live.tsv" || fail "the live row must carry the waiver: $(cat "$TH/data/trunk-live.tsv")"
  [ ! -e "$TH/state/trunk-word-live-proj" ] && [ ! -e "$TH/data/trunk-words.tsv" ] || fail "a waiver records and spends no word"
  out=$(ttrunk live "$PROJ2" 2>&1) && fail "a project without a waiver line must still need the word: $out"
  assert_contains "$out" "no recorded word from the captain" "the second project keeps need_word"
  pass 'T5 live runs the exported tool; the waiver spends no word and only its project skips the word'
}

test_the_landing_check_runs_the_batched_live_step_and_reports_it() {
  local fh="$TMP_ROOT/t6/fm" out
  mkdir -p "$fh/state" "$fh/data" "$fh/config" "$fh/bin" "$fh/projects/proj"
  # shellcheck disable=SC2016 # the stub body expands when it runs
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/calls"\ncase "$1" in verify) exit "$(cat "%s/verify-rc")" ;; autolive) printf "autolive: %%s\\n" "$(cat "%s/verdict")"; exit "$(cat "%s/rc")" ;; esac\n' "$fh" "$fh" "$fh" "$fh" > "$fh/bin/jg-trunk.sh"
  chmod +x "$fh/bin/jg-trunk.sh"; cp "$ROOT/bin/jg-wake-lib.sh" "$ROOT/bin/jg-path-lib.sh" "$fh/bin/"
  printf 'project=%s/projects/proj\nmode=local-trunk\n' "$fh" > "$fh/state/t1.meta"
  local c=cccccccccccccccccccccccccccccccccccccccc ob="$fh/data/jg-trunk-landing/outbox"
  post() { bash "$ROOT/core/trunk-landing/trunk-landing.sh" post "$fh" t1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$c" >/dev/null 2>&1; }
  live() { bash "$ROOT/core/trunk-landing/trunk-landing.sh" live "$fh" proj >/dev/null 2>&1; }
  # The post-landing job runs the suite and never the live step: a landing never waits on a go-live.
  printf '0\n' > "$fh/verify-rc"; post
  [ "$(cat "$fh/calls")" = verify ] || fail "the post-landing job must run the suite only: $(cat "$fh/calls")"
  printf '1\n' > "$fh/verify-rc"; post
  assert_contains "$(cat "$ob")" "t1: the whole suite is red at cccccccccccc" "a red suite is reported and nothing goes live"
  # The live job reports a go-live and a failed move, a new hold once, and nothing for waiting, already live or no waiver.
  : > "$fh/calls"; : > "$ob"; printf '0\n' > "$fh/rc"
  printf 'live at abc on every home (0 skipped, see data/trunk-live.tsv)\n' > "$fh/verdict"; live
  assert_contains "$(cat "$ob")" "proj: live at abc on every home" "a go-live is reported"
  : > "$ob"; printf 'the move failed: hook\n' > "$fh/verdict"; printf '3\n' > "$fh/rc"; live
  assert_contains "$(cat "$ob")" "proj: NOT live: the move failed: hook" "a failed move is reported"
  : > "$ob"; printf '0\n' > "$fh/rc"
  for out in 'waiting: live in about 9 min (quiet 20 min, cap 60 min)' 'already live at abc' "not live: it needs the captain's word (no go-live waiver for proj)"; do
    printf '%s\n' "$out" > "$fh/verdict"; live
  done
  [ ! -s "$ob" ] || fail "waiting, already live and no waiver add no line: $(cat "$ob")"
  printf 'NOT live, held: the trunk is red at abc; every home stays on the last green commit\n' > "$fh/verdict"; live; live
  [ "$(grep -c "held: the trunk is red" "$ob")" = 1 ] || fail "a hold is reported once: $(cat "$ob")"
  pass 'T6 the landing check runs the suite after a landing and the batched live step on its own, and reports their outcomes'
}

test_every_home_moves_or_is_skipped_with_one_row
test_cache_is_cleared_after_a_move
test_home_moves_one_canary_only
test_failed_health_pins_the_home_back_and_stops
test_a_local_trunk_project_is_refused_without_base
test_live_runs_the_exported_tool_and_the_waiver_spends_no_word
test_the_landing_check_runs_the_batched_live_step_and_reports_it
printf 'jg-update-local-base: ok\n'
