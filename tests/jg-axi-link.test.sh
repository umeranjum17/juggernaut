#!/usr/bin/env bash
# Journey for putting `juggernaut-axi` on PATH (migration goal 5, step 1), driven by journeys/axi-on-path.sh.
# A clean machine has no juggernaut-axi on PATH and its migration row is absent. The real session-start
# bootstrap then links it, the row reads live, a second run changes nothing, two homes on one machine
# each get their own bin/juggernaut-axi from one launcher, a deleted home hands the launcher to the
# next one, and a foreign file at the same path is never replaced.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=/usr/bin:/bin
TMP_ROOT=$(jg_test_tmproot jg-axi-link)
unset JG_AXI_LINK_SKIP NPM_CONFIG_PREFIX JG_HOME JG_ROOT_OVERRIDE TMUX TMUX_PANE
export HOME=$TMP_ROOT/user
PREFIX=$HOME/.local
LAUNCHER=$PREFIX/bin/juggernaut-axi
mkdir -p "$HOME"

# The migration row, read from a throwaway home with the forge list pre-seeded so nothing leaves the machine.
row_state() {
  local h=$TMP_ROOT/row-home
  mkdir -p "$h/data/migration-card"
  : > "$h/data/migration-card/prs.tsv"
  PATH="$PREFIX/bin:$BASE_PATH" JG_HOME=$h "$ROOT/bin/jg-migration-live.sh" axi | cut -f2
}

# 1. Before: nothing on PATH, the row is absent.
before=$(PATH="$PREFIX/bin:$BASE_PATH" command -v juggernaut-axi || true)
assert_equals "" "$before" "clean machine has no juggernaut-axi on PATH"
assert_equals absent "$(row_state)" "row is absent before the link"

# 2. The real bootstrap links it for this checkout.
home=$TMP_ROOT/home
mkdir -p "$home/state" "$home/data" "$home/config"
bootstrap() {
  PATH="$PREFIX/bin:$BASE_PATH" JG_HOME=$home JG_ROOT_OVERRIDE=$home JG_STACK_SKIP=1 JG_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/jg-bootstrap.sh" 2>&1
}
out=$(bootstrap)
assert_contains "$out" "BOOTSTRAP_INFO: axi: linked $LAUNCHER" "bootstrap says it linked juggernaut-axi"
assert_equals "$LAUNCHER" "$(PATH="$PREFIX/bin:$BASE_PATH" command -v juggernaut-axi)" "juggernaut-axi is on PATH"
version=$(PATH="$PREFIX/bin:$BASE_PATH" juggernaut-axi --version)
assert_contains "$version" juggernaut-axi "the launcher runs the checkout's juggernaut-axi"
assert_equals live "$(row_state)" "row is live after the link"
pass "bootstrap links juggernaut-axi and the row reads live"

# 3. A second run changes nothing and says nothing about it.
sum=$(cksum < "$LAUNCHER")
out=$(bootstrap)
assert_not_contains "$out" "axi: linked" "second bootstrap is quiet about juggernaut-axi"
assert_equals "$sum" "$(cksum < "$LAUNCHER")" "second run leaves the launcher byte-identical"
pass "a second bootstrap is a no-op"

# 4. Two homes, one launcher. Each home's own bin/juggernaut-axi answers for its own JG_HOME or directory.
rm -rf -- "$PREFIX"
for n in 1 2; do
  mkdir -p "$TMP_ROOT/h$n/bin" "$TMP_ROOT/h$n/state"
  cp "$ROOT/bin/jg-axi-link.sh" "$TMP_ROOT/h$n/bin/"
  printf '#!/usr/bin/env bash\necho "home-%s $*"\n' "$n" > "$TMP_ROOT/h$n/bin/juggernaut-axi"
  chmod +x "$TMP_ROOT/h$n/bin/juggernaut-axi"
done
out=$("$TMP_ROOT/h1/bin/jg-axi-link.sh")
assert_contains "$out" "linked" "first home links"
sum=$(cksum < "$LAUNCHER")
out=$("$TMP_ROOT/h2/bin/jg-axi-link.sh")
assert_equals "" "$out" "second home leaves the working launcher alone"
assert_equals "$sum" "$(cksum < "$LAUNCHER")" "second home does not take the command from the first"
assert_equals "home-1 status" "$(cd "$TMP_ROOT" && "$LAUNCHER" status)" "outside any home the first home answers"
assert_equals "home-2 status" "$(JG_HOME=$TMP_ROOT/h2 "$LAUNCHER" status)" "JG_HOME picks the second home"
assert_equals "home-2 status" "$(cd "$TMP_ROOT/h2/state" && "$LAUNCHER" status)" "the current directory picks the second home"
pass "two homes share one launcher and each answers for itself"

# 5. The first home is deleted: the launcher is repointed by the next home's run, and still answers meanwhile.
rm -rf -- "$TMP_ROOT/h1"
assert_equals "home-2 status" "$(JG_HOME=$TMP_ROOT/h2 "$LAUNCHER" status)" "a deleted home does not break the launcher"
out=$("$TMP_ROOT/h2/bin/jg-axi-link.sh")
assert_contains "$out" "linked" "the second home takes over a launcher whose home is gone"
assert_equals "home-2 status" "$(cd "$TMP_ROOT" && "$LAUNCHER" status)" "the launcher now defaults to the second home"
pass "a deleted home hands the launcher over"

# 6. A file that is not our launcher is never replaced, and bootstrap names it.
rm -rf -- "$PREFIX"
mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\necho mine\n' > "$LAUNCHER"
chmod +x "$LAUNCHER"
out=$(bootstrap)
assert_contains "$out" "AXI_LINK:" "bootstrap names the file it will not replace"
assert_equals "mine" "$("$LAUNCHER")" "a foreign juggernaut-axi is left untouched"
pass "a foreign file is never replaced"

# 7. The one install command plans the link and writes nothing in a dry run.
if command -v node >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
  rm -rf -- "$PREFIX"
  out=$(PATH="$PREFIX/bin:$PATH" bash "$ROOT/install.sh" --home "$home" --dry-run 2>&1)
  assert_contains "$out" "axi: would link $LAUNCHER" "install.sh --dry-run plans the link"
  assert_absent "$LAUNCHER" "install.sh --dry-run writes no launcher"
  pass "install.sh plans the link"
else
  echo "skip: install.sh dry run needs node, git and gh"
fi
