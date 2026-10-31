#!/usr/bin/env bash
# brief-inherit e2e: the shared worker-instruction include through the real jg-brief.sh and
# jg-config-push.sh of a juggernaut checkout.
# Usage: brief-inherit/tests/brief-inherit-e2e.sh <juggernaut-checkout>
#   A checkout without the seam (today's fork) is copied to a temp root and Kun's single-file
#   include read plus the two seam lines are applied there, which is step B. A checkout that
#   already carries the seam runs as is. Present must equal the pre-seam fork's output, the
#   reference: the checkout itself when it lacks the seam, else a temp copy with
#   pre-seam-reference.patch (fork PR 114 reversed, committed) applied. Absent (an empty
#   JG_ADDONS_DIR) must be Kun's behavior: local include only, no error, also under set -e.
# shellcheck disable=SC2016 # literal backticks and $ in fixture text
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
[ -n "$FM" ] && [ -x "$FM/bin/jg-brief.sh" ] || { echo "usage: $0 <juggernaut-checkout>" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/brief-inherit-e2e.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
same() { if cmp -s "$2" "$3"; then ok "$1"; else no "$1: $2 differs from $3"; diff "$2" "$3" | head -5; fi; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

SEAM_BRIEF='_bi="${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/brief-inherit/bin/jg-brief-inherit-lib.sh"; [ ! -f "$_bi" ] || { . "$_bi" && jg_brief_inherit_shared "$CONFIG" "$KIND"; }'
SEAM_LIST='_bi="${JG_ADDONS_DIR:-${JG_HOME:-$HOME}/projects/juggernaut-addons}/brief-inherit/bin/jg-brief-inherit-lib.sh"; [ ! -f "$_bi" ] || { . "$_bi" && jg_brief_inherit_config; }'

# The seam root: the checkout itself when it has the seam, else a step-B copy of it.
root=$FM
seamed=0; grep -q jg_brief_inherit_shared "$FM/bin/jg-brief.sh" && seamed=1
if [ "$seamed" = 0 ]; then
  root=$work/root
  mkdir -p "$root" && cp -R "$FM/bin" "$root/bin" && cp "$FM"/AGENTS.md "$root/" 2>/dev/null
  awk -v seam="$SEAM_BRIEF" '
    /^# Read both optional includes/ && !done {
      print "BRIEF_INCLUDE_BODY="
      print "if [ \"$KIND\" != squad_lead ] && { [ -e \"$CONFIG/brief-include.md\" ] || [ -L \"$CONFIG/brief-include.md\" ]; }; then"
      print "  BRIEF_INCLUDE_FILE=$CONFIG/brief-include.md"
      print "  { [ -f \"$BRIEF_INCLUDE_FILE\" ] && BRIEF_INCLUDE_BODY=$(cat \"$BRIEF_INCLUDE_FILE\" 2>/dev/null); } || {"
      print "    echo \"error: $BRIEF_INCLUDE_FILE must be a readable regular file\" >&2; exit 1; }"
      print "  if printf \"%s\\n\" \"$BRIEF_INCLUDE_BODY\" | grep -q \"^Delivery contract: mode=\"; then"
      print "    echo \"error: $BRIEF_INCLUDE_FILE must not carry a '"'"'Delivery contract: mode='"'"' line; the delivery mode is a per-task --mode decision\" >&2; exit 1; fi"
      print "  [ -n \"$(printf \"%s\" \"$BRIEF_INCLUDE_BODY\" | tr -d \"[:space:]\")\" ] || BRIEF_INCLUDE_BODY="
      print "fi"
      print seam
      skip = 1; done = 1; next }
    skip { if ($0 == "fi") skip = 0; next }
    { print }' "$FM/bin/jg-brief.sh" > "$root/bin/jg-brief.sh"
  sed -i -e 's/ brief-include-shared\.md//' \
    -e "/^JG_INHERITABLE_CONFIG=/a\\$SEAM_LIST" "$root/bin/jg-config-inherit-lib.sh"
fi
grep -q jg_brief_inherit_shared "$root/bin/jg-brief.sh" && grep -q jg_brief_inherit_config "$root/bin/jg-config-inherit-lib.sh" \
  && ok "seam applied" || { no "seam not applied to the checkout copy"; exit 1; }

# The reference: the fork's pre-seam output, never the live checkout once it carries the seam.
ref=$FM
if [ "$seamed" = 1 ]; then
  ref=$work/ref
  mkdir -p "$ref" && cp -R "$FM/bin" "$ref/bin" && cp "$FM"/AGENTS.md "$ref/" 2>/dev/null
  patch -s -F0 -p1 -d "$ref" < "$here/pre-seam-reference.patch" || { no "pre-seam reference patch does not apply to the checkout"; exit 1; }
fi

empty=$work/no-addon; mkdir -p "$empty"
# scaffold <jg-root> <addons-dir|-> <home> <id> <ship|scout>: prints stderr, exit code on the last line.
scaffold() {
  local r=$1 a=$2 h=$3 id=$4 kind=$5 args out rc
  [ "$kind" = scout ] && args=(--scout) || args=(--mode no-mistakes)
  out=$(JG_HOME=$h JG_ADDONS_DIR=$([ "$a" = - ] && echo "$empty" || echo "$a") bash "$r/bin/jg-brief.sh" "$id" sample "${args[@]}" 2>&1 >/dev/null); rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
tail_of() { sed -n '/^# Home brief additions/,$p' "$1/data/$2/brief.md"; }
mkhome() { mkdir -p "$1/config" "$1/data" "$1/state"; }

shared='Shared fleet rule: `echo $(id)`.'
local_rule='Home-local rule.'
for h in fork present absent; do
  mkhome "$work/$h"
  printf '%s\n' "$shared" > "$work/$h/config/brief-include-shared.md"
  printf '%s\n' "$local_rule" > "$work/$h/config/brief-include.md"
done

# present == the pre-seam fork's output, ship and scout
for kind in ship scout; do
  scaffold "$ref" - "$work/fork" "b-$kind" "$kind" > "$work/fork-$kind.out"
  scaffold "$root" "$addons" "$work/present" "b-$kind" "$kind" > "$work/present-$kind.out"
  same "present: $kind scaffold exits and prints like the fork" "$work/fork-$kind.out" "$work/present-$kind.out"
  same "present: $kind include section is byte-identical to the fork's" <(tail_of "$work/fork" "b-$kind") <(tail_of "$work/present" "b-$kind")
done
is "present: shared text comes first, then the local rule" "$(tail_of "$work/present" b-ship | tail -2 | tr '\n' '|')" "$shared|$local_rule|"

# absent == Kun: local include only, clean exit, silent
for kind in ship scout; do
  scaffold "$root" - "$work/absent" "b-$kind" "$kind" > "$work/absent-$kind.out"
  is "absent: $kind scaffold is silent and exits 0" "$(tr -d "\n" < "$work/absent-$kind.out")" "rc=0"
  is "absent: $kind include is only the local rule" "$(tail_of "$work/absent" "b-$kind" | tail -1)" "$local_rule"
  grep -q 'Shared fleet rule' "$work/absent/data/b-$kind/brief.md" && no "absent: $kind brief leaked the shared include"
done
lib=$root/bin/jg-config-inherit-lib.sh
out=$(JG_HOME=$work/absent JG_ADDONS_DIR=$empty bash -e -c ". '$lib'; echo \"\$JG_INHERITABLE_CONFIG\"" 2>&1)
case " $out " in *" brief-include-shared.md "*) no "absent: inheritable list still names the shared include" ;; *) ok "absent: inheritable list is Kun's, sourcing under set -e is silent" ;; esac

# refusals match the fork's, name the shared file, and leave no partial scaffold
for bad in contract dir; do
  for who in fork present; do
    h=$work/bad-$who-$bad; mkhome "$h"; rm -f "$h/config/brief-include-shared.md"
    if [ "$bad" = contract ]; then printf '%s\n' 'Delivery contract: mode=local-only' > "$h/config/brief-include-shared.md"
    else mkdir "$h/config/brief-include-shared.md"; fi
  done
  scaffold "$ref" - "$work/bad-fork-$bad" r scout | sed "s#$work/bad-fork-$bad#H#" > "$work/bad-fork.out"
  scaffold "$root" "$addons" "$work/bad-present-$bad" r scout | sed "s#$work/bad-present-$bad#H#" > "$work/bad-present.out"
  same "present: $bad shared include is refused exactly like the fork" "$work/bad-fork.out" "$work/bad-present.out"
  [ -e "$work/bad-present-$bad/data/r" ] && no "present: refused $bad include left a partial scaffold"
  grep -q 'rc=1' "$work/bad-present.out" && grep -q 'brief-include-shared.md' "$work/bad-present.out" || no "present: $bad refusal did not name the shared file"
done

# charters never take an include
mkhome "$work/sm"; cp "$work/present/config/brief-include-shared.md" "$work/sm/config/"
JG_HOME=$work/sm JG_ADDONS_DIR=$addons JG_SQUAD_LEAD_CHARTER=sample bash "$root/bin/jg-brief.sh" c --squad-lead --no-projects >/dev/null 2>&1
grep -q 'Home brief additions' "$work/sm/data/c/brief.md" && no "charter took the shared include" || ok "charter takes no include"

# config-push: exact bytes propagate, then absence converges (present); nothing propagates (absent)
push_case() { # <addons-dir> <label> <expect-pushed 1|0>
  local a=$1 p=$work/push-$2 sm=$work/push-$2-sm out
  mkhome "$p"; mkdir -p "$sm/config" "$sm/bin"
  printf '%s\n' 'Fixture.' > "$sm/AGENTS.md"; printf '%s\n' config/ data/ state/ .jg-squad-lead-home > "$sm/.gitignore"
  git init -q "$sm"; printf '%s\n' pm > "$sm/.jg-squad-lead-home"
  printf 'kind=squad_lead\nbackend=tmux\nwindow=bi-e2e:absent\nhome=%s\n' "$sm" > "$p/state/pm.meta"
  touch "$p/state/.last-watcher-beat"; printf '%s\n' "$shared" > "$p/config/brief-include-shared.md"
  out=$(JG_HOME=$p JG_ROOT_OVERRIDE=$root JG_ADDONS_DIR=$a bash "$root/bin/jg-config-push.sh" 2>&1)
  if [ "$3" = 1 ]; then
    cmp -s "$p/config/brief-include-shared.md" "$sm/config/brief-include-shared.md" && ok "$2: shared include propagated byte-exactly" || no "$2: not propagated: $out"
    rm "$p/config/brief-include-shared.md"; JG_HOME=$p JG_ROOT_OVERRIDE=$root JG_ADDONS_DIR=$a bash "$root/bin/jg-config-push.sh" >/dev/null 2>&1
    [ ! -e "$sm/config/brief-include-shared.md" ] && ok "$2: absence converged" || no "$2: stale shared include survived"
  else
    [ ! -e "$sm/config/brief-include-shared.md" ] && ok "$2: nothing propagated" || no "$2: shared include propagated without the feature"
  fi
}
push_case "$addons" present 1
push_case "$empty" absent 0

[ "$fails" -eq 0 ] && echo "all brief-inherit checks passed" || { echo "$fails check(s) failed" >&2; exit 1; }
