#!/usr/bin/env bash
# merge-card wiring: a home's config/post-merge runs that home's own core/merge-card/merge-card,
# keeps the board it already named, and is never written over somebody's own hook.
# Fixture home only: nothing real runs and no live config is touched.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
wiring=$here/../wiring.sh
work=$(mktemp -d /var/tmp/merge-card-wiring.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home
mkdir -p "$home/config" "$home/core/merge-card"
printf '#!/bin/sh\nexit 0\n' >"$home/core/merge-card/merge-card"
chmod +x "$home/core/merge-card/merge-card"
hook=$home/config/post-merge
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

printf "#!/bin/sh\nexec '/old/addons/merge-card/merge-card' post --board '/b/board.json' \"\$@\"\n" >"$hook"
chmod +x "$hook"
bash "$wiring" --dry-run "$home" >/dev/null 2>&1
grep -q '/old/addons' "$hook" && ok 'a dry run changes nothing' || no 'a dry run rewrote the hook'
bash "$wiring" "$home" >/dev/null 2>&1 || no 'wiring a stale add-on hook failed'
grep -q "exec $home/core/merge-card/merge-card post --board /b/board.json" "$hook" \
  && ok "the hook names the home's core/merge-card and keeps its board" || no "the hook still runs a stale copy: $(cat "$hook")"
[ -x "$hook" ] && ok 'the hook is executable' || no 'the hook is not executable'
out=$(bash "$wiring" "$home" 2>&1)
case $out in *'already wired'*) ok 'a rerun changes nothing' ;; *) no "a rerun said: $out" ;; esac

rm -f "$hook"
out=$(bash "$wiring" "$home" 2>&1) && [ ! -e "$hook" ] && ok 'a home with no board gets no hook' || no "a home with no board: $out"
out=$(JG_PROOF_BOARD=/p/board.json bash "$wiring" "$home" 2>&1) && grep -q -- '--board /p/board.json' "$hook" \
  && ok 'JG_PROOF_BOARD names the board of a new hook' || no "JG_PROOF_BOARD: $out"

printf '#!/bin/sh\necho mine\n' >"$hook"
if bash "$wiring" "$home" >/dev/null 2>&1; then no "an own hook was overwritten"; else grep -q 'echo mine' "$hook" && ok 'an own hook is refused untouched' || no 'an own hook was changed'; fi

[ "$fails" -eq 0 ] || exit 1
