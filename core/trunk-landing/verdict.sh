#!/usr/bin/env bash
# verdict.sh - what a refused landing's record says, and whether a stored verdict still holds (sourced by trunk-landing.sh).
#
# One owner for the landing check's verdicts, so a single landing (`run`) and a stack (`runbatch`) follow the same rules:
#   1. The state line of a refusal comes from the `refusal-class <id>: wait|retry|final` line bin/jg-trunk.sh prints (its
#      classify_refusal owns the phrase lists). A landing another run already holds (`IN_PROGRESS:`, no class) waits. Anything else
#      is final. A retry counts its tries in <task>.<head>.retries; the RETRY_CAP-th try is final, so a lane the machine failed is
#      never retried for ever and never forgotten. A retry is tried again after its 2 minute backoff (verdict_due). A wait is tried
#      again by every check sweep, and by the start a finished landing chains (`next`) after the same backoff: a sweep starts nothing
#      while a landing runs, so under a steady queue only `next` reaches a wait lane, and the backoff keeps a lane its own landing
#      just refused from restarting itself in a loop. The lander's admission re-judges whether the wait's reason still holds.
#   2. Every verdict is stored with the trunk tip it was judged on, in <task>.<head>.tip beside <task>.<head>.state, the way
#      `jg-trunk.sh land` keys its own admission record by the tip. For one lane it is the tip read before the landing started; for a
#      stack it is the tip after the stack's own landings, because a returned lane was judged on top of the stack's lanes that landed.
#   3. A final conflict, or a final for a trunk something else moved (a home on older code stored it final), holds only while that tip stands: once the trunk moved, the lane is judged again (a conflict attempt stops
#      at the rebase, before any gate). A conflict with no stored tip (a record from before this rule) is judged again once.
#      Every other final (a red gate the lane caused, a second commit) holds for its head on any tip.
#   4. A final whose cause is the environment, not the commit's own content (a reference-transaction hook the lander may not replace),
#      holds for ENV_FINAL_MINUTES (10) and is then asked of the lander again. The lander's admission cache is keyed by every input the
#      refusal read (bin/jg-trunk.sh cmd_land), so an unrepaired cause is answered at once with no attempt and no gate, and a repaired
#      one lands. Without this the check kept its own `final` for the head and never asked, whatever the lander's key now said.
#   5. A worker is steered, and the lead told, only for a verdict that still holds; both key on verdict_reason, which leaves out of a
#      conflict the commit it was judged on and its attempt's log path, so a lane that still conflicts with the same paths after the tip
#      moved is not reported or steered as new, and its ten minute alert keeps counting.
# Needs from the caller: MEM (data/jg-trunk-landing) and STATE.

RETRY_CAP=3
ENV_FINAL_MINUTES=10
# A final refusal as bin/jg-trunk.sh words it when an environment fact, not the commit, refused the landing (rule 4).
VERDICT_ENV_RE='is not the trunk guard|cannot install |cannot resolve the effective reference-transaction hook'
# A conflict refusal as bin/jg-trunk.sh words it on both paths: "<branch> conflicts with <trunk> (<commit>) in: <paths>".
VERDICT_CONFLICT_RE=' conflicts with [^ ]+ \(([0-9a-f]+)\) in: '

# The trunk tip the lander will judge the next landing of <project-name> on.
verdict_tip() {  # <project-name>
  cat "$STATE/trunk-tip-$1" 2>/dev/null || :
}

# Whether a stored wait or retry verdict is due to be tried again: 2 minutes since it was recorded (rule 1).
verdict_due() {  # <state file>
  [ -n "$(find "$1" -mmin +2 2>/dev/null)" ]
}

# The state line for a refusal: `wait <reason>`, `retry <n> <reason>` or `final <reason>`.
verdict_line() {  # <id> <head> <jg-trunk output> <reason>
  local class n
  class=$(printf '%s\n' "$3" | sed -n "s/^refusal-class $1: //p" | tail -n 1)
  if [ -z "$class" ] && printf '%s\n' "$3" | grep -q '^IN_PROGRESS:'; then class='wait'; fi
  case $class in
    wait) printf 'wait %s\n' "$4" ;;
    retry)
      n=$(( $(cat "$MEM/$1.$2.retries" 2>/dev/null || echo 0) + 1 ))
      if [ "$n" -ge "$RETRY_CAP" ]; then printf 'final gave up after %s tries: %s\n' "$n" "$4"
      else printf '%s\n' "$n" > "$MEM/$1.$2.retries"; printf 'retry %s %s\n' "$n" "$4"; fi ;;
    *) printf 'final %s\n' "$4" ;;
  esac
}

# Record a refusal for <head>, with the tip it was judged on. When the lander left the lane's branch at another head, the same
# verdict (and its try count) stands for that head too.
verdict_record() {  # <id> <head> <head the branch is at now, or empty> <tip> <jg-trunk output> <reason>
  local line h
  line=$(verdict_line "$1" "$2" "$5" "$6")
  for h in "$2" "$3"; do
    [ -n "$h" ] || continue
    [ "$h" = "$2" ] || cp -f -- "$MEM/$1.$2.retries" "$MEM/$1.$h.retries" 2>/dev/null || :
    printf '%s\n' "$4" > "$MEM/$1.$h.tip"
    printf '%s\n' "$line" > "$MEM/$1.$h.state"
  done
}

# Whether the stored `final` verdict of <id> at <head> still holds on the trunk of <project-name> (rules 3 and 4).
verdict_holds() {  # <id> <head> <state line> <project-name>
  local tip
  case $3 in final*) ;; *) return 0 ;; esac
  if [[ $3 =~ $VERDICT_ENV_RE ]]; then [ -z "$(find "$MEM/$1.$2.state" -mmin +"$ENV_FINAL_MINUTES" 2>/dev/null)" ]; return; fi
  [[ $3 =~ $VERDICT_CONFLICT_RE || $3 == *'something else moved it'* ]] || return 0
  tip=$(cat "$MEM/$1.$2.tip" 2>/dev/null) || return 1
  [ -n "$tip" ] && [ "$tip" = "$(verdict_tip "$4")" ]
}

# Whether <id> was once refused for a conflict (any head): it comes back after fixing it, and lands before lanes ready earlier.
verdict_returned() {  # <id>
  local f
  for f in "$MEM/$1".*.state; do
    [ -f "$f" ] || continue
    [[ $(cat "$f") =~ ^final.*$VERDICT_CONFLICT_RE ]] && return 0
  done
  return 1
}

# The reason a report and a steer are keyed on: the stored reason, less a conflict's judged commit and attempt log (rule 5).
verdict_reason() {  # <reason>
  local r=$1
  if [[ $r =~ $VERDICT_CONFLICT_RE ]]; then r=${r/ (${BASH_REMATCH[1]}) in: / in: }; r=${r%%; full log: *}; fi
  printf '%s\n' "$r"
}
