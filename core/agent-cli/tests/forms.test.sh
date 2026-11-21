#!/usr/bin/env bash
# The forms of the reviewed list of public operations, run through the real parsers.
# Usage: bash core/agent-cli/tests/forms.test.sh
#
# Every form is rendered with fixture values and run on a throwaway home with argument-recording stand-ins on PATH
# (inventory/parse.py). Proves:
#   1. every row whose note says form=usage parses: a usage error or an unknown verb fails the row;
#   2. the older shape of every positional row (operation words first) is refused by the parser, with the parser's words;
#   3. `jg-control.sh <task> interrupt|exit|relaunch` reaches the task, with the tmux stand-in of tests/jg-control.test.sh;
#   4. every GET row runs on a fixture with data (an answered and an open hold) and changes no file and calls nothing outside;
#   5. a GET-shaped read listed POST is a parity failure; help-only rows are listed and never served as GET;
#   6. a usage line continued on indented lines keeps every continued group, and each optional --option group is parsed
#      absent and present, `--effort bogus` getting the parser's list of allowed values;
#   7. every --option a form names is in the code of its script.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
INV=$ROOT/core/agent-cli/inventory
LIST=$ROOT/core/agent-cli/operations.tsv
d=$(mktemp -d "${TMPDIR:-/tmp}/forms.XXXXXX") || exit 1
chmod 700 "$d"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
has() { case $2 in *"$3"*) ;; *) fail "$1: want [$3] in [$2]" ;; esac; }
lacks() { case $2 in *"$3"*) fail "$1: did not want [$3] in [$2]" ;; esac; }
py() { python3 -I "$@"; }
# a run may leave a read-only folder (a hook install): make the tree removable first
cleanup() { chmod -R u+rwX -- "$d" 2>/dev/null; rm -rf -- "$d"; }
trap cleanup EXIT
for f in operations.tsv inventory/parse.py inventory/extract.py; do
  [ -s "$ROOT/core/agent-cli/$f" ] || fail "core/agent-cli/$f is missing"
done
parse() { py "$INV/parse.py" "$1" "$ROOT" "$LIST" "$d/lab-$1" --known "$d/known.tsv" "${@:2}"; }

# Rows the list is known to get wrong, found by this check. A row listed here that fails is reported `known-defect`; one that
# stops failing is stale and fails the test, so the ledger shrinks as the list is corrected.
#   mode	script	operation	what is wrong
cat > "$d/known.tsv" <<'LEDGER'
get	jg-peek.sh	-	listed GET, but its run writes state/.guard-watcher-stale-banner and calls tmux
LEDGER

# --- 1 + 2 + 4 + 7: the whole list, one run per mode
parse usage > "$d/usage.out" 2> "$d/usage.err" || fail "a listed form does not parse: $(grep -P '\tparse-error\t' "$d/usage.out" | cut -c1-240) $(tail -3 "$d/usage.err")"
want=$(awk -F'\t' 'NR > 1 && $12 ~ /form=usage/ { n++ } END { print n }' "$LIST")
got=$(grep -c -P '^form\t(?!help-only|STALE)' "$d/usage.out")
[ "$got" = "$want" ] || fail "want one line per form=usage row ($want), got $got"
helponly=$(awk -F'\t' 'NR > 1 && $12 !~ /form=usage/ { n++ } END { print n }' "$LIST")
[ "$(grep -c -P '^form\thelp-only\t' "$d/usage.out")" = "$helponly" ] || fail "every help-only row should be listed for its owning order"
pass "$want rows with a usage form parse through the real scripts; $helponly help-only rows are listed, never run"

parse shapes > "$d/shapes.out" || fail "a positional row does not parse, or its older shape was accepted: $(grep -P '\t(parse-error|ACCEPTED)\t' "$d/shapes.out" | cut -c1-240)"
has "older shape" "$(grep -P '^shape\trejected\tjg-control.sh interrupt older' "$d/shapes.out")" "is not a control verb"
has "older shape" "$(grep -P '^shape\trejected\tjg-wait-write.sh open pause older' "$d/shapes.out" || grep -P '^shape\trejected\tjg-wait-write.sh open older' "$d/shapes.out")" "unknown wait kind"
has "older shape" "$(grep -P '^shape\trejected\tjg-pr-wait.sh set older' "$d/shapes.out")" "unknown verb"
has "older shape" "$(grep -P '^shape\trejected\tjg-release-readiness.sh show older' "$d/shapes.out")" "no home at show"
positional=$(grep -c -P '^shape\t[a-z-]+\t.* form\t' "$d/shapes.out")
[ "$positional" -ge 10 ] || fail "want one line per positional row, got $positional"
pass "$positional positional rows parse in the listed shape; the older shape is refused with the parser's own words"

parse names > "$d/names.out" || fail "a form names an option its script does not have: $(grep -P '^name\tabsent' "$d/names.out" | head -3)"
pass "every --option a form names is in the code of its script"

# --- 3: jg-control reaches the task with the stand-in of tests/jg-control.test.sh
# shellcheck disable=SC2016
sed -n '1,/^# --- 1\. adapter contract/p' "$ROOT/tests/jg-control.test.sh" \
  | sed 's#"$(dirname "${BASH_SOURCE\[0\]}")/lib.sh"#"$ROOT/tests/lib.sh"#' > "$d/control-prelude.sh"
# shellcheck source=/dev/null
. "$d/control-prelude.sh"
trap 'chmod -R u+rwX -- "$d" "$TMP_ROOT" 2>/dev/null; rm -rf -- "$d" "$TMP_ROOT"' EXIT
form_args() {  # <script> <operation> <task id>: the listed form's arguments, the task id in its place, optional groups dropped
  awk -F'\t' -v s="$1" -v o="$2" '$1 == s && $2 == o { print $3 }' "$LIST" \
    | sed -e 's/^bin\/[^ ]* //' -e 's/ *\[[^]]*\]//g' -e 's/ *(--note <text> | --note-file <path>)/ --note fixture/' -e "s/<task-id>/$3/"
}
for verb in interrupt exit relaunch; do
  args=$(form_args jg-control.sh "$verb" t1)
  case $args in "t1 $verb"*) ;; *) fail "the listed form of jg-control.sh $verb does not put the task first: [$args]" ;; esac
  dir=$(new_case "form-$verb")
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  # shellcheck disable=SC2086
  out=$(run_control "$dir" $args); rc=$?
  case $verb in
    interrupt)
      [ "$rc" = 0 ] || fail "jg-control.sh $args: exit $rc: $out"
      [ "$(keys_sent "$dir")" = Escape ] || fail "interrupt should send one Escape to the task, got [$(keys_sent "$dir")]" ;;
    exit)
      [ "$rc" = 0 ] || fail "jg-control.sh $args: exit $rc: $out"
      [ "$(literals "$dir")" = /exit ] || fail "exit should type /exit into the task, got [$(literals "$dir")]" ;;
    relaunch)
      # the stand-in keeps the old agent alive until its exit command arrives, so reaching the task is the exit command typed
      [ "$(literals "$dir" | head -1)" = /exit ] || fail "relaunch should stop the task's old agent first, got [$(literals "$dir" | head -1)] ($out)" ;;
  esac
done
pass "jg-control.sh <task-id> interrupt, exit and relaunch reach the task through the tmux stand-in"

# --- 4 + 5: GET rows on a fixture with data, and a read listed POST
parse get > "$d/get.out" || fail "a GET row changed a file or called outside: $(grep -P '^get\t(changed|outside-call|parse-error)\t' "$d/get.out" | cut -c1-240)"
gets=$(awk -F'\t' 'NR > 1 && $5 == "GET" { n++ } END { print n }' "$LIST")
[ "$(grep -c -P '^get\t' "$d/get.out")" = "$gets" ] || fail "want one line per GET row ($gets), got $(grep -c -P '^get\t' "$d/get.out")"
for row in 'jg-captain-hold.sh phase' 'jg-inbox.sh ready' 'jg-afk-return.sh guard'; do
  line=$(grep -P "^get\tok\t$row\t" "$d/get.out") || fail "$row was not run as a GET row on a fixture with data: $(grep -F "$row" "$d/get.out")"
  case $line in *'files changed'* | *'outside calls'*) fail "$row changed a file or called outside: $line" ;; esac
done
[ "$(grep -c -P '^get\thelp-only\t' "$d/get.out")" -ge 1 ] || fail "a GET row with no usage form should be listed as help-only"
lacks "GET rows" "$(grep -P '^get\thelp-only\t' "$d/get.out")" "get	ok	"
pass "$gets GET rows run on a fixture with an answered and an open hold: no file change, no outside call; help-only GET rows are listed, never proven by name"

parse parity > "$d/parity.out" || fail "a read is listed POST: $(grep -P '\tPOST-read\t' "$d/parity.out" | cut -c1-240)"
awk -F'\t' 'BEGIN { OFS = FS } $1 == "jg-captain-hold.sh" && $2 == "phase" { $5 = "POST"; $6 = "yes" } { print }' "$LIST" > "$d/planted-list.tsv"
if py "$INV/parse.py" parity "$ROOT" "$d/planted-list.tsv" "$d/lab-planted" --only jg-captain-hold.sh > "$d/planted.out"; then
  fail "a planted POST read was not reported as a parity failure: $(cat "$d/planted.out")"
fi
has "planted POST read" "$(cat "$d/planted.out")" 'parity	POST-read	jg-captain-hold.sh phase'
pass "a planted POST read is reported as a parity failure; the real list has none"

# --- 6: continued usage lines, optional option groups, --effort
for want in 'jg-control.sh	relaunch	[--effort <level>]' 'jg-afk-launch.sh	enter	[--expected-return <UTC ISO 8601>] [--spend <n>]' \
  'jg-alert.sh	raise	[--owner-gate G --ticket T --origin O | --security-source S]'; do
  IFS=$'\t' read -r s o group <<< "$want"
  form=$(awk -F'\t' -v s="$s" -v o="$o" '$1 == s && $2 == o { print $3 }' "$LIST")
  has "the listed form of $s $o" "$form" "$group"
  has "the script's own usage lines for $s $o" "$(py "$INV/parse.py" forms "$ROOT" "$LIST" "$d/none" --script "$s")" "$group"
done
P=$d/planted-tree
mkdir -p "$P/bin"
cat > "$P/bin/x.sh" <<'SH'
#!/usr/bin/env bash
# Usage: x.sh start <plan> [--now <epoch>]
#                [--late <x>]
#                (--note <text> | --note-file <path>)
echo "$@"
SH
planted=$(py "$INV/parse.py" forms "$P" "$LIST" "$d/none" --script x.sh)
has "a planted continued usage line" "$planted" 'x.sh start <plan> [--now <epoch>] [--late <x>] (--note <text> | --note-file <path>)'
parse options > "$d/options.out" || fail "an optional option group does not parse: $(grep -P '\tparse-error\t' "$d/options.out" | head -3 | cut -c1-240)"
for tag in absent present; do
  grep -q -P "^option\t[a-z-]+\tjg-control.sh relaunch --effort $tag\t" "$d/options.out" || fail "the relaunch row's --effort group was not parsed $tag"
done
parse run --script jg-control.sh --operation relaunch --set task-id=jg-none --extra= '--extra=--effort low' '--extra=--effort=high' '--extra=--effort bogus' > "$d/effort.out" \
  || fail "the relaunch probe failed: $(cat "$d/effort.out")"
[ "$(grep -c "no task 'jg-none'" "$d/effort.out")" = 3 ] || fail "--effort absent, low and =high should reach task lookup: $(cat "$d/effort.out")"
has "--effort bogus" "$(grep -F 'effort bogus' "$d/effort.out")" '--effort must be one of default, low, medium, high, xhigh, max, ultra'
pass "a continued usage line keeps every group; each optional --option group parses absent and present; --effort bogus gets the allowed values"
echo "forms.test.sh: all checks passed"
