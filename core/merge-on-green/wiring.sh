#!/usr/bin/env bash
# Install, update or migrate the merge-on-green watcher check in one juggernaut home. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
#
# This is the one installer path for the merge gate, and it also migrates the retired install of it. A
# home that still runs the add-on's copy at ${XDG_DATA_HOME:-~/.local/share}/fm-merge-on-green keeps
# that directory's fm-checks-lint.sh, whose size rule refused any pull request over 1,000 added lines;
# this feature's copy installs beside it as jg-merge-on-green/jg-checks-lint.sh, where the size is
# advice unless the home writes `refuse` in config/checks-size. The retired directory is left holding
# one redirect line, never the old rule, so a machine whose other homes were not migrated in this run
# keeps running the same gate instead of breaking.
#
# The install share comes from the shim the home already runs, so a re-run keeps a home at its own
# install path instead of moving it to XDG_DATA_HOME. Every expected shape is proved before the first
# write: a shim that execs neither copy, a shim that runs another home's gate, or a retired directory
# that is neither the old install nor this wiring's redirect, refuses the whole run rather than
# leaving the home half-wired. A registration the register script refuses puts the home's previous
# wiring back.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SHARE=${XDG_DATA_HOME:-$HOME/.local/share}
ID=merge-on-green
STATE=$FMH/state
SHIM=$STATE/$ID.check.sh
FILES=(merge-on-green.sh checks-lint.sh jg-checks-lint.sh .done-done.yaml)
STUB_MARK='# Retired add-on path: this one line runs the juggernaut merge gate at'

refuse() { printf 'merge-on-green: refused: %s\n' "$*" >&2; exit 1; }

# 1. Prove the home's own gate chain before touching anything, and take the share it names: a home
#    wired at one install path stays there, so a re-run never moves it to a different directory.
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then refuse "the home has no state directory at $STATE"; fi
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then
  refuse "$SHIM is not a regular file; move it aside and run this again"
fi
wired=0
if [ -f "$SHIM" ]; then
  line=$(sed -n 's/^exec \(.*\)$/\1/p' "$SHIM" | head -n 1)
  case $line in
    *' check '?*) target=${line% check *}; run_for=${line##* } ;;
    *) refuse "$SHIM runs [$line], which is not the merge gate this installer writes; move it aside and run this again" ;;
  esac
  case $target in
    */fm-merge-on-green/merge-on-green.sh) SHARE=${target%/fm-merge-on-green/merge-on-green.sh} ;;
    */jg-merge-on-green/merge-on-green.sh) SHARE=${target%/jg-merge-on-green/merge-on-green.sh}; wired=1 ;;
    *) refuse "$SHIM runs [$line], which is not the merge gate this installer writes; move it aside and run this again" ;;
  esac
  [ "$run_for" = "$(printf '%q' "$FMH")" ] \
    || refuse "$SHIM runs the merge gate for [$run_for], not for this home; move it aside and run this again"
fi
DEST=$SHARE/jg-merge-on-green
RETIRED=$SHARE/fm-merge-on-green
SHIM_TEXT=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/merge-on-green.sh" "$FMH")
STUB_TEXT=$(printf '#!/usr/bin/env bash\n%s %s.\nexec %q "$@"\n' "$STUB_MARK" "$DEST/merge-on-green.sh" "$DEST/merge-on-green.sh")

# 2. Prove the retired add-on copy's shape: the old install, this installer's redirect, or absent.
retired=absent
if [ -e "$RETIRED" ] || [ -L "$RETIRED" ]; then
  if [ ! -d "$RETIRED" ] || [ -L "$RETIRED" ]; then
    refuse "$RETIRED is not a directory; move it aside and run this again"
  fi
  if [ -f "$RETIRED/merge-on-green.sh" ] && grep -qF -- "$STUB_MARK" "$RETIRED/merge-on-green.sh"; then
    retired=migrated
  elif [ -f "$RETIRED/fm-checks-lint.sh" ] && [ -f "$RETIRED/checks-lint.sh" ] && [ -f "$RETIRED/merge-on-green.sh" ]; then
    retired=old
  else
    refuse "$RETIRED does not hold the retired add-on copy (fm-checks-lint.sh, checks-lint.sh, merge-on-green.sh); move it aside and run this again"
  fi
fi

# 3. Dry run: the same steps, printed, and nothing written.
if [ "$DRY" -eq 1 ]; then
  for f in "${FILES[@]}"; do echo "would copy: $SRC/$f -> $DEST/$f"; done
  if [ "$retired" = old ]; then
    echo "would write: $RETIRED/merge-on-green.sh: one redirect to $DEST/merge-on-green.sh"
    for f in "${FILES[@]}"; do
      [ "$f" = merge-on-green.sh ] || echo "would remove: $RETIRED/$f"
    done
  fi
  echo "would write: $SHIM:"
  printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"
  exit 0
fi

# 4. Write: the feature copy, then the retired redirect, then the home's shim, then its registration.
backup=''
if [ -f "$SHIM" ]; then
  backup=$(mktemp "$STATE/.jg-merge-gate-install.XXXXXX") || refuse "cannot write in $STATE"
  cp -p "$SHIM" "$backup"
fi
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
mkdir -p "$DEST"
install -m 755 "$SRC/merge-on-green.sh" "$DEST/merge-on-green.sh"
install -m 755 "$SRC/checks-lint.sh" "$DEST/checks-lint.sh"
install -m 755 "$SRC/jg-checks-lint.sh" "$DEST/jg-checks-lint.sh"
install -m 644 "$SRC/.done-done.yaml" "$DEST/.done-done.yaml"
# The retired path before the shim: a home still pointing at it runs the new gate the moment the
# redirect lands, never a script this run has not installed yet.
if [ "$retired" = old ]; then
  printf '%s' "$STUB_TEXT" > "$RETIRED/.merge-on-green.sh.new" || refuse "cannot write in $RETIRED"
  chmod 755 "$RETIRED/.merge-on-green.sh.new"
  mv -f "$RETIRED/.merge-on-green.sh.new" "$RETIRED/merge-on-green.sh"
  for f in checks-lint.sh fm-checks-lint.sh .done-done.yaml; do rm -f -- "$RETIRED/$f"; done
fi
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
# An JG_STATE_OVERRIDE in the caller env, even empty, would redirect the register away from FMH/state.
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  refuse "the check could not be registered; the home's previous wiring is back"
fi

if [ "$wired" -eq 1 ] && [ "$retired" != old ]; then
  echo "merge-on-green: already wired $FMH (nothing changed)"
else
  echo "merge-on-green: wired $FMH (gate $DEST, size rule advisory unless config/checks-size says refuse)"
fi
if [ "$retired" = old ]; then
  echo "merge-on-green: migrated the retired add-on copy at $RETIRED: it redirects to $DEST and its 1,000-line rule is gone"
fi
