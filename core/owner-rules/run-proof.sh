#!/usr/bin/env bash
# Real publication capture for done-done. Requires JG_PROOF_FORK=<Juggernaut checkout>.
# Scratch is isolated and retained; no server, model, live board, or deletion here.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
fork=${JG_PROOF_FORK:?set JG_PROOF_FORK to a Juggernaut checkout}
head=$(git -C "$repo" rev-parse HEAD)
work=$(mktemp -d /var/tmp/owner-rules-live.XXXXXX)
export HOME=$work/user XDG_DATA_HOME=$work/data XDG_CONFIG_HOME=$work/config XDG_CACHE_HOME=$work/cache
export TMPDIR=$work/tmp SIGN_OFF_HOME=$work/board JG_HOME=$work/home JG_ADDONS_DIR=$repo
mkdir -p "$HOME" "$TMPDIR" "$SIGN_OFF_HOME" "$JG_HOME/config" "$work/parent/state" "$JG_HOME/data/umer/.done-done/runs"
printf 'umer\n' > "$JG_HOME/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$work/parent" > "$JG_HOME/.jg-squad-lead-parent"
bash "$repo/owner-rules/wiring.sh" "$JG_HOME" >/dev/null
board=$SIGN_OFF_HOME/decisions.json
printf '{"schema":2,"items":[]}\n' > "$board"
cp "$board" "$work/before.json"
# Fixture prerequisite for merge-card's screen-free path, confined to this private board.
jq -n --arg c "$head" '{schema:1,run_id:"fixture-only",commit:$c,dirty:false,exit:0,files:[{path:"proof.log"}]}' > "$JG_HOME/data/umer/.done-done/runs/run.json"
printf 'screen: none\n' > "$JG_HOME/data/umer/checks.md"
record() { # expected exit, description, actual command...
  local expected=$1 label=$2 out rc=0; shift 2
  printf '\n%s\n$ ' "$label"
  printf '%q ' "$@"; printf '\n'
  out=$("$@" 2>&1) || rc=$?
  printf '%s\nexit=%s (expected %s)\n' "$out" "$rc" "$expected"
  [ "$rc" -eq "$expected" ]
  if [ "$expected" -ne 0 ]; then [[ $out == *'use the sign-off board (sign-off-axi) instead'* ]]; fi
}
post() {
  jq -n --arg claim "$1" '{verdict:"pass",check:{claim:$claim,evidence:["proof.log"]}}' > "$JG_HOME/data/umer/merge-card.json"
  record "$2" "$3" "$repo/merge-card/merge-card" post --board "$board" umer - "$head" -
}
{
  printf 'Candidate commit: %s\n' "$head"
  printf 'sign-off-axi version: '; sign-off-axi --version
  record 2 'A squad_lead Lavish link is refused before append.' bash "$fork/bin/jg-squad-lead-report.sh" 'done' abcdef0123456789 'http://review.example:4387/session/umer'
  [ ! -e "$work/parent/state/umer.status" ]
  echo 'Refused squad_lead note wrote no status file.'
  record 0 'A squad_lead sign-off link is accepted.' bash "$fork/bin/jg-squad-lead-report.sh" 'done' abcdef0123456789 'http://review.example:4388/board/umer'
  cat "$work/parent/state/umer.status"
  grep -qF 'http://review.example:4388/board/umer' "$work/parent/state/umer.status"
  post 'See http://review.example:4387/session/umer' 1 'A merge-card Lavish link is refused before posting.'
  post 'lavish-axi review.html' 1 'A merge-card publish command is refused before posting.'
  cmp "$board" "$work/before.json"
  echo 'Refused merge-card posts left the private board byte-for-byte unchanged.'
  post 'See http://review.example:4388/board/umer' 0 'A merge-card sign-off link is posted.'
  sign-off-axi list "$board" --json --full > "$work/posted.json"
  cat "$work/posted.json"
  jq -e '.decisions | length == 1 and .[0].evidence.outcome == "See http://review.example:4388/board/umer"' "$work/posted.json"
  echo 'The real sign-off writer holds exactly one clean card.'
} > "$evidence/publication.txt" 2>&1
cat "$evidence/publication.txt"
jq -n --arg version "$head" '{target:{version:$version},start:"An isolated squad_lead home has owner-rules enabled and a private empty sign-off board.",steps:["Send a Lavish link through the real squad_lead report helper and inspect the refusal and absent status file.","Send a sign-off link through that helper and read the appended status.","Post a Lavish link and a publish command through merge-card and compare the unchanged board.","Post a clean sign-off link through merge-card and inspect the single card with sign-off-axi list."],result:"SquadLead notes and merge-card posts refuse Lavish content and point to the sign-off board; clean sign-off links pass both real publishing commands."}' > "$evidence/steps.json"
