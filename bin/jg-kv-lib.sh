#!/usr/bin/env bash
# jg-kv-lib.sh - the one owner of the JetStream key-value client surface.
#
# WHY. Two paths keep records in a JetStream key-value bucket: the task leases,
# which are live (bin/jg-lease-lib.sh), and the busy events, still mirrored in
# shadow (bin/jg-state-bus.sh). Both need the same things - which server, which
# client binary, how a bucket comes into being, and how a value is read, written,
# deleted and revisioned - so this library owns them once instead of each path
# re-spelling a client call.
#
# CONTRACT.
#   server   JG_KV_URL, else JG_STATE_BUS_URL, else the `nats-url` key of the
#            home's config/state-bus, else nats://127.0.0.1:4222.
#   client   JG_NATS_BIN when set, else `nats` on PATH.
#   auth     the machine runs one account per home, so a client that connects as the
#            empty user is refused. jg_kv_run authenticates every call as the home that
#            owns the state directory, with the name core/bus/cmd/jg-bus writes into the
#            machine's accounts file and the password it wrote into that home's
#            credentials file (<state>/bus/<account>.pass). A machine with no such file
#            (an unauthenticated single-home server) is called without credentials.
#   gate     jg_kv_ready fails, printing the reason into JG_KV_WHY, when either
#            the client or the server is missing. It never decides whether that
#            is a skip or a refusal: the shadow mirror skips, a live lease
#            decision refuses, and that choice belongs to the caller.
#   values   bytes. A value read back with jg_kv_get is the value written, with no
#            quoting, escaping or JSON in the way.
#   revision jg_kv_revision prints the revision the key's current value holds,
#            which is the compare-and-set token a claiming writer pins its write
#            to. A store whose client cannot report a revision therefore cannot
#            grant a takeover safely, and this library says so instead of guessing.
#
# Callers resolve their home and state before sourcing this; nothing here has a
# side effect at source time. set -u safe, and every function returns non-zero
# rather than exiting, so a caller keeps the last word.
#
# Sourced by bin/jg-lease-lib.sh and bin/jg-state-bus.sh.

JG_KV_HISTORY=8
JG_KV_WHY=
JG_KV_READY=
JG_KV_URL_RESOLVED=
JG_KV_CLIENT=
JG_KV_STATE=

# jg_kv_home_url <home-dir>: the server address in force for one home.
jg_kv_home_url() { # <home-dir>
  local home=$1 url value
  url=${JG_KV_URL:-${JG_STATE_BUS_URL:-}}
  if [ -z "$url" ] && [ -f "$home/config/state-bus" ]; then
    value=$(awk '$1 == "nats-url" { sub(/^[^ ]+[ \t]+/, ""); print; exit }' \
      "$home/config/state-bus" 2>/dev/null)
    url=$value
  fi
  printf '%s\n' "${url:-nats://127.0.0.1:4222}"
}

# jg_kv_resolve <home-dir>: resolve the URL and the client once per shell.
jg_kv_resolve() { # <home-dir>
  local home=$1
  if [ -z "$JG_KV_URL_RESOLVED" ]; then
    JG_KV_URL_RESOLVED=$(jg_kv_home_url "$home") || return 1
  fi
  if [ -z "$JG_KV_CLIENT" ]; then
    if [ -n "${JG_NATS_BIN:-}" ]; then
      JG_KV_CLIENT=$JG_NATS_BIN
    else
      JG_KV_CLIENT=$(command -v nats 2>/dev/null || true)
    fi
  fi
  if [ -z "$JG_KV_STATE" ]; then
    JG_KV_STATE=${JG_STATE_OVERRIDE:-$home/state}
  fi
  [ -n "$JG_KV_CLIENT" ] || { JG_KV_WHY="no nats client found (set JG_NATS_BIN)"; return 1; }
  return 0
}

# jg_kv_home_account <home-dir>: the account name this home owns on the machine's one
# server - its directory name spelled as a NATS subject can carry it, which is the same
# spelling core/bus/cmd/jg-bus gives the accounts file.
jg_kv_home_account() { # <home-dir>
  local name
  name=$(basename -- "${1:-}") || return 1
  name=${name//[^A-Za-z0-9_-]/_}
  printf '%s\n' "${name:-home}"
}

# jg_kv_home_password <state-dir>: the password the machine's accounts file carries for
# this home. Fails when the machine keeps none, which is how an unauthenticated server
# is called without credentials.
jg_kv_home_password() { # <state-dir>
  local account
  account=$(jg_kv_home_account "$(dirname "$1")") || return 1
  [ -s "$1/bus/$account.pass" ] || return 1
  tr -d '\n' < "$1/bus/$account.pass"
}

# jg_kv_run <client> <url> <state-dir> [args...]: one client call, authenticated as the
# home that owns <state-dir> when the machine keeps credentials for it. The password
# travels in NATS_PASSWORD, never on the argument list, so it never shows in `ps`.
jg_kv_run() { # <client> <url> <state-dir> [args...]
  local client=$1 url=$2 state=$3 account pass
  shift 3
  account=$(jg_kv_home_account "$(dirname "$state")")
  if pass=$(jg_kv_home_password "$state"); then
    NATS_USER=$account NATS_PASSWORD=$pass "$client" -s "$url" --timeout 10s "$@"
    return
  fi
  "$client" -s "$url" --timeout 10s "$@"
}

# jg_kv_call <args...>: one client call, with the server named explicitly.
jg_kv_call() {
  jg_kv_run "$JG_KV_CLIENT" "$JG_KV_URL_RESOLVED" "$JG_KV_STATE" "$@"
}

# jg_kv_ready <home-dir>: 0 iff a client is present and its server answers, so a
# caller can tell a missing store from a missing record.
jg_kv_ready() { # <home-dir>
  [ -n "$JG_KV_READY" ] && return 0
  jg_kv_resolve "$1" || return 1
  if ! jg_kv_call kv ls >/dev/null 2>&1; then
    JG_KV_WHY="no bus at $JG_KV_URL_RESOLVED"
    return 1
  fi
  JG_KV_WHY=
  JG_KV_READY=1
  return 0
}

# jg_kv_ensure_bucket <bucket> [history]: create the bucket when it is absent, so
# a home that has never written to it needs no separate provisioning step.
jg_kv_ensure_bucket() { # <bucket> [history]
  local bucket=$1 history=${2:-$JG_KV_HISTORY}
  jg_kv_call kv info "$bucket" >/dev/null 2>&1 && return 0
  jg_kv_call kv add "$bucket" --history "$history" --storage file >/dev/null 2>&1 || {
    # shellcheck disable=SC2034 # Read by the caller's own refusal or skip text.
    JG_KV_WHY="cannot create the $bucket bucket on $JG_KV_URL_RESOLVED"
    return 1
  }
}

# jg_kv_get <bucket> <key>: the value's bytes on stdout; fails when the key is
# absent or unreadable.
jg_kv_get() { # <bucket> <key>
  jg_kv_call kv get "$1" "$2" --raw 2>/dev/null
}

# jg_kv_put <bucket> <key>: the value arrives on stdin.
jg_kv_put() { # <bucket> <key>
  jg_kv_call kv put "$1" "$2" >/dev/null 2>&1
}

# jg_kv_create <bucket> <key> <value>: write only when the key is new or its last
# operation was a delete, so two writers cannot both create it.
jg_kv_create() { # <bucket> <key> <value>
  jg_kv_call kv create "$1" "$2" "$3" >/dev/null 2>&1
}

# jg_kv_update <bucket> <key> <value> <revision>: write only when the key still
# holds <revision>, so a writer that read a record cannot overwrite a newer one.
jg_kv_update() { # <bucket> <key> <value> <revision>
  jg_kv_call kv update "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

# jg_kv_del <bucket> <key>: drop the key, whether or not it exists.
jg_kv_del() { # <bucket> <key>
  jg_kv_call kv del -f "$1" "$2" >/dev/null 2>&1 || true
}

# jg_kv_keys <bucket> <prefix>: the keys this bucket holds under one prefix.
jg_kv_keys() { # <bucket> <prefix>
  jg_kv_call kv ls "$1" 2>/dev/null | awk -v p="$2" 'index($0, p) == 1' || true
}

# jg_kv_revision <bucket> <key>: the revision the key's current value holds. The
# client reports it only in its history table, whose second column is the
# revision, so a row contributes a revision only when that column is a number;
# the newest such row wins. Fails when the key is absent or reports none.
jg_kv_revision() { # <bucket> <key>
  local rev
  rev=$(jg_kv_call kv history "$1" "$2" 2>/dev/null | awk -F'│' '
    NF >= 4 {
      r = $3
      gsub(/[^0-9]/, "", r)
      if (r != "") last = r
    }
    END { if (last != "") print last; else exit 1 }') || return 1
  case "$rev" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$rev"
}

# jg_kv_home_key <state-dir>: a stable short name for one home, so one bucket
# keeps two homes' identical task names apart. A KV key admits no colon, so the
# path hash is joined to the directory name with a dash.
jg_kv_home_key() { # <state-dir>
  local home digest
  home=$(dirname "$1") || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$home" | sha256sum | cut -d' ' -f1)
  else
    digest=$(printf '%s' "$home" | shasum -a 256 | cut -d' ' -f1)
  fi
  printf '%s-%s\n' "$(basename "$home")" "$(printf '%s' "$digest" | cut -c1-8)"
}
