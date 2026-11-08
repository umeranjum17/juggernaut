"""Daily card reconcile: archive waiting sign-off cards whose source is closed; list the ones it cannot judge."""
import datetime as dt
import re
from lane import delivery_urls

PR_URL = re.compile(r'https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)')
REPORT = {'evidence'}  # sign-off hides these a day after filing by itself


def waiting(decisions):
    """Cards nobody answered or dismissed that ask for something: a button to press or a sign-in to finish."""
    return [d for d in decisions if not d.get('answer') and not d.get('dismissed') and not d.get('decided')
            and d.get('type') not in REPORT and not d['key'].startswith('ticket-cleanup-') and (d.get('options') or d.get('type') == 'signin')]


def captain_words(card):
    """A card the captain wrote or annotated is his words; only a closed source may archive it."""
    return str(card.get('filer', '')).startswith('captain') and card.get('filer') != 'captain-board-feed' or bool(card.get('note'))


def norm(text):
    return re.sub(r'\W+', ' ', text.lower()).strip()


def pr_state(url, run, cache):
    """'merged', 'closed' or 'open' for a PR link; cached so one PR is read once a pass."""
    if url not in cache:
        repo, number = PR_URL.fullmatch(url).groups()
        out = run(['gh-axi', 'api', f'repos/{repo}/pulls/{number}', '--jq', '{merged,state}'])
        v = dict(re.findall(r'^(merged|state) *: *(\S+)$', out, re.M))
        cache[url] = 'merged' if v.get('merged') == 'true' else 'closed' if v.get('state') == 'closed' else 'open'
    return cache[url]


def sources(card, ctx):
    """(board ticket, backlog item, task ref) a card answers; the first two may be None."""
    ticket = ctx['tickets'].get(card.get('ticket'))
    # A task's own card is keyed fm-<hash>-<task id>-<UTC stamp>; a lead's ask card is ask-<ref> or carries ask_ref.
    named = re.fullmatch(r'(?:fm|jg)-[0-9a-f]{8}-(.+)-\d{8}T\d{6}Z', card['key'])
    ref = card.get('ask_ref') or (named[1] if named else re.sub(r'^ask-', '', card['key']))
    return ticket, ctx['items'].get(ref) or ctx['items'].get(re.sub(r'^ask-', '', card['key'])), ref


def card_urls(card):
    text = ' '.join(str(card.get(k, '')) for k in ('title', 'about', 'why', 'detail', 'link'))
    return {m[0] for m in PR_URL.finditer(text)}


UNMERGED = 'every linked change is closed unmerged, so the question about it waits for the captain'


def judge(card, ctx, now, others):
    """(verdict, reason, why): verdict 'dismiss' (reason is a sign-off-axi --reason), 'keep' or 'unclear'.

    A question about work whose every linked change was closed unmerged is the question whether to delete that
    closed work, so the work being closed is the reason it exists and never a reason to dismiss it: it stays until
    the captain answers. This holds on every route, so it wraps the rest."""
    verdict = decide(card, ctx, now, others)
    if verdict[0] == 'dismiss':
        ticket, item, _ = sources(card, ctx)
        urls = card_urls(card) | set((ticket or {}).get('prs') or []) | set(delivery_urls(item) if item else [])
        if urls and {pr_state(u, ctx['run'], ctx['prs']) for u in urls} == {'closed'}:
            return 'keep', '', UNMERGED
    return verdict


def decide(card, ctx, now, others):
    # 1. The board ticket or the backlog item the card answers.
    ticket, item, ref = sources(card, ctx)
    if ticket:
        if ticket.get('state') == 'done': return 'dismiss', 'done-elsewhere', f"ticket {card['ticket']} is done"
        return 'keep', '', f"ticket {card['ticket']} is {ticket.get('state') or 'open'}"
    if item:
        if item['state'] == 'done': return 'dismiss', 'done-elsewhere', f'task {ref} is closed in the backlog'
        if item.get('held') != 'yes': return 'dismiss', 'done-elsewhere', f'task {ref} is no longer held, so it moved on without this card'
        return 'keep', '', f'task {ref} is still held'
    # 2. Pull requests the card links: none open means nothing is left to decide.
    states = [pr_state(u, ctx['run'], ctx['prs']) for u in sorted(card_urls(card))]
    if states and set(states) == {'closed'}: return 'keep', '', UNMERGED
    if 'merged' in states and 'open' not in states:
        return 'dismiss', 'done-elsewhere', f"every linked PR is {'/'.join(sorted(set(states)))}"
    if 'open' in states: return 'keep', '', 'a linked PR is still open'
    if captain_words(card): return 'unclear', '', 'holds the captain\'s words and no source says it is closed'
    # 3. Weaker signals: an expired sign-in, a newer card for the same thing.
    if card['type'] == 'signin' and card.get('expires') and card['expires'] < now.strftime('%Y-%m-%dT%H:%M:%SZ'):
        return 'dismiss', 'not-relevant', f"sign-in link expired {card['expires']}"
    for other in others:
        if other['key'] != card['key'] and norm(other['title']) == norm(card['title']) and other.get('filed', '') > card.get('filed', ''):
            return 'dismiss', 'replaced', f"card {other['key']} asks the same, filed later"
    return 'unclear', '', 'no linked task, ticket or PR to check'


def reconcile(decisions, ctx, now, board, run, log):
    """Dismiss what is clearly closed. Returns (dismissed, kept, unclear): counts and the (key, title, why) list for Main."""
    dismissed, kept, unclear = 0, 0, []
    for card in waiting(decisions):
        try: verdict, reason, why = judge(card, ctx, now, decisions)
        except (RuntimeError, OSError) as error: verdict, reason, why = 'unclear', '', f'source unreadable: {str(error)[:80]}'
        if verdict == 'dismiss':
            run(['sign-off-axi', 'dismiss', card['key'], str(board), '--reason', reason])
            log(f"dismissed {card['key']} ({reason}): {why}")
            dismissed += 1
        elif verdict == 'keep': kept += 1
        else: unclear.append((card['key'], card['title'], why))
    return dismissed, kept, unclear
