#!/usr/bin/env bash
# jg-pref.sh - the captain's preferences as swappable blocks: one folder, one schema, one command.
#
# A preference is one small JSON block, defaults/preferences/<block>.json shipped and
# config/preferences/<block>.json per home (the home copy wins). Every block follows
# defaults/preferences/schema.json. Changing a block needs no code, and the same change reaches every
# squad_lead home through the existing config push (bin/jg-config-push.sh), because every shipped block
# name is in JG_INHERITABLE_CONFIG (bin/jg-config-inherit-lib.sh).
#
# Usage:
#   jg-pref.sh list                          each block, where it comes from, its values
#   jg-pref.sh get <block>[.<key>]           the block, or one value
#   jg-pref.sh set <block>.<key> <value>     change one value (typed by the block's valueTypes), then push
#   jg-pref.sh swap <block> <file>           replace a whole block with a file that passes the schema, then push
#   jg-pref.sh reset <block>                 drop the home copy; the shipped block applies again, then push
#   jg-pref.sh validate                      check every block and clause against the schema
# Set JG_PREF_NO_PUSH=1 to change the block without pushing (a test, or a batch of changes).
# Value kinds: string, number, boolean, range ("12-17"), list ("a,b,c").
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/jg-clause.sh
. "$SCRIPT_DIR/jg-clause.sh"

die() { printf 'jg-pref: %s\n' "$1" >&2; exit 2; }

push() {
  [ "${JG_PREF_NO_PUSH:-0}" = 1 ] && return 0
  [ -x "$SCRIPT_DIR/jg-config-push.sh" ] || return 0
  "$SCRIPT_DIR/jg-config-push.sh" || printf 'jg-pref: the block is changed here; the push reported a problem above\n' >&2
}

home_copy() { # <block>: ensure the home copy exists, starting from the shipped block
  local b=$1
  [ -f "$JG_CLAUSE_DEFAULTS/$b.json" ] || [ -f "$JG_CLAUSE_PREFS/$b.json" ] || die "no block named $b (blocks: $(jg_clause_block_names | tr '\n' ' '))"
  mkdir -p "$JG_CLAUSE_PREFS" || die "cannot create $JG_CLAUSE_PREFS"
  [ -f "$JG_CLAUSE_PREFS/$b.json" ] || cp "$JG_CLAUSE_DEFAULTS/$b.json" "$JG_CLAUSE_PREFS/$b.json" || die "cannot copy the shipped $b block"
}

# publish <tmp file> <block>: check the schema, then replace the home copy in one move.
publish() {
  local tmp=$1 b=$2 why
  why=$(_jg_clause_block_problem "$tmp")
  [ -z "$why" ] || { rm -f -- "$tmp"; die "refused: $why"; }
  [ "$(jq -r .block "$tmp")" = "$b" ] || { rm -f -- "$tmp"; die "refused: the file's block name must be $b"; }
  mv -f -- "$tmp" "$JG_CLAUSE_PREFS/$b.json"
}

cmd=${1:-}
shift || true
case $cmd in
  list)
    while IFS= read -r b; do
      src=shipped; [ -f "$JG_CLAUSE_PREFS/$b.json" ] && src=home
      f=$(jg_clause_block_file "$b" 2>/dev/null) || continue
      printf '%s\t%s\t%s\n' "$b" "$src" "$(jq -c '{values: (.values // {}), clauses: ((.clauses // []) | length)}' "$f")"
    done < <(jg_clause_block_names) ;;
  get)
    [ $# -eq 1 ] || die "usage: jg-pref.sh get <block>[.<key>]"
    b=${1%%.*}; k=""; [ "$1" = "$b" ] || k=${1#*.}
    f=$(jg_clause_block_file "$b") || die "no block named $b"
    if [ -z "$k" ]; then jq . "$f"; else jq -er --arg k "$k" '.values[$k]' "$f" || die "$b has no value $k"; fi ;;
  set)
    [ $# -eq 2 ] || die "usage: jg-pref.sh set <block>.<key> <value>"
    case $1 in *.*) ;; *) die "name the key: <block>.<key>" ;; esac
    b=${1%%.*}; k=${1#*.}; v=$2
    f=$(jg_clause_block_file "$b") || die "no block named $b"
    kind=$(jq -r --arg k "$k" '.valueTypes[$k] // empty' "$f")
    [ -n "$kind" ] || die "block $b has no value $k (values: $(jq -r '(.valueTypes // {}) | keys | join(" ")' "$f"))"
    case $kind in
      range) case $v in [0-9]*-[0-9]*) ;; *) die "refused: $b.$k is a range like 12-17 (got '$v')" ;; esac ;;
      number) case $v in '' | *[!0-9.]*) die "refused: $b.$k is a number (got '$v')" ;; esac ;;
      boolean) case $v in true | false) ;; *) die "refused: $b.$k is true or false (got '$v')" ;; esac ;;
    esac
    home_copy "$b"
    tmp=$(mktemp "$JG_CLAUSE_PREFS/$b.json.XXXXXX") || die "cannot write in $JG_CLAUSE_PREFS"
    jq --arg k "$k" --arg v "$v" --arg kind "$kind" '.values[$k] = (
      if $kind == "number" then ($v | tonumber) elif $kind == "boolean" then ($v == "true")
      elif $kind == "list" then ($v | split(",")) else $v end)' "$JG_CLAUSE_PREFS/$b.json" >"$tmp" || { rm -f -- "$tmp"; die "cannot update $b"; }
    publish "$tmp" "$b"
    printf '%s.%s = %s\n' "$b" "$k" "$v"
    push ;;
  swap)
    [ $# -eq 2 ] || die "usage: jg-pref.sh swap <block> <file>"
    [ -f "$2" ] || die "no file at $2"
    jq -e . "$2" >/dev/null 2>&1 || die "refused: $2 is not JSON"
    mkdir -p "$JG_CLAUSE_PREFS" || die "cannot create $JG_CLAUSE_PREFS"
    tmp=$(mktemp "$JG_CLAUSE_PREFS/$1.json.XXXXXX") || die "cannot write in $JG_CLAUSE_PREFS"
    cp "$2" "$tmp" && publish "$tmp" "$1"
    printf 'swapped block %s\n' "$1"
    push ;;
  reset)
    [ $# -eq 1 ] || die "usage: jg-pref.sh reset <block>"
    rm -f -- "$JG_CLAUSE_PREFS/$1.json"
    printf 'reset block %s to the shipped default\n' "$1"
    push ;;
  validate) jg_clause_validate ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
