#!/usr/bin/env bash
# A busy contribution history must settle through the registered watcher check.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

H=$(jg_test_tmproot jg-contributions)
mkdir -p "$H/"{config,data,state,projects,fakebin,home,tmp} "$H/state/.watch-check-failures"
export JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
  HOME="$H/home" XDG_CONFIG_HOME="$H/home/config" XDG_DATA_HOME="$H/home/data" TMPDIR="$H/tmp" \
  PATH="$H/fakebin:$PATH" JG_CHECK_TIMEOUT=30 JG_SIGNAL_GRACE=0 JG_HEARTBEAT=999999
printf 'off\n' > "$H/config/wake-bus"
printf 'now check *zz-sweep-complete.check.sh *\n' > "$H/config/wake-routing"
cat > "$H/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
touch "$JG_HOME/unexpected-forge-read"
exit 1
EOF
chmod +x "$H/fakebin/gh"

mkdir -p "$H/data/"jg-row-{1..900} "$H/data/jg-shared"
record=$(jq -cn '{kind:"pr",checked_at:"2026-11-01T00:00:00Z",error:null,pending:[],seen:[],notified:[],
  observation:{head:("a"*40),state:"merged",draft:false,mergeable:"unknown",can_merge:true,
  review_decision:"",reviews:[],events:[],checks:[range(12) | {
    name:"CI required",id:.,status:"completed",conclusion:"success",started_at:"2026-11-01T00:00:00Z"}]}}')
url=https://github.com/demo-org/demo/pull
for i in {1..900}; do
  printf '{"schema":"jg-contributions.v1","task":"jg-row-%s","records":[{"url":"%s/%s",%s]}\n' \
    "$i" "$url" "$i" "${record#\{}" > "$H/data/jg-row-$i/contributions.json"
done
jq -c '.task="jg-shared" | .records[0] |=
  (.observation.state="open" | .error="old forge error" | .pending=[{token:"keep-me"}])' \
  "$H/data/jg-row-900/contributions.json" > "$H/data/jg-shared/contributions.json"
printf 'kind=ship\npr=%s/900\n' "$url" > "$H/state/jg-new-owner.meta"
printf '1 fixture\n' > "$H/state/.watch-check-failures/contributions"

bash "$ROOT/bin/jg-contributions.sh" arm >/dev/null
printf '#!/usr/bin/env bash\nprintf "fixture sweep complete\\n"\n' > "$H/state/zz-sweep-complete.check.sh"
chmod 700 "$H/state/zz-sweep-complete.check.sh"
bash "$ROOT/bin/jg-check-register.sh" zz-sweep-complete >/dev/null

start=$SECONDS
bash "$ROOT/bin/jg-watch-arm.sh" > "$H/watcher.log" 2>&1 \
  || fail "watcher did not complete the sweep: $(cat "$H/watcher.log")"
grep -q 'fixture sweep complete' "$H/watcher.log" || fail "watcher did not run the completion check"
[ ! -e "$H/state/.watch-check-failures/contributions" ] \
  || fail "contributions failed during the sweep: $(cat "$H/state/.watch-check-failures/contributions")"
[ ! -e "$H/unexpected-forge-read" ] || fail "a final contribution reached the forge"
jq -e '.records[0] | .observation.state == "merged" and .error == null and .pending[0].token == "keep-me"' \
  "$H/data/jg-shared/contributions.json" >/dev/null || fail "existing owner did not retain its pending signal"
jq -e '.records[0] | .observation.state == "merged" and .error == null and .pending == []' \
  "$H/data/jg-new-owner/contributions.json" >/dev/null || fail "new owner did not inherit the final observation"
pass "the registered contributions check cleared its failure streak and settled both owners across 900 final records with zero forge reads (watcher sweep: $((SECONDS - start))s)"
