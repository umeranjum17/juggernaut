#!/usr/bin/env bash
# jg-tool-models.sh - which AI model each tool in this repo uses, as DATA.
#
# Usage:
#   jg-tool-models.sh resolve <tool>   print "<harness> [<model> [<effort>]]" for the tool's
#                                      entry, or print nothing when the tool's own default stands
#   jg-tool-models.sh model <tool> <harness> [<provider>/]
#                                      print only the entry's model, when the entry names that harness,
#                                      with the optional "<provider>/" prefix removed; else print nothing
#   jg-tool-models.sh profiles <tool> print the tool's allowed profiles as one JSON array (for a tool that takes a
#                                      list, like the route chain), or print nothing when its default stands
#   jg-tool-models.sh check            validate config/tool-models.json; one line per problem
#
# config/tool-models.json is the crew-dispatch shape (docs/configuration.md "Tool
# models (config/tool-models.json)"): {"rules": [{"tool": "squad-lead", "when": "...",
# "use": {"harness": "claude", "model": "sonnet", "effort": "high"}}]}. Each rule
# carries a `tool` tag, and `use` is one profile or an ordered list; the first profile the
# model allow-list accepts wins. The profile rules are the ones config/crew-dispatch.json
# uses (bin/jg-profile.jq), and the allow-list is the one every launch uses
# (bin/jg-model-allowlist.sh).
# The file is read at every call, so an edit applies on the next launch or call with no
# code change and no restart. An absent file, or a tool with no rule, changes nothing.
# A bad file, a bad entry, or a model the allow-list refuses prints one plain
# "TOOL_MODELS:" line on stderr and the tool keeps its default.
# Sourced, this file only defines functions.
_jg_tm_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

jg_tool_models_file() {
  printf '%s\n' "${JG_TOOL_MODELS:-${JG_CONFIG_OVERRIDE:-${CONFIG:-${JG_HOME:-${JG_ROOT_OVERRIDE:-$HOME/juggernaut}}/config}}/tool-models.json}"
}

# jg_tool_models_error <file>: the reason the file is unusable, or nothing when it is sound.
jg_tool_models_error() {
  local file=$1 verified
  # shellcheck source=bin/jg-control-lib.sh
  . "$_jg_tm_dir/jg-control-lib.sh"
  # shellcheck source=bin/jg-quota-axi-lib.sh
  . "$_jg_tm_dir/jg-quota-axi-lib.sh"
  verified=$(jg_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -r -L "$_jg_tm_dir" --argjson verified_harnesses "$verified" --arg provider_re "$JG_QUOTA_PROVIDER_ID_RE" '
    include "jg-profile";
    if type != "object" then "top-level value must be an object"
    elif (.rules | type) != "array" then "rules must be an array"
    elif any(.rules[]; type != "object") then "each rule must be an object"
    elif any(.rules[]; (.tool | type) != "string" or (.tool | length) == 0) then "each rule needs a non-empty tool tag"
    elif any(.rules[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
    elif any(.rules[]; profiles(.use) | length == 0) then "each rule needs at least one use profile"
    elif any(.rules[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
    elif any(.rules[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
    elif any(.rules[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
    elif any(.rules[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
    else empty end' "$file" 2>/dev/null || printf 'not valid JSON'
}

# jg_tool_models_resolve <tool>: see Usage. Always returns 0; the default is the fallback.
jg_tool_models_resolve() {
  local tool=$1 file err harness model effort refusal tried=0
  file=$(jg_tool_models_file)
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "TOOL_MODELS: jq is missing, so $file is not read; $tool keeps its default" >&2; return 0; }
  err=$(jg_tool_models_error "$file")
  if [ -n "$err" ]; then
    echo "TOOL_MODELS: $file is not used - $err; $tool keeps its default" >&2
    return 0
  fi
  # shellcheck source=bin/jg-model-allowlist.sh
  . "$_jg_tm_dir/jg-model-allowlist.sh"
  while IFS=$'\t' read -r harness model effort; do
    [ -n "$harness" ] || continue
    tried=1
    [ "$model" != - ] || model=''
    [ "$effort" != - ] || effort=''
    if refusal=$(jg_model_allowlist_require "$harness" "$model" 2>&1); then
      printf '%s' "$harness"
      if [ -n "$effort" ]; then printf ' %s %s' "${model:-default}" "$effort"; elif [ -n "$model" ]; then printf ' %s' "$model"; fi
      printf '\n'
      return 0
    fi
    echo "TOOL_MODELS: $tool profile $harness ${model:-default} skipped - ${refusal#error: }" >&2
  done < <(jq -r --arg t "$tool" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    first(.rules[] | select(.tool == $t)) | profiles(.use)[]
    | [.harness, (.model // "-"), (.effort // "-")] | @tsv' "$file" 2>/dev/null)
  [ "$tried" = 0 ] || echo "TOOL_MODELS: no profile for $tool is allowed; $tool keeps its default" >&2
}

# jg_tool_models_model <tool> <harness> [<provider>/]: the model of the tool's entry when the entry
# names <harness> and a model, with the prefix removed. Anything else prints one TOOL_MODELS line and
# nothing, so the caller keeps its default. For sites that cannot run every harness (a fixed command,
# or a model on a cloud service), so a mismatched entry never changes what the site does.
jg_tool_models_model() {
  local tool=$1 want=$2 prefix=${3-} tm harness model
  tm=$(jg_tool_models_resolve "$tool") || return 0
  [ -n "$tm" ] || return 0
  read -r harness model _ <<<"$tm"
  case "${model:-default}" in
    default|*[!A-Za-z0-9._:/@-]*) harness='' ;;
  esac
  if [ "$harness" != "$want" ]; then
    echo "TOOL_MODELS: $tool needs harness $want and a model; $tool keeps its default" >&2
    return 0
  fi
  printf '%s\n' "${model#"$prefix"}"
}

# jg_tool_models_profiles <tool>: for a tool that takes a LIST of models (the route chain), print a JSON array of
# every profile of the tool's rule that the allow-list accepts, in file order, or print nothing when the tool's own
# default stands. A refused profile is skipped with one TOOL_MODELS line; a bad file or no accepted profile keeps the
# default. Always returns 0.
jg_tool_models_profiles() {
  local tool=$1 file err p harness model refusal kept=()
  file=$(jg_tool_models_file)
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "TOOL_MODELS: jq is missing, so $file is not read; $tool keeps its default" >&2; return 0; }
  err=$(jg_tool_models_error "$file")
  if [ -n "$err" ]; then
    echo "TOOL_MODELS: $file is not used - $err; $tool keeps its default" >&2
    return 0
  fi
  # shellcheck source=bin/jg-model-allowlist.sh
  . "$_jg_tm_dir/jg-model-allowlist.sh"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    harness=$(jq -r .harness <<<"$p")
    model=$(jq -r '.model // empty' <<<"$p")
    if refusal=$(jg_model_allowlist_require "$harness" "$model" 2>&1); then
      kept+=("$p")
    else
      echo "TOOL_MODELS: $tool profile $harness ${model:-default} skipped - ${refusal#error: }" >&2
    fi
  done < <(jq -c --arg t "$tool" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    first(.rules[] | select(.tool == $t)) | profiles(.use)[]' "$file" 2>/dev/null)
  if [ "${#kept[@]}" -gt 0 ]; then
    printf '%s\n' "${kept[@]}" | jq -sc .
  elif jq -e --arg t "$tool" 'any(.rules[]; .tool == $t)' "$file" >/dev/null 2>&1; then
    echo "TOOL_MODELS: no profile for $tool is allowed; $tool keeps its default" >&2
  fi
}

[ "${BASH_SOURCE[0]}" -ef "$0" ] || return 0
set -u
JG_HOME="${JG_HOME:-$(cd "$_jg_tm_dir/.." && pwd)}"
case "${1:-}" in
  resolve) [ "$#" -eq 2 ] || { echo "usage: jg-tool-models.sh resolve <tool>" >&2; exit 2; }; jg_tool_models_resolve "$2" ;;
  model) [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { echo "usage: jg-tool-models.sh model <tool> <harness> [<provider>/]" >&2; exit 2; }; jg_tool_models_model "$2" "$3" "${4-}" ;;
  profiles) [ "$#" -eq 2 ] || { echo "usage: jg-tool-models.sh profiles <tool>" >&2; exit 2; }; jg_tool_models_profiles "$2" ;;
  check)
    f=$(jg_tool_models_file)
    [ -f "$f" ] || { echo "no $f: every tool keeps its default"; exit 0; }
    err=$(jg_tool_models_error "$f")
    [ -z "$err" ] || { echo "TOOL_MODELS: $f is not used - $err" >&2; exit 1; }
    jq -r '.rules[] | "\(.tool)\t\(.when)"' "$f"
    ;;
  *) echo "usage: jg-tool-models.sh resolve <tool> | model <tool> <harness> [<provider>/] | profiles <tool> | check" >&2; exit 2 ;;
esac
