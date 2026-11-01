#!/usr/bin/env bash
# jg-committed-binary-check.sh - the gate that keeps compiled binaries out of the tree.
#
# The captain channel's command is Go, and everything that runs it builds into the
# home's state directory (bin/jg-bus.sh), never into the repository. A plain
# `go build` under core/bus writes an executable beside its source, and two of
# those were committed by accident, so this check refuses any tracked ELF, Mach-O
# or PE file and names it. The "Repo invariants" CI job runs it, which is what
# makes the refusal a merge refusal rather than a review note.
#
# Usage:
#   jg-committed-binary-check.sh                  # the whole tracked tree
#   jg-committed-binary-check.sh --root <dir>     # check another checkout
#   jg-committed-binary-check.sh --self-test      # prove the gate refuses a planted binary
#
# Exit status: 0 when no tracked file is a compiled binary, 1 with one line per
# offending file, 2 on a usage or environment error.
set -eu

ROOT='' self_test=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'jg-committed-binary-check: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}

hex() { od -An -tx1 -N"${2:-4}" "$1" 2>/dev/null | tr -d ' \n'; }

binary_kind() {  # binary_kind <path>: print ELF, Mach-O, Mach-O fat or PE for a compiled binary
  local magic bytes off
  magic=$(hex "$1" 4) || magic=''
  case $magic in
    7f454c46) printf 'ELF' ;;
    feedface | feedfacf | cefaedfe | cffaedfe) printf 'Mach-O' ;;
    cafebabe | cafebabf)
      # A Java class file opens with the same four bytes; a Mach-O fat header holds
      # a small architecture count there instead, so only that is read as Mach-O.
      bytes=$(hex "$1" 8)
      if [ "${#bytes}" -eq 16 ] && [ "$((16#${bytes#????????}))" -le 8 ]; then printf 'Mach-O fat'; fi
      ;;
    bebafeca | bfbafeca) printf 'Mach-O fat' ;;
    4d5a*)
      # PE: the DOS stub's e_lfanew at offset 60 points at the "PE\0\0" signature.
      off=$(od -An -tu4 -j60 -N4 "$1" 2>/dev/null | tr -d ' ') || off=''
      if [ -n "$off" ] && [ "$off" -gt 0 ]; then
        bytes=$(tail -c +$((off + 1)) "$1" 2>/dev/null | od -An -tx1 -N4 | tr -d ' \n')
        if [ "$bytes" = 50450000 ]; then printf 'PE'; fi
      fi
      ;;
  esac
  return 0
}

scan_tree() {
  local p kind found=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$ROOT/$p" ] || continue
    kind=$(binary_kind "$ROOT/$p")
    [ -n "$kind" ] || continue
    printf 'committed binary: %s (%s)\n' "$p" "$kind"
    found=1
  done < <(git -C "$ROOT" ls-files)
  return "$found"
}

if [ "$self_test" = 1 ]; then
  d=$(mktemp -d "${TMPDIR:-/tmp}/jg-binary-check.XXXXXX")
  trap 'rm -rf -- "$d"' EXIT
  git -C "$d" init -q
  git -C "$d" config user.email fixture@example.invalid
  git -C "$d" config user.name Fixture
  printf 'not a binary\n' >"$d/README.md"
  printf '\177ELF\002\001\001\000' >"$d/planted-elf"
  printf '\316\372\355\376\007\000\000\000\000\000\000\000' >"$d/planted-macho"
  { printf 'MZ'; head -c 58 /dev/zero; printf '\100\000\000\000'; printf 'PE\000\000'; } >"$d/planted-pe"
  git -C "$d" add -A
  git -C "$d" commit -q -m 'plant three binaries'
  out=$(bash "$0" --root "$d" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || { printf 'self-test: planted binaries were not refused (exit %s)\n%s\n' "$rc" "$out" >&2; exit 1; }
  for want in 'committed binary: planted-elf (ELF)' 'committed binary: planted-macho (Mach-O)' 'committed binary: planted-pe (PE)'; do
    case $out in *"$want"*) ;; *) printf 'self-test: the refusal missed "%s":\n%s\n' "$want" "$out" >&2; exit 1 ;; esac
  done
  git -C "$d" rm -q planted-elf planted-macho planted-pe
  git -C "$d" commit -q -m 'remove them'
  out=$(bash "$0" --root "$d" 2>&1) || { printf 'self-test: a clean tree was refused:\n%s\n' "$out" >&2; exit 1; }
  printf 'ok - a planted ELF, Mach-O and PE are each refused by name, and a clean tree passes\n'
  exit 0
fi

scan_tree || exit 1
exit 0
