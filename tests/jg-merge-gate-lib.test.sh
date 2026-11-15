#!/usr/bin/env bash
# The core merge adapters hand config/merge-gate and config/post-merge their home
# under JG_HOME and under FM_HOME (the pre-rename name installed hooks still read).
# Each hook here reads FM_HOME the way the merge-card hook does and refuses to run
# without it, with only JG_HOME set in the caller's environment.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot merge-gate-lib) || fail "no fixture root"
home=$root/home
mkdir -p "$home/config" "$home/state"
printf 'worktree=%s\n' "$root" > "$home/state/task.meta"
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$ROOT/bin/jg-merge-gate-lib.sh"
unset FM_HOME
export JG_HOME=$home

for kind in merge-gate post-merge; do
  cat > "$home/config/$kind" <<HOOK
#!/usr/bin/env bash
echo "$kind: \${FM_HOME:?$kind: FM_HOME is not set} jg=\$JG_HOME"
HOOK
  chmod +x "$home/config/$kind"
done

out=$(jg_dod_merge_gate "$home/config" "$home" task "$home/state/task.meta" abc -) \
  || fail "merge gate refused with only JG_HOME set: $out"
assert_equals "merge-gate: $home jg=$home" "$out" "merge gate saw the home under both names"
pass "merge gate receives FM_HOME from JG_HOME"

out=$(jg_merge_post_hook "$home/config" "$home" task "$home/state/task.meta" abc - 2>&1)
assert_equals "post-merge: $home jg=$home" "$out" "post-merge hook saw the home under both names"
assert_not_contains "$out" "FM_HOME is not set" "post-merge hook lost FM_HOME"
pass "post-merge hook receives FM_HOME from JG_HOME and exits 0"

# The generic design gate is gone (pcp-s7): no design call, receipt line or size rule refuses a merge.
head=1111111111111111111111111111111111111111
rec=$home/state/task.run-receipt.json
mkmeta() { printf 'worktree=%s\n%b' "$root" "$1" > "$home/state/task.meta"; }
receipt() {  # <verdict> <head> <evidence>
  jq -n --arg v "$1" --arg h "$2" --arg e "$3" '{schema:1,task:"task",head:$h,verdict:$v,evidence:$e,at:1}' > "$rec"
}
! declare -F jg_dod_design_gate >/dev/null || fail "the design gate function still exists"
pass "the library has no design gate"

# The UI-change nav gate: a table of PR bodies against a ui_change=yes task.
navgate() { jg_dod_nav_gate task "$home/state/task.meta" "$1" 2>&1; }
nav_case() {  # <label> <want-exit> <ui_change meta> <body> [<needle in output>]
  local out rc=0
  mkmeta "$3"
  out=$(navgate "$4") || rc=$?
  [ "$rc" = "$2" ] || fail "nav gate '$1': want exit $2, got $rc: $out"
  [ -z "${5:-}" ] || assert_contains "$out" "$5" "nav gate '$1' output"
}
NB=$'Nav before: Home, Inbox, Settings'
nav_case "no passes" 0 'ui_change=no\n' "no lines at all"
nav_case "older task warns" 0 '' "no lines at all" "counting it as ui_change=no"
nav_case "malformed refused" 1 'ui_change=maybe\n' "$NB" "malformed"
nav_case "no nav lines refused" 1 'ui_change=yes\n' "just prose" "no 'Nav before"
nav_case "before only refused" 1 'ui_change=yes\n' "$NB" "no 'Nav before"
nav_case "after only refused" 1 'ui_change=yes\n' "Nav after: Home" "no 'Nav before"
nav_case "same items pass" 0 'ui_change=yes\n' "$NB"$'\nNav after: Home, Inbox, Settings'
nav_case "added item passes" 0 'ui_change=yes\n' "$NB"$'\nNav after: settings; inbox, HOME, Reports'
nav_case "bulleted lines pass" 0 'ui_change=yes\n' $'- Nav before: Home\n- Nav after: Home, New'
nav_case "dropped item refused" 1 'ui_change=yes\n' "$NB"$'\nNav after: Home, Inbox' "settings"
nav_case "renamed item refused" 1 'ui_change=yes\n' "$NB"$'\nNav after: Home, Inbox, Preferences' "settings"
nav_case "dropped with empty quote refused" 1 'ui_change=yes\n' "$NB"$'\nNav after: Home, Inbox\nRemoved by captain words:   ' "settings"
nav_case "dropped with captain words passes" 0 'ui_change=yes\n' "$NB"$'\nNav after: Home, Inbox\nRemoved by captain words: "drop Settings, it is dead"'
nav_case "CRLF body passes" 0 'ui_change=yes\n' $'Nav before: Home\r\nNav after: Home\r\n'
pass "nav gate table: every refusal and every pass"

# The TakeOne demo gate: off without config/takeone-demo; on, yes needs a bound PASS
# receipt with a `takeone receipt:` line, no passes, a missing call warns and passes.
cfg=$home/config
dgate() { jg_dod_demo_gate "$cfg" "$home/state" task "$home/state/task.meta" "$head" 2>&1; }
mkdir -p "$cfg"
rm -f "$cfg/takeone-demo"
mkmeta 'demo_call=yes\n'
rm -f "$rec"
dgate >/dev/null || fail "demo gate must stay off without config/takeone-demo"
pass "demo gate is off by default"

: > "$cfg/takeone-demo"
mkmeta 'demo_call=no\n'
dgate >/dev/null || fail "demo_call=no must pass"
mkmeta ''
out=$(dgate) || fail "missing demo_call must pass: $out"
assert_contains "$out" "counting it as demo_call=no" "missing demo call did not warn"
mkmeta 'demo_call=yes\n'
out=$(dgate) && fail "yes task without a receipt must be refused"
assert_contains "$out" "merge refused" "no-receipt refusal"
receipt PASS "$head" "notes
first-draft receipt: $home/state/fd-123"
dgate >/dev/null && fail "a first-draft line must not satisfy the TakeOne gate"
receipt PASS "$head" $'notes\ntakeone receipt: to-123'
dgate >/dev/null || fail "yes task with a takeone receipt line must pass"
receipt FAIL "$head" $'takeone receipt: to-123'
dgate >/dev/null && fail "a FAIL receipt must be refused"
receipt PASS 2222222222222222222222222222222222222222 $'takeone receipt: to-123'
dgate >/dev/null && fail "a receipt for another head must be refused"
mkmeta 'demo_call=bogus\n'
dgate >/dev/null && fail "a malformed demo call must be refused"
pass "demo gate refuses a yes task without a bound takeone receipt line once switched on"

# The bash timeout fallback must hand the gate's output back as soon as the gate exits. Its watchdog's sleep used to survive a group kill
# that raced its fork and hold the output pipe of the $(...) above open for the whole bound, so a gate call under load hung until the
# 600s bound. With a 60s bound, 40 calls of a gate that exits 0 must take far less than one bound.
printf '#!/usr/bin/env bash\ntrue\n' > "$home/config/merge-gate"
start=$SECONDS
for _ in $(seq 1 40); do
  JG_TIMEOUT_MECHANISM_OVERRIDE=bash JG_MERGE_GATE_TIMEOUT=60 jg_dod_merge_gate "$home/config" "$home" task "$home/state/task.meta" abc - >/dev/null \
    || fail "merge gate refused a gate that exits 0 under the bash timeout"
done
[ $((SECONDS - start)) -lt 30 ] || fail "40 gate calls under the bash timeout took $((SECONDS - start))s: a watchdog sleep held the output pipe open"
pass "bash timeout hands the gate output back as soon as the gate exits"
