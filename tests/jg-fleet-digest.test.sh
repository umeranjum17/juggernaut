#!/usr/bin/env bash
# Behavior test for the bounded machine digest (core/fleet-status/digest.sh). A fixture home holds source records for the declared
# machines (the same files the real writers leave). The digest must name every stale and unknown machine, list them before the fresh
# ones, stay under its cap, and when the cap is too small to hold all of it cut the fresh machines first and count what it cut.
# A home that is missing lists every machine as unknown, and a machine that does not answer in the bound reads unknown, not left out.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DG="$ROOT/core/fleet-status/digest.sh"
T=$(jg_test_tmproot jg-fleet-digest)
H=$T/home
mkdir -p "$H/state/alerts" "$H/data" "$H/config" "$H/core/machines" "$T/tmp"
ln -sn "$ROOT/bin" "$H/bin"
ln -sn "$ROOT/core/machines/observers" "$H/core/machines/observers"
cp -r "$ROOT/core/machines/tables" "$H/core/machines/tables"
export JG_HOME=$H JG_TMP_ROOT=$T/tmp
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE

T0=$(date +%s)
# alert: one fresh record and one older than its lifetime (records.tsv column 3 is 86400 s)
printf 'alert=line-red\nsubject=x\nprecedence=P1\nrung=1\ntop=4\nsince=1\nrung_at=1\nstate=open\n' > "$H/state/alerts/line-red--x.rec"; touch -d "@$T0" "$H/state/alerts/line-red--x.rec"
cp "$H/state/alerts/line-red--x.rec" "$H/state/alerts/line-red--old.rec"; touch -d "@$((T0 - 200000))" "$H/state/alerts/line-red--old.rec"
: > "$H/state/.last-watcher-beat"; touch -d "@$T0" "$H/state/.last-watcher-beat"
before=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)

out=$("$DG" "$H" --now "$T0")
first=$(printf '%s\n' "$out" | head -1)
case $first in "machines: 24 declared, "*) ;; *) fail "the first line must count the declared machines: $first" ;; esac
[ "$(printf '%s' "$out" | wc -c)" -le 3500 ] || fail "the digest is over its default cap: $(printf '%s' "$out" | wc -c) bytes"
pass "the digest counts 24 declared machines and stays under its default cap"

printf '%s\n' "$out" | grep -q '^alert: stale - 1 of 2 records stale, oldest line-red--old is 200000s old' || fail "the stale alert machine must be named with its oldest record: $out"
pass "a stale machine is named with its oldest record"

# order: every unknown line, then every stale line, then the fresh line
rank=$(printf '%s\n' "$out" | tail -n +2 | awk '/^fresh \(/ { print 2; next } / - [0-9]+ of [0-9]+ records stale/ { print 1; next } { print 0 }')
[ "$rank" = "$(printf '%s\n' "$rank" | sort -n)" ] || fail "unknown must come before stale before fresh: $out"
pass "unknown machines print first, then stale, then the fresh ones"

# every machine appears exactly once in the digest
while read -r m; do
  c=$(printf '%s\n' "$out" | tail -n +2 | grep -cE "^($m: |fresh \(.*[ :]$m( |\$))") || true
  [ "$c" -eq 1 ] || fail "machine $m appears $c times in the digest, not once"
done < <(cut -f1 "$ROOT/core/fleet-status/records.tsv")
pass "every declared machine appears once"

# a missing home lists every machine as unknown
miss=$("$DG" "$T/no-such-home" --now "$T0")
[ "$(printf '%s\n' "$miss" | head -1)" = "machines: 24 declared, 0 fresh, 0 stale, 24 unknown" ] || fail "a missing home must count 24 unknown: $miss"
[ "$(printf '%s\n' "$miss" | grep -c ': unknown - ')" -eq 24 ] || fail "a missing home must list all 24 machines: $miss"
pass "a missing home lists all 24 machines as unknown"

# a small cap cuts the last lines and counts the stale and unknown machines it cut
small=$("$DG" "$H" --now "$T0" --cap 700)
[ "$(printf '%s' "$small" | wc -c)" -le 700 ] || fail "the digest is over a 700 byte cap: $(printf '%s' "$small" | wc -c)"
printf '%s\n' "$small" | grep -q '^\[cut: [0-9]* of 24 machines not shown, [0-9]* of them stale or unknown; ' || fail "a cut digest must count what it cut: $small"
printf '%s\n' "$small" | head -1 | grep -q '^machines: 24 declared' || fail "the summary line must survive a cut: $small"
full_bad=$(printf '%s\n' "$out" | tail -n +2 | grep -cE ' - [0-9]+ of [0-9]+ records ')
shown_bad=$(printf '%s\n' "$small" | grep -cE ' - [0-9]+ of [0-9]+ records ')
cutbad=$(printf '%s\n' "$small" | sed -n 's/.*machines not shown, \([0-9]*\) of them.*/\1/p')
[ $((shown_bad + cutbad)) -eq "$full_bad" ] || fail "shown $shown_bad plus cut $cutbad stale or unknown must be $full_bad"
pass "a small cap keeps the summary, cuts last, and counts the stale and unknown machines it cut"

# a machine that does not answer in the bound reads unknown and is named
mkdir -p "$T/slowbin"; printf '#!/usr/bin/env bash\nsleep 4\n' > "$T/slowbin/stat"; chmod +x "$T/slowbin/stat"
slow=$(PATH="$T/slowbin:$PATH" JG_MACHINE_DIGEST_BOUND=1 "$DG" "$H" --now "$T0")
printf '%s\n' "$slow" | grep -q '(no reading in 1s)' || fail "a machine with no answer in the bound must read unknown: $slow"
pass "a machine that does not answer in the bound reads unknown"

after=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)
[ "$before" = "$after" ] || fail "the digest wrote to the home"
pass "the digest writes nothing"
