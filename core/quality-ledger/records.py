"""Readers for the three durable records the quality ledger measures.

Each reader loads one record of a home, bounded by the window, and returns plain
tuples. None of them writes anything, and none of them knows what a measure is.
A record that is absent returns None, so the report can say which record is missing.
"""
import glob
import json
import os
import re
from datetime import datetime, timezone

STATUS_WORD = re.compile(r'^\s*([a-z-]+)(?: \[[^\]]*\])*:')
# A launch brief names its task in an H1 section called Task (a suffix after " - " is ignored).
H1 = re.compile(r'(?m)^# ')


def parse_time(text):
    """Seconds since the epoch from plain digits or an ISO 8601 time; ValueError when neither."""
    text = text.strip()
    if text.isdigit():
        return int(text)
    moment = datetime.fromisoformat(text.replace('Z', '+00:00'))
    if moment.tzinfo is None:
        raise ValueError(f'{text!r} has no time zone (write it as ...Z)')
    return int(moment.timestamp())


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def status_word(text):
    """The state word a status line opens with, or '?' when it has none."""
    match = STATUS_WORD.match(text)
    return match.group(1) if match else '?'


def load_chat(path, until):
    """(rows, unreadable) of state/chat.jsonl up to `until`, or None when the file is absent.

    A row is a dict with at (int), kind, sender, to and text. The log is read once,
    line by line; a line that is not a JSON object with a numeric `at` is counted, not fatal.
    """
    if not os.path.isfile(path):
        return None
    rows, unreadable = [], 0
    with open(path, errors='replace') as log:
        for line in log:
            try:
                raw = json.loads(line)
                at = int(raw['at'])
            except (ValueError, KeyError, TypeError):
                unreadable += 1
                continue
            if at <= until:
                rows.append({'at': at, 'kind': raw.get('kind'), 'sender': raw.get('from') or '',
                             'to': raw.get('to') or '', 'text': raw.get('text') or ''})
    return rows, unreadable


def load_first_checks(path, since, until):
    """The first proof check of each target inside the window, as {target: (result, detail)}.

    data/checks-gate.log holds one tab-separated row per check: time, target, head, result, detail.
    Returns None when the file is absent.
    """
    if not os.path.isfile(path):
        return None
    first = {}
    with open(path, errors='replace') as log:
        for line in log:
            fields = line.rstrip('\n').split('\t')
            if len(fields) < 5:
                continue
            try:
                at = parse_time(fields[0])
            except ValueError:
                continue
            if since <= at <= until:
                first.setdefault(fields[1], (fields[3], fields[4]))
    return first


def task_bytes(text):
    """Bytes of the brief's Task section (heading included), or None when it has none."""
    for part in H1.split(text)[1:]:
        if re.sub(r' - .*', '', part.split('\n', 1)[0].strip()) == 'Task':
            return len(part.encode()) + 2
    return None


def load_briefs(home, since, until):
    """([(total bytes, task bytes)], files left out) of data/*/brief.md written inside the window.

    The write time is the file's modification time. A file with no Task section is not a launch
    brief and is counted in the second value only.
    """
    sizes, left_out = [], 0
    for path in glob.glob(os.path.join(home, 'data', '*', 'brief.md')):
        try:
            if not since <= os.stat(path).st_mtime <= until:
                continue
            with open(path, errors='replace') as brief:
                text = brief.read()
        except OSError:
            continue
        task = task_bytes(text)
        if task is None:
            left_out += 1
        else:
            sizes.append((len(text.encode()), task))
    return sizes, left_out
