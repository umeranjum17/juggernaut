# Board answer route

Board answer route: run `done-done run board-answer-route` (it runs `bash tests/jg-board-answers-route.test.sh` and writes its log into `$DONE_DONE_EVIDENCE_ROOT`); an answer to a card with no route file lands in the inbox of the task its card names (longest task-id prefix) in one pass and Main gets nothing, an answer whose card names no task still wakes Main, and a card posted with `bin/jg-question-card.sh` always writes its route file (screen: none).
