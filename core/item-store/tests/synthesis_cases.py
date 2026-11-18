#!/usr/bin/env python3
"""The final plan's own store cases, beyond the suite (shipped by slice 1 as core/item-store/tests/synthesis_cases.py).
S1 a Recon promoted in place: its one work item closes with a receipt and opens its landing (no type, no promote move).
S2 a reopen at a full project waits as a dispatch item that carries the new words, and starts when a lane frees.
S3 the re-check refuses a write made while a check was dropped and then put back (the hash and the fold are silent).
S4 the same re-check finds an item written around the log (a tamper), so it replaces the fold check.
S7 the release word covers what it named (the owner's decision C1, default): a push after his yes asks him again, a
   doubled push writes nothing, the release cannot go out while that question is open, and after his no the step stays
   open on its ladder (it is never silently left), so a lower rung sees it.
The private replay case (the 14-17 Nov log re-applies clean) and the trigger-order case are run apart: the first reads
fleet records that never enter the repository, the second is tests/trigger_order.py."""
import io, contextlib, json, os, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
from store import Store, Refused, SCHEMA
import prove as proofs
import recheck
from prove import T0, check, refused, RES, FAILS


def s1():
    s = Store(); s.set_policy(T0 - 10, "pj", "loose", "owner:registry", "seed:pj", mode="local", lanes=4)
    t = T0
    s.open(t, "work:pj/r1", "work", "pj", "r1", "investigate r1", "lead:pj", source="d:r1", lane="worker:pj/r1", project="pj")
    s.close(t + 900, "work:pj/r1", "done", "receipt:feed12", "adapter:status", source="st:r1",
            then=[dict(key="land:pj/r1@feed12", kind="land", home="pj", subject="r1", owes="land feed12", project="pj"),
                  dict(key="cleanup:pj/r1", kind="cleanup", home="pj", subject="r1", owes="return the copy")])
    check("S1", s.item("land:pj/r1@feed12") is not None and s.one("SELECT count(*) FROM move WHERE key='work:pj/r1'") == 2,
          "a Recon promoted in place closes with a receipt and opens its landing: no type, no promote move, one item", "B R4.3")


def s2():
    s = Store(); s.set_policy(T0 - 10, "pj", "standard", "owner:registry", "seed:pj", mode="local-trunk", lanes=1)
    t = T0
    s.open(t, "work:pj/r1", "work", "pj", "r1", "investigate r1", "lead:pj", source="d:r1", lane="worker:pj/r1", project="pj")
    s.close(t + 100, "work:pj/r1", "done", "report:data/r1/report.md", "worker:pj/r1", source="st:r1")
    s.open(t + 200, "work:pj/b1", "work", "pj", "b1", "build b1", "lead:pj", source="d:b1", lane="worker:pj/b1", project="pj")
    words = "owner's added scope: also measure the drain"
    q = s.open(t + 300, "dispatch:pj/r1#2", "dispatch", "pj", "r1", "reopen r1: " + words, "lead:pj", source="reopen:r1", parent="work:pj/r1")
    nxt = [dict(key="work:pj/r1#2", kind="work", home="pj", subject="r1", lane="worker:pj/r1", owes=words, project="pj", parent="work:pj/r1")]
    full = refused(lambda: s.close(t + 310, "dispatch:pj/r1#2", "done", "lane:pj/r1", "lead:pj", source="sp:r1#2", then=nxt))
    kept = s.item("dispatch:pj/r1#2")
    s.close(t + 400, "work:pj/b1", "done", "receipt:b1", "adapter:status", source="st:b1")
    s.close(t + 410, "dispatch:pj/r1#2", "done", "lane:pj/r1", "lead:pj", source="sp:r1#2b", then=nxt)
    check("S2", q == "open" and full and kept and s.one("SELECT owes FROM item WHERE key=?", ("dispatch:pj/r1#2",)).endswith(words)
          and s.item("work:pj/r1#2") is not None,
          "a reopen at a full project waits as a dispatch item that carries the new words, and starts when a lane frees", "B R4.2 N3")


def s34():
    with contextlib.redirect_stdout(io.StringIO()):
        s = proofs.journeys()
    sql = s.one("SELECT sql FROM sqlite_master WHERE name='move_hand_check'")
    s.con.execute("DROP TRIGGER move_hand_check")
    k = s.one("SELECT key FROM item WHERE state='open' ORDER BY id LIMIT 1"); at = s.one("SELECT max(at) FROM move") + 5; s._host = at
    s.con.execute("INSERT INTO move(at, verb, key, by, holder, holder_id, due_at, why, frame) VALUES(?,?,?,?,?,?,?,?,?)",
                  (at, "hand", k, "worker:nobody/x", "owner", "owner", at + 400 * 86400, "400 days on the owner", "b:0"))
    s.con.execute(sql)
    found = recheck.recheck(s.con, SCHEMA)
    check("S3", s.schema_hash() == s.shipped and not s.fold_check() and any(b[0] == "move" for b in found),
          "a check dropped, a write it refuses, the check put back: hash and fold are silent, the re-check refuses the move", "B re-check")
    with contextlib.redirect_stdout(io.StringIO()):
        s3 = proofs.journeys()
    s3.con.execute("DROP TRIGGER item_update_via_move")
    s3.con.execute("UPDATE item SET holder='owner', holder_id='owner' WHERE key='update:takeone@abc123'")
    check("S4", any(b[0] == "item" and b[1] == "update:takeone@abc123" for b in recheck.recheck(s3.con, SCHEMA)),
          "an item written around the log is found by the same re-check, so one check replaces the fold check", "X10 X18")


def s7():
    s = Store(); s.set_policy(T0 - 10, "beta", "standard", "owner:chat", "tg:s7", mode="local-trunk")
    t = T0
    s.release_push(t + 10, "beta", "pr1", "h1", source="push:h1")
    s.close(t + 100, "question:release:beta@pr1", "done", "owner:chat:m1 pick=yes", "owner:chat", source="m1",
            then=[dict(key="release:beta@pr1", kind="release", home="beta", subject="beta@pr1", owes="release pr1 on his word", project="beta")])
    again = s.release_push(t + 200, "beta", "pr1", "h2", source="push:h2")          # pushed after his yes
    twice = s.release_push(t + 200, "beta", "pr1", "h2", source="push:h2")          # the same push again
    held = refused(lambda: s.release_out(t + 300, "beta", "pr1", "h2", source="merged:pr1"))
    covered = s.covered_head("beta", "pr1")
    s.close(t + 400, "question:release:beta@pr1", "done", "owner:chat:m2 pick=no", "owner:chat", source="m2")
    step = s.item("release:beta@pr1")
    s.tick(t + 400 + 3600 + 60)                                                    # the step's limit passes: it climbs, it is not lost
    climbed = s.item("release:beta@pr1")
    check("S7", again == "open" and twice == "again" and held and covered == "h1" and step is not None
          and climbed is not None and climbed["holder"] == "main",
          "a push after his yes asks him again; the same push twice writes nothing; no release goes out while that question is open; "
          "his first yes covers h1 only; after his no the step stays open and climbs to Main", "C1 C2 D8")


if __name__ == "__main__":
    s1(); s2(); s34(); s7()
    mine = [r for r in RES if r["id"].startswith("S")]
    print("\n%d synthesis cases: %d PASS, %d FAIL" % (len(mine), sum(r["ok"] for r in mine), len(mine) - sum(r["ok"] for r in mine)))
    sys.exit(1 if FAILS else 0)
