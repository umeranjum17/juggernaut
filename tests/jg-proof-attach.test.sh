#!/usr/bin/env bash
# bin/jg-proof-attach.sh: a ready, review or merged card carries its proof, and UI or video
# work is never filed text-only. One host row per case; the forge and the board are stubs.
# It also owns journeys/proof-attach.sh, so the changed-test map selects it.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot proof-attach) || fail "no fixture root"
home=$root/home log=$root/calls.log
mkdir -p "$home/config" "$home/state" "$root/fakebin"; : > "$root/b.json"
export JG_HOME=$home PATH="$root/fakebin:$PATH" STUB_LOG=$log STUB_BODY=$root/body STUB_BOARD=$root/board.json
PR=https://github.com/acme/app/pull/7 HEAD=0123456789abcdef0123456789abcdef01234567
cat > "$root/fakebin/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" edit "*) all="$*"; cp -- "${all##*--body-file }" "$STUB_BODY"; echo "gh edit" >> "$STUB_LOG" ;;
  *headRefOid*) echo "$STUB_HEAD" ;;
  *) cat -- "$STUB_BODY" ;;
esac
STUB
cat > "$root/fakebin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
echo "so $1 $2 $(jq -r ".key // empty" "${4:-/dev/null}" 2>/dev/null)" >> "$STUB_LOG"
[ "$1" != list ] || cat -- "$STUB_BOARD"
STUB
chmod +x "$root/fakebin/gh" "$root/fakebin/sign-off-axi"
export STUB_HEAD=$HEAD

row() {  # <name> <task> <body> <board-json>: fresh task folder and board for one case
  rm -rf -- "$home/data/$2"; mkdir -p "$home/data/$2"; : > "$log"
  printf '%s\n' "$3" > "$STUB_BODY"; printf '%s\n' "$4" > "$STUB_BOARD"
}
shot() { printf 'png' > "$home/data/$1/shot.png"; }
seal() {  # <task>: a real capture listed by a sealed clean run at HEAD
  mkdir -p "$home/data/$1/.done-done/runs"
  printf 'Parser fixture capture\n' > "$home/data/$1/out.txt"
  printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","run_id":"20261029T000000Z-01234567-ab","started_at":"1","files":["out.txt"]}' "$HEAD" > "$home/data/$1/.done-done/runs/r.json"
}
run() { out=$(bash ${PROOF_X:+-x} "$ROOT/bin/jg-proof-attach.sh" "$@" --pr "$PR" --board "$root/b.json" 2>&1); rc=$?; }
key=merge-acme-app-pull-7
EMPTY='{"decisions":[]}'

row ui-ok t1 $'## Checks\noutcome: Sign-in works' "$EMPTY"; shot t1
run attach ready t1
assert_equals 0 "$rc" "UI work with media: ready attach exits 0 ($out)"
assert_contains "$(cat "$log")" "so post" "UI work with media: card posted"
assert_contains "$(jq -r '.media[0]' "$home/data/t1/proof-card/card.json")" "1.png" "UI work with media: card lists the media"
assert_contains "$(cat "$STUB_BODY")" "<!-- jg-proof -->" "UI work with media: PR body has the Proof section"
assert_not_contains "$(cat "$STUB_BODY")" "token" "UI work with media: PR body holds no board token"
pass "row ui-with-media: ready card posts with media and a PR body section"

row ui-none t2 $'## Checks\noutcome: Sign-in works' "$EMPTY"
run attach ready t2
assert_equals 1 "$rc" "UI work without media is refused"
assert_contains "$out" "has no proof media" "refusal names the fix"
assert_not_contains "$(cat "$log")" "so post" "refused: nothing posted"
pass "row ui-without-media: refused, nothing posted"

row text-ok t3 $'## Checks\nscreen: none\noutcome: Parser is faster' "$EMPTY"; seal t3
run attach ready t3
assert_equals 0 "$rc" "non-UI work with a sealed receipt is allowed text-only ($out)"
assert_equals null "$(jq -c '.media // null' "$home/data/t3/proof-card/card.json")" "non-UI card has no media"
assert_contains "$(jq -r '.run.proof' "$home/data/t3/proof-card/card.json")" "unverified capture" "raw attachment is explicitly unverified"
assert_contains "$(cat "$STUB_BODY")" "verification: unverified" "PR attachment does not assert proof approval"
raw_rc=0
# Internal modes supplied through the environment cannot turn discovery into authorization.
discovering=1 recording=1 "$ROOT/core/merge-card/merge-card" receipt-json t3 "$HEAD" > "$root/raw-receipt.json" 2>/dev/null || raw_rc=$?
assert_equals 1 "$raw_rc" "raw attachment cannot satisfy approved receipt lookup"
assert_equals '' "$(cat "$root/raw-receipt.json")" "unapproved lookup returns no JSON"
touch "$home/config/owner-rules"
JG_MAIN_HOME=$home "$ROOT/core/owner-rules/bin/jg-owner-rules-gate.sh" init-key >/dev/null || fail "cannot create fixture proof key"
sign_rc=0
JG_MAIN_HOME=$home "$ROOT/core/owner-rules/bin/jg-owner-rules-gate.sh" sign t3 "$HEAD" "$PR" > "$root/raw-sign.log" 2>&1 || sign_rc=$?
assert_equals 1 "$sign_rc" "raw attachment cannot authorize an owner signature"
[ ! -f "$home/data/t3/proof-authorizations/$HEAD.sig" ] || fail "unapproved capture got an owner signature"
rm -f -- "$home/config/owner-rules"
row text-bad t4 $'## Checks\nscreen: none' "$EMPTY"
run attach ready t4
assert_equals 1 "$rc" "non-UI work without a sealed receipt is refused"
pass "row non-ui-text-only: allowed with a receipt, refused without one"

old="{\"decisions\":[{\"key\":\"$key\",\"media\":[],\"evidence\":{\"commit\":\"$HEAD\"}}]}"
row review t5 $'## Checks\noutcome: Sign-in works' "$old"; shot t5
run attach review t5
assert_equals 0 "$rc" "review attach exits 0 ($out)"
assert_contains "$(cat "$log")" "so dismiss $key" "review: the live card without media is archived"
assert_contains "$(cat "$log")" "so post" "review: the card with media replaces it"
pass "row review-card: a text-only live card is replaced by one with media"

good="{\"decisions\":[{\"key\":\"$key\",\"media\":[{}],\"evidence\":{\"commit\":\"$HEAD\"}}]}"
row merged t6 $'## Checks\noutcome: Sign-in works' "$good"; shot t6
run attach merged t6
assert_equals 0 "$rc" "merged attach exits 0 ($out)"
assert_contains "$out" "already on the board" "merged: the PR's card is reused"
assert_not_contains "$(cat "$log")" "so post" "merged: no second card"
pass "row merge-card: the merge reuses the PR's card"

row find t7 $'## Checks\noutcome: x' "$EMPTY"; shot t7
run find t7
assert_contains "$out" "mode: ui" "find reports UI work"
assert_contains "$out" "media: $home/data/t7/shot.png" "find lists the media"
row find-none t9 $'## Checks\nscreen: none\noutcome: Parser is faster' "$EMPTY"; seal t9
mkdir -p "$root/retired/merge-card"
printf '#!/bin/sh\necho retired >&2; exit 1\n' > "$root/retired/merge-card/merge-card"
chmod +x "$root/retired/merge-card/merge-card"
JG_ADDONS_DIR=$root/retired export JG_ADDONS_DIR
run find t9
unset JG_ADDONS_DIR
assert_contains "$out" "mode: text" "find reports text mode for screen: none despite a stale override"
assert_contains "$out" "receipt: 20261029T000000Z-01234567-ab" "find reports the sealed capture"
assert_contains "$out" "verification: unverified" "find marks discovery as unverified"
pass "find lists evidence and recognizes screen: none"

# verify-merge-card-posts-after-pr-239: the real post-merge hook path files a card with only JG_HOME set.
printf '#!/bin/sh\nexec "%s/core/merge-card/merge-card" post --board "%s/b.json" "$@"\n' "$ROOT" "$root" > "$home/config/post-merge"
chmod +x "$home/config/post-merge"
row hook t8 "" "$EMPTY"; printf 'screen: none\noutcome: Parser is faster\n' > "$home/data/t8/checks.md"; seal t8
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$ROOT/bin/jg-merge-gate-lib.sh"
unset FM_HOME
out=$(jg_merge_post_hook "$home/config" "$home" t8 "$home/state/none.meta" "$HEAD" - 2>&1)
assert_contains "$out" "posted text-only" "post-merge hook posts the card ($out)"
assert_not_contains "$out" "is not set" "post-merge hook lost its home"
assert_contains "$(cat "$log")" "so post" "board saw the merge card"
pass "row verify-merge-card-posts-after-pr-239: the post-merge hook files the merge card"

# The picture rule at done: a ui_change=yes task reports done only with its board card.
uim() {  # <task> <ui_change>: a task record
  printf 'ui_change=%s\n' "$2" > "$home/state/$1.meta"
}
dgate() { jg_ui_card_done_gate "$1" "$home/state/$1.meta" "$HEAD" "$PR" 2>&1; }
export JG_PROOF_BOARD=$root/b.json
row card-none t10 "" "$EMPTY"; uim t10 yes
out=$(dgate t10) && fail "a UI task with no card passed"
assert_contains "$out" "jg-proof-attach.sh attach ready t10 --pr $PR --head $HEAD" "refusal says the one command that posts the card"
ckey=merge-acme-app-pull-7
text_only="{\"decisions\":[{\"key\":\"$ckey\",\"media\":[],\"evidence\":{\"commit\":\"$HEAD\"}}]}"
row card-text t11 "" "$text_only"; uim t11 yes
dgate t11 >/dev/null && fail "a UI task whose card has no pictures passed"
row card-ok t12 "" "$good"; uim t12 yes
out=$(dgate t12) || fail "a UI task with a posted card was refused: $out"
row card-nonui t13 "" "$EMPTY"; uim t13 no
dgate t13 >/dev/null || fail "a non-UI task was touched"
row card-old t14 "" "$EMPTY"; : > "$home/state/t14.meta"
dgate t14 >/dev/null || fail "a record with no ui_change was refused"
pass "row ui-card-done-gate: UI task without a card fails, with a card passes, non-UI untouched"

# The done path itself must hand the picture rule a real head. On the trunk at dad45d8f the gate
# ran before the head was resolved, so every UI change was refused with "its head commit could
# not be read" even when its work copy held a commit and its card was posted.
wt=$root/wt; mkdir -p "$wt"
git -C "$wt" init -q && git -C "$wt" config user.email t@t && git -C "$wt" config user.name t
printf 'x\n' > "$wt/a" && git -C "$wt" add -A && git -C "$wt" commit -qm base
# shellcheck source=bin/jg-dod-lib.sh
. "$ROOT/bin/jg-dod-lib.sh"
uim donehead yes
out=$(jg_dod_accept_ship_done ship direct-PR "$wt" app "done [at=1]: the work is finished" "$home/state" donehead "$home/state/donehead.meta" 2>&1)
assert_not_contains "$out" "head commit could not be read" "the done path hands the picture rule a real head"
assert_contains "$out" "attach ready donehead" "a UI done without its card is refused by the card rule, naming the command"
pass "row ui-card-done-gate-head: a UI done is gated on its card, never on an unread head"
