"""The quality reader: one table for a window, from the records a home already keeps.

Read-only. It reads state/chat.jsonl, data/checks-gate.log and data/*/brief.md of one home,
once each, and prints repeated `done`, first-check proof, brief size and notification volume.
Run it through quality.sh. Exit 0 when it printed; 2 on bad input.
"""
import argparse
import os
import sys
import time

import measures
import records
import routing
from measures import pct

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DAY = 86400


def parse_args(argv):
    ap = argparse.ArgumentParser(prog='quality.sh', description='Daily table of repeated done, proof and brief size.')
    ap.add_argument('--home', default=os.environ.get('JG_HOME'), help='Juggernaut home to read (default: $JG_HOME)')
    ap.add_argument('--since', help='window start, epoch seconds or ISO time ending in Z (default: a day before --until)')
    ap.add_argument('--until', help='window end, the same forms (default: now)')
    ap.add_argument('--routing', help='wake routing rule table (default: JG_WAKE_ROUTING, the home config, then defaults/wake-routing)')
    args = ap.parse_args(argv)
    try:
        args.until = records.parse_time(args.until) if args.until else int(time.time())
        args.since = records.parse_time(args.since) if args.since else args.until - DAY
    except ValueError as err:
        ap.error(f'bad time: {err}')
    if args.since > args.until:
        ap.error('--since is after --until')
    if not args.home or not os.path.isdir(args.home):
        ap.error(f'--home is not a directory: {args.home or "(unset, and JG_HOME is not set)"}')
    return args


def n(value):
    return f'{value:,}'


def absent(path):
    return [f'  no record: {path} is absent']


def render_repeat_done(chat):
    if chat is None:
        return absent('state/chat.jsonl')
    d = measures.repeat_done(chat)
    return [f'  {pct(d["repeats"], d["lines"])} repeat done: {n(d["repeats"])} of {n(d["lines"])} done lines came after an earlier done of the same task',
            f'  {n(d["two_plus"])} of {n(d["tasks"])} tasks wrote done twice or more ({pct(d["two_plus"], d["tasks"])})',
            f'  {pct(d["after_lead"], d["repeats"])} of the repeats ({n(d["after_lead"])} of {n(d["repeats"])}) follow a lead message to that task']


def render_proof(first_checks):
    if first_checks is None:
        return absent('data/checks-gate.log')
    p = measures.proof(first_checks)
    return [f'  {pct(p["passed"], p["targets"])} proof first-check: {n(p["passed"])} of {n(p["targets"])} targets passed their first check',
            f'  {pct(p["form_errors"], p["targets"])} form errors: {n(p["form_errors"])} first checks failed on the shape of the block']


def render_briefs(sizes, left_out):
    b = measures.brief_size(sizes)
    if not b['briefs']:
        return ['  no launch brief was written in the window']
    lines = [f'  {n(b["median"])}-byte brief median over {n(b["briefs"])} briefs; the Task part is {n(b["task_median"])} bytes ({pct(b["task_median"], b["median"])})']
    if left_out:
        lines.append(f'  {n(left_out)} brief files with no Task section are left out')
    return lines


def render_notifications(chat, rules):
    if chat is None:
        return absent('state/chat.jsonl')
    m = measures.notifications(chat, rules)
    lines = [f'  {n(m["rows"])} rows sent to the lead in the window', '  rows per day (UTC):']
    lines += [f'    {day}  {n(count)}' for day, count in m['per_day']]
    lines.append('  top senders: ' + (', '.join(f'{who} {n(count)}' for who, count in m['senders']) or 'none'))
    lines.append(f'  {n(m["digests"])} digest rows')
    lines.append(f'  {n(m["after_status"])} turn-ended rows after a status line '
                 f'({pct(m["after_status"], m["turn_ended"])} of {n(m["turn_ended"])} turn-ended rows)')
    if m['wake_now'] is None:
        lines.append('  no rule table: the rows that wake at once are not counted')
    else:
        total = sum(m['wake_now'].values())
        lines.append(f'  {n(total)} rows wake at once ({pct(total, m["rows"])}), by kind: '
                     + (', '.join(f'{kind} {n(count)}' for kind, count in m['wake_now'].most_common()) or 'none'))
    return lines


def main(argv):
    args = parse_args(argv)
    home, since, until = args.home, args.since, args.until
    loaded = records.load_chat(os.path.join(home, 'state', 'chat.jsonl'), until)
    chat, unreadable = (measures.Chat(loaded[0], since), loaded[1]) if loaded else (None, 0)
    rules = routing.load_rules(routing.routing_file(home, REPO, args.routing))
    sizes, left_out = records.load_briefs(home, since, until)
    sections = [('repeat done', render_repeat_done(chat)),
                ('proof', render_proof(records.load_first_checks(os.path.join(home, 'data', 'checks-gate.log'), since, until))),
                ('brief size', render_briefs(sizes, left_out)),
                ('notifications', render_notifications(chat, rules))]
    print(f'quality ledger, home {home}')
    print(f'window {records.iso(since)} to {records.iso(until)}')
    for title, lines in sections:
        print(f'\n{title}')
        print('\n'.join(lines))
    if unreadable:
        print(f'\n{n(unreadable)} lines of state/chat.jsonl were not readable and are left out')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
