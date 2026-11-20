#!/usr/bin/env bash
# tests/jg-send-trunk-rebase.test.sh - jg-send refuses a steer that tells a local-trunk lane to rebase.
#
# The landing check rebases a trunk lane's commit itself, so a rebase steer is right only after the lander refused the
# lane's current head for a conflict (data/jg-trunk-landing/<task>.<head>.state, written by core/trunk-landing/verdict.sh).
#   T1 local-trunk lane, no refusal on its head, "please rebase on the tip": exit 2, nothing in the inbox.
#   T2 the same with --allow-rebase-steer: sent.
#   T3 a direct-PR lane: sent.
#   T4 a local-trunk lane and a text without the word: sent.
#   T5 a local-trunk lane whose head has a conflict refusal on file: sent.
#   T6 a local-trunk lane, no refusal, a text that says it never rebases: sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/jg-send.sh"
TMP_ROOT=$(jg_test_tmproot jg-send-trunk-rebase)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# A home with one lane t1 (mode $2) whose worktree is a real one-commit repo; echoes the case dir.
setup_case() { # <name> <mode>
  local dir=$TMP_ROOT/$1 fb
  mkdir -p "$dir/home/state" "$dir/wt" "$dir/fakebin"
  git -C "$dir/wt" init -q . && git -C "$dir/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c
  fb=$dir/fakebin
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf 'fakepane\n' ;;
  capture-pane) printf '+--+\n|  |\n+--+\n' ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
  jg_write_meta "$dir/home/state/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude" "mode=$2" "worktree=$dir/wt"
  printf '%s\n' "$dir"
}

send() { # <case-dir> <args...>; stdout and stderr land in <case-dir>/send.out
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" JG_ROOT_OVERRIDE="$dir/home" JG_HOME="$dir/home" JG_SEND_SETTLE=0 \
    "$SEND" "$@" >"$dir/send.out" 2>&1
}

sent() { [ -f "$1/home/state/t1.inbox/001.msg" ]; }

T1() {
  local dir rc
  dir=$(setup_case t1 local-trunk)
  send "$dir" t1 "please rebase on the tip"
  rc=$?
  expect_code 2 "$rc" "a rebase steer to a local-trunk lane with no refusal should exit 2"
  assert_contains "$(cat "$dir/send.out")" "a local-trunk lane never rebases" "the refusal should say why"
  ! sent "$dir" || fail "the refused steer reached the inbox"
  pass "jg-send: a rebase steer to a local-trunk lane with nothing refused is refused"
}

T2() {
  local dir
  dir=$(setup_case t2 local-trunk)
  send "$dir" t1 --allow-rebase-steer "please rebase on the tip" || fail "--allow-rebase-steer should send: $(cat "$dir/send.out")"
  sent "$dir" || fail "the allowed steer was not recorded"
  pass "jg-send: --allow-rebase-steer lets the steer through"
}

T3() {
  local dir
  dir=$(setup_case t3 direct-PR)
  send "$dir" t1 "please rebase on the tip" || fail "a direct-PR lane should be sent the steer: $(cat "$dir/send.out")"
  sent "$dir" || fail "the direct-PR steer was not recorded"
  pass "jg-send: a rebase steer to a direct-PR lane is sent"
}

T4() {
  local dir
  dir=$(setup_case t4 local-trunk)
  send "$dir" t1 "please continue with the tests" || fail "a text without the word should be sent: $(cat "$dir/send.out")"
  sent "$dir" || fail "the steer was not recorded"
  pass "jg-send: a local-trunk lane still gets a text without the word"
}

T5() {
  local dir head
  dir=$(setup_case t5 local-trunk)
  head=$(git -C "$dir/wt" rev-parse HEAD)
  mkdir -p "$dir/home/data/jg-trunk-landing"
  printf 'final chore/t1 conflicts with release/v12 (%s) in: a.sh\n' "$head" >"$dir/home/data/jg-trunk-landing/t1.$head.state"
  send "$dir" t1 "rebase onto the tip and resolve the conflict" || fail "a lane refused for a conflict should be sent the steer: $(cat "$dir/send.out")"
  sent "$dir" || fail "the steer was not recorded"
  pass "jg-send: a rebase steer is sent when the lander refused this head for a conflict"
}

T6() {
  local dir t
  dir=$(setup_case t6 local-trunk)
  for t in "you never rebase for it; wait for the landing" "do not rebase" "don't rebase" "no rebase is needed"; do
    send "$dir" t1 "$t" || fail "a mention of rebase ('$t') should be sent: $(cat "$dir/send.out")"
  done
  sent "$dir" || fail "the steer was not recorded"
  pass "jg-send: a text that mentions a rebase without asking for one is sent"
}

T1
T2
T3
T4
T5
T6
