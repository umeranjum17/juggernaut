#!/usr/bin/env bash
# Durable signal presentation and outcome handling, owned here for every home.
# Called under .status-presentation-lock; the drain also holds the queue lock
# while checking/committing an acknowledgement. The JSON journal is per actor.
# Its captured endpoint advances on presentation; its events remain until ack.
# Each row must have a successful presentation and every OUTCOME a disposition.
# State transitions: core/machines/tables/wake-status.tsv.
# The journal keeps every event until its ack, so it can reach tens of megabytes.
# Present and ack therefore read it once into per-task records
# (JG_WAKE_STATUS_TASKS) and write it back once: a pass over the whole journal for
# every signal row outlasts the caller's time bound, the drain is killed before
# the new endpoint is saved, and the next ack refuses an unchanged status file.
# Each event is held once per id and carries .at, the epoch of the drain that first
# presented it, so --outcomes-before classifies every outcome presented before a cut
# in one pass (an event from a journal written before .at existed counts as older
# than any cut). An outcome with a disposition is never asked for again, and a
# refused acknowledgement counts every open outcome at once and lists a bounded page.

jg_wake_status_index() { # JG_WAKE_STATUS_DATA -> JG_WAKE_STATUS_TASKS[task]=record
  local names recs i=0 name
  declare -gA JG_WAKE_STATUS_TASKS=()
  names=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -r 'to_entries[].key') || return 1
  recs=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -c 'to_entries[].value') || return 1
  [ -n "$names" ] || return 0
  local -a rec_lines
  mapfile -t rec_lines <<EOF
$recs
EOF
  while IFS= read -r name; do
    JG_WAKE_STATUS_TASKS[$name]=${rec_lines[$i]}
    i=$((i + 1))
  done <<EOF
$names
EOF
}

jg_wake_status_unindex() { # JG_WAKE_STATUS_TASKS -> JG_WAKE_STATUS_DATA
  local name
  JG_WAKE_STATUS_DATA=$(for name in "${!JG_WAKE_STATUS_TASKS[@]}"; do
    printf '%s\n%s\n' "$name" "${JG_WAKE_STATUS_TASKS[$name]}"
  done | jq -cRn '[inputs] as $a | reduce range(0; $a | length; 2) as $i ({}; .[$a[$i]] = ($a[$i + 1] | fromjson))') || return 1
}

jg_wake_status_load() {
  JG_WAKE_STATUS_FILE="$STATE/.wake-status-$ACTOR.json"
  JG_WAKE_STATUS_DATA='{}'
  if [ -e "$JG_WAKE_STATUS_FILE" ] || [ -L "$JG_WAKE_STATUS_FILE" ]; then
    [ -f "$JG_WAKE_STATUS_FILE" ] && [ ! -L "$JG_WAKE_STATUS_FILE" ] || {
      printf 'wake drain: unsafe status journal %s\n' "$JG_WAKE_STATUS_FILE" >&2; return 1;
    }
    JG_WAKE_STATUS_DATA=$(cat "$JG_WAKE_STATUS_FILE") || return 1
    printf '%s' "$JG_WAKE_STATUS_DATA" | jq -e 'type == "object" and all(.[];
      (.ident | type == "string") and (.end | type == "number" and . >= 0 and floor == .) and
      (.events | type == "array" and all(.[]; (.id | test("^[0-9a-f]{64}$")) and
        (.kind == "STATUS" or .kind == "ACTION" or .kind == "OUTCOME" or .kind == "OUTCOME ACTION") and (.line | type == "string") and
        (.at == null or (.at | type == "number" and . >= 0 and floor == .)) and
        (.disposition == null or (.disposition | (.kind == "relayed" or .kind == "classified") and (.reference | test("\\S")))))) and
      (.seqs | type == "array" and all(.[]; type == "number" and . > 0 and floor == .)))' >/dev/null \
      || { printf 'wake drain: invalid status journal %s\n' "$JG_WAKE_STATUS_FILE" >&2; return 1; }
  fi
}

jg_wake_status_save() {
  local tmp
  tmp=$(mktemp "$JG_WAKE_STATUS_FILE.XXXXXX") || return 1
  if printf '%s\n' "$JG_WAKE_STATUS_DATA" > "$tmp" && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$JG_WAKE_STATUS_FILE"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

# One task's replay shows its newest JG_WAKE_STATUS_ROOM events (set by the presentation) and one line counting the rest.
# The journal keeps every event until its ack and a status file read from its first byte holds thousands, so replaying
# them all made one drain tens of megabytes and minutes long. An outcome the cap hides before any drain showed it can
# never be shown, so it is classified as not shown in the same pass; the ack then asks only for outcomes a reader saw. Sets JG_WAKE_STATUS_RECORD.
jg_wake_status_print_task() { # <task> <record>
  local task=$1 room=$JG_WAKE_STATUS_ROOM shown out
  JG_WAKE_STATUS_RECORD=$2
  out=$(printf '%s' "$JG_WAKE_STATUS_RECORD" | jq -r --arg t "$task" --argjson room "$room" '
    .events as $all | ([($all | length) - $room, 0] | max) as $cut | $all[$cut:] as $shown |
    ($shown | length),
    ($shown[] | "wake annotation: \(.kind): \($t).status: \(.line)",
      (if (.kind | startswith("OUTCOME")) and .disposition == null then "OUTCOME_REQUIRED: \(.id)" else empty end)),
    (if $cut > 0 then "wake annotation: \($t).status: \($cut) earlier event(s) not shown, "
      + "\($all[:$cut] | map(select((.kind | startswith("OUTCOME")) and .disposition == null and .shown != true)) | length) of them outcomes, "
      + "classified as not shown; the full text stays in state/\($t).status"
      + ($all[:$cut] | map(select((.kind | startswith("OUTCOME")) and .disposition == null and .shown == true)) | length
        | if . > 0 then "; \(.) outcome(s) an earlier drain showed still need a relay or classification" else "" end)
      else empty end)') || return 1
  shown=${out%%$'\n'*}
  JG_WAKE_STATUS_RECORD=$(printf '%s' "$JG_WAKE_STATUS_RECORD" | jq -c --argjson room "$shown" '
    (.events | length) as $n | .events |= to_entries | .events |= map(
      if .key >= $n - $room then .value.shown = true
      elif (.value.kind | startswith("OUTCOME")) and .value.disposition == null and .value.shown != true
      then .value.disposition = {kind: "classified", reference: "not shown: replay cap"} else . end | .value)') || return 1
  [ "$out" = "$shown" ] || printf '%s\n' "${out#*$'\n'}" || return 1
}

jg_wake_status_present() { # <raw actor rows> <status snapshot>
  local rows=$1 snapshot=$2 _epoch seq kind key _payload task end ident offset data lines record printed='' tasks cap now
  now=$(date +%s) || return 1
  # Each signalled task gets an equal share of JG_WAKE_ANNOTATION_CAP events (default 40), at most JG_WAKE_STATUS_TASK_CAP
  # (default 10) and at least one, so a late task is never starved by an early one and the replay stays bounded.
  local JG_WAKE_STATUS_ROOM=${JG_WAKE_STATUS_TASK_CAP:-10}
  case "$JG_WAKE_STATUS_ROOM" in ''|*[!0-9]*) JG_WAKE_STATUS_ROOM=10 ;; esac
  cap=${JG_WAKE_ANNOTATION_CAP:-40}
  case "$cap" in ''|*[!0-9]*) cap=40 ;; esac
  tasks=$(printf '%s\n' "$rows" | awk -F '\t' '$3 == "signal" && !seen[$4]++ { n++ } END { print n + 0 }') || return 1
  [ "$tasks" -gt 0 ] || tasks=1
  [ $((cap / tasks)) -ge "$JG_WAKE_STATUS_ROOM" ] || JG_WAKE_STATUS_ROOM=$((cap / tasks))
  [ "$JG_WAKE_STATUS_ROOM" -ge 1 ] || JG_WAKE_STATUS_ROOM=1
  local -A new_seqs=()
  jg_wake_status_load && jg_wake_status_index || return 1
  while IFS=$'\t' read -r _epoch seq kind key _payload; do
    [ "$kind" = signal ] || continue
    jg_wake_status_key_map "$key" || continue
    task=${JG_WAKE_STATUS_KEY%.status}
    # Rows after a task's first add only their sequence: its span is already presented.
    if [ -n "${new_seqs[$task]+x}" ]; then new_seqs[$task]+=",$seq"; continue; fi
    new_seqs[$task]=$seq
    record=${JG_WAKE_STATUS_TASKS[$task]:-'{"ident":"","end":0,"events":[],"seqs":[]}'}
    data=$(printf '%s\n' "$snapshot" | awk -F '\t' -v t="$task" '$1 == t { print $2 "\t" $3 }') || return 1
    if [ -n "$data" ]; then
      end=${data%%$'\t'*}; ident=${data#*$'\t'}
      offset=$(printf '%s' "$record" | jq -r --arg i "$ident" --argjson e "$end" 'if .ident == $i and .end <= $e then .end else 0 end') || return 1
      lines=$(_jg_status_read_span "$STATE/$task.status" "$offset" "$((end - offset))") || return 1
      [ "$(_jg_open_decisions_file_ident "$STATE/$task.status")" = "$ident" ] || return 1
      # Include the physical home, file identity and span start in the id.
      # A rotated file or a different home cannot reuse a handled outcome.
      data=$(printf '%s' "$lines" | perl -MDigest::SHA=sha256_hex -MJSON::PP -MEncode=decode_utf8 -e '
        my ($home,$task,$ident,$pos,$now)=@ARGV; my @events;
        while (my $line=<STDIN>) {
          my $start=$pos; $pos+=length($line); chomp $line;
          next unless $line =~ /\S/;
          my $action=$line =~ /^(blocked|needs-decision)(?:[\s:]|$)/i;
          my $outcome=$line =~ /^(done|failed)(?:[\s:]|$)|\b(report|pr|landed)\b|https:\/\/\S+\/pull\//i;
          my $kind=$outcome ? ($action ? "OUTCOME ACTION" : "OUTCOME") : $action ? "ACTION" : "STATUS";
          push @events,{id=>sha256_hex(join("\0",$home,$task,$ident,$start,$line)),kind=>$kind,line=>decode_utf8($line),at=>$now+0};
        }
        print JSON::PP->new->utf8->encode(\@events);
      ' "$(cd "$STATE" && pwd -P)" "$task" "$ident" "$offset" "$now") || return 1
      # An id already held is the same line at the same offset of the same file: keep the held event and its disposition.
      record=$(printf '%s\n%s\n' "$record" "$data" | jq -cs --arg i "$ident" --argjson e "$end" \
        '(.[0].events | map({key: .id, value: true}) | from_entries) as $held
         | .[0].ident=$i | .[0].end=$e | .[0].events += [.[1][] | select($held[.id] | not)] | .[0]') || return 1
    elif [ -e "$STATE/$task.status" ] || [ -L "$STATE/$task.status" ]; then
      printf 'wake drain: cannot present signalled status %s safely\n' "$task" >&2
      return 1
    fi
    if [[ "$printed" != *"/$task/"* ]]; then
      jg_wake_status_print_task "$task" "$record" || return 1
      record=$JG_WAKE_STATUS_RECORD
      printed="$printed/$task/"
    fi
    JG_WAKE_STATUS_TASKS[$task]=$record
  done <<EOF
$rows
EOF
  for task in "${!new_seqs[@]}"; do
    JG_WAKE_STATUS_TASKS[$task]=$(printf '%s' "${JG_WAKE_STATUS_TASKS[$task]}" | jq -c --argjson s "[${new_seqs[$task]}]" \
      '.seqs = ((.seqs + $s) | unique)') || return 1
  done
  jg_wake_status_unindex || return 1
  if [ -n "$printed" ]; then
    printf 'OUTCOME_HANDLING: use bin/jg-wake-drain.sh --outcome ID --relayed REFERENCE or --classified REASON before acknowledgement, or --outcomes-before %s --classified REASON for every outcome presented so far.\n' "$((now + 1))" || return 1
  fi
  jg_wake_status_save
}

jg_wake_status_handle() { # <id> <relayed|classified> <reference|reason>
  local id=$1 mode=$2 reason=$3
  case "$id" in ''|*[!0-9a-f]*) return 2 ;; esac
  [ "${#id}" -eq 64 ] && [[ "$reason" = *[![:space:]]* ]] || return 2
  jg_wake_status_load || return 1
  if ! printf '%s' "$JG_WAKE_STATUS_DATA" | jq -e --arg id "$id" \
    'any(.[]?.events[]?; .id == $id and (.kind | startswith("OUTCOME")))' >/dev/null; then
    printf 'wake drain: outcome %s has not been presented to this actor in this home\n' "$id" >&2
    return 1
  fi
  JG_WAKE_STATUS_DATA=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -c --arg id "$id" --arg m "$mode" --arg r "$reason" \
    'map_values(.events |= map(if .id == $id then .disposition={kind:$m,reference:$r} else . end))') || return 1
  jg_wake_status_save
}

# Classify every open outcome first presented before <cut> with one reason, in one pass over the journal.
jg_wake_status_classify_before() { # <cut epoch> <reason>
  local cut=$1 reason=$2 out
  case "$cut" in ''|*[!0-9]*) return 2 ;; esac
  [[ "$reason" = *[![:space:]]* ]] || return 2
  jg_wake_status_load || return 1
  out=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -c --argjson cut "$cut" --arg r "$reason" '
    def open: (.kind | startswith("OUTCOME")) and .disposition == null and (.at // 0) < $cut;
    ([.[]?.events[]? | select(open)] | length),
    map_values(.events |= map(if open then .disposition = {kind: "classified", reference: $r} else . end))') || return 1
  JG_WAKE_STATUS_DATA=${out#*$'\n'}
  jg_wake_status_save || return 1
  printf 'wake drain: classified %s outcome(s) presented before %s\n' "${out%%$'\n'*}" "$cut"
}

jg_wake_status_ack() { # <check|commit> <actor row file> <cutoff>
  local phase=$1 rows=$2 cutoff=$3 _epoch seq kind key _payload task record unresolved='' ident size path
  local -A task_seqs=() task_checked=()
  jg_wake_status_load && jg_wake_status_index || return 1
  if [ "$phase" = check ]; then
    JG_WAKE_STATUS_ACK_ROWS=$(awk -F '\t' -v rows="$rows" 'BEGIN {while ((getline s < rows)>0) keep[s]=1} $2 in keep' "$JG_WAKE_QUEUE") || return 1
  fi
  while IFS=$'\t' read -r _epoch seq kind key _payload; do
    [ "$kind" = signal ] && [ "$seq" -le "$cutoff" ] || continue
    jg_wake_status_key_map "$key" || continue
    task=${JG_WAKE_STATUS_KEY%.status}
    record=${JG_WAKE_STATUS_TASKS[$task]:-'{}'}
    if [ "$phase" = check ]; then
      if [ -z "${task_seqs[$task]+x}" ]; then
        task_seqs[$task]=" $(printf '%s' "$record" | jq -r '(.seqs // []) | map(tostring) | join(" ")') " || return 1
      fi
      if [[ "${task_seqs[$task]}" != *" $seq "* ]]; then
        printf 'wake drain: signal %s row %s has not been fully presented; drain again before acknowledgement\n' "$key" "$seq" >&2
        return 1
      fi
      # The file and outcome checks depend on the task alone, not the row.
      [ -z "${task_checked[$task]+x}" ] || continue
      task_checked[$task]=1
      path="$STATE/$task.status"
      if [ -e "$path" ] || [ -L "$path" ]; then
        [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || {
          printf 'wake drain: signalled status %s is no longer readable safely\n' "$key" >&2; return 1;
        }
        ident=$(_jg_open_decisions_file_ident "$path") || return 1
        size=$(_jg_status_file_size "$path") || return 1
        if ! printf '%s' "$record" | jq -e --arg i "$ident" --argjson e "$size" '.ident == $i and .end == $e' >/dev/null; then
          printf 'wake drain: status %s changed after presentation; drain again before acknowledgement\n' "$key" >&2
          return 1
        fi
      fi
      unresolved+=$(printf '%s' "$record" | jq -r --arg t "$task" \
        '.events[] | select((.kind | startswith("OUTCOME")) and .disposition == null) | "\(.id)\t\($t)"') || return 1
      unresolved+=$'\n'
    elif [ -z "${task_checked[$task]+x}" ]; then
      task_checked[$task]=1
      JG_WAKE_STATUS_TASKS[$task]=$(printf '%s' "$record" | jq -c --argjson n "$cutoff" \
        '.events=[] | .seqs |= map(select(. > $n))') || return 1
    fi
  done <<EOF
$JG_WAKE_STATUS_ACK_ROWS
EOF
  if [[ "$unresolved" = *[![:space:]]* ]]; then
    # One refusal for every open outcome in the batch, each id once and at most 20 listed.
    printf '%s' "$unresolved" | awk -F '\t' -v cut="$(($(date +%s) + 1))" '
      NF >= 2 && !seen[$1]++ { n++; if (!(($2) in tasks)) { tasks[$2] = 1; t++ } if (n <= 20) ids = ids $1 "\n" }
      END {
        printf "wake drain: acknowledgement refused; %d outcome(s) in %d task(s) need a relay or classification first:\n%s", n, t, ids
        if (n > 20) printf "wake drain: %d more not listed\n", n - 20
        printf "wake drain: handle each with --outcome ID --relayed REFERENCE|--classified REASON, or classify every outcome presented so far with bin/jg-wake-drain.sh --outcomes-before %s --classified REASON\n", cut
      }' >&2
    return 1
  fi
  [ "$phase" != commit ] || { jg_wake_status_unindex && jg_wake_status_save; }
}
