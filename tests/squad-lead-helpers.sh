#!/usr/bin/env bash
# tests/squad-lead-helpers.sh - shared fixtures and mocks for the squad_lead
# suites (jg-squad-lead-lifecycle-e2e and jg-squad-lead-safety).
#
# These mocks encode squad-lead-lifecycle behavior (fake tmux that logs window
# ops, fake treehouse that leases/returns homes, fake no-mistakes that records
# init/doctor), so they live here rather than in the generic tests/lib.sh. The
# generic git/identity/meta primitives come from lib.sh, which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake tmux (window ops are logged to JG_FAKE_TMUX_LOG, list-windows returns
# JG_FAKE_TMUX_WINDOW, capture-pane echoes JG_FAKE_TMUX_CAPTURE) plus a fake
# treehouse (durable lease of JG_FAKE_TREEHOUSE_HOME, recording the lease holder
# to JG_FAKE_TREEHOUSE_LEASE_FILE; `return` removes the target and lease unless
# JG_FAKE_TREEHOUSE_RETURN_FAIL is set). Echoes the fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(jg_fakebin "$dir")
  capture="$dir/pane.txt"
  # A real, positively identified empty agent composer. A blank capture is
  # deliberately unknown under the fleet-wide strict blank-row posture.
  printf '❯\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|kill-window)
    printf '%s\n' "$*" >> "$JG_FAKE_TMUX_LOG"
    exit 0
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$JG_FAKE_TMUX_LOG"
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        case "$arg" in
          ". '"*"'")
            staged=${arg#". '"}
            staged=${staged%"'"}
            [ ! -f "$staged" ] || printf 'staged-launch %s\n' "$(cat "$staged")" >> "$JG_FAKE_TMUX_LOG"
            ;;
        esac
      fi
      prev=$arg
    done
    exit 0
    ;;
  list-windows)
    session=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -t ]; then session=$arg; break; fi
      prev=$arg
    done
    while IFS= read -r recorded; do
      [ -n "$recorded" ] || continue
      if [ -z "$session" ]; then
        printf '%s\n' "$recorded"
        continue
      fi
      case "$recorded" in
        "$session":*) printf '%s\n' "${recorded#*:}" ;;
        *:*) ;;
        *) printf '%s\n' "$recorded" ;;
      esac
    done <<EOF
${JG_FAKE_TMUX_WINDOW:-}
EOF
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'juggernaut\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$JG_FAKE_TMUX_LOG"
    cat "$JG_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${JG_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  get)
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${JG_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$JG_FAKE_TREEHOUSE_HOME"
      [ -n "${JG_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$JG_FAKE_TREEHOUSE_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$JG_FAKE_TREEHOUSE_HOME"
    fi
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    [ -z "${JG_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${JG_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$JG_FAKE_TREEHOUSE_LEASE_FILE"
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/treehouse"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(jg_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal juggernaut home (AGENTS.md + bin/).
mark_juggernaut_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Juggernaut\n' > "$home/AGENTS.md"
}

# Scaffold a filled squad_lead charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_squad_lead_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  JG_HOME="$home" JG_SQUAD_LEAD_CHARTER="$charter" "$ROOT/bin/jg-brief.sh" "$id" --squad-lead "$@" >/dev/null
}

# Make a directory look like a genuine seeded squad_lead home (for handoff tests).
seed_squad_lead_home_marker() {
  local home=$1 id=$2
  mark_juggernaut_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.jg-squad-lead-home"
}

