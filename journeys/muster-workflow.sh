#!/usr/bin/env bash
set -euo pipefail

evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
bin/jg-lint.sh --changed-base HEAD^ > "$evidence/workflow-lint.log" 2>&1
bash tests/jg-workflow-muster.test.sh > "$evidence/muster-workflow.log" 2>&1
bin/jg-test-run.sh tests/jg-muster*.test.sh tests/muster*.test.sh tests/jg-swarm-plan-muster.test.sh \
  tests/jg-workflow-parse.test.sh tests/jg-workflow-pick.test.sh tests/jg-workflow-owner.test.sh tests/jg-workflow-war-room.test.sh \
  > "$evidence/workflow-regressions.log" 2>&1
jq -n --arg version "$(git rev-parse HEAD)" --arg result "$(grep '^ok - .*start.*Blitz' "$evidence/muster-workflow.log")" '
  {target:{version:$version}, start:"Tickets in isolated homes with the same help desk project.",
   steps:["Choose each workflow on a ticket.", "Answer the posted Muster question and approve the pack.",
          "Approve the workflow plan and observe which slices Blitz arms."], result:$result}
' > "$evidence/steps.json"
