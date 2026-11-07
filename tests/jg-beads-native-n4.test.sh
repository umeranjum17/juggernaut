#!/usr/bin/env bash
# Ready and blocked from Beads: the provider's ready list is `bd ready` and its blocked list is `bd blocked`, on a real store.
# Needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT naming the pinned builds, and skips without them.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh disable=SC1091
. "$HERE/lib.sh"
# shellcheck source=bin/jg-tasks-axi-lib.sh disable=SC1091
. "$ROOT/bin/jg-tasks-axi-lib.sh"
WRAPPER=$ROOT/bin/jg-beads.sh
WRITE=$ROOT/bin/jg-beads-write.py
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi
T=$(jg_test_tmproot jg-beads-n4)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/one" "$T/cfg"
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT BEADS_DIR=$T/one/.beads
printf '%s\n' "$BEADS_DIR" >"$T/cfg/beads-dir"
PAST=2020-01-02 FUTURE=2099-03-04

bd_() { "$WRAPPER" "$@" 2>/dev/null; }
write() { python3 "$WRITE" "$@" 2>&1; }
provider() { jg_backlog_beads_read "$T/cfg" "$@"; }
same() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }  # <got> <want> <message>
ids() { python3 -c 'import json,sys; print(" ".join(r["id"] for r in json.load(sys.stdin)))'; }  # ids of a bd json list, in order
table_ids() { sed -n 's/^  \([^,]*\),.*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }  # first column of a provider table, in order
status_of() { bd_ show "$1" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); print((r[0] if isinstance(r,list) else r)["status"])'; }
seed() { local id; for id; do "$WRAPPER" create "$id" --id "$id" --force >/dev/null 2>&1 || fail "seed $id"; done; }

"$WRAPPER" init --prefix n4 >/dev/null 2>&1 || fail "init"
before=$("$WRAPPER" dolt sql -q "show create table issues" 2>&1)

# A store of every shape that decides readiness: free rows, a blocker with its dependent, a closed blocker, a plain hold,
# a lane in flight, a future dated hold, and a past dated hold that nobody has woken.
seed n4-free n4-first n4-second n4-closed-blocker n4-after-closed n4-held n4-flying n4-future n4-past n4-epic n4-low n4-kid n4-cond n4-waits
bd_ dep add n4-second n4-first >/dev/null || fail "dep add"
bd_ dep add n4-after-closed n4-closed-blocker >/dev/null || fail "dep add closed"
bd_ close n4-closed-blocker >/dev/null || fail "close blocker"
bd_ dep add n4-epic n4-free >/dev/null || fail "dep add epic"
# Edges the old view read as free and bd does not: a child of a blocked epic, and a conditional dependency.
bd_ dep add n4-kid n4-epic --type parent-child >/dev/null || fail "dep add child"
bd_ dep add n4-cond n4-free --type conditional-blocks >/dev/null || fail "dep add conditional"
bd_ dep add n4-waits n4-free --type waits-for >/dev/null || fail "dep add waits-for"
write hold n4-held --reason "waits on Umer" --kind external >/dev/null || fail "hold"
bd_ update n4-flying --status in_progress >/dev/null || fail "start"
write hold n4-future --reason "later" --kind external --until "$FUTURE" >/dev/null || fail "future hold"
bd_ update n4-past --status deferred --defer "${PAST}T00:00:00Z" --set-metadata hold_reason=returns >/dev/null || fail "past hold"
bd_ update n4-low --priority 4 >/dev/null || fail "priority"
same "$(status_of n4-past)" deferred "a past dated hold must sit deferred until something reads ready"

# 1. The provider's ready list is bd ready: the same rows in the same order, and the past dated row came back by itself.
want=$(bd_ ready --limit 0 --json | ids)
got=$(provider ready | table_ids)
same "$got" "$want" "provider ready must be bd ready"
case " $got " in *" n4-past "*) ;; *) fail "the past dated row must return by itself: $got" ;; esac
same "$(status_of n4-past)" open "bd ready must have woken the past dated row"
for gone in n4-held n4-flying n4-future n4-closed-blocker; do
  case " $got " in *" $gone "*) fail "$gone must not be ready: $got" ;; esac
done
for must in n4-free n4-first n4-after-closed n4-low; do
  case " $got " in *" $must "*) ;; *) fail "$must must be ready: $got" ;; esac
done
case " $got " in *" n4-second "*|*" n4-epic "*|*" n4-kid "*|*" n4-cond "*) fail "a row behind an open blocker must not be ready: $got" ;; esac
case " $got " in *" n4-waits "*) ;; *) fail "bd leaves a waits-for row ready, and so must the provider: $got" ;; esac
assert_contains "$(provider ready)" "count: $(printf '%s\n' "$want" | wc -w | tr -d ' ')" "the count line must match bd ready"

# 2. The blocked list is bd blocked: the same rows, and show names the same blockers.
wanted=$(bd_ blocked --json | ids)
gotten=$(provider list --blocked | table_ids)
same "$(printf '%s\n' "$gotten" | tr ' ' '\n' | sort | tr '\n' ' ')" "$(printf '%s\n' "$wanted" | tr ' ' '\n' | sort | tr '\n' ' ')" "provider blocked list must be bd blocked"
same "$(provider show n4-second | sed -n 's/^  blocked: //p;s/^  blocked_by: //p' | tr '\n' ' ')" "yes n4-first " "show must read the blocker from bd blocked"
same "$(provider show n4-kid | sed -n 's/^  blocked: //p;s/^  blocked_by: //p' | tr '\n' ' ')" "yes n4-epic " "a child of a blocked epic must read as blocked"
same "$(provider show n4-after-closed | sed -n 's/^  blocked: //p' | tr '\n' ' ')" "no " "a closed blocker must not block"

# 3. Closing the blocker releases the row on both sides at once.
bd_ close n4-first >/dev/null || fail "close first"
same "$(provider ready | table_ids)" "$(bd_ ready --limit 0 --json | ids)" "provider ready after the blocker closed"
case " $(provider ready | table_ids) " in *" n4-second "*) ;; *) fail "closing the blocker must release n4-second" ;; esac
same "$(provider show n4-second | sed -n 's/^  blocked: //p')" no "closing the blocker must clear blocked"

# 4. A repo filter reaches bd as its project label.
bd_ update n4-free --add-label project:alpha >/dev/null || fail "label"
same "$(provider ready --repo=alpha | table_ids)" "$(bd_ ready --limit 0 --json --label project:alpha | ids | tr -d '\n')" "ready --repo must be bd ready --label"
same "$(provider ready --repo alpha | table_ids)" n4-free "ready --repo with a separate value"

# 5. The output shape callers read is unchanged: a count line, the table with its columns, the follow-up line and the tip.
provider ready | sed -n 1p | grep -q '^count: [0-9]*$' || fail "ready must open with a count line"
assert_contains "$(provider ready)" "ready[" "ready must print its table"
assert_contains "$(provider ready)" "{id,state,kind,repo,title}:" "ready must keep its columns"
assert_contains "$(provider ready)" "ready_public_followups: 0 delivery-ready obligations" "ready must keep its follow-up line"
assert_contains "$(provider ready)" "Run \`tasks-axi start <id>\` to dispatch one of these" "ready must keep its tip"

# 6. Nothing about the store changed: no table, column, trigger or rule was added.
same "$("$WRAPPER" dolt sql -q "show create table issues" 2>&1)" "$before" "the issues table must be unchanged"

# 7. A store that cannot answer refuses instead of reading as an empty list.
rm -f -- "$T/cfg/beads-dir"
provider ready >/dev/null 2>&1 && fail "a home with no store must not read as an empty ready list"

printf 'ok: jg-beads-native-n4\n'
