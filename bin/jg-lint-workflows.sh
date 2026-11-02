#!/usr/bin/env bash
# jg-lint-workflows.sh - owner of juggernaut's GitHub workflow lint.
#
# Runs pinned actionlint on every .github/workflows/*.{yml,yaml} so a malformed
# workflow, including a self-broken ci.yml, fails in the local and no-mistakes
# lint lane before merge. A broken ci.yml cannot report its own breakage, so
# this check must not live only as a step inside that workflow. bin/jg-lint.sh
# invokes this owner on its default (no explicit-path) path, which CI and
# commands.lint both use.
#
# Usage:
#   jg-lint-workflows.sh                 lint workflows under this repo
#   jg-lint-workflows.sh --root <dir>    lint workflows under <dir>
#   jg-lint-workflows.sh <path>...       lint explicit workflow files
#   jg-lint-workflows.sh --required-version
#   jg-lint-workflows.sh --help
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

REQUIRED_ACTIONLINT=1.7.12
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/jg-lint-workflows.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_ACTIONLINT"
  exit 0
fi

jg_lint_workflows_usage() {
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'jg-lint-workflows.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      jg_lint_workflows_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'jg-lint-workflows.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'jg-lint-workflows.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

FILES=()
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'jg-lint-workflows.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'jg-lint-workflows.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    FILES+=("$path")
  done
else
  workflow_dir="$ROOT/.github/workflows"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$workflow_dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'jg-lint-workflows.sh: no GitHub workflow files found under %s\n' \
      "$workflow_dir" >&2
    exit 1
  fi
fi

if ! command -v actionlint >/dev/null 2>&1; then
  printf 'jg-lint-workflows.sh: actionlint not found; install actionlint %s with bin/jg-install-actionlint.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi
ACTIONLINT_BIN=$(command -v actionlint)
resolved=$("$ACTIONLINT_BIN" -version | awk 'NR==1 {print; exit}')
printf 'jg-lint-workflows.sh: actionlint %s (pinned %s)\n' "$resolved" "$REQUIRED_ACTIONLINT" >&2
if [ "$resolved" != "$REQUIRED_ACTIONLINT" ]; then
  printf 'jg-lint-workflows.sh: actionlint %s required for CI parity, found %s. Install %s with bin/jg-install-actionlint.sh <destination-directory>.\n' \
    "$REQUIRED_ACTIONLINT" "$resolved" "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi

# jg-lint.sh owns ShellCheck of the canonical shell set. Disable actionlint's
# extra shell and Python subprocess linters so this gate is the named workflow
# linter, not a second shell lint of `run:` blocks.
set +e
"$ACTIONLINT_BIN" -no-color -shellcheck= -pyflakes= -- "${FILES[@]}"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

printf 'jg-lint-workflows.sh: %s workflow files valid\n' "${#FILES[@]}"
exit 0
