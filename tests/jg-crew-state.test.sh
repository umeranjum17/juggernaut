#!/usr/bin/env bash
# Behavior tests for bin/jg-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. jg-crew-state
# reads the AUTHORITATIVE source (the semantic busy-state contract) and
# reconciles the possibly-stale log against it. These cases pin every branch of
# that logic, hermetically, over real throwaway git repos with a fake `tmux`
# (pane source): busy pane, idle pane falling to the status-log verb, dead or
# unreadable endpoint, a ship done: gated on its named head, a Recon done: gated
# on its depth report, a squad_lead's log, a remote squad_lead, a torn-down
# worktree and missing meta.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-pr-lib.sh"

CREW_STATE="$ROOT/bin/jg-crew-state.sh"
TMP_ROOT=$(jg_test_tmproot jg-crew-state)
jg_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
# Stamp origin/main at the current HEAD so a later ship done: is not refused
# solely for being a fixture with no remote-tracking refs; tests that need an
# unpreserved named head point those refs at a different commit.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
}

# A fakebin with a fake `tmux` (serves a busy or idle pane) and fake forge CLIs.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "api graphql")
    [ -z "${JG_FAKE_PR_READ_LOG:-}" ] || printf 'gh\n' >> "$JG_FAKE_PR_READ_LOG"
    number=1
    for arg in "$@"; do
      case "$arg" in
        number=*) number=${arg#number=} ;;
      esac
    done
    case "$number" in *[!0-9]*|'') number=1 ;; esac
    state=${JG_FAKE_PR_STATE:-MERGED}
    merged=${JG_FAKE_PR_MERGED:-true}
    eval "state=\${JG_FAKE_PR_${number}_STATE:-\$state}"
    eval "merged=\${JG_FAKE_PR_${number}_MERGED:-\$merged}"
    [ "${JG_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'state=%s\nmerged=%s\n' "$state" "$merged"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    [ -z "${JG_FAKE_PR_READ_LOG:-}" ] || printf 'gh-axi\n' >> "$JG_FAKE_PR_READ_LOG"
    [ "${JG_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'pull_request:\n  number: %s\n  state: %s\n' "${3:-1}" "${JG_FAKE_PR_STATE_AXI:-merged}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/glab" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "mr view")
    [ -z "${JG_FAKE_GLAB_READ_LOG:-}" ] || printf '%s|%s\n' "${GITLAB_HOST:-}" "$*" >> "$JG_FAKE_GLAB_READ_LOG"
    [ "${JG_FAKE_GLAB_READ_FAIL:-0}" = 1 ] && exit 1
    printf '{"state":"%s"}\n' "${JG_FAKE_GLAB_STATE:-merged}"
    exit 0 ;;
esac
exit 1
SH
  # tea answers its login list with one login for git.example.org and a pull
  # request read through "tea api" with the configured state; a read failure
  # prints the error body with exit 0, as the real tea api does.
  cat > "$fb/tea" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "${1:-}" = api ] || exit 1
[ -z "${JG_FAKE_TEA_READ_LOG:-}" ] || printf '%s\n' "$*" >> "$JG_FAKE_TEA_READ_LOG"
if [ "${JG_FAKE_TEA_READ_FAIL:-0}" = 1 ]; then
  printf '{"message":"not found"}\n'
  exit 0
fi
printf '{"state":"%s","merged":%s,"head":{"sha":"abc"}}\n' \
  "${JG_FAKE_TEA_STATE:-closed}" "${JG_FAKE_TEA_MERGED:-true}"
SH
  cat > "$fb/gerrit-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    [ -z "${JG_FAKE_GERRIT_READ_LOG:-}" ] || printf '%s\n' "$*" >> "$JG_FAKE_GERRIT_READ_LOG"
    [ "${JG_FAKE_GERRIT_READ_FAIL:-0}" = 1 ] && exit 1
    # url defaults to null, the shape a server whose gerrit.canonicalWebUrl is
    # unset returns, so every case here reads a record that carries no URL.
    printf '{"ok":true,"op":"show","changes":[{"change":%s,"subject":"fixture change","status":"%s","url":%s}]}\n' \
      "${JG_FAKE_GERRIT_CHANGE:-${2:-0}}" "${JG_FAKE_GERRIT_STATUS:-MERGED}" \
      "${JG_FAKE_GERRIT_URL_JSON:-null}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# JG_FAKE_TMUX_MISSING: the window is authoritatively gone - every addressed
# call fails, but the session inventory still answers successfully and simply
# omits the window, which is what proves absence.
# JG_FAKE_TMUX_UNREADABLE: tmux itself cannot answer - it fails to execute (a
# trimmed PATH) or errors non-definitively - so even the inventory fails, with
# a message that is NOT one of the definitive no-session/no-server/no-socket
# responses that jg_backend_tmux_agent_state owns as death.
[ "${JG_FAKE_TMUX_UNREADABLE:-0}" = 1 ] && { printf 'no current client\n' >&2; exit 1; }
case "${1:-}" in
  list-windows)
    # A successful but empty inventory: it omits the crew's window, so absence
    # is proved by the answer rather than by an addressed call failing. Only
    # reached once display-message has already failed.
    ;;
  display-message)
    [ "${JG_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${JG_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${JG_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${JG_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${JG_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        [ "${JG_FAKE_HERDR_READ_FAIL:-0}" = 1 ] && exit 1
        if [ "${JG_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
      get)
        if [ "${JG_FAKE_HERDR_MISSING:-0}" = 1 ]; then
          printf '{"error":{"code":"pane_not_found","message":"no such pane"}}\n'
          exit 1
        fi
        printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
        exit 0 ;;
      process-info)
        # The process-level view a registration is verified against (#4115):
        # `agent` puts a live claude in the foreground, `shell` a bare zsh whose
        # pid is the test script itself (a real, long-lived process with no
        # harness descendant, so the adapter's real process-table walk finds
        # it), and anything else answers nothing (unreadable).
        pane=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --pane ] && pane=${args[$((i+1))]:-}; done
        case "${JG_FAKE_HERDR_PROCESS:-agent}" in
          agent) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$pane" "${JG_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
          shell) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "${JG_FAKE_HERDR_SHELL_PID:-$PPID}" "${JG_FAKE_HERDR_SHELL_PID:-$PPID}" "${JG_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
        esac
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        if [ "${JG_FAKE_HERDR_HUSK:-0}" = 1 ]; then
          printf '{"error":{"code":"agent_not_found","message":"no agent in pane"}}\n'
          exit 0
        fi
        [ -n "${JG_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$JG_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/gh" "$fb/gh-axi" "$fb/glab" "$fb/tea" "$fb/gerrit-axi" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

# Run the helper for one case dir. JG_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" JG_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/jg-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  JG_FAKE_BUSY=0
  JG_FAKE_BUSY_TEXT=
  JG_FAKE_TMUX_MISSING=0
  JG_FAKE_TMUX_UNREADABLE=0
  JG_FAKE_HERDR_BUSY=0
  JG_FAKE_HERDR_MISSING=0
  JG_FAKE_HERDR_READ_FAIL=0
  JG_FAKE_HERDR_HUSK=0
  JG_FAKE_HERDR_AGENT_STATUS=""
  JG_FAKE_HERDR_PROCESS=agent
  JG_FAKE_HERDR_SHELL_PID=$$
  JG_FAKE_PR_STATE=MERGED
  JG_FAKE_PR_MERGED=true
  JG_FAKE_PR_READ_FAIL=0
  JG_FAKE_PR_READ_LOG=
  JG_FAKE_PR_STATE_AXI=merged
  JG_FAKE_GLAB_STATE=merged
  JG_FAKE_GLAB_READ_FAIL=0
  JG_FAKE_GLAB_READ_LOG=
  JG_FAKE_TEA_STATE=closed
  JG_FAKE_TEA_MERGED=true
  JG_FAKE_TEA_READ_FAIL=0
  JG_FAKE_TEA_READ_LOG=
  JG_FAKE_GERRIT_STATUS=MERGED
  JG_FAKE_GERRIT_CHANGE=
  JG_FAKE_GERRIT_URL_JSON=
  JG_FAKE_GERRIT_READ_FAIL=0
  JG_FAKE_GERRIT_READ_LOG=
  unset JG_FAKE_PR_47_STATE JG_FAKE_PR_47_MERGED JG_FAKE_PR_48_STATE JG_FAKE_PR_48_MERGED
  export  JG_FAKE_BUSY JG_FAKE_BUSY_TEXT JG_FAKE_TMUX_MISSING JG_FAKE_TMUX_UNREADABLE
  export JG_FAKE_HERDR_BUSY JG_FAKE_HERDR_MISSING JG_FAKE_HERDR_READ_FAIL JG_FAKE_HERDR_HUSK JG_FAKE_HERDR_AGENT_STATUS JG_FAKE_HERDR_PROCESS JG_FAKE_HERDR_SHELL_PID
  export JG_FAKE_PR_STATE JG_FAKE_PR_MERGED JG_FAKE_PR_READ_FAIL JG_FAKE_PR_READ_LOG JG_FAKE_PR_STATE_AXI
  export JG_FAKE_GLAB_STATE JG_FAKE_GLAB_READ_FAIL JG_FAKE_GLAB_READ_LOG
  export JG_FAKE_TEA_STATE JG_FAKE_TEA_MERGED JG_FAKE_TEA_READ_FAIL JG_FAKE_TEA_READ_LOG
  export JG_FAKE_GERRIT_STATUS JG_FAKE_GERRIT_CHANGE JG_FAKE_GERRIT_URL_JSON
  export JG_FAKE_GERRIT_READ_FAIL JG_FAKE_GERRIT_READ_LOG
  export JG_FAKE_PR_47_STATE JG_FAKE_PR_47_MERGED JG_FAKE_PR_48_STATE JG_FAKE_PR_48_MERGED
}

# A ship done: whose named head lives only in the disposable copy is not
# current-state done (issue 4768). The worker's claim stays a blocked
# preservation failure rather than finished-and-safe.
test_unpushed_ship_done_is_blocked() {
  reset_fakes
  local d sha out
  d=$(new_case unpushed-done)
  make_repo_on_branch "$d/wt" fm/unpushed
  git -C "$d/wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/unpushed.meta" \
    "window=fm:jg-unpushed" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' \
    > "$d/state/unpushed.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" unpushed
  out=$(run_crew_state "$d" unpushed)
  assert_contains "$out" "state: blocked" "unpushed ship done: must not read as done"
  assert_contains "$out" "source: status-log" "preservation refusal stays status-log sourced"
  assert_contains "$out" "named head $sha is unreachable outside the worker copy" \
    "refusal must name the unpushed head"
  assert_not_contains "$out" "state: done" "unpushed ship done: must not remain done"
  pass "unpushed ship done: is current-state blocked"
}

# The observed 17 Oct failure: the push that opened the fork PR left no
# remote-tracking ref in the worker copy, so current state read blocked while
# the forge held the worker's HEAD as the PR head. The gate's live forge-head
# read must turn this into current-state done. A local bare repository stands
# in for the forge and the fake gh reads the head from it.
test_fork_head_on_forge_reads_done() {
  reset_fakes
  local d sha out
  d=$(new_case forkgreen)
  make_repo_on_branch "$d/wt" fm/forkpub
  git -C "$d/wt" commit -q --allow-empty -m 'pushed to the forge without a tracking ref'
  sha=$(git -C "$d/wt" rev-parse HEAD)
  git init -q --bare "$d/forge.git"
  git -C "$d/wt" push -q "$d/forge.git" fm/forkpub
  make_fakebin "$d" >/dev/null
  # shellcheck disable=SC2016  # runtime expansions must stay in the stub
  cat > "$d/fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\$1 \${2:-}" = "pr view" ] || exit 1
git --git-dir="$d/forge.git" rev-parse refs/heads/fm/forkpub
SH
  chmod +x "$d/fakebin/gh"
  jg_write_meta "$d/state/forkgreen.meta" \
    "window=fm:jg-forkgreen" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://github.com/o/r/pull/92\n' > "$d/state/forkgreen.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" forkgreen
  out=$(run_crew_state "$d" forkgreen)
  assert_contains "$out" "state: done" \
    "a done whose forge PR head is the worker HEAD must read done"
  assert_contains "$out" "source: status-log" "forge-head acceptance stays status-log sourced"
  assert_not_contains "$out" "unreachable outside the worker copy" \
    "the forge-held head must not read as unreachable"
  pass "a fork head the forge holds reads current-state done without a tracking ref"
}

# Fleet snapshot hands crew-state a captured meta copy outside state/. The
# poll's merge marker stays in the live state dir, so a squash-merged PR whose
# branch fleet sync pruned still reads done there.
test_merged_pr_reads_done_under_captured_meta() {
  reset_fakes
  local d out
  d=$(new_case merged-captured)
  make_repo_on_branch "$d/wt" fm/merged
  git -C "$d/wt" commit -q --allow-empty -m 'squash-merged fix, branch pruned'
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/merged.meta" \
    "window=fm:jg-merged" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude" "pr=https://github.com/o/r/pull/7"
  printf '%s\n' jg-pr-poll-merge-notified-v1 github github.com o/r 7 \
    > "$d/state/merged.pr-poll-merge-notified"
  chmod 600 "$d/state/merged.pr-poll-merge-notified"
  printf 'done: PR https://github.com/o/r/pull/7\n' > "$d/state/merged.status"
  mkdir -p "$d/captured"
  cp "$d/state/merged.meta" "$d/captured/merged.meta"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" merged
  out=$(JG_CREW_STATE_META_OVERRIDE="$d/captured/merged.meta" run_crew_state "$d" merged)
  assert_contains "$out" "state: done" "recorded merged PR must read done under a captured meta"
  assert_not_contains "$out" "state: blocked" "merge marker must be read from the live state dir"
  pass "recorded merged PR reads done under the fleet snapshot's captured meta"
}

test_moved_remote_branch_without_named_head_is_blocked() {
  reset_fakes
  local d main_sha fix_sha out
  d=$(new_case moved-branch)
  make_repo_on_branch "$d/wt" fm/moved
  main_sha=$(git -C "$d/wt" rev-parse refs/remotes/origin/main)
  git -C "$d/wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/moved.meta" \
    "window=fm:jg-moved" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/8\n' > "$d/state/moved.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" moved
  out=$(run_crew_state "$d" moved)
  assert_contains "$out" "state: blocked" "a moved remote branch must not count as preserved"
  assert_contains "$out" "named head $fix_sha is unreachable outside the worker copy" \
    "refusal must name the missing fix, not the moved branch"
  pass "moved remote branch without the named head is current-state blocked"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-h.meta" "window=fm:jg-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/jg-busy-lib.sh), not from rendered text.
  JG_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A launch pinned at the jg-spawn seed (no hook has posted yet) whose pane
# renders a recognized interactive prompt must read unknown, never working -
# this is the load-bearing link the launch-prompt backstop depends on:
# jg-watch.sh's pause_state_class absorbs a stale pane as "provably working"
# whenever THIS script reports `state: working · source: pane`, so if this
# authoritative read still said working, the watcher would silently swallow
# the wake even though bin/jg-busy-lib.sh's own classifier had already flipped
# to unknown launch-prompt. crew_busy_verdict must therefore capture a real
# tail for every harness, not only grok, so the backstop's own tail-based
# check ever runs here at all.
test_no_run_launch_prompt_parked_is_not_working() {
  reset_fakes
  local d; d=$(new_case launch-prompt)
  make_repo_on_branch "$d/wt" fm/feat-lp
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-lp.meta" "window=fm:jg-feat-lp" "worktree=$d/wt" "kind=ship" "harness=claude"
  JG_FAKE_BUSY=1
  JG_FAKE_BUSY_TEXT='Quick safety check: Is this a project you created or one you trust? ...
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel'
  export JG_FAKE_BUSY_TEXT
  # arm only, never apply: the launch turn has never advanced past the seed
  # jg-spawn.sh writes at spawn time.
  "$ROOT/bin/jg-busy-event.sh" arm "$d/state" feat-lp >/dev/null
  local out; out=$(run_crew_state "$d" feat-lp)
  assert_not_contains "$out" "state: working" "a launch parked on its trust dialog must never read working"
  assert_contains "$out" "state: unknown" "a parked launch reads unknown, not busy or idle"
  assert_contains "$out" "launch-prompt" "the unknown verdict names the launch-prompt backstop as its source"
  pass "a launch parked on a recognized interactive prompt never reads working, closing the absorb path a stale watcher poll depends on"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-h2.meta" "window=fm:jg-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  JG_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-h3.meta" "window=fm:jg-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  JG_FAKE_BUSY=1
  JG_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export JG_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  JG_FAKE_TMUX_MISSING=1
  JG_FAKE_HERDR_BUSY=1
  JG_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-09 G7 stale-claim incident): a herdr CLI that errors or
# stalls under load made pane_readable's capture fail, and the fallback read
# that single failure as "backend target gone" - text the stale sweep matches
# as positive death - so a busy box briefly scored dozens of live claims dead.
# The reader must separate the two outcomes: only a successful herdr answer
# proving the pane absent may say gone; a CLI that failed to answer is unknown
# and unreachable, never death.
test_no_run_herdr_cli_failure_reads_unreachable_not_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr cli-failure fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-cli-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-cli
  make_fakebin "$d" >/dev/null
  # A herdr whose server is up but whose endpoint calls cannot answer at all:
  # every pane/agent invocation exits non-zero, the busiest-box form of a
  # stalled CLI (capture and pane get alike fail). `status` still answers so
  # the reader probes the endpoint instead of waiting out a server start.
  cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] && { printf '{"server":{"running":true}}\n'; exit 0; }
exit 1
SH
  chmod +x "$d/fakebin/herdr"
  jg_write_meta "$d/state/feat-herdr-cli.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  JG_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-herdr-cli)
  assert_contains "$out" "state: unknown" "a failed herdr CLI must stay unknown"
  assert_contains "$out" "source: none" "a failed herdr CLI has no state source"
  assert_contains "$out" "backend unreachable" "a failed herdr CLI must read as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "a failed herdr CLI is not positive death evidence"
  pass "a herdr CLI that fails to answer reads unknown/unreachable, never gone"
}

# Decision follow-up (2026-09-05 review): an `alive` endpoint answer is
# authoritative even when the heavy scrollback read failed - the live state is
# classified by the normal flow, never discarded as unreachable.
test_no_run_herdr_alive_with_failed_read_stays_live() {
  command -v jq >/dev/null 2>&1 || { pass "herdr alive/read-fail test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-alive-readfail)
  make_repo_on_branch "$d/wt" fm/feat-herdr-alive
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-alive.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  JG_FAKE_TMUX_MISSING=1
  # The 200-line scrollback read fails while the cheap pane get / agent get
  # pair answers: the pane is present and its agent is working.
  JG_FAKE_HERDR_READ_FAIL=1
  JG_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr-alive)
  assert_contains "$out" "state: working" "an alive endpoint with a failed scrollback read stays live"
  assert_not_contains "$out" "backend unreachable" "an authoritative alive answer is never unreachable"
  assert_not_contains "$out" "backend target gone" "an authoritative alive answer is never death"
  pass "an alive endpoint whose scrollback read failed stays working"
}

# Issue #4115: a registration Herdr kept after its Pi exited to a plain shell is
# not an agent. The recovery-grade read proves the process level, so the
# shell-only pane reads as positive agent-gone evidence, never as a live agent
# or as unreachable.
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-registration test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-reg)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-stale.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  JG_FAKE_TMUX_MISSING=1
  JG_FAKE_HERDR_READ_FAIL=1
  JG_FAKE_HERDR_AGENT_STATUS=idle
  JG_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale)
  assert_contains "$out" "state: unknown" "a stale registration over a shell-only pane is not a live state"
  assert_contains "$out" "backend target gone" "a stale registration over a shell-only pane must read as positive agent-gone evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the agent-gone reason must name the remaining shell"
  assert_not_contains "$out" "backend unreachable" "a readable shell-only pane is not unreachable"
  pass "herdr stale registration over a shell-only pane reads agent gone, not alive"
}

# The busy half of the same defect: a `working` record Herdr kept after the
# agent was killed mid-turn must never make a shell-only pane read as working.
test_no_run_herdr_stale_working_record_is_never_busy() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-working test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-working)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale-working
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-stale-working.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  JG_FAKE_TMUX_MISSING=1
  JG_FAKE_HERDR_AGENT_STATUS=working
  JG_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_not_contains "$out" "state: working" "a stale working record over a shell-only pane must never read busy"
  assert_not_contains "$out" "herdr-native" "the native busy verdict must not be trusted for a shell-only pane"
  # The control: the same record with a live harness in the foreground is busy.
  JG_FAKE_HERDR_PROCESS=agent
  out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_contains "$out" "state: working" "the same working record with a live harness process must still read working"
  pass "herdr stale working record never reports a shell-only pane busy"
}

# 2026-10-05 incident: Pi crashed mid-turn, so its extension never posted idle
# and its own busy record kept saying busy over a pane that held only a shell,
# while Herdr's registration still said working. The record cannot carry its
# writer's death, so a busy record must yield to the process-level proof.
test_no_run_herdr_busy_record_over_shell_reads_agent_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr busy-record-over-shell test skipped without jq"; return; }
  reset_fakes
  local d gen out; d=$(new_case herdr-busy-record-shell)
  make_repo_on_branch "$d/wt" fm/feat-herdr-busy-record
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-busy-record.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" feat-herdr-busy-record)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" feat-herdr-busy-record busy --gen "$gen" \
    --source pi-ext --event agent-start
  JG_FAKE_TMUX_MISSING=1
  JG_FAKE_HERDR_AGENT_STATUS=working
  JG_FAKE_HERDR_PROCESS=shell
  out=$(run_crew_state "$d" feat-herdr-busy-record)
  assert_not_contains "$out" "state: working" "a busy record over a shell-only pane must never read working"
  assert_contains "$out" "agent not running under its busy record (dead agent-exited)" "the busy record must yield to the exited harness"
  JG_FAKE_HERDR_PROCESS=agent
  out=$(run_crew_state "$d" feat-herdr-busy-record)
  assert_contains "$out" "state: working" "the same busy record with a live harness must still read working"
  assert_contains "$out" "pi-ext" "the live verdict must come from the busy record"
  # Herdr answers agent_not_found for live harnesses it does not detect, so a
  # missing registration over a running harness is never exit evidence.
  JG_FAKE_HERDR_HUSK=1
  out=$(run_crew_state "$d" feat-herdr-busy-record)
  assert_contains "$out" "state: working" "an unregistered but running harness must still read working"
  pass "a busy record over a pane whose harness exited reads agent gone, and a running one stays working with or without a registration"
}

# Decision follow-up (2026-09-05 review): a husk pane (pane present,
# agent_not_found) is authoritative death evidence - it keeps the gone-class
# text so the stale sweep may still reclaim it, never unknown/unreachable.
test_no_run_herdr_husk_dead_still_reads_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr husk test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-husk-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-husk
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-husk.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  JG_FAKE_TMUX_MISSING=1
  # The pane exists and answers pane get, but no agent is registered in it,
  # and the scrollback read fails besides.
  JG_FAKE_HERDR_READ_FAIL=1
  JG_FAKE_HERDR_HUSK=1
  local out; out=$(run_crew_state "$d" feat-herdr-husk)
  assert_contains "$out" "state: unknown" "a husk pane has no live current state"
  assert_contains "$out" "backend target gone" "a husk pane keeps its gone-class death evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the husk verdict names what actually died"
  assert_not_contains "$out" "backend unreachable" "a husk pane is not an unreachable backend"
  pass "a husk pane (agent gone) still reads gone for reclaim"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# long-running foreground command is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # The crew's semantic busy state is the only remaining signal.
  JG_FAKE_TMUX_MISSING=1
  JG_FAKE_HERDR_AGENT_STATUS=idle
  JG_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  JG_FAKE_TMUX_MISSING=1
  JG_FAKE_HERDR_AGENT_STATUS=idle
  JG_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-i.meta" "window=fm:jg-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-keyed.meta" "window=fm:jg-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-pause.meta" "window=fm:jg-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  printf 'The release window opens tomorrow.\n\n' >> "$d/state/feat-pause.status"
  out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "continuation prose and trailing blanks preserve the pause"
  assert_contains "$out" "holding for the upstream tool release" "multiline pause preserves its declared reason"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_squad_lead_open_block_survives_unrelated_append() {
  reset_fakes
  local d out suffix gen
  d=$(new_case buried-block)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/mate.meta" "window=fm:jg-mate" "worktree=$d/wt" "kind=squad_lead" "harness=claude"
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" mate)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" mate busy --gen "$gen" --source claude-hook --event user-prompt-submit
  for suffix in '' 'note: unrelated progress' 'resolved [key=other]: unrelated answer' 'working: continuing another task' 'done: another task completed' 'failed: another task failed' $'done: another task completed\nnote: cleanup complete' $'failed: another task failed\nnote: cleanup complete'; do
    printf 'blocked [key=access]: need release access\n%s\n' "$suffix" > "$d/state/mate.status"
    out=$(run_crew_state "$d" mate)
    assert_contains "$out" "state: blocked" "open blocker survives '$suffix' with a busy endpoint"
    assert_contains "$out" "need release access" "the open blocker's reason remains visible"
  done
  printf 'resolved [key=access]: access granted\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "matching resolution clears the blocker"
  assert_not_contains "$out" "need release access" "closed blocker is not resurrected"
  pass "a busy squad_lead keeps its open blocker until that exact key closes"
}

test_newest_open_decision_supplies_the_reported_detail() {
  reset_fakes
  local d out gen
  d=$(new_case newest-open-decision)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/mate.meta" "window=fm:jg-mate" "worktree=$d/wt" "kind=squad_lead" "harness=claude"
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" mate)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" mate busy --gen "$gen" --source claude-hook --event user-prompt-submit
  printf 'blocked [key=a]: staging is down\nneeds-decision [key=b]: pick a rollout order\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: parked" "the newer open decision is the reported state"
  assert_contains "$out" "pick a rollout order" "the newer open decision supplies the detail"
  printf 'blocked [key=c]: the deploy host went away\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: blocked" "a newer blocker takes the report back"
  assert_contains "$out" "the deploy host went away" "the newest blocker supplies the detail"
  printf 'resolved [key=c]: host restored\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: parked" "closing the newest decision falls back to the next open one"
  assert_contains "$out" "pick a rollout order" "the still-open older decision is not lost"
  pass "the most recently opened decision supplies the reported state and detail"
}

test_single_owner_terminal_declaration_supersedes_stale_decision() {
  reset_fakes
  local d kind opener terminal out key expected
  d=$(new_case terminal-stale-decision)
  make_repo_on_branch "$d/wt" fm/task
  make_fakebin "$d" >/dev/null
  arm_idle_record "$d/state" task
  for kind in scout ship; do
    jg_write_meta "$d/state/task.meta" "window=fm:jg-task" "worktree=$d/wt" "kind=$kind" "harness=claude"
    for opener in needs-decision blocked; do
      for terminal in 'done' failed; do
        printf '%s [key=choice]: an earlier decision\n%s: final outcome\nContinuation prose.\n\n' \
          "$opener" "$terminal" > "$d/state/task.status"
        out=$(run_crew_state "$d" task)
        assert_contains "$out" "state: $terminal" "$kind terminal declaration supersedes stale $opener"
        assert_contains "$out" "final outcome" "the terminal declaration supplies the detail"
        printf 'note: cleanup complete\n' >> "$d/state/task.status"
        out=$(run_crew_state "$d" task)
        assert_contains "$out" "state: unknown" "$kind cleanup note does not revive a pre-terminal $opener"
        assert_not_contains "$out" "an earlier decision" "superseded decision detail stays absent after cleanup"
        expected=parked
        [ "$opener" != blocked ] || expected=blocked
        for key in choice new-choice; do
          printf '%s [key=%s]: reopened after completion\nnote: more cleanup\n' "$opener" "$key" >> "$d/state/task.status"
          out=$(run_crew_state "$d" task)
          assert_contains "$out" "state: $expected" "$kind retains a post-terminal $opener for $key"
          assert_contains "$out" "reopened after completion" "the reopened decision supplies the detail"
          printf 'resolved [key=%s]: answered\n' "$key" >> "$d/state/task.status"
          out=$(run_crew_state "$d" task)
          assert_contains "$out" "state: unknown" "matching resolution clears the reopened decision"
          assert_not_contains "$out" "an earlier decision" "closing a reopened decision cannot revive pre-terminal decisions"
        done
      done
    done
  done
  pass "ship and scout terminal declarations supersede stale decisions"
}

test_latest_status_preserves_legacy_completions() {
  local d event line
  d=$(new_case latest-legacy)
  for event in 'PR ready https://example.com/pull/1' 'checks green' 'ready in branch fm/topic' merged 'PR READY https://example.com/pull/1'; do
    printf 'paused: awaiting release\n%s\nMore detail: cleanup complete.\n\n' "$event" > "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = "$event" ] || fail "legacy completion '$event' was hidden by an earlier pause"
    status_is_captain_relevant "$line" || fail "legacy completion is no longer captain-relevant"
    status_is_paused "$line" && fail "legacy completion retained pause handling"
    printf 'working: following up on merged work\n' >> "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = 'working: following up on merged work' ] || fail "later working event did not supersede legacy completion"
    status_is_captain_relevant "$line" && fail "legacy prose made a working event captain-relevant"
    printf 'paused: waiting on upstream PR #123 to land\nOnce it is %s I will rebase and continue.\n\n' "$event" > "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = 'paused: waiting on upstream PR #123 to land' ] || fail "continuation prose mentioning '$event' hid a multi-line pause: $line"
    status_is_paused "$line" || fail "a multi-line pause lost pause handling behind prose mentioning '$event'"
  done
  (
    shopt -u nocasematch
    JG_CAPTAIN_RE='custom-event:' status_is_captain_relevant 'CUSTOM-EVENT: ready' || fail "custom captain regex lost case-insensitive matching"
    shopt -q nocasematch && fail "captain matching changed caller shell options"
    JG_CAPTAIN_RE='custom-event:' status_is_captain_relevant 'done: ready' && fail "custom captain regex did not replace defaults"
    shopt -s nocasematch
    status_is_captain_relevant 'unrelated prose' && fail "ordinary prose became captain-relevant"
    shopt -q nocasematch || fail "captain matching cleared caller shell options"
  ) || fail "captain matching changed regex or shell-option behavior"
  pass "latest status retains legacy completion events and shared captain matching"
}

test_latest_status_subshell_work_does_not_grow_with_history() {
  local d size i level small large window
  d=$(new_case latest-processes)
  window=${JG_CLASSIFY_EVENT_WINDOW_LINES:-200}
  for size in "$window" "$((window * 10))"; do
    {
      for ((i = 0; i < size; i++)); do
        printf 'working corr=0123456789abcdef [key=phase]: progress\nMore detail: still working.\n'
      done
      printf 'PR ready https://example.com/pull/1\npaused corr=0123456789abcdef [key=release]: awaiting release\n\n'
    } > "$d/state/task.status"
    : > "$d/children-$size"
    (
      level=$BASH_SUBSHELL
      set -T
      trap 'if [ "$BASH_SUBSHELL" -gt "$level" ]; then printf x >> "$d/children-$size"; fi' DEBUG
      last_status_line "$d/state/task.status" > "$d/output"
    )
    [ "$(cat "$d/output")" = 'paused corr=0123456789abcdef [key=release]: awaiting release' ] \
      || fail "latest status lost correlation-token parsing on a long log"
  done
  small=$(wc -c < "$d/children-$window")
  large=$(wc -c < "$d/children-$((window * 10))")
  [ "$large" -le "$((small + 20))" ] || fail "latest status shell work grows with history ($small -> $large)"
  printf 'paused: awaiting a long quiet tail\n' > "$d/state/task.status"
  for ((i = 0; i < 500; i++)); do printf 'continuation prose %s\n' "$i" >> "$d/state/task.status"; done
  [ "$(last_status_line "$d/state/task.status")" = 'paused: awaiting a long quiet tail' ] \
    || fail "a declared pause buried under a long prose tail was hidden"
  pass "latest status subprocess work stays bounded and still reads past a long prose tail"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-custom-pause.meta" "window=fm:jg-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  JG_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(JG_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(JG_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A lead whose runtime fails every turn keeps no settled pane (each failed turn is
# retried at once), so its current state comes from the watcher's errors wait
# source and reads blocked on every poll until the cause lapses.
test_squad_lead_runtime_error_loop_reads_blocked_steadily() {
  reset_fakes
  local d; d=$(new_case lead-error-loop)
  mkdir -p "$d/wt" "$d/state/.wait-sources"
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/mate.meta" "window=fm:jg-mate" "worktree=$d/wt" "kind=squad_lead" "home=$d/wt"
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  printf 'errors: User not found. (6 times on screen)\n' > "$d/state/.wait-sources/mate.errors"
  local out i
  for i in 1 2 3; do
    JG_FAKE_BUSY=$((i % 2))
    out=$(run_crew_state "$d" mate)
    assert_contains "$out" "state: blocked" "a lead in a runtime error loop reads blocked whatever its pane does (poll $i)"
    assert_contains "$out" "source: pane" "the error loop is read from the pane evidence"
    assert_contains "$out" "User not found." "the repeated error names the cause"
  done
  # The source lapses with the cause: a record nobody rewrote is ignored.
  touch -d '-10 minutes' "$d/state/.wait-sources/mate.errors"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a lapsed error source leaves the status-log state"
  # Another kind of worker is not read this way.
  jg_write_meta "$d/state/mate.meta" "window=fm:jg-mate" "worktree=$d/wt" "kind=ship"
  touch "$d/state/.wait-sources/mate.errors"
  JG_FAKE_BUSY=0
  out=$(run_crew_state "$d" mate)
  assert_not_contains "$out" "runtime failing every turn" "only a lead reads blocked from the error source"
  pass "a lead in a runtime error loop reads blocked on every poll and leaves it when the cause lapses"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle squad_lead that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a squad_lead showed
# state=unknown with resolution prose. The one-owner keyed fold in jg-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_squad_lead_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/mate.meta" "window=fm:jg-mate" "worktree=$d/wt" "kind=squad_lead" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  JG_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle squad_lead is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-dead.meta" "window=fm:jg-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  JG_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  assert_contains "$out" "backend target gone" "an inventory that omits the window is positive death evidence"
  pass "dead window ignores stale status log"
}

# Regression (2026-09 G7 stale-claim incident, tmux half): the default backend
# reached the same false-death path as herdr. A tmux that cannot answer at all
# - a trimmed PATH, or any non-definitive error - made every live crew report
# "backend target gone", the text the stale sweep matches as positive death.
# Absence must be proved by tmux's own answer: a window inventory that omits
# the recorded window, or one of its definitive no-session/no-server/no-socket
# responses. Anything else is a tmux that failed to answer: unknown, never
# death. (A socket-connection error is deliberately NOT in this test's scope -
# jg_backend_tmux_agent_state classifies it as `missing` so jg-bootstrap and
# jg-session-start can respawn after a genuine server death.)
test_no_run_tmux_unreadable_reads_unreachable_not_gone() {
  reset_fakes
  local d; d=$(new_case tmux-unreadable)
  make_repo_on_branch "$d/wt" fm/feat-tmux-unread
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/feat-tmux-unread.meta" "window=fm:jg-feat-tmux-unread" \
    "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-tmux-unread.status"
  JG_FAKE_TMUX_UNREADABLE=1
  local out; out=$(run_crew_state "$d" feat-tmux-unread)
  assert_contains "$out" "state: unknown" "an unreadable tmux must stay unknown"
  assert_contains "$out" "source: none" "an unreadable tmux has no state source"
  assert_contains "$out" "backend unreachable" "an unreadable tmux reads as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "an unreadable tmux is not positive death evidence"
  pass "a tmux that fails to answer reads unknown/unreachable, never gone"
}

# A standard or deep Recon's done is current-state done only past
# bin/jg-recon-gate.sh; a quick Recon's done is not judged by it.
test_recon_done_waits_for_the_depth_gate() {
  reset_fakes
  local d out; d=$(new_case recon-gate)
  make_repo_on_branch "$d/wt" fm/recon-g
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/data"
  jg_write_meta "$d/state/recon-g.meta" "window=fm:jg-recon-g" "worktree=$d/wt" "kind=scout" "harness=claude"
  JG_HOME="$d" JG_DATA_OVERRIDE="$d/data" "$ROOT/bin/jg-brief.sh" recon-g some-proj --scout --depth standard >/dev/null 2>&1 \
    || fail "could not scaffold the standard Recon brief"
  printf 'done: report ready\n' > "$d/state/recon-g.status"
  arm_idle_record "$d/state" recon-g
  out=$(JG_DATA_OVERRIDE="$d/data" run_crew_state "$d" recon-g)
  assert_contains "$out" "state: blocked" "a standard Recon with no report is not done"
  assert_contains "$out" "recon gate refused the done" "the blocked state does not name the gate"
  jg_write_meta "$d/state/recon-q.meta" "window=fm:jg-recon-q" "worktree=$d/wt" "kind=scout" "harness=claude"
  JG_HOME="$d" JG_DATA_OVERRIDE="$d/data" "$ROOT/bin/jg-brief.sh" recon-q some-proj --scout --depth quick >/dev/null 2>&1 \
    || fail "could not scaffold the quick Recon brief"
  printf 'done: report ready\n' > "$d/state/recon-q.status"
  arm_idle_record "$d/state" recon-q
  out=$(JG_DATA_OVERRIDE="$d/data" run_crew_state "$d" recon-q)
  assert_contains "$out" "state: done" "a quick Recon's done is not judged by the depth gate"
  pass "a standard Recon's done is blocked by the depth gate and a quick Recon's is not"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/gone-k.meta" "window=fm:jg-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

# --- remote squad_lead arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real jg-on.sh
# route with a stubbed ssh transport (JG_SSH_BIN seam): the stub prints
# JG_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits JG_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  jg_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=squad_lead" \
    "mode=squad_lead" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=jg-remote" \
    "remote_target=jg-remote:w1:p1"
  cat > "$d/data/squad_leads.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${JG_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$JG_FAKE_REMOTE_STATE_OUT"
exit "${JG_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" \
    JG_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(JG_FAKE_REMOTE_STATE_OUT=alive JG_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "jg-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(JG_FAKE_REMOTE_STATE_OUT=alive JG_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "jg-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(JG_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "jg-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(JG_FAKE_REMOTE_STATE_OUT=dead JG_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "jg-crew-state remote: the remote host's own dead verdict is reported truthfully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

test_squad_lead_open_block_survives_unrelated_append
test_newest_open_decision_supplies_the_reported_detail
test_single_owner_terminal_declaration_supersedes_stale_decision
test_latest_status_preserves_legacy_completions
test_latest_status_subshell_work_does_not_grow_with_history
test_unpushed_ship_done_is_blocked
test_fork_head_on_forge_reads_done
test_merged_pr_reads_done_under_captured_meta
test_moved_remote_branch_without_named_head_is_blocked
test_no_run_busy_pane
test_no_run_launch_prompt_parked_is_not_working
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_cli_failure_reads_unreachable_not_gone
test_no_run_herdr_alive_with_failed_read_stays_live
test_no_run_herdr_husk_dead_still_reads_gone
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_squad_lead_resolved_event_not_state
test_squad_lead_runtime_error_loop_reads_blocked_steadily
test_dead_window_ignores_stale_status_log
test_no_run_tmux_unreadable_reads_unreachable_not_gone
test_recon_done_waits_for_the_depth_gate
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_usage_error
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone
test_no_run_herdr_stale_working_record_is_never_busy
test_no_run_herdr_busy_record_over_shell_reads_agent_gone

echo "all jg-crew-state tests passed"
