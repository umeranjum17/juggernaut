#!/usr/bin/env bash
# owner-rules e2e: the real jg-brief.sh of a juggernaut checkout that carries the brief-inherit seam.
# Usage: owner-rules/tests/owner-rules.test.sh <juggernaut-checkout>
# Proves a no-owner-ask refusal, a no-parent refusal and a clean pass (brief written), plus the
# exemptions and the no-op when the feature is not installed.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
FM=${1:-}
[ -n "$FM" ] && [ -x "$FM/bin/jg-brief.sh" ] \
  || { echo "usage: $0 <juggernaut-checkout with the brief-inherit seam>" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-e2e.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data" "$home/state"
# bin/jg-brief.sh owns the no-mistakes risk reason (--risk); this home answers it up front
# so these cases exercise the feature's owner, hierarchy and design rules only.
: > "$home/config/delivery-risk-loose"
. "$addons/lib/beads-test-env.sh"
core_beads_home "$FM" "$home"
export JG_HOME=$home
add() {  # <id> <title> <body>
  local id=$1 title=$2 body=$3 prio=1
  case $title in "[captain-ask]"*) prio=0 ;; esac
  (cd "$home" && JG_HOME=$home bash "$FM/bin/jg-backlog.sh" add "$id" "$title" --priority "$prio" --kind ship --repo sample --body "$body") >/dev/null 2>"$work/add.err" \
    || { echo "fixture: could not add $id: $(cat "$work/add.err")" >&2; exit 1; }
}
add jg-with-ask '[captain-ask] Ship a thing' 'A body line.'
add jg-with-main 'Plain title' $'type: Main7 asked for this.\nparent: jg-with-ask'
add jg-orphan 'Plain title' 'Main11 asked for this.'
add jg-bad-parent 'Plain title' $'Main12 asked for this.\nparent: jg-nowhere'
add jg-upkeep 'Routine cleanup' $'Main14 asked for this.\nparent: upkeep'
add jg-cycle-a 'Ticket A' 'parent: jg-cycle-b'
add jg-cycle-b 'Ticket B' 'parent: jg-cycle-a'
add jg-scout-parentless 'Plain title' 'Main13 asked for this.'
add jg-no-ask 'Plain title' 'Nothing names an owner.'
add jg-bad-design '[captain-ask] Vague design flag' 'design: maybe'
add jg-with-ask-longer 'Main9 something' 'Done item.'
(cd "$home" && JG_HOME=$home bash "$FM/bin/jg-backlog.sh" 'done' jg-with-ask-longer) >/dev/null 2>&1 || true
# brief <id> <args...>: stderr, then rc= on the last line.
brief() {
  local id=$1 out rc; shift
  out=$(JG_HOME=$home JG_ADDONS_DIR=$addons bash "$FM/bin/jg-brief.sh" "$id" sample "$@" 2>&1 >/dev/null); rc=$?
  printf '%s\n' "$out" >> "$work/emitted"
  printf '%s%src=%s\n' "$out" "${out:+$'\n'}" "$rc"
}
ASK='owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for jg-no-ask)'
PARENT='owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for jg-orphan'

# not installed: no check, even for an entry with no owner ask
is "not installed: jg-no-ask lane is briefed" "$(brief jg-no-ask --mode direct-PR | tail -1)" "rc=0"
rm -rf -- "$home/data/jg-no-ask"

"$addons/owner-rules/wiring.sh" "$home" >/dev/null
is "refusal 1: no owner ask" "$(brief jg-no-ask --mode direct-PR)" "$ASK
rc=1"
[ ! -e "$home/data/jg-no-ask" ] && ok "refusal 1 wrote no brief" || no "refusal 1 left data/jg-no-ask"
is "refusal 1: missing entry is also no owner ask" "$(brief jg-ghost --mode direct-PR | tail -2 | head -1 | cut -c1-27)" "owner-rules: no owner ask: "
is "refusal 1: a scout still needs an owner ask" "$(brief jg-no-ask --scout | tail -1)" "rc=1"
is "refusal: no valid parent" "$(brief jg-orphan --mode direct-PR)" "$PARENT
rc=1"
is "refusal: missing parent id" "$(brief jg-bad-parent --mode direct-PR | tail -1)" "rc=1"
[ ! -e "$home/data/jg-orphan" ] && ok "parent refusal wrote no brief" || no "parent refusal left data/jg-orphan"

is "pass: [captain-ask] title, direct-PR" "$(brief jg-with-ask --mode direct-PR)" "rc=0"
[ -s "$home/data/jg-with-ask/brief.md" ] && ok "pass wrote the brief" || no "pass wrote no brief"
is "pass: MainNNN body with existing parent id" "$(brief jg-with-main --mode direct-PR)" "rc=0"
is "pass: jg-upkeep parent" "$(brief jg-upkeep --mode direct-PR)" "rc=0"
is "pass: scouts keep parent exemption" "$(brief jg-scout-parentless --scout)" "rc=0"
is "pass: scout is exempt from the owner and parent rules" "$(brief jg-with-ask-longer --scout)" "rc=0"
is "pass: prefix id does not match a longer id" "$(brief jg-with-ask --scout | tail -1)" "rc=1"
JG_HOME=$home JG_ADDONS_DIR=$addons JG_SQUAD_LEAD_CHARTER=x bash "$FM/bin/jg-brief.sh" sm --squad-lead --no-projects >/dev/null 2>&1 \
  && ok "pass: squad_lead charter is exempt" || no "squad_lead charter refused"

tree=$(bash "$addons/owner-rules/bin/jg-owner-rules-tree.sh" <(cd "$home" && JG_HOME=$home bash "$FM/bin/jg-backlog.sh" markdown))
printf '%s\n' "$tree" | grep -qF 'jg-with-main: jg-with-main -> jg-with-ask -> [epic root]' && ok "tree: prints epic parent chain" || no "tree: epic parent chain missing"
printf '%s\n' "$tree" | grep -qF 'jg-cycle-a: jg-cycle-a -> jg-cycle-b -> jg-cycle-a -> [cycle: jg-cycle-a]' && ok "tree: reports cycle" || no "tree: cycle unreported"
printf '%s\n' "$tree" | grep -A8 '^Items with no valid parent:' | grep -qF '  jg-cycle-a' && ok "tree: lists invalid items" || no "tree: invalid items list missing cycle"

"$addons/owner-rules/unwiring.sh" "$home" >/dev/null
is "uninstalled: check is off again" "$(brief jg-no-ask --mode direct-PR | tail -1)" "rc=0"

# The merge gate refusals are proved by gate-matrix.test.sh and owner-rules-gate.test.sh.

[ "$fails" -eq 0 ] && echo "PASS owner-rules" || { echo "FAIL owner-rules: $fails"; exit 1; }
