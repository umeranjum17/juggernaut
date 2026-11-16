#!/usr/bin/env bash
# Integration: the interval evaluator and the actual backlog close of a labelled fix.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot jg-closure-gate)
P=$T/proof.json
python3 - "$P" <<'PY'
import json, sys, time
now = int(time.time()); t = now - 90000; d = 86400
proof = {'ticket': 'jg-fix', 'as_of': now, 'homes': ['p'], 'installed_at': t, 'patch_identity': True, 'reverted': False,
         'coverage': {s: {'p': [t-d, now]} for s in ('installs','arrivals','stalls')}, 'stalls': [],
         'arrivals': [{'home':'p', 'at':t-d+100, 'installed_at':t-d+110}, {'home':'p', 'at':t+100, 'installed_at':t+105}]}
with open(sys.argv[1], 'w') as f: json.dump(proof, f)
PY
python3 "$ROOT/bin/jg-closure-gate.py" "$P" jg-fix | grep -q CLOSED || fail 'complete proof refused'
python3 - "$P" <<'PY'
import json,sys
p=sys.argv[1]; x=json.load(open(p)); x['installed_at']=x['as_of']-5; json.dump(x,open(p,'w'))
PY
if python3 "$ROOT/bin/jg-closure-gate.py" "$P" jg-fix >"$T/out" 2>&1; then fail 'early proof accepted'; fi
grep -q '24-hour' "$T/out" || fail 'early refusal missing reason'
python3 - "$P" <<'PY'
import json,sys,time
p=sys.argv[1]; x=json.load(open(p)); t=x['as_of']-86400; x['installed_at']=t
x['arrivals']=[{'home':'p','at':t-500,'installed_at':t-491.5}] + [{'home':'p','at':t+100,'installed_at':t+100+v} for v in range(1,10)] + [{'home':'p','at':x['as_of']-0.5,'installed_at':None}]
json.dump(x,open(p,'w'))
PY
if python3 "$ROOT/bin/jg-closure-gate.py" "$P" jg-fix >"$T/out" 2>&1; then fail 'open interval accepted'; fi
grep -q 'unresolved\|worse' "$T/out" || fail 'interval refusal missing reason'
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then fail 'real Beads binaries are required'; fi
H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/user" "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
: > "$H/config/backlog-intake-loose"
"$ROOT/bin/jg-beads.sh" init --prefix jg >"$T/init" 2>&1 || fail "store init: $(cat "$T/init")"
tasks() { env HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$ROOT/bin/jg-backlog.sh" "$@"; }
tasks add jg-fix -l bottleneck-fix 'Fix delivery flow' --body why >/dev/null
if tasks "done" jg-fix >"$T/out" 2>&1; then fail 'missing source accepted'; fi
grep -q 'trunk-stalls.tsv' "$T/out" || fail "missing stall source not named: $(cat "$T/out")"
# Producer to close: a real project clone, the landing, installation and stall records, and the real close of a labelled ticket.
P=$H/projects/proj
mkdir -p "$P"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$P" init -q -b trunk
mkc() { echo "$1" > "$P/$1"; git -C "$P" add "$1"; git -C "$P" commit -q -m "$1"; git -C "$P" rev-parse HEAD; }
BASE=$(mkc base); B1=$(mkc b1); FIX=$(mkc fix); A1=$(mkc a1); A2=$(mkc a2); EARLY=$(mkc early)
now=$(date +%s); t=$((now - 90000)); day=86400
for f in trunk-landing-proofs trunk-releases trunk-versions trunk-publications trunk-gated trunk-words; do : > "$H/data/$f.tsv"; done
{
  printf 'jg-base\tproj\t%s\t%s\tfull\n' "$BASE" $((t - day - 50))
  printf 'jg-b1\tproj\t%s\t%s\tfull\n' "$B1" $((t - day + 100))
  printf 'jg-fix\tproj\t%s\t%s\tfull\n' "$FIX" $((t - 1000))
  printf 'jg-a1\tproj\t%s\t%s\tfull\n' "$A1" $((t + 100))
  printf 'jg-a2\tproj\t%s\t%s\tfull\n' "$A2" $((t + 1000))
  printf 'jg-early\tproj\t%s\t%s\tfull\n' "$EARLY" $((now - 5))
} > "$H/data/trunk-landings.tsv"
{
  printf 'proj\t%s\t%s\tlive\n' "$BASE" $((t - day - 100))
  printf 'proj\t%s\t%s\tlive\n' "$B1" $((t - day + 4000))
  printf 'proj\t%s\t%s\tlive\n' "$FIX" "$t"
  printf 'proj\t%s\t%s\tlive\n' "$A1" $((t + 200))
  printf 'proj\t%s\t%s\tlive\n' "$A2" $((t + 1100))
  printf 'proj\t%s\t%s\tlive\n' "$EARLY" $((now - 5))
} > "$H/data/trunk-in-use.tsv"
printf 'proj\tproj\t%s\t%s\nproj\tproj\t%s\t%s\n' $((t - day - 500)) $((t - day - 400)) $((now - 10)) $((now - 2)) > "$H/data/trunk-stalls.tsv"
tasks add jg-early -l bottleneck-fix 'Recent fix' --body why >/dev/null
if tasks "done" jg-early >"$T/out" 2>&1; then fail 'closure inside its 24 hours accepted'; fi
grep -q '24-hour' "$T/out" || fail "early closure reason missing: $(cat "$T/out")"
# A slower after-window arrival makes the p90 worse in both views: refused through the same real close.
SLOW=$(mkc slow)
cp "$H/data/trunk-landings.tsv" "$T/landings.keep"; cp "$H/data/trunk-in-use.tsv" "$T/inuse.keep"
printf 'jg-slow\tproj\t%s\t%s\tfull\n' "$SLOW" $((t + 500)) >> "$H/data/trunk-landings.tsv"
printf 'proj\t%s\t%s\tlive\n' "$SLOW" $((now - 6)) >> "$H/data/trunk-in-use.tsv"
if tasks "done" jg-fix >"$T/out" 2>&1; then fail 'worse interval accepted'; fi
grep -q 'worse' "$T/out" || fail "worse interval reason missing: $(cat "$T/out")"
cp "$T/landings.keep" "$H/data/trunk-landings.tsv"; cp "$T/inuse.keep" "$H/data/trunk-in-use.tsv"
tasks "done" jg-fix >"$T/out" 2>&1 || fail "complete producer record refused: $(cat "$T/out")"
grep -q 'CLOSED' "$T/out" || fail "no closed line: $(cat "$T/out")"
[ "$(tasks show jg-fix --full | sed -n 's/^  state: //p' | head -1)" = "done" ] || fail 'labelled ticket not closed'
tasks add jg-plain 'Plain ticket' --body why >/dev/null
JG_HOME="$H" JG_DATA_OVERRIDE="$H/data" bash -c '. "$1"; jg_backlog_beads_serve "$2" done jg-plain' _ "$ROOT/bin/jg-backlog-lib.sh" "$H/config" || fail 'ordinary internal close refused'
pass 'closure gate: complete, early, interval, missing source and ordinary close'
