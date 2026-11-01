#!/usr/bin/env bash
# Run done-done's pinned merge-gate lint, or the Juggernaut lint when the pinned CLI is unavailable or the PR
# has more than one page (100 files) of changes for done-done's truncated file list to measure.
# Usage: JG_HOME=<home> checks-lint.sh <PR URL | report file> <evidence folder>
# A size-only FAIL from the pinned lint is handed to the feature lint instead: done-done hardcodes its 1,000-line
# limit with no config key, while the feature lint owns the size rule and config/checks-size, where the rule is
# advisory by default (captain, release c-1) and a refusal only when a home asks for one.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
[ "$#" -eq 2 ] && [ -n "${JG_HOME:-}" ] || { echo "usage: JG_HOME=<home> checks-lint.sh <PR URL | report file> <evidence folder>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
case "$1" in https://*) source=$1 ;; *) source=$(cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")") ;; esac
evidence=$(cd "$(dirname "$2")" && printf '%s/%s\n' "$PWD" "$(basename "$2")")
# Prefer the feature's lint (lane/meta task identity); JG_LEGACY_CHECKS_LINT overrides.
if [ -n "${JG_LEGACY_CHECKS_LINT:-}" ]; then
  LEGACY=$JG_LEGACY_CHECKS_LINT
elif [ -x "$SRC/jg-checks-lint.sh" ]; then
  LEGACY=$SRC/jg-checks-lint.sh
else
  LEGACY=${JG_MAIN_HOME:-$HOME/juggernaut}/config/jg-checks-lint.sh
fi
DD_HOME=$JG_HOME/data/done-done-lint
DD=(npx --yes --quiet --package=done-done-axi@0.6.17 done-done)
if [ -n "${JG_DONE_DONE_BIN:-}" ]; then DD=("$JG_DONE_DONE_BIN"); fi

# Pin the released CLI: older installed done-done binaries do not have the config keys.
if ! command -v "${DD[0]}" >/dev/null 2>&1 || ! "${DD[@]}" lint --help 2>/dev/null | grep -q 'checks.generated_paths:'; then
  exec "$LEGACY" "$source" "$evidence"
fi

# done-done's lint lists at most 100 changed files, so it measures a PR only when the whole change fits
# one page. Ask the PR object for the real count and hand a bigger or uncountable PR to the feature gate,
# which reads every pull-files page: a truncated list must never become the measurement (Juggernaut fold,
# 408 files). A local report file has no file list to truncate, so it keeps this path.
if [[ "$source" == https://* ]]; then
  changed=
  if command -v gh >/dev/null 2>&1; then
    nwo=$(printf '%s' "$source" | sed -nE 's#^https://github\.com/([^/]+)/([^/]+)/pull/([^/?#]+).*#\1/\2/pulls/\3#p')
    [ -z "$nwo" ] || changed=$(gh api "repos/$nwo" --jq '.changed_files' 2>/dev/null)
  fi
  if ! [[ "$changed" =~ ^[0-9]+$ ]] || [ "$changed" -gt 100 ]; then
    exec "$LEGACY" "$source" "$evidence"
  fi
fi

mkdir -p "$DD_HOME" "$JG_HOME/data" || exit 2
d=$(mktemp -d) || exit 2
trap 'rm -rf -- "$d"' EXIT
# Lint reads repo config and verify-skill presence from cwd. Keep its config isolated from the real checkout.
cp "$SRC/.done-done.yaml" "$d/.done-done.yaml"
repo=$(printf '%s' "$source" | sed -nE 's#https://github\.com/[^/]+/([^/]+)/pull/.*#\1#p')
skills=${JG_HOME}/projects/${repo}/.agents/skills
if [ -d "$skills" ]; then mkdir -p "$d/.agents" && ln -s "$skills" "$d/.agents/skills"; fi

# Frame-reuse identity is the lane (meta pr= or data/<task>), not the PR branch tip.
lane_task=
if [[ "$source" == https://* ]]; then
  for meta in "$JG_HOME"/state/*.meta; do
    [ -f "$meta" ] || continue
    grep -Fxq "pr=$source" "$meta" || continue
    lane_task=${meta##*/}; lane_task=${lane_task%.meta}
    break
  done
fi
if [ -z "$lane_task" ]; then
  case "$evidence" in
    "$JG_HOME"/data/*)
      rest=${evidence#"$JG_HOME"/data/}
      case "$rest" in ''|*/*) ;; *) lane_task=$rest ;; esac
      ;;
  esac
fi
lint_path=$PATH
if [ -n "$lane_task" ] && real_gh=$(command -v gh 2>/dev/null); then
  mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  out=$("$JG_CHECKS_REAL_GH" "$@") || { ec=$?; printf '%s' "$out"; exit "$ec"; }
  printf '%s' "$out" | python3 -c 'import json,os,sys; p=json.load(sys.stdin); p["headRefName"]=os.environ["JG_CHECKS_LANE_TASK"]; json.dump(p, sys.stdout)'
  exit 0
fi
exec "$JG_CHECKS_REAL_GH" "$@"
GHEOF
  chmod +x "$d/bin/gh"
  export JG_CHECKS_REAL_GH=$real_gh JG_CHECKS_LANE_TASK=$lane_task
  lint_path=$d/bin:$PATH
fi

set +e
out=$(cd "$d" && PATH="$lint_path" DONE_DONE_HOME="$DD_HOME" "${DD[@]}" lint "$source" "$evidence" 2>&1)
rc=$?
row=$(tail -n 1 "$DD_HOME/lint.log" 2>/dev/null || true)
logged_src=$(printf '%s' "$row" | cut -f2)
head=$(printf '%s' "$row" | cut -f3)
verdict=$(printf '%s' "$row" | cut -f4)
why=$(printf '%s' "$row" | cut -f5-)
[ "$logged_src" = "$source" ] || { echo "checks-lint: FAIL: done-done produced no matching lint record: $out"; exit 1; }
mkdir -p "$JG_HOME/data"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$source" "$head" "$verdict" "$why" >> "$JG_HOME/data/checks-gate.log"
# Size is advice unless config/checks-size says refuse: re-run the feature lint, which prints the size and its
# advisory line, checks the remaining rules, and exits on those alone. Its row is newer, so it is this head's verdict.
if [ "$rc" -ne 0 ] && printf '%s' "$why" | grep -Eq '^[0-9]+ added non-generated lines \(moved lines excluded\): split it \(limit [0-9]+\)$'; then
  exec "$LEGACY" "$source" "$evidence"
fi
receipt_verdict=FAIL
[ "$rc" -ne 0 ] || receipt_verdict=PASS
if [ "$rc" -eq 0 ]; then
  printf 'checks-lint: PASS: %s\n' "$why"
else
  printf 'checks-lint: FAIL: %s\n' "${why:-$out}"
fi
# Match the legacy lint's completion-receipt side effect for either verdict.
for meta in "$JG_HOME"/state/*.meta; do
  [ -f "$meta" ] && grep -Fxq "pr=$source" "$meta" || continue
  task=${meta##*/}; task=${task%.meta}
  helper=${JG_ADDONS_DIR:-$(cd "$SRC/.." && pwd -P)}/receipts/bin/jg-run-receipt.sh
  if [ -x "$helper" ]; then
    report=$(mktemp) || exit 1
    printf 'checks-lint %s %s head %s: %s\n' "$receipt_verdict" "$source" "$head" "${why:-$out}" > "$report"
    worktree=$(awk -F= '$1 == "worktree" { value = $2 } END { print value }' "$meta")
    receipt=$(env JG_HOME="$JG_HOME" "$helper" "$task" "$receipt_verdict" "$report" "${worktree:-$JG_HOME}" 2>&1); receipt_rc=$?
    [ "$receipt_rc" -eq 0 ] || echo "checks-lint: receipt not published: ${receipt:-jg-run-receipt.sh failed}" >&2
    rm -f -- "$report"
  fi
  break
done
exit "$rc"
