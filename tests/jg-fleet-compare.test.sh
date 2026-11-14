#!/usr/bin/env bash
# Behavior test for the machine view comparison (core/fleet-status/compare.sh): the view is compared with the source records and every
# difference is listed and explained. A fixture home holds source records for several machines. It proves: a faithful view matches, a stale
# record and a hidden status file are listed and explained, a lister that drops a record is UNEXPLAINED and exits 1, a machine that does not
# answer in the bound is listed (not left out), a missing home is a difference, and the comparison writes nothing.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CMP="$ROOT/core/fleet-status/compare.sh"
T=$(jg_test_tmproot jg-fleet-compare)
H=$T/home
mkdir -p "$H/state/alerts" "$H/data" "$H/config" "$H/core/machines" "$T/tmp"
ln -sn "$ROOT/bin" "$H/bin"
ln -sn "$ROOT/core/machines/observers" "$H/core/machines/observers"
cp -r "$ROOT/core/machines/tables" "$H/core/machines/tables"
export JG_HOME=$H JG_TMP_ROOT=$T/tmp
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE

T0=$(date +%s)
alert() { printf 'alert=line-red\nsubject=%s\nprecedence=P1\nrung=1\ntop=4\nsince=1\nrung_at=1\nstate=open\n' "$1" > "$H/state/alerts/line-red--$1.rec"; touch -d "@$2" "$H/state/alerts/line-red--$1.rec"; }
alert fresh "$T0"; alert old $((T0 - 200000))
printf 'working [at=1]: x\n' > "$H/state/lane-a.status"; printf 'working [at=1]: x\n' > "$H/state/lane-b.status"
printf 'working [at=1]: x\n' > "$H/state/.startup-network.status"
: > "$H/state/.last-watcher-beat"; touch -d "@$T0" "$H/state/.last-watcher-beat"
before=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)

out=$("$CMP" "$H" --now "$T0" 2>"$T/err"); rc=$?
[ "$rc" -eq 0 ] || fail "a faithful view must compare clean, exit $rc: $out $(cat "$T/err")"
printf '%s\n' "$out" | grep -q '^alert ok 2 records$' || fail "the two alerts, one stale, must match their source: $out"
printf '%s\n' "$out" | tail -1 | grep -q '^compared: 24 machines, .* 0 unexplained$' || fail "last line must count 24 machines and 0 unexplained: $out"
pass "a view that holds what the source holds matches, a stale record included"

printf '%s\n' "$out" | grep -q '^status-verb missing .startup-network .* - a hidden status file' || fail "the hidden status file must be listed and explained: $out"
pass "a source record the view does not list is named, with its reason"

# a lister that drops a record: a copy of the fleet-status folder whose alert lister lists one record only
cp -r "$ROOT/core/fleet-status" "$T/fs"
sed -i "s|^alert\t.*|alert\tprintf 'line-red--fresh\\\\t$T0\\\\n'\t86400|" "$T/fs/records.tsv"
bad=$("$T/fs/compare.sh" "$H" --now "$T0"); rc=$?
[ "$rc" -eq 1 ] || fail "a dropped record must exit 1, got $rc: $bad"
printf '%s\n' "$bad" | grep -q '^alert missing line-red--old .* - UNEXPLAINED$' || fail "the dropped record must be UNEXPLAINED: $bad"
pass "a lister that drops a record is named UNEXPLAINED and the comparison exits 1"

# a lister that invents a record
sed -i "s|^alert\t.*|alert\tprintf 'line-red--fresh\\\\t$T0\\\\nline-red--old\\\\t$((T0 - 200000))\\\\nghost\\\\t$T0\\\\n'\t86400|" "$T/fs/records.tsv"
bad=$("$T/fs/compare.sh" "$H" --now "$T0"); rc=$?
[ "$rc" -eq 0 ] || fail "an invented record is listed with its live-home reason and exits 0, got $rc: $bad"
printf '%s\n' "$bad" | grep -q '^alert extra ghost ' || fail "the invented record must be listed: $bad"
pass "a record the view holds and the source does not is listed"

# a stale age the view reports wrongly: the view says fresh for a record the source shows old
sed -i "s|^alert\t.*|alert\tprintf 'line-red--fresh\\\\t$T0\\\\nline-red--old\\\\t$T0\\\\n'\t86400|" "$T/fs/records.tsv"
bad=$("$T/fs/compare.sh" "$H" --now "$T0"); rc=$?
printf '%s\n' "$bad" | grep -q '^alert age line-red--old source age 200000s, view age 0s - UNEXPLAINED$' || fail "a wrong age must be listed UNEXPLAINED: $bad"
[ "$rc" -eq 1 ] || fail "a wrong age must exit 1, got $rc"
pass "a record whose age the view gets wrong is listed UNEXPLAINED with both ages"

# a machine that does not answer in the bound is listed, never left out
mkdir -p "$T/slowbin"; printf '#!/usr/bin/env bash\nsleep 4\n' > "$T/slowbin/stat"; chmod +x "$T/slowbin/stat"
slow=$(PATH="$T/slowbin:$PATH" "$CMP" "$H" --bound 1 --now "$T0")
printf '%s\n' "$slow" | grep -q '^alert timeout - no reading in 1s; source holds ' || fail "a machine with no answer must be listed: $slow"
printf '%s\n' "$slow" | tail -1 | grep -q ' 0 unexplained$' || fail "a timeout is explained: $slow"
pass "a machine with no reading in the bound is listed with the source count, and explained"

# a missing home
miss=$("$CMP" "$T/no-such-home"); rc=$?
printf '%s\n' "$miss" | grep -q '^home unreadable .* - the home does not exist' || fail "a missing home must be a difference: $miss"
[ "$rc" -eq 0 ] || fail "an explained missing home exits 0, got $rc"
pass "a missing home is a listed, explained difference"

after=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)
[ "$before" = "$after" ] || fail "the comparison wrote to the home"
pass "the comparison writes nothing"
