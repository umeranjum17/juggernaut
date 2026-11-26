#!/usr/bin/env bash
# tests/jg-muster-drafts.test.sh - pull early drafts of every Muster document at three stages, send two back with notes, and see
# the new version's diff and the documents flagged to re-check (bin/jg-muster-drafts.sh, reached the way the captain reaches it).
# Every call runs on a throwaway home and project; no live home is read.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip - jq is not installed\n'; exit 0; }
TMP_ROOT=$(jg_test_tmproot jg-muster-drafts)
FIXTURE=$ROOT/tests/fixtures/muster/example/helpdesk
export JG_HOME=$TMP_ROOT/home JG_DATA_OVERRIDE=$TMP_ROOT/home/data JG_STATE_OVERRIDE=$TMP_ROOT/home/state \
  JG_PROJECTS_OVERRIDE=$TMP_ROOT/home/projects HOME=$TMP_ROOT/user
unset JG_ROOT_OVERRIDE JG_TASK_ID
P=$JG_PROJECTS_OVERRIDE/helpdesk
mkdir -p "$P/docs" "$JG_DATA_OVERRIDE" "$JG_STATE_OVERRIDE" "$HOME"

jg() {  # the words of the one-line envelope the command prints, or the refusal's
  "$ROOT/bin/jg" "$@" 2>/dev/null | jq -r 'if .ok then (.data.stdout // (.data | tostring)) else .data.error end'
}
drafts() { jg muster drafts helpdesk "$@"; }
line() { grep -F "$1 |" <<<"$2" || true; }
stage() {  # <path>...: the project holds exactly these fixture files
  find "$P" -mindepth 1 -delete
  local f
  for f in "$@"; do mkdir -p "$P/$(dirname "$f")"; cp "$FIXTURE/$f" "$P/$f"; done
}

# --- stage 1: only the vision exists
stage docs/vision.md
out=$(drafts)
assert_contains "$out" 'docs/vision.md | draft | v1 | first draft | open: nothing' 'stage 1 lists the vision as a first draft'
assert_not_contains "$out" 'GLOSSARY.md' 'stage 1 lists only what exists'

# --- stage 2: the language and the model join, and the vision is still the first version
stage docs/vision.md GLOSSARY.md docs/domain/model.md docs/ways-of-working.md
out=$(drafts)
assert_contains "$out" 'docs/domain/model.md | draft | v1' 'stage 2 shows the domain model'
assert_contains "$out" 'docs/vision.md | draft | v1' 'stage 2 keeps one version of an unchanged document'

# --- stage 3: the whole pack
stage docs/vision.md GLOSSARY.md docs/domain/model.md docs/ways-of-working.md docs/use-cases.md docs/design/visual-direction.md \
  docs/design/helpdesk.md docs/charter.md docs/specs/helpdesk.md docs/adr/0001-use-typescript-on-node.md \
  docs/adr/0002-keep-conversations-in-one-store-file.md docs/adr/0003-host-on-one-small-server.md
out=$(drafts --json)
assert_equals 12 "$(jq '.documents | length' <<<"$out")" 'stage 3 shows every document of the pack'
assert_equals true "$(jq '[.documents[].status == "draft"] | all' <<<"$out")" 'a pulled draft is a draft'
board=$(jq -r .board <<<"$out")
folder=$(jq -r .folder <<<"$out")
[ -s "$board" ] || fail "no board page at $board"
[ -s "$folder/documents/docs/vision.md" ] || fail 'the folder holds no copy of the vision'
assert_contains "$(cat "$board")" 'docs/charter.md' 'the board page lists the charter'
pass 'drafts are pulled at three stages as a table, a board page and a folder'

# --- send two documents back with notes; an unknown, an ambiguous and an empty ask are refused
out=$(jg muster revise helpdesk vision --note 'Say who pays for the bot.')
assert_contains "$out" 'docs/vision.md: draft -> discussion' 'the vision goes back to discussion'
out=$(jg muster revise helpdesk domain-model --note 'The rating belongs on the conversation.' --source war-room)
assert_contains "$out" 'docs/domain/model.md: draft -> discussion' 'the domain model goes back to discussion'
assert_contains "$(jg muster revise helpdesk adr --note x)" 'name one path' 'a kind that names several documents is refused'
assert_contains "$(jg muster revise helpdesk nothing --note x)" 'no document named nothing' 'an unknown document is refused'
assert_contains "$(jg muster revise helpdesk vision --note ' ')" 'say what to change' 'an empty note is refused'
out=$(drafts)
assert_contains "$(line docs/vision.md "$out")" 'discussion | v1' 'the vision waits in discussion'
assert_contains "$(line docs/vision.md "$out")" 'sent back: Say who pays for the bot. (captain)' 'the captain sees the open note'
assert_contains "$(line docs/domain/model.md "$out")" '(war-room)' 'a War Room request is told apart from the captain'

# --- the drafter revises both: a new version with its diff, and the documents written from them are flagged
printf '\nPayers are the budget owners.\n' >> "$P/docs/vision.md"
printf '\nA rating belongs to one resolved conversation.\n' >> "$P/docs/domain/model.md"
out=$(drafts)
assert_contains "$(line docs/vision.md "$out")" 'draft | v2 | +2 -0 since v1 | open: nothing' 'the vision shows its second version and what changed'
assert_contains "$(line docs/domain/model.md "$out")" 'draft | v2 | +2 -0 since v1' 'the domain model shows its second version'
assert_contains "$(line GLOSSARY.md "$out")" 're-check: docs/vision.md v2 changed' 'the glossary is flagged after the vision changed'
assert_contains "$(line docs/use-cases.md "$out")" 're-check: docs/domain/model.md v2 changed' 'the use cases are flagged after the model changed'
assert_contains "$(line docs/vision.md "$out")" 'open: nothing' 'a revised document is not flagged by itself'
assert_contains "$(cat "$folder/diffs/docs__vision.diff")" '+Payers are the budget owners.' 'the folder holds the diff'
assert_contains "$(cat "$board")" 'Payers are the budget owners.' 'the board page shows the diff'
v1=$(cat "$JG_DATA_OVERRIDE/muster-drafts/helpdesk/versions/docs__vision/v1.md")
assert_not_contains "$v1" 'budget owners' 'the first version is kept as it was'

# --- a re-check closes by a new version or by `checked`, never by rewriting
out=$(jg muster checked helpdesk glossary)
assert_contains "$out" 'GLOSSARY.md: re-check recorded' 'a re-check closes with nothing to change'
assert_not_contains "$(line GLOSSARY.md "$(drafts)")" 'vision.md v2' 'the closed re-check no longer shows for the vision'
assert_contains "$(jg muster checked helpdesk vision)" 'no re-check open' 'a document with no re-check cannot be checked'
assert_contains "$(cat "$P/GLOSSARY.md")" 'Glossary' 'no document was rewritten by the flags'

# --- all documents go back at once, and the same command works through the older revise verb
out=$(jg muster revise helpdesk all --note 'Read it once more for plain words.')
assert_equals 12 "$(grep -c 'draft -> discussion' <<<"$out")" 'all sends every document back'
out=$(drafts)
assert_equals 12 "$(grep -c '| discussion |' <<<"$out")" 'every document waits in discussion'
pass 'two documents are sent back, the new versions show diffs and their dependants are flagged'

# --- a document the pack marks abandoned is left alone by `all`
printf -- '---\nstatus: abandoned\n---\n# Old charter\n' > "$P/docs/charter.md"
out=$(jg muster revise helpdesk all --note 'Again.')
assert_equals 11 "$(grep -c 'draft -> discussion\|discussion -> discussion' <<<"$out")" 'all skips an abandoned document'
assert_contains "$(line docs/charter.md "$(drafts)")" 'abandoned' 'an abandoned document shows as abandoned'
assert_contains "$(jg muster revise helpdesk charter --note x)" 'is abandoned' 'an abandoned document is not sent back by name'
pass 'abandoned documents stay out of a revision'
