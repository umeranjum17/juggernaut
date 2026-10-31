#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
JG_HOME=$TMP/home
mkdir -p "$JG_HOME"/{bin,state,config}
cat > "$JG_HOME/bin/jg-task-inbox-lib.sh" <<'SH'
jg_task_inbox_write_idempotent() {
  local state=$1 task=$2 body=$3 dir="$1/$2.inbox" file
  mkdir -p "$dir"
  file="$dir/$(printf '%s' "$body" | sha256sum | cut -c1-16).msg"
  for existing in "$dir"/*.msg "$dir/handled"/*.msg; do
    [ -f "$existing" ] || continue
    [ "$(jg_task_inbox_body "$existing")" != "$body" ] || { printf '%s' "$existing"; return; }
  done
  printf 'schema=jg-task-inbox.v1\n--\n%s' "$body" > "$file"
  printf '%s' "$file"
}
jg_task_inbox_body() { awk 'found { print } $0 == "--" { found=1 }' "$1"; }
jg_backend_of_meta() { echo fixture; }
jg_backend_target_of_meta() { echo fixture-target; }
jg_task_inbox_ring() { return 0; }
SH
cat > "$TMP/signoff" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
if [ "$1" = answers ]; then exit 99; fi
if [ "$1" = list ]; then
  printf '{"decisions":[{"key":"a","filer":"task-a"},{"key":"b","filer":"task-b"},{"key":"z","filer":"missing"},{"key":"f","filer":"finished"},{"key":"alt","filer":"alias"}]}'
else
  case " $* " in
    *' task-a '*) printf '{"deeper":[{"id":"req-a","key":"a","part":"intro","q":"A"}]}' ;;
    *' task-b '*) printf '{"deeper":[{"id":"req-b","key":"b","part":"intro","q":"B"}]}' ;;
    *' alias '*) printf '{"deeper":[{"id":"req-alt","key":"alt","part":"intro","q":"Override"}]}' ;;
    *' missing '*) printf '{"deeper":[{"id":"req-z","key":"z","part":"intro","q":"Z"}]}' ;;
    *) printf '{"deeper":[{"id":"req-f","key":"f","part":"intro","q":"F"}]}' ;;
  esac
fi
SH
chmod +x "$TMP/signoff"
printf 'kind=ship\n' > "$JG_HOME/state/task-a.meta"
printf 'kind=ship\n' > "$JG_HOME/state/task-b.meta"
printf 'kind=ship\n' > "$JG_HOME/state/finished.meta"
printf 'done [at=1]: finished\n' > "$JG_HOME/state/finished.status"
export JG_HOME SIGN_OFF_CLI="$TMP/signoff" JG_STATE_OVERRIDE="$JG_HOME/state" JG_CONFIG_OVERRIDE="$JG_HOME/config" CALL_LOG="$TMP/calls"
: > "$TMP/board.json"
"$ROOT/bin/jg-engage-route.sh" bind alias task-b
"$ROOT/bin/jg-engage-route.sh" dispatch "$TMP/board.json"
grep -q req-a "$JG_HOME/state/task-a.inbox/"*.msg
grep -q req-b "$JG_HOME/state/task-b.inbox/"*.msg
grep -q req-alt "$JG_HOME/state/task-b.inbox/"*.msg
[ ! -f "$JG_HOME/state/missing.inbox/request" ]
[ ! -f "$JG_HOME/state/finished.inbox/request" ]
grep -q $'req-f\tqueued\towner task finished is finished' "$JG_HOME/state/engage-route.log"
grep -q $'req-z\tqueued\tno owner record for filer missing' "$JG_HOME/state/engage-route.log"
if grep -q '^answers ' "$CALL_LOG"; then exit 1; fi
"$ROOT/bin/jg-engage-route.sh" dispatch "$TMP/board.json"
[ "$(find "$JG_HOME/state/task-a.inbox" -type f -name '*.msg' | wc -l)" -eq 1 ]
[ "$(find "$JG_HOME/state/task-b.inbox" -type f -name '*.msg' | wc -l)" -eq 2 ]
mkdir -p "$JG_HOME/state/task-a.inbox/handled"
first=$(find "$JG_HOME/state/task-a.inbox" -maxdepth 1 -name '*.msg' -print -quit)
mv "$first" "$JG_HOME/state/task-a.inbox/handled/"
"$ROOT/bin/jg-engage-route.sh" dispatch "$TMP/board.json"
grep -Fq $'req-a\towner-ack\ttask-a' "$JG_HOME/state/engage-route.log"
[ "$(find "$JG_HOME/state/task-a.inbox" -type f -name '*.msg' | wc -l)" -eq 1 ]
[ "$(awk -F '\t' '$1=="alias" {print $2}' "$JG_HOME/config/engage-owners")" = task-b ]
echo 'engage-route fixture journey passed'
