#!/usr/bin/env bash
# jg-workflow-parse: workflows are configuration. defaults/workflows ships the names, config/workflows in a home adds, changes or removes
# any of them, and any spec of any steps in any order and count parses with `bin/jg-workflow.sh parse`. Each case runs against a scratch
# JG_HOME, so only the shipped file is read unless the case writes config/workflows. Proves: the shipped names parse to their stages; custom
# specs of any shape parse; the owner rule holds for every `--by` and every shape; a critic or fanout with nothing to read is refused; the
# count and step limits name the file line that raises them; the home file wins and `off` removes a shipped name; `define` writes the
# home file atomically and keeps what the owner named; `list` shows every broken line at once.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(cd "$here/.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-workflow-parse-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
WF=$root/bin/jg-workflow.sh
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
has() { case $2 in *"$3"*) echo "ok - $1" ;; *) echo "not ok - $1: [$2] lacks [$3]"; fails=$((fails + 1)) ;; esac; }

# home <name>: a fresh scratch home with an empty config directory.
home() { rm -rf -- "${w:?}/$1"; mkdir -p "$w/$1/config"; printf '%s\n' "$w/$1"; }
# wf <home> <args...>: run the router in that home; out, err and rc hold the result.
wf() {
  local h=$1; shift
  out=$(JG_HOME=$h JG_CONFIG_OVERRIDE="" "$WF" "$@" 2>"$w/err"); rc=$?
  err=$(cat "$w/err")
}
# field <json> <key>: one top-level field of the parse result; the stage count for "stages".
field() { printf '%s' "$1" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=d[sys.argv[1]]; print(len(v) if sys.argv[1]=="stages" else v)' "$2"; }
# refused <label> <home> <spec> [--by x]: exit 2, nothing on stdout, a `refused:` line on stderr.
refused() {
  local label=$1 h=$2; shift 2
  wf "$h" parse "$@"
  is "$label: exit 2" "$rc" 2
  is "$label: stdout empty" "$out" ""
  has "$label: refused line" "$err" "refused:"
}
parses() { local label=$1 h=$2; shift 2; wf "$h" parse "$@"; is "$label: exit 0" "$rc" 0; }

H=$(home h0)

# The router: usage on stderr and exit 2 for an unknown or unsafe subcommand; a later slice adds a subcommand by adding a file.
wf "$H" nosuch; is "router: unknown subcommand exits 2" "$rc" 2
wf "$H" wflib; is "router: wflib is not a subcommand" "$rc" 2
wf "$H" '../x'; is "router: a path is not a subcommand" "$rc" 2
wf "$H" --help; is "router: --help exits 0" "$rc" 0
has "router: --help prints the header" "$out" "jg-workflow.sh"

# T1
wf "$H" parse war-room-blitz
is "T1 exit" "$rc" 0
is "T1 name" "$(field "$out" name)" war-room-blitz
is "T1 spec" "$(field "$out" spec)" "war-room(fast) > owner(plan-approval) > fanout"
is "T1 stages" "$(field "$out" stages)" 3

# T2
wf "$H" parse 'scout*2 > owner > worker*2' --by owner
is "T2 exit" "$rc" 0
is "T2 name" "$(field "$out" name)" custom
is "T2 stages" "$(field "$out" stages)" 3
is "T2 counts" "$(printf '%s' "$out" | python3 -I -c 'import json,sys; print([s[0]["n"] for s in json.load(sys.stdin)["stages"]])')" "[2, 1, 2]"

# T3
for by in main owner; do
  refused "T3 by $by" "$H" 'scout*2 > worker*2' --by "$by"
  has "T3 by $by: the owner rule" "$err" "needs owner(plan-approval) between"
done

# T4
for s in 'worker*31' 'critic > worker' 'worker > critic' 'recon(deep) > fanout' 'recon(huge)' 'bogus' 'deep*2' 'scout + deep' \
  'scout > owner > worker > war-room > fanout'; do
  refused "T4 $s" "$H" "$s"
done
wf "$H" parse 'worker*31'; has "T4 count limit names its file line" "$err" "limit count"
wf "$H" parse 'scout > owner > worker > war-room > fanout'; has "T4 each build after a report needs its own yes" "$err" "a fanout after a Recon"

# T5
wf "$H" parse deep-slices; is "T5 deep-slices" "$(field "$out" spec)" "recon(deep) > critic > owner(plan-approval) > fanout"
wf "$H" parse scout-worker; is "T5 scout-worker" "$(field "$out" spec)" "recon(quick) > owner(plan-approval) > worker"
wf "$H" parse worker; is "T5 worker name" "$(field "$out" name)" worker; is "T5 worker spec" "$(field "$out" spec)" worker

# T6
refused "T6 goal" "$H" goal
has "T6 names the Goal script" "$err" "bin/jg-goal.sh"

# T7
wf "$H" parse ' scout >owner> worker '; a=$(field "$out" sha)
wf "$H" parse 'scout > owner > worker'; b=$(field "$out" sha)
is "T7 same sha" "$a" "$b"
is "T7 sha is 12 hex" "$(printf '%s' "$a" | grep -cE '^[0-9a-f]{12}$')" 1

# T8: any order and any count
for s in 'worker > scout > owner > worker > war-room > owner > fanout' 'war-room + scout*3 > owner > fanout + worker*2' \
  'worker*20 + scout*10' 'scout + worker' 'recon(deep)*2 > critic > owner > fanout' 'owner'; do
  parses "T8 $s" "$H" "$s"
done
wf "$H" parse 'recon(deep)*2 > critic > owner > fanout'
is "T8 the critic takes the count of the deep Recons" "$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["spec"])')" \
  "recon(deep)*2 > critic*2 > owner(plan-approval) > fanout"
wf "$H" parse 'scout > owner > worker' --text
is "T8 --text prints one line a stage" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 3
refused "T8 more steps than the limit" "$H" 'worker*30 + scout*30 + scout*30'
has "T8 the steps limit names its line" "$err" "limit"

# T9: the home file wins
H=$(home h9)
printf 'pair: scout*2 > owner > worker*2\nscout-worker: off\nlimit count: 40\n' > "$H/config/workflows"
wf "$H" parse pair; is "T9 pair name" "$(field "$out" name)" pair
refused "T9 off removes a shipped name" "$H" scout-worker
has "T9 unknown" "$err" "unknown"
parses "T9 the raised count limit" "$H" 'worker*40'
parses "T9 a home name inside a spec" "$H" 'pair > war-room > owner > fanout'
H=$(home h9b)
refused "T9 no home file: the shipped count limit" "$H" 'worker*40'
has "T9 the limit is named" "$err" "limit count"

# A line that breaks the rules is refused with its file and line.
H=$(home h9c)
printf '# note\nworker: scout\n' > "$H/config/workflows"
wf "$H" parse scout; is "T9 a kind is not a name: exit 2" "$rc" 2
has "T9 refusal names the file line" "$err" "refused: $H/config/workflows:2:"

# T10: define
H=$(home h10); rm -f "$H/config/workflows"
wf "$H" define two-scouts 'scout*2 > owner > worker' --by main
is "T10 define exit" "$rc" 0
has "T10 define prints the canonical spec" "$out" "defined two-scouts: recon(quick)*2 > owner(plan-approval) > worker"
has "T10 the file has the header" "$(sed -n 1,2p "$H/config/workflows")" "defaults/workflows"
is "T10 the line is written" "$(grep -c '^two-scouts: ' "$H/config/workflows")" 1
parses "T10 the defined name parses" "$H" two-scouts
wf "$H" define two-scouts 'scout > owner > worker' --by main
is "T10 main may not change a name" "$rc" 2
wf "$H" define two-scouts 'scout > owner > worker*3' --by owner
is "T10 the owner replaces the line" "$rc" 0
is "T10 replaced in place, not appended" "$(grep -c '^two-scouts: ' "$H/config/workflows")" 1
cp "$H/config/workflows" "$w/before"
wf "$H" define x 'scout > worker' --by owner
is "T10 owner rule: exit 2" "$rc" 2
has "T10 owner rule: named" "$err" "owner rule"
cmp -s "$w/before" "$H/config/workflows"; is "T10 a refusal changes nothing" "$?" 0
wf "$H" define loop 'loop > worker' --by owner
is "T10 a name that reaches itself is refused" "$rc" 2
has "T10 names itself" "$err" "names itself"
wf "$H" define worker worker --by owner
is "T10 a kind is not a name" "$rc" 2
wf "$H" define two-scouts off --by main
is "T10 main may not remove a name" "$rc" 2
wf "$H" define two-scouts off --by owner
has "T10 remove prints" "$out" "removed two-scouts"
refused "T10 the removed name is unknown" "$H" two-scouts
cmp -s "$w/before" "$H/config/workflows"; is "T10 the file changed on removal" "$?" 1
left=0; for f in "$H"/config/.workflows.*; do [ ! -e "$f" ] || left=1; done
is "T10 no temp file is left" "$left" 0

# T11: list
H=$(home h11)
printf 'pair: scout*2 > owner > worker*2\nscout-worker: off\nlimit count: 40\n' > "$H/config/workflows"
wf "$H" list
is "T11 exit" "$rc" 0
has "T11 home line" "$out" "pair"$'\t'"recon(quick)*2 > owner(plan-approval) > worker*2"$'\t'"home"
is "T11 no scout-worker line" "$(printf '%s\n' "$out" | grep -c '^scout-worker')" 0
is "T11 every other shipped name" "$(printf '%s\n' "$out" | grep -c $'\tshipped$')" 7
printf 'bad: bogus\n' >> "$H/config/workflows"
wf "$H" list
is "T11 a broken line: exit 2" "$rc" 2
has "T11 a broken line is printed" "$out" "bad"$'\t'"refused:"
has "T11 the other lines still print" "$out" "pair"
wf "$H" parse pair; is "T11 parse pair still works" "$rc" 0
H=$(home h11b)
wf "$H" list
is "T11 shipped names with no home file" "$(printf '%s\n' "$out" | grep -c $'\tshipped$')" 8

# Routes: a kind's route reads the home file first, then the shipped one.
H=$(home h12)
printf 'worker codex gpt-5 low\n' > "$H/config/workflow-routes"
route() { JG_HOME=$H JG_CONFIG_OVERRIDE="" JG_WORKFLOW_ROOT=$root JG_WORKFLOW_CONFIG=$H/config python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1]+"/core/workflows"); import wflib; print(*wflib.route(sys.argv[2], sys.argv[3] or None))' "$root" "$1" "${2:-}"; }
is "route: the home file wins" "$(route worker)" "codex gpt-5 low"
is "route: recon(quick) reads recon-quick" "$(route recon quick)" "claude claude-sonnet-5-5 medium"
is "route: the shipped route" "$(route critic)" "claude claude-opus-5-5 high"

[ "$fails" -eq 0 ] || { echo "$fails case(s) failed" >&2; exit 1; }
echo "all cases passed"
