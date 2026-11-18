"""The one key, subject and project contract of the item store. Every adapter builds its keys here (or through
`jg-item key`), and itemdb's store refuses an open whose key does not have its kind's shape.

The subject of every item about a lane or its delivery is the ticket id (the task record's `ticket=`, else the task id),
so `v_ticket` and the leash read a ticket by its id; the task id and the home are in the key. The project is the last
part of the task record's `project=` path; work, land and merge need it (the policy row is the project's).

  kind      key                                      subject      opened by                       closed by
  work      work:<home>/<task>                       <ticket>     the dispatch close (spawn)      its lane's done line (lane adapter)
  wait      wait:<home>/<task>#<wait key>            <ticket>     a paused or blocked line        its `resolved [key=<wait key>]` line, or its holder
  steer     steer:<home>/<task>/<n>                  <ticket>     jg-send.sh                      jg-delivery.sh handled
  report    report:<home>/<task>                     <ticket>     a Recon's done line             its reader
  dispatch  dispatch:<home>/<ticket>[#<n>]            <ticket>     an approval record (#n: a requeue)  the spawn
  land      land:<home>/<ticket>@<head>              <ticket>     a ship's done line              the trunk adapter (trunk:<commit>)
  merge     merge:<home>/<ticket>@<pull request>     <ticket>     the merge adapter               the merge adapter (merged:<sha>)
  release   release:<project>@<pull request>         <project>@<pull request>   the trunk adapter's push   the trunk adapter
  question  question:<home>/<ticket>[#<n>]           <ticket>     Main or a lane line             the owner's channel (owner:<channel>:<id> pick=<pick>)
            question:land:<home>/<ticket>@<head>     <ticket>     Main or the tick: his word on that exact step
            question:merge:<home>/<ticket>@<pull request>
            question:release:<project>@<pull request>   <project>@<pull request>   the store, at a push
  cleanup   cleanup:<home>/<task>                    <ticket>     a lane's done line              the cleanup adapter (cleaned:)
  update    update:<home>@<version>                  <version>    the release                     the update adapter (home-at:)
  A question's subject is the subject of the step it asks about: the ticket id, or <project>@<pull request> for a
  release (the store's release_push opens it so).
  Others (alert, security, main-down, intake, tell, rule, blocker) are written by one adapter or the tick each; their
  shapes are in docs/item-store.md and the alert key is checked by the schema itself."""
import re

import store as S

SEG = r"[A-Za-z0-9][A-Za-z0-9._-]*"
REF = r"[A-Za-z0-9][A-Za-z0-9._/-]*"
SHAPES = {
    "work":     r"work:(?P<home>%s)/%s" % (SEG, SEG),
    "wait":     r"wait:(?P<home>%s)/%s#%s" % (SEG, SEG, SEG),
    "steer":    r"steer:(?P<home>%s)/%s/[A-Za-z0-9@._-]+" % (SEG, SEG),
    "report":   r"report:(?P<home>%s)/%s" % (SEG, SEG),
    "dispatch": r"dispatch:(?P<home>%s)/%s(?:/critic|#%s)?" % (SEG, SEG, SEG),
    "land":     r"land:(?P<home>%s)/%s@%s" % (SEG, SEG, SEG),
    "merge":    r"merge:(?P<home>%s)/%s@%s" % (SEG, SEG, SEG),
    "release":  r"release:%s@%s" % (SEG, REF),
    "question": r"question:(?:(?P<home>%s)/%s(?:#%s)?|(?:land|merge):(?P<shome>%s)/%s@%s|release:%s@%s)" % (
        SEG, SEG, SEG, SEG, SEG, SEG, SEG, REF),
    "cleanup":  r"cleanup:(?P<home>%s)/%s" % (SEG, SEG),
    "update":   r"update:(?P<home>%s)@%s" % (SEG, SEG),
}
TICKET_SUBJECT = {"work", "wait", "steer", "report", "dispatch", "land", "merge", "question", "cleanup"}


def check(kind, key, home, subject):
    """Refuse an open whose key lacks its kind's shape, names another home, or whose subject is not its step's: a plain
    ticket id for a lane kind, <project>@<pull request> for a release step and its question. Kinds not in SHAPES pass
    here (their writer is one adapter or the tick)."""
    pat = SHAPES.get(kind)
    if pat is None:
        return
    m = re.fullmatch(pat, key or "")
    if not m:
        raise S.Refused("key: %s needs the shape %s (keys.py), not %r" % (kind, pat.replace("(?P<home>", "(").replace("(?P<shome>", "("), key))
    h = m.groupdict().get("home") or m.groupdict().get("shome")
    if h is not None and h != home:
        raise S.Refused("key: %r names home %s, but the item is in home %s" % (key, h, home))
    rel = re.fullmatch(r"(?:question:)?release:(%s@%s)" % (SEG, REF), key)
    if rel:      # a release step and its question: the subject is <project>@<pull request>, as the key names it
        if subject != rel.group(1):
            raise S.Refused("subject: a release step's or release question's subject is %s, not %r" % (rel.group(1), subject))
    elif kind in TICKET_SUBJECT and not re.fullmatch(SEG, subject or ""):
        raise S.Refused("subject: a %s item's subject is its ticket id (no '/'), not %r" % (kind, subject))


def key(kind, home, task=None, ticket=None, wait=None, n=None, head=None, pr=None, version=None, project=None):
    """The key of one item, by the table above."""
    need = {"work": ("task",), "wait": ("task", "wait"), "steer": ("task", "n"), "report": ("task",), "dispatch": ("ticket",),
            "land": ("ticket", "head"), "merge": ("ticket", "pr"), "release": ("project", "pr"), "cleanup": ("task",),
            "update": ("version",), "question": ("ticket",), "question:land": ("ticket", "head"),
            "question:merge": ("ticket", "pr"), "question:release": ("project", "pr")}
    if kind not in need:
        raise ValueError("no key rule for kind %r" % kind)
    vals = dict(task=task, ticket=ticket, wait=wait, n=n, head=head, pr=pr, version=version, project=project)
    miss = [x for x in need[kind] if not vals[x]]
    if miss:
        raise ValueError("%s needs %s" % (kind, ", ".join("--" + x for x in miss)))
    return {
        "work": "work:%s/%s" % (home, task), "wait": "wait:%s/%s#%s" % (home, task, wait),
        "steer": "steer:%s/%s/%s" % (home, task, n), "report": "report:%s/%s" % (home, task),
        "dispatch": "dispatch:%s/%s" % (home, ticket) + ("#%s" % n if n else ""),
        "land": "land:%s/%s@%s" % (home, ticket, head),
        "merge": "merge:%s/%s@%s" % (home, ticket, pr), "release": "release:%s@%s" % (project, pr),
        "cleanup": "cleanup:%s/%s" % (home, task), "update": "update:%s@%s" % (home, version),
        "question": "question:%s/%s" % (home, ticket) + ("#%s" % n if n else ""),
        "question:land": "question:land:%s/%s@%s" % (home, ticket, head),
        "question:merge": "question:merge:%s/%s@%s" % (home, ticket, pr),
        "question:release": "question:release:%s@%s" % (project, pr),
    }[kind]
