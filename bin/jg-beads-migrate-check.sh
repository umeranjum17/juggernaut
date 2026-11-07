#!/usr/bin/env bash
# jg-beads-migrate-check.sh - dry-run the Beads migration on copies of every home.
#
# Usage: jg-beads-migrate-check.sh --main <main home> --bd <pinned bd> --dolt <pinned dolt> --scratch <dir> [--rehearse <home>]
#
# Copies the board feed and each home's backlog and archive into a new folder under
# <dir>, builds the import files with bin/jg-beads-migrate.py, then imports one store
# per home and compares its export and `bd count` with the manifest. It stops at the
# first home that differs, and exits 0 only when every home matches and every held row
# is accounted for, printing the post-collapse counts per home. The folder is kept.
#
# --rehearse then cuts a throwaway copy of that home's files under the run folder, with the
# tool the real cut uses. It proves the cut, its refusals, every row and closed row read
# back, an old name finding its row, the old files refusing a write, a clean way back, a
# second cut, a way back that names a new row, and the old path working again.
#
# Nothing here is the live move. bd runs only through bin/jg-beads.sh, which owns the pin,
# the metrics and shared-server guards and the store's place outside any git tree, inside
# a jail where the run folder is the one writable path and the network is gone.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "jg-beads-migrate-check: $*" >&2; exit 1; }
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MAIN='' BD='' DOLT='' SCRATCH='' REHEARSE=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --main) MAIN=${2:-}; shift 2 ;;
    --bd) BD=${2:-}; shift 2 ;;
    --dolt) DOLT=${2:-}; shift 2 ;;
    --scratch) SCRATCH=${2:-}; shift 2 ;;
    --rehearse) REHEARSE=${2:-}; shift 2 ;;
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
mkdir -p "$RUN/runs" "$RUN/tmp"
python3 "$HERE/jg-beads-migrate.py" copy --main "$MAIN" --to "$RUN/copy"
python3 "$HERE/jg-beads-migrate.py" plan --copy "$RUN/copy" --out "$RUN/imp"

TOOLS=/usr/bin:/bin
jailed() { # <command...>: the run folder is the one writable path and the network is gone.
  bwrap --ro-bind / / --bind "$RUN" "$RUN" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent \
    env -i PATH="$TOOLS" HOME="$HOME" TMPDIR="$RUN/tmp" BEADS_ACTOR=migrate-check JG_BEADS_BD="$BD" JG_BEADS_DOLT="$DOLT" "$@"
}
in_store() { # <store parent> <wrapper args...>: one wrapper call, jailed; each store has its own parent.
  local store=$1
  shift
  jailed BEADS_DIR="$store/.beads" "$HERE/jg-beads.sh" "$@"
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
  for status in open in_progress on_hold deferred closed; do
    printf '%s %s\n' "$status" "$(in_store "$store" count --status "$status")"
  done >"$RUN/runs/$home.counts"
  python3 "$HERE/jg-beads-migrate.py" verify --copy "$RUN/copy" --out "$RUN/imp" --runs "$RUN/runs" --home "$home" || die "$home: store differs from the manifest"
done
python3 "$HERE/jg-beads-migrate.py" verify --copy "$RUN/copy" --out "$RUN/imp" --runs "$RUN/runs" || die "the copy and the manifest differ"
echo "dry run passed: $RUN"
[ -n "$REHEARSE" ] || exit 0

H=$REHEARSE HOME_COPY=$RUN/rehearse/$REHEARSE
[ -d "$RUN/copy/homes/$H" ] || die "$H: no such home in the copy"
mkdir -p "$HOME_COPY/data" "$HOME_COPY/config"
cp -p "$RUN"/copy/homes/"$H"/* "$HOME_COPY/data/"
migrate() { jailed python3 "$HERE/jg-beads-migrate.py" "$@"; }
axi() { jailed JG_HOME="$HOME_COPY" "$HERE/jg-backlog.sh" "$@"; }
cut_home() { migrate cut --home "$H" --dir "$HOME_COPY" --copy "$RUN/copy" --out "$RUN/imp" --store "$RUN/rehearse/store-$1/.beads" --order "${2-rehearsal on a throwaway copy}"; }
go_back() { migrate back --dir "$HOME_COPY" "$@"; }
says() { # <text> <command...>: the command fails and its output carries the text.
  local want=$1 out
  shift
  ! out=$("$@" 2>&1) && [[ $out == *"$want"* ]]
}
files() { (cd "$HOME_COPY" && find data config -type f ! -name 'beads-*' -printf '%m %p ' -exec sha256sum {} \; | sort); }
pick() { # <status>: one planned row's old slug with nothing blocking it, for an old name to find.
  python3 -c 'import json,sys
for r in map(json.loads, open(sys.argv[1])):
    if r["metadata"].get("legacy_item") and r["status"] == sys.argv[2] and not r.get("dependencies"): print(r["metadata"]["legacy_item"]); break' "$RUN/imp/$H.jsonl" "$1"
}
rows=$(wc -l <"$RUN/imp/$H.jsonl")
before=$(files)

says '--order' cut_home 1 '' || die "a cut with no order ran"
[ "$(files)" = "$before" ] || die "a refused cut changed the home"
cut_home 1 >/dev/null || die "the cut failed"
cut_home 1 | grep -q 'already cut' || die "a second cut did not converge"
[ -s "$HOME_COPY/config/beads-dir" ] || die "the store did not switch"
[ "$(axi list | sed -n 's/^count: //p' | cut -d' ' -f1)" = "$rows" ] || die "the provider does not read $rows rows"
for f in "$HOME_COPY"/data/backlog.md "$HOME_COPY"/data/done-archive.md; do
  [ ! -e "$f" ] || [ -z "$(find "$f" -perm /222)" ] || die "$f is still writable"
done
closed=$(pick closed)
[ -z "$closed" ] || [[ "$(axi show "$closed")" == *'state: done'* ]] || die "closed row $closed does not read by its old name"
go_back >/dev/null || die "the clean way back failed"
[ "$(files)" = "$before" ] || die "the way back did not restore the home byte for byte"

cut_home 2 >/dev/null || die "the second cut failed"
open=$(pick open)
[ -z "$open" ] || axi start "$open" >/dev/null || die "open row $open does not move by its old name"
axi add rehearsal-row '[feature] Rehearsal row' --body 'Proves a row written after the cut' --priority 2 >/dev/null || die "the store refused a write"
says rehearsal-row go_back || die "the way back did not name the new row"
[ -s "$HOME_COPY/config/beads-dir" ] || die "a refused way back moved the home"
go_back --drop-new-writes >/dev/null || die "the way back with new rows failed"
[ "$(files)" = "$before" ] || die "the way back with new rows did not restore the home"
grep -q rehearsal-row "$HOME_COPY"/data/beads-after-cut.*.jsonl || die "the new row was not saved"
echo "rehearsal passed: $H, $rows rows, $RUN/rehearse"
