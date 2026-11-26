#!/usr/bin/env bash
# The reviewed list of public operations (core/agent-cli/operations.tsv) and the tool that finds drift from it.
# Usage: bash core/agent-cli/tests/inventory.test.sh
#
# Proves, on the real tree and on planted ones:
#   1. coverage is the same with or without private logs: check.py prints the same lines with an empty and a filled usage file;
#   2. the list is whole: one owner per operation, a unique path, GET exactly when the operation changes nothing;
#   3. the hand-written cases (inventory/cases.tsv) are found with their class and never with the wrong effect, and
#      `reconcile list` is a read and `reconcile close` a change, on two paths;
#   4. a planted script with `Usage: x.sh start` and a `start)` arm is found, a header word that is no operation is not,
#      a read that writes a file is a change, and a usage count never makes a script public;
#   5. drift is printed both ways and never written into the list;
#   6. simultaneous parser runs sharing a scratch parent complete and clean up only their own fixtures.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
INV=$ROOT/core/agent-cli/inventory
LIST=$ROOT/core/agent-cli/operations.tsv
d=$(mktemp -d "${TMPDIR:-/tmp}/inventory.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
has() { case $2 in *"$3"*) ;; *) fail "$1: want [$3] in [$2]" ;; esac; }
lacks() { case $2 in *"$3"*) fail "$1: did not want [$3] in [$2]" ;; esac; }
py() { python3 -I "$@"; }

for f in operations.tsv inventory/extract.py inventory/check.py inventory/cases.tsv inventory/parse.py inventory/README.md; do
  [ -s "$ROOT/core/agent-cli/$f" ] || fail "core/agent-cli/$f is missing"
done

# --- 1. coverage never reads private logs
for f in "$ROOT"/bin/jg-*.sh; do printf '9\tx\ty\t%s\n' "${f##*/}"; done > "$d/usage-filled"
: > "$d/usage-empty"
py "$INV/check.py" --usage "$d/usage-empty" > "$d/check-empty" || fail "check.py failed with an empty usage file: $(cat "$d/check-empty")"
py "$INV/check.py" --usage "$d/usage-filled" > "$d/check-filled" || fail "check.py failed with a filled usage file"
cmp -s "$d/check-empty" "$d/check-filled" || fail "usage counts changed what check.py prints: $(diff "$d/check-empty" "$d/check-filled" | head -5)"
has "check.py output" "$(cat "$d/check-empty")" 'operations checked (the reviewed list): '
has "check.py output" "$(cat "$d/check-empty")" 'list integrity problems: 0'
pass "check.py prints the same lines with an empty usage file and with a filled one"

# --- 2. the list is whole (read straight from the file, not through check.py)
awk -F'\t' 'NR == 1 { next } { n++; if ($7 == "") bad++; if (seen[$4]++) dup++; if (($5 == "GET") != ($6 == "no")) meth++ }
  END { exit !(n > 600 && !bad && !dup && !meth) }' "$LIST" || fail "operations.tsv: an operation with no owner, a repeated path, or a method that disagrees with changes"
[ "$(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' "$LIST" | sort | uniq -d | wc -l)" = 0 ] || fail "operations.tsv repeats an operation"
pass "every operation has one owner and one unique path, and GET exactly when it changes nothing"

# --- 3. the hand-written cases, and two paths for one script's read and change
py "$INV/extract.py" "$ROOT" "$d/found.tsv" --cases "$INV/cases.tsv" > "$d/cases.out" || fail "a case is missing or served with the wrong effect: $(grep -E '^(MISSING|WRONG)' "$d/cases.out")"
for want in 'jg-war-room.sh	start' 'jg-war-room.sh	next' 'jg-war-room.sh	approve' 'jg-swarm.sh	start' 'jg-control.sh	interrupt' \
  'jg-control.sh	exit' 'jg-control.sh	relaunch' 'jg-control.sh	primary relaunch' 'jg-check-register.sh	-'; do
  grep -q "^ok	$want	public/change" "$d/cases.out" || fail "case [$want] is not found as a public change: $(grep -F "$want" "$d/cases.out")"
done
read_row=$(awk -F'\t' '$1 == "jg-captain-hold.sh" && $2 == "reconcile list" { print $4 "|" $5 "|" $6 }' "$LIST")
change_row=$(awk -F'\t' '$1 == "jg-captain-hold.sh" && $2 == "reconcile close" { print $4 "|" $5 "|" $6 }' "$LIST")
[ "${read_row#*|}" = "GET|no" ] || fail "reconcile list should be a read, got [$read_row]"
[ "${change_row#*|}" = "POST|yes" ] || fail "reconcile close should be a change, got [$change_row]"
[ "${read_row%%|*}" != "${change_row%%|*}" ] || fail "reconcile list and reconcile close share a path"
grep -q "^jg-captain-hold.sh	reconcile list	.*	read	" "$d/found.tsv" || fail "the extractor does not find reconcile list as a read"
grep -q "^jg-captain-hold.sh	reconcile close	.*	change	" "$d/found.tsv" || fail "the extractor does not find reconcile close as a change"
pass "the cases are found with their class and effect; reconcile list is a read and reconcile close a change, on two paths"

# A migrated skill can call the public command without mentioning its backing script.
swarm=$d/swarm
mkdir -p "$swarm/bin" "$swarm/core/agent-cli/contract"
cp "$ROOT/bin/jg-swarm.sh" "$swarm/bin/"
cp "$ROOT/core/agent-cli/contract/muster-gates.json" "$swarm/core/agent-cli/contract/"
printf 'Run jg plan blitz start to start the plan.\n' > "$swarm/AGENTS.md"
awk -F'\t' '$1 == "jg-swarm.sh" && $2 == "start"' "$INV/cases.tsv" > "$swarm/cases.tsv"
py "$INV/extract.py" "$swarm" "$swarm/found.tsv" --cases "$swarm/cases.tsv" > "$swarm/out" \
  || fail "swarm start disappeared from public inventory: $(cat "$swarm/out")"
grep -q $'^ok\tjg-swarm.sh\tstart\tpublic/change' "$swarm/out" || fail "swarm start case did not run"
pass "swarm start stays public when the skill uses its contract path"

# --- 4. planted scripts
P=$d/planted
mkdir -p "$P/bin"
printf 'Scripts: bin/x.sh, bin/y.sh, bin/jg-quiet.sh.\n' > "$P/AGENTS.md"
cat > "$P/bin/x.sh" <<'SH'
#!/usr/bin/env bash
# Usage: x.sh start
#   x.sh stop
# Pairs x.sh with its stub for the plan.
case "${1:-}" in
  start) mkdir -p "$D/started" ;;
  stop) rm -rf "$D/started" ;;
esac
SH
cat > "$P/bin/y.sh" <<'SH'
#!/usr/bin/env bash
# Usage: y.sh show
#        y.sh list
case "${1:-}" in
  show) echo "seen" > "$OUT" ;;
  list) echo "listed" ;;
esac
SH
cat > "$P/bin/jg-quiet.sh" <<'SH'
#!/usr/bin/env bash
# Usage: jg-quiet.sh
echo quiet
SH
printf '# planted cases\nx.sh\tstart\tpublic\tchange\ny.sh\tshow\tpublic\tchange\ny.sh\tlist\tpublic\tread\n' > "$P/cases.tsv"
py "$INV/extract.py" "$P" "$P/found.tsv" --cases "$P/cases.tsv" > "$P/out" || fail "a planted case failed: $(cat "$P/out")"
grep -q '^x.sh	start	' "$P/found.tsv" || fail "a planted script with 'Usage: x.sh start' and a start) arm was not found"
grep -q '^x.sh	stop	' "$P/found.tsv" || fail "the planted stop arm was not found"
if grep -q '^x.sh	with	' "$P/found.tsv"; then fail "a header word that is no operation (with) was found"; fi
grep -q "^y.sh	show	.*	change	" "$P/found.tsv" || fail "a planted read that writes a file was not classed a change"
grep -q "^y.sh	list	.*	read	" "$P/found.tsv" || fail "a planted read that writes nothing was not classed a read"
printf 'y.sh\tshow\tpublic\tread\n' > "$P/wrong.tsv"
if py "$INV/extract.py" "$P" "$P/found2.tsv" --cases "$P/wrong.tsv" > "$P/wrong.out"; then fail "a read that writes a file was accepted as a read"; fi
has "wrong-effect case" "$(cat "$P/wrong.out")" 'WRONG	y.sh	show'
printf 'x.sh\tnever\tpublic\tchange\n' > "$P/missing.tsv"
if py "$INV/extract.py" "$P" "$P/found3.tsv" --cases "$P/missing.tsv" > "$P/missing.out"; then fail "a case the tree lacks was accepted"; fi
has "missing case" "$(cat "$P/missing.out")" 'MISSING	x.sh	never'
printf '4\tx\ty\tjg-quiet.sh\n' > "$P/usage"
py "$INV/extract.py" "$P" "$P/found4.tsv" --usage "$P/usage" > /dev/null
[ "$(awk -F'\t' '$1 == "jg-quiet.sh" { print $12 }' "$P/found4.tsv")" = public ] || fail "a script an instruction names should be public"
printf '#!/usr/bin/env bash\n# Usage: jg-hidden.sh\necho hidden\n' > "$P/bin/jg-hidden.sh"
printf '8\tx\ty\tjg-hidden.sh\n' > "$P/usage2"
py "$INV/extract.py" "$P" "$P/found5.tsv" --usage "$P/usage2" > /dev/null
[ "$(awk -F'\t' '$1 == "jg-hidden.sh" { print $12 }' "$P/found5.tsv")" != public ] || fail "a usage count made a script public"
[ "$(awk -F'\t' '$1 == "jg-hidden.sh" { print $11 }' "$P/found5.tsv")" = 8 ] || fail "the usage count should still fill the discovery column"
pass "planted scripts: a start arm is found, a prose word is not, a read that writes is a change, a usage count never makes a script public"

# --- 5. drift both ways, printed and never written into the list
printf 'script\toperation\tform\tpath\tmethod\tchanges\towner\taliases\treview\tarea\tsource\tnote\n' > "$P/list.tsv"
printf 'x.sh\tstart\tbin/x.sh start\tplan x start\tPOST\tyes\te9\t-\tconfirmed\tplanning\thelp\tform=usage\n' >> "$P/list.tsv"
printf 'gone.sh\trun\tbin/gone.sh run\tplan gone run\tPOST\tyes\te9\t-\tconfirmed\tplanning\thelp\tform=usage\n' >> "$P/list.tsv"
cp "$P/list.tsv" "$P/list.before"
py "$INV/check.py" "$P/list.tsv" --tree "$P" > "$P/drift.out" || fail "drift alone must not fail check.py: $(cat "$P/drift.out")"
has "forward drift" "$(cat "$P/drift.out")" 'drift+ x.sh stop'
has "forward drift" "$(cat "$P/drift.out")" 'drift+ y.sh show'
has "reverse drift" "$(cat "$P/drift.out")" 'drift- gone.sh run (script gone)'
lacks "listed operation" "$(cat "$P/drift.out")" 'drift+ x.sh start'
cmp -s "$P/list.tsv" "$P/list.before" || fail "check.py wrote into the list"
if py "$INV/check.py" "$P/list.tsv" --tree "$P" --strict > /dev/null; then fail "--strict should exit 1 on drift"; fi
printf 'x.sh\tstop\tbin/x.sh stop\tplan x start\tPOST\tyes\te9\t-\tconfirmed\tplanning\thelp\tform=usage\n' >> "$P/list.tsv"
printf 'y.sh\tlist\tbin/y.sh list\tplan y list\tGET\tyes\t\t-\tconfirmed\tplanning\thelp\tform=usage\n' >> "$P/list.tsv"
if py "$INV/check.py" "$P/list.tsv" --tree "$P" > "$P/bad.out"; then fail "a repeated path, a missing owner and a method that disagrees with changes must fail check.py"; fi
has "integrity" "$(cat "$P/bad.out")" 'path used 2 times'
has "integrity" "$(cat "$P/bad.out")" 'no owner'
has "integrity" "$(cat "$P/bad.out")" 'method GET with changes=yes'
pass "drift is printed both ways and never written into the list; a broken list fails"

# --- 6. both parser invocations start before either is waited on
scratch=$d/parser-scratch
mkdir "$scratch" || fail "cannot create the shared scratch parent"
printf 'keep\n' > "$scratch/keep"
py "$INV/parse.py" usage "$ROOT" "$LIST" "$scratch" --only jg-control.sh --jobs 1 > "$d/parse-a.out" 2>&1 &
first_pid=$!
py "$INV/parse.py" usage "$ROOT" "$LIST" "$scratch" --only jg-control.sh --jobs 1 > "$d/parse-b.out" 2>&1 &
second_pid=$!
first_rc=0 second_rc=0
wait "$first_pid" || first_rc=$?
wait "$second_pid" || second_rc=$?
[ "$first_rc" = 0 ] && [ "$second_rc" = 0 ] ||
  fail "concurrent parser runs exited $first_rc and $second_rc: $(cat "$d/parse-a.out" "$d/parse-b.out")"
for log in "$d/parse-a.out" "$d/parse-b.out"; do
  grep -q $'^form\t[^\t]*\tjg-control.sh interrupt\t' "$log" || fail "parser run did not check the interrupt form: $(cat "$log")"
done
[ "$(find "$scratch" -mindepth 1 -maxdepth 1 -print)" = "$scratch/keep" ] ||
  fail "parser runs removed the caller's file or left scratch behind"
[ "$(cat "$scratch/keep")" = keep ] || fail "parser runs changed the caller's file"
pass "two parser runs share a scratch parent without disturbing each other or leaving fixtures behind"
echo "inventory.test.sh: all checks passed"
