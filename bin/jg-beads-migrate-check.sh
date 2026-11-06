#!/usr/bin/env bash
# jg-beads-migrate-check.sh - dry-run the Beads migration on copies of every home.
#
# Usage: jg-beads-migrate-check.sh --main <main home> --bd <pinned bd> --dolt <pinned dolt> --scratch <dir>
#
# Copies the board feed and each home's backlog and archive into a new folder under
# <dir>, builds the import files with bin/jg-beads-migrate.py, then imports one store
# per home and compares its export and `bd count` with the manifest. It stops at the
# first home that differs, and exits 0 only when every home matches and every held row
# is accounted for, printing the post-collapse counts per home. The folder is kept.
#
# Nothing here is the live move. bd runs only through bin/jg-beads.sh, which owns the pin,
# the metrics and shared-server guards and the store's place outside any git tree, inside
# a jail where the run folder is the one writable path and the network is gone.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "jg-beads-migrate-check: $*" >&2; exit 1; }
usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MAIN='' BD='' DOLT='' SCRATCH=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --main) MAIN=${2:-}; shift 2 ;;
    --bd) BD=${2:-}; shift 2 ;;
    --dolt) DOLT=${2:-}; shift 2 ;;
    --scratch) SCRATCH=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MAIN" ] && [ -n "$BD" ] && [ -n "$DOLT" ] && [ -n "$SCRATCH" ] || die "--main, --bd, --dolt and --scratch are required"
[ -z "${BEADS_DOLT_SHARED_SERVER:-}" ] || die "BEADS_DOLT_SHARED_SERVER is set; a shared server is banned"
[ -f "$BD" ] || die "no bd at $BD"
[ -f "$DOLT" ] || die "no dolt at $DOLT"
command -v bwrap >/dev/null || die "bwrap is required"
mkdir -p "$SCRATCH"
SCRATCH=$(cd "$SCRATCH" && pwd)
dir=$SCRATCH
while [ "$dir" != / ]; do
  [ ! -e "$dir/.git" ] || die "scratch is inside the git tree at $dir"
  dir=$(dirname "$dir")
done

RUN=$(mktemp -d "$SCRATCH/run.XXXXXX")
BD=$(realpath "$BD")
DOLT=$(realpath "$DOLT")
mkdir -p "$RUN/runs"
python3 "$HERE/jg-beads-migrate.py" copy --main "$MAIN" --to "$RUN/copy"
python3 "$HERE/jg-beads-migrate.py" plan --copy "$RUN/copy" --out "$RUN/imp"

in_store() { # <store parent> <wrapper args...>: one wrapper call, jailed; each store has its own parent.
  local store=$1
  shift
  bwrap --ro-bind / / --bind "$RUN" "$RUN" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent \
    env -i PATH=/usr/bin:/bin HOME="$HOME" BEADS_DIR="$store/.beads" BEADS_ACTOR=migrate-check JG_BEADS_BD="$BD" JG_BEADS_DOLT="$DOLT" \
    "$HERE/jg-beads.sh" "$@"
}

for file in "$RUN"/imp/*.jsonl; do
  home=$(basename "$file" .jsonl)
  store=$RUN/stores/$home
  mkdir -p "$store"
  in_store "$store" init --prefix jg >/dev/null
  in_store "$store" config set status.custom on_hold:frozen >/dev/null
  in_store "$store" config set allowed_prefixes "$(cat "$RUN/imp/$home.prefixes")" >/dev/null 2>&1
  in_store "$store" import "$file" >"$RUN/runs/$home.import.log" 2>&1 || die "$home: import failed, see $RUN/runs/$home.import.log"
  in_store "$store" export -o export.jsonl >/dev/null
  mv "$store/export.jsonl" "$RUN/runs/$home.export.jsonl"
  for status in open in_progress on_hold closed; do
    printf '%s %s\n' "$status" "$(in_store "$store" count --status "$status")"
  done >"$RUN/runs/$home.counts"
  python3 "$HERE/jg-beads-migrate.py" verify --copy "$RUN/copy" --out "$RUN/imp" --runs "$RUN/runs" --home "$home" || die "$home: store differs from the manifest"
done
python3 "$HERE/jg-beads-migrate.py" verify --copy "$RUN/copy" --out "$RUN/imp" --runs "$RUN/runs" || die "the copy and the manifest differ"
echo "dry run passed: $RUN"
