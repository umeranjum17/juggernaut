#!/usr/bin/env bash
# jg-delivery-style.sh - read the delivery-style table: for a mode, what the line is, what it adds in delivering, how it joins main, and whether it publishes.
#
# Usage:
#   jg-delivery-style.sh <mode>     print the row as six `key<TAB>value` lines: line, adds, joins, publishes, review, trunk
#   jg-delivery-style.sh <mode> <fact>  exit 0 when the fact (publishes, review, trunk, or local) is yes for a known mode, else 1
#   jg-delivery-style.sh --list     print the mode words, one per line
# Source it to call jg_delivery_style <mode>, jg_delivery_style_modes, or jg_delivery_style_publishes <mode> (exit 0 when the mode
# publishes a pull request, 1 when it does not or is unknown) from another script.
#
# The table is core/machines/styles/delivery-styles.tsv (override: JG_DELIVERY_STYLES). It holds no prover: done-done proves
# the commit in every mode, and a style changes only the stage delivering. Exit 0 is success, 1 an unknown mode, 2 a usage error.
_jg_ds_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

jg_delivery_style() {
  local mode=${1:-} table=${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}
  [ -r "$table" ] || { echo "jg-delivery-style: table not readable: $table" >&2; return 2; }
  [ -n "$mode" ] || { echo "jg-delivery-style: a mode is required" >&2; return 2; }
  awk -F'\t' -v m="$mode" '$1=="style" && $2==m { printf "line\t%s\nadds\t%s\njoins\t%s\npublishes\t%s\nreview\t%s\ntrunk\t%s\n", $3, $4, $5, $6, $7, $8; f=1 } END { exit f?0:1 }' "$table" && return 0
  echo "jg-delivery-style: unknown mode '$mode' (known: $(jg_delivery_style_modes | tr '\n' ' ' | sed 's/ $//'))" >&2
  return 1
}

jg_delivery_style_modes() {
  awk -F'\t' '$1=="style"{print $2}' "${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}"
}

jg_delivery_style_publishes() {
  awk -F'\t' -v m="${1:-}" '$1=="style" && $2==m && $6=="yes" { f=1 } END { exit f?0:1 }' "${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}"
}

# jg_delivery_style_is <mode> <fact>: 0 when the fact is yes. `local` is a known mode that does not publish. An unknown mode or fact is no.
jg_delivery_style_is() {
  awk -F'\t' -v m="${1:-}" -v k="${2:-}" '$1=="style" && $2==m && ((k=="publishes" && $6=="yes") || (k=="review" && $7=="yes") || (k=="trunk" && $8=="yes") || (k=="local" && $6!="yes")) { f=1 } END { exit f?0:1 }' "${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --list) jg_delivery_style_modes ;;
    ""|-*) echo "usage: jg-delivery-style.sh <mode> | --list" >&2; exit 2 ;;
    *) if [ -n "${2:-}" ]; then jg_delivery_style_is "$1" "$2"; else jg_delivery_style "$1"; fi ;;
  esac
fi
