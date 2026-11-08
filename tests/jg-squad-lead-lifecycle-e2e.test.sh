#!/usr/bin/env bash
# tests/jg-squad-lead-lifecycle-e2e.test.sh - the happy-path squad_lead operator
# flow, end to end, against one shared world:
#
#   seed -> spawn -> routed send -> backlog handoff -> recovery respawn -> teardown
#
# Each phase asserts the durable contracts the consolidation audit lists, so the
# many former positive unit tests (registry scope/charter/clone/mode, spawn meta,
# bare-window send, recovery respawn, teardown of an empty home, backlog handoff)
# collapse into one lifecycle. The path-boundary safety invariants and the
# lease-specific paths live in jg-squad-lead-safety.test.sh.
#
# Coverage anchored here (must not regress):
#   - registry line records scope (from a filled charter brief) and project list
#   - charter is copied into the subhome
#   - remote-backed projects are cloned with their origin URL preserved
#   - a no-mistakes project is initialized (init + doctor) in the NEW subhome clone
#     and the parent project clone is never mutated (no write through a project)
#   - spawn meta records kind=squad_lead, home=, and the project list; launch runs
#     in the subhome with the persistent charter and cleared operational overrides
#   - a bare `jg-<id>` send targets the window recorded in THIS home's meta
#   - backlog items move verbatim into the subhome and leave the main backlog
#   - recovery respawns from the durable registry + persistent home
#   - teardown removes meta and the registry route only after removing the home
set -u

# shellcheck source=tests/squad-lead-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/squad-lead-helpers.sh"

TMP_ROOT=$(jg_test_tmproot jg-squad-lead-lifecycle)
export JG_BACKEND=tmux

HOME_DIR="$TMP_ROOT/main home"
SUB="$TMP_ROOT/design-home"
SUB_ABS=
FAKEBIN=
LOG="$TMP_ROOT/tmux.log"
PANE="$TMP_ROOT/pane.txt"
ALPHA_ORIGIN=
BETA_ORIGIN=

# --- shared world + seed ----------------------------------------------------
setup_world() {
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state"
  jg_git_init_commit "$HOME_DIR/projects/alpha"
  jg_git_init_commit "$HOME_DIR/projects/beta"
  jg_git_init_commit "$HOME_DIR/projects/gamma"
  jg_git_add_origin "$HOME_DIR/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
  jg_git_add_origin "$HOME_DIR/projects/beta" "$TMP_ROOT/remotes/beta.git"
  jg_git_add_origin "$HOME_DIR/projects/gamma" "$TMP_ROOT/remotes/gamma.git"
  cat > "$HOME_DIR/data/projects.md" <<EOF
- alpha [direct-PR +yolo] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
- gamma - gamma project (added 2026-06-22)
EOF
  ALPHA_ORIGIN=$(git -C "$HOME_DIR/projects/alpha" remote get-url origin)
  BETA_ORIGIN=$(git -C "$HOME_DIR/projects/beta" remote get-url origin)

  # One combined fakebin: tmux + treehouse (spawn/send/teardown) and no-mistakes
  # (gamma initialization during seed).
  FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
  make_fake_no_mistakes "$TMP_ROOT/fake" >/dev/null

  # A filled charter brief whose routing scope differs from the charter summary,
  # so the registry must read the scope from the brief, not invent a generic one.
  JG_SQUAD_LEAD_SCOPE='customer onboarding from brief' \
    scaffold_squad_lead_charter "$HOME_DIR" design 'customer onboarding charter' alpha beta gamma \
    || fail "filled squad_lead charter scaffold failed"
}

phase_seed() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" \
    "$ROOT/bin/jg-home-seed.sh" design "$SUB" alpha beta gamma) \
    || fail "seed failed"
  SUB_ABS=$(cd "$SUB" && pwd -P)

  assert_contains "$out" "home=$SUB_ABS" "seed did not report the subhome"
  assert_present "$SUB/.jg-squad-lead-home" "seed did not mark the subhome"
  assert_present "$SUB/data/charter.md" "seed did not copy the charter into the subhome"
  assert_grep 'customer onboarding charter' "$SUB/data/charter.md" "charter body was not copied verbatim"

  # Projects cloned; remote-backed origins preserved.
  assert_present "$SUB/projects/alpha/.git" "alpha was not cloned"
  assert_present "$SUB/projects/beta/.git" "beta was not cloned"
  assert_present "$SUB/projects/gamma/.git" "gamma was not cloned"
  [ "$(git -C "$SUB/projects/alpha" remote get-url origin)" = "$ALPHA_ORIGIN" ] \
    || fail "alpha clone did not preserve its origin URL"
  [ "$(git -C "$SUB/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
    || fail "direct-PR beta clone did not preserve its origin URL"

  # no-mistakes init runs in the NEW clone, never the parent project.
  assert_present "$SUB/projects/gamma/.no-mistakes-init" "no-mistakes project was not initialized in the subhome"
  assert_present "$SUB/projects/gamma/.no-mistakes-doctor" "no-mistakes project was not doctored in the subhome"
  assert_absent "$HOME_DIR/projects/gamma/.no-mistakes-init" "seed wrote no-mistakes state through the parent project"

  # Registry line: scope from the filled brief, project list, no legacy owns field.
  assert_grep '- design - customer onboarding charter' "$HOME_DIR/data/squad_leads.md" "registry summary not from the charter"
  assert_grep 'scope: customer onboarding from brief' "$HOME_DIR/data/squad_leads.md" "registry scope not from the filled brief"
  assert_grep 'projects: alpha, beta, gamma' "$HOME_DIR/data/squad_leads.md" "registry did not record the project list"
  assert_no_grep 'owns:' "$HOME_DIR/data/squad_leads.md" "registry used the legacy owns field"

  # Delivery modes preserved in the subhome registry; validation passes.
  [ "$(JG_HOME="$SUB" "$ROOT/bin/jg-project-mode.sh" alpha)" = "direct-PR on" ] \
    || fail "alpha delivery mode not preserved in the subhome"
  [ "$(JG_HOME="$SUB" "$ROOT/bin/jg-project-mode.sh" beta)" = "direct-PR off" ] \
    || fail "beta delivery mode not preserved in the subhome"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-home-seed.sh" validate >/dev/null || fail "registry validation failed after seed"

  pass "seed: registry scope+projects, charter copied, clones+origins, no-mistakes init in subhome only"
}

phase_spawn() {
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_CONFIG_OVERRIDE="$HOME_DIR/parent-config" \
    JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-spawn.sh" design "$SUB" codex --squad-lead >/dev/null \
    || fail "squad_lead spawn failed"

  local meta="$HOME_DIR/state/design.meta"
  assert_grep 'kind=squad_lead' "$meta" "spawn meta did not record kind=squad_lead"
  assert_grep "home=$SUB_ABS" "$meta" "spawn meta did not record the subhome"
  assert_grep 'projects=alpha, beta, gamma' "$meta" "spawn meta did not record the project list"
  # Launch ran in the subhome, with the persistent charter and cleared overrides,
  # and never ran a project-style treehouse get.
  assert_grep "JG_HOME='$SUB_ABS'" "$LOG" "squad_lead launch did not set JG_HOME to the subhome"
  assert_grep 'JG_ROOT_OVERRIDE= JG_STATE_OVERRIDE= JG_DATA_OVERRIDE= JG_PROJECTS_OVERRIDE=' "$LOG" "launch did not clear operational overrides"
  assert_grep 'JG_CONFIG_OVERRIDE=' "$LOG" "launch did not clear the config override"
  assert_grep "$SUB_ABS/data/charter.md" "$LOG" "launch did not use the persistent charter"
  assert_no_grep 'notify=' "$LOG" "squad_lead codex launch included the parent turn-end notify hook"
  assert_no_grep 'turn-ended' "$LOG" "squad_lead codex launch referenced a parent turn-ended signal"
  assert_no_grep 'treehouse get' "$LOG" "squad_lead spawn ran a project treehouse get"
  pass "spawn: launches in the subhome with persistent charter, records routing meta"
}

phase_send() {
  : > "$LOG"
  printf '❯\n' > "$PANE"
  # The meta window (juggernaut:jg-design) must win over a foreign same-named
  # window returned by list-windows. Include the recorded endpoint in the fake
  # inventory so the recovery-grade liveness check can verify it exists.
  PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_FAKE_TMUX_WINDOW="juggernaut:jg-design
other-session:jg-design" \
    JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-send.sh" jg-design 'route this work' >/dev/null 2>&1 \
    || fail "jg-send failed for a bare juggernaut window with home metadata"
  # design is a kind=squad_lead target, so the durable inbox record carries the
  # from-juggernaut marker and original payload. The terminal receives only the
  # constant doorbell, routed through this home's authoritative meta window.
  local record="$HOME_DIR/state/design.inbox/001.msg" body
  assert_present "$record" "send did not enqueue the squad_lead request"
  body=$(bash -c '. "$1"; jg_task_inbox_body "$2"' _ "$ROOT/bin/jg-task-inbox-lib.sh" "$record")
  assert_contains "$body" '[jg-from-juggernaut]' "the inbox request was not marked as from-juggernaut"
  assert_contains "$body" 'route this work' "the original request text did not survive the marker"
  assert_grep 'send-keys -t juggernaut:jg-design -l : Juggernaut instruction waiting:' "$LOG" "send did not ring the window recorded in this home's meta"
  assert_no_grep 'route this work' "$LOG" "send typed the payload instead of only the doorbell"
  assert_no_grep 'send-keys -t other-session:jg-design' "$LOG" "send targeted a foreign same-named window"
  pass "send: a bare jg-<id> squad_lead enqueues a marked request and rings the meta window"
}

phase_recovery() {
  # Simulate a restart: drop the live meta, then respawn from the registry +
  # persistent home (no explicit home argument).
  rm -f "$HOME_DIR/state/design.meta"
  PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-spawn.sh" design "echo relaunch" --squad-lead >/dev/null 2>&1 \
    || fail "recovery respawn failed"
  local meta="$HOME_DIR/state/design.meta"
  assert_grep "home=$SUB_ABS" "$meta" "respawn did not preserve the persistent home from the registry"
  assert_grep 'projects=alpha, beta, gamma' "$meta" "respawn did not preserve the project list from the registry"
  assert_grep 'window=juggernaut:jg-design' "$meta" "respawn did not reconstruct the direct-report window"
  pass "recovery: respawns from the durable registry and persistent home"
}

phase_teardown() {
  local teardown_out corr rec leftover leftover_rec other_corr
  corr=$(JG_HOME="$HOME_DIR" bash -c '
    . "$1"
    jg_pending_reply_create "$2" "$2/state" design "New routed work is in your backlog."
  ' _ "$ROOT/bin/jg-pending-reply-lib.sh" "$HOME_DIR") \
    || fail "could not seed receiver wake retirement state"
  rec="$HOME_DIR/state/pending-replies/$corr"
  leftover=$(JG_HOME="$HOME_DIR" bash -c '
    . "$1"
    jg_pending_reply_create "$2" "$2/state" design "Earlier routed ask that already resolved."
  ' _ "$ROOT/bin/jg-pending-reply-lib.sh" "$HOME_DIR") \
    || fail "could not seed leftover resolved pending-reply"
  leftover_rec="$HOME_DIR/state/pending-replies/$leftover"
  # Settle every parent pending-reply for this mate (earlier send/handoff
  # phases leave open records) so non-forced retirement mirrors a clean
  # captain-approved close rather than hitting the unresolved-reply refuse.
  JG_HOME="$HOME_DIR" bash -c '
    . "$1"
    state="$2/state"
    for rec in "$state/pending-replies"/*; do
      [ -f "$rec" ] || continue
      [ "$(jg_pending_reply_get "$rec" task_id)" = design ] || continue
      jg_pending_reply_set "$rec" phase resolved
      jg_pending_reply_set "$rec" delivered_epoch 1
    done
  ' _ "$ROOT/bin/jg-pending-reply-lib.sh" "$HOME_DIR" \
    || fail "could not settle pending-replies before retirement"
  mkdir -p "$TMP_ROOT/external-pending"
  printf 'task_id=design\nphase=resolved\n' > "$TMP_ROOT/external-pending/escape"
  mv "$HOME_DIR/state/pending-replies" "$HOME_DIR/state/pending-replies.safe"
  ln -s "$TMP_ROOT/external-pending" "$HOME_DIR/state/pending-replies"
  if PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-teardown.sh" design >/dev/null 2>&1; then
    fail "local retirement accepted a symlinked pending-replies directory"
  fi
  assert_present "$SUB" "unsafe pending-replies retirement removed the squad_lead home"
  assert_present "$HOME_DIR/state/design.meta" "unsafe pending-replies retirement removed parent metadata"
  assert_grep '- design ' "$HOME_DIR/data/squad_leads.md" \
    "unsafe pending-replies retirement removed the registry route"
  assert_present "$TMP_ROOT/external-pending/escape" \
    "unsafe local retirement removed an external pending reply"
  rm -f "$HOME_DIR/state/pending-replies"
  mv "$HOME_DIR/state/pending-replies.safe" "$HOME_DIR/state/pending-replies"
  mkdir -p "$HOME_DIR/state/pending-replies/.delivery-confirmed-.."
  mkdir -p "$TMP_ROOT/escape"
  touch "$TMP_ROOT/escape/pwned"
  printf 'task_id=design\nphase=resolved\ncorr_id=../../../../../escape/pwned\n' \
    > "$HOME_DIR/state/pending-replies/aaaaaaaaaaaaaaaa"
  if PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-teardown.sh" design >/dev/null 2>&1; then
    fail "local retirement accepted a pending-reply with unsafe corr_id"
  fi
  assert_present "$SUB" "unsafe corr_id retirement removed the squad_lead home"
  assert_present "$HOME_DIR/state/design.meta" "unsafe corr_id retirement removed parent metadata"
  assert_grep '- design ' "$HOME_DIR/data/squad_leads.md" \
    "unsafe corr_id retirement removed the registry route"
  assert_present "$TMP_ROOT/escape/pwned" \
    "unsafe corr_id cleanup deleted outside pending-replies"
  rm -rf "$HOME_DIR/state/pending-replies/.delivery-confirmed-.."
  rm -f "$HOME_DIR/state/pending-replies/aaaaaaaaaaaaaaaa"
  other_corr=bbbbbbbbbbbbbbbb
  printf 'task_id=other\nphase=resolved\ncorr_id=%s\n' "$other_corr" \
    > "$HOME_DIR/state/pending-replies/$other_corr"
  : > "$HOME_DIR/state/pending-replies/.delivery-confirmed-$other_corr"
  printf 'task_id=design\nphase=resolved\ncorr_id=%s\n' "$other_corr" \
    > "$HOME_DIR/state/pending-replies/aaaaaaaaaaaaaaaa"
  if PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-teardown.sh" design >/dev/null 2>&1; then
    fail "local retirement accepted a pending-reply with mismatched corr_id"
  fi
  assert_present "$SUB" "mismatched corr_id retirement removed the squad_lead home"
  assert_present "$HOME_DIR/state/design.meta" "mismatched corr_id retirement removed parent metadata"
  assert_grep '- design ' "$HOME_DIR/data/squad_leads.md" \
    "mismatched corr_id retirement removed the registry route"
  assert_present "$HOME_DIR/state/pending-replies/$other_corr" \
    "mismatched corr_id cleanup deleted another task's pending reply"
  assert_present "$HOME_DIR/state/pending-replies/.delivery-confirmed-$other_corr" \
    "mismatched corr_id cleanup deleted another task's delivery confirmation"
  rm -f "$HOME_DIR/state/pending-replies/aaaaaaaaaaaaaaaa" \
    "$HOME_DIR/state/pending-replies/$other_corr" \
    "$HOME_DIR/state/pending-replies/.delivery-confirmed-$other_corr"
  printf 'confirmed:%s\n' "$corr" > "$HOME_DIR/state/.backlog-handoff-design.wake-pending"
  printf '%s\tattempt\n' "$(date +%s)" > "$HOME_DIR/state/.squad-lead-relaunch-design"
  printf '%s\tdead\n' "$(date +%s)" > "$HOME_DIR/state/.squad-lead-relaunch-bound-design"
  : > "$LOG"
  teardown_out=$(PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_FAKE_TMUX_LOG="$LOG" JG_FAKE_TMUX_CAPTURE="$PANE" \
    "$ROOT/bin/jg-teardown.sh" design 2>&1) \
    || fail "teardown failed for the empty squad_lead home: $teardown_out"
  printf '%s\n' "$teardown_out" | grep -F 'Backlog:' >/dev/null \
    && fail "squad_lead teardown emitted a main-backlog completion reminder"
  assert_absent "$SUB" "teardown did not remove the retired squad_lead home"
  assert_absent "$HOME_DIR/state/design.meta" "teardown did not clear the parent meta"
  assert_absent "$HOME_DIR/state/.backlog-handoff-design.wake-pending" \
    "teardown left receiver wake state that could poison a replacement route"
  assert_absent "$rec" "teardown left the retired receiver wake correlation"
  assert_absent "$HOME_DIR/state/.squad-lead-relaunch-design" \
    "teardown left the relaunch ledger a same-id replacement would inherit"
  assert_absent "$HOME_DIR/state/.squad-lead-relaunch-bound-design" \
    "teardown left the relaunch park marker a same-id replacement would inherit"
  assert_absent "$HOME_DIR/state/.squad-lead-liveness-design.lock" \
    "teardown left the liveness lock it took to retire relaunch state"
  assert_absent "$leftover_rec" "teardown left a resolved pending-reply for the retired squad_lead"
  assert_no_grep '- design ' "$HOME_DIR/data/squad_leads.md" "teardown did not remove the registry route"
  # The parent's source projects are untouched (no write through a parent home).
  assert_present "$HOME_DIR/projects/alpha" "teardown disturbed a parent project"
  pass "teardown: removes the home, then clears meta and the registry route"
}

setup_world
phase_seed
phase_spawn
phase_send
phase_recovery
phase_teardown
