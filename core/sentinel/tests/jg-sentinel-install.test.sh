#!/usr/bin/env bash
# tests/jg-sentinel-install.test.sh - hermetic install and uninstall of the sentinel feature.
#
# A throwaway HOME and XDG dirs hold a fork-shaped jg-sentinel unit, and a stub
# systemctl on PATH records the calls it would have made, so the real user manager
# is never read or changed. Install and uninstall must restart the service rather
# than stop it, a rerun must change nothing, uninstall must restore the unit byte
# for byte and leave the tree as it was, and a dry run must write nothing.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u

ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL=$ADDON/wiring.sh
UNINSTALL=$ADDON/unwiring.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
LOG=$d/systemctl.log
UNIT_HOME=$d/xdg/config/systemd/user
UNIT=$UNIT_HOME/jg-sentinel.service
DEST=$d/xdg/data/jg-sentinel
FMH=$d/juggernaut

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
snapshot() {
  (cd "$d" && find . \( -path ./stub -o -path ./systemctl.log -o -path ./expect -o -path ./out \) -prune -o -print | sort \
    && find . \( -path ./stub -o -path ./systemctl.log -o -path ./expect -o -path ./out \) -prune -o -type f -exec cksum {} + | sort)
}

mkdir -p "$d/stub" "$d/expect" "$d/out" "$UNIT_HOME" "$FMH/bin" "$d/home" "$d/xdg/data"
: > "$FMH/bin/jg-control.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$LOG" > "$d/stub/systemctl"
chmod +x "$d/stub/systemctl"
export PATH="$d/stub:$PATH" HOME="$d/home" XDG_DATA_HOME="$d/xdg/data" XDG_CONFIG_HOME="$d/xdg/config"
cat > "$UNIT" <<'UNIT_TEXT'
[Unit]
Description=Juggernaut sentinel (fork copy)

[Service]
Environment="JG_HOME=/home/example/juggernaut"
ExecStart="/home/example/juggernaut/bin/jg-sentinel.sh" loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT_TEXT
cp "$UNIT" "$d/expect/unit"
before=$(snapshot)

rc=0; "$INSTALL" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "install without a home should exit 2, got $rc"
pass "install without a home exits 2 with usage"

"$INSTALL" --dry-run "$FMH" >"$d/out/dry" || fail "dry-run install failed"
[ "$(snapshot)" = "$before" ] || fail "dry-run install wrote to the tree"
[ ! -e "$LOG" ] || fail "dry-run install called systemctl"
grep -q 'would restart jg-sentinel.service' "$d/out/dry" || fail "dry run did not say what it would restart"
pass "dry-run install writes nothing and calls no systemctl"

"$INSTALL" "$FMH" >"$d/out/install" || fail "install failed: $(cat "$d/out/install")"
[ -x "$DEST/bin/jg-sentinel.sh" ] || fail "install did not copy the sentinel"
grep -qx "ExecStart=\"$DEST/bin/jg-sentinel.sh\" loop" "$UNIT" || fail "unit does not run the installed copy"
grep -qx "Environment=\"JG_HOME=$(cd "$FMH" && pwd -P)\"" "$UNIT" || fail "unit does not carry the home"
cmp -s "$DEST/unit.before" "$d/expect/unit" || fail "pre-install unit was not recorded"
[ "$(cat "$LOG")" = "$(printf -- '--user daemon-reload\n--user restart jg-sentinel.service\n--user disable --now fm-sentinel.service')" ] \
  || fail "install did not reload and restart in order: $(cat "$LOG")"
pass "install copies the sentinel, re-points the unit, and restarts the service"

installed=$(snapshot)
"$INSTALL" "$FMH" >"$d/out/rerun" || fail "rerun failed"
[ "$(snapshot)" = "$installed" ] || fail "rerun changed the tree"
[ "$(wc -l <"$LOG")" -eq 3 ] || fail "rerun called systemctl again"
grep -q 'already installed' "$d/out/rerun" || fail "rerun did not report nothing to change"
pass "rerunning install changes nothing and restarts nothing"

"$UNINSTALL" --dry-run >/dev/null || fail "dry-run uninstall failed"
[ "$(snapshot)" = "$installed" ] || fail "dry-run uninstall wrote to the tree"
pass "dry-run uninstall writes nothing"

"$UNINSTALL" >"$d/out/uninstall" || fail "uninstall failed: $(cat "$d/out/uninstall")"
cmp -s "$UNIT" "$d/expect/unit" || fail "uninstall did not restore the unit byte for byte"
[ ! -e "$DEST" ] || fail "uninstall left the installed copy behind"
tail -n 2 "$LOG" | grep -qx -- '--user restart jg-sentinel.service' || fail "uninstall did not restart the service"
! grep -q ' stop' "$LOG" || fail "a step stopped the service"
[ "$(snapshot)" = "$before" ] || fail "install then uninstall left the tree changed"
pass "uninstall restores the unit, restarts on it, and leaves the tree clean"

"$UNINSTALL" >"$d/out/again" || fail "second uninstall failed"
grep -q 'not installed' "$d/out/again" || fail "second uninstall did not report nothing to restore"
pass "uninstall is idempotent"

rm -f "$UNIT"
"$INSTALL" "$FMH" >/dev/null || fail "install with no prior unit failed"
grep -q 'enable jg-sentinel.service' "$LOG" || fail "a new unit was not enabled"
rc=0; "$UNINSTALL" >"$d/out/refuse" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "uninstall should refuse when no unit existed before install, got $rc"
grep -q 'did not exist before install' "$d/out/refuse" || fail "refusal does not say why"
grep -qx "ExecStart=\"$DEST/bin/jg-sentinel.sh\" loop" "$UNIT" || fail "refused uninstall touched the unit"
pass "uninstall refuses to stop a sentinel that had no unit before install"
