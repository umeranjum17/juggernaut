#!/usr/bin/env bash
# Project state map, step 1 (search): find candidate states and moving parts in a project's
# code with grep, no model call. Read only: nothing under the project is ever changed.
# Usage: psm-search.sh <project-dir> [--out <file>] [--max-hits N] [--max-per-file N]
# Writes one psm.hits.v1 JSON document (stdout, or --out):
#   {schema, project, tree, files, hit_hash, truncated, hits:[{file, line, passes, text}]}
# Passes: p1 closed value sets, p2 flags and empty fields, p3 loops and timers, p4 machinery.
# Files: tracked files when the project is a git repo, else every file found. Skipped:
#   dependency and build folders, lock files, minified or map files, images and other binary
#   files, secret-looking names (.env*, *.pem, *.key), and files over 400 KB.
# tree      git tree of HEAD, else a hash of the file list. A map is keyed on tree + hit_hash.
# hit_hash  sha256 of the hit lines, so an edit that changes a hit changes the key.
# Caps: at most --max-per-file hits per file and pass (default 40) and --max-hits in all
#   (default 800); `truncated` counts the hits dropped, in file order.
set -euo pipefail

P1='(oneOf|one_of|[Ee]num|choices)[[:space:]]*[(:=[]|Literal\[|(STATES|STAGES|STATUSES|PHASES|MODES)\b|\b(state|status|stage|phase|mode|kind|severity|outcome)[A-Za-z_]*[[:space:]]*(===?|!==?|:)[[:space:]]*['"'"'"`][A-Za-z_-]+['"'"'"`]|['"'"'"][A-Za-z_-]+['"'"'"][[:space:]]*\|[[:space:]]*['"'"'"][A-Za-z_-]+['"'"'"]|case[[:space:]]+['"'"'"][A-Za-z_-]+['"'"'"][[:space:]]*:'
P2='(resolved|closed|done|ended|completed|finished|deleted|cancel[l]?ed|failed)_?[Aa]t\b|_at[[:space:]]*(===?|!==?|is|is not)[[:space:]]*(null|None|nil|undefined)|\b(is|has)_?[A-Za-z]*(Stuck|Blocked|Failed|Done|Ready|Open|Closed|Resolved|Pending|Stale|Locked|Enabled|Paused)\b|\b(stuck|blocked|paused|stale|locked|expired|cancel[l]?ed|dirty|retired)\b[[:space:]]*(===?|!==?|=|:|\?|&&|\|\|)|!\w+(\.\w+)*\.(resolved|closed|done|ended|completed|deleted|finished)'
P3='\b(setInterval|setTimeout|AbortSignal\.timeout|time\.sleep|sleep[[:space:]]+[0-9]|cron|crontab|retry|retries|backoff|debounce|throttle|ttl|poll(ing)?|schedule[dr]?|interval)\b|while[[:space:]]*(\(true\)|true|1\b|\[[[:space:]]*(true|:)|:)|for[[:space:]]*\([[:space:]]*;[[:space:]]*;|every[[:space:]]+[0-9]+[[:space:]]*(s|m|h|sec|min|hour)'
P4='\b(createServer|\.listen\(|spawn(Sync)?\(|exec(Sync|File)?\(|subprocess\.|fetch\(|axios|requests\.(get|post)|http\.(get|request)|createConnection|net\.connect|WebSocket|sqlite|postgres|mysql|redis|mongo|kafka|rabbitmq|amqp|sqs|queue)\b|from[[:space:]]+['"'"'"]node:(http|https|net|child_process|worker_threads|cluster)['"'"'"]|^[[:space:]]*(FROM|EXPOSE|ENTRYPOINT|CMD)[[:space:]]|\b(runs-on|ExecStart|systemd)\b|^(on|jobs):'

max_hits=800 max_file=40 out='' dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out=${2:?}; shift 2 ;;
    --max-hits) max_hits=${2:?}; shift 2 ;;
    --max-per-file) max_file=${2:?}; shift 2 ;;
    -h|--help) sed -n 2,17p "$0" | cut -c3-; exit 0 ;;
    -*) echo "psm-search: unknown argument $1" >&2; exit 2 ;;
    *) [ -z "$dir" ] || { echo 'psm-search: one project directory only' >&2; exit 2; }; dir=$1; shift ;;
  esac
done
[ -n "$dir" ] || { sed -n 2,4p "$0" | cut -c3- >&2; exit 2; }
[ -d "$dir" ] || { echo "psm-search: not a directory: $dir" >&2; exit 2; }
case "$max_hits$max_file" in *[!0-9]*|'') echo 'psm-search: caps need digits' >&2; exit 2 ;; esac
for c in jq grep xargs sha256sum; do command -v "$c" >/dev/null || { echo "psm-search: needs $c" >&2; exit 2; }; done
dir=$(cd "$dir" && pwd -P)
# A pattern grep cannot compile would look like "no hits"; stop and name it instead.
for p in P1 P2 P3 P4; do
  rc=0; : | grep -E -e "${!p}" >/dev/null 2>&1 || rc=$?
  [ "$rc" -le 1 ] || { echo "psm-search: pattern $p does not compile in this grep" >&2; exit 2; }
done

t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
tree=''
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "$(git -C "$dir" rev-parse --show-toplevel)" = "$dir" ]; then
  git -C "$dir" ls-files -z --cached --exclude-standard > "$t/all"
  tree=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
else
  (cd "$dir" && find . -type f -not -path '*/.git/*' -print0 | sed -z 's|^\./||') > "$t/all"
fi

# Candidate files: skip dependency and build output, generated, binary and secret-looking files.
: > "$t/files"
while IFS= read -r -d '' f; do
  case "/$f" in
    */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/target/*|*/.next/*|*/__pycache__/*|*/venv/*|*/.venv/*|*/coverage/*|*/.git/*) continue ;;
    *.lock|*lock.json|*.lockb|*.min.*|*.map|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.gz|*.woff|*.woff2|*.ttf|*.sqlite|*.db) continue ;;
    */.env|*/.env.*|*.pem|*.key|*.p12|*/id_rsa*) continue ;;
    *:*) continue ;;
  esac
  [ -f "$dir/$f" ] && [ ! -L "$dir/$f" ] || continue
  [ "$(wc -c < "$dir/$f")" -le 400000 ] || continue
  printf '%s\0' "$f" >> "$t/files"
done < "$t/all"
[ -n "$tree" ] || tree=$(tr '\0' '\n' < "$t/files" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
files=$(tr -cd '\0' < "$t/files" | wc -c)

# One grep per pass over the candidate files; -I skips binary content. Output: pass TAB file TAB line TAB text.
run_pass() { # run_pass <name> <pattern>
  (cd "$dir" && xargs -0 -r grep -nIHE -m "$max_file" -e "$2" < "$t/files" 2>/dev/null || true) |
    sed -E -n 's/^([^:]+):([0-9]+):(.*)$/\1\t\2\t\3/p' | awk -F '\t' -v p="$1" 'BEGIN { OFS = "\t" } { print p, $1, $2, substr($3, 1, 240) }'
}
{ run_pass p1 "$P1"; run_pass p2 "$P2"; run_pass p3 "$P3"; run_pass p4 "$P4"; } > "$t/raw"

jq -R -s --arg project "$dir" --arg tree "$tree" --argjson files "$files" --argjson cap "$max_hits" '
  [split("\n")[] | select(length > 0) | split("\t") | {pass: .[0], file: .[1], line: (.[2] | tonumber), text: (.[3:] | join(" ") | gsub("^\\s+|\\s+$"; ""))}]
  | group_by([.file, .line]) | map({file: .[0].file, line: .[0].line, passes: (map(.pass) | unique), text: .[0].text})
  | sort_by([.file, .line]) as $all
  | ($all[:$cap]) as $kept
  | {schema: "psm.hits.v1", project: $project, tree: $tree, files: $files,
     truncated: (($all | length) - ($kept | length)), hits: $kept}' < "$t/raw" > "$t/doc"
hash=$(jq -r '.hits[] | "\(.file):\(.line):\(.text)"' "$t/doc" | sha256sum | cut -d' ' -f1)
jq --arg h "$hash" '. + {hit_hash: $h}' "$t/doc" > "$t/final"
if [ -n "$out" ]; then cp "$t/final" "$out"; else cat "$t/final"; fi
