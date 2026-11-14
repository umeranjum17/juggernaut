#!/usr/bin/env bash
# grace.sh - the verify grace (H39): a tracked policy key, off unless a home turns it on, and a verdict that names what it lets through.
#
#   grace.sh judge <proof-dir> <rc> [--project <name>]
#       <proof-dir> is the directory the verify gate gave `bin/jg-test-run.sh --required-shards` (shard-1.json to shard-8.json), <rc> the
#       gate's own exit status. Exit 0: the verify passes. Exit 1: it is red. Always prints one `grace:` line saying which and why.
#   grace.sh limit [--project <name>]
#       Print the grace in force: the policy key `verify-grace` (config/trunk-policy), default 0.
#
# A gate that exited 0 passes and the grace is never read. With the key at 0 (the default, so no grace unless a home sets it) any
# other exit is red. With the key at N the verify passes only when all of these hold, and is red otherwise:
#   - all 8 shard results are present and readable, and none of them is an error record;
#   - every shard that exited non-zero is explained by its own counted failures: it counted at least one failed script, and the
#     scripts it names as failed are exactly that many (a shard that failed for a non-test reason, such as no timing file or a
#     runner that stopped, has no counted failure and is red);
#   - the counted failures over the 8 shards are at most N, and at least one (a non-zero gate exit that no shard explains is red);
#   - every graced script gets its fix ticket through the one filer (core/trunk-landing/quarantine.sh ticket); one that cannot be
#     ticketed is not graced.
# The verdict names each graced script and its ticket. The project defaults to JG_QUARANTINE_PROJECT, else juggernaut.
# Exit 2: usage error.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/../.." && pwd -P)
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$ROOT/bin/jg-trunk-policy-lib.sh"

die() { echo "grace: $*" >&2; exit 2; }
red() { echo "grace: red: $*"; exit 1; }

PROJECT=${JG_QUARANTINE_PROJECT:-juggernaut} ARGS=()
case ${1:-} in -h|--help|"") sed -n '2,/^# Exit 2/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
CMD=$1; shift
while [ $# -gt 0 ]; do
  case $1 in
    --project) [ $# -ge 2 ] || die "--project needs a name"; PROJECT=$2; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ $PROJECT =~ ^[A-Za-z0-9._-]+$ ]] || die "the project name has characters a file name cannot hold: $PROJECT"

# The grace in force: a whole number, 0 when the key is unset or is anything else.
limit() {
  local v; v=$(jg_trunk_policy verify-grace "$PROJECT" 2>/dev/null | tr -d '[:space:]')
  case $v in ''|*[!0-9]*) v=0 ;; esac
  echo $((10#$v))
}

case $CMD in
  limit) limit ;;
  judge)
    [ "${#ARGS[@]}" -eq 2 ] || die "judge needs <proof-dir> <rc>"
    DIR=${ARGS[0]} RC=${ARGS[1]}
    case $RC in ''|*[!0-9]*) die "the gate exit status is a number, got: $RC" ;; esac
    if [ "$RC" -eq 0 ]; then echo "grace: not needed: the gate passed"; exit 0; fi
    N=$(limit)
    [ "$N" -gt 0 ] || red "the gate exited $RC and the verify grace is off (policy key verify-grace is 0)"
    # One line per failed script, or one line starting "red:" with the reason.
    out=$(python3 -I - "$DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
failed = []
for k in range(1, 9):
    p = os.path.join(d, "shard-%d.json" % k)
    try:
        with open(p, encoding="utf-8") as fh:
            doc = json.load(fh)
        s = doc["summary"]
        code, counted = int(s.get("exit", 0)), int(s.get("failed", 0))
        bad = [x["path"] for x in doc.get("scripts", []) if int(x.get("exit", 0)) != 0]
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("red: shard %dof8 has no readable result (%s)" % (k, e.__class__.__name__)); sys.exit(0)
    if doc.get("error"):
        print("red: shard %dof8 stopped before it wrote its result: %s" % (k, doc["error"])); sys.exit(0)
    if code != 0 and (counted < 1 or len(bad) != counted):
        print("red: shard %dof8 exited %d but counted %d failed (%d scripts name a failure): a failure no test accounts for" % (k, code, counted, len(bad))); sys.exit(0)
    if code == 0 and (counted or bad):
        print("red: shard %dof8 exited 0 but counted %d failed: its record contradicts itself" % (k, counted)); sys.exit(0)
    failed += bad
for f in sorted(set(failed)):
    print(f)
PY
) || die "cannot read the shard results"
    case $out in red:*) red "${out#red: }" ;; esac
    COUNT=$(printf '%s' "$out" | grep -c .)
    [ "$COUNT" -ge 1 ] || red "the gate exited $RC and no shard counted a failed script"
    [ "$COUNT" -le "$N" ] || red "$COUNT failing test scripts, at most $N allowed: $(printf '%s' "$out" | paste -sd, -)"
    named=''
    while IFS= read -r s; do
      id=$("$ROOT/core/trunk-landing/quarantine.sh" ticket "$s" --project "$PROJECT" --why "graced by the verify: it failed and the verify passed" 2>&1) \
        || red "$s failed and could not be ticketed, so it is not graced: $id"
      named="$named${named:+, }$s (ticket $id)"
    done <<< "$out"
    echo "grace: pass: $COUNT failing test scripts, at most $N allowed: $named"
    ;;
  *) die "unknown command $CMD" ;;
esac
