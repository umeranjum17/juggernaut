#!/usr/bin/env bash
# tests/jg-running-products.test.sh - a behind service is named, and only a listed `auto` line is restarted.
#
# The failure this pins is a fleet that merges a release and keeps serving the old one: a behind service must be
# reported with both versions, an `auto` line must restart exactly once and then read current, a `manual` line
# must never be restarted, and a service no line names must never be touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(jg_test_tmproot jg-running-products)
RP="$ROOT/bin/jg-running-products.sh"
BIN=$WORK/bin
mkdir -p "$BIN" "$WORK/home"

# A stub systemctl records the unit it was asked to restart and makes that service come up current, the way a real
# restart picks up the release on disk.
cat >"$BIN/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/calls"
[ "\${1-} \${2-}" = "--user restart" ] || exit 1
case "\${3-}" in
  svc-a.service) cat "$WORK/wanted-a" >"$WORK/running-a" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN/systemctl"
printf '1.2.3\n' >"$WORK/wanted-a"
printf '1.2.3\n' >"$WORK/wanted-b"

cfg() { # cfg <mode-a>: one auto line and one manual line, each with its own version files
  cat >"$WORK/products" <<SH
# a comment line is skipped
svc-a svc-a.service "cat $WORK/running-a" "cat $WORK/wanted-a" $1
svc-b svc-b.service "cat $WORK/running-b" "cat $WORK/wanted-b" manual
SH
  : >"$WORK/calls"
}
run() { PATH=$BIN:$PATH JG_HOME=$WORK/home "$RP" "$1" --config "$WORK/products"; }

# current: both lines say so, exit 0, and no service is restarted.
cfg auto
printf '1.2.3\n' >"$WORK/running-a"
printf '1.2.3\n' >"$WORK/running-b"
out=$(run check) || fail "every service current must exit 0, got: $?"
printf -- '--- check, both current\n%s\n' "$out"
assert_contains "$out" "svc-a: current 1.2.3" "a current service reports its version"
assert_contains "$out" "svc-b: current 1.2.3" "a current manual service reports its version too"
[ -s "$WORK/calls" ] && fail "a current fleet must restart nothing, got: $(cat "$WORK/calls")"

# behind: both versions are named and the exit is 1, on check and on refresh alike.
printf '1.1.0\n' >"$WORK/running-a"
printf '1.1.0\n' >"$WORK/running-b"
out=$(run check) && fail "a behind service must exit 1"
assert_contains "$out" "svc-a: running 1.1.0, wanted 1.2.3" "a behind auto service names both versions"
assert_contains "$out" "svc-b: running 1.1.0, wanted 1.2.3" "a behind manual service names both versions"
[ -s "$WORK/calls" ] && fail "check must never restart, got: $(cat "$WORK/calls")"

# refresh: the auto line restarts exactly once and reads current; the manual line is only reported.
out=$(run refresh) && fail "a manual line still behind must keep the exit at 1"
printf -- '--- refresh, one auto and one manual behind\n%s\n' "$out"
assert_contains "$out" "svc-a: current 1.2.3" "the restarted auto service reads current after the restart"
assert_contains "$out" "svc-b: running 1.1.0, wanted 1.2.3" "the manual service is reported, not restarted"
printf -- '--- systemctl calls\n%s\n' "$(cat "$WORK/calls")"
[ "$(cat "$WORK/calls")" = "--user restart svc-a.service" ] \
  || fail "only the listed auto unit restarts, once, got: $(cat "$WORK/calls")"

# refresh again: the auto service is current now, so a second pass touches nothing.
: >"$WORK/calls"
printf '1.2.3\n' >"$WORK/running-b"
out=$(run refresh) || fail "refresh with everything current must exit 0"
[ -s "$WORK/calls" ] && fail "a current fleet has nothing to restart, got: $(cat "$WORK/calls")"

# an absent or failing version command is unknown, and unknown is never current.
cfg manual
rm -f "$WORK/running-a"
cat >"$WORK/products" <<SH
svc-a svc-a.service "cat $WORK/running-a" "cat $WORK/wanted-a" manual
SH
out=$(run check) && fail "an unreadable running version must not count as current"
assert_contains "$out" "svc-a: running unknown, wanted 1.2.3" "a failed version command is reported unknown"

# the shipped template is empty, so a home with no config lists nothing and stays clean.
out=$(JG_HOME=$WORK/home "$RP" check --config "$ROOT/defaults/running-products") \
  || fail "the empty shipped template must exit 0"
[ -z "$out" ] || fail "an empty template prints nothing, got: $out"

pass "jg-running-products.sh: names a behind service, restarts each behind auto line once, never a manual one"
