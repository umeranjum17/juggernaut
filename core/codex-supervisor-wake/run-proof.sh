#!/usr/bin/env bash
set -o pipefail
cat > "${DONE_DONE_EVIDENCE_ROOT:?}/steps.json" <<'JSON'
{"target":{"version":"candidate commit"},"start":"An isolated tmux supervisor with an empty composer.","steps":["Deliver a supervisor escalation to a Codex lead.","Read the submitted wake and its record."],"result":"The lead receives a short record-backed wake and the record contains the full digest."}
JSON
bash tests/jg-afk-inject-e2e.test.sh 2>&1 | tee "$DONE_DONE_EVIDENCE_ROOT/codex-supervisor-wake.log"
