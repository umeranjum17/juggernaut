#!/usr/bin/env bash
# Tests for bin/jg-update.sh: fast-forward-only self-update of a running
# juggernaut repo and every registered squad_lead home.
#
# The guarantees under test mirror jg-fleet-sync.sh and prime directive #3:
#   - The running juggernaut repo (on its default branch) fast-forwards from
#     origin; a leased squad_lead home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - A dirty, offline, wrong-branch, or genuinely unique diverged target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#     Divergence leaves a durable reconciliation record, while a clean local
#     result already present upstream after a squash merge heals automatically.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-juggernaut flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     the two squad_lead action sets are disjoint and correctly gated -
#     restart-squad-leads carries EVERY live mate this pass left on origin's tip
#     whose recorded runtime can prove a restart, INCLUDING one that was already
#     there and one whose advance touched no instruction surface, because a
#     restart is also what re-resolves launch-time harness wiring; a live mate
#     whose runtime cannot prove a restart falls to nudge-squad-leads; and a mate
#     whose home was skipped or whose endpoint is stopped gets no action at all.
#   - SquadLead homes resolve from both state/<id>.meta and the
#     data/squad_leads.md registry, deduped, and the juggernaut repo is never
#     re-processed as one of its own squad_leads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/jg-update.sh"

# Deterministic, isolated git identity for fixture commits.
jg_git_identity fmtest fmtest@example.com

TMP_ROOT=$(jg_test_tmproot jg-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a juggernaut repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$JG_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:jg-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*jg-}
        if [ -e "$JG_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  # Fresh watcher beacon keeps jg-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/jg-remote-squad-lead-control.sh"
  chmod +x "$w/seed/bin/jg-remote-squad-lead-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a squad_lead home as a DETACHED worktree of the juggernaut repo (matching
# how treehouse leases a squad_lead home), plus its state meta. Args: world id.
# The recorded runtime matters to the action split, so it is part of the fixture:
# harness defaults to a control-verified adapter on the default (tmux) backend,
# which is what makes a restart provable. Pass a backend to model one that cannot
# prove an agent stopped.
add_sm() {
  local w=$1 id=$2 harness=${3:-claude} backend=${4:-}
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:jg-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=squad_lead\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'jg-%s\n' "$id" >> "$w/fake/windows"
  printf '%s\n' "$id" > "$w/$id/.jg-squad-lead-home"
}

# Advance origin by one commit. mode=instr changes the whole instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=bin changes only bin/, which
# a running agent re-executes rather than holding; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  PATH="$w/fakebin:$PATH" JG_FAKE_DIR="$w/fake" \
    JG_SSH_BIN="${JG_TEST_SSH_BIN:-ssh}" \
    JG_ROOT_OVERRIDE="$w/main" JG_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + squad_lead behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_squad_lead() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "juggernaut: updated " "juggernaut fast-forwarded"
  assert_contains "$out" "squad_lead sm1: updated " "squad_lead fast-forwarded"
  assert_contains "$out" "reread-juggernaut: yes" "instruction change triggers reread"
  assert_contains "$out" "restart-squad-leads: jg-sm1" "a changed AGENTS.md must move the squad_lead into the restart set"
  assert_contains "$out" "nudge-squad-leads: none" "a restarted squad_lead must not also be nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "juggernaut HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "squad_lead HEAD not at origin/main"
  # Juggernaut stays on its default branch; squad_lead stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "juggernaut left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "squad_lead worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "juggernaut tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "squad_lead tip is not a single-parent fast-forward"
  pass "T1 main + squad_lead fast-forward (single-parent), reread + restart signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "juggernaut: updated " "juggernaut still advanced"
  assert_contains "$out" "reread-juggernaut: no" "non-instruction change skips reread"
  # The running juggernaut reads nothing new, but the mate's agent still holds its
  # launch-time wiring from before the pass, which only a restart re-resolves.
  assert_contains "$out" "restart-squad-leads: jg-sm1" \
    "a live mate on the new tip must restart even when no instruction file moved"
  assert_contains "$out" "nudge-squad-leads: none" "a restarted squad_lead must not also be nudged"
  pass "T3 a non-instruction advance still restarts the live squad_lead"
}

# --- T3b: a bin/-only advance restarts too ---------------------------------
# Helpers under bin/ do reload themselves on the next call, but the mate's agent
# still froze its launch-time harness wiring before this pass, so the restart is
# not redundant and the old bin/-only carve-out no longer applies.
test_bin_only_advance_restarts() {
  local w out
  w=$(new_world t3b)
  add_sm "$w" sm1
  bump_origin "$w" bin

  out=$(run_update "$w")

  assert_contains "$out" "reread-juggernaut: yes" "a bin/ change is still an instruction-surface advance"
  assert_contains "$out" "restart-squad-leads: jg-sm1" "a bin/-only advance must still restart the live mate"
  assert_contains "$out" "nudge-squad-leads: none" "a restarted squad_lead must not also be nudged"
  pass "T3b a bin/-only advance restarts the squad_lead"
}

# --- T3c: an unverifiable runtime receives the fallback nudge ----------------
test_unprovable_runtime_gets_fallback_nudge() {
  local w out
  w=$(new_world t3c)
  # zellij has no recovery-grade agent-state classifier, so no restart there can
  # ever prove the old agent stopped and the replacement came up.
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "restart-squad-leads: none" "an unprovable runtime must stay out of the restart set"
  assert_contains "$out" "nudge-squad-leads: jg-sm1" "an unverifiable runtime must retain the fallback re-read nudge"
  pass "T3c an unverifiable squad_lead receives the fallback nudge"
}

# --- T3d: an already-stopped mate is left to startup recovery ---------------
test_dead_squad_lead_gets_no_action() {
  local w out
  w=$(new_world t3d)
  add_sm "$w" sm1
  : > "$w/fake/dead-sm1"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead sm1: updated " "the stopped mate's safe checkout still advances"
  assert_contains "$out" "restart-squad-leads: none" "a stopped mate must not be sent to restart"
  assert_contains "$out" "nudge-squad-leads: none" "a stopped mate must not receive a queued nudge"
  pass "T3d an already-stopped squad_lead is left to startup recovery"
}

# --- T3e: a legacy remote advance still restarts ---------------------------
# The host's instr= suffix is reporting detail; the parent no longer routes on it,
# so an older host that cannot report a diff can no longer suppress the restart.
test_legacy_remote_advance_restarts() {
  local w out fake_ssh
  w=$(new_world t3e)
  fake_ssh="$w/fakebin/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
case "${rargs[1]:-}" in
  update) printf 'synced: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fake_ssh"
  cat > "$w/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=/srv/sm1
project=/srv/sm1
harness=claude
kind=squad_lead
home=/srv/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
  printf -- '- sm1 - remote domain (host: remote-mac; root: /srv/fm; home: /srv/sm1; scope: things; projects: p; added 2026-09-03)\n' \
    > "$w/home/data/squad_leads.md"

  out=$(JG_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote squad_lead sm1: updated on remote-mac" \
    "the legacy remote advance was not accepted"
  assert_contains "$out" "restart-squad-leads: jg-sm1" \
    "a live remote mate on the new tip must restart even when the host reports no instruction diff"
  assert_contains "$out" "nudge-squad-leads: none" \
    "a restarted remote mate must not also be steered"
  pass "T3e a legacy remote advance still restarts the live remote mate"
}

# --- T4: dirty squad_lead is skipped, its edit preserved -------------------
test_dirty_squad_lead_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "jg-sm1" "skipped squad_lead is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty squad_lead skipped, local edit preserved"
}

# --- T4b: ignored untracked output never refuses; real dirt does -----------
# The retired board tool left an untracked .lavish/ directory in every home it
# ran in, and homes also carry their own untracked data/ output. Neither is part
# of the tracked surface an update advances, so neither may refuse it - that
# refusal is what kept seven homes on old code. A tracked edit, or a genuinely
# untracked file outside those dirs, must still refuse and name the path.
test_ignored_untracked_output_does_not_refuse() {
  local w out w2 out2 w3 out3
  w=$(new_world t4b)
  add_sm "$w" sm1
  bump_origin "$w" instr
  mkdir -p "$w/sm1/.lavish" "$w/sm1/data"
  printf 'board page\n' > "$w/sm1/.lavish/board.htm"
  printf 'local note\n' > "$w/sm1/data/note.md"

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead sm1: updated " \
    "untracked operational output must not refuse the update"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "the home with ignored untracked output did not land on origin/main"
  assert_present "$w/sm1/.lavish/board.htm" "the update removed untracked operational output"

  w2=$(new_world t4b-tracked)
  add_sm "$w2" sm1
  bump_origin "$w2" instr
  printf 'local tracked edit\n' >> "$w2/sm1/README.md"

  out2=$(run_update "$w2")

  assert_contains "$out2" "squad_lead sm1: skipped: dirty working tree" \
    "a tracked change must still refuse the update"
  assert_contains "$out2" "dirty path: README.md" "the skip must name the dirty path"

  w3=$(new_world t4b-stray)
  add_sm "$w3" sm1
  bump_origin "$w3" instr
  printf 'stray\n' > "$w3/sm1/notes.txt"

  out3=$(run_update "$w3")

  assert_contains "$out3" "squad_lead sm1: skipped: dirty working tree" \
    "a genuinely untracked source file must still refuse the update"
  assert_contains "$out3" "dirty path: notes.txt" "the skip must name the stray untracked file"
  pass "T4b ignored untracked output updates; tracked and stray files still refuse by name"
}

# --- T5: diverged squad_lead is skipped, its commit preserved --------------
test_diverged_squad_lead_skipped() {
  local w out before marker second_out
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the squad_lead's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_contains "$out" "reconciliation required (record:" "diverged skip is actionable"
  assert_not_contains "$out" "jg-sm1" "diverged squad_lead is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged squad_lead HEAD moved (unlanded work at risk)"
  marker="$w/home/state/.squad-lead-update-reconcile/sm1.pending"
  assert_present "$marker" "diverged squad_lead did not retain a durable reconciliation record"
  assert_grep 'schema=jg-squad-lead-update-reconcile.v1' "$marker" "divergence record schema missing"
  assert_grep "local_commit=$before" "$marker" "divergence record lost the protected local commit"

  second_out=$(run_update "$w")
  assert_contains "$second_out" "reconciliation required (record: $marker)" \
    "a later update did not surface the durable divergence"
  pass "T5 diverged squad_lead is preserved and durably actionable"
}

test_squash_merged_divergence_reconciles() {
  local w branch_base local_tip out marker
  w=$(new_world t5b)
  add_sm "$w" sm1
  branch_base=$(git -C "$w/sm1" rev-parse HEAD)

  printf 'v2\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add AGENTS.md
  git -C "$w/sm1" commit -qm local-instructions
  printf 'echo squash-landed\n' > "$w/sm1/bin/tool.sh"
  git -C "$w/sm1" add bin/tool.sh
  git -C "$w/sm1" commit -qm local-tooling
  local_tip=$(git -C "$w/sm1" rev-parse HEAD)

  bump_origin "$w" readme
  out=$(run_update "$w")
  marker="$w/home/state/.squad-lead-update-reconcile/sm1.pending"
  assert_contains "$out" "squad_lead sm1: skipped: diverged from origin/main" \
    "unique local work was not initially protected"
  assert_present "$marker" "initial divergence did not leave its durable record"

  git -C "$w/sm1" diff "$branch_base" "$local_tip" | git -C "$w/seed" apply
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm squash-local-contribution
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead sm1: reconciled redundant divergence" \
    "the squash-merged local result did not heal"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "reconciled squad_lead did not reach origin/main"
  assert_absent "$marker" "successful reconciliation left the divergence marker behind"
  assert_contains "$out" "restart-squad-leads: jg-sm1" \
    "the reconciled live squad_lead was excluded from restart"
  pass "T5b squash-merged divergence heals and rejoins live convergence"
}

# --- T6: the git side is idempotent; the restart set is not -----------------
# This is the SSHHIP case: that mate's home was already at the target commit, so
# the old classifier skipped it entirely and its agent kept running the launch-time
# wiring it started with. An already-current live mate must still be restarted.
test_already_current_squad_lead_still_restarts() {
  local w out restart_line
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing left to fast-forward

  assert_contains "$out" "juggernaut: already current" "juggernaut already current"
  assert_contains "$out" "squad_lead sm1: already current" "squad_lead already current"
  assert_contains "$out" "reread-juggernaut: no" "no reread when nothing changed"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-squad-leads:')
  assert_contains "$restart_line" "jg-sm1" \
    "an already-current live squad_lead must still be in the restart set"
  assert_contains "$out" "nudge-squad-leads: none" "a restarted squad_lead must not also be nudged"
  pass "T6 an already-current live squad_lead is still restarted"
}

# --- T6b: an already-current mate that cannot be restarted stays honest -----
# Unconditional restart must not become an unconditional CLAIM of one.
test_already_current_unprovable_mate_is_nudged() {
  local w out restart_line nudge_line
  w=$(new_world t6b)
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: the home is already on the tip

  assert_contains "$out" "squad_lead sm1: already current" "the mate must need no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-squad-leads:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-squad-leads:')
  assert_not_contains "$restart_line" "sm1" "an unprovable runtime must stay out of the restart set"
  assert_contains "$nudge_line" "jg-sm1" "an unprovable runtime must keep the honest re-read steer"
  pass "T6b an already-current mate with an unprovable runtime is steered, not claimed as reloaded"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every squad-lead-resolution edge at once:
#   reg1 - registered in squad_leads.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the juggernaut repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the juggernaut repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.jg-squad-lead-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/squad_leads.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead reg1: updated " "registry-only squad_lead fast-forwarded"
  assert_contains "$out" "squad_lead sm1: updated " "meta+registry squad_lead fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^squad_lead sm1:' || true)
  [ "$count" -eq 1 ] || fail "squad_lead sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "squad_lead selfish" "juggernaut repo re-processed as its own squad_lead"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'squad_lead reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-squad-leads:')
  local restart_line
  restart_line=$(printf '%s\n' "$out" | grep '^restart-squad-leads:')
  assert_contains "$restart_line" "jg-sm1" "live-meta squad_lead is restarted"
  assert_not_contains "$restart_line" "reg1" "registry-only squad_lead without live metadata gets no action"
  assert_not_contains "$nudge_line" "sm1" "a restarted squad_lead must not also be nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only squad_lead without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the juggernaut repo"
}

# --- T9: juggernaut repo on a feature branch is skipped ---------------------
test_juggernaut_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate juggernaut mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "juggernaut: skipped: on feature/wip, expected main" "off-default juggernaut skipped"
  assert_contains "$out" "reread-juggernaut: no" "no reread when juggernaut was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped juggernaut HEAD moved"
  pass "T9 juggernaut off its default branch is skipped, not forced"
}

test_juggernaut_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "juggernaut: skipped: detached HEAD, expected main" "detached juggernaut skipped"
  assert_contains "$out" "reread-juggernaut: no" "no reread when detached juggernaut was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached juggernaut HEAD moved"
  pass "T10 juggernaut detached HEAD is skipped"
}

test_unsafe_squad_lead_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.jg-squad-lead-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/squad_leads.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "squad_lead bad: skipped: unsafe home: squad_lead home cannot be inside the active juggernaut home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-squad-leads: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe squad_lead home HEAD moved"
  pass "T11 unsafe squad_lead home is not fast-forwarded"
}

# --- T12: a self-update rebinds a locally armed watch on the primary --------
# A self-update fast-forwards bin/ in place, changing bytes an armed
# jg-procevent-when watch's trust binding was hashed against with no
# tampering involved; without a rebind the very next fire would be refused.
test_primary_update_rebinds_local_watch() {
  local w before_hash after_hash out spec
  w=$(new_world t12)
  mkdir -p "$w/seed/bin"
  printf "#!/usr/bin/env bash\necho v1 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  chmod +x "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm add-watched-action
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q origin main

  JG_ROOT_OVERRIDE="$w/main" JG_HOME="$w/home" "$ROOT/bin/jg-procevent-when.sh" \
    arm rebind-primary --interval 60 --stable 1 \
    --condition true --action "$w/main/bin/watched-action.sh" "$w/rebind.log" >/dev/null
  spec="$w/home/state/when/when-rebind-primary.spec"
  before_hash=$(grep '^action_sha256=' "$spec")

  printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump-watched-action
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "juggernaut: updated " "the primary still advanced"
  assert_contains "$out" "rebound: when-rebind-primary" "the primary self-update rebound its own locally armed watch"
  after_hash=$(grep '^action_sha256=' "$spec")
  [ "$before_hash" != "$after_hash" ] \
    || fail "the watch's trust binding was not refreshed to match the updated action bytes"
  pass "T12 a self-update rebinds a locally armed watch on the primary"
}

test_updates_main_and_squad_lead
test_reread_gate_is_instruction_only
test_bin_only_advance_restarts
test_unprovable_runtime_gets_fallback_nudge
test_dead_squad_lead_gets_no_action
test_legacy_remote_advance_restarts
test_dirty_squad_lead_skipped
test_ignored_untracked_output_does_not_refuse
test_diverged_squad_lead_skipped
test_squash_merged_divergence_reconciles
test_already_current_squad_lead_still_restarts
test_already_current_unprovable_mate_is_nudged
test_registry_backstop_dedup_and_self_exclusion
test_juggernaut_wrong_branch_skipped
test_juggernaut_detached_head_skipped
test_unsafe_squad_lead_home_skipped_before_git_update
test_primary_update_rebinds_local_watch

echo "# all jg-update tests passed"
