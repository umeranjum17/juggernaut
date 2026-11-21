"""The store's re-check (it replaces the fold check, which cannot see a check dropped and put back): re-apply the whole log (policy rows and moves, in order) to a fresh store built from the
shipped schema. A move the shipped rules refuse is a write the rules never allowed, even when the check that should have
refused it was dropped and later put back, which the schema hash (same text again) and the fold check (the item rows
follow the moves) cannot see. Returns [(table, seq or version, error)]; empty means the log is legal under today's rules."""
import sqlite3

MOVE_COLS = ("seq", "at", "verb", "key", "kind", "home", "subject", "project", "parent", "by", "source", "holder", "holder_id", "due_at", "ends", "why", "options", "page", "frame")

def recheck(con, schema, keep=None):
    fresh = sqlite3.connect(":memory:", isolation_level=None)
    now = [0]
    fresh.create_function("host_now", 0, lambda: now[0])
    fresh.execute("PRAGMA foreign_keys=ON"); fresh.execute("PRAGMA recursive_triggers=ON")   # as store.py opens every connection
    fresh.executescript(open(schema, encoding="utf-8").read())
    if keep is not None: keep.append(fresh)
    pol = con.execute("SELECT * FROM policy ORDER BY set_at, project, version").fetchall()
    pcols = [d[0] for d in con.execute("SELECT * FROM policy LIMIT 0").description]
    moves = con.execute("SELECT %s FROM move ORDER BY seq" % ",".join(MOVE_COLS)).fetchall()
    bad, pi = [], 0
    for m in moves:
        while pi < len(pol) and pol[pi][pcols.index("set_at")] <= m[1]:
            p = pol[pi]; now[0] = p[pcols.index("set_at")]
            try:
                fresh.execute("INSERT INTO policy VALUES(%s)" % ",".join("?" * len(p)), p)
            except sqlite3.Error as e:
                bad.append(("policy", p[1], str(e)[:120]))
            pi += 1
        now[0] = m[1]
        have = fresh.execute("SELECT %s FROM move WHERE seq=?" % ",".join(MOVE_COLS), (m[0],)).fetchone()
        if have is not None:      # the shipped rules wrote this move themselves (a cascade): it must be the same move
            if tuple(have) != tuple(m):
                bad.append(("move", m[0], "the rules write a different move here: %s" % (have[2:4],)))
            continue
        try:
            fresh.execute("INSERT INTO move(%s) VALUES(%s)" % (",".join(MOVE_COLS), ",".join("?" * len(MOVE_COLS))), m)
        except sqlite3.Error as e:
            bad.append(("move", m[0], str(e)[:120]))
    cols = "key, gen, kind, state, holder, holder_id, due_at, late_at, closed_at, outcome"
    a = set(con.execute("SELECT %s FROM item" % cols)); b = set(fresh.execute("SELECT %s FROM item" % cols))
    for row in sorted(a ^ b, key=str)[:20]:
        bad.append(("item", row[0], "the item rows differ from the log's fold under today's rules"))
    return bad

