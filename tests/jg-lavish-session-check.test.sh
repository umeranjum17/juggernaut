#!/usr/bin/env bash
# The day-old session sweep, driven as the watcher check it registers as: an open
# session whose artifact has not changed for a day is ended and reported on one
# line, while a fresh one and another lane's page are left alone.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-lavish-session-check.sh"
TMP_ROOT=$(jg_test_tmproot jg-lavish-session-check)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
END_LOG="$TMP_ROOT/end.log"
export END_LOG
cat > "$BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = end ] || exit 2
printf '%s\n' "$2" >> "$END_LOG"
SH
chmod +x "$BIN/lavish-axi"

# The store is Lavish's own persisted contract: one session per artifact, keyed
# by a digest of the real path.
SESSIONS="$TMP_ROOT/sessions"
mkdir -p "$SESSIONS/old" "$SESSIONS/fresh" "$TMP_ROOT/other"
printf '<h1>old</h1>\n' > "$SESSIONS/old/board.html"
printf '<h1>fresh</h1>\n' > "$SESSIONS/fresh/board.html"
printf '<h1>other</h1>\n' > "$TMP_ROOT/other/board.html"
# Two days old, one minute old, and two days old in a lane this home does not own.
touch -d '2 days ago' "$SESSIONS/old/board.html"
touch -d '2 days ago' "$TMP_ROOT/other/board.html"
perl -MJSON::PP -MCwd=realpath -e '
  my ($path, @files) = @ARGV;
  my %sessions;
  my $n = 0;
  for my $file (@files) {
    $n++;
    my $real = realpath($file) or die "missing $file\n";
    $sessions{sprintf "k%015d", $n} = {
      key => sprintf("k%015d", $n), file => $real, status => "open",
      url => "http://review.example:4387/session/$n",
    };
  }
  open my $out, ">", $path or die $!;
  print $out encode_json({ sessions => \%sessions });
' "$TMP_ROOT/state.json" \
  "$SESSIONS/old/board.html" "$SESSIONS/fresh/board.html" "$TMP_ROOT/other/board.html"

run_check() {
  PATH="$BIN:$PATH" LAVISH_AXI_STATE_DIR="$TMP_ROOT" \
    JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" "$CHECK" "$@"
}

test_an_old_session_is_ended_and_reported_once() {
  local out
  : > "$END_LOG"
  out=$(run_check --root "$HOME_DIR" --root "$SESSIONS") || fail "the session sweep failed"
  [ "$(printf '%s\n' "$out" | grep -c '^closed: ')" = 1 ] \
    || fail "the sweep did not report exactly one closed session: $out"
  assert_contains "$out" "$(cd "$SESSIONS/old" && pwd -P)/board.html" \
    "the closed line does not name the session's artifact"
  [ "$(wc -l < "$END_LOG" | tr -d ' ')" = 1 ] \
    || fail "the sweep ended more than the one day-old session this home owns: $(cat "$END_LOG")"
  assert_grep "$(cd "$SESSIONS/old" && pwd -P)/board.html" "$END_LOG" \
    "the sweep ended a different artifact than the one it reported"
  pass 'a day-old session this home owns is ended and reported on one line'
}

test_a_fresh_or_foreign_session_is_left_alone() {
  local out fresh other
  fresh="$(cd "$SESSIONS/fresh" && pwd -P)/board.html"
  other="$(cd "$TMP_ROOT/other" && pwd -P)/board.html"
  : > "$END_LOG"
  out=$(run_check --root "$HOME_DIR" --root "$SESSIONS")
  assert_not_contains "$out" "$fresh" "a session changed a minute ago was swept"
  assert_not_contains "$out" "$other" "another lane's session was swept"
  assert_no_grep "$fresh" "$END_LOG" "the sweep ended a fresh session"
  pass 'a fresh session and another lane'"'"'s page are never ended'
}

test_list_only_reports_without_ending() {
  local out
  : > "$END_LOG"
  out=$(run_check --root "$HOME_DIR" --root "$SESSIONS" --list-only) \
    || fail "the list-only sweep failed"
  assert_contains "$out" 'open: http://review.example:4387/session/' \
    "list-only did not report the day-old session"
  [ ! -s "$END_LOG" ] || fail "list-only ended a session: $(cat "$END_LOG")"
  pass 'list-only reports the day-old session and ends nothing'
}

test_the_registered_check_is_a_single_line_sweep() {
  local check
  PATH="$BIN:$PATH" LAVISH_AXI_STATE_DIR="$TMP_ROOT" \
    JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" \
    "$CHECK" --install >/dev/null || fail "the sweep could not install itself as a check"
  check="$HOME_DIR/state/lavish-session.check.sh"
  [ -f "$check" ] || fail "the registered check was not written"
  # The registered script must name the interpreter and the real sweep path.
  # A single-quoted format string leaves ${SCRIPT_DIR} literal here, which is
  # both a wrong comment and a ShellCheck SC2016 failure in the lint gate.
  grep -qx '#!/usr/bin/env bash' "$check" \
    || fail "the registered check does not open with a bash shebang"
  grep -qF "# Registered sweep: $ROOT/bin/jg-lavish-session-check.sh" "$check" \
    || fail "the registered check does not name its real sweep path: $(sed -n '2p' "$check")"
  ! grep -qF "\${SCRIPT_DIR}" "$check" \
    || fail "the registered check kept a literal \${SCRIPT_DIR} instead of the path"
  assert_present "$HOME_DIR/state/lavish-session.check-trust" \
    "the registered check was not bound by the custom-check trust record"
  pass 'the sweep registers as a watcher check with its own trust record'
}

test_an_old_session_is_ended_and_reported_once
test_a_fresh_or_foreign_session_is_left_alone
test_list_only_reports_without_ending
test_the_registered_check_is_a_single_line_sweep
printf 'jg-lavish-session-check: ok\n'
