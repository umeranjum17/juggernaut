#!/usr/bin/env bash
# jg-kv-lib.sh - the one owner of the key-value store the task leases live in.
#
# WHY. The task leases (bin/jg-lease-lib.sh) keep records in one SQLite file, state/kv.db. They
# need the same things - how a bucket comes into being, and how a value is read, written,
# deleted and revisioned - so this library owns them once instead of each path re-spelling a
# store call.
#
# CONTRACT.
#   store    $JG_KV_STATE/kv.db (the home's state directory), read and written through python3's
#            sqlite3.
#   gate     jg_kv_ready fails, printing the reason into JG_KV_WHY, when python3 with sqlite3 is
#            missing. It never decides whether that is a skip or a refusal: a live lease
#            decision refuses, and that choice belongs to the caller.
#   values   bytes. A value read back with jg_kv_get is the value written, with no
#            quoting, escaping or JSON in the way.
#   revision jg_kv_revision prints the revision the key's current value holds,
#            which is the compare-and-set token a claiming writer pins its write
#            to.
#
# Callers resolve their home and state before sourcing this; nothing here has a
# side effect at source time. set -u safe, and every function returns non-zero
# rather than exiting, so a caller keeps the last word.
#
# Sourced by bin/jg-lease-lib.sh.

JG_KV_WHY=
JG_KV_READY=
JG_KV_STATE=

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
