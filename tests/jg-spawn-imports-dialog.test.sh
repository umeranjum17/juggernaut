#!/usr/bin/env bash
# A claude spawn never answers Claude's "Allow external CLAUDE.md file imports?" dialog. Every key it
# could send (Enter, Escape) selects the decline, which Claude saves in the owner's store and which
# bin/jg-claude-trust.sh then refuses for every later launch of the project. Real bin/jg-brief.sh and
# bin/jg-spawn.sh over a fixture project; only the terminal and the worktree tool are stand-ins.
#
# T1 with the dialog on screen the spawn fails with the cause, sends no key after it showed, and the
#    owner's store holds no decline.
# T2 a second spawn of the same project is not refused as "already declined".
# T3 with no dialog on screen the spawn succeeds.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset JG_SPAWN_TEST_MODEL_OPTIONAL

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-imports-dialog-tests)

W="$TMP_ROOT/world"
HOME_DIR="$W/home"
PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main
git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

jg_test_spawn_home "$HOME_DIR"
FAKEBIN=$(make_spawn_fakebin "$W/fake" claude)
jg_test_fake_sleep_noop "$FAKEBIN"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

# The stand-in terminal shows the imports dialog when JG_FAKE_IMPORTS_DIALOG=1 and logs every bare key.
KEYLOG="$W/keys.log"
: > "$KEYLOG"
sed -i '/^set -u$/a case "$*" in *"capture-pane -p -t"*"-S -0"*) [ "${JG_FAKE_IMPORTS_DIALOG:-0}" = 1 ] || exit 0; printf "DIALOG_SHOWN\n" >> "${JG_FAKE_KEY_LOG:-/dev/null}"; printf "Allow external CLAUDE.md file imports?\\n  1. No, disable external imports\\n  2. Yes, allow external imports\\n"; exit 0 ;; esac\ncase "$*" in *"send-keys"*) for a in "$@"; do case "$a" in Enter|Escape|Down|Up|C-c) printf "%s\\n" "$a" >> "${JG_FAKE_KEY_LOG:-/dev/null}" ;; esac; done ;; esac' "$FAKEBIN/tmux"
export JG_FAKE_KEY_LOG="$KEYLOG"

STORE_HOME="$HOME_DIR/user-home"
spawn() { # <id>
  local id=$1
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" >"$W/brief.out" 2>&1 || { cat "$W/brief.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the dialog./;s/{JUGGERNAUT_SPEC}/Exercise the dialog end to end./' "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$W/wt-$id" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" claude --model claude-haiku-5-5 --mode direct-PR --yolo off 2>&1
}

out=$(JG_FAKE_IMPORTS_DIALOG=1 spawn jg-imp1); rc=$?
[ "$rc" -ne 0 ] || fail "T1: a spawn with the imports dialog showing succeeded: $out"
assert_contains "$out" "no decline was recorded" "T1: the spawn did not name the cause"
grep -q DIALOG_SHOWN "$KEYLOG" || fail "T1: the fake pane never showed the dialog"
after=$(sed -n '/DIALOG_SHOWN/,$p' "$KEYLOG" | grep -v DIALOG_SHOWN)
[ -z "$after" ] || fail "T1: the spawn sent a key after the dialog showed: $after"
if [ -f "$STORE_HOME/.claude.json" ] && grep -q 'hasClaudeMdExternalIncludesApproved' "$STORE_HOME/.claude.json"; then
  fail "T1: the owner's store gained an imports record"
fi
pass "T1 the dialog stays unanswered and nothing is recorded"

out=$(JG_FAKE_IMPORTS_DIALOG=1 spawn jg-imp2); rc=$?
case $out in *"already declined"*) fail "T2: a later spawn was refused as already declined: $out" ;; esac
pass "T2 a later spawn is not refused for a decline"

out=$(spawn jg-imp3) || fail "T3: a spawn with no dialog failed: $out"
pass "T3 a spawn with no dialog succeeds"
