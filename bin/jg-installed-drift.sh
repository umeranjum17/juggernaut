#!/usr/bin/env bash
# jg-installed-drift.sh - prove every installed runtime copy still matches the repo copy it came from.
#
# An feature installs into ${XDG_DATA_HOME:-~/.local/share}/<product>-<feature> and runs from there, so a repo
# fix never reaches the running copy by itself and a retired file can keep running for days. This check
# compares every regular file of every installed copy with its repo counterpart.
#
# Usage: jg-installed-drift.sh [--all] [--root DIR] [--data-home DIR]
#        jg-installed-drift.sh arm | disarm
#
# Output: one line per finding, and nothing at all when every copy matches. The exit is 0 even with findings,
# because this is a watcher check, not a gate, and the check never repairs or deletes a copy.
#   differ <installed path> <repo path>   the installed file and its repo counterpart hold different content
#
# Only differing content is drift. An installed copy also holds files the package installer creates at runtime
# (prev-hooks-path, link-target, upstream, *.real, hooks.d copies, identity.gitconfig) and some directories under
# the prefix are data, not installs (jg-beads, fm-claude-quota, fm-glm-queue, jg-nm-drain, backups). Neither has
# a repo counterpart to differ from, so a file with no counterpart and a directory with no discoverable repo
# directory are skipped silently rather than reported.
#
# Origin of a copy, first match that names an existing directory wins: <copy>/.jg-origin, whose first line is
# the repo directory the copy was installed from, else <root>/core/<name>, where <name> is the copy's
# directory name without its fm- or jg prefix. The repo counterpart of an installed file is that file's path
# inside the repo directory, or the only file of the same basename anywhere under it. A copy also grows Python
# bytecode, `*.bak-*` backups, the git scaffolding its own `git init` writes under `hooks/`, its runtime
# `state/`, and its own `home` and `unit.*` records; those are not compared.
#
# Legacy copies: an fm-<x> copy whose jg-<x> twin is installed in the same prefix is legacy (the twin is what
# runs), so its findings are not printed by default; --all prints them. An fm-<x> copy with no jg-<x> twin is
# not legacy and stays in the default output. Nothing is deleted either way.
#
# JG_HOME and JG_STATE_OVERRIDE name the home and its state directory, XDG_DATA_HOME names the install prefix,
# and --root or --data-home override the repo root and that prefix. arm writes state/installed-drift.check.sh
# and binds it with jg-check-register.sh; disarm retires it with jg-check-unregister.sh.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$REPO_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
ROOT=$REPO_ROOT
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
ALL=0

die() { printf 'jg-installed-drift: %s\n' "$1" >&2; exit "${2:-1}"; }

origin() { # origin <copy> <name>: print the repo directory this installed copy came from.
  local src
  src=$(sed -n '1p' "$1/.jg-origin" 2>/dev/null)
  [ -d "${src:-/nonexistent}" ] || src=$ROOT/core/$2
  [ -d "$src" ] && printf '%s\n' "$src"
}

counterpart() { # counterpart <repo dir> <relative path>: print the repo file, or nothing.
  local src=$1 rel=$2 hits
  [ -f "$src/$rel" ] && { printf '%s\n' "$src/$rel"; return 0; }
  hits=$(find "$src" -type f -name "${rel##*/}" 2>/dev/null)
  [ -n "$hits" ] && [ "$(printf '%s\n' "$hits" | wc -l)" -eq 1 ] && printf '%s\n' "$hits"
}

scan_copy() { # scan_copy <installed copy> <name-with-prefix>: print one line per finding in this copy.
  local copy=$1 name=${2#??-} src rel repo
  src=$(origin "$copy" "$name") || return 0
  while IFS= read -r -d '' f; do
    rel=${f#"$copy"/}
    case $rel in __pycache__/* | *.pyc | *.bak-* | hooks/* | state/* | home | unit.*) continue ;; esac
    repo=$(counterpart "$src" "$rel") || continue
    cmp -s "$f" "$repo" || printf 'differ %s %s\n' "$f" "$repo"
  done < <(find "$copy" -type f -print0 2>/dev/null)
}

cmd_check() {
  local d
  for d in "$DATA_HOME"/fm-* "$DATA_HOME"/jg-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ "$ALL" = 1 ] || [ "${d##*/}" = "${d##*/fm-}" ] || [ ! -d "$DATA_HOME/jg-${d##*/fm-}" ] || continue
    scan_copy "$d" "${d##*/}"
  done
  return 0
}

cmd_arm() {
  local shim=$STATE/installed-drift.check.sh tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  tmp=$(umask 077; mktemp "$STATE/.jg-installed-drift.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q\n' "$JG_HOME" "$SCRIPT_DIR/jg-installed-drift.sh" >"$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" installed-drift >/dev/null || die "cannot register the check"
  printf 'armed: installed-drift\n'
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --all) ALL=1; shift ;;
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --data-home) DATA_HOME=${2:?--data-home needs a directory}; shift 2 ;;
    arm | check) CMD=$1; shift ;;
    disarm) CMD=disarm; shift ;;
    *) die "unknown argument: $1 (see the header comment)" 2 ;;
  esac
done
case ${CMD:-check} in
  check) cmd_check ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" installed-drift ;;
esac
