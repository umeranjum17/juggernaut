#!/usr/bin/env bash
# Fixture proof for repo-guard in a throwaway HOME and a fixture fork clone whose origin is our own repository and which carries the parent repository as a second remote - the shape that produced six phantom pull requests upstream.
# The real guard runs through its installed gh/gh-axi shims and the real git pre-push hook, with stubs that only record their argv, so nothing here touches a real gh, GitHub or a real home.
# Usage: repo-guard/tests/repo-guard.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
GISRC=$(cd "$SRC/../git-identity" && pwd -P)
d=$(mktemp -d)
trap 'chmod -R u+w -- "$d"; rm -rf -- "$d"' EXIT
for v in $(env | sed -n 's/^\(GIT_CONFIG_[A-Z_0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_PARAMETERS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE
export HOME=$d/home XDG_DATA_HOME=$d/data XDG_CONFIG_HOME=$d/xdg TMPDIR=$d GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$d/global.gitconfig
mkdir -p "$HOME/.local/bin" "$XDG_CONFIG_HOME" "$d/stub" "$d/npm" "$d/fm/config"
: >"$d/global.gitconfig"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then printf 'FAIL: %s\n  unwanted text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); else echo "ok: $1"; fi; }
run() { OUT=$(cd "$d/clone" && "$@" 2>&1) && RC=0 || RC=$?; }

# The real gh-axi is a symlink into a package, so the fixture gives it that shape; gh is a
# plain wrapper script. Both are argv-recording stubs.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\nexit 0\n' "$d/calls" >"$d/npm/gh-axi.js"
chmod +x "$d/npm/gh-axi.js"
ln -s "$d/npm/gh-axi.js" "$d/stub/gh-axi"
cp "$d/npm/gh-axi.js" "$HOME/.local/bin/gh"
export PATH=$d/stub:$HOME/.local/bin:$PATH

git init -q --bare -b main "$d/fork.git"
git clone -q "$d/fork.git" "$d/clone"
git -C "$d/clone" -c user.name=You -c user.email=you@example.com commit -q --allow-empty -m base
git -C "$d/clone" push -q origin main
git -C "$d/clone" remote set-url origin https://github.com/umeranjum17/juggernaut.git
git -C "$d/clone" remote add parent https://github.com/kunchenguid/juggernaut.git
git -C "$d/clone" remote add local "$d/fork.git"

has "install guards gh" "$("$SRC/wiring.sh")" "guarded: $HOME/.local/bin/gh "
"$GISRC/wiring.sh" --email you@example.com --name You "$d/fm" >/dev/null
lacks "the package's own gh-axi file is not overwritten" "$(cat "$d/npm/gh-axi.js")" "repo-guard"

# Kill the installer while its reference copy is partial. The old executable must survive.
mkdir -p "$d/interrupt-bin"
# shellcheck disable=SC2016 # The fixture script expands these variables when invoked.
printf '%s\n' '#!/usr/bin/env bash' 'case "$2" in *.source.tmp.*) dd if="$1" of="$2" bs=1024 count=128 status=none; kill -KILL "$PPID"; exit 1;; esac' 'exec /usr/bin/cp "$@"' >"$d/interrupt-bin/cp"
chmod +x "$d/interrupt-bin/cp"
old_hash=$(sha256sum "$XDG_DATA_HOME/jg-repo-guard/repo-guard" | cut -d' ' -f1)
(PATH="$d/interrupt-bin:$PATH" "$SRC/wiring.sh" >/dev/null 2>&1) 2>/dev/null || true
check "interrupted install preserves the complete executable" "$(sha256sum "$XDG_DATA_HOME/jg-repo-guard/repo-guard" | cut -d' ' -f1)/$([ -x "$XDG_DATA_HOME/jg-repo-guard/repo-guard" ] && echo executable)" "$old_hash/executable"
run gh --version
check "gh still works after interrupted install" "$RC" 0

# Each corrupt state must be repaired on the next real call, with one alert.
for damage in mode truncated changed absent; do
  cp "$XDG_DATA_HOME/jg-repo-guard/repo-guard" "$d/damaged"
  case "$damage" in
    mode) chmod 644 "$d/damaged" ;;
    truncated) truncate -s 131072 "$d/damaged" ;;
    changed) printf X | dd of="$d/damaged" bs=1 seek=100 conv=notrunc status=none ;;
    absent) rm "$d/damaged" ;;
  esac
  if [ "$damage" = absent ]; then rm "$XDG_DATA_HOME/jg-repo-guard/repo-guard"; else mv "$d/damaged" "$XDG_DATA_HOME/jg-repo-guard/repo-guard"; fi
  run gh --version
  check "$damage guard is repaired" "$RC" 0
  check "$damage emits one alert" "$(printf '%s\n' "$OUT" | grep -c 'repo-guard: broken guard detected; reinstalling')" 1
  check "$damage restores the reference" "$(cmp -s "$XDG_DATA_HOME/jg-repo-guard/repo-guard.source" "$XDG_DATA_HOME/jg-repo-guard/repo-guard" && echo equal)" equal
done

mv "$XDG_DATA_HOME/jg-repo-guard/repo-guard.source" "$d/reference"
run gh --version
check "missing reference refuses the call" "$RC" 1
has "missing reference names recovery" "$OUT" "reference unavailable"
mv "$d/reference" "$XDG_DATA_HOME/jg-repo-guard/repo-guard.source"

# A write with no --repo in a fork clone resolves this clone's origin, never the parent
# remote, and reaches the stub with that repository made explicit. Both directions: the parent
# repository is refused by name, our own repository passes.
run gh-axi pr create --title t --body b
check "create on our own origin succeeds with the repo pinned" "$RC/$(tail -n 1 "$d/calls")" "0/pr create --title t --body b --repo umeranjum17/juggernaut"
lacks "the parent repository is never resolved by default" "$(cat "$d/calls")" "kunchenguid/juggernaut"
before=$(wc -l <"$d/calls")
run gh-axi pr create --repo kunchenguid/juggernaut --title t --body b
check "create against the parent is refused" "$RC" 1
has "the refusal names the refused repository" "$OUT" "kunchenguid/juggernaut"
has "the refusal names the allow-listed alternative" "$OUT" "umeranjum17/*"
check "a refused create never reaches gh-axi" "$(wc -l <"$d/calls")" "$before"
for cmd in "pr comment 1 --body b" "pr review 1 --approve" "issue create --title t"; do
  # shellcheck disable=SC2086 # the fixture splits one intended command line
  run gh-axi $cmd -R kunchenguid/juggernaut
  check "$cmd against the parent is refused" "$RC" 1
done
run gh-axi pr comment 1 --body b --repo=umeranjum17/juggernaut
check "a comment on our own repository passes" "$RC" 0
run gh pr create --repo kunchenguid/juggernaut --title t --body b
check "a plain gh create against the parent is refused" "$RC" 1
run gh pr create --title t --body b
check "a plain gh create on our own origin passes" "$RC" 0
run gh-axi pr view 1
check "a read command passes through" "$RC" 0

# The push side: repo-guard is the git pre-push extension git-identity chains, and the lane
# env resolves that hooks dir as the one git runs. The hook is invoked with git's own argv
# shape (<remote> <url>) so no network is needed to prove the refusal.
# shellcheck source=/dev/null
lane() (cd "$d/clone" && "$d/fm/config/launch-env-hook" "$d/env.sh" && . "$d/env.sh" && "$@")
hooks=$(lane git rev-parse --path-format=absolute --git-path hooks)
check "the lane's hooks dir is the one git runs" "$hooks" "$XDG_DATA_HOME/jg-git-identity/hooks"
hook() { OUT=$(printf '' | "$hooks/pre-push" "$@" 2>&1) && RC=0 || RC=$?; }
hook origin https://github.com/umeranjum17/juggernaut.git
check "a push to our own repository passes" "$RC" 0
hook parent https://github.com/kunchenguid/juggernaut.git
check "a push to the parent is refused" "$RC" 1
has "the push refusal names the refused repository" "$OUT" "kunchenguid/juggernaut"
hook parent git@github.com:kunchenguid/juggernaut.git
check "the scp-style parent url is refused too" "$RC" 1
RC=0; lane git push -q local HEAD:refs/heads/probe >/dev/null 2>&1 || RC=$?
check "a real push through the chain passes" "$RC" 0

# Uninstall puts the real tools back, so a refused write is never a one-way door.
"$SRC/wiring.sh" --uninstall >/dev/null
check "uninstall restores the gh-axi symlink" "$(readlink "$d/stub/gh-axi")" "$d/npm/gh-axi.js"
check "uninstall restores the moved gh wrapper" "$(cat "$HOME/.local/bin/gh")" "$(cat "$d/npm/gh-axi.js")"
run gh-axi pr create --repo kunchenguid/juggernaut --title t --body b
check "an uninstalled guard no longer refuses" "$RC" 0

[ "$fails" -eq 0 ] || { echo "FAILED: $fails check(s)" >&2; exit 1; }
echo "all checks passed"
