#!/usr/bin/env bash
# Host test table for psm-refresh.sh: a refresh makes a card, an unchanged project makes no model call, a force run replaces the card.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
refresh=$here/../bin/psm-refresh.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
{ echo '```json'; jq -c '{machines, machinery, not_read}' "$here/fixture-map.json"; echo '```'; } > "$d/reply.txt"
printf '#!/usr/bin/env bash\ncat > /dev/null; echo x >> %s/model-calls; cat %s/reply.txt\n' "$d" "$d" > "$d/model"
printf '#!/usr/bin/env bash\necho "$*" >> %s/board-calls\n' "$d" > "$d/post"
chmod +x "$d/model" "$d/post"; : > "$d/model-calls"; : > "$d/board-calls"
export PSM_READ_COMMAND=$d/model JG_REPORT_POST=$d/post
model_calls() { wc -l < "$d/model-calls" | tr -d ' '; }
board_calls() { sed 's|[^ ]*/board.json|BOARD|; s|[^ ]*/report.json|CARD|; s|state-map-proj-[a-z0-9]*-[0-9]*|KEY|' "$d/board-calls" | paste -sd'|'; }
cp -r "$here/fixture-project" "$d/proj"; : > "$d/board.json"
run() { bash "$refresh" run "$d/proj" --state "$d/state" --board "$d/board.json" "$@"; }

want 'first run reads, proves and posts a card' "$(run --opt-in | grep -c '^refreshed: proj card state-map-proj-')" '1'
want 'first run made one model call and one post' "$(model_calls) $(board_calls)" '1 post BOARD --kind report --from CARD --filer project-state-map'
want 'second run on the same code says unchanged' "$(run --opt-in)" "unchanged: proj (tree $(jq -r '.tree[:8]' <(bash "$here/../bin/psm-search.sh" "$d/proj")))"
want 'unchanged run made no model call and no post' "$(model_calls) $(wc -l < "$d/board-calls" | tr -d ' ')" '1 1'

first=$(cat "$d/state/card-key"); sleep 1
run --opt-in --force > /dev/null
want 'force run calls the model again' "$(model_calls)" '2'
want 'force run posts a new card and dismisses the old one' "$(board_calls | tr '|' '\n' | sed -n '2,3p' | cut -d' ' -f1,2 | paste -sd'|') $(grep -c "^dismiss .* $first$" "$d/board-calls")" 'post BOARD|dismiss BOARD 1'
want 'the stored card is the new one' "$([ "$(cat "$d/state/card-key")" != "$first" ] && echo new)" 'new'

# A changed hit line refreshes; a change that adds no hit does not.
printf '// a comment with no hit\n' >> "$d/proj/app/note.js"
want 'an edit that adds no hit is unchanged' "$(run --opt-in | cut -c1-10)" 'unchanged:'
sed -i "s/'review'/'in-review'/" "$d/proj/lib/contract.js"
want 'a changed hit line refreshes' "$(run --opt-in | cut -c1-10)" 'refreshed:'
want 'the changed hit made a third model call' "$(model_calls)" '3'

# A refused read keeps the old card and the stored key.
sed -i "s/'in-review'/'check'/" "$d/proj/lib/contract.js"; keep=$(cat "$d/state/key"); calls=$(wc -l < "$d/board-calls")
rc=0; out=$(run 2>&1) || rc=$?
want 'no opt-in is refused with exit 3' "$rc $(printf '%s' "$out" | cut -c1-23)" '3 refused: proj: psm-read'
want 'a refused read keeps the key and posts nothing' "$([ "$(cat "$d/state/key")" = "$keep" ] && [ "$(wc -l < "$d/board-calls")" = "$calls" ] && echo kept)" 'kept'
rc=0; out=$(run --opt-in --max-usd 0.001 2>&1) || rc=$?
want 'a read over the cap is refused with exit 3' "$rc $(printf '%s' "$out" | grep -c 'over the cap')" '3 1'
want 'a reply that is not a map exits 4 and keeps the card' "$(printf 'not json' > "$d/reply.txt"; rc=0; run --opt-in >/dev/null 2>&1 || rc=$?; echo "$rc $([ "$(cat "$d/state/key")" = "$keep" ] && echo kept)")" '4 kept'

# tick: silent without a config, silent when nothing changed, one line per refresh.
{ echo '```json'; jq -c '{machines, machinery, not_read}' "$here/fixture-map.json"; echo '```'; } > "$d/reply.txt"
mkdir -p "$d/home/config"
want 'tick without a config is silent' "$(bash "$refresh" tick "$d/home" | wc -c | tr -d ' ')" '0'
printf '%s\n' "$d/board.json" > "$d/home/config/fleet-board"
printf '# projects\n%s opt-in\n%s\n' "$d/proj" "$d/other" > "$d/home/config/project-state-map"
want 'tick refreshes an opted-in project and skips the rest' "$(bash "$refresh" tick "$d/home" | cut -c1-20)" 'refreshed: proj card'
want 'tick on an unchanged project is silent' "$(bash "$refresh" tick "$d/home" | wc -c | tr -d ' ')" '0'
want 'tick keeps state under the home' "$(cd "$d/home/state/project-state-map/proj" && printf '%s\n' * | paste -sd,)" 'card-key,key,proved.json'

# A real board accepts the first card and the forced replacement.
if command -v sign-off-axi >/dev/null; then
  mkdir -p "$d/rb"; (cd "$d/rb" && SIGN_OFF_HOME=$d/rb sign-off-axi init >/dev/null 2>&1)
  unset JG_REPORT_POST; rb=$d/rb/.sign-off/decisions.json
  ok=1; bash "$refresh" run "$d/proj" --state "$d/rs" --board "$rb" --opt-in >/dev/null || ok=0; sleep 1
  bash "$refresh" run "$d/proj" --state "$d/rs" --board "$rb" --opt-in --force >/dev/null || ok=0
  want 'the board takes the card and the forced replacement' "$ok" '1'
  want 'two cards were posted and the first is dismissed' "$(jq -r '.items | length' "$rb") $(jq -r '.key // .item.key' "$d/rb/.sign-off/decisions.dismissed.jsonl") $(jq -r '.items[0].key' "$rb")" "2 $(jq -r '.items[0].key' "$rb") $(jq -r '.items[0].key' "$rb")"
else echo 'SKIP the board takes the cards (sign-off-axi not installed)'; fi
exit "$fail"
