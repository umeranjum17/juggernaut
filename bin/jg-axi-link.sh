#!/usr/bin/env bash
# jg-axi-link.sh - put `juggernaut-axi` on PATH for this checkout.
# Usage: jg-axi-link.sh [--dry-run]
#
# It writes one small launcher, `<prefix>/bin/juggernaut-axi`, where <prefix> is
# NPM_CONFIG_PREFIX or ~/.local - the prefix install.sh and bin/jg-bootstrap.sh
# already install into. install.sh runs it once and bin/jg-bootstrap.sh runs it at
# every locked session start, so every home has the command with no sudo.
#
# The launcher is not a symlink on purpose. bin/juggernaut-axi finds its sibling
# libraries from its own path without following links, and one link could only
# point at one home. The launcher instead runs bin/juggernaut-axi of the first
# home that answers: JG_ROOT_OVERRIDE, then JG_HOME, then the checkout the current
# directory sits in, then the checkout that wrote it. A home whose bin/juggernaut-axi
# is gone no longer answers, so deleting a home never leaves the command broken.
#
# Idempotent and quiet: a launcher that is already ours and whose recorded
# checkout still has bin/juggernaut-axi is left alone, so two homes on one machine
# do not take the command from each other. A file there that is not our launcher
# is never replaced; the script exits 1 and names it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.local}
TARGET=$PREFIX/bin/juggernaut-axi
MARK='# juggernaut-axi launcher (managed by bin/jg-axi-link.sh)'

DRY=no
case "${1:-}" in
  '') ;;
  --dry-run) DRY=yes ;;
  -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  *) echo "usage: jg-axi-link.sh [--dry-run]" >&2; exit 2 ;;
esac

[ -x "$ROOT/bin/juggernaut-axi" ] || { echo "jg-axi-link: $ROOT/bin/juggernaut-axi is missing or not executable" >&2; exit 1; }

# The recorded checkout of an existing launcher of ours, or nothing.
recorded_root() {
  [ -f "$TARGET" ] && [ ! -L "$TARGET" ] && [ "$(sed -n 2p "$TARGET")" = "$MARK" ] || return 1
  sed -n "s/^default='\\(.*\\)'\$/\\1/p" "$TARGET" | head -n 1
}

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  if ! recorded=$(recorded_root); then
    echo "jg-axi-link: $TARGET exists and is not Juggernaut's launcher; left alone" >&2
    exit 1
  fi
  if [ -x "$recorded/bin/juggernaut-axi" ]; then
    exit 0
  fi
fi

if [ "$DRY" = yes ]; then
  echo "axi: would link $TARGET to $ROOT/bin/juggernaut-axi"
  exit 0
fi

mkdir -p "$PREFIX/bin" || exit 1
tmp=$(mktemp "$PREFIX/bin/.juggernaut-axi.XXXXXX") || exit 1
case $ROOT in *"'"*) rm -f -- "$tmp"; echo "jg-axi-link: refusing a checkout path with a quote: $ROOT" >&2; exit 1 ;; esac
cat > "$tmp" <<LAUNCHER
#!/usr/bin/env bash
$MARK
default='$ROOT'
for root in "\${JG_ROOT_OVERRIDE:-}" "\${JG_HOME:-}"; do
  [ -n "\$root" ] && [ -x "\$root/bin/juggernaut-axi" ] && exec "\$root/bin/juggernaut-axi" "\$@"
done
root=\$(pwd -P)
while [ -n "\$root" ]; do
  [ -x "\$root/bin/juggernaut-axi" ] && exec "\$root/bin/juggernaut-axi" "\$@"
  root=\${root%/*}
done
[ -x "\$default/bin/juggernaut-axi" ] && exec "\$default/bin/juggernaut-axi" "\$@"
echo "juggernaut-axi: no Juggernaut checkout answers; set JG_HOME or run bin/jg-axi-link.sh from a checkout" >&2
exit 1
LAUNCHER
if ! { chmod 755 "$tmp" && mv -f -- "$tmp" "$TARGET"; }; then
  rm -f -- "$tmp"
  echo "jg-axi-link: cannot write $TARGET" >&2
  exit 1
fi
echo "axi: linked $TARGET to $ROOT/bin/juggernaut-axi"
