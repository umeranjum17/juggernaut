#!/usr/bin/env bash
# Behavior tests for bin/jg-switch.sh, the switch manifest reader. A fixture home carries known config/, state/, a last
# go-live row and a stub toolchain; one manifest row of each kind is off, then each is turned on, and the real script's
# status, verify and apply are read. Nothing under the real home is touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SW="$ROOT/bin/jg-switch.sh"
T=$(jg_test_tmproot jg-switch)
H=$T/lead; mkdir -p "$H/config" "$H/state" "$H/data" "$T/bin"
export JG_HOME=$H JG_SWITCH_MANIFEST=$T/switches.tsv JG_SWITCH_TOOLCHAIN=$T/toolchain.versions
unset JG_CONFIG_OVERRIDE JG_STATE_OVERRIDE JG_DATA_OVERRIDE
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
{
  tab c1 file machine-view nonempty owner - "needs the view"
  tab c2 policy conflict-resolver@juggernaut set owner - "resolver"
  tab c3 mode ticket - owner - "enforce ticket"
  tab c4 check lead-sweep - auto - "armed"
  tab c5 wiring merge-card - auto - "wired"
  tab c6 npm stubtool - owner - "pin"
  tab c7 restart trunk-live-restart-pending - owner - "restart"
  tab c8 waiver trunk-live-waiver:juggernaut - owner - "waiver"
} > "$JG_SWITCH_MANIFEST"
printf 'stubtool stubtool@1.2.0\n' > "$JG_SWITCH_TOOLCHAIN"
printf '#!/bin/sh\necho "stubtool 1.1.0"\n' > "$T/bin/stubtool"; chmod +x "$T/bin/stubtool"
export PATH="$T/bin:$PATH"
tab juggernaut:a1 abc 1 "live,wiring-failed:merge-card,claude-accounts" "" > "$H/data/trunk-in-use.tsv"
: > "$H/config/machine-view"
printf 'x\n' > "$H/state/trunk-live-restart-pending"

sw() { OUT=$(bash "$SW" "$@" 2>&1); RC=$?; }

sw status
expect_code 0 "$RC" "status exits 0 while switches are off"
assert_contains "$OUT" "home lead" "status names the home"
assert_contains "$OUT" $'off\tc1\tfile\tmachine-view\tempty\towner' "an empty switch file reads off with its reason and who"
assert_contains "$OUT" $'off\tc2\tpolicy\tconflict-resolver@juggernaut\tunset\towner' "an unset policy key reads off"
assert_contains "$OUT" $'off\tc3\tmode\tticket\tabsent\towner' "a machine not enforced reads off"
assert_contains "$OUT" $'off\tc4\tcheck\tlead-sweep\tunarmed\tauto' "an unarmed check reads off"
assert_contains "$OUT" $'off\tc5\twiring\tmerge-card\twiring-failed\tauto' "a failed wiring step of the last row reads off"
assert_contains "$OUT" $'off\tc6\tnpm\tstubtool\tbelow-pin\towner' "a tool under its pin reads off"
assert_contains "$OUT" $'off\tc7\trestart\ttrunk-live-restart-pending\trestart-pending\towner' "a restart marker reads off"
assert_contains "$OUT" $'off\tc8\twaiver\ttrunk-live-waiver:juggernaut\tabsent\towner' "a missing waiver line reads off"
assert_contains "$OUT" $'off\t-\tdetector\tmerge-card\twiring-failed\tauto' "a failed wiring step is also a detector line"
assert_contains "$OUT" $'off\t-\tdetector\tclaude-accounts\twiring-failed\tauto' "every failed step is a detector line"
assert_contains "$OUT" $'off\t-\tdetector\tinstalled-drift\tunarmed\tauto' "an absent drift check shim is a detector line"
assert_contains "$OUT" $'off\t-\tdetector\trestart-marker\trestart-pending\towner' "the restart marker is a detector line"
sw status c3
assert_not_contains "$OUT" $'\tc1\t' "a change id narrows the list"
pass "status prints one off line per kind and the seeded detector lines"

sw verify; expect_code 1 "$RC" "verify exits 1 while manifest rows are off"
sw verify c9; expect_code 0 "$RC" "verify of a change with no rows passes"

sw apply c2 'conflict-resolver@juggernaut' --value 'echo r'
[ "$RC" -ne 0 ] || fail "apply of an owner row without --owner-word was refused"
assert_absent "$H/config/trunk-policy" "a refused apply writes nothing"
sw apply c4 lead-sweep --owner-word x
[ "$RC" -ne 0 ] || fail "apply writes only policy rows"
sw apply c2 'conflict-resolver@juggernaut' --owner-word "owner said so" --value 'echo r'
expect_code 0 "$RC" "apply with the owner's word"
assert_equals 'conflict-resolver@juggernaut=echo r' "$(cat "$H/config/trunk-policy")" "apply appends key@project=value"
got=$(. "$ROOT/bin/jg-trunk-policy-lib.sh"; JG_CONFIG_OVERRIDE=$H/config jg_trunk_policy conflict-resolver juggernaut)
assert_equals 'echo r' "$got" "jg_trunk_policy reads the appended line"
pass "apply refuses without the owner's word and appends the policy line with it"

printf 'x\n' > "$H/config/machine-view"
printf 'ticket\n' > "$H/config/machine-enforce"
: > "$H/state/lead-sweep.check.sh"; : > "$H/state/lead-sweep.check-trust"
tab juggernaut:a2 def 2 live "" > "$H/data/trunk-in-use.tsv"
printf '#!/bin/sh\necho "stubtool 1.2.3"\n' > "$T/bin/stubtool"
: > "$H/state/.session-start-complete"; touch -d '1 minute ago' "$H/state/trunk-live-restart-pending"
printf 'juggernaut 1 1 until=stable\n' > "$H/config/trunk-live-waiver"
sw status
assert_not_contains "$OUT" $'off\tc' "every manifest row turned on prints no off line"
sw verify; expect_code 0 "$RC" "verify exits 0 once every row is on"
assert_contains "$OUT" "detector" "detector lines remain and never fail verify"
pass "each switch turned on prints nothing and verify passes"

printf '#!/bin/sh\nsleep 30\n' > "$T/bin/stubtool"
JG_SWITCH_TIMEOUT=1 sw status c6
assert_contains "$OUT" $'stubtool\ttimeout' "a check that hangs is bounded and reads timeout"
pass "a hanging check reads off with reason timeout"

# --- the npm kind against the registry: the pin floor, then the cached latest release (refresh-releases) ---
{ tab r1 npm reltool - owner - "pin and release"; } > "$JG_SWITCH_MANIFEST"
printf 'reltool reltool-pkg@0.1.44\n' > "$JG_SWITCH_TOOLCHAIN"
installed() { printf '#!/bin/sh\necho "reltool %s"\n' "$1" > "$T/bin/reltool"; chmod +x "$T/bin/reltool"; }
# shellcheck disable=SC2016  # the stub script must keep its own $1 $2 $3 literal
registry() { printf '#!/bin/sh\n[ "$1 $2 $3" = "view reltool-pkg version" ] || exit 2\n%s\n' "$1" > "$T/bin/npm"; chmod +x "$T/bin/npm"; }
rel_row() { tab reltool "$1" "$2" "$3" > "$H/state/tool-releases.tsv"; }
now=$(date +%s)
rm -f "$H/state/tool-releases.tsv"
installed 0.1.34; sw status r1
assert_contains "$OUT" $'off\tr1\tnpm\treltool\tbelow-pin\towner' "installed 0.1.34 under pin 0.1.44 reads below-pin"
installed 0.1.46; sw status r1
assert_not_contains "$OUT" $'off\tr1' "installed 0.1.46 above the pin reads on"
assert_contains "$OUT" $'unknown\tr1\tnpm\treltool\tunknown-release' "no cache reads unknown-release, printed as unknown"
sw verify r1; expect_code 0 "$RC" "unknown-release is not counted by verify"
rel_row 0.1.46 "$now" ok; sw status r1
assert_not_contains "$OUT" "r1" "a fresh cache at the installed version reads on"
rel_row 0.1.50 "$now" ok; sw status r1
assert_contains "$OUT" $'off\tr1\tnpm\treltool\tbehind-release\towner' "a fresh cache row newer than installed reads behind-release"
sw verify r1; expect_code 1 "$RC" "behind-release is counted by verify"
rel_row 0.1.50 $((now - 49 * 3600)) ok; sw status r1
assert_contains "$OUT" $'unknown\tr1\tnpm\treltool\tunknown-release' "a cache older than 48 hours reads unknown-release"
assert_not_contains "$OUT" $'off\tr1' "a stale cache is not counted"
rel_row - "$now" failed; sw status r1
assert_contains "$OUT" $'unknown\tr1\tnpm\treltool\tunknown-release' "a failed refresh reads unknown-release"
pass "the npm kind reads the pin floor, then behind-release, and an unknown release is not counted"

rm -f "$H/state/tool-releases.tsv"
registry 'echo 0.1.60'; sw refresh-releases
expect_code 0 "$RC" "refresh-releases succeeds"
assert_contains "$(cat "$H/state/tool-releases.tsv")" $'reltool\t0.1.60\t' "refresh writes the registry's latest for the pin's package"
sw status r1
assert_contains "$OUT" $'off\tr1\tnpm\treltool\tbehind-release\towner' "a refreshed cache is read by status"
registry 'exit 1'; sw refresh-releases
assert_contains "$(cat "$H/state/tool-releases.tsv")" $'reltool\t-\t' "a failed lookup is recorded as failed"
assert_contains "$(cat "$H/state/tool-releases.tsv")" $'\tfailed' "a failed lookup row says failed"
registry 'sleep 30'; JG_SWITCH_REFRESH_TIMEOUT=1 sw refresh-releases
assert_contains "$(cat "$H/state/tool-releases.tsv")" $'\tfailed' "a hanging lookup is bounded and recorded as failed"
pass "refresh-releases writes the cache under a bound and records a failed lookup"

# --- the back-filled manifest: the real core/machines/switches.tsv against a seeded home (S8) ---
# Three owner switches shipped off and only now declared. The fixture home has none of them on, plus the standing findings
# no change declared; each is then turned on one at a time and only its own line goes.
export JG_SWITCH_MANIFEST=$ROOT/core/machines/switches.tsv
B=$T/backfill; mkdir -p "$B/config" "$B/state" "$B/data"
tab juggernaut:b1 abc 1 "live,wiring-failed:merge-card" "" > "$B/data/trunk-in-use.tsv"
printf 'x\n' > "$B/state/trunk-live-restart-pending"
sw status --home "$B"
for row in $'sm-s12-enforce\tmode\tticket\tabsent\towner' $'jg8-j32a-resolver\tpolicy\tconflict-resolver\tunset\towner' \
  $'jg8-j32b-retest\tpolicy\tretest-runner\tunset\towner'; do
  assert_contains "$OUT" "off"$'\t'"$row" "the seeded home reads the declared switch off: ${row%%$'\t'*}"
done
assert_contains "$OUT" $'off\t-\tdetector\tmerge-card\twiring-failed\tauto' "the seeded wiring failure is a detector line"
assert_contains "$OUT" $'off\t-\tdetector\tinstalled-drift\tunarmed\tauto' "the unarmed drift check is a detector line"
assert_contains "$OUT" $'off\t-\tdetector\ttool-update-check\tunarmed\tauto' "the unarmed tool-update check is a detector line"
assert_contains "$OUT" $'off\t-\tdetector\trestart-marker\trestart-pending\towner' "the restart marker is a detector line"
assert_equals 3 "$(printf '%s\n' "$OUT" | grep -c $'^off\t[^-]')" "exactly three manifest rows are off"
assert_equals 0 "$(awk -F'\t' '$1 !~ /^#/ && $5 != "owner"' "$ROOT/core/machines/switches.tsv" | wc -l | tr -d ' ')" "every back-filled row is who=owner"
sw verify --home "$B"; expect_code 1 "$RC" "verify exits 1 while the three rows are off"
sw apply sm-s12-enforce ticket --home "$B" --owner-word x
[ "$RC" -ne 0 ] || fail "apply writes only policy rows, never the mode row"
printf 'ticket\n' > "$B/config/machine-enforce"; sw status --home "$B"
assert_not_contains "$OUT" $'\tsm-s12-enforce\t' "a machine line in config/machine-enforce turns the mode row on"
assert_contains "$OUT" $'\tjg8-j32a-resolver\t' "turning on one row leaves the others off"
sw apply jg8-j32a-resolver conflict-resolver --home "$B" --owner-word "owner said so" --value 'echo r'; sw status --home "$B"
assert_not_contains "$OUT" $'\tjg8-j32a-resolver\t' "a conflict-resolver line turns its row on"
assert_contains "$OUT" $'\tjg8-j32b-retest\t' "the retest row is still off"
sw apply jg8-j32b-retest retest-runner --home "$B" --owner-word "owner said so" --value 'echo t'; sw status --home "$B"
assert_not_contains "$OUT" $'off\tjg8' "a retest-runner line turns the last row on"
sw verify --home "$B"; expect_code 0 "$RC" "verify passes once the three rows are on"
assert_contains "$OUT" "detector" "detector lines stay and never fail verify"
bash "$ROOT/core/machines/observers/delivery.sh" check >"$T/dcheck" 2>&1; expect_code 0 "$?" "every manifest id has a changes.tsv row: $(cat "$T/dcheck")"
pass "the back-filled manifest reads three owner switches off in a seeded home, and each turns on alone"

# --- the flag sheet: every flag a project has set away from its default, with value, default and flip ---
F=$T/flags; mkdir -p "$F/config" "$F/state" "$F/data"
printf -- '- fx [local +yolo] - fixture (added 2026-11-15)\n' > "$F/data/projects.md"
printf 'gate-lint@fx=true\nbatch-max@other=9\nbatch-max=5\n' > "$F/config/trunk-policy"
printf 'fx owner-rule-a1 1 until=stable\nother owner-rule-b2 1 until=stable\n' > "$F/config/trunk-live-waiver"
JG_HOME=$F bash "$ROOT/bin/jg-proof-bypass.sh" grant --project fx --word owner-rule-c3 >/dev/null 2>&1; bid=$(awk -F'\t' '$2 == "project" { print $1 }' "$F/config/proof-bypass")
sw flags fx --home "$F"; expect_code 0 "$RC" "flags exits 0"
assert_contains "$OUT" "project fx" "flags names the project"
assert_contains "$OUT" $'flag\tgate-lint@fx\ttrue\tbin/jg-lint.sh --changed-base HEAD^\tdelete the last gate-lint line for fx' "a policy key set for the project prints value, default and flip"
assert_contains "$OUT" $'flag\tyolo\ton\toff\tremove +yolo from the fx line' "the registry's yolo prints"
assert_contains "$OUT" $'flag\ttrunk-live-waiver\towner-rule-a1\tnone\tdelete the fx line' "the project's waiver line prints"
assert_contains "$OUT" $'flag\tproof-bypass:project\t'"$bid"$'\tnone\tbin/jg-proof-bypass.sh end '"$bid" "a standing project bypass prints with its end command"
assert_not_contains "$OUT" "other" "another project's lines and a key at its default never print"
assert_not_contains "$OUT" "batch-max" "a key at its default prints no line"
mkdir -p "$T/bare/config" "$T/bare/data"; sw flags fx --home "$T/bare"
assert_contains "$OUT" "no flags set" "a project with nothing set says so"
sw flags; expect_code 2 "$RC" "flags needs a project"
pass "the flag sheet prints each set flag with value, default and flip, and nothing else"
