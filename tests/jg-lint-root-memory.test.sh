#!/usr/bin/env bash
# The bounded-envelope path in bin/jg-lint.sh, fast: a root that outgrows the
# default address-space envelope must be re-run under its own measured allowance
# with source following intact, and a root that cannot fit even there must fail.
#
# Both cases force the memory failure with JG_LINT_ROOT_MEMORY_KIB instead of
# waiting for a multi-gigabyte root, and both drive the real script end to end.
# The fixture's finding is SC2153, which only exists when the sourced file is
# analysed: that is the code the retired no-source fallback excluded, so seeing
# it in the output is what proves the scoped re-run still checks cross-file codes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/jg-lint.sh"
TMP_ROOT=$(jg_test_tmproot jg-lint-root-memory)

# ulimit -v is what the per-root envelope is built on, and macOS cannot apply it,
# so a required-bounds run refuses there before any root starts.
case "$(uname -s)" in
  Darwin) printf 'skip: macOS cannot apply the per-root address-space limit\n'; exit 0 ;;
esac

# make_root <case-name>: a root that sources a library whose variable name the
# root misspells. With source following ShellCheck reports SC2153 for the
# misspelling; without it, the same file only yields SC1091 (not following),
# which the old no-source fallback excluded. Echoes the root path.
make_root() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir"
  cat > "$case_dir/lib.sh" <<'SH'
#!/usr/bin/env bash
SHARED_TIMEOUT=5
SH
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck source=%s/lib.sh\n' "$case_dir"
    printf '. "%s/lib.sh"\n' "$case_dir"
    printf "printf '%%s\\\\n' \"\$SHARED_TIMOUT\"\n"
  } > "$case_dir/root.sh"
  printf '%s\n' "$case_dir/root.sh"
}

# A 24 MiB envelope withholds the heap ShellCheck needs to start, so the first
# attempt really does die on memory (rc=251) and the scoped path is the only way
# this root can be analysed at all.
DEFAULT_ENVELOPE_KIB=24576

test_a_scoped_rerun_keeps_cross_file_codes() {
  local root output rc
  root=$(make_root scoped-pass)
  output=$(JG_LINT_REQUIRE_BOUNDS=1 \
    JG_LINT_ROOT_MEMORY_KIB=$DEFAULT_ENVELOPE_KIB \
    JG_LINT_ROOT_ALLOWANCE_KIB=8388608 \
    bash "$LINT" "$root" 2>&1)
  rc=$?
  # 1 is the finding the scoped attempt legitimately reports, not a memory
  # failure: the first attempt never got far enough to report anything.
  expect_code 1 "$rc" 'a scoped re-run reports its finding and exits on it'
  assert_contains "$output" 'outgrew the 24576 KiB default address-space envelope (reason=memory rc=251)' \
    'the default envelope refused the root on memory'
  assert_contains "$output" 'cross-file codes were still checked' \
    'the scoped re-run says the same source-following analysis ran'
  assert_contains "$output" 'SC2153' \
    'the scoped re-run reports the cross-file-only finding'
  assert_not_contains "$output" 'cross-file codes excluded' \
    'no attempt is reported with the cross-file codes excluded'
  pass 'a root that outgrows the default envelope re-runs with source following and reports SC2153'
}

test_an_allowance_that_is_too_small_still_fails() {
  local root output rc
  root=$(make_root scoped-fail)
  # A 20 MiB allowance is still less than this root's first allocation, so the
  # scoped attempt dies too. The run must refuse instead of falling back to a
  # narrower analysis that would pass.
  output=$(JG_LINT_REQUIRE_BOUNDS=1 \
    JG_LINT_ROOT_MEMORY_KIB=$DEFAULT_ENVELOPE_KIB \
    JG_LINT_ROOT_ALLOWANCE_KIB=20480 \
    bash "$LINT" "$root" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail 'a root that cannot fit its scoped allowance must fail lint'
  assert_contains "$output" 'the scoped re-run did not finish' \
    'the refusal names the failed scoped re-run'
  assert_contains "$output" 'the memory failure stands' \
    'the refusal keeps the memory failure instead of passing the root'
  assert_not_contains "$output" 'cross-file codes excluded' \
    'a failed run never falls back to an analysis with the cross-file codes excluded'
  pass 'a root that exceeds even its scoped allowance still fails, and never falls back'
}

test_a_scoped_rerun_keeps_cross_file_codes
test_an_allowance_that_is_too_small_still_fails
printf 'jg-lint-root-memory: ok\n'
