#!/usr/bin/env bash
# Each Go command offers only what something calls: the status classifier, the wake core and the
# spawn core, each run through the dispatcher its callers use. Two checks per command:
#   - every command name in the usage line it prints has a caller: a shell line outside the
#     command's own module and outside every test and journey that runs the command, or a wrapper
#     named for it, with that name as its first bare argument word;
#   - each entry deleted for having no caller now exits 2, an unknown command, when called with the
#     arguments it took, so the check fails on the tree that still held it.
# A name a test alone calls has no caller. Usage: tests/jg-go-entries.test.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-go-entries.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
export JG_STATE_OVERRIDE=$lab/state TMPDIR=$lab XDG_CACHE_HOME=$lab/cache
unset JG_CLASSIFY_BIN JG_WAKE_CORE_BIN JG_SPAWN_CORE_BIN
for go in "${JG_CLASSIFY_GO:-go}" "${JG_WAKE_CORE_GO:-go}" "${JG_SPAWN_CORE_GO:-go}"; do
  if ! command -v "$go" >/dev/null 2>&1; then
    printf 'skip: no Go toolchain (%s); install go to build the three commands\n' "$go"
    exit 0
  fi
done
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { printf 'FAIL: %s is not a git work tree, so its callers cannot be listed\n' "$ROOT"; exit 1; }
mkdir -p "$JG_STATE_OVERRIDE"
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok: %s\n' "$1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
rc() { "$@" </dev/null >/dev/null 2>&1; echo $?; }

# usage_names <dispatcher>: the command names in the usage line the command prints with no
# argument. Flag groups [..], placeholders <..>, notes (..) and "..." are not names.
usage_names() {
  "$1" </dev/null 2>&1 >/dev/null | sed -n 's/^usage: [^ ]*//p' \
    | sed -e 's/\[[^]]*\]//g' -e 's/<[^>]*>//g' -e 's/([^)]*)//g' -e 's/\.\.\.//g' \
    | tr '|' ' ' | tr ' ' '\n' | grep -E '^[a-z][a-z0-9-]*$' | sort -u
}

# call_lines <token-ERE> <module>: the shell lines, comments dropped, that name the command or a
# wrapper of it, outside its module and outside every test and journey.
call_lines() {
  git -C "$ROOT" grep -nE "$1" -- '*.sh' ":(exclude)$2" ':(exclude)tests' ':(exclude,glob)**/tests/**' \
    ':(exclude)journeys' ':(exclude,glob)**/*.test.sh' \
    | sed -E -e 's/^([^:]*:[0-9]+:)[[:space:]]*#.*$/\1/' -e 's/[[:space:]]#.*$//'
}

# uncalled <token-ERE> <lines> <name>...: the names no line calls as its first bare argument after
# the token; a quoted word, a flag or a variable may come between.
uncalled() {
  local token=$1 lines=$2 name
  shift 2
  for name in "$@"; do
    printf '%s\n' "$lines" \
      | grep -qE "(^|[^A-Za-z0-9_])_*$token\"?( +(\"[^\"]*\"|'[^']*'|-[-A-Za-z0-9_=]+|\\\$[^ ]+))* +\"?$name\"?([ );|&]|\$)" \
      || printf '%s ' "$name"
  done
}

# command_offers <label> <dispatcher> <module> <token-ERE> <live-call...> -- <deleted-call...> -- <exempt...>
# A deleted call is one word list: the deleted name and the arguments it took.
command_offers() {
  local label=$1 dispatcher=$2 module=$3 token=$4 names lines exempt name
  shift 4
  local live=() deleted=() exempt_list=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do live+=("$1"); shift; done
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do deleted+=("$1"); shift; done
  shift
  exempt_list=("$@")

  # A dispatcher that cannot build also exits 2, so first prove this one answers a live call.
  check "$label answers a live command" "$(rc "$dispatcher" "${live[@]}")" 0
  names=$(usage_names "$dispatcher")
  check "$label prints a usage line naming its commands" "$([ -n "$names" ] && echo yes)" yes

  for name in "${deleted[@]}"; do
    # shellcheck disable=SC2086 # the name and its arguments
    check "$label no longer offers ${name%% *}: it exits 2" "$(rc "$dispatcher" $name)" 2
  done
  for exempt in "${exempt_list[@]}"; do
    check "$label still offers $exempt, which waits for its own slice" \
      "$(printf '%s\n' "$names" | grep -qxF -- "$exempt" && echo yes)" yes
    names=$(printf '%s\n' "$names" | grep -vxF -- "$exempt")
  done

  lines=$(call_lines "$token" "$module")
  # shellcheck disable=SC2086 # one name per word
  check "$label: every name in its usage line has a caller" "$(uncalled "$token" "$lines" $names)" ""
}

command_offers classify "$ROOT/bin/jg-classify.sh" core/classify \
  '(jg[-_]classify[A-Za-z0-9_.]*|\$\{?(classify|CLASSIFY)\}?)' is-terminal 'done: x' \
  -- line-facts fold-stream scan-open-decisions \
  -- facts # tests/jg-machine-status.test.sh alone calls it; go-shell slice GS17 deletes it and this
command_offers wake "$ROOT/bin/jg-wake-core.sh" core/wake \
  'jg[-_]wake[-_]core[A-Za-z0-9_.]*' routing-files \
  -- routing-file \
  --
command_offers spawn "$ROOT/bin/jg-spawn-core.sh" core/spawn \
  'jg[-_]spawn[-_]core[A-Za-z0-9_.]*' model-flag claude sonnet \
  -- 'rigor-rank no-mistakes' \
  --

if [ "$fails" -gt 0 ]; then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
