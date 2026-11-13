#!/usr/bin/env bash
# judge.sh - one verdict per commit (H29g): sourced by bin/jg-trunk.sh, or run as `judge.sh record|show`.
#
# Three judges read one commit: the lander's tip run, the line's verify and the nightly whole run. They already read one result
# cache (bin/jg-test-cache.sh, H29f), so their verdicts on one tree must agree. Each judge writes what it saw here, and a second
# judge that saw something else on the same tree raises the alert `judge-split` once, naming both judges and the scripts.
#
#   judge.sh record <judge> <commit> [<failed script>...]  [--project <name>]
#       <judge> is tip, verify or nightly. The verdict is the set of scripts that failed on the tree at the end of the judge's
#       own run, before it was compared with any base: an empty set is green. Prints "agree" or "split <judge> <judge> ...".
#   judge.sh show <commit> [--project <name>]
#       Print the verdicts kept for the commit's tree, one line each: epoch, judge, commit, green or the failed scripts.
#
# The ledger is data/trunk/judge-<project>.tsv, append only: epoch, tree, commit, judge, failed scripts (one word, "-" is green,
# scripts joined by a comma). Two verdicts agree when their failed sets are equal. The key is the tree, so a rebuilt commit with
# the same tree is the same subject. A judge that runs again replaces its own earlier verdict (the newest row of a judge counts).
# One alert per tree: judge-split--<project>-<tree 12> (bin/jg-alert.sh), raised through JG_JUDGE_ALERT when that names a tool.
# The project defaults to JG_QUARANTINE_PROJECT, else juggernaut; the repository is JG_JUDGE_REPO, else the current directory.
# Exit 2: usage error.

judge_die() { echo "judge: $*" >&2; exit 2; }

# judge_record <project> <repo> <data> <alert tool> <judge> <commit> [<script>...]: records the verdict, raises on a split.
judge_record() {
  local project=$1 repo=$2 data=$3 alert=$4 judge=$5 commit=$6 tree ledger failed='-' other sets line j f
  shift 6
  case $judge in tip|verify|nightly) ;; *) echo "judge: the judge is tip, verify or nightly, got $judge" >&2; return 2 ;; esac
  tree=$(git -C "$repo" rev-parse "$commit^{tree}" 2>/dev/null) || { echo "judge: $commit has no tree in $repo" >&2; return 2; }
  if [ "$#" -gt 0 ]; then failed=$(printf '%s\n' "$@" | LC_ALL=C sort -u | paste -sd, -); fi
  ledger="$data/trunk/judge-$project.tsv"
  mkdir -p "$data/trunk" || return 2
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$tree" "$commit" "$judge" "$failed" >> "$ledger" || return 2
  # the newest row of each judge on this tree
  sets=$(awk -F'\t' -v t="$tree" '$2 == t { last[$4] = $5 } END { for (j in last) print j "\t" last[j] }' "$ledger" | LC_ALL=C sort)
  other=''
  while IFS=$'\t' read -r j f; do
    [ -n "$j" ] && [ "$f" != "$failed" ] && [ "$j" != "$judge" ] && other="$other $j=$([ "$f" = - ] && echo green || echo "$f")"
  done <<< "$sets"
  if [ -z "$other" ]; then echo agree; return 0; fi
  line="two verdicts on ${commit:0:12} (tree ${tree:0:12}): $judge=$([ "$failed" = - ] && echo green || echo "$failed");$other"
  echo "split $line"
  [ -z "$alert" ] || "$alert" raise judge-split "$project-${tree:0:12}" --project "$project" --note "$line" --deliver >/dev/null 2>&1 \
    || echo "warning: could not raise judge-split" >&2
  return 0
}

judge_show() {  # <project> <repo> <data> <commit>
  local tree
  tree=$(git -C "$2" rev-parse "$4^{tree}" 2>/dev/null) || { echo "judge: $4 has no tree in $2" >&2; return 2; }
  awk -F'\t' -v t="$tree" '$2 == t { printf "%s\t%s\t%s\t%s\n", $1, $4, $3, ($5 == "-" ? "green" : $5) }' "$3/trunk/judge-$1.tsv" 2>/dev/null
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  ROOT=$(cd "$SELF_DIR/../.." && pwd -P)
  JG_HOME="${JG_HOME:-$ROOT}"
  J_PROJECT=${JG_QUARANTINE_PROJECT:-juggernaut} J_ARGS=()
  case ${1:-} in -h|--help|"") sed -n '2,/^# Exit 2/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
  J_CMD=$1; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --project) [ $# -ge 2 ] || judge_die "--project needs a name"; J_PROJECT=$2; shift 2 ;;
      *) J_ARGS+=("$1"); shift ;;
    esac
  done
  [[ $J_PROJECT =~ ^[A-Za-z0-9._-]+$ ]] || judge_die "the project name has characters a file name cannot hold: $J_PROJECT"
  J_DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
  J_REPO="${JG_JUDGE_REPO:-$PWD}"
  J_ALERT="${JG_JUDGE_ALERT-$ROOT/bin/jg-alert.sh}"
  case $J_CMD in
    record) [ "${#J_ARGS[@]}" -ge 2 ] || judge_die "record needs <judge> <commit>"
      judge_record "$J_PROJECT" "$J_REPO" "$J_DATA" "$J_ALERT" "${J_ARGS[@]}" ;;
    show) [ "${#J_ARGS[@]}" -eq 1 ] || judge_die "show needs <commit>"
      judge_show "$J_PROJECT" "$J_REPO" "$J_DATA" "${J_ARGS[0]}" ;;
    *) judge_die "unknown command $J_CMD" ;;
  esac
fi
