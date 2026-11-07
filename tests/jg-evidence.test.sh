#!/usr/bin/env bash
# tests/jg-evidence.test.sh - pictures on landing: the `evidence=` status token, the reply
# that attaches it, and the check that flags a UI-landing reply with no attachment.
# Real scripts and files; no model call.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-evidence)
url='https://github.com/example/demo/pull/77'

# A parent home and a mate home whose merge outcome lands on the parent channel.
parent="$TMP_ROOT/parent"
mate="$TMP_ROOT/mate"
mkdir -p "$parent/state/inbox" "$parent/data" "$parent/config" "$mate/state" "$mate/data" "$mate/config"
printf 'mate1\n' >"$mate/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" >"$mate/.jg-squad-lead-parent"

# --- part 1: lead lines carry the evidence paths --------------------------------------------
mkdir -p "$mate/data/uitask" "$mate/data/plain"
printf 'png' >"$mate/data/uitask/after.png"
printf 'webm' >"$mate/data/uitask/motion.webm"
printf 'after.png\nmotion.webm\n../escape.png\nmissing.png\n' >"$mate/data/uitask/evidence.list"
printf 'png' >"$mate/data/plain/shot.png"
printf 'shot.png\n' >"$mate/data/plain/evidence.list"
printf 'kind=ship\nui_change=yes\n' >"$mate/state/uitask.meta"
printf 'kind=ship\nui_change=no\n' >"$mate/state/plain.meta"

bash -c '. "$1/bin/jg-merge-outcome-lib.sh"; jg_merge_outcome_report "$2" "$2/state" uitask "$3" poll' \
  _ "$ROOT" "$mate" "$url" >/dev/null 2>&1 || fail "the UI merge outcome failed"
bash -c '. "$1/bin/jg-merge-outcome-lib.sh"; jg_merge_outcome_report "$2" "$2/state" plain "$3" poll' \
  _ "$ROOT" "$mate" "https://github.com/example/demo/pull/78" >/dev/null 2>&1 || fail "the plain merge outcome failed"
ui_line=$(grep 'merged-uitask' "$parent/state/mate1.status")
plain_line=$(grep 'merged-plain' "$parent/state/mate1.status")
assert_contains "$ui_line" "evidence=$mate/data/uitask/after.png,$mate/data/uitask/motion.webm" \
  "a UI landing line lists its existing evidence files, nothing outside the task folder"
assert_not_contains "$ui_line" "escape.png" "a path that climbs out of the task folder is dropped"
assert_not_contains "$ui_line" "missing.png" "a file that does not exist is dropped"
assert_not_contains "$plain_line" "evidence=" "a non-UI landing line stays as before"
pass "UI landing lines carry evidence paths and old lines stay valid"

# --- part 2: reply --evidence-from attaches them through --attach ---------------------------
note=1700000000-aaaaaa
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\nhow did the fix land\n' "$note" >"$parent/state/inbox/$note.note"
rm -f "$mate/data/uitask/after.png"
JG_HOME="$parent" JG_STATE_OVERRIDE="$parent/state" JG_DATA_OVERRIDE="$parent/data" JG_CONFIG_OVERRIDE="$parent/config" \
  bash "$ROOT/bin/jg-inbox.sh" reply "$note" --evidence-from "$ui_line" -- "Your ask: \"how did the fix land\" (2026-01-01)
Done: it landed.
Not done: nothing.
Next: read the attachments.
Landed: $url" >/dev/null 2>"$TMP_ROOT/warn" \
  || fail "reply --evidence-from failed"
reply="$parent/state/inbox/.replies/$note"
assert_grep "attach=$mate/data/uitask/motion.webm" "$reply" "the evidence file became an attachment"
assert_no_grep "after.png" "$reply" "a file removed since the line was written is not attached"
assert_contains "$(cat "$TMP_ROOT/warn")" "after.png" "the skipped file is named on stderr"
pass "reply --evidence-from reuses the attachment path and skips a vanished file"

# --- part 3: the check flags a UI-landing reply with no attachment --------------------------
printf 'pr=%s\n' "$url" >>"$mate/state/uitask.meta"
cp "$mate/state/uitask.meta" "$parent/state/uitask.meta"
printf 'kind=ship\nui_change=no\npr=https://github.com/example/demo/pull/90\n' >"$parent/state/plain.meta"
check() { bash "$ROOT/bin/jg-evidence-check.sh" "$parent"; }
assert_equals "" "$(check)" "a reply that attaches evidence is not flagged"
note2=1700000000-bbbbbb
printf 'id=%s\n--\nx\n' "$note2" >"$parent/state/inbox/$note2.note"
# The reply answers his note, so it carries the ask block (2026-11-05).
block=$'Your ask: "the fix landed" (2026-01-01)\nDone: it landed.\nNot done: nothing.\nNext: read it.'
JG_HOME="$parent" JG_STATE_OVERRIDE="$parent/state" JG_DATA_OVERRIDE="$parent/data" JG_CONFIG_OVERRIDE="$parent/config" \
  bash "$ROOT/bin/jg-inbox.sh" reply "$note2" -- "$block
Merged: $url" >/dev/null || fail "plain reply failed"
note3=1700000000-cccccc
printf 'id=%s\n--\nx\n' "$note3" >"$parent/state/inbox/$note3.note"
JG_HOME="$parent" JG_STATE_OVERRIDE="$parent/state" JG_DATA_OVERRIDE="$parent/data" JG_CONFIG_OVERRIDE="$parent/config" \
  bash "$ROOT/bin/jg-inbox.sh" reply "$note3" -- "$block
Merged: https://github.com/example/demo/pull/90" >/dev/null || fail "plain reply 2 failed"
out=$(check)
assert_contains "$out" "$note2" "the bare reply about the UI landing is flagged"
assert_contains "$out" "$url" "the flag names the PR"
assert_not_contains "$out" "$note3" "a bare reply about non-UI work is not flagged"
assert_equals "" "$(check)" "a reply is flagged once"
pass "the check flags a UI-landing reply with no attachment, once"

# The documented registration binds the check as a single-link 0700 file.
printf '#!/usr/bin/env bash\nexec %q %q\n' "$ROOT/bin/jg-evidence-check.sh" "$parent" >"$parent/state/reply-evidence.check.sh"
chmod 0700 "$parent/state/reply-evidence.check.sh"
JG_HOME="$parent" bash "$ROOT/bin/jg-check-register.sh" reply-evidence >/dev/null || fail "the check did not register"
bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" reply-evidence' _ "$ROOT" "$parent/state" \
  || fail "the registered check is not bound to its bytes"
pass "the check registers as a single-link 0700 watcher check"
