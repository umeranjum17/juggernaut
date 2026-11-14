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
#      A conflict is stored with the tip its refusal names (verdict_tip_met), the one the rebase met: a landing that ran beside the lane moves
#      the trunk during the run, and the tip read first would make the check judge the same head again at once.
#   3. A final for a trunk something else moved (a home on older code stored it final) holds only while that tip stands. A final conflict
#      holds while the commit its refusal names (the tip the rebase met, not the tip read before the run) is still the trunk's tip, or
#      while every path the trunk changed since touches none of the conflict's paths: only a trunk change to a conflicting path (or a
#      rename, which lists both names) can change the lane's conflict, so a landing beside it does not return the lane again. Any other
#      move judges the lane again (a conflict attempt stops at the rebase, before any gate), and so does a conflict whose commit is gone
#      from the project or whose paths are unreadable. A conflict with no stored tip (a record from before this rule) is judged again once.
#      Every other final (a red gate the lane caused, a second commit) holds for its head on any tip, but only while the inputs its
#      refusal read are the ones stored beside it (rule 6).
#   4. A final whose cause is the environment, not the commit's own content (a reference-transaction hook the lander may not replace),
#      holds for ENV_FINAL_MINUTES (10) and is then asked of the lander again. The lander's admission cache is keyed by every input the
#      refusal read (bin/jg-trunk.sh cmd_land), so an unrepaired cause is answered at once with no attempt and no gate, and a repaired
#      one lands. Without this the check kept its own `final` for the head and never asked, whatever the lander's key now said.
#   5. A worker is steered, and the lead told, only for a verdict that still holds; both key on verdict_reason, which leaves out of a
#      conflict the commit it was judged on and its attempt's log path, so a lane that still conflicts with the same paths after the tip
#      moved is not reported or steered as new, and its ten minute alert keeps counting.
#   6. Each verdict is stored with a fingerprint of the inputs a refusal reads (<task>.<head>.inputs, verdict_inputs): the lander's own code
#      (bin/jg-trunk.sh, bin/jg-merge-gate-lib.sh, bin/jg-dod-lib.sh in this home), the task's run receipt less its `at`, and its design
#      approval. A final other than rule 3 or 4 holds only while that fingerprint is the current one: a lander fixed after the refusal, or a
#      receipt published since, is asked again, the way the lander's own admission cache (bin/jg-trunk.sh cmd_land) already keys it. A final
#      stored with no fingerprint (a record from before this rule) is asked again once.
# Needs from the caller: MEM (data/jg-trunk-landing), STATE and FMH (the home whose bin/ is the lander).

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

# The trunk tip a refusal was judged on: for a conflict, the tip the lander's rebase met, which its refusal names (rule 2); otherwise <fallback>,
# the tip read before the run. A landing that ran beside this one moves the trunk during the run, so the tip read first is not the tip judged.
verdict_tip_met() {  # <project dir> <reason> <fallback tip>
  local met=
  if [[ $2 =~ $VERDICT_CONFLICT_RE ]]; then met=$(git -C "$1" rev-parse --verify --quiet "${BASH_REMATCH[1]}^{commit}" 2>/dev/null) || met=; fi
  printf '%s\n' "${met:-$3}"
}

# The fingerprint of what a refusal of <id> reads that can change without the head changing (rule 6).
verdict_inputs() {  # <id>
  {
    git hash-object "$FMH/bin/jg-trunk.sh" "$FMH/bin/jg-merge-gate-lib.sh" "$FMH/bin/jg-dod-lib.sh" 2>/dev/null || :
    jq -Sc 'del(.at)' "$STATE/$1.run-receipt.json" 2>/dev/null || :
    [ ! -f "$STATE/design-approvals/$1.handroll.json" ] || git hash-object "$STATE/design-approvals/$1.handroll.json"
  } | git hash-object --stdin
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
  local line h inputs
  line=$(verdict_line "$1" "$2" "$5" "$6"); inputs=$(verdict_inputs "$1")
  for h in "$2" "$3"; do
    [ -n "$h" ] || continue
    [ "$h" = "$2" ] || cp -f -- "$MEM/$1.$2.retries" "$MEM/$1.$h.retries" 2>/dev/null || :
    printf '%s\n' "$4" > "$MEM/$1.$h.tip"
    printf '%s\n' "$inputs" > "$MEM/$1.$h.inputs"
    printf '%s\n' "$line" > "$MEM/$1.$h.state"
  done
}

# Whether the trunk change between <judged commit> and <tip> leaves a conflict in <paths> (space separated) as it was (rule 3).
verdict_conflict_stands() {  # <project dir> <judged commit> <tip> <paths>
  local changed p c
  [ -d "$1" ] && [ -n "$4" ] && [ "$4" != 'an unreadable merge' ] || return 1
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || return 1
  changed=$(git -C "$1" diff --name-only --no-renames "$2" "$3" 2>/dev/null) || return 1
  [[ $changed != *\"* ]] || return 1  # git quotes an odd name: it cannot be compared, judge again
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [[ $c != *[[:space:]]* ]] || return 1  # a path with a space cannot be told apart in the refusal's list: judge again
    for p in $4; do [ "$p" != "$c" ] || return 1; done
  done <<<"$changed"
  return 0
}

# Whether the stored `final` verdict of <id> at <head> still holds on the trunk of <project-name> (rules 3 and 4).
verdict_holds() {  # <id> <head> <state line> <project-name> [<project dir>]
  local tip cur judged paths
  case $3 in final*) ;; *) return 0 ;; esac
  if [[ $3 =~ $VERDICT_ENV_RE ]]; then [ -z "$(find "$MEM/$1.$2.state" -mmin +"$ENV_FINAL_MINUTES" 2>/dev/null)" ]; return; fi
  if ! [[ $3 =~ $VERDICT_CONFLICT_RE || $3 == *'something else moved it'* ]]; then
    [ "$(cat "$MEM/$1.$2.inputs" 2>/dev/null)" = "$(verdict_inputs "$1")" ]; return
  fi
  tip=$(cat "$MEM/$1.$2.tip" 2>/dev/null) || return 1
  cur=$(verdict_tip "$4")
  if [[ $3 =~ $VERDICT_CONFLICT_RE ]]; then
    judged=${BASH_REMATCH[1]}; paths=${3#*" in: "}; paths=${paths%%;*}
    [ -n "$tip" ] && [ -n "$cur" ] || return 1
    [ "${cur:0:${#judged}}" != "$judged" ] || return 0
    verdict_conflict_stands "${5:-}" "$judged" "$cur" "$paths"; return
  fi
  [ -n "$tip" ] && [ "$tip" = "$cur" ]
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
