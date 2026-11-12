#!/usr/bin/env bash
# Install repo-guard: the gh and gh-axi shims that refuse a write to a repository outside allowed-repos, and the git pre-push extension that refuses a push to one. Idempotent.
# The guard itself is the Go guard host at core/guard-host, built here into the install dir so the installed copy needs no toolchain later; installing needs go on PATH (or JG_GUARD_HOST_GO).
# Usage: wiring.sh [--dry-run | --uninstall]
# The allow-list is ${XDG_DATA_HOME:-~/.local/share}/jg-repo-guard/allowed-repos: copied once and never overwritten, so an extended list survives a rerun.
# An installed gh or gh-axi is usually a symlink into a package, so its real binary runs in place from a recorded path; only the PATH entry becomes the shim, and --uninstall puts it back.
set -euo pipefail
usage() { echo 'usage: wiring.sh [--dry-run | --uninstall]' >&2; exit 2; }
DRY=0 UN=0
case "${1:-}" in
--dry-run) DRY=1 ;;
--uninstall) UN=1 ;;
'') ;;
*) usage ;;
esac
[ "$#" -le 1 ] || usage
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
DEST=$DATA/jg-repo-guard
GUARD=$DEST/repo-guard
SOURCE=$DEST/repo-guard.source
RUNNER=$DEST/run-guard
ALLOW=$DEST/allowed-repos
HOOK=$DATA/jg-git-identity/hooks.d/pre-push/repo-guard
TOOLS='gh-axi gh'
realfile() { printf '%s' "$DEST/$1.real"; }      # where the real binary's path is recorded
movedfile() { printf '%s' "$DEST/$1.real.bin"; } # the binary itself, when it was a plain file
ours() { [ -f "$1" ] && grep -qF -- "$GUARD" "$1"; }

if [ "$UN" = 1 ]; then
  for tool in $TOOLS; do
    target=$(command -v "$tool" || true) real=$(cat "$(realfile "$tool")" 2>/dev/null || true)
    [ -n "$target" ] && [ -n "$real" ] || continue
    echo "restore: $target -> $real"
    if [ "$DRY" = 0 ]; then
      rm -f -- "$target"
      if [ "$real" = "$(movedfile "$tool")" ]; then mv -f -- "$real" "$target"; else ln -s -- "$real" "$target"; fi
    fi
  done
  for f in "$GUARD" "$SOURCE" "$RUNNER" "$HOOK" "$(realfile gh-axi)" "$(realfile gh)"; do echo "remove: $f"; [ "$DRY" = 1 ] || rm -f -- "$f"; done
  [ "$DRY" = 1 ] || rmdir "$DATA/jg-git-identity/hooks.d/pre-push" 2>/dev/null || true
  [ "$DRY" = 0 ] || echo 'dry run: nothing written'
  echo "kept: $ALLOW (an extended allow-list is never dropped)"
  exit 0
fi

[ "$DRY" = 1 ] || mkdir -p "$DEST" "$DATA/jg-git-identity/hooks.d/pre-push"
if [ "$DRY" = 0 ]; then
# The guard itself is the Go guard host, built here so the installed copy needs no toolchain
# later. A build failure refuses loudly: a guard that cannot run must never be installed.
GO=${JG_GUARD_HOST_GO:-go}
command -v "$GO" >/dev/null 2>&1 || { echo "repo-guard: refused: no Go toolchain on PATH (set JG_GUARD_HOST_GO, or install go); nothing installed. This refusal is final." >&2; exit 1; }
GUARD_TMP=$GUARD.tmp.$$
trap 'rm -f -- "$GUARD_TMP"' EXIT
( cd "$SRC/../guard-host" && "$GO" build -o "$GUARD_TMP" ./cmd/jg-guard-host ) || { echo "repo-guard: refused: the guard host did not build; nothing installed" >&2; exit 1; }
chmod 755 "$GUARD_TMP"
# Publish a complete reference first; both renames stay on the destination filesystem.
SOURCE_TMP=$SOURCE.tmp.$$
RUNNER_TMP=$RUNNER.tmp.$$
trap 'rm -f -- "$GUARD_TMP" "$SOURCE_TMP" "$RUNNER_TMP"' EXIT
cp -- "$GUARD_TMP" "$SOURCE_TMP"
chmod 755 "$SOURCE_TMP"
mv -f -- "$SOURCE_TMP" "$SOURCE"
cp -- "$SRC/run-guard" "$RUNNER_TMP"
chmod 755 "$RUNNER_TMP"
mv -f -- "$RUNNER_TMP" "$RUNNER"
mv -f -- "$GUARD_TMP" "$GUARD"
fi
for tool in $TOOLS; do
  target=$(command -v "$tool" || true)
  [ -n "$target" ] || { echo "note: no $tool on PATH; it stays unguarded until one is installed and this runs again"; continue; }
  if [ "$DRY" = 1 ]; then
    if ours "$target"; then echo "would keep: $(cat "$(realfile "$tool")" 2>/dev/null || echo unset)"
    elif [ -L "$target" ]; then echo "would record the real $tool: $(readlink -f "$target")"
    elif [ "${target#"$HOME/.local/bin/"}" != "$target" ]; then echo "would move the real $tool aside to: $(movedfile "$tool")"
    else echo "would leave the package-managed $target alone; symlink $HOME/.local/bin/$tool to it and rerun"; continue; fi
    echo "would write: $target (the shim that runs repo-guard $tool)"
  else
    if ! ours "$target"; then
    # A symlink into a package is dropped, never followed: writing through it would overwrite the package's own file, and copying it out would break its own imports.
    # A plain file is only moved aside inside the user's own bin dir, so a mise- or npm-managed binary is never touched.
    if [ -L "$target" ]; then
      readlink -f "$target" >"$(realfile "$tool")"
      rm -f -- "$target"
    elif [ "${target#"$HOME/.local/bin/"}" != "$target" ]; then
      mv -f -- "$target" "$(movedfile "$tool")"
      printf '%s' "$(movedfile "$tool")" >"$(realfile "$tool")"
    else
      echo "note: $target is package-managed; left unguarded (symlink $HOME/.local/bin/$tool to it and rerun)"
      continue
    fi
    echo "guarded: $target (real: $(cat "$(realfile "$tool")"))"
    fi
    shim_tmp=$target.tmp.$$
    shim_var=JG_REPO_GUARD_IN_$(printf '%s' "$tool" | tr -c 'A-Za-z0-9\n' _)
    # The real tool is often a wrapper that runs "gh" by name (mise x gh -- gh); with the shim first on PATH that finds the shim again and loops for ever.
    # So the shim marks its call chain, and a second entry in one chain runs the first other copy on PATH by its full path, or refuses; it never enters the guard again.
    # shellcheck disable=SC2016 # The shim expands these variables when it runs, not now.
    printf '%s\n' '#!/usr/bin/env bash' "# $GUARD" \
      "if [ -n \"\${$shim_var:-}\" ]; then" \
      '  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) rest=' \
      '  IFS=: read -ra dirs <<<"$PATH"' \
      '  for dir in "${dirs[@]}"; do [ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$self" ] || rest=${rest:+$rest:}$dir; done' \
      "  real=\$(PATH=\$rest command -v $tool) || { echo 'repo-guard: refused: $tool called itself and no other $tool is on PATH' >&2; exit 1; }" \
      '  PATH=$rest exec "$real" "$@"' \
      'fi' \
      "export $shim_var=1" \
      "exec $(printf '%q' "$RUNNER") $tool \"\$@\"" >"$shim_tmp"
    chmod 755 "$shim_tmp"
    mv -f -- "$shim_tmp" "$target"
  fi
done
if [ "$DRY" = 1 ]; then
  echo "would write: $GUARD, $ALLOW, $HOOK"; echo 'dry run: nothing written'
  exit 0
fi
[ -f "$ALLOW" ] || install -m 644 "$SRC/allowed-repos" "$ALLOW"
printf '#!/usr/bin/env bash\nexec %q pre-push "$@"\n' "$RUNNER" >"$HOOK"
chmod 755 "$HOOK"
echo "installed: $GUARD; pre-push extension at $HOOK"; echo "allow-list: $ALLOW"
