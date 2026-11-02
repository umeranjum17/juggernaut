#!/usr/bin/env bash
# The daily token retro check: the off switch silences it, an older lfm without
# tokens mode stays silent, a missing day starts one background retro and lands
# its report only when complete, a week-over-week change past the threshold is
# reported once, a smaller one never, and arm/disarm bind and remove the shim.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(jg_test_tmproot jg-tokens-retro)
home="$WORK/home"
mkdir -p "$home/config" "$home/state" "$home/data" "$WORK/bin"
# Stand-in lfm: `tokens --help` answers when tokens mode exists, and
# `tokens retro --out <dir>` writes the tokens_per_day in $WORK/per-day.
cat >"$WORK/bin/lfm" <<'EOF'
#!/usr/bin/env bash
[ "$1" = tokens ] || exit 2
[ -e "$FAKE_LFM_DIR/no-tokens" ] && exit 2
[ "$2" = --help ] && exit 0
out=${!#}
mkdir -p "$out"
printf '{"total":9000,"requests":30,"metrics":{"tokens_per_day":%s.4,"floor_tokens_median":50000.2,"ctx_over_200k_share":0.4}}\n' "$(cat "$FAKE_LFM_DIR/per-day")" >"$out/tokens.json"
printf 'tokens report\n' >"$out/tokens.txt"
EOF
chmod 755 "$WORK/bin/lfm"
export FAKE_LFM_DIR=$WORK
check() { JG_HOME="$home" JG_TOKENS_RETRO_LFM="$WORK/bin/lfm" "$ROOT/bin/jg-tokens-retro.sh" check; }
today=$(date -u +%F)
out_dir="$home/data/tokens-retro"
wait_for() { for _ in $(seq 50); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }

echo 1000 >"$WORK/per-day"
touch "$home/config/token-saver-off"
[ -z "$(check)" ] || fail "the off switch must keep the check silent"
[ ! -e "$out_dir" ] || fail "the off switch must not start a retro"
rm "$home/config/token-saver-off"
pass "config/token-saver-off turns the check off"

touch "$WORK/no-tokens"
[ -z "$(check)" ] || fail "an lfm without tokens mode must stay silent"
[ ! -e "$out_dir/$today" ] || fail "an lfm without tokens mode must not write a report"
rm "$WORK/no-tokens"
pass "an lfm older than tokens mode stays silent"

[ -z "$(check)" ] || fail "starting a retro must be silent"
wait_for "$out_dir/$today/tokens.json" || fail "the background retro never landed today's report"
wait_for_gone() { for _ in $(seq 50); do [ ! -e "$1" ] && return 0; sleep 0.1; done; return 1; }
wait_for_gone "$out_dir/.$today.running" || fail "a finished retro must release its lock"
pass "a missing day starts one background retro that lands a complete report"

check >/dev/null
[ "$(sed -n 2p "$out_dir/per-call.tsv" | cut -f1,4,5,6)" = "$(printf '%s\t300\t50000\t40' "$today")" ] || fail "per-call row wrong: $(cat "$out_dir/per-call.tsv")"
check >/dev/null
[ "$(wc -l <"$out_dir/per-call.tsv")" = 2 ] || fail "a day must add one per-call row only"
JG_HOME="$home" "$ROOT/bin/jg-tokens-retro.sh" show | grep -q tokens_per_call || fail "show must print the per-call record"
pass "each day records tokens per call once and show prints it"

week_ago=$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F)
mkdir -p "$out_dir/$week_ago"
printf '{"metrics":{"tokens_per_day":1300}}\n' >"$out_dir/$week_ago/tokens.json"
line=$(check)
case $line in "tokens per day 1000 vs 1300 a week earlier (-23%); report: $out_dir/$today/tokens.txt") ;;
  *) fail "a 23% drop must be reported in one line, got: $line" ;; esac
[ -z "$(check)" ] || fail "the same change must be reported only once"
pass "a week-over-week change past the threshold is reported once"

rm -f "$out_dir/$today/.reported"
printf '{"metrics":{"tokens_per_day":1100}}\n' >"$out_dir/$week_ago/tokens.json"
[ -z "$(check)" ] || fail "a 9% change is under the 20% threshold"
pass "a change under the threshold is not reported"

JG_HOME="$home" "$ROOT/bin/jg-tokens-retro.sh" arm | grep -qx 'armed: state/tokens-retro.check.sh' || fail "arm did not report the shim"
[ -x "$home/state/tokens-retro.check.sh" ] && [ -f "$home/state/tokens-retro.check-trust" ] || fail "arm must write and register the shim"
grep -qF 'jg-tokens-retro.sh check' "$home/state/tokens-retro.check.sh" || fail "the shim must run the check"
JG_HOME="$home" "$ROOT/bin/jg-tokens-retro.sh" disarm >/dev/null
[ ! -e "$home/state/tokens-retro.check.sh" ] && [ ! -e "$home/state/tokens-retro.check-trust" ] || fail "disarm must remove the shim and its binding"
[ -f "$out_dir/$today/tokens.json" ] || fail "disarm must keep the reports"
pass "arm binds the watcher check shim and disarm removes it"
