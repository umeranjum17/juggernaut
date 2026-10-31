#!/usr/bin/env bash
# jg-release-record.sh - record what version each registered project has actually
# released, so a report can say which version is live, not merged-not-released.
#
# WHY. bin/jg-live-claim.sh owns the fixed-means-live rule and the release record
# format, and it accepts a `live: <ref> @ <where>` claim only when the record
# names <ref>. Nothing wrote that record, so every "fixed" report was downgraded
# even when the release was live. This script is the writer, reading public
# release metadata only: no token, no key, no publish, no version bump.
#
# FORMAT. bin/jg-live-claim.sh's header owns it; this writer adds only what it
# tolerates, the project name in the second field and a `# none <project>` line.
#
# THE REF, per registered project in data/projects.md:
#   - the npm version when the entry names the package it ships as (`npm <pkg>`,
#     last mention wins), because that is what an installed app runs;
#   - else the newest published forge release tag (`gh api .../releases`), drafts
#     skipped and prereleases kept, newest by published date - the method
#     data/deep-dive-no-outcomes/report.md section 3 used.
# A project with neither is recorded as having no release, never given a version
# this script invented, and a failed read keeps the line an earlier run recorded.
# The forge repository is the clone's origin remote, falling back to the
# owner/repo the registry entry names only when there is no clone here.
#
# MERGES SINCE. Per recorded release, the merged pull requests after its published
# date, from the forge search API - the count the report's section 3 quotes.
#
# USAGE: jg-release-record.sh (rewrite the record, print one RELEASE line per
# project, uses the network) or --help.
# OUTPUT: `RELEASE: sign-off 0.9.13 2026-10-31, 3 merges since`, or
# `RELEASE: juggernaut no release recorded`.
#
# RECORD. ${JG_DATA_OVERRIDE:-$JG_HOME/data}/releases, the same path and overrides
# bin/jg-live-claim.sh reads. bin/jg-startup-network.sh refreshes it in the
# deferred startup worker, off the blocking path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
PROJECTS="${JG_PROJECTS_OVERRIDE:-$JG_HOME/projects}"
REGISTRY="${JG_PROJECTS_REGISTRY:-$DATA/projects.md}"
releases="$DATA/releases"

die() { printf 'jg-release-record: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
  -h|--help)
    printf 'usage: jg-release-record.sh [--help]\n\nRewrite data/releases from public release metadata and print one RELEASE line per\nregistered project (network). The record format, and the rule that reads it:\nbin/jg-live-claim.sh header.\n'
    exit 0 ;;
  '') ;;
  *) die "unknown argument: $1 (try --help)" ;;
esac

command -v jq >/dev/null 2>&1 || die 'jq is required to read release metadata'
command -v gh >/dev/null 2>&1 || die 'gh is required to read the forge release list'

# One line per registered project, in registry order, from data/projects.md's own
# "- <name> [<posture>] - <text>" shape.
registry_projects() {
  sed -nE 's/^- (.+)$/\1/p' "$REGISTRY" | sed -E 's/ (\[| - ).*//'
}

registry_entry() {  # <project> -> its registry line, or nothing
  awk -v p="$1" 'substr($0, 1, length(p) + 3) == "- " p " " || $0 == "- " p { print; exit }' "$REGISTRY"
}

entry_repo() {  # <entry> -> owner/repo named by the entry, or nothing
  # The last parenthetical that names owner/repo, so an entry's earlier prose
  # parenthetical cannot win. A clone's origin is the primary source below;
  # this is only for a registered project with no clone here (fixtures, remote
  # projects).
  printf '%s\n' "$1" | grep -oE '\([^()]*[A-Za-z0-9._-]+/[A-Za-z0-9._-]+[^()]*\)' | tail -n 1 \
    | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' | tail -n 1
}

entry_npm_package() {  # <entry> -> the package named after "npm", or nothing
  # The last mention wins: an entry that says "ships to npm as <pkg>" before
  # naming the package must not resolve to the word after the first "npm".
  printf '%s\n' "$1" | grep -oE 'npm [@A-Za-z0-9._/-]+' | tail -n 1 | cut -d' ' -f2
}

clone_repo() {  # <project> -> owner/repo from its clone's origin, or nothing
  git -C "$PROJECTS/$1" remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##' \
    | sed -nE 's#.*[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$#\1#p'
}

npm_release() {  # <package> -> "<version>\t<published>", exit 1 when unreadable
  local out
# npm answers a bare object on some versions and a one-item array on others,
# so both shapes are accepted; the version and its publish time are all that is
# read, never a token, an install, or a publish.
  out=$(npm view "$1" --json 2>/dev/null \
    | jq -r '(if type == "array" then .[0] else . end) as $m
      | ($m.version // "") as $v | select($v != "")
      | [$v, ($m.time[$v] // "")] | @tsv' 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

forge_release() {  # <owner/repo> -> "<tag>\t<published>", exit 1 when unreadable
  local out
  out=$(gh api --method GET "repos/$1/releases" -f per_page=30 --jq '
    [.[] | select(.published_at != null and .tag_name != null)]
    | sort_by(.published_at) | last
    | if . == null then "" else [.tag_name, .published_at] | @tsv end' 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

merges_since() {  # <owner/repo> <since ISO8601> -> merged PR count, empty when unknown
  [ -n "$1" ] && [ -n "$2" ] && [ "$2" != '-' ] || return 0
  gh api --method GET search/issues \
    -f q="repo:$1 is:pr is:merged merged:>=$2" --jq .total_count 2>/dev/null
}

recorded_release() {  # <project> -> "<ref>\t<date>\t<source>" already in the record
  [ -r "$releases" ] || return 0
  awk -v p="$1" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    $2 == p { r = $1; d = ($3 == "" ? "-" : $3); s = ($4 == "" ? "recorded" : $4) }
    END { if (r != "") printf "%s\t%s\t%s\n", r, d, s }
  ' "$releases"
}

short_date() {  # <ISO8601> -> YYYY-MM-DD, or - when unknown
  case "${1:--}" in -|'') printf '%s' '-' ;; *) printf '%s' "${1%%T*}" ;; esac
}

if [ ! -r "$REGISTRY" ]; then
  printf 'RELEASE: no project registry at %s, nothing to record\n' "$REGISTRY"
  exit 0
fi

mkdir -p "$DATA" || die "cannot create the data directory $DATA"
d=$(mktemp -d "${TMPDIR:-/tmp}/jg-release-record.XXXXXX") || die 'cannot create a temp directory'
trap 'rm -rf -- "$d"' EXIT
new="$d/releases"

printf '%s\n' \
  '# jg-release-record.sh writes this file from public release metadata.' \
  '# The format, and the rule that reads it: bin/jg-live-claim.sh header.' \
  '# <ref> <project> <released-at ISO8601 UTC> <npm|forge-release>' > "$new"

while IFS= read -r proj; do
  [ -n "$proj" ] || continue
  entry=$(registry_entry "$proj")
  repo=$(clone_repo "$proj")
  [ -n "$repo" ] || repo=$(entry_repo "$entry")
  pkg=$(entry_npm_package "$entry")
  ref='' date='' source='' state=unknown

  if [ -n "$pkg" ] && command -v npm >/dev/null 2>&1; then
    if out=$(npm_release "$pkg"); then
      if [ -n "$out" ]; then
        IFS=$'\t' read -r ref date <<< "$out"
        source=npm state=found
      else
        state=none
      fi
    fi
  fi
  if [ "$state" != found ] && [ -n "$repo" ]; then
    if out=$(forge_release "$repo"); then
      if [ -n "$out" ]; then
        IFS=$'\t' read -r ref date <<< "$out"
        source=forge-release state=found
      else
        state=none
      fi
    fi
  fi

  if [ "$state" = found ]; then
    printf '%s %s %s %s\n' "$ref" "$proj" "$date" "$source" >> "$new"
    count=$(merges_since "$repo" "$date")
    if [ -n "$count" ]; then
      case "$count" in
        1) since_noun=merge ;;
        *) since_noun=merges ;;
      esac
      printf 'RELEASE: %s %s %s, %s %s since\n' \
        "$proj" "$ref" "$(short_date "$date")" "$count" "$since_noun"
    else
      printf 'RELEASE: %s %s %s, merges since unknown\n' "$proj" "$ref" "$(short_date "$date")"
    fi
    continue
  fi

  # No source answered with a release. Keep what an earlier run recorded rather
  # than erasing it, and say which of the two cases this is.
  old=$(recorded_release "$proj")
  if [ -n "$old" ]; then
    IFS=$'\t' read -r ref date source <<< "$old"
    printf '%s %s %s %s\n' "$ref" "$proj" "$date" "$source" >> "$new"
    printf 'RELEASE: %s %s %s, kept from the record; its release metadata could not be read now\n' \
      "$proj" "$ref" "$(short_date "$date")"
    continue
  fi
  printf '# none %s\n' "$proj" >> "$new"
  if [ "$state" = none ]; then
    printf 'RELEASE: %s no release recorded\n' "$proj"
  else
    printf 'RELEASE: %s no release recorded; its release metadata could not be read\n' "$proj"
  fi
done < <(registry_projects)

if [ -f "$releases" ] && cmp -s "$new" "$releases"; then
  exit 0
fi
mv -f "$new" "$releases" || die "cannot write $releases"
