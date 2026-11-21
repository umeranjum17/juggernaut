#!/usr/bin/env bash
# policy.py --import --fill-missing: version 1 for a registry project with no row, never touching an existing row; a second run
# fills nothing; the plain --import refusal is unchanged; jg-project-mode.sh resolves a filled local-trunk project.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
POLICY=$HERE/../adapters/policy.py
ROOT=$(cd "$HERE/../../.." && pwd -P)
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
H=$d/main
mkdir -p "$H/data" "$H/state"
printf -- '- alpha [direct-PR]\n' > "$H/data/projects.md"
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
pol() { JG_HOME="$H" python3 -I "$POLICY" "$@" 2>&1; }
db() { sqlite3 "$H/state/item-store/fleet.db" "$1"; }

pol --import >/dev/null || bad first-import "refused"
printf -- '- alpha [no-mistakes +yolo]\n- beta [local-trunk]\n- gamma [no-mistakes +yolo]\n' > "$H/data/projects.md"
rows() { db "SELECT * FROM policy WHERE project='alpha'"; }
before=$(rows)

out=$(pol --import --fill-missing); rc=$?
[ "$rc" -eq 0 ] && ok fill-exit || bad fill-exit "exit $rc: $out"
case $out in *"filled beta"*"filled gamma"*"filled 2 project(s)"*) ok fill-prints ;; *) bad fill-prints "[$out]" ;; esac
[ "$(db 'SELECT project, version, level, mode, set_by FROM policy ORDER BY 1, 2' | tr '\n' ' ')" = "alpha|1|tight|direct-PR|owner:registry beta|1|standard|local-trunk|owner:registry gamma|1|loose|direct-PR|owner:registry " ] \
  && ok only-new-rows-v1 || bad only-new-rows-v1 "[$(db 'SELECT project, version, level, mode FROM policy ORDER BY 1, 2')]"
[ "$(rows)" = "$before" ] && ok existing-row-identical || bad existing-row-identical "[$(rows)] vs [$before]"

out=$(pol --import --fill-missing); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "nothing to fill" ] && [ "$(db 'SELECT count(*) FROM policy')" = 3 ] && ok second-run-fills-nothing || bad second-run-fills-nothing "exit $rc [$out]"

out=$(pol --import); rc=$?
[ "$rc" -eq 1 ] && case $out in "refused: the cut-over import already ran"*) true ;; *) false ;; esac && ok plain-import-still-refuses || bad plain-import-still-refuses "exit $rc [$out]"

[ "$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" beta 2>/dev/null)" = "local-trunk off" ] && ok mode-resolves-local-trunk || bad mode-resolves-local-trunk "[$(JG_HOME=$H "$ROOT/bin/jg-project-mode.sh" beta 2>&1)]"
pol --fill-missing >/dev/null; [ $? -eq 2 ] && ok needs-import || bad needs-import "no usage exit"

# the filled rows are in the cut-over log the stamp check reads
case $(JG_HOME=$H python3 -I "$HERE/../logs/owner-registry") in *"import:projects.md:beta	policy:beta"*"import:projects.md:gamma	policy:gamma"*) ok log-has-filled-pairs ;; *) bad log-has-filled-pairs "[$(JG_HOME=$H python3 -I "$HERE/../logs/owner-registry")]" ;; esac

# the schema clause: a later registry row is refused for a project that has a row, and for a source that is not the import's
reg() { JG_HOME="$H" python3 -I - "$@" <<'PY' 2>&1
import os, sys
sys.path.insert(0, os.path.join(os.environ["POLICY_DIR"], ".."))
import itemdb, store as S
st = itemdb.open_db(os.environ["JG_HOME"], "owner:registry")
at = itemdb.stamp(st)
try:
    print("wrote v%d" % st.set_policy(at + 5, sys.argv[1], "tight", "owner:registry", sys.argv[2], mode="direct-PR"))
except S.Refused as e:
    print("refused: %s" % e)
PY
}
export POLICY_DIR=$HERE/../adapters
case $(reg alpha import:projects.md:alpha) in refused:*) ok existing-project-refused ;; *) bad existing-project-refused "$(reg alpha import:projects.md:alpha)" ;; esac
case $(reg newp other:source) in refused:*) ok wrong-source-refused ;; *) bad wrong-source-refused "$(reg newp other:source)" ;; esac
case $(reg newp import:projects.md:newp) in "wrote v1") ok new-project-filled ;; *) bad new-project-filled "$(reg newp import:projects.md:newp)" ;; esac

# a live store made by the older schema gets the new clause at open; a store with any other trigger text keeps it (the audit finds it)
live() { # $1 = home, $2 = 1 to tamper the trigger text before the open
  mkdir -p "$1/data" "$1/state/item-store"
  TAMPER=$2 HOME_DIR=$1 python3 -I - "$HERE/.." <<'PY'
import os, re, sys
sys.path.insert(0, sys.argv[1])
import itemdb, store as S
schema = open(os.path.join(sys.argv[1], "schema.sql"), encoding="utf-8").read()
i = schema.index("  -- The cut-over run writes every registry row at one stamp.")
j = schema.index("  SELECT RAISE(ABORT, 'policy: the next version", i)
OLD = """  -- The cut-over run writes every registry row at one stamp. After it, a new project has no row (its lanes go to an
  -- intake item) until his answer to a policy question writes version 1.
  SELECT RAISE(ABORT, 'policy: the registry import writes version 1 only, in the one cut-over run; later, his answer to a policy question writes it')
    WHERE NEW.set_by = 'owner:registry'
      AND (NEW.version <> 1 OR EXISTS (SELECT 1 FROM policy WHERE set_by = 'owner:registry' AND set_at <> NEW.set_at));
"""
old = schema[:i] + OLD + schema[j:]
if os.environ["TAMPER"] == "1":
    old = old.replace("> 300;", "> 301;", 1)
home = os.environ["HOME_DIR"]
f = os.path.join(home, "state", "item-store", "old-schema.sql")
open(f, "w", encoding="utf-8").write(old)
S.Store(os.path.join(home, "state", "item-store", "fleet.db"), schema=f).con.close()
st = itemdb.open_db(home, "owner:registry")
print("same" if st.schema_hash() == st.shipped else "differs")
PY
}
[ "$(live "$d/old" 0)" = same ] && ok old-store-reloaded || bad old-store-reloaded "[$(live "$d/old2" 0)]"
[ "$(live "$d/tamper" 1)" = differs ] && ok other-trigger-text-kept || bad other-trigger-text-kept "[$(live "$d/tamper2" 1)]"
exit "$fail"
