#!/usr/bin/env bash
# jg-bus-leaf.sh - a remote squad_lead home on the home bus over a NATS leaf
# node, in shadow: the SSH route stays authoritative.
#
# WHY THIS EXISTS (migration step 5f). A remote lead's home reaches the main home
# over SSH today: bin/jg-on.sh carries one command at a time and returns ssh's
# status. The bus is already in place (steps 5a-5e), so the same reach can ride it
# as a leaf node: the remote home runs its own message server, that server holds a
# leaf connection to the home bus, and interest decides what crosses. This step
# puts that leaf in SHADOW. Both paths run, the SSH path still carries every real
# delivery, and nothing switches until the replay below is green.
#
# docs/bus-leaf-shadow.md owns the event model, the parity contract, the measured
# line count of each path and what a switch would remove. This script is the one
# owner of the leaf's mechanics: the two server configurations (rendered from one
# key file), the canonical event row, the two-sided replay, and the deliberate
# corruption that keeps that replay from being vacuous.
#
# CONTRACT (this header is the one owner of the leaf's shape here).
#   config   One key file decides everything: defaults/bus-leaf, then the home's
#            config/bus-leaf, then JG_BUS_LEAF_<KEY> in the environment; the first
#            source carrying a key wins and no address, subject or credential is
#            hard-coded here. No toggle file turns it on, because a leaf is started
#            by an operator rather than on every poll. `config` prints the values in
#            force.
#   hub      The home bus side: the base server configuration in force
#            (core/bus/nats.conf, or the home's config/bus/nats.conf) with one
#            leafnodes block appended - the listen address, and the user and
#            password a leaf must present. Rendered into the runtime directory, so
#            the base file is never edited. `serve hub` starts that bus side for a
#            run; giving a home's long-running bus service the same block is part of
#            the switch, not of this step.
#   leaf     The remote home side: its own message server plus one remote entry
#            dialling the hub's leaf listener as that user. Rendered from the same
#            key file into the runtime directory.
#   event    One row is the whole vocabulary, and every surface of a lead's home
#            gets the same row:
#              <index> <tab> <kind> <tab> <key> <tab> <payload>
#            `task` appends a steering-inbox record through the production writer
#            (bin/jg-task-inbox-lib.sh), `status` appends one status line, and
#            `wake` raises one queue row through bin/jg-wake-lib.sh. Fields are
#            cleaned the way the wake queue already cleans them, so one event stays
#            one row.
#   ledger   $STATE/bus-leaf-view.tsv (or <ledger-dir>/bus-leaf-view.tsv with
#            --state) is the ordered view of the events the home received. A row is
#            written only after its own record write succeeded, and its line count
#            is the applied index, so an event is applied exactly once and in
#            order: an index that is not the next one is a repeat or a gap and is
#            ignored, and the sender resends from the first missing index.
#   parity   `parity` runs one event set twice, once per path, and compares the two
#            ordered views row by row. The SSH leg calls the real transport
#            (bin/jg-on.sh) once per event; the leaf leg starts a hub and a leaf
#            from the rendered configurations, subscribes on the leaf's own client
#            address, and publishes the same set on the hub. Both legs write into
#            separate directories under --state, so a run never touches a real
#            home's records. It starts its own servers on free ports, so a run never
#            collides with a bus that is already up, and it bounds every wait, so a
#            leg that delivers nothing fails instead of hanging. `--corrupt` tampers
#            with one event on the leaf leg, and a green comparison after that would
#            mean the check is vacuous.
#   write    Nothing here edits the file path's plumbing or the SSH path's records.
#            `parity` writes only under its own --state directory and the runtime
#            directory it starts.
#
# Usage:
#   jg-bus-leaf.sh config [<key>]
#   jg-bus-leaf.sh serve hub|leaf
#   jg-bus-leaf.sh stop
#   jg-bus-leaf.sh send <index> <kind> <key> <payload>   publish one event
#   jg-bus-leaf.sh send < rows                          publish a batch, in order
#   jg-bus-leaf.sh consume --state <dir> [--wait <duration>]
#   jg-bus-leaf.sh apply --state <dir> <index> <kind> <key> <payload>
#   jg-bus-leaf.sh dump --state <dir>                    print the ordered view
#   jg-bus-leaf.sh parity --route <id> --state <dir> [--corrupt]
#
# Env: JG_BUS_LEAF_<KEY> overrides one config key (see `config`), JG_NATS_SERVER
# and JG_NATS_BIN pin the server and client binaries.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
RUNTIME=$STATE/bus-leaf
SELF=$SCRIPT_DIR/jg-bus-leaf.sh
DEFAULTS=$ROOT/defaults/bus-leaf
LEDGER_NAME=bus-leaf-view.tsv
PARITY_RUNTIME=

die() { printf 'jg-bus-leaf: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*" >&2; }

# --- one key file, no hard-coded values --------------------------------------
# env JG_BUS_LEAF_<KEY> wins, then the home's config/bus-leaf, then the shipped
# defaults file. A key nothing carries is a refusal, never a silent default.
cfg() { # <key>
  local key=$1 var value
  var="JG_BUS_LEAF_$(printf '%s' "$key" | tr 'a-z-' 'A-Z_')"
  value=$(eval "printf '%s' \"\${$var:-}\"")
  if [ -z "$value" ]; then value=$(bus_leaf_key "$JG_HOME/config/bus-leaf" "$key"); fi
  if [ -z "$value" ]; then value=$(bus_leaf_key "$DEFAULTS" "$key"); fi
  [ -n "$value" ] || die "no '$key' in $DEFAULTS or $JG_HOME/config/bus-leaf"
  printf '%s\n' "$value"
}

bus_leaf_key() { # <file> <key>
  [ -f "$1" ] || return 0
  awk -v k="$2" '$1 == "set" && $2 == k { sub(/^[[:space:]]*set[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); print; exit }' "$1" 2>/dev/null
}

# conf_check <key> <value> [<key> <value>...]: refuse a value that could close the
# string it is rendered into. It runs in the caller's own shell and prints nothing,
# so a refusal aborts the render instead of leaving the caller with an empty value.
conf_check() { # <key> <value>...
  [ "$#" -ge 2 ] || die "conf_check needs a key and a value"
  while [ "$#" -ge 2 ]; do
    case "$2" in
      ''|*[[:space:]]*|*[\"\\]*) die "config key $1 has an unsafe value" ;;
    esac
    shift 2
  done
}

# conf_check_endpoint <key> <value>: host:port, where the port may be -1 for "any
# free port", which is how a run avoids a fixed address.
conf_check_endpoint() { # <key> <value>
  local host port
  case "$2" in
    *:*:*) die "config key $1 must be host:port" ;;
    *:*) host=${2%:*}; port=${2##*:} ;;
    *) die "config key $1 must be host:port" ;;
  esac
  [ -n "$host" ] || die "config key $1 has an empty host"
  case "$port" in
    -1) ;;
    ''|*[!0-9]*) die "config key $1 has a non-numeric port" ;;
  esac
  conf_check "$1" "$2"
}

# --- the two server configurations -------------------------------------------
# The base bus configuration in force: the home may override the shipped one.
base_conf() {
  if [ -f "$JG_HOME/config/bus/nats.conf" ]; then printf '%s\n' "$JG_HOME/config/bus/nats.conf"
  else printf '%s\n' "$ROOT/core/bus/nats.conf"; fi
}

# Both renders name every value in this shell before writing it, so a refusal is
# reported as the key it belongs to and never as a half-written file.
render_hub_conf() { # <out>
  local out=$1 listen user pass
  listen=$(cfg hub-leaf-listen); conf_check_endpoint hub-leaf-listen "$listen"
  user=$(cfg leaf-user); conf_check leaf-user "$user"
  pass=$(cfg leaf-pass); conf_check leaf-pass "$pass"
  mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"
  {
    printf '# rendered by bin/jg-bus-leaf.sh: the base bus configuration plus the\n'
    printf '# leaf listener a remote home connects to.\n'
    cat "$(base_conf)" || die "cannot read $(base_conf)"
    printf '\nleafnodes {\n  listen: "%s"\n  authorization {\n    users = [ { user: "%s", password: "%s" } ]\n  }\n}\n' \
      "$listen" "$user" "$pass"
  } >"$out" || die "cannot write $out"
  printf '%s\n' "$out"
}

render_leaf_conf() { # <hub-leaf-endpoint> <out>
  local dial=$1 out=$2 listen name user pass
  listen=$(cfg leaf-listen); conf_check_endpoint leaf-listen "$listen"
  conf_check_endpoint hub-leaf-dial "$dial"
  name=$(cfg leaf-name); conf_check leaf-name "$name"
  user=$(cfg leaf-user); conf_check leaf-user "$user"
  pass=$(cfg leaf-pass); conf_check leaf-pass "$pass"
  mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"
  {
    printf '# rendered by bin/jg-bus-leaf.sh: this home is a leaf node of the main\n'
    printf '# home bus.\n'
    printf 'server_name: "%s"\n' "$name"
    printf 'host: "%s"\nport: %s\n' "${listen%:*}" "${listen##*:}"
    printf 'leafnodes {\n  remotes = [ { url: "nats-leaf://%s:%s@%s" } ]\n}\n' \
      "$user" "$pass" "$dial"
  } >"$out" || die "cannot write $out"
  printf '%s\n' "$out"
}

# --- servers ----------------------------------------------------------------
gate_server() {
  if [ -n "${JG_NATS_SERVER:-}" ]; then NATS_SERVER=$JG_NATS_SERVER
  else NATS_SERVER=$(command -v nats-server 2>/dev/null || true); fi
  [ -n "${NATS_SERVER:-}" ] || die "nats-server not found (set JG_NATS_SERVER)"
}

gate_client() {
  if [ -n "${JG_NATS_BIN:-}" ]; then NATS_BIN=$JG_NATS_BIN
  else NATS_BIN=$(command -v nats 2>/dev/null || true); fi
  [ -n "${NATS_BIN:-}" ] || die "nats client not found (set JG_NATS_BIN)"
}

# log_line <log> <regex> [tries]: the first log line matching, or empty. Polling
# the server's own log is how the test avoids a fixed port without guessing.
log_line() { # <log> <sed-expression> [tries]
  local log=$1 expr=$2 tries=${3:-100} i line
  for i in $(seq 1 "$tries"); do
    line=$(sed -n "$expr" "$log" 2>/dev/null | head -n 1)
    [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
    sleep 0.05
  done
  return 1
}

# client_url <endpoint>: a usable client URL. A server listening on every address
# is reached on the loopback one.
client_url() { # <host:port>
  case "$1" in 0.0.0.0:*) printf 'nats://127.0.0.1:%s\n' "${1##*:}" ;; *) printf 'nats://%s\n' "$1" ;; esac
}

start_server() { # <runtime> <role> <conf>
  local runtime=$1 role=$2 conf=$3 log pid addr
  mkdir -p "$runtime" || die "cannot create $runtime"
  log=$runtime/$role.log
  ( cd "$runtime" && exec "$NATS_SERVER" -c "$conf" ) >"$log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$runtime/$role.pid"
  addr=$(log_line "$log" 's/.*Listening for client connections on \(.*\)$/\1/p') \
    || die "$role: the server never reported a client address (see $log)"
  client_url "$addr" >"$runtime/$role.client-url"
  # The leaf listener is optional: only the hub side has one, and nats-server logs
  # it before the client line, so one read after that line is enough.
  addr=$(log_line "$log" 's/.*Listening for leafnode connections on \(.*\)$/\1/p' 1) || addr=
  [ -z "$addr" ] || printf '%s\n' "$addr" >"$runtime/$role.leaf-url"
  printf '%s: client %s' "$role" "$(cat "$runtime/$role.client-url")"
  [ -z "$addr" ] || printf ', leaf %s' "$addr"
  printf '\n'
}

stop_server() { # <runtime> <role>
  local runtime=$1 role=$2 pid
  [ -f "$runtime/$role.pid" ] || return 0
  pid=$(cat "$runtime/$role.pid")
  kill "$pid" 2>/dev/null && printf '%s: stopped\n' "$role" >&2
  rm -f "$runtime/$role.pid"
}

cmd_serve() { # hub|leaf
  local side=${1:-} conf dial
  case "$side" in
    hub)
      conf=$(render_hub_conf "$RUNTIME/hub.conf") || exit 2
      ;;
    leaf)
      dial=$(cfg hub-leaf-dial)
      conf=$(render_leaf_conf "$dial" "$RUNTIME/leaf.conf") || exit 2
      ;;
    *) die "serve needs hub or leaf" ;;
  esac
  # The configuration is rendered and validated first, so a bad value is reported as
  # itself rather than as a missing binary, and a render that refused never reaches
  # the server.
  gate_server
  start_server "$RUNTIME" "$side" "$conf"
}

cmd_stop() {
  stop_server "$RUNTIME" leaf
  stop_server "$RUNTIME" hub
  return 0
}

cmd_config() { # [<key>]
  local key=${1:-}
  if [ -n "$key" ]; then cfg "$key"; return 0; fi
  while read -r tag name _; do
    [ "${tag:-}" = set ] || continue
    printf '  %-16s %s\n' "$name" "$(cfg "$name")"
  done <"$DEFAULTS"
}

# --- the canonical row -------------------------------------------------------
b64() { base64 | tr -d '\n'; }
unb64() { # <text>
  if printf '%s' "$1" | base64 --decode 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D 2>/dev/null
}
clean_field() { printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   '; }

view_path() { # <base>
  printf '%s/%s\n' "$1" "$LEDGER_NAME"
}

view_last_index() { # <base>
  local file last
  file=$(view_path "$1")
  [ -f "$file" ] || { printf '0\n'; return 0; }
  last=$(awk 'END { print $1 }' "$file" 2>/dev/null)
  case "${last:-}" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$last" ;; esac
}

view_rows() { # <base>
  local file
  file=$(view_path "$1")
  [ -f "$file" ] || return 0
  cat "$file"
}

# One event, applied to the home's own surface and then recorded in the ordered
# view. An index that is not the next one is a repeat or a gap and is ignored, so
# a sender can resend from the first missing index without duplicating a row.
cmd_apply() { # <base> <index> <kind> <key> <payload>
  local base=$1 index=$2 kind=$3 key=$4 payload=$5 file last cleaned
  case "$index" in ''|*[!0-9]*) die "apply: index must be a positive integer" ;; esac
  last=$(view_last_index "$base")
  [ "$index" -eq $((last + 1)) ] || { printf 'skip: index %s is not %s\n' "$index" "$((last + 1))" >&2; return 0; }
  cleaned=$(clean_field "$payload")
  mkdir -p "$base" || die "cannot create $base"
  # Both libraries resolve the home they write into when they are sourced, and the
  # inbox library sources the wake library itself, so the record path is named
  # before either one loads: a later event must never inherit an earlier home.
  JG_STATE_OVERRIDE=$base
  JG_WAKE_QUEUE=$base/.wake-queue
  JG_WAKE_QUEUE_LOCK=$base/.wake-queue.lock
  case "$kind" in
    task)
      # shellcheck source=bin/jg-task-inbox-lib.sh
      . "$SCRIPT_DIR/jg-task-inbox-lib.sh"
      jg_task_inbox_write "$base" "$key" "$payload" >/dev/null || die "apply: the inbox record was not written"
      ;;
    status)
      printf '%s\n' "$payload" >>"$base/$key.status" || die "apply: the status line was not written"
      ;;
    wake)
      # shellcheck source=bin/jg-wake-lib.sh
      . "$SCRIPT_DIR/jg-wake-lib.sh"
      jg_wake_append signal "$key" "$payload" || die "apply: the wake row was not written"
      ;;
    *) die "apply: unknown event kind '$kind'" ;;
  esac
  file=$(view_path "$base")
  printf '%s\t%s\t%s\t%s\n' "$index" "$kind" "$(clean_field "$key")" "$cleaned" >>"$file" \
    || die "apply: the view row was not written"
}

# A published body is one line: <index> <tab> <kind> <tab> <b64 key> <tab> <b64 payload>.
apply_line() { # <base> <line>
  local base=$1 line=$2 index kind key payload
  IFS=$'\t' read -r index kind key payload <<<"$line"
  case "${index:-}" in ''|*[!0-9]*) printf 'skip: malformed event row\n' >&2; return 0 ;; esac
  case "${kind:-}" in task|status|wake) ;; *) printf 'skip: malformed event row\n' >&2; return 0 ;; esac
  { [ -n "${key:-}" ] && [ -n "${payload:-}" ]; } || { printf 'skip: malformed event row\n' >&2; return 0; }
  cmd_apply "$base" "$index" "$kind" "$(unb64 "$key")" "$(unb64 "$payload")"
}

# encode_rows: event rows on stdin, one wire line per row on stdout.
encode_rows() {
  local index kind key payload
  while IFS=$'\t' read -r index kind key payload; do
    [ -n "${index:-}" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$index" "$kind" \
      "$(printf '%s' "$key" | b64)" "$(printf '%s' "$payload" | b64)"
  done
}

# send: one event from argv, or any number of rows on stdin. A batch goes out on
# ONE connection in the order it is written, because the order the server receives
# is the order this step has to prove; a separate connection per event would let
# the server interleave them and the comparison would fail for the sender's
# reason, not the leaf's.
cmd_send() { # [<index> <kind> <key> <payload>] | rows on stdin
  gate_client
  {
    if [ "$#" -eq 4 ]; then
      printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
    elif [ "$#" -eq 0 ]; then
      cat
    else
      die "send needs <index> <kind> <key> <payload>, or event rows on stdin"
    fi
  } | encode_rows \
    | "$NATS_BIN" -s "$(cfg url)" pub --force-stdin --count 1 --send-on=newline --no-templates "$(cfg subject)" \
      >/dev/null 2>&1 \
    || die "send: the event was not published"
}

cmd_consume() { # --state <dir> [--wait <duration>]
  local base='' idle='' line
  local -a args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) base=${2:-}; shift 2 || die "consume --state needs a directory" ;;
      --wait) idle=${2:-}; shift 2 || die "consume --wait needs a duration" ;;
      *) die "consume: unknown argument $1" ;;
    esac
  done
  [ -n "$base" ] || die "consume needs --state <dir>"
  gate_client
  [ -z "$idle" ] || args+=(--wait "$idle")
  # --wait bounds a reader nobody is feeding, which is how a replay ends; a reader
  # with no bound stays subscribed, as a live consumer of the home must.
  "$NATS_BIN" -s "$(cfg url)" sub "$(cfg subject)" --raw ${args[@]+"${args[@]}"} 2>/dev/null \
    | while IFS= read -r line; do [ -z "$line" ] || apply_line "$base" "$line"; done
}

cmd_dump() { # --state <dir>
  local base=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) base=${2:-}; shift 2 || die "dump --state needs a directory" ;;
      *) die "dump: unknown argument $1" ;;
    esac
  done
  [ -n "$base" ] || die "dump needs --state <dir>"
  view_rows "$base"
}

# --- the replay -------------------------------------------------------------
# The event set both paths carry: the three surfaces a remote lead's home holds -
# a task that arrives as a steering record, a status line it reports, and a wake
# that raises it - in one fixed order.
event_set() {
  printf '1\ttask\tlane-a\tdo the first thing\n'
  printf '2\twake\tcrew.remote\tsignal: crew.remote\n'
  printf '3\tstatus\tlane-a\tworking: first step\n'
  printf '4\ttask\tlane-b\tsecond instruction\n'
  printf '5\twake\tlane-b.status\tsignal: lane-b finished\n'
  printf '6\tstatus\tlane-b\tdone: second step\n'
  printf '7\ttask\tlane-a\tthird instruction\n'
}

event_count() { event_set | awk 'END { print NR }'; }

# publish_from <from-index> <corrupt> <hub-url>: the events the leaf leg still owes,
# as one ordered batch on one connection, from the first index the home has not
# applied.
publish_from() { # <from> <corrupt> <hub-url>
  local from=$1 corrupt=$2 hub=$3 index kind key payload
  {
    while IFS=$'\t' read -r index kind key payload; do
      [ -n "$index" ] || continue
      [ "$index" -gt "$from" ] || continue
      if [ "$corrupt" -eq 1 ] && [ "$index" -eq 3 ]; then
        payload="$payload (corrupted by the parity test)"
      fi
      printf '%s\t%s\t%s\t%s\n' "$index" "$kind" "$key" "$payload"
    done < <(event_set)
  } | JG_BUS_LEAF_URL=$hub "$SELF" send \
    || die "parity: the leaf leg could not publish its events"
}

# ssh_leg <route> <base>: the real transport, one call per event, so the order the
# lead sees is the order the caller sent.
ssh_leg() { # <route> <base>
  local route=$1 base=$2 index kind key payload
  while IFS=$'\t' read -r index kind key payload; do
    [ -n "$index" ] || continue
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-on.sh" "$route" jg-bus-leaf.sh apply \
      --state "$base" "$index" "$kind" "$key" "$payload" >/dev/null \
      || die "parity: the SSH leg could not deliver event $index"
  done < <(event_set)
  verify_leg ssh "$base"
}

# leaf_leg <base> <runtime>: start a hub and a leaf from the rendered
# configurations, subscribe on the leaf's own address, and publish the same set on
# the hub until every event has been applied.
leaf_leg() { # <base> <runtime> <corrupt>
  local base=$1 runtime=$2 corrupt=${3:-0} consumer
  local hub_leaf applied tries=0 want
  gate_server
  gate_client
  mkdir -p "$runtime" || die "parity: cannot create $runtime"
  hub_leaf=127.0.0.1:-1
  start_server "$runtime" hub \
    "$(JG_BUS_LEAF_HUB_LEAF_LISTEN="$hub_leaf" render_hub_conf "$runtime/hub.conf")" >/dev/null \
    || exit 2
  hub_leaf=$(cat "$runtime/hub.leaf-url" 2>/dev/null) || die "parity: the hub has no leaf listener"
  start_server "$runtime" leaf \
    "$(JG_BUS_LEAF_LEAF_LISTEN=127.0.0.1:-1 render_leaf_conf "$hub_leaf" "$runtime/leaf.conf")" >/dev/null \
    || exit 2
  want=$(event_count)
  JG_BUS_LEAF_URL=$(cat "$runtime/leaf.client-url") \
    "$SELF" consume --state "$base" --wait 1s >"$runtime/consume.log" 2>&1 &
  consumer=$!
  while [ "$tries" -lt 200 ]; do
    applied=$(view_last_index "$base")
    [ "$applied" -ge "$want" ] && break
    publish_from "$applied" "$corrupt" "$(cat "$runtime/hub.client-url")"
    tries=$((tries + 1))
    sleep 0.05
  done
  if [ "$(view_last_index "$base")" -ge "$want" ]; then
    wait "$consumer" 2>/dev/null || true
  else
    kill "$consumer" 2>/dev/null || true
  fi
  stop_server "$runtime" leaf
  stop_server "$runtime" hub
  [ "$(view_last_index "$base")" -ge "$want" ] \
    || die "parity: the leaf leg applied $(view_last_index "$base") of $want events"
  verify_leg leaf "$base"
}

# verify_leg <name> <base>: a leg that recorded nothing would compare equal to an
# empty one, so each side must hold the whole set before the comparison.
verify_leg() { # <name> <base>
  local name=$1 base=$2 rows want
  rows=$(view_rows "$base" | awk 'END { print NR }')
  want=$(event_count)
  [ "$rows" -eq "$want" ] || die "parity: the $name leg holds $rows of $want rows"
}

cmd_parity() { # --route <id> --state <dir> [--corrupt]
  local route='' state='' corrupt=0 ssh_view leaf_view runtime rows differences status=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --route) route=${2:-}; shift 2 || die "parity --route needs a squad_lead id" ;;
      --state) state=${2:-}; shift 2 || die "parity --state needs a directory" ;;
      --corrupt) corrupt=1; shift ;;
      *) die "parity: unknown argument $1" ;;
    esac
  done
  [ -n "$route" ] || die "parity needs --route <squad_lead id>"
  [ -n "$state" ] || die "parity needs --state <dir>"
  case "$state" in /*) ;; *) die "parity --state must be an absolute path" ;; esac
  mkdir -p "$state" || die "parity: cannot create $state"
  ssh_view=$state/ssh
  leaf_view=$state/leaf
  runtime=$state/servers
  rm -rf -- "${ssh_view:?}" "${leaf_view:?}" "${runtime:?}"
  mkdir -p "$ssh_view" "$leaf_view" "$runtime" || die "parity: cannot prepare $state"
  PARITY_RUNTIME=$runtime
  trap parity_cleanup EXIT
  ssh_leg "$route" "$ssh_view"
  leaf_leg "$leaf_view" "$runtime" "$corrupt"
  trap - EXIT
  parity_cleanup
  rows=$(view_rows "$ssh_view" | awk 'END { print NR }')
  if ! diff -u "$(view_path "$ssh_view")" "$(view_path "$leaf_view")" >"$state/parity.diff" 2>&1; then
    status=1
  fi
  differences=$(grep -c '^[-+][^-+]' "$state/parity.diff" 2>/dev/null || true)
  case "${differences:-}" in ''|*[!0-9]*) differences=0 ;; esac
  # A difference that did not come out as a changed line - a side that is missing
  # altogether - still counts as one, so the report never reads as agreement.
  [ "$status" -eq 0 ] || [ "$differences" -gt 0 ] || differences=1
  printf 'rows=%s differences=%s route=%s\n' "$rows" "$differences" "$route"
  if [ "$status" -ne 0 ]; then
    printf 'the two paths disagree; see %s\n' "$state/parity.diff"
    sed -n '1,40p' "$state/parity.diff"
  fi
  return "$status"
}

# The servers a replay started, stopped on the way out and on any failure.
parity_cleanup() {
  [ -n "$PARITY_RUNTIME" ] || return 0
  stop_server "$PARITY_RUNTIME" leaf
  stop_server "$PARITY_RUNTIME" hub
  PARITY_RUNTIME=
  return 0
}

case "${1:-}" in
  config) shift; cmd_config "$@" ;;
  serve) shift; cmd_serve "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  send) shift; cmd_send "$@" ;;
  consume) shift; cmd_consume "$@" ;;
  apply)
    shift
    # No default: this writes into the home it is given, so a missing --state would
    # write into whichever home happens to be current.
    [ "${1:-}" = --state ] || die "apply needs --state <dir>"
    base=${2:-}
    [ -n "$base" ] || die "apply --state needs a directory"
    shift 2
    [ "$#" -eq 4 ] || die "apply needs <index> <kind> <key> <payload>"
    cmd_apply "$base" "$1" "$2" "$3" "$4"
    ;;
  dump) shift; cmd_dump "$@" ;;
  parity) shift; cmd_parity "$@" ;;
  *) die "unknown command: ${1:-}" ;;
esac
