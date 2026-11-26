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

# A pane that carries the overlay still creates repositories: git writes HEAD through the
# reference-transaction hook before the new repository can be resolved, and the wrapper must not refuse that.
out=$(cd "$d" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks \
  git init -q --bare created.git 2>&1 && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks \
  git clone -q created.git cloned 2>&1) || fail "a repository could not be created under the overlay: $out"
assert_not_contains "$out" "refusing to skip" "the overlay refused a repository that was still being created"
[ -d "$d/cloned/.git" ] || fail "the clone made under the overlay has no repository"
pass "a repository is created under the overlay"

# jg-5hw: a refresh run by a copy of the code that is deleted afterwards (a verify copy, a go-live tool export) must not write
# that copy's path into the hook. The home's own copy stays the target, so a commit after the cleanup still works.
h="$d/home"
mkdir -p "$h/bin" "$h/state" "$h/data/trunk/.verify-code.AbC123/bin"
cp "$STRIP" "$h/bin/" && cp "$STRIP" "$h/data/trunk/.verify-code.AbC123/bin/"
jg_git_init_commit "$h/wt"
"$h/bin/jg-git-strip-ai-trailers.sh" install "$h/state/t3.git-hooks" "$h/wt" || fail "home install failed"
hh=$(cd "$h/state/t3.git-hooks" && pwd -P)
chmod u+w "$hh" && mv "$hh/pre-push" "$d/old-pre-push" && chmod 500 "$hh"
for via in override parent; do
  # Stale in the way an older hook set was: one wrapper gone, so refresh also rewrites the commit-msg text it compares.
  chmod u+w "$hh"
  sed -i "s#$h/bin/jg-git-strip-ai-trailers.sh#/gone/.verify-code.Old/bin/jg-git-strip-ai-trailers.sh#" "$hh/commit-msg"
  chmod 500 "$hh"
  if [ "$via" = override ]; then
    JG_ROOT_OVERRIDE=$h "$h/data/trunk/.verify-code.AbC123/bin/jg-git-strip-ai-trailers.sh" refresh "$h/state" >/dev/null 2>&1 || fail "refresh from the verify copy failed"
  else
    (unset JG_ROOT_OVERRIDE; "$h/data/trunk/.verify-code.AbC123/bin/jg-git-strip-ai-trailers.sh" refresh "$h/state" >/dev/null 2>&1) || fail "refresh from the verify copy failed"
  fi
  assert_not_contains "$(cat "$hh/commit-msg")" ".verify-code" "a refresh from a verify copy wrote the copy's path into the hook ($via)"
  assert_contains "$(cat "$hh/commit-msg")" "$h/bin/jg-git-strip-ai-trailers.sh" "the hook does not name the home's own copy ($via)"
done
rm -rf -- "$h/data/trunk/.verify-code.AbC123"
printf 'x\n' >"$h/wt/f" && git -C "$h/wt" add f
out=$(cd "$h/wt" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hh git -c user.name=t -c user.email=t@example.com commit -q -m "jg-5hw commit after the verify copy is gone" 2>&1) ||
  fail "a commit failed after the verify copy was deleted: $out"
pass "a refresh from a deleted verify copy leaves the hook on the home's own copy"

# The files this journey owns stay ShellCheck-clean, so CI's lint cannot refuse the landing.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$ROOT/bin/jg-git-strip-ai-trailers.sh" "${BASH_SOURCE[0]}" || fail "shellcheck reports findings"
  pass "the installer and this test are shellcheck-clean"
fi
