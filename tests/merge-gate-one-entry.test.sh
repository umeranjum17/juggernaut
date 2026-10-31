#!/usr/bin/env bash
# One merge gate: the installer writes ONE config/merge-gate that runs the owner-details scan,
# then the owner-rules proof gate, then the home's own previous gate, and both installers keep
# their step in it without a chain of files. Fixture only: a throwaway HOME, XDG paths and home,
# a local bare repo standing in for GitHub, and a stub gh. No network, no real home.
#
# Refuses and allows the same cases as the old chain: a PR with no evidence card, an
# owner-details hit, a missing owner-guard executable, a previous-gate refusal, and a clean pass.
# Also proves the two one-release symlinks resolve to the single file, that an older three-file
# chain folds into it without losing either check, and that uninstalling one feature keeps the
# other running.
# Usage: bash tests/merge-gate-one-entry.test.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
w=$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-one-entry.XXXXXX") || exit 1
trap 'chmod -R u+w -- "$w" 2>/dev/null; rm -rf -- "$w"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
has() { case $2 in *"$3"*) ok "$1" ;; *) no "$1: want text [$3], got [$2]" ;; esac; }
lacks() { case $2 in *"$3"*) no "$1: unexpected text [$3] in [$2]" ;; *) ok "$1" ;; esac; }

export HOME=$w/user XDG_DATA_HOME=$w/user/.local/share XDG_CONFIG_HOME=$w/user/.config
export TMPDIR=$w GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$w/user/.gitconfig
mkdir -p "$HOME" "$w/bin" "$w/forge/acme" "$XDG_DATA_HOME/jg-merge-on-green"
: >"$GIT_CONFIG_GLOBAL"
printf '#!/bin/sh\nexit 0\n' >"$XDG_DATA_HOME/jg-merge-on-green/checks-lint.sh"
chmod +x "$XDG_DATA_HOME/jg-merge-on-green/checks-lint.sh"

# A forge: GitHub URLs resolve to a local bare repo that serves fetch-by-sha like GitHub, and a stub
# gh that answers the base-branch query the owner-details scan makes.
git config --global url."$w/forge/".insteadOf https://github.com/
git init -q --bare -b main "$w/forge/acme/widget.git"
git -C "$w/forge/acme/widget.git" config uploadpack.allowAnySHA1InWant true
printf '#!/bin/sh\ncase "$*" in *baseRefName*) echo main ;; *) cat %q 2>/dev/null ;; esac\n' "$w/body" >"$w/bin/gh"
chmod +x "$w/bin/gh"
export PATH=$w/bin:$PATH

git init -q -b main "$w/work"
git -C "$w/work" remote add origin https://github.com/acme/widget.git
commit() { git -C "$w/work" -c core.hooksPath=/dev/null -c user.name=You -c user.email=you@example.invalid commit -q "$@"; }
printf 'one\n' >"$w/work/notes.txt"
git -C "$w/work" add notes.txt && commit -m base && git -C "$w/work" push -q --no-verify origin main
git -C "$w/work" checkout -q -b clean
printf 'two\n' >>"$w/work/notes.txt" && commit -am clean && git -C "$w/work" push -q --no-verify origin clean
clean_head=$(git -C "$w/work" rev-parse HEAD)
git -C "$w/work" checkout -q -b leak main
printf 'two\nreach fixture-secret-surname here\n' >>"$w/work/notes.txt" && commit -am leak
git -C "$w/work" push -q --no-verify origin leak
leak_head=$(git -C "$w/work" rev-parse HEAD)
git -C "$w/work" checkout -q clean
pr=https://github.com/acme/widget/pull/7

home=$w/home
mkdir -p "$home/config" "$home/data/lane/.done-done/runs"
printf '%s\n' '# fixture-only patterns' 'fixture-secret-surname' >"$home/config/owner-details-patterns"
chmod 600 "$home/config/owner-details-patterns"
# The home's own previous gate, written before either feature installs.
cat >"$home/config/merge-gate" <<EOF
#!/bin/sh
echo "prev gate ran: \$*"
exit "\$(cat $w/prev-rc 2>/dev/null || echo 0)"
EOF
chmod +x "$home/config/merge-gate"
cp "$home/config/merge-gate" "$w/orig-prev-gate"
printf '{"schema":1,"answers_only":false,"items":[]}\n' >"$home/board.json"
gate=$home/config/merge-gate
steps=$home/config/merge-gate.steps
prev=$home/config/merge-gate.pre-chain

gate_args() { printf 'lane - %s %s' "$1" "$pr"; }
# Run the gate as jg_dod_merge_gate does: GATE_OUT is everything it printed, RC its exit code, and
# GATE_LAST the gate's own last line (the refusal, or the previous gate's line when it allows).
run_gate() { # <head>
  GATE_OUT=$(JG_HOME=$home JG_FLEET_BOARD=$home/board.json "$gate" lane - "$1" "$pr" 2>&1)
  RC=$?
  GATE_LAST=$(printf '%s\n' "$GATE_OUT" | grep -v '^$' | tail -n 1)
}
hook_line() { [ "$RC" -eq 0 ] || printf 'merge refused by config/merge-gate (exit %s)\n' "$RC"; }
# The passing proof setup: a sealed clean run at the head, a signed receipt, and a lint row.
seal() { # <head> <card|no-card>
  printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","files":["a.png"],"run_id":"r1"}\n' "$1" \
    >"$home/data/lane/.done-done/runs/r1.json"
  printf 't\t%s\t%s\tpass\tok\n' "$pr" "$1" >"$home/data/checks-gate.log"
  printf '{"schema":1,"answers_only":false,"items":[]}\n' >"$home/board.json"
  if [ "$2" = card ]; then
    jq --arg h "$1" '.items += [{kind:"evidence",key:"merge-acme-widget-pull-7",run:{commit:$h}}]' \
      "$home/board.json" >"$w/board.tmp" && mv "$w/board.tmp" "$home/board.json"
  fi
  JG_HOME=$home "$here/core/owner-rules/bin/jg-owner-rules-gate.sh" init-key >/dev/null 2>&1
  JG_HOME=$home "$here/core/owner-rules/bin/jg-owner-rules-gate.sh" sign lane "$1" "$pr" >/dev/null 2>&1
}

# The last line of the home's own gate, as the single file keeps it at config/merge-gate.pre-chain.
# shellcheck disable=SC2016 # The expected line is the emitted gate text, not this script's text.
kept_gate_last_line='exit "$(cat '"$w"'/prev-rc 2>/dev/null || echo 0)"'
bash "$here/core/owner-guard/wiring.sh" "$home" >/dev/null 2>&1 || no 'owner-guard install failed'
bash "$here/core/owner-rules/wiring.sh" "$home" >/dev/null 2>&1 || no 'owner-rules install failed'

# One file, both steps, in the required order, and no chain files left behind.
is 'the home previous gate is kept aside' "$(tail -n 1 "$prev" 2>/dev/null)" "$kept_gate_last_line"
[ -f "$gate" ] && [ ! -L "$gate" ] && ok 'config/merge-gate is one regular file' || no 'config/merge-gate is not a regular file'
body=$(cat "$gate")
has 'the single file runs the owner-details scan' "$body" "$XDG_DATA_HOME/jg-owner-guard/owner-guard merge-gate \"\$@\""
has 'the single file runs the owner-rules proof gate' "$body" "$here/core/owner-rules/bin/jg-owner-rules-gate.sh \"\$@\""
# shellcheck disable=SC2016 # The expected text is the emitted gate line, not this script's text.
has 'the single file runs the home previous gate last' "$body" 'exec "$prev" "$@"'
guard_line=$(grep -n 'merge-gate "$@"' "$gate" | head -n 1 | cut -d: -f1)
rules_line=$(grep -n 'owner-rules-gate.sh "$@"' "$gate" | head -n 1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$rules_line" ] && [ "$guard_line" -lt "$rules_line" ]; then
  ok 'the owner-details scan runs before the proof gate'
else
  no 'the owner-details scan does not run before the proof gate'
fi
is 'both steps are recorded' "$(awk -F'\t' 'NF > 1 { printf "%s ", $1 }' "$steps")" 'guard rules '
for name in pre-owner-guard pre-owner-rules; do
  link=$home/config/merge-gate.$name
  if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$gate")" ]; then
    ok "the old path $name is a symlink to the single file"
  else
    no "the old path $name does not resolve to the single file"
  fi
done

# A PR with no evidence card: refused by name, exactly as the recorded chain refusals read.
seal "$clean_head" no-card
run_gate "$clean_head"
is 'no evidence card: refused' "$RC" 1
case $GATE_LAST in
'owner-rules: no passed-proof Evidence card for '$pr'; post it with: '*) ok 'no evidence card: the one-line refusal is the proof gate refusal' ;;
*) no "no evidence card: unexpected refusal line [$GATE_LAST]" ;;
esac
is 'no evidence card: the hook line follows the refusal' "$(hook_line)" 'merge refused by config/merge-gate (exit 1)'

# The same PR with its card: allowed, and the home's own gate still runs last.
seal "$clean_head" card
printf '0\n' >"$w/prev-rc"
run_gate "$clean_head"
is 'with its card: allowed' "$RC" 0
is 'with its card: the home previous gate runs last' "$GATE_LAST" "prev gate ran: $(gate_args "$clean_head")"
printf '3\n' >"$w/prev-rc"
run_gate "$clean_head"
is 'the home previous gate refusal still refuses' "$RC" 3
is 'the home previous gate refusal keeps its exit code' "$(hook_line)" 'merge refused by config/merge-gate (exit 3)'
rm -f "$w/prev-rc"

# An owner-details hit: refused by the scan, with the same line the chain printed.
seal "$leak_head" card
run_gate "$leak_head"
is 'owner-details hit: refused' "$RC" 1
has 'owner-details hit: the scan refuses it' "$GATE_OUT" 'owner-guard: merge refused: 1 added line(s) match protected owner details:'
has 'owner-details hit: names the leaking line' "$GATE_OUT" 'notes.txt:3'
is 'owner-details hit: the hook line follows the refusal' "$(hook_line)" 'merge refused by config/merge-gate (exit 1)'

# A missing hook: the scan executable gone refuses by name, before anything else runs.
mv "$XDG_DATA_HOME/jg-owner-guard/owner-guard" "$w/guard.off"
seal "$clean_head" card
run_gate "$clean_head"
is 'missing hook: refused' "$RC" 1
is 'missing hook: the one-line refusal names the missing executable' "$GATE_LAST" \
  "merge refused: owner-guard is missing from this home; reinstall the owner-guard feature before merging: $XDG_DATA_HOME/jg-owner-guard/owner-guard"
mv "$w/guard.off" "$XDG_DATA_HOME/jg-owner-guard/owner-guard"

# Reinstalling either feature is a no-op, and neither one re-chains the file.
before=$(cat "$gate")
bash "$here/core/owner-guard/wiring.sh" "$home" >/dev/null 2>&1
bash "$here/core/owner-rules/wiring.sh" "$home" >/dev/null 2>&1
bash "$here/core/owner-guard/wiring.sh" "$home" >/dev/null 2>&1
is 'a repeat install changes nothing' "$(cat "$gate")" "$before"

# An older three-file chain folds into the one file without losing either check.
# The three files the old installers chained: the proof gate, the owner-details scan, and the
# home's own gate at the end of the chain.
old=$w/old-chain
mkdir -p "$old/config"
cp "$home/config/owner-details-patterns" "$old/config/owner-details-patterns"
chmod 600 "$old/config/owner-details-patterns"
printf '%s\n' '#!/bin/sh' 'echo "prev gate ran: $*"' 'exit 0' >"$old/config/merge-gate.pre-owner-guard"
chmod +x "$old/config/merge-gate.pre-owner-guard"
{
  printf '#!/usr/bin/env bash\n# jg-owner-guard merge gate\nguard=%q\n' "$XDG_DATA_HOME/jg-owner-guard/owner-guard"
  # shellcheck disable=SC2016 # Emitted code of the old chain, not this script's text.
  printf '[[ -x "$guard" ]] || exit 1\n'
  printf '%q merge-gate "$@" || exit $?\nprev=%q\n' "$XDG_DATA_HOME/jg-owner-guard/owner-guard" "$old/config/merge-gate.pre-owner-guard"
  # shellcheck disable=SC2016 # Emitted code of the old chain, not this script's text.
  printf '%s\n' '[ -e "$prev" ] || [ -L "$prev" ] || exit 0' '[ -x "$prev" ] || exit 1' 'exec "$prev" "$@"'
} >"$old/config/merge-gate.pre-owner-rules"
chmod +x "$old/config/merge-gate.pre-owner-rules"
{
  printf '#!/usr/bin/env bash\n# jg-owner-rules merge gate\n'
  printf '%q "$@" || exit $?\nprev=%q\n' "$here/core/owner-rules/bin/jg-owner-rules-gate.sh" "$old/config/merge-gate.pre-owner-rules"
  # shellcheck disable=SC2016 # Emitted code of the old chain, not this script's text.
  printf '%s\n' '[ -e "$prev" ] || [ -L "$prev" ] || exit 0' '[ -x "$prev" ] || exit 1' 'exec "$prev" "$@"'
} >"$old/config/merge-gate"
chmod +x "$old/config/merge-gate"
bash "$here/core/owner-rules/wiring.sh" "$old" >/dev/null 2>&1 || no 'install over an old chain failed'
old_body=$(cat "$old/config/merge-gate")
has 'an old chain folds into one file that keeps the scan' "$old_body" "$XDG_DATA_HOME/jg-owner-guard/owner-guard merge-gate \"\$@\""
has 'an old chain folds into one file that keeps the proof gate' "$old_body" "$here/core/owner-rules/bin/jg-owner-rules-gate.sh \"\$@\""
is 'an old chain keeps the home own gate as the previous gate' "$(cat "$old/config/merge-gate.pre-chain" 2>/dev/null)" '#!/bin/sh
echo "prev gate ran: $*"
exit 0'
old_files=0
for f in "$old/config"/merge-gate*; do [ -e "$f" ] || continue; old_files=$((old_files + 1)); done
is 'an old chain leaves the single file, the kept gate, the record and two symlinks' "$old_files" 5

# Uninstalling one feature keeps the other running; the last one out gives the home's gate back.
bash "$here/core/owner-rules/unwiring.sh" "$home" >/dev/null 2>&1 || no 'owner-rules uninstall failed'
has 'uninstalling the proof gate keeps the owner-details scan' "$(cat "$gate")" "$XDG_DATA_HOME/jg-owner-guard/owner-guard merge-gate \"\$@\""
lacks 'uninstalling the proof gate drops its step' "$(cat "$gate")" 'owner-rules-gate.sh "$@"'
bash "$here/core/owner-guard/wiring.sh" --uninstall "$home" >/dev/null 2>&1 || no 'owner-guard uninstall failed'
is 'the last uninstall restores the home own gate' "$(cat "$gate")" "$(cat "$w/orig-prev-gate")"
[ ! -e "$steps" ] && ok 'the last uninstall drops the steps record' || no 'the steps record survived the last uninstall'
[ ! -e "$prev" ] && ok 'the last uninstall moves the previous gate back' || no 'the previous gate is still aside'
left=0
for f in "$home"/config/merge-gate.pre-owner-*; do [ -e "$f" ] || [ -L "$f" ] || continue; left=$((left + 1)); done
is 'the last uninstall leaves no old path symlink' "$left" 0

[ "$fails" -eq 0 ] && echo "PASS merge-gate-one-entry" || { echo "FAIL merge-gate-one-entry: $fails"; exit 1; }
