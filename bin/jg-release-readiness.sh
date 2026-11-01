#!/usr/bin/env bash
# jg-release-readiness.sh - the release branch pushes its own readiness.
#
# WHY. The captain asked "did we make releases?" while a finished release branch
# sat unheard: its features were merged and green, and nothing said so or said
# what blocked it. A release that waits for someone to remember it does not ship,
# so readiness pushes itself along three paths this repository already owns and
# invents none of them:
#
#   card    One board question, raised through bin/jg-question-card.sh the moment
#           the release is genuinely ready, so the board's own ask rules apply
#           (bin/jg-ask-gate-lib.sh, must category public-release). It carries
#           what ships, the measured numbers, the risks and one Approve.
#   digest  bin/jg-status-digest.sh reads `show` and prints one release line
#           every time, so the captain digest answers "did we make releases?"
#           without being asked.
#   alert   bin/jg-inbox.sh note queues one check wake once the release has
#           waited past its limit, and its request id makes a repeat impossible.
#
# CONTRACT (this header is the one owner).
#   ready   Every feature of the version branch is complete: at least one change
#           sits on it, no open pull request targets it, it carries the default
#           branch (parity), and the checks on its tip are green. A fact that
#           cannot be read leaves the release not ready with the reason named,
#           so an unreadable check never produces a release card.
#   records $DATA/release-readiness/state.jsonl  one row per changed measurement:
#           {at,state,changes,open,behind,ci,lines,files,version,default}. The
#           wait is measured from the first row of the current contiguous run of
#           one `state`, so a new feature does not restart the wait for a release
#           that has already been waiting.
#           $DATA/release-readiness/cards.jsonl  one row per raised card:
#           {at,key,hash}. The hash is the card's own text, and an unchanged card
#           is never raised twice.
#           $DATA/release-readiness/alerts.jsonl  one row per alert:
#           {at,since,hours}. One alert per wait.
#   config  $CONFIG/release-readiness, key=value, all optional: wait-hours (the
#           limit in whole hours, default 24), project-dir (else the home, which
#           is the self repository), board (a board file, else the one
#           sign-off-axi walks), filer (default release-readiness), branch (only
#           for a checkout that carries no release/c-<N> ref).
#
# Usage: jg-release-readiness.sh <home> tick [--now <epoch>]
#        jg-release-readiness.sh <home> show [--now <epoch>]
#
#   tick  One pass: measure, record, then raise the card and the alert when the
#         rules say so. One line per action, and one `unchanged:` line when the
#         state, the card and the wait are all as the last pass left them.
#   show  Print the one captain line the digest carries, and nothing else. It
#         writes no record.
#
# Environment: JG_DATA_OVERRIDE, JG_CONFIG_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-version-branch-lib.sh
. "$SCRIPT_DIR/jg-version-branch-lib.sh"
# shellcheck source=bin/jg-tangle-lib.sh
. "$SCRIPT_DIR/jg-tangle-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

die() { printf 'jg-release-readiness: %s\n' "$*" >&2; exit 2; }

# <n> <singular>: a count the captain reads, in its own number.
count_word() { case $1 in 1) printf '1 %s\n' "$2" ;; *) printf '%s %ss\n' "$1" "$2" ;; esac; }
changes_word() { count_word "$1" change; }

# A scheduled check runs this pass, so a provider call that hangs would hold the
# check rather than fail it. Bound it where the host has `timeout`.
gh_call() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 25 gh "$@"
  else
    gh "$@"
  fi
}

# Print the ref this clone carries for <branch>, preferring the remote one
# because a release branch lives on the remote.
ref_of() {  # <dir> <branch>
  local dir=$1 ref
  for ref in "refs/remotes/origin/$2" "refs/heads/$2"; do
    git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" && return 0
  done
  return 1
}

# green, red, pending or unknown for the checks on one commit.
checks_state() {  # <slug> <sha>
  local out
  out=$(gh_call api "repos/$1/commits/$2/check-runs?per_page=100" \
    --jq '[.check_runs[] | (.status + " " + (.conclusion // ""))] | join(",")' 2>/dev/null) || out=''
  # No checks at all is not green: nothing has confirmed the release.
  [ -n "$out" ] || { printf 'unknown\n'; return 0; }
  if printf '%s' "$out" | grep -qE '(queued|in_progress)'; then printf 'pending\n'; return 0; fi
  if printf '%s' "$out" | grep -qE 'completed (failure|timed_out|cancelled|action_required|startup_failure)'; then
    printf 'red\n'
    return 0
  fi
  printf 'green\n'
}

# Fill the measurement globals from the project checkout and the provider.
measure() {
  local dir version default vref dref stat add del
  STATE_W=none CHANGES=0 OPEN=0 BEHIND=0 CI=green LINES='+0/-0' FILES=0
  VERSION='' DEFAULT='' SLUG=''
  dir=$(cfg project-dir)
  dir=${dir:-$home}
  case $dir in /*) ;; *) dir=$home/$dir ;; esac
  PROJECT=$dir
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  version=$(jg_current_version_branch "$dir") || version=$(cfg branch)
  [ -n "$version" ] || return 0
  VERSION=$version
  NAME=$(printf '%s' "$version" | tr '/' '-')
  default=$(jg_default_branch "$dir") || default=main
  DEFAULT=$default
  vref=$(ref_of "$dir" "$version") || return 0
  dref=$(ref_of "$dir" "$default") || return 0
  CHANGES=$(git -C "$dir" rev-list --count "$dref..$vref" 2>/dev/null) || CHANGES=0
  BEHIND=$(git -C "$dir" rev-list --count "$vref..$dref" 2>/dev/null) || BEHIND=0
  stat=$(git -C "$dir" diff --shortstat "$dref...$vref" 2>/dev/null) || stat=''
  add=$(printf '%s' "$stat" | sed -n 's/.* \([0-9][0-9]*\) insertion.*/\1/p')
  del=$(printf '%s' "$stat" | sed -n 's/.* \([0-9][0-9]*\) deletion.*/\1/p')
  LINES="+${add:-0}/-${del:-0}"
  FILES=$(git -C "$dir" diff --name-only "$dref...$vref" 2>/dev/null | wc -l | tr -d ' ')
  [ "$CHANGES" -gt 0 ] || { STATE_W=empty; return 0; }
  jg_pr_repo_from_git_url "$(git -C "$dir" remote get-url origin 2>/dev/null)" || SLUG=
  SLUG=${JG_PR_GIT_REPO:-}
  if [ -z "$SLUG" ] || ! command -v gh >/dev/null 2>&1; then
    STATE_W=unknown
    CI=unknown
    OPEN=-1
    return 0
  fi
  OPEN=$(gh_call api "repos/$SLUG/pulls?state=open&base=$version&per_page=100" --jq 'length' 2>/dev/null) \
    || OPEN=-1
  CI=$(checks_state "$SLUG" "$(git -C "$dir" rev-parse "$vref")")
  if [ "$OPEN" -lt 0 ] || [ "$CI" = unknown ]; then
    STATE_W=unknown
  elif [ "$OPEN" -gt 0 ]; then
    STATE_W=open
  elif [ "$BEHIND" -gt 0 ]; then
    STATE_W=behind
  elif [ "$CI" = red ]; then
    STATE_W=red
  elif [ "$CI" = pending ]; then
    STATE_W=pending
  else
    STATE_W=ready
  fi
}

# The card's text. It names no internal word beyond what the compare link shows,
# because the board's ask rules refuse a card that does (bin/jg-ask-gate-lib.sh).
card_title() { printf 'Ship the next release now?\n'; }

card_why() {
  printf 'All %s are in, it matches the live version and the checks are green. It only needs your approval.\n' \
    "$(changes_word "$CHANGES")"
}

# The card is its measurement and nothing else: no clock ever enters it, so an
# unchanged release keeps exactly one card. The wait is what the alert measures.
card_detail() {
  printf 'Ships: %s, %s lines across %s.\n' \
    "$(changes_word "$CHANGES")" "$LINES" "$(count_word "$FILES" file)"
  printf 'Everything it changes: %s\n' "$(record_url)"
  printf 'Risks: all of it goes live at once, and none of it has run in production yet.\n'
}

# The release's own compare page: the captain opens it to read the change list.
record_url() {
  local host=github.com url
  url=$(git -C "$PROJECT" remote get-url origin 2>/dev/null) || url=''
  jg_pr_repo_from_git_url "$url"
  host=${JG_PR_GIT_HOST:-$host}
  [ -n "${JG_PR_GIT_REPO:-}" ] || return 0
  printf 'https://%s/%s/compare/%s...%s\n' "$host" "$JG_PR_GIT_REPO" "$DEFAULT" "$VERSION"
}

card_hash() {
  { card_title; card_why; card_detail; } | cksum | tr -d ' \n'
}

# Append the measurement when it changed since the last row.
record_state() {
  local cur last
  cur=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$STATE_W" "$CHANGES" "$OPEN" "$BEHIND" "$CI" "$LINES" "$FILES" "$VERSION")
  last=$(tail -n 1 "$STATE" 2>/dev/null \
    | jq -r '[.state,(.changes|tostring),(.open|tostring),(.behind|tostring),.ci,.lines,(.files|tostring),.version] | @tsv' 2>/dev/null) \
    || last=''
  [ "$cur" = "$last" ] && return 0
  mkdir -p "$DIR"
  jq -cn --argjson at "$now" --arg state "$STATE_W" --argjson changes "$CHANGES" \
    --argjson open "$OPEN" --argjson behind "$BEHIND" --arg ci "$CI" --arg lines "$LINES" \
    --argjson files "$FILES" --arg version "$VERSION" --arg default "$DEFAULT" \
    '{at: $at, state: $state, changes: $changes, open: $open, behind: $behind, ci: $ci,
      lines: $lines, files: $files, version: $version, default: $default}' >> "$STATE" \
    || die "cannot record the measurement in $STATE"
}

# The epoch the current contiguous run of <state> began, or <now> for the first.
state_since() {  # <state>
  local st at since=$now
  while IFS=$'\t' read -r st at; do
    [ "$st" = "$1" ] || break
    since=$at
  done <<EOF
$(jq -sr 'reverse | .[] | [.state, (.at|tostring)] | @tsv' "$STATE" 2>/dev/null)
EOF
  printf '%s\n' "$since"
}

# Is this exact card already waiting on the board? A card that waits is one the
# captain has not answered, so it is never raised a second time.
card_open() {  # <key>
  local board out
  command -v sign-off-axi >/dev/null 2>&1 || return 1
  board=$(cfg board)
  if [ -n "$board" ]; then
    out=$(sign-off-axi list "$board" --json 2>/dev/null)
  else
    out=$(sign-off-axi list --json 2>/dev/null)
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -e --arg k "$1" '[(.decisions // [])[]? | select(.key == $k)] | length > 0' \
    >/dev/null 2>&1
}

# Raise the one release card, replacing the previous one so the board holds one.
raise_card() {  # <key> <hash>
  local key=$1 hash=$2 board filer args=() prev out
  board=$(cfg board)
  filer=$(cfg filer)
  [ -z "$board" ] || args+=(--board "$board")
  # The previous card goes first: a board refuses a new ask that repeats one
  # still waiting, and this card is meant to replace it rather than join it.
  prev=$(tail -n 1 "$CARDS" 2>/dev/null | jq -r '.key // empty' 2>/dev/null) || prev=''
  if [ "$DISMISS" = 1 ] && [ -n "$prev" ] && [ "$prev" != "$key" ] \
    && command -v sign-off-axi >/dev/null 2>&1; then
    if [ -n "$board" ]; then
      sign-off-axi dismiss "$prev" "$board" --reason replaced >/dev/null 2>&1 || true
    else
      sign-off-axi dismiss "$prev" --reason replaced >/dev/null 2>&1 || true
    fi
  fi
  out=$("$CARD_POST" post ${args[@]+"${args[@]}"} \
    --must public-release --filer "${filer:-release-readiness}" \
    --ask-ref "$key" --key "$key" \
    --title "$(card_title)" --why "$(card_why)" --detail "$(card_detail)" \
    --outcome yes="It ships now." --outcome no="It keeps waiting." \
    --recommend yes --recommend-reason "Everything in it is green." --default no) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  mkdir -p "$DIR"
  jq -cn --argjson at "$now" --arg key "$key" --arg hash "$hash" \
    '{at: $at, key: $key, hash: $hash}' >> "$CARDS" || die "cannot record the card in $CARDS"
  printf '%s\n' "$key"
}

alerted() {  # <since>
  [ -s "$ALERTS" ] || return 1
  jq -e --argjson s "$1" 'select(.since == $s)' "$ALERTS" >/dev/null 2>&1
}

raise_alert() {  # <since> <hours>
  local since=$1 hours=$2 out
  # JG_HOME is the ticked home, never this script's own repository: the alert
  # belongs to the fleet that owns the release.
  out=$(JG_HOME="$home" "$ALERT_NOTE" note --request-id "release-readiness-$since" \
    "The next release ($VERSION) waited $hours hours for approval: $CHANGES changes are green and nothing shipped. Approve the release card to ship it." 2>&1) \
    || { printf 'jg-release-readiness: the alert was not queued: %s\n' "$out" >&2; return 1; }
  mkdir -p "$DIR"
  jq -cn --argjson at "$now" --argjson since "$since" --argjson hours "$hours" \
    '{at: $at, since: $since, hours: $hours}' >> "$ALERTS" || die "cannot record the alert in $ALERTS"
}

tick() {
  local hash key last hours wait
  measure
  [ "$STATE_W" = none ] || record_state
  SINCE=$(state_since "$STATE_W")
  if [ "$STATE_W" != ready ]; then
    printf 'not ready: %s\n' "$STATE_W"
    return 0
  fi
  hash=$(card_hash)
  # One key per card text: an unchanged card keeps its key and is never raised
  # twice, while a changed one is a new card that replaces the last.
  key="$NAME-$hash"
  last=$(tail -n 1 "$CARDS" 2>/dev/null | jq -r '.hash // empty' 2>/dev/null) || last=''
  if ! card_open "$key" && [ "$hash" != "$last" ]; then
    raise_card "$key" "$hash" >/dev/null || { printf 'the release card was not raised\n' >&2; return 1; }
    printf 'card: %s\n' "$key"
  fi
  hours=$(( (now - SINCE) / 3600 ))
  wait=$(cfg wait-hours)
  case $wait in ''|*[!0-9]*) wait=24 ;; esac
  if [ $((now - SINCE)) -ge $((wait * 3600)) ] && ! alerted "$SINCE"; then
    raise_alert "$SINCE" "$hours" || return 1
    printf 'alert: the release has waited %s hours for approval (limit %s)\n' "$hours" "$wait"
    return 0
  fi
  [ "$hash" = "$last" ] && [ "$(state_since "$STATE_W")" = "$SINCE" ] \
    && printf 'unchanged: the release card and its wait are as the last pass left them\n'
  return 0
}

show() {
  local hours
  measure
  case $STATE_W in
    none) line='Release: no release is in progress' ;;
    empty) line='Release: nothing is waiting to ship in the next release' ;;
    unknown) line='Release: the next release cannot be checked right now' ;;
    open) line="Release: not ready, $(changes_word "$OPEN") still open" ;;
    behind) line="Release: not ready, $(changes_word "$BEHIND") of the live version are not in it" ;;
    red) line='Release: not ready, the checks on it are red' ;;
    pending) line='Release: not ready, the checks on it are still running' ;;
    ready)
      SINCE=$(state_since ready)
      hours=$(( (now - SINCE) / 3600 ))
      if [ "$hours" -ge 1 ]; then
        line="Release: ready to ship, $(changes_word "$CHANGES") green, waiting $hours h for your approval"
      else
        line="Release: ready to ship, $(changes_word "$CHANGES") green, waiting for your approval"
      fi
      ;;
    *) line='Release: no release is in progress' ;;
  esac
  printf '%s\n' "$line"
}

[ "$#" -ge 2 ] || die "usage: jg-release-readiness.sh <home> tick|show [--now <epoch>]"
home=$(cd "$1" 2>/dev/null && pwd -P) || die "no home at $1"
shift
verb=$1
shift
now=$(date +%s)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now) [ "$#" -ge 2 ] || die "--now needs epoch seconds"; now=$2; shift 2 ;;
    *) die "unknown flag $1" ;;
  esac
done
case $now in ''|*[!0-9]*) die "--now needs epoch seconds" ;; esac

DATA=${JG_DATA_OVERRIDE:-$home/data}
CFG=${JG_CONFIG_OVERRIDE:-$home/config}
# The poster and the alerter are injectable for tests and fixtures, the same way
# bin/jg-status-digest.sh injects its poster; both keep the real scripts' own
# argument shapes.
CARD_POST=${JG_RELEASE_CARD_POST:-$SCRIPT_DIR/jg-question-card.sh}
ALERT_NOTE=${JG_RELEASE_ALERT_NOTE:-$SCRIPT_DIR/jg-inbox.sh}
DISMISS=1
[ -z "${JG_RELEASE_CARD_POST:-}" ] || DISMISS=0
DIR=$DATA/release-readiness
STATE=$DIR/state.jsonl
CARDS=$DIR/cards.jsonl
ALERTS=$DIR/alerts.jsonl
cfg() { sed -n "s/^$1=//p" "$CFG/release-readiness" 2>/dev/null | tail -n 1; }

STATE_W=none CHANGES=0 OPEN=0 BEHIND=0 CI=green LINES='+0/-0' FILES=0
VERSION='' DEFAULT='' SLUG='' PROJECT='' SINCE=0 NAME='' line=''

case $verb in
  tick) tick ;;
  show) show ;;
  *) die "unknown verb $verb: use tick or show" ;;
esac
