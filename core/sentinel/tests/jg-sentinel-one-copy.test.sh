#!/usr/bin/env bash
# core/sentinel/tests/jg-sentinel-one-copy.test.sh - the sentinel has one copy, and
# the copy the host runs holds every sentinel change.
#
# bin/jg-sentinel.sh is a forwarder into core/sentinel/bin/jg-sentinel.sh, and
# core/sentinel/wiring.sh installs that core copy as the host's sentinel. Before the
# two were one, fixes landed in the bin/ copy while the host ran the core one, so
# the /tmp guard, the inbox ring and the deferred-wake alert never ran there.
#
# Hermetic: a throwaway HOME and XDG dirs, a stub systemctl that records its calls,
# a stub herdr that reports no server, a stand-in for the captain alert and an empty
# /tmp stand-in (JG_TMP_ROOT). The real user manager, Herdr and /tmp are never read
# or changed. It proves, through both entries (the installed copy and the forwarder):
#   - the forwarder is short, holds no sentinel code, and prints the core copy's usage;
#   - the installed copy is the core copy byte for byte, and its unit runs it;
#   - one tick of the installed copy, which runs its home's own bin/, warns on /tmp
#     use, defers the wake and tells the captain nothing, and a tick
#     through the forwarder, for a home with no bin/ of its own, does the same;
#   - both entries refuse `unit` in a Squad Lead home with the owner's reason;
#   - `unit` names the entry it was run through.
set -u

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CORE=$REPO/core/sentinel/bin/jg-sentinel.sh
FORWARDER=$REPO/bin/jg-sentinel.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

mkdir -p "$d/stub" "$d/home" "$d/xdg/data" "$d/xdg/config" "$d/tmproot"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/systemctl.log"\n' "$d" > "$d/stub/systemctl"
# The only Herdr answer: no server is running, so no pane is found and every wake defers.
cat > "$d/stub/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" status "*) printf '%s\n' '{"server":{"running":false}}' ;;
  *) exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$d" > "$d/stub/say"
chmod +x "$d/stub/systemctl" "$d/stub/herdr" "$d/stub/say"
export PATH="$d/stub:$PATH" HOME="$d/home" XDG_DATA_HOME="$d/xdg/data" XDG_CONFIG_HOME="$d/xdg/config"
unset JG_BIN

# home <dir> [with-bin]: a home's state folders; with-bin gives it this checkout's bin/,
# the shape of a home that is its own checkout, which is what the installed copy runs.
home() {
  mkdir -p "$1/state" "$1/data" "$1/config"
  [ "${2:-}" != with-bin ] || ln -s "$REPO/bin" "$1/bin"
}

# tick <entry> <home>: one pass with every wake deferring; the captain must hear nothing about it.
tick() {
  JG_HOME=$2 JG_SENTINEL_HERDR_SESSION=jg-one-copy-lab JG_TMP_ROOT=$d/tmproot JG_TMP_WARN_PCT=0 \
    JG_SENTINEL_TMP_SWEEP_SECS=0 JG_SENTINEL_CAPTAIN_SAY=$d/stub/say \
    "$1" tick
}

# expect_tick_outcome <home> <label>: what one tick of the merged sentinel leaves behind.
expect_tick_outcome() {
  grep -q 'WARNING: .*space' "$1/state/.sentinel.log" || fail "$2: no /tmp warning in the log: $(cat "$1/state/.sentinel.log" 2>/dev/null)"
  grep -q 'no single Herdr pane runs session' "$1/state/.sentinel.log" || fail "$2: the wake did not defer: $(cat "$1/state/.sentinel.log")"
  [ ! -s "$d/alerts.log" ] || fail "$2: the captain was called about a deferred wake: $(cat "$d/alerts.log")"
}

# --- one copy: the forwarder holds no sentinel ---------------------------------
lines=$(wc -l < "$FORWARDER")
[ "$lines" -lt 45 ] || fail "bin/jg-sentinel.sh has $lines lines; a forwarder has under 45"
! grep -Eq '^[a-z_]+\(\) *\{' "$FORWARDER" || fail "bin/jg-sentinel.sh defines functions; it must only forward"
grep -q 'core/sentinel/bin/jg-sentinel.sh' "$FORWARDER" || fail "bin/jg-sentinel.sh does not forward to the core copy"
usage_core=$("$CORE" --help) || fail "core --help failed"
usage_fwd=$("$FORWARDER" --help) || fail "forwarder --help failed"
[ "$usage_core" = "$usage_fwd" ] || fail "the two entries print different usage"
for cmd in tick loop ring reconcile unit model-reconcile lead-model-reconcile; do
  printf '%s\n' "$usage_core" | grep -q "jg-sentinel.sh $cmd " || fail "usage does not list $cmd: $usage_core"
done
pass "bin/jg-sentinel.sh is a $lines-line forwarder and both entries print one usage"

# --- the installed copy is the core copy, and it runs the merged behaviour -------
home "$d/main" with-bin
out=$("$REPO/core/sentinel/wiring.sh" "$d/main") || fail "install failed: $out"
INSTALLED=$d/xdg/data/jg-sentinel/bin/jg-sentinel.sh
cmp -s "$INSTALLED" "$CORE" || fail "the installed copy differs from the core copy"
grep -qx "ExecStart=\"$INSTALLED\" loop" "$d/xdg/config/systemd/user/jg-sentinel.service" \
  || fail "the unit does not run the installed copy"
tick "$INSTALLED" "$d/main" >/dev/null 2>&1 || fail "installed tick failed: $(cat "$d/main/state/.sentinel.log" 2>/dev/null)"
expect_tick_outcome "$d/main" "installed copy"
pass "the installed copy warns on /tmp use, defers the wake and tells the captain nothing"

# --- the forwarder runs the same copy with this checkout's bin/ ------------------
home "$d/bare"
tick "$FORWARDER" "$d/bare" >/dev/null 2>&1 || fail "forwarder tick failed: $(cat "$d/bare/state/.sentinel.log" 2>/dev/null)"
expect_tick_outcome "$d/bare" "forwarder"
[ ! -e "$d/bare/bin" ] || fail "the forwarder tick created a bin/ in the home"
pass "the forwarder runs the same tick for a home with no bin/ of its own"

# --- unit: the entry it ran through, and Main only -----------------------------
unit_exec() { JG_HOME=$2 "$1" unit | sed -n 's/^ExecStart=//p'; }
[ "$(unit_exec "$FORWARDER" "$d/bare")" = "\"$FORWARDER\" loop" ] || fail "forwarder unit: $(unit_exec "$FORWARDER" "$d/bare")"
[ "$(unit_exec "$CORE" "$d/main")" = "\"$CORE\" loop" ] || fail "core unit: $(unit_exec "$CORE" "$d/main")"
: > "$d/main/.jg-squad-lead-home"
: > "$d/bare/.jg-squad-lead-home"
for entry in "$INSTALLED:$d/main" "$FORWARDER:$d/bare"; do
  rc=0; out=$(JG_HOME=${entry#*:} "${entry%%:*}" unit 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "${entry%%:*} unit in a Squad Lead home exited $rc: $out"
  printf '%s\n' "$out" | grep -q 'Main owns the machine services' || fail "${entry%%:*} refusal names no owner: $out"
done
pass "unit names its entry, and both entries refuse a Squad Lead home with the owner's reason"
