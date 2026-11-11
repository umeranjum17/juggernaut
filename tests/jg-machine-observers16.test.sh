#!/usr/bin/env bash
# Behavior test for the Squad Lead home, supervisor session and presence tables (core/machines/tables/{squad-lead,supervision,presence}.tsv):
# each table lints clean with the states of section 6.12 and no other word list, and its report-only observer, called through the real
# bin/jg-machine.sh, prints the right word for a fixture record in every state. The observers only read.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(cd "$(jg_test_tmproot jg-machine-observers16)" && pwd); H=$T/home; S=$H/state; D=$H/data; C=$H/config
mkdir -p "$S" "$D" "$C"
unset JG_MACHINES_TABLES
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DATA_OVERRIDE="$D" JG_CONFIG_OVERRIDE="$C"
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
word() { jm show "$1" "$2"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }
states() { awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/$1.tsv" | sed 's/ $//'; }

# 1. Each table lints clean (the lint of J25 and the enum) and has exactly the states of its enum file.
jm check squad-lead; expect_code 0 "$RC" "squad-lead lints"; assert_equals "ok squad-lead: 6 states, 10 edges" "$OUT" "squad-lead golden"
jm check supervision; expect_code 0 "$RC" "supervision lints"; assert_equals "ok supervision: 5 states, 9 edges" "$OUT" "supervision golden"
jm check presence; expect_code 0 "$RC" "presence lints"; assert_equals "ok presence: 4 states, 6 edges" "$OUT" "presence golden"
for m in squad-lead supervision presence; do
  assert_equals "$(grep -v '^#' "$ROOT/core/machines/$m.states" | cut -f1 | paste -sd' ')" "$(states "$m")" "$m has the enum's states and no other list"
done
assert_equals "provisioned idle working down parked retired" "$(states squad-lead)" "six Squad Lead states"
assert_equals "off starting watching handling read-only" "$(states supervision)" "five supervisor states, start state off"
assert_equals "present quiet away returning" "$(states presence)" "four presence states, start state present"
pass "the three tables lint clean with the states of section 6.12"

# 2. Squad Lead home: a fixture in each of the six states.
reg() { printf -- '- %s - fixture lead (home: %s/%s-home; scope: x; projects: p; added 2026-01-01)\n' "$1" "$T" "$1" >> "$D/squad_leads.md"; }
for id in sl-prov sl-idle sl-work sl-down sl-park; do reg "$id"; mkdir -p "$T/$id-home/state"; done
printf 'kind=squad_lead\n' > "$S/sl-idle.meta"; printf 'kind=squad_lead\n' > "$S/sl-work.meta"; printf 'kind=squad_lead\n' > "$S/sl-down.meta"; printf 'kind=squad_lead\n' > "$S/sl-park.meta"
printf 'kind=ship\n' > "$T/sl-work-home/state/job1.meta"
printf '1\tattempt\n' > "$S/.squad-lead-relaunch-sl-down"
printf 'sl-park\n' > "$C/parked-homes"
: > "$S/.squad-lead-retired-sl-gone"
assert_equals provisioned "$(word squad-lead sl-prov)" "no session record: provisioned"
assert_equals idle "$(word squad-lead sl-idle)" "up with no work: idle"
assert_equals working "$(word squad-lead sl-work)" "a lane of its own: working"
assert_equals down "$(word squad-lead sl-down)" "last relaunch row is an attempt: down"
assert_equals parked "$(word squad-lead sl-park)" "listed in parked-homes: parked"
assert_equals retired "$(word squad-lead sl-gone)" "retirement record and no registry line: retired"
printf '1\tattempt\n2\trelaunched\n' > "$S/.squad-lead-relaunch-sl-down"; assert_equals idle "$(word squad-lead sl-down)" "a relaunched home reads idle again"
jm show squad-lead nobody; expect_code 1 "$RC" "no record, no state"
pass "the Squad Lead observer prints the right word for all six states"

# 3. Supervisor session: a fixture in each of the five states.
rm -f "$S/.lock" "$S/.last-watcher-beat" "$S/.wake-queue" "$S/.lock-refused"
assert_equals off "$(word supervision main)" "no lock: off"
printf '%s\n' "$$" > "$S/.lock"; touch -d '1 minute ago' "$S/.lock"
assert_equals starting "$(word supervision main)" "lock and no beat: starting"
touch "$S/.last-watcher-beat"; assert_equals watching "$(word supervision main)" "lock and a beat after it: watching"
printf 'wake one\n' > "$S/.wake-queue"; assert_equals handling "$(word supervision main)" "queued wake: handling"
rm -f "$S/.lock" "$S/.wake-queue"; printf '%s\n' "$$" > "$S/.lock-refused"; assert_equals read-only "$(word supervision main)" "a live refused session: read-only"
printf '999999999\n' > "$S/.lock"; rm -f "$S/.lock-refused"; assert_equals off "$(word supervision main)" "a dead lock pid: off"
pass "the supervisor observer prints the right word for all five states"

# 4. Presence: a fixture in each of the four states.
rm -f "$S/.afk" "$S/.afk-return-catchup"
assert_equals present "$(word presence main)" "no away file: present"
printf 'quiet\n' > "$S/.afk"; assert_equals quiet "$(word presence main)" "mode line quiet: quiet"
printf '1700000000\n' > "$S/.afk"; assert_equals away "$(word presence main)" "any other content: away"
rm -f "$S/.afk"; : > "$S/.afk-return-catchup"; assert_equals returning "$(word presence main)" "return gate open: returning"
pass "the presence observer prints the right word for all four states"

# 5. The observers only read: no record changed, none created.
before=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)
for _ in 1 2; do word squad-lead sl-work >/dev/null; word supervision main >/dev/null; word presence main >/dev/null; done
assert_equals "$before" "$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)" "observers are read-only"
pass "the observers write nothing"
