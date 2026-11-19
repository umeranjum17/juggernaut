#!/usr/bin/env bash
# Slice 11a of the item store: the owner's chat reads and writes the store beside the bus. Drives adapters/chat_bridge.py,
# chat-wiring.sh, jg-item and owner.py as processes in a temporary main home and a lead home bound to it; the bus is stubbed by a
# fixture record, state/captain-channel.jsonl, written the way core/bus/cmd/jg-bus writes it (one JSON event per line).
# a: would-send lists a question once and acks. b: a security item and a main-down item, climbed to him by the tick, give one line each.
# c: compare against a fixture channel record (paired, an unpaged channel event, an unsent page, a rerun, summary and reply events).
# d: received writes the tell, and with a pick closes the question. e: chat-wiring.sh --dry-run.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ITEM=$ROOT/core/item-store
JI=$ITEM/jg-item
BR=$ITEM/adapters/chat_bridge.py
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
export JG_ITEM_TICK_LEASE_S=0
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
H=$d/main; L=$d/lead
mkdir -p "$H/state" "$H/config" "$H/data" "$L/state" "$L/config" "$L/data" "$H/bin"
printf 'muxr\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$L/.jg-squad-lead-parent"
H=$(cd "$H" && pwd -P); L=$(cd "$L" && pwd -P)
: > "$H/config/item-store"; : > "$H/config/chat-store"
S=$H/state/item-store
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
want() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }
ji() { env JG_HOME="$H" "$JI" "$@"; }
jl() { env JG_HOME="$L" "$JI" "$@"; }
br() { env JG_HOME="$H" python3 -I "$BR" "$@"; }
sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$H" "$1"; }
wlog() { cat "$S/chat-would-send.log" 2>/dev/null; }
intakes() { sql "SELECT count(*) FROM item WHERE kind='intake' AND state='open' AND key LIKE 'intake:main/chat-%'"; }

# ------------------------------------------------------------------ a: a question pages him; would-send lists it once
ji open question:main/Q1 --kind question --home main --subject T-ONE --owes "which colour for T-ONE" --options 'red|blue' --source qa >/dev/null
br would-send >/dev/null; rc=$?
want "a1 would-send exits 0" 0 "$rc"
want "a2 one would-send line for the question: <seq> <key> <text>" "question:main/Q1 which colour for T-ONE" "$(wlog | awk -F'\t' 'NF==3 && $1 ~ /^[0-9]+$/ {print $2, $3}')"
want "a3 a second would-send writes nothing" 1 "$(br would-send >/dev/null; wlog | wc -l | tr -d ' ')"
want "a4 the bridge acked the reader's cursor" "owner" "$(sql "SELECT reader FROM cursor WHERE reader='owner'")"
jl open question:muxr/L1 --kind question --home muxr --subject T-LEAD --owes "lead asks him" --options 'yes|no' --source la >/dev/null; br would-send >/dev/null
want "a5 a lead home's question is one more line, never a repeat" 2 "$(wlog | wc -l | tr -d ' ')"

# ------------------------------------------------------------------ b: security and main-down, climbed to him by the tick
ji open security:fleet/leak --kind security --home main --subject stamp --owes "a key is in a log" --due 1 --source sb >/dev/null
ji open main-down:main/supervision --kind main-down --home main --subject supervision --owes "Main's supervision stopped" --due 1 --source mb >/dev/null
sleep 2; ji tick >/dev/null
want "b1 both climbed to him" "owner owner" "$(sql "SELECT holder FROM item WHERE key IN ('security:fleet/leak','main-down:main/supervision') AND state='open'" | tr '\n' ' ' | sed 's/ $//')"
br would-send >/dev/null
want "b2 a security line and a main-down line" "main-down:main/supervision security:fleet/leak" "$(wlog | awk -F'\t' '$2 ~ /^(security|main-down)/ {print $2}' | sort | tr '\n' ' ' | sed 's/ $//')"
want "b3 four lines in all" 4 "$(wlog | wc -l | tr -d ' ')"

# ------------------------------------------------------------------ c: compare with the captain channel's own record
now=$(date +%s); later=$((now + 2000)); REC=$H/state/captain-channel.jsonl
ev() { printf '{"at":%s,"kind":"%s","key":"%s","subject":"jg.captain.%s","text":"%s"}\n' "$1" "$2" "$3" "$2" "$4" >> "$REC"; }
ev "$now" card which-colour "A decision waits for you: T-ONE, which colour?"
ev "$now" card lead-asks "A decision waits for you: T-LEAD, lead asks him"
ev "$now" alert main-down-alert "main-down:main/supervision: Main's supervision stopped"
ev "$now" summary turn-1 "Turn summary: nothing owed"
ev "$now" reply r-1 "Reply to his note"
ev "$now" card never-paged "A decision waits for you: T-NINE, never paged"
out=$(br compare --now "$later"); rc=$?
want "c1 compare exits 0" 0 "$rc"
want "c2 the question's and the main-down's pages are paired; the unpaged event and the unsent security page open one intake each" "intake:main/chat-never-paged intake:main/chat-security:fleet/leak" "$(sql "SELECT key FROM item WHERE kind='intake' AND state='open' ORDER BY key" | tr '\n' ' ' | sed 's/ $//')"
want "c3 the intake items are sourced chat-compare:<item key>" "chat-compare:never-paged chat-compare:security:fleet/leak" "$(sql "SELECT source FROM move WHERE key LIKE 'intake:main/chat-%' ORDER BY source" | tr '\n' ' ' | sed 's/ $//')"
br compare --now "$later" >/dev/null
want "c4 the same compare twice opens nothing more" 2 "$(intakes)"
want "c5 a turn summary and a reply event write no intake and no would-send line" "4 2" "$(wlog | wc -l | tr -d ' ') $(intakes)"
ev "$now" card late-one "A decision waits for you: T-ONE again"
br compare --now "$now" >/dev/null
want "c6 an event less than 15 minutes old waits for its page" 2 "$(intakes)"

# ------------------------------------------------------------------ d: his messages
out=$(br received --message-id m-d1 --text "how is T-ONE going?")
want "d1 received writes the tell" "open" "$(sql "SELECT state FROM item WHERE key='tell:main/m-d1'")"
br received --message-id m-d2 --key question:main/Q1 --pick red >/dev/null
want "d2 received with a pick closes the question" "done" "$(sql "SELECT state FROM item WHERE key='question:main/Q1' ORDER BY gen DESC LIMIT 1")"
want "d3 its close is stamped for his chat and carries the message id" "owner:chat owner:chat:m-d2 pick=red" "$(sql "SELECT by || ' ' || why FROM move WHERE key='question:main/Q1' AND verb='close'")"
want "d4 a pick he was not offered is listed as an intake item, not lost" "intake" "$(br received --message-id m-d3 --key question:muxr/L1 --pick maybe | tail -1)"
br received --message-id m-d4 --key question:main/Q1 >/dev/null 2>&1; want "d5 --key without --pick is a usage refusal" 2 "$?"
want "d6 the tick's stamp check finds nothing forged" 0 "$(ji tick >/dev/null; sql "SELECT count(*) FROM item WHERE kind='security' AND key LIKE 'security:fleet/forged-%'")"

# ------------------------------------------------------------------ e: the wiring
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/bin/jg-check-register.sh"; chmod +x "$H/bin/jg-check-register.sh"
cp "$H/bin/jg-check-register.sh" "$H/bin/jg-check-unregister.sh"
mkdir -p "$H/core/item-store/adapters"; cp "$BR" "$H/core/item-store/adapters/chat_bridge.py"
out=$("$ITEM/chat-wiring.sh" --dry-run "$H"); rc=$?
want "e1 --dry-run exits 0 and writes nothing" "0 0" "$rc $([ -e "$H/state/item-store-chat.check.sh" ] && echo 1 || echo 0)"
case $out in *"config/chat-store"*"would-send"*"compare"*"would run: env -u JG_STATE_OVERRIDE JG_HOME=$H $H/bin/jg-check-register.sh item-store-chat"*) ok "e2 --dry-run prints the register call and the check" ;; *) bad "e2 dry run" "$out" ;; esac
"$ITEM/chat-wiring.sh" "$H" >/dev/null; want "e3 wiring writes the check, twice the same" "0" "$("$ITEM/chat-wiring.sh" "$H" >/dev/null; echo $?)"
rm "$H/config/chat-store"; before=$(wlog | wc -l | tr -d ' '); "$H/state/item-store-chat.check.sh"
want "e4 with config/chat-store absent the check does nothing" "$before" "$(wlog | wc -l | tr -d ' ')"
case $("$ITEM/chat-unwiring.sh" --dry-run "$H") in *"would run: $H/bin/jg-check-unregister.sh item-store-chat"*) ok "e5 chat-unwiring.sh --dry-run prints the unregister call" ;; *) bad "e5 unwiring" "no unregister call" ;; esac

[ "$fail" -eq 0 ]
