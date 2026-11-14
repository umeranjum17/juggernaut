#!/usr/bin/env bash
# Drive the daily ticket clean-up on a throwaway home with a real Beads store and a real sign-off board, and save what a
# captain would see: the tickets before and after, the check's own line, its report file, and the question cards.
# gh-axi is the one stand-in (a PR's state lives on GitHub): PR 11 closed unmerged, PR 20 merged.
# Also runs the two clean-up tests and keeps their output. done-done holds the folder in DONE_DONE_EVIDENCE_ROOT.
set -euo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
root=$(cd "$(dirname "$0")" && pwd -P)
fork=${JG_TEST_FORK:-$(cd "$root/../.." && pwd -P)}
evidence=$DONE_DONE_EVIDENCE_ROOT
work=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-proof.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
bash "$root/tests/cleanup-acts.test.sh" >"$evidence/cleanup-acts-test.log" 2>&1
bash "$root/tests/cleanup-keeps-question.test.sh" >"$evidence/cleanup-keeps-question-test.log" 2>&1
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state} "$work/shim"
ln -sn "$fork/bin" "$JG_HOME/bin"
cat > "$work/shim/gh-axi" <<'SHIM'
#!/usr/bin/env bash
case "${2##*/}" in
  11) printf 'merged: false\nstate: closed\ndraft: false\n' ;;
  20) printf 'merged: true\nstate: closed\ndraft: false\n' ;;
  *) printf 'merged: false\nstate: open\ndraft: false\n' ;;
esac
SHIM
chmod +x "$work/shim/gh-axi"
export PATH=$work/shim:$PATH
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# shellcheck source=core/lib/beads-test-env.sh
. "$root/../lib/beads-test-env.sh"
core_beads_home "$fork" "$JG_HOME"
pr() { echo "https://github.com/example/alpha/pull/$1"; }
board() { (cd "$JG_HOME"; for id in jg-dead jg-dupa jg-dupb jg-sup jg-ask-dead jg-hold-dead jg-merged jg-flight; do
  printf '%-14s %s\n' "$id" "$(jg-backlog.sh show "$id" --full | sed -n 's/^  state: //p')"; done); }
(cd "$JG_HOME"
 jg-backlog.sh add jg-dead 'Umer closed work' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh add jg-dupa 'Umer same words' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-dupb 'Umer same words' --repo alpha --priority 2 >/dev/null
 jg-backlog.sh add jg-sup 'Umer old plan' --repo alpha --priority 2 --body 'status: superseded' >/dev/null
 jg-backlog.sh add jg-ask-dead '[captain-ask] P0 Umer wants this' --repo alpha --priority 0 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh add jg-hold-dead 'Umer held closed work' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh hold jg-hold-dead --reason 'Captain decides whether to delete it' --kind captain >/dev/null
 jg-backlog.sh add jg-merged 'Umer shipped' --repo alpha --priority 2 --body "pr: $(pr 20)" >/dev/null
 jg-backlog.sh add jg-flight 'Umer worker running' --repo alpha --priority 2 --body "pr: $(pr 11)" >/dev/null
 jg-backlog.sh start jg-flight >/dev/null)
board > "$evidence/tickets-before.txt"
sign-off-axi raise "$work/board.json" --key q-closed --ask-ref q-closed --title 'Delete the abandoned export rewrite?' \
  --why "Nobody merged it: $(pr 11)" --outcome yes='Main deletes it.' --outcome no='It stays.' --recommend no \
  --recommend-reason 'Nothing is lost.' --default no >/dev/null
bash "$root/wiring.sh" >/dev/null
"$JG_HOME/state/tickets-cleanup.check.sh" | tee "$evidence/cleanup-check-line.txt" >/dev/null
board > "$evidence/tickets-after.txt"
(cd "$JG_HOME"; jg-backlog.sh show jg-dead --full) > "$evidence/closed-ticket-note.txt"
cp "$JG_HOME/state/tickets-sync/cleanup-$(date -u +%F).txt" "$evidence/cleanup-report.txt"
sign-off-axi list "$work/board.json" --json | jq '[.decisions[] | {key, dismissed: (.dismissed // false)}]' > "$evidence/question-cards.json"
jq -e '.[] | select(.key == "q-closed") | .dismissed == false' "$evidence/question-cards.json" >/dev/null
grep -q '^jg-dead  *done$' "$evidence/tickets-after.txt" && grep -q '^jg-ask-dead  *\(queued\|open\|ready\)' "$evidence/tickets-after.txt"
jq -n '{target:{version:"daily ticket clean-up"},start:"A throwaway home holds a Beads store with closed-unmerged, duplicate and superseded tickets, a captain ask, a captain hold and a running worker on closed work, plus a question card about closed work.",steps:["Run the daily clean-up check on that home.","Read each ticket state before and after.","Read the closed ticket note for its recorded reason.","Read the clean-up report file.","Read the question card state on the board."],result:"The closed-unmerged, duplicate and superseded tickets are done with a reason in their note, the captain ask, the held ticket and the running worker stay open, and the question card about closed work is still waiting."}' > "$evidence/steps.json"
