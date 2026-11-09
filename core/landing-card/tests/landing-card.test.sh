#!/usr/bin/env bash
# Journey: landing-card.sh against a fixture home with a real git clone and the real sign-off-axi on a temp board.
# a) every landing row gets one evidence card keyed landing-<commit>, whatever its gate kind: a passed full gate with a
#    receipt and a done-done verdict, a full-tip-red batch row, a revert, and a no-gate row whose commit is not in the clone;
#    a missing proof reads "absent" / "not checked" and never skips the card;
# b) the second run posts nothing, and an archived card is not posted again;
# c) a new landing posts exactly one card, and `check` is silent on success;
# d) a failed post stops the run after one attempt with one line, and the next run posts the rest;
# e) the wiring installs a shim that registers the check.
# Skips (exit 0) when sign-off-axi is not on PATH. Never touches a real board: SIGN_OFF_HOME is a temp folder.
# Usage: landing-card/tests/landing-card.test.sh
set -euo pipefail
command -v sign-off-axi >/dev/null || { echo "skip - sign-off-axi is not on PATH"; exit 0; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null SIGN_OFF_HOME=$d/board
unset GIT_CONFIG_COUNT
mkdir -p "$HOME" "$d/board"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
FM=$d/fm; P=$FM/projects/proj; BOARD=$d/board/decisions.json
mkdir -p "$FM/state" "$FM/data" "$FM/config" "$FM/bin" "$P"
cp "$SRC/../../bin/"jg-*.sh "$FM/bin/"
(cd "$d/board" && sign-off-axi init >/dev/null 2>&1)
printf "#!/bin/sh\nexec merge-card post --board '%s' \"\$@\"\n" "$BOARD" > "$FM/config/post-merge"
git -C "$P" init -q
land() { echo "$1" > "$P/$1"; git -C "$P" add "$1"; git -C "$P" commit -qm "$2"; git -C "$P" rev-parse HEAD; }
c1=$(land one 'one: the first lane'); c2=$(land two 'two: the second lane'); c3=$(land three 'three: a revert'); c4=${c1//[0-9a-f]/a}
printf '%s\tproj\t%s\t1794200000\tfull\n%s\tproj\t%s\t1794200100\tfull-tip-red\tbatch-from=%s\n%s\tproj\t%s\t1794200200\treverts-%s\n%s\tproj\t%s\t1794200300\tno-gate\n' \
  one "$c1" two "$c2" "$c1" revert-one "$c3" "${c1:0:12}" ghost "$c4" > "$FM/data/trunk-landings.tsv"
printf 'one\tproj\t%s\t1794200001\treceipt=PASS@%s\tsignature=absent\tmerge-card=present\n' "$c1" "${c1:0:12}" > "$FM/data/trunk-landing-proofs.tsv"
mkdir -p "$FM/data/one"; printf '{"verdict":"pass"}\n' > "$FM/data/one/merge-card.json"
fails=0; LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/landing-card.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
cards() { sign-off-axi list "$BOARD" --json --full | jq "[.decisions[] | select(.key | startswith(\"landing-\"))]"; }
run() { "$SRC/landing-card.sh" "$1" "$FM"; }

check "a: the first run posts a card for every landing" "$(run run)" 'landing-card: posted 4, 0 already on the board'
check "a: one card per commit, keyed landing-<commit>" "$(cards | jq -r '[.[].key] | sort | join(" ")')" "$(printf 'landing-%s\n' "$c1" "$c2" "$c3" "$c4" | sort | tr '\n' ' ' | sed 's/ $//')"
check "a: every card is evidence" "$(cards | jq -r '[.[].type] | unique | join(",")')" evidence
check "a: the title is the lane name, short enough for a phone row" "$(cards | jq -r --arg k "landing-$c1" '.[] | select(.key == $k) | .title')" 'Landed: one'
about() { cards | jq -r --arg k "landing-$1" '.[] | select(.key == $k) | .about'; }
case $(about "$c1") in "one: the first lane. Landed on the proj trunk at 2026-11-09"*"All required tests passed."*"Test receipt: PASS@${c1:0:12}."*"Done-done verdict: pass."*) say "ok: a: proofs on the card" ;; *) say "FAIL: a: proofs on the card: $(about "$c1")"; fails=$((fails + 1)) ;; esac
case $(about "$c2") in *"not charged to this lane"*"Test receipt: absent."*"Done-done verdict: not checked."*) say "ok: a: a missing proof reads absent" ;; *) say "FAIL: a: a missing proof: $(about "$c2")"; fails=$((fails + 1)) ;; esac
case $(about "$c3") in "three: a revert. Landed"*"Revert of ${c1:0:12}."*) say "ok: a: a revert has its card" ;; *) say "FAIL: a: revert: $(about "$c3")"; fails=$((fails + 1)) ;; esac
check "a: a revert is titled Reverted" "$(cards | jq -r --arg k "landing-$c3" '.[] | select(.key == $k) | .title')" 'Reverted: one'
check "a: a commit not in the clone still has its card" "$(cards | jq -r --arg k "landing-$c4" '.[] | select(.key == $k) | .title + " / " + (.about | .[0:35])')" 'Landed: ghost / The commit is not in the local copy'

check "b: the second run posts nothing" "$(run run)" 'landing-card: posted 0, 4 already on the board'
sign-off-axi dismiss "landing-$c2" "$BOARD" >/dev/null
check "b: an archived card is not posted again" "$(run run)" 'landing-card: posted 0, 4 already on the board'

c5=$(land five 'five: a new lane'); printf 'five\tproj\t%s\t1794200400\tfull\n' "$c5" >> "$FM/data/trunk-landings.tsv"
check "c: check is silent on success" "$(run check)" ''
check "c: the new landing has exactly one card" "$(cards | jq -r --arg k "landing-$c5" '[.[] | select(.key == $k)] | length')" 1
check "c: five cards in all" "$(cards | jq length)" 5

c6=$(land six 'six: another'); c7=$(land seven 'seven: another again')
printf 'six\tproj\t%s\t1794200500\tfull\nseven\tproj\t%s\t1794200600\tfull\n' "$c6" "$c7" >> "$FM/data/trunk-landings.tsv"
cat > "$d/signoff" <<'STUB'
#!/usr/bin/env bash
case $1 in post) echo x >> "$STUB_POSTS"; echo 'error: the board is busy' >&2; exit 1 ;; *) exec sign-off-axi "$@" ;; esac
STUB
chmod +x "$d/signoff"; : > "$d/posts"
out=$(STUB_POSTS=$d/posts JG_LANDING_CARD_SIGNOFF=$d/signoff run check)
check "d: a failed post stops after one attempt" "$(wc -l < "$d/posts" | tr -d ' ')" 1
check "d: it says which card failed, once" "$(printf '%s\n' "$out" | grep -c '^landing-card: card for six not posted (error: the board is busy)')" 1
check "d: the next run posts the rest" "$(run run)" 'landing-card: posted 2, 5 already on the board'

mkdir -p "$d/share"
if XDG_DATA_HOME=$d/share "$SRC/wiring.sh" "$FM" > "$d/wire" 2>&1; then
  check "e: the wiring registers the check" "$(head -n 1 "$FM/state/landing-card.check-trust")" jg-custom-check-v1
else say "FAIL: e: wiring: $(cat "$d/wire")"; fails=$((fails + 1)); fi
[ "$fails" -eq 0 ] || { say "FAILED: $fails"; exit 1; }
say "PASS: landing-card"
