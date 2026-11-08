#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/jg_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared tmux and
# spawn-world helpers. Wake-queue mocks stay in wake-helpers.sh;
# squad-lead-lifecycle mocks stay in squad-lead-helpers.sh.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${JG_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
JG_TEST_FIXTURES_SOURCED=1

# --- fake tmux / sleep -----------------------------------------------------

# jg_test_fake_tmux_spawn <fakebin>
# Spawn-world tmux: pane_current_path from JG_FAKE_PANE_PATH, session named
# juggernaut, window ops succeed, send-keys succeed. When JG_FAKE_LAUNCH_LOG is
# set, each send-keys -l payload is appended one per line. When JG_FAKE_PANE_LOG
# is set, each send-keys TEXT-LINE payload (the pre-launch pane exports, which
# carry no -l) is appended there instead, one per line in send order. Optional
# JG_FAKE_DUPLICATE_WINDOW is printed from list-windows.
#
# The pane path defaults to empty when JG_FAKE_PANE_PATH is unset. Window
# cleanup and option operations are no-ops. Launch logging is env-gated, so
# suites that do not set JG_FAKE_LAUNCH_LOG keep a silent send-keys.
jg_test_fake_tmux_spawn() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${JG_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'juggernaut\n'; exit 0 ;;
  list-windows)
    if [ -n "${JG_FAKE_DUPLICATE_WINDOW:-}" ]; then
      printf '%s\n' "$JG_FAKE_DUPLICATE_WINDOW"
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${JG_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          # A spawn types a short line sourcing its staged launch file; log
          # the staged command itself so suites assert what the pane runs.
          # Direct literals past the terminal line buffer are truncated, so a
          # long launch only survives when it arrived through that short source.
          case "$a" in
            ". '"*"'")
              staged=${a#". '"}
              staged=${staged%"'"}
              if [ -f "$staged" ]; then
                a=$(cat "$staged")
              elif [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
            *)
              if [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
          esac
          printf '%s\n' "$a" >> "$JG_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    # The pre-launch pane exports ride the text-line form
    # (`send-keys -t <target> <text> Enter`), which carries no -l flag, so a
    # suite that asserts on what the pane shell received opts in with its own
    # log. Skip the flags, the target, and the trailing key so only the payload
    # is recorded, one per line, in send order.
    if [ -n "${JG_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m) continue ;;
          *) [ -n "$literal" ] || printf '%s\n' "$a" >> "$JG_FAKE_PANE_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# jg_test_fake_tmux_send <fakebin>
# Send-world tmux: logs send-keys -l payloads to JG_SEND_LOG, reports a numeric
# cursor_y, and renders an empty bordered composer so the submit path reads
# empty. Env knobs:
#   JG_FAKE_TMUX_SEND_FAIL=1  send-keys exits 1
#   JG_FAKE_TMUX_COMPOSER=pending  capture-pane shows leftover composer text
jg_test_fake_tmux_send() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${JG_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "${JG_SEND_LOG:-/dev/null}"
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${JG_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# jg_test_fake_sleep_noop <fakebin>
jg_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# jg_test_spawn_home <home> [harness]
# Minimal juggernaut home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
jg_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  # These fixtures scaffold no-mistakes briefs to exercise spawn behavior, so the
  # home opts out of the delivery-risk question (docs/configuration.md).
  : > "$home/config/delivery-risk-loose"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
  # A spawn reads the backlog before it creates anything, and a home with no store refuses it, so the
  # fixture home gets a real one (the suite skips plainly without the pinned bd and dolt).
  jg_test_beads_home "$home"
}

# jg_test_spawn_item <home> <id>
# A spawn reads the backlog first: a home with no store refuses it, and so does a task with no item
# there, so the fixture home gets both (the suite skips plainly without the pinned bd and dolt).
# A Beads id has a prefix and a hyphen, so the fixture task ids do too.
jg_test_spawn_item() {
  local home=$1 id=$2
  # A case that takes the home's config away on purpose (no search permission) is filed already and cannot be read.
  [ ! -d "$home/config" ] || [ -x "$home/config" ] || return 0
  # A hostile id is a case that spawn must refuse as an invalid task id before it reads any backlog, so there is no ticket to file.
  case $id in *[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -s "$home/config/beads-dir" ] || jg_test_beads_home "$home"
  jg_test_backlog "$home" show "$id" >/dev/null 2>&1 || jg_test_add "$home" "$id" "[feature] Spawn fixture $id"
}

# jg_test_spawn_brief <home> <id> [captain-intent]
jg_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  jg_test_spawn_item "$home" "$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Juggernaut spec
Exercise the spawn behavior under test.
EOF
}

# jg_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with the spawn tmux stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
jg_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(jg_fakebin "$dir")
  jg_test_fake_tmux_spawn "$fakebin"
  jg_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  jg_test_make_spawn_fakebin "$@"
}

# jg_test_run_spawn <home> <pane-path> <fakebin> [jg-spawn args...]
# Common spawn env. Extra variables in the caller (GROK_HOME, JG_FAKE_LAUNCH_LOG,
# CLAUDE_CONFIG_DIR, ...) are inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
jg_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/jg-claude-trust.sh), so every spawn here runs against a throwaway
  # HOME; without it the suite would write the developer's real ~/.claude.json.
  # CLAUDE_CONFIG_DIR must be pinned too, and pinned EMPTY: the script resolves
  # the store as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so a value inherited from the
  # developer's shell would beat the throwaway HOME and the sandbox would not
  # hold, while an empty value falls through to it. Empty rather than a path
  # because bin/jg-spawn.sh prefixes the launch only when the value is non-empty,
  # so every launch-shape assertion in the suite keeps reading the same command.
  # A test that needs the set case opts in through JG_TEST_CLAUDE_CONFIG_DIR.
  # XDG_DATA_HOME is pinned for the same reason: an OpenCode launch reads
  # <data dir>/opencode/auth.json to decide whether an opencode-go model gets
  # its own session store, so a value inherited from the developer's shell would
  # decide that assertion from their real credentials. The default sits under
  # the throwaway HOME, which is where an unset XDG_DATA_HOME resolves anyway,
  # so the default case is "no auth.json". A test that needs the set case opts
  # in through JG_TEST_XDG_DATA_HOME.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  case ${1:-} in ''|-*) ;; *) jg_test_spawn_item "$home" "$1" ;; esac
  JG_ROOT_OVERRIDE='' JG_HOME="$home" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR="${JG_TEST_CLAUDE_CONFIG_DIR:-}" \
    XDG_DATA_HOME="${JG_TEST_XDG_DATA_HOME:-$spawn_home/.local/share}" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_PROJECTS_OVERRIDE="$home/projects" JG_CONFIG_OVERRIDE="$home/config" \
    JG_SPAWN_NO_GUARD=1 JG_FAKE_PANE_PATH="$pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/jg-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: send tmux + no-op sleep. Echoes the fakebin path.
# Suites that need a recording herdr add that on top of this fakebin.
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(jg_fakebin "$dir")
  jg_test_fake_tmux_send "$fakebin"
  jg_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}
