#!/usr/bin/env bash
# Durable signal presentation and outcome handling, owned here for every home.
# Called under .status-presentation-lock; the drain also holds the queue lock
# while checking/committing an acknowledgement. The JSON journal is per actor.
# Its captured endpoint advances on presentation; its events remain until ack.
# Each row must have a successful presentation and every OUTCOME a disposition.
# State transitions: core/machines/tables/wake-status.tsv.

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

jg_wake_status_present() { # <raw actor rows> <status snapshot>
  local rows=$1 snapshot=$2 _epoch seq kind key _payload task end ident offset data lines record output printed=''
  jg_wake_status_load || return 1
  while IFS=$'\t' read -r _epoch seq kind key _payload; do
    [ "$kind" = signal ] || continue
    jg_wake_status_key_map "$key" || continue
    task=${JG_WAKE_STATUS_KEY%.status}
    record=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -c --arg t "$task" '.[$t] // {ident:"",end:0,events:[],seqs:[]}') || return 1
    data=$(printf '%s\n' "$snapshot" | awk -F '\t' -v t="$task" '$1 == t { print $2 "\t" $3 }') || return 1
    if [ -n "$data" ]; then
      end=${data%%$'\t'*}; ident=${data#*$'\t'}
      offset=$(printf '%s' "$record" | jq -r --arg i "$ident" --argjson e "$end" 'if .ident == $i and .end <= $e then .end else 0 end') || return 1
      lines=$(_jg_status_read_span "$STATE/$task.status" "$offset" "$((end - offset))") || return 1
      [ "$(_jg_open_decisions_file_ident "$STATE/$task.status")" = "$ident" ] || return 1
      # Include the physical home, file identity and span start in the id.
      # A rotated file or a different home cannot reuse a handled outcome.
      data=$(printf '%s' "$lines" | perl -MDigest::SHA=sha256_hex -MJSON::PP -MEncode=decode_utf8 -e '
        my ($home,$task,$ident,$pos)=@ARGV; my @events;
        while (my $line=<STDIN>) {
          my $start=$pos; $pos+=length($line); chomp $line;
          next unless $line =~ /\S/;
          my $action=$line =~ /^(blocked|needs-decision)(?:[\s:]|$)/i;
          my $outcome=$line =~ /^(done|failed)(?:[\s:]|$)|\b(report|pr|landed)\b|https:\/\/\S+\/pull\//i;
          my $kind=$outcome ? ($action ? "OUTCOME ACTION" : "OUTCOME") : $action ? "ACTION" : "STATUS";
          push @events,{id=>sha256_hex(join("\0",$home,$task,$ident,$start,$line)),kind=>$kind,line=>decode_utf8($line)};
        }
        print JSON::PP->new->utf8->encode(\@events);
      ' "$(cd "$STATE" && pwd -P)" "$task" "$ident" "$offset") || return 1
      record=$(printf '%s\n%s\n' "$record" "$data" | jq -cs --arg i "$ident" --argjson e "$end" \
        '.[0].ident=$i | .[0].end=$e | .[0].events += .[1] | .[0]') || return 1
    elif [ -e "$STATE/$task.status" ] || [ -L "$STATE/$task.status" ]; then
      printf 'wake drain: cannot present signalled status %s safely\n' "$task" >&2
      return 1
    fi
    if [[ "$printed" != *"/$task/"* ]]; then
      output=$(printf '%s' "$record" | jq -r --arg t "$task" '.events[] |
      "wake annotation: \(.kind): \($t).status: \(.line)",
      (if .kind | startswith("OUTCOME") then "OUTCOME_REQUIRED: \(.id)" else empty end)') || return 1
      [ -z "$output" ] || printf '%s\n' "$output" || return 1
      printed="$printed/$task/"
    fi
    record=$(printf '%s' "$record" | jq -c --argjson s "$seq" '.seqs = ((.seqs + [$s]) | unique)') || return 1
    JG_WAKE_STATUS_DATA=$(printf '%s\n%s\n' "$JG_WAKE_STATUS_DATA" "$record" | jq -cs --arg t "$task" '.[0] + {($t):.[1]}') || return 1
  done <<EOF
$rows
EOF
  if [ -n "$printed" ]; then
    printf 'OUTCOME_HANDLING: use bin/jg-wake-drain.sh --outcome ID --relayed REFERENCE or --classified REASON before acknowledgement.\n' || return 1
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

jg_wake_status_ack() { # <check|commit> <actor row file> <cutoff>
  local phase=$1 rows=$2 cutoff=$3 _epoch seq kind key _payload task record unresolved ident size path
  jg_wake_status_load || return 1
  if [ "$phase" = check ]; then
    JG_WAKE_STATUS_ACK_ROWS=$(awk -F '\t' -v rows="$rows" 'BEGIN {while ((getline s < rows)>0) keep[s]=1} $2 in keep' "$JG_WAKE_QUEUE") || return 1
  fi
  while IFS=$'\t' read -r _epoch seq kind key _payload; do
    [ "$kind" = signal ] && [ "$seq" -le "$cutoff" ] || continue
    jg_wake_status_key_map "$key" || continue
    task=${JG_WAKE_STATUS_KEY%.status}
    record=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -c --arg t "$task" '.[$t] // {}') || return 1
    if [ "$phase" = check ]; then
      if ! printf '%s' "$record" | jq -e --argjson s "$seq" '(.seqs // []) | index($s) != null' >/dev/null; then
        printf 'wake drain: signal %s row %s has not been fully presented; drain again before acknowledgement\n' "$key" "$seq" >&2
        return 1
      fi
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
      unresolved=$(printf '%s' "$record" | jq -r '.events[] | select((.kind | startswith("OUTCOME")) and .disposition == null) | .id') || return 1
      if [ -n "$unresolved" ]; then
        printf 'wake drain: acknowledgement refused; relay or classify each outcome first:\n%s\n' "$unresolved" >&2
        return 1
      fi
    else
      JG_WAKE_STATUS_DATA=$(printf '%s' "$JG_WAKE_STATUS_DATA" | jq -c --arg t "$task" --argjson n "$cutoff" \
        '.[$t].events=[] | .[$t].seqs |= map(select(. > $n))') || return 1
    fi
  done <<EOF
$JG_WAKE_STATUS_ACK_ROWS
EOF
  [ "$phase" != commit ] || jg_wake_status_save
}
