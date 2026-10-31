#!/usr/bin/env bash
# card-title: a merge evidence card is titled with the outcome sentence a reader can act on.
# The title is the pull request's own title (else its declared claim), trimmed of a leading
# bracket tag, a conventional-commit prefix, a trailing (repo:)/(kind:) suffix and a trailing
# full stop, and never invented. This journey proves both sides: the derivation, and the real
# producer's screen-free card, which the refusal check passes. Run it with MERGE_CARD=<an older
# producer> to watch that check fail on the old behaviour. Fixture stubs only: nothing real runs.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
mc=${MERGE_CARD:-$here/../merge-card}
refuse=$here/../merge-card
[ -f "$mc" ] || { echo "not ok - $mc is missing"; exit 1; }
work=$(mktemp -d /var/tmp/merge-card-title.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home
board=$work/board.json
head_c=titlehead00000000000000000000000000000000
pr=https://github.com/acme/app/pull/7
mkdir -p "$home/data/app-card/.done-done/runs" "$work/wt" "$work/bin"
printf '{"schema":1,"answers_only":false,"items":[]}\n' >"$board"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

# Stub forge: the PR's own title and Checks body as `gh pr view --jq` prints them.
cat >"$work/bin/gh" <<'STUB' || exit 1
#!/usr/bin/env bash
case " $* " in
  *" --jq .title "*) if [ -n "${GH_TITLE:-}" ]; then cat "$GH_TITLE"; fi ;;
  *" --jq .body "*) if [ -n "${GH_BODY:-}" ]; then cat "$GH_BODY"; fi ;;
esac
exit 0
STUB
# Stub done-done: the screen-free card path only asks its version and its evidence root.
printf '#!/usr/bin/env bash\necho 0.6.12\n' >"$work/bin/done-done" || exit 1
# Stub sign-off-axi: keep the board and capture the card it was handed.
cat >"$work/bin/sign-off-axi" <<'STUB' || exit 1
#!/usr/bin/env bash
[ "${1:-}" = post ] || { jq '{decisions:[.items[]? | {key,dismissed,evidence:(.run // .evidence)}]}' "$2"; exit 0; }
board=$2 from=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = --from ]; then from=$2; shift 2; else shift; fi
done
rm -rf "$SO_CAPTURE" && cp -r "$(dirname "$from")" "$SO_CAPTURE"
jq --slurpfile c "$from" '.items += [($c[0] + {type:"evidence",dismissed:false})]' "$board" >"$board.tmp"
mv "$board.tmp" "$board"
STUB
chmod +x "$work/bin/gh" "$work/bin/done-done" "$work/bin/sign-off-axi"

# title_of <pr-title>: the title merge-card derives for a PR that carries it.
title_of() {
  printf '%s\n' "$1" >"$work/title.txt"
  GH_TITLE=$work/title.txt PATH="$work/bin:$PATH" bash "$mc" title "$pr"
}
is "a plain title is kept as written" "$(title_of 'Refresh keeps the session alive')" 'Refresh keeps the session alive'
is "a leading bracket tag is dropped" "$(title_of '[design-ux] Retire the old sign-off card')" 'Retire the old sign-off card'
is "a trailing repo suffix is dropped" "$(title_of 'Fix the retitle dry run (repo: merge-card)')" 'Fix the retitle dry run'
is "a conventional-commit prefix and full stop are dropped" "$(title_of 'feat(ui): Titles say the outcome.')" 'Titles say the outcome'
is "tag, prefix, kind suffix and full stop all go" "$(title_of '[feature] feat: Cards say what shipped (kind: copy).')" 'Cards say what shipped'
is "repeated bracket tags are dropped" "$(title_of '[P1] [design-ux] Two tags in front')" 'Two tags in front'
is "an unreadable PR title derives nothing" "$(title_of '')" ''

# The real producer: a screen-free merge whose Checks block declares its outcome.
printf '## Checks\n\noutcome: Refresh keeps the session alive\nrepro: n/a\nproof: no verify skill\nscreen: none\n' >"$home/data/app-card/checks.md"
jq -n --arg c "$head_c" '{schema:1, run_id:"20261030T000000Z-title0001", commit:$c, dirty:false, exit:0, files:[{path:"app-card/stdout.log"}]}' \
  >"$home/data/app-card/.done-done/runs/20261030T000000Z-title0001.json"
cp "$home/data/app-card/checks.md" "$work/body.md"
printf '[design-ux] Retire the old sign-off card\n' >"$work/prtitle.txt"
SO_CAPTURE=$work/card
export SO_CAPTURE GH_BODY=$work/body.md GH_TITLE=$work/prtitle.txt
out=$(PATH="$work/bin:$PATH" JG_HOME=$home bash "$mc" post --board "$board" app-card "$work/wt" "$head_c" "$pr" 2>&1)
is "the text-only card posts" "$?" 0
case $out in *"posted text-only"*) ok "the card is the short text evidence card" ;; *) no "unexpected post outcome: [$out]" ;; esac
card_title=$(jq -r '.title // empty' "$work/card/card.json" 2>/dev/null)
is "the card title is the PR's outcome sentence" "$card_title" 'Retire the old sign-off card'
if bash "$refuse" generic-title "$card_title"; then no "the produced card passes the refusal"; else ok "the produced card passes the refusal"; fi

# The refusal: the generic sentence, bare or with only a repo/PR prefix, is not a title.
for title in 'Internal change passed its checks' 'muxr #1012: internal change passed its checks'; do
  if bash "$refuse" generic-title "$title"; then ok "[$title] is refused"; else no "[$title] is refused"; fi
done
bash "$refuse" generic-title 'Muxr #1012: Internal change passed its checks.' &&
  ok "a qualified, capitalized, full-stopped title is refused too" || no "a qualified, capitalized, full-stopped title is refused too"

[ "$fails" -eq 0 ] || { printf '%s check(s) failed\n' "$fails"; exit 1; }
echo 'all card-title tests passed'
