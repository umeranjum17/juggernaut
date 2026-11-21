#!/usr/bin/env bash
# Host test table for report-writer.py: the real script over a stand-in agy that records how it was called.
# The live proof with the real agy and Gemini 4 Neon is core/report-writer/run-proof.sh.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd "$here/../../.." && pwd -P)
rw=(python3 -I "$repo/core/report-writer/bin/report-writer.py")
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
ck() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }

cat > "$d/good.md" <<'M'
## Captain's Call
- Captain, one decision waits: pick the plan for the new board.
- Review the change: https://github.com/example/repo/pull/7
## Recently Landed
- The fix for slow report pages is done.
## Underway
- Two workers are busy.
## Charted Next
- Nothing is queued.
M
wall="## Captain's Call
$(printf 'Captain, read data/jg-abc/report.md and /home/you/x/state/jg-abc.status now. %.0s' {1..12})"

# A stand-in agy: logs argv, answers from $FAKE_ANSWERS (one file per call, in order).
cat > "$d/agy" <<'S'
#!/usr/bin/env bash
n=$(cat "$FAKE_DIR/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/count"
printf '%s\n' "$@" > "$FAKE_DIR/argv.$n"
ls -A | wc -l > "$FAKE_DIR/cwdcount.$n"
cat "$FAKE_DIR/answer.$n" 2>/dev/null || cat "$FAKE_DIR/answer.last"
S
chmod +x "$d/agy"
reset() { rm -f "$d"/count "$d"/argv.* "$d"/answer.* "$d"/cwdcount.*; }
run() { JG_AGY="$d/agy" FAKE_DIR="$d" "${rw[@]}" "$@"; }

printf '{"reports":["/home/u/home/data/jg-abc/report.md"],"x":"state/jg-abc.status"}' > "$d/facts.json"

reset; cp "$d/good.md" "$d/answer.last"
out=$(run write sitrep --facts "$d/facts.json"); ck 'good sitrep is printed' "$out" "$(cat "$d/good.md")"
ck 'default model is gemini-4-neon-medium' "$(sed -n 2p "$d/argv.1")" gemini-4-neon-medium
ck 'agy runs in an empty folder' "$(cat "$d/cwdcount.1")" 0
prompt=$(cat "$d/argv.1"); case $prompt in *"/home/u"*|*"data/jg-abc"*|*"state/jg-abc"*) p=leaked;; *) p=scrubbed;; esac
ck 'facts reach the model with no local path' "$p" scrubbed
case $prompt in *"the report of jg-abc"*) p=labelled;; *) p=none;; esac
ck 'a report path becomes a plain label' "$p" labelled

reset; cp "$d/good.md" "$d/answer.last"; out=$(run write sitrep --facts "$d/facts.json" --model gemini-4-neon-low); ck 'a neon tier is accepted' "$(sed -n 2p "$d/argv.1")" gemini-4-neon-low
reset; run write sitrep --facts "$d/facts.json" --model claude-opus-5-5-high >/dev/null 2>"$d/err"; ck 'a non-neon model is refused' "$?" 2
ck 'a refused model never reaches agy' "$(cat "$d/count" 2>/dev/null || echo 0)" 0

reset; printf '%s\n' "$wall" > "$d/answer.1"; cp "$d/good.md" "$d/answer.2"
out=$(run write sitrep --facts "$d/facts.json" 2>"$d/err"); ck 'a text wall is rewritten once' "$out" "$(cat "$d/good.md")"
ck 'the retry names the findings' "$(grep -c 'local file or path' "$d/argv.2")" 1

reset; printf '%s\n' "$wall" > "$d/answer.last"
out=$(run write sitrep --facts "$d/facts.json" 2>"$d/err"); rc=$?
ck 'two text walls fail' "$rc" 1; ck 'a failed write prints nothing to stdout' "$out" ""
ck 'the failure names the cause' "$(grep -c 'refused twice' "$d/err")" 1

JG_AGY="$d/nope" "${rw[@]}" write sitrep --facts "$d/facts.json" >/dev/null 2>"$d/err"; ck 'a missing agy stops' "$?" 3
ck 'a missing agy offers no other writer' "$(grep -c 'no other writer' "$d/err")" 1

reset; fence='```'; printf '%smarkdown\n%s\n%s\n' "$fence" "$(cat "$d/good.md")" "$fence" > "$d/answer.last"
out=$(run write sitrep --facts "$d/facts.json"); ck 'a code fence around the answer is removed' "$out" "$(cat "$d/good.md")"

# lint rules
l() { "${rw[@]}" lint "$@" 2>&1; }
ck 'good sitrep passes lint' "$(l sitrep "$d/good.md"; echo rc=$?)" rc=0
printf '## Underway\n- Captain, see ~/notes/x\n' > "$d/t.md"; ck 'tilde path refused' "$(l spotrep "$d/t.md" | grep -c 'local file')" 1
printf '## Underway\n- Captain, see report.md\n' > "$d/t.md"; ck 'bare file name refused' "$(l spotrep "$d/t.md" | grep -c 'local file')" 1
printf '## Underway\n- Captain, see https://github.com/a/b/blob/main/data/x/report.md\n' > "$d/t.md"; ck 'a path inside a https link is fine' "$(l spotrep "$d/t.md"; echo rc=$?)" rc=0
printf '## Underway\n- Captain, see file:///home/u/x\n' > "$d/t.md"; ck 'file link refused' "$(l spotrep "$d/t.md" | grep -c 'not an https')" 1
printf '## Underway\n- Captain, http://a.example\n' > "$d/t.md"; ck 'http link refused' "$(l spotrep "$d/t.md" | grep -c 'not an https')" 1
{ echo '## Underway'; for i in 1 2 3 4 5 6 7 8 9; do echo "- Captain, https://example.com/$i"; done; } > "$d/t.md"; ck 'nine links refused' "$(l spotrep "$d/t.md" | grep -c 'links;')" 1
printf '## Underway\n- Captain, https://a.example/1 and https://a.example/2\n' > "$d/t.md"; ck 'two links on one line refused' "$(l spotrep "$d/t.md" | grep -c 'more than one link')" 1
printf '## Underway\n| a | b |\n' > "$d/t.md"; ck 'table refused' "$(l spotrep "$d/t.md" | grep -c 'table')" 1
printf '## Underway\n- A line without the word.\n' > "$d/t.md"; ck 'no captain address refused' "$(l spotrep "$d/t.md" | grep -c "never says")" 1
sed -i '/Charted/,$d' "$d/good.md"; ck 'a sitrep with a missing section refused' "$(l sitrep "$d/good.md" | grep -c 'four sections')" 1

# The four section names stay the ones the sitrep skill's contract names.
for s in "Captain's Call" "Recently Landed" "Underway" "Charted Next"; do
  ck "skill contract names $s" "$(grep -c "^[0-9]\. \*\*$s\*\*" "$repo/.agents/skills/sitrep/SKILL.md")" 1
done

# render: a phone page with a viewport, the links as links and no raw markup
printf '# Status\n## Needs you\n- **Review** https://github.com/example/repo/pull/7 <b>\n' > "$d/r.md"
page=$("${rw[@]}" render "$d/r.md" --title Status)
ck 'page has the viewport tag' "$(grep -c 'name="viewport"' <<<"$page")" 1
ck 'link is a link' "$(grep -c '<a href="https://github.com/example/repo/pull/7">' <<<"$page")" 1
ck 'a page with no title line gets one' "$("${rw[@]}" render "$d/good.md" --title Daily | grep -c '<h1>Daily</h1>')" 1
ck 'markup in text is escaped' "$(grep -c '&lt;b&gt;' <<<"$page")" 1

exit $fail
