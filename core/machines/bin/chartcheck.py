"""The chart check (core/machines/README.md, "Diagram"): reads the SVG that Graphviz made and names each fault.

plate() lifts every arrow label and every title of a composite group to a top layer, each on a plate of the page colour, so a line that
passes a label is cut there and cannot strike its text. check() then fails on:
  - two arrows that cross (each arrow is cut into short pieces; a piece of one meeting a piece of the other, away from a state both touch);
  - an arrow with no arrowhead;
  - a label that is not on its plate in the top layer;
  - two labels that overlap, and a label that overlaps a state;
  - a narrow layout wider than NARROW_MAX, whose text would fall under 9.5 px on a 390 px screen.
"""
import html
import re

NARROW_MAX = 450  # pt: the narrow chart is shown at 85% on a 390 px screen, and 450 * 0.85 keeps its 11 pt text above 9.5 px
EDGE = re.compile(r'<g id="([^"]*)" class="edge[^"]*">(.*?)</g>', re.S)
CLUSTER = re.compile(r'<g id="clust\d+" class="cluster[^"]*">.*?</g>', re.S)
TEXT = re.compile(r'<text[^>]* x="(-?[\d.]+)" y="(-?[\d.]+)"[^>]* font-size="([\d.]+)"[^>]*>([^<]*)</text>\s*')
NUM = re.compile(r"-?\d+\.?\d*")


def _plain(t):
    return html.unescape(t).strip()


def _plate(texts, cls):
    """One plate for the lines of one label: the box that holds them all, in the width of an estimate of 0.47 of the font size a letter."""
    boxes = []
    for x, y, fs, t in texts:
        w = 0.47 * fs * max(len(_plain(t)), 1) + 4
        boxes.append((x - w / 2, y - 0.82 * fs, x + w / 2, y + 0.23 * fs))
    x0, y0, x1, y1 = min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)
    body = "".join(f'<text x="{x}" y="{y}" font-size="{fs}" text-anchor="middle" font-family="Helvetica">{t}</text>' for x, y, fs, t in texts)
    return f'<g class="label"><rect class="plate {cls}" x="{x0:.1f}" y="{y0:.1f}" width="{x1 - x0:.1f}" height="{y1 - y0:.1f}"/>{body}</g>'


def plate(svg):
    """The SVG with each label lifted to the top layer on its plate."""
    top = []

    def lift(g, cls):
        texts = [(m.group(1), m.group(2), float(m.group(3)), m.group(4)) for m in TEXT.finditer(g)]
        if texts:
            top.append(_plate([(float(x), float(y), fs, t) for x, y, fs, t in texts], cls))
        return TEXT.sub("", g)

    svg = EDGE.sub(lambda g: g.group(0).replace(g.group(2), lift(g.group(2), "pe")), svg)
    svg = CLUSTER.sub(lambda g: lift(g.group(0), "pc"), svg)
    i = svg.rindex("</g>")
    return svg[:i] + '<g class="labels">\n' + "\n".join(top) + "\n</g>\n" + svg[i:]


def _path(d):
    """The points of a Graphviz path (M then cubic pieces), each piece cut into 12 short segments."""
    nums = [float(x) for x in NUM.findall(d)]
    p = list(zip(nums[0::2], nums[1::2]))
    out, i = [p[0]], 1
    while i + 2 < len(p):
        p0, p1, p2, p3 = out[-1], p[i], p[i + 1], p[i + 2]
        for k in range(1, 13):
            t = k / 12.0
            a, b, c, e = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
            out.append((a * p0[0] + b * p1[0] + c * p2[0] + e * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + e * p3[1]))
        i += 3
    return out


def _orient(p, q, r):
    return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])


def _cross(a, b, c, d):
    return _orient(a, b, c) * _orient(a, b, d) < 0 and _orient(c, d, a) * _orient(c, d, b) < 0


def _near(p, q, r=9.0):
    return abs(p[0] - q[0]) < r and abs(p[1] - q[1]) < r


def _over(a, b, pad):
    return a[0] < b[2] - pad and b[0] < a[2] - pad and a[1] < b[3] - pad and b[1] < a[3] - pad


def _name(gid, title):
    """An arrow as the page names it: its event (from the id chartdot gave it) and its two ends."""
    ev = re.sub(r"^e\d+_", "", _plain(gid))
    return f"{ev} ({_plain(title)})"


def check(svg, narrow):
    """Every fault of one chart, one line each; an empty list is a pass."""
    bad = []
    edges = []
    for gid, body in EDGE.findall(svg):
        t = re.search(r"<title>([^<]*)</title>", body)
        d = re.search(r'<path[^>]* d="([^"]+)"', body)
        if not d:
            continue
        edges.append((_name(gid, t.group(1) if t else gid), _path(d.group(1))))
        if "<polygon" not in body:
            bad.append(f"the arrow {edges[-1][0]} has no arrowhead")
        if "<text" in body:
            bad.append(f"the label of {edges[-1][0]} is not on its plate in the top layer")
    for i in range(len(edges)):
        for j in range(i + 1, len(edges)):
            a, b = edges[i][1], edges[j][1]
            ends = [a[0], a[-1], b[0], b[-1]]
            for x in range(len(a) - 1):
                hit = False
                for y in range(len(b) - 1):
                    if _cross(a[x], a[x + 1], b[y], b[y + 1]):
                        mid = ((a[x][0] + a[x + 1][0]) / 2, (a[x][1] + a[x + 1][1]) / 2)
                        shared = any(_near(a[u], b[v]) for u in (0, -1) for v in (0, -1))
                        hit = not (shared and any(_near(mid, e, 14.0) for e in ends))
                    if hit:
                        break
                if hit:
                    bad.append(f"the arrows {edges[i][0]} and {edges[j][0]} cross")
                    break
    layer = re.search(r'<g class="labels">(.*)</g>\s*(?:</g>\s*)*</svg>', svg, re.S)
    labels = re.findall(r'<g class="label">(.*?)</g>', layer.group(1), re.S) if layer else []
    plates = []
    for body in labels:
        r = re.search(r'<rect class="plate[^"]*" x="(-?[\d.]+)" y="(-?[\d.]+)" width="([\d.]+)" height="([\d.]+)"/>', body)
        words = " ".join(_plain(t) for t in re.findall(r"<text[^>]*>([^<]*)</text>", body))
        if not r or not words:
            bad.append("a label has no plate")
            continue
        x, y, w, h = (float(v) for v in r.groups())
        plates.append((x, y, x + w, y + h, words))
    for i in range(len(plates)):
        for j in range(i + 1, len(plates)):
            if _over(plates[i], plates[j], 2.0):
                bad.append(f"the labels '{plates[i][4]}' and '{plates[j][4]}' overlap")
    nodes = []
    for g in re.findall(r'<g id="node\d+" class="node[^"]*">(.*?)</g>', svg, re.S):
        nums = [float(x) for x in NUM.findall(" ".join(re.findall(r'(?:points|d)="([^"]+)"', g)))]
        e = re.search(r'<ellipse[^>]* cx="(-?[\d.]+)" cy="(-?[\d.]+)" rx="([\d.]+)" ry="([\d.]+)"', g)
        if len(nums) >= 4:
            nodes.append((min(nums[0::2]), min(nums[1::2]), max(nums[0::2]), max(nums[1::2]), re.search(r"<title>([^<]*)</title>", g).group(1)))
        elif e:
            cx, cy, rx, ry = (float(v) for v in e.groups())
            nodes.append((cx - rx, cy - ry, cx + rx, cy + ry, re.search(r"<title>([^<]*)</title>", g).group(1)))
    for p in plates:
        for n in nodes:
            if _over(p, n, 1.5):
                bad.append(f"the label '{p[4]}' overlaps the state {_plain(n[4])}")
    w = re.search(r'<svg width="(\d+)pt"', svg)
    if narrow and w and int(w.group(1)) > NARROW_MAX:
        bad.append(f"the narrow layout is {w.group(1)} wide, over {NARROW_MAX}: its text would be under 9.5 px on a 390 px screen")
    return bad
