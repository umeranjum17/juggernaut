#!/usr/bin/env bash
# tests/git-config-helpers.sh - fixture Git isolation from the host's global and
# system configuration and from an inherited repository location.
#
# Source this before a fixture's first Git operation:
#   # shellcheck source=tests/git-config-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"
#
# Fixture Git processes must not inherit host signing, hooks, or other global and
# system preferences: with commit.gpgsign=true set globally and no secret key for
# the fixture identities, every fixture commit fails before its assertion.
# Isolation is limited to the inherited layers on purpose, so repository-local config,
# inline `git -c`, and a GIT_CONFIG_COUNT or GIT_CONFIG_GLOBAL the suite itself sets
# after sourcing all stay authoritative - the Git-config suites assert on them.
# The export reaches only the sourcing shell and its children, so the developer's
# own config files are never written and real project commits made outside the
# fixtures keep their configuration and signing.
#
# The repository-location variables are cleared too: an absolute GIT_DIR (as a
# linked-worktree hook exports) overrides the discovery `git -C <fixture>`
# implies, so fixture refs, commits, and worktree registrations would land in
# the caller's repository instead. A suite that wants one sets it after sourcing.
#
# tests/lib.sh and tests/herdr-test-safety.sh source this for every suite that
# uses them, bin/jg-test-run.sh sources it per suite in run_script_bounded, and a
# suite reaching none of those sources it directly so a hand-run invocation is
# isolated too. tests/jg-test-fixtures.test.sh is the regression - it drives the
# shared helpers, the runner, and the standalone entry points that run without a
# live vendor - and the changed-file map selects it for a change to this file.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# Config injected through the environment is the caller's too: a fleet pane carries
# core.hooksPath (the managed hooks, including reference-transaction) and identity
# includes in GIT_CONFIG_COUNT/KEY_n/VALUE_n or GIT_CONFIG_PARAMETERS. Inherited, they
# make `git init -b main` in a fresh fixture abort in the hook before the repository
# is valid ("not a git repository: .../.git"). GLOBAL, SYSTEM and NOSYSTEM keep the
# values set above.
for _jg_gitvar in $(compgen -v GIT_CONFIG_); do
  case $_jg_gitvar in
  GIT_CONFIG_GLOBAL | GIT_CONFIG_SYSTEM | GIT_CONFIG_NOSYSTEM) ;;
  *) unset "$_jg_gitvar" ;;
  esac
done
unset _jg_gitvar
