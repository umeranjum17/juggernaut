#!/usr/bin/env bash
# Integration test for the fleet live move (slice ap-t2-fleet-live-move): bin/jg-update.sh --base <sha>,
# `jg-trunk.sh live` / `waiver`, and the landing check's auto-live, against real git repositories.
#
# T1 One move, one row per home: a clean detached lead behind the tip fast-forwards, a clean lead whose HEAD is
#    not an ancestor but whose content the tip holds is re-pointed by `reset --keep` (row says re-pointed-from),
#    a dirty lead and a lead holding an uncontained commit are SKIPPED with the reason and not touched, Main
#    moves last with a restart-pending marker, and a pool worktree on a lane branch is not touched. The move then fails, its
#    last line naming every home not at the base, so a go-live records no `live` row while a home is behind.
# T1c Each home that stands on the moved commit runs its own host wiring for the add-ons whose files changed since it last
#    wired, with the real bin/jg-host-wiring.sh and the real tickets-sync wiring: the installed copy equals core/ after a
#    move that changed it, a move that changed no add-on file runs no wiring, a skipped home is not wired, a wiring failure
#    is named in the home's row and never blocks the move, and a home rolled back by its health check while already on the
#    moved commit (the drift Main hit) is still wired to the code it holds; a pipeline config naming the pre-rename wrapper is
#    migrated by the real pipeline-quota-failover step and every home ends live.
# T1d A go-live run from a lead home reads Main's registry: every lead, the lead itself and Main move, one row each (the
#    fleet's real shape, where the lead's own registry is empty).
# T7 A move that leaves a home behind names it; bin/jg-trunk-live-lag.sh reports a home not at the last go-live after 10 minutes.
# T2 --home moves exactly one lead (the canary) and leaves Main alone.
# T3 A health check that fails on the new commit pins that home back to its recorded pre-move HEAD and the rollout goes on.
# T9 Replay of 08:43:10Z (the fleet moves with no hand): a home whose launch overlay lacks a hook of the installer's set is
#    refreshed and goes live (it was rolled back as stale-overlay and the rollout stopped); a home with a stale watcher beacon
#    before and after the move stays live and reports `pre-existing:stale-beacon`; every home runs its host wiring
#    (state/lead-sweep.check.sh) and the project verdict is clean. A second run: a home whose supervision read fails on the
#    new commit only is rolled back and the rollout goes on past it, a dirty home is skipped, the other homes are live and
#    the next run takes the two that were left once they are clean.
# T3b A home whose shared reference-transaction hook is the trunk guard moves and stays live (the guard chains it); any other
#    hook there refuses the guard install, and the rolled-back row names that refusal.
# T4 A local-trunk project is refused without --base ("update this project from its trunk").
# T5 `jg-trunk.sh live` runs the mover from an export of the tip, never from the home's own bin; the waiver
#    record is written only by the Overwatch path, spends no word and marks the row; a project without a
#    waiver still needs the captain's word.
# T6 The landing check runs no suite after a landing and, under a waiver, runs the batched live step on its own, and reports a go-live,
#    a failed move, a new hold or a home left behind the last go-live; tests/jg-trunk-live.test.sh owns the quiet-window, hourly-cap, red and pin-back journeys.
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
# The fixture homes are bare worktrees (no beacon, overlay or supervision read), so the mover runs from a copy of bin/ whose
# health check passes; bin/jg-home-health.sh has its own test (tests/jg-home-health.test.sh).
stub_health() {  # <bin dir>
  # shellcheck disable=SC2016 # the stub expands its own argument
  printf '#!/usr/bin/env bash\necho "ok $2"\n' > "$1/jg-home-health.sh"; chmod +x "$1/jg-home-health.sh"
}
passing_health_mover() {
  mkdir -p "$W/bin-ok"; cp -r "$ROOT/bin/." "$W/bin-ok/"; stub_health "$W/bin-ok"
  printf '%s\n' "$W/bin-ok/jg-update.sh"
}
run_mover() {  # <extra args>
  local mover=${MOVER:-}
  [ -n "$mover" ] || mover=$(passing_health_mover)
  JG_ROOT_OVERRIDE="$W/main" JG_HOME="$W/home" JG_STACK_SKIP=1 JG_HOST_WIRING_SKIP=1 \
    "$mover" --base "$C2" --project "$W/proj" --branch trunk "$@" 2>&1
}
head_of() { git -C "$W/$1" rev-parse HEAD; }
row_of() { awk -F'\t' -v k="proj:$1" '$1 == k' "$W/home/data/trunk-live.tsv"; }

test_every_home_moves_or_is_skipped_with_one_row() {
  local out rows rc=0
  mover_world t1
  out=$(run_mover) || rc=$?
  [ "$rc" -ne 0 ] || fail "a move that leaves a home behind must fail: $out"
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "fleet: not every home is at ${C2:0:12}: lead-dirty lead-unlanded" ] || fail "the last line must name the homes left behind: $out"
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

# A lead whose HEAD is a divergence the tip holds, left half-moved (index and tree already at the tip, HEAD behind), finishes
# the move; the same lead with an extra untracked file keeps the refusal and loses nothing.
test_a_half_moved_lead_finishes_its_move() {
  local out
  mover_world t1h
  git -C "$W/lead-repoint" fetch -q "$W/proj" trunk
  git -C "$W/lead-repoint" read-tree -u -m HEAD "$C2" || fail "fixture: cannot stage the tip"
  [ "$(git -C "$W/lead-repoint" write-tree)" = "$(git -C "$W/proj" rev-parse "$C2^{tree}")" ] || fail "fixture: index must equal the tip tree"
  git -C "$W/lead-ff" fetch -q "$W/proj" trunk
  git -C "$W/lead-ff" checkout -q --detach "$X" 2>/dev/null || :
  git -C "$W/lead-ff" read-tree -u -m HEAD "$C2" || fail "fixture: cannot stage the tip"
  printf 'mine\n' > "$W/lead-ff/note.txt"
  out=$(run_mover) || :
  [ "$(head_of lead-repoint)" = "$C2" ] || fail "a half-moved lead must reach the tip: $out"
  git -C "$W/lead-repoint" diff --quiet HEAD || fail "the finished lead must hold no change against the tip"
  [ "$(row_of lead-repoint | cut -f4)" = "live,re-pointed-from:${X:0:12}" ] || fail "the row must say re-pointed: $(row_of lead-repoint)"
  [ "$(head_of lead-ff)" != "$C2" ] || fail "a half-moved lead with an untracked file must not move"
  [ -f "$W/lead-ff/note.txt" ] || fail "the untracked file must be kept"
  pass 'T1h a half-moved lead (index and tree at the tip) finishes its move; an extra untracked file keeps the refusal'
}

test_cache_is_cleared_after_a_move() {
  mover_world t1b
  mkdir -p "$W/home/state/squad-lead-summary-cache"; : > "$W/home/state/squad-lead-summary-cache/old.json"
  run_mover >/dev/null || :  # two leads are skipped, so the move exits 1; the homes that did move still clear the cache
  [ ! -e "$W/home/state/squad-lead-summary-cache/old.json" ] || fail "a move must clear the lead summary cache"
  pass 'T1b the lead summary cache is cleared after a move'
}

# A trunk tip that carries the real host wiring entry point and the real tickets-sync add-on; every other step of the plan
# is a stub that logs "<step> <home>" and installs nothing. bin/jg-check-register.sh is a stub, since registering a check
# needs a watcher home. Sets TIP.
wiring_tip() {
  local name
  git -C "$W/proj" checkout -q trunk
  mkdir -p "$W/proj/bin" "$W/proj/core/tickets-sync/icons"
  cp "$ROOT/bin/jg-host-wiring.sh" "$ROOT/bin/jg-lab-home-lib.sh" "$W/proj/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/proj/bin/jg-check-register.sh"; chmod +x "$W/proj/bin/jg-check-register.sh"
  cp "$ROOT"/core/tickets-sync/*.py "$ROOT/core/tickets-sync/wiring.sh" "$W/proj/core/tickets-sync/"
  cp "$ROOT"/core/tickets-sync/icons/* "$W/proj/core/tickets-sync/icons/"
  while IFS=$'\t' read -r name _; do
    [ "$name" != tickets-sync ] || continue
    if [ "$name" = machines ]; then mkdir -p "$W/proj/core/machines"; printf '#!/usr/bin/env bash\nexit 0\n' > "$W/proj/core/machines/view.sh"; continue; fi
    mkdir -p "$W/proj/core/$name"
    # shellcheck disable=SC2016 # the stub expands its own variables when it runs
    printf '#!/usr/bin/env bash\n[ "${1:-}" != --dry-run ] || exit 0\nprintf "%%s %%s\\n" %s "$JG_HOME" >> "$JG_TEST_WIRING_LOG"\n' "$name" > "$W/proj/core/$name/wiring.sh"
  done < <("$ROOT/bin/jg-host-wiring.sh" --list)
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "owner-guard-scan %%s\\n" "$JG_HOME" >> "$JG_TEST_WIRING_LOG"\n' > "$W/proj/core/owner-guard/install-scan.sh"
  git -C "$W/proj" add bin core; git -C "$W/proj" commit -q -m "tip with the host wiring"
  git -C "$W/proj" checkout -q main; TIP=$(git -C "$W/proj" rev-parse trunk)
}
trunk_commit() {  # <file> <line> <message>: append a line to a trunk file; sets TIP
  git -C "$W/proj" checkout -q trunk; printf '%s\n' "$2" >> "$W/proj/$1"
  git -C "$W/proj" commit -q -am "$3"; git -C "$W/proj" checkout -q main; TIP=$(git -C "$W/proj" rev-parse trunk)
}
wire_move() {  # <mover> [<extra args>]: move every home to TIP with the wiring on, in a throwaway user home
  local mover=$1; shift
  env -u JG_HOST_WIRING_SKIP JG_ROOT_OVERRIDE="$W/main" JG_HOME="$W/home" JG_STACK_SKIP=1 JG_TEST_WIRING_LOG="$W/wiring.log" \
    HOME="$W/user" XDG_DATA_HOME="$W/user/.local/share" XDG_CONFIG_HOME="$W/user/.config" \
    "$mover" --base "$TIP" --project "$W/proj" --branch trunk "$@" 2>&1
}
installed_equals_core() {  # <home dir>: every installed tickets-sync file equals that home's core/ copy
  local f
  for f in "$1"/core/tickets-sync/*.py; do
    cmp -s "$f" "$W/user/.local/share/jg-tickets-sync/tickets-sync/${f##*/}" || return 1
  done
}
last_row_of() { row_of "$1" | tail -n 1; }
two_skipped() {  # <output> <rc>: the move's only verdict is the two leads the fixture always skips
  [ "$2" -eq 1 ] && [ "$(printf '%s\n' "$1" | tail -n 1)" = "fleet: not every home is at ${TIP:0:12}: lead-dirty lead-unlanded" ]
}

test_a_move_rewires_only_the_add_ons_it_changed_and_names_a_failure() {
  local out rc=0 ok lines
  mover_world t1c
  ok=$(passing_health_mover)
  wiring_tip
  : > "$W/wiring.log"

  # First move: no home has a wiring record, so every step runs in each home that moved, and the copy equals core/.
  rc=0; out=$(wire_move "$ok") || rc=$?
  two_skipped "$out" "$rc" || fail "the first move must leave only the two skipped leads behind: rc=$rc $out"
  grep -q " $W/lead-ff\$" "$W/wiring.log" || fail "a lead with no wiring record must wire every step: $out"
  grep -q " $W/main\$" "$W/wiring.log" || fail "Main with no wiring record must wire every step: $out"
  ! grep -q "lead-dirty\|lead-unlanded" "$W/wiring.log" || fail "a skipped home must not be wired"
  installed_equals_core "$W/lead-ff" || fail "the installed tickets-sync copy must equal core/ after the first move: $out"
  [ "$(awk -F'\t' '$1 == "tickets-sync" { print $2 }' "$W/lead-ff/state/host-wiring.tsv")" = "$TIP" ] || fail "the home must record the commit tickets-sync wired from"

  # An add-on file changes in the move: only that add-on is wired again, and its installed copy follows core/.
  : > "$W/wiring.log"
  trunk_commit core/tickets-sync/sync.py '# the landed no-store fix' "tickets-sync change"
  rc=0; out=$(wire_move "$ok") || rc=$?
  two_skipped "$out" "$rc" || fail "the tickets-sync move must leave only the two skipped leads behind: rc=$rc $out"
  installed_equals_core "$W/lead-ff" || fail "the installed copy must equal the lead's core/ after a move that changed it: $out"
  installed_equals_core "$W/main" || fail "the installed copy must equal Main's core/ after a move that changed it: $out"
  grep -q 'the landed no-store fix' "$W/user/.local/share/jg-tickets-sync/tickets-sync/sync.py" || fail "the installed sync.py must carry the change"
  [ ! -s "$W/wiring.log" ] || fail "a move that changed only tickets-sync must run no other step: $(cat "$W/wiring.log")"
  assert_contains "$out" "jg-host-wiring: 1 steps wired" "only the changed add-on is wired"

  # A move that changes no add-on file runs no wiring.
  trunk_commit a.txt more "not an add-on"
  rc=0; out=$(wire_move "$ok") || rc=$?
  two_skipped "$out" "$rc" || fail "a move with no add-on change must leave only the two skipped leads behind: rc=$rc $out"
  [ ! -s "$W/wiring.log" ] || fail "a move that changed no add-on file must run no wiring: $(cat "$W/wiring.log")"
  assert_contains "$out" "jg-host-wiring: 0 steps wired" "no step runs when no add-on changed"
  [ "$(last_row_of lead-ff | cut -f4)" = live ] || fail "a move with nothing to wire keeps a plain live row: $(last_row_of lead-ff)"

  # A wiring failure is named in the move row, never blocks the move, and the failed step is retried on the next move.
  trunk_commit core/fleet-flow/wiring.sh 'echo "fleet-flow: refused: no install dir" >&2; exit 1' "break one wiring"
  rc=0; out=$(wire_move "$ok") || rc=$?
  two_skipped "$out" "$rc" || fail "a wiring failure must not add a home to the move's verdict: rc=$rc $out"
  [ "$(head_of lead-ff)" = "$TIP" ] || fail "a wiring failure must not undo the move"
  [ "$(last_row_of lead-ff | cut -f4)" = "live,wiring-failed:fleet-flow" ] || fail "the row must name the failed step: $(last_row_of lead-ff)"
  [ "$(last_row_of primary | cut -f4)" = "live,wiring-failed:fleet-flow" ] || fail "Main's row must name the failed step: $(last_row_of primary)"
  trunk_commit a.txt again "not an add-on either"
  rc=0; out=$(wire_move "$ok") || rc=$?
  two_skipped "$out" "$rc" || fail "the next move must leave only the two skipped leads behind: rc=$rc $out"
  [ "$(last_row_of lead-ff | cut -f4)" = "live,wiring-failed:fleet-flow" ] || fail "a failed step has no record, so the next move retries it: $(last_row_of lead-ff)"

  # The drift Main hit: the home already holds an add-on change it never wired (its code moved without the wiring), and
  # its health check fails, so the move rolls it back to the commit it already stands on. It is still wired.
  trunk_commit core/tickets-sync/ticket.py '# a second landed fix' "tickets-sync change, unwired"
  rc=0; out=$(env JG_HOST_WIRING_SKIP=1 JG_ROOT_OVERRIDE="$W/main" JG_HOME="$W/home" JG_STACK_SKIP=1 HOME="$W/user" \
    XDG_DATA_HOME="$W/user/.local/share" "$ok" --base "$TIP" --project "$W/proj" --branch trunk 2>&1) || rc=$?
  two_skipped "$out" "$rc" || fail "the unwired move must leave only the two skipped leads behind: rc=$rc $out"
  installed_equals_core "$W/lead-ff" && fail "the fixture must start with a copy that lags core/"
  mkdir -p "$W/bin-bad"; cp -r "$ROOT/bin/." "$W/bin-bad/"
  printf '#!/usr/bin/env bash\necho "missing-guard: no home guard hook" >&2\nexit 1\n' > "$W/bin-bad/jg-home-health.sh"; chmod +x "$W/bin-bad/jg-home-health.sh"
  out=$(wire_move "$W/bin-bad/jg-update.sh") || true
  lines=$(last_row_of lead-ff | cut -f4)
  case $lines in rolled-back:*) ;; *) fail "the failed health check must roll the home back: $lines" ;; esac
  [ "$(head_of lead-ff)" = "$TIP" ] || fail "the home must stay on the commit it already held"
  installed_equals_core "$W/lead-ff" || fail "a home rolled back onto the moved commit must still be wired to the code it holds: $out"

  # The failure every move hit after the rename: the pipeline config names the wrapper the pre-rename installer wrote. The
  # real pipeline-quota-failover step moves the key to the current wrapper on the first home, finds it current on the rest,
  # and every home ends live with no failed step.
  git -C "$W/proj" checkout -q trunk
  cp "$ROOT/core/pipeline-quota-failover/wiring.sh" "$ROOT/core/pipeline-quota-failover/pi-quota-failover" "$W/proj/core/pipeline-quota-failover/"
  # The step broken above is mended, so the row can only name this one.
  sed '$d' "$W/proj/core/fleet-flow/wiring.sh" > "$W/fleet-flow.sh" && mv -f "$W/fleet-flow.sh" "$W/proj/core/fleet-flow/wiring.sh"
  git -C "$W/proj" add core; git -C "$W/proj" commit -q -m "the real pipeline-quota-failover step"; git -C "$W/proj" checkout -q main
  TIP=$(git -C "$W/proj" rev-parse trunk)
  printf 'agent_path_override:\n  pi: %s\n' "$W/user/.local/share/fm-pipeline-quota-failover/pi-quota-failover" > "$W/user/pipeline.yaml"
  rc=0; out=$(NM_CONFIG="$W/user/pipeline.yaml" wire_move "$ok") || rc=$?
  two_skipped "$out" "$rc" || fail "the legacy-config move must leave only the two skipped leads behind: rc=$rc $out"
  [ "$(last_row_of lead-ff | cut -f4)" = live ] && [ "$(last_row_of primary | cut -f4)" = live ] \
    || fail "a pre-rename pipeline wrapper must not fail the move: $(last_row_of lead-ff) / $(last_row_of primary)"
  [ "$(sed -n 's/^  pi: //p' "$W/user/pipeline.yaml")" = "$W/user/.local/share/jg-pipeline-quota-failover/pi-quota-failover" ] \
    || fail "the move must leave the key on the current wrapper: $(cat "$W/user/pipeline.yaml")"
  assert_contains "$out" "moved key agent_path_override.pi from the pre-rename" "the first home migrates the key"
  pass 'T1c a move wires only the add-ons it changed, the copy equals core/, a failure is named in the row, a rolled-back home on the moved commit is wired, a pre-rename pipeline wrapper is migrated'
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

test_failed_health_pins_the_home_back_and_the_rollout_goes_on() {
  local out rc=0
  mover_world t3
  mkdir -p "$W/bin"; cp -r "$ROOT/bin/." "$W/bin/"
  # The health check fails on the new commit only: the pre-move read (no commit named) is healthy.
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/usr/bin/env bash\n[ -n "${3:-}" ] || { echo "ok $2"; exit 0; }\necho "overlay stale" >&2\nexit 1\n' > "$W/bin/jg-home-health.sh"; chmod +x "$W/bin/jg-home-health.sh"
  out=$(MOVER="$W/bin/jg-update.sh" run_mover) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed health check must fail the move: $out"
  [ "$(head_of lead-ff)" = "$C0" ] || fail "the failed home must be pinned back to its pre-move HEAD"
  [ "$(row_of lead-ff | cut -f4)" = "rolled-back:overlay stale" ] || fail "the row says rolled-back:<reason>: $(row_of lead-ff)"
  [ "$(row_of lead-repoint | cut -f4)" = "rolled-back:overlay stale" ] && [ "$(row_of primary | cut -f4)" = "rolled-back:overlay stale" ] \
    || fail "the rollout must go on to the homes after the failed one, each judged on its own: $(row_of lead-repoint) / $(row_of primary)"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "lead-ff lead-repoint lead-dirty lead-unlanded primary" "the verdict must name every home left behind, rolled back or skipped"
  pass 'T3 a health check that fails on the new commit pins that home back and the rollout goes on'
}

test_a_refused_guard_install_is_named_in_the_row() {
  local out rc=0 kind
  # The homes share one repository whose reference-transaction hook another owner already holds. The trunk guard (the fleet's
  # shape, where Main's home is also the local-trunk project) is chained and the move stands; any other hook refuses the install,
  # and the row says why.
  for kind in trunk other; do
    rc=0
    mover_world "t3b-$kind"
    case $kind in
      trunk) printf '#!/bin/sh\n# managed by bin/jg-trunk.sh: only the lander moves the trunk, and only forward\nexit 0\n' ;;
      other) printf '#!/bin/sh\nexit 0\n' ;;
    esac > "$W/main/.git/hooks/reference-transaction"
    chmod +x "$W/main/.git/hooks/reference-transaction"
    mkdir -p "$W/bin"; cp -r "$ROOT/bin/." "$W/bin/"
    # shellcheck disable=SC2016 # the stub makes the health check's own guard read, and expands its variables when it runs
    printf '#!/usr/bin/env bash\nout=$("$(dirname "$0")/jg-home-guard.sh" check "$2" 2>&1) || { echo "missing-guard: $out"; exit 1; }\necho "ok $2"\n' > "$W/bin/jg-home-health.sh"
    chmod +x "$W/bin/jg-home-health.sh"
    out=$(MOVER="$W/bin/jg-update.sh" run_mover) || rc=$?
    if [ "$kind" = trunk ]; then
      [ "$(row_of lead-ff | cut -f4)" = live ] && [ "$(row_of primary | cut -f4)" = live ] \
        || fail "a home whose hook is the trunk guard must move and stay live: $(row_of lead-ff) / $(row_of primary)"
      [ -x "$W/main/.git/hooks/reference-transaction.chained" ] || fail "the trunk guard must be kept in the chained slot"
      continue
    fi
    [ "$rc" -ne 0 ] || fail "a home with no guard must fail the move: $out"
    [ "$(row_of lead-ff | cut -f4)" = "rolled-back:missing-guard: the guard install refused: $W/main/.git/hooks/reference-transaction is not the home guard; move it aside so the home can be guarded" ] \
      || fail "the row must name why the guard is missing, not only that it is: $(row_of lead-ff)"
  done
  pass 'T3b a home holding the trunk guard moves with both hooks; any other hook refuses the guard install, named in the rolled-back row'
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

# A lead home that owns the trunk: Main (a clone that is also its home, holding the registry) and three leads, one of them the
# home that runs the move. This is the real fleet's shape: the runner's own registry is empty, Main's names everyone.
lead_world() {  # <name>: sets W MAIN SELF C0 C2
  W="$TMP_ROOT/$1"; MAIN="$W/main"; SELF="$W/lead-self"; mkdir -p "$W"
  git init -q -b main "$W/proj"; commit_file "$W/proj" AGENTS.md v1 c0; commit_file "$W/proj" bin/tool.sh a c0b
  git clone -q "$W/proj" "$MAIN"
  git -C "$W/proj" checkout -q -b trunk; commit_file "$W/proj" a.txt alpha c1; commit_file "$W/proj" b.txt beta c2; git -C "$W/proj" checkout -q main
  C0=$(git -C "$MAIN" rev-parse HEAD); C2=$(git -C "$W/proj" rev-parse trunk)
  printf 'state/\ndata/\nconfig/\n.jg-squad-lead-home\n.jg-squad-lead-parent\n' >> "$MAIN/.git/info/exclude"; mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config"
  local id
  for id in lead-a lead-b lead-self; do
    git -C "$MAIN" worktree add -q --detach "$W/$id" "$C0"; printf '%s\n' "$id" > "$W/$id/.jg-squad-lead-home"
    printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$W/$id/.jg-squad-lead-parent"
    mkdir -p "$W/$id/state" "$W/$id/data" "$W/$id/config"
    printf -- '- %s - fixture (home: %s; scope: x; projects: proj; added 2026-11-09)\n' "$id" "$W/$id" >> "$MAIN/data/squad_leads.md"
  done
}
run_from_self() {  # <script> <args>: as the lead home that owns the trunk runs it
  local script=$1; shift
  JG_HOME="$SELF" JG_ROOT_OVERRIDE="$SELF" JG_STACK_SKIP=1 JG_HOST_WIRING_SKIP=1 "$script" "$@" 2>&1
}

test_a_go_live_run_from_a_lead_home_moves_every_home() {
  local out rc=0 id
  lead_world t1d
  out=$(run_from_self "$(passing_health_mover)" --base "$C2" --project "$W/proj" --branch trunk) || rc=$?
  [ "$rc" -eq 0 ] || fail "a move from a lead home must succeed when every home can move: $out"
  for id in lead-a lead-b lead-self main; do [ "$(git -C "$W/$id" rev-parse HEAD)" = "$C2" ] || fail "$id must be at the base, not left behind: $out"; done
  [ "$(cut -d$'\t' -f1 "$SELF/data/trunk-live.tsv" | paste -sd' ' -)" = "proj:lead-a proj:lead-b proj:lead-self proj:primary" ] \
    || fail "one row per home, Main last: $(cat "$SELF/data/trunk-live.tsv")"
  assert_contains "$(cat "$MAIN/state/trunk-live-restart-pending" 2>/dev/null)" "$C2" "Main, not the lead, gets the restart-pending marker"
  [ ! -e "$SELF/state/trunk-live-restart-pending" ] || fail "the lead home's own state is not Main's"
  pass 'T1d a move run from a lead home reads Main'"'"'s registry and moves every lead, itself and Main, one row each'
}

test_a_home_left_behind_is_named_and_the_lag_check_reports_it() {
  local out rc=0 lag="$ROOT/bin/jg-trunk-live-lag.sh" now
  lead_world t7; now=$(date +%s)
  printf 'proj\t%s\t%s\tlive\n' "$C2" "$((now - 1200))" > "$SELF/data/trunk-live.tsv"
  out=$(run_from_self "$lag" "$W/proj") || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "lag: homes not at the last go-live ${C2:0:12}: lead-a lead-b lead-self primary" ] || fail "every home is behind a 20 minute old go-live: rc=$rc $out"
  printf 'proj\t%s\t%s\tlive\n' "$C2" "$((now - 60))" > "$SELF/data/trunk-live.tsv"
  out=$(run_from_self "$lag" "$W/proj") || fail "a go-live under 10 minutes old is not a lag: $out"
  [ -z "$out" ] || fail "no lag line inside the 10 minutes: $out"
  printf 'proj\t%s\t%s\tlive\n' "$C2" "$((now - 1200))" > "$SELF/data/trunk-live.tsv"; rc=0
  printf 'edit\n' >> "$W/lead-b/AGENTS.md"
  out=$(run_from_self "$(passing_health_mover)" --base "$C2" --project "$W/proj" --branch trunk) || rc=$?
  [ "$rc" -ne 0 ] || fail "a dirty home must fail the move: $out"
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "fleet: not every home is at ${C2:0:12}: lead-b" ] || fail "the failed move names the home left behind: $out"
  out=$(run_from_self "$lag" "$W/proj") && fail "a home left behind must be a lag: $out"
  [ "$out" = "lag: homes not at the last go-live ${C2:0:12}: lead-b" ] || fail "only the home left behind is named: $out"
  git -C "$W/lead-b" checkout -q -- AGENTS.md; run_from_self "$(passing_health_mover)" --base "$C2" --project "$W/proj" --branch trunk >/dev/null || fail "the move must finish once the home is clean"
  out=$(run_from_self "$lag" "$W/proj") || fail "no lag once every home is at the commit: $out"
  pass 'T7 a home left behind is named on the failed move, and the lag check reports it after 10 minutes and clears when it catches up'
}

# --- a bad home does not stop the fleet --------------------------------------
# fleet_tip <dir>: a tip tree with the real wiring entry point and the real lead-sweep add-on, every other step a no-op stub, and a
# supervision read that fails in a home holding state/fail-on-the-new-commit (the old commit's read never looks at it).
fleet_tip() {
  local d=$1 name
  mkdir -p "$d/bin" "$d/core/owner-guard"
  cp "$ROOT/bin/jg-host-wiring.sh" "$ROOT/bin/jg-lab-home-lib.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/jg-check-register.sh"; chmod +x "$d/bin/jg-check-register.sh"
  # shellcheck disable=SC2016 # the read expands its own variables when it runs
  printf '#!/usr/bin/env bash\n[ ! -e "$JG_HOME/state/fail-on-the-new-commit" ]\n' > "$d/bin/jg-supervision-instructions.sh"
  while IFS=$'\t' read -r name _; do
    if [ "$name" = lead-sweep ]; then cp -r "$ROOT/core/lead-sweep" "$d/core/"; continue; fi
    if [ "$name" = machines ]; then mkdir -p "$d/core/machines"; printf '#!/usr/bin/env bash\nexit 0\n' > "$d/core/machines/view.sh"; continue; fi
    mkdir -p "$d/core/$name"; printf '#!/usr/bin/env bash\nexit 0\n' > "$d/core/$name/wiring.sh"
  done < <("$ROOT/bin/jg-host-wiring.sh" --list)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/core/owner-guard/install-scan.sh"
}
# fleet_world <name> <leads>: sets W TIP C0. Main and the leads stand on an old commit whose supervision read always passes,
# each with a fresh watcher beacon; the trunk tip carries the wiring.
fleet_world() {
  local id i
  W="$TMP_ROOT/$1"; mkdir -p "$W/home/state" "$W/home/data" "$W/home/config"
  git init -q -b main "$W/proj"
  commit_file "$W/proj" AGENTS.md v1 c0; mkdir -p "$W/proj/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/proj/bin/jg-supervision-instructions.sh"; chmod +x "$W/proj/bin/jg-supervision-instructions.sh"
  git -C "$W/proj" add bin; git -C "$W/proj" commit -q -m "old supervision read"
  git clone -q "$W/proj" "$W/main"
  git -C "$W/proj" checkout -q -b trunk; fleet_tip "$W/proj"; git -C "$W/proj" add bin core; git -C "$W/proj" commit -q -m "tip with the wiring"
  git -C "$W/proj" checkout -q main
  C0=$(git -C "$W/main" rev-parse HEAD); TIP=$(git -C "$W/proj" rev-parse trunk)
  mkdir -p "$W/main/state"; touch "$W/main/state/.last-watcher-beat"
  for ((i = 1; i <= $2; i++)); do
    id=lead-$i
    git -C "$W/main" worktree add -q --detach "$W/$id" "$C0"; printf '%s\n' "$id" > "$W/$id/.jg-squad-lead-home"
    printf -- '- %s - fixture (home: %s; scope: x; projects: proj; added 2026-11-10)\n' "$id" "$W/$id" >> "$W/home/data/squad_leads.md"
    mkdir -p "$W/$id/state"; touch "$W/$id/state/.last-watcher-beat"
  done
}
# grace_now: the beacon grace the health check will derive. The load, the CPU count and the poll are fixed outright (a caller's
# JG_HOST_LOAD, JG_HOST_CPUS or JG_POLL is overridden), so the grace is always 300 s and cannot drift with the host.
export JG_HOST_LOAD=1 JG_HOST_CPUS=1 JG_POLL=15
# shellcheck source=/dev/null
grace_now() { ( . "$ROOT/bin/jg-wake-lib.sh"; jg_poll_derived_grace ); }
# fleet_move: the move to TIP with the real health check and the real wiring, in a throwaway user home.
fleet_move() {
  env -u JG_HOST_WIRING_SKIP JG_ROOT_OVERRIDE="$W/main" JG_HOME="$W/home" JG_STACK_SKIP=1 \
    HOME="$W/user" XDG_DATA_HOME="$W/user/.local/share" XDG_CONFIG_HOME="$W/user/.config" \
    "$ROOT/bin/jg-update.sh" --base "$TIP" --project "$W/proj" --branch trunk 2>&1
}

test_the_fleet_moves_past_a_home_with_an_old_fault() {
  local out rc=0 id
  fleet_world t9 3
  # lead-1: a launch overlay written by an older installer (no reference-transaction hook) and no task record for it.
  "$ROOT/bin/jg-git-strip-ai-trailers.sh" install "$W/lead-1/state/old.git-hooks" "$W/lead-1" >/dev/null || fail "overlay install"
  chmod u+w "$W/lead-1/state/old.git-hooks"; rm -f "$W/lead-1/state/old.git-hooks/reference-transaction"; chmod 500 "$W/lead-1/state/old.git-hooks"
  # lead-2: its watcher beat is older than the grace before the move and still is after it (the lead home of 09:37:55Z).
  # The grace stretches with host load (jg_host_load_scale), so the age is read from the same derivation, 138 s past it.
  touch -d "$(( $(grace_now) + 138 )) seconds ago" "$W/lead-2/state/.last-watcher-beat"
  out=$(fleet_move) || rc=$?
  [ "$rc" -eq 0 ] || fail "a fleet with an old overlay and an old beacon fault must move whole (rc=$rc): $out"
  for id in "$W/lead-1" "$W/lead-2" "$W/lead-3" "$W/main"; do
    [ "$(git -C "$id" rev-parse HEAD)" = "$TIP" ] || fail "$id must stand on the tip: $out"
    [ -f "$id/state/lead-sweep.check.sh" ] || fail "$id must be wired (state/lead-sweep.check.sh): $out"
  done
  [ "$(row_of lead-1 | cut -f4)" = live ] || fail "the home with the old overlay is refreshed and live: $(row_of lead-1)"
  [ -x "$W/lead-1/state/old.git-hooks/reference-transaction" ] || fail "the launch overlay must gain the hook it lacked"
  [ "$(row_of lead-2 | cut -f4)" = "live,pre-existing:stale-beacon" ] || fail "an old beacon fault is kept and named: $(row_of lead-2)"
  assert_contains "$out" "health fault kept from before the move: stale-beacon" "the kept fault must be reported in one line"
  [ "$(row_of lead-3 | cut -f4)" = live ] && [ "$(row_of primary | cut -f4)" = live ] || fail "the healthy homes are live: $(row_of lead-3) / $(row_of primary)"
  case $(printf '%s\n' "$out" | tail -n 1) in fleet:*) fail "the project verdict must be clean: $out" ;; esac

  # A second fleet: a read that fails on the new commit only (lead-2), a dirty home (lead-3).
  fleet_world t9b 3
  touch "$W/lead-2/state/fail-on-the-new-commit"
  printf 'edit\n' >> "$W/lead-3/AGENTS.md"
  rc=0; out=$(fleet_move) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fleet with a home left behind must report it: $out"
  [ "$(git -C "$W/lead-1" rev-parse HEAD)" = "$TIP" ] && [ "$(row_of lead-1 | cut -f4)" = live ] || fail "lead-1 is live: $(row_of lead-1)"
  [ "$(git -C "$W/main" rev-parse HEAD)" = "$TIP" ] && [ "$(row_of primary | cut -f4)" = live ] || fail "Main, after both, is live: $(row_of primary)"
  [ "$(git -C "$W/lead-2" rev-parse HEAD)" = "$C0" ] || fail "a fault the old commit did not have pins that home back: $(row_of lead-2)"
  case $(row_of lead-2 | cut -f4) in rolled-back:slow-session-start*) ;; *) fail "the row names the new fault: $(row_of lead-2)" ;; esac
  [ "$(row_of lead-3 | cut -f4)" = skipped:dirty ] && [ "$(git -C "$W/lead-3" rev-parse HEAD)" = "$C0" ] || fail "the dirty home is skipped untouched: $(row_of lead-3)"
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "fleet: not every home is at ${TIP:0:12}: lead-2 lead-3" ] || fail "the verdict names the two homes left: $out"
  # The next run: both are clean and the whole fleet is on the tip (the two homes are tried again, nothing was forced).
  rm -f "$W/lead-2/state/fail-on-the-new-commit"; git -C "$W/lead-3" checkout -q -- AGENTS.md
  rc=0; out=$(fleet_move) || rc=$?
  [ "$rc" -eq 0 ] || fail "the next run must take the homes left behind (rc=$rc): $out"
  [ "$(git -C "$W/lead-2" rev-parse HEAD)" = "$TIP" ] && [ "$(git -C "$W/lead-3" rev-parse HEAD)" = "$TIP" ] || fail "both homes stand on the tip after the next run"
  pass 'T9 an old overlay is refreshed, an old beacon fault is kept and named, a new fault rolls back only that home, the rollout goes on and the next run takes the rest'
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
  mkdir -p "$PROJ/bin"; cp -r "$ROOT/bin/." "$PROJ/bin/"; stub_health "$PROJ/bin"; git -C "$PROJ" add bin; git -C "$PROJ" commit -q -m "tip with tools"
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
  mkdir -p "$fh/state" "$fh/data/jg-trunk-landing" "$fh/config" "$fh/bin" "$fh/projects/proj"
  # shellcheck disable=SC2016 # the stub body expands when it runs
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/calls"\ncase "$1" in autolive) printf "autolive: %%s\\n" "$(cat "%s/verdict")"; exit "$(cat "%s/rc")" ;; esac\n' "$fh" "$fh" "$fh" > "$fh/bin/jg-trunk.sh"
  chmod +x "$fh/bin/jg-trunk.sh"; cp "$ROOT/bin/jg-wake-lib.sh" "$ROOT/bin/jg-path-lib.sh" "$fh/bin/"
  local rc=0 ob="$fh/data/jg-trunk-landing/outbox"
  live() { bash "$ROOT/core/trunk-landing/trunk-landing.sh" live "$fh" proj >/dev/null 2>&1; }
  # No job follows a landing to run the whole suite on this machine: it runs once, on the release pull request in GitHub CI.
  bash "$ROOT/core/trunk-landing/trunk-landing.sh" post "$fh" t1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && [ ! -e "$fh/calls" ] || fail "the landing check must have no post-landing suite job (exit $rc, calls: $(cat "$fh/calls" 2>/dev/null))"
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
  # A home behind the last go-live (the lag script's one line) is reported once per set of homes, and again after it clears and returns.
  printf '#!/usr/bin/env bash\ncat "%s/lag" 2>/dev/null\n' "$fh" > "$fh/bin/jg-trunk-live-lag.sh"; chmod +x "$fh/bin/jg-trunk-live-lag.sh"
  : > "$ob"; printf 'waiting: live in about 9 min\n' > "$fh/verdict"
  printf 'lag: homes not at the last go-live abc: lead-b\n' > "$fh/lag"; live; live
  [ "$(grep -c "proj: lag: homes not at the last go-live abc: lead-b" "$ob")" = 1 ] || fail "a lagging home is reported once: $(cat "$ob")"
  printf 'lag: homes not at the last go-live abc: lead-b lead-c\n' > "$fh/lag"; live
  [ "$(grep -c "proj: lag: " "$ob")" = 2 ] || fail "a new set of lagging homes is reported: $(cat "$ob")"
  rm "$fh/lag"; live; printf 'lag: homes not at the last go-live abc: lead-b lead-c\n' > "$fh/lag"; live
  [ "$(grep -c "proj: lag: " "$ob")" = 3 ] || fail "a lag that clears and returns is reported again: $(cat "$ob")"
  pass 'T6 the landing check runs no suite after a landing, runs the batched live step on its own, and reports its outcomes'
}

test_guarded_primary_moves_with_tip() {
  local out rc=0
  mover_world guarded-primary
  "$ROOT/bin/jg-home-guard.sh" install "$W/main" --tip "$C0" >/dev/null || fail "install home guard"
  out=$(run_mover) || rc=$?
  [ "$rc" -ne 0 ] || fail "fixture has two skipped leads"
  [ "$(head_of main)" = "$C2" ] || fail "guarded primary must move: $out"
  [ "$(cat "$W/main/.git/jg-home-guard/trunk-tip")" = "$C2" ] || fail "guard tip must move"
  [ -z "$(git -C "$W/main" status --porcelain)" ] || fail "guarded primary must be clean"
  pass 'fleet live advances guarded primary and guard tip together'
}

test_guarded_linked_home_moves_twice() {
  local out next
  mover_world linked-guard
  "$ROOT/bin/jg-home-guard.sh" install "$W/lead-ff" --tip "$C0" >/dev/null || fail "install linked guard"
  out=$(run_mover --home "$W/lead-ff") || fail "first linked live move: $out"
  [ "$(head_of lead-ff)" = "$C2" ] || fail "first linked move must reach the tip"
  git -C "$W/proj" checkout -q trunk
  commit_file "$W/proj" c.txt gamma c3
  next=$(git -C "$W/proj" rev-parse HEAD)
  git -C "$W/proj" checkout -q main
  C2=$next
  out=$(run_mover --home "$W/lead-ff") || fail "second linked live move: $out"
  [ "$(head_of lead-ff)" = "$next" ] || fail "second linked move must reach the tip"
  pass 'fleet live advances a guarded linked home twice'
}

# The real go-live shape (jg-ff-adopt-diverged): a home guarded by an OLDER guard copy, HEAD a commit that is patch-equivalent to a
# trunk commit but diverged (trunk-v6 line), index and tree at a later trunk commit T2 whose three-way merge with HEAD conflicts,
# and the target further on. The old guard refused the re-point to T2, so the home read as dirty and was skipped. The move now
# refreshes the guard, adopts T2 and reaches the target; an untracked file keeps the refusal and loses nothing.
test_a_guarded_diverged_half_moved_home_finishes() {
  local out id t2 target hook
  W="$TMP_ROOT/diverged-half"; mkdir -p "$W/home/state" "$W/home/data" "$W/home/config"
  git init -q -b main "$W/proj"
  commit_file "$W/proj" AGENTS.md v1 c0; mkdir -p "$W/proj/bin"; commit_file "$W/proj" bin/tool.sh a c0b
  commit_file "$W/proj" f.txt "$(printf 'a\nb\nc\nd\ne\nf\ng\nh')" base
  git clone -q "$W/proj" "$W/main"
  C0=$(git -C "$W/main" rev-parse HEAD)
  git -C "$W/proj" checkout -q -b trunk
  commit_file "$W/proj" f.txt "$(printf 'a-home\nb\nc\nd\ne\nf\ng\nh')" t1
  commit_file "$W/proj" f.txt "$(printf 'a-v2\nb\nc\nd\ne\nf\ng\nh')" t2a; commit_file "$W/proj" z.txt zed t2; t2=$(git -C "$W/proj" rev-parse HEAD)
  commit_file "$W/proj" f.txt "$(printf 'a-v3\nb\nc\nd\ne\nf\ng\nh')" t3; C2=$(git -C "$W/proj" rev-parse HEAD); target=$C2
  git -C "$W/proj" checkout -q main
  for id in lead-a lead-b; do
    git -C "$W/main" worktree add -q --detach "$W/$id" "$C0"; printf '%s\n' "$id" > "$W/$id/.jg-squad-lead-home"
    printf -- '- %s - fixture (home: %s; scope: x; projects: proj; added 2026-11-08)\n' "$id" "$W/$id" >> "$W/home/data/squad_leads.md"
    commit_file "$W/$id" f.txt "$(printf 'a-home\nb\nc\nd\ne\nf\ng\nh')" "same patch as t1"
    X=$(git -C "$W/$id" rev-parse HEAD)
    git -C "$W/$id" fetch -q "$W/proj" trunk
    git -C "$W/$id" read-tree -u -m HEAD "$t2" || fail "fixture: cannot stage the earlier target"
    "$ROOT/bin/jg-home-guard.sh" install "$W/$id" --tip "$X" >/dev/null || fail "install home guard"
  done
  git -C "$W/lead-a" merge-tree --write-tree "$X" "$t2" >/dev/null 2>&1 && fail "fixture: the three-way merge into the earlier target must conflict"
  # The guard in the homes is the older copy: it lacks the patch-equivalence rule.
  hook="$W/main/.git/hooks/reference-transaction"
  # shellcheck disable=SC2016 # the pattern names the guard's own variables
  sed '/patch_held "\$old" "\$new" && return 0/d' "$hook" > "$hook.old" && chmod +x "$hook.old" && mv -f "$hook.old" "$hook"
  printf 'mine\n' > "$W/lead-b/note.txt"
  out=$(run_mover) || :
  [ "$(head_of lead-a)" = "$target" ] || fail "a guarded diverged half-moved home must reach the target: $out"
  git -C "$W/lead-a" diff --quiet HEAD || fail "the finished home must hold no change against the target"
  [ -z "$(git -C "$W/lead-a" status --porcelain --untracked-files=no)" ] || fail "the finished home must be clean"
  [ "$(head_of lead-b)" != "$target" ] || fail "a home with an untracked file must not move"
  [ -f "$W/lead-b/note.txt" ] || fail "the untracked file must be kept"
  assert_contains "$out" "squad_lead lead-b: skipped: dirty working tree" "an untracked file must keep the refusal"
  pass 'T1i a guarded diverged half-moved home finishes through the refreshed guard; an untracked file keeps the refusal'
}

test_guarded_linked_home_moves_twice

test_guarded_primary_moves_with_tip
test_every_home_moves_or_is_skipped_with_one_row
test_a_half_moved_lead_finishes_its_move
test_a_guarded_diverged_half_moved_home_finishes
test_cache_is_cleared_after_a_move
test_a_move_rewires_only_the_add_ons_it_changed_and_names_a_failure
test_a_go_live_run_from_a_lead_home_moves_every_home
test_a_home_left_behind_is_named_and_the_lag_check_reports_it
test_home_moves_one_canary_only
test_failed_health_pins_the_home_back_and_the_rollout_goes_on
test_the_fleet_moves_past_a_home_with_an_old_fault
test_a_refused_guard_install_is_named_in_the_row
test_a_local_trunk_project_is_refused_without_base
test_live_runs_the_exported_tool_and_the_waiver_spends_no_word
test_the_landing_check_runs_the_batched_live_step_and_reports_it
printf 'jg-update-local-base: ok\n'
