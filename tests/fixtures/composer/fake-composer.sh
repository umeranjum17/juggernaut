#!/usr/bin/env bash
# A throwaway Claude-shaped composer for tests: a bare ❯ box between two rules
# that echoes what it receives. Usage: fake-composer.sh <log-file> [swallow]
#   Enter submits the box (appends its text to <log-file>) unless `swallow` is
#   given, which models a swallowed Enter that leaves typed text in the box.
#   Ctrl+U clears the box. Ctrl+X ends the pane. The cursor sits in the box.
log=$1
mode=${2:-submit}
buf=
rule=; for _ in $(seq 60); do rule+=─; done
draw() {
  printf '\033[2J\033[H'
  printf '● Done. All checks pass.\n\n%s\n❯ %s\n%s\n  ? for shortcuts' "$rule" "$buf" "$rule"
  printf '\033[4;%dH' $((3 + ${#buf}))
}
stty -icanon -echo
draw
while IFS= read -rsn1 -d '' ch; do
  case "$ch" in
    $'\r'|$'\n') if [ "$mode" = submit ]; then printf '%s\n' "$buf" >> "$log"; buf=; fi ;;
    $'\025') buf= ;;
    $'\030') break ;;
    *) buf+=$ch ;;
  esac
  draw
done
