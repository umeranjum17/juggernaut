#!/usr/bin/env bash
# Same-lane follow-up PR may reuse its own earlier frames; cross-task reuse must still fail.
# Task identity comes from lane meta / data/<task>, not the PR branch tip name.
# The proof line's verify skill comes from the repository under test, never from the folder the lint runs
# from: a repo with a verify skill refuses the phrase "no verify skill" and passes when it is named, and a
# repo without one passes the phrase.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
LINT=$ROOT/merge-on-green/jg-checks-lint.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/fm/state" "$d/fm/data/lane-alpha" "$d/fm/data/lane-beta" "$d/bin"
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d PATH="$d/bin:$PATH" JG_HOME=$d/fm
mkdir -p "$HOME" "$XDG_DATA_HOME"

printf 'frame-alpha\n' > "$d/fm/data/lane-alpha/shot.png"
printf 'frame-beta-other\n' > "$d/fm/data/lane-beta/other.png"
# First claim: local report under the lane folder records hashes as lane-alpha.
cat > "$d/fm/data/lane-alpha/report.md" <<'EOF'
## Checks
outcome: lane recorded its own frame
repro: n/a: no bug
proof: no verify skill - bash fixture
evidence: shot.png
EOF
"$LINT" "$d/fm/data/lane-alpha/report.md" "$d/fm/data/lane-alpha" >/dev/null
grep -Eq ' lane-alpha$' "$d/fm/data/checks-gate.hashes" || {
  echo "FAIL: expected hash owner lane-alpha; got: $(cat "$d/fm/data/checks-gate.hashes")" >&2
  exit 1
}

# Follow-up PR from the same lane: branch tip name differs from the lane folder.
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view'*)
    case "$3" in
      *pull/2) name=lane-alpha-pr2 ;;
      *pull/3) name=totally-other-branch ;;
      *) echo "unexpected pr: $3" >&2; exit 2 ;;
    esac
    printf '%s\n' "{\"author\":{\"login\":\"umer\"},\"body\":\"## Checks\\noutcome: follow-up reuses lane frames\\nrepro: n/a: no bug\\nproof: no verify skill - bash fixture\\nevidence: shot.png\\n\",\"title\":\"feat: follow-up\",\"files\":[{\"path\":\"a.txt\",\"additions\":1}],\"headRefOid\":\"abc\",\"headRefName\":\"fm/$name\",\"baseRefOid\":\"base\"}"
    ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/gh"
printf 'pr=https://github.com/owner/repo/pull/2\nbranch=fm/lane-alpha-pr2\n' > "$d/fm/state/lane-alpha.meta"

set +e
same=$(JG_HOME=$d/fm "$LINT" 'https://github.com/owner/repo/pull/2' "$d/fm/data/lane-alpha" 2>&1)
same_rc=$?
set -e
[ "$same_rc" -eq 0 ] && [[ "$same" == *'checks-lint: PASS:'* ]] || {
  echo "FAIL same-lane follow-up should PASS: rc=$same_rc ($same)" >&2
  exit 1
}
echo "PASS same-lane follow-up reuses its own frames"

# True cross-task reuse: another lane cites the same bytes.
cp "$d/fm/data/lane-alpha/shot.png" "$d/fm/data/lane-beta/shot.png"
printf 'pr=https://github.com/owner/repo/pull/3\n' > "$d/fm/state/lane-beta.meta"
cat > "$d/fm/data/lane-beta/report.md" <<'EOF'
## Checks
outcome: other lane steals the frame
repro: n/a: no bug
proof: no verify skill - bash fixture
evidence: shot.png
EOF
set +e
cross=$(JG_HOME=$d/fm "$LINT" 'https://github.com/owner/repo/pull/3' "$d/fm/data/lane-beta" 2>&1)
cross_rc=$?
set -e
[ "$cross_rc" -ne 0 ] && [[ "$cross" == *'every evidence file was already used by another PR'* ]] || {
  echo "FAIL cross-task reuse should FAIL: rc=$cross_rc ($cross)" >&2
  exit 1
}
echo "PASS cross-task reuse still fails"
echo 'PASS: lane-task frame-reuse identity'

# The verify skill belongs to the repository under test, not to the caller's folder. Two fixture homes:
# one clones a repo that has a verify skill, the other a repo that has none, and the lint is run from a
# third folder that has its own verify skill to prove the caller cannot decide the verdict.
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view'*)
    id=${3##*/}
    printf '%s\n' "{\"author\":{\"login\":\"umer\"},\"body\":\"$(cat "$STUB_BODY")\",\"title\":\"feat: proof line\",\"files\":[{\"path\":\"a.txt\",\"additions\":1}],\"headRefOid\":\"sha-$id\",\"headRefName\":\"fm/lane-x\",\"baseRefOid\":\"base\"}"
    ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/gh"
export STUB_BODY=$d/body.txt
mkdir -p "$d/fm2/state" "$d/fm2/data/lane-x" "$d/fm2/projects/widget/.agents/skills/verify-widget" \
  "$d/fm2/projects/plainwidget" "$d/caller/.agents/skills/verify-caller"
printf 'frame\n' > "$d/fm2/data/lane-x/proof.txt"
printf -- '---\nname: verify-widget\n---\n' > "$d/fm2/projects/widget/.agents/skills/verify-widget/SKILL.md"
printf -- '---\nname: verify-caller\n---\n' > "$d/caller/.agents/skills/verify-caller/SKILL.md"
proof_case() { # <pr id> <proof line> <expected rc> <expected text> <label>
  printf '## Checks\\noutcome: proof-line fixture\\nrepro: n/a: no bug\\nproof: %s\\nevidence: proof.txt\\n' "$2" > "$STUB_BODY"
  set +e
  out=$(cd "$d/caller" && JG_HOME=$d/fm2 "$LINT" "https://github.com/owner/$1/pull/$3" "$d/fm2/data/lane-x" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq "$4" ] && [[ "$out" == *"$5"* ]]; then
    echo "PASS $6"
  else
    echo "FAIL $6: rc=$rc want $4, want text [$5], got [$out]" >&2
    exit 1
  fi
}
proof_case widget  'no verify skill - bash fixture'                        10 1 'does not name the verify skill this repository has (verify-widget)' 'a repo with a verify skill refuses the phrase "no verify skill"'
proof_case widget  'verify-widget: bash widget/test.sh, green'             11 0 'checks-lint: PASS:' 'a repo with a verify skill passes when that skill is named'
proof_case plainwidget 'no verify skill - bash fixture'                    12 0 'checks-lint: PASS:' 'a repo with no verify skill passes the phrase'
echo 'PASS: the proof line reads the verify skill of the repository under test, not the caller folder'

