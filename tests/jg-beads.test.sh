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
CLI="$ROOT/bin/jg-tasks-axi.sh" today=$(date +%F) jail=()
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
  same list --json
  assert_contains "$(. "$ROOT/bin/jg-supervision-lib.sh"; jg_ready_work_rows "$T/bd")" "jg-one-a acme" "supervision must see ready work"
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
  for ident in jg-w1 jg-w2 jg-w4; do same show "$ident" --full; same show "$ident"; done
  same list
  same ready
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
  stamp="${today}T10:00:0"
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
  out=$(JG_HOME="$T/bd" "$CLI" reopen x 2>&1)
  expect_code 2 $? "an unserved verb on beads"
  assert_contains "$out" "does not serve reopen" "an unserved verb must be refused"
  ROWS=$T/rows.json callers
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
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
else
  unset JG_PIN_FILE_OVERRIDE
  mkdir -p "$T/real"
  export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
  jail=()
  command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
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
    TMPDIR=$T callers  # The jail's /tmp is read-only.
    TMPDIR=$T writes
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
