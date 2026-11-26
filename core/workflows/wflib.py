"""wflib: the workflow grammar, the two files that name workflows, and the routes. Every subcommand of
bin/jg-workflow.sh imports this and nothing else; core/workflows/README.md owns the contract."""
import hashlib
import os
import re
import sys

# kind -> (arguments it takes, the default argument). One entry here is one step kind.
KINDS = {
    "worker": ((), None),
    "recon": (("quick", "standard", "deep"), "standard"),
    "critic": ((), None),
    "owner": (("plan-approval",), "plan-approval"),
    "fanout": ((), None),
    "war-room": (("fast", "full"), "fast"),
    "muster": (("survey", "light", "full", "complete"), "full"),
}
REPORTS = {"recon", "critic", "war-room"}  # steps that end in a report the owner has not yet approved a build from
BUILDS = {"worker", "fanout"}
PLAN_SOURCES = {"recon(standard)", "recon(deep)", "war-room"}  # what a critic reads and a fanout starts from
FANOUT_SOURCES = PLAN_SOURCES | {"muster(light)", "muster(full)", "muster(complete)"}
RESERVED = set(KINDS) | {"goal", "custom", "off", "limit", "angles", "pick"}
BY = ("owner", "main", "lead")
NAME = re.compile(r"^[a-z][a-z0-9-]*$")
STEP = re.compile(r"([a-z][a-z0-9-]*)(?:\(([a-z-]+)\))?(?:\*(\d+))?")
HOME_FILE = "config/workflows"


class Refused(Exception):
    """A rule was broken; the message is the whole `refused: ...` line after the colon."""


def refuse(why):
    raise Refused(why)


def run(main):
    """Run a subcommand: a refusal prints one line on stderr and exits 2, with nothing on stdout."""
    try:
        sys.exit(main() or 0)
    except Refused as e:
        print("refused:", e, file=sys.stderr)
        sys.exit(2)


# --- the files -----------------------------------------------------------------------------------------------

def roots():
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    root = os.environ.get("JG_WORKFLOW_ROOT") or here
    return root, os.environ.get("JG_WORKFLOW_CONFIG") or os.path.join(os.environ.get("JG_HOME") or root, "config")


def home_path():
    return os.path.join(roots()[1], "workflows")


def lines(path):
    """(line number, text) of every line with text on it; `#` starts a comment."""
    with open(path) as f:
        for n, raw in enumerate(f.read().splitlines(), 1):
            text = raw.split("#", 1)[0].strip()
            if text:
                yield n, text


def keyed(path):
    """(line number, key, value) of every `<key>: <value>` line of a workflows file."""
    for n, text in lines(path):
        key, sep, value = text.partition(":")
        if not sep:
            refuse(f"{path}:{n}: a line is `<name>: <spec>`; there is no ':' here")
        yield n, key.strip(), value.strip()


class Config:
    def __init__(self):
        self.names = {}  # name -> (spec, source, "file:line")
        self.shipped = set()  # every name the shipped file defines, whether or not a home changed it
        self.limits = {"count": 30, "steps": 64}
        self.angles = []
        self.picks = []  # (test, name) in the order of the file that holds any, the home's first
        self.files = []

    def specs(self):
        return {name: v[0] for name, v in self.names.items()}


def load():
    root, config = roots()
    shipped = os.path.join(root, "defaults", "workflows")
    if not os.path.exists(shipped):
        refuse(f"{shipped}: the shipped workflows file is missing")
    c = Config()
    for source, path in (("shipped", shipped), ("home", home_path())):
        if not os.path.exists(path):
            continue
        c.files.append(path)
        picks = []
        for n, key, value in keyed(path):
            where = f"{path}:{n}"
            word, _, rest = key.partition(" ")
            rest = rest.strip()
            if word == "limit":
                if rest not in c.limits or not value.isdigit() or int(value) < 1:
                    refuse(f"{where}: `limit count|steps: <positive integer>` is the form")
                c.limits[rest] = int(value)
            elif word == "angles" and not rest:
                c.angles = [a.strip() for a in value.split("|")]
                if not all(c.angles):
                    refuse(f"{where}: an angle is empty")
            elif word == "pick" and rest:
                if not value:
                    refuse(f"{where}: a pick names a workflow")
                picks.append((rest, value))
            elif NAME.match(key) and key not in RESERVED:
                if not value:
                    refuse(f"{where}: '{key}' has no spec; write `off` to remove it")
                if source == "shipped":
                    c.shipped.add(key)
                if value == "off":
                    c.names.pop(key, None)
                else:
                    c.names[key] = (value, source, where)
            else:
                refuse(f"{where}: '{key}' is not a name you may define (lowercase letters, digits and dashes; "
                       "not a step kind, goal, custom, off, limit, angles or pick)")
        if picks:
            c.picks = picks
    return c


def angles():
    return load().angles


def route(kind, arg=None):
    """(harness, model, effort) of a step kind: `recon(quick)` reads `recon-quick`, else the bare kind. A home's line wins."""
    root, config = roots()
    table = {}
    for path in (os.path.join(root, "defaults", "workflow-routes"), os.path.join(config, "workflow-routes")):
        if not os.path.exists(path):
            continue
        for n, text in lines(path):
            f = text.split()
            if len(f) != 4:
                refuse(f"{path}:{n}: a route is `<kind> <harness> <model> <effort>`")
            table[f[0]] = tuple(f[1:])
    for key in ([f"{kind}-{arg}"] if arg else []) + [kind]:
        if key in table:
            return table[key]
    refuse(f"no route for '{kind}' in defaults/workflow-routes or config/workflow-routes")


# --- the grammar ---------------------------------------------------------------------------------------------

def matches(step, kinds):
    kind, arg, _ = step
    return kind in kinds or f"{kind}({arg})" in kinds


def nearest(stages, s, kinds):
    """Index of the closest stage before s holding a step of one of the kinds ("recon(deep)" or a bare "war-room"), else None."""
    for j in range(s - 1, -1, -1):
        if any(matches(step, kinds) for step in stages[j]):
            return j
    return None


def _step(text):
    m = STEP.fullmatch(text.replace(" ", ""))
    if not m:
        refuse(f"cannot read '{text.strip()}': a step is a word, an optional (argument) and an optional *count")
    return m.group(1), m.group(2), int(m.group(3)) if m.group(3) else None


def _kind(word, arg, n):
    if word == "goal":
        refuse("a Goal runs through bin/jg-goal.sh")
    if word not in KINDS:
        refuse(f"unknown step '{word}': a kind ({', '.join(KINDS)}) or a name in defaults/workflows or config/workflows")
    args, default = KINDS[word]
    if arg is None:
        arg = default
    elif arg not in args:
        refuse(f"'{word}' takes {'|'.join(args) or 'no argument'}, not '{arg}'")
    return word, arg, (1 if n is None and word != "critic" else n)  # a critic with no count is sized in resolve()


def _named(word, arg, n, names, seen):
    if arg:
        refuse(f"'{word}' is a name and takes no argument")
    if word in seen:
        refuse(f"'{word}' names itself")
    sub = expand(names[word], names, seen + (word,))
    if n is None:
        return sub
    if len(sub) > 1:
        refuse(f"'{word}' has {len(sub)} stages; '*{n}' needs a one-stage name: write its stages out")
    return [[(k, a, (1 if c is None else c) * n) for k, a, c in sub[0]]]


def expand(spec, names, seen=()):
    """The stages of a spec: names replaced by their specs. names maps a name to its spec text."""
    stages = []
    for text in spec.split(">"):
        parts = text.split("+")
        if not spec.strip() or any(not p.strip() for p in parts):
            refuse(f"an empty stage or step in '{spec.strip()}'")
        steps = [_step(p) for p in parts]
        if len(steps) == 1 and steps[0][0] in names:
            stages += _named(*steps[0], names, seen)
            continue
        row = []
        for word, arg, n in steps:
            if word in names:
                sub = _named(word, arg, n, names, seen)
                if len(sub) > 1:
                    refuse(f"'{word}' has {len(sub)} stages; it cannot run beside another step: write its stages out")
                row += sub[0]
            else:
                row.append(_kind(word, arg, n))
        stages.append(row)
    return stages


def resolve(stages):
    """A critic with no count takes the count of the Recons it reads (1 for a war room)."""
    out = []
    for s, row in enumerate(stages):
        new = []
        for k, a, n in row:
            if n is None:
                j = nearest(stages, s, PLAN_SOURCES)
                n = (sum(c for kk, aa, c in stages[j] if kk == "recon" and aa != "quick") if j is not None else 0) or 1
            new.append((k, a, n))
        out.append(new)
    return out


def check(stages, limits, reads=True):
    """The rules that hold for every shape; nothing else is refused. reads=False skips what a step reads: a name
    such as `blitz` is a building block that has its plan source in the spec that uses it."""
    total = 0
    for row in stages:
        for k, a, n in row:
            total += n
            if n < 1:
                refuse(f"'{k}*{n}': a count is 1 or more")
            if n > limits["count"]:
                refuse(f"'{k}*{n}': over the count limit of {limits['count']}; "
                       f"raise it with the line `limit count: {n}` in {HOME_FILE}")
    if total > limits["steps"]:
        refuse(f"{total} steps; the limit is {limits['steps']}; raise it with the line `limit steps: {total}` in {HOME_FILE}")
    for s, row in enumerate(stages):
        for k, a, n in row:
            sources = FANOUT_SOURCES if k == "fanout" else PLAN_SOURCES
            if reads and k in ("critic", "fanout") and nearest(stages, s, sources) is None:
                choices = " or muster" if k == "fanout" else ""
                refuse(f"a {k} needs a recon(standard|deep) or war-room{choices} in an earlier stage "
                       f"({'nothing to critique' if k == 'critic' else 'no slice plan to start'})")
            if k in BUILDS:
                last = max((j for j in range(s) if any(x[0] in REPORTS for x in stages[j])), default=None)
                if last is not None and not any(x[0] == "owner" for j in range(last + 1, s) for x in stages[j]):
                    refuse(f"a {k} after a Recon needs owner(plan-approval) between (owner rule 2026-11-05)")
                if k == "fanout":
                    muster = nearest(stages, s, {"muster"})
                    if muster is not None and not any(x[0] == "owner" for j in range(muster + 1, s) for x in stages[j]):
                        refuse("a fanout after Muster needs owner(plan-approval) between")


def parse(spec_or_name, by="main", config=None, block=False):
    """(name, stages) of a spec or a name; the name is "custom" for a spec that is neither a name nor a bare kind.
    The owner rule holds for every `by`: naming a shape is not approving a plan. block=True parses a name as a
    building block (see check)."""
    if by not in BY:
        refuse(f"--by is one of {', '.join(BY)}")
    c = config or load()
    text = spec_or_name.strip()
    names = c.specs()
    if text in names:
        name, stages = text, expand(names[text], names, (text,))
    else:
        name, stages = (text if text in KINDS else "custom"), expand(text, names)
    stages = resolve(stages)
    check(stages, c.limits, reads=not block)
    return name, stages


def _step_text(step):
    k, a, n = step
    return k + (f"({a})" if a else "") + (f"*{n}" if n > 1 else "")


def stage_texts(stages):
    return [" + ".join(_step_text(x) for x in row) for row in stages]


def canonical(stages):
    return " > ".join(stage_texts(stages))


def sha(stages):
    return hashlib.sha256(canonical(stages).encode()).hexdigest()[:12]


def as_json(stages):
    return [[{"kind": k, "arg": a, "n": n} for k, a, n in row] for row in stages]
