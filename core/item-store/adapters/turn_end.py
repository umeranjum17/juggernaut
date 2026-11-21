#!/usr/bin/env python3
"""turn_end.py: the reply proof. A turn-end hook feeds it its payload JSON on stdin; it closes a `tell` (his note, which Main owes
a reply) done only when the turn that just ended answered it, so a reply is proved by the turn that held it, never by a guess.

  - It acts only in the locked primary session: the payload's session_id must equal the first line of
    <state>/.lock-session (the test `jg-inbox.sh primary-chat` uses). Any other session writes nothing.
  - A tell closes when (1) its note's text or its message id appears in the user entry that opened the turn that just ended,
    in the transcript the payload names (transcript_path), and (2) that turn's final assistant message is not empty. A payload
    with no readable transcript writes nothing: the tell stays open and climbs (late, never a false done).
  - The close is stamped adapter:chat, proof `sent:turn:<session>@<turn end>`, source `turn:<session>@<turn end>`; the line
    `<source>\\t<tell key>` is appended to <store dir>/turn-sent.log first, which logs/adapter-chat hands to the stamp check.
  - A note queued behind a running turn is not in that turn's opening message, so that turn does not prove it; nothing is
    kept between turns but the store.
Never blocking and never noisy: any failure ends in exit 0 with no output (the hook calls it with `|| true`)."""
import json, os, re, sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import itemdb  # noqa: E402


def text_of(entry):
    """The words of one transcript entry; tool results and tool calls carry none."""
    m = entry.get("message") if isinstance(entry.get("message"), dict) else entry
    c = m.get("content", m.get("text"))
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x if isinstance(x, str) else (x.get("text") or "") for x in c
                         if isinstance(x, str) or (isinstance(x, dict) and x.get("type") in (None, "text", "input_text", "output_text")))
    return ""


def role_of(entry):
    m = entry.get("message") if isinstance(entry.get("message"), dict) else {}
    r = entry.get("role") or m.get("role") or entry.get("type")
    return {"human": "user"}.get(r, r)


def last_turn(path):
    """(user text that opened the last turn, final assistant message, its timestamp or line number), or None."""
    entries = []
    for i, ln in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if isinstance(e, dict):
            entries.append((i, e))
    start = None
    for n, (_, e) in enumerate(entries):
        if role_of(e) == "user" and text_of(e).strip():
            start = n
    if start is None:
        return None
    final = None
    for i, e in entries[start + 1:]:
        if role_of(e) == "assistant" and text_of(e).strip():
            final = (text_of(e), str(e.get("timestamp") or "line%d" % i))
    if final is None:
        return None
    return text_of(entries[start][1]), final[0], final[1]


def norm(s):
    return " ".join(s.split())


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        sid, path = str(payload.get("session_id") or ""), payload.get("transcript_path")
        home = os.environ.get("JG_HOME")
        if not (sid and path and home and os.path.isdir(home)):
            return
        state = os.environ.get("JG_STATE_OVERRIDE") or os.path.join(home, "state")
        lock = os.path.join(state, ".lock-session")
        if os.path.islink(lock) or not os.path.isfile(lock):
            return
        with open(lock, encoding="utf-8") as fh:
            if fh.readline().strip() != sid:
                return
        turn = last_turn(path)
        if not turn:
            return
        user, _, end = turn
        hid = itemdb.home_id(home)
        st = itemdb.open_db(home, "adapter:chat")
        shown = norm(user)
        sent = []
        for key, owes in st.con.execute("SELECT key, owes FROM item WHERE kind='tell' AND state='open' AND home=?", (hid,)).fetchall():
            mid = key[len("tell:%s/" % hid):]
            words = norm(owes)[:160]
            if mid in user or (words and words in shown):
                sent.append(key)
        if not sent:
            return
        source = "turn:%s@%s" % (sid, end)
        d = itemdb.store_dir(home)
        with open(os.path.join(d, "turn-sent.log"), "a", encoding="utf-8") as fh:
            fh.write("".join("%s\t%s\n" % (source, k) for k in sent))
        at = itemdb.stamp(st)
        for key in sent:
            st.close(at, key, "done", "sent:turn:%s@%s" % (sid, end), st.me, source=source)
    except Exception:
        return


if __name__ == "__main__":
    main()
