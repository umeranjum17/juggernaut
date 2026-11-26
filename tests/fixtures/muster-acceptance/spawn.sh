#!/usr/bin/env bash
# Start the real Scout in a disposable fixture worktree. The terminal never starts a model.
set -euo pipefail
task=$1 project=$2
shift 2
worktree=$ACCEPT_TMP/worker-$task
git -C "$project" worktree add -q --detach "$worktree" HEAD
JG_SPAWN_NO_GUARD=1 JG_FAKE_PANE_PATH="$worktree" TMUX=fake,1,0 PATH="$ACCEPT_FAKEBIN:$PATH" \
  "$ROOT/bin/jg-spawn.sh" "$task" "$project" "$@"

brief=$JG_DATA_OVERRIDE/$task/brief.md
lens=$(sed -n 's/^Lens: //p' "$brief")
case "$lens" in
  user)
    printf '## Questions\n- Q: Which language should the bot use? | A: | owner: yes\n' ;;
  domain)
    printf '## Questions\n- Q: Where should the help pages live? | A: | owner: yes\n'
    printf '## Core objects\n- Object: Conversation | states: awaiting_answer, answered, handed_off, resolved | events: ConversationStarted, Answered, HandedOff, Resolved\n' ;;
  *) exit 0 ;;
esac > "$JG_DATA_OVERRIDE/$task/report.md"
JG_WAR_ROOM_NEXT=0 "$ROOT/bin/jg-recon-handoff.sh" draft "$task" >/dev/null
