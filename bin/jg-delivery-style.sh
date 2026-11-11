#!/usr/bin/env bash
# jg-delivery-style.sh - read the delivery-style table: for a mode, what the line is, what it adds in delivering, how it joins main.
#
# Usage:
#   jg-delivery-style.sh <mode>     print the row as three `key<TAB>value` lines: line, adds, joins
#   jg-delivery-style.sh --list     print the mode words, one per line
# Source it to call jg_delivery_style <mode> from another script.
#
# The table is core/machines/styles/delivery-styles.tsv (override: JG_DELIVERY_STYLES). It holds no prover: done-done proves
# the commit in every mode, and a style changes only the stage delivering. Exit 0 is success, 1 an unknown mode, 2 a usage error.
_jg_ds_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

jg_delivery_style() {
  local mode=${1:-} table=${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}
  [ -r "$table" ] || { echo "jg-delivery-style: table not readable: $table" >&2; return 2; }
  [ -n "$mode" ] || { echo "jg-delivery-style: a mode is required" >&2; return 2; }
  awk -F'\t' -v m="$mode" '$1=="style" && $2==m { printf "line\t%s\nadds\t%s\njoins\t%s\n", $3, $4, $5; f=1 } END { exit f?0:1 }' "$table" && return 0
  echo "jg-delivery-style: unknown mode '$mode' (known: $(jg_delivery_style_modes | tr '\n' ' ' | sed 's/ $//'))" >&2
  return 1
}

jg_delivery_style_modes() {
  awk -F'\t' '$1=="style"{print $2}' "${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --list) jg_delivery_style_modes ;;
    ""|-*) echo "usage: jg-delivery-style.sh <mode> | --list" >&2; exit 2 ;;
    *) jg_delivery_style "$1" ;;
  esac
fi
