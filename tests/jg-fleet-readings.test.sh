#!/usr/bin/env bash
# Behavior test for the machine readings (core/fleet-status/readings.sh): every one of the 24 declared machines has a lister,
# and each reading carries its age and says fresh, stale or unknown. A fixture home holds one source record for each machine
# (same files the real writers leave), and the clock the reading runs against is moved: at the record's time its reading is fresh,
# past the machine's lifetime (records.tsv, column 3) it is stale, and before the record's time (a time in the future) it is unknown.
# A home that is not there reads unknown for every machine, never no lines. A source with no time reads unknown: the account
# observer's `no-reading` (no quota reading at all), a Squad Lead whose session has not answered, a supervisor that has not beaten.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RD="$ROOT/core/fleet-status/readings.sh"
T=$(jg_test_tmproot jg-fleet-readings)
H=$T/home
mkdir -p "$H/state/alerts" "$H/state/.stops" "$H/state/t1.inbox" "$H/data/jg-trunk-landing" "$H/config" "$H/core/machines" "$T/tmp"
ln -sn "$ROOT/bin" "$H/bin"
ln -sn "$ROOT/core/machines/observers" "$H/core/machines/observers"
cp -r "$ROOT/core/machines/tables" "$H/core/machines/tables"
export JG_HOME=$H JG_TMP_ROOT=$T/tmp
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE

T0=$(date +%s)
at() { touch -d "@$T0" "$@"; }   # give each source record the time T0
printf '{"accounts":[{"id":"a1","five_hour":{"left":50},"seven_day":{"left":50}}]}\n' > "$H/state/claude-accounts.json"; at "$H/state/claude-accounts.json"
printf 'alert=line-red\nsubject=x\nprecedence=P1\nrung=1\ntop=4\nsince=1\nrung_at=1\nstate=open\n' > "$H/state/alerts/line-red--x.rec"; at "$H/state/alerts/line-red--x.rec"
printf 'b1\thome\t-\tword\t%s\t%s\tstanding\t0\t-\t-\n' "$T0" "$((T0 + 86400))" > "$H/config/proof-bypass"; at "$H/config/proof-bypass"
: > "$H/state/t1.backlog-close"; at "$H/state/t1.backlog-close"
printf '%s\tt1\tdelivering.queued\tnew-head\tproving.planned\n' "$T0" > "$H/data/moves.log"
{ grep '^#' "$ROOT/core/machines/changes.tsv"; printf 'c1\tproj\t-\t-\t-\twhat\n'; } > "$H/core/machines/changes.tsv"; at "$H/core/machines/changes.tsv"
printf 'project=proj\ndecision_keys=k1\n' > "$H/state/t1.meta"; at "$H/state/t1.meta"
at "$H/state/.stops"; : > "$H/state/.stops/pool-proj.pool-full"; at "$H/state/.stops/pool-proj.pool-full"
: > "$H/data/jg-trunk-landing/t1.abc123.state"; at "$H/data/jg-trunk-landing/t1.abc123.state"
: > "$H/state/.hash-pane1"; at "$H/state/.hash-pane1"
: > "$H/state/t1.inbox/001.msg"; at "$H/state/t1.inbox/001.msg"
printf 't1\tproj\tabc123\t%s\n' "$T0" > "$H/data/trunk-landings.tsv"
printf -- '- sl1 - a Squad Lead\n' > "$H/data/squad_leads.md"; : > "$H/state/sl1.meta"; at "$H/state/sl1.meta"
printf 'working [at=1]: x\n' > "$H/state/t1.status"; at "$H/state/t1.status"
: > "$H/state/.last-watcher-beat"; at "$H/state/.last-watcher-beat"
: > "$H/state/trunk-tip-proj"; at "$H/state/trunk-tip-proj"
: > "$T/tmp/jg-old-entry"; at "$T/tmp/jg-old-entry"
before=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)

machines=$(find "$ROOT/core/machines/tables" -name '*.tsv' -printf '%f\n' | sed 's/\.tsv$//' | sort)
[ "$(printf '%s\n' "$machines" | wc -l)" -eq 24 ] || fail "expected 24 declared machines, found $(printf '%s\n' "$machines" | wc -l)"

f() { printf '%s\n' "$line" | cut -f"$1"; }   # one column of the reading line
first() { "$RD" "$H" "$1" --now "$2" | head -1; }
for m in $machines; do
  life=$(awk -F'\t' -v m="$m" '$1 == m { print $3 }' "$ROOT/core/fleet-status/records.tsv")
  [[ $life =~ ^[1-9][0-9]*$ ]] || fail "$m has no freshness lifetime in records.tsv: '$life'"
  line=$(first "$m" "$((T0 + 5))"); rm=$(f 1) rid=$(f 2) rstate=$(f 3) rage=$(f 5) rfresh=$(f 6)
  [ "$rm" = "$m" ] && [ "$rid" != - ] && [ "$rfresh" = fresh ] && [ "$rage" -ge 0 ] && [ "$rage" -le 6 ] || fail "$m: expected a fresh reading with its age, got: $line"
  [ -n "$rstate" ] || fail "$m: a reading must carry a state: $line"
  line=$(first "$m" "$((T0 + life + 100))"); rage=$(f 5) rfresh=$(f 6)
  [ "$rfresh" = stale ] && [ "$rage" -gt "$life" ] || fail "$m: expected a stale reading older than $life s, got: $line"
  line=$(first "$m" "$((T0 - 100))"); rage=$(f 5) rfresh=$(f 6)
  [ "$rfresh" = unknown ] && [ -z "$rage" ] || fail "$m: a record dated after the clock must read unknown with no age, got: $line"
  line=$("$RD" "$T/no-such-home" "$m"); [ "$line" = "$(printf '%s\t-\tunknown\t\t\tunknown' "$m")" ] || fail "$m: a missing home must read unknown, got: $line"
  pass "$m: fresh, stale and unknown readings"
done

# states a reading names, read through the real observers
st() { first "$1" "$((T0 + 5))" | cut -f3; }
[ "$(st account)" = available ] || fail "account a1 must read available: $(st account)"
[ "$(st alert)" = open ] || fail "alert must read open: $(st alert)"
[ "$(st bypass)" = standing ] || fail "bypass must read standing: $(st bypass)"
pass "readings name the state the observer names"

after=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)
[ "$before" = "$after" ] || fail "reading wrote to the home"
pass "reading writes nothing"

# a source with no time reads unknown, and the account observer's no-reading is a defined state
rm "$H/state/claude-accounts.json"
for tool in claude codex; do
  l=$("$RD" "$H" account --now "$T0" | grep "^account	$tool\.unread")
  [ "$l" = "$(printf 'account\t%s.unread\tunknown\t\t\tunknown' "$tool")" ] || fail "account with no quota reading must read state unknown and freshness unknown: $l"
done
pass "the account observer's no-reading reads as state unknown, freshness unknown"
rm "$H/state/sl1.meta"
[ "$("$RD" "$H" squad-lead --now "$T0")" = "$(printf 'squad-lead\tsl1\tprovisioned\t\t\tunknown')" ] || fail "a Squad Lead with no session record must read unknown: $("$RD" "$H" squad-lead --now "$T0")"
rm "$H/state/.last-watcher-beat"
[ "$("$RD" "$H" supervision --now "$T0" | cut -f4-)" = "$(printf '\t\tunknown')" ] || fail "a supervisor that never beat must read unknown: $("$RD" "$H" supervision --now "$T0")"
pass "a source with no time reads unknown, never fresh"

# a home with no state folder reads unknown too
mkdir "$T/bare"; l=$("$RD" "$T/bare" alert); [ "$l" = "$(printf 'alert\t-\tunknown\t\t\tunknown')" ] || fail "a home with no state must read unknown: $l"
pass "a home with no state reads unknown"
