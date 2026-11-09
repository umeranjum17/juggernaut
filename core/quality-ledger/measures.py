"""The measures of the quality ledger: pure functions over records already read.

Nothing here reads a file or prints. Each measure returns a plain dict of counts and the
report renders them. A count covers the window [since, until]; a status line before `since`
is kept only as context, to join a notification to the status line that just came before it.
"""
import os
import re
import statistics
from bisect import bisect_right
from collections import Counter, defaultdict
from datetime import datetime, timezone

from records import status_word
from routing import route

FORM_ERRORS = ('proof: names no command', 'evidence file missing', 'no "## Checks" block',
               'missing or empty Checks line')
# A turn that ends within this long after one of these status lines is the turn that wrote it.
TURN_END_SECONDS = 120
TURN_END_AFTER = ('done', 'needs-decision', 'blocked', 'failed', 'paused')
# The router matches a `<task>.status` event with the newest line of that status file; the line may
# be written a moment after the wake row, so a row also sees a status this many seconds ahead of it.
STATUS_SLACK_SECONDS = 10
STATUS_TAG = re.compile(r'\[status=([a-z-]+)\]')
TURN_ENDED = '.turn-ended'


def pct(part, whole):
    """A whole-number percent, rounded half up; 'n/a' when there is nothing to divide by."""
    return f'{int(100 * part / whole + 0.5)}%' if whole else 'n/a'


def median(values):
    return int(statistics.median(values) + 0.5) if values else None


class StatusLog:
    """One task's status lines, oldest first, with the newest-at-a-time lookup."""

    def __init__(self, entries):
        self.entries = sorted(entries, key=lambda entry: entry[0])
        self.times = [entry[0] for entry in self.entries]

    def newest(self, at):
        """The newest (at, word, text) written at or before `at`, or None."""
        i = bisect_right(self.times, at)
        return self.entries[i - 1] if i else None


class Chat:
    """The message log up to `until`, indexed by task."""

    def __init__(self, rows, since):
        self.since = since
        status, self.lead, self.wakes = defaultdict(list), defaultdict(list), []
        for row in rows:
            if row['kind'] == 'status':
                status[row['sender']].append((row['at'], status_word(row['text']), row['text']))
            elif row['kind'] == 'agent':
                self.lead[row['to']].append(row['at'])
            elif row['kind'] == 'wake' and row['at'] >= since:
                self.wakes.append(row)
        self.status = {task: StatusLog(entries) for task, entries in status.items()}
        for times in self.lead.values():
            times.sort()

    def newest_status(self, task, at):
        log = self.status.get(task)
        return log.newest(at) if log else None


def repeat_done(chat):
    """How often a task wrote `done` again, and how often a lead message came between the two."""
    dones = {}
    for task, log in chat.status.items():
        times = [at for at, word, _ in log.entries if word == 'done' and at >= chat.since]
        if times:
            dones[task] = times
    lines = sum(len(times) for times in dones.values())
    after_lead = 0
    for task, times in dones.items():
        lead = chat.lead.get(task, [])
        for earlier, later in zip(times, times[1:]):
            after_lead += bisect_right(lead, later) > bisect_right(lead, earlier)
    return {'tasks': len(dones), 'lines': lines, 'repeats': lines - len(dones),
            'two_plus': sum(len(times) >= 2 for times in dones.values()), 'after_lead': after_lead}


def proof(first_checks):
    """The share of proof targets that passed their first check, and the share that failed on form."""
    passed = sum(result == 'pass' for result, _ in first_checks.values())
    form = sum(result != 'pass' and detail.startswith(FORM_ERRORS) for result, detail in first_checks.values())
    return {'targets': len(first_checks), 'passed': passed, 'form_errors': form}


def brief_size(sizes):
    """Median bytes of a launch brief and of its Task section."""
    return {'briefs': len(sizes), 'median': median([total for total, _ in sizes]),
            'task_median': median([task for _, task in sizes])}


def sender_name(sender):
    """The task or check a row came from: no `.turn-ended` suffix, and a check script by its file name."""
    return os.path.basename(sender.removesuffix(TURN_ENDED)) or '(none)'


def split_wake(text):
    """(kind, key, rest) of a notification text such as `check: <key> <payload>`."""
    rest = text.split(' ', 1)[1] if ' ' in text else ''
    return text.split(':', 1)[0], rest.split(' ', 1)[0], rest


def wake_payload(chat, row, kind, key, rest):
    """The text the rule table matches a row against, as the router builds it."""
    if kind == 'signal':
        if key.endswith(TURN_ENDED):
            return ''
        newest = chat.newest_status(key.removesuffix('.status'), row['at'] + STATUS_SLACK_SECONDS)
        if newest:
            return newest[2].strip()
        tag = STATUS_TAG.search(row['text'])
        return tag.group(1) if tag else ''
    return rest.split(' ', 1)[1] if kind == 'check' and ' ' in rest else rest


def notifications(chat, rules):
    """What the lead was sent in the window: volume, senders, digests, and the rows that wake at once.

    `rules` is the routing rule table, or None when it is absent (no class is then counted).
    A sender is the task or check script (see sender_name).
    """
    per_day, senders = Counter(), Counter()
    digests = turn_ended = after_status = 0
    wake_now = Counter()
    for row in chat.wakes:
        text, task = row['text'], sender_name(row['sender'])
        per_day[datetime.fromtimestamp(row['at'], timezone.utc).strftime('%Y-%m-%d')] += 1
        senders[task] += 1
        kind, key, rest = split_wake(text)
        digests += text.startswith('check: wake-digest')
        if kind == 'signal' and key.endswith(TURN_ENDED):
            turn_ended += 1
            newest = chat.newest_status(task, row['at'])
            after_status += bool(newest and row['at'] - newest[0] <= TURN_END_SECONDS
                                 and newest[1] in TURN_END_AFTER)
        if rules is not None and route(rules, kind, key, wake_payload(chat, row, kind, key, rest)) == 'now':
            tag = STATUS_TAG.search(text) if kind == 'signal' else None
            wake_now[f'{kind} {tag.group(1)}' if tag else kind] += 1
    return {'rows': len(chat.wakes), 'per_day': sorted(per_day.items()), 'senders': senders.most_common(5),
            'digests': digests, 'turn_ended': turn_ended, 'after_status': after_status,
            'wake_now': None if rules is None else wake_now}
