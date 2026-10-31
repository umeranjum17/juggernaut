#!/usr/bin/env bash
# A home whose config/merge-gate was written for the retired add-ons clone is repointed at this checkout's
# owner-rules gate by install.sh, and the clone path is gone from the gate. Fixture home; no merge runs.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
inst=$here/../install.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
home=$work/home
mkdir -p "$home/config"
retired=$home/projects/firstmate-addons/owner-rules/bin/fm-owner-rules-gate.sh
printf '#!/bin/sh\nexit 0\n' > "$home/config/merge-gate.pre-owner-rules"
chmod 755 "$home/config/merge-gate.pre-owner-rules"
{
  printf '#!/usr/bin/env bash\n# fm-owner-rules merge gate\n%s "$@" || exit $?\n' "$retired"
  # shellcheck disable=SC2016 # $prev expands in the written gate.
  printf 'prev=%s\n[ -e "$prev" ] || exit 0\nexec "$prev" "$@"\n' "$home/config/merge-gate.pre-owner-rules"
} > "$home/config/merge-gate"
chmod 755 "$home/config/merge-gate"
fail() { echo "not ok - $*"; exit 1; }
cp "$home/config/merge-gate.pre-owner-rules" "$work/prev"
bash "$inst" "$home" >/dev/null || fail "install.sh refused the gate written for the retired clone"
gate=$home/config/merge-gate
! grep -q 'firstmate-addons' "$gate" || fail "the gate still names the retired clone"
resolved=$(sed -n 's/^\(.*jg-owner-rules-gate.sh\) "\$@".*/\1/p' "$gate" | head -1)
resolved=$(eval "printf '%s' $resolved")
[ -x "$resolved" ] || fail "the gate resolves $resolved, which is not an executable"
case $resolved in "$(cd "$here/.." && pwd -P)"/bin/*) ;; *) fail "the gate resolves $resolved, not this checkout's owner-rules" ;; esac
cmp -s "$home/config/merge-gate.pre-chain" "$work/prev" || fail "the previous gate is no longer chained"
cp "$gate" "$work/first"
bash "$inst" "$home" >/dev/null || fail "a second install failed"
cmp -s "$gate" "$work/first" || fail "a second install changed the gate"
echo "resolved: ${resolved##*/} under this checkout's addons/owner-rules/bin"
echo "ok - the gate runs the maintained owner-rules gate and names no retired clone"
