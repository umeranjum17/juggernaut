#!/usr/bin/env bash
# Recommendation-only stack, layout and engineering rules.
#
# config/preferred-stack.json names a stack per medium; config/architecture.json
# names a layout and practices per language; config/engineering-rules.json names
# this home's testing, CI, release, proof and naming rules. All three use the
# crew-dispatch rule shape (when / use / why) and all three are advice, never a
# gate: nothing here refuses a build, and a project that already has its own
# stack wins because the caller passes that project in and its own stack is what
# the brief names.
#
# Every rules file may carry kind ("checkable": a script or CI check decides it,
# "judgement": a person reads it and decides) and, for a checkable rule, the
# exact enforcedBy check as a path in this checkout that must exist. Both are
# optional, so an older file keeps working; a judgement rule names no check,
# because a rule nothing checks is a wish. An engineering rule's use object
# carries `text`, the instruction itself.
#
# A malformed file, an unknown medium, or an unknown language is one warning and
# a fall back to the file's neutral `default`, never a hard failure.
#
# Public surface:
#   jg_stack_advice <config-dir> <preferred-stack.json|architecture.json> <kind> <key>
#       Prints value, practices and why for one key, or the default, or nothing,
#       separated by the unit separator (IFS collapses a run of tabs). Warnings go
#       to stderr.
#   jg_stack_language_for <dir>     language of an existing project, or nothing.
#   jg_stack_project_stack <dir>    stack an existing project already uses.
#   jg_stack_section <config-dir> <medium> <project-dir>
#       Prints the brief's preference section, or nothing when no advice applies.
#
JG_STACK_MEDIA="mobile web desktop cli backend"
JG_STACK_LANGUAGES="javascript typescript python rust go"

# First structural warning for one file, or nothing. Each check is written out
# in full: a jq `def name($arg)` argument is a filter evaluated in the caller's
# context, so a helper taking the test would test the whole document instead of
# one rule.
jg_stack_validate() {  # <file> <kind>
  jq -r --arg kind "$2" --arg media "$JG_STACK_MEDIA" --arg languages "$JG_STACK_LANGUAGES" '
    def rules: (.rules // [])[]?;
    def known: if $kind == "medium" then ($media | split(" ")) else ($languages | split(" ")) end;
    def keyfield: if $kind == "medium" then (.medium // "") else (.language // "") end;
    def unknown: [rules | select(.use | type == "object") | .use | keyfield
      | select(. as $k | known | index($k) | not)] | unique;
    if type != "object" then "top-level value must be an object"
    elif ((.rules? // []) | type) != "array" then "rules must be an array"
    elif ([rules | select(type != "object")] | length) > 0 then "each rule must be an object"
    elif ([rules | select((.when? | type) != "string" or (.when | length) == 0)] | length) > 0
      then "each rule needs a non-empty when"
    elif ([rules | select((.why? | type) != "string" or (.why | length) == 0)] | length) > 0
      then "each rule needs a non-empty why"
    elif ([rules | select((.use? | type) != "object")] | length) > 0 then "each rule needs a use object"
    elif (unknown | length) > 0 then "unknown \($kind): " + (unknown | join(", "))
    else empty end
  ' "$1" 2>/dev/null
}

jg_stack_advice() {  # <config-dir> <file> <kind> <key>
  local file="$1/$2" label="config/$2" warn
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  warn=$(jg_rules_problem "$file")
  if [ -n "$warn" ]; then
    echo "PREFERRED_STACK: invalid $label - $warn; using the neutral default" >&2
    return 0
  fi
  warn=$(jg_stack_validate "$file" "$3")
  if [ -n "$warn" ]; then
    echo "PREFERRED_STACK: invalid $label - $warn; using the neutral default" >&2
    return 0
  fi
  jq -r --arg kind "$3" --arg want "$4" '
    def keyfield: if $kind == "medium" then (.medium // "") else (.language // "") end;
    def value: if $kind == "medium" then (.stack // "") else (.layout // "") end;
    def pick: (.rules // [])[]? | select((.use? | type) == "object") | select((.use | keyfield) == $want);
    ([pick][0]) as $rule
    | (if $rule != null then [$rule.use | value, ($rule.use.practices // ""), ($rule.why // "")]
       else [.default | value, (.default.practices // ""), (.default.why // "")] end)
    | select(.[0] != "")
    | join("")
  ' "$file" 2>/dev/null || true
}

# Language of an existing project from its manifest, or nothing. Manifest
# detection is reliable; medium is not, so a medium always comes from intake.
jg_stack_language_for() {  # <dir>
  local dir=$1
  [ -d "$dir" ] || return 0
  if [ -f "$dir/package.json" ]; then
    grep -q '"typescript"' "$dir/package.json" 2>/dev/null && echo typescript || echo javascript
  elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ] || [ -f "$dir/setup.py" ]; then
    echo python
  elif [ -f "$dir/go.mod" ]; then
    echo go
  elif [ -f "$dir/Cargo.toml" ]; then
    echo rust
  fi
}

# The stack an existing project already uses, or nothing. An existing project
# always keeps what it has; the home preference never overrides it.
jg_stack_project_stack() {  # <dir>
  local dir=$1
  [ -d "$dir" ] || return 0
  if grep -qs '"expo"' "$dir/package.json"; then echo "Expo"
  elif grep -qs '"react-native"' "$dir/package.json"; then echo "React Native"
  elif [ -f "$dir/pubspec.yaml" ]; then echo "Flutter"
  elif [ -f "$dir/next.config.js" ] || [ -f "$dir/next.config.mjs" ] || [ -f "$dir/next.config.ts" ]; then echo "Next.js"
  elif grep -qs '"electron"' "$dir/package.json"; then echo "Electron"
  elif [ -d "$dir/src-tauri" ]; then echo "Tauri"
  fi
}

JG_RULES_FILE=engineering-rules.json
_jg_rules_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# First problem with one rules file, or nothing. Every rules file shares one
# shape: kind is checkable or judgement; a checkable rule names the check that
# enforces it, as a path in this checkout that must exist; a judgement rule
# names none, because advice nothing checks is advice and a rule nothing checks
# is a wish.
jg_rules_problem() {  # <file>
  local problem token path
  jq -e . "$1" >/dev/null 2>&1 || { printf 'malformed JSON'; return 0; }
  problem=$(jq -r '
    def rules: (.rules // [])[]?;
    def bad_kind: [rules | select(has("kind"))
      | select(.kind != "checkable" and .kind != "judgement")] | length;
    def missing_enforcement: [rules | select(.kind? == "checkable")
      | select(((.enforcedBy? // "") | tostring | length) == 0)] | length;
    def unused_enforcement: [rules | select(.kind? == "judgement")
      | select(((.enforcedBy? // "") | tostring | length) > 0)] | length;
    def bad_id: [rules | select(has("id")) | .id
      | select(if type != "string" then true else (test("^[a-z0-9][a-z0-9-]*$") | not) end)] | length;
    def dup_id: ([rules | select(has("id")) | .id] | length)
      != ([rules | select(has("id")) | .id] | unique | length);
    if bad_kind > 0 then "kind must be checkable or judgement"
    elif missing_enforcement > 0 then "a checkable rule needs enforcedBy"
    elif unused_enforcement > 0 then "a judgement rule must not name enforcedBy"
    elif bad_id > 0 then "an id is lower-case words joined by dashes"
    elif dup_id then "an id is used twice in one file"
    else empty end
  ' "$1" 2>/dev/null)
  if [ -n "$problem" ]; then printf '%s' "$problem"; return 0; fi
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    path=${token%%#*}
    case "$path" in
      /*) ;;
      */*) path="$_jg_rules_root/$path" ;;
      *) printf 'enforcedBy names %s, which is not a path in this checkout' "$token"; return 0 ;;
    esac
    [ -e "$path" ] || { printf 'enforcedBy names %s, which does not exist in this checkout' "$token"; return 0; }
  done < <(jq -r '(.rules // [])[]? | select(.kind? == "checkable") | .enforcedBy // empty' "$1" 2>/dev/null)
}

# The brief's engineering-rule section, or nothing when the file is absent.
# A judgement rule prints as advice; a checkable one prints as the check that
# decides it, so a worker never treats a mechanical check as a suggestion.
jg_rules_section() {  # <config-dir>
  local file="$1/$JG_RULES_FILE" label="config/$JG_RULES_FILE" problem rows checked
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  problem=$(jg_rules_problem "$file")
  if [ -n "$problem" ]; then
    echo "FLEET_RULES: invalid $label - $problem; the brief carries no rule advice" >&2
    return 0
  fi
  rows=$(jq -r '(.rules // [])[]? | select(.kind? == "judgement")
    | "- **\(.when)** \(.use.text // "") \(.why)"' "$file" 2>/dev/null | sed 's/  */ /g')
  checked=$(jq -r '(.rules // [])[]? | select(.kind? == "checkable")
    | "- \(.id // "rule"): `\(.enforcedBy)`"' "$file" 2>/dev/null)
  [ -n "$rows$checked" ] || return 0
  printf '# Engineering rules (recommendation, never a gate)\n\n'
  printf '%s\n' "\`$label\` holds this home's testing, CI, release, proof and naming rules." \
    'Follow the judgement rules below. A checked rule is enforced by the named check, not by you.'
  [ -z "$rows" ] || printf '\n%s\n' "$rows"
  [ -z "$checked" ] || printf '\nChecked by a script or CI:\n%s\n' "$checked"
}

# The brief's preference section, or nothing when the files give no advice.
jg_stack_section() {  # <config-dir> <medium> <project-dir>
  local line value practices why existing rows=
  existing=$(jg_stack_project_stack "$3")
  if [ -n "$existing" ]; then
    rows+="- This project already uses $existing. Keep it; this home's preference does not override an existing project."$'\n'
  elif [ -n "$2" ]; then
    line=$(jg_stack_advice "$1" preferred-stack.json medium "$2")
    if [ -n "$line" ]; then
      IFS=$'\x1f' read -r value practices why <<<"$line"
      rows+="- Stack for \`$2\`: **$value**. $why"$'\n'
    fi
  fi
  line=$(jg_stack_advice "$1" architecture.json language "$(jg_stack_language_for "$3")")
  if [ -n "$line" ]; then
    IFS=$'\x1f' read -r value practices why <<<"$line"
    rows+="- Layout for this project's language: $value $practices $why"$'\n'
  fi
  [ -n "$rows" ] || return 0
  printf '# Preferred stack (recommendation, never a gate)\n\n'
  printf '%s\n' "\`config/preferred-stack.json\` and \`config/architecture.json\` hold this home's stack and layout advice." \
    'Follow it for new projects. An existing project keeps the stack and layout it already has.' \
    'Nothing refuses a build because of these files.'
  printf '\n%s\n' "$(printf '%s' "$rows" | sed 's/  */ /g')"
}
