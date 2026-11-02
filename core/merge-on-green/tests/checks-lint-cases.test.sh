#!/usr/bin/env bash
# E2E: the merge gate's Checks-block decision, driven through the real lint (jg-checks-lint.sh) on a corpus of
# pull requests, one per decision branch. Each case in checks-lint-cases.json carries the verdict and reason the
# lint gave when its rules were shell code; the rules now live in policy/gate/checks_lint.rego and
# policy/gate/rules.json, and this test holds them to those recorded decisions.
# Usage: tests/checks-lint-cases.test.sh          check every case against its recorded decision
#        RECORD=1 tests/checks-lint-cases.test.sh  re-record the decisions (only after a deliberate rule change)
# Needs opa and go (the guard host evaluates the policy); with either absent the test skips.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
CASES=${CHECKS_LINT_CASES:-$ROOT/core/merge-on-green/tests/checks-lint-cases.json}
LINT=${CHECKS_LINT:-$ROOT/core/merge-on-green/jg-checks-lint.sh}
# shellcheck source=lib/policy-test-env.sh
[ -n "${RECORD:-}" ] || . "$ROOT/core/lib/policy-test-env.sh"
d=$(mktemp -d "${TMPDIR:-/tmp}/checks-lint-cases.XXXXXX")
trap 'rm -rf -- "$d"' EXIT
unset GIT_DIR GIT_WORK_TREE
export HOME=$d/home TMPDIR=$d
mkdir -p "$HOME" "$d/bin"
# The pull request and its API calls come from the case file; every API call but `pr view` fails, so the size
# is read from the file list exactly as a PR with no reachable diff is.
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "pr view" ] && { cat "$CASE_PR_JSON"; exit 0; }
exit 1
EOF
chmod +x "$d/bin/gh"
export PATH="$d/bin:$PATH"

fails=0
n=$(jq '.cases | length' "$CASES")
out=$d/recorded.json
cp "$CASES" "$out"
for ((i = 0; i < n; i++)); do
  case_json=$(jq -c ".cases[$i]" "$CASES")
  name=$(jq -r .name <<<"$case_json")
  home=$d/c$i/home task=lane-$i
  mkdir -p "$home/state" "$home/config" "$home/data/$task" "$home/projects/repo"
  [ -z "$(jq -r .size_mode <<<"$case_json")" ] || jq -r .size_mode <<<"$case_json" > "$home/config/checks-size"
  while IFS= read -r skill; do
    [ -z "$skill" ] || mkdir -p "$home/projects/repo/.agents/skills/$skill"
  done < <(jq -r '.skills[]' <<<"$case_json")
  while IFS= read -r ename; do
    f=$home/data/$task/$ename
    mkdir -p "$(dirname "$f")"
    jq -j --arg n "$ename" '.evidence[$n].content' <<<"$case_json" > "$f"
    [ "$(jq -r --arg n "$ename" '.evidence[$n].old // false' <<<"$case_json")" != true ] || touch -d @1 "$f"
  done < <(jq -r '.evidence | keys[]' <<<"$case_json")
  while IFS=$'\t' read -r content by; do
    [ -n "$by" ] || continue
    [ "$by" != SELF ] || by=$task
    printf '%s %s\n' "$(printf '%b' "$content" | sha256sum | cut -d' ' -f1)" "$by" >> "$home/data/checks-gate.hashes"
  done < <(jq -r '.seen[] | [.content, .by] | @tsv' <<<"$case_json")
  jq -c --arg task "$task" '{author: {login: .author}, body: .body, title: .title, files: .files,
      headRefOid: "0123456789abcdef0123456789abcdef01234567", headRefName: ("fm/" + $task), baseRefOid: "base"}' <<<"$case_json" > "$d/c$i/pr.json"
  text=$(CASE_PR_JSON=$d/c$i/pr.json JG_HOME=$home "$LINT" https://github.com/owner/repo/pull/7 "$home/data/$task" 2>&1) && rc=0 || rc=$?
  line=$(printf '%s\n' "$text" | grep -E '^checks-lint: (PASS|FAIL)' | tail -n 1 | sed "s|$home|<HOME>|g")
  row=$(tail -n 1 "$home/data/checks-gate.log" 2>/dev/null | cut -f4,5 | tr '\t' ' ' | sed "s|$home|<HOME>|g")
  got=$(jq -cn --argjson rc "$rc" --arg line "$line" --arg row "$row" '{rc: $rc, line: $line, row: $row}')
  if [ -n "${RECORD:-}" ]; then
    jq --argjson i "$i" --argjson got "$got" '.cases[$i].expect = $got' "$out" > "$out.new" && mv "$out.new" "$out"
    continue
  fi
  want=$(jq -c ".cases[$i].expect" "$CASES")
  if [ "$got" = "$want" ]; then
    printf 'ok: %s\n' "$name"
  else
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
    fails=$((fails + 1))
  fi
done
if [ -n "${RECORD:-}" ]; then
  { echo '{"cases": ['; jq -c '.cases[]' "$out" | sed '$!s/$/,/'; echo ']}'; } > "$CASES"
  printf 'recorded %s cases\n' "$n"
  exit 0
fi
[ "$fails" -eq 0 ] && printf 'PASS: %s cases match their recorded decisions\n' "$n" && exit 0
printf 'FAIL: %s of %s cases differ from their recorded decisions\n' "$fails" "$n"
exit 1
