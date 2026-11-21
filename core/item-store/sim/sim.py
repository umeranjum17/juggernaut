#!/usr/bin/env python3
"""Deterministic simulation of the item store: one seed = one fleet day on a fake clock, scripted workers, leads, Main and
owner (no model calls), seeded faults, and the invariants checked after every step.

  sim.py --seeds 0-99 [--hours 24] [--no-faults] [--out PATH] [--rates]

Arrivals follow profile-14-17nov.json (the 14-17 Nov fleet window): the dispatch, note and security actors draw their next
arrival from the kind's per_day (an exponential gap of mean 86400/per_day); every other kind has a top-up stream at its
per_day that opens an item only while the kind's opens run behind the profile (the lanes' own opens count), so each kind
lands at the profile's rate. --rates prints each kind's simulated rate against the profile's on stderr and exits 1 on any `off`.

Everything runs in one thread from one heap of timed events; every choice draws from random.Random(seed), so a seed
replays exactly (the run prints a digest of its whole move log). The store is a real SQLite file in a temporary
folder (two writers need two connections); it is deleted after each seed.

Faults: worker crash, lost message, doubled message, slow notification, red check, quota stop, restart mid-move,
two writers, host clock jump (forward or back by 1, 7 or 30 days, for 10 to 60 minutes), a write inside a jump's window
(after the clock moves, before the tick sees it), forged owner stamp, forged trunk-adapter landing, and a late tick: the
tick stops for 15 to 60 minutes while the host clock is stepped by 5.5 to 60 minutes, either way.
Releases follow the store's one asking rule: the trunk adapter pushes each landing into the project's one open
release pull request (store.release_push); a machine-release project lets it out at once; otherwise the tick asks him
once per release pull request, he answers that one question, a red run on it is a blocker naming the step, and the fix
is pushed into the same pull request.
Invariants (after every step): I2 the items are the fold of the move log; I3 no arrival lost (every outside record
older than one reconcile has its move or a refusal item); I4 a doubled arrival changes nothing; I5 a forbidden write
is refused; I6 every open item has a holder and a deadline; I7 nothing reaches the owner that a lower rung could
settle; I8 after each tick, the clock alert is open exactly when the host clock is off (a leap not yet undone);
I9 after each tick, no open item is past its deadline by the host clock without a climb or a late mark (liveness);
I10 a forged owner or adapter stamp has its security item within one tick; I11 after each tick, no open item still
waiting on its deadline (not yet marked late) rests it on a move stamped more than 300 s ahead of the host clock (a jump
forward then back cannot park an item for days); I12 after each tick, in true time, no climb came more than one tick
sooner, and no open item is waiting more than two ticks past (counted from when a stopped tick runs again), than the
interval its last deadline move gave it (a clock
leap's own hand is not such a move: it only carries the item's time into the new frame; a move's true time is its stamp
minus its frame's offset); I13 after every step, no project has two open release questions, and no release question
stays open once its release pull request went out; I14 after each tick, once Main's watcher has been stopped for 52
minutes (the beat's 15 minutes, one 5-minute supervision check, one 15-minute reconcile of a lost open, the item's 15
minutes, two ticks; when the late-tick fault stopped every check of the host too, 33 minutes after they restart), the
owner holds an open Main-down item (checked after every step that ran, so a tick that never runs fails it). Two homes run the tick (Main's and a Squad Lead's, 30 s
apart) behind the store's tick lease; the watcher-stop fault stops Main's for 30 to 120 minutes, the Squad Lead home's
tick goes on alone, and its supervision check opens Main-down when Main's beat is 15 minutes old and closes it when
the beat is back. (I1, the count, could fail only
when I2 fails; the old I8, "time never runs back in the log", went with the writer clamp.) The checks are I2 to I14 in
this file; the proof suite's run-twice cases are D1 to D13.

The store file is written in a temporary folder and deleted after each seed."""
import argparse, hashlib, heapq, json, os, random, re, sqlite3, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
from store import Store, Refused

T0 = 1794614400
SCRATCH = TMP
with open(os.path.join(_HERE, "profile-14-17nov.json")) as _f:
    RATE = {k: v["per_day"] for k, v in json.load(_f)["kinds"].items()}     # the profile's arrivals per day, by kind
# top-up streams: kind -> (what the item owes, who writes it); a question names what only the owner decides
KIND_OF = {"dispatch": "work", "owner_note": "tell", "security": "security"}   # the actors that draw their own arrivals: actor -> kind
SETTLE = {"alert": ("gone:fixed", None), "cleanup": ("cleaned:slot", "adapter:teardown"), "dispatch": ("lane:sim", None),
          "intake": ("filed:sim", None), "land": ("trunk:sim", "adapter:trunk"), "main-down": ("back:sim", "adapter:supervision"),
          "merge": ("merged:sim", "adapter:merge"), "release": ("released:sim", "adapter:trunk"), "report": ("acted:sim", None),
          "steer": ("handled:sim", None), "update": ("home-at:sim", None)}   # kind -> the proof its done close names, and the adapter that closes it
TOPUP = {"alert": ("a check went red", "adapter:ci"), "cleanup": ("return the copy", "adapter:teardown"),
         "dispatch": ("start a lane", "lead:"), "intake": ("record an outside note", "adapter:intake"),
         "land": ("land the commit", "tick"), "main-down": ("Main's watcher beat is old", "adapter:supervision"),
         "merge": ("merge the pull request", "tick"), "question": ("design pick: which table", "tick"),
         "release": ("release the pull request", "tick"), "report": ("report the finding", "lead:"),
         "steer": ("steer a lane", "lead:"),
         "update": ("update a lane", "lead:"), "wait": ("pick a table", "lead:")}
OWNER_KINDS = ("question", "security", "main-down")
OWNER_ONLY = ("design pick", "credential", "spend", "destructive act", "release word", "merge word", "land word")
STRETCH = 4 * 3                 # the profile's release rate is the fleet's (3 projects), and a day starts cold: its first release pull request opens at once
LANES = 3                       # lanes per project, in the seed policy
PROJECTS = {"alpha": "loose", "beta": "standard", "gamma": "tight"}
FAULTS = ("crash", "lost", "double", "slow", "red", "quota", "restart", "two-writers", "clock-jump", "window-write", "forged-owner", "forged-adapter",
          "late-tick", "watcher-stop")
CHANNEL = re.compile(r"owner:[a-z-]+|adapter:(?:trunk|merge|chat|supervision)")   # the writers whose own log the stamp check reads


class Violation(Exception):
    pass


SKIP = object()     # what a tick returns when it did not run (stopped, or another home holds the lease)


class Sim:
    def __init__(self, seed, hours, faults):
        self.seed, self.r, self.faults = seed, random.Random(seed), faults
        self.t, self.end = T0, T0 + hours * 3600
        os.makedirs(SCRATCH, exist_ok=True)
        self.path = os.path.join(SCRATCH, "sim-%d.db" % seed)
        for x in (self.path, self.path + "-journal"):
            if os.path.exists(x):
                os.unlink(x)
        self.s = Store(self.path)
        self.s.con.execute("PRAGMA synchronous=OFF")      # scratch file: the sim checks logic, not disk durability
        self.heap, self.n = [], 0
        self.outside = []                    # every arrival, as the outside world keeps it (status line, chat message, CI result)
        self.host_off = 0                    # the host clock's error (clock-jump fault): every writer and the tick read it
        self.forged, self.last_tick = {}, None  # forged owner stamps (source -> time) for I10; the last tick's time
        self.last_top, self.changed_at = 0, -1  # the log top at the last tick; the true time the host clock last moved
        self.pending = {}                    # arrivals not yet seen in the log (checked by I3 until they are)
        self.stats = {f: 0 for f in FAULTS}
        self.stats.update(steps=0, arrivals=0, refusals=0, owner_items=0, lanes=0, clock_resets=0, early_climbs=0, early_climbs_to_owner=0,
                          window_moves=0, true_time_climbs=0, worst_late_s=0, release_pushes=0, release_questions=0, releases=0,
                          main_down_to_owner=0)
        self.lk = {}                         # lane -> its land key (land:<home>/<ticket>@<head>)
        self.rel_pr, self.rel_n = {}, {}     # project -> its open release pull request; how many it has opened
        self.tick_down = (0, 0)              # the late-tick fault: the tick does not run in [from, to)
        self.watch_down = (0, 0)             # the watcher-stop fault: Main's watcher (its tick and its beat) stops in [from, to)
        self.beat = T0                       # the last time Main's watcher ran
        self.r2 = random.Random(seed * 7919 + 17)   # the watcher-stop fault's own draws: the other faults' draws are unchanged
        self.logs = {}                       # each owner channel's and closing adapter's own log: (record id, item key) pairs
        for i, (pj, lvl) in enumerate(sorted(PROJECTS.items())):
            self.s.set_policy(T0 - 10, pj, lvl, "owner:chat", "seed-policy:%s" % pj, lanes=LANES)
            self.logs.setdefault("owner:chat", set()).add(("seed-policy:%s" % pj, "policy:" + pj))
        self.lane_no = 0
        self.counts, self.counted = {}, 0    # opens per kind (read from the log), and the log seq counted up to
        self.topup_n = 0
        self.queued, self.retry = 0, False   # tickets waiting for a free lane
        self.clock_first = True
        self.r4 = random.Random(seed * 15485863 + 11)   # the clock faults' own draws: the workload's draws do not decide which seeds jump the clock
        self.r3 = random.Random(seed * 104729 + 5)   # the top-up streams' own draws: the actors' draws are not shifted by them

    # ------------------------------------------------------------------ the event loop
    def at(self, t, fn, *a):
        self.n += 1
        heapq.heappush(self.heap, (t, self.n, fn, a))

    def chance(self, p, fault=None, rng=None):
        hit = (rng or self.r).random() < p
        if hit and fault:
            if not self.faults:
                return False
            self.stats[fault] += 1
        return hit

    def gap(self, kind, rng=None):
        """The next arrival of a kind: exponential, mean 86400 / the profile's per_day, from this seed's own generator."""
        return max(1, int((rng or self.r).expovariate(RATE[kind] / 86400)))

    def opens(self, kind):
        """How many items of a kind were opened so far, from the log (every actor, the lanes' next steps and the store's own opens)."""
        for k, n in self.s.con.execute("SELECT kind, count(*) FROM move WHERE verb='open' AND seq>? GROUP BY kind", (self.counted,)):
            self.counts[k] = self.counts.get(k, 0) + n
        self.counted = self.s.one("SELECT max(seq) FROM move") or 0
        return self.counts.get(kind, 0)

    def behind(self, kind):
        return self.opens(kind) < RATE[kind] * (self.t - T0) / 86400 - 0.5    # the running count, rounded

    def topup(self, kind):
        """A kind's stream at the profile's rate: it opens an item only while the kind's opens run behind the profile."""
        if self.behind(kind):
            owes, by = TOPUP[kind]
            pj = self.r3.choice([p for p in sorted(PROJECTS) if kind not in ("land", "merge", "release") or self.s.one("SELECT %s FROM v_policy WHERE project=?" % kind, (p,)) != "owner"])
            self.topup_n += 1
            key = "%s:%s/sim%d%s" % (kind, pj, self.topup_n, "@sim%d" % self.topup_n if kind in ("land", "merge", "release") else "")
            self.arrive("topup:" + key, pj, self.s.open, key, kind, pj, "sim%d" % self.topup_n, owes, by + (pj if by.endswith(":") else ""),
                        named="lead")
            if kind != "question":                            # a question waits for him; the rest are settled by whoever owns them
                self.at(self.t + self.r3.randint(60, 3600), self.settle, key, kind, pj)
        self.at(self.t + max(1, self.gap(kind, self.r3) // 3), self.topup, kind)   # polls at 3x the rate: a clipped cluster is made up

    def settle(self, key, kind, pj):
        """A top-up item is closed with the proof its kind names, by the adapter that owns it or by its holder."""
        it = self.s.item(key)
        if it:
            proof, by = SETTLE.get(kind, ("answer:sim", None))
            self.arrive("settled:" + key, pj, self.s.close, key, "done", proof, by or it["holder_id"])

    def now(self):
        """The host clock (maybe jumped): every writer stamps it, and the tick reads it."""
        return self.t + self.host_off

    # ------------------------------------------------------------------ arrivals: recorded outside first, then written
    def arrive(self, source, home, fn, *a, **kw):
        """An arrival is kept outside first (a status line, a chat message, a CI result), then written by the adapter.
        A lost message skips the write; a doubled one writes twice; the reconcile re-applies anything not in the log."""
        self.outside.append((self.t, source, home, fn, a, kw))
        self.pending[source] = self.t
        ch = [x for x in a if isinstance(x, str) and CHANNEL.fullmatch(x)]
        if ch:                                # his message, or the adapter's own record: its (id, item) pair is in that channel's log
            self.logs.setdefault(ch[0], set()).add((source, a[0]))
        self.stats["arrivals"] += 1
        if self.chance(0.02, "lost"):
            return None
        r = self.apply(source, home, fn, a, kw)
        if self.chance(0.03, "double"):
            before = self.snapshot()
            self.apply(source, home, fn, a, kw)
            if self.snapshot() != before:
                raise Violation("I4 a doubled arrival changed the store: %s" % source)
        if self.chance(0.01, "two-writers"):     # a second adapter, on its own connection, raced to write the same record
            other = Store(self.path, attach=True)
            before = self.snapshot()
            try:
                self.apply(source, home, fn, a, kw, store=other)
            finally:
                other.con.close()
            if self.snapshot() != before:
                raise Violation("I4 a second writer changed the store: %s" % source)
        return r

    def apply(self, source, home, fn, a, kw, store=None):
        s = store or self.s
        s._off[0] = self.host_off                # the writer reads the host clock and its frame
        bound = getattr(s, fn.__name__)
        try:
            return bound(self.now(), *a, source=source, **kw)
        except Refused as e:
            if "UNIQUE constraint failed: move.source" in str(e):
                return "again"                   # the other writer won the race: the same record, written once
            self.stats["refusals"] += 1
            try:                                 # a refused arrival is itself recorded: an intake item to Main
                s.open(self.now(), "intake:" + source, "intake", home, source, "refused arrival: " + str(e)[:120], "adapter:intake",
                       source="refused:" + source)
            except Refused:
                pass
            return None

    def reconcile(self):
        """Every 15 minutes: re-apply, in their first order, the outside records the log has not seen (lost messages)."""
        for (t, source, home, fn, a, kw) in self.outside:
            if not self.s.seen(source) and not self.s.seen("refused:" + source):
                self.apply(source, home, fn, a, kw)
        self.at(self.t + 900, self.reconcile)

    # ------------------------------------------------------------------ actors (scripted, no model calls)
    def dispatch(self):
        """A ticket arrives at the profile's rate and waits in a queue for a project with a free lane, as a lead's would."""
        self.queued += 1
        self.at(self.t + self.gap("work"), self.dispatch)
        self.start_lane()

    def start_lane(self):
        free = [p for p in sorted(PROJECTS) if self.s.one("SELECT count(*) FROM item WHERE kind='work' AND state='open' AND project=?", (p,)) < LANES]
        if not self.queued or not free:
            if self.queued and not self.retry:
                self.retry = True
                self.at(self.t + 300, self.retry_lane)
            return
        self.queued -= 1
        pj = self.r.choice(free)
        self.lane_no += 1
        key = "%s/jg-%d" % (pj, self.lane_no)
        r = self.arrive("dispatch:" + key, pj, self.s.open, "work:" + key, "work", pj, key, "build " + key, "lead:" + pj,
                        lane="worker:" + key, project=pj)
        if r == "open" or self.s.item("work:" + key):
            self.stats["lanes"] += 1
            self.at(self.t + self.r.randint(600, 3600), self.worker_step, key, pj, 0)
        self.start_lane()

    def retry_lane(self):
        self.retry = False
        self.start_lane()

    def worker_step(self, key, pj, n):
        if not self.s.item("work:" + key):
            return
        wid = "worker:" + key
        if self.chance(0.04, "crash"):          # the worker stops writing; the liveness adapter opens a stuck alert later
            self.at(self.t + 1800, self.liveness, key, pj)
            return
        if n >= 3 or self.r.random() < 0.3:
            then = [dict(key="cleanup:" + key, kind="cleanup", home=pj, subject=key, owes="return the copy")]
            head = "h%d" % self.t                # the proved head the done-done receipt names
            self.lk[key] = lk = "land:%s@%s" % (key, head)
            lq = "question:" + lk
            if self.s.one("SELECT land FROM v_policy WHERE project=?", (pj,)) == "owner":
                self.arrive("ask:" + lq, pj, self.s.open, lq, "question", pj, key, "land word: land %s at %s?" % (key, head), "tick")
            else:
                then.append(dict(key=lk, kind="land", home=pj, subject=key, project=pj, owes="land %s at %s" % (key, head)))
            # the worker writes its done line; the lane adapter reads it and closes the work with the next steps
            self.arrive("done:" + key, pj, self.s.close, "work:" + key, "done", "receipt:%s" % key, "adapter:status", then=then)
            self.at(self.t + 120, self.land, key, pj)
            self.at(self.t + 300, self.cleanup, key, pj)
            if self.s.item(lq):
                self.stats["owner_items"] += 1
                self.at(self.t + self.r.randint(1800, 20000), self.owner_answers, lq, key, pj)
            return
        w = self.r.random()
        if self.chance(0.08, "quota"):
            self.arrive("quota:%s/%d" % (key, n), pj, self.s.open, "wait:%s/quota" % key, "wait", pj, key, "quota stop until reset", wid,
                        named="outside", due=7200)
            self.at(self.t + 7200 + self.r.randint(0, 900), self.quota_back, key, pj, n)
            return
        if w < 0.4:
            named = self.r.choice(("lead", "main"))
            wk = "wait:%s/%d" % (key, n)
            self.arrive("wait:%s/%d" % (key, n), pj, self.s.open, wk, "wait", pj, key, "pick a table", wid, named=named)
            self.page(named, wk, pj)
        else:
            self.arrive("note:%s/%d" % (key, n), pj, self.s.note, "work:" + key, wid, "progress %d" % n)
        if self.chance(0.05, "red"):
            self.arrive("ci-red:%s/%d" % (key, n), pj, self.s.open, "red:%s/%s" % (pj, pj), "alert", pj, pj, "the line is red", "adapter:ci", named="lead")
            self.page("lead", "red:%s/%s" % (pj, pj), pj, fix=0.7)
        self.at(self.t + self.r.randint(900, 5400), self.worker_step, key, pj, n + 1)

    def quota_back(self, key, pj, n):
        if self.s.item("wait:%s/quota" % key):
            self.arrive("quota-back:%s/%d" % (key, n), pj, self.s.close, "wait:%s/quota" % key, "done", "answer:quota reset", "adapter:quota")
        self.at(self.t + 60, self.worker_step, key, pj, n + 1)

    def liveness(self, key, pj):
        if self.s.item("work:" + key):
            self.arrive("stuck:%s@%d" % (key, self.t), pj, self.s.open, "stuck:%s/%s" % (pj, key), "alert", pj, key, "the worker stopped writing",
                        "adapter:liveness", named="lead")
            self.at(self.t + self.r.randint(300, 9000), self.relaunch, key, pj)

    def relaunch(self, key, pj):
        if self.s.item("stuck:%s/%s" % (pj, key)):
            by = self.s.item("stuck:%s/%s" % (pj, key))["holder_id"]      # the alert may have climbed past the lead: its holder closes it
            self.arrive("relaunch:%s@%d" % (key, self.t), pj, self.s.close, "stuck:%s/%s" % (pj, key), "done", "gone: relaunched, it writes again", by)
            self.at(self.t + 600, self.worker_step, key, pj, 1)

    def page(self, holder, ik, pj, fix=1.0):
        """The holder reads its page after a delay (slow notification: up to 3 hours) and closes the item, or never does."""
        delay = self.r.randint(60, 1800)
        if self.chance(0.1, "slow"):
            delay = self.r.randint(3600, 10800)
        if self.r.random() < fix:
            self.at(self.t + delay, self.answer, ik, holder, pj)

    def answer(self, ik, holder, pj):
        it = self.s.item(ik)
        if it:
            by = it["holder_id"] if it["holder"] in ("lead", "main") else ("main" if holder == "main" else "lead:" + pj)
            proof = "gone:fixed" if it["kind"] == "alert" else "answer:%s" % holder
            self.arrive("answer:%s@%d" % (ik, self.t), pj, self.s.close, ik, "done", proof, by)

    def land(self, key, pj):
        lk = self.lk.get(key)
        if lk and self.s.item(lk):
            self.arrive("trunk:" + key, pj, self.s.close, lk, "done", "trunk:%s" % lk.split("@")[1], "adapter:trunk")
            self.push(pj, lk.split("@")[1])

    def push(self, pj, head):
        """The trunk adapter pushes the landed head into the project's one open release pull request, opening the next one
        when none is open; the store asks once per release pull request."""
        fresh = pj not in self.rel_pr
        if fresh:
            self.rel_n[pj] = self.rel_n.get(pj, 0) + 1
            self.rel_pr[pj] = "pr%d" % self.rel_n[pj]
        pr = self.rel_pr[pj]
        self.stats["release_pushes"] += 1
        qk = "question:release:%s@%s" % (pj, pr)
        asked = self.s.item(qk) is not None
        self.arrive("push:%s:%s" % (pj, head), pj, self.s.release_push, pj, pr, head)
        if self.s.one("SELECT release FROM v_policy WHERE project=?", (pj,)) == "machine":
            self.at(self.t + self.gap("release", self.r3) * STRETCH, self.release_merged, pj, pr, head)   # it batches its interval's landings
        elif fresh or (not asked and self.s.item(qk)):   # a first ask, or a push after his yes that asks again (C1)
            self.stats["owner_items"] += 1
            self.stats["release_questions"] += 1
            self.at(self.t + self.r.randint(1800, 30000) * STRETCH, self.owner_release, pj, pr, head)

    def owner_release(self, pj, pr, head):
        """He answers the one release question of this pull request; his adapter opens the step in the same write."""
        qk, step = "question:release:%s@%s" % (pj, pr), "release:%s@%s" % (pj, pr)
        if self.s.item(qk):
            self.arrive("owner-msg:" + qk, pj, self.s.close, qk, "done", "owner:chat:%d pick=yes" % self.t, "owner:chat",
                        then=[dict(key=step, kind="release", home=pj, subject="%s@%s" % (pj, pr), owes="release pull request %s on his word" % pr, project=pj)])
        elif not self.s.one("SELECT 1 FROM item WHERE key=?", (qk,)):
            self.at(self.t + 600, self.owner_release, pj, pr, head)          # its ask is not in the log yet (a lost arrival)
            return
        elif not self.s.one("SELECT 1 FROM item WHERE key=?", (step,)):     # closed already (a forged yes): the tick opens the step on it
            self.arrive("rel-open:" + step, pj, self.s.open, step, "release", pj, "%s@%s" % (pj, pr), "release pull request %s" % pr, "tick", project=pj)
        if self.s.one("SELECT count(*) FROM item WHERE key=?", (qk,)) > 1:   # a second answer (a re-ask): the merge is already scheduled
            return
        if self.chance(0.15, "red"):                  # CI on the release pull request is red: a blocker naming the step
            self.at(self.t + 300, self.release_red, pj, pr)
        else:
            self.at(self.t + self.r.randint(300, 1800), self.release_merged, pj, pr, head)

    def release_red(self, pj, pr):
        step = "release:%s@%s" % (pj, pr)
        if self.s.item(step):
            self.arrive("red-run:%s:%s@%d" % (pj, pr, self.t), pj, self.s.open, "red-ci:%s/release-%s" % (pj, pr), "blocker", pj, "%s@%s" % (pj, pr),
                        "CI required red on release pull request %s: find the root cause" % pr, "adapter:ci", named="lead", parent=step)
        self.at(self.t + self.r.randint(1800, 5400), self.release_fix, pj, pr)

    def release_fix(self, pj, pr):
        """The fix lands and is pushed into the same release pull request: the step stays one item at its new head."""
        head = "fix%d" % self.t
        self.stats["release_pushes"] += 1
        self.arrive("push:%s:%s" % (pj, head), pj, self.s.release_push, pj, pr, head)
        self.at(self.t + 600, self.release_merged, pj, pr, head)

    def release_merged(self, pj, pr, head):
        step = "release:%s@%s" % (pj, pr)
        if self.s.item("question:" + step):          # asked again after his yes: the trunk adapter waits for his word (C1)
            self.at(self.t + 600, self.release_merged, pj, pr, head)
            return
        if self.s.item(step) or not self.s.one("SELECT 1 FROM item WHERE key=?", (step,)):
            self.arrive("merged:%s:%s" % (pj, pr), pj, self.s.close, step, "done", "released:%s at %s" % (pr, head), "adapter:trunk")
            self.stats["releases"] += 1
        if self.rel_pr.get(pj) == pr:
            del self.rel_pr[pj]

    def owner_answers(self, qk, subject, pj):
        if self.s.item(qk):
            self.arrive("owner-msg:" + qk, pj, self.s.close, qk, "done", "owner:chat:%d pick=yes" % self.t, "owner:chat")
        if qk.startswith("question:land:"):
            lk = qk[len("question:"):]
            key = lk[len("land:"):].split("@")[0]
            self.arrive("land-open:" + key, pj, self.s.open, lk, "land", pj, key, "land on his word", "tick", project=pj)
            self.at(self.t + 60, self.land, key, pj)

    def cleanup(self, key, pj):
        if self.s.item("cleanup:" + key):
            self.arrive("cleaned:" + key, pj, self.s.close, "cleanup:" + key, "done", "cleaned:slot", "adapter:teardown")

    def owner_note(self):
        nid = "note-%d" % self.t
        self.arrive("note:" + nid, "main", self.s.open, "tell:" + nid, "tell", "main", nid, "reply to his note", "owner:chat")
        self.at(self.t + self.r.randint(10, 600) * (12 if self.chance(0.1, "slow") else 1), self.reply, nid)
        self.at(self.t + self.gap("tell"), self.owner_note)

    def reply(self, nid):
        if self.s.item("tell:" + nid):
            self.arrive("sent:" + nid, "main", self.s.close, "tell:" + nid, "done", "sent:chat:%d" % self.t, "adapter:chat")

    def security(self):
        k = "security:fleet/%d" % self.t
        if self.behind("security"):       # the store's own security items (a forged stamp) count toward the profile's rate
            self.arrive("sec:%d" % self.t, "main", self.s.open, k, "security", "main", "fleet", "a key in a worker's environment", "adapter:security")
            if self.r.random() < 0.6:
                self.at(self.t + self.r.randint(60, 1200), self.contain, k)
        self.at(self.t + self.gap("security"), self.security)

    def contain(self, k):
        if self.s.item(k):
            self.arrive("contained:" + k, "main", self.s.close, k, "done", "contained:key rotated", "adapter:security")

    def restart_mid_move(self):
        """A writer dies inside a transaction: the first row is written, the connection drops before the commit."""
        if self.chance(0.5, "restart"):
            c = sqlite3.connect(self.path, isolation_level=None)
            c.execute("BEGIN")
            try:
                c.execute("INSERT INTO move(at, verb, key, kind, home, subject, by, source, holder, holder_id, due_at, why) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                          (self.now(), "open", "tell:crash-%d" % self.t, "tell", "main", "crash", "owner:chat", "crash:%d" % self.t, "main", "main",
                           self.now() + 600, "half-written"))
            except sqlite3.Error:
                pass
            c.close()                           # no commit: the half-written move must not exist
            if self.s.seen("crash:%d" % self.t):
                raise Violation("restart mid-move left a half-written move in the log")
        self.at(self.t + self.r.randint(3600, 20000), self.restart_mid_move)

    def clock_jump(self):
        first, self.clock_first = self.clock_first, False      # every seed jumps the host clock at least once (the clock mutant needs it)
        if self.host_off == 0 and self.chance(1.0 if first else 0.5, "clock-jump", self.r4):
            self.host_off = self.r4.choice((-1, 1)) * self.r4.choice((1, 7, 30)) * 86400
            self.changed_at = self.t
            self.at(self.t + self.r4.randint(1, 50), self.window_write)
            self.at(self.t + self.r4.randint(600, 3600), self.clock_back)
        elif self.host_off == 0 and self.chance(0.4, "late-tick", self.r4):   # the tick stops, and the clock is stepped while it is down
            stop = self.r4.randint(900, 3600)
            self.tick_down = (self.t, self.t + stop)
            self.at(self.t + self.r4.randint(60, stop - 300), self.small_jump, self.r4.choice((-1, 1)) * self.r4.randint(330, 3600))
        self.at(self.t + self.r4.randint(20000, 40000), self.clock_jump)

    def small_jump(self, j):
        self.host_off = j
        self.changed_at = self.t
        self.at(self.t + self.r.randint(1, 50), self.window_write)
        self.at(self.tick_down[1] + self.r.randint(600, 3600), self.clock_back)

    def clock_back(self):
        self.host_off = 0
        self.changed_at = self.t
        self.at(self.t + self.r.randint(1, 50), self.window_write)

    def window_write(self):
        """A write right after the host clock moved: often before the tick that sees the leap."""
        if self.chance(0.8, "window-write"):
            wk = "wait:main/clock-%d" % self.t
            self.arrive("window:%d" % self.t, "main", self.s.open, wk, "wait", "main", "clock-%d" % self.t, "pick a table", "main", named="lead")
            self.page("main", wk, "main")

    def rogue(self):
        """I5: a careless script tries a forbidden write; the store must refuse it."""
        tries = [lambda: self.s.con.execute("UPDATE item SET holder='owner' WHERE state='open'"),
                 lambda: self.s.con.execute("DELETE FROM move WHERE seq=(SELECT min(seq) FROM move)"),
                 lambda: self.s.con.execute("UPDATE policy SET release='machine'"),
                 lambda: self.s.close(self.now(), self.r.choice([k for (k,) in self.s.con.execute("SELECT key FROM item WHERE state='open' AND kind='question'")] or ["question:none"]),
                                      "done", "owner:quoted", "main")]
        lands = [k for (k,) in self.s.con.execute("SELECT key FROM item WHERE state='open' AND kind='land'")]
        if lands and self.chance(0.2, "forged-adapter"):   # a script forges the trunk adapter's landing record: the stamp check must find it
            src = "forged-land:%d" % self.t
            self.s._host = self.now()
            self.s.con.execute("INSERT INTO move(at, verb, key, by, source, ends, why) VALUES(?,?,?,?,?,?,?)",
                               (self.now(), "close", self.r.choice(lands), "adapter:trunk", src, "done", "trunk:deadbeef"))
            self.forged[src] = self.t
            self.at(self.t + self.r.randint(1800, 7200), self.rogue)
            return
        if self.chance(0.3, "forged-owner"):     # a script forges an owner stamp in a raw write: the store accepts it; the owner check must find it
            qs = [k for (k,) in self.s.con.execute("SELECT key FROM item WHERE state='open' AND kind='question'")]
            if qs:
                src = "forged:%d" % self.t
                self.s._host = self.now()
                self.s.con.execute("INSERT INTO move(at, verb, key, by, source, ends, why) VALUES(?,?,?,?,?,?,?)",
                                   (self.now(), "close", self.r.choice(qs), "owner:chat", src, "done", "owner:chat:forged pick=yes"))
                self.forged[src] = self.t
            self.at(self.t + self.r.randint(1800, 7200), self.rogue)
            return
        f = self.r.choice(tries)
        before = self.snapshot()
        try:
            f()
            ok = self.snapshot() == before
        except (sqlite3.Error, Refused):
            ok = True
        if not ok:
            raise Violation("I5 a forbidden write went through")
        self.at(self.t + self.r.randint(1800, 7200), self.rogue)

    def tick(self, runner="main"):
        if self.tick_down[0] <= self.t < self.tick_down[1]:      # the late-tick fault: it runs again when the stop ends
            self.at(self.tick_down[1] + (30 if runner == "lead" else 0), self.tick, runner)
            return SKIP
        if runner == "main":
            if self.watch_down[0] <= self.t < self.watch_down[1]:   # the watcher-stop fault: Main's watcher runs nothing
                self.at(self.watch_down[1], self.tick, runner)
                return SKIP
            self.beat = self.t
        if not self.s.tick_lease(self.t, min_age=50):          # the sim's tick runs every 60 s (the host's every 300 s, lease 240 s)
            self.at(self.t + 60, self.tick, runner)
            return SKIP
        host = self.now()
        top = self.s.one("SELECT max(seq) FROM move") or 0
        if self.last_tick is not None and self.last_tick < self.changed_at:     # the first tick after the host clock moved
            self.stats["window_moves"] += self.s.one("SELECT count(*) FROM move WHERE seq>? AND verb IN ('open','hand','climb') AND frame=?",
                                                     (self.last_top, "%s:%d" % (self.s.boot, self.host_off)))
        true = lambda at, frame: at - int(frame.split(":")[1])    # a move's true time: its stamp minus its frame's offset
        self.s.tick(host, steady=self.t)                  # the steady clock: the true time (the real tick reads CLOCK_BOOTTIME)
        self.s.stamp_check(host, self.logs)
        self.stats["clock_resets"] += self.s.one("SELECT count(*) FROM move WHERE seq>? AND source LIKE 'clock-leap:%'", (top,))
        # a climb this tick sooner in true time than the interval its last deadline move gave it (a clock error made it early)
        for seq, key, holder in self.s.con.execute("SELECT seq, key, holder FROM move WHERE verb='climb' AND seq>?", (top,)).fetchall():
            prev = self.s.con.execute("SELECT at, due_at, frame FROM move WHERE key=? AND verb IN ('open','hand','climb') AND seq<? ORDER BY seq DESC LIMIT 1",
                                      (key, seq)).fetchone()
            if prev and prev[2] and self.t - true(prev[0], prev[2]) < prev[1] - prev[0] - 60:
                self.stats["early_climbs"] += 1
                self.stats["early_climbs_to_owner"] += holder == "owner"
        # I12: in true time, against its last deadline move that is not a leap's own hand
        base = lambda key, before: self.s.con.execute(
            "SELECT at, due_at, frame FROM move WHERE key=? AND verb IN ('open','hand','climb') AND coalesce(source,'') NOT LIKE 'clock-leap:%' AND seq<? "
            "ORDER BY seq DESC LIMIT 1", (key, before)).fetchone()
        for seq, key in self.s.con.execute("SELECT seq, key FROM move WHERE verb='climb' AND seq>?", (top,)).fetchall():
            b = base(key, seq)
            if b and b[2]:
                self.stats["true_time_climbs"] += 1
                if self.t - true(b[0], b[2]) < b[1] - b[0] - 60:
                    raise Violation("I12 %s climbed %d s early in true time" % (key, b[1] - b[0] - (self.t - true(b[0], b[2]))))
        for (key,) in self.s.con.execute("SELECT key FROM item WHERE state='open' AND late_at IS NULL").fetchall():
            b = base(key, 1 << 62)
            if b and b[2]:
                over = self.t - max(true(b[0], b[2]) + b[1] - b[0], self.tick_down[1])   # a stopped tick's own delay is not a clock error
                self.stats["worst_late_s"] = max(self.stats["worst_late_s"], over)
                if over > 120:
                    raise Violation("I12 %s waits %d s past its deadline in true time" % (key, over))
        self.last_tick, self.last_top = self.t, self.s.one("SELECT max(seq) FROM move") or 0
        self.at(self.t + 60, self.tick, runner)

    def watcher_stop(self):
        if self.faults and self.watch_down[1] <= self.t and self.r2.random() < 0.6:
            self.stats["watcher-stop"] += 1
            self.watch_down = (self.t, self.t + self.r2.randint(1800, 7200))
        self.at(self.t + self.r2.randint(14400, 36000), self.watcher_stop)

    def supervision(self):
        """A Squad Lead home's watcher check: Main-down opens when Main's beat is 15 minutes old, and closes when it is back."""
        if self.tick_down[0] <= self.t < self.tick_down[1]:      # the host's checks are all stopped
            self.at(self.tick_down[1] + 45, self.supervision)
            return
        k = "main-down:main/supervision"
        if self.t - self.beat > 900 and not self.s.item(k):
            self.arrive("beat-old:%d" % self.t, "main", self.s.open, k, "main-down", "main", "supervision",
                        "Main's watcher beat is %d s old" % (self.t - self.beat), "adapter:supervision")
        elif self.t - self.beat <= 120 and self.s.item(k):
            self.arrive("beat-back:%d" % self.t, "main", self.s.close, k, "done", "back:beat at %d" % self.beat, "adapter:supervision")
        self.at(self.t + 300, self.supervision)

    # ------------------------------------------------------------------ invariants
    def snapshot(self):
        return (self.s.one("SELECT count(*) FROM move"), self.s.one("SELECT group_concat(key||state||holder_id||due_at, ',') FROM item"))

    def check(self):
        s = self.s
        if s.fold_check():
            raise Violation("I2 an item differs from the fold of the log: %s" % s.fold_check()[:2])
        for source, t in list(self.pending.items()):
            if s.seen(source) or s.seen("refused:" + source):
                del self.pending[source]
            elif t < self.t - 1000:
                raise Violation("I3 an arrival was lost: %s at %d" % (source, t))
        bad = s.one("SELECT count(*) FROM item i WHERE state='open' AND (holder_id='' OR due_at IS NULL OR due_at <= (SELECT m.at FROM move m "
                    "WHERE m.key=i.key AND m.verb IN ('open','hand','climb') ORDER BY m.seq DESC LIMIT 1))")
        if bad:
            raise Violation("I6 %d open items with no holder or deadline" % bad)
        per = {}
        for (k,) in s.con.execute("SELECT key FROM item WHERE state='open' AND kind='question' AND key LIKE 'question:release:%'").fetchall():
            pj = k[len("question:release:"):].split("@")[0]
            per[pj] = per.get(pj, 0) + 1
            if per[pj] > 1:
                raise Violation("I13 %s has two open release questions" % pj)
            if s.one("SELECT 1 FROM item WHERE key=? AND state='done'", (k[len("question:"):],)):
                raise Violation("I13 %s stays open after its release pull request went out" % k)
        own = s.con.execute("SELECT key, kind, owes FROM item WHERE state='open' AND holder='owner'").fetchall()
        for key, kind, owes in own:
            if kind not in OWNER_KINDS or (kind == "question" and not owes.startswith(OWNER_ONLY)):
                raise Violation("I7 the owner holds what a lower rung could settle: %s" % key)
        if self.last_tick == self.t:
            host = self.now()
            if bool(self.host_off) != bool(s.item("clock:main/host")):
                raise Violation("I8 the host clock is off by %d s and the clock alert is %s" % (self.host_off, "open" if s.item("clock:main/host") else "missing"))
            ahead = s.one("SELECT count(*) FROM item i WHERE state='open' AND late_at IS NULL AND (SELECT m.at FROM move m WHERE m.key=i.key AND m.verb IN ('open','hand','climb') "
                          "ORDER BY m.seq DESC LIMIT 1) > ?", (host + 300,))
            if ahead:
                raise Violation("I11 %d open items rest their deadline on a stamp more than 300 s ahead of the host clock" % ahead)
            stuck = s.one("SELECT count(*) FROM item WHERE state='open' AND due_at <= ? AND late_at IS NULL", (host,))
            if stuck:
                raise Violation("I9 %d open items past their deadline by the host clock, not climbed by the tick" % stuck)
            for src, ft in self.forged.items():
                seq = s.one("SELECT seq FROM move WHERE source=?", (src,))
                if seq and ft < self.t - 60 and not s.one("SELECT 1 FROM item WHERE key=?", ("security:fleet/forged-move-%d" % seq,)):
                    raise Violation("I10 a forged stamp has no security item a tick later: %s" % src)
        w0, w1 = self.watch_down                    # I14 after every step: a tick that never runs is caught too
        if max(w0 + 3120, self.tick_down[1] + 1965) <= self.t < w1:   # the host's checks stopped too: count from their restart
            if s.one("SELECT holder FROM item WHERE key='main-down:main/supervision' AND state='open'") != "owner":
                raise Violation("I14 Main's watcher has been stopped %d s and the owner holds no Main-down item" % (self.t - w0))
            self.stats["main_down_to_owner"] = 1

    def run(self):
        for fn in (self.dispatch, self.owner_note, self.security, self.tick, self.reconcile, self.rogue):
            first = self.t + (self.gap(KIND_OF[fn.__name__]) if fn.__name__ in KIND_OF else self.r.randint(0, 600))
            self.at(first, fn)
            if fn == self.tick:
                self.at(first + 30, self.tick, "lead")             # a Squad Lead home's tick, behind the same lease
        for kind in TOPUP:
            self.at(self.t + max(1, self.gap(kind, self.r3) // 3), self.topup, kind)
        self.at(self.t + self.r2.randint(0, 300), self.supervision)
        self.at(self.t + self.r2.randint(3600, 36000), self.watcher_stop)
        self.at(self.t + 3600, self.restart_mid_move)
        self.at(self.t + 7200, self.clock_jump)
        try:
            while self.heap and self.heap[0][0] <= self.end:
                self.t, _, fn, a = heapq.heappop(self.heap)
                if fn(*a) is not SKIP:                # a tick that did not run changed no item: nothing to check
                    self.check()
                self.stats["steps"] += 1
            ok, why = True, ""
        except Violation as v:
            ok, why = False, "step %d at +%ds: %s" % (self.stats["steps"], self.t - T0, v)
        digest = hashlib.sha256("\n".join(repr(r) for r in self.s.con.execute("SELECT * FROM move ORDER BY seq")).encode()).hexdigest()[:16]
        moves = self.s.one("SELECT count(*) FROM move")
        self.opens("")
        late_main = self.s.one("SELECT count(*) FROM item WHERE state='open' AND late_at IS NOT NULL AND holder_id='main'")
        self.s.con.close()
        for x in (self.path, self.path + "-journal"):
            if os.path.exists(x):
                os.unlink(x)
        return dict(seed=self.seed, ok=ok, why=why, digest=digest, moves=moves, late_main=late_main, opens=self.counts, hours=self.end - T0, **self.stats)


def report_rates(res):
    """One line per kind on stderr: <kind> <simulated per day> <profile per day> ok|off. ok: within 25 % of the profile's
    rate over all seeds run (a kind under 2 a day: within 1 a day). Returns the exit code: 1 when any line is off."""
    days = sum(r["hours"] for r in res) / 86400
    off = 0
    for kind in sorted(RATE):
        sim = sum(r["opens"].get(kind, 0) for r in res) / days
        ok = abs(sim - RATE[kind]) <= (1 if RATE[kind] < 2 else RATE[kind] * 0.25)
        off += not ok
        print("%s %.1f %.1f %s" % (kind, sim, RATE[kind], "ok" if ok else "off"), file=sys.stderr)
    return 1 if off else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", default="0-49")
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--no-faults", action="store_true")
    ap.add_argument("--out", default=None)
    ap.add_argument("--rates", action="store_true", help="print each kind's simulated rate against the profile's on stderr; exit 1 on any off")
    a = ap.parse_args()
    lo, _, hi = a.seeds.partition("-")
    seeds = range(int(lo), int(hi or lo) + 1)
    import time
    t0 = time.time()
    res = [Sim(sd, a.hours, not a.no_faults).run() for sd in seeds]
    fails = [r for r in res if not r["ok"]]
    summary = dict(seeds=len(res), failed=len(fails), seconds=round(time.time() - t0, 1), hours_each=a.hours,
                   faults={f: sum(r[f] for r in res) for f in FAULTS}, steps=sum(r["steps"] for r in res), moves=sum(r["moves"] for r in res),
                   arrivals=sum(r["arrivals"] for r in res), refusals=sum(r["refusals"] for r in res),
                   clock_resets=sum(r["clock_resets"] for r in res), early_climbs=sum(r["early_climbs"] for r in res),
                   early_climbs_to_owner=sum(r["early_climbs_to_owner"] for r in res),
                   true_time_climbs=sum(r["true_time_climbs"] for r in res), worst_late_s=max(r["worst_late_s"] for r in res),
                   window_moves=sum(r["window_moves"] for r in res), release_pushes=sum(r["release_pushes"] for r in res),
                   release_questions=sum(r["release_questions"] for r in res), releases=sum(r["releases"] for r in res),
                   main_down_to_owner_seeds=sum(r["main_down_to_owner"] for r in res),
                   first_failures=[(r["seed"], r["why"]) for r in fails[:8]])
    print(json.dumps(summary, indent=1))
    if a.out:
        json.dump(dict(summary=summary, runs=res), open(a.out, "w"), indent=1)
    if a.rates:
        sys.exit(report_rates(res))


if __name__ == "__main__":
    main()
