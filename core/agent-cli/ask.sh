#!/usr/bin/env bash
# jg ask "<question>" --option <a> --option <b> [--recommend <a>] [--owner [--must <category>]]
# One decision line (`needs-decision`) with the options and the recommendation. With --owner the
# question is the captain's: the ticket is first held for the captain (bin/jg-captain-hold.sh owns
# the hold and its board card), and the line names that hold, which the guard checks.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage='usage: jg ask "<question>" --option <a> --option <b> [--recommend <a>] [--owner [--must <category>]]'
question=''; options=(); rec=''; owner=0; must=''
while [ $# -gt 0 ]; do
  case $1 in
    --option) [ $# -ge 2 ] || jg_cli_die "$usage"; options+=("$2"); shift 2 ;;
    --recommend) [ $# -ge 2 ] || jg_cli_die "$usage"; rec=$2; shift 2 ;;
    --must) [ $# -ge 2 ] || jg_cli_die "$usage"; must=$2; shift 2 ;;
    --owner) owner=1; shift ;;
    -*) jg_cli_die "$usage" ;;
    *) question="${question:+$question }$1"; shift ;;
  esac
done
[ -n "$question" ] || jg_cli_die "$usage"
[ "${#options[@]}" -ge 2 ] || jg_cli_die "a question needs two options. $usage"
if [ -n "$rec" ]; then
  ok=0; for o in "${options[@]}"; do [ "$o" != "$rec" ] || ok=1; done
  [ "$ok" = 1 ] || jg_cli_die "--recommend must be one of the options"
fi
[ -z "$must" ] || [ "$owner" = 1 ] || jg_cli_die "--must goes with --owner"
jg_cli_context

opts=$(printf '%s | ' "${options[@]}"); opts=${opts% | }
text="$question Options: $opts."
[ -z "$rec" ] || text="$text Recommend: $rec."
if [ "$owner" = 1 ]; then
  args=(hold "$JG_CLI_TASK" --title "$question" --reason "$text")
  [ -z "$must" ] || args+=(--must "$must")
  "$JG_CLI_TOOLS/bin/jg-captain-hold.sh" "${args[@]}" || exit 1
  text="captain call, hold $JG_CLI_TASK: $text"
fi
jg_cli_status_append needs-decision "$text" || exit 1
echo "decision asked for $JG_CLI_TASK${owner:+ (held for the captain)}. Next: stop; the answer arrives as a steer"
