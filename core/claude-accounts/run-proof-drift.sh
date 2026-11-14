#!/usr/bin/env bash
# run-proof-drift.sh: the account drift proof for done-done. A throwaway home with a pin and a by-model map, one idle lane recorded on
# the mapped account; the map is removed; one real `account-drift.sh tick` relaunches the lane (the lifecycle command is a recorder that
# does what a relaunch does to the record) and the lane records the pin's account. Then the same tick shows a busy lane waiting and a
# refused relaunch raising one alert. Captures keep lane names and account labels only.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$repo/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/config" "$work/home/state" "$work/pin" "$work/mapped" "$work/bin"
S=$work/home/state
cat >"$work/bin/control" <<X
#!/usr/bin/env bash
echo "control: \$*" >>"$work/log"
[ ! -e "$work/refuse" ] || { echo "error: no account is signed in" >&2; exit 1; }
. "$root/bin/jg-worker-account-lib.sh"
new=\$(jg_worker_account_resolve claude "$work/home/config" "\$(sed -n 's/^model=//p' "$S/\$1.meta")" | cut -f1)
sed -i "s|^account=.*|account=\$new|" "$S/\$1.meta"
X
printf '#!/usr/bin/env bash\necho "alert: $*" >>"%s/log"\n' "$work" >"$work/bin/alert"
chmod +x "$work/bin/control" "$work/bin/alert"
export JG_HOME=$work/home JG_DRIFT_CONTROL=$work/bin/control JG_DRIFT_ALERT=$work/bin/alert
label() { sed -e "s|$work/pin|<pin account>|g" -e "s|$work/mapped|<mapped account>|g" "$@"; }
lane() { printf 'harness=claude\nkind=ship\nmodel=claude-opus\naccount=%s\n' "$2" >"$S/$1.meta"; echo g1 >"$S/$1.busy-gen"
  echo "v1 gen=g1 seq=1 state=$3 source=claude-hook event=x ts=1" >"$S/$1.busy-state"; }
{
  echo "$work/pin" >"$work/home/config/claude-account"
  echo "claude-opus $work/mapped" >"$work/home/config/claude-account-by-model"
  lane lane-idle "$work/mapped" idle; lane lane-busy "$work/mapped" busy
  echo "== map selects the mapped account; tick moves nothing"
  bash "$repo/claude-accounts/bin/account-drift.sh" tick; { cat "$work/log" 2>/dev/null || true; } | label; echo "relaunches: $(grep -c control "$work/log" 2>/dev/null || echo 0)"
  echo "== the map is removed; the pin now selects"
  rm "$work/home/config/claude-account-by-model"
  bash "$repo/claude-accounts/bin/account-drift.sh" tick
  label "$work/log"; for l in lane-idle lane-busy; do echo "$l: $(label "$S/$l.meta" | grep ^account=)"; done
  echo "== the busy lane turns idle; the next tick moves it"
  echo "v1 gen=g1 seq=2 state=idle source=claude-hook event=x ts=2" >"$S/lane-busy.busy-state"
  bash "$repo/claude-accounts/bin/account-drift.sh" tick; echo "lane-busy: $(label "$S/lane-busy.meta" | grep ^account=)"
  echo "== a refused relaunch raises one alert, once"
  touch "$work/refuse"; echo "$work/mapped" >"$work/home/config/claude-account"
  lane lane-refused "$work/pin" idle
  bash "$repo/claude-accounts/bin/account-drift.sh" tick; bash "$repo/claude-accounts/bin/account-drift.sh" tick
  label "$work/log" | grep -E 'lane-refused'
  echo "== fixture test"
  bash "$root/tests/jg-account-drift.test.sh"
} >"$evidence/drift.txt" 2>&1
cat "$evidence/drift.txt"
jq -n --arg v "$(git -C "$root" rev-parse --short HEAD)" '{target: {version: ("account-drift.sh at " + $v)},
  start: "a home with a pin and a by-model map; one idle lane and one busy lane recorded on the mapped account",
  steps: ["remove the by-model map so the pin selects", "run one account-drift tick", "turn the busy lane idle and run the next tick",
    "make the home select an account whose relaunch is refused and run two ticks"],
  result: "the idle lane was relaunched and records the pin account, the busy lane moved at its next idle, and the refused relaunch raised one alert naming the lane and the account"}' >"$evidence/steps.json"
