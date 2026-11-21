"""words "<text>": the owner's plain words as one canonical workflow spec on stdout, or `refused: I do not know "<word>"; I
know: <list>` on stderr with exit 2. Stages split on `then`, `after that` or `>`; the steps of one stage split on `and`,
`,`, `+` or `at once with`; a count is digits or one to thirty, `a` and `an` are 1. A noun is a step word of PHRASES or any
workflow name of the files (written with `-` or with spaces, longest match first, a name wins a tie), so a name the owner
adds is a word at once. A deep Recon always has its critic, and a build after a report always has its owner(plan-approval)
(owner rule 2026-11-05); each one added is told on stderr. wflib checks the result with --by owner."""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wflib  # noqa: E402

# phrase -> (spec, deep). One entry is one way to say a step; a spec of more than one stage takes no count.
PHRASES = {
    "scout": ("recon(quick)", False),
    "worker": ("worker", False), "lane": ("worker", False),
    "recon": ("recon(standard)", False), "quick recon": ("recon(quick)", False),
    "deep recon": ("recon(deep)", True), "lite war room": ("recon(deep)", True),
    "critic": ("critic", False),
    "war room": ("war-room(fast)", False), "fast war room": ("war-room(fast)", False),
    "full war room": ("war-room(full)", False),
    "blitz": ("owner(plan-approval) > fanout", False), "slices": ("owner(plan-approval) > fanout", False),
    "my approval": ("owner(plan-approval)", False), "my yes": ("owner(plan-approval)", False),
    "plan approval": ("owner(plan-approval)", False),
}
FILLER = {"the", "with", "run", "do", "first", "go", "on", "it", "just", "are"}
ONES = "one two three four five six seven eight nine".split()
TEENS = "ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
NUMBERS = {w: i for i, w in enumerate(ONES, 1)}
NUMBERS.update({w: 10 + i for i, w in enumerate(TEENS)})
NUMBERS.update({"a": 1, "an": 1, "twenty": 20, "thirty": 30})
NUMBERS.update({f"twenty {w}": 20 + i for i, w in enumerate(ONES, 1)})  # `twenty-three` reads as these two words
SEPARATORS = [(("after", "that"), "stage"), (("at", "once", "with"), "step"), (("then",), "stage"), ((">",), "stage"),
              (("and",), "step"), ((",",), "step"), (("+",), "step")]
TOKEN = re.compile(r"[a-z0-9]+|[>+,]")


def nouns(c):
    """tokens -> (spec, deep, label): the step words, then every workflow name (which wins a tie)."""
    table = {tuple(p.split()): (spec, deep, p) for p, (spec, deep) in PHRASES.items()}
    for name in c.names:
        table[tuple(name.split("-"))] = (name, False, name)
    return table


def match(tokens, i, table):
    """(noun, length) of the longest noun at tokens[i], also with its last word in the plural; else None."""
    for length in range(min(max(map(len, table)), len(tokens) - i), 0, -1):
        words = tuple(tokens[i:i + length])
        for key in (words, words[:-1] + (words[-1][:-1],)):
            if key in table:
                return table[key], length
    return None


def separator(tokens, i):
    return next(((kind, len(words)) for words, kind in SEPARATORS if tuple(tokens[i:i + len(words)]) == words), None)


def number(tokens, i):
    """(count, tokens used) of the count at tokens[i], else None."""
    for length in (2, 1):
        word = " ".join(tokens[i:i + length])
        if len(tokens[i:i + length]) == length and (word in NUMBERS or length == 1 and word.isdigit()):
            return NUMBERS.get(word) or int(word), length
    return None


def scaled(stages, n, label):
    if n is None:
        return stages
    if len(stages) > 1:
        wflib.refuse(f"'{label}' has {len(stages)} stages; a count needs a one-stage word: write its stages out")
    return [[(k, a, (1 if c is None else c) * n) for k, a, c in stages[0]]]


def unknown(word, names):
    wflib.refuse(f'I do not know "{word}"; I know: {", ".join(sorted(set(PHRASES) | set(names)))}')


def read(text, c):
    """[(steps, deep)] of the words, one entry per stage, before the two rules that add a stage."""
    table, names = nouns(c), c.specs()
    tokens = TOKEN.findall(text.lower().replace("-", " "))
    stages, cur, deep = [], [], False
    count = None  # a count read, waiting for its noun
    fresh = True  # no step since the last separator
    alone = False  # a word of several stages fills its stages alone

    def close():
        nonlocal cur, deep, alone
        if cur:
            stages.append((cur, deep))
        cur, deep, alone = [], False, False

    i = 0
    while i < len(tokens):
        hit, sep, num = match(tokens, i, table), separator(tokens, i), number(tokens, i)
        if hit:
            (spec, is_deep, label), length = hit
            if not fresh:
                wflib.refuse(f'"{label}" follows another step with no "and", "then" or "," between them')
            found = scaled(wflib.expand(spec, names), count, label)
            if len(found) > 1 and cur or len(found) == 1 and alone:
                wflib.refuse(f"'{label}' and a word of several stages cannot run side by side: write their stages out")
            if len(found) > 1:
                stages.extend((s, False) for s in found)
                alone = True
            else:
                cur += found[0]
                deep = deep or is_deep
            count, fresh, i = None, False, i + length
        elif sep:
            if count is not None:
                wflib.refuse("a count needs a step right after it")
            if sep[0] == "stage":
                close()
            fresh, i = True, i + sep[1]
        elif tokens[i] in FILLER:
            i += 1
        elif num and count is None:
            count, i = num[0], i + num[1]
        else:
            unknown(tokens[i], names)
    if count is not None:
        wflib.refuse("a count needs a step right after it")
    close()
    if not stages:
        wflib.refuse("there are no steps in these words")
    return stages


def with_critics(stages):
    """A critic stage right after each stage holding a deep Recon, unless the next stage already holds a critic."""
    out = []
    for s, (steps, deep) in enumerate(stages):
        out.append(steps)
        nxt = stages[s + 1][0] if s + 1 < len(stages) else []
        if deep and not any(k == "critic" for k, _, _ in nxt):
            out.append([("critic", None, None)])
    return out


def with_approvals(stages):
    """(stages, notes): owner(plan-approval) in front of each build stage that follows a report with no approval between."""
    out, notes = [], []
    for steps in stages:
        build = next((k for k, _, _ in steps if k in wflib.BUILDS), None)
        last = max((j for j, row in enumerate(out) if any(k in wflib.REPORTS for k, _, _ in row)), default=None)
        if build and last is not None and not any(k == "owner" for row in out[last + 1:] for k, _, _ in row):
            out.append([("owner", "plan-approval", 1)])
            notes.append(f"added: owner(plan-approval) before {build} (owner rule 2026-11-05)")
        out.append(steps)
    return out, notes


def spec_text(stages):
    """The spec as written: a critic without a count stays `critic`, and wflib sizes it to the Recons it reads."""
    def step(k, a, n):
        return k + (f"({a})" if a else "") + (f"*{n}" if n and n > 1 else "")
    return " > ".join(" + ".join(step(*x) for x in row) for row in stages)


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh words")
    p.add_argument("text", help="the owner's words, such as '2 scouts then 2 workers'")
    a = p.parse_args()
    c = wflib.load()
    stages, notes = with_approvals(with_critics(read(a.text, c)))
    text = spec_text(stages)
    wflib.parse(text, "owner", c)  # the grammar's own rules
    for note in notes:
        print(note, file=sys.stderr)
    print(text)


wflib.run(main)
