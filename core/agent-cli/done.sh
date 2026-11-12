#!/usr/bin/env bash
# jg done [<text>]: the done line. With no text a local lane gets `ready in branch <branch> (<mode>)`;
# any other mode needs the text (name the pull request by its full URL). The guard refuses a
# done whose head the landing would refuse, and lists every gap.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_cli_context
text=$*
if [ -z "$text" ]; then
  mode=$(jg_cli_meta_get mode); branch=$(jg_cli_meta_get branch)
  case "$mode" in
    local*) text="ready in branch $branch ($mode)" ;;
    *) jg_cli_die "mode ${mode:-unknown} needs the text. Next: jg done 'PR ready: <full https URL>'" ;;
  esac
fi
jg_cli_status_append "done" "$text" || exit 1
echo "done recorded for $JG_CLI_TASK. Next: stop; a landing or a steer arrives by itself"
