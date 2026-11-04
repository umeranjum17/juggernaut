#!/usr/bin/env bash
# tests/jg-voice.test.sh - the captain voice file at the shell send points.
#
# Runs the real bin/jg-voice.py through the real bin/jg-inbox.sh reply and the real
# jg_parent_channel_report. Proves the defaults rewrite the internal words of two real relay
# messages, that an edit to the voice file changes behaviour with no code change, that a chat
# reply is refused in block mode, that the parent channel rewrites but never blocks and never
# writes a retried line twice, and that a missing voice file lets the text through unchanged.
# The Telegram send is covered by `go test ./cmd/jg-bus -run TestGatewayVoice` in core/bus.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-voice)
VOICE="$ROOT/bin/jg-voice.py"
INBOX_BIN="$ROOT/bin/jg-inbox.sh"

# The closest real messages we could recover (the sent log keeps ids only).
RELAY_ONE='MAIN: wf-6 worker is done. The merge guard passed and the merge-card judge agreed. Lane parked, bot token here. See PR 602.'
RELAY_TWO='Squad Lead report: the worktree is clean after teardown. The brief is filed. Details at https://github.com/example/repo/pull/602 key=worktree.'

home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$home/config"
export JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config"
unset JG_VOICE_FILE

# --- the defaults ------------------------------------------------------------
out=$(printf '%s' "$RELAY_ONE" | python3 "$VOICE" apply --channel telegram 2>/dev/null)
case $out in *"merge guard"* | *"merge-card judge"* | *"wf-6"*) fail "default voice left an internal term: $out" ;; esac
case $out in *"merge check"*"merge review"*) ;; *) fail "default voice did not give the plain words: $out" ;; esac
case $out in *"MAIN"*"bot token"*"PR 602"*) ;; *) fail "advice-only terms must stay for the author: $out" ;; esac
printf '%s' "$RELAY_ONE" | python3 "$VOICE" check --channel telegram 2>/dev/null && fail "check passed a message full of internal terms"
pass "the default voice file rewrites plain-replaceable terms and flags the rest"

out=$(printf '%s' "$RELAY_TWO" | python3 "$VOICE" apply --channel telegram 2>/dev/null)
case $out in *"https://github.com/example/repo/pull/602 key=worktree."*) ;; *) fail "URL and key=value were not protected: $out" ;; esac
case $out in *"local copy is clean after cleanup"*"instructions is filed"*) ;; *) fail "second message not rewritten: $out" ;; esac
pass "URLs, key=value tokens and code spans are never rewritten"

# --- an edit changes behaviour with no code change ----------------------------
# shellcheck disable=SC2016  # the backticks are literal table text
sed 's/^| `\\bteardown\\b` | cleanup |$/| `\\bcleanup\\b` | tidy-up |/' "$ROOT/defaults/captain-voice.md" > "$TMP_ROOT/edited.md"
grep -q 'tidy-up' "$TMP_ROOT/edited.md" || fail "fixture edit did not apply"
out=$(printf 'We finished teardown and cleanup.' | JG_VOICE_FILE="$TMP_ROOT/edited.md" python3 "$VOICE" apply 2>/dev/null)
[ "$out" = "We finished teardown and tidy-up." ] || fail "an edited row did not take effect at once: $out"
out=$(printf 'We finished teardown and cleanup.' | python3 "$VOICE" apply 2>/dev/null)
[ "$out" = "We finished cleanup and cleanup." ] || fail "the default file changed under the edit: $out"
pass "editing the markdown changes the banned terms with no code change"

cp "$ROOT/defaults/captain-voice.md" "$home/config/captain-voice.md"
sed -i 's/^- mode: rewrite$/- mode: off/' "$home/config/captain-voice.md"
out=$(printf '%s' "$RELAY_ONE" | python3 "$VOICE" apply --channel telegram 2>/dev/null)
[ "$out" = "$RELAY_ONE" ] || fail "mode off must pass the text unchanged: $out"
rm -f "$home/config/captain-voice.md"
pass "the home's config/captain-voice.md replaces the default, and mode off does nothing"

out=$(printf 'Done.' | JG_VOICE_FILE="$TMP_ROOT/missing.md" JG_HOME="$TMP_ROOT/none" python3 "$VOICE" apply --channel telegram 2>/dev/null) || fail "missing file"
[ "$out" = "Done." ] || fail "a message must pass when no voice file can be read"
pass "a missing voice file lets the message through"

# --- the chat reply is refused in block mode, with the default --------------
"$INBOX_BIN" note "ping" >/dev/null 2>&1 || fail "could not file a note"
id=$("$INBOX_BIN" list 2>/dev/null | head -1 | awk '{print $1}' || true)
[ -n "$id" ] || fail "no note to answer"
err=$("$INBOX_BIN" reply "$id" "The merge guard passed on wf-6 worker." 2>&1) && fail "a reply with internal terms was recorded"
case $err in *"voice"*) ;; *) fail "the refusal must name the voice file: $err" ;; esac
[ ! -e "$home/state/inbox/replies" ] || [ -z "$(find "$home/state/inbox/replies" -type f 2>/dev/null)" ] || fail "a refused reply left a record"
"$INBOX_BIN" reply "$id" "The fix is merged. It is released in v1." >/dev/null 2>&1 || fail "a plain reply was refused"
pass "a chat reply with internal terms is refused, and a plain reply goes through"

# --- the parent channel rewrites, never blocks, never duplicates -------------
# shellcheck source=bin/jg-parent-channel-lib.sh disable=SC1091
. "$ROOT/bin/jg-parent-channel-lib.sh"
chan="$TMP_ROOT/parent/lead.status"
line='done [at=1793000000]: the merge guard passed on the worktree; see PR 602'
jg_parent_channel_append_once "$chan" "$line"
jg_parent_channel_append_once "$chan" "$line"
[ "$(wc -l < "$chan")" -eq 1 ] || fail "a retried line was written twice: $(cat "$chan")"
case $(cat "$chan") in "done [at=1793000000]: the merge check passed on the local copy; see PR 602") ;; *) fail "parent line not rewritten with its framing kept: $(cat "$chan")" ;; esac
sed -i 's/^- mode: rewrite$/- mode: block/; s/^- mode.chat-reply: block$/- mode.parent-channel: block/' "$TMP_ROOT/edited.md"
JG_VOICE_FILE="$TMP_ROOT/edited.md" jg_parent_channel_append_once "$chan" 'working [at=1793000001]: a lane is parked' || fail "block mode must never hold a parent-channel line back"
grep -q 'a lane is parked' "$chan" || fail "the blocked parent line was not delivered as written"
pass "the parent channel rewrites the note, keeps its status framing, deduplicates a retry and never holds a line back"
