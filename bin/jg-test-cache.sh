#!/usr/bin/env bash
# jg-test-cache.sh - the one result cache of the behavior-test runner (H29f).
#
#   jg-test-cache.sh key <script>
#       Print the cache key of a script: a hash of the script's path, the content of every file its selection depends on, and
#       the tool versions of this host.
#   jg-test-cache.sh lookup <script> <output-file>
#       A green entry with the same key: copy the output it kept to <output-file>, print "hit <key>" and exit 0. Anything else
#       (no entry, an entry of another key) prints "miss <key>" and exits 1.
#   jg-test-cache.sh store <script> <duration-ms> <output-file>
#       Keep a green result and its output under the script's key. Only a green is ever kept, so a red is never reused: the
#       script runs again on the lane and a stale red cannot charge it.
#
# What the key holds. The files a script depends on are found by the map the selector (bin/jg-test-run.sh --changed) reads the
# other way round: a changed file selects the scripts that name it, so the files a script depends on are the repository files it
# names. A name is a file's basename, a repository path, or a repository directory written with a slash (every file under it). The map is followed
# through the shell files it finds for two more rounds, so a library the script sources through another file counts. The content
# hashed is the working tree's, so an uncommitted edit changes the key. A file the script reaches by a name it builds at run time
# is outside the map: the same limit the selector has.
#
# Where it lives. JG_TEST_CACHE_DIR, else <JG_HOME>/state/test-cache, else ${XDG_CACHE_HOME:-$HOME/.cache}/jg-test-cache: one
# folder per machine and home, so every lane, stack, verify and nightly run on it reads the same entries. A stale entry (a key
# input changed) is never found, because its key differs; it stays until `prune` is run on it.
#   jg-test-cache.sh prune [<days>]    remove entries not used in <days> days (default 14)
#
# JG_TEST_CACHE_ROOT names the repository the script path is relative to (default: the repository this file is in).
# JG_TEST_CACHE_FILELIST names a file holding the repository's file list; a runner passes one so it is listed once per run.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CACHE_ROOT=${JG_TEST_CACHE_ROOT:-$(cd "$SELF_DIR/.." && pwd -P)}

die() { echo "jg-test-cache: $*" >&2; exit 2; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

cache_dir() {
  if [ -n "${JG_TEST_CACHE_DIR:-}" ]; then printf '%s\n' "$JG_TEST_CACHE_DIR"
  elif [ -n "${JG_HOME:-}" ]; then printf '%s\n' "$JG_HOME/state/test-cache"
  else printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/jg-test-cache"
  fi
}

# The repository's files, tracked and not ignored, one per line.
file_list() {
  if [ -n "${JG_TEST_CACHE_FILELIST:-}" ] && [ -f "$JG_TEST_CACHE_FILELIST" ]; then
    cat -- "$JG_TEST_CACHE_FILELIST"
  else
    { git -C "$CACHE_ROOT" ls-files; git -C "$CACHE_ROOT" ls-files --others --exclude-standard; } 2>/dev/null | sort -u
  fi
}

# tool_versions: the first version line of each tool a test commonly runs, empty for a tool this host lacks.
tool_versions() {
  local t
  uname -sm
  for t in bash git jq python3 go shellcheck; do
    command -v "$t" >/dev/null 2>&1 || continue
    printf '%s: ' "$t"
    case "$t" in
      go) go version 2>&1 | head -n 1 ;;
      *) "$t" --version 2>&1 | head -n 1 ;;
    esac
  done
}

# resolve <filelist> <file>...: the repository files the given files name, one per line.
resolve() {
  local list=$1
  shift
  [ "$#" -gt 0 ] || return 0
  cat -- "$@" 2>/dev/null | grep -aoE '[A-Za-z0-9_./-]+' | sort -u | awk -v list="$list" '
    BEGIN {
      while ((getline p < list) > 0) {
        n = split(p, parts, "/"); base = parts[n]
        byBase[base] = byBase[base] "\n" p
        all[++count] = p
        dir = p
        while (sub("/[^/]*$", "", dir) && dir != "") isDir[dir] = 1
        isFile[p] = 1
      }
    }
    {
      t = $0; sub("^\\./", "", t); sub("/+$", "", t)
      if (t == "" || t == "." || t == "..") next
      if (t in isFile) print t
      if (t in byBase) { m = split(byBase[t], hits, "\n"); for (i = 2; i <= m; i++) print hits[i] }
      if ((t in isDir) && index(t, "/") > 0) { pre = t "/"; for (i = 1; i <= count; i++) if (index(all[i], pre) == 1) print all[i] }
    }' | sort -u
}

script_key() {  # <script>
  local script=$1 rel list files next hashes
  case "$script" in
    "$CACHE_ROOT"/*) rel=${script#"$CACHE_ROOT"/} ;;
    *) rel=${script#./} ;;
  esac
  [ -f "$CACHE_ROOT/$rel" ] || die "no such script: $script"
  list=$(mktemp "${TMPDIR:-/tmp}/jg-test-cache.XXXXXX") || die "no temp file"
  # shellcheck disable=SC2064
  trap "rm -f -- '$list' '$list.deps' '$list.have'" RETURN
  file_list >"$list"
  printf '%s\n' "$rel" >"$list.deps"
  files=$rel
  for _ in 1 2 3; do
    local -a paths=()
    local f
    while IFS= read -r f; do
      case "$f" in
        *.sh|*.bash|bin/*|core/*) [ -f "$CACHE_ROOT/$f" ] && paths+=("$CACHE_ROOT/$f") ;;
      esac
    done <<<"$files"
    [ "${#paths[@]}" -gt 0 ] || break
    next=$(cd "$CACHE_ROOT" && resolve "$list" "${paths[@]}")
    # Only the files not seen yet feed the next round.
    files=$(printf '%s\n' "$next" | grep -vxFf "$list.deps" || true)
    [ -n "$files" ] || break
    printf '%s\n' "$files" >>"$list.deps"
  done
  # One git call hashes every dependency; a file deleted from the working tree drops out.
  (cd "$CACHE_ROOT" && sort -u "$list.deps" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done) >"$list.have"
  # shellcheck disable=SC2094
  hashes=$(cd "$CACHE_ROOT" && git hash-object --no-filters --stdin-paths <"$list.have" | paste -d' ' "$list.have" -)
  { printf 'script %s\n' "$rel"; printf '%s\n' "$hashes"; tool_versions; } | sha256sum | cut -d' ' -f1
}

entry_dir() {  # <key>
  printf '%s/%s/%s\n' "$(cache_dir)" "${1:0:2}" "$1"
}

cmd_lookup() {
  local script=${1:-} out=${2:-} key dir
  [ -n "$script" ] && [ -n "$out" ] || die "lookup needs <script> <output-file>"
  key=$(script_key "$script") || exit 2
  dir=$(entry_dir "$key")
  if [ "$(cut -f1 "$dir/result" 2>/dev/null)" = green ] && [ -f "$dir/output" ]; then
    cp -- "$dir/output" "$out" || die "cannot write $out"
    touch -- "$dir/result" 2>/dev/null || :
    printf 'hit %s\n' "$key"
    return 0
  fi
  printf 'miss %s\n' "$key"
  return 1
}

cmd_store() {
  local script=${1:-} duration=${2:-} out=${3:-} key dir tmp
  [ -n "$script" ] && [ -n "$duration" ] && [ -f "$out" ] || die "store needs <script> <duration-ms> <output-file>"
  key=$(script_key "$script") || exit 2
  dir=$(entry_dir "$key")
  mkdir -p -- "$dir" || die "cannot create $dir"
  tmp=$(mktemp -d "$dir.tmp.XXXXXX") || die "cannot create a temp entry in $(dirname "$dir")"
  cp -- "$out" "$tmp/output" || { rm -rf -- "$tmp"; die "cannot copy the output"; }
  printf 'green\t%s\t%s\t%s\n' "$(date +%s)" "$duration" "$script" >"$tmp/result"
  # Entries are whole or absent: move the finished files in, output first, the result file last.
  mv -f -- "$tmp/output" "$dir/output" && mv -f -- "$tmp/result" "$dir/result"
  rm -rf -- "$tmp"
  printf 'stored %s\n' "$key"
}

cmd_prune() {
  local days=${1:-14} dir
  dir=$(cache_dir)
  [ -d "$dir" ] || return 0
  # A lookup touches the entry's result file, so its age is the time since the entry was last used.
  find "$dir" -mindepth 3 -maxdepth 3 -name result -mtime "+$days" -printf '%h\n' 2>/dev/null | while IFS= read -r e; do rm -rf -- "$e"; done
}

case "${1:-}" in
  key) [ -n "${2:-}" ] || die "key needs <script>"; script_key "$2" ;;
  lookup) shift; cmd_lookup "$@" ;;
  store) shift; cmd_store "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $1" ;;
esac
