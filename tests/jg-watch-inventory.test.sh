#!/usr/bin/env bash
# The watcher's window inventory in Go (core/watch/cmd/jg-watch-core): which meta records it
# watches and in what order, and the kind, backend and harness it answers for a window.
#
# Two proofs:
#
#   replay   A corpus of state/<id>.meta records - every rule the deleted shell applied:
#            an absent backend= or kind=, an orca terminal target, a record with no target at
#            all, a repeated target, a `jg-control.sh exit` record newer and older than the
#            spawn generation, a non-numeric exit epoch, repeated keys, an unreadable record -
#            is answered by the Go command and by the shell reader it replaced after every
#            record of the corpus. The rows, their order and every answer must be identical.
#            Two corrupted controls (one answer, one row order) must fail the same comparison,
#            so a green replay is never vacuous.
#   live     A real bin/jg-watch.sh cycle over a throwaway home: it reads the inventory through
#            the Go command (a logging wrapper proves the call), scans the fleet, and delivers
#            the one actionable wake the home holds.
#
# The corpus is written here rather than recorded from a home: a record names a project, a
# worktree and a home path, so a recorded corpus would carry an owner's data into the repo.
#
# This is also the test that owns the watcher-window-inventory journey of .done-done.yaml (the done-done journey
# runs this file), so the changed-test map selects it for a change to that journey.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(jg_test_tmproot jg-watch-inventory)
DIR=$TMP_ROOT
CORE="$ROOT/core/watch"
DISPATCH="$ROOT/bin/jg-watch-core.sh"
command -v "${JG_WATCH_CORE_GO:-go}" >/dev/null 2>&1 || { echo "skip: no Go toolchain to build the inventory command"; exit 0; }

( cd "$CORE" && "${JG_WATCH_CORE_GO:-go}" build -o "$DIR/jg-watch-core" ./cmd/jg-watch-core ) \
  || fail "could not build the inventory command"
export JG_WATCH_CORE_BIN="$DIR/jg-watch-core"

# The shell reader this port deletes, quoted from the commit before it. jg_meta_get,
# jg_backend_of_meta, jg_backend_target_of_meta and jg_meta_exited_on_purpose stay in
# bin/jg-backend.sh for the other scripts that read a record, so the reference sources them
# and quotes only the four functions deleted from bin/jg-watch.sh.
# shellcheck source=bin/jg-backend.sh
. "$ROOT/bin/jg-backend.sh"

shell_windows() {  # <state>: recorded_windows, verbatim apart from the row shape
  local meta w seen=
  for meta in "$1"/*.meta; do
    [ -e "$meta" ] || continue
    ! jg_meta_exited_on_purpose "$meta" || continue
    w=$(jg_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf 'r\t%s\n' "$w"
  done
}

shell_kind() {  # <window>: window_kind, verbatim
  local w=$1 meta kind
  meta=$(jg_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

shell_backend() {  # <window>: window_backend, verbatim
  local w=$1 meta backend
  meta=$(jg_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

shell_harness() {  # <window>: window_harness, verbatim
  local w=$1 meta
  meta=$(jg_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

# Every window the corpus names, in first-appearance order (window= then terminal= per
# record). This list is the replay's own scaffolding, not a ported rule: it only decides
# which windows both sides are asked about.
named_windows() {  # <state>
  local meta name seen='|' names
  for meta in "$1"/*.meta; do
    names=$(jg_meta_get "$meta" window; printf '\n'; jg_meta_get "$meta" terminal)
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$seen" in
        *"|$name|"*) continue ;;
      esac
      seen="$seen$name|"
      printf '%s\n' "$name"
    done <<EOF
$names
EOF
  done
}

shell_inventory() {  # <state>: the reference answer in the shape the Go rows compare against
  local state=$1 name
  shell_windows "$state"
  while IFS= read -r name; do
    printf 'w\t%s\t%s\t%s\t%s\n' "$name" "$(shell_kind "$name")" \
      "$(shell_backend "$name")" "$(shell_harness "$name")"
  done <<EOF
$(named_windows "$state")
EOF
}

go_inventory() {  # <state>: the Go answer, unit separators rewritten to tabs
  local state=$1 line
  local metas=("$state"/*.meta)
  "$DISPATCH" inventory "${metas[@]}" | while IFS= read -r line; do
    printf '%s\n' "${line//$'\x1f'/$'\t'}"
  done
}

# ---- the corpus ---------------------------------------------------------------------------

corpus() {  # <dir>: write the records, then echo the state directory
  local dir=$1 state=$1/state
  mkdir -p "$state"
  # Plain tmux record: every field present.
  printf 'window=juggernaut:jg-alpha\nbackend=tmux\nkind=ship\nharness=claude\n' > "$state/alpha.meta"
  # Absent backend= means tmux, absent kind= means ship (the P1 compatibility contract).
  printf 'window=juggernaut:jg-beta\nharness=codex\n' > "$state/beta.meta"
  # A non-tmux backend, and the repeated window below must not re-answer for it.
  printf 'window=herdr:gamma\nbackend=herdr\nkind=scout\nharness=pi\n' > "$state/gamma.meta"
  # A repeated target: gamma answers for it, and the watched list names it once.
  printf 'window=herdr:gamma\nbackend=herdr\nkind=squad_lead\nharness=pi\n' > "$state/gamma-again.meta"
  # orca owns its endpoint: terminal= is the target, window= is not watched here.
  printf 'window=orca-window\nterminal=orca-terminal\nbackend=orca\nkind=squad_lead\nharness=echo\n' > "$state/delta.meta"
  # orca without a terminal= falls back to window=.
  printf 'window=orca-plain\nbackend=orca\nkind=ship\nharness=echo\n' > "$state/epsilon.meta"
  # A legacy kind word is answered as written: window_kind applied no compat rename.
  printf 'window=juggernaut:jg-zeta\nbackend=cmux\nkind=secondmate\nharness=claude\n' > "$state/zeta.meta"
  # A record that names no window at all is never watched, and answers nothing.
  printf 'kind=ship\nharness=claude\n' > "$state/eta.meta"
  # Repeated window= answers its last value (jg_meta_get's own rule); a value keeps
  # everything after the first `=`; an empty harness stays an empty column.
  printf 'window=first-name\nwindow=juggernaut:jg-theta\nkind=ship=extra\nbackend=tmux\nharness=\n' > "$state/theta.meta"
  # An orca terminal that an earlier record already names as its window: the earlier record
  # answers, exactly as jg_backend_meta_for_window's first match did.
  printf 'window=shared-endpoint\nbackend=herdr\nkind=scout\nharness=pi\n' > "$state/iota.meta"
  printf 'window=iota-window\nterminal=shared-endpoint\nbackend=orca\nkind=squad_lead\nharness=echo\n' > "$state/iota-orca.meta"
  # Stopped on purpose (exit epoch newer than spawn_gen): not watched, still answerable.
  printf 'window=juggernaut:jg-kappa\nbackend=tmux\nkind=ship\nharness=claude\nspawn_gen=s100.3\n' > "$state/kappa.meta"
  printf '2000\n' > "$state/kappa.exit"
  # Relaunched since that exit (spawn_gen newer): watched.
  printf 'window=juggernaut:jg-lambda\nbackend=tmux\nkind=ship\nharness=claude\nspawn_gen=s900\n' > "$state/lambda.meta"
  printf '2000\n' > "$state/lambda.exit"
  # A non-numeric exit epoch is not an exit: watched.
  printf 'window=juggernaut:jg-mu\nbackend=tmux\nkind=ship\nspawn_gen=s1\n' > "$state/mu.meta"
  printf 'not-an-epoch\n' > "$state/mu.exit"
  # An epoch equal to the spawn generation is not a later exit: watched.
  printf 'window=juggernaut:jg-nu\nbackend=tmux\nkind=ship\nspawn_gen=s500\n' > "$state/nu.meta"
  printf '500\n' > "$state/nu.exit"
  # No trailing newline: the last line still reads.
  printf 'window=juggernaut:jg-xi\nbackend=tmux\nkind=ship' > "$state/xi.meta"
  # An unreadable record reads as empty, exactly as jg_meta_get answers.
  mkdir -p "$state/omicron.meta"
  # A window name carrying the characters window_key rewrites, so the row itself is pinned.
  printf 'window=juggernaut:jg-a.b/c\nbackend=tmux\nkind=ship\nharness=claude\n' > "$state/pi.meta"
  printf '%s\n' "$state"
}

compare() {  # <state> <label>
  local shell_out go_out
  STATE=$1
  shell_out=$(shell_inventory "$1")
  go_out=$(go_inventory "$1")
  if [ "$shell_out" != "$go_out" ]; then
    printf '%s\n' "shell reader:" "$shell_out" "Go command:" "$go_out" >&2
    fail "$2: the Go inventory differs from the shell reader it replaced"
  fi
}

test_replay() {
  local state shell_out go_out corrupt
  state=$(corpus "$DIR/replay")
  compare "$state" "the corpus"
  # Every rule above must have produced an answer, or the replay compared nothing.
  go_out=$(go_inventory "$state")
  [ "$(printf '%s\n' "$go_out" | grep -c '^r	')" = 12 ] \
    || fail "the corpus no longer pins twelve watched targets: $(printf '%s\n' "$go_out" | grep -c '^r	')"
  for name in juggernaut:jg-alpha juggernaut:jg-beta herdr:gamma orca-terminal orca-plain \
    juggernaut:jg-zeta juggernaut:jg-theta shared-endpoint juggernaut:jg-kappa \
    juggernaut:jg-lambda juggernaut:jg-mu juggernaut:jg-nu juggernaut:jg-xi \
    juggernaut:jg-a.b/c; do
    printf '%s\n' "$go_out" | grep -q "^w	$name	" || fail "the inventory names no answer for $name"
  done
  # Controls: a corrupted answer and a reordered watched list must both fail the comparison.
  STATE=$state
  shell_out=$(shell_inventory "$state")
  corrupt=$(go_inventory "$state" | awk -F'\t' 'BEGIN { OFS="\t" } $1 == "w" && !done { $3 = "corrupted"; done = 1 } { print }')
  [ "$shell_out" != "$corrupt" ] || fail "the comparison accepted a corrupted answer"
  corrupt=$(go_inventory "$state" | awk -F'\t' 'BEGIN { OFS="\t" } $1 == "r" { rows[++n] = $0; next } { rest[++m] = $0 } END { for (i = n; i > 0; i--) print rows[i]; for (i = 1; i <= m; i++) print rest[i] }')
  [ "$shell_out" != "$corrupt" ] || fail "the comparison accepted a reordered watched list"
  pass "the Go inventory answers the corpus exactly as the shell reader did, and both controls fail"
}

test_live_cycle() {
  local dir state pid i log
  dir=$(make_case inventory-live)
  state="$dir/state"
  log="$dir/core-calls.log"
  jg_write_meta "$state/lane.meta" \
    "window=juggernaut:jg-lane" "backend=tmux" "kind=ship" "harness=echo"
  printf 'done: the lane finished its work\n' > "$state/lane.status"
  cat > "$dir/logging-core" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$DIR/jg-watch-core" "\$@"
SH
  chmod 0700 "$dir/logging-core"
  PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$state" \
    JG_WATCH_CORE_BIN="$dir/logging-core" \
    JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 \
    "$ROOT/bin/jg-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" 150 || fail "the watcher cycle did not deliver a wake in time"
  grep -q '^signal:' "$dir/watch.out" || fail "the cycle delivered no signal wake: $(cat "$dir/watch.out")"
  ! grep -q 'window inventory read failed' "$dir/watch.err" \
    || fail "the cycle could not read its inventory: $(cat "$dir/watch.err")"
  [ -s "$log" ] || fail "the cycle never asked the Go command for its inventory"
  grep -q "^inventory .*lane\.meta$" "$log" \
    || fail "the inventory call did not name the home's record: $(cat "$log")"
  pass "a real cycle read its inventory through the Go command and delivered the wake: $(head -n 1 "$dir/watch.out")"
}

test_replay
test_live_cycle
