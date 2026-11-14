#!/usr/bin/env bash
# runners run-shard: run one gate shard on a registered runner and bring its JSON back (H30b).
# Usage: run-shard.sh <jg-home> <runner-id> <commit> <base> <out-json> -- <jg-test-run.sh arguments>
#   Bundles <base>..<commit> from the repository this script lives in, sends it as the stdin of the runner's job
#   bin/jg-runner-shard.sh through bin/jg-on.sh --stdin (the remote job queue; its stdin bound is 1 MiB), and writes the
#   shard's JSON, as it came back on stdout, to <out-json>.
# Exit: 0  the shard ran green          1  the shard ran red (its JSON is written)
#       3  the runner was lost: no connection (ssh 255), the runner could not run the shard (97), no JSON came back, or
#          the bundle does not fit the queue. This is never a red: the caller reruns the shard here or on another runner.
#       2  usage
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$DIR/../.." && pwd)}"
LOST=3
[ "$#" -ge 7 ] && [ "$6" = -- ] && [ -d "$1" ] || { echo "usage: run-shard.sh <jg-home> <runner-id> <commit> <base> <out-json> -- <jg-test-run.sh arguments>" >&2; exit 2; }
home=$1 runner=$2 commit=$3 base=$4 out=$5
shift 6
max=${JG_REMOTE_JOB_MAX_BYTES:-1048576}

lost() { printf 'run-shard: runner %s lost: %s\n' "$runner" "$1" >&2; exit "$LOST"; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/jg-run-shard.XXXXXX") || { echo "run-shard: cannot create a scratch directory" >&2; exit 2; }
ref=refs/jg-shard/$commit
# The scratch path is the one literal deleted: a mktemp directory just made. The temporary ref only names the bundle's tip.
cleanup() { git -C "$ROOT" update-ref -d "$ref" 2>/dev/null || :; rm -rf -- "$scratch"; }
trap cleanup EXIT

git -C "$ROOT" update-ref "$ref" "$commit" || { echo "run-shard: $commit is not a commit of $ROOT" >&2; exit 2; }
git -C "$ROOT" bundle create -q "$scratch/shard.bundle" "$ref" "^$base" 2>"$scratch/bundle.err" \
  || { echo "run-shard: cannot bundle $base..$commit: $(tail -n 1 "$scratch/bundle.err")" >&2; exit 2; }
bytes=$(wc -c < "$scratch/shard.bundle")
[ "$bytes" -le "$max" ] || lost "the bundle is $bytes bytes, over the queue's $max-byte bound"

rc=0
JG_HOME="$home" "$ROOT/bin/jg-on.sh" --stdin "$runner" jg-runner-shard.sh "$commit" "$base" -- "$@" \
  < "$scratch/shard.bundle" > "$scratch/result.json" 2> "$scratch/job.err" || rc=$?
cat "$scratch/job.err" >&2
case $rc in
  255) lost "no connection" ;;
  97) lost "it could not run the shard" ;;
esac
[ -s "$scratch/result.json" ] || lost "no result came back (exit $rc)"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$scratch/result.json" 2>/dev/null || lost "the result is not JSON (exit $rc)"
cp "$scratch/result.json" "$out" || { echo "run-shard: cannot write $out" >&2; exit 2; }
[ "$rc" -eq 0 ] || exit 1
