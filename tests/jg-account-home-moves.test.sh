#!/usr/bin/env bash
# Accounts and homes record their moves: the real picker (pick, rest, unrest, a recovered rest), the real quota reader (a
# login that stops and comes back) and the Squad Lead writers (provisioned, down, relaunched) each leave one line with its
# time in data/machine-moves.log, so resting -> ready and down -> relaunched have times. Every record is generated here.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot jg-account-home-moves)
H=$T/home; S=$H/state; MOVES=$H/data/machine-moves.log; SHADOW=$H/data/machine-shadow.log
export JG_HOME=$H JG_STATE_OVERRIDE=$S JG_DATA_OVERRIDE=$H/data HOME=$T/user
mkdir -p "$H/data" "$S" "$H/core" "$HOME" "$T/f1" "$T/f2"
ln -s "$ROOT/bin" "$H/bin"; ln -s "$ROOT/core/machines" "$H/core/machines"; ln -s "$ROOT/core/claude-accounts" "$H/core/claude-accounts"
PICK=$H/core/claude-accounts/bin/claude-accounts-pick; QUOTA=$H/core/claude-accounts/bin/claude-accounts-quota.sh
export JG_CLAUDE_ACCOUNTS_REGISTRY=$T/registry.json
printf '{"accounts":[{"provider":"claude","id":"a1","name":"one","folder":"%s"},{"provider":"claude","id":"a2","name":"two","folder":"%s"}]}\n' "$T/f1" "$T/f2" > "$JG_CLAUDE_ACCOUNTS_REGISTRY"
# a fake quota-axi: a1 reports a window of $LEFT percent, a2 answers by its folder: signed out when $T/out exists
FAKE=$T/quota-axi
cat > "$FAKE" <<FAKE
#!/usr/bin/env bash
if [ "\$CLAUDE_CONFIG_DIR" = "$T/f2" ] && [ -e "$T/out" ]; then echo "not authenticated, please sign in" >&2; exit 1; fi
left=\$(cat "$T/left" 2>/dev/null || echo 80)
printf '{"windows":[{"id":"five_hour","percentRemaining":%s,"resetsAt":"2099-01-01T00:00:00Z"},{"id":"seven_day","percentRemaining":%s,"resetsAt":"2099-01-02T00:00:00Z"}]}\n' "\$left" "\$left"
FAKE
chmod +x "$FAKE"; export JG_QUOTA_AXI_REAL=$FAKE
reading() { JG_ACCOUNTS_PROVIDER=claude bash "$QUOTA" >/dev/null 2>&1; }
moves_of() { awk -F'\t' -v id="$1" '$2 == "account" && $3 == id { print $5 ">" $6 }' "$MOVES" 2>/dev/null | paste -sd' ' -; }

echo 80 > "$T/left"; reading
bash "$PICK" pick claude --json --state "$S" >"$T/pick.out" || fail "the pick failed: $(cat "$T/pick.out")"
picked=$(jq -r .id "$T/pick.out"); [ "$picked" = a1 ] || [ "$picked" = a2 ] || fail "no account picked"
assert_equals "lease>in-use" "$(moves_of "claude.$picked")" "a lease is one move, available -> in-use"
case $(awk -F'\t' '$2 == "account" { print $1 }' "$MOVES") in *[!0-9$'\n']* | '') fail "a move has no epoch" ;; esac
pass "a lease records the move with its time"

echo 4 > "$T/left"; reading
bash "$PICK" rest a1 --state "$S" >/dev/null || fail "rest a1 was refused"
case $(moves_of claude.a1) in *">limited") : ;; *) fail "the rest recorded no move to limited: $(moves_of claude.a1)" ;; esac
echo 100 > "$T/left"; reading
bash "$PICK" pick claude --json --state "$S" >/dev/null || fail "a pick after recovery failed"
assert_contains "$(moves_of claude.a1)" "reset>available" "the recovered rest is one move, limited -> available"
pass "resting and ready record their moves with times"

echo 4 > "$T/left"; reading; bash "$PICK" rest a1 --state "$S" >/dev/null || fail "second rest refused"
bash "$PICK" unrest a1 --state "$S" >/dev/null || fail "unrest failed"
assert_contains "$(moves_of claude.a1)" "reset>available" "an owner unrest is a ready move too"

touch "$T/out"; reading
assert_contains "$(moves_of claude.a2)" "sign-out>signed-out" "a login that stopped is a move"
rm -f "$T/out"; reading
assert_contains "$(moves_of claude.a2)" "sign-in>available" "a login that came back is a move"
pass "the quota reader records the login moves"

# Squad Lead homes: provisioned by the seed's writer, down and relaunched by the liveness ledger
# shellcheck source=bin/jg-squad-lead-charter-lib.sh
. "$H/bin/jg-squad-lead-charter-lib.sh"
# shellcheck source=bin/jg-squad-lead-liveness-lib.sh
. "$H/bin/jg-squad-lead-liveness-lib.sh"
STATE=$S
squad_lead_report_provisioned lead1
assert_equals "provision>provisioned" "$(awk -F'\t' '$2 == "squad-lead" && $3 == "lead1" { print $5 ">" $6 }' "$MOVES")" "provisioned is a move with the (none) start"
printf -- '- lead1 - a charter (home: %s; scope: x; projects: p; added 2026-11-13)\n' "$T/leadhome" > "$H/data/squad_leads.md"
mkdir -p "$T/leadhome/state"; printf 'kind=squad_lead\n' > "$S/lead1.meta"
jg_squad_lead_liveness_ledger_add lead1 attempt
jg_squad_lead_liveness_ledger_add lead1 relaunched
assert_equals "idle>down down>idle" "$(awk -F'\t' '$2 == "squad-lead" && $3 == "lead1" && $4 != "(none)" { print $4 ">" $6 }' "$MOVES" | paste -sd' ' -)" "exited then relaunched"
pass "a home records provisioned, down and relaunched with times"
[ ! -s "$SHADOW" ] || fail "a reported move was illegal: $(cat "$SHADOW")"
