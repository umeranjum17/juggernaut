#!/usr/bin/env bash
# jg-retired-catalog-check.sh - the gate that keeps the retired bolt-on catalog retired.
#
# The add-ons were a second product: a catalog directory, one installer per feature and a
# separate repository. They are part of the core now (core/<feature>/), and this check is what
# makes that stick rather than being a one-time cleanup: nothing may be added back under the
# retired directory, and a tracked path there is refused outright.
#
# Usage:
#   jg-retired-catalog-check.sh                  # the whole tracked tree
#   jg-retired-catalog-check.sh --base <ref>     # only paths this change adds, against <ref>
#   jg-retired-catalog-check.sh --root <dir>     # check another checkout
#   jg-retired-catalog-check.sh --self-test      # prove the gate still refuses a fixture file
#
# --base is what a pull request gate uses: `--base origin/main` (or the merge base the forge
# reports) refuses a new file under a retired root even when the rest of the tree is clean.
# The whole-tree scan is the release gate: it refuses any tracked path there at all.
#
# Exit status: 0 when nothing retired is present or added, 1 with one line per offending path,
# 2 on a usage or environment error.
set -eu

RETIRED=(addons)
# Slice B of the one-repo fold is deferred: the catalog's images are design surface, so they stay under
# the retired directory until that slice moves the ten project images and deletes the two catalog logos.
# This list may only shrink, and slice B deletes it with that move. Nothing outside it may appear under
# a retired root.
DEFERRED=(
  addons/docs/media/logo-dark.svg
  addons/docs/media/logo-light.svg
  addons/tickets-sync/icons/byokit.svg
  addons/tickets-sync/icons/desklink.svg
  addons/tickets-sync/icons/done-done.svg
  addons/tickets-sync/icons/first-draft.svg
  addons/tickets-sync/icons/herdr-runtime.svg
  addons/tickets-sync/icons/juggernaut-addons.svg
  addons/tickets-sync/icons/juggernaut.svg
  addons/tickets-sync/icons/learn-from-mistakes.svg
  addons/tickets-sync/icons/muxr-cloud.svg
  addons/tickets-sync/icons/sign-off.svg
)
ROOT='' base='' self_test=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --base) base=${2:?--base needs a ref}; shift 2 ;;
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'jg-retired-catalog-check: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}

retired_path() {  # retired_path <path>: 0 when <path> sits under a retired root and is not deferred
  local p=${1#./} r d
  for d in "${DEFERRED[@]}"; do [ "$p" = "$d" ] && return 1; done
  for r in "${RETIRED[@]}"; do
    case $p in "$r" | "$r"/*) return 0 ;; esac
  done
  return 1
}

scan_tree() {
  local p found=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    retired_path "$p" || continue
    printf 'retired path: %s\n' "$p"
    found=1
  done < <(git -C "$ROOT" ls-files)
  return "$found"
}

scan_added() {
  local p found=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    retired_path "$p" || continue
    printf 'retired path: %s (added by this change)\n' "$p"
    found=1
  done < <(git -C "$ROOT" diff --diff-filter=A --name-only "$base"...HEAD)
  return "$found"
}

if [ "$self_test" = 1 ]; then
  d=$(mktemp -d "${TMPDIR:-/tmp}/jg-retired-check.XXXXXX")
  trap 'rm -rf -- "$d"' EXIT
  git -C "$d" init -q
  git -C "$d" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q --allow-empty -m base
  git -C "$d" branch -q -m main
  git -C "$d" checkout -q -b candidate
  mkdir -p "$d/addons/fixture"
  : >"$d/addons/fixture/install.sh"
  git -C "$d" add -A
  git -C "$d" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q -m 'add a retired path'
  out=$(bash "$0" --root "$d" --base main 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || { printf 'self-test: a new file under addons/ was not refused (exit %s)\n%s\n' "$rc" "$out" >&2; exit 1; }
  case $out in *'retired path: addons/fixture/install.sh'*) ;; *) printf 'self-test: the refusal did not name the path:\n%s\n' "$out" >&2; exit 1 ;; esac
  out=$(bash "$0" --root "$d" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || { printf 'self-test: the whole-tree scan missed a tracked retired path (exit %s)\n%s\n' "$rc" "$out" >&2; exit 1; }
  # A clean base passes both scans.
  d2=$(mktemp -d "${TMPDIR:-/tmp}/jg-retired-check-clean.XXXXXX")
  git -C "$d2" init -q
  mkdir -p "$d2/core/kill-guard"
  : >"$d2/core/kill-guard/README.md"
  git -C "$d2" add -A
  git -C "$d2" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q -m base
  out=$(bash "$0" --root "$d2" 2>&1) || { printf 'self-test: a clean tree was refused:\n%s\n' "$out" >&2; exit 1; }
  printf 'ok - a new file under addons/ is refused by name, and a clean tree passes\n'
  exit 0
fi

if [ -n "$base" ]; then
  git -C "$ROOT" rev-parse --verify --quiet "$base" >/dev/null || { printf 'jg-retired-catalog-check: unknown ref %s\n' "$base" >&2; exit 2; }
  scan_added || exit 1
else
  scan_tree || exit 1
fi
exit 0
