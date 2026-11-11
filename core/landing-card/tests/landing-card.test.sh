#!/usr/bin/env bash
# Journey: landing-card.sh against a fixture home with a real git clone and the real sign-off-axi on a temp board.
# a) every landing row gets one evidence card keyed landing-<commit>, whatever its gate kind: a passed full gate with a
#    receipt and a done-done verdict, a full-tip-red batch row, a revert, and a no-gate row whose commit is not in the clone;
#    a missing proof reads "absent" / "not checked" and never skips the card;
# b) the second run posts nothing, and an archived card is not posted again;
# c) a new landing posts exactly one card, and `check` is silent on success;
# d) a failed post stops the run after one attempt with one line, and the next run posts the rest;
# e) the wiring installs a shim that registers the check;
# f) each go-live row of trunk-live.tsv gets one card listing the landings since the previous live commit, with the delivery
#    machine's word for a registered lane and none for the others; a failed go-live row and a per-home row get no card, a
#    second run posts nothing;
# h) the first run in a home with history (no data/landing-card-since) writes the marker and posts one summary card per UTC
#    day of old landings, none per landing; a landing after the marker gets its own card with its gate figures; a second run
#    posts nothing;
# g) the summary command posts one card for a day's landings once, and says so when the day has none.
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
mkdir -p "$FM/state" "$FM/data" "$FM/config" "$FM/bin" "$FM/core" "$P"
cp "$SRC/../../bin/"jg-*.sh "$FM/bin/"; ln -s "$SRC/../machines" "$FM/core/machines"
(cd "$d/board" && sign-off-axi init >/dev/null 2>&1)
printf "#!/bin/sh\nexec merge-card post --board '%s' \"\$@\"\n" "$BOARD" > "$FM/config/post-merge"
git -C "$P" init -q
land() { echo "$1" > "$P/$1"; git -C "$P" add "$1"; git -C "$P" commit -qm "$2"; git -C "$P" rev-parse HEAD; }
c1=$(land one 'one: the first lane'); c2=$(land two 'two: the second lane'); c3=$(land three 'three: a revert'); c4=${c1//[0-9a-f]/a}
printf '%s\tproj\t%s\t1794200000\tfull\n%s\tproj\t%s\t1794200100\tfull-tip-red\tbatch-from=%s\n%s\tproj\t%s\t1794200200\treverts-%s\n%s\tproj\t%s\t1794200300\tno-gate\n' \
  one "$c1" two "$c2" "$c1" revert-one "$c3" "${c1:0:12}" ghost "$c4" > "$FM/data/trunk-landings.tsv"
printf 'one\tproj\t%s\t1794200001\treceipt=PASS@%s\tsignature=absent\tmerge-card=present\tgate=ran:312,failed:0,secs:431\n' "$c1" "${c1:0:12}" > "$FM/data/trunk-landing-proofs.tsv"
echo 0 > "$FM/data/landing-card-since"   # no backfill here: every row gets its own card (h tests the backfill)
mkdir -p "$FM/data/one"; printf '{"verdict":"pass"}\n' > "$FM/data/one/merge-card.json"
fails=0; LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/landing-card.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
cards() { sign-off-axi list "$BOARD" --json --full | jq "[.decisions[] | select(.key | startswith(\"landing-\"))]"; }
run() { "$SRC/landing-card.sh" "$1" "$FM" "${@:2}"; }

check "a: the first run posts a card for every landing" "$(run run)" 'landing-card: posted 4, 0 already on the board'
check "a: one card per commit, keyed landing-<commit>" "$(cards | jq -r '[.[].key] | sort | join(" ")')" "$(printf 'landing-%s\n' "$c1" "$c2" "$c3" "$c4" | sort | tr '\n' ' ' | sed 's/ $//')"
check "a: every card is evidence" "$(cards | jq -r '[.[].type] | unique | join(",")')" evidence
check "a: the title is the lane name, short enough for a phone row" "$(cards | jq -r --arg k "landing-$c1" '.[] | select(.key == $k) | .title')" 'Landed: one'
about() { cards | jq -r --arg k "landing-$1" '.[] | select(.key == $k) | .about'; }
case $(about "$c1") in "one: the first lane. Landed on the proj trunk at 2026-11-09"*"All required tests passed. 312 test scripts ran, 0 failed on the first run, the gate took 431 s. Test receipt: PASS@${c1:0:12}."*"Done-done verdict: pass."*) say "ok: a: proofs on the card" ;; *) say "FAIL: a: proofs on the card: $(about "$c1")"; fails=$((fails + 1)) ;; esac
case $(about "$c2") in *"not charged to this lane"*"Gate figures: not recorded. (one gate for its whole stack)"*"Test receipt: absent."*"Done-done verdict: not checked."*) say "ok: a: a missing proof reads absent" ;; *) say "FAIL: a: a missing proof: $(about "$c2")"; fails=$((fails + 1)) ;; esac
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

# f) go-live cards: a registry names lane `one` (switch absent) and lane `five` (switch present, proof holds).
touch "$FM/config/five-on"
export JG_DELIVERY_CHANGES=$d/changes.tsv
printf 'one\tproj\t%s\tone-off\tswitch\tthe first\nfive\tproj\t%s\tfive-on\tswitch\tthe fifth\n' "$c1" "$c5" > "$JG_DELIVERY_CHANGES"
printf 'proj\t%s\t1794201000\tlive\nproj:home-a\t%s\t1794201000\tlive\nproj:home-b\t%s\t1794201000\tlive\n' "$c2" "$c2" "$c2" >> "$FM/data/trunk-live.tsv"
check "f: the first go-live posts one card" "$(run run)" 'landing-card: posted 1, 7 already on the board'
livecard() { sign-off-axi list "$BOARD" --json --full | jq -r --arg k "live-$1" '.decisions[] | select(.key == $k) | .about'; }
case $(livecard "$c2") in "Live in 2 home(s) at 2026-11-09"*"Landings since the last go-live: one, two."*"Delivery now: one is in-homes-off.") say "ok: f: the first go-live lists its two lanes and only the registered lane's word" ;; *) say "FAIL: f: first go-live: $(livecard "$c2")"; fails=$((fails + 1)) ;; esac
printf 'proj\t%s\t1794201500\thook-failed:disk full\nproj\t%s\t1794202000\tlive,pinned-behind-%s\nproj:home-a\t%s\t1794202000\tlive\nproj:home-b\t%s\t1794202000\tlive\n' "$c6" "$c7" "${c7:0:12}" "$c7" "$c7" >> "$FM/data/trunk-live.tsv"
check "f: a failed row gets no card; the next go-live posts one" "$(run run)" 'landing-card: posted 1, 8 already on the board'
case $(livecard "$c7") in *"Live in 2 home(s)"*"Landings since the last go-live: revert-one, five, six, seven."*"pinned this go-live behind the trunk tip ${c7:0:12}."*"Delivery now: five is in-use.") say "ok: f: the second go-live lists the batch since the first, one lane in use" ;; *) say "FAIL: f: second go-live: $(livecard "$c7")"; fails=$((fails + 1)) ;; esac
check "f: no card for a failed row" "$(livecard "$c6")" ''
check "f: the second run posts nothing" "$(run run)" 'landing-card: posted 0, 9 already on the board'

# g) the summary card
check "g: the summary posts once" "$(run summary 2026-11-09)" 'landing-card: posted the card landings-2026-11-09'
case $(sign-off-axi list "$BOARD" --json --full | jq -r '.decisions[] | select(.key == "landings-2026-11-09") | .title + " | " + .about') in
  "Landed on 2026-11-09: 7 lanes | 7 landings from "*"1 failed only where the trunk was already red, 1 are reverts"*) say "ok: g: the summary counts the day by gate kind" ;;
  *) say "FAIL: g: summary: $(sign-off-axi list "$BOARD" --json --full | jq -r '.decisions[] | select(.key == "landings-2026-11-09") | .about')"; fails=$((fails + 1)) ;; esac
check "g: the second summary posts nothing" "$(run summary 2026-11-09)" 'landing-card: the card landings-2026-11-09 is already on the board'
check "g: a day with no landings gets no card" "$(run summary 2026-01-01)" 'landing-card: no landings on 2026-01-01; no card'

mkdir -p "$d/share"
if XDG_DATA_HOME=$d/share "$SRC/wiring.sh" "$FM" > "$d/wire" 2>&1; then
  check "e: the wiring registers the check" "$(head -n 1 "$FM/state/landing-card.check-trust")" jg-custom-check-v1
else say "FAIL: e: wiring: $(cat "$d/wire")"; fails=$((fails + 1)); fi
# h) the backfill: a second home with three old landings on two days and no marker.
FM2=$d/fm2; mkdir -p "$FM2/state" "$FM2/data" "$FM2/config" "$FM2/bin" "$FM2/core"
cp "$FM/bin/"jg-*.sh "$FM2/bin/"; ln -s "$SRC/../machines" "$FM2/core/machines"; ln -s "$FM/projects" "$FM2/projects"; cp "$FM/config/post-merge" "$FM2/config/"
printf 'one\tproj\t%s\t1793940800\tfull\ntwo\tproj\t%s\t1793940900\tfull-tip-red\nthree\tproj\t%s\t1794100000\tfull\n' "$c1" "$c2" "$c3" > "$FM2/data/trunk-landings.tsv"
board_before=$(cards | jq length); summaries() { sign-off-axi list "$BOARD" --json --full | jq -r '[.decisions[] | select(.key | startswith("landings-")) | .key] | sort | join(" ")'; }
check "h: the first run posts one summary per old day and no landing card" "$("$SRC/landing-card.sh" run "$FM2")" 'landing-card: posted 2, 0 already on the board'
check "h: the two old days have their summaries (beside the one g posted)" "$(summaries)" 'landings-2026-11-06 landings-2026-11-08 landings-2026-11-09'
check "h: no landing card was added" "$(cards | jq length)" "$board_before"
check "h: the marker is written" "$(grep -c '^[0-9][0-9]*$' "$FM2/data/landing-card-since")" 1
case $(sign-off-axi list "$BOARD" --json --full | jq -r '.decisions[] | select(.key == "landings-2026-11-06") | .about') in
  *"2 landings from "*"1 passed every required test, 1 failed only where the trunk was already red"*"These landed before the cards were posted one by one"*) say "ok: h: a backfill summary counts its day's old landings" ;;
  *) say "FAIL: h: backfill summary: $(sign-off-axi list "$BOARD" --json --full | jq -r '.decisions[] | select(.key == "landings-2026-11-06") | .about')"; fails=$((fails + 1)) ;; esac
check "h: the second run posts nothing" "$("$SRC/landing-card.sh" run "$FM2")" 'landing-card: posted 0, 2 already on the board'
c8=$(land eight 'eight: after the marker'); printf 'eight\tproj\t%s\t%s\tfull\n' "$c8" "$(( $(cat "$FM2/data/landing-card-since") + 5 ))" >> "$FM2/data/trunk-landings.tsv"
check "h: a landing after the marker gets its own card" "$("$SRC/landing-card.sh" run "$FM2")" 'landing-card: posted 1, 2 already on the board'
check "h: the new card is that landing's" "$(cards | jq -r --arg k "landing-$c8" '.[] | select(.key == $k) | .title')" 'Landed: eight'

[ "$fails" -eq 0 ] || { say "FAILED: $fails"; exit 1; }
say "PASS: landing-card"
