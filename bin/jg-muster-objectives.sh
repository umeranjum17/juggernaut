#!/usr/bin/env bash
# jg-muster-objectives.sh - run the objective journeys of a muster pack, and check the model's behaviour is in the code.
#
# Usage:
#   jg-muster-objectives.sh objectives <project> --base <ref> [--head <ref>] [--spec <slug> | --change <slug>]
#   jg-muster-objectives.sh code <project>
#
# objectives: <project> is a git repository. Its objectives are the Objectives table of each docs/specs/<slug>.md (one row per
#   journey: id, then kind `new` or `preserve`), or with --change <slug> the `- <id> (<kind>)` lines under `## Objectives` in
#   docs/changes/<slug>.md. The command of a journey is its `command:` in the journeys map of .done-done.yaml.
#   The base is the base ref's code with the head's journeys laid over it (the head's `.done-done.yaml` and `journeys/`),
#   because journeys are written before code. The head is the --head ref, or the project's working tree when --head is absent.
#   With no --head only the base half runs (before approval, when no code exists yet): the head column is empty and the base
#   condition decides alone. A journey passes the base condition when:
#     new       exit 1 and a first output line `assert: <name>`, so it fails on its named assertion;
#     preserve  exit 0.
#   With --head a journey must also exit 0 on the head. Exit 77 is a setup error and is never the expected failure.
#   Prints one line per journey, then `PASS` or `refused: objectives: <n> journey(s) break the rule`. Exit 0 on PASS, 1 on a
#   refusal, 2 on misuse.
# code: for each core object of docs/domain/model.md (`### <Name>` under `## Core objects`), every method named in its
#   `- Behaviour:` line (`name(args)` in backticks) must be defined in the module its `- Lives in:` line names. Prints
#   `PASS`, or one `refused: code: <Object>.<method> not found in <module>` line per miss. Exit 0 on PASS, 1 on a miss.
# The command only reads the project; journeys run in throwaway copies under a temporary folder.
set -u
export LC_ALL=C
JOURNEY_PATHS='.done-done.yaml journeys'   # the files that make up the journeys, laid over the base code

die() { printf 'jg-muster-objectives: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"; }

# Copy a ref of <project> into <dir>; the word WORKTREE copies the working tree as it stands (tracked and unignored files).
snapshot() {  # <project> <ref|WORKTREE> <dir>
  mkdir -p "$3" || return 1
  if [ "$2" = WORKTREE ]; then
    git -C "$1" ls-files -co --exclude-standard -z | (cd "$1" && xargs -0 -r cp --parents -t "$3")
  else
    git -C "$1" archive "$2" | tar -x -C "$3"
  fi
}

# The objectives, `id<TAB>kind` lines, of a project snapshot: the spec tables, or one change pack's list.
objectives_of() {  # <dir> <spec slug|-> <change slug|->
  local dir=$1 spec=$2 change=$3 f
  if [ "$change" != - ]; then
    f=$dir/docs/changes/$change.md; [ -f "$f" ] || { echo "no change pack docs/changes/$change.md" >&2; return 1; }
    awk '/^## /{ on = ($0 ~ /^## Objectives/) } on && match($0, /^- [A-Za-z0-9._-]+ \((new|preserve)\)/) { s = substr($0, 3); id = s; sub(/ .*/, "", id); k = s; sub(/^[^(]*\(/, "", k); sub(/\).*/, "", k); print id "\t" k }' "$f"
    return 0
  fi
  for f in "$dir"/docs/specs/*.md; do
    [ -f "$f" ] || continue
    [ "$spec" = - ] || [ "$(basename "$f" .md)" = "$spec" ] || continue
    awk -F'|' '/^## /{ on = ($0 ~ /^## Objectives/); next } on && /^\|/ {
      id = $2; k = $3; gsub(/[ `]/, "", id); gsub(/ /, "", k)
      if (k == "new" || k == "preserve") print id "\t" k }' "$f"
  done
}

# The command of one journey in .done-done.yaml: `  <id>: {tier: ..., command: <cmd>}`.
command_of() {  # <dir> <id>
  awk -v id="$2" '$1 == id ":" { s = $0; sub(/.*command: */, "", s); sub(/ *}[ \t]*$/, "", s); print s; exit }' "$1/.done-done.yaml" 2>/dev/null
}

# Run one journey in a tree: prints `<exit> <first output line>`.
run_journey() {  # <dir> <cmd>
  local out rc ev
  ev=$(mktemp -d "${TMPDIR:-/tmp}/jg-muster-evidence.XXXXXX") || return 1
  out=$(cd "$1" && DONE_DONE_EVIDENCE_ROOT=$ev timeout 300 bash -c "$2" 2>/dev/null </dev/null); rc=$?
  rm -rf -- "$ev"
  printf '%s %s\n' "$rc" "$(printf '%s\n' "$out" | head -n 1)"
}

cmd_objectives() {
  local project='' base='' head='' spec=- change=- tmp rows id kind cmd b h bc bl hc ok bad=0 n=0 line
  project=${1:-}; [ -n "$project" ] || die 'usage: objectives <project> --base <ref> [--head <ref>] [--spec <slug> | --change <slug>]'; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --base) base=${2:-}; shift 2 || die '--base needs a ref' ;;
      --head) head=${2:-}; shift 2 || die '--head needs a ref' ;;
      --spec) spec=${2:-}; shift 2 || die '--spec needs a slug' ;;
      --change) change=${2:-}; shift 2 || die '--change needs a slug' ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -n "$base" ] || die 'objectives needs --base <ref>'
  [ "$spec" = - ] || [ "$change" = - ] || die '--spec and --change are two ways to pick the objectives; give one'
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die "$project is not a git repository"
  git -C "$project" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "$base is not a commit of $project"
  [ -z "$head" ] || git -C "$project" rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "$head is not a commit of $project"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-muster-objectives.XXXXXX") || die 'no temporary folder'
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" EXIT
  snapshot "$project" "${head:-WORKTREE}" "$tmp/head" || die "cannot read the head of $project"
  snapshot "$project" "$base" "$tmp/base" || die "cannot read the base of $project"
  for id in $JOURNEY_PATHS; do                 # the base runs the head's journeys over the base's code
    rm -rf -- "${tmp:?}/base/$id"
    [ ! -e "$tmp/head/$id" ] || cp -a "$tmp/head/$id" "$tmp/base/$id"
  done

  rows=$(objectives_of "$tmp/head" "$spec" "$change") || die 'cannot read the objectives'
  [ -n "$rows" ] || { echo 'refused: objectives: the project names no objective (a spec Objectives table, or --change <slug>)'; return 1; }
  id=$(printf '%s\n' "$rows" | sort -u | cut -f1 | uniq -d | head -n 1)
  [ -z "$id" ] || { echo "refused: objectives: journey $id has two kinds"; return 1; }

  while IFS=$'\t' read -r id kind; do
    n=$((n + 1)); ok=1; hc=''
    cmd=$(command_of "$tmp/head" "$id")
    if [ -z "$cmd" ]; then
      echo "FAIL $id ($kind): no journey command in .done-done.yaml"; bad=$((bad + 1)); continue
    fi
    b=$(run_journey "$tmp/base" "$cmd"); bc=${b%% *}; bl=${b#* }
    case $kind in
      new) [ "$bc" = 1 ] && [[ $bl == "assert: "* ]] || ok=0 ;;
      preserve) [ "$bc" = 0 ] || ok=0 ;;
    esac
    if [ -n "$head" ]; then
      h=$(run_journey "$tmp/head" "$cmd"); hc=${h%% *}; [ "$hc" = 0 ] || ok=0
    fi
    line="$id ($kind): base exit $bc \"$bl\""; [ -z "$head" ] || line="$line; head exit $hc"
    [ "$bc" != 77 ] || line="$line [setup error]"
    if [ "$ok" = 1 ]; then echo "ok   $line"; else echo "FAIL $line"; bad=$((bad + 1)); fi
  done <<< "$rows"
  if [ "$bad" = 0 ]; then echo PASS; return 0; fi
  echo "refused: objectives: $bad journey(s) break the rule"
  return 1
}

# Every behaviour a core object names is defined in its Lives-in module.
cmd_code() {
  local project=${1:-} model miss='' row name meth mod n=0
  [ -n "$project" ] || die 'usage: code <project>'
  model=$project/docs/domain/model.md
  [ -f "$model" ] || { echo 'refused: code: docs/domain/model.md is missing'; return 1; }
  while IFS=$'\t' read -r name meth mod; do
    n=$((n + 1))
    if [ ! -f "$project/$mod" ]; then
      row="refused: code: $name.$meth not found: its module $mod is missing"
    elif ! grep -Eq "^[[:space:]]*((static|async|public|private|protected|export|function|def|fn|func)[[:space:]]+)*${meth}[[:space:]]*\\(" "$project/$mod"; then
      row="refused: code: $name.$meth not found in $mod"
    else continue; fi
    miss="$miss$row"$'\n'
  done < <(awk '
    /^## /{ core = ($0 ~ /^## Core objects/); next }
    core && /^### / { name = substr($0, 5); order[++k] = name; next }
    core && /^- Behaviour: / { s = $0; while (match(s, /`[A-Za-z_][A-Za-z0-9_]*\(/)) { beh[name, ++cnt[name]] = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) } }
    core && /^- Lives in: `/ { s = $0; sub(/^- Lives in: `/, "", s); sub(/`.*/, "", s); lives[name] = s }
    END { for (i = 1; i <= k; i++) { o = order[i]; for (j = 1; j <= cnt[o]; j++) print o "\t" beh[o, j] "\t" lives[o] } }' "$model")
  [ "$n" -gt 0 ] || { echo 'refused: code: docs/domain/model.md names no behaviour of a core object'; return 1; }
  if [ -z "$miss" ]; then echo PASS; return 0; fi
  printf '%s' "$miss"
  return 1
}

case ${1:-} in
  objectives) shift; cmd_objectives "$@" ;;
  code) shift; cmd_code "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
