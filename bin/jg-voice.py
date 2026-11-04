#!/usr/bin/env python3
"""jg-voice.py - check or rewrite a captain-facing message against the voice file.

The rules live in one markdown file the captain edits, never in this code:
  JG_VOICE_FILE, else <home>/config/captain-voice.md, else <root>/defaults/captain-voice.md.
It is read on every run, so an edit changes behaviour at once.
Its `## Settings` list holds `mode` (rewrite|warn|block|off, with `mode.<channel>`
overrides) and `max-sentence-words`; its `## Internal terms` table holds the banned
patterns and what to say instead (a cell starting with `?` is advice only).

  jg-voice.py check [--channel C] [--line] [text...]   exit 1 when the text breaks a rule
  jg-voice.py apply [--channel C] [--line] [text...]   print the text to send, as the mode says

The text comes from the arguments, else stdin. `apply` exits 1 with nothing on stdout only
when the mode is `block` and the text breaks a rule; findings go to stderr. A missing or
unreadable voice file steps aside: the text passes unchanged. `--line` treats the text as a
status line (`verb [key=..]: note`) and only checks the note after the first colon.
Send points: bin/jg-voice-lib.sh (chat reply, parent channel) and the Telegram send in core/bus.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# What a rewrite must never touch: code spans, URLs, [..=..] tags and key=value tokens.
PROTECTED = re.compile(r"(`[^`\n]*`|\S+://\S+|\[[^\]\n]*=[^\]\n]*\]|[\w.-]+=\S+)")
STATUS_LINE = re.compile(r"^([A-Za-z-]+(?: \[[^\]\n]*\])*:)(.*)$", re.S)


def voice_path():
    root = os.environ.get("JG_HOME") or os.path.dirname(HERE)
    for p in (os.environ.get("JG_VOICE_FILE"), os.path.join(os.environ.get("JG_CONFIG_OVERRIDE") or os.path.join(root, "config"), "captain-voice.md"), os.path.join(HERE, "..", "defaults", "captain-voice.md")):
        if p and os.path.isfile(p):
            return p
    return None


def load(path):
    """-> (settings, rules); a rule is (compiled regex, replacement or None, advice)."""
    settings, rules, section = {}, [], ""
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if line.startswith("## "):
            section = line[3:].strip().lower()
        elif section == "settings":
            m = re.match(r"^- ([\w.-]+): (.+)$", line)
            if m:
                settings[m.group(1)] = m.group(2).strip().strip("`")
        elif section == "internal terms" and line.startswith("|"):
            cells = [c.replace("\\|", "|").strip() for c in re.split(r"(?<!\\)\|", line)[1:-1]]
            if len(cells) != 2 or cells[0].lower() == "pattern" or set(cells[0]) <= set("-: "):
                continue
            try:
                rx = re.compile(cells[0].strip("`"), re.I)
            except re.error as e:
                sys.stderr.write("voice: skipping bad pattern %s (%s)\n" % (cells[0], e))
                continue
            say = cells[1]
            rules.append((rx, None, say[1:].strip()) if say.startswith("?") else (rx, say, say))
    return settings, rules


def split_status(text, line):
    m = STATUS_LINE.match(text) if line else None
    return (m.group(1), m.group(2)) if m else ("", text)


def plain_segments(text):
    """Yield (is_plain, piece) so patterns only ever see unprotected text."""
    pos = 0
    for m in PROTECTED.finditer(text):
        yield True, text[pos:m.start()]
        yield False, m.group(0)
        pos = m.end()
    yield True, text[pos:]


def review(text, rules, max_words, fix):
    """-> (text with plain replacements when fix, findings). Rows run in order and the first
    row to claim a stretch of text keeps it, so an advice-only phrase is never half-rewritten."""
    findings, out = [], []
    for is_plain, piece in plain_segments(text):
        claims = []
        for rx, rep, advice in rules if is_plain else ():
            for m in rx.finditer(piece):
                if m.end() > m.start() and not any(m.start() < e and s < m.end() for s, e, *_ in claims):
                    claims.append((m.start(), m.end(), rep, advice))
        pos = 0
        for s, e, rep, advice in sorted(claims):
            findings.append('"%s" - %s' % (piece[s:e], ("say: " + advice) if rep is not None else advice))
            if fix and rep is not None:
                out.append(piece[pos:s] + (rep[:1].upper() + rep[1:] if piece[s].isupper() else rep))
                pos = e
        out.append(piece[pos:])
    result = "".join(out)
    if max_words:
        for s in re.split(r"(?<=[.!?])\s+|\n+", PROTECTED.sub(lambda m: "x" if "://" in m.group(0) else m.group(0), text)):
            if len(s.split()) > int(max_words):
                findings.append('sentence of %d words (limit %s): "%s..."' % (len(s.split()), max_words, " ".join(s.split()[:6])))
    return result, findings


def main(argv):
    if len(argv) < 2 or argv[1] not in ("check", "apply"):
        sys.stderr.write(__doc__)
        return 2
    cmd, args, channel, line = argv[1], argv[2:], "", False
    while args and args[0] in ("--channel", "--line"):
        if args[0] == "--line":
            line, args = True, args[1:]
        else:
            channel, args = (args[1] if len(args) > 1 else ""), args[2:]
    text = " ".join(args) if args else sys.stdin.read()
    path = voice_path()
    try:
        settings, rules = load(path) if path else ({}, [])
    except OSError:
        settings, rules = {}, []
    mode = settings.get("mode." + channel, settings.get("mode", "rewrite"))
    if not rules and not settings or (mode == "off" and cmd == "apply"):
        sys.stdout.write(text)
        return 0
    head, note = split_status(text, line)
    fixed, findings = review(note, rules, settings.get("max-sentence-words"), cmd == "apply" and mode == "rewrite")
    for f in findings:
        sys.stderr.write("voice: %s: %s\n" % (channel or "message", f))
    if cmd == "check":
        return 1 if findings else 0
    if findings and mode == "block":
        sys.stderr.write("voice: not sent; rewrite it in plain words (rules: %s)\n" % path)
        return 1
    sys.stdout.write(head + fixed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
