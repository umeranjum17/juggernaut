#!/usr/bin/env bash
# decision-handler.sh - a worker's own question (`jg ask`, a `needs-decision` line) is answered by this home with no Main turn.
#
# Usage: decision-handler.sh tick        one pass over every open worker question in this home's state
#        decision-handler.sh show <task> the handler's record of that task's questions
#
# The wait ladder (core/wait-timers) pages the holder and then Main; a page never resolves the question. This is the step
# that does: it reads each open decision the worker raised about its own work, settles it inside the authority
# `.agents/skills/ask-user-authority` owns, and sends the answer to that exact worker with `bin/jg-send.sh --resolve-key`,
# which delivers the steer and closes the wait in one write.
#
# One record per question, `$DATA/decision-handler/<id>` (id = hash of task, key and the question's own text, so a
# new question on the same key is a new record). Its states and the only moves between them:
#
#   (new)       -> escalated   the question or an option names a boundary (a credential, a discard, a waived proof, a
#                              scope or release change, a merge): left to the existing authority, never answered here
#   (new)       -> answered    a recorded answer to the same question, else the advisor's pick (an option, reason, proof)
#   (new)       -> (new)       the advisor failed or picked no option: one more attempt on a later tick
#   (new)       -> escalated   the advisor failed three times, said the question is the owner's, or none is configured
#   answered    -> delivered   `jg-send --resolve-key` succeeded and the wait is closed
#   answered    -> answered    the send failed: the same pick is sent again on the next tick (a lost delivery stays pending)
#   delivered   -> answered    the same question is open again (a worker asked it twice): the recorded pick is sent again
#   delivered   -> escalated   it was sent twice and the question is still open
#   escalated   -> (none)      the handler leaves it to the ladder; nothing more is written
# A duplicate tick, a second handler or a restart reads the record first, so one question gets one answer and one send.
#
# Not taken here: a `owner-call` (the captain's question, `jg ask --owner`), a validation gate finding (key `nm-*`, owned by
# validation-supervision) and any reserved supervisor key. `status_own_open_decisions` leaves out the reserved keys.
#
# The advisor is a command: the environment's JG_DECISION_ADVISOR_CMD, else the first line of `config/decision-advisor`, else
# `codex exec ... --sandbox read-only --model gpt-6-astra -` (plan only: a read-only sandbox, so it can propose and cannot
# change anything). The prompt goes on stdin and the reply's last line is JSON: {"pick","reason","proof"} or {"escalate":true,
# "reason"}. The prompt carries the question, its options, the worker's recommendation and the task's accepted intent
# (the brief's `## Captain's intent` and `## Juggernaut spec`).
#
# Env: JG_HOME, JG_STATE_OVERRIDE, JG_DATA_OVERRIDE, JG_CONFIG_OVERRIDE, JG_DECISION_ADVISOR_CMD, JG_DECISION_ADVISOR_SECS (300),
# JG_DECISION_BOUNDARY (an extended regex that replaces the boundary words below).
# Exit 0 after a pass (prints one line per move), 2 on a usage or setup error.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
RECORDS=$DATA/decision-handler
SEND=${JG_DECISION_SEND:-$ROOT/bin/jg-send.sh}
BOUNDARY=${JG_DECISION_BOUNDARY:-'credential|secret|password|(auth|access|api|bearer) token|api[ _-]?key|discard|delete|destroy|force[ -]?push|irreversible|waive|skip (the )?(proof|test|check|review)|scope|release|go live|merge'}
MAX_ADVISOR=3 MAX_DELIVERIES=2

die() { printf 'decision-handler: %s\n' "$*" >&2; exit 2; }
# shellcheck source=bin/jg-classify-lib.sh
. "$ROOT/bin/jg-classify-lib.sh" || die "cannot read the status classifier"

advisor_cmd() {
  local f=$CONFIG/decision-advisor
  if [ -n "${JG_DECISION_ADVISOR_CMD:-}" ]; then printf '%s' "$JG_DECISION_ADVISOR_CMD"
  elif [ -s "$f" ]; then head -n 1 "$f"
  else printf '%s' 'codex exec --skip-git-repo-check --sandbox read-only --model gpt-6-astra -'; fi
}

record_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
record_put() {  # <file> <field> <value>: one field, replaced in place
  local f=$1 tmp
  tmp=$(mktemp "$f.XXXXXX") || return 1
  { grep -v "^$2=" "$f" 2>/dev/null; printf '%s=%s\n' "$2" "$3"; } > "$tmp" && mv -f "$tmp" "$f"
}
one_line() { printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-600; }

# The options the worker listed: `<question> Options: a | b. Recommend: a.` (core/agent-cli/ask.sh writes exactly this form).
options_of() { printf '%s' "$1" | sed -n 's/.* Options: \(.*\)$/\1/p' | sed 's/\. Recommend: .*$//; s/\.$//' | tr '|' '\n' | sed 's/^ *//; s/ *$//'; }
recommend_of() { printf '%s' "$1" | sed -n 's/.* Recommend: \(.*\)\.$/\1/p'; }
question_of() { printf '%s' "$1" | sed 's/ Options: .*$//'; }

intent_of() {  # <task>: the accepted intent a decision is judged against
  local brief=$DATA/$1/brief.md
  [ -f "$brief" ] || { echo '(no brief recorded)'; return; }
  awk '/^## (Captain.s intent|Juggernaut spec)$/ { on = 1; print; next } /^#{1,2} / { on = 0 } on' "$brief" | head -c 4000
}

ask_advisor() {  # <task> <note>: prints the advisor's last JSON line, or nothing
  local task=$1 note=$2 prompt cmd out
  cmd=$(advisor_cmd)
  prompt=$(printf 'You advise on one engineering question a worker raised. Plan only: change nothing.\nDecide it from the accepted intent below, or say it is the owner'"'"'s call.\nReply with one JSON line: {"pick":"<exactly one option>","reason":"<why>","proof":"<what shows it is right>"} or {"escalate":true,"reason":"<why>"}.\n\nQuestion: %s\nOptions:\n%s\nWorker recommends: %s\n\nAccepted intent:\n%s\n' \
    "$(question_of "$note")" "$(options_of "$note" | sed 's/^/- /')" "$(recommend_of "$note")" "$(intent_of "$task")")
  # shellcheck disable=SC2086 # the command is a configured word list
  out=$(printf '%s' "$prompt" | timeout "${JG_DECISION_ADVISOR_SECS:-300}" $cmd 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep '^{' | tail -n 1
}

send_answer() {  # <task> <key> <pick> <reason> <proof>
  local text="Decision answered: $3. Reason: $4. Proof: $5. Continue with this option; do not ask this question again."
  JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SEND" "$1" --resolve-key "$2" "$(one_line "$text")" >/dev/null 2>&1
}

handle() {  # <task> <key> <verb> <note>
  local task=$1 key=$2 note=$4 id rec state pick reason proof n json opts
  id=$(printf '%s\t%s\t%s' "$task" "$key" "$note" | sha256sum | cut -c1-16)
  rec=$RECORDS/$id
  mkdir -p "$RECORDS" || return 0
  if [ ! -f "$rec" ]; then
    printf 'task=%s\nkey=%s\nstate=new\nadvisor=0\ndeliveries=0\n' "$task" "$key" > "$rec"
  fi
  state=$(record_get "$rec" state)
  case $state in
    escalated) return 0 ;;
    delivered)
      n=$(record_get "$rec" deliveries)
      if [ "${n:-0}" -ge "$MAX_DELIVERIES" ]; then record_put "$rec" state escalated; echo "escalated $task $key: answered twice and still open"; return 0; fi
      record_put "$rec" state answered; state=answered ;;
  esac
  if [ "$state" = new ]; then
    opts=$(options_of "$note")
    if [ -z "$opts" ] || printf '%s\n%s\n' "$(question_of "$note")" "$opts" | grep -Eiq "$BOUNDARY"; then
      record_put "$rec" state escalated; echo "escalated $task $key: boundary or no options, left to the existing authority"; return 0
    fi
    n=$(record_get "$rec" advisor)
    json=$(ask_advisor "$task" "$note") || json=''
    record_put "$rec" advisor $(( ${n:-0} + 1 ))
    if printf '%s' "$json" | jq -e '.escalate == true' >/dev/null 2>&1; then
      record_put "$rec" state escalated; echo "escalated $task $key: the advisor says it is the owner's call"; return 0
    fi
    pick=$(printf '%s' "$json" | jq -r '.pick // empty' 2>/dev/null)
    if [ -z "$pick" ] || ! printf '%s\n' "$opts" | grep -Fxq -- "$pick"; then
      if [ "$(record_get "$rec" advisor)" -ge "$MAX_ADVISOR" ]; then record_put "$rec" state escalated; echo "escalated $task $key: no usable advice after $MAX_ADVISOR tries"
      else echo "pending $task $key: no usable advice yet"; fi
      return 0
    fi
    reason=$(printf '%s' "$json" | jq -r '.reason // "no reason given"'); proof=$(printf '%s' "$json" | jq -r '.proof // "none stated"')
    record_put "$rec" pick "$(one_line "$pick")"; record_put "$rec" reason "$(one_line "$reason")"; record_put "$rec" proof "$(one_line "$proof")"
    record_put "$rec" state answered; state=answered
  fi
  pick=$(record_get "$rec" pick); reason=$(record_get "$rec" reason); proof=$(record_get "$rec" proof)
  if send_answer "$task" "$key" "$pick" "$reason" "$proof"; then
    record_put "$rec" deliveries $(( $(record_get "$rec" deliveries) + 1 )); record_put "$rec" state delivered
    echo "delivered $task $key: $pick"
  else
    echo "pending $task $key: send failed, the same answer is kept for the next tick"
  fi
}

tick() {
  local f task key verb note prefix
  prefix=$("$ROOT/bin/jg-classify.sh" human-call-prefix) || die "cannot read the owner-call prefix"
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=$(basename "$f" .status)
    while IFS=$'\t' read -r key verb note; do
      [ -n "$verb" ] || continue
      case $verb in needs-decision) ;; *) continue ;; esac
      case $key in nm-*) continue ;; esac
      case $note in "$prefix"*) continue ;; esac
      handle "$task" "$key" "$verb" "$note"
    done < <(status_own_open_decisions "$f")
  done
}

case ${1:-} in
  tick) tick ;;
  show) [ -n "${2:-}" ] || die "usage: decision-handler.sh show <task>"; grep -l "^task=$2\$" "$RECORDS"/* 2>/dev/null | while read -r r; do echo "# $(basename "$r")"; cat "$r"; done ;;
  *) die "usage: decision-handler.sh tick | show <task>" ;;
esac
