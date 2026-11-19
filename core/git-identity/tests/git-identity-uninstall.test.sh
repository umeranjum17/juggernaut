#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
mkdir -p "$T/home" "$T/fm/config"; export HOME=$T/home XDG_DATA_HOME=$T/data GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/global.gitconfig
printf 'original hook\n' > "$T/fm/config/launch-env-hook"; printf keep > "$T/fm/config/unrelated"
"$A/wiring.sh" --email a@example.test --name Tester "$T/fm" >/dev/null
"$A/unwiring.sh" --dry-run "$T/fm" > "$T/dry"
grep -q 'dry run: nothing written' "$T/dry" || fail "the dry run must say it wrote nothing"
grep -q 'exec .*env-file' "$T/fm/config/launch-env-hook" || fail "the dry run must leave the wired hook in place"
out=$("$A/unwiring.sh" "$T/fm")
grep -q 'prior git identity values are not known' <<< "$out" || fail "unwiring must say the prior identity is not known: $out"
[ "$(cat "$T/fm/config/launch-env-hook")" = 'original hook' ] || fail "unwiring must restore the original hook"
[ "$(cat "$T/fm/config/unrelated")" = keep ] || fail "unwiring must leave unrelated config alone"
[ ! -e "$T/data/jg-git-identity/git-identity" ] && [ ! -e "$T/data/jg-git-identity/identity.gitconfig" ] || fail "unwiring must remove the installed identity files"
"$A/unwiring.sh" "$T/fm" >/dev/null || fail "a second unwiring must succeed"
echo 'ok - git-identity uninstall restores the hook, keeps other config and removes the identity files'
