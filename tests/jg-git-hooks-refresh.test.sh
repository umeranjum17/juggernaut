#!/usr/bin/env bash
# A launch hook overlay (state/<id>.git-hooks) written before the installed hook set changed becomes
# current at the next locked session start: bootstrap runs `jg-git-strip-ai-trailers.sh refresh`.
# A directory that is not this installer's own for that path is left alone, and the overlay stays read-only.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A pane running this test carries its own launch overlay in GIT_CONFIG_*; the fixture repos must not inherit it.
unset GIT_CONFIG_COUNT

STRIP="$ROOT/bin/jg-git-strip-ai-trailers.sh"
d=$(jg_test_tmproot jg-hooks-refresh) || fail "no temp root"
mkdir -p "$d/state" "$d/other"
jg_git_init_commit "$d/wt"

"$STRIP" install "$d/state/t1.git-hooks" "$d/wt" || fail "install failed"
hooks=$(cd "$d/state/t1.git-hooks" && pwd -P)
want=$(find "$hooks" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')

# Stale overlay: an older hook set lacked one wrapper, and another wrapper has an older body.
chmod u+w "$hooks"
mv "$hooks/pre-auto-gc" "$d/old-pre-auto-gc"
printf '#!/usr/bin/env bash\nexit 0\n' >"$hooks/pre-push.new"
chmod 500 "$hooks/pre-push.new"
mv -f "$hooks/pre-push.new" "$hooks/pre-push"
chmod 500 "$hooks"

# A copy under another name names the first directory as its own, so it is not ours to touch.
cp -r "$hooks" "$d/state/t2.git-hooks"
chmod u+w "$d/state/t2.git-hooks"
mv "$d/state/t2.git-hooks/post-merge" "$d/other/post-merge"
chmod 500 "$d/state/t2.git-hooks"

out=$("$STRIP" refresh "$d/state" 2>&1) || fail "refresh failed: $out"
assert_contains "$out" "refreshed: $hooks/pre-auto-gc" "the missing wrapper was not restored"
assert_contains "$out" "refreshed: $hooks/pre-push" "the old wrapper body was not replaced"
assert_equals "$want" "$(find "$hooks" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" "the overlay is not the full current set"
assert_equals "500" "$(stat -c %a "$hooks")" "the overlay directory is no longer read-only"
assert_equals "500" "$(stat -c %a "$hooks/pre-auto-gc")" "a refreshed wrapper is not read-only"
pass "a stale overlay becomes current and stays read-only"

[ ! -e "$d/state/t2.git-hooks/post-merge" ] || fail "a directory that is not ours was modified"
pass "a directory the installer did not write for that path is left alone"

out=$("$STRIP" refresh "$d/state" 2>&1) || fail "second refresh failed: $out"
assert_equals "" "$out" "a current overlay was modified"
pass "a current overlay is untouched"

# The locked session-start sweep is what runs it.
# shellcheck disable=SC2016  # the pattern is literal text of the bootstrap source
grep -q 'jg-git-strip-ai-trailers.sh" refresh "\$STATE"' "$ROOT/bin/jg-bootstrap.sh" ||
  fail "bin/jg-bootstrap.sh does not refresh the launch hook overlays"
pass "bootstrap refreshes the overlays at session start"

# The files this journey owns stay ShellCheck-clean, so CI's lint cannot refuse the landing.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$ROOT/bin/jg-git-strip-ai-trailers.sh" "${BASH_SOURCE[0]}" || fail "shellcheck reports findings"
  pass "the installer and this test are shellcheck-clean"
fi
