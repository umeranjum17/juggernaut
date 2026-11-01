#!/usr/bin/env bash
# Table regressions for the permission-prompt gate (bin/jg-prompt-gate.py and
# bin/jg-prompt-gate-lib.sh): which OpenCode "Access external directory"
# dialogs are approved, and that every other shape, path escape, or unprovable
# reading becomes a card. Screens copy the layout captured live from OpenCode
# 1.18.25; a `|` in a path marks where OpenCode wrapped it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/jg-prompt-gate.py"
TMP_ROOT=$(jg_test_tmproot jg-prompt-gate)
F="$TMP_ROOT/fleet"
SIDE='                                        LSP'

mkdir -p "$F/state/task1.inbox" "$F/state/pending-replies" "$F/bin" "$F/data" "$F/config" "$F/projects" "$F/.agents/skills/s" "$F/wt/src" "$F/wt/.docker" \
  "$TMP_ROOT/fleet-evil/bin" "$TMP_ROOT/outside" "$TMP_ROOT/fle et/bin" "$TMP_ROOT/user/.config/gh"
for f in state/task1.inbox/001.msg state/task1.inbox/.env state/task1.status state/task1x.status \
  state/other.status bin/a.sh AGENTS.md data/x config/y projects/p .agents/skills/s/SKILL.md wt/src/a.js wt/.npmrc wt/id_rsa \
  wt/.docker/config.json wt/config.api_key wt/.env.local wt/src/environment.ts; do : > "$F/$f"; done
: > "$TMP_ROOT/user/.config/gh/hosts.yml"
: > "$TMP_ROOT/fleet-evil/bin/a.sh"
: > "$TMP_ROOT/outside/f"
: > "$TMP_ROOT/fle et/bin/a.sh"
ln -s "$TMP_ROOT/outside/f" "$F/state/task1.inbox/link"
ln -s "$F/data/x" "$F/state/task1.inbox/data-link"

# Message-area lines: the head at indent 5, each wrap at indent 7.
msg() {  # <glyph+tool> <path-with-|>
  local first=${2%%|*} rest=${2#*|}
  printf '     %s %s%s\n' "$1" "$first" "$SIDE"
  [ "$rest" = "$2" ] && return 0
  printf '%s\n' "$rest" | tr '|' '\n' | sed 's/^/       /'
}

# Panel lines: the dialog header at indent 4 (wraps at 6), patterns at indent 2.
screen() {  # <pending-tool> <target> <dir> [pattern] [extra-turn-lines]
  local pattern=${4:-$3/*} p
  printf '  \342\224\203  an earlier message\n     \342\226\243  Build \302\267 Model \302\267 1m 9s\n\n'
  printf '  \342\224\203  read your inbox\n%s' "${5-}"
  printf '     + Thought: 347ms\n'
  msg "$1" "$2"
  printf '     \342\226\243  Build \302\267 Model\n\n  \342\224\203\n  \342\224\203  \342\226\263 Permission required\n'
  printf '  \342\224\203    \342\206\220 Access external directory %s\n' "${3%%|*}"
  [ "${3#*|}" = "$3" ] || printf '%s\n' "${3#*|}" | tr '|' '\n' | sed 's/^/  \xe2\x94\x83      /'
  printf '  \342\224\203\n  \342\224\203  Patterns\n  \342\224\203                                                 sidebar\n'
  p=${pattern%%|*}
  printf '  \342\224\203  - %s%s\n' "$p" "$SIDE"
  [ "${pattern#*|}" = "$pattern" ] || printf '%s\n' "${pattern#*|}" | tr '|' '\n' | sed "s/^/  \xe2\x94\x83  /; s/\$/$SIDE/"
  printf '  \342\224\203\n  \342\224\203   Allow once   Allow always   Reject          ctrl+f fullscreen  enter confirm\n'
}

ROOTS=(--dir "inbox=$F/state/task1.inbox" --state-files "state=$F/state/task1"
  --dir "pending-replies=$F/state/pending-replies" --dir "tooling=$F/bin" --file "tooling=$F/AGENTS.md"
  --dir "tooling=$F/.agents/skills" --dir "worktree=$F/wt" --file "home-dir=$F" --file "state-dir=$F/state"
  --secret "$F/data" --secret "$F/config" --secret "$TMP_ROOT/user/.config")
READ=$'\342\240\264 Read'

case_is() {  # <name> <expected verdict> <expected second field substring> <screen>
  local out
  out=$(printf '%s\n' "$4" | python3 "$GATE" opencode "${ROOTS[@]}")
  case "$out" in
    "$2"$'\t'*"$3"*) ;;
    "$2") [ -z "$3" ] || fail "$1: expected '$2 ... $3', got: $out" ;;
    *) fail "$1: expected '$2 ... $3', got: $out" ;;
  esac
}

test_allowed_reads_are_approved() {
  case_is "inbox message, wrapped" approve inbox "$(screen "$READ" "$F/state/|task1.inbox/001.msg" "$F/state/|task1.inbox")"
  case_is "own status file" approve state "$(screen "$READ" "$F/state/task1.status" "$F/state")"
  case_is "pending-replies directory" approve pending-replies "$(screen "$READ" "$F/state/pending-replies" "$F/state/pending-replies")"
  case_is "home tooling" approve tooling "$(screen "$READ" "$F/bin/a.sh" "$F/bin")"
  case_is "home AGENTS.md" approve tooling "$(screen "$READ" "$F/AGENTS.md" "$F")"
  case_is "the home folder itself" approve home-dir "$(screen "$READ" "$F" "$F")"
  case_is "the state folder itself" approve state-dir "$(screen "$READ" "$F/state" "$F/state")"
  case_is "skill under a dot root" approve tooling "$(screen "$READ" "$F/.agents/skills/s/SKILL.md" "$F/.agents/skills/s")"
  case_is "worktree source" approve worktree "$(screen "$READ" "$F/wt/src/a.js" "$F/wt/src")"
  case_is "finished reads earlier in the step" approve inbox "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg $'\342\206\222 Read' "$F/bin/a.sh")"$'\n')"
  pass "reads of the fleet's own files are approved, wrapped or not"
}

test_disallowed_paths_are_cards() {
  case_is "another task's status" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/other.status" "$F/state")"
  case_is "prefix-sibling task id" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/task1x.status" "$F/state")"
  case_is "prefix-sibling home" card "outside this fleet's own roots" "$(screen "$READ" "$TMP_ROOT/fleet-evil/bin/a.sh" "$TMP_ROOT/fleet-evil/bin")"
  case_is "a folder below the home" card "outside this fleet's own roots" "$(screen "$READ" "$F/projects/p" "$F/projects")"
  case_is "dotfile in the worktree" card "hidden or credential-like path" "$(screen "$READ" "$F/wt/.npmrc" "$F/wt")"
  case_is "ssh key in the worktree" card "credential-like path" "$(screen "$READ" "$F/wt/id_rsa" "$F/wt")"
  case_is "dot directory in the worktree" card "hidden or credential-like path" "$(screen "$READ" "$F/wt/.docker/config.json" "$F/wt/.docker")"
  case_is "api key name in the worktree" card "credential-like path" "$(screen "$READ" "$F/wt/config.api_key" "$F/wt")"
  case_is "symlink out of the inbox" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/task1.inbox/link" "$F/state/task1.inbox")"
  case_is ".. out of the inbox" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/task1.inbox/../../projects/p" "$F/state/task1.inbox/../../projects")"
  case_is "missing path" card "read path does not exist" "$(screen "$READ" "$F/state/task1.inbox/nope" "$F/state/task1.inbox")"
  case_is "a dropped space at a wrap reads outside" card "outside this fleet's own roots" "$(screen "$READ" "$TMP_ROOT/fle|et/bin/a.sh" "$TMP_ROOT/fle|et/bin")"
  pass "paths outside the roots, escapes, and ambiguous wraps are cards"
}

# Rung one's other half: a secrets path is rejected at once, whatever the call,
# and every other path keeps its approve-or-card verdict.
test_secrets_are_rejected() {
  case_is ".env in the inbox" reject "secrets path"$'\t'"$F/state/task1.inbox/.env" "$(screen "$READ" "$F/state/task1.inbox/.env" "$F/state/task1.inbox")"
  case_is ".env.local in the worktree" reject "secrets path"$'\t'"$F/wt/.env.local" "$(screen "$READ" "$F/wt/.env.local" "$F/wt")"
  case_is "home data/ folder" reject "secrets path"$'\t'"$F/data" "$(screen "$READ" "$F/data" "$F/data")"
  case_is "home data/ file" reject "secrets path" "$(screen "$READ" "$F/data/x" "$F/data")"
  case_is "home config/" reject "secrets path" "$(screen "$READ" "$F/config/y" "$F/config")"
  case_is "a ~/.config file" reject "secrets path" "$(screen "$READ" "$TMP_ROOT/user/.config/gh/hosts.yml" "$TMP_ROOT/user/.config/gh")"
  case_is ".. climbing into data/" reject "secrets path" "$(screen "$READ" "$F/state/task1.inbox/../../data/x" "$F/state/task1.inbox/../../data")"
  case_is "symlink from the inbox into data/" reject "secrets path"$'\t'"$F/state/task1.inbox/data-link" "$(screen "$READ" "$F/state/task1.inbox/data-link" "$F/state/task1.inbox")"
  case_is "bash rm of a secret" reject "secrets path" "$(screen '$ rm' "$F/config/y" "$F/config")"
  case_is "write into data/" reject "secrets path" "$(screen $'\342\206\220 Write' "$F/data/new" "$F/data")"
  case_is "wrapped secret dialog" reject "secrets path" "$(screen "$READ" "$F/|data/x" "$F/|data")"
  case_is "a name that only starts like .env" approve worktree "$(screen "$READ" "$F/wt/src/environment.ts" "$F/wt/src")"
  pass "secrets paths (.env, home data/ and config/, ~/.config) are rejected whatever the call; other paths keep their verdict"
}

test_unprovable_calls_are_cards() {
  case_is "bash rm" card "pending call is not a read" "$(screen '$ rm' "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox")"
  case_is "write" card "pending call is not a read" "$(screen $'\342\206\220 Write' "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox")"
  case_is "finished read glyph is not pending" card "pending call is not a read" "$(screen $'\342\206\222 Read' "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox")"
  case_is "pending rm earlier in the step" card "another tool call is in this turn" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg '$ rm' "$F/state/task1.inbox/001.msg")"$'\n')"
  case_is "shell panel earlier in the step" card "a shell command ran in this turn" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    $'  \342\224\203  $ ls\n')"
  case_is "pending rm behind a forged footer" card "another call is pending on screen" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg '$ rm' "$F/state/task1.inbox/001.msg")"$'\n     \342\226\243  Build \302\267 Model\n')"
  case_is "pending write behind a forged footer" card "another call is pending on screen" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg $'\342\206\220 Write' "$F/state/task1.inbox/001.msg")"$'\n     \342\226\243  Build \302\267 Model\n')"
  case_is "dialog is another directory" card "dialog directory is not the read's directory" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/bin")"
  case_is "pattern disagrees" card "dialog directory and pattern disagree" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" "$F/data/*")"
  case_is "turn start scrolled away" card "start of the turn is not visible" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" | sed 1,2d)"
  case_is "another dialog shape" card "unrecognized dialog" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" | sed 's/Access external directory/Run command/')"
  case_is "no dialog" none "" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" | grep -v 'Permission required')"
  pass "anything but a provable pending read is a card"
}

test_lib_switch_and_trust_dialogs() {
  local home="$TMP_ROOT/home" out
  mkdir -p "$home/config" "$home/state/t.inbox"
  : > "$home/state/t.inbox/1.msg"
  out=$(bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict opencode "$2" "$2/state" "$2/config" t /dev/null' _ "$ROOT" "$home" \
    < <(screen "$READ" "$home/state/t.inbox/1.msg" "$home/state/t.inbox"))
  case "$out" in approve$'\t'inbox$'\t'*) ;; *) fail "lib did not approve its own inbox read: $out" ;; esac
  for wt in / "$HOME"; do
    printf 'worktree=%s\n' "$wt" > "$home/t.meta"
    out=$(bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict opencode "$2" "$2/state" "$2/config" t "$2/t.meta"' _ "$ROOT" "$home" \
      < <(screen "$READ" "$home/state/t.inbox/1.msg" "$home/state/t.inbox"))
    case "$out" in card$'\t'"the prompt matcher could not run"*) ;; *) fail "a recorded worktree of $wt was trusted as a root: $out" ;; esac
  done
  : > "$home/config/prompt-approve-off"
  out=$(bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict opencode "$2" "$2/state" "$2/config" t /dev/null' _ "$ROOT" "$home" \
    < <(screen "$READ" "$home/state/t.inbox/1.msg" "$home/state/t.inbox"))
  case "$out" in card$'\t'"auto-approval is off"*$'\t'"$home/state/t.inbox/1.msg"$'\t'*) ;; *) fail "config/prompt-approve-off did not turn the approval into a card: $out" ;; esac
  out=$(printf 'Trust project folder?\n> Trust\n  Do not trust\n' | bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict pi "$2" "$2/state" "$2/config" t /dev/null' _ "$ROOT" "$home")
  case "$out" in card$'\t'"a trust dialog is never auto-approved"*) ;; *) fail "a Pi trust dialog was not a card: $out" ;; esac
  pass "a root at / or the user home, the off switch, and trust dialogs are all cards"
}

# The real watcher over a pane that never leaves its prompt: no scan between
# them shows the pane unblocked, yet the wait is never dropped. An approvable
# read is approved again every interval, a secrets read is rejected and the
# worker is told why, and any other prompt wakes Main once and is then
# re-alerted every interval by the wait-timers chain.
test_prompt_still_up_is_acted_on_every_interval() {
  command -v tmux >/dev/null 2>&1 || { printf '# skip: tmux not found\n'; return 0; }
  local lab w=jglab:jg-lead1 n approvals wakes ack ack_args
  lab=$("$ROOT/bin/jg-lab-home.sh" create "$TMP_ROOT/lab")
  TMUX_TMPDIR=$("$ROOT/bin/jg-lab-home.sh" tmux-dir "$lab")
  export TMUX_TMPDIR
  trap 'tmux kill-server 2>/dev/null; "$ROOT/bin/jg-lab-home.sh" teardown "'"$lab"'" >/dev/null 2>&1; jg_test_cleanup' EXIT
  mkdir -p "$lab/state/lead1.inbox" "$lab/signoff" "$lab/projects" "$TMP_ROOT/lead"
  : > "$lab/state/lead1.inbox/001.msg"
  : > "$lab/data/x"
  : > "$lab/projects/x"
  screen "$READ" "$lab/state/lead1.inbox/001.msg" "$lab/state/lead1.inbox" > "$TMP_ROOT/approvable.txt"
  screen "$READ" "$lab/projects/x" "$lab/projects" > "$TMP_ROOT/outside.txt"
  screen "$READ" "$lab/data/x" "$lab/data" > "$TMP_ROOT/secret.txt"
  printf 'window=%s\nendpoint_task_id=lead1\nworktree=%s\nhome=%s\nharness=opencode\nkind=squad_lead\nmode=squad_lead\nyolo=off\nbackend=tmux\n' \
    "$w" "$TMP_ROOT/lead" "$TMP_ROOT/lead" > "$lab/state/lead1.meta"
  show() { tmux respawn-pane -k -t "$w" "stty -echo; cat '$1'; exec sleep 999999" 2>/dev/null \
    || tmux new-session -d -s jglab -n jg-lead1 -x 220 -y 60 "stty -echo; cat '$1'; exec sleep 999999"; sleep 1; }
  watch_until() {  # <out> <pattern> <count>: rerun the watcher, which exits on each wake
    : > "$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      JG_HOME="$lab" SIGN_OFF_HOME="$lab/signoff" JG_POLL=1 JG_PROMPT_REALERT_SECS=3 \
        JG_WAIT_ALERT_SECS=1 JG_WAIT_ESCALATE_SECS=999998 JG_WAIT_CARD_SECS=999999 \
        JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 timeout 20 "$ROOT/bin/jg-watch.sh" >> "$1" 2>&1
      # Main drains and acknowledges each wake before the watcher is re-armed.
      JG_HOME="$lab" JG_STATE_OVERRIDE="$lab/state" "$ROOT/bin/jg-wake-drain.sh" >/dev/null 2>"$TMP_ROOT/drain.err"
      ack=$(sed -n 's/^WAKE_ACK_REQUIRED: *//p' "$TMP_ROOT/drain.err")
      read -ra ack_args <<< "${ack#*jg-wake-drain.sh}"
      [ -z "$ack" ] || JG_HOME="$lab" JG_STATE_OVERRIDE="$lab/state" "$ROOT/bin/jg-wake-drain.sh" \
        "${ack_args[@]}" >/dev/null 2>&1 || fail "the wake acknowledgement failed: $(cat "$TMP_ROOT/drain.err")"
      [ "$(grep -c "$2" "$1")" -lt "$3" ] || return 0
    done
  }

  # An identical urgent wake inside the re-alert window is downgraded to batch
  # (jg_wake_append_locked), so Main is woken once at first sight and every
  # later rung is the wait-timers chain's check wake, as for any other prompt.
  show "$TMP_ROOT/approvable.txt"
  watch_until "$TMP_ROOT/a.out" "check: waiting-state lead1 (prompt, .*level=owner; still open" 3
  approvals=$(grep -c '"root":"inbox"' "$lab/state/prompt-approvals.jsonl" 2>/dev/null || true)
  wakes=$(grep -c "stale: $w (permission prompt: .*not answered: inbox; the approval sent under a minute ago did not take" "$TMP_ROOT/a.out" || true)
  n=$(grep -c "check: waiting-state lead1 (prompt, .*level=owner; still open.* source=\[prompt: Access external directory $lab/state/lead1.inbox" "$TMP_ROOT/a.out" || true)
  [ "${approvals:-0}" -ge 3 ] && [ "$wakes" -eq 1 ] && [ "$n" -ge 2 ] \
    || fail "an approvable prompt left on screen was not re-approved every interval, woken once, and re-alerted by the chain (approvals=$approvals wakes=$wakes re-alerts=$n): $(cat "$TMP_ROOT/a.out")"

  show "$TMP_ROOT/secret.txt"
  watch_until "$TMP_ROOT/s.out" "stale: $w (permission prompt" 1
  grep -q "rejected permission prompt (secrets path): $w $lab/data" "$lab/state/.watch-triage.log" \
    || fail "a secrets read was not rejected: $(cat "$TMP_ROOT/s.out")"
  grep -rq "Supervision rejected your permission prompt .*$lab/data is a secrets path" "$lab/state/lead1.inbox" \
    || fail "the rejected worker was not told why: $(ls "$lab/state/lead1.inbox")"
  grep -q "stale: $w (permission prompt: .*not answered: secrets path; the rejection sent under a minute ago did not take" "$TMP_ROOT/s.out" \
    || fail "a rejection that did not take was not reported: $(cat "$TMP_ROOT/s.out")"

  show "$TMP_ROOT/outside.txt"
  watch_until "$TMP_ROOT/b.out" "check: waiting-state lead1 (prompt, .*level=owner; still open" 2
  n=$(grep -c "stale: $w (permission prompt: .*not answered: outside this fleet's own roots" "$TMP_ROOT/b.out" || true)
  [ "$n" -eq 1 ] || fail "an unanswered prompt did not wake Main exactly once at first sight (wakes=$n): $(cat "$TMP_ROOT/b.out")"
  n=$(grep -c "check: waiting-state lead1 (prompt, .*level=owner; still open.* source=\[prompt: Access external directory $lab/projects" "$TMP_ROOT/b.out" || true)
  [ "$n" -ge 2 ] || fail "an unanswered prompt was not re-alerted every interval by the chain (re-alerts=$n): $(cat "$TMP_ROOT/b.out")"
  [ "$(grep -c '"root"' "$lab/state/prompt-approvals.jsonl")" = "$approvals" ] || fail "a read outside the roots was approved"
  pass "a prompt that never leaves the screen is approved, rejected, or re-alerted again every interval"
}

test_allowed_reads_are_approved
test_disallowed_paths_are_cards
test_secrets_are_rejected
test_unprovable_calls_are_cards
test_lib_switch_and_trust_dialogs
test_prompt_still_up_is_acted_on_every_interval
