#!/usr/bin/env bash
# jg-3uo: a Claude worker parked behind the "Autocompact at N tokens" offer is
# freed by the real watcher with the offer's own Esc. The pane is a fake Claude
# on a private tmux server: it paints the offer text taken from the installed
# 2.1.330 binary (not yet a live capture), then reads one key. Esc must reach it
# once; a pane that only mentions the sentence in scrollback must get no key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
TMP_ROOT=$(jg_test_tmproot jg-autocompact-offer)
LAB=$("$ROOT/bin/jg-lab-home.sh" create "$TMP_ROOT/home")
TMUX_TMPDIR=$("$ROOT/bin/jg-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR
WATCHER=
cleanup_lab() {
  [ -z "$WATCHER" ] || kill "$WATCHER" 2>/dev/null
  tmux kill-server 2>/dev/null
  "$ROOT/bin/jg-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
}
trap 'cleanup_lab; jg_test_cleanup' EXIT

OFFER="$TMP_ROOT/offer.sh"
cat > "$OFFER" <<'EOS'
#!/usr/bin/env bash
# $1 = offer | scrollback; prints what Claude would, then waits for one key.
clear
if [ "$1" = scrollback ]; then
  echo "Want to autocompact at 150000 tokens instead? Your model doesn't change. Switch back any time with /autocompact."
  for i in $(seq 1 30); do echo "worker output line $i"; done
else
  echo '● working'
  echo '│ Autocompact at 150,000 tokens'
  echo "│ Want to autocompact at 150000 tokens instead? Your model doesn't change."
  echo '│ Switch back any time with /autocompact.'
fi
IFS= read -rsn1 -t 40 key
[ "$key" = $'\033' ] && echo KEY-ESC || echo "KEY-OTHER-$key"
sleep 60
EOS
chmod +x "$OFFER"

run_case() {  # <name> <mode>
  local name=$1 mode=$2 w=jglab:$1
  if tmux has-session -t jglab 2>/dev/null; then
    tmux new-window -d -t jglab -n "$name" "$OFFER $mode"
  else
    tmux new-session -d -s jglab -n "$name" -x 120 -y 40 "$OFFER $mode"
  fi
  printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nhome=%s\nharness=claude\nkind=operator\nmode=ship\nyolo=off\nbackend=tmux\n' \
    "$w" "$name" "$TMP_ROOT" "$LAB" > "$LAB/state/$name.meta"
  printf 'working [at=%s]: fixture\n' "$(date +%s)" > "$LAB/state/$name.status"
}
screen() { tmux capture-pane -p -t "jglab:$1" 2>/dev/null; }

run_case offer offer
run_case scroll scrollback
sleep 1
JG_HOME="$LAB" SIGN_OFF_HOME="$LAB/signoff" JG_POLL=2 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
  "$ROOT/bin/jg-watch.sh" > "$TMP_ROOT/watch.out" 2>&1 &
WATCHER=$!
for _ in $(seq 1 40); do screen offer | grep -q KEY-ESC && break; sleep 1; done
screen offer | grep -q 'KEY-ESC' || fail "the offer was not dismissed with Esc: $(screen offer) $(cat "$TMP_ROOT/watch.out") $(tail -3 "$LAB/state/.watch-triage.log" 2>&1)"
grep -qF 'dismissed claude autocompact offer' "$LAB/state/.watch-triage.log" || fail "the dismissal was not logged"
screen scroll | grep -q 'KEY-' && fail "a pane with the sentence only in scrollback got a key: $(screen scroll)"
pass "the watcher frees a Claude pane parked on the autocompact offer with one Esc and leaves scrollback echoes alone"
