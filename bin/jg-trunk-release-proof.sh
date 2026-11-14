#!/usr/bin/env bash
# Generate and publish the proof for an already-pushed trunk release.
# Usage: jg-trunk-release-proof.sh <project> <trunk> <base> <head> <PR URL>
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
HOME_DIR=${JG_HOME:?JG_HOME is required}
STATE=${JG_STATE_OVERRIDE:-$HOME_DIR/state}
DATA=${JG_DATA_OVERRIDE:-$HOME_DIR/data}
CONFIG=${JG_CONFIG_OVERRIDE:-$HOME_DIR/config}
fail() { printf 'release proof: %s\n' "$*" >&2; exit 1; }

# This command runs inside done-done so its output and step record belong to that run.
if [ "${1:-}" = capture ]; then
  project=${JG_RELEASE_PROJECT:?} trunk=${JG_RELEASE_TRUNK:?} base=${JG_RELEASE_BASE:?} head=${JG_RELEASE_HEAD:?}
  pn=${project##*/}; out=${DONE_DONE_EVIDENCE_ROOT:?done-done must supply its capture folder}
  [ "$(git rev-parse HEAD)" = "$head" ] || fail 'capture is not at the release head'
  [ "$(cat "$STATE/trunk-green-$pn")" = "$head" ] || fail 'green pin changed during proof'
  git merge-base --is-ancestor "$base" "$head" || fail 'release base is not an ancestor'
  [ -r "$DATA/trunk-landing-proofs.tsv" ] && [ -r "$DATA/trunk-versions.tsv" ] || fail 'landing proof or trunk version records are missing'
  commits=$(git rev-list --reverse "$base..$head") || fail 'cannot read the release range'
  [ -n "$commits" ] || fail 'release range is empty'
  # The first recorded proof on this trunk marks the start of proof-row enforcement.
  # Only its first-parent ancestors can be established as earlier trunk landings.
  first_parents=$(git rev-list --first-parent --reverse "$head") || fail 'cannot read trunk history'
  cutover=
  while IFS= read -r candidate; do
    if awk -F '\t' -v p="$pn" -v h="$candidate" '$2 == p && $3 == h { found=1 } END { exit !found }' "$DATA/trunk-landing-proofs.tsv"; then
      cutover=$candidate
      break
    fi
  done <<< "$first_parents"
  # A trunk-home-converge merge puts commits only a home carried onto the trunk; they arrive by its second parent.
  # The merge is itself a first-parent commit, so it still needs its own proof row or an earlier-landing claim below.
  merges=$(git log --first-parent --merges --format='%H %s' "$head") || fail 'cannot read trunk merges'
  converged=
  while read -r merge subject; do
    case $subject in
      'trunk-home-converge:'*) converged+=$(git rev-list "$merge^1..$merge^2" | sed "s/\$/ $merge/")$'\n' ;;
    esac
  done <<< "$merges"
  versions=$(awk -F '\t' -v p="$pn" '$1 == p { print $2 "\t" $3 "\t" $4 }' "$DATA/trunk-versions.tsv") || fail 'cannot read trunk versions'
  {
    printf 'Release head: %s\nRelease base: %s\nGreen pin: %s\n' "$head" "$base" "$head"
    accepted=
    while IFS= read -r sha; do
      row=$(awk -F '\t' -v p="$pn" -v h="$sha" '$2 == p && $3 == h { r=$0 } END { print r }' "$DATA/trunk-landing-proofs.tsv")
      if [ -z "$row" ]; then
        merge=$(awk -v h="$sha" '$1 == h { print $2; exit }' <<< "$converged")
        if [ -n "$merge" ]; then
          printf 'Converged landing: %s (merged by %s)\n' "$sha" "$merge"
          accepted+="$sha"$'\n'
          continue
        fi
        if [ -n "$cutover" ] && [ "$sha" != "$cutover" ] && git merge-base --is-ancestor "$sha" "$cutover" && grep -Fxq "$sha" <<< "$first_parents"; then
          printf 'Legacy landing: %s (before %s)\n' "$sha" "$cutover"
          accepted+="$sha"$'\n'
          continue
        fi
        # A Revert commit is accepted when trunk-landings.tsv records it as reverts-<sha> and the commit it reverts is itself proven.
        if [[ $(git log -1 --format=%s "$sha") == 'Revert "'* ]]; then
          reverted=$(awk -F '\t' -v p="$pn" -v h="$sha" '$2 == p && $3 == h && $NF ~ /^reverts-/ { sub(/^reverts-/, "", $NF); print $NF; exit }' "$DATA/trunk-landings.tsv")
          reverted=$(git rev-parse --verify --quiet "${reverted:-HEAD}^{commit}" 2>/dev/null || true)
          if [ -n "$reverted" ] && [ "$reverted" != "$(git rev-parse HEAD)" ] && { grep -Fxq "$reverted" <<< "$accepted" ||
            awk -F '\t' -v p="$pn" -v h="$reverted" '$2 == p && $3 == h { f=1 } END { exit !f }' "$DATA/trunk-landing-proofs.tsv"; }; then
            printf 'Revert landing: %s (reverts %s)\n' "$sha" "$reverted"
            accepted+="$sha"$'\n'
            continue
          fi
        fi
        fail "no landing proof row for $sha"
      fi
      accepted+="$sha"$'\n'
      printf 'Landing: %s\n' "$(cut -f1-5 <<<"$row" | tr '\t' ' ')"
    done <<< "$commits"
    # Check each old trunk's local and remote tips; a missing object cannot prove a hotfix was carried.
    while IFS=$'\t' read -r _version branch _; do
      [ -n "$branch" ] && [ "$branch" != "$trunk" ] || continue
      local_tip=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch^{commit}" || true)
      remote=$(git ls-remote "$(git -C "$project" remote get-url origin)" "refs/heads/$branch") || fail "cannot inspect remote trunk $branch"
      remote_tip=${remote%%[[:space:]]*}
      for tip in $local_tip $remote_tip; do
        git cat-file -e "$tip^{commit}" 2>/dev/null || git fetch -q "$(git -C "$project" remote get-url origin)" "$tip" || fail "cannot inspect old trunk $branch at $tip"
        if ! git merge-base --is-ancestor "$tip" "$head"; then
          changes=$(git cherry "$head" "$tip") || fail "cannot compare old trunk $branch"
          if grep -q '^+' <<<"$changes"; then fail "hotfix on $branch is not carried into $head"; fi
        fi
      done
      printf 'Old trunk checked: %s\n' "$branch"
    done <<< "$versions"
    printf 'Full-suite CI is a later release pull request gate.\n'
  } > "$out/run.log"
  jq -n --arg h "$head" '{target:{version:$h},start:"A published trunk release has landing proof records.",steps:["Read the release head and green pin.","Check each landing proof and old trunk tip."],result:"The release head has landing proof, earlier trunk history or a recorded home converge for every commit and no uncarried old trunk hotfix; full-suite CI remains a later gate."}' > "$out/steps.json"
  exit 0
fi

[ "$#" -eq 5 ] || fail 'expected project, trunk, base, head and PR URL'
project=$1 trunk=$2 base=$3 head=$4 url=$5
pn=${project##*/}; id=release-$pn-$trunk; dir=$DATA/$id
mkdir -p "$dir/.done-done/runs"
# shellcheck source=bin/jg-wake-lib.sh
. "$HERE/jg-wake-lib.sh"
lock=$STATE/.trunk-release-proof-$pn.lock
jg_lock_acquire_wait "$lock" || fail 'cannot lock the release proof'
trap 'jg_lock_release "$lock" || true' EXIT
# A private clone is kept with the evidence so merge-card can re-read its proof context on a retry.
clone=$dir/candidate-$head
if [ ! -d "$clone/.git" ]; then
  git clone -q --shared --no-checkout "$project" "$clone" || fail 'cannot clone the release head'
  git -C "$clone" checkout -q --detach "$head" || fail 'cannot check out the release head'
fi
[ "$(git -C "$clone" rev-parse HEAD)" = "$head" ] && [ -z "$(git -C "$clone" status --porcelain)" ] || fail 'the release proof clone is not clean at its head'
# shellcheck source=bin/jg-worker-account-lib.sh
. "$HERE/jg-worker-account-lib.sh"
pin=$(jg_worker_account_resolve claude "$CONFIG") || fail 'cannot resolve the home Claude account pin'
if [ -n "$pin" ]; then account=$(cut -f2 <<<"$pin"); if [ -n "$account" ]; then export CLAUDE_CONFIG_DIR=$account; else unset CLAUDE_CONFIG_DIR; fi; fi
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
# shellcheck disable=SC2016 # The child shell expands the proof helper variable.
result=$(cd "$clone" && JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=$STATE JG_DATA_OVERRIDE=$DATA \
  JG_RELEASE_HELPER="$HERE/jg-trunk-release-proof.sh" JG_RELEASE_PROJECT=$project JG_RELEASE_TRUNK=$trunk JG_RELEASE_BASE=$base JG_RELEASE_HEAD=$head \
  done-done run --json -- bash -c '"$JG_RELEASE_HELPER" capture') || fail "done-done run failed: $result"
run=$(jq -r '.run_id // empty' <<<"$result"); record=$(jq -r '.record // empty' <<<"$result")
# shellcheck disable=SC2088 # Match the literal tilde emitted by done-done.
case $record in '~/'*) record=$HOME/${record#'~/'} ;; esac
[ -n "$run" ] && [ -f "$record" ] && [ "$(jq -r .commit <<<"$result")" = "$head" ] && [ "$(jq -r .dirty <<<"$result")" = false ] || fail "done-done returned no clean run for the release head: $result"
root=${record%/.done-done/runs/*}
[ -d "$root/$run" ] || fail 'done-done capture folder is missing'
cp -R "$root/$run" "$dir/" || fail 'cannot copy the sealed capture'
cp "$record" "$dir/.done-done/runs/$run.json" || fail 'cannot copy the sealed record'
outcome="Release head $head: every commit has a landing proof, earlier trunk history or a recorded home converge, the green pin matches, and no old trunk hotfix is uncarried; whole-suite CI is a later gate"
(cd "$clone" && JG_HOME=$HOME_DIR "$HERE/jg-checks-write.sh" "$id" --head "$head" --outcome "$outcome" --screen none) || fail 'cannot write the Checks block'
JG_HOME=$HOME_DIR "$HERE/../core/merge-on-green/checks-lint.sh" "$dir/checks.md" "$dir" || fail 'draft Checks lint failed'
# Keep the existing PR body and append a fresh Checks block; the newest block is authoritative.
case $url in https://github.com/*/*/pull/[0-9]*) ;; *) fail "unsupported PR URL: $url" ;; esac
path=${url#https://github.com/}; path=${path/\/pull\//\/pulls/}
api="repos/$path"
remote_head=$(cd "$project" && gh-axi api "$api" --jq '.head.sha') || fail 'cannot read the PR head'
[ "$remote_head" = "$head" ] || fail 'the PR head changed before proof publication'
body=$(cd "$project" && gh-axi api "$api" --jq '.body // ""') || fail 'cannot read the PR body'
body=$(printf '%s\n\n%s\n' "$body" "$(cat "$dir/checks.md")")
(cd "$project" && gh-axi api PATCH "$api" --raw-field "body=$body" >/dev/null) || fail 'cannot publish the Checks block'
# The forge can serve the old body just after the write, or time out (PR 814: "no Checks block" twelve seconds after the write;
# PR 817: gh ETIMEDOUT). Either left no receipt and a hand-run proof, so the lint of the published body is tried again a few times.
lint_published=0
for try in 1 2 3 4; do
  if JG_HOME=$HOME_DIR "$HERE/../core/merge-on-green/checks-lint.sh" "$url" "$dir"; then lint_published=1; break; fi
  [ "$try" -eq 4 ] || sleep "${JG_RELEASE_LINT_RETRY_SLEEP:-5}"
done
[ "$lint_published" -eq 1 ] || fail 'published Checks lint failed'
(cd "$clone" && JG_HOME=$HOME_DIR JG_FORK_BIN=$HERE JG_STATE_OVERRIDE=$STATE JG_RECEIPT_PR=$url "$HERE/../core/receipts/bin/jg-run-receipt.sh" "$id" PASS "$dir/checks.md") || fail 'cannot publish the completion receipt'
# shellcheck source=bin/jg-board-link-lib.sh
. "$HERE/jg-board-link-lib.sh"
board=$(jg_board_file "$HOME_DIR") || fail 'no proof board is configured'
JG_HOME=$HOME_DIR "$HERE/../core/merge-card/merge-card" check "$id" "$clone" "$head" "$url" || fail 'merge-card check failed'
jq -e --arg h "$head" '.head == $h and .verdict == "pass" and (.check.evidence | length > 0)' "$dir/merge-card.json" >/dev/null || fail 'merge-card did not approve cited evidence'
JG_HOME=$HOME_DIR "$HERE/../core/merge-card/merge-card" post --board "$board" "$id" "$clone" "$head" "$url" || fail 'merge-card evidence was not posted'
JG_HOME=$HOME_DIR "$HERE/../core/merge-card/merge-card" receipt "$id" "$head" || fail 'merge-card receipt was refused'
remote_head=$(cd "$project" && gh-axi api "$api" --jq '.head.sha') || fail 'cannot re-read the PR head'
[ "$remote_head" = "$head" ] || fail 'the PR head changed while publishing proof'
printf 'release proof complete: %s at %s\n' "$url" "$head"
