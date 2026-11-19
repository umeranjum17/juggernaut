#!/usr/bin/env python3
"""chat_bridge.py: the owner's chat beside the bus (docs/item-store.md). The bus still sends; this bridge reads the store's
`owner` pages, records what it WOULD send, compares that with what the captain channel did send, and writes his messages as
items. It sends nothing. Run on Main's home, behind `config/chat-store` (chat-wiring.sh registers the check). Exit: 0 ok,
2 usage or a refusal to open the store.

  would-send
      Reads `pages owner` from the reader's cursor (this bridge is the one reader of it), appends one line per listed item,
      `<seq>\\t<item key>\\t<the text it would send>`, to <store dir>/chat-would-send.log, then acks the count line's ack=.
      A second call lists nothing new. A turn summary, a reply and a voice message are not items and have no page.
  compare [--now <epoch>]
      Reads the captain channel's own record, $STATE/captain-channel.jsonl (core/bus/cmd/jg-bus: one JSON event per line,
      appended before anything is published) from its own byte cursor (<store dir>/chat-compare.json). It opens one
      `intake:main/chat-<item key>` item on Main (source `chat-compare:<item key>`) for
        - a would-send line, 15 minutes old, that no channel event names (the item key, or its subject, the ticket id, in
          the event's key, subject or text, within 15 minutes of the page), and
        - an owner-bound channel event (kind card, alert or blocker: a decision waiting, an alert, a blocker), 15 minutes
          old, that no would-send line names within 15 minutes.
      Other kinds (summary, outcome, digest, card-close, a reply) are not items and are never compared. The same compare run
      twice opens nothing more. --now sets the clock (tests only).
  received --message-id <id> --text <t> [--key <question key> --pick <p>]
      His message: `owner.py answer` (closes the question) when --key and --pick are given, else `owner.py tell`; both write
      through itemdb.or_intake, so a refused write is listed on Main's board.

The bridge opens the store as adapter:chat. The intake items it files are stamped adapter:intake, as owner.py's are, because
the stamp check reads every adapter:chat move against the sent record of turn_end.py and a comparison is not a sent message."""
import argparse, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
ITEM = os.path.dirname(HERE)
sys.path.insert(0, ITEM)
import itemdb  # noqa: E402

READER = "owner"
WINDOW = 900                                   # 15 minutes: a page and its channel event belong together inside it
OWNER_KINDS = ("card", "alert", "blocker")     # the channel events that are an owner decision waiting, an alert or a blocker


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def jg_home():
    h = os.environ.get("JG_HOME")
    if not h or not os.path.isdir(h):
        die("refused: JG_HOME must name this home's directory")
    return os.path.realpath(h)


def opened(home):
    try:
        return itemdb.open_db(home, "adapter:chat"), itemdb.store_dir(home)
    except Exception as e:
        die("refused: cannot open the store: %s" % e)


def one_line(text):
    return " ".join(str(text).split())


# ------------------------------------------------------------------ would-send

def cmd_would_send(a):
    home = jg_home()
    st, d = opened(home)
    lines, last = st.pages(READER)
    rows = []
    for ln in lines[:-1]:                      # the last line is the count line: pages: ... ack=<seq>
        f = ln.split("\t")
        rows.append("%s\t%s\t%s" % (f[0], f[1], f[-1]))
    if rows:
        with open(os.path.join(d, "chat-would-send.log"), "a", encoding="utf-8") as fh:
            fh.write("\n".join(rows) + "\n")
    st.ack(READER, last)
    print("would-send: %d listed" % len(rows))


# ------------------------------------------------------------------ compare

def state_path(d):
    return os.path.join(d, "chat-compare.json")


def load_state(d):
    try:
        s = json.load(open(state_path(d), encoding="utf-8"))
        return dict(bytes=int(s["bytes"]), lines=int(s["lines"]), events=list(s["events"]))
    except (OSError, ValueError, KeyError, TypeError):
        return dict(bytes=0, lines=0, events=[])


def save_state(d, s):
    tmp = state_path(d) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(s, fh)
    os.replace(tmp, state_path(d))


def read_new_events(path, start):
    """(owner-bound events from byte `start`, the byte offset after the last whole line). A half-written last line waits."""
    try:
        with open(path, "rb") as fh:
            fh.seek(start)
            raw = fh.read()
    except OSError:
        return [], start
    end = start + raw.rfind(b"\n") + 1 if b"\n" in raw else start
    out = []
    for ln in raw[:max(end - start, 0)].decode("utf-8", "replace").splitlines():
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("kind") in OWNER_KINDS and isinstance(e.get("at"), int):
            out.append({k: e.get(k, "") for k in ("at", "kind", "key", "subject", "text")})
    return out, end


def would_lines(st, d):
    """(seq, item key, ticket subject, page time, text) of each would-send line."""
    out = []
    try:
        raw = open(os.path.join(d, "chat-would-send.log"), encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for ln in raw:
        f = ln.split("\t", 2)
        if len(f) < 3 or not f[0].isdigit():
            continue
        at = st.one("SELECT at FROM move WHERE seq=?", (int(f[0]),)) or 0
        out.append((int(f[0]), f[1], st.one("SELECT subject FROM item WHERE key=? ORDER BY gen DESC LIMIT 1", (f[1],)) or "", at, f[2]))
    return out


def names(event, word):
    """Does the event name this word (an item key or a ticket id) in its key, subject or text, as a whole token."""
    if not word:
        return False
    hay = " ".join(str(event.get(k, "")) for k in ("key", "subject", "text"))
    return re.search(r"(?<![A-Za-z0-9._-])%s(?![A-Za-z0-9._-])" % re.escape(word), hay) is not None


def pair(w, e):
    return abs(w[3] - e["at"]) <= WINDOW and (names(e, w[1]) or names(e, w[2]))


def file_intake(st, at, key, subject, owes):
    st = st.as_("adapter:intake")
    return itemdb.or_intake(st, at, "chat-compare:" + key, "main", subject, st.open, at, "intake:main/chat-" + key, "intake",
                            "main", subject, owes, st.me)


def cmd_compare(a):
    home = jg_home()
    st, d = opened(home)
    now = a.now if a.now is not None else int(time.time())
    s = load_state(d)
    new, s["bytes"] = read_new_events(os.path.join(itemdb.main_home(home), "state", "captain-channel.jsonl"), s["bytes"])
    s["events"] += new
    ws = would_lines(st, d)
    at = itemdb.stamp(st)
    filed = 0
    while s["lines"] < len(ws):                # would-send lines in order: judged when a channel event names it, or at 15 minutes
        w = ws[s["lines"]]
        if any(pair(w, e) for e in s["events"]):
            s["lines"] += 1
            continue
        if now - w[3] < WINDOW:
            break
        filed += file_intake(st, at, w[1], w[2] or "owner", "the owner's page %s (%s) has no captain channel message within 15 minutes: %s" % (w[0], w[1], w[4][:120])) == "open"
        s["lines"] += 1
    keep = []
    for e in s["events"]:
        hit = [i for i, w in enumerate(ws) if pair(w, e)]
        if hit:                                # a would-send line names it; it stays until each such line is judged
            if max(hit) >= s["lines"]:
                keep.append(e)
            continue
        if now - e["at"] < WINDOW:
            keep.append(e)                     # its page may still come
            continue
        k = e["key"] or "%s@%d" % (e["kind"], e["at"])
        filed += file_intake(st, at, k, e["subject"] or "owner", "the captain channel sent %s %s with no owner page in the store within 15 minutes: %s" % (e["kind"], k, one_line(e["text"])[:120])) == "open"
    s["events"] = keep
    save_state(d, s)
    print("compare: %d intake items opened" % filed)


# ------------------------------------------------------------------ received

def cmd_received(a):
    home = jg_home()
    if bool(a.key) != bool(a.pick):
        die("received: --key and --pick go together")
    owner = os.path.join(HERE, "owner.py")
    if a.key:
        cmd = [sys.executable, "-I", owner, "answer", "--channel", "chat", "--message-id", a.message_id, "--key", a.key, "--pick", a.pick]
    else:
        cmd = [sys.executable, "-I", owner, "tell", "--channel", "chat", "--message-id", a.message_id, "--subject", "-", "--text", a.text]
    r = subprocess.run(cmd, env=dict(os.environ, JG_HOME=home), capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)


def main(argv):
    p = argparse.ArgumentParser(prog="chat_bridge.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("would-send").set_defaults(fn=cmd_would_send)
    c = sp.add_parser("compare")
    c.add_argument("--now", type=int, default=None)
    c.set_defaults(fn=cmd_compare)
    r = sp.add_parser("received")
    r.add_argument("--message-id", required=True)
    r.add_argument("--text", default="")
    r.add_argument("--key")
    r.add_argument("--pick")
    r.set_defaults(fn=cmd_received)
    a = p.parse_args(argv)
    try:
        a.fn(a)
    except itemdb.Unbound as e:
        die("refused: %s" % e)


if __name__ == "__main__":
    main(sys.argv[1:])
