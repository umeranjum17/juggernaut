#!/usr/bin/env bash
# Install or update the owner-details guard: copy owner-guard to
# ${XDG_DATA_HOME:-~/.local/share}/jg-owner-guard, record the home, keep the
# home's config/owner-details-patterns private (mode 600, never created
# and never overwritten), chain pre-commit and pre-push through the
# git-identity hooks dir, and point the user's global core.hooksPath at the
# guard's own hooks dir so plain-shell commits and pushes are checked too
# (every wrapper then chains the previous global hooks dir and the
# repository's own hook), and wire the guard's merge scan into the home's
# single config/merge-gate entry point (addons/lib/merge-gate-lib.sh owns that
# file), where it runs first, before the owner-rules proof gate and the home's
# own previous gate. Idempotent; never touches repo-local core.hooksPath.
# Usage: wiring.sh [--dry-run] <jg-home> | wiring.sh [--dry-run] --uninstall
# [<jg-home>] (the home defaults to the recorded one).
set -euo pipefail
DRY=0 UNINST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --dry-run) DRY=1; shift ;;
  --uninstall) UNINST=1; shift ;;
  *) break ;;
  esac
done
if [ "$UNINST" -eq 0 ]; then
  [ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: wiring.sh [--dry-run] <jg-home> | wiring.sh [--dry-run] --uninstall [<jg-home>]" >&2; exit 2; }
  FMH=$(cd "$1" && pwd -P)
elif [ "$#" -gt 1 ]; then
  echo "usage: wiring.sh [--dry-run] <jg-home> | wiring.sh [--dry-run] --uninstall [<jg-home>]" >&2; exit 2
fi
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/merge-gate-lib.sh
. "$SRC/../lib/merge-gate-lib.sh"
GUARD=$(jgmg_guard_bin)
DEST=${GUARD%/*}
GDEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-git-identity
GHOOKS=$DEST/hooks
PREVF=$DEST/prev-hooks-path
# The client-side hook names git-identity chains, plus the server-side names
# a global hooksPath would otherwise hide: this dir becomes the hooks dir git
# consults, so a missing name would skip the repo's own hook.
HOOK_NAMES='applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg
post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc sendemail-validate
pre-receive update post-receive post-update push-to-checkout proc-receive reference-transaction post-index-change'
CURGLOBAL=$(git config --global --get --type=path core.hooksPath 2>/dev/null || true)
if [ "$UNINST" -eq 1 ]; then
  FMH=${1:-$(cat "$DEST/home" 2>/dev/null || true)}
fi
MG=$(jgmg_gate "$FMH")
# The hooks run under whatever PATH git's caller has, so the installed copies
# carry absolute paths resolved here, at install time: a ref update under a
# PATH with no bash used to fail on "env: bash: No such file or directory".
abs_tool() { # abs_tool <name>: set ABS to the installed tool's absolute path, or fail naming it.
  ABS=$(command -v "$1" 2>/dev/null || true)
  [ -n "$ABS" ] && [ -x "$ABS" ] || { echo "error: $1 is not installed; install it, then rerun" >&2; exit 1; }
}

install_global() { # Write one wrapper per hook name; adopt the global hooksPath, keeping the old value chained.
  mkdir -p "$GHOOKS"
  # shellcheck disable=SC2086
  for name in $HOOK_NAMES; do
    sed -e "s/__NAME__/$name/g" -e "1s|^#!.*|#!$BASH_BIN|" -e "s|__CAT__|$CAT_BIN|g" -e "s|__MKTEMP__|$MKTEMP_BIN|g" -e "s|__RM__|$RM_BIN|g" "$SRC/global-hook.sh" >"$GHOOKS/$name"
    chmod 755 "$GHOOKS/$name"
  done
  if [ "$CURGLOBAL" = "$GHOOKS" ]; then
    echo "kept: global core.hooksPath already $GHOOKS"
  else
    if [ -n "$CURGLOBAL" ]; then
      printf '%s\n' "$CURGLOBAL" >"$PREVF"
      echo "kept: previous global core.hooksPath recorded ($CURGLOBAL)"
    else
      rm -f "$PREVF"
    fi
    git config --global core.hooksPath "$GHOOKS"
    echo "installed: global core.hooksPath=$GHOOKS"
  fi
}

install_merge_gate() { # Wire the owner-details merge scan into the home's single merge gate.
  jgmg_install "$FMH" guard "$GUARD"
}

uninstall_merge_gate() { # Drop our step; the last feature out gives the home its own gate back.
  if [ -z "$FMH" ] || ! jgmg_owned "$FMH"; then
    echo "kept: ${FMH:+$MG }merge gate is not ours; leaving it"
  else
    jgmg_remove "$FMH" guard
  fi
}

uninstall_global() { # Drop our wrappers; give the global hooksPath back to the recorded previous value.
  if [ "$CURGLOBAL" = "$GHOOKS" ]; then
    if [ -s "$PREVF" ]; then
      git config --global core.hooksPath "$(cat "$PREVF")"
      echo "restored: global core.hooksPath=$(cat "$PREVF")"
    else
      git config --global --unset core.hooksPath
      echo "restored: global core.hooksPath unset (nothing before)"
    fi
  else
    echo "kept: global core.hooksPath is not ours (${CURGLOBAL:-unset}); leaving it"
  fi
  # shellcheck disable=SC2086
  for name in $HOOK_NAMES; do rm -f "$GHOOKS/$name"; done
  rmdir "$GHOOKS" 2>/dev/null || true
  rm -f "$PREVF"
  echo "uninstalled: global guard hooks removed"
}

if [ "$UNINST" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
  if [ "$CURGLOBAL" = "$GHOOKS" ]; then
    if [ -s "$PREVF" ]; then
      echo "would restore: global core.hooksPath to $(cat "$PREVF")"
    else
      echo "would unset: global core.hooksPath (nothing before)"
    fi
  else
    echo "would keep: global core.hooksPath (${CURGLOBAL:-unset}, not ours)"
  fi
    echo "would remove: $GHOOKS/<name> wrappers and $PREVF"
    if [ -n "$FMH" ]; then jgmg_dry_run_remove "$FMH"; else echo "would keep: merge gate (no home recorded)"; fi
    echo "dry run: nothing written"
    exit 0
  fi
  uninstall_global
  uninstall_merge_gate
  exit 0
fi
BASH_BIN=$(command -v bash 2>/dev/null || true)
[ -x "$BASH_BIN" ] || BASH_BIN=/bin/bash
abs_tool cat; CAT_BIN=$ABS
abs_tool mktemp; MKTEMP_BIN=$ABS
abs_tool rm; RM_BIN=$ABS
PAT=$FMH/config/owner-details-patterns
REC=$(cat "$DEST/home" 2>/dev/null || true)
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/owner-guard -> $GUARD"
  [ -e "$PAT" ] || echo "would skip: $PAT is missing (the installer never creates it)"
  if [ ! -s "$PAT" ] && [ -n "$REC" ] && [ -s "$REC/config/owner-details-patterns" ]; then
    echo "would keep: $DEST/home (it already names a home with a patterns file this home lacks)"
  else
    echo "would write: $DEST/home ($FMH)"
  fi
  echo "would write: $GDEST/hooks.d/pre-commit/owner-guard $GDEST/hooks.d/pre-push/owner-guard"
  echo "would write: $GHOOKS/<name>, one wrapper each: $HOOK_NAMES"
  echo "would set: global core.hooksPath=$GHOOKS (previous: ${CURGLOBAL:-none})"
  jgmg_dry_run "$FMH"
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST"
sed "1s|.*|#!$BASH_BIN|" "$SRC/owner-guard" >"$GUARD"
chmod 755 "$GUARD"
if [ -e "$PAT" ]; then
  chmod 600 "$PAT"
else
  echo "note: $PAT is missing; leaving it for the owner to create (one extended regex per line, mode 600)"
fi
if [ ! -s "$PAT" ] && [ -n "$REC" ] && [ -s "$REC/config/owner-details-patterns" ]; then
  echo "kept recorded patterns home: $FMH has no patterns file"
else
  printf '%s\n' "$FMH" >"$DEST/home"
fi
mkdir -p "$GDEST/hooks.d/pre-commit" "$GDEST/hooks.d/pre-push"
for name in pre-commit pre-push; do
  printf '#!%s\nexec %q %s "$@"\n' "$BASH_BIN" "$GUARD" "$name" >"$GDEST/hooks.d/$name/owner-guard"
  chmod 755 "$GDEST/hooks.d/$name/owner-guard"
done
[ -d "$GDEST/hooks" ] || echo "note: $GDEST/hooks is missing (git-identity not installed); chaining activates when it installs"
echo "installed: $GUARD chained into $GDEST/hooks.d (patterns: $PAT)"
install_global
install_merge_gate
