#!/usr/bin/env bash
# A launch never carries a provider credential it was not allowed to carry.
# The real builder (bin/jg-launch-env-lib.sh, called by bin/jg-spawn.sh) is run
# here in a subshell with planted synthetic names: the credential name must be
# gone, an allowlisted credential must survive, and a non-credential name that
# merely contains KEY must survive. The names exist only in the pane, never in
# the process that builds the launch. Only names are used; the values are
# synthetic and are never asserted on.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/jg-launch-env-lib.sh
. "$ROOT/bin/jg-launch-env-lib.sh"

# print_set <shell> <prefix>: run the emitted prefix in a fresh shell that holds
# the synthetic names, then report which of them are still set.
print_set() {
  local shell=$1 prefix=$2
  # shellcheck disable=SC2016  # the inner shell expands these
  env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" \
    OPENROUTER_API_KEY=synthetic-credential \
    JG_TEST_REFRESH_TOKEN=synthetic-credential \
    JG_TEST_ALLOWED_API_KEY=synthetic-credential \
    STARSHIP_SESSION_KEY=synthetic-not-a-credential \
    GIT_CONFIG_KEY_0=synthetic-not-a-credential \
    JG_TEST_BENIGN=synthetic-value \
    "$shell" -c "$prefix"'for n in OPENROUTER_API_KEY JG_TEST_REFRESH_TOKEN \
      JG_TEST_ALLOWED_API_KEY STARSHIP_SESSION_KEY GIT_CONFIG_KEY_0 JG_TEST_BENIGN; do
      eval "v=\${$n+set}"
      printf "%s=%s\n" "$n" "${v:-unset}"
    done'
}

# The builder runs in a process that holds none of the planted names, as the
# spawner does: the pane, not the spawner, is where they exist.
# shellcheck disable=SC2016  # the inner shell expands these
prefix=$(env -i PATH=/usr/bin:/bin bash -c '. "$1"; jg_launch_env_strip_prefix ""' _ "$ROOT/bin/jg-launch-env-lib.sh") ||
  fail "the builder failed with no allowlist"
assert_contains "$prefix" "unset" "the builder emitted no unset statement"
pass "the builder emits a pane-side strip that needs no name from the spawner"

for pane_shell in /bin/sh /bin/bash /bin/zsh; do
  [ -x "$pane_shell" ] || continue
  out=$(print_set "$pane_shell" "$prefix") || fail "$pane_shell could not run the prefix"
  assert_contains "$out" "OPENROUTER_API_KEY=unset" "$pane_shell kept a provider key"
  assert_contains "$out" "JG_TEST_REFRESH_TOKEN=unset" "$pane_shell kept a token"
  assert_contains "$out" "STARSHIP_SESSION_KEY=set" "$pane_shell lost a non-credential name"
  assert_contains "$out" "GIT_CONFIG_KEY_0=set" "$pane_shell lost a git config name"
  assert_contains "$out" "JG_TEST_BENIGN=set" "$pane_shell lost a plain variable"
  pass "$pane_shell starts the worker without the planted credential"
done

# An allowlisted credential is the one a launch is explicitly permitted to
# carry, so the builder must leave it alone.
prefix=$(jg_launch_env_strip_prefix $'JG_TEST_ALLOWED_API_KEY\n') || fail "the builder failed with an allowlist"
out=$(print_set /bin/sh "$prefix") || fail "the prefix failed with an allowlist"
assert_contains "$out" "JG_TEST_ALLOWED_API_KEY=set" "an allowlisted credential did not reach the worker"
assert_contains "$out" "OPENROUTER_API_KEY=unset" "an unlisted credential reached the worker"
pass "an allowlisted credential survives and an unlisted one does not"
