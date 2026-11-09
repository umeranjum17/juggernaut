#!/usr/bin/env bash
# Sync an internal-home ticket whose store title ends in a truncation tail and a file path onto a task-owned sign-off board and capture
# the Tickets page at 390px: the ticket shows under the project juggernaut, with a plain one-line title.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
command -v sign-off-axi >/dev/null || { echo 'sign-off-axi is required' >&2; exit 1; }
command -v chrome-devtools-axi >/dev/null || { echo 'chrome-devtools-axi is required' >&2; exit 1; }
ver=$(sign-off-axi --version | head -n1)
case $ver in 0.6.9|0.6.[1-9][0-9]*|0.[7-9]*|0.[1-9][0-9]*|[1-9]*) ;; *)
  echo "sign-off-axi $ver is older than 0.6.9 (needs --stage and --last-event-at)" >&2; exit 1 ;;
esac
real_home=${HOME:-/home/you}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
fork=${JG_TEST_FORK:-${JG_MAIN_HOME:-$(cd "$repo/.." && pwd -P)}}
evidence=$DONE_DONE_EVIDENCE_ROOT
work=$(mktemp -d "${TMPDIR:-/tmp}/plain-board.XXXXXX")  # the store and the board stay out of the evidence folder
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main TMPDIR=$work/tmp
mkdir -p "$HOME" "$JG_HOME"/{data,config,state,projects/herdr} "$TMPDIR"
ln -s "$fork/bin" "$JG_HOME/bin"
ln -s "$fork/toolchain.versions" "$JG_HOME/toolchain.versions"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
mkdir -p "$work/store"
printf '%s\n' "$work/store/.beads" > "$JG_HOME/config/beads-dir"
BEADS_DIR="$work/store/.beads" "$fork/bin/jg-beads.sh" init --prefix plain >/dev/null 2>&1 || { echo 'cannot create the Beads store (set JG_BEADS_BD and JG_BEADS_DOLT to the pinned builds)' >&2; exit 1; }
(cd "$JG_HOME"; "$fork/bin/jg-backlog.sh" add plain-row $'[feature] Umer plain words data/umer/report.md\n... (truncated, 90 chars total - use show plain-row --full)' --repo herdr --priority 1 --body $'Plain board proof row\nparent: upkeep' >/dev/null)
git init -q "$JG_HOME/projects/herdr"
git -C "$JG_HOME/projects/herdr" remote add origin https://github.com/example/herdr.git
bash "$repo/tickets-sync/wiring.sh"
"$JG_HOME/state/tickets-sync.check.sh" | tee "$evidence/sync.out"
tid=$(printf 'jg-%s' "$(printf '%s' main/plain-row | sha256sum | cut -c1-32)")
sign-off-axi ticket "$work/board.json" --id "$tid" --json | tee "$evidence/ticket.json" | jq -e '.ticket.project == "juggernaut" and .ticket.title == "Umer plain words"' >/dev/null
sign-off-axi serve "$work/board.json" --port 0 --bind 127.0.0.1 >"$work/serve.log" 2>&1 &
cleanup() {
  SIGN_OFF_HOME=$work/signoff sign-off-axi stop "$work/board.json" >/dev/null 2>&1 || true
  [ -z "${CHROME_DEVTOOLS_AXI_SESSION:-}" ] || HOME=$real_home timeout 20 chrome-devtools-axi stop >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for _ in $(seq 1 50); do
  if grep -Eoq 'http://127\.0\.0\.1:[0-9]+' "$work/serve.log"; then break; fi
  sleep 0.1
done
url=$(grep -Eo 'http://127\.0\.0\.1:[0-9]+' "$work/serve.log" | head -n1)
[ -n "$url" ] || { echo "serve did not print a URL: $(cat "$work/serve.log")" >&2; exit 1; }
export HOME=$real_home CHROME_DEVTOOLS_AXI_SESSION=tickets-plain-$$
unset XDG_DATA_HOME TMPDIR || true
chrome-devtools-axi selectpage 1 >/dev/null 2>&1 || true
for theme in light dark; do
  chrome-devtools-axi emulate --viewport 390x844x1 --color-scheme "$theme" >/dev/null
  chrome-devtools-axi open "$url#ticket/$tid" >/dev/null
  chrome-devtools-axi wait 'Umer plain words' >/dev/null
  chrome-devtools-axi eval 'JSON.stringify({ text: document.body.innerText })' | tee "$evidence/tickets-390-$theme.txt" >/dev/null
  chrome-devtools-axi screenshot "$evidence/tickets-390-$theme.png" >/dev/null
  grep -qi juggernaut "$evidence/tickets-390-$theme.txt" || { echo "the $theme capture does not show the project juggernaut" >&2; cat "$evidence/tickets-390-$theme.txt" >&2; exit 1; }
  if grep -Eqi 'truncated|data/umer|herdr' "$evidence/tickets-390-$theme.txt"; then echo "the $theme capture shows a truncation tail, a file path or the home name" >&2; exit 1; fi
done
stat -c '%n %s' "$evidence"/tickets-390-*.png | tee "$evidence/shots.ls"
jq -n --arg version "$ver" --arg url "$url" \
  '{target:{version:$version,board:$url},start:"A disposable Juggernaut home has one backlog row from the internal home herdr whose store title ends in a truncation tail and a data/ file path.",steps:["Install this checkout'\''s tickets-sync into a throwaway XDG and run the watcher check.","Confirm the ticket JSON carries the project juggernaut and the title Umer plain words.","Serve the board with sign-off-axi and open the ticket at 390px in light and dark."],result:"Each ticket capture shows the ticket under the project juggernaut with the plain one-line title Umer plain words, and no truncation tail, file path or home name."}' \
  > "$evidence/steps.json"
printf 'PASS: tickets plain board shows the project and a plain one-line title on the real sign-off Tickets tab\n'
