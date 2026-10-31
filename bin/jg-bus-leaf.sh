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
#            source carrying a key wins and no value is hard-coded here. There is
#            no `config/bus-leaf` switch file: the leaf runs when an operator
#            starts it, not on every poll, so it needs no per-home toggle. `config`
#            prints the values in force.
#   hub      The home bus side: the base server configuration in force
#            (core/bus/nats.conf, or the home's config/bus/nats.conf) with one
#            leafnodes block appended - the listen address, and the user and
#            password a leaf must present. Rendered into the runtime directory, so
#            the base file is never edited.
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
#            port, and publishes the same set on the hub. Both legs write into
#            separate directories under --state, so a run never touches a real
#            home's records. `--corrupt` tampers with one event on the leaf leg, and
#            a green comparison after that would mean the check is vacuous.
#   write    Nothing here edits the file path's plumbing or the SSH path's records.
#            `parity` writes only under its own --state directory and the runtime
#            directory it starts.
#
# Usage:
#   jg-bus-leaf.sh config [<key>]
#   jg-bus-leaf.sh serve hub|leaf
#   jg-bus-leaf.sh stop
#   jg-bus-leaf.sh send <index> <kind> <key> <payload>   publish one event
#   jg-bus-leaf.sh consume --state <dir> [--count <n>]   subscribe and apply
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

# conf_field <key> <value>: one value safe to place inside a config file. A value
# that could close the string it sits in is refused rather than rendered.
conf_field() { # <key> <value>
  case "$2" in
    ''|*[\"\\\ \	]*|*$'\n'*|*$'\r'*) die "config key $1 has an unsafe value" ;;
  esac
  printf '%s' "$2"
}

# conf_endpoint <key> <value>: host:port, where the port may be -1 for "any free
# port", which is how a run avoids a fixed address.
conf_endpoint() { # <key> <value>
  local host port
  case "$2" in
    *:*:*) die "config key $1 must be host:port" ;;
    *:*) host=${2%:*}; port=${2##*:} ;;
    *) die "config key $1 must be host:port" ;;
  esac
  [ -n "$host" ] || die "config key $1 has an empty host"
  case "$port" in
    -1|[0-9]*) ;;
    *) die "config key $1 has a non-numeric port" ;;
  esac
  case "$port" in *[!0-9-]*) die "config key $1 has a non-numeric port" ;; esac
  conf_field "$1" "$host:$port"
}

# --- the two server configurations -------------------------------------------
# The base bus configuration in force: the home may override the shipped one.
base_conf() {
  if [ -f "$JG_HOME/config/bus/nats.conf" ]; then printf '%s\n' "$JG_HOME/config/bus/nats.conf"
  else printf '%s\n' "$ROOT/core/bus/nats.conf"; fi
}

render_hub_conf() { # <out>
  local out=$1 listen user pass
  listen=$(conf_endpoint hub-leaf-listen "$(cfg hub-leaf-listen)")
  user=$(conf_field leaf-user "$(cfg leaf-user)")
  pass=$(conf_field leaf-pass "$(cfg leaf-pass)")
  mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"
  {
    printf '# rendered by bin/jg-bus-leaf.sh serve hub: the base bus configuration\n'
    printf '# plus the leaf listener this remote home connects to.\n'
    cat "$(base_conf)" || die "cannot read $(base_conf)"
    printf '\nleafnodes {\n  listen: "%s"\n  authorization {\n    users = [ { user: "%s", password: "%s" } ]\n  }\n}\n' \
      "$listen" "$user" "$pass"
  } >"$out" || die "cannot write $out"
  printf '%s\n' "$out"
}

render_leaf_conf() { # <hub-leaf-endpoint> <out>
  local dial=$1 out=$2 listen name user pass
  listen=$(conf_endpoint leaf-listen "$(cfg leaf-listen)")
  dial=$(conf_endpoint hub-leaf-dial "$dial")
  name=$(conf_field leaf-name "$(cfg leaf-name)")
  user=$(conf_field leaf-user "$(cfg leaf-user)")
  pass=$(conf_field leaf-pass "$(cfg leaf-pass)")
  mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"
  {
    printf '# rendered by bin/jg-bus-leaf.sh serve leaf: this home is a leaf node\n'
    printf '# of the main home bus.\n'
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
  addr=$(log_line "$log" 's/.*Listening for leafnode connections on \(.*\)$/\1/p' 2) || addr=
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
  local side=${1:-} dial
  case "$side" in
    hub)
      gate_server
      start_server "$RUNTIME" hub "$(render_hub_conf "$RUNTIME/hub.conf")"
      ;;
    leaf)
      gate_server
      dial=$(cfg hub-leaf-dial)
      start_server "$RUNTIME" leaf "$(render_leaf_conf "$dial" "$RUNTIME/leaf.conf")"
      ;;
    *) die "serve needs hub or leaf" ;;
  esac
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
      JG_STATE_OVERRIDE=$base
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
  case "${index:-}${kind:-}${key:-}" in ''|*[!a-z0-9._-]*) printf 'skip: malformed event row\n' >&2; return 0 ;; esac
  [ -n "${payload:-}" ] || { printf 'skip: malformed event row\n' >&2; return 0; }
  cmd_apply "$base" "$index" "$kind" "$(unb64 "$key")" "$(unb64 "$payload")"
}

cmd_send() { # <index> <kind> <key> <payload>
  local index=${1:-} kind=${2:-} key=${3:-} payload=${4:-}
  [ "$#" -eq 4 ] || die "send needs <index> <kind> <key> <payload>"
  gate_client
  printf '%s\t%s\t%s\t%s\n' "$index" "$kind" "$(printf '%s' "$key" | b64)" "$(printf '%s' "$payload" | b64)" \
    | "$NATS_BIN" -s "$(cfg url)" pub --force-stdin --no-templates "$(cfg subject)" >/dev/null 2>&1 \
    || die "send: the event was not published"
}

cmd_consume() { # --state <dir> [--count <n>]
  local base='' count='' line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) base=${2:-}; shift 2 || die "consume --state needs a directory" ;;
      --count) count=${2:-}; shift 2 || die "consume --count needs a number" ;;
      *) die "consume: unknown argument $1" ;;
    esac
  done
  [ -n "$base" ] || die "consume needs --state <dir>"
  gate_client
  if [ -n "$count" ]; then
    "$NATS_BIN" -s "$(cfg url)" sub "$(cfg subject)" --raw --count "$count" 2>/dev/null \
      | while IFS= read -r line; do [ -z "$line" ] || apply_line "$base" "$line"; done
  else
    "$NATS_BIN" -s "$(cfg url)" sub "$(cfg subject)" --raw 2>/dev/null \
      | while IFS= read -r line; do [ -z "$line" ] || apply_line "$base" "$line"; done
  fi
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
# configurations, subscribe on the leaf's own client port, and publish the same
# set on the hub until every event has been applied.
leaf_leg() { # <base> <runtime> <corrupt>
  local base=$1 runtime=$2 corrupt=${3:-0} index kind key payload consumer
  local hub_leaf applied tries=0 want
  gate_server
  gate_client
  mkdir -p "$runtime" || die "parity: cannot create $runtime"
  hub_leaf=$(conf_endpoint hub-leaf-listen 127.0.0.1:-1)
  start_server "$runtime" hub \
    "$(JG_BUS_LEAF_HUB_LEAF_LISTEN="$hub_leaf" render_hub_conf "$runtime/hub.conf")" >/dev/null
  hub_leaf=$(cat "$runtime/hub.leaf-url" 2>/dev/null) || die "parity: the hub has no leaf listener"
  start_server "$runtime" leaf \
    "$(JG_BUS_LEAF_LEAF_LISTEN=127.0.0.1:-1 render_leaf_conf "$hub_leaf" "$runtime/leaf.conf")" >/dev/null
  want=$(event_count)
  JG_BUS_LEAF_URL=$(cat "$runtime/leaf.client-url") \
    "$SELF" consume --state "$base" --count "$want" >"$runtime/consume.log" 2>&1 &
  consumer=$!
  while [ "$tries" -lt 200 ]; do
    applied=$(view_last_index "$base")
    [ "$applied" -ge "$want" ] && break
    while IFS=$'\t' read -r index kind key payload; do
      [ -n "$index" ] || continue
      [ "$index" -gt "$applied" ] || continue
      if [ "$corrupt" -eq 1 ] && [ "$index" -eq 3 ]; then
        payload="$payload (corrupted by the parity test)"
      fi
      JG_BUS_LEAF_URL=$(cat "$runtime/hub.client-url") \
        "$SELF" send "$index" "$kind" "$key" "$payload" || die "parity: the leaf leg could not publish event $index"
    done < <(event_set)
    tries=$((tries + 1))
    sleep 0.05
  done
  wait "$consumer" 2>/dev/null || true
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
  printf 'rows=%s differences=%s route=%s\n' "$rows" "$differences" "$route"
  if [ "$status" -ne 0 ]; then
    printf 'the two paths disagree; see %s\n' "$state/parity.diff"
    sed -n '1,40p' "$state/parity.diff"
    [ "$differences" -gt 0 ] || differences=1
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
    base=
    if [ "${1:-}" = --state ]; then base=${2:-}; [ -n "$base" ] || die "apply --state needs a directory"; shift 2; fi
    [ "$#" -eq 4 ] || die "apply needs <index> <kind> <key> <payload>"
    cmd_apply "${base:-$STATE}" "$1" "$2" "$3" "$4"
    ;;
  dump) shift; cmd_dump "$@" ;;
  parity) shift; cmd_parity "$@" ;;
  *) die "unknown command: ${1:-}" ;;
esac
