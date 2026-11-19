#!/usr/bin/env python3
"""Proof suite for schema.sql. Runs on throwaway in-memory stores; writes nothing outside.

  A  legal journeys: a ship from dispatch to In use in every home, a Recon, a parked lane, a yolo-off release
  R  refusals: every illegal move the past misses need refused, each tagged with the misses it catches
  I  idempotency: every action run twice gives the same store and one outside effect
  M  mutants: drop each trigger or unique index; some refusal case must then pass (each part is needed)
  F  fold and tamper: item = fold(move); a direct write is refused; a dropped trigger is seen by the schema check
Prints one PASS/FAIL line per case and a summary; exits 1 on any FAIL."""
import hashlib, json, os, re, sqlite3, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
from store import Store, Refused, SCHEMA, FOLD_ALERT as FOLD_ALERT_KEY

T0 = 1794614400
RES, FAILS = [], []


def check(cid, ok, what, tags=""):
    RES.append({"id": cid, "ok": bool(ok), "what": what, "catches": tags})
    if not ok:
        FAILS.append(cid)
    print("%s %-6s %s%s" % ("PASS" if ok else "FAIL", cid, what, ("  [" + tags + "]") if tags else ""))


def refused(fn):
    try:
        fn()
        return None
    except Refused as e:
        return str(e)


def raw(s, **kw):
    """One raw INSERT INTO move, bypassing the writer's own logic (what a careless script could do). It stamps its own
    host clock correctly, so each case tests the rule it names, not the clock."""
    s._host = kw.get("at", s._host)
    s._write([kw])


def owner_logs(s, skip=()):
    """What his channels' own logs, and the logs of the adapters that alone close a kind, hold for the moves written
    so far: (record id, item key) per move, and (source, 'policy:<project>') per policy version. `skip` leaves out forged
    ids (they are not in any log)."""
    logs = {}
    for by, src, key in s.con.execute("SELECT by, source, key FROM move WHERE source IS NOT NULL"):
        if (by.startswith("owner:") or by in s.closers) and src not in skip:
            logs.setdefault(by, set()).add((src, key))
    for by, src, pj in s.con.execute("SELECT set_by, source, project FROM policy"):
        logs.setdefault(by, set()).add((src, "policy:" + pj))
    return logs


def store():
    """A fresh store with one policy version: muxr and crewhouse are loose (yolo on), as their registry rows say today."""
    s = Store()
    for pj in ("muxr", "crewhouse"):
        s.set_policy(T0 - 10, pj, "loose", "owner:registry", "seed:" + pj, mode="local", lanes=8)
    return s


# ------------------------------------------------------------------------------------------- A legal journeys
def journeys():
    s = store()
    t = T0
    s.open(t, "dispatch:muxr/jg-1", "dispatch", "muxr", "jg-1", "start jg-1", "main", source="approve:jg-1")
    s.close(t + 60, "dispatch:muxr/jg-1", "done", "lane:muxr/jg-1", "main", source="spawn:muxr/jg-1",
            then=[dict(key="work:muxr/jg-1", kind="work", home="muxr", subject="jg-1", lane="worker:muxr/jg-1", owes="build jg-1")])
    assert s.item("work:muxr/jg-1")["holder"] == "worker"
    s.open(t + 120, "wait:muxr/jg-1/schema", "wait", "muxr", "jg-1", "which table?", "worker:muxr/jg-1", source="st:1", named="main")
    s.close(t + 300, "wait:muxr/jg-1/schema", "done", "answer:Main42000", "main", source="st:2")
    s.close(t + 900, "work:muxr/jg-1", "done", "receipt:abc123", "adapter:status", source="st:3",     # the lane adapter reads the done line
            then=[dict(key="land:muxr/jg-1@abc123", kind="land", home="muxr", subject="jg-1", owes="land abc123"),
                  dict(key="cleanup:muxr/jg-1", kind="cleanup", home="muxr", subject="jg-1", owes="return the copy")])
    s.close(t + 960, "land:muxr/jg-1@abc123", "done", "trunk:abc123", "adapter:trunk", source="trunk:muxr@abc123",
            then=[dict(key="release:muxr@pr41", kind="release", home="muxr", subject="jg-1", owes="yolo on: release pull request pr41 at abc123")])
    s.close(t + 1000, "release:muxr@pr41", "done", "released:pr41 at abc123 yolo:data/projects.md@9f1", "adapter:trunk", source="rel:muxr@pr41",
            then=[dict(key="update:%s@abc123" % h, kind="update", home=h, subject="jg-1", owes="run abc123") for h in ("muxr", "takeone")])
    s.close(t + 1200, "update:muxr@abc123", "done", "home-at:abc123", "adapter:update", source="home:muxr@abc123")
    s.close(t + 1300, "cleanup:muxr/jg-1", "done", "cleaned:slot 4", "lead:muxr", source="clean:muxr/jg-1")
    # takeone lags: its own item climbs; muxr is In use already (X14, N4)
    climbs = s.tick(t + 1000 + 7200)
    check("A1", s.item("update:takeone@abc123")["holder"] == "main" and not s.item("update:muxr@abc123"),
          "ship: dispatch -> work -> wait answered -> done with receipt -> land -> release (yolo is the word) -> In use per home; the lagging home climbs alone", "A3 X14 N4 X13 A12")
    check("A2", not s.fold_check() and not s.count_check(), "the fold of the move log equals the items; the count adds up for every kind")
    t = T0 + 20000          # the journeys below start later: the writer never stamps a move before the last one
    # recon
    s.open(t, "work:crewhouse/jg-r", "work", "crewhouse", "jg-r", "investigate", "lead:crewhouse", source="d:r", lane="worker:crewhouse/jg-r")
    s.close(t + 500, "work:crewhouse/jg-r", "done", "report:data/jg-r/report.md", "worker:crewhouse/jg-r", source="st:r",
            then=[dict(key="report:crewhouse/jg-r", kind="report", home="crewhouse", subject="jg-r", owes="act on the finished Recon")])
    s.tick(t + 500 + 3600)
    it = s.item("report:crewhouse/jg-r")
    check("A3", it and it["holder"] == "main" and s.one("SELECT late_at FROM item WHERE key='report:crewhouse/jg-r'"),
          "Recon done opens Main's report item; unread past an hour it is late on Main and in the digest", "A1 X11")
    t = t + 5000
    # park: a hand to the lead with a date and a reason
    s.open(t, "work:muxr/jg-p", "work", "muxr", "jg-p", "build", "lead:muxr", source="d:p", lane="worker:muxr/jg-p")
    s.hand(t + 10, "work:muxr/jg-p", "lead", "lead:muxr", 7 * 86400, "parked: waits for quota reset", "lead:muxr", source="park:p")
    s.tick(t + 10 + 7 * 86400)
    check("A4", s.item("work:muxr/jg-p")["holder"] == "main", "a park is a hand to the lead with a date and a reason; at the date it climbs", "U1 N3")
    t = T0 + 9 * 86400
    # yolo off: the release waits on a question; a question on the ticket stops the release open
    s.open(t, "question:release:muxr@pr42", "question", "muxr", "jg-2", "release pull request pr42 at def456?", "tick", source="rq:def")
    e = refused(lambda: s.open(t + 5, "release:muxr@pr42", "release", "muxr", "jg-2", "release pr42", "tick", source="rel:def"))
    s.close(t + 100, "question:release:muxr@pr42", "done", "owner:telegram:1215 pick=yes", "owner:telegram", source="tg:1215",
            then=[dict(key="release:muxr@pr42", kind="release", home="muxr", subject="jg-2", owes="release pr42 on his word")])
    check("A5", e and s.item("release:muxr@pr42"), "yolo off: release opens only when his question closes on his own message", "X9 U5")
    t = t + 1000
    # the policy drives the project: standard lands alone and asks for the release; a shorter lead rung climbs sooner
    s.set_policy(t, "sign-off", "standard", "owner:chat", "tg:1300", lead_s=600)
    s.open(t, "land:sign-off/jg-s@s1", "land", "sign-off", "jg-s", "land s1", "tick", source="ready:s1", project="sign-off")
    e2 = refused(lambda: s.open(t, "release:sign-off@pr377", "release", "sign-off", "sign-off@pr377", "release pr377", "tick", project="sign-off"))
    s.open(t, "question:release:sign-off@pr377", "question", "sign-off", "sign-off@pr377", "release pr377?", "tick", source="rq:s1")
    s.close(t + 50, "question:release:sign-off@pr377", "done", "owner:chat:note-9 pick=yes", "owner:chat", source="note-9")
    s.open(t + 60, "release:sign-off@pr377", "release", "sign-off", "sign-off@pr377", "release pr377 on his word", "tick", source="rel:s1", project="sign-off")
    s.open(t + 70, "work:sign-off/jg-s2", "work", "sign-off", "jg-s2", "build", "lead:sign-off", source="d:s2", lane="worker:sign-off/jg-s2", project="sign-off")
    s.hand(t + 71, "work:sign-off/jg-s2", "lead", "lead:sign-off", 600, "failed: tests red", "worker:sign-off/jg-s2", source="f:s2")
    s.tick(t + 671)
    w2 = s.con.execute("SELECT holder, due_at FROM item WHERE key='work:sign-off/jg-s2' AND state='open'").fetchone()
    # the review base comes from the policy: a local-trunk project reviews against its trunk, a PR project against origin
    s.set_policy(t, "muxr-lt", "loose", "owner:chat", "tg:1400", mode="local-trunk", trunk="main")
    s.set_policy(t, "pr-app", "tight", "owner:chat", "tg:1401", mode="direct-PR", trunk="main")
    b_lt, b_pr, b_none = s.base("muxr-lt"), s.base("pr-app"), refused(lambda: s.base("no-such-project"))
    check("A7", b_lt == "refs/heads/main" and b_pr == "refs/remotes/origin/main" and b_none,
          "the review base comes from the project's mode and trunk: a local-trunk project reviews against its own trunk, never origin/main; no policy, no base", "Y3 jg-kile-s3")
    # Main's answer closes what it answers and opens the steer that carries it, in one write; delivery comes after
    s.open(t + 700, "needs-answer:muxr/jg-a8", "alert", "muxr", "jg-a8", "the lead needs Main's answer", "lead:muxr", source="a8", named="main")
    s.close(t + 760, "needs-answer:muxr/jg-a8", "done", "gone: answered by Main42521", "main", source="send:main/muxr/77",
            then=[dict(key="steer:main/muxr/77", kind="steer", home="muxr", subject="jg-a8", named="lead", owes="act on Main's answer")])
    answered_before_delivery = not s.item("needs-answer:muxr/jg-a8") and s.item("steer:main/muxr/77")
    s.tick(t + 760 + 3 * 3600)          # the delivery hangs for hours: nothing it answered climbs
    no_climb = not s.one("SELECT 1 FROM move WHERE key='needs-answer:muxr/jg-a8' AND verb='climb'")
    s.open(t + 9000, "other-question:muxr/jg-a8", "alert", "muxr", "jg-a8", "a second question for Main", "lead:muxr", source="a8b", named="main")
    e3 = refused(lambda: s.close(t + 9001, "other-question:muxr/jg-a8", "done", "gone: x", "main", source="send:main/muxr/78",
                                 then=[dict(key="steer:main/muxr/78", kind="steer", home="muxr", subject="jg-a8", named="owner", owes="x")]))
    check("A8", answered_before_delivery and no_climb and e3 and s.item("other-question:muxr/jg-a8") and not s.seen("send:main/muxr/78"),
          "an answer closes its item and opens the steer to the lead in one write, before delivery; a hung delivery leaves nothing climbing; if any part is refused, nothing is written",
          "Y4 jg-send --resolve-key")
    # a lane's final move closes every alert and steer on it in the same write; its owner question stays
    s.open(t + 9100, "work:muxr/jg-kile", "work", "muxr", "jg-kile", "build", "lead:muxr", source="d:kile", lane="worker:muxr/jg-kile")
    s.open(t + 9101, "stuck:muxr/jg-kile", "alert", "muxr", "jg-kile", "the worker stopped writing", "adapter:liveness", source="st:kile", named="lead")
    s.open(t + 9102, "steer:main/muxr/jg-kile/1", "steer", "muxr", "jg-kile", "rebase", "main", source="sk:1", named="worker", lane="worker:muxr/jg-kile")
    s.open(t + 9103, "wait:muxr/jg-kile/pick", "wait", "muxr", "jg-kile", "which table?", "worker:muxr/jg-kile", source="wk:1", named="main")
    again = s.open(t + 9150, "stuck:muxr/jg-kile", "alert", "muxr", "jg-kile", "the worker stopped writing (steer 2)", "adapter:liveness", source="st:kile:2", named="lead")
    one_alert = again == "note" and s.one("SELECT count(*) FROM item WHERE kind='alert' AND subject='jg-kile' AND state='open'") == 1
    s.close(t + 9200, "work:muxr/jg-kile", "done", "receipt:PASS", "worker:muxr/jg-kile", source="done:kile")
    left = [k for (k,) in s.con.execute("SELECT key FROM item WHERE state='open' AND subject='jg-kile' AND kind IN ('alert','steer')")]
    s.tick(t + 9200 + 3 * 86400)
    check("A9", one_alert and not left and s.item("wait:muxr/jg-kile/pick") and not s.fold_check(),
          "one alert per subject and cause (a repeat is a note); a done lane holds no live alert or steer: its final move closes them in the same write; a wait someone else owes stays", "Y5 jg-kile-s3 X1")
    # an owner question is withdrawn only by its raiser; after it paged him, his digest lists it with its reason
    t2 = s.one("SELECT max(at) FROM move") + 1000     # after every earlier journey's last move
    s.open(t2, "question:muxr/jg-q1", "question", "muxr", "jg-q1", "keep or drop jg-q1?", "lead:muxr", source="q1", quiet=True)
    s.close(t2 + 5, "question:muxr/jg-q1", "dropped", "no longer needed: the lane found the answer in the docs", "lead:muxr", source="w1")
    s.open(t2 + 10, "question:muxr/jg-q2", "question", "muxr", "jg-q2", "keep or drop jg-q2?", "lead:muxr", source="q2")
    s.close(t2 + 600, "question:muxr/jg-q2", "dropped", "released by the lead: the ticket moved to next week", "lead:muxr", source="w2")
    listed = [(k, why) for _, _, k, _, why in s.con.execute("SELECT * FROM v_withdrawn")]
    s.con.execute("INSERT INTO cursor VALUES('owner-digest', (SELECT max(seq) FROM move)) ON CONFLICT(reader) DO UPDATE SET seq=excluded.seq")
    check("A10", listed == [("question:muxr/jg-q2", "released by the lead: the ticket moved to next week")] and not s.con.execute("SELECT 1 FROM v_withdrawn").fetchone(),
          "his question is withdrawn only by its raiser: before it paged him nothing is shown; after, his next digest lists it with its reason, once", "N9 X9")
    # a forged owner stamp gets past the store, but the owner check finds it within one tick and opens a security item
    s.open(t2 + 700, "question:muxr/jg-q3", "question", "muxr", "jg-q3", "merge jg-q3?", "lead:muxr", source="q3")
    s._host = t2 + 701
    s.con.execute("INSERT INTO move(at, verb, key, by, source, ends, why) VALUES(?,?,?,?,?,?,?)",
                  (t2 + 701, "close", "question:muxr/jg-q3", "owner:board", "forged-by-main", "done", "owner:board yes pick=yes"))
    logs = owner_logs(s, skip={"forged-by-main"})
    found = [p[0] for _, _, p in s.stamp_check(t2 + 760, logs)]
    check("A11", found == ["forged-by-main"] and s.item("security:fleet/forged-move-%d" % s.one("SELECT seq FROM move WHERE source='forged-by-main'"))
          and s.stamp_check(t2 + 820, logs) == [] and s.one("SELECT count(*) FROM item WHERE kind='security' AND subject='stamp'") == 1,
          "a raw write that forges an owner stamp is found by the owner check against his channel's own log: one security item to Main, once", "X9 X15 X17 U5 U9 U14 N9")
    # the host clock runs back 30 days: nothing is refused or lost, a clock alert reaches Main at the next tick, and
    # clears when the host clock passes the last move again
    t3 = t2 + 1000
    s.tick(t3, steady=t3)                                       # the tick's last run: host and steady clocks agree
    s.open(t3, "steer:main/muxr/jg-c/1", "steer", "muxr", "jg-c", "rebase", "main", source="c1", named="lead")
    back = t3 - 30 * 86400
    s._off[0] = -30 * 86400                                    # a writer during the jump reads the jumped frame
    s.open(back + 5, "steer:main/muxr/jg-c/2", "steer", "muxr", "jg-c", "rebase again", "main", source="c2", named="lead")
    s.tick(back + 60, steady=t3 + 60)                           # the host clock runs 30 days behind
    raised = s.item("clock:main/host")
    s.tick(t3 + 4000, steady=t3 + 4000)                         # and is right again: the steer, due in true time, is due at the next tick
    s.tick(t3 + 4060, steady=t3 + 4060)
    climbed = s.one("SELECT count(*) FROM move WHERE verb='climb' AND key='steer:main/muxr/jg-c/1'")
    check("A12", raised and raised["holder"] == "main" and not s.item("clock:main/host") and s.seen("c2") and climbed,
          "the host clock runs back 30 days: the write is kept, Main gets a clock alert at the next tick, it clears when the clock is right, and the earlier steer still climbs", "")
    # tight (yolo off): his one word on the ticket lands it and carries the release; no second question
    s.set_policy(t3 + 4000, "pockit-t", "tight", "owner:chat", "tg:1500", mode="local")
    e4 = refused(lambda: s.open(t3 + 4001, "land:pockit-t/jg-t@t1", "land", "pockit-t", "jg-t", "land t1", "tick", project="pockit-t"))
    s.open(t3 + 4002, "question:land:pockit-t/jg-t@t1", "question", "pockit-t", "jg-t", "land jg-t at t1?", "tick", source="lq:t")
    s.close(t3 + 4100, "question:land:pockit-t/jg-t@t1", "done", "owner:chat:note-21 pick=yes", "owner:chat", source="note-21")
    s.open(t3 + 4101, "land:pockit-t/jg-t@t1", "land", "pockit-t", "jg-t", "land t1 on his word", "tick", source="land:t", project="pockit-t")
    s.close(t3 + 4102, "land:pockit-t/jg-t@t1", "done", "trunk:t1", "adapter:trunk", source="trunk:t1",
            then=[dict(key="release:pockit-t@pr1", kind="release", home="pockit-t", subject="pockit-t@pr1", owes="release pull request pr1 at t1", project="pockit-t")])
    asks = s.one("SELECT count(*) FROM item WHERE kind='question' AND key LIKE '%pockit-t%'")
    check("A13", e4 and s.item("release:pockit-t@pr1") and asks == 1,
          "tight (yolo off): the landing waits for his word; that one word carries it to release, with no second question", "K1 jg8-j21")
    # Y6 (18 Nov, muxr): the trunk lander re-cuts the lane's commit (same patch, new hash). The landed check reads the
    # land item's proof, so cleanup goes on its own; nothing asks the owner, and the copy's own head is never searched for.
    t6 = t3 + 5000
    s.open(t6, "work:muxr/jg-r", "work", "muxr", "jg-r", "build jg-r", "lead:muxr", source="d-r", lane="worker:muxr/jg-r")
    s.close(t6 + 10, "work:muxr/jg-r", "done", "receipt:aaa111", "adapter:status", source="st-r",
            then=[dict(key="land:muxr/jg-r@aaa111", kind="land", home="muxr", subject="jg-r", owes="land aaa111")])
    s.close(t6 + 20, "land:muxr/jg-r@aaa111", "done", "trunk:bbb222 recut of aaa111", "adapter:trunk", source="trunk:muxr@bbb222",
            then=[dict(key="cleanup:muxr/jg-r", kind="cleanup", home="muxr", subject="jg-r", owes="return the copy")])
    before_check = s.landed("jg-r")                  # not yet passed by the stamp check: the cleanup waits (at most one tick)
    s.stamp_check(t6 + 25, owner_logs(s))
    landed = s.landed("jg-r")
    s.close(t6 + 30, "cleanup:muxr/jg-r", "done", "cleaned:landed as " + landed, "adapter:teardown", source="clean:muxr/jg-r")
    q6 = s.one("SELECT count(*) FROM item WHERE kind='question' AND subject='jg-r'")
    check("A14", before_check is None and landed == "bbb222" and s.one("SELECT state FROM item WHERE key='cleanup:muxr/jg-r'") == "done" and q6 == 0
          and s.one("SELECT landed FROM v_ticket WHERE ticket='jg-r'") == 1,
          "a re-cut landing (new hash, same patch): the land item names the landed commit, the landed check reads it, and cleanup goes without an owner word", "Y6")
    # the approval record (state/dispatch-approved/<ticket>, written by jg-backlog.sh approve-dispatch) is the arrival;
    # the dispatch adapter opens one dispatch item from it; no lane in 24 h and it climbs to Main.
    t8 = t6 + 100
    s.open(t8, "dispatch:muxr/jg-q", "dispatch", "muxr", "jg-q", "start jg-q", "adapter:dispatch", source="state/dispatch-approved/jg-q@%d" % t8)
    again = s.open(t8 + 5, "dispatch:muxr/jg-q", "dispatch", "muxr", "jg-q", "start jg-q", "adapter:dispatch", source="state/dispatch-approved/jg-q@%d" % t8)
    s.tick(t8 + 86400 + 60)
    d8 = s.item("dispatch:muxr/jg-q")
    check("A15", again == "again" and d8["holder"] == "main",
          "an approval record opens one dispatch item (a second read of it is 'again'); with no lane after 24 h it climbs from the lead to Main", "A3 A7")
    check("A6", e2 and s.item("release:sign-off@pr377") and w2 == ("main", t + 671 + 3600),
          "standard project: the landing goes alone, the release waits for his word, and its 10-minute lead rung climbs to Main on time", "K1 U2")
    return s


# ------------------------------------------------------------------------------------------- A16 the page read
def reads():
    """Y7 (18 Nov, Main home): one drain of 259 wake rows printed 113,366 lines (32.5 MB) and ran past its 400 s limit,
    mostly status lines weeks old. A page read prints only pages past the reader's cursor, one line per item, at most
    200 lines and 32 KiB, then a count line; nothing is lost past the cap, and an unacknowledged read repeats."""
    s = store()
    t = T0 + 90000
    for i in range(300):        # 300 arrivals paged to Main, each with a long text (one of 20 KB), then 40 closed before Main reads
        s.open(t + i, "intake:main/x%d" % i, "intake", "main", "x%d" % i, ("long " * 4000) if i == 250 else ("arrival %d " % i) * 30,
               "adapter:lane", source="ar:%d" % i)
    for i in range(5):          # the same cause again: a note, and no second page inside the 2-hour quiet
        s.open(t + 310 + i, "intake:main/x45", "intake", "main", "x45", "again", "adapter:lane", source="ar:again:%d" % i)
    for i in range(40):
        s.close(t + 400 + i, "intake:main/x%d" % i, "done", "filed:x%d" % i, "main", source="f:%d" % i)
    for i in range(250):        # 250 short dispatch pages to the muxr lead
        s.open(t + 500 + i, "dispatch:muxr/d%d" % i, "dispatch", "muxr", "d%d" % i, "start d%d" % i, "main", source="ap:%d" % i)
    keys = lambda p: [l.split("\t")[1] for l in p[:-1]]
    size = lambda p: sum(len(l) + 1 for l in p)
    p1, a1 = s.pages("main")
    p1b, a1b = s.pages("main")                          # Main died before acting: the same read again
    got, reads_n, p = list(keys(p1)), 1, p1
    s.ack("main", a1)
    while reads_n < 10:                                 # read and acknowledge until the count line says 0 more
        p, a = s.pages("main"); reads_n += 1; got += keys(p); s.ack("main", a)
        if " 0 more after ack" in p[-1]:
            break
    past = refused(lambda: s.ack("lead:muxr", 10 ** 9))                 # only what a read shows can be acknowledged
    l1, la = s.pages("lead:muxr")
    ok_main = (p1 == p1b and a1 == a1b and len(keys(p1)) < 200 and size(p1) <= 32768 and "40 closed since paged" in p1[-1]
               and len(got) == len(set(got)) and set(got) == {"intake:main/x%d" % i for i in range(40, 300)}
               and max(len(l) for l in p1) < 300 and reads_n == 2)
    ok_lead = len(keys(l1)) == 200 and size(l1) <= 32768 and "50 more after ack" in l1[-1] and past
    check("A16", ok_main and ok_lead, "a page read lists only pages past the cursor, one line per item (a 20 KB text cut to 160 characters), "
          "at most 32 KiB (Main: %d of 260 lines) and 200 lines (the lead: 200 of 250), with a count line; an unacknowledged read repeats; "
          "the rest come after the ack, none twice; closed items are counted, not listed" % len(keys(p1)), "Y7 N7")


# ------------------------------------------------------------------------------------------- A17 to A22: drafts, steps, clock leaps and stamps
def round2():
    t = T0 + 120000
    # A17 (Y8, 18 Nov): a ready draft starts the next critic round in the same write, found by the link set at spawn
    s = store()
    s.open(t, "dispatch:muxr/rc", "dispatch", "muxr", "rc", "start the Recon rc", "main", source="ap:rc")
    s.close(t + 10, "dispatch:muxr/rc", "done", "lane:muxr/rc", "lead:muxr", source="sp:rc",
            then=[dict(key="work:muxr/rc", kind="work", home="muxr", subject="rc", lane="worker:muxr/rc", owes="research rc")])
    r1 = s.ready(t + 100, "work:muxr/rc", "d1", "worker:muxr/rc", source="st:rc:1")
    seq1 = s.one("SELECT max(seq) FROM move")
    d = s.item("dispatch:muxr/rc/critic")
    same1 = s.one("SELECT count(DISTINCT at) FROM move WHERE seq >= ?", (seq1 - 1,)) == 1
    s.close(t + 400, "dispatch:muxr/rc/critic", "done", "lane:muxr/zz-any-name", "lead:muxr", source="sp:crit",     # the critic's name follows no convention
            then=[dict(key="work:muxr/zz-any-name", kind="work", home="muxr", subject="zz-any-name", lane="worker:muxr/zz-any-name",
                       owes="criticise rc", parent="work:muxr/rc")])
    r2 = s.ready(t + 2000, "work:muxr/rc", "d2", "worker:muxr/rc", source="st:rc:2")
    st = s.item("steer:muxr/zz-any-name/round@d2")
    again = s.ready(t + 2001, "work:muxr/rc", "d2", "worker:muxr/rc", source="st:rc:2")
    s.tick(t + 2000 + 1801)
    climbed = s.item("steer:muxr/zz-any-name/round@d2")
    nolane = refused(lambda: s.ready(t + 2100, "work:muxr/none", "d1", "worker:muxr/none", source="st:none"))
    check("A17", r1 == "dispatch" and d and d["holder"] == "lead" and d["due_at"] == t + 100 + 1800 and same1 and r2 == "round" and st
          and st["holder_id"] == "worker:muxr/zz-any-name" and st["due_at"] == t + 2000 + 1800 and again == "again" and climbed["holder"] == "lead" and nolane,
          "a ready draft opens the next critic round in the same write: a steer to the critic lane found by its spawn link (any name), or a "
          "dispatch item for a critic when none runs; either climbs after 30 minutes", "Y8")

    # A18: on a tight project only his yes on the step's own question opens the merge or the landing
    s = store()
    s.set_policy(t, "tp", "tight", "owner:chat", "tg:tp", mode="direct-PR")
    s.open(t + 1, "question:tp/jg-7/design", "question", "tp", "jg-7", "pick a design for jg-7", "lead:tp", source="qd", options="A|B")
    s.close(t + 2, "question:tp/jg-7/design", "done", "owner:board:m1 pick=A", "owner:board", source="m1")
    e_design = refused(lambda: s.open(t + 3, "merge:tp/jg-7@pr12", "merge", "tp", "jg-7", "merge jg-7", "main", project="tp", source="mg1"))
    s.open(t + 4, "question:merge:tp/jg-7@pr12", "question", "tp", "jg-7", "merge jg-7 (pull request pr12)?", "tick", source="qm")
    s.close(t + 5, "question:merge:tp/jg-7@pr12", "done", "owner:chat:m2 pick=no", "owner:chat", source="m2")
    e_no = refused(lambda: s.open(t + 6, "merge:tp/jg-7@pr12", "merge", "tp", "jg-7", "merge jg-7", "main", project="tp", source="mg2"))
    s.open(t + 7, "question:merge:tp/jg-7@pr12", "question", "tp", "jg-7", "merge jg-7 (pull request pr12) now?", "tick", source="qm2")
    s.close(t + 8, "question:merge:tp/jg-7@pr12", "done", "owner:chat:m3 pick=yes", "owner:chat", source="m3")
    ok_yes = s.open(t + 9, "merge:tp/jg-7@pr12", "merge", "tp", "jg-7", "merge jg-7", "main", project="tp", source="mg3") == "open"
    e_land = refused(lambda: s.open(t + 10, "land:tp/jg-7@h7", "land", "tp", "jg-7", "land jg-7", "tick", project="tp", source="ld1"))
    check("A18", e_design and e_no and ok_yes and e_land,
          "tight: a design pick on the ticket does not open its merge, nor does his 'no'; his 'yes' on question:<the merge's key> opens "
          "the merge only, not the landing", "X9 U4 U5 hard-rule-2")

    # A19: one chat message both opens a reply to him and answers a question: both moves are written
    s = store()
    s.open(t, "question:muxr/jg-9/q", "question", "muxr", "jg-9", "keep jg-9?", "lead:muxr", source="q9")
    a = s.open(t + 5, "tell:msg-77", "tell", "main", "msg-77", "reply to his note", "owner:chat", source="msg-77")
    b = s.close(t + 5, "question:muxr/jg-9/q", "done", "owner:chat:msg-77 pick=yes", "owner:chat", source="msg-77")
    c = s.close(t + 6, "question:muxr/jg-9/q", "done", "owner:chat:msg-77 pick=yes", "owner:chat", source="msg-77")
    check("A19", a == "open" and b == "done" and c == "again" and s.one("SELECT state FROM item WHERE key='question:muxr/jg-9/q'") == "done",
          "one message of his opens a reply duty and answers a question: the idempotency key is (message, item), so both are written once", "N9 A8")

    # A20: the host clock jumps 30 days ahead for 10 minutes and comes back. The tick sees the leap against its
    # steady clock both ways and moves every open deadline with it: nothing climbs during the jump, every deadline has its
    # true time after it, and the alert opens on Main and closes when the clock is back
    s = store()
    s.tick(t, steady=t)
    s.open(t, "steer:main/muxr/j1", "steer", "muxr", "jg-j", "rebase", "main", source="j1", named="lead")
    d1 = s.item("steer:main/muxr/j1")["due_at"]
    jump = t + 30 * 86400
    s.tick(jump + 60, steady=t + 60)                            # during the jump: a leap of +30 days
    none_climbed = s.item("steer:main/muxr/j1")["holder"] == "lead" and s.item("clock:main/host")
    s.open(jump + 120, "wait:muxr/jg-j/w", "wait", "muxr", "jg-j", "which base?", "worker:muxr/jg-j", source="j2", named="lead")
    lw = s.item("wait:muxr/jg-j/w")["due_at"] - (jump + 120)
    s.tick(t + 700, steady=t + 700)                             # the clock is back: a leap of -30 days
    st_, w = s.item("steer:main/muxr/j1"), s.item("wait:muxr/jg-j/w")
    back_ok = st_["due_at"] == d1 and w["due_at"] == t + 120 + lw and not s.item("clock:main/host")
    s.tick(t + 120 + lw + 1, steady=t + 120 + lw + 1)
    climbed = s.item("wait:muxr/jg-j/w")["holder"] == "main"
    ahead = s.one("SELECT count(*) FROM item i WHERE state='open' AND late_at IS NULL AND (SELECT m.at FROM move m WHERE m.key=i.key "
                  "AND m.verb IN ('open','hand','climb') ORDER BY m.seq DESC LIMIT 1) > ?", (t + 120 + lw + 1 + 300,))
    check("A20", none_climbed and back_ok and climbed and ahead == 0,
          "the host clock runs 30 days ahead for 10 minutes: the tick moves every open deadline with each leap, so nothing climbs "
          "during the jump, each deadline keeps its true time after it, the alert closes when the clock is back, and the wait "
          "climbs on time", "Y2")

    # A21: a real message of his, reused for an item it did not answer, is found by the pair check
    s = store()
    s.open(t, "tell:m-thanks", "tell", "main", "m-thanks", "reply to his note", "owner:chat", source="m-thanks")
    s.open(t + 1, "question:muxr/jg-8/discard", "question", "muxr", "jg-8", "discard the unlanded work of jg-8?", "lead:muxr", source="qd8")
    logs = owner_logs(s)
    s._host = t + 2
    s.con.execute("INSERT INTO move(at, verb, key, by, source, ends, why) VALUES(?,?,?,?,?,?,?)",
                  (t + 2, "close", "question:muxr/jg-8/discard", "owner:chat", "m-thanks", "done", "owner:chat:m-thanks pick=yes"))
    bad = s.stamp_check(t + 60, logs)
    check("A21", [p for _, _, p in bad] == [("m-thanks", "question:muxr/jg-8/discard")] and s.one("SELECT count(*) FROM item WHERE kind='security'") == 1,
          "a real message of his ('thanks') reused to close a discard question: its pair (message, item) is not in his log, so a security item opens", "X9 N9")

    # A22: adapter and tick stamps are checked too: a raw chat-adapter close of a reply with no sent record, and a
    # raw tick drop of a wait whose lane still works
    s = store()
    s.open(t, "work:muxr/jg-w", "work", "muxr", "jg-w", "build jg-w", "lead:muxr", source="dw", lane="worker:muxr/jg-w")
    s.open(t + 1, "wait:muxr/jg-w/q", "wait", "muxr", "jg-w", "which table?", "worker:muxr/jg-w", source="ww", named="main")
    s.open(t + 2, "tell:m5", "tell", "main", "m5", "reply to his note", "owner:chat", source="m5")
    logs = owner_logs(s)
    logs["adapter:chat"] = set()                                # the bridge's sent log holds no reply for m5
    s._host = t + 3
    s.con.execute("INSERT INTO move(at, verb, key, by, source, ends, why) VALUES(?,?,?,?,?,?,?)", (t + 3, "close", "tell:m5", "adapter:chat", "sent:fake", "done", "sent:fake"))
    s.con.execute("INSERT INTO move(at, verb, key, by, source, ends, why) VALUES(?,?,?,?,?,?,?)", (t + 3, "close", "wait:muxr/jg-w/q", "tick", "tk", "dropped", "subject gone: the lane closed"))
    s.con.execute("INSERT INTO move(at, verb, key, by, source, holder, holder_id, due_at, why) VALUES(?,?,?,?,?,?,?,?,?)",
                  (t + 3, "hand", "work:muxr/jg-w", "tick", "clock-leap:fake", "worker", "worker:muxr/jg-w", t + 1209000, "clock: a leap"))
    bad = s.stamp_check(t + 60, logs)
    s2 = store()                                                # and the true cases raise nothing
    s2.open(t, "work:muxr/jg-v", "work", "muxr", "jg-v", "build", "lead:muxr", source="dv", lane="worker:muxr/jg-v")
    s2.open(t + 1, "wait:muxr/jg-v/q", "wait", "muxr", "jg-v", "which?", "worker:muxr/jg-v", source="wv", named="main")
    s2.open(t + 2, "tell:m6", "tell", "main", "m6", "reply", "owner:chat", source="m6")
    s2.close(t + 3, "tell:m6", "done", "sent:telegram:6", "adapter:chat", source="sent:6")
    s2.close(t + 4, "work:muxr/jg-v", "done", "receipt:v", "adapter:status", source="stv")
    s2.close(t + 5, "wait:muxr/jg-v/q", "dropped", "subject gone: the lane closed", "tick", source="tkv")
    logs2 = owner_logs(s2); logs2["adapter:chat"] = {("sent:6", "tell:m6")}
    s2.open(t + 5, "steer:main/muxr/v2", "steer", "muxr", "jg-v", "rebase", "main", source="v2", named="lead")
    s2.tick(t + 5, steady=t + 5); s2.tick(t + 2000, steady=t + 5 + 60)          # and a true leap's tick hands pass
    check("A22", sorted(w for w, _, _ in bad) == ["drop", "hand", "move"] and s2.stamp_check(t + 2100, logs2) == []
          and s2.one("SELECT count(*) FROM move WHERE by='tick' AND verb='hand'") > 0,
          "a raw chat-adapter close with no sent record, a raw tick drop of a wait whose lane still works, and a raw tick hand "
          "that postpones a lane by two weeks with no clock leap each open a security item; true stamps raise none", "X3 X15")


def round3():
    """Two live misses of 18 Nov."""
    t = T0 + 40000
    # A23 (Y9): the lead parks its 17 ready items and the backlog-overdue alert rings again 59 times. Nothing reads the
    # log to learn what is open: a park is one hand on the item's row, a re-ring is one note on the one open alert.
    s = store()
    for i in range(400):                                    # history: closed lanes, each with status notes
        k = "dispatch:muxr/old%d" % i
        s.open(t, k, "dispatch", "muxr", "old%d" % i, "old ticket", "lead:muxr")
        for n in range(10):
            s.note(t, k, "lead:muxr", "status line %d" % n)
        s.close(t, k, "dropped", "done long ago", "lead:muxr")
    ready = ["dispatch:muxr/ready%d" % i for i in range(17)]
    for i, k in enumerate(ready):
        s.open(t + 1, k, "dispatch", "muxr", "ready%d" % i, "ready ticket", "lead:muxr")
    parked = [s.hand(t + 60, k, "outside", "outside", 7 * 86400, "parked until the owner's call", "lead:muxr") for k in ready]
    ak = Store.alert_key("backlog-overdue", "muxr", "muxr")
    rings = [s.open(t + 60 + 800 * i, ak, "alert", "muxr", "muxr", "ready work, nothing started", "adapter:alerts", source="bo:%d" % i, named="lead") for i in range(59)]
    pages = s.one("SELECT count(*) FROM move WHERE key=? AND page IS NOT NULL", (ak,))
    check("A23", parked == ["hand"] * 17 and s.one("SELECT count(*) FROM item WHERE kind='dispatch' AND state='open' AND holder='outside'") == 17
          and rings[0] == "open" and rings[1:] == ["note"] * 58 and s.one("SELECT count(*) FROM item WHERE key=?", (ak,)) == 1 and pages <= 1
          and s.one("SELECT max(seq) FROM move") > 4400,
          "on a log of 4,400 moves the lead parks its 17 ready items (17 hands, no read of the log) and the backlog-overdue "
          "alert raised 59 times in 13 hours is one item with 58 notes that paged the lead once (pages: %d)" % pages, "Y9 N7")

    # A24 (Y10): a red-CI blocker names the merge it holds back; the merge's done close closes it in the same write.
    s = store()
    s.open(t, "merge:muxr/rel-v10@821", "merge", "muxr", "rel-v10", "merge the release PR 821", "tick", source="pr821")
    b = s.open(t + 10, "red-ci:muxr/rel-v10", "blocker", "muxr", "rel-v10", "CI required red at 5110436: find the root cause",
               "adapter:ci", source="run:9001", named="lead", parent="merge:muxr/rel-v10@821")
    held = s.item("red-ci:muxr/rel-v10")
    s.close(t + 10080, "merge:muxr/rel-v10@821", "done", "merged: 5634169ef", "adapter:merge", source="merged:821")
    closed = s.con.execute("SELECT state, closed_at, closed_by, outcome FROM item WHERE key='red-ci:muxr/rel-v10'").fetchone()
    same = s.one("SELECT count(DISTINCT at) FROM move WHERE key IN ('merge:muxr/rel-v10@821','red-ci:muxr/rel-v10') AND verb='close'")
    late = s.open(t + 10100, "red-ci:muxr/rel-v10b", "blocker", "muxr", "rel-v10", "an older red run polled after the merge",
                  "adapter:ci", source="run:9000", named="lead", parent="merge:muxr/rel-v10@821")
    again = s.close(t + 10200, "merge:muxr/rel-v10@821", "done", "merged: 5634169ef", "adapter:merge", source="merged:821")
    logs = owner_logs(s); logs["adapter:merge"] = {("merged:821", "merge:muxr/rel-v10@821")}; logs["adapter:ci"] = {("run:9001", "red-ci:muxr/rel-v10")}
    stamp = s.stamp_check(t + 10300, logs)
    check("A24", b == "open" and held and held["holder"] == "lead" and closed[0] == "done" and closed[1] == t + 10080 and closed[2] == "adapter:merge"
          and closed[3].startswith("gone: its step merge:muxr/rel-v10@821 closed done: merged:") and same == 1 and late == "clear"
          and not s.item("red-ci:muxr/rel-v10b") and again == "again" and stamp == [],
          "a red-CI blocker names the merge it holds back; the merge's done close closes it done in the same write with the "
          "merge's proof; a red run polled after the merge files nothing ('clear'); the repeat of the merge writes nothing; "
          "the stamp check finds the cascade close true", "Y10 U7")

    # A25: the stamp check reads a cascade close by its cause, so wiring an adapter's log raises no false alarm, and a
    # forged cascade close whose step is not done is still found
    s = store()
    s.open(t, "work:muxr/jg-c", "work", "muxr", "jg-c", "build", "lead:muxr", source="dc", lane="worker:muxr/jg-c")
    s.open(t + 1, "stuck:muxr/jg-c", "alert", "muxr", "jg-c", "the worker stopped writing", "adapter:liveness", source="stc", named="lead")
    s.open(t + 2, "merge:muxr/jg-c@pr-c", "merge", "muxr", "jg-c", "merge jg-c", "tick", source="prc")
    s.open(t + 3, "red-ci:muxr/jg-c", "blocker", "muxr", "jg-c", "CI red", "adapter:ci", source="run:1", named="lead", parent="merge:muxr/jg-c@pr-c")
    s.close(t + 4, "work:muxr/jg-c", "done", "receipt:c", "adapter:status", source="st:c")
    logs = owner_logs(s); logs["adapter:status"] = {("st:c", "work:muxr/jg-c")}
    true_ = s.stamp_check(t + 60, logs)
    s._host = t + 61
    s.con.execute("INSERT INTO move(at, verb, key, by, ends, why) VALUES(?,?,?,?,?,?)",
                  (t + 61, "close", "red-ci:muxr/jg-c", "main", "done", "gone: its step merge:muxr/jg-c@pr-c closed done: merged: fake"))
    still = s.item("red-ci:muxr/jg-c")
    check("A25", true_ == [] and s.one("SELECT state FROM item WHERE key='stuck:muxr/jg-c'") == "dropped" and still is None
          and s.one("SELECT closed_by FROM item WHERE key='red-ci:muxr/jg-c'") == "main",
          "with the lane adapter's log wired, a lane's done close and its cascade drop of the lane's alert raise no security "
          "item; Main, ranked above the lead, may still close a blocker by hand", "Y10")


def round4():
    """Cases on a store a raw writer can reach."""
    t = T0 + 160000
    # A26: an owner-stamped next step counts as his only on the subject of the question he answered
    s = store()
    s.open(t, "question:muxr/jg-7/design", "question", "muxr", "jg-7", "pick a design for jg-7", "lead:muxr", source="qd", options="A|B")
    s.close(t + 2, "question:muxr/jg-7/design", "done", "owner:board:m1 pick=A", "owner:board", source="m1")
    raw(s, at=t + 2, verb="open", key="land:muxr/jg-9@h9", kind="land", home="muxr", subject="jg-9", project="muxr", parent="question:muxr/jg-7/design",
        by="owner:board", holder="tick", holder_id="tick", due_at=t + 600, why="land jg-9")      # loose: the leash lets it open
    s.open(t + 3, "question:release:muxr@pr43", "question", "muxr", "muxr@pr43", "release pr43?", "tick", source="qr1")
    s.close(t + 4, "question:release:muxr@pr43", "done", "owner:chat:m2 pick=yes", "owner:chat", source="m2",
            then=[dict(key="release:muxr@pr43", kind="release", home="muxr", subject="muxr@pr43", owes="release pr43 on his word")])
    logs = owner_logs(s)
    bad = s.stamp_check(t + 60, logs)
    check("A26", [(w, p) for w, _, p in bad] == [("move", (None, "land:muxr/jg-9@h9"))] and s.item("release:muxr@pr43"),
          "a raw owner-stamped landing of jg-9 that names his design pick on jg-7 as its parent is found by the stamp check; the release "
          "his yes opened in the same write, on that question's own subject, is not", "X9 U5")

    # A27: after the cut-over a new project has no row until his answer writes version 1
    s = store()                                          # the cut-over ran at T0 - 10 (muxr, crewhouse)
    cut_log = owner_logs(s)["owner:registry"]            # the cut-over run's own output, written once
    late = refused(lambda: s.set_policy(t, "newpj", "loose", "owner:registry", "forged:newpj", mode="local"))
    no_lane = refused(lambda: s.open(t + 1, "work:newpj/jg-n", "work", "newpj", "jg-n", "build", "lead:newpj", source="dn", lane="worker:newpj/jg-n", project="newpj"))
    s.open(t + 2, "intake:newpj/jg-n", "intake", "newpj", "jg-n", "a lane of newpj, which has no policy row", "adapter:status", source="in:jg-n")
    s.open(t + 3, "question:policy/newpj", "question", "main", "policy:newpj", "newpj has no policy: tight, standard or loose?", "main",
           source="qp", options="tight|standard|loose")
    s.close(t + 100, "question:policy/newpj", "done", "owner:chat:m9 pick=standard", "owner:chat", source="m9")
    v = s.set_policy(t + 100, "newpj", "standard", "owner:chat", "m9", mode="local")
    lane = s.open(t + 101, "work:newpj/jg-n", "work", "newpj", "jg-n", "build", "lead:newpj", source="dn2", lane="worker:newpj/jg-n", project="newpj")
    s._host = T0 - 10                                    # a writer that fakes its own clock to the cut-over's stamp
    s.con.execute("INSERT INTO policy VALUES('newpj2',1,'loose','local','machine','machine','machine',4,'main',NULL,NULL,NULL,NULL,?,'owner:registry','import:projects.md:newpj2')", (T0 - 10,))
    logs = owner_logs(s); logs["owner:registry"] = cut_log
    bad = s.stamp_check(t + 200, logs)
    check("A27", late and no_lane and v == 1 and lane == "open" and [(w, r) for w, r, _ in bad] == [("policy", "newpj2 v1")],
          "after the cut-over the registry writes no row under a source that is not the import's (a fill is the import's own source, jg-6sa2s); a new project's lane goes to intake; his answer to the policy question "
          "writes version 1 and the lane opens; a row forged at the cut-over's stamp is not in that run's output, so a security item opens", "U14")

    # A28: a raw trunk-adapter close of a landing is found within one tick, and the cleanup never reads it as landed
    s = store()
    s.open(t, "work:muxr/jg-5", "work", "muxr", "jg-5", "build", "lead:muxr", source="d5", lane="worker:muxr/jg-5")
    s.close(t + 10, "work:muxr/jg-5", "done", "receipt:h5", "adapter:status", source="st5",
            then=[dict(key="land:muxr/jg-5@h5", kind="land", home="muxr", subject="jg-5", owes="land h5"),
                  dict(key="cleanup:muxr/jg-5", kind="cleanup", home="muxr", subject="jg-5", owes="return the copy")])
    logs = owner_logs(s); logs["adapter:status"] = {("st5", "work:muxr/jg-5")}
    raw(s, at=t + 20, verb="close", key="land:muxr/jg-5@h5", by="adapter:trunk", source="tk-forged", ends="done", why="trunk:deadbeef")
    before = s.landed("jg-5")
    bad = s.stamp_check(t + 60, logs)
    after = s.landed("jg-5")
    s2 = store()                                         # the true landing: read as landed once the stamp check passed it
    s2.open(t, "land:muxr/jg-6@h6", "land", "muxr", "jg-6", "land h6", "tick", source="l6")
    s2.close(t + 20, "land:muxr/jg-6@h6", "done", "trunk:h6", "adapter:trunk", source="trunk:muxr@h6")
    ok2 = s2.landed("jg-6") is None and s2.stamp_check(t + 60, owner_logs(s2)) == [] and s2.landed("jg-6") == "h6"
    check("A28", before is None and [w for w, _, _ in bad] == ["move"] and after is None and s.item("cleanup:muxr/jg-5") and ok2,
          "a raw write of the trunk adapter's landing record is not in the trunk's own log: a security item opens within one tick, and "
          "the cleanup's landed check never reads it; a true landing reads as landed once the stamp check passed it", "Y6 A12 X13 hard-rule-3")

    # A29: writes made between a clock jump and the tick that sees it keep their own time limit
    s = store()
    s.tick(t, steady=t)
    J = 30 * 86400
    s._off[0] = J                                               # the writer reads the jumped clock and its frame
    s.open(t + J + 20, "steer:main/muxr/p1", "steer", "muxr", "jg-p1", "rebase", "main", source="p1", named="lead")    # true time t + 20
    s.tick(t + J + 60, steady=t + 60)
    s.tick(t + 700, steady=t + 700)
    fwd = s.item("steer:main/muxr/p1")["due_at"] - (t + 20)
    s.tick(t + 20 + 1800 + 60, steady=t + 20 + 1800 + 60)
    fwd_climbed = s.item("steer:main/muxr/p1")["holder"] == "main"
    s = store()
    s.tick(t, steady=t)
    s._off[0] = -J
    s.open(t - J + 20, "security:main/fleet/p1b", "security", "main", "fleet", "a token in a log", "main", source="p1b")
    s.tick(t - J + 60, steady=t + 60)
    s.tick(t - J + 120, steady=t + 120)
    back_held = s.item("security:main/fleet/p1b")["holder"]
    back_left = s.item("security:main/fleet/p1b")["due_at"] - (t - J + 20)
    check("A29", fwd == 1800 and fwd_climbed and back_held == "main" and back_left == 900,
          "a steer opened 40 s before the tick sees a +30-day jump keeps its 30 minutes in true time and climbs on time; a security item "
          "opened inside a -30-day jump keeps its 15 minutes and does not reach the owner after 100 s", "Y2")

    # A30: every deadline move carries its writer's frame, so a leap moves a deadline by exactly the clock change
    # since that move, however late the tick runs. The cases: jumps just over 300 s with the tick on
    # time, and jumps inside an hour the tick is down. An item opened after the jump is not moved and climbs on time in
    # true time; one opened before it moves by exactly the jump.
    def frames(J, down, oa, kind, limit):
        s = store()
        s.tick(t, steady=t)
        s.open(t + 10, "update:muxr/pre", "update", "muxr", "pre", "run the released tip", "main", source="pre")
        pre = s.item("update:muxr/pre")["due_at"]
        s._off[0] = J                                   # the host clock jumped; a writer after it reads the new frame
        key = "steer:main/muxr/post" if kind == "steer" else "security:main/fleet/post"
        if kind == "steer":
            s.open(t + oa + J, key, "steer", "muxr", "jg-post", "rebase", "main", source="post", named="lead")
        else:
            s.open(t + oa + J, key, "security", "main", "fleet", "a token in a log", "main", source="post")
        first = s.item(key)["holder"]
        s.tick(t + down + J, steady=t + down)           # the tick runs again only now
        kept = s.item(key)["due_at"] - (t + oa + J) == limit and not s.seen("clock-leap:%s@%d" % (key, t + down + J), key)
        moved = s.item("update:muxr/pre")["due_at"] == pre + J
        s.tick(t + oa + limit - 60 + J, steady=t + oa + limit - 60)
        before = s.item(key)["holder"]
        s.tick(t + oa + limit + 60 + J, steady=t + oa + limit + 60)
        after = s.item(key)["holder"]
        return kept and moved and before == first and after != first and s.item("clock:main/host") is not None
    cases = {"P1c back 330 s, tick on time": frames(-330, 60, 55, "security", 900),
             "P1d forward 30 min inside a 1-hour stop": frames(1800, 3600, 3000, "steer", 1800),
             "P1e forward 330 s, tick on time": frames(330, 60, 15, "steer", 1800),
             "P1f back 20 min inside a 25-minute stop": frames(-1200, 1500, 600, "steer", 1800)}
    check("A30", all(cases.values()),
          "each deadline move carries its writer's clock frame: after a jump of 330 s to 30 minutes, with the tick on time or down for up "
          "to an hour, an item opened after the jump keeps its limit and climbs within one tick of it in true time, and one opened before "
          "moves by exactly the jump (%s)" % ", ".join(k for k, v in cases.items() if not v) if not all(cases.values()) else
          "each deadline move carries its writer's clock frame: after a jump of 330 s to 30 minutes, with the tick on time or down for up "
          "to an hour, an item opened after the jump keeps its limit and climbs within one tick of it in true time, and one opened before "
          "moves by exactly the jump", "Y2")

    try:     # a refused write here (an older key rule) fails A31 and A32 rather than stopping the suite
        # A31: a standard project's release step and question are keyed by its release pull request: two landings
        # pushed into one release pull request ask him once, his one yes lets it out, and no release question stays open
        s = store()
        s.set_policy(t, "beta", "standard", "owner:chat", "tg:b31", mode="local-trunk")
        r1 = s.release_push(t + 10, "beta", "pr5", "h1", source="push:h1")
        r2 = s.release_push(t + 600, "beta", "pr5", "h2", source="push:h2")
        asked = s.one("SELECT count(*) FROM item WHERE kind='question' AND key LIKE 'question:release:beta@%'")
        s.close(t + 700, "question:release:beta@pr5", "done", "owner:chat:m31 pick=yes", "owner:chat", source="m31",
                then=[dict(key="release:beta@pr5", kind="release", home="beta", subject="beta@pr5", owes="release pull request pr5 on his word", project="beta")])
        out = s.release_out(t + 900, "beta", "pr5", "h2", source="merged:pr5")
        open_q = s.one("SELECT count(*) FROM item WHERE state='open' AND key LIKE 'question:release:beta@%'")
        r3 = s.release_push(t + 1000, "beta", "pr6", "h3", source="push:h3")
        # his yes is in, but nothing opened the step yet (a forged yes, or his adapter's write lost): the next push opens it
        s2 = store(); s2.set_policy(t, "beta", "standard", "owner:chat", "tg:b31b", mode="local-trunk")
        s2.release_push(t + 10, "beta", "pr8", "g1", source="push:g1")
        s2.close(t + 20, "question:release:beta@pr8", "done", "owner:chat:m33 pick=yes", "owner:chat", source="m33")
        r4 = s2.release_push(t + 30, "beta", "pr8", "g2", source="push:g2")
        again = s2.one("SELECT count(*) FROM item WHERE key='question:release:beta@pr8'")
        check("A31", (r1, r2, asked, out, open_q, r3, r4, again) == ("open", "note", 1, "done", 0, "open", "open", 1),
              "standard: two landings pushed into one release pull request ask him once (the second push is a note), his one yes lets "
              "that pull request out, no release question stays open after it, the next release pull request asks once again, and a push "
          "made after his yes opens the step and asks nothing", "Y10")

        # A32 (Y10 for a release): a red run holds back the release step; the fix is pushed into the same release pull
        # request, so the step stays one item at its new head, and the release going out closes the blocker in the same write
        s.close(t + 1100, "question:release:beta@pr6", "done", "owner:chat:m32 pick=yes", "owner:chat", source="m32",
                then=[dict(key="release:beta@pr6", kind="release", home="beta", subject="beta@pr6", owes="release pull request pr6 on his word", project="beta")])
        b = s.open(t + 1200, "red-ci:beta/release-pr6", "blocker", "beta", "beta@pr6", "CI required red at h3: find the root cause",
                   "adapter:ci", source="run:32", named="lead", parent="release:beta@pr6")
        fix = s.release_push(t + 2000, "beta", "pr6", "h4", source="push:h4")     # after his yes: he is asked again
        cov1 = s.covered_head("beta", "pr6")
        s.close(t + 2050, "question:release:beta@pr6", "done", "owner:chat:m32b pick=yes", "owner:chat", source="m32b",
                then=[dict(key="release:beta@pr6", kind="release", home="beta", subject="beta@pr6", owes="release pull request pr6 on his word", project="beta")])
        cov2 = s.covered_head("beta", "pr6")
        out2 = s.release_out(t + 2100, "beta", "pr6", "h4", source="merged:pr6")
        blk = s.con.execute("SELECT state, closed_at, outcome FROM item WHERE key='red-ci:beta/release-pr6'").fetchone()
        steps = s.one("SELECT count(*) FROM item WHERE key LIKE 'release:beta@%'")
        left = s.one("SELECT count(*) FROM item WHERE state='open' AND subject LIKE 'beta@%'")
        asks = s.one("SELECT count(*) FROM item WHERE key='question:release:beta@pr6'")
        check("A32", b == "open" and fix == "open" and cov1 == "h3" and cov2 == "h4" and asks == 2 and out2 == "done" and blk[0] == "done"
              and blk[1] == t + 2100 and blk[2].startswith("gone: its step release:beta@pr6 closed done") and steps == 2 and left == 0,
              "a red run on a release is a blocker naming its step; the fix pushed into the same release pull request after his yes asks "
              "him again (his first yes covered h3, not h4: a word covers its own commit and those under it), his second yes covers h4, "
              "and the release going out closes the blocker in the same write: nothing stays open", "Y10 A24 C1")
    except Refused as x:
        check("A31", False, "standard: one release question per release pull request (refused: %s)" % str(x)[:80], "Y10")
        check("A32", False, "a red run on a release closes when its release pull request goes out (not reached)", "Y10 A24")


# ------------------------------------------------------------------------------------------- R refusals
def refusals():
    s = store()
    t = T0
    s.open(t, "work:muxr/jg-1", "work", "muxr", "jg-1", "build", "lead:muxr", source="d1", lane="worker:muxr/jg-1")
    s.open(t, "wait:muxr/jg-1/k", "wait", "muxr", "jg-1", "pick a table", "worker:muxr/jg-1", source="w1", named="main")
    s.open(t, "question:muxr/jg-1/q", "question", "muxr", "jg-1", "keep or drop?", "lead:muxr", source="q1")
    s.open(t, "disk:muxr/muxr", "alert", "muxr", "muxr", "disk full", "adapter:disk", source="a1", named="lead")
    s.open(t, "steer:muxr/jg-1/7", "steer", "muxr", "jg-1", "rebase on main", "main", source="s7", named="worker", lane="worker:muxr/jg-1")
    s.open(t, "tell:n1", "tell", "main", "n1", "reply to his note", "owner:telegram", source="n1")
    s.open(t, "stuck:muxr/jg-1", "alert", "muxr", "jg-1", "the worker stopped writing", "adapter:liveness", source="st1", named="lead")
    s.open(t, "work:muxr/jg-2", "work", "muxr", "jg-2", "build", "lead:muxr", source="d2", lane="worker:muxr/jg-2")
    s.open(t, "done:muxr/x", "alert", "muxr", "x", "a fault", "adapter:disk", source="dx", named="lead")
    s.close(t, "done:muxr/x", "done", "gone: fixed", "adapter:disk", source="dxg")
    # a tight project: his design pick on jg-7 and his yes to merge pull request pr1 of jg-7
    s.set_policy(t, "tp4", "tight", "owner:chat", "tg:tp4", mode="direct-PR")
    s.open(t, "question:tp4/jg-7/design", "question", "tp4", "jg-7", "pick a design for jg-7", "lead:tp4", source="qd74", options="A|B")
    s.close(t, "question:tp4/jg-7/design", "done", "owner:board:m74 pick=A", "owner:board", source="m74")
    s.open(t, "question:merge:tp4/jg-7@pr1", "question", "tp4", "jg-7", "merge jg-7 (pull request pr1)?", "tick", source="qm75")
    s.close(t, "question:merge:tp4/jg-7@pr1", "done", "owner:chat:m75 pick=yes", "owner:chat", source="m75")
    s.open(t, "merge:tp4/jg-7@pr1", "merge", "tp4", "jg-7", "merge pull request pr1", "tick", source="mg75", project="tp4")
    s.open(t, "land:muxr/jg-5@h5", "land", "muxr", "jg-5", "land h5", "tick", source="l82")
    s.open(t, "cleanup:muxr/jg-5", "cleanup", "muxr", "jg-5", "return the copy", "tick", source="c84")
    cases = [
        ("R1", "X12 U6 U2", "an open with no holder id", lambda: raw(s, at=t, verb="open", key="wait:x", kind="wait", home="muxr", subject="jg-1", by="worker:muxr/jg-1", holder="lead", holder_id="", due_at=t + 60, why="x")),
        ("R2", "A4 U10", "an open with no deadline", lambda: raw(s, at=t, verb="open", key="wait:y", kind="wait", home="muxr", subject="jg-1", by="w", holder="lead", holder_id="lead:muxr", why="x")),
        ("R3", "A6", "an open that owes nothing", lambda: raw(s, at=t, verb="open", key="question:z", kind="question", home="muxr", subject="jg-1", by="lead:muxr", holder="owner", holder_id="owner", due_at=t + 60, why="")),
        ("R4", "A9 A10 A11 N8", "a second open of a cause already open", lambda: raw(s, at=t, verb="open", key="disk:muxr/muxr", kind="alert", home="muxr", subject="muxr", by="adapter:disk", holder="lead", holder_id="lead:muxr", due_at=t + 60, why="again")),
        ("R5", "A4", "a deadline past the kind's limit", lambda: raw(s, at=t, verb="open", key="wait:w2", kind="wait", home="muxr", subject="jg-1", by="w", holder="main", holder_id="main", due_at=t + 86400, why="x")),
        ("R6", "X1", "a keyless done closes another item (the wait is not the lane's work)", lambda: s.close(t + 9, "wait:muxr/jg-1/k", "done", "receipt:abc", "worker:muxr/jg-1")),
        ("R7", "X2", "a pause does not replace a key: a second open on the same key is refused", lambda: raw(s, at=t, verb="open", key="wait:muxr/jg-1/k", kind="wait", home="muxr", subject="jg-1", by="worker:muxr/jg-1", holder="outside", holder_id="outside", due_at=t + 600, why="paused")),
        ("R8", "X3", "a writer below the holder closes it", lambda: s.close(t + 9, "wait:muxr/jg-1/k", "done", "answer:x", "worker:muxr/other")),
        ("R9", "X6", "a resolve with no proof", lambda: s.close(t + 9, "disk:muxr/muxr", "done", "resolved", "adapter:disk")),
        ("R10", "X7 X15 X8 U11", "a steer closed with something other than its handled proof", lambda: s.close(t + 9, "steer:muxr/jg-1/7", "done", "turn-end note", "worker:muxr/jg-1")),
        ("R11", "X9 U5 N9 A8", "a lead closes an owner question done", lambda: s.close(t + 9, "question:muxr/jg-1/q", "done", "owner:board pick=yes", "lead:muxr")),
        ("R12", "X9 U5", "Main closes an owner question done by quoting him", lambda: s.close(t + 9, "question:muxr/jg-1/q", "done", "owner:quoted by Main pick=yes", "main")),
        ("R13", "N9", "Main drops an owner question", lambda: s.close(t + 9, "question:muxr/jg-1/q", "dropped", "not needed", "main")),
        ("R14", "X9", "a landing while an owner question on the ticket is open", lambda: s.open(t + 9, "land:muxr/jg-1@h1", "land", "muxr", "jg-1", "land", "tick")),
        ("R15", "X17 U14 U9", "a standing rule not on the owner's own message", lambda: s.open(t, "rule:bypass", "rule", "main", "bin/jg-proof-bypass.sh", "bypass proofs", "main", source="r1")),
        ("R16", "X4", "a climb before the deadline (an ack can not reset the clock either: no ack move exists)", lambda: raw(s, at=t + 9, verb="climb", key="disk:muxr/muxr", by="tick", holder="main", holder_id="main", due_at=t + 9 + 3600, why="x")),
        ("R17", "X3", "someone other than the tick climbs", lambda: raw(s, at=t + 99999, verb="climb", key="disk:muxr/muxr", by="main", holder="main", holder_id="main", due_at=t + 99999 + 3600, why="x")),
        ("R18", "A5", "a climb that skips a rung", lambda: raw(s, at=t + 99999, verb="climb", key="disk:muxr/muxr", by="tick", holder="owner", holder_id="owner", due_at=t + 99999 + 86400, why="x")),
        ("R19", "N1", "an owner's note closed with no sent proof", lambda: s.close(t + 9, "tell:n1", "done", "read", "main")),
        ("R20", "X18 U8", "an item is erased", lambda: s.con.execute("DELETE FROM item WHERE key='tell:n1'")),
        ("R21", "X18 N6", "a move is erased or changed", lambda: s.con.execute("UPDATE move SET why='x' WHERE seq=1")),
        ("R22", "U1 N3", "a park with no date (a hand needs a deadline in the next 14 days)", lambda: raw(s, at=t, verb="hand", key="work:muxr/jg-1", by="lead:muxr", holder="lead", holder_id="lead:muxr", why="parked")),
        ("R23", "U1", "a park longer than 14 days", lambda: s.hand(t, "work:muxr/jg-1", "lead", "lead:muxr", 30 * 86400, "parked", "lead:muxr")),
        ("R24", "A6 U4", "a hand with no reason", lambda: raw(s, at=t, verb="hand", key="work:muxr/jg-1", by="lead:muxr", holder="lead", holder_id="lead:muxr", due_at=t + 60, why="")),
        ("R25", "X5 A9", "a second live lane for one ticket", lambda: raw(s, at=t, verb="open", key="work:muxr/jg-1", kind="work", home="muxr", subject="jg-1", by="lead:muxr", holder="worker", holder_id="w2", due_at=t + 60, why="again")),
        ("R26", "K1", "a release opened while its owner question is open", lambda: s.open(t, "release:muxr@x", "release", "muxr", "jg-1", "release", "tick")),
        ("R27", "-", "a close with no reason", lambda: s.close(t, "work:muxr/jg-1", "dropped", "", "main")),
        ("R28", "X13 A12", "a closed item changes", lambda: (s.close(t + 1, "disk:muxr/muxr", "done", "gone:recheck 1", "adapter:disk"),
                                                             s.con.execute("UPDATE item SET state='open', closed_at=NULL WHERE key='disk:muxr/muxr'"))),
        ("R29", "U12 X10", "an item written around the move log", lambda: s.con.execute("UPDATE item SET holder='owner' WHERE key='work:muxr/jg-1'")),
        ("R30", "-", "a rule changed at run time", lambda: s.con.execute("UPDATE kind SET ceiling='owner' WHERE kind='work'")),
        ("R31", "N7", "a cursor moved back", lambda: (s.con.execute("INSERT INTO cursor VALUES('main', 50)"), s.con.execute("UPDATE cursor SET seq=10 WHERE reader='main'"))),
        ("R32", "A5", "a wait handed to the owner by hand (only owner-only kinds reach him)", lambda: s.hand(t, "wait:muxr/jg-1/k", "owner", "owner", 3600, "he decides", "main")),
        ("R34", "I1-I11", "the same outside record applied twice", lambda: (raw(s, at=t, verb="note", key="work:muxr/jg-1", by="w", source="dup-1", why="x"),
                                                                          raw(s, at=t, verb="note", key="work:muxr/jg-1", by="w", source="dup-1", why="x"))),
        ("R35", "X18", "the move log is erased", lambda: s.con.execute("DELETE FROM move WHERE seq=1")),
        ("R36", "U12 X10", "an item inserted around the move log", lambda: s.con.execute("INSERT INTO item(key,gen,kind,home,subject,state,holder,holder_id,owes,due_at,opened_at,opened_by) VALUES('x',1,'work','muxr','jg-9','open','worker','w','x',1,1,'w')")),
        ("R37", "lost item", "a note on a cause with no open item (the arrival would have no holder)", lambda: raw(s, at=t, verb="note", key="wait:nobody", by="w", why="x")),
        ("R38", "X2", "a note that changes the holder", lambda: raw(s, at=t, verb="note", key="work:muxr/jg-1", by="w", holder="outside", why="x")),
        ("R33", "-", "a machine-only close done by a person", lambda: (s.open(t, "merge:muxr/jg-9@pr7", "merge", "muxr", "jg-9", "merge PR 7", "tick"),
                                                                       s.close(t + 5, "merge:muxr/jg-9@pr7", "done", "merged:pr/7", "main"))),
        ("R45", "", "a move stamped 30 days ahead of the host clock (one bad stamp would push its deadline out by 30 days)", lambda: (setattr(s, "_host", t), s.con.execute("INSERT INTO move(at, verb, key, by, why) VALUES(?,?,?,?,?)", (t + 30 * 86400, "note", "work:muxr/jg-1", "w", "stamp ahead")))),
        ("R46", "Y5 jg-kile-s3", "a lane's stuck alert dropped as if its lane closed while the lane's work is open", lambda: raw(s, at=t + 9, verb="close", key="stuck:muxr/jg-1", by="worker:muxr/jg-1", ends="dropped", why="subject gone: its lane closed done")),
        ("R47", "Y5 jg-kile-s3", "an alert keyed per steer, not per subject and cause", lambda: raw(s, at=t + 9, verb="open", key="stuck-steer:muxr/jg-1/steer-7", kind="alert", home="muxr", subject="jg-1", by="adapter:liveness", holder="lead", holder_id="lead:muxr", due_at=t + 600, why="steer 7 unread")),
        ("R48", "X9 X15 U5", "a writer running as Main stamps an owner close (jg item takes no by)", lambda: s.as_("main").close(t + 9, "question:muxr/jg-1/q", "done", "owner:board pick=yes", "owner:board")),
        ("R49", "", "a lead of another home closes this home's work done", lambda: s.close(t + 9, "work:muxr/jg-1", "done", "receipt:x", "lead:crewhouse")),
        ("R50", "N1", "Main closes its own reply duty with a sent proof (only the chat adapter's sent record closes it)", lambda: s.close(t + 9, "tell:n1", "done", "sent:i replied", "main")),
        ("R51", "N9", "the tick drops an owner question as subject gone", lambda: s.close(t + 9, "question:muxr/jg-1/q", "dropped", "subject gone: the ticket closed", "tick")),
        ("R52", "", "a worker opens a merge", lambda: raw(s, at=t + 9, verb="open", key="merge:muxr/jg-8@pr8", kind="merge", home="muxr", subject="jg-8", project="muxr", by="worker:muxr/jg-1", holder="tick", holder_id="tick", due_at=t + 600, why="merge")),
        ("R53", "", "a lead opens a landing", lambda: raw(s, at=t + 9, verb="open", key="land:muxr/jg-8@h8", kind="land", home="muxr", subject="jg-8", project="muxr", by="lead:muxr", holder="tick", holder_id="tick", due_at=t + 600, why="land")),
        ("R54", "", "a lead writes in another home", lambda: raw(s, at=t + 9, verb="open", key="wait:muxr/x", kind="wait", home="muxr", subject="jg-1", by="lead:crewhouse", holder="main", holder_id="main", due_at=t + 600, why="x")),
        ("R56", "X18 U14", "a policy version that skips a number", lambda: s.con.execute("INSERT INTO policy(project,version,level,mode,merge,land,release,lanes,trunk,set_at,set_by,source) VALUES('muxr',9,'loose','local','machine','machine','machine',8,'main',?,'owner:chat','tg:skip')", (t,))),
        ("R57", "-", "an open of an unknown kind", lambda: raw(s, at=t, verb="open", key="bogus:x", kind="bogus", home="muxr", subject="jg-1", by="main", holder="main", holder_id="main", due_at=t + 60, why="x")),
        ("R58", "X12", "an open with an empty subject", lambda: raw(s, at=t, verb="open", key="wait:muxr/e", kind="wait", home="muxr", subject="", by="main", holder="main", holder_id="main", due_at=t + 60, why="x")),
        ("R59", "N2 K1", "a lane's work that names no project (no lane limit or leash could apply)", lambda: raw(s, at=t, verb="open", key="work:muxr/jg-np", kind="work", home="muxr", subject="jg-np", by="lead:muxr", holder="worker", holder_id="worker:muxr/jg-np", due_at=t + 600, why="build")),
        ("R60", "X18", "a hand on a key with no open item (a dangling move the fold could not place)", lambda: raw(s, at=t + 9, verb="hand", key="done:muxr/x", by="main", holder="lead", holder_id="lead:muxr", due_at=t + 600, why="again")),
        ("R61", "X18", "a climb of a closed item", lambda: raw(s, at=t + 99999, verb="climb", key="done:muxr/x", by="tick", holder="main", holder_id="main", due_at=t + 99999 + 3600, why="x")),
        ("R62", "X5 U12", "one lane's worker hands another lane's work away", lambda: s.hand(t + 9, "work:muxr/jg-1", "lead", "lead:muxr", 600, "not mine", "worker:muxr/jg-2")),
        ("R63", "A4 X4", "a climb that sets a 30-day deadline instead of the rung's limit", lambda: raw(s, at=t + 99999, verb="climb", key="stuck:muxr/jg-1", by="tick", holder="main", holder_id="main", due_at=t + 99999 + 30 * 86400, why="x")),
        ("R66", "Y6", "a landing closed done with a proof that names no commit", lambda: (s.open(t, "land:muxr/jg-2@h2", "land", "muxr", "jg-2", "land", "tick"),
                                                                        s.close(t + 5, "land:muxr/jg-2@h2", "done", "trunk: ", "adapter:trunk"))),
        ("R67", "", "a second registry import writes version 2 (a later version is his answer to a policy question)", lambda: s.set_policy(t + 9, "muxr", "tight", "owner:registry", "seed2:muxr", mode="local")),
        ("R68", "", "an owner question that offers no picks", lambda: raw(s, at=t, verb="open", key="question:muxr/np", kind="question", home="muxr", subject="jg-1", by="lead:muxr", holder="owner", holder_id="owner", due_at=t + 600, why="pick?")),
        ("R69", "X9", "his answer names a pick he was not offered", lambda: s.close(t + 9, "question:muxr/jg-1/q", "done", "owner:board:m9 pick=maybe", "owner:board", source="m9")),
        ("R70", "", "a worker's own done close opens the landing in the same write (it would skip the leash's opener rule)", lambda: s.close(t + 9, "work:muxr/jg-1", "done", "receipt:w1", "worker:muxr/jg-1", source="w70",
              then=[dict(key="land:muxr/jg-1w@w1", kind="land", home="muxr", subject="jg-1", owes="land w1")])),
        ("R72", "Y10", "a blocker that names no open step (nothing its clearing could close it by)", lambda: s.open(t, "red-ci:muxr/none", "blocker", "muxr", "jg-bl0", "CI red", "adapter:ci", source="rc0", named="lead")),
        ("R73", "Y10", "a worker of another lane closes a blocker done saying its step is done while the step is still open", lambda: (
            s.open(t, "merge:muxr/jg-bl@pr-bl", "merge", "muxr", "jg-bl", "merge jg-bl", "tick", source="mjb"),
            s.open(t, "red-ci:muxr/jg-bl", "blocker", "muxr", "jg-bl", "CI red", "adapter:ci", source="rc1", named="lead", parent="merge:muxr/jg-bl@pr-bl"),
            raw(s, at=t + 1, verb="close", key="red-ci:muxr/jg-bl", by="worker:muxr/jg-1", ends="done", why="gone: its step merge:muxr/jg-bl@pr-bl closed done: merged: x"))),
        ("R71", "N2", "a lane's work on a project with no policy row (no lane limit or review base could apply)", lambda: s.open(t, "work:nopol/jg-x", "work", "nopol", "jg-x", "build", "lead:nopol", source="np", lane="worker:nopol/jg-x", project="nopol")),
        ("R65", "X13 A12", "a second close of an item already closed", lambda: s.close(t + 9, "done:muxr/x", "dropped", "again", "main")),
        ("R64", "A5", "an owner question held by Main from the start", lambda: raw(s, at=t, verb="open", key="question:muxr/hm", kind="question", home="muxr", subject="jg-1", by="lead:muxr", holder="main", holder_id="main", due_at=t + 600, why="pick?")),
        ("R39", "U9 X17 U14", "a project policy written by Main, not on the owner's own message", lambda: s.set_policy(t, "pockit", "loose", "main", "m1")),
        ("R40", "X18 U14", "a policy version edited in place", lambda: s.con.execute("UPDATE policy SET land='owner' WHERE project='muxr'")),
        ("R41", "X18", "a policy version erased", lambda: s.con.execute("DELETE FROM policy WHERE project='muxr'")),
        ("R42", "K1 SR1", "a landing by the tick on a tight project with no word of his", lambda: (s.set_policy(t, "pockit", "tight", "owner:chat", "tg:900"),
                                                                       s.open(t, "land:pockit/jg-a1@a1", "land", "pockit", "jg-a1", "land a1", "tick", project="pockit"))),
        ("R55", "K1", "a release by the tick on a standard project with no word of his", lambda: (s.set_policy(t, "stdp", "standard", "owner:chat", "tg:902"),
                                                                       s.open(t, "release:stdp@pr1", "release", "stdp", "stdp@pr1", "release a1", "tick", project="stdp"))),
        ("R43", "K1", "a landing that names no project, even on his own word (no policy can apply)", lambda: raw(s, at=t, verb="open", key="land:x/jg-9@h9", kind="land", home="x", subject="jg-9", by="owner:chat", holder="tick", holder_id="tick", due_at=t + 60, why="land")),
        ("R44", "N2", "a lane past the project's lane limit (opened after the policy took effect)", lambda: (s.set_policy(t, "herdr", "standard", "owner:chat", "tg:901", lanes=1),
                                                    s.open(t + 1, "work:herdr/jg-a", "work", "herdr", "jg-a", "build", "lead:herdr", lane="worker:herdr/jg-a", project="herdr"),
                                                    s.open(t + 1, "work:herdr/jg-b", "work", "herdr", "jg-b", "build", "lead:herdr", lane="worker:herdr/jg-b", project="herdr"))),
    ]
    cases += [
        ("R74", "X9 U5", "a raw owner-stamped merge of another ticket on a tight project, riding on his design pick (no writer skips the leash)",
         lambda: raw(s, at=t, verb="open", key="merge:tp4/jg-9@pr9", kind="merge", home="tp4", subject="jg-9", project="tp4", parent="question:tp4/jg-7/design",
                     by="owner:board", holder="tick", holder_id="tick", due_at=t + 600, why="merge jg-9")),
        ("R75", "U4 hard-rule-2", "a second pull request of a ticket merged on his yes to the first",
         lambda: s.open(t + 5 * 86400, "merge:tp4/jg-7@pr2", "merge", "tp4", "jg-7", "merge a follow-up pull request pr2", "main", source="mg76", project="tp4")),
        ("R76", "", "a merge whose key names no pull request (his yes could not name what it lets through)",
         lambda: s.open(t, "merge:muxr/jg-5", "merge", "muxr", "jg-5", "merge jg-5", "tick", source="mg77")),
        ("R77", "", "a lead opens a step question (any text could ride on it)",
         lambda: s.open(t, "question:merge:tp4/jg-8@pr8", "question", "tp4", "jg-8", "is the new colour right? pr8", "lead:tp4", source="q77")),
        ("R78", "", "Main opens a step question whose text does not name the pull request",
         lambda: s.open(t, "question:merge:tp4/jg-8@pr8", "question", "tp4", "jg-8", "is the new colour right?", "main", source="q78")),
        ("R79", "U14", "the registry writes a new project's first policy version 10 days after the cut-over, under a source that is not the import's",
         lambda: s.set_policy(t + 10 * 86400, "newpj", "loose", "owner:registry", "forged:newpj", mode="local")),
        ("R80", "X18", "a policy version stamped 10 days from the host clock",
         lambda: (setattr(s, "_host", t), s.con.execute("INSERT INTO policy(project,version,level,mode,merge,land,release,lanes,trunk,set_at,set_by,source) "
                                                       "VALUES('newpj2',1,'loose','local','machine','machine','machine',4,'main',?,'owner:chat','tg:80')", (t + 10 * 86400,)))),
        ("R82", "X13 A12 Y6", "the tick closes a landing done (only the trunk adapter, from its own record)",
         lambda: s.close(t + 1, "land:muxr/jg-5@h5", "done", "trunk:deadbeef", "tick", source="tk82")),
        ("R84", "hard-rule-3", "the tick closes a cleanup done (it closes done only an alert it opened)",
         lambda: s.close(t + 1, "cleanup:muxr/jg-5", "done", "cleaned:muxr/jg-5", "tick", source="tk84")),
        ("R85", "residual-b", "Main opens a merge whose key does not start with merge: (a lead's question on it would escape the step-question clause)",
         lambda: s.open(t, "pr:muxr/jg-8@pr8", "merge", "muxr", "jg-8", "merge jg-8 pr8", "main", source="mg85")),
    ]
    for cid, tags, what, fn in cases:
        try:
            fn()
            e = None
        except (sqlite3.Error, Refused) as x:
            e = " ".join(str(x).split())
        check(cid, e is not None, "refused: %s%s" % (what, (" (%s)" % e[:70]) if e else ""), tags)
    return cases


def refusal_case_runner():
    """Re-run every refusal case on a fresh store; return the ids that were NOT refused (used by the mutants)."""
    import io, contextlib
    global RES, FAILS
    keep = (RES, FAILS)
    RES, FAILS = [], []
    with contextlib.redirect_stdout(io.StringIO()):
        refusals()
    out = [r["id"] for r in RES if not r["ok"]]
    RES, FAILS = keep
    return out


# ------------------------------------------------------------------------------------------- I idempotency: each action twice
class Outside:
    """Fake outside world: a trunk, a forge, a chat, a pool of copies. Counts every effect."""
    def __init__(self):
        self.trunk, self.merged, self.sent, self.released, self.slots, self.spawned = set(), set(), [], set(), {"s1": "jg-1"}, []


def idempotency():
    def act(name, fn, s, o):
        a = fn(s, o)
        snap1 = (list(s.con.execute("SELECT * FROM item ORDER BY id")), s.one("SELECT count(*) FROM move"), json.dumps(o.__dict__, default=sorted, sort_keys=True))
        b = fn(s, o)
        snap2 = (list(s.con.execute("SELECT * FROM item ORDER BY id")), s.one("SELECT count(*) FROM move"), json.dumps(o.__dict__, default=sorted, sort_keys=True))
        return a, b, snap1 == snap2

    t = T0
    def intake(s, o):          # an owner note arrives (key: the note id)
        return s.open(t, "tell:note-77", "tell", "main", "note-77", "reply to his note", "owner:telegram", source="note:note-77")

    def wake(s, o):            # Main handles its pages: reads from its cursor, acts on the item's current state, moves the cursor
        cur = s.one("SELECT seq FROM cursor WHERE reader='main'") or 0
        pages = s.con.execute("SELECT seq, key FROM move WHERE page='main' AND seq>? ORDER BY seq", (cur,)).fetchall()
        for seq, key in pages:
            it = s.item(key)
            if it and it["kind"] == "tell":
                if not any(x[0] == key for x in o.sent):
                    o.sent.append((key, "reply"))
                s.close(t + 5, key, "done", "sent:telegram:%d" % len(o.sent), "adapter:chat", source="sent:" + key)
        if pages:
            s.con.execute("INSERT INTO cursor VALUES('main', ?) ON CONFLICT(reader) DO UPDATE SET seq=excluded.seq", (pages[-1][0],))
        return len(pages)

    def spawn(s, o):           # key: the ticket; a second spawn finds the live lane and starts nothing
        if s.item("work:muxr/jg-5"):
            return "already live"
        o.spawned.append("jg-5")
        return s.open(t, "work:muxr/jg-5", "work", "muxr", "jg-5", "build jg-5", "lead:muxr", source="spawn:muxr/jg-5", lane="worker:muxr/jg-5")

    def steer(s, o):           # key: inbox/seq
        return s.open(t, "steer:muxr/jg-5/3", "steer", "muxr", "jg-5", "rebase", "main", source="steer:muxr/jg-5/3", named="worker", lane="worker:muxr/jg-5")

    def review(s, o):          # a review the lane waits for: key wait:<lane>/review
        return s.open(t, "wait:muxr/jg-5/review", "wait", "muxr", "jg-5", "review the diff", "worker:muxr/jg-5", source="st:review-1", named="lead")

    def merge(s, o):           # key: the PR; the forge is asked only when the PR is not merged yet
        k = "merge:muxr/jg-6@pr9"
        if not s.item(k) and not s.one("SELECT 1 FROM item WHERE key=?", (k,)):
            s.open(t, k, "merge", "muxr", "jg-6", "merge PR 9", "tick", source="ready:pr/9")
        if "pr/9" not in o.merged:
            o.merged.add("pr/9")
        return s.close(t + 9, k, "done", "merged:pr/9@sha9", "adapter:merge", source="merged:pr/9") if s.item(k) else "again"

    def landing(s, o):         # key: task@sha; the trunk already holding the sha is a no-op
        k = "land:muxr/jg-7@sha7"
        if not s.one("SELECT 1 FROM item WHERE key=?", (k,)):
            s.open(t, k, "land", "muxr", "jg-7", "land sha7", "tick", source="ready:jg-7@sha7")
        o.trunk.add("sha7")
        return s.close(t + 9, k, "done", "trunk:sha7", "adapter:trunk", source="trunk:muxr@sha7") if s.item(k) else "again"

    def release(s, o):         # key: project@release pull request
        if not s.one("SELECT 1 FROM item WHERE key='release:muxr@pr7'"):
            s.open(t, "release:muxr@pr7", "release", "muxr", "jg-7", "release sha7", "tick", source="tip:muxr@sha7")
        o.released.add("muxr@sha7")
        return s.close(t + 9, "release:muxr@pr7", "done", "released:pr7 at sha7", "adapter:trunk", source="released:muxr@sha7") if s.item("release:muxr@pr7") else "again"

    def cleanup(s, o):         # key: the lane; a slot already free is not freed twice
        if not s.one("SELECT 1 FROM item WHERE key='cleanup:muxr/jg-1'"):
            s.open(t, "cleanup:muxr/jg-1", "cleanup", "muxr", "jg-1", "return the copy", "tick", source="done:jg-1")
        o.slots.pop("s1", None)
        return s.close(t + 9, "cleanup:muxr/jg-1", "done", "cleaned:s1", "adapter:teardown", source="cleaned:muxr/jg-1") if s.item("cleanup:muxr/jg-1") else "again"

    def owner_message(s, o):   # key: the item and its page move; the bridge sends only when no sent record exists
        if not s.one("SELECT 1 FROM item WHERE key='question:muxr/jg-8'"):
            s.open(t, "question:muxr/jg-8", "question", "muxr", "jg-8", "keep or drop jg-8?", "lead:muxr", source="ask:jg-8")
        seq = s.one("SELECT seq FROM move WHERE key='question:muxr/jg-8' AND page='owner'")
        if s.seen("sent:%d" % seq):
            return "again"
        o.sent.append(("question:muxr/jg-8", "card"))
        return s.note(t + 1, "question:muxr/jg-8", "adapter:chat", "card sent: telegram 1300 [ref question:muxr/jg-8]", source="sent:%d" % seq)

    def tick(s, o):            # key: item@deadline
        return len(s.tick(t + 86400 * 2))

    actions = [("D1", "intake", intake), ("D2", "wake handling", wake), ("D3", "spawn", spawn), ("D4", "steer", steer),
               ("D5", "review", review), ("D6", "merge", merge), ("D7", "landing", landing), ("D8", "release", release),
               ("D9", "cleanup", cleanup), ("D10", "message to the owner", owner_message), ("D11", "tick", tick)]
    s, o = store(), Outside()
    rows = []
    for cid, name, fn in actions:
        a, b, same = act(name, fn, s, o)
        rows.append((name, a, b))
        check(cid, same, "%s twice: first %r, second %r, store and outside world unchanged by the second" % (name, a, b))
    check("D12", (len(o.sent), len(o.merged), len(o.trunk), len(o.released), len(o.spawned)) == (2, 1, 1, 1, 1),
          "outside effects exactly once each: 2 messages (one reply, one card), 1 merge, 1 landing, 1 release, 1 spawn")
    # the honest limit: a crash between the send and its record sends twice; the message carries its ref so it is seen as one
    s2, o2 = store(), Outside()
    s2.open(t, "question:x", "question", "muxr", "jg-x", "pick?", "lead:muxr", source="ask:x")
    o2.sent.append(("question:x", "card"))            # sent, then the bridge died before recording it
    seq = s2.one("SELECT seq FROM move WHERE key='question:x' AND page='owner'")
    if not s2.seen("sent:%d" % seq):
        o2.sent.append(("question:x", "card"))        # the retry sends again
        s2.note(t + 1, "question:x", "adapter:chat", "card sent [ref question:x]", source="sent:%d" % seq)
    check("D13", len(o2.sent) == 2 and s2.one("SELECT count(*) FROM move WHERE source LIKE 'sent:%'") == 1,
          "stated limit: a crash between a chat send and its record sends the owner one duplicate, tagged with the same ref; the store records one")
    return rows


# ------------------------------------------------------------------------------------------- M mutants
def suite_runner():
    """Run journeys and refusals quietly on the current schema; return the ids that fail (or the crash)."""
    import io, contextlib
    global RES, FAILS
    keep = (RES, FAILS)
    RES, FAILS = [], []
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                journeys()
            except Exception as e:
                FAILS.append("journeys crashed: " + str(e)[:60])
            refusals()
        return list(FAILS)
    finally:
        RES, FAILS = keep


def mutants():
    sql = open(SCHEMA, encoding="utf-8").read()
    parts = re.findall(r"CREATE (?:UNIQUE )?(TRIGGER|INDEX) (\w+)", sql)
    base = suite_runner()
    killed, alive = [], []
    for typ, name in parts:
        if name in ("move_key", "move_page", "item_due", "item_subject", "item_parent"):
            continue    # read-speed indexes: no rule rests on them
        end = "END;" if typ == "TRIGGER" else ";"
        m = re.sub(r"CREATE (?:UNIQUE )?%s %s\b.*?%s" % (typ, name, re.escape(end)), "", sql, count=1, flags=re.S)
        sqlite3.connect(":memory:").executescript(m)    # the mutant schema must load
        path = os.path.join(TMP, "schema-mut-%s.sql" % name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(m)
        import store as item_store
        old = item_store.SCHEMA
        item_store.Store.__init__.__defaults__ = (":memory:", path, None, False)
        try:
            now_pass = [c for c in suite_runner() if c not in base]
        except Exception as e:
            now_pass = ["crash:" + str(e)[:40]]
        finally:
            item_store.Store.__init__.__defaults__ = (":memory:", old, None, False)
            os.unlink(path)
        (killed if now_pass else alive).append((name, now_pass))
    for name, cs in killed:
        check("M-" + name, True, "without %s these refusals pass: %s" % (name, ",".join(cs[:6])))
    for name, cs in alive:
        check("M-" + name, False, "without %s no refusal case changes: the part is not needed, or a case is missing" % name)
    return killed, alive


# ------------------------------------------------------------------------------------------- F fold and tamper
def fold_and_tamper():
    s = journeys_quiet()
    h1 = hashlib.sha256("\n".join(r[0] or "" for r in s.con.execute("SELECT sql FROM sqlite_master ORDER BY name")).encode()).hexdigest()
    s.con.execute("DROP TRIGGER item_update_via_move")
    s.con.execute("UPDATE item SET holder='owner', holder_id='owner' WHERE key='update:takeone@abc123'")
    h2 = hashlib.sha256("\n".join(r[0] or "" for r in s.con.execute("SELECT sql FROM sqlite_master ORDER BY name")).encode()).hexdigest()
    bad = s.fold_check()
    at = s.one("SELECT max(at) FROM move") + 60
    found = [k for k, _ in s.audit(at, fold=True)]
    check("F1", h1 != h2 and bad and found == ["schema:main/fleet", "fold:main/fleet"] and s.item("schema:main/fleet") and s.item("fold:main/fleet"),
          "a dropped trigger changes the schema hash and the write it let through differs from the fold: the tick's audit opens one alert on Main for each: %s" % bad[:1])


def journeys_quiet():
    import io, contextlib
    global RES, FAILS
    keep = (RES, FAILS)
    RES, FAILS = [], []
    with contextlib.redirect_stdout(io.StringIO()):
        s = journeys()
    RES, FAILS = keep
    return s


if __name__ == "__main__":
    journeys()
    reads()
    round2()
    round3()
    round4()
    refusals()
    rows = idempotency()
    killed, alive = mutants()
    fold_and_tamper()
    # F2 (synthesis): the tick itself runs the re-check, at its first run and then every 15 minutes, so a write around the
    # log is found within 15 minutes with no one calling the audit by hand (the fold check must run from the tick)
    s = store()
    s.open(T0, "steer:muxr/f2", "steer", "muxr", "f2", "read this", "main", named="lead")
    s.tick(T0 + 60)
    first = s.item(FOLD_ALERT_KEY) is None
    s.con.execute("DROP TRIGGER item_update_via_move")
    s.con.execute("UPDATE item SET holder='owner', holder_id='owner' WHERE key='steer:muxr/f2'")
    s.tick(T0 + 120)
    s.tick(T0 + 60 + 900)
    check("F2", first and s.item(FOLD_ALERT_KEY) is not None,
          "the tick runs the re-check at its first run and every 15 minutes: an item written around the log is found within 15 minutes")
    out = {"cases": len(RES), "pass": sum(r["ok"] for r in RES), "fail": FAILS, "results": RES, "idempotency": rows,
           "mutants_killed": [k for k, _ in killed], "mutants_alive": [k for k, _ in alive]}
    json.dump(out, open(os.path.join(TMP, "prove.json"), "w"), indent=1, default=str)
    print("\n%d cases: %d PASS, %d FAIL; mutants killed %d of %d" % (len(RES), out["pass"], len(FAILS), len(killed), len(killed) + len(alive)))
    sys.exit(1 if FAILS else 0)
