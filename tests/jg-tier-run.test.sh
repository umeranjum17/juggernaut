#!/usr/bin/env bash
# bin/jg-tier-run.sh runs each journey of a tier through done-done, reports red ones, and refuses an empty tier.
# Uses a fake done-done on PATH, so it checks the runner's own contract: the call shape and the exit codes.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
d="$(mktemp -d)"; trap 'rm -rf -- "$d"' EXIT
mkdir "$d/bin"
cat >"$d/bin/done-done" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
case "$2" in red-one) exit 1 ;; esac
F
chmod +x "$d/bin/done-done"
cat >"$d/cfg.yaml" <<'Y'
app: t
journeys:
  green-a:
    tier: ci
    command: x
  red-one:
    tier: ci
    command: x
  other:
    tier: local
    command: x
Y
run() { FAKE_LOG="$d/log" PATH="$d/bin:$PATH" JG_TIER_CONFIG="$d/cfg.yaml" bash "$ROOT/bin/jg-tier-run.sh" "$@" >"$d/out" 2>&1; }
: >"$d/log"
run ci; rc=$?
if [ "$rc" = 1 ]; then ok "a red journey makes the tier exit 1"; else bad "exit $rc, want 1"; fi
if [ "$(cat "$d/log")" = "$(printf 'run green-a --tier ci\nrun red-one --tier ci')" ]; then ok "every ci journey ran by name, the local one did not"; else bad "calls: $(cat "$d/log")"; fi
run live; rc=$?
if [ "$rc" = 2 ]; then ok "an empty tier exits 2"; else bad "empty tier exit $rc, want 2"; fi
sed -i 's/red-one) exit 1/never) exit 1/' "$d/bin/done-done"
run ci; rc=$?
if [ "$rc" = 0 ]; then ok "all green exits 0"; else bad "all green exit $rc"; fi
exit "$fail"
