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
#    moved commit (the drift Main hit) is still wired to the code it holds.
# T1d A go-live run from a lead home reads Main's registry: every lead, the lead itself and Main move, one row each (the
#    fleet's real shape, where the lead's own registry is empty).
# T7 A move that leaves a home behind names it; bin/jg-trunk-live-lag.sh reports a home not at the last go-live after 10 minutes.
# T2 --home moves exactly one lead (the canary) and leaves Main alone.
# T3 A failed health check pins that home back to its recorded pre-move HEAD and stops the rollout.
# T4 A local-trunk project is refused without --base ("update this project from its trunk").
# T5 `jg-trunk.sh live` runs the mover from an export of the tip, never from the home's own bin; the waiver
#    record is written only by the Overwatch path, spends no word and marks the row; a project without a
#    waiver still needs the captain's word.
# T6 The landing check runs the suite after a landing and, under a waiver, the batched live step on its own, and reports a go-live,
#    a failed move, a new hold, a home left behind the last go-live or a red suite; tests/jg-trunk-live.test.sh owns the quiet-window, hourly-cap, red and pin-back journeys.
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
  cp "$ROOT/bin/jg-host-wiring.sh" "$W/proj/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/proj/bin/jg-check-register.sh"; chmod +x "$W/proj/bin/jg-check-register.sh"
  cp "$ROOT"/core/tickets-sync/*.py "$ROOT/core/tickets-sync/wiring.sh" "$W/proj/core/tickets-sync/"
  cp "$ROOT"/core/tickets-sync/icons/* "$W/proj/core/tickets-sync/icons/"
  while IFS=$'\t' read -r name _; do
    [ "$name" != tickets-sync ] || continue
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
  pass 'T1c a move wires only the add-ons it changed, the copy equals core/, a failure is named in the row, a rolled-back home on the moved commit is wired'
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
  mkdir -p "$fh/state" "$fh/data" "$fh/config" "$fh/bin" "$fh/projects/proj"
  # shellcheck disable=SC2016 # the stub body expands when it runs
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/calls"\ncase "$1" in verify) exit "$(cat "%s/verify-rc")" ;; autolive) printf "autolive: %%s\\n" "$(cat "%s/verdict")"; exit "$(cat "%s/rc")" ;; esac\n' "$fh" "$fh" "$fh" "$fh" > "$fh/bin/jg-trunk.sh"
  chmod +x "$fh/bin/jg-trunk.sh"; cp "$ROOT/bin/jg-wake-lib.sh" "$ROOT/bin/jg-path-lib.sh" "$fh/bin/"
  local c=cccccccccccccccccccccccccccccccccccccccc ob="$fh/data/jg-trunk-landing/outbox"
  # The landing's own row names its project: the check tears the lane down (its record is gone) before the post-landing job runs.
  printf 't1\tproj\t%s\t1\tfull\n' "$c" > "$fh/data/trunk-landings.tsv"
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
  # A home behind the last go-live (the lag script's one line) is reported once per set of homes, and again after it clears and returns.
  printf '#!/usr/bin/env bash\ncat "%s/lag" 2>/dev/null\n' "$fh" > "$fh/bin/jg-trunk-live-lag.sh"; chmod +x "$fh/bin/jg-trunk-live-lag.sh"
  : > "$ob"; printf 'waiting: live in about 9 min\n' > "$fh/verdict"
  printf 'lag: homes not at the last go-live abc: lead-b\n' > "$fh/lag"; live; live
  [ "$(grep -c "proj: lag: homes not at the last go-live abc: lead-b" "$ob")" = 1 ] || fail "a lagging home is reported once: $(cat "$ob")"
  printf 'lag: homes not at the last go-live abc: lead-b lead-c\n' > "$fh/lag"; live
  [ "$(grep -c "proj: lag: " "$ob")" = 2 ] || fail "a new set of lagging homes is reported: $(cat "$ob")"
  rm "$fh/lag"; live; printf 'lag: homes not at the last go-live abc: lead-b lead-c\n' > "$fh/lag"; live
  [ "$(grep -c "proj: lag: " "$ob")" = 3 ] || fail "a lag that clears and returns is reported again: $(cat "$ob")"
  pass 'T6 the landing check runs the suite after a landing and the batched live step on its own, and reports their outcomes'
}

test_every_home_moves_or_is_skipped_with_one_row
test_cache_is_cleared_after_a_move
test_a_move_rewires_only_the_add_ons_it_changed_and_names_a_failure
test_a_go_live_run_from_a_lead_home_moves_every_home
test_a_home_left_behind_is_named_and_the_lag_check_reports_it
test_home_moves_one_canary_only
test_failed_health_pins_the_home_back_and_stops
test_a_local_trunk_project_is_refused_without_base
test_live_runs_the_exported_tool_and_the_waiver_spends_no_word
test_the_landing_check_runs_the_batched_live_step_and_reports_it
printf 'jg-update-local-base: ok\n'
