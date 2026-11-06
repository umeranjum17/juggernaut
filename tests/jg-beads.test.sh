#!/usr/bin/env bash
# Behavior tests for bin/jg-beads.sh. Every store sits in a throwaway folder outside any git tree.
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
{ printf 'pwd=%s args=%s\n' "$PWD" "$*"; env; } > "$LOG"
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
refused "already a store" "$WRAPPER" init --prefix jg
"$WRAPPER" list --json || fail "a served verb must run"
assert_grep "args=list --json" "$LOG" "arguments must reach bd unchanged"
assert_grep "BD_DISABLE_METRICS=1" "$LOG" "metrics stay off on every call"
assert_contains "$("$WRAPPER" check)" "embedded, stealth" "check must name the store"
# The verbs and flags that leave the store.
for verb in sync serve config hooks setup migrate; do refused "is not served" "$WRAPPER" "$verb"; done
for flag in --global --db --db=/x --database=x -C -C/x -qC/x --directory=/x --mem-profile=/x --cpu-profile=/x; do
  refused "off BEADS_DIR" "$WRAPPER" list "$flag"
done
refused "only dolt version" "$WRAPPER" dolt sql-server
refused "reaches a remote" "$WRAPPER" dolt sql -q "CALL DOLT_PUSH('origin', 'main')"
"$WRAPPER" dolt sql -q 'show tables' || fail "a plain query must run"
assert_grep "pwd=$T/store/.beads/embeddeddolt/jg args=sql -q show tables" "$LOG" "dolt must run in the database folder"
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
  "${jail[@]}" "$WRAPPER" check >/dev/null || fail "real check"
  id=$("${jail[@]}" "$WRAPPER" create one --json 2>/dev/null | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')
  assert_contains "$("${jail[@]}" "$WRAPPER" show "$id" --json 2>/dev/null)" '"title": "one"' "real show"
  out=$("${jail[@]}" "$WRAPPER" dolt version 2>&1) || fail "real dolt version"
  assert_contains "$out" "dolt version 2.6.0" "real dolt must be the pin"
  assert_not_contains "$out" "unable to query" "real dolt must not call out"
  assert_contains "$("${jail[@]}" "$WRAPPER" dolt sql -q 'show tables' 2>&1)" "issues" "real dolt must read the store"
fi
pass "jg-beads guards"
