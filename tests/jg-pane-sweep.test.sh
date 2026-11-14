#!/usr/bin/env bash
# Journey (ticket jg-7v6uw-s30): core/pane-sweep/sweep.sh run in a real isolated Herdr lab session.
#   a) a bare shell that no record names, first seen over 30 minutes ago, is closed and the line names its spawn-map task;
#   b) the same shell seen only just now stays, and is first-seen-stamped;
#   c) a pane a state/*.meta names stays, even when its sighting is old;
#   d) a pane that runs a process (the agent stand-in) stays, and its old sighting is forgotten;
#   e) a bare unrecorded shell in another workspace stays (only the home's own space is swept);
#   f) a second sweep is quiet and closes nothing more.
# Every Herdr call goes through the guarded lab helper; teardown proves the default session is unchanged.
# Usage: tests/jg-pane-sweep.test.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/jg-herdr-lab.sh}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HELPER" ] || { echo "skip: lab helper not executable at $HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr); ORIG_PATH=$PATH
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jg-pane-sweep.XXXXXX")
H=$TMP/home; FAKEBIN=$TMP/fakebin
mkdir -p "$FAKEBIN" "$H/state" "$H/config" "$H/data"
ln -sn "$ROOT/bin" "$H/bin"; ln -sn "$ROOT/core" "$H/core"
printf '%s\n' herdr > "$H/config/backend"
export JG_HERDR_LAB_STATE_DIR=$TMP/lab-state JG_HERDR_LAB_FLEET_HOME=$HOME
mkdir -m 700 "$JG_HERDR_LAB_STATE_DIR"
SESSION=$("$HELPER" name pane-sweep)
export HELPER SESSION REAL_HERDR ORIG_PATH
cleanup() { s=$?; env PATH="$ORIG_PATH" "$HELPER" teardown "$SESSION" || s=1; rm -rf "$TMP"; exit "$s"; }
trap cleanup EXIT
"$HELPER" provision "$SESSION" || fail 'could not provision the lab'

# The production adapter appends --session; this shim hands every call to the guarded helper instead.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$SESSION" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
for a in "$@"; do case "$a" in --session|--session=*) exit 9 ;; esac; done
if [ "${1:-}" = --version ]; then exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@" --session "$SESSION"; fi
exec env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"; }
sweep() { JG_HOME=$H JG_BACKEND=herdr HERDR_SESSION=$SESSION PATH="$FAKEBIN:$ORIG_PATH" JG_PANE_SWEEP_IDLE_S=1800 \
  "$ROOT/core/pane-sweep/sweep.sh" run "$H"; }

# The home's own workspace (label juggernaut) holds four panes; another workspace holds one more.
OWN=$(lab workspace create --cwd "$TMP" --label juggernaut --no-focus) || fail 'no own workspace'
P_OLD=$(jq -r '.result.root_pane.pane_id' <<<"$OWN")
split() { lab pane split "$1" --direction right --no-focus | jq -r '.result.pane.pane_id'; }
P_REC=$(split "$P_OLD") || fail 'split 1'
P_NEW=$(split "$P_OLD") || fail 'split 2'
P_RUN=$(split "$P_OLD") || fail 'split 3'
OTHER=$(lab workspace create --cwd "$TMP" --label somebody-else --no-focus) || fail 'no other workspace'
P_OTHER=$(jq -r '.result.root_pane.pane_id' <<<"$OTHER")
lab pane run "$P_RUN" 'sleep 3000' >/dev/null || fail 'could not start the agent stand-in'
printf 'window=%s:%s\nkind=ship\n' "$SESSION" "$P_REC" > "$H/state/recorded.meta"
printf '%s\t%s\t%s\t%s\n' "$TMP/copy" "$SESSION:$P_OLD" jg-fixture-task 1 > "$H/data/copy-tasks.tsv"
old=$(( $(date +%s) - 3600 ))
mkdir -p "$H/data/pane-sweep"
printf '%s\t%s\n' "$P_OLD" "$old" "$P_REC" "$old" "$P_RUN" "$old" "$P_OTHER" "$old" > "$H/data/pane-sweep/seen.tsv"
sleep 2   # let each shell settle at its prompt

out=$(sweep) || fail "sweep failed: $out"
present() { lab pane get "$1" >/dev/null 2>&1; }
present "$P_OLD" && fail "a: the old unrecorded shell survived: $out"
printf '%s\n' "$out" | grep -q "closed $SESSION:$P_OLD, a bare shell idle 60 minutes that no record names (spawned for jg-fixture-task)" \
  || fail "a: the close line is wrong: $out"
pass 'a: an unrecorded bare shell idle over 30 minutes is closed, and the line names the task that made it'
present "$P_NEW" || fail 'b: the fresh shell was closed'
awk -F'\t' -v p="$P_NEW" '$1 == p && $2 > 0 { f = 1 } END { exit !f }' "$H/data/pane-sweep/seen.tsv" || fail 'b: the fresh shell was not stamped'
pass 'b: a shell seen for the first time stays and is stamped'
present "$P_REC" || fail 'c: the recorded pane was closed'
pass 'c: a pane a record names stays'
present "$P_RUN" || fail 'd: the pane with a running process was closed'
! grep -q "^$P_RUN	" "$H/data/pane-sweep/seen.tsv" || fail 'd: the busy pane kept its old sighting'
pass 'd: a pane that runs a process stays and loses its sighting'
present "$P_OTHER" || fail 'e: a pane outside the home space was closed'
pass 'e: a pane in another workspace is never touched'
out2=$(sweep) || fail 'second sweep failed'
[ -z "$out2" ] || fail "f: the second sweep was not quiet: $out2"
for p in "$P_NEW" "$P_REC" "$P_RUN" "$P_OTHER"; do present "$p" || fail 'f: a pane went missing on the second sweep'; done
pass 'f: the second sweep is quiet and closes nothing more'
