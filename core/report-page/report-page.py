#!/usr/bin/env python3
"""Build a Recon's board page and card from its sources, and check that nobody edited them (core/report-page/README.md)."""
import hashlib, html, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
USAGE = "usage: jg-report-page.sh build|check <task-id>"
PAGE, CARD = "page.html", "report.json"
OUT = "board-report"
STAMP_RE = re.compile(r"jg-report-page sha256=([0-9a-f]{64}) inputs=([0-9a-f]{64})")


def die(msg, rc=2):
    print(f"jg-report-page: {msg}", file=sys.stderr)
    sys.exit(rc)


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def data_dir(task):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task):
        die(f"task id '{task}' is not a plain id")
    data = os.environ.get("JG_DATA_OVERRIDE") or os.path.join(os.environ.get("JG_HOME") or ROOT, "data")
    d = os.path.join(data, task)
    if not os.path.isdir(d):
        die(f"no task directory at {d}")
    return d


def read(path, what):
    if not os.path.isfile(path):
        die(f"{what} is missing: {path}")
    return open(path, encoding="utf-8").read()


def sections(report):
    """The body of each numbered `## n. Name` section of report.md."""
    heads = list(re.finditer(r"^## (\d+)\.\s+(.*)$", report, re.M))
    out = {}
    for i, m in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(report)
        out[int(m.group(1))] = report[m.end():end].strip()
    return out


def ledger(path):
    """key -> (value, source): one line of ledger.tsv holds one count."""
    rows = {}
    for n, line in enumerate(read(path, "ledger.tsv").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 2 or not cols[0] or not cols[1]:
            die(f"ledger.tsv line {n} needs 'key<TAB>value[<TAB>source]'")
        if cols[0] in rows:
            die(f"ledger.tsv line {n}: key '{cols[0]}' appears twice")
        rows[cols[0]] = (cols[1], cols[2] if len(cols) > 2 else "")
    return rows


def machine_edges(machine):
    """(event, from, to) lines from the one reader of the tables."""
    if not re.fullmatch(r"[a-z0-9-]+", machine):
        die(f"machine name '{machine}' is not a plain name")
    r = subprocess.run([os.path.join(ROOT, "bin", "jg-machine.sh"), "events", machine], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"machine '{machine}' has no readable table: {r.stderr.strip() or r.stdout.strip()}")
    return [tuple(l.split("\t")) for l in r.stdout.splitlines() if l.count("\t") == 2]


def layout(edges):
    """Columns by distance from the first event; rows in order of first sight. Nothing is placed by hand."""
    order, level = [], {}
    for _, a, b in edges:
        for s in (a, b):
            if s != "(none)" and s not in level:
                level[s] = None
                order.append(s)
    queue = [b for _, a, b in edges if a == "(none)"]
    for s in queue:
        level[s] = 0
    i = 0
    while i < len(queue):
        s = queue[i]; i += 1
        for _, a, b in edges:
            if a == s and level.get(b) is None:
                level[b] = level[s] + 1
                queue.append(b)
    top = max([v for v in level.values() if v is not None], default=0)
    for s in order:
        if level[s] is None:
            level[s] = top + 1
    rows, pos = {}, {}
    for s in order:
        pos[s] = (level[s], rows.setdefault(level[s], 0))
        rows[level[s]] += 1
    return order, pos, rows


CSS = ("body{margin:0;font:14px system-ui,sans-serif;color:#1c2430;background:#fff}"
       "main{max-width:960px;margin:0 auto;padding:16px}svg{max-width:100%;height:auto}"
       ".b{fill:#eef2f7;stroke:#7d8aa0}.e{stroke:#7d8aa0;fill:none}.l{font-size:10px;fill:#5a6577}"
       "@media(prefers-color-scheme:dark){body{color:#e6ebf2;background:#12161c}.b{fill:#1e2631}.l{fill:#a9b3c3}}")


def drawing(label, edges):
    bw, bh, gx, gy, pad = 128, 30, 78, 26, 12
    order, pos, rows = layout(edges)
    cols = max([c for c, _ in pos.values()], default=0) + 1
    height = max(rows.values(), default=1) * (bh + gy) + pad * 2
    width = cols * (bw + gx) - gx + pad * 2
    xy = {s: (pad + c * (bw + gx), pad + r * (bh + gy)) for s, (c, r) in pos.items()}
    out = [f'<svg viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(label)}"><defs>'
           '<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
           '<path d="M0 0L10 5L0 10z" fill="#7d8aa0"/></marker></defs>']
    for ev, a, b in edges:
        if a == "(none)":
            continue
        (x1, y1), (x2, y2) = xy[a], xy[b]
        if pos[a][0] < pos[b][0]:
            p = (x1 + bw, y1 + bh / 2, x2, y2 + bh / 2)
        else:
            p = (x1 + bw / 2, y1, x2 + bw / 2, y2)
        out.append(f'<path class="e" d="M{p[0]:g} {p[1]:g}L{p[2]:g} {p[3]:g}" marker-end="url(#ah)"/>')
        out.append(f'<text class="l" x="{(p[0] + p[2]) / 2:g}" y="{(p[1] + p[3]) / 2 - 2:g}" text-anchor="middle">{html.escape(ev)}</text>')
    for s in order:
        x, y = xy[s]
        out.append(f'<rect class="b" x="{x}" y="{y}" width="{bw}" height="{bh}" rx="6"/>'
                   f'<text x="{x + bw / 2:g}" y="{y + bh / 2 + 4:g}" text-anchor="middle" font-size="12">{html.escape(s)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def plan_items(text):
    """One item per table row of the plan section: the slice id and its outcome."""
    items = []
    for line in text.splitlines():
        cols = [c.strip() for c in line.strip().strip("|").split("|")]
        if line.startswith("|") and len(cols) >= 3 and not set(cols[0]) <= set("-: ") and cols[0] != "Slice":
            items.append({"title": cols[0], "text": cols[2]})
    return items


def gather(task):
    d = data_dir(task)
    spec = json.loads(read(os.path.join(d, "page.json"), "page.json"))
    secs = sections(read(os.path.join(d, "report.md"), "report.md"))
    for n, name in ((1, "Answer"), (8, "Implementation plan")):
        if not secs.get(n):
            die(f"report.md has no body under '## {n}. {name}'")
    led = ledger(os.path.join(d, "ledger.tsv")) if os.path.isfile(os.path.join(d, "ledger.tsv")) else {}

    def fill(s):
        def one(m):
            if m.group(1) not in led:
                die(f"page.json names count '{m.group(1)}' and ledger.tsv has no such line")
            return led[m.group(1)][0]
        return re.sub(r"\{\{count:([A-Za-z0-9._-]+)\}\}", one, s)

    machines = [(x["label"], x["machine"], machine_edges(x["machine"])) for x in spec.get("drawings", [])]
    counts = [{"label": fill(c["label"]), "value": fill("{{count:%s}}" % c["ledger"])} for c in spec.get("counts", [])]
    answer = secs[1].split("\n\n")[0].strip()
    inputs = sha(json.dumps([spec, secs[1], secs[8], sorted(led.items()), machines], sort_keys=True))
    return d, spec, fill, machines, counts, answer, plan_items(secs[8]), inputs


def render(task):
    d, spec, fill, machines, counts, answer, plan, inputs = gather(task)
    title = fill(spec["title"])
    card = {"contract": 1, "kind": "report", "schema": 5, "key": spec["key"], "title": title,
            "purpose": spec.get("purpose", "audit"), "filed": spec["filed"], "filer": spec["filer"],
            "about": fill(answer), "project": spec["project"], "group": spec.get("group", ""),
            "sections": [{"id": "answer", "heading": "Answer", "body": fill(answer)},
                         {"id": "plan", "heading": "Plan", "body": f"{len(plan)} slices", "items": plan}],
            "counts": counts}
    card_text = json.dumps(card, indent=1, ensure_ascii=False) + "\n"
    figs = "\n".join(f"<h2>{html.escape(fill(l))}</h2>\n{drawing(l, e)}" for l, _, e in machines)
    rows = "\n".join(f"<tr><td>{html.escape(c['label'])}</td><td>{html.escape(c['value'])}</td></tr>" for c in counts)
    page = (f"<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>{html.escape(title)}</title>"
            f"<style>{CSS}</style></head><body><main><h1>{html.escape(title)}</h1><p>{html.escape(fill(answer))}</p>\n"
            f"{figs}\n<table>\n{rows}\n</table></main></body></html>\n")
    return d, inputs, page, card


def stamp(body, inputs):
    return f"jg-report-page sha256={sha(body)} inputs={inputs}"


def build(task):
    d, inputs, page, card = render(task)
    out = os.path.join(d, OUT)
    os.makedirs(out, exist_ok=True)
    card["built_by"] = stamp(json.dumps(card, indent=1, ensure_ascii=False) + "\n", inputs)
    # The stamp of the card covers the card without its own stamp line.
    with open(os.path.join(out, PAGE), "w", encoding="utf-8") as f:
        f.write(f"<!-- {stamp(page, inputs)} -->\n{page}")
    with open(os.path.join(out, CARD), "w", encoding="utf-8") as f:
        f.write(json.dumps(card, indent=1, ensure_ascii=False) + "\n")
    print(f"jg-report-page: built {OUT}/{PAGE} and {OUT}/{CARD} for {task}")


def check(task):
    d, inputs, _, _ = render(task)
    out = os.path.join(d, OUT)
    if not os.path.isdir(out):
        print(f"jg-report-page: PASS - {task} has no {OUT} folder")
        return 0
    bad = []
    for name in (PAGE, CARD):
        path = os.path.join(out, name)
        if not os.path.isfile(path):
            bad.append(f"{OUT}/{name} is missing; run jg-report-page.sh build {task}")
            continue
        text = open(path, encoding="utf-8").read()
        if name == PAGE:
            first, _, body = text.partition("\n")
            m = STAMP_RE.search(first)
            got = (m.group(1), m.group(2)) if m else None
            want = sha(body)
        else:
            try:
                obj = json.loads(text)
            except ValueError:
                bad.append(f"{OUT}/{name} is not JSON and was not written by jg-report-page.sh")
                continue
            m = STAMP_RE.fullmatch(str(obj.pop("built_by", "")))
            got = (m.group(1), m.group(2)) if m else None
            want = sha(json.dumps(obj, indent=1, ensure_ascii=False) + "\n")
        if got is None:
            bad.append(f"{OUT}/{name} carries no jg-report-page stamp, so the command did not write it")
        elif got[0] != want:
            bad.append(f"{OUT}/{name} was edited by hand: its content hash does not match its stamp")
        elif got[1] != inputs:
            bad.append(f"{OUT}/{name} is stale: its sources changed; run jg-report-page.sh build {task}")
    for b in bad:
        print(f"jg-report-page: refused: {b}", file=sys.stderr)
    if bad:
        return 1
    print(f"jg-report-page: PASS - {task}: page and card match their sources")
    return 0


def main(a):
    if len(a) != 2 or a[0] not in ("build", "check"):
        die(USAGE)
    if a[0] == "build":
        build(a[1])
        return 0
    return check(a[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
