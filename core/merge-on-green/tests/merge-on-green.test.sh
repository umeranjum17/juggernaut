#!/usr/bin/env bash
# End-to-end: drive merge-on-green.sh against a fixture juggernaut home with stub jg-crew-state.sh and
# jg-pr-merge.sh in the home's bin/ and a stub jg-checks-lint.sh behind JG_MOG_CHECKS_LINT, then wiring.sh
# against the same home. Usage: merge-on-green/tests/merge-on-green.test.sh
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/data TMPDIR=$d
export STUB_DIR=$d/stub
FM=$d/fm
mkdir -p "$HOME" "$STUB_DIR" "$FM/state" "$FM/bin" "$FM/data/t1" "$FM/data/t2" "$FM/data/t3"
export JG_MOG_CHECKS_LINT=$STUB_DIR/jg-checks-lint.sh
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
mog() { JG_CHECK_TIMEOUT=30 "$SRC/merge-on-green.sh" check "$FM" 2>&1; }
meta() { # <task> <yolo> <head> <gen> -> meta + matching PASS receipt
  printf 'yolo=%s\npr=https://github.com/ex/r/pull/%s\npr_head=%s\nspawn_gen=%s\n' "$2" "${1#t}" "$3" "$4" > "$FM/state/$1.meta"
  printf '{\n  "verdict": "PASS",\n  "head": "%s",\n  "spawn_gen": "%s"\n}\n' "$3" "$4" > "$FM/state/$1.run-receipt.json"
}
ready() { printf 'state: done · source: run-step · checks green: PR ready for review\n'; }
working() { printf 'state: working · source: run-step · validating (running)\n'; }

cat > "$FM/bin/jg-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
# stub: ready line unless the task is listed in $STUB_DIR/not-ready/<task> (working) or $STUB_DIR/merged/<task>
if [ -f "$STUB_DIR/merged/$1" ]; then
  echo "state: done · source: run-step · checks green: PR merged (ci monitor ended): https://github.com/ex/r/pull/$1"
elif [ -f "$STUB_DIR/not-ready/$1" ]; then
  echo "state: working · source: run-step · validating (running)"
else
  echo "state: done · source: run-step · checks green: PR ready for review"
fi
EOF
cat > "$FM/bin/jg-pr-merge.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$STUB_DIR/merge-calls"
[ -f "$STUB_DIR/merge-slow" ] && sleep 600
if [ -f "$STUB_DIR/merge-refuse" ]; then
  echo "error: pull request is not mergeable: required check ci is red" >&2
  exit 1
fi
echo "merged pull request $2"
EOF
cat > "$STUB_DIR/jg-checks-lint.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$STUB_DIR/lint-calls"
[ -f "$STUB_DIR/lint-slow" ] && sleep 600
if [ -f "$STUB_DIR/lint-fail" ]; then
  echo "checks-lint: FAIL: evidence: not proven: no verify skill ran"
  exit 1
fi
if [ -f "$STUB_DIR/lint-notproven" ]; then
  echo "checks-lint: PASS: not-proven: no device"
  exit 0
fi
echo "checks-lint: PASS: 2 evidence files"
EOF
chmod +x "$FM/bin/jg-crew-state.sh" "$FM/bin/jg-pr-merge.sh" "$STUB_DIR/jg-checks-lint.sh"
export PATH=$STUB_DIR:$PATH
H1=1111111111111111111111111111111111111111 H2=2222222222222222222222222222222222222222

# (a) yolo=off: skipped even though the state is green, nothing is linted or merged.
meta t1 off "$H1" s1
check "a: yolo off -> silent" "$(mog)" ""
check "a: nothing linted" "$(wc -l 2>/dev/null < "$STUB_DIR/lint-calls" || echo 0)" 0
check "a: nothing merged" "$([ -e "$STUB_DIR/merge-calls" ] && echo called || echo never)" never

# (b) lint FAIL: no merge, exactly one wake line naming task, PR URL and the refusal reason.
meta t2 on "$H1" s1
touch "$STUB_DIR/lint-fail"
out=$(mog)
check "b: exactly one line" "$(printf '%s\n' "$out" | wc -l)" 1
has "b: names the task and URL" "$out" "NOT merging t2 https://github.com/ex/r/pull/2"
has "b: first refusal reason" "$out" "checks-lint: FAIL: evidence: not proven: no verify skill ran"
has "b: gate refusal says lead merges, genuine holds to Main" "$out" "merge through bin/jg-pr-merge.sh; only a genuine hold"
check "b: no merge call" "$([ -e "$STUB_DIR/merge-calls" ] && echo called || echo never)" never
rm "$STUB_DIR/lint-fail" "$FM/state/t2.meta" "$FM/state/t2.run-receipt.json"

# (c) receipt head mismatch: no merge, one wake line.
meta t3 on "$H1" s1
printf '{\n  "verdict": "PASS",\n  "head": "%s",\n  "spawn_gen": "s1"\n}\n' "$H2" > "$FM/state/t3.run-receipt.json"
out=$(mog)
check "c: exactly one line" "$(printf '%s\n' "$out" | wc -l)" 1
has "c: head mismatch reason" "$out" "run receipt head $H2 != meta pr_head"
check "c: no merge call" "$([ -e "$STUB_DIR/merge-calls" ] && echo called || echo never)" never
printf '{\n  "verdict": "PASS",\n  "head": "%s",\n  "spawn_gen": "s1"\n}\n' "$H1" > "$FM/state/t3.run-receipt.json"

# (d) all gates pass: jg-pr-merge called once with exactly task and PR URL, one merge wake line.
out=$(mog)
check "d: exactly one line" "$(printf '%s\n' "$out" | wc -l)" 1
has "d: merged line with URL" "$out" "merged t3 https://github.com/ex/r/pull/3"
check "d: merge called once with both args" "$(cat "$STUB_DIR/merge-calls")" "$FM|t3 https://github.com/ex/r/pull/3"
check "d: attempted head remembered" "$(cat "$FM/data/jg-merge-on-green/t3.head")" "$H1"
check "d: normal merged line in the task status" "$(sed -E 's/^done \[at=[0-9]+\]: /done [at=N]: /' "$FM/state/t3.status")" "done [at=N]: merged https://github.com/ex/r/pull/3"

# (e) same head not retried after a merge, and not retried after a refusal either.
check "e: silent after merged head" "$(mog)" ""
check "e: still one merge call" "$(wc -l < "$STUB_DIR/merge-calls")" 1
meta t4 on "$H2" s4
touch "$STUB_DIR/merge-refuse"
out=$(mog)
check "e: refusal -> one line" "$(printf '%s\n' "$out" | wc -l)" 1
has "e: refusal reason named" "$out" "required check ci is red"
has "e: lead merges, only genuine holds go to Main" "$out" "merge through bin/jg-pr-merge.sh; only a genuine hold"
check "e: refusal recorded the attempted head" "$(cat "$FM/data/jg-merge-on-green/t4.head")" "$H2"
check "e: refused head silent on rerun" "$(mog)" ""
check "e: no second merge attempt" "$(wc -l < "$STUB_DIR/merge-calls")" 2
check "e: refused merge writes no status line" "$([ -e "$FM/state/t4.status" ] && echo written || echo none)" none

# (f) not-ready resolved state and no pr_head: silent, no gate commands ran.
rm "$STUB_DIR/merge-refuse"
mkdir -p "$STUB_DIR/not-ready"
meta t5 on "$H1" s5
printf 'yolo=on\npr=https://github.com/ex/r/pull/6\n' > "$FM/state/t6.meta"
touch "$STUB_DIR/not-ready/t5"
before=$(wc -l 2>/dev/null < "$STUB_DIR/lint-calls" || echo 0)
meta t7 on "$H1" s7
mkdir -p "$STUB_DIR/merged"
touch "$STUB_DIR/merged/t7"
check "f: already-merged PR -> silent" "$(mog)" ""
check "f: already-merged PR not re-merged" "$([ -e "$FM/data/jg-merge-on-green/t7.head" ] && echo attempted || echo never)" never
check "f: not-ready state -> silent" "$(mog)" ""
check "f: no pr_head -> silent" "$(mog)" ""
check "f: lint not consulted" "$(wc -l 2>/dev/null < "$STUB_DIR/lint-calls" || echo 0)" "$before"

# (i) JG_CHECK_TIMEOUT too small to fit a merge: nothing is started and the head is never recorded,
# so the next sweep can retry instead of a watcher kill burning the recorded head silently.
meta t8 on "$H1" s8
check "i: too-small bound -> silent" "$(JG_CHECK_TIMEOUT=4 "$SRC/merge-on-green.sh" check "$FM" 2>&1)" ""
check "i: no merge started" "$(wc -l < "$STUB_DIR/merge-calls")" 2
check "i: head not recorded" "$([ -e "$FM/data/jg-merge-on-green/t8.head" ] && echo recorded || echo never)" never
rm "$FM/state/t8.meta" "$FM/state/t8.run-receipt.json"

# (j) a gate refusal wakes once per task+head+reason+receipt: repeats are silent, a changed reason,
# receipt or head wakes again, and past refusals never block the merge itself.
meta t9 on "$H1" s9
printf '{\n  "verdict": "FAIL",\n  "head": "%s",\n  "spawn_gen": "s9"\n}\n' "$H1" > "$FM/state/t9.run-receipt.json"
out=$(mog)
check "j: verdict refusal wakes once" "$(printf '%s\n' "$out" | wc -l)" 1
has "j: verdict refusal reason" "$out" "run receipt verdict is FAIL, not PASS"
check "j: repeat verdict refusal silent" "$(mog)" ""
printf '{\n  "verdict": "FAIL",\n  "head": "%s",\n  "spawn_gen": "s9",\n  "note": "republished"\n}\n' "$H1" > "$FM/state/t9.run-receipt.json"
check "j: republished receipt wakes again" "$(printf '%s\n' "$(mog)" | wc -l)" 1
check "j: repeat republished silent" "$(mog)" ""
printf '{\n  "verdict": "PENDING",\n  "head": "%s",\n  "spawn_gen": "s9"\n}\n' "$H1" > "$FM/state/t9.run-receipt.json"
out=$(mog)
check "j: changed reason wakes again" "$(printf '%s\n' "$out" | wc -l)" 1
has "j: changed reason named" "$out" "run receipt verdict is PENDING, not PASS"
check "j: repeat changed reason silent" "$(mog)" ""
printf '{\n  "verdict": "PASS",\n  "head": "%s",\n  "spawn_gen": "s9"\n}\n' "$H1" > "$FM/state/t9.run-receipt.json"
printf 'yolo=on\npr=https://github.com/ex/r/pull/9\npr_head=%s\nspawn_gen=s9\n' "$H2" > "$FM/state/t9.meta"
out=$(mog)
check "j: new head wakes again" "$(printf '%s\n' "$out" | wc -l)" 1
has "j: new head reason" "$out" "run receipt head $H1 != meta pr_head"
check "j: repeat new-head refusal silent" "$(mog)" ""
touch "$STUB_DIR/lint-fail"
out=$(mog)
check "j: lint refusal wakes once" "$(printf '%s\n' "$out" | wc -l)" 1
has "j: lint refusal reason" "$out" "checks lint refused"
check "j: repeat lint refusal silent" "$(mog)" ""
rm "$STUB_DIR/lint-fail"
meta t9 on "$H2" s9
out=$(mog)
check "j: gates pass after refusals -> merged" "$(printf '%s\n' "$out" | wc -l)" 1
has "j: merged line" "$out" "merged t9 https://github.com/ex/r/pull/9"
check "j: merge attempt recorded" "$(cat "$FM/data/jg-merge-on-green/t9.head")" "$H2"
check "j: silent after merge" "$(mog)" ""
rm "$FM/state/t9.meta" "$FM/state/t9.run-receipt.json"

# (k) a command this check kills on its own timeout is no attempt: one truthful timeout wake per
# task+head+reason, no merge attempt recorded, and the next sweep still retries silently.
meta t10 on "$H1" s10
touch "$STUB_DIR/lint-slow"
out=$(JG_CHECK_TIMEOUT=9 "$SRC/merge-on-green.sh" check "$FM" 2>&1)
check "k: lint timeout wakes once" "$(printf '%s\n' "$out" | wc -l)" 1
has "k: lint timeout named" "$out" "checks lint timed out"
has "k: lint timeout truthful" "$out" "retrying next sweep"
check "k: repeat lint timeout silent" "$(JG_CHECK_TIMEOUT=9 "$SRC/merge-on-green.sh" check "$FM" 2>&1)" ""
check "k: lint timeout remembered, no head" "$([ -e "$FM/data/jg-merge-on-green/t10.refused" ] && [ ! -e "$FM/data/jg-merge-on-green/t10.head" ] && echo timeout-only || echo wrong)" timeout-only
rm "$STUB_DIR/lint-slow"
touch "$STUB_DIR/merge-slow"
out=$(JG_CHECK_TIMEOUT=9 "$SRC/merge-on-green.sh" check "$FM" 2>&1)
check "k: merge attempted then killed" "$(wc -l < "$STUB_DIR/merge-calls")" 4
check "k: merge timeout wakes once" "$(printf '%s\n' "$out" | wc -l)" 1
has "k: merge timeout named" "$out" "jg-pr-merge timed out"
check "k: merge timeout not recorded as head" "$([ -e "$FM/data/jg-merge-on-green/t10.head" ] && echo recorded || echo never)" never
check "k: repeat merge timeout silent" "$(JG_CHECK_TIMEOUT=9 "$SRC/merge-on-green.sh" check "$FM" 2>&1)" ""
check "k: repeat merge timeout still retried" "$(wc -l < "$STUB_DIR/merge-calls")" 5
rm "$STUB_DIR/merge-slow"
out=$(mog)
check "k: next sweep retries and merges" "$(printf '%s\n' "$out" | wc -l)" 1
has "k: merged after timeout" "$out" "merged t10 https://github.com/ex/r/pull/10"
check "k: head recorded after merge" "$(cat "$FM/data/jg-merge-on-green/t10.head")" "$H1"
rm "$FM/state/t10.meta" "$FM/state/t10.run-receipt.json"

# (l) merge=manual: skipped silently even though every gate would pass; nothing read, linted or merged.
meta t11 on "$H1" s11
echo merge=manual >> "$FM/state/t11.meta"
lint_before=$(wc -l < "$STUB_DIR/lint-calls")
check "l: merge=manual -> silent" "$(mog)" ""
check "l: merge=manual not linted" "$(wc -l < "$STUB_DIR/lint-calls")" "$lint_before"
check "l: merge=manual not merged" "$(wc -l < "$STUB_DIR/merge-calls")" 6
check "l: merge=manual no attempt recorded" "$([ -e "$FM/data/jg-merge-on-green/t11.head" ] && echo recorded || echo never)" never
rm "$FM/state/t11.meta" "$FM/state/t11.run-receipt.json"

# (m) a not-proven PASS from the evidence gate (the gate reads the PR's newest "## Checks" block):
# the task is skipped silently after the lint, before the receipt or merge, with no recorded
# attempt, on the first sweep and every repeat; the same task merges once the gate returns a plain
# PASS.
meta t12 on "$H1" s12
touch "$STUB_DIR/lint-notproven"
check "m: not proven -> silent" "$(mog)" ""
check "m: repeat not proven silent" "$(mog)" ""
check "m: not proven not merged" "$(wc -l < "$STUB_DIR/merge-calls")" 6
check "m: not proven no attempt recorded" "$([ -e "$FM/data/jg-merge-on-green/t12.head" ] && echo recorded || echo never)" never
rm "$STUB_DIR/lint-notproven"
out=$(mog)
has "m: plain PASS merges" "$out" "merged t12 https://github.com/ex/r/pull/12"
check "m: merged once" "$(wc -l < "$STUB_DIR/merge-calls")" 7
rm "$FM/state/t12.meta" "$FM/state/t12.run-receipt.json"

# (g) install --dry-run lists the steps and writes nothing.
cat > "$FM/bin/jg-check-register.sh" <<'EOF'
#!/bin/sh
[ "${JG_STATE_OVERRIDE+set}" ] && exit 9
echo "register $1" >> "${JG_HOME:?no JG_HOME}/reg-calls"
EOF
chmod +x "$FM/bin/jg-check-register.sh"
before=$(find "$d" -mindepth 1 | sort)
out=$("$SRC/wiring.sh" --dry-run "$FM" 2>&1)
has "g: would copy" "$out" "would copy: $SRC/merge-on-green.sh -> $d/data/jg-merge-on-green/merge-on-green.sh"
has "g: lint adapter copied" "$out" "would copy: $SRC/checks-lint.sh -> $d/data/jg-merge-on-green/checks-lint.sh"
has "g: legacy lint copied" "$out" "would copy: $SRC/jg-checks-lint.sh -> $d/data/jg-merge-on-green/jg-checks-lint.sh"
has "g: done-done config copied" "$out" "would copy: $SRC/.done-done.yaml -> $d/data/jg-merge-on-green/.done-done.yaml"
has "g: would register" "$out" "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FM $FM/bin/jg-check-register.sh merge-on-green"
check "g: nothing written" "$(find "$d" -mindepth 1 | sort)" "$before"

# (h) real install with JG_STATE_OVERRIDE exported empty: the shim execs the installed script with the home.
out=$(JG_STATE_OVERRIDE='' "$SRC/wiring.sh" "$FM" 2>&1) && rc=0 || rc=$?
check "h: install exits 0 with JG_STATE_OVERRIDE=''" "$rc" 0
check "h: register ran without the override" "$(cat "$FM/reg-calls")" "register merge-on-green"
check "h: adapter installed" "$([ -x "$d/data/jg-merge-on-green/checks-lint.sh" ] && echo yes)" yes
check "h: legacy lint installed" "$([ -x "$d/data/jg-merge-on-green/jg-checks-lint.sh" ] && echo yes)" yes
check "h: done-done config installed" "$([ -f "$d/data/jg-merge-on-green/.done-done.yaml" ] && echo yes)" yes
check "h: shim execs the check" "$(sed -n 2p "$FM/state/merge-on-green.check.sh")" "exec $d/data/jg-merge-on-green/merge-on-green.sh check $FM"
check "h: shim mode 0700" "$(stat -c %a "$FM/state/merge-on-green.check.sh")" 700
check "h: installed script runs from the shim" "$(JG_CHECK_TIMEOUT=30 "$FM/state/merge-on-green.check.sh")" ""

# (i) A home still running the retired add-on copy: install migrates it instead of installing beside it.
OLD=$d/data/fm-merge-on-green
mkdir -p "$OLD"
printf '#!/bin/sh\n# retired add-on copy\n' > "$OLD/merge-on-green.sh"
printf '#!/bin/sh\n# retired adapter\n' > "$OLD/checks-lint.sh"
printf '#!/usr/bin/env python3\n# retired 1,000-line rule\n' > "$OLD/fm-checks-lint.sh"
printf 'x: 1\n' > "$OLD/.done-done.yaml"
for f in merge-on-green.sh checks-lint.sh jg-checks-lint.sh .done-done.yaml; do rm -f -- "$d/data/jg-merge-on-green/$f"; done
printf '#!/usr/bin/env bash\nexec %q check %q\n' "$OLD/merge-on-green.sh" "$FM" > "$FM/state/merge-on-green.check.sh"
chmod 700 "$FM/state/merge-on-green.check.sh"
rm -f "$FM/reg-calls"
out=$("$SRC/wiring.sh" "$FM" 2>&1) && rc=0 || rc=$?
check "i: migration exits 0" "$rc" 0
has "i: names the retired copy it replaced" "$out" "migrated the retired add-on copy at $OLD"
check "i: the retired 1,000-line rule is gone" "$([ -e "$OLD/fm-checks-lint.sh" ] && echo present || echo gone)" gone
check "i: the retired adapter is gone" "$([ -e "$OLD/checks-lint.sh" ] && echo present || echo gone)" gone
check "i: the retired path redirects to the feature gate" "$(tail -n 1 "$OLD/merge-on-green.sh")" "exec $d/data/jg-merge-on-green/merge-on-green.sh \"\$@\""
check "i: the home's shim now execs the feature gate" "$(sed -n 2p "$FM/state/merge-on-green.check.sh")" "exec $d/data/jg-merge-on-green/merge-on-green.sh check $FM"
check "i: the retired path still runs the gate" "$(JG_CHECK_TIMEOUT=30 "$OLD/merge-on-green.sh" check "$FM")" ""
check "i: the check was registered" "$(cat "$FM/reg-calls")" "register merge-on-green"
before_retired=$(find "$OLD" -mindepth 1 | sort)
out=$("$SRC/wiring.sh" "$FM" 2>&1) && rc=0 || rc=$?
check "i: a re-run exits 0" "$rc" 0
has "i: a re-run reports nothing changed" "$out" "already wired $FM (nothing changed)"
check "i: a re-run leaves the retired redirect alone" "$(find "$OLD" -mindepth 1 | sort)" "$before_retired"

# (j) A shim that execs some other gate: refused before the first write, nothing half-wired.
FM2=$d/fm2
mkdir -p "$FM2/state" "$FM2/bin" "$d/data2"
cp "$FM/bin/jg-check-register.sh" "$FM2/bin/"
printf '#!/usr/bin/env bash\nexec /opt/other/gate.sh check %q\n' "$FM2" > "$FM2/state/merge-on-green.check.sh"
chmod 700 "$FM2/state/merge-on-green.check.sh"
before2=$(find "$d/data2" -mindepth 1 | sort)
out=$(XDG_DATA_HOME=$d/data2 "$SRC/wiring.sh" "$FM2" 2>&1) && rc=0 || rc=$?
check "j: an unknown shim refuses" "$rc" 1
has "j: the refusal names the shim it will not replace" "$out" "is not the merge gate this installer writes"
check "j: the refusal wrote nothing" "$(find "$d/data2" -mindepth 1 | sort)" "$before2"
check "j: the refusal left the shim alone" "$(sed -n 2p "$FM2/state/merge-on-green.check.sh")" "exec /opt/other/gate.sh check $FM2"
check "j: the refusal did not register" "$([ -e "$FM2/reg-calls" ] && echo called || echo no)" no

# (k) A retired directory holding something else: refused, never overwritten or half-replaced.
FM3=$d/fm3
mkdir -p "$FM3/state" "$FM3/bin" "$d/data3/fm-merge-on-green"
cp "$FM/bin/jg-check-register.sh" "$FM3/bin/"
printf '#!/bin/sh\n# somebody else gate\n' > "$d/data3/fm-merge-on-green/other-gate.sh"
before3=$(find "$d/data3" -mindepth 1 | sort)
out=$(XDG_DATA_HOME=$d/data3 "$SRC/wiring.sh" "$FM3" 2>&1) && rc=0 || rc=$?
check "k: an unknown retired directory refuses" "$rc" 1
has "k: the refusal names the retired copy it will not replace" "$out" "does not hold the retired add-on copy"
check "k: the refusal wrote nothing" "$(find "$d/data3" -mindepth 1 | sort)" "$before3"
check "k: the refusal left the home with no shim" "$([ -e "$FM3/state/merge-on-green.check.sh" ] && echo present || echo absent)" absent

# (l) A home wired at another install path keeps that share: the installer follows the shim instead of
# moving the home to XDG_DATA_HOME, and a shim that runs another home's gate is refused.
FM4=$d/fm4
OTHER=$d/other-share
mkdir -p "$FM4/state" "$FM4/bin" "$OTHER/fm-merge-on-green"
cp "$FM/bin/jg-check-register.sh" "$FM4/bin/"
printf '#!/bin/sh\n# retired adapter\n' > "$OTHER/fm-merge-on-green/checks-lint.sh"
printf '#!/usr/bin/env python3\n# retired rule\n' > "$OTHER/fm-merge-on-green/fm-checks-lint.sh"
printf '#!/bin/sh\n# retired copy\n' > "$OTHER/fm-merge-on-green/merge-on-green.sh"
printf '#!/usr/bin/env bash\nexec %q check %q\n' "$OTHER/fm-merge-on-green/merge-on-green.sh" "$FM4" > "$FM4/state/merge-on-green.check.sh"
chmod 700 "$FM4/state/merge-on-green.check.sh"
out=$(XDG_DATA_HOME=$d/data4 "$SRC/wiring.sh" "$FM4" 2>&1) && rc=0 || rc=$?
check "l: install exits 0" "$rc" 0
check "l: the gate lands in the share the shim names" "$([ -x "$OTHER/jg-merge-on-green/jg-checks-lint.sh" ] && echo yes)" yes
check "l: XDG_DATA_HOME is untouched" "$(mkdir -p "$d/data4"; find "$d/data4" -mindepth 1 | sort)" ""
check "l: the old copy in that share now redirects" "$(tail -n 1 "$OTHER/fm-merge-on-green/merge-on-green.sh")" "exec $OTHER/jg-merge-on-green/merge-on-green.sh \"\$@\""
printf '#!/usr/bin/env bash\nexec %q check %q\n' "$OTHER/jg-merge-on-green/merge-on-green.sh" "$FM" > "$FM4/state/merge-on-green.check.sh"
chmod 700 "$FM4/state/merge-on-green.check.sh"
out=$(XDG_DATA_HOME=$d/data4 "$SRC/wiring.sh" "$FM4" 2>&1) && rc=0 || rc=$?
check "l: a shim running another home's gate refuses" "$rc" 1
has "l: the refusal names the home it runs for" "$out" "not for this home"

if [ "$fails" -eq 0 ]; then echo "PASS: merge-on-green e2e"; else echo "FAIL: $fails check(s)"; exit 1; fi
