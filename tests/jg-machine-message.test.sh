#!/usr/bin/env bash
# Behavior test for the message table (core/machines/tables/message.tsv): a steer is one message with 5 states, and the
# ladder counts are fields. Real steers are sent through bin/jg-send.sh (tmux stubbed): the record carries the ticket and the
# kind, steers are counted from records and not from a tag, and each steer reads as one of the five words. The table lints
# clean, and the inbox corpus (the ledger words of those steers, with a ring that did not land) replays against it.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(cd "$(jg_test_tmproot jg-machine-message)" && pwd); H=$T/home; S=$H/state; mkdir -p "$S" "$T/fakebin"; ln -sn "$ROOT/bin" "$H/bin"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0;; esac; done; echo fakepane;; capture-pane) printf "╭────╮\\n│    │\\n╰────╯\\n";; list-windows) echo jg-t1;; esac\nexit 0\n' > "$T/fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/tmux" "$T/fakebin/sleep"
jg_write_meta "$S/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
unset JG_MACHINES_TABLES
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DELIVERY_BUS_TIMEOUT=1
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
send() { env PATH="$T/fakebin:$PATH" JG_ROOT_OVERRIDE="$H" JG_SEND_SETTLE=0 JG_SEND_LOG="$T/typed" "$ROOT/bin/jg-send.sh" t1 "$1" >/dev/null 2>"$T/err" || fail "send failed: $(cat "$T/err")"; }
state_of() { jm show message "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }
field() { bash -c '. "$1"; jg_task_inbox_field "$2" "$3"' _ "$ROOT/bin/jg-task-inbox-lib.sh" "$S/t1.inbox/$1.msg" "$2"; }

# 1. The table lints clean: 5 states, the six count states are not states.
jm check message; expect_code 0 "$RC" "the table lints"; assert_equals "ok message: 5 states, 9 edges" "$OUT" "lint golden"
assert_equals "stored rung read handled failed" "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/message.tsv" | sed 's/ $//')" "the five states"
for c in ring-counted busy-deferred busy-reported held-reported escalated retry-owed; do
  assert_equals 0 "$(grep -c "^state	$c	" "$ROOT/core/machines/tables/message.tsv")" "$c is a field, not a state"
done
pass "the message table lints with 5 states and no count state"

# 2. The send command writes the ticket and the kind on the record; steers are counted from records.
send "please rebase onto main"
send "[order] ticket=jg-zz1 build the thing"
send "[route] ticket=jg-zz2 look at this"
assert_equals "t1 steer" "$(field 001 ticket) $(field 001 kind)" "an untagged steer is about its task"
assert_equals "jg-zz1 order" "$(field 002 ticket) $(field 002 kind)" "an order names its ticket"
assert_equals "jg-zz2 route" "$(field 003 ticket) $(field 003 kind)" "a route names its ticket"
assert_equals 3 "$(for f in "$S"/t1.inbox/*.msg; do bash -c '. "$1"; jg_task_inbox_field "$2" kind' _ "$ROOT/bin/jg-task-inbox-lib.sh" "$f"; done | grep -c .)" "steers counted from records"
assert_equals "please rebase onto main" "$(bash -c '. "$1"; jg_task_inbox_body "$2"' _ "$ROOT/bin/jg-task-inbox-lib.sh" "$S/t1.inbox/001.msg")" "the body is untouched by the new lines"
pass "a steer is a message with its ticket and kind on the record"

# 3. Each steer reads as one of the five words, from the record alone.
assert_equals rung "$(state_of t1:001)" "a rung steer"
mv "$S/t1.inbox/001.msg" "$S/t1.inbox/handled/"; assert_equals read "$(state_of t1:001)" "a moved steer"
bash "$ROOT/bin/jg-delivery.sh" handled t1 001 --evidence status:x >/dev/null 2>&1; assert_equals handled "$(state_of t1:001)" "a claimed steer"
bash "$ROOT/bin/jg-delivery.sh" failed t1 002 --reason gone >/dev/null 2>&1; assert_equals failed "$(state_of t1:002)" "a refused steer"
mkdir -p "$S/u.inbox/handled"; : > "$S/u.inbox/001.msg"; printf '{"seq":1,"word":"stored","at":1}\n' > "$S/u.inbox/.delivery.jsonl"
assert_equals stored "$(state_of u:001)" "a stored steer"
jm show message t1:099; expect_code 1 "$RC" "no record, no state"
pass "each steer reads as one of the five words"

# 4. The inbox corpus replays: every ledger word path of these steers (and a ring that did not land) is a legal move.
printf '{"seq":4,"word":"stored","at":2}\n{"seq":4,"word":"ring-failed","at":3,"pointer":"1"}\n{"seq":4,"word":"rung","at":4}\n{"seq":4,"word":"rung","at":5}\n{"seq":4,"word":"handled","at":6}\n' >> "$S/t1.inbox/.delivery.jsonl"
ev() { case "$1 $2" in "stored rung"|"rung rung") echo ring ;; *" ring-failed") echo ring-fail ;; *" handled") echo handle ;; *" failed") echo fail ;; esac; }
corpus() {
  jq -r -s 'group_by(.seq)[] | map(.word) | join(" ")' "$S/t1.inbox/.delivery.jsonl" | while read -r -a ws; do
    for i in $(seq 1 $((${#ws[@]} - 1))); do p=${ws[i-1]}; [ "$p" = ring-failed ] && p=${ws[i-2]}
      printf '%s\t%s\t%s\n' "$p" "$(ev "$p" "${ws[i]}")" "${ws[i]/ring-failed/$p}"; done
  done
}
corpus > "$T/paths"; [ "$(wc -l < "$T/paths")" -ge 5 ] || fail "the corpus is too small: $(cat "$T/paths")"
jm check message --corpus "$T/paths"; expect_code 0 "$RC" "the corpus replays"; assert_contains "$OUT" "0 findings" "no finding"
printf 'handled\tring\trung\n' >> "$T/paths"
jm check message --corpus "$T/paths"; expect_code 1 "$RC" "a ring after handled"; assert_contains "$OUT" "handled ring rung is not a move" "the illegal path is named"
pass "the inbox corpus replays against the table"
