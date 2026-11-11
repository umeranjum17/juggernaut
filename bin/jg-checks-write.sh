#!/usr/bin/env bash
# jg-checks-write.sh - write a task's `## Checks` block from its sealed done-done proof run.
#
# Usage: JG_HOME=<home> jg-checks-write.sh <task-id> --outcome "<what a user can now do>"
#          [--repro "<command that failed before and passes now>"] [--head <sha>] [--screen none]
#
# The worker states the outcome (and the repro of a fix); everything else comes from files:
#   - the run is the sealed clean done-done run at <head> that `core/merge-card/merge-card capture-json`
#     discovers, so the writer and the merge card agree on which run counts;
#   - its record must sit in the task folder ($JG_HOME/data/<task-id>/.done-done/runs/<run-id>.json),
#     beside the copied run folder, because the lint and the merge card resolve evidence names there;
#   - proof: names the repo's done-done-verify-<app> skill (else "no verify skill"), the run's own
#     journey or command as `done-done run ...`, and the run id;
#   - evidence: names only the files that run record lists which exist in the task folder, are
#     non-empty, and still hold the bytes the record sealed (sha256), relative to the task folder.
# <head> defaults to the HEAD of the worktree in state/<task-id>.meta, else of the current checkout;
# the verify skill is looked up in that same checkout. --repro defaults to "n/a: no bug".
# --screen none adds the `screen: none` line a change with no user-visible screen declares.
# It writes $JG_HOME/data/<task-id>/checks.md (the whole file, replaced atomically) and prints the block.
# Then lint it: JG_HOME=<home> core/merge-on-green/checks-lint.sh <that file> $JG_HOME/data/<task-id>
# Exit 0 written; 1 no sealed run at <head>, its record is not in the task folder, or no evidence file
# holds up (each refused file is named with its reason); 2 usage.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MERGE_CARD=${JG_MERGE_CARD:-$SCRIPT_DIR/../core/merge-card/merge-card}

usage() { printf 'usage: JG_HOME=<home> jg-checks-write.sh <task-id> --outcome "<text>" [--repro "<cmd>"] [--head <sha>] [--screen none]\n' >&2; exit 2; }
bad() { printf 'jg-checks-write: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'jg-checks-write: %s\n' "$1" >&2; exit 1; }

TASK=${1:-}
[ "$#" -ge 1 ] || usage
shift
OUTCOME='' REPRO='n/a: no bug' HEAD='' SCREEN=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || bad "$1 needs a value"
  case $1 in
    --outcome) OUTCOME=$2 ;;
    --repro) REPRO=$2 ;;
    --head) HEAD=$2 ;;
    --screen) SCREEN=$2 ;;
    *) bad "unknown option $1" ;;
  esac
  shift 2
done
[ -n "${JG_HOME:-}" ] || bad "JG_HOME is not set"
[[ $TASK =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || bad "bad task id: ${TASK:-<none>}"
for pair in "outcome:$OUTCOME" "repro:$REPRO"; do
  value=${pair#*:}
  [[ $value =~ [^[:space:]] ]] || bad "--${pair%%:*} is empty"
  case $value in *$'\n'* | *$'\r'*) bad "--${pair%%:*} must be one line" ;; esac
done
case $SCREEN in '' | none) ;; *) bad "--screen takes only: none" ;; esac
command -v jq >/dev/null 2>&1 || refuse "jq is not installed"
[ -x "$MERGE_CARD" ] || refuse "the merge card is not installed at $MERGE_CARD"

DIR=$JG_HOME/data/$TASK
# The checkout the proof ran in: the task's recorded worktree, else the current one.
CHECKOUT=$(sed -n 's/^worktree=//p' "$JG_HOME/state/$TASK.meta" 2>/dev/null | tail -n 1)
if [ -z "$CHECKOUT" ] || [ ! -d "$CHECKOUT" ]; then
  CHECKOUT=$(git rev-parse --show-toplevel 2>/dev/null) || CHECKOUT=''
fi
if [ -z "$HEAD" ]; then
  [ -n "$CHECKOUT" ] || bad "no --head and no checkout to read it from"
  HEAD=$(git -C "$CHECKOUT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || bad "cannot read HEAD of $CHECKOUT; pass --head <sha>"
fi
[[ $HEAD =~ ^[0-9a-f]{40,64}$ ]] || bad "--head must be a full commit sha: $HEAD"

capture=$(JG_HOME=$JG_HOME "$MERGE_CARD" capture-json "$TASK" "$HEAD") || capture=''
RUN=$(jq -r '.run_id // empty' <<<"${capture:-null}" 2>/dev/null)
[ -n "$RUN" ] || refuse "no sealed clean done-done run at $HEAD for $TASK; run the proof at this clean head (done-done run -- <the command that proves it>) and copy its run folder and record into $DIR"
RECORD=$DIR/.done-done/runs/$RUN.json
[ -f "$RECORD" ] || refuse "the sealed run $RUN is not in $DIR: copy its folder $RUN/ and its record .done-done/runs/$RUN.json from done-done's evidence root (done-done doctor names it) into $DIR"

# The evidence: the run's own files that hold up in the task folder, in the order discovery lists them.
evidence=() refused=0
while IFS=$'\t' read -r name sealed; do
  [ -n "$name" ] || continue
  case $name in "$DIR"/*) name=${name#"$DIR"/} ;; /*) printf 'jg-checks-write: skipped %s: outside the task folder\n' "$name" >&2; refused=$((refused + 1)); continue ;; esac
  file=$DIR/$name
  if [ ! -s "$file" ]; then why='missing or empty in the task folder'
  elif [ -n "$sealed" ] && [ "$(sha256sum -- "$file" | cut -d' ' -f1)" != "$sealed" ]; then why='its bytes differ from the sealed run record'
  elif [[ ! $name =~ \.[A-Za-z0-9_]{1,10}$ ]] || [[ $name =~ [[:space:],] ]]; then why='the lint cannot name it (no extension, or a space or comma in the name)'
  else evidence+=("$name"); continue
  fi
  printf 'jg-checks-write: skipped %s: %s\n' "$name" "$why" >&2
  refused=$((refused + 1))
done < <(jq -r --argjson want "$(jq -c '.files // []' <<<"$capture")" '
  [(.files // [])[] | if type == "object" then {path, sha256: (.sha256 // "")} else {path: ., sha256: ""} end] as $sealed
  | $want[] as $f | [$f, ([$sealed[] | select(.path == $f) | .sha256][0] // "")] | @tsv' "$RECORD")
[ "${#evidence[@]}" -gt 0 ] || refuse "the sealed run $RUN has no evidence file that holds up in $DIR ($refused refused, named above)"

# The proof: the skill that owns the recipe, the run's own recipe, and the run id.
skill=''
[ -z "$CHECKOUT" ] || skill=$(find "$CHECKOUT/.agents/skills" -mindepth 1 -maxdepth 1 -name 'done-done-verify-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | head -n 1)
recipe=$(jq -r 'if (.journey // "") != "" then "done-done run \(.journey)" else "done-done run -- \(.command // "")" end' "$RECORD")
[ "$recipe" != 'done-done run -- ' ] || refuse "the run record $RECORD names neither a journey nor a command"
if [ -n "$skill" ]; then proof="$skill: $recipe (run $RUN)"; else proof="no verify skill - $recipe (run $RUN)"; fi

block="## Checks

outcome: $OUTCOME
repro: $REPRO
proof: $proof
evidence: $(printf '%s, ' "${evidence[@]}" | sed 's/, $//')"
[ "$SCREEN" != none ] || block="$block

screen: none"
tmp=$(mktemp "$DIR/.checks.md.XXXXXX") || refuse "cannot write in $DIR"
if ! { printf '%s\n' "$block" > "$tmp" && mv -f -- "$tmp" "$DIR/checks.md"; }; then
  rm -f -- "$tmp"
  refuse "cannot write $DIR/checks.md"
fi
printf '%s\n' "$block"
printf 'jg-checks-write: wrote %s from run %s at %s\n' "$DIR/checks.md" "$RUN" "$HEAD"
