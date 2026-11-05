#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: jg-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|devin|unknown
#        jg-harness.sh crew             print the effective OPERATOR harness
#                                        (config/crew-harness; "default" resolves to own)
#        jg-harness.sh squad_lead [id]  print the harness the PRIMARY uses to launch
#                                        SQUAD_LEAD agents: config/squad-lead-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        squad-lead-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        jg-harness.sh squad-lead-model [id] print the optional MODEL token from
#                                        config/squad-lead-harness, or empty when absent.
#        jg-harness.sh squad-lead-effort [id] print the optional EFFORT token from
#                                        config/squad-lead-harness, or empty when absent.
#        jg-harness.sh validate-native-effort <harness> <model> <effort>
#                                        Refuse ultra unless the harness is pi or
#                                        pi-signed and the model explicitly names
#                                        codex-native/<id>. Other efforts retain
#                                        their adapter's existing policy. Native
#                                        Codex validates model support at startup.
#        jg-harness.sh ancestry [<pid>] print "<strength> <harness>" for the nearest
#                                        harness process at or above <pid> (default this
#                                        process), or nothing when the walk finds none.
#                                        Ancestry evidence only, with no marker layer, so
#                                        a real harness process can be asked what the walk
#                                        makes of it (tests/jg-harness-liveness-drift-live-e2e.test.sh).
#        jg-harness.sh ancestry-descent [<pid>] [<leaf-pid>...]
#                                        print each DISTINCT "<strength> <harness>" the walk
#                                        reaches from the vantages on the UPWARD path
#                                        between the deepest descendant of <pid> and <pid>
#                                        itself, deepest first. Same evidence-only purpose
#                                        as `ancestry`, asked from the vantage point a tool
#                                        subprocess actually occupies rather than from the
#                                        top of the session, which is the only place a
#                                        harness behind an interpreter shim can be seen at
#                                        comm strength. Optional <leaf-pid> values restrict
#                                        which descendants may be chosen as the deepest one,
#                                        so a caller that knows the terminal's foreground
#                                        process group can keep a backgrounded process out
#                                        of the selection.
# config/squad-lead-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# An entry tagged "squad-lead" in config/tool-models.json (bin/jg-tool-models.sh) outranks
# this global line, so one JSON edit moves the lead; without one this line stands.
# With an id, config/squad_leads/<id>/harness takes precedence as a complete
# three-token harness/model/effort pin. Invalid pins refuse and name the file.
# config/crew-harness stays a bare adapter name, never parsed for a model.
# Detection evidence and precedence:
#   Markers  - verified environment variables a harness publishes about itself.
#              Cheap and unambiguous about WHICH harness set them, but they are
#              ordinary environment state: a child inherits them, and a terminal
#              multiplexer can replay a stale one into an unrelated session.
#   Ancestry - the nearest harness process in this process's parent chain. This
#              is the structural fact about who actually owns the process tree,
#              so it is what settles a disagreement.
# detect_own is the single owner of how the two combine; harness_marker and
# harness_ancestry only report evidence. Record each newly verified env marker
# in harness_marker, and each newly verified command name in harness_ancestry.
# Supervision-branch primary pin: a supervision branch running as its own
# process under another harness (a Pi engine under a Claude primary detects as
# pi) would otherwise resolve "own" - and with it an absent or "default"
# config/crew-harness or config/squad-lead-harness - to its own harness and
# dispatch crew there. While JG_SUPERVISION_ACTOR=branch, a non-empty
# JG_SUPERVISION_PRIMARY_HARNESS names the primary's harness and replaces
# detection for the own, crew, and squad_lead resolutions; a value that names
# no known harness refuses (exit 2, nothing on stdout) instead of resolving.
# Outside the branch actor the pin is ignored, and the evidence-only ancestry
# verbs never consult it.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# shellcheck source=bin/jg-cursor-lib.sh
. "$SCRIPT_DIR/jg-cursor-lib.sh"
# shellcheck source=bin/jg-gemini-lib.sh
. "$SCRIPT_DIR/jg-gemini-lib.sh"
# shellcheck source=bin/jg-tool-models.sh
. "$SCRIPT_DIR/jg-tool-models.sh"

# Print the harness named by a verified environment marker, or nothing when no
# marker is present. Markers only report what the environment CLAIMS; detect_own
# decides whether that claim survives contradicting ancestry.
harness_marker() {
  # Cursor is tested BEFORE claude, deliberately. cursor-agent does NOT clear an
  # inherited CLAUDECODE, so a cursor session started by hand from a claude
  # primary carries BOTH markers and whichever is tested first wins. This
  # ordering only settles the case where ancestry finds nothing to arbitrate
  # with; a nearer claude ancestor still outranks both in detect_own.
  # Verified live on cursor-agent 2026.08.11-e8db854: CURSOR_INVOKED_AS=cursor-agent
  # is set on the agent process itself, and CURSOR_AGENT=1 is set for the
  # child/tool processes this script runs as.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  # Gemini is checked BEFORE claude for exactly cursor's reason above: the
  # Gemini CLI does NOT clear an inherited CLAUDECODE, so a gemini worker
  # launched from a claude primary carries BOTH markers and whichever is
  # tested first wins. Verified live on gemini-cli 0.58.0: a tool process
  # spawned by a gemini worker under a claude primary reported GEMINI_CLI=1
  # AND CLAUDECODE=1 together. GEMINI_CLI is gemini's own and is unset in the
  # launching environment, so ordering it first is what makes the verdict
  # correct; bin/jg-spawn.sh additionally clears the foreign markers at the
  # launch boundary. Both are kept for the same reason cursor keeps both.
  # AI_AGENT is deliberately NOT used: it was present in that same process
  # carrying the claude primary's value (claude-code_2-1-260_agent), so it is
  # an inherited launcher marker, not a Gemini identity.
  [ "${GEMINI_CLI:-}" = "1" ] && { echo gemini; return; }
  # rovo (Atlassian Rovo CLI) sets ATLASSIAN_AGENT_TYPE=rovo, ROVODEV_CLI=1, and
  # AGENT=rovodev_cli on its tool subprocesses (verified, rovo 202609.1.2). It does
  # NOT scrub an inherited CLAUDECODE, so a rovo worker launched from a claude
  # session carries both markers - this must be tested BEFORE the CLAUDECODE line,
  # the same ordering hazard cursor documents above (see issue #3517). bin/jg-spawn.sh
  # additionally clears foreign markers at rovo's launch boundary as defense in depth.
  [ "${ATLASSIAN_AGENT_TYPE:-}" = "rovo" ] && { echo rovo; return; }
  [ "${ROVODEV_CLI:-}" = "1" ] && { echo rovo; return; }
  # omp (Oh My Pi) publishes NO harness-identity marker of its own: verified on
  # omp 18.1.11 that PI_CODING_AGENT is absent from the binary and that the
  # default profile sets neither PI_CODING_AGENT_DIR nor OMP_PROFILE in the
  # process environment. JG_OMP_HARNESS=omp is therefore a Juggernaut-OWNED
  # launch marker, established by bin/jg-spawn.sh at the omp launch boundary
  # (which also clears every foreign marker) and by the README's primary launch
  # command. It is a PRECEDENCE override, never evidence on its own: it wins
  # over an inherited CLAUDECODE only when an omp process is genuinely in the
  # ancestry, so `JG_OMP_HARNESS=omp omp` started from a Claude pane identifies
  # as omp, while the same variable leaking from an omp squad_lead into that
  # home's claude worker (whose ancestry holds no omp) changes nothing. The
  # anchored ancestry arm below covers a plain hand-started `omp` by itself.
  if [ "${JG_OMP_HARNESS:-}" = omp ] && ancestry_names_omp; then
    echo omp
    return
  fi
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${JG_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok set GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so the marker
  # is unambiguous WHEN PRESENT - but it is not guaranteed present. A grok 1.0.0
  # hook process carries GROK_HOOK_EVENT, GROK_HOOK_NAME, GROK_SESSION_ID, and
  # GROK_WORKSPACE_ROOT with no GROK_AGENT at all (verified from the live process
  # environment of a wedged grok 1.0.0 Stop hook, 2026-08-07). Treat this marker as
  # a fast path only; the ancestry walk below is what actually guarantees grok is
  # identified, and any rule that must be RELIABLE under grok has to test the hook
  # markers too (see .claude/settings.json Stop entries, docs/turnend-guard.md).
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # codex, opencode, kimi, muse, agy, and devin publish no harness-identity marker at all, so
  # they are never named here and are identified by ancestry alone. That is the
  # whole reason a foreign marker must not outrank ancestry: with markers winning
  # unconditionally, any retained CLAUDECODE would silently rename one of them.
  # muse's only documented child variable is MUSE_CURRENT_SESSION_LOG, a
  # per-session log PATH rather than an identity, and its export to tool
  # subprocesses is unverified (verified: muse 0.1.0-R708.1). Do NOT promote it
  # to a marker without verifying it reaches children AND that it cannot survive
  # in a multiplexer's stored environment.
  return 0
}

# True when an exact `omp` process sits within eight parents of this one. The
# same anchored match as the ancestry walk below, kept separate so the marker
# precedence above can demand real process evidence before trusting JG_OMP_HARNESS.
ancestry_names_omp() {
  local pid=$$ comm
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [ "$(basename -- "$comm")" = omp ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Print "<strength> <harness>" when one process identifies a harness, or nothing.
# Strength records how the match was made:
#   comm - the ancestor's own executable name identifies the harness. This is a
#          structural fact about the running program, so it outranks a marker.
#   args - a bare interpreter matched only because a harness name appears in the
#          script path it was handed. This is the weakest inference in this file
#          (any node process holding a harness-shaped path matches it), so it is
#          used only when no marker is present.
harness_process_verdict() {  # <pid>
  local pid=$1 comm args argv0
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  argv0=$(jg_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
  if jg_cursor_process_matches "$comm" '' "$argv0"; then
    echo "comm cursor"
    return
  fi
  if jg_gemini_path_is_gemini "$comm"; then
    echo "comm gemini"
    return
  fi
  case "$(basename -- "$comm")" in
    # gemini precedes claude here for the same precedence reason as the
    # marker layer above, so a gemini worker under a claude primary is never
    # read as claude. This arm covers a natively-named gemini binary only.
    # It does NOT reach the currently installed CLI, which is a node bundle
    # (~/.local/bin/gemini -> @google/gemini-cli/bundle/gemini.js): modern
    # Node on Linux reports `comm` as MainThread rather than node (measured
    # on Node v24.20.0), so neither this arm nor the node interpreter arm
    # below matches a live gemini process. GEMINI_CLI above is therefore
    # load-bearing for gemini rather than a fast path, which is why gemini
    # is not offered as a primary or squad_lead harness. Do NOT add
    # MainThread to the interpreter arm to close this: that would make the
    # args of EVERY node process searchable and let an unrelated node
    # command carrying a harness name in its arguments claim an identity.
    *claude*) echo "comm claude"; return ;;
    *codex*) echo "comm codex"; return ;;
    *opencode*) echo "comm opencode"; return ;;
    *grok*) echo "comm grok"; return ;;
    kimi) echo "comm kimi"; return ;;
    rovo) echo "comm rovo"; return ;;
      # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
      # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
      # name carries the version and CHANGES on every auto-update. Match the stable
      # prefix rather than any exact name. Deliberately anchored, never *muse*, so
      # unrelated commands (musescore, amuse) cannot be misread as this harness.
    muse|muse-bin-*) echo "comm muse"; return ;;
    # Both Pi identities share this launcher name. Ancestry can only prove the
    # FAMILY; only the launch-boundary marker selects the signed identity, which
    # is why detect_own keeps a marker that agrees on the family.
    pi-signed) echo "comm pi"; return ;;
    pi) echo "comm pi"; return ;;
    # omp is a Bun-compiled single binary whose process name is exactly `omp`
    # (verified, omp 18.1.11: `ps -o comm=` reports omp from both its `!`
    # bash path and the model's bash tool). Anchored, never *omp*, so ompd,
    # comp, and similar unrelated commands are not misread as this harness.
    # It sits above the node*|python* interpreter fallback deliberately: the
    # optional claude-bridge extension runs a nested executable literally
    # named `claude` with its own node child, and that fallback's *claude*
    # args glob would otherwise claim it if that subtree were ever walked.
    omp) echo "comm omp"; return ;;
    # agy (Antigravity CLI) is a Go-compiled single binary whose process name
    # is exactly `agy` (verified, agy 1.2.0: `ps -o comm=` reports agy and
    # Herdr's process-info reports name agy with argv[0] agy). Anchored, never
    # *agy*, so unrelated commands cannot be misread as this harness. agy
    # publishes no harness-identity marker of its own (a live 1.2.0 TUI
    # carries no AGY_* or ANTIGRAVITY_* variable; AGENT=1 seen there is an
    # inherited launcher value, not an agy identity), so like muse it is
    # detected by ancestry alone.
    agy) echo "comm agy"; return ;;
    devin) echo "comm devin"; return ;;
    node*|python*)
      # Bare interpreter: match the harness name in its script path.
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      if jg_gemini_args_are_gemini "$args"; then
        echo "args gemini"
        return
      fi
      case "$args" in
        *claude*) echo "args claude"; return ;;
        *codex*) echo "args codex"; return ;;
        *opencode*) echo "args opencode"; return ;;
        *grok*) echo "args grok"; return ;;
        *" pi "*|*/pi) echo "args pi"; return ;;
      esac ;;
  esac
}

# Print the verdict for the NEAREST harness process in the parent chain, or
# nothing when the walk finds none. The nearest match wins, so a worker nested
# inside another harness resolves to its own harness.
harness_ancestry() {  # [<pid>]
  local pid=${1:-$$} verdict
  for _ in 1 2 3 4 5 6 7 8; do
    verdict=$(harness_process_verdict "$pid")
    [ -z "$verdict" ] || { echo "$verdict"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Stop only once the walk has EXAMINED the top of the chain. Inside a PID
    # namespace the harness itself is pid 1 - a container, or the `codex sandbox`
    # this boundary was proven in - so breaking as soon as the next pid is 1
    # skips the one process that identifies the session and hands the verdict
    # straight back to a retained marker. A host's real pid 1 (init, systemd,
    # launchd) matches no harness name above, so examining it costs one ps call
    # and can introduce no false positive.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 0
}

# Print the pids on the UPWARD path between the deepest descendant of <root> and
# <root> itself, deepest first. Optional <eligible-leaf-pid> values restrict which
# descendants may be chosen as that deepest one; with none given every descendant
# is eligible. Bounded to the same eight levels harness_ancestry climbs, so a deep
# or pathological tree cannot make this walk unbounded.
process_descent_path() {  # <root> [<eligible-leaf-pid>...]
  local root=${1:-$$} eligible any hit pairs frontier next pid child parent verdict
  local parents='' depth=0 best best_depth=0 best_strength='' hops=0
  case "$root" in '' | *[!0-9]*) return 0 ;; esac
  shift 2>/dev/null || true
  eligible=" ${*+$*} "
  any=0
  [ "$#" -eq 0 ] && any=1
  pairs=$(ps -eo pid=,ppid= 2>/dev/null) || { printf '%s\n' "$root"; return 0; }
  best=$root
  frontier=$root
  while [ -n "$frontier" ] && [ "$depth" -lt 8 ]; do
    next=
    for pid in $frontier; do
      while read -r child parent; do
        [ "$parent" = "$pid" ] || continue
        [ "$child" != "$pid" ] || continue
        parents="$parents $child:$pid"
        next="$next $child"
        if [ "$any" = 1 ]; then
          hit=1
        else
          case "$eligible" in
            *" $child "*) hit=1 ;;
            *) hit=0 ;;
          esac
        fi
        if [ "$hit" = 1 ]; then
          verdict=$(harness_process_verdict "$child")
          if [ $((depth + 1)) -gt "$best_depth" ]; then
            best=$child
            best_depth=$((depth + 1))
            best_strength=${verdict%% *}
          # At equal depth, prefer the leaf whose own executable reaches comm
          # strength. Otherwise an earlier MCP interpreter carrying a foreign
          # harness path can hide a native harness sibling purely through ps
          # ordering. This repairs the chosen path's comm-strength guarantee;
          # args-strength foreign verdicts remain excluded from cross-checking.
          elif [ $((depth + 1)) -eq "$best_depth" ] \
            && [ "$best_strength" != comm ] && [ "${verdict%% *}" = comm ]; then
            best=$child
            best_strength='comm'
          fi
        fi
      done <<EOF
$pairs
EOF
    done
    frontier=$next
    depth=$((depth + 1))
  done

  pid=$best
  while [ -n "$pid" ] && [ "$hops" -le 8 ]; do
    printf '%s\n' "$pid"
    [ "$pid" != "$root" ] || break
    parent=
    case "$parents" in
      *" $pid:"*)
        parent=${parents##*" $pid:"}
        parent=${parent%% *} ;;
    esac
    pid=$parent
    hops=$((hops + 1))
  done
}

# Print each DISTINCT "<strength> <harness>" verdict harness_ancestry reaches from
# the vantages on the upward path between the deepest descendant of <root> and
# <root>, one per line, deepest first.
#
# Why a descent path and not <root> alone: detect_own always runs from a TOOL
# SUBPROCESS inside a session, never from the process at the top of it, and that
# difference decides whether a retained foreign marker can rename the session. A
# harness that ships as an interpreter shim spawning its native binary as a CHILD
# is only args strength when asked from the shim, and detect_own hands an
# args-strength verdict straight back to the marker; the native child is comm
# strength and outranks it. Asking from below is what puts the question at the
# vantage point a real session uses, so a guard built on this can assert the
# strength the shipped guarantee actually depends on
# (tests/jg-harness-liveness-drift-live-e2e.test.sh).
#
# Why the upward path and not the whole subtree: harness_ancestry only ever climbs,
# so a SIBLING branch is a vantage juggernaut's own detection can never occupy. A
# harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js` matches
# *claude* on its script path in the bare-interpreter branch above and would report a
# foreign harness from a process no real tool subprocess ever asks from.
harness_ancestry_descent() {  # <root> [<eligible-leaf-pid>...]
  local pid verdict seen=
  for pid in $(process_descent_path "$@"); do
    verdict=$(harness_ancestry "$pid")
    [ -n "$verdict" ] || continue
    case "$seen" in *"|$verdict|"*) continue ;; esac
    seen="$seen|$verdict|"
    printf '%s\n' "$verdict"
  done
}

# Collapse a verdict to the harness FAMILY its evidence can actually prove, so a
# marker's more specific verdict and ancestry's coarser one are not read as a
# disagreement. Only Pi has two identities behind one launcher name.
harness_family() {
  case "$1" in
    pi-signed) printf 'pi\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Print the supervision-branch primary pin when it applies (header), or
# nothing. Returns 2, with the reason on stderr, for a pin naming no harness.
supervision_primary_pin() {
  local pin=${JG_SUPERVISION_PRIMARY_HARNESS:-}
  [ "${JG_SUPERVISION_ACTOR:-}" = branch ] && [ -n "$pin" ] || return 0
  case "$pin" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|devin)
      printf '%s\n' "$pin"
      ;;
    *)
      echo "error: JG_SUPERVISION_PRIMARY_HARNESS='$pin' names no known harness; refusing to resolve the supervision branch's harness" >&2
      return 2
      ;;
  esac
}

# Combine the two evidence layers. The precedence boundary, in one rule: a
# marker names its harness, but only ancestry proves which harness owns this
# process tree, so a structural (comm) ancestor of a DIFFERENT harness wins.
#   - No ancestry match: the marker is the only evidence there is.
#   - No marker: ancestry is the only evidence there is.
#   - Same family: keep the marker's verdict, which is the more specific one
#     (pi-signed, which ancestry can only see as pi).
#   - Different harness, structural ancestor: ancestry wins. This is what stops
#     an inherited or multiplexer-retained CLAUDECODE from renaming a markerless
#     codex, opencode, kimi, or muse session, and symmetrically stops a retained
#     CURSOR_AGENT from renaming a claude worker nested under cursor.
#   - Different harness, interpreter-args ancestor only: the marker wins, because
#     a harness-shaped path in some node process's arguments is weaker evidence
#     than a harness publishing its own identity.
# The supervision-branch primary pin, when it applies, answers before either
# evidence layer is read.
detect_own() {
  local marker ancestry strength harness pin
  pin=$(supervision_primary_pin) || exit 2
  [ -z "$pin" ] || { echo "$pin"; return; }
  marker=$(harness_marker)
  ancestry=$(harness_ancestry)
  if [ -z "$ancestry" ]; then
    if [ -n "$marker" ]; then echo "$marker"; else echo unknown; fi
    return
  fi
  strength=${ancestry%% *}
  harness=${ancestry#* }
  [ -n "$marker" ] || { echo "$harness"; return; }
  if [ "$(harness_family "$marker")" = "$(harness_family "$harness")" ]; then
    echo "$marker"
    return
  fi
  if [ "$strength" = comm ]; then echo "$harness"; else echo "$marker"; fi
}

# Resolve the effective operator harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors juggernaut's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Select and validate the per-mate pin, otherwise read the global default's
# first non-empty, non-comment line. An absent/blank global default is empty;
# an unreadable or malformed per-mate pin refuses, naming its file.
squad_lead_line() {
  local line file pinned=0
  file=$(jg_compat_pick "$CONFIG/squad-lead-harness")
  if [ -n "$SQUAD_LEAD_ID" ]; then
    case "$SQUAD_LEAD_ID" in
      ''|.*|*[!a-zA-Z0-9._-]*) echo "error: invalid squad_lead id '$SQUAD_LEAD_ID'" >&2; return 1 ;;
    esac
    file="$(jg_compat_pick "$CONFIG/squad_leads")/$SQUAD_LEAD_ID/harness"
    if [ -e "$file" ] || [ -L "$file" ]; then
      pinned=1
      [ -f "$file" ] && [ -r "$file" ] || { echo "error: unreadable squad_lead pin $file" >&2; return 1; }
    else
      file=$(jg_compat_pick "$CONFIG/squad-lead-harness")
    fi
  fi
  if [ "$pinned" = 0 ]; then
    # config/tool-models.json "squad-lead" outranks the global default and yields to a per-lead pin.
    line=$(jg_tool_models_resolve squad-lead)
    [ -z "$line" ] || { printf '%s\n' "$line"; return 0; }
  fi
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    if [ "$pinned" = 1 ]; then
      local -a fields
      read -r -a fields <<< "$line"
      if [ "${#fields[@]}" != 3 ]; then
        echo "error: malformed squad_lead pin $file: expected <harness> <model> <effort>" >&2
        return 1
      fi
      case "${fields[0]}" in
        claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|omp) ;;
        *) echo "error: malformed squad_lead pin $file: unverified squad_lead harness '${fields[0]}'" >&2; return 1 ;;
      esac
      case "${fields[1]}" in
        default|-) echo "error: malformed squad_lead pin $file: a concrete model is required" >&2; return 1 ;;
      esac
      case "${fields[2]}" in
        low|medium|high|xhigh|max|ultra) ;;
        *) echo "error: malformed squad_lead pin $file: invalid effort '${fields[2]}'" >&2; return 1 ;;
      esac
      validate_native_effort "${fields[@]}" || { echo "error: malformed squad_lead pin $file" >&2; return 1; }
    fi
    printf '%s\n' "$line"
    return 0
  done < "$file"
  [ "$pinned" = 0 ] || { echo "error: malformed squad_lead pin $file: empty pin" >&2; return 1; }
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved squad_lead_line, or nothing if the line or that field is absent.
squad_lead_field() {
  local idx=$1 line
  local -a fields
  line=$(squad_lead_line) || return 1
  [ -n "$line" ] || return 0
  read -r -a fields <<< "$line"
  printf '%s\n' "${fields[$((idx - 1))]:-}"
}

# Resolve the harness the PRIMARY uses to launch SQUAD_LEAD agents: a fallback
# chain config/squad-lead-harness -> config/crew-harness -> own. An absent or
# "default" squad-lead-harness token defers to the crew resolution, so an unset
# squad-lead-harness behaves exactly as before this knob existed (a squad_lead
# launched on the crew harness). config/squad-lead-harness is the PRIMARY's own
# setting and is never inherited downstream - squad_leads do not spawn squad_leads.
resolve_squad_lead() {
  local sm
  sm=$(squad_lead_field 1) || return 1
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then sm=$(resolve_crew) || exit; fi
  echo "$sm"
}

# Print the optional model token (2nd field) from config/squad-lead-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_squad_lead_model() {
  local sm
  sm=$(squad_lead_field 1) || return 1
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  squad_lead_field 2
}

# Print the optional effort token (3rd field) from config/squad-lead-harness,
# the same way.
resolve_squad_lead_effort() {
  local sm
  sm=$(squad_lead_field 1) || return 1
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  squad_lead_field 3
}

validate_native_effort() {
  local harness=${1:-} model=${2:-} effort=${3:-}
  [ "$effort" = ultra ] || return 0
  case "$harness" in
    pi|pi-signed)
      case "$model" in codex-native/?*) return 0 ;; esac
      ;;
  esac
  echo "error: ultra effort requires pi or pi-signed with an explicit codex-native/<model> model" >&2
  return 1
}

case "${1:-}" in
  validate-native-effort) shift; validate_native_effort "$@" ;;
  ancestry)
    case "${2:-}" in
      ''|*[!0-9]*) [ -z "${2:-}" ] || { echo "error: ancestry takes a numeric pid" >&2; exit 2; } ;;
    esac
    harness_ancestry "${2:-$$}"
    ;;
  ancestry-descent)
    shift
    for arg in ${1+"$@"}; do
      case "$arg" in
        ''|*[!0-9]*) echo "error: ancestry-descent takes numeric pids" >&2; exit 2 ;;
      esac
    done
    descent_pid="${1:-$$}"
    [ "$#" -eq 0 ] || shift
    harness_ancestry_descent "$descent_pid" ${1+"$@"}
    ;;
  crew) resolve_crew ;;
  squad_lead) SQUAD_LEAD_ID=${2:-}; resolve_squad_lead ;;
  squad-lead-model) SQUAD_LEAD_ID=${2:-}; resolve_squad_lead_model ;;
  squad-lead-effort) SQUAD_LEAD_ID=${2:-}; resolve_squad_lead_effort ;;
  *) detect_own ;;
esac
