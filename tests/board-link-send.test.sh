#!/usr/bin/env bash
# Every send path to the owner gives a bare board link its access token, or refuses the
# message, and leaves a link that already has the token alone. Paths: the board-link helper
# the Telegram gateway calls, the inbox reply and the chat reply. The Telegram send itself is
# covered by TestGatewayBoardLink in core/bus. The token never appears in test output.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot board-link-send)
TOK=tok-$(printf '%s' "$T" | cksum | cut -d' ' -f1)-zq
BOARD='http://100.64.0.1:4420/'
BARE="see ${BOARD}#reports/card-1 now"
WITH="see ${BOARD}?token=${TOK}#reports/card-1 now"
OTHER='see https://example.org/page#reports/x now'

mkhome() { # <name> <url-line|-> -> home dir
  local h=$T/$1
  mkdir -p "$h/state" "$h/data" "$h/config"
  [ "$2" = - ] || printf '%s\n' "$2" > "$h/state/signoff-board.url"
  printf '%s' "$h"
}
env_for() { printf 'JG_HOME=%s JG_ROOT_OVERRIDE=%s JG_STATE_OVERRIDE=%s/state JG_DATA_OVERRIDE=%s/data JG_CONFIG_OVERRIDE=%s/config' "$1" "$ROOT" "$1" "$1" "$1"; }
# check <label> <expected> <actual>: compare without printing either (they may hold the token)
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: output differs from the expected text"; fi; }

good=$(mkhome good "${BOARD}?token=${TOK}#old")
notok=$(mkhome notoken "$BOARD")
nofile=$(mkhome nofile -)

# Path 1: the helper the Telegram gateway runs.
# shellcheck disable=SC2046
fix() { env $(env_for "$1") bash "$ROOT/bin/jg-board-link.sh" fix <<< "$2" 2>"$T/err"; }
same "gateway helper: bare link gets the token" "$WITH" "$(fix "$good" "$BARE")"
same "gateway helper: tokened link unchanged" "$WITH" "$(fix "$good" "$WITH")"
same "gateway helper: other host unchanged" "$OTHER" "$(fix "$good" "$OTHER")"
for h in "$notok" "$nofile"; do
  if fix "$h" "$BARE" >"$T/out"; then fail "gateway helper: a bare link with no token must be refused"; fi
  [ ! -s "$T/out" ] || fail "gateway helper: a refused message printed text"
  grep -q 'access token' "$T/err" || fail "gateway helper: refusal gives no plain reason"
done
pass "gateway helper: refused with a reason when the token is unavailable"

# Path 2: inbox reply.
reply() { # <home> <text> -> prints the recorded reply file
  local h=$1
  # The reply answers his note, so it carries the ask block (2026-11-05): his words and their
  # date, done, not done, next, and a proof link.
  local block=$'Your ask: "Show the report link on the board." (2026-01-01)\nDone: the reply holds the link.\nNot done: nothing.\nNext: read it.\nProof: https://example.org/proof\n'
  mkdir -p "$h/state/inbox"
  printf 'id=n1\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\nShow the report link on the board.\n' > "$h/state/inbox/n1.note"
  # shellcheck disable=SC2046
  env $(env_for "$h") JG_VOICE_FILE=/dev/null bash "$ROOT/bin/jg-inbox.sh" reply n1 "$block$2" >"$T/rout" 2>"$T/err"
}
recorded() { cat "$1"/state/inbox/.replies/n1 2>/dev/null; }
reply "$good" "$BARE" || fail "inbox reply with a token available failed"
case "$(recorded "$good")" in *"?token=${TOK}#reports/card-1"*) pass "inbox reply: bare link gets the token" ;; *) fail "inbox reply: recorded reply has no tokened link" ;; esac
reply "$(mkhome good2 "${BOARD}?token=${TOK}")" "$WITH" || fail "inbox reply with a tokened link failed"
case "$(recorded "$T/good2")" in *"${BOARD}?token=${TOK}#reports/card-1 now"*) pass "inbox reply: tokened link unchanged" ;; *) fail "inbox reply: tokened link changed" ;; esac
if reply "$notok" "$BARE"; then fail "inbox reply: a bare link with no token must be refused"; fi
[ -z "$(recorded "$notok")" ] || fail "inbox reply: a refused reply was recorded"
pass "inbox reply: refused when the token is unavailable"

# Path 3: chat reply.
# shellcheck disable=SC2046
chat() { env $(env_for "$1") bash "$ROOT/bin/jg-chat.sh" "${@:2}" >"$T/rout" 2>"$T/err"; }
chat_text() { cat "$1"/state/chat.jsonl 2>/dev/null; }
chat "$good" reply '#fleet' "$BARE" || fail "chat reply with a token available failed"
case "$(chat_text "$good")" in *"?token=${TOK}#reports/card-1"*) pass "chat reply: bare link gets the token" ;; *) fail "chat reply: stored reply has no tokened link" ;; esac
chat "$good" reply '#fleet' "$WITH" || fail "chat reply with a tokened link failed"
if chat "$notok" reply '#fleet' "$BARE"; then fail "chat reply: a bare link with no token must be refused"; fi
[ -z "$(chat_text "$notok")" ] || fail "chat reply: a refused reply was stored"
pass "chat reply: refused when the token is unavailable"
