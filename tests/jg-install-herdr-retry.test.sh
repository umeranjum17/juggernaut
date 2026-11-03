#!/usr/bin/env bash
# Journey: the pinned Herdr install survives a transient download failure
# without weakening verification.
#
# Drives bin/jg-install-herdr.sh end to end with a stubbed `curl`. The script's
# real SHA-256 pins name upstream release binaries no fixture can reproduce, so
# the run uses a copy of the script whose pin lines are rewritten to the stub
# asset's digest; every other line, including the retry loop, the hash compare
# and the version/protocol-floor assertions, is the shipped code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null || { echo "skip: jq required"; exit 0; }
if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "skip: sha256sum or shasum required"; exit 0
fi

ROOT_DIR=$(jg_test_tmproot jg-install-herdr-retry) || fail "tmp root"
FAKEBIN=$(jg_fakebin "$ROOT_DIR")

write_stub_asset() {  # <path> <protocol>
  cat > "$1" <<SH
#!/bin/sh
case "\$1" in
  --version) echo "herdr 0.7.4" ;;
  status) echo '{"client":{"version":"0.7.4","protocol":$2}}' ;;
esac
SH
}

# Stub curl: fail with exit 56 for the first $CURL_FAILS calls, then copy the
# staged asset to the -o target. Every call is counted in $CURL_COUNT_FILE.
cat > "$FAKEBIN/curl" <<'SH'
#!/bin/sh
n=$(cat "$CURL_COUNT_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$CURL_COUNT_FILE"
out=
while [ $# -gt 0 ]; do
  [ "$1" = -o ] && out=$2
  shift
done
[ "$n" -le "${CURL_FAILS:-0}" ] && exit 56
cp "$STUB_ASSET" "$out"
SH
chmod +x "$FAKEBIN/curl"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/sleep"; chmod +x "$FAKEBIN/sleep"

# run_install <case> <protocol> <pin-digest|good> <curl-fails>
run_install() {
  local name=$1 protocol=$2 pin=$3 fails=$4 dir
  dir="$ROOT_DIR/$name"; mkdir -p "$dir/bin"
  write_stub_asset "$dir/asset" "$protocol"
  [ "$pin" = good ] && pin=$(digest "$dir/asset")
  sed "s/SHA256=[0-9a-f]\{64\}/SHA256=$pin/" "$ROOT/bin/jg-install-herdr.sh" > "$dir/bin/jg-install-herdr.sh"
  chmod +x "$dir/bin/jg-install-herdr.sh"
  echo 0 > "$dir/count"
  OUT=$(PATH="$FAKEBIN:$PATH" STUB_ASSET="$dir/asset" CURL_COUNT_FILE="$dir/count" \
    CURL_FAILS=$fails RUNNER_TEMP="$ROOT_DIR" JG_HERDR_CI_RETRY_DELAY=0 \
    "$dir/bin/jg-install-herdr.sh" "$dir/dest" 2>&1)
  RC=$?
  CALLS=$(cat "$dir/count")
  DEST="$dir/dest/herdr"
}

# 1. One transient failure, then success: install completes, pin verified.
run_install transient 16 good 1
[ "$RC" -eq 0 ] || fail "transient failure then success should install (rc=$RC): $OUT"
[ "$CALLS" -eq 2 ] || fail "expected 2 download attempts, got $CALLS"
[ -x "$DEST" ] || fail "herdr not installed after a retried download"
case "$OUT" in *"download attempt 1 failed (curl exit status 56); retrying"*) ;; *) fail "retry not announced: $OUT" ;; esac
case "$OUT" in *"installed herdr 0.7.4 (protocol 16)"*) ;; *) fail "success line missing: $OUT" ;; esac
pass "download fails once, retry succeeds, install completes"

# 2. Wrong hash: fails on the first attempt, never retried, nothing installed.
run_install badhash 16 0000000000000000000000000000000000000000000000000000000000000000 0
[ "$RC" -ne 0 ] || fail "a hash mismatch must fail the install"
[ "$CALLS" -eq 1 ] || fail "a hash mismatch must not retry (downloads: $CALLS)"
case "$OUT" in *"checksum mismatch"*) ;; *) fail "mismatch not named: $OUT" ;; esac
[ ! -e "$DEST" ] || fail "binary installed despite hash mismatch"
pass "wrong hash fails on the first attempt with no retry"

# 3. Retry does not skip the protocol floor: a good hash below the floor fails.
run_install lowproto 15 good 1
[ "$RC" -ne 0 ] || fail "a below-floor protocol must fail after a retried download"
case "$OUT" in *"below the required floor"*) ;; *) fail "floor failure not named: $OUT" ;; esac
pass "protocol floor still asserted after a retried download"

# 4. Persistent failure: bounded attempts, final error names URL and last failure.
run_install persistent 16 good 99
[ "$RC" -ne 0 ] || fail "persistent download failure must fail"
[ "$CALLS" -eq 3 ] || fail "expected exactly 3 bounded attempts, got $CALLS"
case "$OUT" in
  *"download failed for https://github.com/"*"after 3 attempts (last curl exit status 56"*) ;;
  *) fail "final error must name the URL and last failure: $OUT" ;;
esac
pass "persistent failure stops after 3 attempts naming URL and last status"
