#!/usr/bin/env bash
# jg-install-pre-push.sh - install the pre-push hook that runs bin/jg-pre-push.sh
# (ShellCheck and the fast changed tests on the files a push changes).
#
#   jg-install-pre-push.sh              install into this repository's shared hooks directory
#   jg-install-pre-push.sh --uninstall  remove the hook this script installed
#   jg-install-pre-push.sh --force      replace a pre-push hook this script did not install
#                                       (the old one is kept as pre-push.pre-jg)
#   jg-install-pre-push.sh --help
#
# The hook is a few lines in <git-common-dir>/hooks/pre-push, so every linked
# worktree of the repository shares one install. It finds bin/jg-pre-push.sh in
# the work tree being pushed from, and does nothing when that tree has none, so
# a checkout from before the check existed is unaffected. Rerunning is safe.
#
# A hook this script did not write is never overwritten without --force.
# core.hooksPath is never changed: when it points elsewhere, git runs hooks from
# there, so this prints a warning and the directory it names must chain
# <git-common-dir>/hooks/pre-push (the owner-guard global hook does).
# `git push --no-verify` skips the hook for one push; CI still runs everything.
#
# Exit 0 on success, 1 when it refused or failed, 2 on bad usage.
set -u

MARK='# jg-pre-push-hook: managed by bin/jg-install-pre-push.sh'
say() { printf 'jg-install-pre-push: %s\n' "$*" >&2; }

ACTION=install FORCE=0
for arg in "$@"; do
  case $arg in
    -h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    --uninstall) ACTION=uninstall ;;
    --force) FORCE=1 ;;
    *) say "unknown argument: $arg"; exit 2 ;;
  esac
done

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
common=$(git -C "$SELF_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { say "not inside a git repository"; exit 1; }
hook_dir=$common/hooks
hook=$hook_dir/pre-push

if [ "$ACTION" = uninstall ]; then
  if [ ! -e "$hook" ]; then
    say "no pre-push hook to remove"
    exit 0
  fi
  grep -qF "$MARK" "$hook" 2>/dev/null || { say "$hook was not installed by this script; leaving it"; exit 1; }
  rm -f -- "$hook" || { say "could not remove $hook"; exit 1; }
  [ ! -e "$hook.pre-jg" ] || { mv -- "$hook.pre-jg" "$hook" && say "restored the previous hook from pre-push.pre-jg"; }
  say "removed $hook"
  exit 0
fi

if [ -e "$hook" ] && ! grep -qF "$MARK" "$hook" 2>/dev/null; then
  if [ "$FORCE" -ne 1 ]; then
    say "$hook exists and was not installed by this script; rerun with --force to replace it (it is kept as pre-push.pre-jg)"
    exit 1
  fi
  mv -- "$hook" "$hook.pre-jg" || { say "could not keep the old hook"; exit 1; }
  say "kept the old hook as $hook.pre-jg"
fi

mkdir -p "$hook_dir" || { say "could not create $hook_dir"; exit 1; }
tmp=$(mktemp "$hook_dir/.pre-push.XXXXXX") || { say "could not write in $hook_dir"; exit 1; }
cat >"$tmp" <<HOOK
#!/bin/sh
$MARK
# Runs bin/jg-pre-push.sh of the work tree being pushed from; git's stdin is kept.
top=\$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -x "\$top/bin/jg-pre-push.sh" ] || exit 0
exec "\$top/bin/jg-pre-push.sh" "\$@"
HOOK
if ! { chmod +x "$tmp" && mv -f -- "$tmp" "$hook"; }; then
  rm -f -- "$tmp"
  say "could not install $hook"
  exit 1
fi
say "installed $hook"

hooks_path=$(git -C "$SELF_DIR" config --get core.hooksPath 2>/dev/null || true)
if [ -n "$hooks_path" ]; then
  say "warning: core.hooksPath is $hooks_path, so git runs hooks from there; its pre-push must chain $hook for the check to run"
fi
exit 0
