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
#            owns the state directory, with the name and the credentials file that
#            `bin/jg-bus.sh login` prints - the one function core/bus/cmd/jg-bus writes the
#            machine's accounts file from, answering only when that file holds the account
#            (<state>/bus/<account>.pass). A machine with no accounts, or a home that has not
#            joined one, gets no credentials at all.
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

# shellcheck disable=SC2034 # kept for the NATS functions until slice 11b5
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

# jg_kv_login <state-dir>: this home's account name and its credentials file, tab
# separated, asked of the one function that also writes the server's accounts block
# (bin/jg-bus.sh login), so the name and the password can never drift from what the
# server loaded, and answered only when that block really holds this home's account. A
# machine where that command cannot answer (no Go toolchain and no built command, no
# accounts, or this home has not joined) keeps no credentials for this home, which is how
# an unauthenticated server is called without them. The answer is kept for the rest of
# the shell.
JG_KV_LOGIN_STATE=
JG_KV_LOGIN=
jg_kv_login() { # <state-dir>
  local state=$1 bus
  if [ "$JG_KV_LOGIN_STATE" != "$state" ]; then
    bus=${BASH_SOURCE[0]%/*}/jg-bus.sh
    JG_KV_LOGIN=$(JG_HOME=$(dirname -- "$state") JG_STATE_OVERRIDE=$state "$bus" login 2>/dev/null) || JG_KV_LOGIN=
    JG_KV_LOGIN_STATE=$state
  fi
  [ -n "$JG_KV_LOGIN" ] && printf '%s\n' "$JG_KV_LOGIN"
}

# jg_kv_run <client> <url> <state-dir> [args...]: one client call, authenticated as the
# home that owns <state-dir> when the machine keeps credentials for it. The password
# travels in NATS_PASSWORD, never on the argument list, so it never shows in `ps`.
# JG_KV_DEADLINE, when set, is the whole call's limit in seconds: the client's own
# --timeout bounds a request, not a subscription waiting for its message.
jg_kv_run() { # <client> <url> <state-dir> [args...]
  local client=$1 url=$2 state=$3 login account cred pass deadline=()
  shift 3
  [ -z "${JG_KV_DEADLINE:-}" ] || deadline=(timeout "$JG_KV_DEADLINE")
  if login=$(jg_kv_login "$state"); then
    account=${login%%$'\t'*}
    cred=${login#*$'\t'}
    if [ -s "$cred" ] && pass=$(tr -d '\n' < "$cred"); then
      NATS_USER=$account NATS_PASSWORD=$pass ${deadline[@]+"${deadline[@]}"} "$client" -s "$url" --timeout 10s "$@"
      return
    fi
  fi
  ${deadline[@]+"${deadline[@]}"} "$client" -s "$url" --timeout 10s "$@"
}

# jg_kv_call <args...>: one client call, with the server named explicitly.
jg_kv_call() {
  jg_kv_run "$JG_KV_CLIENT" "$JG_KV_URL_RESOLVED" "$JG_KV_STATE" "$@"
}

# jg_kv_py <op> [args...]: the one SQLite call every bucket function below makes. The store is
# one file, $JG_KV_STATE/kv.db, table kv(bucket, key, value, revision, PRIMARY KEY(bucket, key)).
# A revision comes from one counter that only rises (table kv_seq), so a key deleted and made
# again never repeats a revision a stale reader still holds. A create fails when the key exists;
# an update is `UPDATE ... WHERE revision = ?` and wins only when one row changed.
# The value of a put arrives on stdin; every other value is an argument.
# shellcheck disable=SC2016 # the program is Python, not shell.
JG_KV_PY='
import os, sqlite3, sys
op, args = sys.argv[1], sys.argv[2:]
os.makedirs(os.path.dirname(args[0]), exist_ok=True)
db = sqlite3.connect(args[0], timeout=5, isolation_level=None)
db.execute("PRAGMA busy_timeout=5000")
db.execute("PRAGMA journal_mode=WAL")
db.execute("CREATE TABLE IF NOT EXISTS kv(bucket TEXT NOT NULL, key TEXT NOT NULL, value BLOB, revision INTEGER NOT NULL, PRIMARY KEY(bucket, key))")
db.execute("CREATE TABLE IF NOT EXISTS kv_seq(n INTEGER PRIMARY KEY AUTOINCREMENT)")
a = args[1:]
def nxt():
    return db.execute("INSERT INTO kv_seq DEFAULT VALUES").lastrowid
def out(b):
    sys.stdout.buffer.write(b)
if op == "ensure":
    pass
elif op == "get":
    r = db.execute("SELECT value FROM kv WHERE bucket=? AND key=?", a[:2]).fetchone()
    if r is None: sys.exit(1)
    out(r[0] if isinstance(r[0], bytes) else r[0].encode())
elif op == "put":
    v = sys.stdin.buffer.read()
    db.execute("BEGIN IMMEDIATE")
    db.execute("INSERT INTO kv VALUES(?,?,?,?) ON CONFLICT(bucket, key) DO UPDATE SET value=excluded.value, revision=excluded.revision", (a[0], a[1], v, nxt()))
    db.execute("COMMIT")
elif op == "create":
    db.execute("BEGIN IMMEDIATE")
    if db.execute("SELECT 1 FROM kv WHERE bucket=? AND key=?", a[:2]).fetchone():
        db.execute("ROLLBACK"); sys.exit(1)
    db.execute("INSERT INTO kv VALUES(?,?,?,?)", (a[0], a[1], a[2].encode(), nxt()))
    db.execute("COMMIT")
elif op == "update":
    db.execute("BEGIN IMMEDIATE")
    c = db.execute("UPDATE kv SET value=?, revision=? WHERE bucket=? AND key=? AND revision=?", (a[2].encode(), nxt(), a[0], a[1], int(a[3])))
    if c.rowcount != 1:
        db.execute("ROLLBACK"); sys.exit(1)
    db.execute("COMMIT")
elif op == "del":
    db.execute("DELETE FROM kv WHERE bucket=? AND key=?", a[:2])
elif op == "keys":
    for (k,) in db.execute("SELECT key FROM kv WHERE bucket=? ORDER BY key", a[:1]):
        if k.startswith(a[1]): print(k)
elif op == "revision":
    r = db.execute("SELECT revision FROM kv WHERE bucket=? AND key=?", a[:2]).fetchone()
    if r is None: sys.exit(1)
    print(r[0])
'

# jg_kv_db: the path of the store file, resolved from the home on the first jg_kv_ready.
jg_kv_db() { printf '%s/kv.db\n' "${JG_KV_STATE:-${JG_STATE_OVERRIDE:-}}"; }

# STUB (slice 11b1): the NATS functions above (jg_kv_home_url, jg_kv_resolve, jg_kv_login,
# jg_kv_run, jg_kv_call) are no longer called by the bucket functions; slice 11b5 deletes them.

# jg_kv_ready <home-dir>: 0 iff python3 runs, so a caller can tell a missing store from a
# missing record. The store is a file in the home's state directory.
jg_kv_ready() { # <home-dir>
  [ -n "$JG_KV_READY" ] && return 0
  [ -n "$JG_KV_STATE" ] || JG_KV_STATE=${JG_STATE_OVERRIDE:-$1/state}
  if ! python3 -I -c 'import sqlite3' >/dev/null 2>&1; then
    JG_KV_WHY="python3 with sqlite3 is not available"
    return 1
  fi
  JG_KV_WHY=
  JG_KV_READY=1
  return 0
}

# jg_kv_ensure_bucket <bucket> [history]: a bucket is a column value, so it needs no step;
# this opens the file so a home that has never written to it fails here, not later.
jg_kv_ensure_bucket() { # <bucket> [history]
  python3 -I -c "$JG_KV_PY" ensure "$(jg_kv_db)" >/dev/null 2>&1 || {
    # shellcheck disable=SC2034 # Read by the caller's own refusal or skip text.
    JG_KV_WHY="cannot open the store at $(jg_kv_db)"
    return 1
  }
}

# jg_kv_get <bucket> <key>: the value's bytes on stdout; fails when the key is
# absent or unreadable.
jg_kv_get() { # <bucket> <key>
  python3 -I -c "$JG_KV_PY" get "$(jg_kv_db)" "$1" "$2" 2>/dev/null
}

# jg_kv_put <bucket> <key>: the value arrives on stdin.
jg_kv_put() { # <bucket> <key>
  python3 -I -c "$JG_KV_PY" put "$(jg_kv_db)" "$1" "$2" >/dev/null 2>&1
}

# jg_kv_create <bucket> <key> <value>: write only when the key is new, so two writers
# cannot both create it.
jg_kv_create() { # <bucket> <key> <value>
  python3 -I -c "$JG_KV_PY" create "$(jg_kv_db)" "$1" "$2" "$3" >/dev/null 2>&1
}

# jg_kv_update <bucket> <key> <value> <revision>: write only when the key still
# holds <revision>, so a writer that read a record cannot overwrite a newer one.
jg_kv_update() { # <bucket> <key> <value> <revision>
  python3 -I -c "$JG_KV_PY" update "$(jg_kv_db)" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

# jg_kv_del <bucket> <key>: drop the key, whether or not it exists.
jg_kv_del() { # <bucket> <key>
  python3 -I -c "$JG_KV_PY" del "$(jg_kv_db)" "$1" "$2" >/dev/null 2>&1 || true
}

# jg_kv_keys <bucket> <prefix>: the keys this bucket holds under one prefix.
jg_kv_keys() { # <bucket> <prefix>
  python3 -I -c "$JG_KV_PY" keys "$(jg_kv_db)" "$1" "$2" 2>/dev/null || true
}

# jg_kv_revision <bucket> <key>: the revision the key's current value holds. Fails when the
# key is absent.
jg_kv_revision() { # <bucket> <key>
  python3 -I -c "$JG_KV_PY" revision "$(jg_kv_db)" "$1" "$2" 2>/dev/null
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
