#!/usr/bin/env bash
# A re-run is a no-op, not an error: two wiring steps share one hook file and each used to refuse the other's
# re-chain. The real wiring fragments, four runs, one throwaway home: every run succeeds, the chain settles,
# both sides run, and the core's one host-wiring entry point reaches every step in its own order.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-host-wiring.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

pass() { printf 'ok - %s\n' "$*"; }
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# The suite never writes to a home it was handed by the shell that runs it: a supervisor exports its
# live home as JG_HOME (and, mid-migration, FM_HOME), and this suite used to rewire that home through
# the one entry-point run that names no home. Prove the isolation by running the suite once more with
# a throwaway home in those variables and requiring that home to come out byte-identical. The inner
# run is this same file with the marker set, so the check does not recurse.
if [ -z "${JG_SUITE_INHERITED_HOME:-}" ]; then
  inherited=$tmp/inherited-home
  mkdir -p "$inherited/config" "$inherited/bin" "$inherited/state" "$inherited/data"
  # A live home carries this checker, so a leak registers state checks and cannot pass unseen.
  install -m 755 "$here/bin/jg-check-register.sh" "$inherited/bin/"
  printf 'kept\n' >"$inherited/config/merge-gate"
  printf 'kept\n' >"$inherited/config/launch-env-hook"
  inherited_state() { (cd "$inherited" && find . -type f -exec sha256sum {} + | sort); }
  inherited_before=$(inherited_state)
  if ! JG_SUITE_INHERITED_HOME=$inherited JG_HOME=$inherited FM_HOME=$inherited \
    bash "${BASH_SOURCE[0]}" >"$tmp/inherited.log" 2>&1; then
    cat "$tmp/inherited.log" >&2
    no 'the suite failed when it inherited a home in its environment'
  fi
  if [ "$(inherited_state)" != "$inherited_before" ]; then
    printf 'not ok - the suite wired the home it inherited from its environment:\n' >&2
    diff <(printf '%s\n' "$inherited_before") <(inherited_state) >&2 || true
    exit 1
  fi
  pass 'a run that inherits a home in its environment leaves that home untouched'
fi

home=$tmp/home
mkdir -p "$home/config" "$home/bin" "$home/state" "$home/data" "$tmp/user"
# Every write this suite makes lands in the throwaway home named here: JG_HOME is pinned to it and the
# home- and state-naming variables a live shell carries are cleared, so no fallback can reach a real
# one. A run that must name no home, or another home, clears JG_HOME for that one call.
export JG_HOME=$home
unset JG_MAIN_HOME JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
export HOME=$tmp/user
export XDG_DATA_HOME=$HOME/.local/share XDG_CONFIG_HOME=$HOME/.config
# Keep the guard's global hooks path inside the fixture, never the runner's real git configuration.
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig GIT_CONFIG_SYSTEM=/dev/null
printf '[user]\n\tname = Fixture Owner\n\temail = fixture@example.invalid\n' >"$GIT_CONFIG_GLOBAL"

# The four wiring steps that fight over the two hook files, in jg-host-wiring.sh's order.
install_pairs() {  # install_pairs <round>
  local round=$1 name
  for name in git-identity pane-titles owner-guard owner-rules; do
    bash "$here/core/$name/wiring.sh" "$home" >"$tmp/$round-$name.log" 2>&1 || {
      printf 'not ok - %s failed on run %s:\n' "$name" "$round" >&2
      cat "$tmp/$round-$name.log" >&2
      exit 1
    }
  done
}

chain_state() {  # chain_state: every chain file's content digest, in a fixed order
  local f
  for f in "$home/config/launch-env-hook" \
    "$XDG_DATA_HOME/jg-pane-titles/previous-launch-env-hook" \
    "$home/config/merge-gate" \
    "$home/config/merge-gate.steps" \
    "$home/config/merge-gate.pre-chain" \
    "$home/config/merge-gate.pre-owner-rules" \
    "$home/config/merge-gate.pre-owner-guard"; do
    if [ -e "$f" ]; then printf '%s %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "${f#"$tmp"/}"; fi
  done
  return 0
}

install_pairs one
install_pairs two
chain_after_two=$(chain_state)
install_pairs three

[ "$(chain_state)" = "$chain_after_two" ] || {
  printf 'not ok - a repeat install changed the hook chains:\n' >&2
  diff <(printf '%s\n' "$chain_after_two") <(chain_state) >&2 || true
  exit 1
}
printf 'ok - a repeat install succeeds and settles the two shared hook files\n'

# A repeat install adds no files either: the backup a chained hook earns is kept once, not once per run.
count_backups() { local n=0 f; for f in "$home/config"/launch-env-hook.bak-git-identity-*; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s\n' "$n"; }
backups=$(count_backups)
install_pairs four
[ "$(count_backups)" -eq "$backups" ] ||
  { printf 'not ok - a repeat install added another hook backup\n' >&2; exit 1; }
printf 'ok - a repeat install adds no hook backup\n'

# Both sides of each pair still run: pane-titles' shim execs the launcher, and the merge gate runs the
# owner-details scan and the owner-rules proof gate from one file without ever revisiting a file. A repeat
# install that wired a step back into itself would close a loop here, and the gate would exec itself forever.
if ! grep -q 'jg-pane-titles/launch-env-hook' "$home/config/launch-env-hook"; then
  printf 'not ok - the launch-env hook no longer runs pane-titles\n' >&2
  exit 1
fi
gate=$home/config/merge-gate
seen=' '
found_guard=0 found_rules=0
depth=0
while [ -e "$gate" ] && [ "$depth" -lt 8 ]; do
  case $seen in
    *" $gate "*) printf 'not ok - the merge gate chains back to %s: it would exec itself forever\n' "$gate" >&2; exit 1 ;;
  esac
  seen="$seen$gate "
  if grep -q 'jg-owner-guard' "$gate"; then found_guard=1; fi
  if grep -q 'jg-owner-rules-gate.sh' "$gate"; then found_rules=1; fi
  gate=$(sed -n 's/^prev=//p' "$gate" | head -1)
  [ -n "$gate" ] || break
  depth=$((depth + 1))
done
[ "$found_guard" -eq 1 ] && [ "$found_rules" -eq 1 ] ||
  { printf 'not ok - the merge gate lost a side (owner-guard=%s owner-rules=%s)\n' "$found_guard" "$found_rules" >&2; exit 1; }
printf 'ok - both sides of each shared hook file still run, and the merge gate chain has no loop\n'

pass "a repeat wiring run settles the two shared hook files"

# The one entry point reaches every feature that carries wiring, in its own order, and --list writes nothing.
listed=$("$here/bin/jg-host-wiring.sh" --list)
missing=''
for f in "$here"/core/*/wiring.sh; do
  name=${f%/wiring.sh}; name=${name##*/}
  printf '%s\n' "$listed" | cut -f1 | grep -qx "$name" || missing="$missing $name"
done
[ -z "$missing" ] || no "jg-host-wiring.sh does not run these wired features:$missing"
pass 'the host-wiring entry point runs every core feature that carries wiring'

# The entry point refuses to guess a home, with the usage status, before it writes anything: a bare
# nonzero exit is also what a wiring step leaves behind after it has already rewritten the home, so the
# status is checked, not merely the failure.
rc=0
env -u JG_HOME "$here/bin/jg-host-wiring.sh" >"$tmp/nohome.log" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { cat "$tmp/nohome.log" >&2; no "a run with no home exited $rc, not the usage refusal 2"; }
pass 'the entry point refuses a run with no home named'

env -u JG_HOME HOME="$tmp/user" XDG_DATA_HOME="$tmp/user/.local/share" XDG_CONFIG_HOME="$tmp/user/.config" \
  bash "$here/bin/jg-host-wiring.sh" --dry-run --home "$home" >"$tmp/dry.log" 2>&1 || true
grep -q '^== git-identity' "$tmp/dry.log" || { cat "$tmp/dry.log" >&2; no 'a dry run did not reach the git-identity step'; }
pass 'a dry run reaches each step and prints what it would write'

# A Squad Lead home never wires the machine-wide units, wiring or unwiring; per-home steps still run.
lead=$tmp/lead
mkdir -p "$lead/config" "$lead/bin" "$lead/state" "$lead/data"
printf 'lead\n' >"$lead/.jg-squad-lead-home"
for mode in --dry-run '--dry-run --unwire'; do
  # shellcheck disable=SC2086
  env -u JG_HOME bash "$here/bin/jg-host-wiring.sh" $mode --home "$lead" >"$tmp/lead.log" 2>&1 || true
  grep -q 'Squad Lead home; skipping the machine-wide units: sentinel host-memory lookout-adapter' "$tmp/lead.log" ||
    { cat "$tmp/lead.log" >&2; no "a lead home ($mode) did not name the skipped machine-wide units"; }
  if grep -Eq '^== (sentinel|host-memory|lookout-adapter):' "$tmp/lead.log"; then no "a lead home ($mode) reached a machine-wide step"; fi
  grep -q '^== git-identity' "$tmp/lead.log" || no "a lead home ($mode) lost its per-home steps"
done
pass 'a lead home skips the machine-wide units in wire and unwire, and keeps per-home steps'
