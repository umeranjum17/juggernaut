#!/usr/bin/env bash
# jg-muster-depth.sh - pick the alignment (Muster) depth of an ask with one no-model rule, and record it on a ticket.
#
# Usage: jg-muster-depth.sh [--project <name>] [--projects-dir <dir>] <ask text> | -
#        jg-muster-depth.sh record --ticket <id> [--backfill] [--project <name>] [--projects-dir <dir>]
#        jg-muster-depth.sh record --ticket <id> --depth <skip|light|full|complete> --reason <why>
#
# Reading and recording are two commands. The pick changes nothing: it prints one line, `<depth>`,
# `<depth> survey-first` or `<depth> review`, and exits 0 (exit 2 on a usage error).
# `record` writes the ticket's one `Muster:` line (the line is the depth line of the muster formats):
#   Muster: <skip|light|full|complete>[ survey-first][ backfilled][ review] - <reason>
#   - `record --ticket <id>` reads the ticket's title through jg-backlog.sh, picks the depth and writes the line
#     once; a ticket that already has a line is left as it is (`--backfill` marks a ticket filed before the rule);
#   - `record --ticket <id> --depth <d> --reason <why>` is Main's reading of a `review` line, or Main's raise (or
#     lowering) of a picked depth. It always carries the reason, replaces the ticket's line with
#     `Muster: <d> - <why>`, and a repeat of the same call changes nothing.
# `.agents/skills/task-dispatch/SKILL.md` owns how intake uses it. Nothing refuses on the line yet.
#
# What the person wants is read apart from the project's state:
#   1. an explicit word wins: "muster: full", "complete muster", "no grilling" (skip);
#   2. the kind of ask, from general words only, in this order: the requested action is read before any noun in its
#      object, through request wrappers first ("could you", "help me", "I want you to", "go ahead and"):
#        - an information verb (explain, describe, list) or a verb aimed at the asker ("show me", "give me") is
#          not a build; so is an ask that starts with approve, recon, report and the like, or is a question;
#        - a fix, or a [blocker] tag, is small unless a complex verb (migrate, redesign, rewrite) is also asked;
#        - once the action is a build verb, no word of its object ("approve", "account", "proof") is read as the
#          action; new-project intent and complex verbs beat incidental nouns; a strong small word (typo, readme)
#          beats a complex noun only;
#        - an ask whose action no rule reads, or a request whose action stays unread after its wrappers, gets
#          `review`: Main reads it before any refusal can fire;
#   3. the project state: none (no project named), new (an empty repository), young (under 20 commits) or mature;
#      a named project with no local copy counts as mature, never new.
# Table: not-build, slice, small, other -> skip; new -> complete (full in a mature project); complex -> full
# (complete in a new project); build -> light (complete in a new project). The agreed documents never raise the
# depth: when they are missing and the depth is full or complete in an existing project, `survey-first` is added.
set -u
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "jg-muster-depth: $*" >&2; exit 2; }
depth_ok() { case $1 in skip|light|full|complete) return 0 ;; *) return 1 ;; esac; }

# ---- the pick: sets PICK_DEPTH, PICK_EXTRA (survey-first, review) and PICK_REASON ----
pick() {  # <ask> <project or ''> <projects dir>
  local ask=$1 project=$2 pdir=$3 d n state=none pack=no w kind='' unread=no asked=no
  local t B E wrap cverb cnoun small lead info infome fixv nbv buildv newp
  t=$(printf '%s' "$ask" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')
  has() { printf '%s' "$t" | grep -q -E "$1"; }
  B='(^|[^a-z0-9])' E='([^a-z0-9]|$)'
  PICK_DEPTH='' PICK_EXTRA='' PICK_REASON=''
  if [ -n "$project" ]; then
    d=$pdir/$project
    if [ -d "$d" ]; then
      n=$(git -C "$d" rev-list --count HEAD 2>/dev/null || echo 0)
      if [ "$n" -eq 0 ]; then state=new; elif [ "$n" -lt 20 ]; then state=young; else state=mature; fi
      { [ -f "$d/docs/vision.md" ] || [ -f "$d/VISION.md" ]; } && { [ -f "$d/GLOSSARY.md" ] || [ -f "$d/docs/glossary.md" ]; } \
        && [ -f "$d/docs/ways-of-working.md" ] && pack=yes
    else
      state=mature
    fi
  fi
  w=$(printf '%s' "$t" | sed -n -E 's/.*(muster|depth|grilling)[ :=]+(skip|light|full|complete)([^a-z].*|$)/\2/p; s/.*(^|[^a-z])(skip|light|full|complete) (muster|alignment)([^a-z].*|$)/\2/p' | head -1)
  if [ -n "$w" ]; then PICK_DEPTH=$w PICK_REASON='the ask names the depth'
  elif has "${B}no grilling${E}"; then PICK_DEPTH=skip PICK_REASON='the ask says no grilling'
  fi
  if [ -z "$PICK_DEPTH" ]; then
    # A request for action phrased as a question ("can you start ...?") is read as the action; a request for
    # information ("what is ...?", "why did ...?") is not a build. Request wrappers are peeled until the action
    # shows: politeness first, then "help me", "I want you to", "we need to", "go ahead and". `asked` remembers
    # that the ask was a request, so an action still unread after the wrappers goes to Main's review.
    wrap='^(\[[a-z-]+\] *)?((can|could|would|will) (you|we)|please|let'"'"'?s|help (me|us)( to)?|i (want|need|would like|'"'"'d like|wish)( you)?( to)?|we (need|want|should|must)( to)?|go ahead and|try to|kindly)( +|$)'
    for _ in 1 2 3 4; do
      if has "$wrap"; then
        t=$(printf '%s' "$t" | sed -E "s/$wrap//; s/\?[[:space:]]*$//"); asked=yes
      fi
    done
    cverb="${B}(migrate|migrates|migrating|redesign|redesigns|re-?architect|rewrite|rewrites|replace the [a-z ]*(system|store|engine|database))${E}"
    cnoun="${B}(architecture|migration|multi-machine|many machines|all machines|state machine|schema|domain model|platform|all [a-z]+ slices|internals|concept|release train|onboarding|routing|consent|privacy|security|payments?|sync|parallel|priority|gate|rules)${E}"
    small="${B}(typo|readme|heading|wording|copy|bump|notes|changelog)${E}"
    # the action: the first word after a slice marker, tags ([blocker]) and a short label ("CLI: ", "P1 J1: ")
    lead=$(printf '%s' "$t" | sed -E 's/^(\[[a-z-]+\] *)*//; s/^([a-z0-9][a-z0-9 ._\/-]{0,23}: +)+//; s/^[^a-z]+//' | awk '{print $1}')
    info='^(explain|describe|summari[sz]e|list|tell|show-me|compare|walk)$'
    # "show me", "give us", "take me through", "let me see": a leading verb aimed at the asker asks for information
    infome='^(show|give|take|walk|send|remind|let) (me|us)([^a-z]|$)'
    fixv='^(fix|fixes|revert|repair|patch|debug|hotfix|restore|unbreak)$'
    nbv='^(approve|recon|scout|critic|report|measure|review|audit|investigate|research|explore|benchmark|record|document|draft|look|check|inspect|verify)$'
    buildv='^(build|create|start|make|set|scaffold|add|write|design|plan|launch|bootstrap|spin)$'
    newp="${B}(new (project|app|product|repo|service)|new react native app|from scratch|brand[- ]new|start something new|start a new)${E}"
    if has '\?[[:space:]]*$' || has '^(\[[a-z-]+\] *)?(what|why|how|when|where|which|who|is|are|was|were|does|did|do|has|have|should|shall)([^a-z]|$)' \
       || has '^\[captain-ask\][^:]*(approve|when|resume|which|should|reset)' || has '^(report|recon|scout|critic)([^a-z]|$)' \
       || printf '%s' "$lead" | grep -q -E "$info" || has "$infome"; then kind=not-build
    elif has "${B}(slice [a-z0-9]+|part [0-9]|w[0-9]:|prerequisite)${E}"; then kind=slice
    elif printf '%s' "$lead" | grep -q -E "$fixv" || has '^\[blocker\]'; then
      if has "$cverb"; then kind=complex; else kind=small; fi
    elif printf '%s' "$lead" | grep -q -E "$nbv"; then kind=not-build
    elif printf '%s' "$lead" | grep -q -E "$buildv"; then
      # the action is a build: words in its object are not the action
      if has "$newp"; then kind=new
      elif has "$cverb" || { has "$cnoun" && ! has "$small"; }; then kind=complex
      elif has "$small"; then kind=small
      else kind=build
      fi
    elif [ "$asked" = yes ]; then
      # a request whose action is still unread after its wrappers: read the nouns, but Main confirms
      unread=yes
      if has "$newp"; then kind=new
      elif has "$cverb" || { has "$cnoun" && ! has "$small"; }; then kind=complex
      else kind=other
      fi
    elif has "${B}(approve|recon|scout|critic|explainer|measure|dry run|captain calls|go-ahead|feasibility|proof|demo|recorded|runbook|stop all|later:|future:)${E}"; then kind=not-build
    elif has "$newp"; then kind=new
    elif has "$cverb" || { has "$cnoun" && ! has "$small"; }; then kind=complex
    elif has "$small"; then kind=small
    elif has "${B}(sign-?ins?|account|buy)${E}"; then kind=not-build
    elif has "${B}(fix|bug|rename|remove|broken|revert|adopt|swap|cherry-pick|fails|stale|revoke)${E}"; then kind=small
    elif has "${B}(build|add|make|show|shows|support|enable|allow|view|page|enforce|ship|turns?|get|gets|find|finds|tell|works|follow|follows|polish|create|let|lets|start|set up|setup|scaffold|first version)${E}"; then kind=build
    else kind=other
    fi
    case $kind in
      new) [ "$state" = mature ] && PICK_DEPTH=full || PICK_DEPTH=complete ;;
      complex) [ "$state" = new ] && PICK_DEPTH=complete || PICK_DEPTH=full ;;
      build) [ "$state" = new ] && PICK_DEPTH=complete || PICK_DEPTH=light ;;
      *) PICK_DEPTH=skip ;;
    esac
    case $kind in
      not-build) PICK_REASON='not a build: a question, approval, report or proof' ;;
      slice) PICK_REASON='a slice of an approved plan' ;;
      small) PICK_REASON='a small change: a fix, typo or rename' ;;
      complex) PICK_REASON='a complex change' ;;
      new) PICK_REASON='a new project' ;;
      build) PICK_REASON='a build' ;;
      *) PICK_REASON='no rule read the action' ;;
    esac
  fi
  case "$PICK_DEPTH:$state:$pack" in
    full:young:no|full:mature:no|complete:young:no|complete:mature:no) PICK_EXTRA=' survey-first' ;;
  esac
  # an ask whose action no rule read: Main reads it before War Room or Blitz can refuse on it
  { [ "$kind" = other ] || [ "$unread" = yes ]; } && [ -z "$w" ] && PICK_EXTRA="$PICK_EXTRA review"
  return 0
}

# ---- record: the one Muster line of a ticket ----
backlog() { "$SELF_DIR/jg-backlog.sh" "$@"; }

ticket_field() {  # <show output> <field>: the value of `  <field>: ...`, unquoted when the store quoted it
  local v
  v=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case $v in '"'*) printf '%s' "$v" | jq -r . ;; *) printf '%s' "$v" ;; esac
}

cmd_record() {
  local ticket='' backfill=no depth='' reason='' project='' pdir=${JG_PROJECTS_DIR:-${JG_HOME:-.}/projects}
  while [ "$#" -gt 0 ]; do
    case $1 in
      --ticket) [ "$#" -ge 2 ] || die "--ticket needs an id"; ticket=$2; shift 2 ;;
      --backfill) backfill=yes; shift ;;
      --depth) [ "$#" -ge 2 ] || die "--depth needs skip, light, full or complete"; depth=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die "--reason needs the words that say why"; reason=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || die "--project needs a name"; project=$2; shift 2 ;;
      --projects-dir) [ "$#" -ge 2 ] || die "--projects-dir needs a folder"; pdir=$2; shift 2 ;;
      *) die "record: unknown argument $1" ;;
    esac
  done
  [ -n "$ticket" ] || die "usage: jg-muster-depth.sh record --ticket <id> [--backfill] | --ticket <id> --depth <d> --reason <why>"
  case $ticket in *[!A-Za-z0-9._-]*) die "invalid ticket id" ;; esac
  if [ -n "$depth" ]; then
    depth_ok "$depth" || die "--depth must be skip, light, full or complete"
    [ -n "$reason" ] || die "--depth needs --reason: a reading or a raise of a depth always says why"
    [ "$backfill" = no ] || die "--backfill marks the rule's own pick; it cannot go with --depth"
  elif [ -n "$reason" ]; then
    die "--reason goes with --depth"
  fi
  command -v jq >/dev/null 2>&1 || die "record needs jq on PATH"
  local show body cur title label new tmp out
  show=$(backlog show "$ticket" --full 2>&1) || die "cannot read ticket $ticket: $show"
  body=$(ticket_field "$show" body)
  [ "$body" != - ] || body=''
  cur=$(printf '%s\n' "$body" | grep -m1 '^Muster: ')
  if [ -n "$depth" ]; then
    new="Muster: $depth - $reason"
  else
    if [ -n "$cur" ]; then echo "unchanged: $cur"; return 0; fi
    title=$(ticket_field "$show" title)
    # the store keeps a leading type tag as a label: the rule reads it as the tag again
    label=$(backlog list --fields id,labels 2>/dev/null | awk -F, -v id="$ticket" '$1 ~ "^ *" id "$" {print $2}' | head -1)
    case $label in blocker|captain-ask) title="[$label] $title" ;; esac
    [ -n "$project" ] || { project=$(ticket_field "$show" repo); [ "$project" != - ] || project=''; }
    pick "$title" "$project" "$pdir"
    new="Muster: $PICK_DEPTH$PICK_EXTRA"
    if [ "$backfill" = yes ]; then
      case $PICK_EXTRA in *' review') new="Muster: $PICK_DEPTH${PICK_EXTRA% review} backfilled review" ;; *) new="$new backfilled" ;; esac
    fi
    new="$new - $PICK_REASON"
  fi
  [ "$cur" != "$new" ] || { echo "unchanged: $new"; return 0; }
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-muster-depth.XXXXXX") || die "cannot stage the ticket body"
  # the new line replaces the first Muster line, drops any later one, or ends the body when there is none
  printf '%s\n' "$body" | awk -v new="$new" '/^Muster: /{ if (!done) { print new; done = 1 } ; next } { print } END { if (!done) print new }' > "$tmp"
  if ! out=$(backlog update "$ticket" --body-file "$tmp" 2>&1); then
    rm -f -- "$tmp"; die "could not write the line on $ticket: $out"
  fi
  rm -f -- "$tmp"
  echo "recorded: $new"
}

# ---- entry ----
if [ "${1:-}" = record ]; then shift; cmd_record "$@"; exit $?; fi
project='' pdir=${JG_PROJECTS_DIR:-${JG_HOME:-.}/projects}
while [ "$#" -gt 0 ]; do
  case $1 in
    --project) [ "$#" -ge 2 ] || die "--project needs a name"; project=$2; shift 2 ;;
    --projects-dir) [ "$#" -ge 2 ] || die "--projects-dir needs a folder"; pdir=$2; shift 2 ;;
    --) shift; break ;;
    -) break ;;
    -*) die "unknown flag $1" ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || die "usage: jg-muster-depth.sh [--project <name>] <ask text> | -"
if [ "$1" = "-" ]; then ask=$(cat); else ask="$*"; fi
[ -n "$ask" ] || die "the ask is empty"
pick "$ask" "$project" "$pdir"
echo "$PICK_DEPTH$PICK_EXTRA"
