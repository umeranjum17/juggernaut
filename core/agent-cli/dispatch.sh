#!/usr/bin/env bash
# core/agent-cli/dispatch.sh - the one dispatcher behind `jg` and `juggernaut-axi`: it reads the command
# contract (core/agent-cli/contract/*.json, one fragment per slice; README.md in that folder owns the shape),
# checks it, resolves a path to its entry, runs the entry's script with the caller's environment unchanged,
# and prints the jg.v1 envelope {schema, ok, data, next}.
#
# Usage: dispatch.sh [--as <command name>] <check | has <word> | matches <words...> | help | run <path words> [args...]>
#   check   validate every fragment: its shape, unique paths and aliases, one entry per (script, operation),
#           the owner of a row in operations.tsv, and that each entry's script is there.
#   has     exit 0 when <word> starts a path or an alias (the wrappers' routing test).
#   matches exit 0 when the words match a route of at least two words (before falling back to a worker verb).
#   help    every entry of every fragment on one page, with its plain meaning.
#   run     resolve the longest path that matches, bind the arguments against the entry's form, run it.
# Exit codes of `run`: 0 done, 1 refused by a rule, 2 usage, 3 still waiting, 4 not found, 5 a dependency missing.
# The dispatcher never defaults JG_HOME: a script that needs an explicit home refuses without one, as it does
# when run by hand. Its one record is the repeat guard (below), written only under an explicit home.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
CONTRACT_DIR=$HERE/contract
OPERATIONS_TSV=$HERE/operations.tsv
NAME=jg

die() { printf '%s: %s\n' "$NAME" "$*" >&2; exit "${DIE_CODE:-2}"; }

command -v jq >/dev/null 2>&1 || { DIE_CODE=5 die "jq is not installed, and the command contract needs it"; }

# --- the contract ---------------------------------------------------------------------------------------------
# Every entry of every fragment as one JSON array, each with its fragment's area and owner.
contract_all() {
  set -- "$CONTRACT_DIR"/*.json
  [ -e "$1" ] || { printf '[]\n'; return 0; }
  jq -s '
    (map(.form_extensions // {}) | add) as $extensions
    | [.[] | .area as $a | .owner as $o | .entries[]
       | . + {area: $a, owner: $o}
       | $extensions[.path | join(" ")] as $ext
       | if $ext then . + {form_extension: $ext} else . end]
  ' "$@" 2>/dev/null || printf '[]\n'
}

# The command line's words as a JSON array of strings (jq would read a word such as --x as its own option).
words_json() {
  [ "$#" -gt 0 ] || { printf '[]\n'; return 0; }
  printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]'
}

ROUTES_JQ='def routes: [.path] + [.aliases[] | split(" ")];'

# Shape of one fragment: the check of example-pack/formats.md section 6, plus the fields this dispatcher reads.
FRAGMENT_SHAPE='(.area|type=="string") and (.owner|type=="string") and (.entries|type=="array" and length>0)
  and (if has("form_extensions") then
      (.form_extensions | type=="object" and all(.[]; (.form|type=="string")
        and (if has("changes") then (.changes|type=="boolean") else true end)))
    else true end)
  and all(.entries[];
    (.path | type=="array" and length>0
      and (if length>1 and .[-1]=="--help" then .[:-1] else . end
        | all(.[]; type=="string" and test("^[a-z0-9][a-z0-9_-]*$"))))
    and (.meaning|type=="string" and length>0) and (.roles|type=="array") and (.changes|type=="boolean")
    and (.method == (if .changes then "POST" else "GET" end))
    and ((.changes|not) or (.repeat_key|type=="string"))
    and (.script|type=="string" and (startswith("bin/") or (startswith("core/agent-cli/") and (contains("..")|not))))
    and ((.passthrough // false)|type=="boolean") and (.operation|type=="string")
    and (.form|type=="string") and (if has("additional_forms") then
      (.additional_forms | type=="array" and all(.[]; type=="string")) else true end)
    and (if has("stream_stdout_for") then
      (.stream_stdout_for | type=="array" and all(.[]; type=="string")) else true end)
    and (.exits|type=="object") and (.schema|type=="string")
    and (.args|type=="array" and all(.[]; (.name|type=="string") and (.type|type=="string")))
    and (.aliases|type=="array"))'

cmd_check() {
  local f bad=0 all dups out
  for f in "$CONTRACT_DIR"/*.json; do
    [ -e "$f" ] || continue
    jq -e "$FRAGMENT_SHAPE" "$f" >/dev/null 2>&1 \
      || { printf 'contract: %s does not have the fragment shape (example-pack/formats.md section 6)\n' "${f##*/}" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ] || return 1
  all=$(contract_all)
  dups=$(printf '%s' "$all" | jq -r '
    def dups: group_by(.) | map(select(length > 1) | .[0]);
    ([.[] | .path | join(" ")] ) as $paths
    | ([.[] | .aliases[]]) as $aliases
    | ($paths | dups | map("path " + . + " is in two entries")),
      ($aliases | dups | map("alias " + . + " is in two entries")),
      ([$aliases[] | select(. as $a | $paths | index($a))] | map("alias " + . + " is also a path")),
      ([.[] | .script + " " + .operation] | dups | map("(script, operation) " + . + " is in two entries"))
    | .[]')
  [ -z "$dups" ] || { printf 'contract: %s\n' "$dups" >&2; return 1; }
  if [ -f "$OPERATIONS_TSV" ]; then
    out=$(printf '%s' "$all" | jq -r '.[] | [(.script | sub("^bin/"; "")), .operation, .owner, (.path | join(" "))] | @tsv' \
      | awk -F '\t' -v tsv="$OPERATIONS_TSV" '
          BEGIN { while ((getline line < tsv) > 0) { split(line, c, "\t"); own[c[1] "\t" c[2]] = c[7] } }
          ($1 "\t" $2) in own && own[$1 "\t" $2] != $3 {
            printf "%s (%s %s) is owned by %s in operations.tsv, not %s\n", $4, $1, $2, own[$1 "\t" $2], $3; bad = 1 }
          END { exit bad }') \
      || { printf 'contract: %s\n' "$out" >&2; return 1; }
  fi
  for f in $(printf '%s' "$all" | jq -r '.[].script' | sort -u); do
    [ -f "$ROOT/$f" ] || { printf 'contract: %s names a script that is not there\n' "$f" >&2; return 1; }
  done
  return 0
}

cmd_has() {
  contract_all | jq -e --arg w "${1:-}" "$ROUTES_JQ any(.[] | routes[]; .[0] == \$w)" >/dev/null
}

cmd_help() {
  printf '%s help - every command of the contract (words in <> are arguments; [] is optional)\n' "$NAME"
  contract_all | jq -r --arg n "$NAME" '
    sort_by(.area, (.path | join(" "))) | group_by(.area)[]
    | "", "\(.[0].area):",
      (.[] | "  \($n) \(.path | join(" ")) - \(.meaning)\(if .changes or .form_extension.changes then "" else " (reads only)" end)\(if (.aliases | length) > 0 then " [also: \(.aliases | join(", "))]" else "" end)")'
}

# --- binding the arguments to the form -----------------------------------------------------------------------
# The form is the script's own usage line. Bind one branch of each choice, and keep argument values separate
# from literal words the script expects. An entry can also declare the dispatcher options --again and --key.
# shellcheck disable=SC2016  # the jq program is one single-quoted string
BIND_JQ='
# Two usage lines use descriptive names in place of the explicit operand grammar.
def canonical_form:
  if .script == "bin/jg-migration-card.sh" and .operation == "milestone" then
    .form | sub("\\[text\\]"; "[<text>]")
  elif .script == "bin/jg-runner-shard.sh" then
    .form | sub("<jg-test-run\\.sh arguments>"; "[<args>...]")
  else .form end;
def lex: [scan("\"<[^>]+>\"|<[^>]+>(?:\\.\\.\\.)?|[\\[\\]()|]|[^\\s<>\\[\\]()|]+")
  | if startswith("\"<") then .[1:-1] else . end];
def passthrough: . == "args...";
def placeholder: passthrough or test("^<[^>]+>(\\.\\.\\.)?$|^[A-Z][A-Z0-9_-]*$");
def argname: ltrimstr("<") | rtrimstr("...") | rtrimstr(">") | rtrimstr("...");
def option: test("^--?[a-zA-Z]");
def find_at_level($toks; $stop):
  first(foreach range(0; $toks | length) as $i
    ({depth: 0}; $toks[$i] as $t
      | .found = (.depth == 0 and ($t | IN($stop[])))
      | if $t == "[" or $t == "(" then .depth += 1
        elif $t == "]" or $t == ")" then .depth -= 1 else . end;
      select(.found) | $i)) // ($toks | length);
def specs($toks; $opt; $choice):
  find_at_level($toks; ["|"]) as $or
  | if $or < ($toks | length) then
      specs($toks[:$or]; $opt; true), specs($toks[$or+1:]; $opt; true)
    elif ($toks | length) == 0 then []
    else $toks[0] as $t | $toks[1:] as $rest
    | if $t == "[" or $t == "(" then
        find_at_level($rest; [if $t == "[" then "]" else ")" end]) as $end
        | $rest[:$end] as $group
        | ($rest[$end+1] == "...") as $repeat
        | (if $t == "[" and find_at_level($group; ["|"]) < ($group | length) then
             [], specs($group; $opt; true)
           else specs($group; ($opt or $t == "["); false) end)
          | (if $repeat then map(if .k == "opt" then .repeat = true else . end) else . end)
            + specs($rest[$end+1:]; $opt; $choice)
      elif $t == "..." then specs($rest; $opt; $choice)
      elif $t | placeholder then
        [{k: "pos", name: ($t | argname), rest: ($t | test("\\.\\.\\.>?$")),
          passthrough: ($t | passthrough), opt: $opt}]
        + specs($rest; $opt; $choice)
      elif ($t | option) and ($rest[0] // "" | placeholder) then
        [{k: "opt", flag: $t, name: ($rest[0] | argname), opt: $opt, rest: ($rest[0] | test("\\.\\.\\.>?$"))}]
        + specs($rest[1:]; $opt; $choice)
      elif $t | option then
        [{k: "flag", flag: $t, name: ($t | sub("^--?"; "")), opt: $opt, default: ($opt or $choice | not)}]
        + specs($rest; $opt; $choice)
      elif $t == "--" then
        [{k: "separator", opt: $opt}] + specs($rest; $opt; $choice)
      elif $t == "-" or $choice or $opt then
        [{k: "pos", name: $t, literal: $t, opt: $opt}] + specs($rest; $opt; $choice)
      else [{k: "lit", v: $t}] + specs($rest; $opt; $choice)
      end
    end;
def ref_ok: test("^[0-9]+:[A-Za-z0-9._-]+(:[0-9]+)?$");
def expand($type; $v): if $type == "ack-ref" then ($v | split(":")) as $p
  | ["--ack-through", $p[0], "--recovery-generation", $p[1]] + (if ($p | length) > 2 then ["--pages-ack", $p[2]] else [] end) else [$v] end;
def take_pos($pos; $a):
  $pos[.posi] as $p
  | if $p.k == "separator" then .err = "expected -- before \($a)"
    elif $p == null or ($p.literal != null and $a != $p.literal) then .err = "unexpected argument \($a)"
    elif $p.rest then .vals[$p.name] += [$a]
    else .vals[$p.name] = $a | .posi += 1 end;
def take_value($flags; $a):
  .pending as $flag
  | if $flags[$flag].rest then .opts[$flag] += [$a]
    elif $flags[$flag].repeat then .opts[$flag] += [$a] | .pending = null
    else .opts[$flag] = $a | .pending = null end;
def bind($in; $spec; $types; $declared):
  ($spec | map(select(.k == "pos" or (.k == "separator" and (.opt | not))))) as $pos
| any($pos[]; .k == "separator") as $requires_separator
| ($spec | map(select(.k == "opt" or .k == "flag") | {(.flag): .}) | add // {}) as $named
| (({"--again": {k: "flag", name: "again"}, "--key": {k: "opt", name: "key"}}
    | with_entries(select(.value.name as $n | $declared | index($n)))) + $named) as $flags
| [$spec[] | select(.rest and .k == "opt") | .flag] as $rest_flags
| (reduce $in.args[] as $a ({vals: {}, opts: {}, pending: null, posi: 0, dd: false, err: null};
    if .err != null then .
    elif .pending != null then
      if $flags[.pending].rest and (.pending as $f | ($rest_flags | index($f)) as $i | $a == $rest_flags[$i+1]) then
        if (.opts[.pending] | length) == 0 then .err = "option \(.pending) needs at least one argument"
        else .pending = $a end
      else take_value($flags; $a) end
    # A trailing args... delegates the entire remaining line to the child parser.
    elif $pos[.posi].passthrough then take_pos($pos; $a)
    elif (.dd | not) and $a == "--" then
      if $pos[.posi].k == "separator" then .dd = true | .posi += 1
      elif $requires_separator then .err = "unexpected separator --"
      else .dd = true end
    elif (.dd | not) and ($a | option) then
      if $flags | has($a) then ($flags[$a]) as $f
        | if $f.k == "opt" then .pending = $a else .opts[$a] = true end
      elif $pos[.posi].rest then take_pos($pos; $a)
      else .err = "unknown option \($a)" end
    else take_pos($pos; $a) end)) as $s
| if $s.err != null then {ok: false, error: $s.err}
  elif $s.pending != null and ($flags[$s.pending].rest != true or ($s.opts[$s.pending] | length) == 0) then
    {ok: false, error: "option \($s.pending) is missing its value"}
  else $s.vals as $v | $s.opts as $opts
    | ([$pos[] | if .k == "separator" then select($s.dd | not) | "--"
      else select((.opt | not) and (.name as $n | $v | has($n) | not)) | (.literal // "<\(.name)>") end]
       + [$named[] | select((.opt or .default | not) and (.flag as $f | $opts | has($f) | not)) | .flag]) as $missing
    | ($v + ($opts | to_entries | map({($flags[.key].name): .value}) | add // {})) as $vals
    | ([$vals | to_entries[] | select($types[.key] == "ack-ref" and (.value | ref_ok | not)) | .key]) as $badref
    | if ($missing | length) > 0 then {ok: false, error: "missing \($missing | join(" "))"}
      elif ($badref | length) > 0 then {ok: false, error: "\($badref[0]) is not a reference from `\($in.name) radio drain` (<sequence>:<generation>[:<pages>])"}
      else {ok: true, vals: $vals, argv: ($spec | map(
          if .k == "lit" then [.v]
          elif .k == "separator" then (if (.opt | not) or $s.dd then ["--"] else [] end)
          elif .k == "pos" then (if (.name as $n | $v | has($n)) then (if .rest then $v[.name] else expand($types[.name]; $v[.name]) end) else [] end)
          elif .k == "opt" then
            .flag as $f | $opts[$f] as $value
            | if $value == null then []
              elif .rest then [$f] + $value
              elif .repeat then [$value[] | $f, .]
              else [$f] + expand($types[.name]; $value) end
          else (if .default or $opts[.flag] then [.flag] else [] end) end) | add // [])}
      end
  end;
. as $in | $in.entry as $e
| ($e.args | map({(.name): .type}) | add // {}) as $types
| [([($e | canonical_form)] + ($e.additional_forms // []) + [$e.form_extension.form // empty]) | to_entries[]
   | .key as $index | .value | lex | .[1:] as $toks
   # A flag-only alternative selects a new form only when the caller supplies its flags.
   | ($index > 0 and ($toks | length > 0) and all($toks[]; option)) as $explicit_flags
   | if ($e.operation | option) and $toks[0] == $e.operation then
     [{k: "lit", v: $e.operation}] + specs($toks[1:]; false; false)
     | bind($in | if .args[0] == $e.operation then .args = .args[1:] else . end; .; $types; $e.args | map(.name))
   else specs($toks; false; $explicit_flags) | bind($in; .; $types; $e.args | map(.name))
   end]
# Prefer a matching extension. The base form can inject a default flag that changes the action.
# Keep the base form first for diagnostics and for the priority of its own alternatives.
| (if $e.form_extension then .[-1] | select(.ok) else empty end)
  // first(.[] | select(.ok)) // .[0]'

# --- the repeat guard ------------------------------------------------------------------------------------------
# An entry that declares an `again` argument runs once per repeat key: the sha256 of its schema and the values
# its repeat_key names (a+b for two), or of --key's value. The key is written after the script succeeds, under
# the explicit home's state folder (JG_STATE_OVERRIDE, else JG_HOME/state); with no home the script is run and
# refuses by itself. A repeat prints "already processed" and exits 0; --again runs it anyway.
repeat_file() {  # <entry> <vals> -> the key file path, or nothing when the entry has no guard or there is no home
  local entry=$1 vals=$2 state mat
  printf '%s' "$entry" | jq -e '.args | any(.[]; .name == "again")' >/dev/null || return 0
  [ -n "${JG_HOME:-}" ] || [ -n "${JG_STATE_OVERRIDE:-}" ] || return 0
  state=${JG_STATE_OVERRIDE:-$JG_HOME/state}
  [ -d "$state" ] || return 0
  mat=$(jq -rn --argjson e "$entry" --argjson v "$vals" '
    if $v | has("key") then "key:" + $v.key
    else [$e.repeat_key | split("+")[] | ($v[.] // "") | if type == "array" then join(" ") else tostring end] | join("\u001f") end')
  printf '%s/.jg-repeat/%s\n' "$state" "$(printf '%s\037%s' "$(printf '%s' "$entry" | jq -r .schema)" "$mat" | sha256sum | cut -d' ' -f1)"
}

# --- the acknowledgement reference (the `ack-ref` argument type and the `ack-ref` emit) ---------------------
# jg-wake-drain.sh asks for `--ack-through <sequence> --recovery-generation <generation> [--pages-ack <n>]` on
# a line of its stderr; the reference is those values as <sequence>:<generation>[:<pages>].
ack_ref_from() {  # <stderr file>
  sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)\( --pages-ack \([0-9][0-9]*\)\)\{0,1\}$/\1:\2\3/p' "$1" \
    | head -n1 | sed 's/ --pages-ack /:/'
}
# An acknowledgement the drain answers with exit 0 but did not complete is a refusal here, so the caller drains
# again: one under a generation that is no longer current ("a newer recovery episode is pending") or through a
# sequence none of its presented rows reach ("nothing was acknowledged").
ack_ref_stale() { grep -q -e 'a newer recovery episode is pending' -e 'nothing was acknowledged through' "$1"; }

# --- run -----------------------------------------------------------------------------------------------------
envelope() {  # <schema> <ok> <data json> <next or empty>
  jq -nc --arg schema "$1" --argjson ok "$2" --argjson data "$3" --arg next "$4" \
    '{schema: ("jg.v1 " + $schema), ok: $ok, data: $data, next: (if $next == "" then null else $next end)}'
}

resolve() {
  contract_all | jq -c --argjson w "$(words_json "$@")" "$ROUTES_JQ
    [.[] as \$entry | \$entry | routes[] | length as \$n | select(\$w[:\$n] == .) | {entry: \$entry, words: \$n}]
    | max_by(.words) // empty"
}

cmd_run() {
  local entry n resolved bound vals script rc maprc out err file next ref data
  [ "$#" -gt 0 ] || { printf '%s: run needs a command\n' "$NAME" >&2; return 2; }
  cmd_check || return 1
  resolved=$(resolve "$@")
  if [ -z "$resolved" ]; then
    if cmd_has "$1"; then
      printf '%s: no command %s. Next: %s help\n' "$NAME" "$*" "$NAME" >&2
    else
      printf '%s: unknown command: %s (try %s help)\n' "$NAME" "$1" "$NAME" >&2
    fi
    return 2
  fi
  entry=$(printf '%s' "$resolved" | jq -c .entry)
  n=$(printf '%s' "$resolved" | jq .words)
  shift "$n"
  if [ "$(printf '%s' "$entry" | jq -r '.passthrough // false')" = true ]; then
    exec "$ROOT/$(printf '%s' "$entry" | jq -r .script)" "$@"
  fi
  bound=$(jq -nc --argjson entry "$entry" --arg name "$NAME" --argjson args "$(words_json "$@")" \
    "{entry: \$entry, name: \$name, args: \$args} | $BIND_JQ") || { printf '%s: the command contract could not be read\n' "$NAME" >&2; return 5; }
  if [ "$(printf '%s' "$bound" | jq -r .ok)" != true ]; then
    printf '%s: %s. Usage: %s %s %s\n' "$NAME" "$(printf '%s' "$bound" | jq -r .error)" "$NAME" \
      "$(printf '%s' "$entry" | jq -r '.path | join(" ")')" "$(printf '%s' "$entry" | jq -r '.form | split(" ")[1:] | join(" ")')" >&2
    return 2
  fi
  vals=$(printf '%s' "$bound" | jq -c .vals)
  eval "set -- $(printf '%s' "$bound" | jq -r '.argv | map(@sh) | join(" ")')"
  script=$ROOT/$(printf '%s' "$entry" | jq -r .script)
  file=$(repeat_file "$entry" "$vals")
  if [ -n "$file" ] && [ -e "$file" ] && [ "$(printf '%s' "$vals" | jq -r '.again // false')" != true ]; then
    envelope "$(printf '%s' "$entry" | jq -r .schema)" true '{"status":"already processed"}' "add --again to run it again"
    return 0
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/jg-dispatch.XXXXXX") || return 5
  err=$(mktemp "${TMPDIR:-/tmp}/jg-dispatch.XXXXXX") || { rm -f -- "$out"; return 5; }
  if printf '%s' "$entry" | jq -e --arg first "${1:-}" '.stream_stdout_for // [] | index($first) != null' >/dev/null; then
    # Show progress as it arrives and keep stdout reserved for the final envelope.
    "$script" "$@" 2>"$err" | tee "$out" >&2
    rc=${PIPESTATUS[0]}
  else
    case "$script:${1:-}" in
    "$ROOT/bin/jg-procevent-remote-reply.sh":arm-locked|\
    "$ROOT/bin/jg-procevent-remote-reply.sh":retire-quiesce-locked|\
    "$ROOT/bin/jg-procevent-remote-reply.sh":retire-finalize-locked)
      # A Bash subshell keeps the dispatcher's PPID for the adapter's lock check.
      # It isolates the adapter's variables and exits so we can still return the envelope.
      # Lint the adapter as a separate script, matching this isolation boundary.
      # shellcheck source=/dev/null
      ( . "$script" "$@" ) >"$out" 2>"$err" ;;
    *) "$script" "$@" >"$out" 2>"$err" ;;
    esac
    rc=$?
  fi
  cat "$err" >&2
  # The script's exit through the entry's exit map; a code the map does not name is a refusal.
  maprc=$(printf '%s' "$entry" | jq -r --arg rc "$rc" '.exits[$rc] // (if $rc == "0" then 0 else 1 end)')
  if [ "$maprc" = 0 ] && printf '%s' "$entry" | jq -e '.args | any(.[]; .type == "ack-ref")' >/dev/null && ack_ref_stale "$err"; then
    maprc=1
  fi
  data=$(jq -c -R -s '. as $t | (try ($t | fromjson) catch {stdout: $t})' < "$out")
  [ -n "$data" ] || data='{}'
  next=$(printf '%s' "$entry" | jq -r '.next // empty')
  if printf '%s' "$entry" | jq -e '.emits == "ack-ref"' >/dev/null; then
    ref=$(ack_ref_from "$err")
    data=$(printf '%s' "$data" | jq -c --arg ref "$ref" '. + {ack_ref: (if $ref == "" then null else $ref end)}')
    [ -z "$ref" ] || next="$NAME radio ack $ref"
  fi
  if [ "$maprc" = 0 ]; then
    envelope "$(printf '%s' "$entry" | jq -r .schema)" true "$data" "$next"
    if [ -n "$file" ]; then
      mkdir -p "${file%/*}" && date +%s > "$file" || printf '%s: the repeat record could not be written; a repeat will run again\n' "$NAME" >&2
    fi
  else
    envelope "$(printf '%s' "$entry" | jq -r .schema)" false "$(jq -nc --rawfile e "$err" --argjson d "$data" '$d + {error: $e}')" "$next"
    [ -z "$next" ] || printf 'Next: %s\n' "$next" >&2
  fi
  rm -f -- "$out" "$err"
  return "$maprc"
}

if [ "${1:-}" = --as ]; then NAME=${2:?--as needs a name}; shift 2; fi
case "${1:-}" in
  check) cmd_check ;;
  has) shift; cmd_has "$@" ;;
  matches) shift; resolve "$@" | jq -e '.words >= 2' >/dev/null ;;
  help) cmd_help ;;
  run) shift; cmd_run "$@" ;;
  *) printf 'usage: dispatch.sh [--as <name>] check | has <word> | matches <words...> | help | run <path words> [args...]\n' >&2; exit 2 ;;
esac
