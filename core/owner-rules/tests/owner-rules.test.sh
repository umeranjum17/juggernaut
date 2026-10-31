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
cat > "$home/data/backlog.md" <<'BL'
# Backlog

## In flight
- [ ] with-ask - [captain-ask] Ship a thing (repo: sample) (kind: ship)
  A body line.
- [ ] with-main - Plain title (repo: sample) (kind: ship)
  type: Main7 asked for this.
  parent: with-ask
- [ ] orphan - Plain title (repo: sample) (kind: ship)
  Main11 asked for this.
- [ ] bad-parent - Plain title (repo: sample) (kind: ship)
  Main12 asked for this.
  parent: nowhere
- [ ] upkeep - Routine cleanup (repo: sample) (kind: ship)
  Main14 asked for this.
  parent: upkeep
- [ ] cycle-a - Ticket A (repo: sample) (kind: ship)
  parent: cycle-b
- [ ] cycle-b - Ticket B (repo: sample) (kind: ship)
  parent: cycle-a
- [ ] scout-parentless - Plain title (repo: sample) (kind: ship)
  Main13 asked for this.
- [ ] no-ask - Plain title (repo: sample) (kind: ship)
  Nothing names an owner.
- [ ] bad-design - [captain-ask] Vague design flag (repo: sample) (kind: ship)
  design: maybe
## Done
- [x] with-ask-longer - Main9 something
BL
# brief <id> <args...>: stderr, then rc= on the last line.
brief() {
  local id=$1 out rc; shift
  out=$(JG_HOME=$home JG_ADDONS_DIR=$addons bash "$FM/bin/jg-brief.sh" "$id" sample "$@" 2>&1 >/dev/null); rc=$?
  printf '%s\n' "$out" >> "$work/emitted"
  printf '%s%src=%s\n' "$out" "${out:+$'\n'}" "$rc"
}
ASK='owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for no-ask)'
PARENT='owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for orphan'

# not installed: no check, even for an entry with no owner ask
is "not installed: no-ask lane is briefed" "$(brief no-ask --mode direct-PR | tail -1)" "rc=0"
rm -rf -- "$home/data/no-ask"

"$addons/owner-rules/wiring.sh" "$home" >/dev/null
is "refusal 1: no owner ask" "$(brief no-ask --mode direct-PR)" "$ASK
rc=1"
[ ! -e "$home/data/no-ask" ] && ok "refusal 1 wrote no brief" || no "refusal 1 left data/no-ask"
is "refusal 1: missing entry is also no owner ask" "$(brief ghost --mode direct-PR | tail -2 | head -1 | cut -c1-27)" "owner-rules: no owner ask: "
is "refusal 1: a scout still needs an owner ask" "$(brief no-ask --scout | tail -1)" "rc=1"
is "refusal: no valid parent" "$(brief orphan --mode direct-PR)" "$PARENT
rc=1"
is "refusal: missing parent id" "$(brief bad-parent --mode direct-PR | tail -1)" "rc=1"
[ ! -e "$home/data/orphan" ] && ok "parent refusal wrote no brief" || no "parent refusal left data/orphan"

is "pass: [captain-ask] title, direct-PR" "$(brief with-ask --mode direct-PR)" "rc=0"
[ -s "$home/data/with-ask/brief.md" ] && ok "pass wrote the brief" || no "pass wrote no brief"
is "pass: MainNNN body with existing parent id" "$(brief with-main --mode direct-PR)" "rc=0"
is "pass: upkeep parent" "$(brief upkeep --mode direct-PR)" "rc=0"
is "pass: scouts keep parent exemption" "$(brief scout-parentless --scout)" "rc=0"
is "pass: scout is exempt from the owner and parent rules" "$(brief with-ask-longer --scout)" "rc=0"
is "pass: prefix id does not match a longer id" "$(brief with-ask --scout | tail -1)" "rc=1"
JG_HOME=$home JG_ADDONS_DIR=$addons JG_SQUAD_LEAD_CHARTER=x bash "$FM/bin/jg-brief.sh" sm --squad-lead --no-projects >/dev/null 2>&1 \
  && ok "pass: squad_lead charter is exempt" || no "squad_lead charter refused"

tree=$(bash "$addons/owner-rules/bin/jg-owner-rules-tree.sh" "$home/data/backlog.md")
printf '%s\n' "$tree" | grep -qF 'with-main: with-main -> with-ask -> [epic root]' && ok "tree: prints epic parent chain" || no "tree: epic parent chain missing"
printf '%s\n' "$tree" | grep -qF 'bad-parent: bad-parent -> [missing: nowhere]' && ok "tree: reports missing parent id" || no "tree: missing parent id unreported"
printf '%s\n' "$tree" | grep -qF 'cycle-a: cycle-a -> cycle-b -> cycle-a -> [cycle: cycle-a]' && ok "tree: reports cycle" || no "tree: cycle unreported"
printf '%s\n' "$tree" | grep -A8 '^Items with no valid parent:' | grep -qF '  cycle-a' && ok "tree: lists invalid items" || no "tree: invalid items list missing cycle"

"$addons/owner-rules/unwiring.sh" "$home" >/dev/null
is "uninstalled: check is off again" "$(brief no-ask --mode direct-PR | tail -1)" "rc=0"

# The leads skill quotes each real refusal line (with $id, $what, ... standing in for the runtime value).
# Provoke every refusal through the real brief and the installed merge gate, then require each quoted line to
# match a line they actually emitted.
"$addons/owner-rules/wiring.sh" "$home" >/dev/null
brief bad-design --mode direct-PR >/dev/null
mkdir -p "$work/bin" "$work/ship" "$work/data/jg-merge-on-green" "$home/data/lane/.done-done/runs"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/gh"; printf '#!/bin/sh\nexit 0\n' > "$work/data/jg-merge-on-green/checks-lint.sh"
chmod +x "$work/bin/gh" "$work/data/jg-merge-on-green/checks-lint.sh"
gate() { PATH=$work/bin:$PATH JG_HOME=$home JG_FLEET_BOARD=$work/board.json "$home/config/merge-gate" lane "$1" abc123 https://github.com/o/r/pull/9 2>&1 | tee -a "$work/emitted" >/dev/null; }
gate "$work/ship"
printf '{"schema":1,"exit":0,"dirty":false,"commit":"abc123","files":["a.png"],"run_id":"r1"}\n' > "$home/data/lane/.done-done/runs/r1.json"
gate "$work/ship"
unmatched=$(python3 - "$addons/owner-rules/skill/SKILL.md" "$work/emitted" <<'PY'
import re, sys
quotes = [l.rstrip("\n") for l in open(sys.argv[1]) if l.startswith("owner-rules: ")]
emitted = open(sys.argv[2]).read().splitlines()
print(len(quotes))
for q in quotes:
    pat = re.escape(q)
    pat = re.sub(r"\\\$\{?\w+\}?|<[A-Za-z_]+>", ".+", pat)
    if not any(re.match(pat, e) for e in emitted):
        print("unmatched: " + q)
PY
)
is "skill quotes all five refusals" "$(printf '%s\n' "$unmatched" | head -1)" "5"
is "every refusal quoted in the skill is emitted by the brief or the gate" "$(printf '%s\n' "$unmatched" | tail -n +2)" ""

[ "$fails" -eq 0 ] && echo "PASS owner-rules" || { echo "FAIL owner-rules: $fails"; exit 1; }
