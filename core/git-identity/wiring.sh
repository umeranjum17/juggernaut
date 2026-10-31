#!/usr/bin/env bash
# Install or update the git-identity feature for this user and point one juggernaut home's config/launch-env-hook at it
# through an exec shim, backing up a replaced hook first. Idempotent; a configured identity is kept unless a flag
# replaces it. Usage: wiring.sh [--dry-run] [--email <email>] [--name <name>] <jg-home>
set -euo pipefail
usage() { echo "usage: wiring.sh [--dry-run] [--email <email>] [--name <name>] <jg-home>" >&2; exit 2; }
DRY=0 EMAIL='' NAME=''
while [ "$#" -gt 1 ]; do
  case "$1" in
  --dry-run) DRY=1; shift ;;
  --email) EMAIL=$2; shift 2 ;;
  --name) NAME=$2; shift 2 ;;
  *) break ;;
  esac
done
[ "$#" -eq 1 ] && [ -d "$1/config" ] || usage
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-git-identity
CONF=$DEST/identity.gitconfig
if [ -z "$EMAIL" ]; then
  EMAIL=$(git config -f "$CONF" user.email 2>/dev/null || git config --global user.email 2>/dev/null || true)
  [ -n "$EMAIL" ] || { echo "wiring.sh: no identity: pass --email or set git user.email (no default identity)" >&2; exit 1; }
fi
if [ -z "$NAME" ]; then
  NAME=$(git config -f "$CONF" user.name 2>/dev/null || git config --global user.name 2>/dev/null || true)
  [ -n "$NAME" ] || { echo "wiring.sh: no identity: pass --name or set git user.name (no default identity)" >&2; exit 1; }
fi
# Every client-side hook name the fork's lane hooks dir chains (bin/jg-git-strip-ai-trailers.sh), plus commit-msg:
# a lane resolves this dir as the repository's hooks dir, so a missing name would skip the repository's own hook.
HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg
post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc sendemail-validate'
HOOK=$FMH/config/launch-env-hook
SHIM=$(printf '#!/usr/bin/env bash\nexec %q env-file "$@"\n' "$DEST/git-identity")
# Back up a hook that is not already ours, once per distinct hook: another feature (pane-titles) re-chains the
# shim every install, so a repeat run would otherwise pile up identical copies instead of being a no-op.
BAK=
if [ -e "$HOOK" ] && [ "$(cat "$HOOK")" != "$SHIM" ]; then
  hook_text=$(cat "$HOOK")
  for prior in "$HOOK".bak-git-identity-*; do
    [ -f "$prior" ] && [ "$(cat "$prior")" = "$hook_text" ] && { BAK=$prior; break; }
  done
  [ -n "$BAK" ] || BAK=$HOOK.bak-git-identity-$(date +%s)
fi
grep -q launch-env-hook "$FMH/bin/jg-spawn.sh" 2>/dev/null ||
  echo "note: $FMH/bin/jg-spawn.sh does not run config/launch-env-hook yet; lanes stay unguarded until it does"

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/git-identity -> $DEST/git-identity"
  echo "would write: $CONF (user.name=$NAME user.email=$EMAIL core.hooksPath=$DEST/hooks)"
  echo "would write: $DEST/hooks/<name>, one read-only wrapper each: $(tr '\n' ' ' <<<"$HOOKS")"
  [ -z "$BAK" ] || echo "would back up: $HOOK -> $BAK"
  echo "would write: $HOOK:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST/hooks"
install -m 755 "$SRC/git-identity" "$DEST/git-identity"
rm -f "$CONF"
git config -f "$CONF" user.name "$NAME"
git config -f "$CONF" user.email "$EMAIL"
git config -f "$CONF" core.hooksPath "$DEST/hooks"
# Read-only, so a hook manager run inside a lane fails loudly instead of replacing a wrapper.
for name in $HOOKS; do
  rm -f "$DEST/hooks/$name"
  printf '#!/usr/bin/env bash\nexec %q hook %s "$@"\n' "$DEST/git-identity" "$name" >"$DEST/hooks/$name"
  chmod 555 "$DEST/hooks/$name"
done
[ -z "$BAK" ] || [ -f "$BAK" ] || { cp -p "$HOOK" "$BAK"; echo "backed up: $BAK"; }
printf '%s\n' "$SHIM" >"$HOOK"
chmod 700 "$HOOK"
echo "installed: $HOOK -> $DEST/git-identity (lanes commit and push as $NAME <$EMAIL>)"
