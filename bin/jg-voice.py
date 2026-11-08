#!/usr/bin/env python3
"""jg-voice.py - check or rewrite a captain-facing message against the voice file.

The rules live in one markdown file the captain edits, never in this code:
  JG_VOICE_FILE, else <home>/config/captain-voice.md, else <root>/defaults/captain-voice.md.
It is read on every run, so an edit changes behaviour at once.
Its `## Settings` list holds `mode` (rewrite|warn|block|off, with `mode.<channel>`
overrides) and `max-sentence-words`; its `## Internal terms` table holds the banned
patterns and the plain wording to use instead. The wording is guidance for a rewrite, never a
swap: a word swapped into a sentence breaks the sentence ("its whether it can merge").

  jg-voice.py check [--channel C] [--role R] [--line] [--ask WORDS --ask-date D] [text...]
  jg-voice.py apply [same options]   print the text to send, as the mode says; exit 1 when it is refused
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

The text comes from the arguments, else stdin. A text with no banned term passes unchanged, except
for its layout: `apply` puts every list item on its own line and a blank line between a list and
the prose around it, and a rewrite that runs list items together is refused (not with `--line`).
In mode `rewrite`, `apply` asks a model to rewrite the whole text in plain sentences, checks the
result again, and prints it only when no banned term remains and every URL, code span and
key=value token survived. The rewrite command is JG_VOICE_REWRITE_CMD, else the first line of
<home>/config/voice-rewrite-command, else `claude -p` on Haiku; it reads the request on stdin and
prints the new text. In mode `block`, or when the rewrite is missing, fails, times out or still
holds a banned term, `apply` exits 1 with nothing on stdout and a re-draft instruction on
stderr: a banned term is never sent and a half-swapped sentence is never printed. Findings go to
stderr. A missing or unreadable voice file steps aside: the text passes unchanged. `--line`
treats the text as a status line (`verb [key=..]: note`) and only checks the note after the
first colon.
A PR number the same text also links in full (`pull/678`) is not flagged, so `revert-pr678` beside
its URL passes; the same id with no link, or a link to another PR, is still refused.

A reply or report that answers an ask carries an ask block: a `Your ask:` line that quotes his
words and their date, then `Done:`, `Not done:` and `Next:` lines, and a proof link (2026-11-05:
"There is no reference: what was my ask and what work was done against it"). The check is
structural and deterministic, never a model call: a model rewrite cannot invent his words. With
`--ask <his words> --ask-date <YYYY-MM-DD>`, a message longer than a pure acknowledgement must
carry the whole block and its quote must be his words; without them, a message that carries a
`Your ask:` line must still complete the block, so a half-written one is refused at every send
point. A pure acknowledgement (short, no proof link, no outcome line) answers no ask and passes.
Send points: bin/jg-voice-lib.sh (chat reply, parent channel) and the Telegram send in core/bus;
bin/jg-inbox.sh reply passes the note it answers as the ask.
"""
import os
import re
import shlex
import subprocess
import sys
import tempfile

import jg_voice_records as records

HERE = os.path.dirname(os.path.abspath(__file__))
# What a rewrite must never touch: code spans, URLs, [..=..] tags and key=value tokens.
PROTECTED = re.compile(r"(`[^`\n]*`|\S+://\S+|\[[^\]\n]*=[^\]\n]*\]|[\w.-]+=\S+)")
# A PR number the message also links in full (`.../pull/678`) is a ticket id beside its link, not a bare number.
PR_LINK = re.compile(r"\S+://\S+/pull/(\d+)")
PR_NUMBER = re.compile(r"(?:pr|pull request)[\s#-]*(\d+)", re.I)
STATUS_LINE = re.compile(r"^([A-Za-z-]+(?: \[[^\]\n]*\])*:)(.*)$", re.S)
# The ask block: his words and their date, then Done / Not done / Next, then a proof link.
ASK_LINE = re.compile(r"^[ \t]*(?:[-*][ \t]+)?\*{0,2}your ask\*{0,2}[ \t]*:(.*)$", re.I | re.M)
ASK_OUTCOME = (("done", "Done"), ("not done", "Not done"), ("next", "Next"))
PROOF_LINK = re.compile(r"https?://\S+")
DATE_ISO = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
DATE_WORD = re.compile(r"\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)", re.I)
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
ACK_MAX_WORDS = 25
WORD_STOP = {"that", "this", "with", "from", "have", "your", "will", "what", "when", "then",
             "them", "they", "their", "there", "here", "also", "into", "than", "just", "only",
             "more", "most", "some", "such", "about", "after", "before", "been", "being",
             "does", "did", "each", "because", "please", "very", "much", "make", "made"}
# A list item line (`1. x`, `2) x`, `- x`, `* x`, a bullet), and a numbered marker inside a line of prose.
ITEM = re.compile(r"^\s*(?:\d{1,3}[.)]|[-*\u2022])\s+\S")
INLINE_MARK = re.compile(r"(?:(?<=\s)|^)(\d{1,2})[.)]\s+(?=\S)")


ROLES = ("overwatch", "squad-lead", "worker")
CHANNEL_ROLE = {"parent-channel": "squad-lead", "telegram": "overwatch", "chat-reply": "overwatch"}
PERSONA_MAX_LINES = 40
DEFAULT_REWRITE = ("claude -p --model claude-haiku-5-5 --tools '' --no-session-persistence "
                   "--disable-slash-commands --setting-sources project")
REWRITE_SECONDS = 45


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
    """-> (settings, rules); a rule is (compiled regex, the plain wording to use instead)."""
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
            rules.append((rx, cells[1].lstrip("?").strip()))
    return settings, rules


def content_words(text):
    """Lowercase words of four letters or more, minus the short stopword list. A quote is made of
    these, so a paraphrase in new words cannot pass as his words."""
    return [w for w in re.findall(r"[a-z0-9][a-z0-9'-]*", text.lower())
            if len(w) >= 4 and w not in WORD_STOP]


def outcome_line(name):
    return re.compile(r"^[ \t]*(?:[-*][ \t]+)?\*{0,2}" + name + r"\*{0,2}[ \t]*:", re.I | re.M)


def quote_is_his_words(line, ask_words):
    """Two content words or more, and 60% of them occur in the ask. A verbatim quote passes; a
    paraphrase in the writer's own words does not. A tiny ask ("x") cannot be quoted, so any
    words stand in for it."""
    quoted, asked = content_words(line), set(content_words(ask_words))
    if not ask_words or len(asked) < 2:
        return bool(line.strip())
    if len(quoted) < 2:
        return False
    return sum(1 for w in quoted if w in asked) * 100 >= 60 * len(quoted)


def date_forms(iso):
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", iso or "")
    if not m:
        return [iso] if iso else []
    y, mo, d = m.group(1), int(m.group(2)), int(m.group(3))
    mon = MONTHS[mo - 1]
    return ["%s-%02d-%02d" % (y, mo, d), "%d %s" % (d, mon), "%02d %s" % (d, mon), "%s %d" % (mon, d)]


def carries_date(line, ask_date):
    forms = date_forms(ask_date)
    if forms:
        return any(f.lower() in line.lower() for f in forms)
    return bool(DATE_ISO.search(line) or DATE_WORD.search(line))


def ask_report_findings(text, ask_words, ask_date):
    """-> findings for the ask block. A pure acknowledgement (short, no proof link, no outcome
    line) answers no ask and passes, so the standing "Captain, standing by." still goes out."""
    m = ASK_LINE.search(text)
    if not m:
        if not ask_words:
            return []
        if (len(text.split()) <= ACK_MAX_WORDS and not PROOF_LINK.search(text)
                and not any(outcome_line(n).search(text) for n, _ in ASK_OUTCOME)):
            return []
        return ["it answers the captain's ask but carries no 'Your ask:' line with his words and date"]
    line = m.group(1).strip()
    out = []
    if not carries_date(line, ask_date):
        out.append("its 'Your ask:' line carries no date (%s)" % (ask_date or "YYYY-MM-DD"))
    if not quote_is_his_words(line, ask_words):
        out.append("its 'Your ask:' line does not quote his words")
    for name, shown in ASK_OUTCOME:
        if not outcome_line(name).search(text):
            out.append("it has no '%s:' line" % shown)
    if not PROOF_LINK.search(text):
        out.append("it carries no proof link (https://...)")
    return out


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


def review(text, rules, max_words):
    """-> (term findings, length findings). The first row to claim a stretch of text keeps it."""
    terms, lengths = [], []
    linked = set(PR_LINK.findall(text))
    for is_plain, piece in plain_segments(text):
        claims = []
        for rx, say in rules if is_plain else ():
            for m in rx.finditer(piece):
                if m.end() > m.start() and not any(m.start() < e and s < m.end() for s, e, _ in claims):
                    claims.append((m.start(), m.end(), say))
        for s, e, say in sorted(claims):
            ref = PR_NUMBER.fullmatch(piece[s:e])
            if not (ref and ref.group(1) in linked):
                terms.append('"%s" - plain wording: %s' % (piece[s:e], say))
    if max_words:
        for s in re.split(r"(?<=[.!?])\s+|\n+", PROTECTED.sub(lambda m: "x" if "://" in m.group(0) else m.group(0), text)):
            if len(s.split()) > int(max_words):
                lengths.append('sentence of %d words (limit %s): "%s..."' % (len(s.split()), max_words, " ".join(s.split()[:6])))
    return terms, lengths


def split_inline_list(line):
    """'Two things: 1. A 2. B' -> ['Two things:', '1. A', '2. B']. Only a run that counts up from 1 with words in each item splits."""
    marks, want = [], 1
    for m in INLINE_MARK.finditer(line):
        if int(m.group(1)) == want:
            marks.append(m)
            want += 1
    if len(marks) < 2:
        return [line]
    bounds = [m.start() for m in marks] + [len(line)]
    items = [line[bounds[i]:bounds[i + 1]].strip() for i in range(len(marks))]
    if not all(re.search(r"[^\W\d_]", re.sub(r"^\d+[.)]\s*", "", item)) for item in items):
        return [line]
    lead = line[:bounds[0]].rstrip()
    return ([lead] if lead else []) + items


def layout(text):
    """The text with its list one item per line and a blank line between blocks (prose and list).

    A list a writer or the rewrite model ran into one line is split; a fenced code block and the
    lines of an item's continuation stay as written. Text with no list comes back unchanged.
    """
    lines, fenced = [], False
    for raw in text.replace("\r\n", "\n").split("\n"):
        if raw.lstrip().startswith("```"):
            fenced = not fenced
            lines.append(raw)
        else:
            lines.extend([raw] if fenced else split_inline_list(raw))
    out, kind, fenced = [], "blank", False
    for line in lines:
        if line.lstrip().startswith("```") or fenced:
            fenced = fenced != line.lstrip().startswith("```")
            out.append(line)
            kind = "blank"
            continue
        if not line.strip():
            now = "blank"
        elif ITEM.match(line):
            now = "item"
        elif line[0].isspace() and kind == "item":
            now = "item"
        else:
            now = "prose"
        if (kind, now) in (("prose", "item"), ("item", "prose")):
            out.append("")
        out.append(line)
        kind = now
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out))


def rewrite_command():
    cmd = os.environ.get("JG_VOICE_REWRITE_CMD")
    if cmd is None:
        config = os.environ.get("JG_CONFIG_OVERRIDE") or os.path.join(home_root(), "config")
        try:
            cmd = open(os.path.join(config, "voice-rewrite-command"), encoding="utf-8").readline().strip()
        except OSError:
            cmd = ""
    if cmd:
        return shlex.split(cmd)
    # No command of the captain's own: the default command, with the model an entry tagged voice-rewrite in
    # config/tool-models.json names (harness claude). No entry keeps today's model.
    model = records.tool_model(home_root(), "voice-rewrite", "claude")
    return shlex.split(DEFAULT_REWRITE.replace("claude-haiku-5-5", model, 1) if model else DEFAULT_REWRITE)


def rewrite_request(rules_text, text, findings):
    return (
        "Rewrite the message below for the captain, a busy reader who wants plain words.\n"
        "Write whole, natural sentences that say the same thing. Never swap one word for another inside a sentence;\n"
        "recast the sentence so it reads right. Put the outcome first. Do not add facts. Do not use any banned term.\n"
        "Copy every URL, `code span`, [tag=value] and key=value token exactly as written.\n"
        "Keep the layout: every list item stays on its own line, in the same order, and a blank line stays between blocks.\n"
        "Print only the new message: no preface, no quotes, no notes.\n\n"
        "Voice rules:\n%s\n\nTerms found in the message, each with a plain idea to say instead (express the idea; never paste the words into the sentence):\n- %s\n\n"
        "Message:\n%s\n" % (rules_text, "\n- ".join(findings), text))


def ask_model(request):
    """-> (rewritten text or None, why not)."""
    try:
        cmd = rewrite_command()
        secs = float(os.environ.get("JG_VOICE_REWRITE_TIMEOUT") or REWRITE_SECONDS)
        # Run from an empty directory so the model reads no project instructions and fires no project hooks.
        with tempfile.TemporaryDirectory() as cwd:
            run = subprocess.run(cmd, input=request, capture_output=True, text=True, timeout=secs, cwd=cwd)
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        return None, "the rewrite step did not run (%s)" % (e.__class__.__name__ if isinstance(e, subprocess.TimeoutExpired) else e)
    out = run.stdout.strip()
    if run.returncode != 0 or not out:
        return None, "the rewrite step failed (exit %d)" % run.returncode
    return out, ""


def rewritten(text, rules, rules_text):
    """-> (plain text, why not): the model's rewrite of the whole text, only if it re-checks clean."""
    terms, _ = review(text, rules, None)
    out, why = ask_model(rewrite_request(rules_text, text, terms))
    if out is None:
        return None, why
    out = layout(out)
    again, _ = review(out, rules, None)
    if again:
        return None, "the rewrite still holds a banned term: " + "; ".join(again)
    lost = [m.group(0) for m in PROTECTED.finditer(text) if m.group(0).strip("(),:;.") not in out]
    if lost:
        return None, "the rewrite lost %s" % ", ".join(lost)
    items, kept = sum(bool(ITEM.match(l)) for l in text.split("\n")), sum(bool(ITEM.match(l)) for l in out.split("\n"))
    if kept < items:
        return None, "the rewrite turned a list of %d items into %d; keep one item per line" % (items, kept)
    return out, ""


def report_role(role, path, ignored):
    for name in ignored:
        sys.stderr.write("voice: role file %s: %s ignored; a role file adds tone only\n" % (path or role, name))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("check", "apply", "persona"):
        sys.stderr.write(__doc__)
        return 2
    cmd, args, channel, line, role = argv[1], argv[2:], "", False, ""
    ask_words, ask_date = "", ""
    while args and args[0] in ("--channel", "--line", "--role", "--ask", "--ask-date"):
        if args[0] == "--line":
            line, args = True, args[1:]
        elif args[0] == "--role":
            role, args = (args[1] if len(args) > 1 else ""), args[2:]
        elif args[0] == "--ask":
            ask_words, args = (args[1] if len(args) > 1 else ""), args[2:]
        elif args[0] == "--ask-date":
            ask_date, args = (args[1] if len(args) > 1 else ""), args[2:]
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
    # The ask block is structure, not wording: a model rewrite cannot invent his words, so a
    # message that breaks it is refused as it stands. In mode `warn` it is reported and sent.
    findings = ask_report_findings(text, ask_words, ask_date)
    for f in findings:
        sys.stderr.write("voice: %s: %s\n" % (channel or "message", f))
    if findings:
        if cmd == "check":
            return 1
        if mode == "warn":
            sys.stdout.write(text)
            return 0
        sys.stderr.write(
            "voice: not sent. Re-draft it with an ask block: a 'Your ask:' line that quotes his words\n"
            "and carries their date, then 'Done:', 'Not done:' and 'Next:' lines, and a proof link.\n"
            "(rules: %s)\n" % (path or "the voice file"))
        return 1
    if not line:
        text = layout(text)
    head, note = split_status(text, line)
    terms, lengths = review(note, rules, settings.get("max-sentence-words"))
    for f in terms + lengths:
        sys.stderr.write("voice: %s: %s\n" % (channel or "message", f))
    if cmd == "check":
        return 1 if terms or lengths or role_ignored else 0
    if not terms or mode == "warn":
        sys.stdout.write(text)
        return 0
    fixed, why = (None, "mode is block") if mode == "block" else rewritten(note, rules, open(path, encoding="utf-8").read())
    if fixed is None:
        sys.stderr.write("voice: not sent (%s). Re-draft it yourself in whole plain sentences, then send it again (rules: %s)\n" % (why, path))
        return 1
    sys.stdout.write(head + note[:len(note) - len(note.lstrip())] + fixed + note[len(note.rstrip()):])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
