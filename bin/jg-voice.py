#!/usr/bin/env python3
"""jg-voice.py - check or rewrite a captain-facing message against the voice file.

The rules live in one markdown file the captain edits, never in this code:
  JG_VOICE_FILE, else <home>/config/captain-voice.md, else <root>/defaults/captain-voice.md.
It is read on every run, so an edit changes behaviour at once.
Its `## Settings` list holds `mode` (rewrite|warn|block|off, with `mode.<channel>`
overrides) and `max-sentence-words`; its `## Internal terms` table holds the banned
patterns and what to say instead (a cell starting with `?` is advice only).

  jg-voice.py check [--channel C] [--role R] [--line] [text...]   exit 1 when the text breaks a rule
  jg-voice.py apply [--channel C] [--role R] [--line] [text...]   print the text to send, as the mode says
  jg-voice.py persona [--role R]                       print the role's personality text

Each role (overwatch, squad-lead, worker) has one personality file beside the shared voice
file: JG_VOICE_ROLE_FILE, else <home>/config/captain-voice-<role>.md, else
<root>/defaults/captain-voice-<role>.md. The role is --role, else JG_VOICE_ROLE, else the send
point's (parent-channel is the squad lead's; telegram and chat-reply are the overwatch's, or the
squad lead's in a home that has a .jg-squad-lead-home marker). A role file adds tone only: only
its `## Personality` section is read, and every rule and setting still comes from the shared
file. Any other section or setting in a role file is ignored, reported on stderr, and makes
`check` exit 1, so a role file cannot weaken the shared rules. `persona` prints the personality
for the agent that writes the message; bin/jg-session-start.sh and bin/jg-brief.sh call it.

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


ROLES = ("overwatch", "squad-lead", "worker")
CHANNEL_ROLE = {"parent-channel": "squad-lead", "telegram": "overwatch", "chat-reply": "overwatch"}
PERSONA_MAX_LINES = 40


def home_root():
    return os.environ.get("JG_HOME") or os.path.dirname(HERE)


def find_file(override, name):
    config = os.environ.get("JG_CONFIG_OVERRIDE") or os.path.join(home_root(), "config")
    for p in (os.environ.get(override), os.path.join(config, name), os.path.join(HERE, "..", "defaults", name)):
        if p and os.path.isfile(p):
            return p
    return None


def voice_path():
    return find_file("JG_VOICE_FILE", "captain-voice.md")


def sender_role(channel, explicit):
    """The role whose personality applies: --role, else JG_VOICE_ROLE, else the send point's."""
    role = explicit or os.environ.get("JG_VOICE_ROLE") or ""
    if not role:
        role = CHANNEL_ROLE.get(channel, "overwatch")
        if role == "overwatch" and os.path.exists(os.path.join(home_root(), ".jg-squad-lead-home")):
            role = "squad-lead"
    return role


def load_role(role):
    """-> (path, personality text, ignored section names). Only `## Personality` is read, so a
    role file can add tone but can never reach the rules or settings, which load() takes from
    the shared file alone."""
    if role not in ROLES:
        return None, "", ["unknown role %r (use one of %s)" % (role, ", ".join(ROLES))]
    path = find_file("JG_VOICE_ROLE_FILE", "captain-voice-%s.md" % role)
    if not path:
        return None, "", []
    try:
        raw = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return None, "", []
    keep, ignored, section = [], [], ""
    for line in raw:
        if line.startswith("## "):
            section = line[3:].strip().lower()
            if section != "personality":
                ignored.append(line[3:].strip())
        elif section == "personality":
            keep.append(line)
    text = "\n".join(keep).strip()
    if len(text.splitlines()) > PERSONA_MAX_LINES:
        ignored.append("Personality is over %d lines; the rest is cut" % PERSONA_MAX_LINES)
        text = "\n".join(text.splitlines()[:PERSONA_MAX_LINES])
    return path, text, ignored


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


def report_role(role, path, ignored):
    for name in ignored:
        sys.stderr.write("voice: role file %s: %s ignored; a role file adds tone only\n" % (path or role, name))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("check", "apply", "persona"):
        sys.stderr.write(__doc__)
        return 2
    cmd, args, channel, line, role = argv[1], argv[2:], "", False, ""
    while args and args[0] in ("--channel", "--line", "--role"):
        if args[0] == "--line":
            line, args = True, args[1:]
        elif args[0] == "--role":
            role, args = (args[1] if len(args) > 1 else ""), args[2:]
        else:
            channel, args = (args[1] if len(args) > 1 else ""), args[2:]
    role = sender_role(channel, role)
    if cmd == "persona":
        path, persona, ignored = load_role(role)
        report_role(role, path, ignored)
        if persona:
            sys.stdout.write(persona + "\n")
        return 0
    text = " ".join(args) if args else sys.stdin.read()
    path = voice_path()
    try:
        settings, rules = load(path) if path else ({}, [])
    except OSError:
        settings, rules = {}, []
    mode = settings.get("mode." + channel, settings.get("mode", "rewrite"))
    role_path, _, role_ignored = load_role(role)
    report_role(role, role_path, role_ignored)
    if not rules and not settings or (mode == "off" and cmd == "apply"):
        sys.stdout.write(text)
        return 0
    head, note = split_status(text, line)
    fixed, findings = review(note, rules, settings.get("max-sentence-words"), cmd == "apply" and mode == "rewrite")
    for f in findings:
        sys.stderr.write("voice: %s: %s\n" % (channel or "message", f))
    if cmd == "check":
        return 1 if findings or role_ignored else 0
    if findings and mode == "block":
        sys.stderr.write("voice: not sent; rewrite it in plain words (rules: %s)\n" % path)
        return 1
    sys.stdout.write(head + fixed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
