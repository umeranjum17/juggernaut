#!/usr/bin/env bash
# The runner links the real python3 and node ahead of a tool manager's shims, so a test that moves HOME still runs them.
# A shim that refuses unless HOME is the home it started with stands in for the manager's "config.toml is not trusted".
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/jg-test-run.sh"
TMP_ROOT=$(jg_test_tmproot jg-test-run-tools)
export JG_TEST_HOST_SLOTS="$TMP_ROOT/run-slots"
mkdir -p "$TMP_ROOT/shims" "$TMP_ROOT/real" "$TMP_ROOT/start-home"

for name in python3 node; do
  # shellcheck disable=SC2016 # the shim body expands when the shim runs
  printf '#!/bin/sh\n[ "$HOME" = "%s" ] || { echo "shim refused"; exit 1; }\nexec /usr/bin/%s "$@"\n' "$TMP_ROOT/start-home" "$name" >"$TMP_ROOT/shims/$name"
  # The runner itself uses python3 under the start home, so the real stub passes that call to the system program.
  # shellcheck disable=SC2016 # the stub body expands when the stub runs
  printf '#!/bin/sh\n[ "$HOME" != "%s" ] || exec /usr/bin/%s "$@"\necho "real ran"\n' "$TMP_ROOT/start-home" "$name" >"$TMP_ROOT/real/$name"
  chmod +x "$TMP_ROOT/shims/$name" "$TMP_ROOT/real/$name"
done

printf '#!/usr/bin/env bash\nset -u\nmkdir -p "%s/empty-home"\nHOME="%s/empty-home" python3 || exit 1\nHOME="%s/empty-home" node || exit 1\n' \
  "$TMP_ROOT" "$TMP_ROOT" "$TMP_ROOT" >"$TMP_ROOT/fixture.test.sh"
chmod +x "$TMP_ROOT/fixture.test.sh"

# run_case <path-prefix>: runs the fixture through the runner with HOME at the start home; output in $OUT, status in $RC.
run_case() {
  RC=0
  OUT=$(env HOME="$TMP_ROOT/start-home" PATH="$1:/usr/bin:/bin" bash "$RUNNER" --jobs 1 "$TMP_ROOT/fixture.test.sh" 2>&1) || RC=$?
}

test_shims_first_in_path_are_bypassed() {
  local n
  run_case "$TMP_ROOT/shims:$TMP_ROOT/real"
  [ "$RC" = 0 ] || fail "the run must exit 0, got $RC: $OUT"
  printf '%s\n' "$OUT" | grep -Eq 'JG_TEST_END .*exit=0' || fail "the fixture must end with exit=0: $OUT"
  n=$(printf '%s\n' "$OUT" | grep -c 'real ran' || true)
  [ "$n" = 2 ] || fail "real ran must appear twice, got $n: $OUT"
  ! printf '%s\n' "$OUT" | grep -q 'shim refused' || fail "a shim ran: $OUT"
  printf '%s\n' "$OUT" | grep -Fxq 'jg-test-run: tool shims bypassed: python3 node' || fail "the bypass line is missing: $OUT"
  pass 'a run bypasses shims ahead of the real tools and says which'
}

test_no_shims_folder_changes_nothing() {
  run_case "$TMP_ROOT/real"
  [ "$RC" = 0 ] || fail "the run must exit 0, got $RC: $OUT"
  ! printf '%s\n' "$OUT" | grep -q 'tool shims bypassed' || fail "a run with no shims folder printed the bypass line: $OUT"
  pass 'a run with no shims folder links nothing'
}

test_shims_first_in_path_are_bypassed
test_no_shims_folder_changes_nothing
