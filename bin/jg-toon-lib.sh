# shellcheck shell=bash
# Shared TOON renderer (jq program) for the AXI-style projections, such as
# jg-bearings-snapshot.sh and juggernaut-axi: one owner of the output-boundary format.
# Usage: . bin/jg-toon-lib.sh; printf '%s\n' "$JSON" | jq -r "$JG_TOON_JQ"
# Nested objects use indented keys; arrays of uniform scalar objects use
# the tabular array form
# (key[N]{fields}: + comma rows at +2 indent), and the empty-array form (key: []),
# per the TOON spec. Quoting follows the spec exactly. An array of plain scalars
# (the help[] next-step lines the backlog prints) is key[N]: with one "- item" per line.
# shellcheck disable=SC2034,SC2016
JG_TOON_JQ='
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "object" then
      "\($k): ", ($v | to_entries[] | emit(.key;.value) | "  " + .)
    elif ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      elif ($v | all(type != "object" and type != "array")) then
        "\($k)[\($v | length)]:", ($v[] | "  - " + scal)
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
'
