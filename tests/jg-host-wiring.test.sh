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
[ ! -e "$home/config/machine-view" ] || no 'dry run enabled the machine view'
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

# A real wiring run enables the read-only machine view for each kind of home.
for target in "$home" "$lead"; do
  env -u JG_HOME bash "$here/bin/jg-host-wiring.sh" --home "$target" >"$tmp/view.log" 2>&1 || true
  [ -f "$target/config/machine-view" ] || no 'host wiring did not enable the machine view'
  env -u JG_HOME bash "$here/bin/jg-host-wiring.sh" --home "$target" >"$tmp/view-repeat.log" 2>&1 || true
  [ -f "$target/config/machine-view" ] || no 'repeat wiring lost the machine view'
done
pass 'host wiring enables the machine view in main and lead homes'

# installed-drift and tool-update-check: the detectors are armed by wiring, and the owner's tool list is never invented.
det=$tmp/detectors
mkdir -p "$det/config" "$det/bin" "$det/state" "$det/data"
install -m 755 "$here/bin/jg-check-register.sh" "$det/bin/"
bash "$here/core/installed-drift/wiring.sh" "$det" >"$tmp/det-drift.log" 2>&1 || { cat "$tmp/det-drift.log" >&2; no 'installed-drift wiring failed'; }
[ -x "$det/state/installed-drift.check.sh" ] || no 'installed-drift wiring left no check shim'
bash "$here/core/tool-update-check/wiring.sh" "$det" >"$tmp/det-tool.log" 2>&1 || { cat "$tmp/det-tool.log" >&2; no 'tool-update-check wiring failed with no registry'; }
grep -qx 'not armed: no watched-tools registry' "$tmp/det-tool.log" || no 'tool-update-check without a registry did not say so'
[ ! -e "$det/state/tool-update-check.check.sh" ] && [ ! -e "$det/config/watched-tools.json" ] || no 'tool-update-check wiring armed or created a registry on its own'
bash "$here/core/installed-drift/unwiring.sh" "$det" >/dev/null 2>&1 || no 'installed-drift unwiring failed'
[ ! -e "$det/state/installed-drift.check.sh" ] || no 'installed-drift unwiring left the shim'
pass 'detector wiring arms installed-drift, leaves tool-update-check unarmed without a registry, and unwires'

# An installed copy that differs from its source, or is gone, is drift whatever git says: a step recorded as wired
# at this commit reruns under --changed, and only that step. The home is a committed copy of this checkout's bin/ and
# core/ (so the record, the commit and the sources are real, and a dirty working tree cannot hide a step), the host is
# a throw-away HOME, and the commands that reach the real service manager are stubs that fail.
# The launcher injects core.hooksPath and identity includes through GIT_CONFIG_COUNT; a fixture repo must run none of them.
unset GIT_CONFIG_COUNT
for v in $(compgen -v | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
fx=$tmp/fx
fxuser=$tmp/fxuser
fxstubs=$tmp/fxstubs
mkdir -p "$fx/config" "$fx/state" "$fx/data" "$fxuser" "$fxstubs"
cp -r "$here/bin" "$here/core" "$fx/"
for c in systemd-run systemctl tailscale curl; do printf '#!/bin/sh\nexit 1\n' >"$fxstubs/$c"; chmod +x "$fxstubs/$c"; done
git -C "$fx" init -q
git -C "$fx" add -A
git -C "$fx" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m fixture
fxdata=$fxuser/.local/share
fxwire() {  # fxwire <args>: the fixture home's own entry point, on the throw-away host
  env -u JG_HOME -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_CONFIG_OVERRIDE -u JG_ROOT_OVERRIDE \
    HOME="$fxuser" XDG_DATA_HOME="$fxdata" XDG_CONFIG_HOME="$fxuser/.config" PATH="$fxstubs:$PATH" \
    bash "$fx/bin/jg-host-wiring.sh" "$@" --home "$fx"
}
steps_run() { sed -n 's/^== \([a-z0-9-]*\):.*/\1/p' "$1" | sort | tr '\n' ' '; }  # the steps a run's log shows it ran

# The steps a run named as failed ("..., failed: a b" on its last line; the owner-guard scan counts as owner-guard): a failed step
# has no record, so the next --changed run reruns it, and a step that failed before may wire on the rerun.
failed_of() { sed -n 's/.*, failed: *//p' "$1" | tail -n 1 | tr ' ' '\n' | sed 's/-scan$//' | sort -u | tr '\n' ' '; }
steps_with() {  # steps_with <log> <step>...: the steps that failed in that log, plus the named ones
  { printf '%s\n' "$(failed_of "$1")" | tr ' ' '\n'; printf '%s\n' "${@:2}"; } | sed '/^$/d' | sort -u | tr '\n' ' '
}

rc=0
fxwire >"$tmp/fx-first.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { tail -n 20 "$tmp/fx-first.log" >&2; no "the first full wiring run of the fixture home exited $rc, not 1 (the steps that need a service manager fail)"; }
failed=$(failed_of "$tmp/fx-first.log")
[ -n "$failed" ] || no 'the first full run named no failed step'
[ -f "$fx/state/host-wiring.tsv" ] || no 'the first full run recorded no wired step'

# Every drifted copy of a step that wired is a defect; a step that failed may hold copies it never installed.
drift_outside_failed() {  # drift_outside_failed <failed steps>
  local step copy state source bad=''
  while IFS=$'\t' read -r step copy state source; do
    case " $1" in *" $step "*) continue ;; esac
    bad="$bad $step:$state:${copy#"$fxuser"/}"
  done < <(fxwire --drift)
  printf '%s\n' "$bad"
}
bad=$(drift_outside_failed "$failed")
[ -z "$bad" ] || no "a step that wired left a copy that differs from its source:$bad"
pass 'after a full wiring run every copy of every step that wired equals its source'

# The table names every plain copy: delete each installed file that equals a repo file, and --drift must report each one.
# repo-guard's allowed-repos is the seeded list the owner edits, so it is installed once and never compared.
: >"$tmp/fx-expected"
while IFS= read -r -d '' f; do
  b=${f##*/}
  [ "$b" != allowed-repos ] || continue
  while IFS= read -r s; do
    if cmp -s "$fx/$s" "$f"; then printf '%s\n' "$f" >>"$tmp/fx-expected"; rm -f -- "$f"; break; fi
  done < <(git -C "$fx" ls-files | grep -E "(^|/)$b\$")
done < <(find "$fxdata" -type f -not -path '*/state/*' -print0)
[ -s "$tmp/fx-expected" ] || no 'the fixture host holds no installed copy'
fxwire --drift >"$tmp/fx-drift.tsv"
cut -f2 "$tmp/fx-drift.tsv" | sort >"$tmp/fx-reported"
unnamed=$(sort "$tmp/fx-expected" | comm -23 - "$tmp/fx-reported")
[ -z "$unnamed" ] || no "step_copies in jg-host-wiring.sh does not name these installed copies: $unnamed"
awk -F'\t' 'NF != 4 || $3 != "missing" { bad = 1 } END { exit bad }' "$tmp/fx-drift.tsv" || no '--drift lines are not "<step> <copy> missing <source>"'
pass '--drift names every installed copy that equals a repo file, and says missing for a deleted one'

# --changed restores them all; the run after it reruns only the steps that failed (they have no record to be current by).
fxwire --changed >"$tmp/fx-restore.log" 2>&1 || true
failed=$(failed_of "$tmp/fx-restore.log")
bad=$(drift_outside_failed "$failed")
[ -z "$bad" ] || no "--changed left a copy missing or different:$bad"
while IFS= read -r f; do
  [ -f "$f" ] || case " $failed" in *" pipeline-quota-failover "*) [ "${f##*/}" = pi-quota-failover ] || no "--changed did not restore $f" ;; *) no "--changed did not restore $f" ;; esac
done <"$tmp/fx-expected"
fxwire --changed >"$tmp/fx-second.log" 2>&1 || true
[ "$(steps_run "$tmp/fx-second.log")" = "$(steps_with "$tmp/fx-restore.log")" ] ||
  { printf 'ran: [%s] failed before: [%s]\n' "$(steps_run "$tmp/fx-second.log")" "$(steps_with "$tmp/fx-restore.log")" >&2; no 'a second --changed run reran a step that was current'; }
pass '--changed restores every deleted copy, and the run after it reruns only the steps that failed'

# One step, both ways a copy drifts: deleted, then edited. The step reruns, its copy equals its source, and no step that wired reruns.
copy=$fxdata/jg-fleet-flow/jg-flow-check.sh
source=$fx/core/fleet-flow/bin/jg-flow-check.sh
prev=$tmp/fx-second.log
for how in deleted edited; do
  if [ "$how" = deleted ]; then rm -f -- "$copy"; want=missing; else printf '# edited on the host\n' >>"$copy"; want=differs; fi
  got=$(fxwire --drift | awk -F'\t' '$1 == "fleet-flow"')
  [ "$got" = "$(printf 'fleet-flow\t%s\t%s\t%s' "$copy" "$want" "$source")" ] || no "a $how copy was not reported as $want: $got"
  fxwire --changed >"$tmp/fx-$how.log" 2>&1 || true
  [ "$(steps_run "$tmp/fx-$how.log")" = "$(steps_with "$prev" fleet-flow)" ] ||
    { printf 'ran: [%s] want: [%s]\n' "$(steps_run "$tmp/fx-$how.log")" "$(steps_with "$prev" fleet-flow)" >&2; no "a $how copy did not rerun exactly its own step"; }
  cmp -s "$source" "$copy" || no "the rerun left a $how copy different from its source"
  [ -z "$(fxwire --drift | awk -F'\t' '$1 == "fleet-flow"')" ] || no "--drift still reports a $how copy after the rerun"
  fxwire --changed >"$tmp/fx-$how-again.log" 2>&1 || true
  [ "$(steps_run "$tmp/fx-$how-again.log")" = "$(steps_with "$tmp/fx-$how.log")" ] || no "a run after the $how copy was restored reran a current step"
  prev=$tmp/fx-$how-again.log
done
pass 'a deleted or an edited copy reruns exactly its step, restores it, and the next run reruns nothing that wired'
