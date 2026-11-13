#!/usr/bin/env bash
# jg-runner-shard.sh - the runner's half of a gate shard (H30b): run one shard of the test selection at a commit that
# arrived as a git bundle, and print the shard's timing JSON.
# Usage: jg-runner-shard.sh <commit> <base> -- <jg-test-run.sh arguments>      the bundle is the job's stdin
#   Runs only as a remote job (bin/jg-on.sh --stdin <runner> jg-runner-shard.sh ...; core/runners/run-shard.sh is the caller),
#   under the remote job queue's own bounds: stdin and stdout are capped at 1 MiB, and the job record carries the shard
#   timeout (jg_remote_job_command_timeout in bin/jg-remote-job-lib.sh).
#   The bundle holds <base>..<commit> under refs/jg-shard/<commit>. It is fetched into a throw-away shared clone of this
#   code root (the runner's own repository is never changed), the commit is checked out there, and bin/jg-test-run.sh of
#   that commit runs with the given arguments plus --json. stdout is that JSON and nothing else; the log goes to stderr.
# Exit: the shard's own exit status when it wrote its JSON (0 green, else red); 97 when the runner could not run the shard
#   at all (bad arguments, a bundle it cannot apply, no JSON), which the caller treats as a lost runner and never as a red.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$DIR/.." && pwd)}"
UNABLE=97

unable() { printf 'jg-runner-shard: %s\n' "$1" >&2; exit "$UNABLE"; }
[ "$#" -ge 3 ] && [ "$3" = -- ] || unable "usage: jg-runner-shard.sh <commit> <base> -- <jg-test-run.sh arguments>"
commit=$1 base=$2
shift 3
for sha in "$commit" "$base"; do
  case $sha in *[!0-9a-f]*|'') unable "not a full commit id: $sha" ;; esac
  [ "${#sha}" -eq 40 ] || unable "not a full commit id: $sha"
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/jg-runner-shard.XXXXXX") || unable "cannot create a scratch directory"
# The scratch path is the one literal this script deletes: a mktemp directory it just made.
# shellcheck disable=SC2329 # runs from the trap
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT
trap 'exit "$UNABLE"' INT TERM

cat > "$scratch/in.bundle" || unable "cannot read the bundle from stdin"
git clone -q --no-checkout --shared "$ROOT" "$scratch/tree" >&2 || unable "cannot clone the runner's code root $ROOT"
git -C "$scratch/tree" fetch -q "$scratch/in.bundle" "refs/jg-shard/$commit:refs/jg-shard/$commit" >&2 \
  || unable "the bundle does not apply: this runner's code root lacks $base or the bundle is damaged"
git -C "$scratch/tree" checkout -q --detach "$commit" >&2 || unable "cannot check out $commit"

mkdir -p "$scratch/tmp" || unable "cannot create the shard's temp directory"
rc=0
TMPDIR="$scratch/tmp" TMUX_TMPDIR="$scratch/tmp" JG_ROOT_OVERRIDE='' \
  bash "$scratch/tree/bin/jg-test-run.sh" "$@" --json "$scratch/out.json" >&2 || rc=$?
[ -s "$scratch/out.json" ] || unable "the shard stopped with exit $rc before it wrote its result"
cat "$scratch/out.json"
exit "$rc"
