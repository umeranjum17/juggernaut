#!/usr/bin/env bash
# Sourced by every test that runs a merge-gate rule before it moves HOME. The gate asks the Rego policy
# (policy/gate/) through the Go guard host, so these tests need OPA and Go and skip without them. The runner
# keeps the real Go build cache for them (bin/jg-test-host-lib.sh), so a throwaway HOME does not rebuild Go.
command -v opa >/dev/null 2>&1 || { echo "skip: no opa on PATH (install OPA, see toolchain.versions)"; exit 0; }
command -v "${JG_GUARD_HOST_GO:-go}" >/dev/null 2>&1 || { echo "skip: no Go toolchain on PATH"; exit 0; }
# One built guard host for every test, outside the throwaway HOME, rebuilt by its dispatcher only when a source is newer.
export JG_GUARD_HOST_BIN=${JG_GUARD_HOST_BIN:-${XDG_CACHE_HOME:-$HOME/.cache}/jg-test/jg-guard-host}
