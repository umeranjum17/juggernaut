#!/usr/bin/env bash
# jg-delivery-style.sh - read the delivery-style table: for a mode, what the line is, what it adds in delivering, how it joins main, and whether it publishes.
#
# Usage:
#   jg-delivery-style.sh <mode>     print the row as six `key<TAB>value` lines: line, adds, joins, publishes, review, trunk
#   jg-delivery-style.sh <mode> <fact>  exit 0 when the fact (publishes, review, trunk, or local) is yes for a known mode, else 1
#   jg-delivery-style.sh --list     print the style words, one per line
#   jg-delivery-style.sh --accepted print every accepted word: the styles, then the old words that read as one of them
#   jg-delivery-style.sh --trunk-aliases print the old words whose lane lands on the local trunk
#   jg-delivery-style.sh --field <mode> <name>   print one named column (the `columns` row names them)
#   jg-delivery-style.sh knob <word>  print the knob (pr or local) a registry word reads as; an unknown word exits 1
#   jg-delivery-style.sh task-mode <word>  print the mode a task is run with: no-mistakes prints direct-PR, any other word prints as it came
#   jg-delivery-style.sh pr|local   print the knob's row: line, adds, joins, publishes
# Source it to call jg_delivery_style_knob <word>, jg_delivery_style <mode>, jg_delivery_style_modes, or jg_delivery_style_publishes <mode> (exit 0 when the mode
# publishes a pull request, 1 when it does not or is unknown) from another script.
#
# The table is core/machines/styles/delivery-styles.tsv (override: JG_DELIVERY_STYLES). It holds no prover: done-done proves
# the commit in every mode, and a style changes only the stage delivering. Exit 0 is success, 1 an unknown mode, 2 a usage error.
_jg_ds_root=$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/.." && pwd)  # the real bin, since a home may link its bin

_jg_ds_table() { printf '%s\n' "${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}"; }

# jg_delivery_style_canonical <word>: the style a mode word reads as (a style as itself, an alias row as its style); 1 for an unknown word.
jg_delivery_style_canonical() {
  awk -F'\t' -v m="${1:-}" '($1=="style" || $1=="alias") && $2==m { print ($1=="alias" ? $3 : $2); f=1 } END { exit f?0:1 }' "$(_jg_ds_table)"
}

# jg_delivery_style_task_mode <word>: the mode a task is run with. The retired word no-mistakes runs as direct-PR: the worker proves with done-done
# and takes the pull request path, and no pipeline run starts. Every other word is printed as it came, so local-only and local-trunk read as before.
jg_delivery_style_task_mode() {
  local w=${1:-} r
  r=$(awk -F'\t' -v w="$w" '$1=="retired" && $2==w { print $3; f=1 } END { exit f?0:1 }' "$(_jg_ds_table)") && { printf '%s\n' "$r"; return 0; }
  printf '%s\n' "$w"
}

jg_delivery_style() {
  local mode=${1:-} table=${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}
  [ -r "$table" ] || { echo "jg-delivery-style: table not readable: $table" >&2; return 2; }
  [ -n "$mode" ] || { echo "jg-delivery-style: a mode is required" >&2; return 2; }
  awk -F'\t' -v m="$mode" '
    $1=="knob" && $2==m { kn=sprintf("line\t%s\nadds\t%s\njoins\t%s\npublishes\t%s\n", $3, $4, $5, $6) }
    $1=="alias" && $2==m { s=$3; t=$4; rv=$6 }
    $1=="style" { row[$2]=sprintf("line\t%s\nadds\t%s\njoins\t%s\npublishes\t%s\nreview\t%s\n", $3, $4, $5, $6, $7); tr[$2]=$8; rvd[$2]=$7 }
    # a style or an old word wins over a knob of the same name
    END { if (s=="") s=m; if (!(s in row)) { if (kn=="") exit 1; printf "%s", kn; exit 0 }  if (t=="") t=tr[s]; if (rv!="") sub("review\t" rvd[s] "\n", "review\t" rv "\n", row[s]); printf "%strunk\t%s\n", row[s], t }' "$table" && return 0
  echo "jg-delivery-style: unknown mode '$mode' (known: $(jg_delivery_style_modes | tr '\n' ' ' | sed 's/ $//'); read as before: $(jg_delivery_style_aliases | tr '\n' ' ' | sed 's/ $//'))" >&2
  return 1
}

# jg_delivery_style_knob <word>: print pr or local for a registry word (direct-PR and no-mistakes read as pr; local-only and local-trunk as local).
jg_delivery_style_knob() {
  local word=${1:-} table=${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}
  [ -r "$table" ] || { echo "jg-delivery-style: table not readable: $table" >&2; return 2; }
  [ -n "$word" ] || { echo "jg-delivery-style: a word is required" >&2; return 2; }
  awk -F'\t' -v w="$word" '$1=="word" && $2==w { print $3; f=1 } END { exit f?0:1 }' "$table" && return 0
  echo "jg-delivery-style: unknown word '$word' (known: $(awk -F'\t' '$1=="word"{print $2}' "$table" | tr '\n' ' ' | sed 's/ $//'))" >&2
  return 1
}

# The styles a task is given, and the old words that read as one of them.
jg_delivery_style_modes() { awk -F'\t' '$1=="style"{print $2}' "$(_jg_ds_table)"; }
jg_delivery_style_aliases() { awk -F'\t' '$1=="alias"{print $2}' "$(_jg_ds_table)"; }
# jg_delivery_style_accepts <word>: 0 for a style or an old word, the accepted-mode test of every entry point.
jg_delivery_style_accepts() { jg_delivery_style_canonical "${1:-}" >/dev/null; }
jg_delivery_style_accepted() { jg_delivery_style_modes; jg_delivery_style_aliases; }
# jg_delivery_style_trunk_aliases: the old words whose lane lands on the local trunk (read from the alias rows, so a record's old note word needs no list of its own).
jg_delivery_style_trunk_aliases() { local w; for w in $(jg_delivery_style_aliases); do jg_delivery_style_is "$w" trunk && printf '%s\n' "$w"; done; return 0; }

jg_delivery_style_publishes() { jg_delivery_style_is "${1:-}" publishes; }

# jg_delivery_style_is <mode> <fact>: 0 when the fact is yes for the word (an old word keeps the trunk fact it carried). `local` is a
# known mode that does not publish. An unknown mode or fact is no.
jg_delivery_style_is() {
  local row k=${2:-}
  row=$(jg_delivery_style "${1:-}" 2>/dev/null) || return 1
  case "$k" in
    local) printf '%s\n' "$row" | grep -q '^publishes	yes$' && return 1; return 0 ;;
    publishes|review|trunk) printf '%s\n' "$row" | grep -q "^$k	yes\$" ;;
    *) return 1 ;;
  esac
}

# jg_delivery_style_field <mode> <name>: the value of a named column of the mode's row; 1 when the mode or column is unknown.
jg_delivery_style_field() {
  local table=${JG_DELIVERY_STYLES:-$_jg_ds_root/core/machines/styles/delivery-styles.tsv}
  [ -r "$table" ] || { echo "jg-delivery-style: table not readable: $table" >&2; return 2; }
  awk -F'\t' -v m="${1:-}" -v n="${2:-}" '
    $1=="columns" { for (i=2; i<=NF; i++) if ($i==n) c=i-1 }
    $1=="alias" && $2==m { s=$3; at=$4; ar=$5 }
    $1=="style" { val[$2]=(c ? $(c+1) : ""); has[$2]=1 }
    END { if (s=="") s=m; if (!has[s] || !c) exit 1; v=val[s]; if (n=="trunk" && at!="") v=at; if (n=="rule1" && ar!="") v=ar; print v }' "$table"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --list) jg_delivery_style_modes ;;
    --accepted) jg_delivery_style_accepted ;;
    --trunk-aliases) jg_delivery_style_trunk_aliases ;;
    --field) jg_delivery_style_field "${2:-}" "${3:-}" || { echo "jg-delivery-style: no property '${3:-}' for mode '${2:-}'" >&2; exit 1; } ;;
    knob) jg_delivery_style_knob "${2:-}" ;;
    task-mode) jg_delivery_style_task_mode "${2:-}" ;;
    ""|-*) echo "usage: jg-delivery-style.sh <mode> | --list" >&2; exit 2 ;;
    *) if [ -n "${2:-}" ]; then jg_delivery_style_is "$1" "$2"; else jg_delivery_style "$1"; fi ;;
  esac
fi
