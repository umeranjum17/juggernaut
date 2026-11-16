#!/usr/bin/env python3
"""reduce.py - the one reducer of the verify's proof results (ticket jg-ftplan.3), the only owner of the rule below.

  reduce.py verdict <inputs.json> [--check <results.json>]   print the typed verdict as JSON; exit 0 when it is green or graced
                                                              (a home may be kept), 1 when it is red or incomplete
  reduce.py order <spec.json>                                 print the order evidence of one script (see ORDER below)
  reduce.py map <inputs.json>                                 print the record map {script: [asks]} (see MAP below)

The rule, per required script (a pass is a pass):
  - The result of a script is its proof result, replaced by its latest same-recipe rerun when the proof result was not a pass
    (a rerun pass after a fail is a flaky pass; a skip clears the same way).
  - A skip, a missing or quarantined result, a runner-bound timeout and a missing aggregate are INCOMPLETE: never a red, never
    inside the grace, never a pass.
  - A failure is COUNTED when the script passes at the pin, when the script is new at the head and red twice, or when the pin's
    own run printed `ok` for the case holding the head's first failing assertion (the pin got past it) and the head is red twice
    with that assertion. One such run is incomplete. It is CARRIED when it fails like the pin (the same first assertion).
  - When the pin stopped before that case, the failure is CARRIED-PROGRESSED if the head gets past the pin's stopping point: a
    pre-existing red that uses no grace slot but blocks its asks. Otherwise it is INCOMPLETE: no pin baseline, which no rerun
    can create. Order is read from the test source and the run logs (`order`), never from the message text.
  - The verdict is RED when the counted scripts exceed the grace, else INCOMPLETE when anything is incomplete, else GRACED when
    something is counted, carried or carried-progressed, else GREEN.
  - A counted, carried or incomplete script blocks the In-use claim of every ask the record map says it proves, inside the grace
    too. Every blocking script, and a missing aggregate, gets exactly one repair owner: an open ticket that already names it
    (reused), else its planned slice, else one new lane `fix-<script>`. Owner ids are deterministic, so routing a verdict twice
    opens nothing.
  - `check_pending` lists the incomplete scripts a rerun can resolve; `unresolvable` lists the inputs no rerun can (missing,
    quarantined, no pin baseline, a missing aggregate): a mover refuses those before it moves anything.

verdict inputs (JSON): grace (number), aggregate_present (bool), manifest [script], runs {script: [{kind, ff}]} with kind one of
pass, fail, timeout, skip, missing, quarantined and ff the first failing assertion; pin {script: {state, ff}} with state one of
pass, fail, absent, record-fail, unknown; order {script: {pin_passed_head_case, head_progressed_past_pin}}; map {script: [ask]};
tickets [{id, title, body}] open tickets (owners are reused from them); planned {script or "official aggregate": owner}.
--check <results.json> is {script: {kind, ff}}: the first-home check's reruns, appended to each script's runs before the verdict
is recomputed, so one verdict covers every proof and check result.

ORDER (spec JSON): head_src, pin_src (test sources), head_log, pin_log (run logs with JG_TEST_BEGIN <id> <script> lines),
script, head_ff, pin_ff. Prints {head_case, pin_case, pin_ok_cases, head_ok_cases, pin_passed_head_case, head_progressed_past_pin}.

MAP (inputs JSON): manifest, asks [ticket ids that are owner asks], tickets [{id, body, close_reason}], creators {script: {sha,
ticket}} (or repo: a git directory to read them from). A script proves an ask when a ticket that traces through `parent:` lines to
an ask names the script on a line that is not a `refused:` line, or when the commit that created the script carries such a ticket.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import defaultdict

PASS, FAIL, TIMEOUT, SKIP, MISSING, QUARANTINED = "pass", "fail", "timeout", "skip", "missing", "quarantined"
UNRESOLVABLE = ("missing", "quarantined", "no pin baseline", "official aggregate")
AGGREGATE = "official aggregate"


def norm(x):
    x = re.sub(r"^not ok - ", "", x or "")
    x = re.sub(r"/[^ ]*/", "/", x)
    x = re.sub(r"\bjg-[0-9a-z]{3,5}(-\d+)?\b", "jg-ID", x)
    x = re.sub(r"\.[A-Za-z0-9]{6}\b", ".TMP", x)
    return re.sub(r":? ?cat: /\S*", "", x).strip()[:120]


def kind_of(r):
    k = r.get("kind", MISSING)
    return SKIP if k.startswith("skip") else k


def classify(runs, pin, order):
    """One script's class: pass, counted, carried, carried-progressed or incomplete, each with its reason."""
    rs = runs or [{"kind": MISSING}]
    r = rs[0]
    if kind_of(r) != PASS and len(rs) > 1:
        r = rs[-1]                                    # a rerun replaces any non-pass
    kind = kind_of(r)
    fails = [x for x in rs if kind_of(x) == FAIL]
    twice = len(fails) >= 2 and len({norm(x.get("ff")) for x in fails}) == 1 and kind == FAIL
    if kind == PASS:
        return "pass"
    if kind in (SKIP, MISSING, QUARANTINED):
        return "incomplete: " + kind
    if kind == TIMEOUT:
        return "incomplete: runner-bound timeout"
    state = pin.get("state", "unknown")
    if state == "absent":
        return "counted: new script red twice" if twice else "incomplete: new script red once"
    if state == "pass":
        return "counted: regression"
    if state == "fail" and norm(r.get("ff")) == norm(pin.get("ff")):
        return "carried: same first assertion as the pin"
    if state == "record-fail" and norm(r.get("ff")) == norm(pin.get("ff")):
        return "carried: same first assertion as the pin-ancestor record"
    if state == "fail" and order.get("pin_passed_head_case"):
        return "counted: the pin passed this assertion; red twice" if twice else "incomplete: new failing assertion seen once"
    if order.get("head_progressed_past_pin"):
        return "carried-progressed: red at the pin; the head gets past the pin's failing case and fails later"
    return "incomplete: no pin baseline for this assertion"


def existing_owners(manifest, tickets):
    """The open ticket that already names each script: by its id, title or body, or the flaky-test gate's id for it."""
    out = {}
    for t in tickets:
        if t.get("status") in ("done", "closed"):
            continue
        text = " ".join(str(t.get(k) or "") for k in ("id", "title", "body"))
        for s in manifest:
            if s in text or t["id"] == "flaky-juggernaut-" + re.sub(r"\.test\.sh$", "", s.rsplit("/", 1)[-1]):
                out.setdefault(s, t["id"])
    return out


def repair_owners(cls, aggregate_present, bmap, existing, planned):
    out = {}
    for s in [s for s, c in sorted(cls.items()) if c != "pass"] + ([] if aggregate_present else [AGGREGATE]):
        c = cls.get(s, "incomplete: official aggregate missing")
        if s in existing:
            o = {"owner": existing[s], "source": "existing open ticket (reused; typed cause appended)"}
        elif s in planned:
            o = {"owner": planned[s], "source": "planned slice"}
        else:
            o = {"owner": "fix-" + re.sub(r"\.test\.sh$", "", s.rsplit("/", 1)[-1]), "source": "new lane"}
        out[s] = {**o, "kind": "make complete" if c.startswith("incomplete") else "fix forward", "class": c, "asks": sorted(bmap.get(s, ()))}
    return out


def verdict(doc, check=None):
    manifest, grace, bmap = doc["manifest"], doc.get("grace", 2), doc.get("map", {})
    runs = {s: list(v) for s, v in doc.get("runs", {}).items()}
    for s, r in (check or {}).items():
        runs[s] = runs.get(s, []) + [r]
    agg = bool(doc.get("aggregate_present"))
    cls = {s: classify(runs.get(s), doc.get("pin", {}).get(s, {}), doc.get("order", {}).get(s, {})) for s in manifest}
    by = lambda prefix: sorted(s for s, c in cls.items() if c.startswith(prefix))  # noqa: E731
    counted, carried, incomplete = by("counted"), by("carried"), by("incomplete")
    reasons = [f"{s}: {cls[s][12:]}" for s in incomplete] + ([] if agg else ["official aggregate missing"])
    status = "red" if len(counted) > grace else "incomplete" if reasons else "graced" if counted or carried else "green"
    blocked = defaultdict(list)
    for s in counted + carried + incomplete:
        for a in sorted(bmap.get(s, ())):
            blocked[a].append(s)
    owners = repair_owners(cls, agg, bmap, existing_owners(manifest, doc.get("tickets", [])), doc.get("planned", {}))
    stuck = [x for x in reasons if any(u in x for u in UNRESOLVABLE)]
    return {"status": status, "keep": status in ("green", "graced"), "grace": grace, "counted": counted, "carried": carried,
            "incomplete": incomplete, "incomplete_reasons": reasons, "class": cls, "asks_not_in_use": dict(sorted(blocked.items())),
            "repair_owners": owners, "new_lanes": sorted({o["owner"] for o in owners.values() if o["source"] == "new lane"}),
            "check_pending": [s for s in incomplete if not any(u in cls[s] for u in UNRESOLVABLE)], "unresolvable": stuck,
            "unmapped_failures": sorted(s for s in counted + carried + incomplete if not bmap.get(s))}


# ---------- order: where in the test the pin and the head each stopped ----------
def cname(x):
    return re.sub(r"\s+", " ", re.sub(r"^ok - ", "", x or "")).strip().lower()


def cases_in(src):
    """[(line, case name)] for every `pass "..."` of a test source, in source order."""
    return [(i, cname(m[1])) for i, ln in enumerate(src.splitlines(), 1) for m in [re.match(r'\s*pass "(.*)"\s*$', ln)] if m]


def ok_cases(log, script):
    """The `ok - ...` case names the log printed for one script, between its JG_TEST_BEGIN and JG_TEST_END lines."""
    oks, cur = [], None
    for ln in log.splitlines():
        m = re.match(r"JG_TEST_BEGIN \S+ (\S+)", ln)
        if m:
            cur, oks = m[1], ([] if m[1] == script else oks)
        elif cur == script and ln.startswith("ok - "):
            oks.append(cname(ln))
        elif cur == script and ln.startswith("JG_TEST_END"):
            break
    return oks


def fail_case(src, ff, oks):
    """The case that holds a run's first failing assertion: the case after the source line that prints the message, else the case
    after the last `ok` line."""
    cases = cases_in(src)
    msg = re.sub(r"\s*\(expected .*$", "", norm(ff)).rstrip(": ").strip()
    hits = []
    for i, ln in enumerate(src.splitlines(), 1):
        for m in re.finditer(r'"((?:[^"\\]|\\.){10,})"', ln):
            rx = re.sub(r"\\\$\\\{[^}]*\\\}|\\\$[A-Za-z_][A-Za-z0-9_]*", ".+", re.escape(norm(m[1])))
            lit = len(re.sub(r"\.\+|\\", "", rx))
            if msg and lit >= 10 and re.fullmatch(rx, msg):
                hits.append((-lit, i))
    if hits:
        line = sorted(hits)[0][1]
        nxt = next((c for ln, c in cases if ln >= line), None)
        if nxt:
            return nxt
    names = [c for _, c in cases]
    if oks and oks[-1] in names and names.index(oks[-1]) + 1 < len(names):
        return names[names.index(oks[-1]) + 1]
    return names[0] if names and not oks else None


def order_evidence(spec):
    script = spec["script"]
    head_ok, pin_ok = ok_cases(spec["head_log"], script), ok_cases(spec["pin_log"], script)
    head_case = fail_case(spec["head_src"], spec["head_ff"], head_ok)
    pin_case = fail_case(spec["pin_src"], spec["pin_ff"], pin_ok)
    passed = head_case in pin_ok
    in_head_source = pin_case in {c for _, c in cases_in(spec["head_src"])}
    progressed = (not passed) and (pin_case in head_ok or (not in_head_source and len(head_ok) > len(pin_ok)))
    return {"head_case": head_case, "pin_case": pin_case, "head_ok_cases": len(head_ok), "pin_ok_cases": len(pin_ok),
            "pin_passed_head_case": passed, "head_progressed_past_pin": progressed}


# ---------- map: the asks a script proves ----------
def creators_of(repo, manifest):
    """{script: {sha, ticket}}: the oldest commit that added each script and the ticket it carries (a `Ticket:` trailer, else the
    subject's leading `<ticket>:`)."""
    out = {}
    for s in manifest:
        log = subprocess.run(["git", "-C", repo, "log", "--diff-filter=A", "--format=@%H%x09%s%n%(trailers:key=Ticket,valueonly)", "HEAD", "--", s],
                             capture_output=True, text=True, check=False).stdout
        cur = None
        for ln in log.splitlines():
            if ln.startswith("@"):
                sha, subj = ln[1:].split("\t", 1)
                m = re.match(r"^([a-z0-9][a-z0-9-]+):", subj)
                cur = {"sha": sha, "ticket": m[1] if m else None}
            elif ln.strip() and cur:
                cur["ticket"] = ln.strip()
        if cur:
            out[s] = cur
    return out


def record_map(doc):
    asks, tickets = set(doc.get("asks", [])), {t["id"]: t for t in doc.get("tickets", [])}

    def ask_of(t):
        seen = []
        while t and t not in seen and len(seen) < 12:
            seen.append(t)
            if t in asks:
                return t
            m = re.search(r"(?m)^parent: (\S+)", (tickets.get(t) or {}).get("body") or "")
            t = m[1] if m else None
        return None

    named = defaultdict(set)
    for tid, t in tickets.items():
        a = ask_of(tid)
        for ln in ((t.get("body") or "") + "\n" + (t.get("close_reason") or "")).splitlines():
            if a and not re.match(r"\s*(?:[-*]\s*)?refused:", ln, re.I):
                for s in re.findall(r"(?:tests/)?(jg-[a-z0-9-]+?)\.test\.sh", ln):
                    named["tests/" + s + ".test.sh"].add(a)
    creators = doc.get("creators") or creators_of(doc["repo"], doc["manifest"])
    out = {}
    for s in doc["manifest"]:
        c = (creators.get(s) or {}).get("ticket")
        a = ask_of(c) if c else None
        out[s] = sorted(named.get(s, set()) | ({a} if a else set()))
    return out


def main(argv):
    if len(argv) < 3 or argv[1] not in ("verdict", "order", "map"):
        sys.stdout.write(__doc__)
        return 0 if argv[1:2] in (["-h"], ["--help"]) else 2
    with open(argv[2], encoding="utf-8") as fh:
        doc = json.load(fh)
    if argv[1] == "order":
        print(json.dumps(order_evidence(doc), indent=1))
        return 0
    if argv[1] == "map":
        print(json.dumps(record_map(doc), indent=1, sort_keys=True))
        return 0
    check = None
    if len(argv) == 5 and argv[3] == "--check":
        with open(argv[4], encoding="utf-8") as fh:
            check = json.load(fh)
    elif len(argv) != 3:
        sys.stderr.write("reduce: verdict takes <inputs.json> [--check <results.json>]\n")
        return 2
    v = verdict(doc, check)
    print(json.dumps(v, indent=1, sort_keys=True))
    return 0 if v["keep"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
