#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
# Recursion guard: a quota read can never recurse through its own wrapper.
#
# The cycle this pins down, seen on a real machine as ~750 `quota-axi` processes and a load of 16:
#   quota-axi (the quota-axi-pool wrapper on PATH)
#     -> jg-model-pool pick -> claude-accounts-pick -> claude-accounts-quota.sh
#       -> `quota-axi` (the wrapper again) -> and round it goes.
# Both halves are fixed here. The reader must ask the real upstream, and the wrapper must refuse to
# delegate a call that is already inside one. Either half alone would hide the other in this test, so
# both are asserted separately: a future edit that drops one fails here instead of on the machine.
#
# Everything is a fixture: a stub upstream that records its callers, a stand-in pool tool that records
# its own invocation and exits, a fixture registry and a throwaway home. No network, no login folder.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
reader=$addons/claude-accounts/bin/claude-accounts-quota.sh
w=$(mktemp -d "${TMPDIR:-/tmp}/quota-axi-pool-recursion-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
# The wrapper installed the way wiring.sh installs it: a copy in jg-quota-axi-pool/, symlinked into
# a PATH dir as `quota-axi`. A bare copy under another name is not the shape anything ships.
install -d "$w/data/jg-quota-axi-pool" "$w/bin" "$w/real" "$w/home/config" "$w/home/state" "$w/acct"
install -m 755 "$addons/quota-axi-pool/bin/quota-axi-pool" "$w/data/jg-quota-axi-pool/quota-axi-pool"
ln -sfn "$w/data/jg-quota-axi-pool/quota-axi-pool" "$w/bin/quota-axi"
printf '%s\n' "$w/real/quota-axi" >"$w/upstream"
: >"$w/log-upstream"; : >"$w/log-pool"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
lines() { grep -c . "$1" 2>/dev/null || true; }

# The real upstream: records that it ran and answers one 80%/80% Claude account.
cat >"$w/real/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$w/log-upstream"
printf '%s\n' '{"providers":[{"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"five_hour","percentRemaining":80},{"id":"seven_day","percentRemaining":80}]}]}'
SH
chmod +x "$w/real/quota-axi"
# Stands in for jg-model-pool: records that the wrapper delegated (and at what depth) and exits, so a
# wrapper that wrongly delegates fails this test instead of starting the real cycle on this machine.
cat >"$w/bin/fake-pool" <<SH
#!/usr/bin/env bash
printf 'depth=%s\n' "\${JG_QUOTA_AXI_POOL_DEPTH:-unset}" >>"$w/log-pool"
exit 1
SH
chmod +x "$w/bin/fake-pool"

printf '{"version":1,"accounts":[{"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"%s"}]}\n' \
  "$w/acct" >"$w/registry.json"
printf 'command=%s\nstate=%s\n' "$w/bin/fake-pool" "$w/home/state" >"$w/home/config/account-pool"

# run_reader <extra PATH entry, "" for none> <recorded upstream file value>
run_reader() {
  : >"$w/log-upstream"; : >"$w/log-pool"; rm -f "$w/home/state/claude-accounts.json"
  out=$(env -i PATH="$w/bin${1:+:$1}:/usr/bin:/bin" HOME="$w" TMPDIR="$w" \
    JG_HOME="$w/home" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" \
    JG_CLAUDE_ACCOUNTS_SECONDS=5 JG_ACCOUNTS_PROVIDER=claude \
    JG_QUOTA_AXI_POOL_UPSTREAM="$2" JG_MODEL_POOL="$w/bin/fake-pool" \
    timeout 30 "$reader" 2>&1)
  rc=$?
}

# run_wrapper <depth value, "" to leave it unset>
run_wrapper() {
  : >"$w/log-upstream"; : >"$w/log-pool"
  if [ -n "$1" ]; then
    out=$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" JG_HOME="$w/home" \
      JG_QUOTA_AXI_POOL_UPSTREAM="$w/upstream" JG_MODEL_POOL="$w/bin/fake-pool" \
      JG_QUOTA_AXI_POOL_DEPTH="$1" timeout 15 "$w/bin/quota-axi" --json 2>&1)
  else
    out=$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" JG_HOME="$w/home" \
      JG_QUOTA_AXI_POOL_UPSTREAM="$w/upstream" JG_MODEL_POOL="$w/bin/fake-pool" \
      timeout 15 "$w/bin/quota-axi" --json 2>&1)
  fi
  rc=$?
}

# 1. The whole journey as it runs in the field: wrapper first on PATH, upstream only recorded.
run_reader "" "$w/upstream"
is "reader with the wrapper first on PATH finishes" "$rc" 0
is "the reader reached the real upstream" "$(lines "$w/log-upstream")" 1
is "the reader did not ask the wrapper (that is the cycle)" "$(lines "$w/log-pool")" 0
is "the reading carries the upstream's numbers" \
  "$(jq -r '.accounts[0] | "\(.five_hour.left)/\(.seven_day.left)"' "$w/home/state/claude-accounts.json" 2>/dev/null)" "80/80"

# 2. The wrapper's own guard: a call that is already inside the pool goes straight upstream.
run_wrapper 1
is "depth 1 wrapper call finishes" "$rc" 0
is "depth 1 never delegates to the pool again" "$(lines "$w/log-pool")" 0
is "depth 1 answers from the upstream" "$(lines "$w/log-upstream")" 1
is "depth 1 answers with the upstream's json" "$(jq -r '.providers[0].windows[0].percentRemaining' <<<"$out" 2>/dev/null)" 80

# 3. The control that makes 2 mean something: the same call without the depth variable does delegate,
#    and hands the delegated call depth 1, which is what stops the next one from doing the same.
run_wrapper ""
is "depth 0 wrapper call still uses the pool" "$(lines "$w/log-pool")" 1
is "the delegated call carries depth 1" "$(head -n 1 "$w/log-pool")" "depth=1"

# 4. The last-resort resolution when nothing recorded an upstream: PATH, with the wrapper skipped.
run_reader "$w/real" "$w/no-such-upstream-file"
is "reader still finishes with no recorded upstream" "$rc" 0
is "reader skipped the wrapper and took the real one on PATH" "$(lines "$w/log-upstream")" 1
is "reader never delegated on the PATH route either" "$(lines "$w/log-pool")" 0

[ "$fails" -eq 0 ] || { echo "FAIL: $fails assertions"; exit 1; }
echo "PASS: quota-axi-pool cannot recurse through its own pick"
exit 0
