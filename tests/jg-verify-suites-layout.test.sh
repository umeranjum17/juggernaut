#!/usr/bin/env bash
# jg-verify-suites-layout.test.sh - the verify skill holds one suite per file,
# so two lanes that each add a suite never edit one shared file.
#
# On 9 Nov five lanes were refused at landing for a conflict in the one skill
# file that held every suite, because each lane added its entry at the top of
# the same list. This suite checks the layout that removes that conflict, on the
# real skill folder, and replays two lanes that each add a suite:
#   1. SKILL.md holds no suite, and every suites/*.md is named in lowercase
#      words, starts with its `# <feature>` heading, names a command, and is
#      listed once by the index command SKILL.md gives.
#   2. In a lab repository holding the real skill folder and the real
#      inventory's entries for it, two lanes from one base each add a suite in
#      its own file. The merge is clean, SKILL.md and the inventory are
#      untouched, check 1 passes on the result, and the real
#      bin/jg-doc-audience-check.sh classifies both new files and resolves
#      every local link in the folder.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_REL=.agents/skills/done-done-verify-suites
INVENTORY_REL=docs/documentation-audiences.json

check_layout() {  # <skill dir> -> prints the first problem and returns 1
  local dir=$1 f name entries
  local -a listed
  [ -d "$dir/suites" ] || { echo "no suites/ folder in $dir"; return 1; }
  entries=$(grep -cE '^- .*\brun `' "$dir/SKILL.md")
  [ "$entries" -eq 0 ] || { echo "SKILL.md holds suite text ($entries entry lines); each suite belongs in its own suites/ file"; return 1; }
  for f in "$dir"/suites/*; do
    name=${f##*/}
    [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] || { echo "suite file name is not lowercase words joined by -: $name"; return 1; }
    head -n1 "$f" | grep -qE '^# [^ ]' || { echo "suite file does not start with its # heading: $name"; return 1; }
    grep -q '`' "$f" || { echo "suite file names no command: $name"; return 1; }
  done
  # The index command SKILL.md gives must list each suite file once.
  mapfile -t listed < <(cd "$dir" && grep -m1 '^# ' suites/*.md)
  [ "${#listed[@]}" -eq "$(find "$dir/suites" -type f | wc -l)" ] || { echo "index lists ${#listed[@]} of the suite files"; return 1; }
}

add_suite() {  # <repo> <branch> <slug> <title>: one lane adds one suite and commits
  local repo=$1 branch=$2 slug=$3 title=$4
  git -C "$repo" checkout -q -b "$branch" base
  printf '# %s\n\n%s\n' "$title" "$title: run \`bash tests/$slug.test.sh\`; it proves the lab case." \
    > "$repo/$SKILL_REL/suites/$slug.md"
  git -C "$repo" add "$SKILL_REL/suites/$slug.md"
  git -C "$repo" commit -qm "add the $slug suite"
}

# 1. The real skill folder.
out=$(check_layout "$ROOT/$SKILL_REL") || fail "real skill folder: $out"
pass "SKILL.md holds no suite; $(find "$ROOT/$SKILL_REL/suites" -type f | wc -l) suite files each have a heading and a command and are indexed"

# 2. Two lanes in a lab that holds the real skill folder and its inventory entries.
jg_git_identity
lab=$(jg_test_tmproot jg-verify-suites)/repo
mkdir -p "$lab/docs" "$lab/$(dirname "$SKILL_REL")"
cp -R "$ROOT/$SKILL_REL" "$lab/$SKILL_REL"
printf '# lab\n\n[Setup](docs/setup.md)\n' > "$lab/README.md"
printf '# setup\n' > "$lab/docs/setup.md"
python3 -I - "$ROOT" "$lab" "$SKILL_REL/" "$INVENTORY_REL" <<'PY' || fail "could not build the lab inventory"
import json, os, re, shutil, sys
root, lab, folder, inventory = sys.argv[1:]
# A link target outside the skill folder is copied untracked, so the check
# resolves it without classifying it; a missing target stays missing.
for base, _, names in os.walk(os.path.join(root, folder)):
    for name in names:
        if not name.endswith(".md"):
            continue
        text = open(os.path.join(base, name), encoding="utf-8").read()
        for link in re.findall(r"\]\(([^)#\s]+)", text):
            if "://" in link or link.startswith("/"):
                continue
            target = os.path.normpath(os.path.join(base, link))
            rel = os.path.relpath(target, root)
            if rel.startswith("..") or rel.startswith(folder) or not os.path.isfile(target):
                continue
            os.makedirs(os.path.dirname(os.path.join(lab, rel)), exist_ok=True)
            shutil.copyfile(target, os.path.join(lab, rel))
src, dst = os.path.join(root, inventory), os.path.join(lab, inventory)
data = json.load(open(src, encoding="utf-8"))
data["surfaces"] = [s for s in data["surfaces"] if s["path"].startswith(folder)]
data["surfaces"] += [{"path": "README.md", "audience": "public-product"},
                     {"path": "docs/setup.md", "audience": "operator-current"}]
data["readmeSetupTargets"] = ["docs/setup.md"]
data["requiredOwnerPointers"] = [{"source": folder + "SKILL.md", "target": folder + "features/README.md"}]
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2)
PY
git -C "$lab" init -q -b main
git -C "$lab" add README.md docs "$SKILL_REL"
git -C "$lab" commit -qm base
git -C "$lab" branch base
add_suite "$lab" lane-a lab-suite-alpha 'Lab suite alpha'
add_suite "$lab" lane-b lab-suite-beta 'Lab suite beta'
git -C "$lab" checkout -q main
git -C "$lab" merge -q --no-edit lane-a || fail "lane a did not merge"
merge_out=$(git -C "$lab" merge --no-edit lane-b 2>&1) || fail "two lanes that each add a suite conflict: $merge_out"
pass "two lanes that each add a suite in its own file merge cleanly"

changed=$(git -C "$lab" diff --name-only base main)
[ "$changed" = "$SKILL_REL/suites/lab-suite-alpha.md
$SKILL_REL/suites/lab-suite-beta.md" ] || fail "adding two suites changed more than their own files: $changed"
out=$(check_layout "$lab/$SKILL_REL") || fail "merged lab skill folder: $out"
index=$(cd "$lab/$SKILL_REL" && grep -m1 '^# ' suites/*.md)
case $index in *'# Lab suite alpha'*'# Lab suite beta'*) ;; *) fail "index does not list both new suites" ;; esac
pass "the merge touches only the two suite files, and the index lists both"

audience_out=$("$ROOT/bin/jg-doc-audience-check.sh" --root "$lab" 2>&1) || fail "audience check on the merged lab: $audience_out"
pass "the audience check classifies both new suite files by their folder entry and resolves every link: $audience_out"
