#!/usr/bin/env bash
# Behavior tests for bin/jg-beads.sh, and for bin/jg-tasks-axi.sh reading through it: its callers must get the
# same lines from either provider. Every store sits in a throwaway folder outside any git tree.
# Stand-ins hashed into a private pin table prove each refusal comes before a binary starts. JG_BEADS_TEST_BD
# and JG_BEADS_TEST_DOLT name the pinned builds for the real case, which skips plainly without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/jg-beads.sh" T=$(jg_test_tmproot jg-beads)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }

mkdir -p "$T/bin" "$T/store" "$T/linked" "$T/repo/.git" "$T/repo/a/b"
STUB=$T/bin/bd STUB_DOLT=$T/bin/dolt
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
[ ! -e "$LOG.down" ] || { echo "the store cannot be read" >&2; exit 1; }
{ printf 'pwd=%s args=%s\n' "$PWD" "$*"; env; } >> "$LOG"
[ "$1" != list ] || [ ! -r "${ROWS:-}" ] || cat "$ROWS"
[ "$1" = init ] || exit 0
printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$BEADS_DIR/metadata.json"
printf 'no-git-ops: true\n' > "$BEADS_DIR/config.yaml"
mkdir -p "$BEADS_DIR/embeddeddolt/jg"
SH
{ cat "$STUB"; printf '# dolt\n'; } > "$STUB_DOLT"
{ cat "$STUB"; printf '# another build\n'; } > "$T/bin/other"
chmod +x "$T"/bin/*
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
  "$os" "$arch" "$(sha_of "$STUB")" "$os" "$arch" "$(sha_of "$STUB_DOLT")" > "$T/pins"
export JG_PIN_FILE_OVERRIDE=$T/pins LOG=$T/call.log BEADS_DIR=$T/store/.beads JG_BEADS_BD=$STUB JG_BEADS_DOLT=$STUB_DOLT
refused() {  # <wanted text> <env assignments and wrapper args...>; no binary may have started.
  local want=$1 out code
  shift
  rm -f "$LOG"
  out=$(env "$@" 2>&1)
  code=$?
  expect_code 2 "$code" "$*"
  assert_contains "$out" "$want" "$*"
  assert_absent "$LOG" "$*: a binary ran"
}
# The path is checked before anything is written.
ln -s "$T/store/.beads" "$T/linked/.beads"
ln -s "$T/repo/a" "$T/alias"
refused "is not set" -u BEADS_DIR "$WRAPPER" list
refused "must be absolute" BEADS_DIR=store/.beads "$WRAPPER" list
refused "no . or .." BEADS_DIR="$T/store/../store/.beads" "$WRAPPER" list
refused "must end in /.beads" BEADS_DIR="$T/store/beads" "$WRAPPER" list
refused "is a symlink" BEADS_DIR="$T/linked/.beads" "$WRAPPER" list
refused "does not exist" BEADS_DIR="$T/none/.beads" "$WRAPPER" list
refused "cannot be /" BEADS_DIR=/.beads "$WRAPPER" list
refused "cannot be $T" HOME="$T" BEADS_DIR="$T/.beads" "$WRAPPER" list
refused "inside the git tree" BEADS_DIR="$T/repo/a/b/.beads" "$WRAPPER" init --prefix jg
refused "inside the git tree" BEADS_DIR="$T/alias/b/.beads" "$WRAPPER" list
assert_absent "$T/repo/a/b/.jg-beads-env" "a refused path took a write"
refused "shared server is banned" BEADS_DOLT_SHARED_SERVER= "$WRAPPER" list
# Only the pinned build starts, and init takes nothing but a prefix.
refused "no store at" "$WRAPPER" list
refused "is not the pinned bd 1.3.4" JG_BEADS_BD="$T/bin/other" "$WRAPPER" init --prefix jg
refused "a prefix is letters" "$WRAPPER" init --prefix --force
refused "usage: jg-beads.sh init" "$WRAPPER" init --prefix jg --server
# Each call runs with the store forced and everything else dropped.
env BD_FOO=1 DOLT_BAR=1 GIT_DIR=/x BD_DISABLE_METRICS=0 DO_NOT_TRACK=0 "$WRAPPER" init --prefix jg 2>&1 || fail "init"
for want in "pwd=$T/store args=init --quiet --stealth --prefix jg" "BEADS_DIR=$T/store/.beads" BD_DISABLE_METRICS=1 \
  DO_NOT_TRACK=1 BD_NON_INTERACTIVE=1 "HOME=$T/store/.jg-beads-env/home" "TMPDIR=$T/store/.jg-beads-env/tmp"; do
  assert_grep "$want" "$LOG" "init must run with $want"
done
for gone in BD_FOO DOLT_BAR GIT_DIR; do assert_no_grep "$gone=" "$LOG" "$gone must not reach bd"; done
"$WRAPPER" list --json || fail "a served verb must run"
assert_grep "args=list --json" "$LOG" "arguments must reach bd unchanged"
assert_grep "BD_DISABLE_METRICS=1" "$LOG" "metrics stay off on every call"
# The stand-in dolt reads back no rule, and a store without it never passes.
out=$("$WRAPPER" check 2>&1)
expect_code 2 "$?" "a store with no hold rule"
assert_contains "$out" "embedded, stealth" "check must name the store"
assert_contains "$out" "hold rule missing or changed in $T/store/.beads: hold_needs_reason wisp_hold_needs_reason" "check must name the rule"
# A read that fails shows its own cause and never reads as a missing rule.
: > "$LOG.down"
out=$("$WRAPPER" check 2>&1)
expect_code 2 "$?" "a store dolt cannot read"
assert_contains "$out" "the store cannot be read" "check must show the real cause"
assert_contains "$out" "cannot read the hold rule" "check must say what it could not do"
assert_not_contains "$out" "hold rule missing" "a failed read is not a missing rule"
rm -f "$LOG.down"
# The verbs and flags that leave the store.
for verb in sync serve config hooks setup migrate; do refused "is not served" "$WRAPPER" "$verb"; done
refused "is not served" "$WRAPPER" config set sync.remote x
refused "usage: jg-beads.sh import" "$WRAPPER" import a.jsonl --extra
refused "plain file name" "$WRAPPER" export -o ../out.jsonl
"$WRAPPER" config set allowed_prefixes jg || fail "a served config key must run"
assert_grep "args=config set allowed_prefixes jg" "$LOG" "a served config key must reach bd"
"$WRAPPER" import a.jsonl || fail "import must run"
"$WRAPPER" export -o out.jsonl || fail "export must run"
assert_grep "args=export -o out.jsonl" "$LOG" "export must reach bd"
for flag in --global --db --db=/x --database=x -C -C/x -qC/x --directory=/x --mem-profile=/x --cpu-profile=/x; do
  refused "off BEADS_DIR" "$WRAPPER" list "$flag"
done
refused "only dolt version" "$WRAPPER" dolt sql-server
refused "reaches a remote" "$WRAPPER" dolt sql -q "CALL DOLT_PUSH('origin', 'main')"
"$WRAPPER" dolt sql -q 'show tables' || fail "a plain query must run"
assert_grep "pwd=$T/store/.beads/embeddeddolt/jg args=sql -q show tables" "$LOG" "dolt must run in the database folder"
# Both providers answer each caller alike. The stand-in prints bd's own JSON for the seeded backlog.
export TZ=UTC  # Beads stamps rows in UTC and tasks-axi in local time.
CLI="$ROOT/bin/jg-tasks-axi.sh" jail=()
same() {  # <wrapper args...>: stdout and exit status match across providers.
  local a b ra=0 rb=0
  a=$(JG_HOME="$T/ta" "$CLI" "$@" 2>/dev/null) || ra=$?
  b=$(JG_HOME="$T/bd" "${jail[@]}" "$CLI" "$@" 2>/dev/null) || rb=$?
  [ "$a" = "$b" ] && [ "$ra" = "$rb" ] || fail "$* differs, rc $ra/$rb: $(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"))"
}
callers() {  # The read shapes each backlog caller parses.
  local state
  same list
  same ready
  for state in queued in_flight "done" held; do same list --state "$state" --fields blocked_by,held,hold_kind,hold_reason; done
  same list --state queued --fields priority
  same list --fields created --limit 2
  same list --repo acme
  same list --blocked
  same list --state "done" --repo none
  for state in jg-one-a jg-two-b jg-wait; do same show "$state" --full; done
  same show nope
  for zone in Etc/GMT-14 Etc/GMT+12; do  # These two are never on the same day, so UTC cannot pass for either.
    assert_contains "$(TZ=$zone JG_HOME="$T/bd" "${jail[@]}" "$CLI" list --fields created --limit 1 2>&1)" ",$(TZ=$zone date +%F)" "created must read as the local day"
  done
  same list --json
  assert_contains "$(. "$ROOT/bin/jg-supervision-lib.sh"; jg_ready_work_rows "$T/bd")" "jg-one-a acme" "supervision must see ready work"
  readers
}
reader() {  # <home> <command...>: a reader of that home's backlog, with no tasks-axi on its path.
  local home=$1
  shift
  env -u JG_PIN_FILE_OVERRIDE HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" JG_BOOTSTRAP_NETWORK=skip JG_PIN_FILE_OVERRIDE="${JG_PIN_FILE_OVERRIDE:-}" \
    "${jail[@]}" "$@" 2>&1
}
flow_home() {  # <ta|bd>: a copy of that home with a held lane and an open lane.
  local lane fl=$T/fl-$1
  mkdir -p "$fl/state" "$fl/data"
  cp -R "$T/$1/config" "$fl/"
  [ ! -f "$T/$1/data/backlog.md" ] || cp "$T/$1/data/backlog.md" "$fl/data/"
  for lane in jg-wait jg-one-a; do
    printf 'kind=ship\n' > "$fl/state/$lane.meta"
    printf 'blocked [at=1000]: waits\n' > "$fl/state/$lane.status"
  done
}
flow() {  # <home>: the lead's lines, past each lane's clock.
  rm -f "$1/state/.flow.last"
  reader "$1" env JG_MAIN_HOME="$ROOT" JG_FLOW_NOW=100000 "$ROOT/core/fleet-flow/bin/jg-flow-check.sh" "$1"
}
owner_rule() {  # <home> <id>: the owner rule's verdict on that row, and its exit status.
  local rc=0
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  reader "$1" env JG_GUARD_HOST_BIN="${GUARD:-}" OPA="${OPA:-}" bash -c '. "$1/core/owner-rules/bin/jg-owner-rules-lib.sh"; jg_owner_rules_check "$2/data" "$3" direct-PR ship' _ "$ROOT" "$1" "$2" || rc=$?
  printf 'rc=%s\n' "$rc"
}
readers() {  # What reads the backlog file reads the same rows from the store.
  local pick out home flying
  pick='[.backlog.records[] | {id,state,title,repo,kind,priority,blocked_by_ids,hold_reason,hold_kind,pr_url,verb:.completion.verb,body_lines}] | sort_by(.id)'
  mkdir -p "$T/user" "$T/ta/state" "$T/ta/config" "$T/bd/data" "$T/bd/state"
  for home in ta bd; do
    reader "$T/$home" "$ROOT/bin/jg-fleet-snapshot.sh" --contribution-input | jq -S "$pick" > "$T/$home.rows" || fail "$home snapshot"
    flying=$(reader "$T/$home" "$ROOT/bin/jg-inbox.sh" status | sed -n '/^--- in flight/,/^$/p')
    printf '%s\n' "$flying" > "$T/$home.flying"
    reader "$T/$home" "$ROOT/bin/jg-owner-asks.sh" --json | jq -S '[.. | objects | select(.id? == "jg-wait")]' > "$T/$home.asks" || fail "$home asks"
  done
  assert_contains "$(cat "$T/bd.rows")" '"hold_reason": "wait: for x"' "the snapshot must read a held row from the store"
  assert_contains "$(cat "$T/bd.flying")" 'jg-fly - Flying' "the inbox status must list the store's work in flight"
  assert_contains "$(cat "$T/bd.asks")" 'jg-wait' "the owner's asks must read the store"
  for out in rows flying asks; do
    diff "$T/ta.$out" "$T/bd.$out" >/dev/null || fail "$out differs across providers: $(diff "$T/ta.$out" "$T/bd.$out")"
  done
  for home in ta bd; do
    reader "$T/$home" python3 "$ROOT/bin/jg_voice_records.py" status --home "$T/$home" --scope full | jq -S 'del(.generated_at, .as_of)' > "$T/$home.voice" || fail "$home voice"
    reader "$T/$home" "$ROOT/bin/jg-whats-left.sh" show | grep -v '^Updated ' > "$T/$home.left"
    printf 'JG\n' > "$T/$home/config/ticket-prefix"
    reader "$T/$home" "$ROOT/bin/jg-ticket-key.sh" sync || fail "$home keys"
    cut -f2 "$T/$home/data/ticket-keys.tsv" | sort > "$T/$home.keys"  # A file row keeps a held item's date before its hold tags, so mint order can differ.
    rm -f "$T/$home/config/ticket-prefix" "$T/$home/data/ticket-keys.tsv" "$T/$home/data/ticket-counters.tsv"
    flow_home "$home"
    flow "$T/fl-$home" > "$T/$home.flow"
    owner_rule "$T/$home" jg-one-a > "$T/$home.owner"
  done
  assert_contains "$(cat "$T/bd.voice")" 'Flying' "the voice status must read the store"
  assert_contains "$(cat "$T/bd.left")" 'jg-one-a' "what is left must read the store"
  assert_contains "$(cat "$T/bd.keys")" 'jg-one-a' "ticket keys must cover the store's open rows"
  [ -z "${GUARD:-}" ] || assert_contains "$(cat "$T/bd.owner")" 'no owner ask' "the owner rule must judge the store's row"
  assert_contains "$(cat "$T/bd.flow")" 'jg-one-a lead' "an open lane must raise its wait line"
  assert_not_contains "$(cat "$T/bd.flow")" 'jg-wait' "a lane held in the store must raise no wait line"
  assert_contains "$(reader "$T/bd" env JG_BIN="$ROOT/bin" "$ROOT/core/fleet-flow/bin/jg-flow.sh" --json | jq -c '.queue')" 'jg-one-a' "the flow report must read the store's queue"
  for out in voice left keys flow owner; do
    diff "$T/ta.$out" "$T/bd.$out" >/dev/null || fail "$out differs across providers: $(diff "$T/ta.$out" "$T/bd.$out")"
  done
  out=$(reader "$T/bd" timeout 90 "$ROOT/bin/jg-session-start.sh")
  for want in 'compact backlog listing (beads;' 'jg-fly,in_flight,recon' 'jg-wait,queued' '"wait: for x"' 'jg-two-b,queued' 'jg-one-a,queued' \
    'bin/jg-tasks-axi.sh show <id> --full.'; do
    assert_contains "$out" "$want" "the digest must print the store's rows"
  done
}
writes() {  # The write shapes backlog callers send, then what each provider reads back.
  local one=https://github.com/o/r/pull/1 two=https://github.com/o/r/pull/2
  same add jg-w1 "no type" --body why
  same add jg-w1 "[feature] One" --kind ship --repo acme --priority 1 --body why
  same add jg-w1 "[feature] One" --priority 1 --body why
  same add jg-w2 "[feature] Two" --priority 2 --body why --blocked-by jg-w1 --pr "$one" --report data/w2/report.md
  same add jg-w3 "[feature] Three" --priority 2 --body why --blocked-by nope
  same add jg-w4 "[feature] Four" --priority 3 --body why --json
  same add jg-w5 --priority 2
  same add jg-w5 "[feature] Five" --priority 2 --body why --pr nope
  same add jg-w5 "[feature] Five" --priority 2 --body why --body-file /dev/null
  same add jg-w5 "[feature] Five" --priority 2 --body why --report nope
  same update jg-w1 --title "[feature] One more" --repo beta --kind recon --priority 2 --body new
  same update jg-w1 --pr "$one"
  same update jg-w1 --pr "$one"
  same update jg-w1 --pr "$two" --json
  same update jg-w1 --report data/w1/report.md
  same update jg-w1
  same update nope --title x
  same update jg-w1 --priority 9
  same block jg-w4 --by jg-w1
  same block jg-w4 --by jg-w1
  same block jg-w4 --by jg-w4
  same block jg-w4 --by nope
  same block jg-w4
  same block nope --by jg-w1
  same "done" jg-w4 --pr "$one" --note finished
  same "done" jg-w4 --pr "$one"
  same "done" jg-w4 --json
  same "done" jg-w2
  same "done" nope
  same add jg-w6 "[feature] Six" --priority 2 --body why
  same start jg-w6
  same start jg-w6
  same show jg-w6
  same reopen jg-w6
  same reopen jg-w6
  same start jg-w6 --json
  same "done" jg-w6
  same reopen jg-w6  # tasks-axi forgets a reopened row's created date and Beads keeps it, so show stays out.
  same start
  same start jg-w6 extra
  same start nope
  same reopen nope
  for ident in jg-w1 jg-w2 jg-w4; do same show "$ident" --full; same show "$ident"; done
  same list
  same ready
  printf 'JG\n' | tee "$T/ta/config/ticket-prefix" > "$T/bd/config/ticket-prefix"
  same add jg-ask "[captain-ask] Asked" --kind ship --repo acme --priority 0 --body why
  assert_grep "jg-ask" "$T/bd/data/ticket-keys.tsv" "an add on the store must key its ticket"
  assert_equals "$(cut -f2 "$T/bd/data/ticket-keys.tsv" | sort)" "$(cut -f2 "$T/ta/data/ticket-keys.tsv" | sort)" "both homes must key the same tickets"
  rm -f "$T"/{ta,bd}/config/ticket-prefix "$T"/{ta,bd}/data/ticket-keys.tsv "$T"/{ta,bd}/data/ticket-counters.tsv
  [ -z "${GUARD:-}" ] || assert_contains "$(owner_rule "$T/bd" jg-ask)" 'rc=0' "the owner rule must pass the store's ask"
  assert_contains "$(reader "$T/bd" "$ROOT/bin/jg-whats-left.sh" show)" "jg-ask" "a look after a write must show the new row"
}
# What a row's lifecycle leaves, through the library the spawn, teardown and session-start scripts call.
TRANSITION=$T/transition.sh
cat > "$TRANSITION" <<'SH'
. "$BIN/jg-timeout-lib.sh"
. "$BIN/jg-tasks-axi-lib.sh"
. "$BIN/jg-backlog-transition-lib.sh"
state=$JG_HOME/state data=$JG_HOME/data op=$1 id=$2
shift 2
case "$op" in
  applies) jg_backlog_transition_applies "$JG_HOME/config" "$data" ship ;;
  dispatch) : > "$state/$id.meta"; jg_backlog_atomic_transition dispatch "$state/$id.meta" "$data" "$id" "$state" ;;
  lane|handover)
    printf 'spawn_gen=%s\nharness=%s\n' "$1" "$2" > "$state/$id.meta"
    [ "$op" = handover ] || op=dispatch
    jg_backlog_atomic_transition "$op" "$state/$id.meta" "$data" "$id" "$state"
    ;;
  close|retain) jg_backlog_atomic_transition "$op" "" "$state/$id.backlog-close" "$data" "$id" "$state" "$@" ;;
  probe) jg_backlog_row_probe "$data" "$id" ;;
  reopen) jg_backlog_mutate "$data" reopen "$id" ;;
esac
rc=$?
printf '%s rc=%s row=[%s] %s\n' "$op" "$rc" "${JG_BACKLOG_ROW_STATE:-}" "${JG_BACKLOG_TRANSITION_ERROR:-}"
exit "$rc"
SH
step() {  # <home> <op> <id> [args...]: the library's answer on one home.
  local home=$1
  shift
  env -u JG_DATA_OVERRIDE -u JG_STATE_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$home" BIN="$ROOT/bin" \
    "${jail[@]}" bash "$TRANSITION" "$@" 2>&1
}
both() {  # <op> <id> [args...]: a gate that answers on the old store answers the same on Beads.
  local old new
  old=$(step "$T/ta" "$@")
  new=$(step "$T/bd" "$@")
  [ "$old" = "$new" ] || fail "transition $*: providers differ"$'\n'"tasks-axi: $old"$'\n'"beads: $new"
  printf 'ok - both stores answer: %s\n' "$new"
}
transitions() {
  local out one=https://github.com/o/r/pull/9 h
  mkdir -p "$T/ta/state" "$T/bd/state" "$T/bd/data"
  same add jg-t1 "[feature] Life" --priority 2 --body why
  same add jg-t2 "[feature] Held" --priority 2 --body why
  same add jg-t3 "[feature] Gone" --priority 2 --body why
  same add jg-t4 "[feature] Waits" --priority 2 --body why --blocked-by jg-t1
  (cd "$T/ta" && TASKS_AXI_FILE="$T/ta/data/backlog.md" tasks-axi hold jg-t2 --reason "owner call" --kind captain >/dev/null) || fail "seed a hold"
  "${jail[@]}" "$WRAPPER" update jg-t2 --status on_hold --set-metadata "hold_reason=owner call" \
    --set-metadata hold_kind=captain >/dev/null 2>&1 || fail "seed a held row"
  both applies jg-t1
  both probe jg-t1
  both probe jg-t2
  both dispatch jg-t1
  both probe jg-t1
  both dispatch jg-t1
  both dispatch jg-t2
  both dispatch jg-t4
  both dispatch nope
  both retain jg-t2 --report data/jg-t2/report.md --note kept
  both probe jg-t2
  both close jg-t3 --pr "$one"
  both probe jg-t3
  both dispatch jg-t3
  both close jg-t3 --pr "$one"
  both close jg-t4 --pr "$one"
  same show jg-t2 --full
  same show jg-t3 --full
  same show jg-t4 --full
  both reopen jg-t3
  assert_not_contains "$("${jail[@]}" "$WRAPPER" show jg-t3 --json 2>/dev/null)" closed_at "a reopened row must forget its close"
  # Beads has one status column, so a row a hold reached first refuses in the store too.
  out=$(JG_HOME="$T/bd" "${jail[@]}" "$CLI" start jg-t2 2>&1)
  expect_code 13 $? "a start on a held row"
  assert_contains "$out" 'stale write refused: jg-t2 has status \"on_hold\"' "a held row must refuse the start"
  # A second writer lands just before the guarded write: each move refuses with bd's 13 and leaves the row alone.
  h=$T/race
  mkdir -p "$h/bin"
  cat > "$h/bin/bd" <<SH
#!/usr/bin/env bash
if [ "\$1" = update ] && [[ " \$* " = *" --if-"* ]] && [ -e "$h/armed" ]; then
  rm -f "$h/armed"
  "$JG_BEADS_TEST_BD" update "\$2" \$(cat "$h/to") >/dev/null 2>&1
fi
exec "$JG_BEADS_TEST_BD" "\$@"
SH
  chmod +x "$h/bin/bd"
  printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' "$os" "$arch" "$(sha_of "$h/bin/bd")" \
    "$os" "$arch" "$(sha_of "$JG_BEADS_TEST_DOLT")" > "$h/pins"
  race() {  # <library exit> <id> <status the other writer sets> <op> [args...]
    local want=$1 id=$2 to=$3 after rc
    shift 3
    printf -- '--status %s\n' "$to" > "$h/to"
    : > "$h/armed"
    out=$(JG_PIN_FILE_OVERRIDE=$h/pins JG_BEADS_BD=$h/bin/bd step "$T/bd" "$1" "$id" "${@:2}")
    rc=$?
    expect_code "$want" "$rc" "$1 $id after a second writer: $out"
    assert_contains "$out" "stale write refused: $id has status \\\"$to\\\"" "$1 $id must name the stale row"
    after=$("${jail[@]}" "$WRAPPER" show "$id" --json 2>/dev/null)
    assert_contains "$after" "\"status\": \"$to\"" "$1 $id must leave the other writer's status"
    assert_not_contains "$after" "$one" "$1 $id must write nothing"
    printf 'ok - a second writer set %s first, and the store refused: %s\n' "$to" "$out"
    rm -f "$T/bd/state/$id.meta"
  }
  same add jg-t5 "[feature] Race" --priority 2 --body why
  race 13 jg-t5 in_progress dispatch
  race 13 jg-t5 closed reopen
  same add jg-t6 "[feature] Race close" --priority 2 --body why
  race 1 jg-t6 in_progress close --pr "$one"
  lanes
}
owner() {  # <id> <lane> <agent>: the row's assignee and metadata.agent, empty for none.
  local row
  row=$("${jail[@]}" "$WRAPPER" show "$1" --json 2>/dev/null)
  [ "$(printf '%s' "$row" | jq -r '(if type == "array" then .[0] else . end) | "\(.assignee // "")/\(.metadata.agent // "")"')" = "$2/$3" ] ||
    fail "row $1 must be owned by [$2/$3]: $row"
  printf 'ok - %s is owned by [%s/%s]\n' "$1" "$2" "$3"
}
lanes() {
  local one=https://github.com/o/r/pull/9 h=$T/race out rc
  same add jg-l1 "[feature] Lane" --priority 2 --body why
  same add jg-l2 "[feature] Held lane" --priority 2 --body why
  same add jg-l3 "[feature] Blocked lane" --priority 2 --body why
  same add jg-l4 "[feature] Race lane" --priority 2 --body why
  same add jg-l5 "[feature] Race handover" --priority 2 --body why
  both lane jg-l1 s1.1.1 claude
  owner jg-l1 s1.1.1 claude
  both lane jg-l1 s1.1.1 claude
  # The old store has no owner to compare, so a second lane is refused on Beads alone.
  out=$(step "$T/bd" lane jg-l1 s2.2.2 codex)
  expect_code 13 $? "a second lane on a claimed row: $out"
  assert_contains "$out" 'stale write refused: jg-l1 is held by \"s1.1.1\", expected \"\"' "a second lane must name the owner"
  printf 'ok - a second lane is refused: %s\n' "$out"
  owner jg-l1 s1.1.1 claude
  both handover jg-l1 s3.3.3 codex
  owner jg-l1 s3.3.3 codex
  both retain jg-l1 --report data/jg-l1/report.md --note kept
  owner jg-l1 "" ""
  both probe jg-l1
  both lane jg-l1 s4.4.4 claude
  owner jg-l1 s4.4.4 claude
  # A closed row keeps its lane as history, whoever closes it, and a reopen clears it.
  both close jg-l1 --pr "$one"
  owner jg-l1 s4.4.4 claude
  both close jg-l1 --pr "$one"
  both reopen jg-l1
  owner jg-l1 "" ""
  # A hold reaches a lane's row: it stays in flight, a relaunch moves the lane, and a retain leaves it held.
  both lane jg-l2 s5.5.5 claude
  (cd "$T/ta" && TASKS_AXI_FILE="$T/ta/data/backlog.md" tasks-axi hold jg-l2 --reason "owner call" --kind captain >/dev/null) || fail "seed a hold"
  "${jail[@]}" "$WRAPPER" update jg-l2 --status on_hold --set-metadata "hold_reason=owner call" \
    --set-metadata hold_kind=captain >/dev/null 2>&1 || fail "seed a held row"
  both probe jg-l2
  both dispatch jg-l2
  both handover jg-l2 s6.6.6 codex
  owner jg-l2 s6.6.6 codex
  both retain jg-l2 --report data/jg-l2/report.md --note kept
  owner jg-l2 "" ""
  both probe jg-l2
  # bd takes no owner guard with --force, so a blocked lane still closes on its status guard.
  both lane jg-l3 s7.7.7 claude
  same add jg-l6 "[feature] Blocker" --priority 2 --body why
  same block jg-l3 --by jg-l6
  both close jg-l3 --pr "$one"
  owner jg-l3 s7.7.7 claude
  # Another lane lands between the read and the write: each move refuses and the winner keeps the row.
  lane_race() {  # <library exit> <id> <the other lane> <the owner it replaces, - for none> <op> [args...]
    local want=$1 id=$2 winner=$3 before=$4
    shift 4
    printf -- '-a %s%s\n' "$winner" "$([ "$before" = - ] || printf ' --if-assignee %s' "$before")" > "$h/to"
    : > "$h/armed"
    out=$(JG_PIN_FILE_OVERRIDE=$h/pins JG_BEADS_BD=$h/bin/bd step "$T/bd" "$1" "$id" "${@:2}")
    rc=$?
    expect_code "$want" "$rc" "$1 $id after another lane: $out"
    assert_contains "$out" "stale write refused: $id is held by \\\"$winner\\\"" "$1 $id must name the other lane"
    owner "$id" "$winner" ""
    printf 'ok - another lane took the row first, and the store refused: %s\n' "$out"
  }
  lane_race 13 jg-l4 winner - lane s8.8.8 claude
  "${jail[@]}" "$WRAPPER" update jg-l5 --status in_progress -a s9.9.9 >/dev/null 2>&1 || fail "seed a lane"
  lane_race 13 jg-l5 winner s9.9.9 handover s0.0.1 codex
  lane_race 1 jg-l5 second winner close --pr "$one"
  lane_race 1 jg-l5 third second retain --report data/jg-l5/report.md --note kept
  # bd itself refuses a reassign that names no owner, so a live lane cannot be overwritten unguarded.
  out=$("${jail[@]}" "$WRAPPER" update jg-l5 -a fourth 2>&1)
  expect_code 1 $? "a bare reassign of a live lane"
  assert_contains "$out" 'cannot reassign jg-l5' "a bare reassign must refuse"
  owner jg-l5 third ""
}
if command -v tasks-axi >/dev/null; then
  mkdir -p "$T/ta/data" "$T/bd/config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$T/ta/data/backlog.md"
  ta() { (cd "$T/ta" && TASKS_AXI_FILE="$T/ta/data/backlog.md" tasks-axi "$@" >/dev/null) || fail "seed: $*"; }
  ta add jg-one-a "First, thing: here" --kind ship --repo acme --priority 1 --body $'line one\nline two'
  ta add jg-two-b Second --priority 2 --blocked-by jg-one-a
  ta add jg-wait Waiting --priority 2
  ta hold jg-wait --reason "wait: for x" --kind captain
  ta add jg-fly Flying --kind recon --priority 3
  ta start jg-fly
  ta add jg-fin Finished --priority 2
  ta "done" jg-fin --pr https://github.com/o/r/pull/5 --note fin
  stamp=$(date -u +%FT%H:%M:0)
  cat > "$T/rows.json" <<JSON
[{"id":"jg-one-a","title":"First, thing: here","description":"line one\nline two","status":"open","priority":1,"issue_type":"task","created_at":"${stamp}1Z","metadata":{"kind":"ship"},"labels":["project:acme"]},
{"id":"jg-two-b","title":"Second","status":"open","priority":2,"issue_type":"task","created_at":"${stamp}2Z","dependencies":[{"issue_id":"jg-two-b","depends_on_id":"jg-one-a","type":"blocks","metadata":"{}"}]},
{"id":"jg-wait","title":"Waiting","status":"on_hold","priority":2,"issue_type":"task","created_at":"${stamp}3Z","metadata":{"hold_reason":"wait: for x","hold_kind":"captain"}},
{"id":"jg-fly","title":"Flying","status":"in_progress","priority":3,"issue_type":"task","created_at":"${stamp}4Z","metadata":{"kind":"recon"}},
{"id":"jg-fin","title":"Finished https://github.com/o/r/pull/5","description":"fin","status":"closed","priority":2,"issue_type":"task","created_at":"${stamp}5Z","closed_at":"${stamp}6Z","external_ref":"https://github.com/o/r/pull/5"}]
JSON
  printf 'beads\n' > "$T/bd/config/backlog-backend"
  out=$(JG_HOME="$T/bd" "$CLI" list 2>&1) && fail "a beads home with no store must refuse"
  assert_contains "$out" "beads-dir" "the refusal must name the store file"
  printf '%s\n' "$BEADS_DIR" > "$T/bd/config/beads-dir"
  out=$(JG_HOME="$T/bd" "$CLI" unblock x --by y 2>&1)
  expect_code 2 $? "an unserved verb on beads"
  assert_contains "$out" "does not serve unblock" "an unserved verb must be refused"
  GUARD=$T/guard/jg-guard-host OPA=$(command -v opa || true)
  if [ -z "$OPA" ] || ! JG_GUARD_HOST_BIN=$GUARD "$ROOT/bin/jg-guard-host.sh" --list >/dev/null 2>&1; then
    GUARD=
    printf 'skip: owner rule verdicts: the guard needs Go and OPA\n'
  fi
  ROWS=$T/rows.json callers
  # A failed read says so, and a lead's store decides whether that lead can sleep.
  : > "$LOG.down"
  out=$(reader "$T/bd" timeout 90 "$ROOT/bin/jg-session-start.sh")
  assert_contains "$out" "beads compact listing failed:" "a failed read must not look like an empty backlog"
  assert_contains "$out" "the store cannot be read" "a failed read must give its reason"
  assert_not_contains "$out" "title-line" "a store has no title lines to fall back on"
  assert_contains "$(reader "$T/bd" "$ROOT/bin/jg-inbox.sh" status)" "the backlog cannot be read" "a failed read must not look like nothing in flight"
  out=$(reader "$T/bd" python3 "$ROOT/bin/jg_voice_records.py" status --home "$T/bd" --scope full)
  expect_code 2 $? "a voice status with no store"
  assert_contains "$out" "the backlog cannot be read" "a failed read must not read as an empty fleet"
  printf 'JG\n' > "$T/bd/config/ticket-prefix"
  out=$(reader "$T/bd" "$ROOT/bin/jg-ticket-key.sh" sync)
  expect_code 2 $? "a key sync with no store"
  assert_contains "$out" "the backlog cannot be read" "a failed read must not look like nothing to key"
  rm -f "$T/bd/config/ticket-prefix"
  assert_contains "$(flow "$T/fl-bd")" "backlog read failed" "an unread hold must not look like no hold"
  assert_contains "$(owner_rule "$T/bd" jg-one-a)" "cannot read the backlog for jg-one-a" "an unread entry must refuse"
  mkdir -p "$T/dm/bin" "$T/dm/state" "$T/dm/config" "$T/dm/data"
  printf '#!/usr/bin/env bash\n' | tee "$T/dm/bin/jg-control.sh" > "$T/dm/bin/jg-send.sh"
  chmod +x "$T/dm/bin/"*.sh
  printf 'kind=squad_lead\nhome=%s\nharness=claude\nbackend=tmux\nwindow=jg-lead\n' "$T/bd" > "$T/dm/state/lead.meta"
  printf -- '- lead - a local lead (home: %s; scope: l; projects: l; added 2026-10-30)\n' "$T/bd" > "$T/dm/data/squad_leads.md"
  printf '1\n' > "$T/dm/config/squad-lead-dormant-secs"
  mv "$T/bd/state" "$T/bd.state"
  sweep_lead() { JG_ROOT_OVERRIDE=$T/dm JG_HOME=$T/dm JG_STATE_OVERRIDE=$T/dm/state "$ROOT/bin/jg-squad-lead-dormant.sh" sweep 2>&1; }
  assert_equals "$(ROWS=$T/rows.json sweep_lead)" "" "a store that cannot be read must keep its lead awake"
  rm "$LOG.down"
  assert_equals "$(ROWS=$T/rows.json sweep_lead)" "" "a lead with open rows must stay awake"
  printf '[]\n' > "$T/none.json"
  assert_contains "$(ROWS=$T/none.json sweep_lead)" "asked: lead" "a lead with an empty store may sleep"
  mv "$T/bd.state" "$T/bd/state"
else
  printf 'skip: providers: tasks-axi is not installed\n'
fi
# A store this wrapper would not create is never opened.
printf '{"dolt_mode": "server"}\n' > "$BEADS_DIR/metadata.json"
refused "not an embedded store" "$WRAPPER" list
printf '{"dolt_mode": "embedded", "dolt_server_host": "x"}\n' > "$BEADS_DIR/metadata.json"
refused "names a server" "$WRAPPER" list
printf '{"dolt_mode": "embedded"}\n' > "$BEADS_DIR/metadata.json"
printf 'no-git-ops: false\n' > "$BEADS_DIR/config.yaml"
refused "not in stealth mode" "$WRAPPER" list
# bin/jg-lint.sh lets only the wrapper name bd.
mkdir -p "$T/lint/bin/backends"
cp "$ROOT/bin/jg-lint.sh" "$T/lint/bin/"
printf '#!/usr/bin/env bash\nbd list\n' | tee "$T/lint/bin/jg-beads.sh" > "$T/lint/bin/jg-other.sh"
assert_contains "$(cd "$T/lint" && bash bin/jg-lint.sh bin/jg-other.sh 2>&1)" "bin/jg-other.sh:2: direct Beads CLI invocation bypasses bin/jg-beads.sh" "lint must refuse bd outside the wrapper"
(cd "$T/lint" && bash bin/jg-lint.sh bin/jg-beads.sh >/dev/null 2>&1) || fail "lint must let the wrapper name bd"
# Bootstrap, the session digest and the remote doctor all report this home's store.
mkdir -p "$T/hh/config" "$T/hh/data" "$T/hh/state" "$T/user"
printf 'beads\n' > "$T/hh/config/backlog-backend"
printf '%s\n' "$BEADS_DIR" > "$T/hh/config/beads-dir"
spawned() {  # A real spawn, relaunch and teardown on a Beads home: the lane follows the task's record.
  local w=$T/world h=$T/world/home wt=$T/world/wt p=$T/world/proj fake out gen
  command -v go >/dev/null || { printf 'skip: real spawn: a spawn builds its core with Go, and Go is not installed\n'; return 0; }
  # shellcheck source=tests/fixtures.sh disable=SC1091
  . "$ROOT/tests/fixtures.sh"
  mkdir -p "$w/gotmp"
  export GOTMPDIR=$w/gotmp GOCACHE=$w/go GOPATH=$w/gp  # A spawn builds its core, and the jail keeps only $T writable.
  jg_git_identity fmtest fmtest@example.com
  git init -q --bare -b main "$w/origin.git"
  git clone -q "$w/origin.git" "$p" 2>/dev/null
  git -C "$p" commit -q --allow-empty -m base
  git -C "$p" push -q origin HEAD:refs/heads/main
  git -C "$p" remote set-head origin main >/dev/null 2>&1
  git -C "$p" worktree add -q --detach "$wt" origin/main
  jg_test_spawn_home "$h"
  fake=$(make_spawn_fakebin "$w/fake" gh gh-axi)
  jg_test_fake_sleep_noop "$fake"
  sed -i '/^set -u$/a case "$*" in *pane_current_command*) echo bash; exit 0 ;; esac' "$fake/tmux"
  printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$h/config/host-memory"
  printf 'beads\n' > "$h/config/backlog-backend"
  printf '%s\n' "$BEADS_DIR" > "$h/config/beads-dir"
  run() {  # <jg-spawn args...>
    # shellcheck disable=SC2016  # The inner shell expands them.
    "${jail[@]}" bash -c '. "$1/tests/fixtures.sh"; shift; jg_test_run_spawn "$@"' _ \
      "$ROOT" "$h" "$wt" "$fake" "$@"
  }
  for id in jg-s1 jg-s2; do
    JG_HOME=$h "${jail[@]}" "$CLI" add "$id" "[feature] Umer's lane" --kind ship --priority 2 --body why >/dev/null || fail "seed $id"
    JG_HOME=$h "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$p" >/dev/null 2>&1 || fail "brief $id"
    sed -i 's/{TASK}/Drive a lane./;s/{JUGGERNAUT_SPEC}/Drive a lane end to end./' "$h/data/$id/brief.md"
  done
  lane_of() { sed -n 's/^spawn_gen=//p' "$h/state/jg-s1.meta"; }
  out=$(run jg-s1 "$p" codex --mode direct-PR --yolo off) || fail "a spawn on a Beads home: $out"
  owner jg-s1 "$(lane_of)" codex
  gen=$(lane_of)
  out=$(JG_FAKE_DUPLICATE_WINDOW=jg-jg-s1 run jg-s1 --relaunch) || fail "a relaunch on a Beads home: $out"
  [ "$(lane_of)" != "$gen" ] || fail "a relaunch must start a new lane"
  owner jg-s1 "$(lane_of)" codex
  gen=$(lane_of)
  # Another home's lane holds this row, so no second agent starts on it.
  "${jail[@]}" "$WRAPPER" update jg-s2 --status in_progress -a other >/dev/null 2>&1 || fail "seed another lane"
  out=$(run jg-s2 "$p" codex --mode direct-PR --yolo off)
  expect_code 13 $? "a spawn on a row another lane holds: $out"
  owner jg-s2 other ""
  printf 'ok - a spawn on another lane'"'"'s row is refused: %s\n' "$(printf '%s\n' "$out" | tail -1)"
  printf 'pr=https://github.com/o/r/pull/7\n' >> "$h/state/jg-s1.meta"
  out=$(JG_HOME=$h JG_STATE_OVERRIDE=$h/state JG_DATA_OVERRIDE=$h/data JG_CONFIG_OVERRIDE=$h/config HOME=$h/user-home \
    PATH="$fake:$PATH" "${jail[@]}" "$ROOT/bin/jg-teardown.sh" jg-s1 2>&1) \
    || fail "a teardown on a Beads home: $out"
  assert_contains "$("${jail[@]}" "$WRAPPER" show jg-s1 --json 2>/dev/null)" '"status": "closed"' "teardown must close the row"
  owner jg-s1 "$gen" codex
  printf 'ok - a real spawn, relaunch and teardown moved the lane on the store\n'
}
start_lines() {  # Each surface's lines about the store, with the fleet's real pin table.
  local home=(env -u JG_PIN_FILE_OVERRIDE HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin JG_HOME="$T/hh"
    JG_STATE_OVERRIDE="$T/hh/state" JG_DATA_OVERRIDE="$T/hh/data" JG_CONFIG_OVERRIDE="$T/hh/config" JG_BOOTSTRAP_NETWORK=skip)
  "${home[@]}" JG_BOOTSTRAP_DETECT_ONLY=1 JG_BOOTSTRAP_VERBOSE_FACTS=1 "${jail[@]}" "$ROOT/bin/jg-bootstrap.sh" 2>&1 \
    | grep -E '^(BEADS_UNHEALTHY|BOOTSTRAP_INFO: Beads)' | sed 's/^/bootstrap /'
  "${home[@]}" "${jail[@]}" timeout 90 "$ROOT/bin/jg-session-start.sh" 2>&1 | sed -n 's/^BEADS_UNHEALTHY/digest &/p'
  "${home[@]}" "${jail[@]}" "$ROOT/bin/jg-remote-doctor.sh" 2>&1 | grep -E '^(check |action: )beads-store'
}
out=$(JG_BEADS_BD=$STUB start_lines)
for want in 'bootstrap BEADS_UNHEALTHY: jg-beads: ' 'digest BEADS_UNHEALTHY: jg-beads: ' 'check beads-store=human: jg-beads: ' \
  'action: beads-store: install the bd and dolt builds'; do
  assert_contains "$out" "$want" "a store that fails its check must say so at every start surface"
done
assert_contains "$out" "is not the pinned bd 1.3.4" "each start surface must give the reason"
rm "$T/hh/config/backlog-backend"
out=$(JG_BEADS_BD=$STUB start_lines)
assert_contains "$out" "check beads-store=skip:" "the doctor must skip a home off Beads"
assert_not_contains "$out" BEADS_UNHEALTHY "a home off Beads must not report a store"
printf 'beads\n' > "$T/hh/config/backlog-backend"
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
else
  unset JG_PIN_FILE_OVERRIDE
  mkdir -p "$T/real"
  export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
  jail=()
  command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
  "${jail[@]}" "$WRAPPER" init --prefix jg 2>/dev/null || fail "real init"
  [ -e "$T/real/.beads.gate.lock" ] || fail "the gate lock must sit beside the store"
  assert_contains "$("${jail[@]}" "$WRAPPER" dolt sql -q 'select count(*) as dirty from dolt_status' 2>&1)" "| 0 " "init must commit the rule"
  "${jail[@]}" "$WRAPPER" check >/dev/null || fail "real check"
  "${jail[@]}" "$WRAPPER" create "First, thing: here" --id jg-one-a --priority 1 --description $'line one\nline two' \
    --labels project:acme --metadata '{"kind":"ship"}' >/dev/null 2>&1 || fail "real create"
  assert_contains "$("${jail[@]}" "$WRAPPER" show jg-one-a --json 2>/dev/null)" '"title": "First, thing: here"' "real show"
  out=$("${jail[@]}" "$WRAPPER" dolt version 2>&1) || fail "real dolt version"
  assert_contains "$out" "dolt version 2.6.0" "real dolt must be the pin"
  assert_not_contains "$out" "unable to query" "real dolt must not call out"
  assert_contains "$("${jail[@]}" "$WRAPPER" dolt sql -q 'show tables' 2>&1)" "issues" "real dolt must read the store"
  if command -v tasks-axi >/dev/null; then
    bd_() { "${jail[@]}" "$WRAPPER" "$@" >/dev/null 2>&1 || fail "real seed: $*"; }
    bd_ create Second --id jg-two-b --priority 2
    bd_ dep add jg-two-b jg-one-a
    bd_ create Waiting --id jg-wait --priority 2 --metadata '{"hold_reason":"wait: for x","hold_kind":"captain"}'
    bd_ update jg-wait --status on_hold
    bd_ create Flying --id jg-fly --priority 3 --metadata '{"kind":"recon"}'
    bd_ update jg-fly --status in_progress
    bd_ create "Finished https://github.com/o/r/pull/5" --id jg-fin --priority 2 --description fin --external-ref https://github.com/o/r/pull/5
    bd_ close jg-fin --reason fin
    printf '%s\n' "$BEADS_DIR" > "$T/bd/config/beads-dir"
    TMPDIR=$T callers  # The jail's /tmp is gone with each call.
    TMPDIR=$T writes
    TMPDIR=$T transitions
    TMPDIR=$T spawned
    out=$(TMPDIR=$T JG_HOME="$T/bd" "${jail[@]}" "$CLI" add --mint "[feature] Mint me" --prefix zz --priority 2 --body why --json) || fail "real mint"
    assert_contains "$out" '"id": "zz-feature-mint-me-' "a minted id must carry the prefix and the title"
  fi
  id=jg-one-a
  # A held row needs a reason on every route in, and the store itself refuses each one.
  jg() { "${jail[@]}" "$WRAPPER" "$@"; }
  no_hold() {  # <label> <wrapper args...>
    local got
    got=$(jg "${@:2}" 2>&1) && fail "$1: the store took a held row with no reason"
    assert_contains "$got" 'hold_needs_reason" violated' "$1"
  }
  row='"issue_type":"task","priority":2,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-01T00:00:00Z"'
  printf '{"id":"jg-held","title":"held","status":"blocked",%s}\n' "$row" > "$T/held.jsonl"
  printf '{"id":"jg-wisp","title":"held","status":"on_hold","ephemeral":true,%s}\n' "$row" > "$T/held-wisp.jsonl"
  no_hold "no reason" update "$id" --status blocked
  no_hold "empty reason" update "$id" --status blocked --set-metadata hold_reason=
  no_hold "spaces for a reason" update "$id" --status blocked --set-metadata "hold_reason=   "
  no_hold "custom status" update "$id" --status on_hold
  no_hold "direct SQL" dolt sql -q "update issues set status='blocked', metadata='{}' where id='$id'"
  no_hold "create into held" create held -t task --status on_hold
  no_hold "ephemeral create into held" create held -t task --ephemeral --status blocked
  no_hold "import of a held row" import "$T/held.jsonl"
  no_hold "ephemeral import of a held row" import "$T/held-wisp.jsonl"
  jg update "$id" --status on_hold --set-metadata "hold_reason=owner call" >/dev/null 2>&1 || fail "a held row with a reason must land"
  no_hold "clearing the reason while held" update "$id" --unset-metadata hold_reason
  held=$(jg show "$id" --json 2>/dev/null)
  assert_contains "$held" '"status": "on_hold"' "the good write must stay held"
  assert_contains "$held" '"hold_reason": "owner call"' "the good write must keep its reason"
  # The embedded store has no server: nothing outlives a jailed call, so each call is a restart from disk.
  assert_contains "$(jg check)" "rule: hold_needs_reason" "the rule must pass check"
  # A healthy store is quiet at start, and a queued telemetry event is not.
  printf '%s\n' "$BEADS_DIR" > "$T/hh/config/beads-dir"
  healthy='healthy: bd 1.3.4, dolt 2.6.0, hold rule present, telemetry off'
  out=$(start_lines)
  assert_contains "$out" "bootstrap BOOTSTRAP_INFO: Beads store $healthy" "bootstrap must name a healthy store"
  assert_contains "$out" "check beads-store=ok: $healthy" "the doctor must pass a healthy store"
  assert_not_contains "$out" BEADS_UNHEALTHY "a healthy store must not report a fault"
  for trace in home/.dolt/eventsData/queued home/.beads/machine-id; do
    mkdir -p "$T/real/.jg-beads-env/${trace%/*}"
    : > "$T/real/.jg-beads-env/$trace"
    out=$(start_lines)
    assert_contains "$out" "digest BEADS_UNHEALTHY: jg-beads: telemetry ran from this store" "$trace must fail the digest"
    assert_contains "$out" "check beads-store=human: jg-beads: telemetry ran" "$trace must fail the doctor"
    rm "$T/real/.jg-beads-env/$trace"
  done
  no_hold "no reason after a restart" update "$id" --status blocked --unset-metadata hold_reason
  assert_contains "$(jg init --prefix jg 2>&1)" "already a store" "a store with its rule must refuse init"
  # A rule gone or weakened fails check, init restores a gone one, and init never replaces a changed one.
  jg dolt sql -q "ALTER TABLE wisps DROP CHECK wisp_hold_needs_reason" >/dev/null 2>&1 || fail "drop the wisps rule"
  out=$(jg check 2>&1)
  expect_code 2 "$?" "a store missing its wisps rule"
  assert_contains "$out" "hold rule missing or changed in $BEADS_DIR: wisp_hold_needs_reason" "check must name the gone rule"
  jg init --prefix jg >/dev/null 2>&1 || fail "init must restore a gone rule"
  jg check >/dev/null || fail "a restored rule must pass check"
  jg dolt sql -q "ALTER TABLE issues DROP CHECK hold_needs_reason" >/dev/null 2>&1 || fail "drop the issues rule"
  jg dolt sql -q "ALTER TABLE issues ADD CONSTRAINT hold_needs_reason CHECK (status <> 'x')" >/dev/null 2>&1 || fail "weaken the issues rule"
  out=$(jg check 2>&1)
  expect_code 2 "$?" "a store with a weakened rule"
  assert_contains "$out" "hold rule missing or changed" "check must catch a weakened rule"
  jg init --prefix jg >/dev/null 2>&1 && fail "init must not pass over a weakened rule"
fi
pass "jg-beads guards"
