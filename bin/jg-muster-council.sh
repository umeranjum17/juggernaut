#!/usr/bin/env bash
# jg-muster-council.sh - /muster council's merge: the lens drafts of a council become the questions of a round.
#
# Usage: jg-muster-council.sh merge <council-ticket>
#        jg-muster-council.sh --help
#
# The lens lanes are started by `bin/jg-war-room.sh lenses` (the same lane machinery as /war-room, with no pack and no plan); each
# lens drafts data/<lens task>/report.md and records it with bin/jg-recon-handoff.sh draft. A lens draft holds:
#   ## Questions     one line each: `- Q: <question> | A: <answer, or nothing> | owner: <yes|no>`
#   ## Core objects  (the domain lens only) one line each: `- Object: <Name> | states: <a, b> | events: <x, y>`
#
# merge reads the lanes in data/war-room/<council>/lanes and refuses (exit 1, nothing written) while a lens has not recorded its
# draft or holds a line it cannot read. It then groups the questions of every lens by their words (case, spacing and punctuation
# aside) and writes one round, the next free round number at revision 1, to data/<council>/muster/rounds.tsv in the round format
# of the muster formats (round revision qid gate presented qset question_sha answer source taken at doc_rev):
#   - a question every answering lens agrees on, that no lens marks owner: yes, is taken by the agent: answer, source=agent, taken=agent;
#   - a contested question (two different answers), a captain-only question (any lens says owner: yes) and a question nobody could
#     answer stay open: no answer, no source, no taken. Posting the open ones to the board is the round's own step.
# The domain lens's core objects, states and events are copied to data/<council>/muster/council-domain.md for the drafter.
# data/<council>/muster/council-merged records the round and the hash of the drafts, so a second merge prints `already merged` and
# changes nothing; a draft changed after the merge is refused (a changed answer is a revision of the round, not a second merge).
# The merge never reads or writes a project: a brand-new project has no pack. Exit 0 merged or already merged, 1 refused, 2 usage.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
HANDOFF=$SCRIPT_DIR/jg-recon-handoff.sh
export JG_HOME

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { echo "jg-muster-council: $*" >&2; exit 2; }
refuse() { echo "jg-muster-council: refused: $*" >&2; exit 1; }

cmd_merge() {
  local council run lens task phase lens_list='' task_list=''
  [ $# -eq 1 ] || die "usage: jg-muster-council.sh merge <council-ticket>"
  council=$1
  case $council in ''|*/*|.*) die "council ticket '$council' is not a plain id" ;; esac
  run=$DATA/war-room/$council
  grep -qx 'kind=lenses' "$run/record" 2>/dev/null || die "no lens council $council (data/war-room/$council/record): start it with jg-war-room.sh lenses"
  [ -s "$run/lanes" ] || die "no lanes for $council (data/war-room/$council/lanes): start it with jg-war-room.sh lenses"
  while IFS=$'\t' read -r lens task; do
    phase=$("$HANDOFF" phase "$task" 2>/dev/null || echo none)
    [ "$phase" != none ] || refuse "the $lens lens ($task) has not recorded its draft: run bin/jg-war-room.sh next $council"
    [ -s "$DATA/$task/report.md" ] || refuse "the $lens lens ($task) has no report.md"
    lens_list+="$lens,"; task_list+="$task,"
  done < "$run/lanes"
  python3 -I - "$DATA" "$council" "${lens_list%,}" "${task_list%,}" <<'PY'
import hashlib, os, re, sys, time

data, council, lenses, tasks = sys.argv[1], sys.argv[2], sys.argv[3].split(','), sys.argv[4].split(',')
muster = os.path.join(data, council, 'muster')
rounds, marker, domain_out = (os.path.join(muster, n) for n in ('rounds.tsv', 'council-merged', 'council-domain.md'))
QLINE = re.compile(r'^-\s*Q:\s*(.+?)\s*\|\s*A:\s*(.*?)\s*\|\s*owner:\s*(yes|no)\s*$', re.I)


def stop(msg):
    print('jg-muster-council: refused: ' + msg, file=sys.stderr)
    sys.exit(1)


def sections(text):
    out, cur = {}, None
    for line in text.splitlines():
        if line.startswith('## '):
            cur = out.setdefault(line[3:].strip().lower(), [])
        elif cur is not None and line.strip():
            cur.append(line.strip())
    return out


def key(words):
    return ' '.join(re.sub(r'[^a-z0-9]+', ' ', words.lower()).split())


drafts, groups, objects = [], {}, []
for lens, task in zip(lenses, tasks):
    raw = open(os.path.join(data, task, 'report.md'), encoding='utf-8').read()
    drafts.append(hashlib.sha256(raw.encode()).hexdigest())
    sec = sections(raw)
    if 'questions' not in sec:
        stop(f'the {lens} lens ({task}) has no "## Questions" section')
    for line in sec['questions']:
        m = QLINE.match(line)
        if not m:
            stop(f'the {lens} lens ({task}) has a question line the merge cannot read: {line[:120]}')
        q, a, owner = (' '.join(x.split()) for x in m.groups())
        g = groups.setdefault(key(q), {'q': q, 'answers': {}, 'owner': False})
        g['owner'] = g['owner'] or owner.lower() == 'yes'
        if a:
            g['answers'].setdefault(key(a), a)
    if lens == 'domain':
        objects = [l for l in sec.get('core objects', []) if l.startswith('- Object:')]
        if not objects:
            stop(f'the domain lens ({task}) lists no core objects (a "## Core objects" line "- Object: <Name> | states: <a, b> | events: <x, y>")')

digest = hashlib.sha256('\n'.join(drafts).encode()).hexdigest()[:12]
if os.path.exists(marker):
    merged_round, merged_digest = open(marker).read().split()[:2]
    if merged_digest != digest:
        stop(f'a lens draft changed after round {merged_round} was merged; a changed answer is a revision of that round')
    print(f'already merged: round {merged_round} of {council}')
    sys.exit(0)

os.makedirs(muster, exist_ok=True)
prior = [int(l.split('\t')[0]) for l in open(rounds)] if os.path.exists(rounds) else []
rnd, now, rows, agreed = (max(prior) + 1 if prior else 1), int(time.time()), [], 0
for k, g in enumerate(groups.values(), 1):
    settled = not g['owner'] and len(g['answers']) == 1
    agreed += settled
    answer, source, taken = (next(iter(g['answers'].values())), 'agent', 'agent') if settled else ('', '', '')
    rows.append('\t'.join([str(rnd), '1', f'R{rnd}Q{k}', '', '', '', hashlib.sha256(g['q'].encode()).hexdigest()[:12],
                           answer, source, taken, str(now), '']))
with open(rounds, 'a', encoding='utf-8') as f:
    f.write('\n'.join(rows) + '\n')
if objects:
    with open(domain_out, 'w', encoding='utf-8') as f:
        f.write(f'# Core objects, states and events from the domain lens of {council}\n\n' + '\n'.join(objects) + '\n')
with open(marker, 'w') as f:
    f.write(f'{rnd} {digest}\n')
print(f'merged: round {rnd} of {council}: {len(rows)} questions, {agreed} taken by the agent, {len(rows) - agreed} open')
PY
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  merge) shift; cmd_merge "$@"; exit $? ;;
  *) die "usage: jg-muster-council.sh merge <council-ticket>" ;;
esac
