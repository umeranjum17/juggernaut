#!/usr/bin/env bash
# jg-status-states-lib.sh - read the core status-state contract (defaults/status-states.tsv). Source only.
#
#   jg_states_table                  the table path (JG_STATES_TABLE overrides it, for a test home)
#   jg_states_words <state|close|wait|reason>   the words of that kind, one per line, in table order; the declared-wait
#                                    verb is spelled as JG_CLASSIFY_PAUSED_VERB says
#   jg_states_line                   the one `States: a, b, c.` line every brief and charter carries
#   jg_states_check_text <file>      print one `<file>:<line>: <kind>: <what>` finding per line of the file that defines
#                                    a status state another way than the table; return 1 when there is one
#   jg_states_render_file <file>     rewrite each `States:` line of the file to jg_states_line; print the line numbers
#                                    it changed (none when the file already matched)
# The table is the only place a state word is typed; the brief scaffold and the charter take it from here.
# Needs bash 3.2: no associative arrays.

_jg_states_here=${BASH_SOURCE[0]%/*}
[ "$_jg_states_here" != "${BASH_SOURCE[0]}" ] || _jg_states_here=.

jg_states_table() { printf '%s\n' "${JG_STATES_TABLE:-$_jg_states_here/../defaults/status-states.tsv}"; }

jg_states_words() {  # <kind>
  local table verb=${JG_CLASSIFY_PAUSED_VERB:-paused}
  table=$(jg_states_table)
  [ -r "$table" ] || { echo "jg-status-states: cannot read the status-state table $table" >&2; return 1; }
  awk -F'\t' -v kind="$1" -v verb="$verb" '
    /^#/ || NF < 2 || $1 != kind { next }
    kind == "state" || kind == "close" { print ($2 == "paused" ? verb : $2); next }
    { n = split($2, w, " "); for (i = 1; i <= n; i++) print w[i] }
  ' "$table"
}

jg_states_line() {
  local words
  words=$(jg_states_words state) || return 1
  [ -n "$words" ] || { echo "jg-status-states: the table names no state" >&2; return 1; }
  printf 'States: %s.\n' "$(printf '%s\n' "$words" | paste -sd, - | sed 's/,/, /g')"
}

# A comma or space separated list as sorted words, so two spellings of one set compare equal.
_jg_states_set() { tr ',;' '  ' | tr -s ' ' '\n' | sed -e 's/[.)]*$//' -e '/^$/d' | sort -u | paste -sd' ' -; }

jg_states_check_text() {  # <file>
  local file=$1 n=0 line rest span verb states closes want got bad=0 pv
  [ -r "$file" ] || { echo "jg-status-states: cannot read $file" >&2; return 2; }
  states=$(jg_states_words state | paste -sd' ' -) || return 2
  closes=$(jg_states_words close | paste -sd' ' -)
  pv=${JG_CLASSIFY_PAUSED_VERB:-paused}
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # a `States:` line lists exactly the table's states
    if [[ $line =~ ^[[:space:]]*States:[[:space:]]*(.*)$ ]]; then
      got=$(printf '%s' "${BASH_REMATCH[1]}" | _jg_states_set)
      want=$(printf '%s' "$states" | _jg_states_set)
      if [ "$got" != "$want" ]; then
        printf '%s:%s: states: lists "%s" but the core contract lists "%s"\n' "$file" "$n" "${BASH_REMATCH[1]%.}" "${states// /, }"; bad=1
      fi
    fi
    # a code span that writes a status line starts with a state word or a closing word
    rest=$line
    while [[ $rest =~ \`([A-Za-z][A-Za-z-]*)\ \[(at|key|wait|reason)= ]]; do
      verb=${BASH_REMATCH[1]}
      case " $states $closes " in
        *" $verb "*) ;;
        *) printf '%s:%s: state-word: writes "%s", which is not a status state of the core contract (%s)\n' "$file" "$n" "$verb" "$states"; bad=1 ;;
      esac
      rest=${rest#*"${BASH_REMATCH[0]}"}
    done
    # a declared wait always carries both its wait and its reason
    rest=$line
    while [[ $rest =~ \`$pv\ \[[^\`]*\` ]]; do
      span=${BASH_REMATCH[0]}
      case $span in *"[wait="*"[reason="*|*"[reason="*"[wait="*) ;;
        *) printf '%s:%s: wait-shape: %s lacks [wait=...] or [reason=...], which the core contract requires\n' "$file" "$n" "$span"; bad=1 ;;
      esac
      rest=${rest#*"$span"}
    done
    # a stated vocabulary of wait or reason words is the table's
    for kind in wait reason; do
      if [[ $line =~ \`?$kind\`?\ (is\ )?one\ of\ ([A-Za-z,\ -]+) ]]; then
        got=$(printf '%s' "${BASH_REMATCH[2]}" | _jg_states_set)
        want=$(jg_states_words "$kind" | paste -sd' ' - | _jg_states_set)
        if [ "$got" != "$want" ]; then
          printf '%s:%s: %s-words: lists "%s" but the core contract lists "%s"\n' "$file" "$n" "$kind" "${BASH_REMATCH[2]}" "$(jg_states_words "$kind" | paste -sd' ' - | sed 's/ /, /g')"; bad=1
        fi
      fi
    done
  done < "$file"
  return "$bad"
}

jg_states_render_file() {  # <file>
  local file=$1 want tmp n=0 line changed=''
  want=$(jg_states_line) || return 1
  tmp=$(mktemp "$file.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [[ $line =~ ^([[:space:]]*)States:[[:space:]] ]] && [ "$line" != "${BASH_REMATCH[1]}$want" ]; then
      line=${BASH_REMATCH[1]}$want
      changed="$changed $n"
    fi
    printf '%s\n' "$line"
  done < "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -n "$changed" ]; then
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    printf '%s\n' "${changed# }"
  else
    rm -f -- "$tmp"
  fi
}
