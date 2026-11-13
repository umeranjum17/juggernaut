#!/usr/bin/env bash
# jg-shard-hints-refresh.sh - refresh the portable test shard hints from the Behavior suite's own timings.
#
# Usage: jg-shard-hints-refresh.sh [--timing-dir <dir>]... [--runs <n>] [--gate-log <file>] [--split] [--root <dir>]
#                                  [--repo <owner/name>] [--workflow <name>]
#
# The lane that takes the `shard-budget-<project>` ticket (bin/jg-trunk.sh files it when the coverage guard advises) runs this
# once and lands the edit like any change; nothing here commits, pushes or lands.
#
# Timing files: each --timing-dir holds one green run's jg-test-timing-*.json files (what bin/jg-test-run.sh --json writes and
# .github/workflows/behavior.yml uploads). Without one, the tool downloads the artifacts of the last green runs of the Behavior
# suite on the forge (gh; --runs, at most 5, default 5; --repo and --workflow override the defaults). It takes the runs that exist.
#   - A script with a sample keeps the slowest passing time (exit 0) across the runs, in whichever hint table lists it.
#   - A script with no sample keeps its old hint.
#   - A script in the serial lane with no hint at all gets a provisional one from --gate-log: the gate's own JG_TEST_END time for
#     it on this host, rounded up to 500 ms. The gate log also names which scripts have no hint (the paths the coverage advice
#     lists); without --gate-log the tool runs `bin/jg-test-run.sh --check-coverage` itself to find them. The next refresh after a
#     forge run holds the script replaces a provisional hint with a measurement.
#   - --split: when the guard still advises that the largest shard is over its budget after the rewrite, raise
#     PORTABLE_SERIAL_SHARDS in bin/jg-test-run.sh by one and add that shard to the matrix in .github/workflows/behavior.yml.
#     The lane's own gate checks the result; the tool does not re-run the guard after a split.
# --root names the checkout to edit (default: this script's repository).
# Prints what changed and the final `JG_TEST_COVERAGE` line; exits 0 when the rewrite was made, 2 on a usage error, 1 on any failure.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO=umeranjum17/juggernaut
WORKFLOW="Behavior suite"
RUNS=5
GATE_LOG=
SPLIT=0
DIRS=()

die() { echo "jg-shard-hints-refresh: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --timing-dir) [ "$#" -gt 1 ] || { echo "--timing-dir needs a directory" >&2; exit 2; }; DIRS+=("$2"); shift 2 ;;
    --runs) [ "$#" -gt 1 ] || { echo "--runs needs a number" >&2; exit 2; }; RUNS=$2; shift 2 ;;
    --gate-log) [ "$#" -gt 1 ] || { echo "--gate-log needs a file" >&2; exit 2; }; GATE_LOG=$2; shift 2 ;;
    --root) [ "$#" -gt 1 ] || { echo "--root needs a directory" >&2; exit 2; }; ROOT=$(cd "$2" && pwd); shift 2 ;;
    --repo) [ "$#" -gt 1 ] || { echo "--repo needs owner/name" >&2; exit 2; }; REPO=$2; shift 2 ;;
    --workflow) [ "$#" -gt 1 ] || { echo "--workflow needs a name" >&2; exit 2; }; WORKFLOW=$2; shift 2 ;;
    --split) SPLIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case $RUNS in ''|*[!0-9]*) echo "--runs needs a number" >&2; exit 2 ;; esac
[ "$RUNS" -ge 1 ] && [ "$RUNS" -le 5 ] || { echo "--runs takes 1 to 5" >&2; exit 2; }
[ -z "$GATE_LOG" ] || [ -r "$GATE_LOG" ] || die "cannot read the gate log $GATE_LOG"
RUNNER="$ROOT/bin/jg-test-run.sh"
WORKFLOW_FILE="$ROOT/.github/workflows/behavior.yml"
[ -f "$RUNNER" ] || die "no $RUNNER"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/jg-shard-hints.XXXXXX")
trap 'rm -rf -- "$SCRATCH"' EXIT

# The timing files of the last green runs on the forge, one directory per run.
fetch_forge_runs() {
  command -v gh >/dev/null 2>&1 || die "gh is required to read the forge; pass --timing-dir instead"
  local ids id
  ids=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --status success --limit "$RUNS" --json databaseId --jq '.[].databaseId') \
    || die "cannot list the green $WORKFLOW runs of $REPO"
  [ -n "$ids" ] || die "$REPO has no green $WORKFLOW run to read"
  for id in $ids; do
    mkdir -p "$SCRATCH/run-$id"
    gh run download "$id" --repo "$REPO" --pattern 'jg-test-timing-*' --dir "$SCRATCH/run-$id" >/dev/null \
      || die "cannot download the timing files of run $id"
    DIRS+=("$SCRATCH/run-$id")
  done
}
[ "${#DIRS[@]}" -gt 0 ] || fetch_forge_runs
[ "${#DIRS[@]}" -le "$RUNS" ] || DIRS=("${DIRS[@]:0:$RUNS}")

# The scripts that have no hint: the paths the coverage advice lists (the gate's own log, else a guard run of this checkout).
if [ -n "$GATE_LOG" ]; then cp -- "$GATE_LOG" "$SCRATCH/gate.log"
else (cd "$ROOT" && bash "$RUNNER" --check-coverage) >"$SCRATCH/gate.log" 2>&1 || true; fi

python3 -I - "$RUNNER" "$SCRATCH/gate.log" "${DIRS[@]}" <<'PY'
import glob, json, os, re, sys

runner, gate_log, dirs = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(runner, encoding="utf-8").read()
TABLES = ("portable_parallel_weight_hints", "portable_serial_weight_hints")

best = {}                      # script -> slowest passing duration_ms across the runs
for d in dirs:
    files = sorted(glob.glob(os.path.join(d, "**", "jg-test-timing-*.json"), recursive=True))
    if not files:
        sys.exit("jg-shard-hints-refresh: no jg-test-timing-*.json under %s" % d)
    for f in files:
        for s in json.load(open(f, encoding="utf-8")).get("scripts", []):
            if s.get("exit") == 0:
                best[s["path"]] = max(best.get(s["path"], 0), int(s["duration_ms"]))

log = open(gate_log, encoding="utf-8", errors="replace").read()
gate_ms = {m.group(1): int(m.group(2)) for m in
           re.finditer(r"^JG_TEST_END \S+ (\S+) exit=0 duration_ms=(\d+)", log, re.M)}
unhinted = re.findall(r"^(tests/\S+\.sh)$", log, re.M)

changed = []
def rewrite(name, body):
    out, seen = [], set()
    for line in body.splitlines():
        path, _, ms = line.partition(" ")
        seen.add(path)
        new = best.get(path)
        if new is not None and str(new) != ms:
            changed.append("%s %s -> %d" % (path, ms, new))
            line = "%s %d" % (path, new)
        out.append(line)
    if name == "portable_serial_weight_hints":
        for path in dict.fromkeys(unhinted):
            if path in seen:
                continue
            # a measurement from the forge wins; else the gate's own time here, rounded up to 500 ms
            ms = best.get(path) or (-(-gate_ms[path] // 500) * 500 if path in gate_ms else None)
            if ms is None:
                print("no sample and no gate time for %s: left without a hint" % path, file=sys.stderr)
                continue
            kind = "measured" if path in best else "provisional"
            changed.append("%s new %s %d" % (path, kind, ms))
            out.append("%s %d" % (path, max(ms, 1)))
    return "\n".join(out)

for name in TABLES:
    pat = re.compile(r"(%s\(\) \{\n  cat <<'EOF'\n)(.*?)(\nEOF\n\})" % name, re.S)
    m = pat.search(text)
    if not m:
        sys.exit("jg-shard-hints-refresh: the %s table is not where it was" % name)
    text = text[:m.start(2)] + rewrite(name, m.group(2)) + text[m.end(2):]

open(runner, "w", encoding="utf-8").write(text)
print("hints rewritten from %d run(s): %d change(s)" % (len(dirs), len(changed)))
for c in changed:
    print("  " + c)
PY

verdict_line() { (cd "$ROOT" && bash "$RUNNER" --check-coverage 2>"$SCRATCH/guard.err") | grep -a '^JG_TEST_COVERAGE ' | tail -n 1; }
line=$(verdict_line) || { cat "$SCRATCH/guard.err" >&2; die "the coverage guard refused after the rewrite"; }
field() { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

if [ "$SPLIT" = 1 ] && [ "$(field serial_max_ms)" -gt "$(field serial_budget_ms)" ]; then
  n=$(sed -n 's/^PORTABLE_SERIAL_SHARDS=\([0-9][0-9]*\)$/\1/p' "$RUNNER")
  [ -n "$n" ] || die "PORTABLE_SERIAL_SHARDS is not where it was in $RUNNER"
  [ -f "$WORKFLOW_FILE" ] || die "no $WORKFLOW_FILE"
  grep -q "^        shard: \[1, .*, $n\]$" "$WORKFLOW_FILE" || die "the serial matrix in $WORKFLOW_FILE does not end at shard $n"
  sed -i "s/^PORTABLE_SERIAL_SHARDS=$n\$/PORTABLE_SERIAL_SHARDS=$((n + 1))/" "$RUNNER"
  sed -i "s/^\(        shard: \[1, .*, $n\)\]\$/\1, $((n + 1))]/" "$WORKFLOW_FILE"
  echo "split: PORTABLE_SERIAL_SHARDS $n -> $((n + 1)); the serial matrix gained shard $((n + 1)); the lane's gate checks the result"
elif [ "$SPLIT" = 1 ]; then
  echo "split: not needed, the largest shard is within its budget"
fi
echo "$line"
